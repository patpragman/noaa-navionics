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
ssh_batch_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
    localhost|localhost.localdomain|*.localhost|127.*|0.0.0.0)
      echo "SSH target must not point at this computer or loopback: $host_part" >&2
      exit 2
      ;;
  esac
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
dry_run_quoted="$(printf '%q' "$dry_run")"

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
  if [[ ! -x "$resolved_path" ]]; then
    echo "Remote ${command_name} command is not executable after resolution: $resolved_path" >&2
    exit 1
  fi
  check_remote_directory_chain "$resolved_path"
  check_remote_owner_and_mode "$command_name" "$resolved_path"
  printf '%s\n' "$resolved_path"
}

sync_cmd="$(require_remote_command sync)"
sudo_cmd="$(require_remote_command sudo)"
systemctl_cmd="$(require_remote_command systemctl)"

if ! "$sudo_cmd" -n -l "$systemctl_cmd" poweroff >/dev/null 2>&1; then
  echo "Remote sudo is not permitted to run systemctl poweroff without a password prompt." >&2
  echo "Allow passwordless sudo for: $systemctl_cmd poweroff" >&2
  exit 1
fi

"$sync_cmd"
if [[ "${NOAA_NAVIONICS_SHUTDOWN_DRY_RUN:-0}" == "1" ]]; then
  printf 'Dry run passed; would run: %s -n %s poweroff\n' "$sudo_cmd" "$systemctl_cmd"
  exit 0
fi

printf 'Filesystem sync completed; requesting clean Pi poweroff.\n'
"$sudo_cmd" -n "$systemctl_cmd" poweroff
REMOTE

if [[ "$dry_run" -eq 1 ]]; then
  printf 'Pi shutdown dry run passed for %s.\n' "$target"
else
  printf 'Clean Pi poweroff requested for %s.\n' "$target"
fi
