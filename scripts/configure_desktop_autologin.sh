#!/usr/bin/env bash
set -euo pipefail
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

autologin_user="${USER}"
autologin_session=""
allow_non_pi=0
dry_run=0

usage() {
  cat >&2 <<'EOF'
Usage: scripts/configure_desktop_autologin.sh [options]

Options:
  --user USER         User to log in automatically; defaults to current user
  --session SESSION   LightDM X11 session name; defaults to an installed
                      session from /usr/share/xsessions
  --dry-run           Print intended changes without writing system files
  --allow-non-pi      Allow running on non-Raspberry Pi architecture

Configures Raspberry Pi OS Desktop/LightDM to boot into a graphical session
and log in the selected user so the NOAA Navionics chartplotter autostart
entry can launch OpenCPN after power-up.
EOF
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
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ verify_promoted_root_file %q %q %q\n' "$source" "$target" "$mode"
    return 0
  fi
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

run() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

install_root_file_atomic() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local target_dir
  local target_name
  local target_tmp
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ install_root_file_atomic %q %q %q\n' "$source" "$target" "$mode"
    return 0
  fi
  validate_lightdm_autologin_path
  target_dir="$(dirname "$target")"
  target_name="$(basename "$target")"
  sudo install -d -m 0755 "$target_dir"
  validate_lightdm_autologin_path
  target_tmp="$(sudo mktemp "${target_dir}/.${target_name}.XXXXXX")"
  if ! sudo install -m "$mode" "$source" "$target_tmp"; then
    sudo rm -f "$target_tmp"
    return 1
  fi
  if ! sync_path "$target_tmp"; then
    sudo rm -f "$target_tmp"
    return 1
  fi
  if ! validate_lightdm_autologin_path; then
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

validate_lightdm_autologin_path() {
  python3 - "$lightdm_dir" "$lightdm_conf_dir" "$autologin_conf" "$dry_run" <<'PY'
from pathlib import Path
import os
import sys

lightdm_dir = Path(sys.argv[1])
conf_dir = Path(sys.argv[2])
target = Path(sys.argv[3])
dry_run = sys.argv[4] == "1"

def first_symlink_ancestor(path: Path):
    current = Path(path).expanduser()
    for component in [current, *current.parents]:
        if component.is_symlink():
            return component
    return None

def check_directory(path: Path, label: str, *, required: bool) -> None:
    if path.is_symlink():
        raise SystemExit(f"{label} is a symlink: {path}")
    symlink_component = first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        raise SystemExit(f"{label} path contains a symlink: {symlink_component}")
    if not path.exists():
        if required:
            raise SystemExit(f"{label} does not exist: {path}")
        return
    if not path.is_dir():
        raise SystemExit(f"{label} is not a directory: {path}")
    stat_result = path.stat()
    mode = stat_result.st_mode & 0o777
    if not dry_run and stat_result.st_uid != 0:
        raise SystemExit(f"{label} {path} is owned by uid {stat_result.st_uid}, expected root")
    if mode & 0o022:
        raise SystemExit(f"{label} {path} has permissions {mode:04o}, expected no group/other write bits")

check_directory(lightdm_dir, "LightDM config directory", required=not dry_run)
check_directory(conf_dir, "LightDM autologin directory", required=False)
if target.is_symlink():
    raise SystemExit(f"LightDM autologin config is a symlink: {target}")
target_symlink_component = first_symlink_ancestor(target.parent)
if target_symlink_component is not None:
    raise SystemExit(f"LightDM autologin config path contains a symlink: {target_symlink_component}")
if target.exists():
    if not target.is_file():
        raise SystemExit(f"LightDM autologin config is not a regular file: {target}")
    stat_result = target.stat()
    mode = stat_result.st_mode & 0o777
    if not dry_run and stat_result.st_uid != 0:
        raise SystemExit(f"LightDM autologin config {target} is owned by uid {stat_result.st_uid}, expected root")
    if mode & 0o022:
        raise SystemExit(
            f"LightDM autologin config {target} has permissions {mode:04o}, "
            "expected no group/other write bits"
        )
PY
}

session_is_safe() {
  [[ "$1" =~ ^[A-Za-z0-9._+-]+$ ]]
}

installed_xsession() {
  local session="$1"
  [[ -f "/usr/share/xsessions/${session}.desktop" ]]
}

choose_xsession() {
  local session_file
  local session_name
  local preferred
  if [[ -n "$autologin_session" ]]; then
    if ! session_is_safe "$autologin_session"; then
      echo "Autologin session is not a safe LightDM session name: $autologin_session" >&2
      exit 2
    fi
    if [[ "$dry_run" -eq 0 ]] && ! installed_xsession "$autologin_session"; then
      echo "Autologin session is not installed under /usr/share/xsessions: $autologin_session" >&2
      exit 2
    fi
    return 0
  fi

  for preferred in LXDE-pi LXDE-pi-x openbox xfce; do
    if installed_xsession "$preferred"; then
      autologin_session="$preferred"
      return 0
    fi
  done

  if [[ -d /usr/share/xsessions ]]; then
    for session_file in /usr/share/xsessions/*.desktop; do
      [[ -e "$session_file" ]] || continue
      session_name="$(basename "$session_file" .desktop)"
      if session_is_safe "$session_name"; then
        autologin_session="$session_name"
        return 0
      fi
    done
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    autologin_session="LXDE-pi"
    return 0
  fi

  cat >&2 <<'EOF'
No LightDM X11 sessions are installed under /usr/share/xsessions.
Install Raspberry Pi OS with Desktop/X11 support before relying on chartplotter autostart and display power controls.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      autologin_user="${2:-}"
      shift 2
      ;;
    --session)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      autologin_session="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
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

if [[ ! "$autologin_user" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
  echo "Autologin user is not a safe local username: $autologin_user" >&2
  exit 2
fi

if [[ "$autologin_user" == "root" ]]; then
  echo "Refusing to configure graphical autologin for root." >&2
  exit 2
fi

if [[ "$dry_run" -eq 0 && "$(id -u)" -eq 0 ]]; then
  cat >&2 <<'EOF'
Do not configure desktop autologin as root.
Run this as the Pi desktop user; the script uses sudo only for LightDM and systemd changes.
EOF
  exit 2
fi

arch="$(uname -m)"
if [[ "$allow_non_pi" -eq 0 && "$arch" != armv7l && "$arch" != aarch64 ]]; then
  cat >&2 <<EOF
Refusing to configure desktop autologin on architecture '$arch'.
Run this on the Raspberry Pi, or pass --allow-non-pi for development-only testing.
EOF
  exit 2
fi

if [[ "$dry_run" -eq 0 ]] && ! id "$autologin_user" >/dev/null 2>&1; then
  echo "Autologin user does not exist: $autologin_user" >&2
  exit 2
fi

if [[ "$dry_run" -eq 0 ]]; then
  if ! python3 - "$autologin_user" <<'PY'
from pathlib import Path
import pwd
import sys

username = sys.argv[1]
try:
    entry = pwd.getpwnam(username)
except KeyError as exc:
    raise SystemExit(f"Autologin user does not exist: {username}") from exc
home = Path(entry.pw_dir)
if not home.is_absolute():
    raise SystemExit(f"Autologin user home is not absolute: {home}")
if not home.exists():
    raise SystemExit(f"Autologin user home does not exist: {home}")
if not home.is_dir():
    raise SystemExit(f"Autologin user home is not a directory: {home}")
if home.stat().st_uid != entry.pw_uid:
    raise SystemExit(f"Autologin user does not own home directory: {home}")
PY
  then
    exit 2
  fi
fi

lightdm_dir="${NOAA_NAVIONICS_LIGHTDM_DIR:-/etc/lightdm}"
lightdm_conf_dir="${lightdm_dir}/lightdm.conf.d"
autologin_conf="${lightdm_conf_dir}/50-noaa-navionics-autologin.conf"

if [[ "$dry_run" -eq 0 && ! -d "$lightdm_dir" ]]; then
  cat >&2 <<EOF
LightDM is not installed at $lightdm_dir.
Use Raspberry Pi OS with Desktop, or install and configure a display manager before relying on chartplotter autostart.
EOF
  exit 2
fi

validate_lightdm_autologin_path
choose_xsession

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat >"$tmp" <<EOF
[Seat:*]
autologin-user=${autologin_user}
autologin-user-timeout=0
autologin-session=${autologin_session}
EOF

if [[ "$dry_run" -eq 1 ]]; then
  echo "Would write $autologin_conf:"
  cat "$tmp"
  echo
fi

install_root_file_atomic "$tmp" "$autologin_conf" 0644
run sudo systemctl set-default graphical.target
run sudo systemctl enable lightdm.service

echo "Configured graphical autologin for $autologin_user using X11 session $autologin_session"
