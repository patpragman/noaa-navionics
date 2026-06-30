#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/export_pi_recovery_bundle.sh user@raspberrypi.local [output-dir] [options]

Runs the read-only Pi recovery exports into one timestamped local directory:
commissioning settings, OpenCPN user data, GPX tracks, and a diagnostic
support bundle.

Options:
  --track-days N     Export GPX tracks modified in the last N days; 0 exports all

Nothing is installed, enabled, rebooted, shut down, downloaded, or changed
on the local computer. NOAA chart archives and extracted ENC cells are not
copied by these helpers.
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
output_dir="pi-recovery-exports"
track_days=0
if [[ $# -gt 0 && "$1" != --* ]]; then
  output_dir="$1"
  shift
fi

require_non_negative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a non-negative integer" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --track-days)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      track_days="${2:-}"
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
Do not export recovery bundles as root@.
Use the Pi desktop user so settings, OpenCPN data, tracks, and diagnostics match the helm account.
EOF
    exit 2
  fi
}

validate_output_dir_arg() {
  local value="$1"
  if [[ -z "$value" ]]; then
    echo "Output directory is required" >&2
    exit 2
  fi
  if [[ "$value" =~ [\"\'] ]]; then
    echo "Output directory must not contain quotes: $value" >&2
    exit 2
  fi
  if [[ -L "$value" ]]; then
    echo "Output directory must not be a symlink: $value" >&2
    exit 2
  fi
}

prepare_private_output_dir() {
  local label="$1"
  local path="$2"
  local mode

  mkdir -p -- "$path"
  if [[ ! -d "$path" || -L "$path" ]]; then
    echo "$label must be a real directory: $path" >&2
    exit 2
  fi
  if ! chmod 0700 -- "$path"; then
    echo "Could not tighten $label permissions to 0700: $path" >&2
    exit 2
  fi
  if [[ ! -d "$path" || -L "$path" ]]; then
    echo "$label must remain a real directory after tightening: $path" >&2
    exit 2
  fi
  if ! mode="$(stat -Lc '%a' -- "$path" 2>/dev/null)"; then
    echo "Could not inspect $label permissions: $path" >&2
    exit 2
  fi
  if [[ "$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')" != "700" ]]; then
    echo "$label has permissions ${mode}, expected private 0700: $path" >&2
    exit 2
  fi
}

require_helper() {
  local path="$1"
  if [[ -L "$path" ]]; then
    echo "Helper script must not be a symlink: $path" >&2
    exit 2
  fi
  if [[ ! -f "$path" || ! -x "$path" ]]; then
    echo "Helper script is missing or not executable: $path" >&2
    exit 2
  fi
}

run_step() {
  local label="$1"
  shift
  printf '==> %s\n' "$label"
  "$@"
}

validate_ssh_target "$target"
validate_output_dir_arg "$output_dir"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
settings_helper="${repo_root}/scripts/export_pi_settings.sh"
opencpn_helper="${repo_root}/scripts/export_pi_opencpn_data.sh"
tracks_helper="${repo_root}/scripts/export_pi_tracks.sh"
support_helper="${repo_root}/scripts/collect_pi_support_bundle.sh"
require_helper "$settings_helper"
require_helper "$opencpn_helper"
require_helper "$tracks_helper"
require_helper "$support_helper"

prepare_private_output_dir "Output directory" "$output_dir"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_target="$(printf '%s' "$target" | tr '@.' '___')"
recovery_dir="${output_dir}/noaa-navionics-pi-recovery-${safe_target}-${timestamp}"
if [[ -e "$recovery_dir" ]]; then
  echo "Refusing to overwrite existing recovery directory: $recovery_dir" >&2
  exit 2
fi
prepare_private_output_dir "Recovery output directory" "$recovery_dir"

run_step "Exporting commissioning settings" "$settings_helper" "$target" "$recovery_dir"
run_step "Exporting OpenCPN user data" "$opencpn_helper" "$target" "$recovery_dir"
run_step "Exporting GPX tracks" "$tracks_helper" "$target" "$recovery_dir" --days "$track_days"
run_step "Collecting diagnostic support bundle" "$support_helper" "$target" "$recovery_dir"

printf '\nPi recovery exports written to: %s\n' "$recovery_dir"
