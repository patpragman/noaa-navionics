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
systemctl_cmd=""
sudo_cmd=""
python3_cmd=""

utc_timestamp() {
  local stamp
  TZ=UTC0 printf -v stamp '%(%Y%m%dT%H%M%SZ)T' -1
  printf '%s\n' "$stamp"
}

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

path_in_trusted_system_dir() {
  case "$1" in
    /usr/local/sbin/*|/usr/local/bin/*|/usr/sbin/*|/usr/bin/*|/sbin/*|/bin/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_trusted_system_command() {
  local command_name="$1"
  local label="$2"
  local command_path
  local resolved_path
  local stat_output
  local owner_uid
  local mode_text
  local mode
  local parent_dir
  local parent_stat
  local parent_owner_uid
  local parent_mode_text
  local parent_mode

  if ! command_path="$(command -v "$command_name" 2>/dev/null)" || [[ -z "$command_path" ]]; then
    echo "${label} was not found on PATH" >&2
    return 1
  fi
  case "$command_path" in
    /*)
      ;;
    *)
      echo "${label} path is not absolute: $command_path" >&2
      return 1
      ;;
  esac
  if ! path_in_trusted_system_dir "$command_path"; then
    echo "${label} is not in a trusted system directory: $command_path" >&2
    return 1
  fi
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    echo "Could not resolve ${label}: $command_path" >&2
    return 1
  fi
  if ! path_in_trusted_system_dir "$resolved_path"; then
    echo "${label} resolves outside trusted system directories: $command_path -> $resolved_path" >&2
    return 1
  fi
  if [[ ! -f "$resolved_path" ]]; then
    echo "${label} is not a regular file after resolution: $command_path -> $resolved_path" >&2
    return 1
  fi
  if [[ ! -x "$resolved_path" ]]; then
    echo "${label} is not executable: $resolved_path" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$resolved_path" 2>/dev/null)" || {
    echo "Could not inspect ${label}: $resolved_path" >&2
    return 1
  }
  owner_uid="${stat_output%% *}"
  mode_text="${stat_output#* }"
  if [[ "$owner_uid" != "0" ]]; then
    echo "${label} is owned by uid ${owner_uid}, expected root: $resolved_path" >&2
    return 1
  fi
  mode=$((8#$mode_text))
  if (( mode & 022 )); then
    echo "${label} has permissions ${mode_text}, expected no group/other write bits: $resolved_path" >&2
    return 1
  fi
  parent_dir="$(dirname "$resolved_path")"
  parent_stat="$(stat -c '%u %a' "$parent_dir" 2>/dev/null)" || {
    echo "Could not inspect ${label} directory: $parent_dir" >&2
    return 1
  }
  parent_owner_uid="${parent_stat%% *}"
  parent_mode_text="${parent_stat#* }"
  if [[ "$parent_owner_uid" != "0" ]]; then
    echo "${label} directory is owned by uid ${parent_owner_uid}, expected root: $parent_dir" >&2
    return 1
  fi
  parent_mode=$((8#$parent_mode_text))
  if (( parent_mode & 022 )); then
    echo "${label} directory has permissions ${parent_mode_text}, expected no group/other write bits: $parent_dir" >&2
    return 1
  fi
  printf '%s\n' "$resolved_path"
}

systemctl_command() {
  if [[ -z "$systemctl_cmd" ]]; then
    systemctl_cmd="$(require_trusted_system_command systemctl "Systemctl command")" || return 1
  fi
  printf '%s\n' "$systemctl_cmd"
}

sudo_command() {
  if [[ -z "$sudo_cmd" ]]; then
    sudo_cmd="$(require_trusted_system_command sudo "Sudo command")" || return 1
  fi
  printf '%s\n' "$sudo_cmd"
}

python3_command() {
  if [[ -z "$python3_cmd" ]]; then
    python3_cmd="$(require_trusted_system_command python3 "Python command")" || return 1
  fi
  printf '%s\n' "$python3_cmd"
}

sync_path() {
  local path="$1"
  "$sudo_cmd" "$python3_cmd" - "$path" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
nofollow = getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except OSError as exc:
    if path.is_symlink():
        raise SystemExit(f"root file sync target is a symlink: {path}") from exc
    raise SystemExit(f"could not open root file sync target {path}: {exc}") from exc
try:
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        raise SystemExit(f"root file sync target is not a regular file: {path}")
    os.fsync(fd)
finally:
    os.close(fd)
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

verify_promoted_root_file() {
  local source="$1"
  local target="$2"
  local mode="$3"
  "$sudo_cmd" "$python3_cmd" - "$source" "$target" "$mode" <<'PY'
from pathlib import Path
import os
import stat
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
expected_mode = int(sys.argv[3], 8)
nofollow = getattr(os, "O_NOFOLLOW", 0)

def read_regular(path: Path, label: str, *, expected_uid=None, expected_mode=None) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | nofollow)
    except OSError as exc:
        if path.is_symlink():
            raise SystemExit(f"{label} is a symlink: {path}") from exc
        raise SystemExit(f"could not open {label}: {path}: {exc}") from exc
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise SystemExit(f"{label} is not a regular file: {path}")
        mode = opened.st_mode & 0o777
        if expected_uid is not None and opened.st_uid != expected_uid:
            raise SystemExit(f"{label} is owned by uid {opened.st_uid}, expected {expected_uid}: {path}")
        if expected_mode is not None and mode != expected_mode:
            raise SystemExit(f"{label} has permissions {mode:04o}, expected {expected_mode:04o}: {path}")
        chunks = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)

source_bytes = read_regular(source, "root config source")
target_bytes = read_regular(target, "promoted root config", expected_uid=0, expected_mode=expected_mode)
if target_bytes != source_bytes:
    raise SystemExit(f"promoted root config does not match source: {target}")
PY
}

verify_root_temp_file() {
  local path="$1"
  local mode="$2"
  "$sudo_cmd" "$python3_cmd" - "$path" "$mode" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
expected_mode = int(sys.argv[2], 8)
nofollow = getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except OSError as exc:
    if path.is_symlink():
        raise SystemExit(f"root config temporary file is a symlink: {path}") from exc
    raise SystemExit(f"could not open root config temporary file: {path}: {exc}") from exc
try:
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        raise SystemExit(f"root config temporary file is not a regular file: {path}")
    if opened.st_uid != 0:
        raise SystemExit(f"root config temporary file {path} is owned by uid {opened.st_uid}, expected root")
    mode = opened.st_mode & 0o777
    if mode != expected_mode:
        raise SystemExit(
            f"root config temporary file {path} has permissions {mode:04o}, expected {expected_mode:04o}"
        )
finally:
    os.close(fd)
PY
}

backup_root_file_private() {
  local source="$1"
  local backup="$2"
  "$sudo_cmd" "$python3_cmd" - "$source" "$backup" <<'PY'
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
  validate_gpsd_config_path
  target_dir="$(dirname "$target")"
  target_name="$(basename "$target")"
  "$sudo_cmd" install -d -m 0755 "$target_dir"
  validate_gpsd_config_path
  target_tmp="$("$sudo_cmd" mktemp "${target_dir}/.${target_name}.XXXXXX")"
  if ! verify_root_temp_file "$target_tmp" 0600; then
    "$sudo_cmd" rm -f "$target_tmp"
    return 1
  fi
  if ! "$sudo_cmd" install -m "$mode" "$source" "$target_tmp"; then
    "$sudo_cmd" rm -f "$target_tmp"
    return 1
  fi
  if ! verify_root_temp_file "$target_tmp" "$mode"; then
    "$sudo_cmd" rm -f "$target_tmp"
    return 1
  fi
  if ! sync_path "$target_tmp"; then
    "$sudo_cmd" rm -f "$target_tmp"
    return 1
  fi
  if ! validate_gpsd_config_path; then
    "$sudo_cmd" rm -f "$target_tmp"
    return 1
  fi
  if ! "$sudo_cmd" mv -f "$target_tmp" "$target"; then
    "$sudo_cmd" rm -f "$target_tmp"
    return 1
  fi
  verify_promoted_root_file "$source" "$target" "$mode"
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
  "$python3_cmd" - "$repo_root" "$config" "$device" <<'PY'
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
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(config_path.parent), delete=False) as handle:
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
  "$python3_cmd" - "$repo_root" "$config" "$dry_run" <<'PY'
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
  "$python3_cmd" - "$gpsd_conf" "$dry_run" <<'PY'
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
  echo "Run on the Pi first: noaa-navionics list-gps-devices" >&2
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

if [[ "$check_device" -eq 1 && "$device" == /dev/serial/by-id/* && -L "$device" && ! -e "$device" ]]; then
  target="$(readlink -- "$device" 2>/dev/null || true)"
  cat >&2 <<EOF
GPS by-id device path is a broken symlink: $device -> ${target:-<unknown>}
Plug in the receiver, remove the stale link, or run: noaa-navionics list-gps-devices
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

if [[ "$check_device" -eq 1 && "$device" == /dev/serial/by-id/* && ! -L "$device" ]]; then
  echo "GPS by-id device path is not a symlink: $device" >&2
  exit 2
fi

if [[ "$check_device" -eq 1 && ! -c "$device" ]]; then
  echo "GPS device path is not a character device: $device" >&2
  exit 2
fi

python3_cmd="$(python3_command)" || exit 2

prepare_app_config_path
validate_updated_app_config
validate_gpsd_config_path

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

"$python3_cmd" - "$tmp" "$device" <<'PY'
from pathlib import Path
import os
import stat
import sys

target = Path(sys.argv[1])
device = sys.argv[2]
nofollow = getattr(os, "O_NOFOLLOW", 0)
fd = os.open(target, os.O_WRONLY | os.O_TRUNC | nofollow)
try:
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        raise SystemExit(f"generated GPSD config temp is not a regular file: {target}")
    if opened.st_uid != os.getuid():
        raise SystemExit(
            f"generated GPSD config temp {target} is owned by uid {opened.st_uid}, expected {os.getuid()}"
        )
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        raise SystemExit(f"generated GPSD config temp {target} has permissions {mode:04o}, expected 0600")
    text = (
        'START_DAEMON="true"\n'
        'USBAUTO="false"\n'
        f'DEVICES="{device}"\n'
        'GPSD_OPTIONS="-n"\n'
    )
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        fd = -1
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
finally:
    if fd >= 0:
        os.close(fd)
PY

if [[ "$dry_run" -eq 1 ]]; then
  echo "Would write $gpsd_conf:"
  cat "$tmp"
  echo
  echo "Would update $config with gps.mode=gpsd and gps.device=$device"
  exit 0
fi

sudo_cmd="$(sudo_command)" || exit 2
systemctl_cmd="$(systemctl_command)" || exit 2

if [[ -e "$gpsd_conf" ]]; then
  stamp="$(utc_timestamp)"
  backup="${gpsd_conf}.noaa-navionics.${stamp}.bak"
  backup_root_file_private "$gpsd_conf" "$backup"
fi

install_root_file_atomic "$tmp" "$gpsd_conf" 0644
"$sudo_cmd" "$systemctl_cmd" daemon-reload
"$sudo_cmd" "$systemctl_cmd" enable --now gpsd.socket gpsd.service
"$sudo_cmd" "$systemctl_cmd" restart gpsd.socket gpsd.service

"$python3_cmd" - "$repo_root" "$config" "$device" <<'PY'
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
