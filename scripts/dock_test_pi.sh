#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/dock_test_pi.sh user@raspberrypi.local [remote-dir] --device /dev/serial/by-id/YOUR_GPS [options]

Options:
  --device PATH       Stable GPS device path on the Pi
  --allow-dirty       Allow deploying a dirty local worktree for deliberate test runs
  --skip-deploy       Do not deploy/provision; verify the existing Pi setup
  --skip-gps-time     Pass through provisioning without configuring chrony GPS time
  --no-reboot         Do not reboot; run only pre-reboot verification
  --timeout SECONDS   Time to wait for SSH after reboot
  --gps-seconds N     Seconds to wait for a GPS fix during provisioning
  --sync-retries N    Chart download attempts during provisioning
  --sync-retry-delay N
                     Seconds between chart download retry attempts
  --opencpn-restarts N
                     OpenCPN nonzero-exit restart attempts after boot
  --opencpn-restart-delay N
                     Seconds between OpenCPN restart attempts

Runs a dock acceptance test over SSH:
deploy/provision, verify, reboot, wait for the Pi, and verify again.
Nothing is installed or enabled on the local computer.
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
remote_dir="~/noaa-navionics"
device=""
skip_deploy=0
no_reboot=0
timeout=180
deploy_args=()
provision_args=()
verify_args=()
remote_reboot_cmd=""
remote_sudo_cmd=""
ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
ssh_probe_options=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
Do not run the dock test as root@.
Use the Pi desktop user so autologin, user services, charts, and tracks are verified for the real helm account.
EOF
    exit 2
  fi
}

validate_gps_device_path_arg() {
  local value="$1"
  local suffix
  if [[ -z "$value" ]]; then
    echo "GPS device path is required" >&2
    exit 2
  fi
  if [[ "$value" =~ [[:space:]\"\'] ]]; then
    echo "GPS device path must not contain whitespace or quotes: $value" >&2
    exit 2
  fi
  case "$value" in
    /dev/serial/by-id/*)
      suffix="${value#/dev/serial/by-id/}"
      if [[ -n "$suffix" && "$suffix" != */* && "$suffix" != "." && "$suffix" != ".." && "$suffix" =~ ^[A-Za-z0-9._:+@-]+$ ]]; then
        return 0
      fi
      ;;
    /dev/serial0|/dev/serial1|/dev/gps)
      return 0
      ;;
    /dev/ttyUSB*|/dev/ttyACM*)
      echo "GPS device path is volatile; use /dev/serial/by-id/... instead: $value" >&2
      exit 2
      ;;
  esac
  echo "GPS device path must be /dev/serial/by-id/..., /dev/serial0, /dev/serial1, or /dev/gps: $value" >&2
  exit 2
}

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

require_local_command() {
  local command_name="$1"
  local command_path
  if ! command_path="$(command -v "$command_name" 2>/dev/null)" || [[ -z "$command_path" ]]; then
    echo "Missing required local command: $command_name" >&2
    exit 2
  fi
  validate_trusted_local_command "$command_name" "$command_path"
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
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    echo "Could not resolve local ${command_name} command path: $command_path" >&2
    exit 2
  fi
  if ! local_path_in_trusted_system_dir "$resolved_path"; then
    echo "Local ${command_name} command resolves outside trusted system directories: $command_path -> $resolved_path" >&2
    exit 2
  fi
  if [[ ! -f "$resolved_path" ]]; then
    echo "Local ${command_name} command is not a regular file after resolution: $command_path -> $resolved_path" >&2
    exit 2
  fi
  if [[ ! -x "$resolved_path" ]]; then
    echo "Local ${command_name} command is not executable after resolution: $command_path -> $resolved_path" >&2
    exit 2
  fi
  check_local_directory_chain "$command_path"
  check_local_directory_chain "$resolved_path"
  check_local_owner_and_mode file "$resolved_path"
}

validate_remote_dir() {
  local value="$1"
  local trimmed
  local basename

  trimmed="${value%/}"
  if [[ -z "$trimmed" || "$trimmed" == "." || "$trimmed" == ".." || "$trimmed" == "/" || "$trimmed" == "~" || "$trimmed" == "/home" || "$trimmed" == "/root" ]]; then
    echo "Remote deployment directory must be a dedicated noaa-navionics directory, not: $value" >&2
    exit 2
  fi
  if [[ ! "$value" =~ ^((~)?/)?[A-Za-z0-9._/-]+$ ]]; then
    echo "Remote deployment directory contains unsafe characters: $value" >&2
    exit 2
  fi
  case "$trimmed" in
    /tmp/*|/var/*|/etc/*|/usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*|/run/*|/dev/*|/proc/*|/sys/*|/boot/*)
      echo "Remote deployment directory must be under the Pi user's home directory, not a system or volatile path: $value" >&2
      exit 2
      ;;
  esac
  basename="${trimmed##*/}"
  case "$basename" in
    noaa-navionics|noaa-navionics-*|noaa-navionics_*|noaa-navionics.*)
      ;;
    *)
      echo "Remote deployment directory must end in noaa-navionics or a noaa-navionics-* variant: $value" >&2
      exit 2
      ;;
  esac
}

