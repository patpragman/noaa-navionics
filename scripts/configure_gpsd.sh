#!/usr/bin/env bash
set -euo pipefail
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${HOME}/.config/noaa-navionics/config.ini"
gpsd_conf="/etc/default/gpsd"
device=""
allow_non_pi=0
dry_run=0
check_device=1

usage() {
  cat >&2 <<'EOF'
Usage: scripts/configure_gpsd.sh --device /dev/serial/by-id/YOUR_GPS [options]

Options:
  --config PATH       NOAA Navionics config path
  --gpsd-conf PATH    GPSD config path for dry-run inspection
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
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path.parent, flags)
except OSError:
    fd = None
if fd is not None:
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

backup_root_file_private() {
  local source="$1"
  local backup="$2"
  sudo python3 - "$source" "$backup" <<'PY'
from pathlib import Path
import os
import stat
import sys

source = Path(sys.argv[1])
backup = Path(sys.argv[2])
parent = backup.parent
nofollow = getattr(os, "O_NOFOLLOW", 0)

if source.is_symlink():
    raise SystemExit(f"root config source is a symlink: {source}")
if parent.is_symlink():
    raise SystemExit(f"root config backup directory is a symlink: {parent}")
if not parent.exists() or not parent.is_dir():
    raise SystemExit(f"root config backup parent is not a directory: {parent}")
parent_stat = parent.stat()
parent_mode = parent_stat.st_mode & 0o777
if parent_stat.st_uid != 0:
    raise SystemExit(f"root config backup directory {parent} is owned by uid {parent_stat.st_uid}, expected root")
if parent_mode & 0o022:
    raise SystemExit(
        f"root config backup directory {parent} has permissions {parent_mode:04o}, "
        "expected no group/other write bits"
    )
if backup.exists() or backup.is_symlink():
    raise SystemExit(f"root config backup already exists: {backup}")

src_fd = None
dst_fd = None
created = False
completed = False
try:
    src_fd = os.open(source, os.O_RDONLY | nofollow)
    source_stat = os.fstat(src_fd)
    source_mode = source_stat.st_mode & 0o777
    if not stat.S_ISREG(source_stat.st_mode):
        raise SystemExit(f"root config source is not a regular file: {source}")
    if source_stat.st_uid != 0:
        raise SystemExit(f"root config source {source} is owned by uid {source_stat.st_uid}, expected root")
    if source_mode & 0o022:
        raise SystemExit(
            f"root config source {source} has permissions {source_mode:04o}, "
            "expected no group/other write bits"
        )

    dst_fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow, 0o600)
    created = True
    os.fchmod(dst_fd, 0o600)
    while True:
        chunk = os.read(src_fd, 1024 * 1024)
        if not chunk:
            break
        offset = 0
        while offset < len(chunk):
            offset += os.write(dst_fd, chunk[offset:])
    os.fsync(dst_fd)
    completed = True
finally:
    if dst_fd is not None:
        os.close(dst_fd)
    if src_fd is not None:
        os.close(src_fd)
    if created and not completed:
        try:
            backup.unlink()
        except FileNotFoundError:
            pass

try:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent_fd = os.open(parent, flags)
except OSError:
    parent_fd = None
if parent_fd is not None:
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)

backup_stat = backup.stat()
backup_mode = backup_stat.st_mode & 0o777
if backup_stat.st_uid != 0 or backup_mode != 0o600:
    try:
        backup.unlink()
    finally:
        raise SystemExit(f"root config backup was not created as root-owned 0600: {backup}")
PY
}

install_root_file_atomic() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local target_dir
  local target_name
  local target_tmp
  target_dir="$(dirname "$target")"
  target_name="$(basename "$target")"
  sudo install -d -m 0755 "$target_dir"
  target_tmp="$(sudo mktemp "${target_dir}/.${target_name}.XXXXXX")"
  if ! sudo install -m "$mode" "$source" "$target_tmp"; then
    sudo rm -f "$target_tmp"
    return 1
  fi
  if ! sync_path "$target_tmp"; then
    sudo rm -f "$target_tmp"
    return 1
  fi
  if ! sudo mv -f "$target_tmp" "$target"; then
    sudo rm -f "$target_tmp"
    return 1
  fi
  sync_path "$target"
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

