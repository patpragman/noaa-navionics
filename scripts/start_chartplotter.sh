#!/usr/bin/env bash
set -euo pipefail
umask 077

config="${HOME}/.config/noaa-navionics/config.ini"
launcher_env="${HOME}/.config/noaa-navionics/launcher.env"
status_report="${HOME}/.cache/noaa-navionics/status.json"
log_file="${HOME}/.cache/noaa-navionics/chartplotter.log"
launcher_lock_dir="${HOME}/.cache/noaa-navionics/chartplotter.launch.lock"
cache_dir="$(dirname "$status_report")"
max_log_bytes=$((1024 * 1024))
bin="${HOME}/.local/bin/noaa-navionics"
gps_seconds=60
warning_seconds=8
readiness_attempts=3
readiness_retry_delay=10
start_on_failed_readiness=0
opencpn_restarts=3
opencpn_restart_delay=5
lock_acquired=0

reexec_without_ambient_launcher_settings() {
  local key
  local removed=0
  local env_args=()
  while IFS='=' read -r key _; do
    case "$key" in
      NOAA_NAVIONICS_*)
        env_args+=("-u" "$key")
        removed=$((removed + 1))
        ;;
    esac
  done < <(env)
  if [[ "$removed" -gt 0 ]]; then
    exec env "${env_args[@]}" "$0" "$@"
  fi
}