if [[ $# -gt 0 && "$1" != --* ]]; then
  remote_dir="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      validate_gps_device_path_arg "$2"
      device="$2"
      provision_args+=("--device" "$device")
      verify_args+=("--expected-gps-device" "$device")
      shift 2
      ;;
    --gps-seconds)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_integer "$1" "${2:-}"
      provision_args+=("$1" "${2:-}")
      verify_args+=("$1" "${2:-}")
      shift 2
      ;;
    --sync-retries)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_integer "$1" "${2:-}"
      provision_args+=("$1" "${2:-}")
      shift 2
      ;;
    --sync-retry-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      provision_args+=("$1" "${2:-}")
      shift 2
      ;;
    --opencpn-restarts|--opencpn-restart-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      provision_args+=("$1" "${2:-}")
      verify_args+=("$1" "${2:-}")
      shift 2
      ;;
    --allow-dirty)
      deploy_args+=("$1")
      verify_args+=("$1")
      shift
      ;;
    --skip-deploy)
      skip_deploy=1
      shift
      ;;
    --skip-autologin)
      cat >&2 <<'EOF'
--skip-autologin cannot be used for the dock acceptance test.
The dock test verifies the production desktop startup path; use deploy_to_pi.sh --provision --skip-autologin --skip-services for weaker manual or headless testing.
EOF
      exit 2
      ;;
    --skip-gps-time)
      provision_args+=("$1")
      shift
      ;;
    --no-reboot)
      no_reboot=1
      shift
      ;;
    --timeout)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_integer "$1" "${2:-}"
      timeout="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

validate_ssh_target "$target"
require_positive_integer "--timeout" "$timeout"

if [[ -z "$device" && ! ( "$skip_deploy" -eq 1 && "$no_reboot" -eq 1 ) ]]; then
  echo "--device is required for the rebooted dock acceptance test" >&2
  echo "Use --skip-deploy --no-reboot only for a weaker smoke check of an already-provisioned Pi." >&2
  exit 2
fi

if [[ "$skip_deploy" -eq 0 ]]; then
  validate_remote_dir "$remote_dir"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_local_command ssh

wait_for_ssh_down() {
  local deadline=$((SECONDS + 60))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if ! ssh_available; then
      return 0
    fi
    sleep 2
  done
  echo "warning: SSH did not drop after reboot request; continuing to wait for availability" >&2
}

wait_for_ssh_up() {
  local deadline=$((SECONDS + timeout))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if ssh_available; then
      return 0
    fi
    sleep 5
  done
  echo "Pi did not return on SSH within ${timeout}s: $target" >&2
  return 1
}

ssh_available() {
  ssh "${ssh_probe_options[@]}" "$target" "${remote_system_path} && export PATH && true" >/dev/null 2>&1
}

remote_boot_id() {
  ssh "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && python3 -" <<'REMOTE_BOOT_ID'
from pathlib import Path
import re

try:
    value = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
except OSError as exc:
    raise SystemExit(f"could not read remote boot ID: {exc}") from exc
if not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", value):
    raise SystemExit(f"remote boot ID is invalid; expected Linux boot_id value: {value or '<empty>'}")
print(value)
REMOTE_BOOT_ID
}

validate_boot_id_value() {
  local label="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    echo "${label} boot ID is empty" >&2
    return 1
  fi
  if [[ ! "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "${label} boot ID is invalid; expected Linux boot_id value: $value" >&2
    return 1
  fi
}

validate_remote_root_command_trust() {
  local command_label="$1"
  local command_path="$2"
  local command_path_quoted
  local command_label_quoted

  case "$command_path" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*)
      ;;
    *)
      echo "Remote ${command_label} command is not in a trusted system directory: $command_path" >&2
      return 1
      ;;
  esac

  command_path_quoted="$(printf '%q' "$command_path")"
  command_label_quoted="$(printf '%q' "$command_label")"
  ssh "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && sh -s -- ${command_path_quoted} ${command_label_quoted}" <<'REMOTE_ROOT_COMMAND_TRUST'
set -eu

command_path="$1"
command_label="$2"

check_trusted_system_path() {
  case "$1" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*)
      return 0
      ;;
  esac
  echo "Remote ${command_label} command resolves outside trusted system directories: $1" >&2
  return 1
}

check_owner_and_mode() {
  item_kind="$1"
  item_path="$2"
  stat_output="$(stat -Lc '%u %a' -- "$item_path")"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"

  if [ "$owner_uid" != "0" ]; then
    echo "Remote ${command_label} command ${item_kind} is owned by uid ${owner_uid}, expected 0: ${item_path}" >&2
    return 1
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      echo "Remote ${command_label} command ${item_kind} has permissions ${mode}, expected no group/other write: ${item_path}" >&2
      return 1
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
  echo "Remote ${command_label} command is not executable after resolution: ${command_path} -> ${resolved_cmd}" >&2
  exit 1
fi
check_directory_chain "$command_path"
check_directory_chain "$resolved_cmd"
check_owner_and_mode file "$resolved_cmd"
REMOTE_ROOT_COMMAND_TRUST
}

