#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/refresh_pi_charts.sh user@raspberrypi.local [options]

Refreshes the commissioned Raspberry Pi's NOAA chart package over SSH by
running wait-network and sync-charts on the Pi. This downloads NOAA data on
the Raspberry Pi, not on the local computer.

Options:
  --force             Force a redownload even when cached chart files exist
  --retries N         Download attempts on the Pi before failing (1-20; default: 5)
  --retry-delay N     Seconds between retryable failures (0-3600; default: 30)
  --status            Run a read-only status-report after chart sync succeeds
  --gps-seconds N     Override the commissioned GPS fix wait during --status (1-600)

Nothing is installed, enabled, rebooted, shut down, or downloaded on the
local computer.
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
force=0
retries=5
retry_delay=30
status=0
gps_seconds=""
max_retries=20
max_retry_delay=3600
max_gps_seconds=600
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

require_non_negative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a non-negative integer" >&2
    exit 2
  fi
}

integer_greater_than() {
  local value="$1"
  local maximum="$2"
  if (( ${#value} > ${#maximum} )); then
    return 0
  fi
  if (( ${#value} == ${#maximum} )) && [[ "$value" > "$maximum" ]]; then
    return 0
  fi
  return 1
}

require_integer_at_most() {
  local name="$1"
  local value="$2"
  local maximum="$3"
  if integer_greater_than "$value" "$maximum"; then
    echo "$name must be at most ${maximum}" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      force=1
      shift
      ;;
    --retries)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      retries_value="${2:-}"
      require_positive_integer "$1" "$retries_value"
      require_integer_at_most "$1" "$retries_value" "$max_retries"
      retries="$retries_value"
      shift 2
      ;;
    --retry-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      retry_delay_value="${2:-}"
      require_non_negative_integer "$1" "$retry_delay_value"
      require_integer_at_most "$1" "$retry_delay_value" "$max_retry_delay"
      retry_delay="$retry_delay_value"
      shift 2
      ;;
    --status)
      status=1
      shift
      ;;
    --gps-seconds)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      gps_seconds_value="${2:-}"
      require_positive_integer "$1" "$gps_seconds_value"
      require_integer_at_most "$1" "$gps_seconds_value" "$max_gps_seconds"
      gps_seconds="$gps_seconds_value"
      shift 2
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

if [[ -n "$gps_seconds" && "$status" -ne 1 ]]; then
  echo "--gps-seconds requires --status" >&2
  exit 2
fi

validate_ssh_target() {
  local value="$1"
  local user_part
  local host_part
  local host_lower

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
  host_lower="${host_part,,}"
  case "$host_lower" in
    localhost|localhost.localdomain|*.localhost|ip6-localhost|ip6-loopback|loopback|127.*|0|0.0.0.0)
      echo "SSH target must not point at this computer or loopback: $host_part" >&2
      exit 2
      ;;
  esac
  if [[ "$user_part" == "root" ]]; then
    cat >&2 <<'EOF'
Do not refresh charts as root@.
Use the Pi desktop user so the onboard config, chart storage, and manifest ownership stay consistent.
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
  if [[ ! -f "$resolved_path" ]]; then
    echo "Local ${command_name} command is not a regular file after resolution: $command_path -> $resolved_path" >&2
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
force_quoted="$(printf '%q' "$force")"
retries_quoted="$(printf '%q' "$retries")"
retry_delay_quoted="$(printf '%q' "$retry_delay")"
status_quoted="$(printf '%q' "$status")"
gps_seconds_quoted="$(printf '%q' "$gps_seconds")"

"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && NOAA_NAVIONICS_REFRESH_FORCE=${force_quoted} NOAA_NAVIONICS_REFRESH_RETRIES=${retries_quoted} NOAA_NAVIONICS_REFRESH_RETRY_DELAY=${retry_delay_quoted} NOAA_NAVIONICS_REFRESH_STATUS=${status_quoted} NOAA_NAVIONICS_REFRESH_GPS_SECONDS=${gps_seconds_quoted} /bin/bash -s" <<'REMOTE'
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

app_bin="${HOME}/.local/bin/noaa-navionics"
config="${HOME}/.config/noaa-navionics/config.ini"
launcher_env="${HOME}/.config/noaa-navionics/launcher.env"
expected_venv_bin="${HOME}/.local/share/noaa-navionics/venv/bin/noaa-navionics"
force="${NOAA_NAVIONICS_REFRESH_FORCE:-0}"
retries="${NOAA_NAVIONICS_REFRESH_RETRIES:-5}"
retry_delay="${NOAA_NAVIONICS_REFRESH_RETRY_DELAY:-30}"
status="${NOAA_NAVIONICS_REFRESH_STATUS:-0}"
gps_seconds="${NOAA_NAVIONICS_REFRESH_GPS_SECONDS:-}"
python3_cmd=""
max_retries=20
max_retry_delay=3600
max_gps_seconds=600

require_nonnegative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a non-negative integer" >&2
    exit 1
  fi
}

integer_greater_than() {
  local value="$1"
  local maximum="$2"
  if (( ${#value} > ${#maximum} )); then
    return 0
  fi
  if (( ${#value} == ${#maximum} )) && [[ "$value" > "$maximum" ]]; then
    return 0
  fi
  return 1
}

require_integer_at_most() {
  local name="$1"
  local value="$2"
  local maximum="$3"
  if integer_greater_than "$value" "$maximum"; then
    echo "$name must be at most ${maximum}" >&2
    exit 1
  fi
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer" >&2
    exit 1
  fi
}

require_boolean_control() {
  local name="$1"
  local value="$2"
  case "$value" in
    0|1)
      ;;
    *)
      echo "$name must be 0 or 1" >&2
      exit 1
      ;;
  esac
}

validate_refresh_controls() {
  require_boolean_control "NOAA_NAVIONICS_REFRESH_FORCE" "$force"
  require_boolean_control "NOAA_NAVIONICS_REFRESH_STATUS" "$status"
  require_positive_integer "NOAA_NAVIONICS_REFRESH_RETRIES" "$retries"
  require_integer_at_most "NOAA_NAVIONICS_REFRESH_RETRIES" "$retries" "$max_retries"
  require_nonnegative_integer "NOAA_NAVIONICS_REFRESH_RETRY_DELAY" "$retry_delay"
  require_integer_at_most "NOAA_NAVIONICS_REFRESH_RETRY_DELAY" "$retry_delay" "$max_retry_delay"
  if [[ -n "$gps_seconds" ]]; then
    if [[ "$status" != "1" ]]; then
      echo "NOAA_NAVIONICS_REFRESH_GPS_SECONDS requires NOAA_NAVIONICS_REFRESH_STATUS=1" >&2
      exit 1
    fi
    require_positive_integer "NOAA_NAVIONICS_REFRESH_GPS_SECONDS" "$gps_seconds"
    require_integer_at_most "NOAA_NAVIONICS_REFRESH_GPS_SECONDS" "$gps_seconds" "$max_gps_seconds"
  fi
}

fail() {
  echo "$*" >&2
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
    fail "Could not inspect remote command ${item_kind}: $item_path"
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"

  if [[ "$owner_uid" != "0" ]]; then
    fail "Remote ${item_kind} command is owned by uid ${owner_uid}, expected 0: ${item_path}"
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      fail "Remote ${item_kind} command has permissions ${mode}, expected no group/other write: ${item_path}"
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
    fail "Missing required remote command: $command_name"
  fi
  if ! remote_path_in_trusted_system_dir "$command_path"; then
    fail "Remote ${command_name} command is not in a trusted system directory: $command_path"
  fi
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    fail "Could not resolve remote ${command_name} command: $command_path"
  fi
  if ! remote_path_in_trusted_system_dir "$resolved_path"; then
    fail "Resolved remote ${command_name} command is not in a trusted system directory: $resolved_path"
  fi
  if [[ ! -f "$resolved_path" ]]; then
    fail "Remote ${command_name} command is not a regular file after resolution: $command_path -> $resolved_path"
  fi
  if [[ ! -x "$resolved_path" ]]; then
    fail "Remote ${command_name} command is not executable after resolution: $resolved_path"
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

check_user_owned_private_file() {
  local label="$1"
  local path="$2"
  local stat_output
  local owner_uid
  local mode
  local mode_tail
  local current_uid

  reject_symlinked_path_components "$label" "$path"
  if [[ -L "$path" ]]; then
    fail "$label must not be a symlink: $path"
  fi
  if [[ ! -f "$path" ]]; then
    fail "$label is missing or not a regular file: $path"
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    fail "Could not inspect $label: $path"
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

check_user_owned_nonwritable_directory() {
  local label="$1"
  local path="$2"
  local stat_output
  local owner_uid
  local mode
  local mode_tail
  local current_uid

  reject_symlinked_path_components "$label" "$path"
  if [[ -L "$path" ]]; then
    fail "$label is a symlink: $path"
  fi
  if [[ ! -d "$path" ]]; then
    fail "$label is missing or not a directory: $path"
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    fail "Could not inspect $label: $path"
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

check_installed_noaa_command_tree() {
  check_user_owned_nonwritable_directory "home directory" "$HOME"
  check_user_owned_nonwritable_directory "installed command directory" "${HOME}/.local"
  check_user_owned_nonwritable_directory "installed command directory" "${HOME}/.local/bin"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics/venv"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics/venv/bin"
}

check_installed_noaa_command() {
  local resolved
  local stat_output
  local owner_uid
  local current_uid
  local mode
  local mode_tail

  check_installed_noaa_command_tree
  reject_symlinked_parent_components "installed noaa-navionics command" "$app_bin"
  if [[ ! -L "$app_bin" ]]; then
    fail "Installed noaa-navionics command is not the expected private venv symlink: $app_bin"
  fi
  if ! resolved="$(readlink -f -- "$app_bin" 2>/dev/null)" || [[ -z "$resolved" ]]; then
    fail "Could not resolve installed noaa-navionics command: $app_bin"
  fi
  if [[ "$resolved" != "$expected_venv_bin" ]]; then
    fail "Installed noaa-navionics command resolves to $resolved, expected $expected_venv_bin"
  fi
  if [[ ! -f "$resolved" ]]; then
    fail "Installed noaa-navionics command target is not a regular file: $resolved"
  fi
  if [[ ! -x "$resolved" ]]; then
    fail "Installed noaa-navionics command is not executable after resolution: $resolved"
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$resolved" 2>/dev/null)"; then
    fail "Could not inspect installed noaa-navionics command target: $resolved"
  fi
  current_uid="$(id -u)"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    fail "Installed noaa-navionics command target is owned by uid $owner_uid, expected $current_uid: $resolved"
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      fail "Installed noaa-navionics command target has permissions $mode, expected no group/other write: $resolved"
      ;;
  esac
  "$python3_cmd" - "$resolved" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
nofollow = getattr(os, "O_NOFOLLOW", 0)
try:
    before = os.stat(path, follow_symlinks=False)
except OSError as exc:
    print(f"Could not inspect installed noaa-navionics command target through no-follow stat: {path}: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
if not stat.S_ISREG(before.st_mode):
    print(f"Installed noaa-navionics command target is not a regular non-symlink file: {path}", file=sys.stderr)
    raise SystemExit(1)
if before.st_uid != os.getuid():
    print(
        f"Installed noaa-navionics command target is owned by uid {before.st_uid}, expected current user {os.getuid()}: {path}",
        file=sys.stderr,
    )
    raise SystemExit(1)
mode = stat.S_IMODE(before.st_mode)
if mode & 0o022:
    print(f"Installed noaa-navionics command target has permissions {mode:03o}, expected no group/other write: {path}", file=sys.stderr)
    raise SystemExit(1)
if not mode & 0o111:
    print(f"Installed noaa-navionics command target is not executable: {path}", file=sys.stderr)
    raise SystemExit(1)
try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except OSError as exc:
    print(f"Could not open installed noaa-navionics command through no-follow descriptor: {path}: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        print(f"Installed noaa-navionics command changed before it could be validated: {path}", file=sys.stderr)
        raise SystemExit(1)
    if not stat.S_ISREG(opened.st_mode):
        print(f"Opened installed noaa-navionics command is not regular: {path}", file=sys.stderr)
        raise SystemExit(1)
finally:
    os.close(fd)
PY
  printf '%s\n' "$resolved"
}

run_noaa_navionics() {
  local app_exec
  app_exec="$(check_installed_noaa_command)"
  "$python3_cmd" - "$app_exec" "$@" <<'PY'
from pathlib import Path
import os
import stat
import subprocess
import sys

path = Path(sys.argv[1])
args = sys.argv[2:]
nofollow = getattr(os, "O_NOFOLLOW", 0)


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


try:
    before = os.stat(path, follow_symlinks=False)
except OSError as exc:
    fail(f"Could not inspect installed noaa-navionics command before descriptor execution: {path}: {exc}")
if not stat.S_ISREG(before.st_mode):
    fail(f"Installed noaa-navionics command must be regular before descriptor execution: {path}")
if before.st_uid != os.getuid():
    fail(f"Installed noaa-navionics command is owned by uid {before.st_uid}, expected current user {os.getuid()}: {path}")
mode = stat.S_IMODE(before.st_mode)
if mode & 0o022:
    fail(f"Installed noaa-navionics command has permissions {mode:03o}, expected no group/other write bits: {path}")
if not mode & 0o111:
    fail(f"Installed noaa-navionics command is not executable before descriptor execution: {path}")

try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except OSError as exc:
    fail(f"Could not open installed noaa-navionics command through no-follow descriptor for execution: {path}: {exc}")
try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        fail(f"Installed noaa-navionics command changed before descriptor execution: {path}")
    if not stat.S_ISREG(opened.st_mode):
        fail(f"Installed noaa-navionics command must be regular when opened for descriptor execution: {path}")
    if opened.st_uid != os.getuid():
        fail(f"Installed noaa-navionics command is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}")
    opened_mode = stat.S_IMODE(opened.st_mode)
    if opened_mode & 0o022:
        fail(f"Installed noaa-navionics command has permissions {opened_mode:03o}, expected no group/other write bits: {path}")
    if not opened_mode & 0o111:
        fail(f"Installed noaa-navionics command is not executable when opened for descriptor execution: {path}")
    try:
        result = subprocess.run([f"/proc/self/fd/{fd}", *args], pass_fds=(fd,))
    except OSError as exc:
        fail(f"Could not execute installed noaa-navionics command through validated descriptor: {path}: {exc}")
finally:
    os.close(fd)
raise SystemExit(result.returncode)
PY
}

validate_refresh_controls
python3_cmd="$(require_remote_command python3)"
check_user_owned_private_file "onboard NOAA Navionics config" "$config"

sync_args=(sync-charts --config "$config" --retries "$retries" --retry-delay "$retry_delay")
if [[ "$force" == "1" ]]; then
  sync_args+=(--force)
fi

run_noaa_navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300
run_noaa_navionics "${sync_args[@]}"
if [[ "$status" == "1" ]]; then
  printf '\nPost-refresh status report:\n'
  status_args=(status-report --config "$config")
  if [[ -n "$gps_seconds" ]]; then
    status_args+=(--gps-seconds "$gps_seconds")
  else
    check_user_owned_private_file "NOAA Navionics launcher environment" "$launcher_env"
    status_args+=(--gps-seconds-from-launcher-env "$launcher_env")
  fi
  run_noaa_navionics "${status_args[@]}"
fi
printf 'Pi NOAA chart refresh completed using %s.\n' "$config"
REMOTE

printf 'Pi NOAA chart refresh completed for %s.\n' "$target"
