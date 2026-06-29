#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${HOME}/.config/noaa-navionics/config.ini"
device=""
allow_non_pi=0
check_device=1
dry_run=0
skip_gpsd=0
skip_sync=0
skip_services=0
skip_autologin=0
skip_gps_time=0
gps_seconds=10
sync_retries=5
sync_retry_delay=30

sync_paths() {
  python3 - "$@" <<'PY'
from pathlib import Path
import os
import sys

synced_dirs: set[Path] = set()
for arg in sys.argv[1:]:
    path = Path(arg).expanduser()
    try:
        with path.open("rb") as handle:
            os.fsync(handle.fileno())
    except OSError:
        continue
    synced_dirs.add(path.parent)
for directory in synced_dirs:
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        continue
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

usage() {
  cat >&2 <<'EOF'
Usage: scripts/provision_sailboat_pi.sh --device /dev/serial/by-id/YOUR_GPS [options]

Options:
  --config PATH       NOAA Navionics config path
  --gps-seconds N     Seconds to wait for a GPS fix during final status report
  --sync-retries N    Chart download attempts during initial commissioning
  --sync-retry-delay N
                     Seconds between chart download retry attempts
  --dry-run           Print commands without changing the Pi
  --skip-gpsd         Do not configure GPSD
  --skip-sync         Do not download charts
  --skip-services     Do not enable user systemd services
  --skip-autologin    Do not configure desktop graphical autologin
  --skip-gps-time     Do not configure chrony to use GPSD time
  --no-device-check   Do not require the GPS device path to exist now
  --allow-non-pi      Allow running on non-Raspberry Pi architecture

Runs the onboard commissioning sequence on the Raspberry Pi:
GPSD, chart sync, OpenCPN config, services, and final readiness report.
EOF
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      device="${2:-}"
      shift 2
      ;;
    --config)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      config="${2:-}"
      shift 2
      ;;
    --gps-seconds)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      gps_seconds="${2:-}"
      shift 2
      ;;
    --sync-retries)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      sync_retries="${2:-}"
      shift 2
      ;;
    --sync-retry-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      sync_retry_delay="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --skip-gpsd)
      skip_gpsd=1
      shift
      ;;
    --skip-sync)
      skip_sync=1
      shift
      ;;
    --skip-services)
      skip_services=1
      shift
      ;;
    --skip-autologin)
      skip_autologin=1
      shift
      ;;
    --skip-gps-time)
      skip_gps_time=1
      shift
      ;;
    --no-device-check)
      check_device=0
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

require_positive_integer "--gps-seconds" "$gps_seconds"
require_positive_integer "--sync-retries" "$sync_retries"
require_non_negative_integer "--sync-retry-delay" "$sync_retry_delay"

if [[ "$skip_gpsd" -eq 0 && -z "$device" ]]; then
  echo "--device is required unless --skip-gpsd is used" >&2
  usage
  exit 2
fi

arch="$(uname -m)"
if [[ "$allow_non_pi" -eq 0 && "$arch" != armv7l && "$arch" != aarch64 ]]; then
  cat >&2 <<EOF
Refusing to provision sailboat Pi on architecture '$arch'.
Run this on the Raspberry Pi, or pass --allow-non-pi for development-only testing.
EOF
  exit 2
fi

if [[ "$skip_gpsd" -eq 0 && "$check_device" -eq 1 && "$dry_run" -eq 0 && ! -e "$device" ]]; then
  cat >&2 <<EOF
GPS device does not exist: $device
Use a stable path from /dev/serial/by-id/, or pass --no-device-check if it is not plugged in yet.
EOF
  exit 2
fi

bin="${HOME}/.local/bin/noaa-navionics"
if [[ ! -x "$bin" && "$dry_run" -eq 0 ]]; then
  if command -v noaa-navionics >/dev/null 2>&1; then
    bin="$(command -v noaa-navionics)"
  else
    echo "noaa-navionics is not installed; run scripts/install_raspberry_pi.sh first" >&2
    exit 2
  fi
fi

run() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

