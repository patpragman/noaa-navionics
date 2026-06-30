#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/post_trip_collect_pi.sh user@raspberrypi.local [output-dir] [options]

Collects post-trip evidence from an already commissioned Raspberry Pi:
  1. Save a local JSON status snapshot.
  2. Export GPX track logs.
  3. Collect a diagnostic support bundle.
  4. Optionally dry-run or request a clean Pi shutdown.

Options:
  --track-days N       Export GPX tracks modified in the last N days; 0 exports all (default: 30)
  --gps-seconds N      Seconds to wait for a GPS fix in the status snapshot (default: 10)
  --skip-status        Skip the local JSON status snapshot
  --skip-tracks        Skip GPX track export
  --skip-support       Skip diagnostic support bundle collection
  --shutdown-dry-run   Validate the remote shutdown path without powering off
  --shutdown-confirm   Request a clean Pi poweroff after collection

This wrapper does not install, enable, reboot, download charts, or change
anything on the local computer. Shutdown is opt-in only.
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
output_dir="pi-post-trip-exports"
track_days=30
gps_seconds=10
skip_status=0
skip_tracks=0
skip_support=0
shutdown_mode=""

if [[ $# -gt 0 && "$1" != --* ]]; then
  output_dir="$1"
  shift
fi

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
Do not collect post-trip artifacts as root@.
Use the Pi desktop user so status, GPX tracks, OpenCPN data, and support logs match the helm account.
EOF
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
    --gps-seconds)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_integer "$1" "${2:-}"
      gps_seconds="${2:-}"
      shift 2
      ;;
    --skip-status)
      skip_status=1
      shift
      ;;
    --skip-tracks)
      skip_tracks=1
      shift
      ;;
    --skip-support)
      skip_support=1
      shift
      ;;
    --shutdown-dry-run)
      if [[ -n "$shutdown_mode" ]]; then
        echo "--shutdown-dry-run and --shutdown-confirm cannot be used together" >&2
        exit 2
      fi
      shutdown_mode="dry-run"
      shift
      ;;
    --shutdown-confirm)
      if [[ -n "$shutdown_mode" ]]; then
        echo "--shutdown-dry-run and --shutdown-confirm cannot be used together" >&2
        exit 2
      fi
      shutdown_mode="confirm"
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
validate_output_dir_arg "$output_dir"
if [[ "$skip_status" -eq 1 && "$skip_tracks" -eq 1 && "$skip_support" -eq 1 && -z "$shutdown_mode" ]]; then
  echo "At least one post-trip collection or shutdown step must run" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status_helper="${repo_root}/scripts/check_pi_status.sh"
tracks_helper="${repo_root}/scripts/export_pi_tracks.sh"
support_helper="${repo_root}/scripts/collect_pi_support_bundle.sh"
shutdown_helper="${repo_root}/scripts/shutdown_pi_safely.sh"
require_helper "$status_helper"
require_helper "$tracks_helper"
require_helper "$support_helper"
require_helper "$shutdown_helper"

prepare_private_output_dir "Output directory" "$output_dir"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_target="$(printf '%s' "$target" | tr '@.' '___')"
trip_dir="${output_dir}/noaa-navionics-pi-post-trip-${safe_target}-${timestamp}"
if [[ -e "$trip_dir" ]]; then
  echo "Refusing to overwrite existing post-trip directory: $trip_dir" >&2
  exit 2
fi
prepare_private_output_dir "Post-trip output directory" "$trip_dir"

status_code=0
if [[ "$skip_status" -eq 0 ]]; then
  status_path="${trip_dir}/status.json"
  printf '==> Saving Pi status snapshot\n'
  set +e
  "$status_helper" "$target" --gps-seconds "$gps_seconds" --json >"$status_path"
  status_code=$?
  set -e
  if [[ "$status_code" -eq 0 ]]; then
    printf 'Saved Pi status snapshot: %s\n' "$status_path"
  else
    printf 'Pi status snapshot exited %s; saved output for diagnosis: %s\n' "$status_code" "$status_path" >&2
  fi
else
  printf '==> Skipping Pi status snapshot\n'
fi

if [[ "$skip_tracks" -eq 0 ]]; then
  run_step "Exporting Pi GPX tracks" "$tracks_helper" "$target" "$trip_dir" --days "$track_days"
else
  printf '==> Skipping Pi GPX track export\n'
fi

if [[ "$skip_support" -eq 0 ]]; then
  run_step "Collecting Pi diagnostic support bundle" "$support_helper" "$target" "$trip_dir"
else
  printf '==> Skipping Pi diagnostic support bundle\n'
fi

case "$shutdown_mode" in
  dry-run)
    run_step "Dry-running clean Pi shutdown path" "$shutdown_helper" "$target" --dry-run
    ;;
  confirm)
    run_step "Requesting clean Pi shutdown" "$shutdown_helper" "$target" --confirm
    ;;
  "")
    ;;
esac

printf '\nPost-trip Pi artifacts written to: %s\n' "$trip_dir"
if [[ "$status_code" -ne 0 ]]; then
  echo "Post-trip collection completed, but the status snapshot reported a failure." >&2
  exit 1
fi
printf 'Post-trip Pi collection completed for %s.\n' "$target"
