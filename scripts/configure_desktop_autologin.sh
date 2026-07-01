#!/usr/bin/env bash
set -euo pipefail
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

autologin_user="${USER}"
autologin_session=""
allow_non_pi=0
dry_run=0
systemctl_cmd=""
sudo_cmd=""
python3_cmd=""

cleanup_private_local_temp_file() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  "$python3_cmd" - "$path" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
nofollow = getattr(os, "O_NOFOLLOW", 0)

try:
    before = os.stat(path, follow_symlinks=False)
except FileNotFoundError:
    raise SystemExit(0)
except OSError as exc:
    print(f"could not inspect generated config temp for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600:
    print(f"generated config temp is not a trusted private file; leaving it in place: {path}", file=sys.stderr)
    raise SystemExit(0)

try:
    dir_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
except OSError as exc:
    print(f"could not open generated config temp directory for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)
try:
    try:
        fd = os.open(path.name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
    except FileNotFoundError:
        raise SystemExit(0)
    try:
        opened = os.fstat(fd)
    finally:
        os.close(fd)
    if not os.path.samestat(before, opened):
        print(f"generated config temp changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    os.unlink(path.name, dir_fd=dir_fd)
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
}

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
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ verify_promoted_root_file %q %q %q\n' "$source" "$target" "$mode"
    return 0
  fi
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

cleanup_root_temp_file() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  "$sudo_cmd" "$python3_cmd" - "$path" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
nofollow = getattr(os, "O_NOFOLLOW", 0)

try:
    before = os.stat(path, follow_symlinks=False)
except FileNotFoundError:
    raise SystemExit(0)
except OSError as exc:
    print(f"could not inspect root config temporary file for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

mode = stat.S_IMODE(before.st_mode)
if not stat.S_ISREG(before.st_mode) or before.st_uid != 0 or mode & 0o022:
    print(f"root config temporary file is not a trusted root-owned file; leaving it in place: {path}", file=sys.stderr)
    raise SystemExit(0)

try:
    dir_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
except OSError as exc:
    print(f"could not open root config temporary file directory for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)
try:
    try:
        fd = os.open(path.name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
    except FileNotFoundError:
        raise SystemExit(0)
    try:
        opened = os.fstat(fd)
    finally:
        os.close(fd)
    if not os.path.samestat(before, opened):
        print(f"root config temporary file changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    os.unlink(path.name, dir_fd=dir_fd)
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
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
  "$sudo_cmd" install -d -m 0755 "$target_dir"
  validate_lightdm_autologin_path
  target_tmp="$("$sudo_cmd" mktemp "${target_dir}/.${target_name}.XXXXXX")"
  if ! verify_root_temp_file "$target_tmp" 0600; then
    cleanup_root_temp_file "$target_tmp"
    return 1
  fi
  if ! "$sudo_cmd" install -m "$mode" "$source" "$target_tmp"; then
    cleanup_root_temp_file "$target_tmp"
    return 1
  fi
  if ! verify_root_temp_file "$target_tmp" "$mode"; then
    cleanup_root_temp_file "$target_tmp"
    return 1
  fi
  if ! sync_path "$target_tmp"; then
    cleanup_root_temp_file "$target_tmp"
    return 1
  fi
  if ! validate_lightdm_autologin_path; then
    cleanup_root_temp_file "$target_tmp"
    return 1
  fi
  if ! "$sudo_cmd" mv -f "$target_tmp" "$target"; then
    cleanup_root_temp_file "$target_tmp"
    return 1
  fi
  verify_promoted_root_file "$source" "$target" "$mode"
  sync_path "$target"
}

validate_lightdm_autologin_path() {
  "$python3_cmd" - "$lightdm_dir" "$lightdm_conf_dir" "$autologin_conf" "$dry_run" <<'PY'
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

python3_cmd="$(python3_command)" || exit 2

if [[ "$dry_run" -eq 0 ]] && ! id "$autologin_user" >/dev/null 2>&1; then
  echo "Autologin user does not exist: $autologin_user" >&2
  exit 2
fi

if [[ "$dry_run" -eq 0 ]]; then
  if ! "$python3_cmd" - "$autologin_user" <<'PY'
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
cleanup_generated_config_temp() {
  cleanup_private_local_temp_file "${tmp:-}" || true
}
trap cleanup_generated_config_temp EXIT

"$python3_cmd" - "$tmp" "$autologin_user" "$autologin_session" <<'PY'
from pathlib import Path
import os
import stat
import sys

target = Path(sys.argv[1])
autologin_user = sys.argv[2]
autologin_session = sys.argv[3]
nofollow = getattr(os, "O_NOFOLLOW", 0)
fd = os.open(target, os.O_WRONLY | os.O_TRUNC | nofollow)
try:
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        raise SystemExit(f"generated LightDM autologin temp is not a regular file: {target}")
    if opened.st_uid != os.getuid():
        raise SystemExit(
            f"generated LightDM autologin temp {target} is owned by uid {opened.st_uid}, expected {os.getuid()}"
        )
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        raise SystemExit(f"generated LightDM autologin temp {target} has permissions {mode:04o}, expected 0600")
    text = (
        "[Seat:*]\n"
        f"autologin-user={autologin_user}\n"
        "autologin-user-timeout=0\n"
        f"autologin-session={autologin_session}\n"
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
  echo "Would write $autologin_conf:"
  cat "$tmp"
  echo
  sudo_cmd="sudo"
  systemctl_cmd="systemctl"
else
  sudo_cmd="$(sudo_command)" || exit 2
  systemctl_cmd="$(systemctl_command)" || exit 2
fi

install_root_file_atomic "$tmp" "$autologin_conf" 0644
run "$sudo_cmd" "$systemctl_cmd" set-default graphical.target
run "$sudo_cmd" "$systemctl_cmd" enable lightdm.service

echo "Configured graphical autologin for $autologin_user using X11 session $autologin_session"