status_report="${HOME}/.cache/noaa-navionics/status.json"
launcher_env="${HOME}/.config/noaa-navionics/launcher.env"
systemd_user_dir="${HOME}/.config/systemd/user"
chart_service="${systemd_user_dir}/noaa-navionics.service"
chart_timer="${systemd_user_dir}/noaa-navionics.timer"
track_service="${systemd_user_dir}/noaa-navionics-track.service"
preflight_service="${systemd_user_dir}/noaa-navionics-preflight.service"

write_launcher_env() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ write %q with NOAA_NAVIONICS_GPS_SECONDS=%q\n' "$launcher_env" "$gps_seconds"
  else
    mkdir -p "$(dirname "$launcher_env")"
    printf 'NOAA_NAVIONICS_GPS_SECONDS=%s\n' "$gps_seconds" >"$launcher_env"
    sync_paths "$launcher_env"
  fi
}

run mkdir -p "$(dirname "$config")"
if [[ ! -f "$config" ]]; then
  run "$bin" init-config --config "$config"
fi
write_launcher_env

if [[ "$skip_gpsd" -eq 0 ]]; then
  gpsd_args=(--device "$device" --config "$config")
  if [[ "$check_device" -eq 0 ]]; then
    gpsd_args+=(--no-device-check)
  fi
  if [[ "$allow_non_pi" -eq 1 ]]; then
    gpsd_args+=(--allow-non-pi)
  fi
  if [[ "$dry_run" -eq 1 ]]; then
    gpsd_args+=(--dry-run)
  fi
  run "${repo_root}/scripts/configure_gpsd.sh" "${gpsd_args[@]}"
  if [[ "$skip_gps_time" -eq 0 ]]; then
    gps_time_args=()
    if [[ "$allow_non_pi" -eq 1 ]]; then
      gps_time_args+=(--allow-non-pi)
    fi
    if [[ "$dry_run" -eq 1 ]]; then
      gps_time_args+=(--dry-run)
    fi
    run "${repo_root}/scripts/configure_gps_time.sh" "${gps_time_args[@]}"
  fi
fi

if [[ "$skip_sync" -eq 0 ]]; then
  run "$bin" sync-charts --config "$config" --retries "$sync_retries" --retry-delay "$sync_retry_delay"
fi

run "$bin" configure-opencpn --config "$config"

if [[ "$skip_autologin" -eq 0 ]]; then
  desktop_args=(--user "$USER")
  if [[ "$allow_non_pi" -eq 1 ]]; then
    desktop_args+=(--allow-non-pi)
  fi
  if [[ "$dry_run" -eq 1 ]]; then
    desktop_args+=(--dry-run)
  fi
  run "${repo_root}/scripts/configure_desktop_autologin.sh" "${desktop_args[@]}"
fi

if [[ "$skip_services" -eq 0 ]]; then
  run mkdir -p "$systemd_user_dir"
  run cp "${repo_root}/systemd/noaa-navionics.service" \
         "${repo_root}/systemd/noaa-navionics.timer" \
         "${repo_root}/systemd/noaa-navionics-track.service" \
         "${repo_root}/systemd/noaa-navionics-preflight.service" \
         "$systemd_user_dir/"
  run sync_paths "$chart_service" "$chart_timer" "$track_service" "$preflight_service"
  run systemctl --user daemon-reload
  run sudo loginctl enable-linger "$USER"
  run systemctl --user reset-failed noaa-navionics-track.service noaa-navionics-preflight.service
  run systemctl --user enable --now noaa-navionics.timer
  run systemctl --user enable --now noaa-navionics-track.service
  run systemctl --user restart noaa-navionics-track.service
  run systemctl --user enable noaa-navionics-preflight.service
fi

run "$bin" status-report --config "$config" --gps-seconds "$gps_seconds" --output "$status_report"

if [[ "$dry_run" -eq 1 ]]; then
  result_label="Dry run complete; no changes were made."
else
  result_label="Provisioning complete."
fi

cat <<EOF
$result_label

Config: $config
Status report: $status_report
Start chartplotter: noaa-navionics-start-chartplotter
EOF
