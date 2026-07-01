#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/check_pi_status.sh user@raspberrypi.local [options]

Runs a read-only NOAA Navionics status-report on an already commissioned
Raspberry Pi over SSH. This is a lightweight status snapshot for maintenance
or underway checks; it does not replace verify_pi.sh or dock_test_pi.sh.

Options:
  --gps-seconds N   Override the commissioned GPS fix wait from launcher.env
  --json            Print the raw JSON status report

Nothing is installed, enabled, rebooted, shut down, downloaded, or written on
the local computer or the Raspberry Pi.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

target="$1"
shift
gps_seconds=""
json=0
ssh_cmd=""
ssh_batch_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gps-seconds)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_integer "$1" "${2:-}"
      gps_seconds="${2:-}"
      shift 2
      ;;
    --json)
      json=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

validate_ssh_target() {
  local value="$1"
  local user_part
  local host_part

  if [[ -z "$value" ]]; then
    echo "SSH target is required" >&2
    exit 2
  fi
  if [[ "$value" == -* ]]; then
    echo "SSH target must not begin with '-': $value" >&2
    exit 2
  fi
  if [[ "$value" =~ [[:space:]\"\'] ]]; then
    echo "SSH target must not contain whitespace or quotes: $value" >&2
    exit 2
  fi
  if [[ "$value" != *@* ]]; then
    echo "SSH target must be user@host: $value" >&2
    exit 2
  fi
  user_part="${value%@*}"
  host_part="${value#*@}"
  if [[ -z "$user_part" || -z "$host_part" ]]; then
    echo "SSH target must be user@host: $value" >&2
    exit 2
  fi
  if [[ ! "$user_part" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]; then
    echo "SSH target user contains unsafe characters: $user_part" >&2
    exit 2
  fi
  if [[ "$host_part" == *:* || "$host_part" == */* ]]; then
    echo "SSH target must be plain user@host without paths or ports: $value" >&2
    exit 2
  fi
  if [[ ! "$host_part" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    echo "SSH target host contains unsafe characters: $host_part" >&2
    exit 2
  fi
  if [[ "$user_part" == "root" ]]; then
    cat >&2 <<'EOF'
Do not check NOAA Navionics status as root@.
Use the Pi desktop user so the same config, services, tracks, and OpenCPN data are inspected.
EOF
    exit 2
  fi
}

local_path_in_trusted_system_dir() {
  case "$1" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*)
      return 0
      ;;
  esac
  return 1
}

check_local_owner_and_mode() {
  local item_kind="$1"
  local item_path="$2"
  local stat_output
  local owner_uid
  local mode
  local mode_tail

  if ! stat_output="$(stat -Lc '%u %a' -- "$item_path" 2>/dev/null)"; then
    echo "Could not inspect local command ${item_kind}: $item_path" >&2
    exit 2
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"

  if [[ "$owner_uid" != "0" ]]; then
    echo "Local command ${item_kind} is owned by uid ${owner_uid}, expected 0: ${item_path}" >&2
    exit 2
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      echo "Local command ${item_kind} has permissions ${mode}, expected no group/other write: ${item_path}" >&2
      exit 2
      ;;
  esac
}

check_local_directory_chain() {
  local directory
  directory="$(dirname -- "$1")"
  while :; do
    check_local_owner_and_mode directory "$directory"
    [[ "$directory" == "/" ]] && break
    directory="$(dirname -- "$directory")"
  done
}

validate_trusted_local_command() {
  local command_name="$1"
  local command_path="$2"
  local resolved_path

  if [[ "${NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS:-0}" == "1" || ( "$command_name" == "ssh" && "${NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH:-0}" == "1" ) ]]; then
    return 0
  fi
  if ! local_path_in_trusted_system_dir "$command_path"; then
    echo "Local ${command_name} command is not in a trusted system directory: $command_path" >&2
    exit 2
  fi
  if [[ ! -x "$command_path" ]]; then
    echo "Local ${command_name} command is not executable: $command_path" >&2
    exit 2
  fi
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    echo "Could not resolve local ${command_name} command: $command_path" >&2
    exit 2
  fi
  if ! local_path_in_trusted_system_dir "$resolved_path"; then
    echo "Resolved local ${command_name} command is not in a trusted system directory: $resolved_path" >&2
    exit 2
  fi
  if [[ ! -x "$resolved_path" ]]; then
    echo "Local ${command_name} command is not executable after resolution: $resolved_path" >&2
    exit 2
  fi
  check_local_owner_and_mode "$command_name" "$resolved_path"
  check_local_directory_chain "$resolved_path"
}

require_local_command() {
  local command_name="$1"
  local command_path
  if ! command_path="$(command -v "$command_name" 2>/dev/null)" || [[ -z "$command_path" ]]; then
    echo "Missing required local command: $command_name" >&2
    exit 2
  fi
  validate_trusted_local_command "$command_name" "$command_path"
  printf '%s\n' "$command_path"
}

validate_ssh_target "$target"
ssh_cmd="$(require_local_command ssh)"
gps_seconds_quoted="$(printf '%q' "$gps_seconds")"
json_quoted="$(printf '%q' "$json")"

"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" \
  "${remote_system_path} && export PATH && NOAA_NAVIONICS_STATUS_GPS_SECONDS=${gps_seconds_quoted} NOAA_NAVIONICS_STATUS_JSON=${json_quoted} /bin/bash -s" <<'REMOTE'
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

command_path="${HOME}/.local/bin/noaa-navionics"
expected_resolved="${HOME}/.local/share/noaa-navionics/venv/bin/noaa-navionics"
config_path="${HOME}/.config/noaa-navionics/config.ini"
launcher_env_path="${HOME}/.config/noaa-navionics/launcher.env"
python3_cmd=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

remote_path_in_trusted_system_dir() {
  case "$1" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*)
      return 0
      ;;
  esac
  return 1
}

check_remote_owner_and_mode() {
  local item_kind="$1"
  local item_path="$2"
  local mode
  local mode_tail
  local owner_uid
  local stat_output

  if ! stat_output="$(stat -Lc '%u %a' -- "$item_path" 2>/dev/null)"; then
    fail "could not inspect remote command ${item_kind}: $item_path"
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"

  if [[ "$owner_uid" != "0" ]]; then
    fail "remote ${item_kind} command is owned by uid ${owner_uid}, expected 0: ${item_path}"
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      fail "remote ${item_kind} command has permissions ${mode}, expected no group/other write: ${item_path}"
      ;;
  esac
}

check_remote_directory_chain() {
  local directory
  directory="$(dirname -- "$1")"
  while :; do
    check_remote_owner_and_mode directory "$directory"
    [[ "$directory" == "/" ]] && break
    directory="$(dirname -- "$directory")"
  done
}

require_remote_command() {
  local command_name="$1"
  local command_path
  local resolved_path

  if ! command_path="$(command -v "$command_name" 2>/dev/null)" || [[ -z "$command_path" ]]; then
    fail "missing required remote command: $command_name"
  fi
  if ! remote_path_in_trusted_system_dir "$command_path"; then
    fail "remote ${command_name} command is not in a trusted system directory: $command_path"
  fi
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    fail "could not resolve remote ${command_name} command: $command_path"
  fi
  if ! remote_path_in_trusted_system_dir "$resolved_path"; then
    fail "resolved remote ${command_name} command is not in a trusted system directory: $resolved_path"
  fi
  if [[ ! -x "$resolved_path" ]]; then
    fail "remote ${command_name} command is not executable after resolution: $resolved_path"
  fi
  check_remote_directory_chain "$resolved_path"
  check_remote_owner_and_mode "$command_name" "$resolved_path"
  printf '%s\n' "$resolved_path"
}

reject_symlinked_path_components() {
  local label="$1"
  local path="$2"
  local current="$path"

  if [[ "$path" != /* ]]; then
    fail "$label path must be absolute: $path"
  fi
  while [[ "$current" != "/" ]]; do
    if [[ -L "$current" ]]; then
      fail "$label path contains a symlink: $current"
    fi
    current="$(dirname -- "$current")"
  done
}

reject_symlinked_parent_components() {
  local label="$1"
  local path="$2"

  if [[ "$path" != /* ]]; then
    fail "$label path must be absolute: $path"
  fi
  reject_symlinked_path_components "$label parent" "$(dirname -- "$path")"
}

check_user_owned_nonwritable_directory() {
  local label="$1"
  local path="$2"
  local current_uid
  local mode
  local mode_tail
  local owner_uid
  local stat_output

  reject_symlinked_path_components "$label" "$path"
  if [[ -L "$path" ]]; then
    fail "$label is a symlink: $path"
  fi
  if [[ ! -d "$path" ]]; then
    fail "$label is missing or not a directory: $path"
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    fail "could not inspect $label: $path"
  fi
  current_uid="$(id -u)"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    fail "$label is owned by uid $owner_uid, expected $current_uid: $path"
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      fail "$label has permissions $mode, expected no group/other write: $path"
      ;;
  esac
}

check_user_owned_private_file() {
  local label="$1"
  local path="$2"
  local current_uid
  local mode
  local mode_tail
  local owner_uid
  local stat_output

  reject_symlinked_path_components "$label" "$path"
  if [[ -L "$path" ]]; then
    fail "$label must not be a symlink: $path"
  fi
  if [[ ! -f "$path" ]]; then
    fail "$label is missing or not a regular file: $path"
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    fail "could not inspect $label: $path"
  fi
  current_uid="$(id -u)"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    fail "$label is owned by uid $owner_uid, expected $current_uid: $path"
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      fail "$label has permissions $mode, expected no group/other write: $path"
      ;;
  esac
}

check_installed_command_tree() {
  check_user_owned_nonwritable_directory "home directory" "$HOME"
  check_user_owned_nonwritable_directory "installed command directory" "${HOME}/.local"
  check_user_owned_nonwritable_directory "installed command directory" "${HOME}/.local/bin"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics/venv"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics/venv/bin"
}

check_installed_noaa_command() {
  local current_uid
  local mode
  local mode_tail
  local owner_uid
  local resolved_path
  local stat_output

  check_installed_command_tree
  reject_symlinked_parent_components "installed noaa-navionics command" "$command_path"
  if [[ ! -L "$command_path" ]]; then
    fail "installed noaa-navionics command is not the expected private venv symlink: $command_path"
  fi
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    fail "could not resolve installed noaa-navionics command: $command_path"
  fi
  if [[ "$resolved_path" != "$expected_resolved" ]]; then
    fail "installed noaa-navionics command resolves to $resolved_path, expected $expected_resolved"
  fi
  if [[ ! -f "$resolved_path" ]]; then
    fail "installed noaa-navionics command target is not a regular file: $resolved_path"
  fi
  if [[ ! -x "$resolved_path" ]]; then
    fail "installed noaa-navionics command is not executable after resolution: $resolved_path"
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$resolved_path" 2>/dev/null)"; then
    fail "could not inspect installed noaa-navionics command target: $resolved_path"
  fi
  current_uid="$(id -u)"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    fail "installed noaa-navionics command target is owned by uid $owner_uid, expected $current_uid: $resolved_path"
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      fail "installed noaa-navionics command target has permissions $mode, expected no group/other write: $resolved_path"
      ;;
  esac
  "$python3_cmd" - "$resolved_path" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
nofollow = getattr(os, "O_NOFOLLOW", 0)
try:
    before = os.stat(path, follow_symlinks=False)
except OSError as exc:
    print(f"could not inspect installed noaa-navionics command target through no-follow stat: {path}: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
if not stat.S_ISREG(before.st_mode):
    print(f"installed noaa-navionics command target is not a regular non-symlink file: {path}", file=sys.stderr)
    raise SystemExit(1)
if before.st_uid != os.getuid():
    print(
        f"installed noaa-navionics command target is owned by uid {before.st_uid}, expected current user {os.getuid()}: {path}",
        file=sys.stderr,
    )
    raise SystemExit(1)
mode = stat.S_IMODE(before.st_mode)
if mode & 0o022:
    print(f"installed noaa-navionics command target has permissions {mode:03o}, expected no group/other write: {path}", file=sys.stderr)
    raise SystemExit(1)
if not mode & 0o111:
    print(f"installed noaa-navionics command target is not executable: {path}", file=sys.stderr)
    raise SystemExit(1)
try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except OSError as exc:
    print(f"could not open installed noaa-navionics command through no-follow descriptor: {path}: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        print(f"installed noaa-navionics command changed before it could be validated: {path}", file=sys.stderr)
        raise SystemExit(1)
    if not stat.S_ISREG(opened.st_mode):
        print(f"opened installed noaa-navionics command is not regular: {path}", file=sys.stderr)
        raise SystemExit(1)
finally:
    os.close(fd)
PY
  printf '%s\n' "$resolved_path"
}

run_noaa_navionics() {
  local app_exec
  app_exec="$(check_installed_noaa_command)"
  "$app_exec" "$@"
}

python3_cmd="$(require_remote_command python3)"
check_user_owned_private_file "onboard NOAA Navionics config" "$config_path"

status_args=(
  status-report
  --config "$config_path"
)
if [[ -n "$NOAA_NAVIONICS_STATUS_GPS_SECONDS" ]]; then
  status_args+=(--gps-seconds "$NOAA_NAVIONICS_STATUS_GPS_SECONDS")
else
  status_args+=(--gps-seconds-from-launcher-env "$launcher_env_path")
fi
if [[ "$NOAA_NAVIONICS_STATUS_JSON" == "1" ]]; then
  status_args+=(--json)
fi

run_noaa_navionics "${status_args[@]}"
REMOTE