validate_remote_reboot_command_trust() {
  validate_remote_root_command_trust reboot "$1"
}

remote_reboot_command() {
  local reboot_cmd

  if ! reboot_cmd="$(ssh "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && command -v reboot" 2>/dev/null)" || [[ -z "$reboot_cmd" ]]; then
    echo "Could not find the remote reboot command on $target." >&2
    return 1
  fi
  if [[ "$reboot_cmd" != /* || "$reboot_cmd" =~ [[:space:]\"\'] ]]; then
    echo "Remote reboot command path is unsafe: $reboot_cmd" >&2
    return 1
  fi
  if ! validate_remote_reboot_command_trust "$reboot_cmd"; then
    return 1
  fi
  printf '%s\n' "$reboot_cmd"
}

remote_sudo_command() {
  local sudo_cmd

  if ! sudo_cmd="$(ssh "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && command -v sudo" 2>/dev/null)" || [[ -z "$sudo_cmd" ]]; then
    echo "Could not find the remote sudo command on $target." >&2
    return 1
  fi
  if [[ "$sudo_cmd" != /* || "$sudo_cmd" =~ [[:space:]\"\'] ]]; then
    echo "Remote sudo command path is unsafe: $sudo_cmd" >&2
    return 1
  fi
  if ! validate_remote_root_command_trust sudo "$sudo_cmd"; then
    return 1
  fi
  printf '%s\n' "$sudo_cmd"
}

check_remote_noninteractive_reboot_available() {
  if ! remote_reboot_cmd="$(remote_reboot_command)"; then
    return 1
  fi
  if ! remote_sudo_cmd="$(remote_sudo_command)"; then
    return 1
  fi

  if ssh "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && '$remote_sudo_cmd' -n -l '$remote_reboot_cmd'" >/dev/null 2>&1; then
    printf 'OK   noninteractive sudo can run %s\n' "$remote_reboot_cmd"
    return 0
  fi

  echo "Failed to preflight passwordless sudo reboot on $target." >&2
  echo "The dock test requires the SSH user to run reboot without a password prompt." >&2
  echo "Allow passwordless sudo for: $remote_reboot_cmd" >&2
  echo "Use --no-reboot only for a weaker pre-reboot smoke check." >&2
  return 1
}

request_reboot() {
  if [[ -z "$remote_reboot_cmd" ]]; then
    remote_reboot_cmd="$(remote_reboot_command)"
  fi
  if [[ -z "$remote_sudo_cmd" ]]; then
    remote_sudo_cmd="$(remote_sudo_command)"
  fi

  if ssh "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && '$remote_sudo_cmd' -n '$remote_reboot_cmd'" >/dev/null 2>&1; then
    return 0
  fi

  local deadline=$((SECONDS + 30))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if ! ssh_available; then
      return 0
    fi
    sleep 2
  done

  echo "Failed to request reboot with passwordless sudo on $target." >&2
  echo "The dock test requires the SSH user to run: $remote_sudo_cmd -n $remote_reboot_cmd" >&2
  return 1
}

if [[ "$no_reboot" -eq 0 ]]; then
  printf '\n[reboot sudo preflight]\n'
  check_remote_noninteractive_reboot_available
fi

if [[ "$skip_deploy" -eq 0 ]]; then
  "${repo_root}/scripts/deploy_to_pi.sh" "$target" "$remote_dir" "${deploy_args[@]}" --provision "${provision_args[@]}"
fi

printf '\n[verify before reboot]\n'
"${repo_root}/scripts/verify_pi.sh" "${verify_args[@]}" "$target"

if [[ "$no_reboot" -eq 1 ]]; then
  printf '\nPre-reboot verification passed; reboot and chartplotter autostart proof were skipped.\n'
  exit 0
fi

printf '\n[reboot]\n'
before_boot_id="$(remote_boot_id)"
validate_boot_id_value "pre-reboot" "$before_boot_id" || exit 1
request_reboot
wait_for_ssh_down
wait_for_ssh_up
after_boot_id="$(remote_boot_id)"
validate_boot_id_value "post-reboot" "$after_boot_id" || exit 1
if [[ "$after_boot_id" == "$before_boot_id" ]]; then
  echo "Pi SSH returned, but boot ID did not change after reboot request" >&2
  exit 1
fi
printf 'OK   boot ID changed after reboot\n'

printf '\n[verify after reboot]\n'
"${repo_root}/scripts/verify_pi.sh" --require-chartplotter-started --expected-boot-id "$after_boot_id" "${verify_args[@]}" "$target"

printf '\nDock test passed after reboot.\n'
