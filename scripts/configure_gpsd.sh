#!/usr/bin/env bash
set -euo pipefail

config="${HOME}/.config/noaa-navionics/config.ini"
device=""
allow_non_pi=0
dry_run=0
check_device=1

usage() {
  cat >&2 <<'EOF'
Usage: scripts/configure_gpsd.sh --device /dev/serial/by-id/YOUR_GPS [options]

Options:
  --config PATH       NOAA Navionics config path
  --dry-run           Print intended changes without writing system files
  --no-device-check   Do not require the GPS device path to exist now
  --allow-non-pi      Allow running on non-Raspberry Pi architecture

Configures GPSD on the Raspberry Pi and updates NOAA Navionics config.
EOF
}

sync_path() {
  local path="$1"
  sudo python3 - "$path" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
with path.open("rb") as handle:
    os.fsync(handle.fileno())
try:
    fd = os.open(path.parent, os.O_RDONLY)
except OSError:
    fd = None
if fd is not None:
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

volatile_usb_device_path() {
  case "$(basename "$1")" in
    ttyUSB*|ttyACM*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      device="${2:-}"
      shift 2
      ;;
    --config)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      config="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --no-device-check)
      check_device=0
      shift
      ;;
    --allow-non-pi)
      allow_non_pi=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$device" ]]; then
  echo "--device is required" >&2
  usage
  exit 2
fi

case "$device" in
  /dev/*)
    ;;
  *)
    echo "GPS device must be an absolute /dev path: $device" >&2
    exit 2
    ;;
esac

if [[ "$device" =~ [[:space:]\"\'] ]]; then
  echo "GPS device path must not contain whitespace or quotes: $device" >&2
  exit 2
fi

if volatile_usb_device_path "$device"; then
  cat >&2 <<EOF
GPS device path is volatile: $device
Use /dev/serial/by-id/... for USB GPS receivers, or a stable Raspberry Pi serial alias such as /dev/serial0.
EOF
  exit 2
fi

arch="$(uname -m)"
if [[ "$allow_non_pi" -eq 0 && "$arch" != armv7l && "$arch" != aarch64 ]]; then
  cat >&2 <<EOF
Refusing to configure GPSD on architecture '$arch'.
Run this on the Raspberry Pi, or pass --allow-non-pi for development-only testing.
EOF
  exit 2
fi

if [[ "$check_device" -eq 1 && ! -e "$device" ]]; then
  cat >&2 <<EOF
GPS device does not exist: $device
Use a stable path from /dev/serial/by-id/, or pass --no-device-check if it is not plugged in yet.
EOF
  exit 2
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat >"$tmp" <<EOF
START_DAEMON="true"
USBAUTO="false"
DEVICES="$device"
GPSD_OPTIONS="-n"
EOF

if [[ "$dry_run" -eq 1 ]]; then
  echo "Would write /etc/default/gpsd:"
  cat "$tmp"
  echo
  echo "Would update $config with gps.mode=gpsd and gps.device=$device"
  exit 0
fi

if [[ -e /etc/default/gpsd ]]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="/etc/default/gpsd.noaa-navionics.${stamp}.bak"
  sudo cp -a /etc/default/gpsd "$backup"
  sync_path "$backup"
fi

sudo install -m 0644 "$tmp" /etc/default/gpsd
sync_path /etc/default/gpsd
sudo systemctl enable --now gpsd
sudo systemctl restart gpsd

mkdir -p "$(dirname "$config")"
python3 - "$config" "$device" <<'PY'
from configparser import ConfigParser
from pathlib import Path
import os
import sys
import tempfile

config_path = Path(sys.argv[1]).expanduser()
device = sys.argv[2]
parser = ConfigParser()
if config_path.exists():
    parser.read(config_path)
if not parser.has_section("gps"):
    parser.add_section("gps")
parser.set("gps", "mode", "gpsd")
parser.set("gps", "device", device)
parser.set("gps", "gpsd_host", "127.0.0.1")
parser.set("gps", "gpsd_port", "2947")
tmp_path = None
try:
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=config_path.parent,
        prefix=f".{config_path.name}.",
        suffix=".part",
        delete=False,
    ) as handle:
        tmp_path = Path(handle.name)
        parser.write(handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp_path, config_path)
    try:
        fd = os.open(config_path.parent, os.O_RDONLY)
    except OSError:
        fd = None
    if fd is not None:
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
finally:
    if tmp_path is not None:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
PY

echo "Configured GPSD for $device"
echo "Updated $config"
echo "Verify with: cgps"
echo "Then run: noaa-navionics gps-monitor --gpsd --once"