first_symlink_ancestor() {
  local path="$1"
  local current

  current="$path"
  while [[ -n "$current" && "$current" != "." ]]; do
    if [[ -L "$current" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    if [[ "$current" == "/" ]]; then
      return 1
    fi
    current="$(dirname "$current")"
  done
  return 1
}

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

prepare_private_cache_dir() {
  local cache_parent
  local symlink_component
  cache_parent="$(dirname "$cache_dir")"
  if [[ -L "$cache_parent" ]]; then
    echo "NOAA Navionics cache parent directory is a symlink: $cache_parent" >&2
    exit 1
  fi
  if symlink_component="$(first_symlink_ancestor "$(dirname "$cache_parent")")"; then
    echo "NOAA Navionics cache path contains a symlink: $symlink_component" >&2
    exit 1
  fi
  if [[ -L "$cache_dir" ]]; then
    echo "NOAA Navionics cache directory is a symlink: $cache_dir" >&2
    exit 1
  fi
  mkdir -p "$cache_dir"
  chmod 0700 "$cache_dir"
  sync_paths "$cache_dir" || true
}

prepare_private_log_file() {
  if [[ -L "$log_file" ]]; then
    echo "NOAA Navionics launcher log is a symlink: $log_file" >&2
    exit 1
  fi
  if [[ -e "$log_file" && ! -f "$log_file" ]]; then
    echo "NOAA Navionics launcher log is not a regular file: $log_file" >&2
    exit 1
  fi
  : >>"$log_file"
  chmod 0600 "$log_file"
  sync_paths "$log_file" || true
}

load_launcher_settings() {
  local key
  local raw_line
  local trimmed
  local value
  local start_on_failed_text
  if [[ -r "$launcher_env" ]]; then
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
      trimmed="${raw_line#"${raw_line%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      if [[ -z "$trimmed" || "$trimmed" == \#* ]]; then
        continue
      fi
      if [[ "$trimmed" != *=* ]]; then
        echo "Malformed launcher environment line in $launcher_env: $raw_line" >&2
        return 1
      fi
      key="${trimmed%%=*}"
      value="${trimmed#*=}"
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
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
        NOAA_NAVIONICS_OPENCPN_RESTARTS)
          opencpn_restarts="$value"
          ;;
        NOAA_NAVIONICS_OPENCPN_RESTART_DELAY)
          opencpn_restart_delay="$value"
          ;;
        *)
          echo "Unknown launcher environment key in $launcher_env: $key" >&2
          return 1
          ;;
      esac
    done <"$launcher_env"
  fi
  start_on_failed_text="${start_on_failed_text:-no}"
  if [[ ! "$gps_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid NOAA_NAVIONICS_GPS_SECONDS=${gps_seconds}; using 60 seconds." >&2
    gps_seconds=60
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
  if [[ ! "$opencpn_restarts" =~ ^[0-9]+$ ]]; then
    echo "Invalid NOAA_NAVIONICS_OPENCPN_RESTARTS=${opencpn_restarts}; using 3 restarts." >&2
    opencpn_restarts=3
  fi
  if [[ ! "$opencpn_restart_delay" =~ ^[0-9]+$ ]]; then
    echo "Invalid NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=${opencpn_restart_delay}; using 5 seconds." >&2
    opencpn_restart_delay=5
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

validate_launcher_env_path() {
  local launcher_env_dir
  local env_stat
  local env_uid
  local env_mode
  local symlink_component
  launcher_env_dir="$(dirname "$launcher_env")"
  if [[ -L "$launcher_env_dir" ]]; then
    echo "NOAA Navionics launcher environment directory is a symlink: $launcher_env_dir" >&2
    exit 1
  fi
  if symlink_component="$(first_symlink_ancestor "$(dirname "$launcher_env_dir")")"; then
    echo "NOAA Navionics launcher environment path contains a symlink: $symlink_component" >&2
    exit 1
  fi
  if [[ ! -e "$launcher_env" ]]; then
    return 0
  fi
  if [[ -L "$launcher_env" ]]; then
    echo "NOAA Navionics launcher environment is a symlink: $launcher_env" >&2
    exit 1
  fi
  if [[ ! -f "$launcher_env" ]]; then
    echo "NOAA Navionics launcher environment is not a regular file: $launcher_env" >&2
    exit 1
  fi
  env_stat="$(stat -c '%u %a' "$launcher_env" 2>/dev/null || true)"
  if [[ -z "$env_stat" ]]; then
    echo "Could not inspect NOAA Navionics launcher environment: $launcher_env" >&2
    exit 1
  fi
  read -r env_uid env_mode <<<"$env_stat"
  if [[ "$env_uid" != "$(id -u)" ]]; then
    echo "NOAA Navionics launcher environment is owned by uid ${env_uid}, expected $(id -u): $launcher_env" >&2
    exit 1
  fi
  if [[ "$env_mode" != "600" && "$env_mode" != "0600" ]]; then
    echo "NOAA Navionics launcher environment has permissions ${env_mode}, expected private 0600: $launcher_env" >&2
    exit 1
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
  local pid
  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r pid; do
      if opencpn_process_active "$pid"; then
        return 0
      fi
    done < <(pgrep -u "$(id -u)" -x opencpn 2>/dev/null || true)
  fi
  return 1
}

opencpn_process_active() {
  local pid="$1"
  local stat_line
  local state
  if [[ ! "$pid" =~ ^[0-9]+$ || ! -r "/proc/${pid}/stat" ]]; then
    return 1
  fi
  stat_line="$(cat "/proc/${pid}/stat" 2>/dev/null || true)"
  state="${stat_line##*) }"
  state="${state%% *}"
  [[ -n "$state" && "$state" != "Z" ]]
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

current_boot_id() {
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    head -n 1 /proc/sys/kernel/random/boot_id 2>/dev/null || true
  fi
}

validate_launcher_lock_path() {
  if [[ -L "$cache_dir" || -L "$launcher_lock_dir" || -L "${launcher_lock_dir}/pid" || -L "${launcher_lock_dir}/boot_id" ]]; then
    echo "chartplotter launcher lock path contains a symlink: $launcher_lock_dir" >&2
    exit 1
  fi
  if [[ -e "$launcher_lock_dir" && ! -d "$launcher_lock_dir" ]]; then
    echo "chartplotter launcher lock path is not a directory: $launcher_lock_dir" >&2
    exit 1
  fi
}

launcher_lock_path_safe_for_cleanup() {
  if [[ -L "$cache_dir" || -L "$launcher_lock_dir" || -L "${launcher_lock_dir}/pid" || -L "${launcher_lock_dir}/boot_id" ]]; then
    echo "chartplotter launcher lock path became unsafe; leaving it in place: $launcher_lock_dir" >&2
    return 1
  fi
  if [[ -e "$launcher_lock_dir" && ! -d "$launcher_lock_dir" ]]; then
    echo "chartplotter launcher lock path is no longer a directory; leaving it in place: $launcher_lock_dir" >&2
    return 1
  fi
  return 0
}

launcher_lock_from_current_boot() {
  local current
  local lock_boot_id=""
  current="$(current_boot_id)"
  if [[ -z "$current" || ! -r "${launcher_lock_dir}/boot_id" ]]; then
    return 0
  fi
  read -r lock_boot_id <"${launcher_lock_dir}/boot_id" || lock_boot_id=""
  [[ "$lock_boot_id" == "$current" ]]
}

write_launcher_lock_files() {
  local boot_id
  printf '%s\n' "$$" >"${launcher_lock_dir}/pid"
  chmod 0600 "${launcher_lock_dir}/pid"
  boot_id="$(current_boot_id)"
  if [[ -n "$boot_id" ]]; then
    printf '%s\n' "$boot_id" >"${launcher_lock_dir}/boot_id"
    chmod 0600 "${launcher_lock_dir}/boot_id"
  else
    rm -f "${launcher_lock_dir}/boot_id"
  fi
  sync_paths "${launcher_lock_dir}/pid" "${launcher_lock_dir}/boot_id" "$launcher_lock_dir" || true
}

release_launcher_lock() {
  if [[ "$lock_acquired" -eq 1 ]]; then
    if ! launcher_lock_path_safe_for_cleanup; then
      lock_acquired=0
      return
    fi
    rm -f "${launcher_lock_dir}/pid" "${launcher_lock_dir}/boot_id"
    rmdir "$launcher_lock_dir" 2>/dev/null || true
    sync_paths "$launcher_lock_dir" || true
    lock_acquired=0
  fi
}

acquire_launcher_lock() {
  local owner_pid=""
  validate_launcher_lock_path
  if mkdir "$launcher_lock_dir" 2>/dev/null; then
    chmod 0700 "$launcher_lock_dir"
    write_launcher_lock_files
    lock_acquired=1
    trap release_launcher_lock EXIT
    return 0
  fi
  if ! launcher_lock_from_current_boot; then
    echo "Launcher lock is from a previous boot; treating lock as stale."
  else
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
  fi
  echo "Removing stale chartplotter launcher lock."
  if ! launcher_lock_path_safe_for_cleanup; then
    exit 1
  fi
  rm -rf "$launcher_lock_dir"
  sync_paths "$launcher_lock_dir" || true
  if mkdir "$launcher_lock_dir" 2>/dev/null; then
    chmod 0700 "$launcher_lock_dir"
    write_launcher_lock_files
    lock_acquired=1
    trap release_launcher_lock EXIT
    return 0
  fi
  echo "Could not acquire chartplotter launcher lock; leaving any active launcher in charge." >&2
  exit 0
}

show_preflight_warning() {
  local action_text
  local button_text
  if [[ "$start_on_failed_readiness" -eq 1 ]]; then
    action_text="OpenCPN will start anyway. Keep backup navigation available."
    button_text="Start OpenCPN"
  else
    action_text="OpenCPN will not start automatically. Keep backup navigation available and fix readiness before departure."
    button_text="Dismiss"
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
  if python3 - "$status_report" "$warning_seconds" "$action_text" "$button_text" <<'PY'
from pathlib import Path
import json
import sys
import tkinter as tk

status_report = Path(sys.argv[1]).expanduser()
seconds = int(sys.argv[2])
action_text = sys.argv[3]
button_text = sys.argv[4]

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
button = tk.Button(frame, text=button_text, command=root.destroy)
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

run_opencpn_supervised() {
  local restart_count=0
  local opencpn_pid
  local opencpn_status
  while true; do
    if opencpn_running; then
      echo "OpenCPN is already running; leaving the existing chartplotter instance in place."
      return 0
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
    if [[ "$opencpn_status" -eq 0 ]]; then
      echo "OpenCPN exited cleanly; not restarting."
      return 0
    fi
    if [[ "$restart_count" -ge "$opencpn_restarts" ]]; then
      echo "OpenCPN exited with status ${opencpn_status} after ${restart_count} restart(s); no restart attempts remain." >&2
      return "$opencpn_status"
    fi
    restart_count=$((restart_count + 1))
    echo "Restarting OpenCPN after nonzero exit status ${opencpn_status} (restart ${restart_count}/${opencpn_restarts}) in ${opencpn_restart_delay}s." >&2
    sleep "$opencpn_restart_delay"
  done
}

reexec_without_ambient_launcher_settings "$@"

if [[ ! -x "$bin" ]]; then
  echo "noaa-navionics is not installed at $bin" >&2
  exit 127
fi

prepare_private_cache_dir
if [[ -L "$log_file" ]]; then
  echo "NOAA Navionics launcher log is a symlink: $log_file" >&2
  exit 1
fi
if [[ -e "$log_file" && ! -f "$log_file" ]]; then
  echo "NOAA Navionics launcher log is not a regular file: $log_file" >&2
  exit 1
fi
if [[ -f "$log_file" ]]; then
  log_bytes="$(wc -c <"$log_file" 2>/dev/null || printf '0')"
  if [[ "$log_bytes" -gt "$max_log_bytes" ]]; then
    if [[ -L "${log_file}.1" ]]; then
      echo "NOAA Navionics rotated launcher log is a symlink: ${log_file}.1" >&2
      exit 1
    fi
    if [[ -e "${log_file}.1" && ! -f "${log_file}.1" ]]; then
      echo "NOAA Navionics rotated launcher log is not a regular file: ${log_file}.1" >&2
      exit 1
    fi
    mv -f "$log_file" "${log_file}.1"
    chmod 0600 "${log_file}.1"
    sync_paths "${log_file}.1" || true
  fi
fi
prepare_private_log_file
exec > >(tee -a "$log_file") 2>&1

printf '\n[%s] Starting NOAA Navionics chartplotter launcher\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
acquire_launcher_lock
validate_launcher_env_path
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

run_opencpn_supervised
