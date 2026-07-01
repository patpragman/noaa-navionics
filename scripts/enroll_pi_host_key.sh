#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/enroll_pi_host_key.sh user@raspberrypi.local --expected-sha256 SHA256:FINGERPRINT [options]

Scans the Pi SSH host key, verifies it against a fingerprint from a trusted
channel, and writes only matching key lines to known_hosts.

Options:
  --expected-sha256 VALUE  Required trusted host-key fingerprint
  --known-hosts PATH       known_hosts file to update (default: ~/.ssh/known_hosts)
  --port N                 SSH port to scan (default: 22)
  --dry-run                Print matching key lines without updating known_hosts

Get the expected fingerprint from the Pi console or another trusted channel:
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
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
expected_sha256=""
known_hosts="${HOME}/.ssh/known_hosts"
port=22
dry_run=0
host_part=""
ssh_keyscan_cmd=""
ssh_keygen_cmd=""

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
  local mode
  local mode_tail
  local owner_uid
  local stat_output

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

  if [[ "${NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS:-0}" == "1" ]]; then
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

validate_ssh_target() {
  local value="$1"
  local user_part

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
}

require_positive_port() {
  local value="$1"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ || "$value" -gt 65535 ]]; then
    echo "--port must be an integer from 1 to 65535" >&2
    exit 2
  fi
}

validate_expected_sha256() {
  local value="$1"
  if [[ ! "$value" =~ ^SHA256:[A-Za-z0-9+/]{20,}$ ]]; then
    echo "--expected-sha256 must look like an OpenSSH SHA256 fingerprint: SHA256:..." >&2
    exit 2
  fi
}

reject_symlinked_path_components() {
  local label="$1"
  local path="$2"
  local current
  local component
  local remaining

  if [[ "$path" == /* ]]; then
    current="/"
    remaining="${path#/}"
  else
    current="."
    remaining="$path"
  fi

  while [[ -n "$remaining" ]]; do
    component="${remaining%%/*}"
    if [[ "$component" == "$remaining" ]]; then
      remaining=""
    else
      remaining="${remaining#*/}"
    fi
    if [[ -z "$component" || "$component" == "." ]]; then
      continue
    fi
    if [[ "$current" == "/" ]]; then
      current="/$component"
    else
      current="${current}/${component}"
    fi
    if [[ -L "$current" ]]; then
      echo "$label path contains a symlink: $current" >&2
      exit 2
    fi
  done
}

prepare_known_hosts_file() {
  local path="$1"
  local directory
  local current_uid
  local owner_uid
  local mode
  local stat_output

  directory="$(dirname -- "$path")"
  current_uid="$(id -u)"
  reject_symlinked_path_components "known_hosts" "$directory"
  mkdir -p -- "$directory"
  reject_symlinked_path_components "known_hosts" "$path"
  chmod 0700 -- "$directory"
  if ! stat_output="$(stat -Lc '%u %a' -- "$directory" 2>/dev/null)"; then
    echo "Could not inspect known_hosts directory owner and permissions: $directory" >&2
    exit 2
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    echo "known_hosts directory is owned by uid ${owner_uid}, expected current user ${current_uid}: $directory" >&2
    exit 2
  fi
  if [[ "$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')" != "700" ]]; then
    echo "known_hosts directory has permissions ${mode}, expected private 0700: $directory" >&2
    exit 2
  fi
  if [[ -e "$path" && ( -L "$path" || ! -f "$path" ) ]]; then
    echo "known_hosts must be a regular non-symlink file: $path" >&2
    exit 2
  fi
  if [[ ! -e "$path" ]]; then
    : >"$path"
  fi
  chmod 0600 -- "$path"
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    echo "Could not inspect known_hosts owner and permissions: $path" >&2
    exit 2
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    echo "known_hosts is owned by uid ${owner_uid}, expected current user ${current_uid}: $path" >&2
    exit 2
  fi
  if [[ "$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')" != "600" ]]; then
    echo "known_hosts has permissions ${mode}, expected private 0600: $path" >&2
    exit 2
  fi
}

host_marker() {
  if [[ "$port" == "22" ]]; then
    printf '%s\n' "$host_part"
  else
    printf '[%s]:%s\n' "$host_part" "$port"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-sha256)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      expected_sha256="${2:-}"
      shift 2
      ;;
    --known-hosts)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      known_hosts="${2:-}"
      shift 2
      ;;
    --port)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_port "${2:-}"
      port="${2:-}"
      shift 2
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

validate_ssh_target "$target"
if [[ -z "$expected_sha256" ]]; then
  echo "--expected-sha256 is required; get it from the Pi console or another trusted channel" >&2
  exit 2
fi
validate_expected_sha256 "$expected_sha256"
require_positive_port "$port"

ssh_keyscan_cmd="$(require_local_command ssh-keyscan)"
ssh_keygen_cmd="$(require_local_command ssh-keygen)"

scan_path="$(mktemp)"
match_path="$(mktemp)"
one_key_path="$(mktemp)"
cleanup() {
  rm -f -- "$scan_path" "$match_path" "$one_key_path"
}
trap cleanup EXIT

if ! "$ssh_keyscan_cmd" -T 10 -p "$port" "$host_part" >"$scan_path" 2>/dev/null || [[ ! -s "$scan_path" ]]; then
  echo "Could not scan SSH host keys from ${host_part}:${port}" >&2
  exit 1
fi

printf 'Scanned SSH host key fingerprints for %s:%s:\n' "$host_part" "$port"
"$ssh_keygen_cmd" -lf "$scan_path" -E sha256

while IFS= read -r key_line; do
  [[ -z "$key_line" || "$key_line" == \#* ]] && continue
  printf '%s\n' "$key_line" >"$one_key_path"
  keygen_output="$("$ssh_keygen_cmd" -lf "$one_key_path" -E sha256 2>/dev/null || true)"
  [[ -z "$keygen_output" ]] && continue
  read -r _bits fingerprint _rest <<<"$keygen_output"
  if [[ "$fingerprint" == "$expected_sha256" ]]; then
    printf '%s\n' "$key_line" >>"$match_path"
  fi
done <"$scan_path"

if [[ ! -s "$match_path" ]]; then
  echo "No scanned SSH host key matched expected fingerprint: $expected_sha256" >&2
  exit 1
fi

printf '\nVerified matching known_hosts line(s):\n'
cat "$match_path"

if [[ "$dry_run" -eq 1 ]]; then
  printf '\nDry run only; known_hosts was not changed.\n'
  exit 0
fi

prepare_known_hosts_file "$known_hosts"
marker="$(host_marker)"
"$ssh_keygen_cmd" -R "$marker" -f "$known_hosts" >/dev/null 2>&1 || true
cat "$match_path" >>"$known_hosts"
chmod 0600 -- "$known_hosts"
printf '\nEnrolled verified SSH host key for %s in %s.\n' "$marker" "$known_hosts"
