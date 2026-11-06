#!/usr/bin/env bash
set -euo pipefail

BOOT_MOUNT="/boot/firmware"
AUTOBOOT_MOUNT="/boot/autoboot"
PENDING_FILE="${BOOT_MOUNT}/update-pending"
AUTOBOOT_FILE="${AUTOBOOT_MOUNT}/autoboot.txt"
UPDATE_LOG="/data/update-log.txt"

log() {
  local msg="[$(date -Iseconds)] amplipi-tryboot-verify: $*"
  echo "${msg}"
  echo "${msg}" >> "${UPDATE_LOG}" 2>/dev/null || true
}

# Retry helper: retry N times with DELAY seconds between attempts
retry() {
  local n=$1 delay=$2; shift 2
  for i in $(seq 1 "${n}"); do
    if "$@" &>/dev/null; then return 0; fi
    [ "${i}" -lt "${n}" ] && sleep "${delay}"
  done
  return 1
}

# BOOT_SLOT is injected via systemd.setenv on the kernel cmdline. If it's missing we can't tell
# which slot we're on, so treat it as a failed trial boot rather than dying under `set -u` and
# leaving the unit to sit until the 15-minute deadline fires.
if [ -z "${BOOT_SLOT:-}" ]; then
  current_part=""
else
  current_part=$( [[ "${BOOT_SLOT}" == "A" ]] && echo 2 || echo 3 )
fi

commit() { # Swap which boot slot is considered primary and secondary p1's autoboot.txt
  local old_part
  if [ "${current_part}" = "2" ]; then old_part=3; else old_part=2; fi

  log "Committing: p${current_part} becomes default, p${old_part} becomes tryboot"

  # Not required for correctness (amplipi-boot-deadline-fire.sh no-ops once
  # update-pending is gone), but avoids leaving a 15min transient timer
  # ticking down to a no-op after every successful update.
  systemctl stop amplipi-boot-deadline-fire.timer 2>/dev/null || true

  mount -o remount,rw "${AUTOBOOT_MOUNT}"
  python3 /usr/local/bin/update_autoboot.py "${AUTOBOOT_FILE}" "${current_part}" "${old_part}"
  mount -o remount,ro "${AUTOBOOT_MOUNT}"

  mount -o remount,rw "${BOOT_MOUNT}"
  rm -f "${PENDING_FILE}"
  mount -o remount,ro "${BOOT_MOUNT}"

  # The update this commit just finalized is now what's actually running - the multi-GB images
  # that got us here have served their purpose. Removing them now (rather than letting them sit on
  # /data indefinitely, or waiting for scripts/imaging/cleanup to catch them manually) reclaims that space
  # right when it's safe to: do_checks() and the flash itself may still need them right up until
  # this point, but nothing after commit does.
  log "Cleaning up /data/update/ (images for the now-committed update)"
  rm -f /data/update/root.img.xz /data/update/boot.img.xz /data/update/manifest.json

  # Runs after commit, not before: firmware isn't part of the tryboot/revert contract, so this
  # only ever touches the preamp once the OS-level update is already confirmed good and
  # permanent - never against content that might still get reverted. Failure here doesn't undo
  # the commit above; a bad flash and an already-good OS update are independent concerns.
  # amplipi.service drives the same I2C bus and serial line the flasher uses - stop it for the
  # duration, and always bring it back afterward whether or not the flash worked.
  log "Checking preamp firmware"
  systemctl stop amplipi || log "Warning: couldn't stop amplipi before firmware check"
  bash /home/pi/amplipi-dev/scripts/update/flash_latest_firmware 2>&1 | while read -r line; do log "$line"; done \
    || log "Warning: firmware flash failed - will retry on the next update"
  systemctl start amplipi || log "Warning: couldn't restart amplipi after firmware check"

  log "Commit complete. Default: p${current_part} | Tryboot: p${old_part}"
}

revert() { # If anything is unsuccessful, revert to the previous boot slot
  local reason="$1"
  log "Health check failed: ${reason} — rebooting to trigger auto-revert"
  mount -o remount,rw "${BOOT_MOUNT}" 2>/dev/null || true
  rm -f "${PENDING_FILE}"
  mount -o remount,ro "${BOOT_MOUNT}" 2>/dev/null || true
  systemctl reboot
}

# ---- Main ----

if [ ! -f "${PENDING_FILE}" ]; then
  log "No update pending — exiting"
  exit 0
fi

expected_part=$(tr -d '[:space:]' < "${PENDING_FILE}")
log "Trial boot detected. Expected p${expected_part}, running on p${current_part}"

if [ -z "${current_part}" ]; then
  revert "BOOT_SLOT not set on the kernel cmdline - cannot identify the running slot"
  exit 0
fi

if [ "${current_part}" != "${expected_part}" ]; then
  revert "Booted on wrong partition (expected p${expected_part}, got p${current_part})"
  exit 0
fi

log "Running health checks"

failed_checks=()

# timeout 10 on the systemctl calls: retry()'s own sleep only happens *between* attempts, not
# around the command itself, so without this a single wedged systemctl/dbus call (rare, but a
# real failure mode - stuck dbus, hung systemd manager) blocks here forever with no way out,
# instead of correctly failing the check and reverting. 10s is generous relative to how fast a
# healthy call actually returns (milliseconds), so this can't cause a spurious revert on a normal,
# even slow, boot - it only ever fires when a call is genuinely stuck well past any legitimate
# response time. curl already self-bounds via --max-time 5, so it doesn't need this.
retry 12 5 timeout 10 systemctl is-active amplipi       || failed_checks+=("amplipi service")
retry 12 5 timeout 10 systemctl is-active amplipi-tasks || failed_checks+=("amplipi-tasks service")
retry 6  5 timeout 10 systemctl is-active redis-server                || failed_checks+=("redis-server service")
# /api sits behind CookieOrParamAPIKey, so on a password-protected unit an unauthenticated request
# 401s and the check would fail on every update. We run as root, so read any stored access key
# straight out of the users file and pass it as the api-key query param. With no keys set (no
# password), auth is open and the bare URL works.
api_url="http://localhost/api"
api_key=$(python3 - <<'PYEOF' 2>/dev/null || true
import json
try:
  with open('/data/.config/amplipi/users.json', encoding='utf-8') as f:
    users = json.load(f)
  for u in users.values():
    if isinstance(u, dict) and u.get('access_key'):
      print(u['access_key'])
      break
except Exception:
  pass
PYEOF
)
if [ -n "${api_key}" ]; then
  api_url="${api_url}?api-key=${api_key}"
fi
retry 12 5 curl -sf --max-time 5 "${api_url}"      || failed_checks+=("API health check")

if [ "${#failed_checks[@]}" -gt 0 ]; then
  revert "Failed: ${failed_checks[*]}"
  exit 0
fi

commit
