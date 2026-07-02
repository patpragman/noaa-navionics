#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/shutdown_pi_safely.sh user@raspberrypi.local --confirm
       scripts/shutdown_pi_safely.sh user@raspberrypi.local --dry-run

Flushes filesystem buffers and requests a clean Raspberry Pi poweroff over SSH.
Use this before cutting boat power to reduce SD-card, chart, config, and GPX
track-file corruption risk.

Options:
  --confirm   Required for a real shutdown
  --dry-run   Validate the remote shutdown path without powering off
  --timeout N Seconds to wait for SSH to stop responding after real shutdown (1-600; default: 90)

--timeout cannot be combined with --dry-run because there is no shutdown wait.
Nothing is installed, enabled, downloaded, or changed on the local computer.
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
confirm=0
dry_run=0
ssh_cmd=""
sleep_cmd=""
local_python_cmd=""
ssh_batch_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
ssh_probe_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o ServerAliveInterval=10 -o ServerAliveCountMax=2)
shutdown_timeout=90
timeout_set=0
max_shutdown_timeout=600
max_shutdown_output_bytes=$((1024 * 1024))
remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

normalize_decimal_integer() {
  local value="$1"
  value="${value#"${value%%[!0]*}"}"
  printf '%s\n' "${value:-0}"
}

