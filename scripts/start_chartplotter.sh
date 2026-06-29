#!/usr/bin/env bash
set -euo pipefail

config="${HOME}/.config/noaa-navionics/config.ini"
status_report="${HOME}/.cache/noaa-navionics/status.json"
log_file="${HOME}/.cache/noaa-navionics/chartplotter.log"
max_log_bytes=$((1024 * 1024))
bin="${HOME}/.local/bin/noaa-navionics"

keep_display_awake() {
  if [[ -n "${DISPLAY:-}" ]] && command -v xset >/dev/null 2>&1; then
    xset s off >/dev/null 2>&1 || true
    xset s noblank >/dev/null 2>&1 || true
    xset -dpms >/dev/null 2>&1 || true
    echo "Requested display sleep and blanking disabled."
  elif [[ -n "${DISPLAY:-}" ]]; then
    echo "Display session found, but xset is unavailable; leaving display power settings unchanged."
  fi
}

if [[ ! -x "$bin" ]]; then
  echo "noaa-navionics is not installed at $bin" >&2
  exit 127
fi

mkdir -p "$(dirname "$status_report")"
if [[ -f "$log_file" ]]; then
  log_bytes="$(wc -c <"$log_file" 2>/dev/null || printf '0')"
  if [[ "$log_bytes" -gt "$max_log_bytes" ]]; then
    mv -f "$log_file" "${log_file}.1"
  fi
fi
exec > >(tee -a "$log_file") 2>&1

printf '\n[%s] Starting NOAA Navionics chartplotter launcher\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
keep_display_awake

if "$bin" status-report --config "$config" --gps-seconds 10 --output "$status_report"; then
  echo "NOAA Navionics preflight passed."
else
  echo "NOAA Navionics preflight failed. Status report: $status_report" >&2
  echo "Starting OpenCPN anyway; keep backup navigation available." >&2
  sleep 8
fi

if ! command -v opencpn >/dev/null 2>&1; then
  echo "OpenCPN is not installed or not on PATH; install opencpn before launching chartplotter." >&2
  exit 127
fi

echo "Launching OpenCPN with ENC processing."
exec opencpn -parse_all_enc
