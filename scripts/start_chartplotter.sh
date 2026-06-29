#!/usr/bin/env bash
set -euo pipefail

config="${HOME}/.config/noaa-navionics/config.ini"
launcher_env="${HOME}/.config/noaa-navionics/launcher.env"
status_report="${HOME}/.cache/noaa-navionics/status.json"
log_file="${HOME}/.cache/noaa-navionics/chartplotter.log"
launcher_lock_dir="${HOME}/.cache/noaa-navionics/chartplotter.launch.lock"
max_log_bytes=$((1024 * 1024))
bin="${HOME}/.local/bin/noaa-navionics"
gps_seconds=10
warning_seconds=8
lock_acquired=0

load_launcher_settings() {
  local key
  local value
  if [[ -r "$launcher_env" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        NOAA_NAVIONICS_GPS_SECONDS)
          gps_seconds="$value"
          ;;
        NOAA_NAVIONICS_WARNING_SECONDS)
          warning_seconds="$value"
          ;;
      esac
    done <"$launcher_env"
  fi
  gps_seconds="${NOAA_NAVIONICS_GPS_SECONDS:-$gps_seconds}"
  warning_seconds="${NOAA_NAVIONICS_WARNING_SECONDS:-$warning_seconds}"
  if [[ ! "$gps_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid NOAA_NAVIONICS_GPS_SECONDS=${gps_seconds}; using 10 seconds." >&2
    gps_seconds=10
  fi
  if [[ ! "$warning_seconds" =~ ^[0-9]+$ ]]; then
    echo "Invalid NOAA_NAVIONICS_WARNING_SECONDS=${warning_seconds}; using 8 seconds." >&2
    warning_seconds=8
  fi
}

keep_display_awake() {
  if [[ -n "${DISPLAY:-}" ]] && command -v xset >/dev/null 2>&1; then
    local failures=0
    xset s off >/dev/null 2>&1 || failures=$((failures + 1))
    xset s noblank >/dev/null 2>&1 || failures=$((failures + 1))
    xset -dpms >/dev/null 2>&1 || failures=$((failures + 1))
    if [[ "$failures" -eq 0 ]]; then
      echo "Requested display sleep and blanking disabled."
    else
      echo "Display session found, but ${failures} xset command(s) failed; leaving some display power settings unchanged." >&2
    fi
  elif [[ -n "${DISPLAY:-}" ]]; then
    echo "Display session found, but xset is unavailable; leaving display power settings unchanged."
  fi
  return 0
}

opencpn_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -u "$(id -u)" -x opencpn >/dev/null 2>&1
  else
    return 1
  fi
}

process_looks_like_launcher() {
  local pid="$1"
  local cmdline
  if [[ ! "$pid" =~ ^[0-9]+$ || ! -r "/proc/${pid}/cmdline" ]]; then
    return 1
  fi
  cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "$cmdline" == *"noaa-navionics-start-chartplotter"* || "$cmdline" == *"start_chartplotter.sh"* ]]
}

release_launcher_lock() {
  if [[ "$lock_acquired" -eq 1 ]]; then
    rm -f "${launcher_lock_dir}/pid"
    rmdir "$launcher_lock_dir" 2>/dev/null || true
    lock_acquired=0
  fi
}

acquire_launcher_lock() {
  local owner_pid=""
  if mkdir "$launcher_lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"${launcher_lock_dir}/pid"
    lock_acquired=1
    trap release_launcher_lock EXIT
    return 0
  fi
  if [[ -r "${launcher_lock_dir}/pid" ]]; then
    read -r owner_pid <"${launcher_lock_dir}/pid" || owner_pid=""
  fi
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null && process_looks_like_launcher "$owner_pid"; then
    if opencpn_running; then
      echo "OpenCPN is already running; leaving the existing chartplotter instance in place."
    else
      echo "Another NOAA Navionics chartplotter launcher is already running; leaving it in charge."
    fi
    exit 0
  fi
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    echo "Launcher lock PID ${owner_pid} is not a chartplotter launcher; treating lock as stale."
  fi
  echo "Removing stale chartplotter launcher lock."
  rm -rf "$launcher_lock_dir"
  if mkdir "$launcher_lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"${launcher_lock_dir}/pid"
    lock_acquired=1
    trap release_launcher_lock EXIT
    return 0
  fi
  echo "Could not acquire chartplotter launcher lock; leaving any active launcher in charge." >&2
  exit 0
}