integer_greater_than() {
  local value
  local maximum
  value="$(normalize_decimal_integer "$1")"
  maximum="$(normalize_decimal_integer "$2")"
  if (( ${#value} > ${#maximum} )); then
    return 0
  fi
  if (( ${#value} == ${#maximum} )) && [[ "$value" > "$maximum" ]]; then
    return 0
  fi
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)
      confirm=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --timeout)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      timeout_value="${2:-}"
      if [[ ! "$timeout_value" =~ ^[1-9][0-9]*$ ]]; then
        echo "--timeout must be a positive integer" >&2
        exit 2
      fi
      if integer_greater_than "$timeout_value" "$max_shutdown_timeout"; then
        echo "--timeout must be between 1 and ${max_shutdown_timeout} seconds" >&2
        exit 2
      fi
      shutdown_timeout="$(normalize_decimal_integer "$timeout_value")"
      timeout_set=1
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

if [[ "$confirm" -eq 1 && "$dry_run" -eq 1 ]]; then
  echo "--confirm and --dry-run cannot be used together" >&2
  exit 2
fi
if [[ "$confirm" -eq 0 && "$dry_run" -eq 0 ]]; then
  echo "--confirm is required for a real Pi shutdown; use --dry-run to test the path" >&2
  exit 2
fi
if [[ "$dry_run" -eq 1 && "$timeout_set" -eq 1 ]]; then
  echo "--timeout requires a real shutdown; remove --dry-run or omit --timeout" >&2
  exit 2
fi

validate_ssh_target() {
  local value="$1"
  local user_part
  local host_part
  local host_lower
  local local_hostname_file
  local local_hostname
  local local_hostname_lower
  local local_hostname_short

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
  for local_hostname_file in /proc/sys/kernel/hostname /etc/hostname; do
    if [[ ! -r "$local_hostname_file" ]]; then
      continue
    fi
    IFS= read -r local_hostname <"$local_hostname_file" || local_hostname=""
    local_hostname="${local_hostname%%[[:space:]]*}"
    if [[ -z "$local_hostname" ]]; then
      continue
    fi
    local_hostname_lower="${local_hostname,,}"
    local_hostname_short="${local_hostname_lower%%.*}"
    case "$host_lower" in
      "$local_hostname_lower"|"$local_hostname_short"|"$local_hostname_short.local")
        echo "SSH target must not point at this computer or loopback: $host_part" >&2
        exit 2
        ;;
    esac
  done
  if [[ "$user_part" == "root" ]]; then
    cat >&2 <<'EOF'
Do not shut down root@.
Use the Pi desktop user so the same SSH account used for commissioning is tested.
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

validate_remote_bash_entrypoint() {
  "$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && /bin/sh -s -- /bin/bash bash" <<'REMOTE_BASH_TRUST' >/dev/null
set -eu

command_path="$1"
command_label="$2"

check_trusted_system_path() {
  case "$1" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*)
      return 0
      ;;
  esac
  echo "Remote ${command_label} command is not in a trusted system directory: $1" >&2
  exit 1
}

check_owner_and_mode() {
  item_kind="$1"
  item_path="$2"
  stat_output="$(stat -Lc '%u %a' -- "$item_path")" || {
    echo "Could not inspect remote ${command_label} ${item_kind}: ${item_path}" >&2
    exit 1
  }
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [ "$owner_uid" != "0" ]; then
    echo "Remote ${command_label} ${item_kind} is owned by uid ${owner_uid}, expected 0: ${item_path}" >&2
    exit 1
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      echo "Remote ${command_label} ${item_kind} has permissions ${mode}, expected no group/other write: ${item_path}" >&2
      exit 1
      ;;
  esac
}

check_directory_chain() {
  directory="$(dirname -- "$1")"
  while :; do
    check_owner_and_mode directory "$directory"
    [ "$directory" = "/" ] && break
    directory="$(dirname -- "$directory")"
  done
}

check_trusted_system_path "$command_path"
resolved_cmd="$(readlink -f -- "$command_path")"
check_trusted_system_path "$resolved_cmd"
if [ ! -f "$resolved_cmd" ]; then
  echo "Remote ${command_label} command is not a regular file after resolution: ${command_path} -> ${resolved_cmd}" >&2
  exit 1
fi
if [ ! -x "$resolved_cmd" ]; then
  echo "Remote ${command_label} command is not executable after resolution: ${resolved_cmd}" >&2
  exit 1
fi
check_directory_chain "$command_path"
check_directory_chain "$resolved_cmd"
check_owner_and_mode file "$resolved_cmd"
REMOTE_BASH_TRUST
}

wait_for_ssh_shutdown() {
  local deadline
  local remaining

  deadline=$((SECONDS + shutdown_timeout))
  while (( SECONDS < deadline )); do
    if "$ssh_cmd" -T "${ssh_probe_options[@]}" "$target" "${remote_system_path} && export PATH && true" >/dev/null 2>&1; then
      remaining=$((deadline - SECONDS))
      if (( remaining <= 0 )); then
        break
      fi
      "$sleep_cmd" 2
    else
      printf 'SSH stopped responding after shutdown request for %s.\n' "$target"
      return 0
    fi
  done

  printf 'Pi still accepts SSH after %ss; do not cut boat power yet: %s\n' "$shutdown_timeout" "$target" >&2
  return 1
}

create_private_shutdown_output_capture() {
  local capture
  capture="$(mktemp "${TMPDIR:-/tmp}/.noaa-navionics-shutdown-output.XXXXXX")"
  chmod 0600 "$capture"
  printf '%s\n' "$capture"
}

cleanup_shutdown_output_capture() {
  local capture="${1:-}"
  [[ -n "$capture" ]] || return 0
  rm -f -- "$capture"
}

capture_shutdown_output() {
  local capture="$1"
  "$local_python_cmd" -c '
import os
import stat
import sys

path = sys.argv[1]
limit = int(sys.argv[2])
flags = os.O_WRONLY | os.O_TRUNC
flags |= getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags)
except OSError as exc:
    print(f"could not open shutdown output capture {path}: {exc}", file=sys.stderr)
    raise SystemExit(125)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        print(f"shutdown output capture is not a regular file: {path}", file=sys.stderr)
        raise SystemExit(125)
    if info.st_uid != os.getuid():
        print(
            f"shutdown output capture {path} is owned by uid {info.st_uid}, expected {os.getuid()}",
            file=sys.stderr,
        )
        raise SystemExit(125)
    mode = stat.S_IMODE(info.st_mode)
    if mode != 0o600:
        print(f"shutdown output capture {path} has permissions {mode:04o}, expected 0600", file=sys.stderr)
        raise SystemExit(125)

    total = 0
    while True:
        chunk = sys.stdin.buffer.read(65536)
        if not chunk:
            break
        previous = total
        total += len(chunk)
        if total > limit:
            allowed = max(0, limit - previous)
            if allowed:
                os.write(fd, chunk[:allowed])
            os.fsync(fd)
            print(f"shutdown output exceeds size limit ({total} > {limit} bytes)", file=sys.stderr)
            raise SystemExit(124)
        os.write(fd, chunk)
    os.fsync(fd)
finally:
    os.close(fd)
' "$capture" "$max_shutdown_output_bytes"
}

run_remote_shutdown() {
  "$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && NOAA_NAVIONICS_SHUTDOWN_DRY_RUN=${dry_run_quoted} /bin/bash -s" <<'REMOTE'
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

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
  local stat_output
  local owner_uid
  local mode
  local mode_tail

  if ! stat_output="$(stat -Lc '%u %a' -- "$item_path" 2>/dev/null)"; then
    echo "Could not inspect remote command ${item_kind}: $item_path" >&2
    exit 1
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"

  if [[ "$owner_uid" != "0" ]]; then
    echo "Remote ${item_kind} command is owned by uid ${owner_uid}, expected 0: ${item_path}" >&2
    exit 1
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      echo "Remote ${item_kind} command has permissions ${mode}, expected no group/other write: ${item_path}" >&2
      exit 1
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

validate_shutdown_controls() {
  case "${NOAA_NAVIONICS_SHUTDOWN_DRY_RUN:-}" in
    0|1)
      ;;
    *)
      echo "NOAA_NAVIONICS_SHUTDOWN_DRY_RUN must be 0 or 1" >&2
      exit 1
      ;;
  esac
}

track_unit=noaa-navionics-track.service

require_remote_command() {
  local command_name="$1"
  local command_path
  local resolved_path

  if ! command_path="$(command -v "$command_name" 2>/dev/null)" || [[ -z "$command_path" ]]; then
    echo "Missing required remote command: $command_name" >&2
    exit 1
  fi
  if ! remote_path_in_trusted_system_dir "$command_path"; then
    echo "Remote ${command_name} command is not in a trusted system directory: $command_path" >&2
    exit 1
  fi
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    echo "Could not resolve remote ${command_name} command: $command_path" >&2
    exit 1
  fi
  if ! remote_path_in_trusted_system_dir "$resolved_path"; then
    echo "Resolved remote ${command_name} command is not in a trusted system directory: $resolved_path" >&2
    exit 1
  fi
  if [[ ! -f "$resolved_path" ]]; then
    echo "Remote ${command_name} command is not a regular file after resolution: $command_path -> $resolved_path" >&2
    exit 1
  fi
  if [[ ! -x "$resolved_path" ]]; then
    echo "Remote ${command_name} command is not executable after resolution: $resolved_path" >&2
    exit 1
  fi
  check_remote_directory_chain "$resolved_path"
  check_remote_owner_and_mode "$command_name" "$resolved_path"
  printf '%s\n' "$resolved_path"
}

validate_track_logger_user_service() {
  local load_state

  if ! load_state="$("$systemctl_cmd" --user show "$track_unit" --property=LoadState --value 2>/dev/null)" || [[ -z "$load_state" ]]; then
    echo "Remote user systemd cannot inspect ${track_unit}; run provisioning and verify user linger before shutdown checks." >&2
    exit 1
  fi
  if [[ "$load_state" == "not-found" ]]; then
    echo "Remote track logger unit is not installed for this user: ${track_unit}" >&2
    exit 1
  fi
}

stop_track_logger_for_shutdown() {
  validate_track_logger_user_service
  printf 'Stopping track logger before filesystem sync.\n'
  "$systemctl_cmd" --user stop "$track_unit"
  printf 'Track logger stop completed.\n'
}

validate_shutdown_controls
sync_cmd="$(require_remote_command sync)"
sudo_cmd="$(require_remote_command sudo)"
systemctl_cmd="$(require_remote_command systemctl)"

if ! "$sudo_cmd" -n -l "$systemctl_cmd" poweroff >/dev/null 2>&1; then
  echo "Remote sudo is not permitted to run systemctl poweroff without a password prompt." >&2
  echo "Allow passwordless sudo for: $systemctl_cmd poweroff" >&2
  exit 1
fi

sync_cmd="$(require_remote_command sync)"
sudo_cmd="$(require_remote_command sudo)"
systemctl_cmd="$(require_remote_command systemctl)"
if ! "$sudo_cmd" -n -l "$systemctl_cmd" poweroff >/dev/null 2>&1; then
  echo "Remote sudo is not permitted to run systemctl poweroff without a password prompt." >&2
  echo "Allow passwordless sudo for: $systemctl_cmd poweroff" >&2
  exit 1
fi
if [[ "${NOAA_NAVIONICS_SHUTDOWN_DRY_RUN:-0}" == "1" ]]; then
  validate_track_logger_user_service
  printf 'Dry run passed; would stop %s, sync filesystems, and run: %s -n %s poweroff\n' "$track_unit" "$sudo_cmd" "$systemctl_cmd"
  exit 0
fi

stop_track_logger_for_shutdown
sync_cmd="$(require_remote_command sync)"
"$sync_cmd"
printf 'Filesystem sync completed; requesting clean Pi poweroff.\n'
"$sudo_cmd" -n "$systemctl_cmd" poweroff
printf 'Poweroff request accepted by systemd.\n'
REMOTE
}

validate_ssh_target "$target"
ssh_cmd="$(require_local_command ssh)"
sleep_cmd="$(require_local_command sleep)"
local_python_cmd="$(require_local_command python3)"
dry_run_quoted="$(printf '%q' "$dry_run")"
validate_remote_bash_entrypoint

shutdown_output_capture="$(create_private_shutdown_output_capture)"
cleanup_shutdown_capture() {
  cleanup_shutdown_output_capture "${shutdown_output_capture:-}" || true
}
trap cleanup_shutdown_capture EXIT

set +e
run_remote_shutdown 2>&1 | capture_shutdown_output "$shutdown_output_capture"
shutdown_pipe_statuses=("${PIPESTATUS[@]}")
set -e
ssh_status="${shutdown_pipe_statuses[0]}"
capture_status="${shutdown_pipe_statuses[1]}"
if [[ "$capture_status" -eq 124 ]]; then
  exit 2
fi
if [[ "$capture_status" -ne 0 ]]; then
  exit "$capture_status"
fi
ssh_output="$(<"$shutdown_output_capture")"
if [[ -n "$ssh_output" ]]; then
  printf '%s\n' "$ssh_output"
fi

if [[ "$dry_run" -eq 1 ]]; then
  if [[ "$ssh_status" -ne 0 ]]; then
    exit "$ssh_status"
  fi
  printf 'Pi shutdown dry run passed for %s.\n' "$target"
  exit 0
fi

if [[ "$ssh_output" != *"Filesystem sync completed; requesting clean Pi poweroff."* ]]; then
  printf 'Remote shutdown command did not reach the poweroff request for %s.\n' "$target" >&2
  if [[ "$ssh_status" -ne 0 ]]; then
    exit "$ssh_status"
  fi
  exit 1
fi
if [[ "$ssh_output" != *"Poweroff request accepted by systemd."* ]]; then
  printf 'Remote shutdown command did not report that systemd accepted the poweroff request for %s.\n' "$target" >&2
  if [[ "$ssh_status" -ne 0 && "$ssh_status" -ne 255 ]]; then
    exit "$ssh_status"
  fi
  exit 1
fi
if [[ "$ssh_status" -ne 0 && "$ssh_status" -ne 255 ]]; then
  exit "$ssh_status"
fi
wait_for_ssh_shutdown
printf 'Clean Pi poweroff confirmed by SSH drop for %s.\n' "$target"
