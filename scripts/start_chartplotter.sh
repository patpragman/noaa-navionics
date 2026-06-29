#!/usr/bin/env bash
set -euo pipefail

config="${HOME}/.config/noaa-navionics/config.ini"
status_report="${HOME}/.cache/noaa-navionics/status.json"
bin="${HOME}/.local/bin/noaa-navionics"

if [[ ! -x "$bin" ]]; then
  echo "noaa-navionics is not installed at $bin" >&2
  exit 127
fi

mkdir -p "$(dirname "$status_report")"

if "$bin" status-report --config "$config" --output "$status_report"; then
  echo "NOAA Navionics preflight passed."
else
  echo "NOAA Navionics preflight failed. Status report: $status_report" >&2
  echo "Starting OpenCPN anyway; keep backup navigation available." >&2
  sleep 8
fi

exec opencpn -D