show_preflight_warning() {
  if [[ "$warning_seconds" -eq 0 ]]; then
    echo "Readiness warning timeout is 0 seconds; continuing immediately."
    return 0
  fi
  if [[ -z "${DISPLAY:-}" ]]; then
    echo "No display session found for readiness warning; waiting ${warning_seconds}s before OpenCPN."
    sleep "$warning_seconds"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is unavailable for readiness warning; waiting ${warning_seconds}s before OpenCPN." >&2
    sleep "$warning_seconds"
    return 0
  fi
  if python3 - "$status_report" "$warning_seconds" <<'PY'
from pathlib import Path
import json
import sys
import tkinter as tk

status_report = Path(sys.argv[1]).expanduser()
seconds = int(sys.argv[2])

def failed_checks(path):
    try:
        with path.open(encoding="utf-8") as handle:
            report = json.load(handle)
    except Exception:
        return []
    failed = []
    for section in ("checks", "service_checks"):
        rows = report.get(section, [])
        if not isinstance(rows, list):
            continue
        for row in rows:
            if not isinstance(row, dict) or row.get("ok") is True:
                continue
            name = str(row.get("name", "Check")).strip() or "Check"
            detail = str(row.get("detail", "")).strip()
            failed.append(f"{name}: {detail}" if detail else name)
    return failed

failures = failed_checks(status_report)
if failures:
    visible = failures[:6]
    extra = len(failures) - len(visible)
    failure_text = "Failed checks:\n" + "\n".join(f"- {item}" for item in visible)
    if extra > 0:
        failure_text += f"\n- and {extra} more"
else:
    failure_text = "Failed checks could not be read from the status report."

root = tk.Tk()
root.title("NOAA Navionics Readiness")
root.attributes("-topmost", True)
root.resizable(False, False)
message = (
    "NOAA Navionics readiness failed.\n\n"
    f"{failure_text}\n\n"
    f"Status report:\n{status_report}\n\n"
    "OpenCPN will start anyway. Keep backup navigation available."
)
frame = tk.Frame(root, padx=24, pady=20)
frame.pack(fill="both", expand=True)
label = tk.Label(frame, text=message, justify="left", wraplength=520)
label.pack(pady=(0, 16))
button = tk.Button(frame, text="Start OpenCPN", command=root.destroy)
button.pack()
root.after(seconds * 1000, root.destroy)
root.mainloop()
PY
  then
    echo "Readiness warning displayed for ${warning_seconds}s."
  else
    echo "Readiness warning dialog unavailable; waiting ${warning_seconds}s before OpenCPN." >&2
    sleep "$warning_seconds"
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
acquire_launcher_lock
load_launcher_settings
keep_display_awake

if "$bin" status-report --config "$config" --gps-seconds "$gps_seconds" --output "$status_report"; then
  echo "NOAA Navionics preflight passed."
else
  echo "NOAA Navionics preflight failed. Status report: $status_report" >&2
  echo "Starting OpenCPN anyway; keep backup navigation available." >&2
  show_preflight_warning
fi

if ! command -v opencpn >/dev/null 2>&1; then
  echo "OpenCPN is not installed or not on PATH; install opencpn before launching chartplotter." >&2
  exit 127
fi

if opencpn_running; then
  echo "OpenCPN is already running; leaving the existing chartplotter instance in place."
  exit 0
fi

echo "Launching OpenCPN with ENC processing."
opencpn -parse_all_enc &
opencpn_pid=$!
for _ in 1 2 3 4 5; do
  if opencpn_running || ! kill -0 "$opencpn_pid" 2>/dev/null; then
    break
  fi
  sleep 1
done
release_launcher_lock
trap - EXIT
set +e
wait "$opencpn_pid"
opencpn_status=$?
set -e
printf '[%s] OpenCPN exited with status %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$opencpn_status"
exit "$opencpn_status"
