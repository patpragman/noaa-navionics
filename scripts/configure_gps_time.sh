#!/usr/bin/env bash
set -euo pipefail
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

allow_non_pi=0
dry_run=0
chrony_conf="/etc/chrony/chrony.conf"
restart_gpsd=1
systemctl_cmd=""

usage() {
  cat >&2 <<'EOF'
Usage: scripts/configure_gps_time.sh [options]

Options:
  --chrony-conf PATH  Chrony config path
  --dry-run           Print intended changes without writing system files
  --no-gpsd-restart   Do not restart GPSD after restarting chrony
  --allow-non-pi      Allow running on non-Raspberry Pi architecture

Configures chrony to use GPSD's message-based SHM 0 time source.
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

sync_path() {
  local path="$1"
  sudo python3 - "$path" <<'PY'
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
  sudo python3 - "$source" "$target" "$mode" <<'PY'
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
  validate_chrony_config_path
  target_dir="$(dirname "$target")"
  target_name="$(basename "$target")"
  sudo install -d -m 0755 "$target_dir"
  validate_chrony_config_path
  target_tmp="$(sudo mktemp "${target_dir}/.${target_name}.XXXXXX")"
  if ! sudo install -m "$mode" "$source" "$target_tmp"; then
    sudo rm -f "$target_tmp"
    return 1
  fi
  if ! sync_path "$target_tmp"; then
    sudo rm -f "$target_tmp"
    return 1
  fi
  if ! validate_chrony_config_path; then
    sudo rm -f "$target_tmp"
    return 1
  fi
  if ! sudo mv -f "$target_tmp" "$target"; then
    sudo rm -f "$target_tmp"
    return 1
  fi
  verify_promoted_root_file "$source" "$target" "$mode"
  sync_path "$target"
}

validate_chrony_config_path() {
  python3 - "$chrony_conf" "$dry_run" <<'PY'
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
    raise SystemExit(f"Chrony config is a symlink: {path}")
if path.exists() and not path.is_file():
    raise SystemExit(f"Chrony config is not a regular file: {path}")
if parent.is_symlink():
    raise SystemExit(f"Chrony config directory is a symlink: {parent}")
symlink_component = first_symlink_ancestor(parent)
if symlink_component is not None:
    raise SystemExit(f"Chrony config directory is a symlink: {symlink_component}")
if parent.exists():
    if not parent.is_dir():
        raise SystemExit(f"Chrony config parent is not a directory: {parent}")
    parent_stat = parent.stat()
    parent_mode = parent_stat.st_mode & 0o777
    if parent_mode & 0o022:
        raise SystemExit(
            f"Chrony config directory {parent} has permissions {parent_mode:04o}, "
            "expected no group/other write bits"
        )
    if not dry_run and parent_stat.st_uid != 0:
        raise SystemExit(f"Chrony config directory {parent} is owned by uid {parent_stat.st_uid}, expected root")
if not dry_run and path.exists():
    path_stat = path.stat()
    path_mode = path_stat.st_mode & 0o777
    if path_stat.st_uid != 0:
        raise SystemExit(f"Chrony config {path} is owned by uid {path_stat.st_uid}, expected root")
    if path_mode & 0o022:
        raise SystemExit(
            f"Chrony config {path} has permissions {path_mode:04o}, expected no group/other write bits"
        )
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chrony-conf)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      chrony_conf="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --no-gpsd-restart)
      restart_gpsd=0
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

if [[ "$dry_run" -eq 0 && "$(id -u)" -eq 0 ]]; then
  cat >&2 <<'EOF'
Do not configure GPS time as root.
Run this as the Pi desktop user; the script uses sudo only for system chrony changes.
EOF
  exit 2
fi

case "$chrony_conf" in
  /*)
    ;;
  *)
    echo "Chrony config path must be absolute: $chrony_conf" >&2
    exit 2
    ;;
esac

if [[ "$chrony_conf" =~ [[:space:]\"\'] ]]; then
  echo "Chrony config path must not contain whitespace or quotes: $chrony_conf" >&2
  exit 2
fi

if [[ "$dry_run" -eq 0 && "$chrony_conf" != "/etc/chrony/chrony.conf" ]]; then
  cat >&2 <<EOF
Refusing to write a non-standard chrony config path: $chrony_conf
Use /etc/chrony/chrony.conf for production, or --dry-run for custom-path inspection.
EOF
  exit 2
fi

arch="$(uname -m)"
if [[ "$allow_non_pi" -eq 0 && "$arch" != armv7l && "$arch" != aarch64 ]]; then
  cat >&2 <<EOF
Refusing to configure GPS time on architecture '$arch'.
Run this on the Raspberry Pi, or pass --allow-non-pi for development-only testing.
EOF
  exit 2
fi

validate_chrony_config_path

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

python3 - "$chrony_conf" "$tmp" "$dry_run" <<'PY'
from pathlib import Path
import os
import stat
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
dry_run = sys.argv[3] == "1"
begin = "# BEGIN NOAA Navionics GPS time"
end = "# END NOAA Navionics GPS time"
block = """# BEGIN NOAA Navionics GPS time
# GPSD publishes message-based GPS time on SHM 0. This is sufficient for
# chart-age checks and GPX timestamps; add PPS hardware for sub-second timing.
refclock SHM 0 offset 0.5 delay 0.1 refid GPS
makestep 1.0 3
# END NOAA Navionics GPS time
"""

def read_existing_chrony_config(path: Path) -> str:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, os.O_RDONLY | nofollow)
    except FileNotFoundError:
        return ""
    except OSError as exc:
        raise SystemExit(f"could not open chrony config {path}: {exc}") from exc

    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise SystemExit(f"chrony config is not a regular file when opened: {path}")
        mode = opened.st_mode & 0o777
        if mode & 0o022:
            raise SystemExit(
                f"chrony config {path} has permissions {mode:04o}, expected no group/other write bits"
            )
        expected_uids = {0}
        if dry_run:
            expected_uids.add(os.getuid())
        if opened.st_uid not in expected_uids:
            expected = "root or current user" if dry_run else "root"
            raise SystemExit(f"chrony config {path} is owned by uid {opened.st_uid}, expected {expected}")
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            return handle.read()
    finally:
        if fd >= 0:
            os.close(fd)


text = read_existing_chrony_config(source)

lines = text.splitlines(keepends=True)
filtered: list[str] = []
skipping = False
for line in lines:
    stripped = line.strip()
    if stripped == begin:
        if skipping:
            raise SystemExit(f"nested NOAA Navionics GPS time block in {source}")
        skipping = True
        continue
    if stripped == end and skipping:
        skipping = False
        continue
    if stripped == end:
        raise SystemExit(f"found NOAA Navionics GPS time END marker without BEGIN in {source}")
    if not skipping:
        filtered.append(line)
if skipping:
    raise SystemExit(f"unterminated NOAA Navionics GPS time block in {source}")

if filtered and filtered[-1].strip():
    filtered.append("\n")
filtered.append(block)
target.write_text("".join(filtered), encoding="utf-8")
PY

if [[ "$dry_run" -eq 1 ]]; then
  echo "Would update $chrony_conf with NOAA Navionics GPS time block:"
  sed -n '/BEGIN NOAA Navionics GPS time/,$p' "$tmp"
  if [[ "$restart_gpsd" -eq 1 ]]; then
    echo "Would restart chrony and GPSD so GPSD attaches to chrony after restart."
  else
    echo "Would restart chrony."
  fi
  exit 0
fi

if ! command -v chronyd >/dev/null 2>&1 && ! command -v chronyc >/dev/null 2>&1; then
  echo "chrony is not installed; run scripts/install_raspberry_pi.sh first" >&2
  exit 2
fi

systemctl_cmd="$(systemctl_command)" || exit 2

sudo mkdir -p "$(dirname "$chrony_conf")"
if [[ -e "$chrony_conf" ]]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${chrony_conf}.noaa-navionics.${stamp}.bak"
  backup_root_file_private "$chrony_conf" "$backup"
fi

install_root_file_atomic "$tmp" "$chrony_conf" 0644
sudo "$systemctl_cmd" enable --now chrony
sudo "$systemctl_cmd" restart chrony
if [[ "$restart_gpsd" -eq 1 ]]; then
  sudo "$systemctl_cmd" restart gpsd.socket gpsd.service
fi

cat <<EOF
Configured chrony GPS time source.

Chrony config: $chrony_conf
Then verify: timedatectl show -p SystemClockSynchronized
EOF
