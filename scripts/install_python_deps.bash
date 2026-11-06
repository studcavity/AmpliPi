#!/bin/bash
# Helper script for configure.py
#
# Uses the OS's own Python (Debian Trixie / Raspberry Pi OS Trixie ship 3.13) and its venv + pip,
# so nothing gets piped from the internet into a shell and the interpreter is pinned by the OS
# image itself. python3-venv and python3-dev (headers for the few packages that build from source,
# e.g. RPi.GPIO, spidev, PyGObject, dbus-python) are installed by configure.py's base os deps.

set -e
cd "$( dirname "$0" )"/..

VENV=/home/pi/amplipi-dev/venv
TARGET_PYTHON=3.13
PYTHON=/usr/bin/python${TARGET_PYTHON}

if [[ ! -x $PYTHON ]]; then
  echo "ERROR: $PYTHON not found - this release expects Raspberry Pi OS / Debian Trixie (Python $TARGET_PYTHON)"
  exit 1
fi

# Rebuild the venv if it's missing, or if it exists but isn't running the target Python version -
# e.g. the Python 3.8 venv uv created on earlier Trixie builds. Without this check, pip install
# below would silently install into a stale interpreter instead of failing loudly.
current_python=""
if [[ -e $VENV/bin/python ]]; then
  current_python=$($VENV/bin/python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
fi
if [[ ! -d $VENV ]] || [[ ! -e $VENV/bin/python ]] || [[ "$current_python" != "$TARGET_PYTHON" ]]; then
  echo ""
  if [[ -n "$current_python" && "$current_python" != "$TARGET_PYTHON" ]]; then
    echo "Existing virtual environment is Python $current_python, rebuilding for Python $TARGET_PYTHON"
  else
    echo "Setting up virtual environment"
  fi
  rm -rf "$VENV"
  $PYTHON -m venv "$VENV"
fi

# Inside a venv, Trixie's PEP 668 "externally managed" block doesn't apply.
$VENV/bin/python -m pip install --upgrade --disable-pip-version-check -q 'pip==25.2'
$VENV/bin/python -m pip install --disable-pip-version-check -r requirements.txt

echo "install python deps complete!"