stable_gps_device_path() {
  case "$1" in
    /dev/serial/by-id/*)
      local suffix="${1#/dev/serial/by-id/}"
      [[ -n "$suffix" && "$suffix" != */* && "$suffix" != "." && "$suffix" != ".." && "$suffix" =~ ^[A-Za-z0-9._:+@-]+$ ]]
      return
      ;;
    /dev/serial0|/dev/serial1|/dev/gps)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_updated_app_config() {
  python3 - "$repo_root" "$config" "$device" <<'PY'
from configparser import ConfigParser
from pathlib import Path
import os
import sys
import tempfile

repo_root = Path(sys.argv[1])
config_path = Path(sys.argv[2]).expanduser()
device = sys.argv[3]

sys.path.insert(0, str(repo_root / "src"))
from noaa_navionics.config import _read_existing_config, _reject_unsafe_config_path, read_config

parser = ConfigParser()
_reject_unsafe_config_path(config_path)
if config_path.exists():
    _read_existing_config(parser, config_path)
if not parser.has_section("gps"):
    parser.add_section("gps")
parser.set("gps", "mode", "gpsd")
parser.set("gps", "device", device)
parser.set("gps", "gpsd_host", "127.0.0.1")
parser.set("gps", "gpsd_port", "2947")

tmp_path = None
try:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        tmp_path = Path(handle.name)
        parser.write(handle)
        handle.flush()
        os.fsync(handle.fileno())
    app_config = read_config(tmp_path)
finally:
    if tmp_path is not None:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass

if app_config.gps_mode != "gpsd":
    raise SystemExit("updated config did not set gps.mode=gpsd")
if app_config.gps_device != device:
    raise SystemExit(f"updated config GPS device mismatch: {app_config.gps_device} != {device}")
if app_config.gpsd_host != "127.0.0.1" or app_config.gpsd_port != 2947:
    raise SystemExit("updated config did not set local GPSD host and port")
PY
}

prepare_app_config_path() {
  python3 - "$repo_root" "$config" "$dry_run" <<'PY'
from pathlib import Path
import os
import sys

repo_root = Path(sys.argv[1])
config_path = Path(sys.argv[2]).expanduser()
dry_run = sys.argv[3] == "1"

sys.path.insert(0, str(repo_root / "src"))
from noaa_navionics.config import _prepare_config_parent

parent = config_path.parent
if dry_run and not parent.exists() and not parent.is_symlink():
    raise SystemExit(0)
_prepare_config_parent(config_path)
PY
}

validate_gpsd_config_path() {
  python3 - "$gpsd_conf" "$dry_run" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
dry_run = sys.argv[2] == "1"
parent = path.parent

def first_symlink_ancestor(candidate):
    current = Path(candidate).expanduser()
    for component in [current, *current.parents]:
        if component.is_symlink():
            return component
    return None

if path.is_symlink():
    raise SystemExit(f"GPSD config is a symlink: {path}")
if path.exists() and not path.is_file():
    raise SystemExit(f"GPSD config is not a regular file: {path}")
if parent.is_symlink():
    raise SystemExit(f"GPSD config directory is a symlink: {parent}")
symlink_component = first_symlink_ancestor(parent)
if symlink_component is not None:
    raise SystemExit(f"GPSD config directory is a symlink: {symlink_component}")
if parent.exists():
    if not parent.is_dir():
        raise SystemExit(f"GPSD config parent is not a directory: {parent}")
    parent_stat = parent.stat()
    parent_mode = parent_stat.st_mode & 0o777
    if parent_mode & 0o022:
        raise SystemExit(
            f"GPSD config directory {parent} has permissions {parent_mode:04o}, "
            "expected no group/other write bits"
        )
    if not dry_run and parent_stat.st_uid != 0:
        raise SystemExit(f"GPSD config directory {parent} is owned by uid {parent_stat.st_uid}, expected root")
elif not dry_run:
    ancestor = parent.parent
    if ancestor.is_symlink():
        raise SystemExit(f"GPSD config parent directory is below a symlink: {ancestor}")
    if not ancestor.exists() or not ancestor.is_dir():
        raise SystemExit(f"GPSD config parent ancestor is not a directory: {ancestor}")
    ancestor_stat = ancestor.stat()
    ancestor_mode = ancestor_stat.st_mode & 0o777
    if ancestor_stat.st_uid != 0:
        raise SystemExit(f"GPSD config parent ancestor {ancestor} is owned by uid {ancestor_stat.st_uid}, expected root")
    if ancestor_mode & 0o022:
        raise SystemExit(
            f"GPSD config parent ancestor {ancestor} has permissions {ancestor_mode:04o}, "
            "expected no group/other write bits"
        )
if not dry_run and path.exists():
    path_stat = path.stat()
    path_mode = path_stat.st_mode & 0o777
    if path_stat.st_uid != 0:
        raise SystemExit(f"GPSD config {path} is owned by uid {path_stat.st_uid}, expected root")
    if path_mode & 0o022:
        raise SystemExit(
            f"GPSD config {path} has permissions {path_mode:04o}, expected no group/other write bits"
        )
PY
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
    --gpsd-conf)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      gpsd_conf="${2:-}"
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

