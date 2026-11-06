""" Where AmpliPi keeps its persistent data.

Deliberately dependency-free (stdlib only): the updater, auth and the standalone stream helper
scripts all import this, and the updater has to keep working when the rest of AmpliPi is broken.

Resolution order for DATA_DIR:
  1. $AMPLIPI_DATA_DIR, if set (tests, dev boxes, unusual installs).
  2. On an A/B-imaged unit (BOOT_SLOT on the kernel cmdline) always /data. Never fall back there:
     if /data failed to mount, silently writing a fresh config to the root slot would look like a
     factory reset and then vanish on the next slot swap. Better to fail loudly.
  3. /data, if it exists (CI and hand-built dev setups that mimic the device).
  4. The user's home directory, so config lands in ~/.config/amplipi - the pre-A/B location, which
     keeps dev machines and legacy installs working without any migration.
"""

import os

_DEVICE_DATA_DIR = '/data'


def _on_ab_device() -> bool:
  try:
    with open('/proc/cmdline', encoding='utf-8') as cmdline:
      return 'BOOT_SLOT=' in cmdline.read()
  except OSError:
    return False


def _resolve_data_dir() -> str:
  override = os.environ.get('AMPLIPI_DATA_DIR')
  if override:
    return override
  if _on_ab_device() or os.path.isdir(_DEVICE_DATA_DIR):
    return _DEVICE_DATA_DIR
  return os.path.expanduser('~')


DATA_DIR = _resolve_data_dir()
""" Root of persistent, slot-independent storage (/data on a device). """

USER_CONFIG_DIR = os.path.join(DATA_DIR, '.config', 'amplipi')
""" AmpliPi's config: house.json, users.json, identity, per-source stream state, ... """
