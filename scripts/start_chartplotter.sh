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
readiness_attempts=3
readiness_retry_delay=10
start_on_failed_readiness=0
lock_acquired=0

sync_paths() {
  python3 - "$@" <<'PY'
from pathlib import Path
import os
import sys

synced_dirs = set()
for arg in sys.argv[1:]:
    path = Path(arg).expanduser()
    if path.is_dir():
        synced_dirs.add(path)
        synced_dirs.add(path.parent)
        continue
    try:
        with path.open("rb") as handle:
            os.fsync(handle.fileno())
    except OSError:
        synced_dirs.add(path.parent)
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

load_launcher_settings() {
  local key
  local value
  local start_on_failed_text
  if [[ -r "$launcher_env" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        NOAA_NAVIONICS_GPS_SECONDS)
          gps_seconds="$value"
          ;;
        NOAA_NAVIONICS_WARNING_SECONDS)
          warning_seconds="$value"
          ;;
        NOAA_NAVIONICS_READINESS_ATTEMPTS)
          readiness_attempts="$value"
          ;;
        NOAA_NAVIONICS_READINESS_RETRY_DELAY)
          readiness_retry_delay="$value"
          ;;
        NOAA_NAVIONICS_START_ON_FAILED_READINESS)
          start_on_failed_text="$value"
          ;;
      esac
    done <"$launcher_env"
  fi
  gps_seconds="${NOAA_NAVIONICS_GPS_SECONDS:-$gps_seconds}"
  warning_seconds="${NOAA_NAVIONICS_WARNING_SECONDS:-$warning_seconds}"
  readiness_attempts="${NOAA_NAVIONICS_READINESS_ATTEMPTS:-$readiness_attempts}"
  readiness_retry_delay="${NOAA_NAVIONICS_READINESS_RETRY_DELAY:-$readiness_retry_delay}"
  start_on_failed_text="${NOAA_NAVIONICS_START_ON_FAILED_READINESS:-${start_on_failed_text:-no}}"
  if [[ ! "$gps_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid NOAA_NAVIONICS_GPS_SECONDS=${gps_seconds}; using 10 seconds." >&2
    gps_seconds=10
  fi
  if [[ ! "$warning_seconds" =~ ^[0-9]+$ ]]; then
    echo "Invalid NOAA_NAVIONICS_WARNING_SECONDS=${warning_seconds}; using 8 seconds." >&2
    warning_seconds=8
  fi
  if [[ ! "$readiness_attempts" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid NOAA_NAVIONICS_READINESS_ATTEMPTS=${readiness_attempts}; using 3 attempts." >&2
    readiness_attempts=3
  fi
  if [[ ! "$readiness_retry_delay" =~ ^[0-9]+$ ]]; then
    echo "Invalid NOAA_NAVIONICS_READINESS_RETRY_DELAY=${readiness_retry_delay}; using 10 seconds." >&2
    readiness_retry_delay=10
  fi
  case "${start_on_failed_text,,}" in
    1|yes|true|on)
      start_on_failed_readiness=1
      ;;
    0|no|false|off)
      start_on_failed_readiness=0
      ;;
    *)
      echo "Invalid NOAA_NAVIONICS_START_ON_FAILED_READINESS=${start_on_failed_text}; using no." >&2
      start_on_failed_readiness=0
      ;;
  esac
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
    sync_paths "$launcher_lock_dir" || true
    lock_acquired=0
  fi
}

acquire_launcher_lock() {
  local owner_pid=""
  if mkdir "$launcher_lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"${launcher_lock_dir}/pid"
    sync_paths "${launcher_lock_dir}/pid" "$launcher_lock_dir" || true
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
  sync_paths "$launcher_lock_dir" || true
  if mkdir "$launcher_lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"${launcher_lock_dir}/pid"
    sync_paths "${launcher_lock_dir}/pid" "$launcher_lock_dir" || true
    lock_acquired=1
    trap release_launcher_lock EXIT
    return 0
  fi
  echo "Could not acquire chartplotter launcher lock; leaving any active launcher in charge." >&2
  exit 0
}

show_preflight_warning() {
  local action_text
  if [[ "$start_on_failed_readiness" -eq 1 ]]; then
    action_text="OpenCPN will start anyway. Keep backup navigation available."
  else
    action_text="OpenCPN will not start automatically. Keep backup navigation available and fix readiness before departure."
  fi
  if [[ "$warning_seconds" -eq 0 ]]; then
    echo "Readiness warning timeout is 0 seconds; continuing immediately."
    return 0
  fi
  if [[ -z "${DISPLAY:-}" ]]; then
    echo "No display session found for readiness warning; waiting ${warning_seconds}s before continuing."
    sleep "$warning_seconds"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is unavailable for readiness warning; waiting ${warning_seconds}s before continuing." >&2
    sleep "$warning_seconds"
    return 0
  fi
  if python3 - "$status_report" "$warning_seconds" "$action_text" <<'PY'
from pathlib import Path
import json
import sys
import tkinter as tk

status_report = Path(sys.argv[1]).expanduser()
seconds = int(sys.argv[2])
action_text = sys.argv[3]

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
    f"{action_text}"
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
    echo "Readiness warning dialog unavailable; waiting ${warning_seconds}s before continuing." >&2
    sleep "$warning_seconds"
  fi
}

run_readiness_report() {
  local attempt=1
  while [[ "$attempt" -le "$readiness_attempts" ]]; do
    if "$bin" status-report --config "$config" --gps-seconds "$gps_seconds" --output "$status_report"; then
      if [[ "$attempt" -eq 1 ]]; then
        echo "NOAA Navionics preflight passed."
      else
        echo "NOAA Navionics preflight passed on attempt ${attempt}/${readiness_attempts}."
      fi
      return 0
    fi
    echo "NOAA Navionics preflight failed on attempt ${attempt}/${readiness_attempts}. Status report: $status_report" >&2
    if [[ "$attempt" -lt "$readiness_attempts" ]]; then
      echo "Retrying readiness in ${readiness_retry_delay}s." >&2
      sleep "$readiness_retry_delay"
    fi
    attempt=$((attempt + 1))
  done
  return 1
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
    sync_paths "${log_file}.1" || true
  fi
fi
exec > >(tee -a "$log_file") 2>&1

printf '\n[%s] Starting NOAA Navionics chartplotter launcher\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
acquire_launcher_lock
load_launcher_settings
keep_display_awake

if ! run_readiness_report; then
  echo "NOAA Navionics readiness failed after ${readiness_attempts} attempt(s). Status report: $status_report" >&2
  show_preflight_warning
  if [[ "$start_on_failed_readiness" -ne 1 ]]; then
    echo "Not starting OpenCPN automatically because readiness failed." >&2
    exit 1
  fi
  echo "Starting OpenCPN despite failed readiness because NOAA_NAVIONICS_START_ON_FAILED_READINESS is enabled." >&2
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
set +e
wait "$opencpn_pid"
opencpn_status=$?
set -e
printf '[%s] OpenCPN exited with status %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$opencpn_status"
exit "$opencpn_status"