if [[ "$dry_run" -eq 0 && "$(id -u)" -eq 0 ]]; then
  cat >&2 <<'EOF'
Do not configure GPSD as root.
Run this as the Pi desktop user; the script uses sudo only for system GPSD changes.
EOF
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

case "$gpsd_conf" in
  /*)
    ;;
  *)
    echo "GPSD config path must be absolute: $gpsd_conf" >&2
    exit 2
    ;;
esac

if [[ "$gpsd_conf" =~ [[:space:]\"\'] ]]; then
  echo "GPSD config path must not contain whitespace or quotes: $gpsd_conf" >&2
  exit 2
fi

if [[ "$dry_run" -eq 0 && "$gpsd_conf" != "/etc/default/gpsd" ]]; then
  cat >&2 <<EOF
Refusing to write a non-standard GPSD config path: $gpsd_conf
Use /etc/default/gpsd for production, or --dry-run for custom-path inspection.
EOF
  exit 2
fi

if volatile_usb_device_path "$device"; then
  cat >&2 <<EOF
GPS device path is volatile: $device
Use /dev/serial/by-id/... for USB GPS receivers, or a stable Raspberry Pi serial alias such as /dev/serial0.
EOF
  exit 2
fi

if ! stable_gps_device_path "$device"; then
  cat >&2 <<EOF
GPS device path is not a recognized stable path: $device
Use /dev/serial/by-id/... for USB GPS receivers, /dev/serial0 or /dev/serial1 for Raspberry Pi UART GPS, or /dev/gps for a managed stable alias.
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

if [[ "$check_device" -eq 1 && -d "$device" ]]; then
  echo "GPS device path is a directory, not a GPS device: $device" >&2
  exit 2
fi

if [[ "$check_device" -eq 1 && ! -c "$device" ]]; then
  echo "GPS device path is not a character device: $device" >&2
  exit 2
fi

prepare_app_config_path
validate_updated_app_config
validate_gpsd_config_path

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat >"$tmp" <<EOF
START_DAEMON="true"
USBAUTO="false"
DEVICES="$device"
GPSD_OPTIONS="-n"
EOF

if [[ "$dry_run" -eq 1 ]]; then
  echo "Would write $gpsd_conf:"
  cat "$tmp"
  echo
  echo "Would update $config with gps.mode=gpsd and gps.device=$device"
  exit 0
fi

if [[ -e "$gpsd_conf" ]]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${gpsd_conf}.noaa-navionics.${stamp}.bak"
  backup_root_file_private "$gpsd_conf" "$backup"
fi

install_root_file_atomic "$tmp" "$gpsd_conf" 0644
sudo systemctl daemon-reload
sudo systemctl enable --now gpsd.socket gpsd.service
sudo systemctl restart gpsd.socket gpsd.service

python3 - "$repo_root" "$config" "$device" <<'PY'
from configparser import ConfigParser
from pathlib import Path
import os
import sys
import tempfile

repo_root = Path(sys.argv[1])
config_path = Path(sys.argv[2]).expanduser()
device = sys.argv[3]

sys.path.insert(0, str(repo_root / "src"))
from noaa_navionics.config import _prepare_config_parent, _read_existing_config, _reject_unsafe_config_path

_prepare_config_parent(config_path)
parser = ConfigParser()
_reject_unsafe_config_path(config_path)
if config_path.exists():
    _read_existing_config(parser, config_path)
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
        os.chmod(tmp_path, 0o600)
        os.fsync(handle.fileno())
    os.replace(tmp_path, config_path)
    try:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(config_path.parent, flags)
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
