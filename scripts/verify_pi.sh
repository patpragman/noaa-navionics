#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify_pi.sh [--require-chartplotter-started] [--gps-seconds N] [--opencpn-restarts N] [--opencpn-restart-delay N] [--expected-gps-device PATH] [--expected-boot-id ID] [--allow-dirty] user@raspberrypi.local

Runs onboard verification on the Raspberry Pi over SSH.
With --require-chartplotter-started, also requires a post-boot launcher log
and a running OpenCPN process.
Use --gps-seconds to allow a longer GPS fix wait during the status report.
Use --opencpn-restarts and --opencpn-restart-delay to assert the persisted
OpenCPN supervision policy.
Use --expected-gps-device to assert GPSD and the onboard config use a specific receiver.
Use --expected-boot-id after reboot to assert verification ran against that boot.
Use --allow-dirty only for deliberate test deployments recorded with a -dirty suffix.
Nothing is installed or enabled on the local computer.
EOF
}

target=""
allow_dirty=0
require_chartplotter_started=0
gps_seconds=60
opencpn_restarts=3
opencpn_restart_delay=5
expected_gps_device=""
expected_boot_id=""
ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)

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
  check_local_directory_chain "$command_path"
  check_local_directory_chain "$resolved_path"
  check_local_owner_and_mode file "$resolved_path"
}

validate_ssh_target() {
  local value="$1"
  local user_part
  local host_part

  if [[ -z "$value" ]]; then
    usage
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
  if [[ "$host_part" == *:* || "$host_part" == */* ]]; then
    echo "SSH target must be plain user@host without paths or ports: $value" >&2
    exit 2
  fi
  if [[ "$user_part" == "root" ]]; then
    cat >&2 <<'EOF'
Do not verify root@.
Verify the Pi desktop user so autologin, user services, charts, and tracks are checked for the real helm account.
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

validate_boot_id_arg() {
  local value="$1"
  if [[ -z "$value" ]]; then
    echo "boot ID is required" >&2
    exit 2
  fi
  if [[ ! "$value" =~ ^[0-9a-fA-F-]{32,40}$ ]]; then
    echo "boot ID must be the Linux boot_id value from /proc/sys/kernel/random/boot_id: $value" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-chartplotter-started)
      require_chartplotter_started=1
      shift
      ;;
    --allow-dirty)
      allow_dirty=1
      shift
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
    --opencpn-restarts)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      opencpn_restarts="${2:-}"
      shift 2
      ;;
    --opencpn-restart-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      opencpn_restart_delay="${2:-}"
      shift 2
      ;;
    --expected-gps-device)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      validate_gps_device_path_arg "${2:-}"
      expected_gps_device="${2:-}"
      shift 2
      ;;
    --expected-boot-id)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      validate_boot_id_arg "${2:-}"
      expected_boot_id="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$target" ]]; then
        echo "Unexpected extra argument: $1" >&2
        usage
        exit 2
      fi
      target="$1"
      shift
      ;;
  esac
done

validate_ssh_target "$target"
require_local_command ssh

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
require_local_command git
expected_revision="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
worktree_status="$(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null || true)"
if [[ "$expected_revision" != "unknown" && -n "$worktree_status" ]]; then
  if [[ "$allow_dirty" -eq 0 ]]; then
    cat >&2 <<EOF
Refusing to verify a dirty local worktree as production evidence.
Commit or stash local changes first, or pass --allow-dirty only for a deliberate test deployment recorded as ${expected_revision}-dirty.
EOF
    exit 2
  fi
  expected_revision="${expected_revision}-dirty"
fi
expected_revision_quoted="$(printf '%q' "$expected_revision")"
require_chartplotter_started_quoted="$(printf '%q' "$require_chartplotter_started")"
gps_seconds_quoted="$(printf '%q' "$gps_seconds")"
opencpn_restarts_quoted="$(printf '%q' "$opencpn_restarts")"
opencpn_restart_delay_quoted="$(printf '%q' "$opencpn_restart_delay")"
expected_gps_device_quoted="$(printf '%q' "$expected_gps_device")"
expected_boot_id_quoted="$(printf '%q' "$expected_boot_id")"

ssh -T "${ssh_batch_options[@]}" "$target" "NOAA_NAVIONICS_EXPECTED_REVISION=${expected_revision_quoted} NOAA_NAVIONICS_REQUIRE_CHARTPLOTTER_STARTED=${require_chartplotter_started_quoted} NOAA_NAVIONICS_GPS_SECONDS=${gps_seconds_quoted} NOAA_NAVIONICS_OPENCPN_RESTARTS=${opencpn_restarts_quoted} NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=${opencpn_restart_delay_quoted} NOAA_NAVIONICS_EXPECTED_GPS_DEVICE=${expected_gps_device_quoted} NOAA_NAVIONICS_EXPECTED_BOOT_ID=${expected_boot_id_quoted} bash -s" <<'REMOTE'
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

failures=0
bin_dir="${HOME}/.local/bin"
data_dir="${HOME}/.local/share/noaa-navionics"
config_dir="${HOME}/.config/noaa-navionics"
autostart_dir="${HOME}/.config/autostart"
systemd_user_dir="${HOME}/.config/systemd/user"
config="${HOME}/.config/noaa-navionics/config.ini"
bin="${HOME}/.local/bin/noaa-navionics"
gui_bin="${HOME}/.local/bin/noaa-navionics-gui"
launcher="${HOME}/.local/bin/noaa-navionics-start-chartplotter"
desktop_autologin="${HOME}/.local/bin/noaa-navionics-configure-desktop-autologin"
gps_time_helper="${HOME}/.local/bin/noaa-navionics-configure-gps-time"
autostart="${HOME}/.config/autostart/noaa-navionics-chartplotter.desktop"
lightdm_autologin="/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf"
status_report="${HOME}/.cache/noaa-navionics/status.json"
log_file="${HOME}/.cache/noaa-navionics/chartplotter.log"
rotated_log_file="${log_file}.1"
launcher_lock="${HOME}/.cache/noaa-navionics/chartplotter.launch.lock"
venv_dir="${HOME}/.local/share/noaa-navionics/venv"
revision_file="${HOME}/.local/share/noaa-navionics/source-revision"
launcher_env="${HOME}/.config/noaa-navionics/launcher.env"
status_attempts=3
status_retry_delay=30
require_chartplotter_started="${NOAA_NAVIONICS_REQUIRE_CHARTPLOTTER_STARTED:-0}"
gps_seconds="${NOAA_NAVIONICS_GPS_SECONDS:-60}"
chartplotter_start_timeout=120
chartplotter_start_timeout_floor=120
chartplotter_start_interval=5
opencpn_stability_seconds=10

check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'OK   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    failures=$((failures + 1))
  fi
}

check_output() {
  local name="$1"
  shift
  printf '\n[%s]\n' "$name"
  if "$@"; then
    printf 'OK   %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    failures=$((failures + 1))
  fi
}

check_not_root_user() {
  [[ "$(id -u)" -ne 0 && "$USER" != "root" ]]
}

check_status_report_json() {
  local path="$1"
  local require_current_boot="${2:-0}"
  local expected_config_path="${3:-}"
  local expected_launcher_env_path="${4:-}"
  python3 - "$path" "$require_current_boot" "$expected_config_path" "$expected_launcher_env_path" <<'PY'
from pathlib import Path
from configparser import ConfigParser
from datetime import datetime, timezone
from urllib.parse import urlparse
import hashlib
import json
import math
import os
import re
import sys

def config_bool(parser, section, key, fallback):
    value = parser.get(section, key, fallback=fallback).strip().lower()
    if value in {"1", "yes", "true", "on"}:
        return True
    if value in {"0", "no", "false", "off"}:
        return False
    raise SystemExit(f"{section}.{key} is not a boolean value: {value}")

def expected_package_filename(package, value):
    package = package.strip().lower()
    value = value.strip()
    if package == "state":
        return f"{value.upper()}_ENCs.zip"
    if package == "cgd":
        code = value.upper().replace("CGD", "")
        return f"{int(code):02d}CGD_ENCs.zip"
    if package == "region":
        code = value.upper().replace("REGION", "")
        return f"{int(code):02d}Region_ENCs.zip"
    if package == "chart":
        return f"{value.upper()}.zip"
    if package == "all":
        return "All_ENCs.zip"
    return ""

def expected_package_url(package, value):
    filename = expected_package_filename(package, value)
    return f"https://www.charts.noaa.gov/ENCs/{filename}" if filename else ""

def download_url_matches_package(download_url, package_url):
    if download_url == package_url:
        return True
    parsed_download = urlparse(download_url)
    parsed_package = urlparse(package_url)
    if parsed_download.scheme.lower() != "https":
        return False
    download_filename = Path(parsed_download.path).name
    package_filename = Path(parsed_package.path).name
    return bool(download_filename and package_filename and download_filename == package_filename)

def parse_manifest_int(value, field, source):
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"status report manifest {field} is invalid in {source}: {value!r}") from exc

def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).expanduser().open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def count_enc_cells(path):
    root = Path(path).expanduser()
    if not root.exists():
        return 0
    return sum(1 for _ in root.rglob("*.000"))

def normalize_path(value):
    return str(Path(value).expanduser().resolve(strict=False))

def first_symlink_ancestor(path):
    current = Path(path).expanduser()
    for candidate in [current, *current.parents]:
        if candidate.is_symlink():
            return candidate
    return None

def normalize_host(value):
    value = value.strip().lower()
    return "127.0.0.1" if value == "localhost" else value

def parse_opencpn_config(path):
    try:
        text = Path(path).expanduser().read_text(encoding="utf-8", errors="ignore")
    except OSError as exc:
        raise SystemExit(f"could not read OpenCPN config {path}: {exc}") from exc
    section = ""
    chart_directories = []
    data_connections = []
    for raw_line in text.splitlines():
        section_match = re.match(r"^\s*\[([^\]]+)\]\s*$", raw_line)
        if section_match:
            section = section_match.group(1).strip().lower()
            continue
        if section == "chartdirectories":
            chart_match = re.match(r"^\s*ChartDir\d+\s*=\s*(.*?)\s*$", raw_line)
            if chart_match:
                chart_directories.append(normalize_path(chart_match.group(1).strip()))
        elif section == "settings/nmeadatasource":
            data_match = re.match(r"^\s*DataConnections\s*=\s*(.*?)\s*$", raw_line)
            if data_match:
                data_connections = [part for part in data_match.group(1).strip().split("|") if part]
    return chart_directories, data_connections

def gpsd_connection_present(data_connections, host, port):
    expected_host = normalize_host(host)
    for connection in data_connections:
        fields = connection.split(";")
        if len(fields) < 18:
            continue
        if fields[0] != "1" or fields[1] != "2":
            continue
        try:
            configured_port = int(fields[3])
        except ValueError:
            continue
        if normalize_host(fields[2]) == expected_host and configured_port == port and fields[17] == "1":
            return True
    return False

def parse_key_value_file(path, comment_prefixes):
    try:
        text = Path(path).expanduser().read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"could not read {path}: {exc}") from exc
    sections = []
    values = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(comment_prefixes):
            continue
        if line.startswith("[") and line.endswith("]"):
            sections.append(line[1:-1].strip())
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return sections, values

def verify_status_file_owner_and_mode(summary, path, stat_result, label, expected_uid):
    status_uid = summary.get("uid")
    if status_uid is None:
        raise SystemExit(f"status report {label} has no uid: {path}")
    try:
        parsed_uid = int(status_uid)
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"status report {label} uid is invalid: {status_uid!r}") from exc
    if parsed_uid != stat_result.st_uid:
        raise SystemExit(
            f"status report {label} uid {parsed_uid} does not match live owner "
            f"{stat_result.st_uid}: {path}"
        )
    if stat_result.st_uid != expected_uid:
        raise SystemExit(
            f"status report {label} {path} is owned by uid {stat_result.st_uid}, expected {expected_uid}"
        )
    live_mode = stat_result.st_mode & 0o777
    status_mode = str(summary.get("mode", "")).strip()
    if not status_mode:
        raise SystemExit(f"status report {label} has no mode: {path}")
    if status_mode != f"{live_mode:04o}":
        raise SystemExit(
            f"status report {label} mode {status_mode} does not match live permissions "
            f"{live_mode:04o}: {path}"
        )
    if live_mode & 0o022:
        raise SystemExit(
            f"status report {label} {path} has permissions {live_mode:04o}, "
            "expected no group/other write bits"
        )

path = sys.argv[1]
require_current_boot = sys.argv[2] == "1"
expected_config_path = sys.argv[3]
expected_launcher_env_path = sys.argv[4]
require_track_disk_check = False
status_path = Path(path).expanduser()
if status_path.is_symlink():
    raise SystemExit(f"status report is a symlink: {status_path}")
if not status_path.is_file():
    raise SystemExit(f"status report is not a regular file: {status_path}")
try:
    status_stat = status_path.stat()
except OSError as exc:
    raise SystemExit(f"could not inspect status report {status_path}: {exc}") from exc
if status_stat.st_uid != os.getuid():
    raise SystemExit(
        f"status report {status_path} is owned by uid {status_stat.st_uid}, expected {os.getuid()}"
    )
status_mode = status_stat.st_mode & 0o777
if status_mode != 0o600:
    raise SystemExit(
        f"status report {status_path} has permissions {status_mode:04o}, expected private 0600"
    )
cache_dir = status_path.parent
if cache_dir.is_symlink():
    raise SystemExit(f"status report cache directory is a symlink: {cache_dir}")
if cache_dir.parent.is_symlink():
    raise SystemExit(f"status report cache parent directory is a symlink: {cache_dir.parent}")
if not cache_dir.is_dir():
    raise SystemExit(f"status report cache directory is not a directory: {cache_dir}")
try:
    cache_parent_stat = cache_dir.parent.stat()
    cache_stat = cache_dir.stat()
except OSError as exc:
    raise SystemExit(f"could not inspect status report cache path {cache_dir}: {exc}") from exc
if cache_parent_stat.st_uid != os.getuid():
    raise SystemExit(
        f"status report cache parent directory {cache_dir.parent} is owned by uid "
        f"{cache_parent_stat.st_uid}, expected {os.getuid()}"
    )
cache_parent_mode = cache_parent_stat.st_mode & 0o777
if cache_parent_mode != 0o700:
    raise SystemExit(
        f"status report cache parent directory {cache_dir.parent} has permissions "
        f"{cache_parent_mode:04o}, expected private 0700"
    )
if cache_stat.st_uid != os.getuid():
    raise SystemExit(
        f"status report cache directory {cache_dir} is owned by uid {cache_stat.st_uid}, expected {os.getuid()}"
    )
cache_mode = cache_stat.st_mode & 0o777
if cache_mode != 0o700:
    raise SystemExit(
        f"status report cache directory {cache_dir} has permissions {cache_mode:04o}, expected private 0700"
    )
with status_path.open(encoding="utf-8") as handle:
    report = json.load(handle)
if report.get("ok") is not True:
    raise SystemExit("status report ok is not true")
generated_at = str(report.get("generated_at", ""))
if not generated_at:
    raise SystemExit("status report has no generated_at")
try:
    generated = datetime.fromisoformat(generated_at.replace("Z", "+00:00")).astimezone(timezone.utc)
except ValueError as exc:
    raise SystemExit(f"invalid generated_at: {generated_at}") from exc
age_seconds = (datetime.now(timezone.utc) - generated).total_seconds()
if age_seconds < -30 or age_seconds > 600:
    raise SystemExit(f"status report is not fresh: {age_seconds:.0f}s old")
checks = report.get("checks")
service_checks = report.get("service_checks")
if not isinstance(checks, list) or not checks:
    raise SystemExit("status report has no checks")
if not isinstance(service_checks, list) or not service_checks:
    raise SystemExit("status report has no service checks")
actual_config_path = str(report.get("config_path", "")).strip()
if expected_config_path and actual_config_path != expected_config_path:
    raise SystemExit(f"status report config path {actual_config_path} does not match {expected_config_path}")
if expected_config_path:
    config_file = Path(expected_config_path).expanduser()
    if config_file.is_symlink():
        raise SystemExit(f"status report config path is a symlink: {config_file}")
    if not config_file.is_file():
        raise SystemExit(f"status report config path is not a regular file: {config_file}")
    try:
        config_stat = config_file.stat()
    except OSError as exc:
        raise SystemExit(f"could not inspect status report config path {config_file}: {exc}") from exc
    if config_stat.st_uid != os.getuid():
        raise SystemExit(
            f"status report config path {config_file} is owned by uid {config_stat.st_uid}, expected {os.getuid()}"
        )
    config_mode = config_stat.st_mode & 0o777
    if config_mode & 0o022:
        raise SystemExit(
            f"status report config path {config_file} has permissions {config_mode:04o}, "
            "expected no group/other write bits"
        )
if expected_launcher_env_path:
    launcher_settings = report.get("launcher_settings")
    if not isinstance(launcher_settings, dict):
        raise SystemExit("status report has no launcher_settings section")
    launcher_env_path = str(launcher_settings.get("path", "")).strip()
    if launcher_env_path != expected_launcher_env_path:
        raise SystemExit(
            f"status report launcher settings path {launcher_env_path} does not match {expected_launcher_env_path}"
        )
    if launcher_settings.get("exists") is not True:
        raise SystemExit(f"status report launcher settings do not exist: {expected_launcher_env_path}")
    if launcher_settings.get("is_symlink") is True:
        raise SystemExit(f"status report launcher settings path is a symlink: {expected_launcher_env_path}")
    launcher_env_file = Path(expected_launcher_env_path).expanduser()
    if launcher_env_file.is_symlink():
        raise SystemExit(f"status report launcher settings path is a symlink: {launcher_env_file}")
    if launcher_settings.get("directory_is_symlink") is not False:
        raise SystemExit(
            "status report launcher settings directory is a symlink or missing symlink status: "
            f"{launcher_env_file.parent}"
        )
    launcher_settings_symlink_component = str(
        launcher_settings.get("launcher_settings_symlink_component", "")
    ).strip()
    if launcher_settings_symlink_component:
        raise SystemExit(
            "status report launcher settings path contains a symlink: "
            f"{launcher_settings_symlink_component}"
        )
    if launcher_env_file.parent.is_symlink():
        raise SystemExit(f"status report launcher settings directory is a symlink: {launcher_env_file.parent}")
    live_launcher_settings_symlink_component = first_symlink_ancestor(launcher_env_file.parent)
    if live_launcher_settings_symlink_component is not None:
        raise SystemExit(
            "status report launcher settings path contains a symlink: "
            f"{live_launcher_settings_symlink_component}"
        )
    values = launcher_settings.get("values")
    if not isinstance(values, dict):
        raise SystemExit(f"status report launcher settings values were not parsed: {expected_launcher_env_path}")
    try:
        launcher_lines = launcher_env_file.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise SystemExit(f"could not read launcher environment {expected_launcher_env_path}: {exc}") from exc
    actual_values = {}
    for raw_line in launcher_lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        actual_values[key.strip()] = value.strip()
    if values != actual_values:
        raise SystemExit(
            f"status report launcher settings values {values!r} do not match launcher environment {actual_values!r}"
        )
    gps_wait = str(values.get("NOAA_NAVIONICS_GPS_SECONDS", "")).strip()
    if gps_wait != os.environ.get("NOAA_NAVIONICS_GPS_SECONDS", "60"):
        raise SystemExit(
            f"status report launcher GPS wait {gps_wait} does not match verification wait "
            f"{os.environ.get('NOAA_NAVIONICS_GPS_SECONDS', '60')}"
        )
    restart_attempts = str(values.get("NOAA_NAVIONICS_OPENCPN_RESTARTS", "")).strip()
    expected_restart_attempts = os.environ.get("NOAA_NAVIONICS_OPENCPN_RESTARTS", "3")
    if restart_attempts != expected_restart_attempts:
        raise SystemExit(
            f"status report launcher OpenCPN restart attempts {restart_attempts or '<missing>'} "
            f"do not match verification value {expected_restart_attempts}"
        )
    restart_delay = str(values.get("NOAA_NAVIONICS_OPENCPN_RESTART_DELAY", "")).strip()
    expected_restart_delay = os.environ.get("NOAA_NAVIONICS_OPENCPN_RESTART_DELAY", "5")
    if restart_delay != expected_restart_delay:
        raise SystemExit(
            f"status report launcher OpenCPN restart delay {restart_delay or '<missing>'} "
            f"does not match verification value {expected_restart_delay}"
        )
    fail_open = str(values.get("NOAA_NAVIONICS_START_ON_FAILED_READINESS", "")).strip().lower()
    if fail_open in {"1", "yes", "true", "on"}:
        raise SystemExit(
            "status report launcher settings enable NOAA_NAVIONICS_START_ON_FAILED_READINESS"
        )
    if fail_open and fail_open not in {"0", "no", "false", "off"}:
        raise SystemExit(
            f"status report launcher settings contain invalid NOAA_NAVIONICS_START_ON_FAILED_READINESS={fail_open}"
        )
    for key in ("NOAA_NAVIONICS_OPENCPN_RESTARTS", "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY"):
        value = str(values.get(key, "")).strip()
        if value and (not value.isdigit() or int(value) < 0):
            raise SystemExit(f"status report launcher settings contain invalid {key}={value}")
user = report.get("user")
if not isinstance(user, dict):
    raise SystemExit("status report has no user section")
status_user = str(user.get("name", "")).strip()
if status_user != os.environ.get("USER", ""):
    raise SystemExit(
        f"status report user {status_user or '<missing>'} does not match {os.environ.get('USER', '')}"
    )
status_linger = str(user.get("linger", "")).strip()
if status_linger != "yes":
    raise SystemExit(f"status report user linger={status_linger or '<missing>'}, expected yes")
if expected_config_path:
    parser = ConfigParser()
    if not parser.read(Path(expected_config_path).expanduser()):
        raise SystemExit(f"could not read expected config: {expected_config_path}")
    chart_output = Path(parser.get("charts", "output", fallback="~/charts/noaa-enc").strip()).expanduser()
    expected_manifest_path = str(chart_output / "noaa-navionics-manifest.json")
    expected_config = {
        "chart_package": parser.get("charts", "package", fallback="state").strip().lower(),
        "chart_value": parser.get("charts", "value", fallback="AK").strip(),
        "chart_output": str(chart_output),
        "extract": config_bool(parser, "charts", "extract", "yes"),
        "keep_zip": config_bool(parser, "charts", "keep_zip", "yes"),
        "force": config_bool(parser, "charts", "force", "yes"),
        "max_chart_age_days": int(parser.get("charts", "max_age_days", fallback="30").strip()),
        "min_free_gb": float(parser.get("charts", "min_free_gb", fallback="2.0").strip()),
        "gps_mode": parser.get("gps", "mode", fallback="gpsd").strip().lower(),
        "gps_device": parser.get("gps", "device", fallback="/dev/serial/by-id/YOUR_GPS_DEVICE").strip(),
        "gps_baud": int(parser.get("gps", "baud", fallback="4800").strip()),
        "gpsd_host": parser.get("gps", "gpsd_host", fallback="127.0.0.1").strip(),
        "gpsd_port": int(parser.get("gps", "gpsd_port", fallback="2947").strip()),
        "track_output": str(Path(parser.get("tracking", "output", fallback=str(chart_output)).strip()).expanduser()),
        "track_retention_days": int(parser.get("tracking", "retention_days", fallback="90").strip()),
    }
    expected_package_zip = expected_package_filename(
        expected_config["chart_package"],
        expected_config["chart_value"],
    )
    expected_package_source_url = expected_package_url(
        expected_config["chart_package"],
        expected_config["chart_value"],
    )
    try:
        require_track_disk_check = Path(expected_config["track_output"]).resolve() != chart_output.resolve()
    except OSError:
        require_track_disk_check = Path(expected_config["track_output"]) != chart_output
    report_config = report.get("config")
    if not isinstance(report_config, dict):
        raise SystemExit("status report has no config section")
    mismatches = []
    for key, expected in expected_config.items():
        actual = report_config.get(key)
        if actual != expected:
            mismatches.append(f"{key}={actual!r}, expected {expected!r}")
    if mismatches:
        raise SystemExit("status report config values do not match current config: " + "; ".join(mismatches))
    track_log = report.get("track_log")
    if not isinstance(track_log, dict):
        raise SystemExit("status report has no track_log section")
    expected_track_output = Path(expected_config["track_output"]).expanduser()
    expected_tracks_dir = expected_track_output / "tracks"
    actual_track_output = str(track_log.get("track_output", "")).strip()
    if actual_track_output != str(expected_track_output):
        raise SystemExit(
            f"status report track_log track_output {actual_track_output or '<missing>'} "
            f"does not match configured {expected_track_output}"
        )
    if track_log.get("track_output_is_symlink") is not False:
        raise SystemExit(
            f"status report track_log track_output is a symlink or missing symlink status: {expected_track_output}"
        )
    actual_tracks_dir = str(track_log.get("tracks_dir", "")).strip()
    if actual_tracks_dir != str(expected_tracks_dir):
        raise SystemExit(
            f"status report track_log tracks_dir {actual_tracks_dir} does not match configured {expected_tracks_dir}"
        )
    track_symlink_component = first_symlink_ancestor(expected_tracks_dir)
    status_track_symlink_component = str(track_log.get("track_storage_symlink_component", "")).strip()
    if track_symlink_component is not None:
        raise SystemExit(f"configured GPX track storage path contains a symlink: {track_symlink_component}")
    if status_track_symlink_component:
        raise SystemExit(
            "status report track_log track_storage_symlink_component is set unexpectedly: "
            f"{status_track_symlink_component}"
        )
    try:
        tracks_dir_stat = expected_tracks_dir.stat()
    except OSError as exc:
        raise SystemExit(f"could not inspect status report track_log tracks_dir {expected_tracks_dir}: {exc}") from exc
    if expected_tracks_dir.is_symlink():
        raise SystemExit(f"status report track_log tracks_dir is a symlink: {expected_tracks_dir}")
    if not expected_tracks_dir.is_dir():
        raise SystemExit(f"status report track_log tracks_dir is not a directory: {expected_tracks_dir}")
    if tracks_dir_stat.st_uid != os.getuid():
        raise SystemExit(
            f"status report track_log tracks_dir {expected_tracks_dir} is owned by uid "
            f"{tracks_dir_stat.st_uid}, expected {os.getuid()}"
        )
    tracks_dir_mode = tracks_dir_stat.st_mode & 0o777
    if tracks_dir_mode & 0o077:
        raise SystemExit(
            f"status report track_log tracks_dir {expected_tracks_dir} has permissions "
            f"{tracks_dir_mode:04o}, expected private 0700"
        )
    status_tracks_mode = str(track_log.get("tracks_mode", "")).strip()
    if status_tracks_mode != f"{tracks_dir_mode:04o}":
        raise SystemExit(
            f"status report track_log tracks_mode {status_tracks_mode or '<missing>'} "
            f"does not match directory permissions {tracks_dir_mode:04o}"
        )
    latest_track_path = Path(str(track_log.get("latest_path", "")).strip()).expanduser()
    if not str(latest_track_path):
        raise SystemExit("status report track_log has no latest_path")
    if latest_track_path.is_symlink():
        raise SystemExit(f"status report track_log latest_path is a symlink: {latest_track_path}")
    if not latest_track_path.is_file():
        raise SystemExit(f"status report track_log latest_path is not a regular file: {latest_track_path}")
    try:
        latest_track_path.resolve(strict=True).relative_to(expected_tracks_dir.resolve(strict=True))
    except OSError as exc:
        raise SystemExit(f"could not resolve status report track_log paths: {exc}") from exc
    except ValueError as exc:
        raise SystemExit(
            f"status report track_log latest_path {latest_track_path} is outside {expected_tracks_dir}"
        ) from exc
    try:
        latest_track_stat = latest_track_path.stat()
    except OSError as exc:
        raise SystemExit(f"could not inspect status report track_log latest_path {latest_track_path}: {exc}") from exc
    if latest_track_stat.st_uid != os.getuid():
        raise SystemExit(
            f"status report track_log latest_path {latest_track_path} is owned by uid "
            f"{latest_track_stat.st_uid}, expected {os.getuid()}"
        )
    latest_track_mode = latest_track_stat.st_mode & 0o777
    if latest_track_mode & 0o077:
        raise SystemExit(
            f"status report track_log latest_path {latest_track_path} has permissions "
            f"{latest_track_mode:04o}, expected private 0600"
        )
    status_latest_mode = str(track_log.get("latest_mode", "")).strip()
    if status_latest_mode != f"{latest_track_mode:04o}":
        raise SystemExit(
            f"status report track_log latest_mode {status_latest_mode or '<missing>'} "
            f"does not match file permissions {latest_track_mode:04o}"
        )
    latest_satellites = track_log.get("latest_satellites")
    latest_hdop = track_log.get("latest_hdop")
    if latest_satellites is None and latest_hdop is None:
        raise SystemExit("status report track_log has no latest satellite or HDOP quality fields")
    if latest_satellites is not None:
        if isinstance(latest_satellites, bool) or not isinstance(latest_satellites, int):
            raise SystemExit(f"status report track_log latest_satellites is not an integer: {latest_satellites!r}")
        if latest_satellites < 4:
            raise SystemExit(f"status report track_log latest_satellites is weak: {latest_satellites}")
    if latest_hdop is not None:
        if isinstance(latest_hdop, bool) or not isinstance(latest_hdop, (int, float)):
            raise SystemExit(f"status report track_log latest_hdop is not numeric: {latest_hdop!r}")
        if not math.isfinite(float(latest_hdop)):
            raise SystemExit(f"status report track_log latest_hdop is not finite: {latest_hdop!r}")
        if float(latest_hdop) > 5.0:
            raise SystemExit(f"status report track_log latest_hdop is weak: {latest_hdop:g}")
    opencpn_config = report.get("opencpn_config")
    if not isinstance(opencpn_config, dict):
        raise SystemExit("status report has no opencpn_config section")
    opencpn_config_path = str(opencpn_config.get("path", "")).strip()
    if not opencpn_config_path:
        raise SystemExit("status report OpenCPN config path is empty")
    if opencpn_config.get("exists") is not True:
        raise SystemExit(f"status report OpenCPN config does not exist: {opencpn_config_path}")
    if opencpn_config.get("is_symlink") is True:
        raise SystemExit(f"status report OpenCPN config is a symlink: {opencpn_config_path}")
    if opencpn_config.get("directory_is_symlink") is True:
        raise SystemExit(f"status report OpenCPN config directory is a symlink: {Path(opencpn_config_path).expanduser().parent}")
    opencpn_symlink_component = str(opencpn_config.get("config_symlink_component", "")).strip()
    if opencpn_symlink_component:
        raise SystemExit(f"status report OpenCPN config path contains a symlink: {opencpn_symlink_component}")
    if str(opencpn_config.get("error", "")).strip():
        raise SystemExit(
            f"status report OpenCPN config has parse error at {opencpn_config_path}: {opencpn_config.get('error')}"
        )
    status_chart_directories = opencpn_config.get("chart_directories")
    status_data_connections = opencpn_config.get("data_connections")
    if not isinstance(status_chart_directories, list):
        raise SystemExit(f"status report OpenCPN chart directories were not parsed: {opencpn_config_path}")
    if not isinstance(status_data_connections, list):
        raise SystemExit(f"status report OpenCPN data connections were not parsed: {opencpn_config_path}")
    opencpn_config_file = Path(opencpn_config_path).expanduser()
    opencpn_config_dir = opencpn_config_file.parent
    opencpn_live_symlink_component = first_symlink_ancestor(opencpn_config_dir)
    if opencpn_live_symlink_component is not None:
        raise SystemExit(f"status report OpenCPN config path contains a symlink: {opencpn_live_symlink_component}")
    if opencpn_config_dir.is_symlink():
        raise SystemExit(f"status report OpenCPN config directory is a symlink: {opencpn_config_dir}")
    if not opencpn_config_dir.is_dir():
        raise SystemExit(f"status report OpenCPN config directory is not a directory: {opencpn_config_dir}")
    try:
        opencpn_dir_stat = opencpn_config_dir.stat()
    except OSError as exc:
        raise SystemExit(f"could not inspect status report OpenCPN config directory {opencpn_config_dir}: {exc}") from exc
    if opencpn_dir_stat.st_uid != os.getuid():
        raise SystemExit(
            f"status report OpenCPN config directory {opencpn_config_dir} is owned by uid "
            f"{opencpn_dir_stat.st_uid}, expected {os.getuid()}"
        )
    opencpn_dir_mode = opencpn_dir_stat.st_mode & 0o777
    status_opencpn_dir_uid = opencpn_config.get("directory_uid")
    try:
        parsed_opencpn_dir_uid = int(status_opencpn_dir_uid)
    except (TypeError, ValueError) as exc:
        raise SystemExit(
            f"status report OpenCPN config directory_uid is invalid: {status_opencpn_dir_uid!r}"
        ) from exc
    if parsed_opencpn_dir_uid != opencpn_dir_stat.st_uid:
        raise SystemExit(
            f"status report OpenCPN config directory_uid {parsed_opencpn_dir_uid} "
            f"does not match live owner {opencpn_dir_stat.st_uid}: {opencpn_config_dir}"
        )
    status_opencpn_dir_mode = str(opencpn_config.get("directory_mode", "")).strip()
    if status_opencpn_dir_mode != f"{opencpn_dir_mode:04o}":
        raise SystemExit(
            f"status report OpenCPN config directory_mode {status_opencpn_dir_mode or '<missing>'} "
            f"does not match live permissions {opencpn_dir_mode:04o}: {opencpn_config_dir}"
        )
    if opencpn_dir_mode & 0o077:
        raise SystemExit(
            f"status report OpenCPN config directory {opencpn_config_dir} has permissions "
            f"{opencpn_dir_mode:04o}, expected private 0700"
        )
    if opencpn_config_file.is_symlink():
        raise SystemExit(f"status report OpenCPN config is a symlink: {opencpn_config_file}")
    if not opencpn_config_file.is_file():
        raise SystemExit(f"status report OpenCPN config is not a regular file: {opencpn_config_file}")
    try:
        opencpn_stat = opencpn_config_file.stat()
    except OSError as exc:
        raise SystemExit(f"could not inspect status report OpenCPN config {opencpn_config_file}: {exc}") from exc
    verify_status_file_owner_and_mode(
        opencpn_config,
        opencpn_config_file,
        opencpn_stat,
        "OpenCPN config",
        os.getuid(),
    )
    if opencpn_stat.st_uid != os.getuid():
        raise SystemExit(
            f"status report OpenCPN config {opencpn_config_file} is owned by uid "
            f"{opencpn_stat.st_uid}, expected {os.getuid()}"
        )
    opencpn_mode = opencpn_stat.st_mode & 0o777
    if opencpn_mode & 0o022:
        raise SystemExit(
            f"status report OpenCPN config {opencpn_config_file} has permissions {opencpn_mode:04o}, "
            "expected no group/other write bits"
        )
    live_chart_directories, live_data_connections = parse_opencpn_config(opencpn_config_path)
    normalized_status_chart_directories = [normalize_path(str(value)) for value in status_chart_directories]
    normalized_status_data_connections = [str(value) for value in status_data_connections]
    if normalized_status_chart_directories != live_chart_directories:
        raise SystemExit(
            f"status report OpenCPN chart directories {normalized_status_chart_directories!r} "
            f"do not match live OpenCPN config {live_chart_directories!r}"
        )
    if normalized_status_data_connections != live_data_connections:
        raise SystemExit("status report OpenCPN data connections do not match live OpenCPN config")
    normalized_chart_output = normalize_path(expected_config["chart_output"])
    if normalized_chart_output not in live_chart_directories:
        raise SystemExit(
            f"OpenCPN config {opencpn_config_path} does not list configured chart output {normalized_chart_output}"
        )
    if expected_config["gps_mode"] == "gpsd" and not gpsd_connection_present(
        live_data_connections,
        expected_config["gpsd_host"],
        expected_config["gpsd_port"],
    ):
        raise SystemExit(
            f"OpenCPN config {opencpn_config_path} does not contain enabled GPSD connection "
            f"{expected_config['gpsd_host']}:{expected_config['gpsd_port']}"
        )
    desktop = report.get("desktop")
    if not isinstance(desktop, dict):
        raise SystemExit("status report has no desktop section")
    autostart = desktop.get("autostart")
    if not isinstance(autostart, dict):
        raise SystemExit("status report has no desktop autostart section")
    autostart_path = str(autostart.get("path", "")).strip()
    if autostart.get("exists") is not True:
        raise SystemExit(f"status report desktop autostart does not exist: {autostart_path}")
    if autostart.get("is_symlink") is True:
        raise SystemExit(f"status report desktop autostart path is a symlink: {autostart_path}")
    autostart_file = Path(autostart_path).expanduser()
    if autostart_file.is_symlink():
        raise SystemExit(f"status report desktop autostart path is a symlink: {autostart_file}")
    if autostart.get("directory_is_symlink") is not False:
        raise SystemExit(
            "status report desktop autostart directory is a symlink or missing symlink status: "
            f"{autostart_file.parent}"
        )
    autostart_symlink_component = str(autostart.get("path_symlink_component", "")).strip()
    if autostart_symlink_component:
        raise SystemExit(
            f"status report desktop autostart path contains a symlink: {autostart_symlink_component}"
        )
    if autostart_file.parent.is_symlink():
        raise SystemExit(f"status report desktop autostart directory is a symlink: {autostart_file.parent}")
    live_autostart_symlink_component = first_symlink_ancestor(autostart_file.parent)
    if live_autostart_symlink_component is not None:
        raise SystemExit(
            f"status report desktop autostart path contains a symlink: {live_autostart_symlink_component}"
        )
    if not autostart_file.is_file():
        raise SystemExit(f"status report desktop autostart is not a regular file: {autostart_file}")
    try:
        autostart_stat = autostart_file.stat()
    except OSError as exc:
        raise SystemExit(f"could not inspect status report desktop autostart {autostart_file}: {exc}") from exc
    verify_status_file_owner_and_mode(
        autostart,
        autostart_file,
        autostart_stat,
        "desktop autostart",
        os.getuid(),
    )
    autostart_values = autostart.get("values")
    if not isinstance(autostart_values, dict):
        raise SystemExit(f"status report desktop autostart values were not parsed: {autostart_path}")
    _autostart_sections, live_autostart_values = parse_key_value_file(autostart_path, ("#",))
    if autostart_values != live_autostart_values:
        raise SystemExit("status report desktop autostart values do not match live desktop file")
    expected_autostart = {
        "Type": "Application",
        "Name": "NOAA Navionics Chartplotter",
        "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
        "Terminal": "false",
        "X-GNOME-Autostart-enabled": "true",
    }
    for key, expected in expected_autostart.items():
        actual = str(autostart_values.get(key, "")).strip()
        if actual != expected:
            raise SystemExit(f"desktop autostart {key}={actual or '<missing>'} expected {expected}")
    if str(autostart_values.get("Hidden", "")).strip().lower() == "true":
        raise SystemExit("desktop autostart is hidden")
    lightdm = desktop.get("lightdm_autologin")
    if not isinstance(lightdm, dict):
        raise SystemExit("status report has no LightDM autologin section")
    lightdm_path = str(lightdm.get("path", "")).strip()
    if lightdm.get("exists") is not True:
        raise SystemExit(f"status report LightDM autologin config does not exist: {lightdm_path}")
    if lightdm.get("is_symlink") is True:
        raise SystemExit(f"status report LightDM autologin config path is a symlink: {lightdm_path}")
    lightdm_file = Path(lightdm_path).expanduser()
    if lightdm_file.is_symlink():
        raise SystemExit(f"status report LightDM autologin config path is a symlink: {lightdm_file}")
    if lightdm.get("directory_is_symlink") is not False:
        raise SystemExit(
            "status report LightDM autologin config directory is a symlink or missing symlink status: "
            f"{lightdm_file.parent}"
        )
    lightdm_symlink_component = str(lightdm.get("path_symlink_component", "")).strip()
    if lightdm_symlink_component:
        raise SystemExit(
            f"status report LightDM autologin config path contains a symlink: {lightdm_symlink_component}"
        )
    if lightdm_file.parent.is_symlink():
        raise SystemExit(f"status report LightDM autologin config directory is a symlink: {lightdm_file.parent}")
    live_lightdm_symlink_component = first_symlink_ancestor(lightdm_file.parent)
    if live_lightdm_symlink_component is not None:
        raise SystemExit(
            f"status report LightDM autologin config path contains a symlink: {live_lightdm_symlink_component}"
        )
    if not lightdm_file.is_file():
        raise SystemExit(f"status report LightDM autologin config is not a regular file: {lightdm_file}")
    try:
        lightdm_stat = lightdm_file.stat()
    except OSError as exc:
        raise SystemExit(f"could not inspect status report LightDM autologin config {lightdm_file}: {exc}") from exc
    verify_status_file_owner_and_mode(
        lightdm,
        lightdm_file,
        lightdm_stat,
        "LightDM autologin config",
        0,
    )
    lightdm_values = lightdm.get("values")
    lightdm_sections = lightdm.get("sections")
    if not isinstance(lightdm_values, dict) or not isinstance(lightdm_sections, list):
        raise SystemExit(f"status report LightDM autologin values were not parsed: {lightdm_path}")
    live_lightdm_sections, live_lightdm_values = parse_key_value_file(lightdm_path, ("#", ";"))
    if lightdm_values != live_lightdm_values or [str(value) for value in lightdm_sections] != live_lightdm_sections:
        raise SystemExit("status report LightDM autologin values do not match live LightDM config")
    if "Seat:*" not in {str(value) for value in lightdm_sections}:
        raise SystemExit("LightDM autologin config missing [Seat:*] section")
    if str(lightdm_values.get("autologin-user", "")).strip() != os.environ.get("USER", ""):
        raise SystemExit(
            f"LightDM autologin-user {lightdm_values.get('autologin-user', '<missing>')} "
            f"does not match {os.environ.get('USER', '')}"
        )
    if str(lightdm_values.get("autologin-user-timeout", "")).strip() != "0":
        raise SystemExit("LightDM autologin-user-timeout is not 0")
    session = str(lightdm_values.get("autologin-session", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9._+-]+", session):
        raise SystemExit(f"LightDM autologin-session is unsafe or missing: {session or '<missing>'}")
    if not (Path("/usr/share/xsessions") / f"{session}.desktop").is_file():
        raise SystemExit(f"LightDM autologin-session is not installed: {session}")
    if str(desktop.get("graphical_target", "")).strip() != "graphical.target":
        raise SystemExit(f"status report graphical target is {desktop.get('graphical_target', '<missing>')}")
    if str(desktop.get("lightdm_enabled", "")).strip() != "enabled":
        raise SystemExit(f"status report LightDM enabled state is {desktop.get('lightdm_enabled', '<missing>')}")
    manifest = report.get("manifest")
    if not isinstance(manifest, dict):
        raise SystemExit("status report has no manifest section")
    actual_manifest_path = str(manifest.get("path", "")).strip()
    if actual_manifest_path != expected_manifest_path:
        raise SystemExit(
            f"status report manifest path {actual_manifest_path} does not match {expected_manifest_path}"
        )
    if manifest.get("exists") is not True:
        raise SystemExit(f"status report manifest does not exist: {expected_manifest_path}")
    if manifest.get("is_symlink") is True:
        raise SystemExit(f"status report manifest path is a symlink: {expected_manifest_path}")
    if manifest.get("directory_is_symlink") is not False:
        raise SystemExit(
            f"status report manifest directory is a symlink or missing symlink status: {expected_manifest_path.parent}"
        )
    manifest_symlink_component = str(manifest.get("manifest_symlink_component", "")).strip()
    if manifest_symlink_component:
        raise SystemExit(f"status report manifest path contains a symlink: {manifest_symlink_component}")
    for key in ("created_at", "package", "package_filename", "url", "download_path", "download_url", "sha256", "extract_path"):
        if not str(manifest.get(key, "")).strip():
            raise SystemExit(f"status report manifest missing {key}: {expected_manifest_path}")
    manifest_created_at_source = str(manifest.get("created_at_source", "")).strip()
    if not manifest_created_at_source:
        raise SystemExit(f"status report manifest missing created_at_source: {expected_manifest_path}")
    if manifest_created_at_source not in {"download", "previous-manifest"}:
        raise SystemExit(
            f"status report manifest created_at_source {manifest_created_at_source} is not verified"
        )
    manifest_file_path = Path(expected_manifest_path).expanduser()
    if manifest_file_path.is_symlink():
        raise SystemExit(f"status report manifest path is a symlink: {manifest_file_path}")
    if manifest_file_path.parent.is_symlink():
        raise SystemExit(f"status report manifest directory is a symlink: {manifest_file_path.parent}")
    live_manifest_symlink_component = first_symlink_ancestor(manifest_file_path.parent)
    if live_manifest_symlink_component is not None:
        raise SystemExit(f"status report manifest path contains a symlink: {live_manifest_symlink_component}")
    if not manifest_file_path.is_file():
        raise SystemExit(f"status report manifest path is not a regular file: {manifest_file_path}")
    try:
        manifest_stat = manifest_file_path.stat()
    except OSError as exc:
        raise SystemExit(f"could not inspect status report manifest path {manifest_file_path}: {exc}") from exc
    verify_status_file_owner_and_mode(
        manifest,
        manifest_file_path,
        manifest_stat,
        "manifest",
        os.getuid(),
    )
    with manifest_file_path.open(encoding="utf-8") as manifest_handle:
        manifest_file = json.load(manifest_handle)
    package_section = manifest_file.get("package", {})
    download_section = manifest_file.get("download", {})
    extract_section = manifest_file.get("extract", {})
    if not isinstance(package_section, dict):
        raise SystemExit(f"manifest file has no package section: {expected_manifest_path}")
    if not isinstance(download_section, dict):
        raise SystemExit(f"manifest file has no download section: {expected_manifest_path}")
    if not isinstance(extract_section, dict):
        raise SystemExit(f"manifest file has no extract section: {expected_manifest_path}")
    manifest_file_created_at_source = str(manifest_file.get("created_at_source", "")).strip()
    manifest_file_created_at = str(manifest_file.get("created_at", "")).strip()
    if str(manifest.get("created_at", "")).strip() != manifest_file_created_at:
        raise SystemExit(
            "status report manifest created_at "
            f"{str(manifest.get('created_at', '')).strip()} does not match manifest file {manifest_file_created_at}"
        )
    if manifest_file_created_at_source != manifest_created_at_source:
        raise SystemExit(
            f"status report manifest created_at_source {manifest_created_at_source} "
            f"does not match manifest file {manifest_file_created_at_source}"
        )
    manifest_download_skipped = bool(manifest.get("download_skipped", False))
    manifest_file_download_skipped = bool(download_section.get("skipped", False)) if isinstance(download_section, dict) else False
    if manifest_download_skipped != manifest_file_download_skipped:
        raise SystemExit(
            f"status report manifest download_skipped {manifest_download_skipped} "
            f"does not match manifest file {manifest_file_download_skipped}"
        )
    manifest_field_pairs = [
        ("package", package_section, "label"),
        ("package_filename", package_section, "filename"),
        ("url", package_section, "url"),
        ("download_path", download_section, "path"),
        ("download_url", download_section, "url"),
        ("sha256", download_section, "sha256"),
        ("extract_path", extract_section, "path"),
    ]
    for status_key, source_section, source_key in manifest_field_pairs:
        status_value = str(manifest.get(status_key, "")).strip()
        file_value = str(source_section.get(source_key, "")).strip()
        if status_value != file_value:
            raise SystemExit(
                f"status report manifest {status_key} {status_value} "
                f"does not match manifest file {source_key} {file_value}"
            )
    manifest_file_download_bytes = parse_manifest_int(
        download_section.get("bytes", 0),
        "download bytes",
        expected_manifest_path,
    )
    manifest_file_sha256 = str(download_section.get("sha256", "")).strip().lower()
    manifest_file_enc_cell_count = parse_manifest_int(
        extract_section.get("enc_cell_count", 0),
        "ENC cell count",
        expected_manifest_path,
    )
    status_download_bytes = parse_manifest_int(
        manifest.get("download_bytes", 0),
        "download_bytes",
        "status report",
    )
    status_enc_cell_count = parse_manifest_int(
        manifest.get("enc_cell_count", 0),
        "enc_cell_count",
        "status report",
    )
    if status_download_bytes != manifest_file_download_bytes:
        raise SystemExit(
            f"status report manifest download_bytes {manifest.get('download_bytes', 0)} "
            f"does not match manifest file bytes {manifest_file_download_bytes}"
        )
    if status_enc_cell_count != manifest_file_enc_cell_count:
        raise SystemExit(
            f"status report manifest enc_cell_count {manifest.get('enc_cell_count', 0)} "
            f"does not match manifest file enc_cell_count {manifest_file_enc_cell_count}"
        )
    manifest_package_filename = str(manifest.get("package_filename", "")).strip()
    if expected_package_zip and manifest_package_filename != expected_package_zip:
        raise SystemExit(
            f"status report manifest package filename {manifest_package_filename} "
            f"does not match configured {expected_package_zip}"
        )
    manifest_package_url = str(manifest.get("url", "")).strip()
    if expected_package_source_url and manifest_package_url != expected_package_source_url:
        raise SystemExit(
            f"status report manifest package URL {manifest_package_url} "
            f"does not match configured {expected_package_source_url}"
        )
    manifest_download_url = str(manifest.get("download_url", "")).strip()
    if expected_package_source_url and not download_url_matches_package(
        manifest_download_url,
        expected_package_source_url,
    ):
        raise SystemExit(
            f"status report manifest download URL {manifest_download_url} "
            f"does not match configured package filename from {expected_package_source_url} or uses a non-HTTPS redirect"
        )
    def first_symlink_component(path, root):
        root_path = Path(root).expanduser()
        current = Path(path).expanduser()
        while True:
            if current.is_symlink():
                return current
            if current == root_path:
                return None
            parent = current.parent
            if parent == current:
                return None
            current = parent
    download_path = Path(str(manifest.get("download_path", "")).strip()).expanduser()
    if manifest.get("download_path_is_symlink") is True or download_path.is_symlink():
        raise SystemExit(f"status report manifest download path is a symlink: {download_path}")
    download_path_symlink_component = str(manifest.get("download_path_symlink_component", "")).strip()
    if download_path_symlink_component:
        raise SystemExit(
            f"status report manifest download path contains a symlink: {download_path_symlink_component}"
        )
    download_path_error = str(manifest.get("download_path_error", "")).strip()
    if download_path_error:
        raise SystemExit(f"status report manifest download path error: {download_path_error}")
    if download_path.name != manifest_package_filename:
        raise SystemExit(
            f"status report manifest download path {download_path} does not end with {manifest_package_filename}"
        )
    try:
        download_path.resolve().relative_to(chart_output.resolve())
    except ValueError as exc:
        raise SystemExit(
            f"status report manifest download path {download_path} is outside {chart_output}"
        ) from exc
    download_symlink_component = first_symlink_component(download_path, chart_output)
    if download_symlink_component is not None:
        raise SystemExit(
            f"status report manifest download path contains a symlink: {download_symlink_component}"
        )
    if download_path.exists():
        if not download_path.is_file():
            raise SystemExit(f"status report manifest download path is not a regular file: {download_path}")
        try:
            download_path_stat = download_path.stat()
        except OSError as exc:
            raise SystemExit(f"could not inspect status report manifest download path {download_path}: {exc}") from exc
        verify_status_file_owner_and_mode(
            {
                "uid": manifest.get("download_path_uid"),
                "mode": manifest.get("download_path_mode"),
            },
            download_path,
            download_path_stat,
            "manifest download path",
            os.getuid(),
        )
        if download_path_stat.st_size != manifest_file_download_bytes:
            raise SystemExit(
                f"status report manifest download path {download_path} has "
                f"{download_path_stat.st_size} bytes, expected {manifest_file_download_bytes}"
            )
        actual_download_sha256 = sha256_file(download_path).lower()
        if actual_download_sha256 != manifest_file_sha256:
            raise SystemExit(
                f"status report manifest download path SHA-256 {actual_download_sha256} "
                f"does not match manifest file {manifest_file_sha256}: {download_path}"
            )
    if status_download_bytes <= 0:
        raise SystemExit(f"status report manifest download byte count is not positive: {expected_manifest_path}")
    extract_path = Path(str(manifest.get("extract_path", "")).strip()).expanduser()
    if manifest.get("extract_path_is_symlink") is True or extract_path.is_symlink():
        raise SystemExit(f"status report manifest extract path is a symlink: {extract_path}")
    extract_path_symlink_component = str(manifest.get("extract_path_symlink_component", "")).strip()
    if extract_path_symlink_component:
        raise SystemExit(
            f"status report manifest extract path contains a symlink: {extract_path_symlink_component}"
        )
    try:
        extract_path.resolve().relative_to(chart_output.resolve())
    except ValueError as exc:
        raise SystemExit(
            f"status report manifest extract path {extract_path} is outside {chart_output}"
        ) from exc
    extract_symlink_component = first_symlink_component(extract_path, chart_output)
    if extract_symlink_component is not None:
        raise SystemExit(
            f"status report manifest extract path contains a symlink: {extract_symlink_component}"
        )
    if not extract_path.exists():
        raise SystemExit(f"status report manifest extract path does not exist: {extract_path}")
    if not extract_path.is_dir():
        raise SystemExit(f"status report manifest extract path is not a directory: {extract_path}")
    if status_enc_cell_count <= 0:
        raise SystemExit(f"status report manifest has no ENC cells: {expected_manifest_path}")
    actual_enc_cell_count = count_enc_cells(extract_path)
    if actual_enc_cell_count < manifest_file_enc_cell_count:
        raise SystemExit(
            f"status report manifest extract path {extract_path} has {actual_enc_cell_count} ENC cells, "
            f"expected at least {manifest_file_enc_cell_count}"
        )
check_names = {str(check.get("name", "")) for check in checks if isinstance(check, dict)}
service_check_names = {str(check.get("name", "")) for check in service_checks if isinstance(check, dict)}
required_checks = {
    "Python",
    "Source Revision",
    "Clock",
    "Time Sync",
    "Tkinter",
    "OpenCPN",
    "Display Power",
    "Chart Package",
    "Charts",
    "Chart Update Debris",
    "Manifest",
    "OpenCPN Charts",
    "Disk",
    "Pi Power",
    "Pi Thermal",
    "OpenCPN GPSD",
    "GPSD Config",
    "Chrony Config",
    "GPSD",
    "GPS Time Source",
}
if require_track_disk_check:
    required_checks.add("Track Disk")
required_service_checks = {
    "Chart Sync",
    "Chart Sync Settings",
    "Chart Timer",
    "Chart Timer Install",
    "Chart Timer Settings",
    "Track Log",
    "Track Logger",
    "Track Logger Install",
    "Track Logger Settings",
    "Boot Readiness",
    "Boot Readiness Install",
    "Boot Readiness Settings",
    "Boot Readiness Run",
    "Desktop Startup",
    "Launcher Settings",
    "User Linger",
    "GPSD Socket",
    "GPSD Service",
    "Chrony Service",
}
missing_checks = sorted(required_checks - check_names)
if missing_checks:
    raise SystemExit("status report missing readiness checks: " + ", ".join(missing_checks))
missing_service_checks = sorted(required_service_checks - service_check_names)
if missing_service_checks:
    raise SystemExit("status report missing service checks: " + ", ".join(missing_service_checks))
unit_files = report.get("unit_files")
if not isinstance(unit_files, dict):
    raise SystemExit("status report has no unit_files section")
expected_unit_files = {
    "noaa-navionics.service": "",
    "noaa-navionics.timer": "timers.target",
    "noaa-navionics-track.service": "default.target",
    "noaa-navionics-preflight.service": "default.target",
}
expected_unit_dir = Path.home() / ".config/systemd/user"
for unit, expected_target in expected_unit_files.items():
    state = unit_files.get(unit)
    if not isinstance(state, dict):
        raise SystemExit(f"status report has no unit file entry for {unit}")
    expected_unit_path = expected_unit_dir / unit
    unit_path = str(state.get("path", "")).strip()
    if unit_path != str(expected_unit_path):
        raise SystemExit(f"status report {unit} path {unit_path} does not match {expected_unit_path}")
    if state.get("exists") is not True:
        raise SystemExit(f"status report {unit} does not exist: {expected_unit_path}")
    if state.get("is_symlink") is True:
        raise SystemExit(f"status report {unit} path is a symlink: {expected_unit_path}")
    if expected_unit_path.is_symlink():
        raise SystemExit(f"status report {unit} path is a symlink: {expected_unit_path}")
    if state.get("directory_is_symlink") is not False:
        raise SystemExit(
            f"status report {unit} directory is a symlink or missing symlink status: {expected_unit_path.parent}"
        )
    unit_symlink_component = str(state.get("path_symlink_component", "")).strip()
    if unit_symlink_component:
        raise SystemExit(f"status report {unit} path contains a symlink: {unit_symlink_component}")
    if expected_unit_path.parent.is_symlink():
        raise SystemExit(f"status report {unit} directory is a symlink: {expected_unit_path.parent}")
    live_unit_symlink_component = first_symlink_ancestor(expected_unit_path.parent)
    if live_unit_symlink_component is not None:
        raise SystemExit(f"status report {unit} path contains a symlink: {live_unit_symlink_component}")
    try:
        unit_stat = expected_unit_path.stat()
        unit_dir_stat = expected_unit_path.parent.stat()
    except OSError as exc:
        raise SystemExit(f"could not inspect status report {unit} ownership: {exc}") from exc
    status_uid = state.get("uid")
    if status_uid != unit_stat.st_uid:
        raise SystemExit(
            f"status report {unit} uid {status_uid!r} does not match file owner uid {unit_stat.st_uid}"
        )
    if unit_stat.st_uid != os.getuid():
        raise SystemExit(
            f"status report {unit} file is owned by uid {unit_stat.st_uid}, expected {os.getuid()}"
        )
    unit_mode = unit_stat.st_mode & 0o777
    status_mode = str(state.get("mode", "")).strip()
    if status_mode != f"{unit_mode:04o}":
        raise SystemExit(
            f"status report {unit} mode {status_mode or '<missing>'} "
            f"does not match file permissions {unit_mode:04o}"
        )
    if unit_mode & 0o022:
        raise SystemExit(
            f"status report {unit} file has permissions {unit_mode:04o}, "
            "expected no group/other write bits"
        )
    status_dir_uid = state.get("directory_uid")
    if status_dir_uid != unit_dir_stat.st_uid:
        raise SystemExit(
            f"status report {unit} directory_uid {status_dir_uid!r} "
            f"does not match directory owner uid {unit_dir_stat.st_uid}"
        )
    if unit_dir_stat.st_uid != os.getuid():
        raise SystemExit(
            f"status report {unit} directory is owned by uid {unit_dir_stat.st_uid}, expected {os.getuid()}"
        )
    unit_dir_mode = unit_dir_stat.st_mode & 0o777
    status_dir_mode = str(state.get("directory_mode", "")).strip()
    if status_dir_mode != f"{unit_dir_mode:04o}":
        raise SystemExit(
            f"status report {unit} directory_mode {status_dir_mode or '<missing>'} "
            f"does not match directory permissions {unit_dir_mode:04o}"
        )
    if unit_dir_mode & 0o022:
        raise SystemExit(
            f"status report {unit} directory has permissions {unit_dir_mode:04o}, "
            "expected no group/other write bits"
        )
    if expected_target:
        wanted_by = state.get("wanted_by")
        if not isinstance(wanted_by, list):
            raise SystemExit(f"status report {unit} install targets were not parsed: {expected_unit_path}")
        if expected_target not in {str(value) for value in wanted_by}:
            raise SystemExit(
                f"status report {unit} WantedBy={','.join(str(value) for value in wanted_by) or '<missing>'} "
                f"expected {expected_target}"
            )
expected_revision = os.environ.get("NOAA_NAVIONICS_EXPECTED_REVISION", "unknown")
app = report.get("app")
if not isinstance(app, dict):
    raise SystemExit("status report has no app section")
source_revision_path = str(app.get("source_revision_path", "")).strip()
if source_revision_path != str(Path("~/.local/share/noaa-navionics/source-revision").expanduser()):
    raise SystemExit(
        "status report source revision path "
        f"{source_revision_path or '<missing>'} does not match {Path('~/.local/share/noaa-navionics/source-revision').expanduser()}"
    )
if app.get("source_revision_path_is_symlink") is True:
    raise SystemExit(f"status report source revision path is a symlink: {source_revision_path}")
if app.get("source_revision_directory_is_symlink") is not False:
    raise SystemExit(
        "status report source revision directory is a symlink or missing symlink status: "
        f"{Path(source_revision_path).expanduser().parent}"
    )
source_revision_symlink_component = str(app.get("source_revision_symlink_component", "")).strip()
if source_revision_symlink_component:
    raise SystemExit(
        f"status report source revision path contains a symlink: {source_revision_symlink_component}"
    )
source_revision_file = Path(source_revision_path).expanduser()
if source_revision_file.is_symlink():
    raise SystemExit(f"status report source revision path is a symlink: {source_revision_file}")
if source_revision_file.parent.is_symlink():
    raise SystemExit(f"status report source revision directory is a symlink: {source_revision_file.parent}")
live_source_revision_symlink_component = first_symlink_ancestor(source_revision_file.parent)
if live_source_revision_symlink_component is not None:
    raise SystemExit(
        f"status report source revision path contains a symlink: {live_source_revision_symlink_component}"
    )
actual_revision = str(app.get("source_revision", "unknown"))
if expected_revision != "unknown" and actual_revision != expected_revision:
    raise SystemExit(f"status report source revision {actual_revision} does not match {expected_revision}")
if require_current_boot:
    host = report.get("host")
    if not isinstance(host, dict):
        raise SystemExit("status report has no host section")
    report_boot_id = str(host.get("boot_id", "")).strip()
    if not report_boot_id or report_boot_id == "unknown":
        raise SystemExit("status report has no current boot ID")
    try:
        current_boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    except OSError as exc:
        raise SystemExit(f"could not read current boot ID: {exc}") from exc
    expected_boot_id = os.environ.get("NOAA_NAVIONICS_EXPECTED_BOOT_ID", "").strip()
    if expected_boot_id and current_boot_id != expected_boot_id:
        raise SystemExit(
            f"current boot ID {current_boot_id} does not match expected reboot boot ID {expected_boot_id}"
        )
    if report_boot_id != current_boot_id:
        raise SystemExit(
            f"status report boot ID {report_boot_id} does not match current boot {current_boot_id}"
        )
if any(not isinstance(check, dict) or check.get("ok") is not True for check in checks):
    raise SystemExit("status report contains a failed readiness check")
if any(not isinstance(check, dict) or check.get("ok") is not True for check in service_checks):
    raise SystemExit("status report contains a failed service check")
track_log = report.get("track_log")
if not isinstance(track_log, dict):
    raise SystemExit("status report has no track_log section")
if track_log.get("track_output_is_symlink") is True:
    raise SystemExit(f"status report track_log track_output is a symlink: {track_log.get('track_output', '<missing>')}")
track_symlink_component = str(track_log.get("track_storage_symlink_component", "")).strip()
if track_symlink_component:
    raise SystemExit(f"status report track_log storage path contains a symlink: {track_symlink_component}")
if track_log.get("ok") is not True:
    raise SystemExit(f"status report track_log is not ok: {track_log.get('detail', '<missing detail>')}")
latest_track_path = str(track_log.get("latest_path", "")).strip()
if not latest_track_path:
    raise SystemExit("status report track_log has no latest_path")
for field in ("latest_latitude", "latest_longitude", "age_seconds"):
    value = track_log.get(field)
    if not isinstance(value, (int, float)):
        raise SystemExit(f"status report track_log {field} is not numeric: {value!r}")
latest_satellites = track_log.get("latest_satellites")
latest_hdop = track_log.get("latest_hdop")
if latest_satellites is None and latest_hdop is None:
    raise SystemExit("status report track_log has no latest satellite or HDOP quality fields")
if latest_satellites is not None:
    if isinstance(latest_satellites, bool) or not isinstance(latest_satellites, int):
        raise SystemExit(f"status report track_log latest_satellites is not an integer: {latest_satellites!r}")
    if latest_satellites < 4:
        raise SystemExit(f"status report track_log latest_satellites is weak: {latest_satellites}")
if latest_hdop is not None:
    if isinstance(latest_hdop, bool) or not isinstance(latest_hdop, (int, float)):
        raise SystemExit(f"status report track_log latest_hdop is not numeric: {latest_hdop!r}")
    if not math.isfinite(float(latest_hdop)):
        raise SystemExit(f"status report track_log latest_hdop is not finite: {latest_hdop!r}")
    if float(latest_hdop) > 5.0:
        raise SystemExit(f"status report track_log latest_hdop is weak: {latest_hdop:g}")
PY
}

check_gpsd_device_matches_config() {
  local config_path="$1"
  local gpsd_device="$2"
  python3 - "$config_path" "$gpsd_device" <<'PY'
from configparser import ConfigParser
from pathlib import Path
import sys

config_path = Path(sys.argv[1]).expanduser()
gpsd_device = sys.argv[2]
parser = ConfigParser()
if not parser.read(config_path):
    raise SystemExit(f"could not read config: {config_path}")
mode = parser.get("gps", "mode", fallback="gpsd").strip().lower()
configured_device = parser.get("gps", "device", fallback="").strip()
if mode != "gpsd":
    raise SystemExit(f"gps.mode is {mode}, expected gpsd for GPSD verification")
if not configured_device:
    raise SystemExit("gps.device is empty in config")
if configured_device != gpsd_device:
    raise SystemExit(f"config gps.device {configured_device} does not match GPSD device {gpsd_device}")
PY
}

check_expected_gps_device_matches() {
  local config_path="$1"
  local gpsd_device="$2"
  local expected_device="${NOAA_NAVIONICS_EXPECTED_GPS_DEVICE:-}"
  if [[ -z "$expected_device" ]]; then
    return 0
  fi
  python3 - "$config_path" "$gpsd_device" "$expected_device" <<'PY'
from configparser import ConfigParser
from pathlib import Path
import sys

config_path = Path(sys.argv[1]).expanduser()
gpsd_device = sys.argv[2]
expected_device = sys.argv[3]
parser = ConfigParser()
if not parser.read(config_path):
    raise SystemExit(f"could not read config: {config_path}")
configured_device = parser.get("gps", "device", fallback="").strip()
if configured_device != expected_device:
    raise SystemExit(f"config gps.device {configured_device} does not match expected GPS device {expected_device}")
if gpsd_device != expected_device:
    raise SystemExit(f"GPSD device {gpsd_device} does not match expected GPS device {expected_device}")
PY
}

check_lightdm_autologin_session() {
  local config_path="$1"
  python3 - "$config_path" <<'PY'
from pathlib import Path
import re
import sys

config = Path(sys.argv[1])
try:
    text = config.read_text(encoding="utf-8")
except OSError as exc:
    raise SystemExit(f"could not read LightDM autologin config: {exc}") from exc
session = ""
for line in text.splitlines():
    if line.startswith("autologin-session="):
        session = line.split("=", 1)[1].strip()
        break
if not session:
    raise SystemExit("LightDM autologin session is not configured")
if not re.fullmatch(r"[A-Za-z0-9._+-]+", session):
    raise SystemExit(f"LightDM autologin session name is unsafe: {session}")
session_file = Path("/usr/share/xsessions") / f"{session}.desktop"
if not session_file.is_file():
    raise SystemExit(f"LightDM autologin session is not an installed X11 session: {session_file}")
PY
}

check_tkinter_available() {
  python3 - <<'PY'
try:
    import tkinter  # noqa: F401
except Exception as exc:
    raise SystemExit(f"Tkinter import failed: {exc}") from exc
PY
}

check_raspberry_pi_throttling_state() {
  local output
  local value_text
  local value
  local reported=()

  if ! output="$(vcgencmd get_throttled 2>&1)"; then
    printf 'vcgencmd get_throttled failed: %s\n' "$output" >&2
    return 1
  fi
  if [[ "$output" != throttled=* ]]; then
    printf 'unexpected vcgencmd get_throttled output: %s\n' "$output" >&2
    return 1
  fi
  value_text="${output#throttled=}"
  value_text="${value_text%%[[:space:]]*}"
  if [[ ! "$value_text" =~ ^(0x[[:xdigit:]]+|[0-9]+)$ ]]; then
    printf 'unexpected vcgencmd get_throttled value: %s\n' "$output" >&2
    return 1
  fi
  value=$((value_text))

  (( value & (1 << 0) )) && reported+=("under-voltage")
  (( value & (1 << 1) )) && reported+=("frequency capped")
  (( value & (1 << 2) )) && reported+=("currently throttled")
  (( value & (1 << 3) )) && reported+=("soft temperature limit active")
  (( value & (1 << 16) )) && reported+=("under-voltage occurred")
  (( value & (1 << 17) )) && reported+=("frequency cap occurred")
  (( value & (1 << 18) )) && reported+=("throttling occurred")
  (( value & (1 << 19) )) && reported+=("soft temperature limit occurred")

  if [[ "${#reported[@]}" -gt 0 ]]; then
    printf 'Raspberry Pi power or thermal throttling reported since boot: %s\n' "${reported[*]}" >&2
    return 1
  fi
}

check_chrony_gps_time_config() {
  python3 - <<'PY'
from pathlib import Path

path = Path("/etc/chrony/chrony.conf")
expected = "refclock SHM 0 offset 0.5 delay 0.1 refid GPS"
try:
    text = path.read_text(encoding="utf-8")
except OSError as exc:
    raise SystemExit(f"could not read chrony config {path}: {exc}") from exc
configured = any(
    line.strip() == expected
    for line in text.splitlines()
    if not line.lstrip().startswith("#")
)
if not configured:
    raise SystemExit(f"{path} does not contain an uncommented NOAA Navionics GPSD SHM 0 time source")
PY
}

check_launcher_env_production_settings() {
  local path="$1"
  python3 - "$path" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1]).expanduser()
try:
    lines = path.read_text(encoding="utf-8").splitlines()
except OSError as exc:
    raise SystemExit(f"could not read launcher environment {path}: {exc}") from exc
values = {}
for raw_line in lines:
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    values[key.strip()] = value.strip()

def optional_positive_integer(key):
    value = values.get(key)
    if value is not None and (not value.isdigit() or int(value) <= 0):
        raise SystemExit(f"{key} must be a positive integer in {path}: {value!r}")

def optional_non_negative_integer(key):
    value = values.get(key)
    if value is not None and (not value.isdigit() or int(value) < 0):
        raise SystemExit(f"{key} must be a non-negative integer in {path}: {value!r}")

optional_positive_integer("NOAA_NAVIONICS_READINESS_ATTEMPTS")
optional_non_negative_integer("NOAA_NAVIONICS_READINESS_RETRY_DELAY")
optional_non_negative_integer("NOAA_NAVIONICS_WARNING_SECONDS")
optional_non_negative_integer("NOAA_NAVIONICS_OPENCPN_RESTARTS")
optional_non_negative_integer("NOAA_NAVIONICS_OPENCPN_RESTART_DELAY")
value = values.get("NOAA_NAVIONICS_START_ON_FAILED_READINESS")
if value is None:
    raise SystemExit(0)
normalized = value.lower()
if normalized in {"1", "yes", "true", "on"}:
    raise SystemExit(
        f"NOAA_NAVIONICS_START_ON_FAILED_READINESS is enabled in {path}; "
        "production dock verification requires fail-closed chartplotter startup"
    )
if normalized not in {"0", "no", "false", "off"}:
    raise SystemExit(f"NOAA_NAVIONICS_START_ON_FAILED_READINESS has an invalid value in {path}: {value!r}")
PY
}

first_shell_symlink_ancestor() {
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

check_user_regular_file_integrity() {
  local path="$1"
  local label="$2"
  local expected_uid
  local stat_output
  local owner_uid
  local mode_text
  local mode
  local symlink_component

  expected_uid="$(id -u)"
  if [[ -L "$path" ]]; then
    printf '%s is a symlink: %s\n' "$label" "$path" >&2
    return 1
  fi
  if symlink_component="$(first_shell_symlink_ancestor "$(dirname "$path")")"; then
    printf '%s path contains a symlink: %s\n' "$label" "$symlink_component" >&2
    return 1
  fi
  if [[ ! -f "$path" ]]; then
    printf '%s is not a regular file: %s\n' "$label" "$path" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$path" 2>/dev/null)" || {
    printf 'could not inspect %s: %s\n' "$label" "$path" >&2
    return 1
  }
  owner_uid="${stat_output%% *}"
  mode_text="${stat_output#* }"
  if [[ "$owner_uid" != "$expected_uid" ]]; then
    printf '%s is owned by uid %s, expected %s: %s\n' "$label" "$owner_uid" "$expected_uid" "$path" >&2
    return 1
  fi
  mode=$((8#$mode_text))
  if (( mode & 022 )); then
    printf '%s has permissions %s, expected no group/other write bits: %s\n' "$label" "$mode_text" "$path" >&2
    return 1
  fi
}

check_user_private_regular_file_integrity() {
  local path="$1"
  local label="$2"
  local mode_text

  check_user_regular_file_integrity "$path" "$label" || return 1
  mode_text="$(stat -c '%a' "$path" 2>/dev/null)" || {
    printf 'could not inspect %s: %s\n' "$label" "$path" >&2
    return 1
  }
  if [[ "$mode_text" != "600" && "$mode_text" != "0600" ]]; then
    printf '%s has permissions %s, expected private 0600: %s\n' "$label" "$mode_text" "$path" >&2
    return 1
  fi
}

check_user_executable_file_integrity() {
  local path="$1"
  local label="$2"

  check_user_regular_file_integrity "$path" "$label" || return 1
  if [[ ! -x "$path" ]]; then
    printf '%s is not executable: %s\n' "$label" "$path" >&2
    return 1
  fi
}

check_user_private_directory_integrity() {
  local path="$1"
  local label="$2"
  local expected_uid
  local stat_output
  local owner_uid
  local mode_text
  local mode
  local symlink_component

  expected_uid="$(id -u)"
  if [[ -L "$path" ]]; then
    printf '%s is a symlink: %s\n' "$label" "$path" >&2
    return 1
  fi
  if symlink_component="$(first_shell_symlink_ancestor "$(dirname "$path")")"; then
    printf '%s path contains a symlink: %s\n' "$label" "$symlink_component" >&2
    return 1
  fi
  if [[ ! -d "$path" ]]; then
    printf '%s is not a directory: %s\n' "$label" "$path" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$path" 2>/dev/null)" || {
    printf 'could not inspect %s: %s\n' "$label" "$path" >&2
    return 1
  }
  owner_uid="${stat_output%% *}"
  mode_text="${stat_output#* }"
  if [[ "$owner_uid" != "$expected_uid" ]]; then
    printf '%s is owned by uid %s, expected %s: %s\n' "$label" "$owner_uid" "$expected_uid" "$path" >&2
    return 1
  fi
  mode=$((8#$mode_text))
  if (( mode & 022 )); then
    printf '%s has permissions %s, expected no group/other write bits: %s\n' "$label" "$mode_text" "$path" >&2
    return 1
  fi
}

check_optional_user_regular_file_integrity() {
  local path="$1"
  local label="$2"

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi
  check_user_regular_file_integrity "$path" "$label"
}

check_command_symlink_to_private_venv() {
  local path="$1"
  local label="$2"
  local expected_target="$3"
  local actual_target
  local resolved_target
  local resolved_venv

  if [[ ! -L "$path" ]]; then
    printf '%s is not the expected symlink: %s\n' "$label" "$path" >&2
    return 1
  fi
  actual_target="$(readlink "$path" 2>/dev/null)" || {
    printf 'could not read %s symlink: %s\n' "$label" "$path" >&2
    return 1
  }
  if [[ "$actual_target" != "$expected_target" ]]; then
    printf '%s symlink target is %s, expected %s\n' "$label" "$actual_target" "$expected_target" >&2
    return 1
  fi
  resolved_target="$(readlink -f "$path" 2>/dev/null)" || {
    printf 'could not resolve %s symlink target: %s\n' "$label" "$path" >&2
    return 1
  }
  resolved_venv="$(readlink -f "$venv_dir" 2>/dev/null)" || {
    printf 'could not resolve private venv directory: %s\n' "$venv_dir" >&2
    return 1
  }
  case "$resolved_target" in
    "$resolved_venv"/bin/*)
      ;;
    *)
      printf '%s resolves outside private venv: %s\n' "$label" "$resolved_target" >&2
      return 1
      ;;
  esac
  check_user_executable_file_integrity "$resolved_target" "$label target" || return 1
}

check_root_regular_file_integrity() {
  local path="$1"
  local label="$2"
  local stat_output
  local owner_uid
  local mode_text
  local mode
  local symlink_component

  if [[ -L "$path" ]]; then
    printf '%s is a symlink: %s\n' "$label" "$path" >&2
    return 1
  fi
  if symlink_component="$(first_shell_symlink_ancestor "$(dirname "$path")")"; then
    printf '%s path contains a symlink: %s\n' "$label" "$symlink_component" >&2
    return 1
  fi
  if [[ ! -f "$path" ]]; then
    printf '%s is not a regular file: %s\n' "$label" "$path" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$path" 2>/dev/null)" || {
    printf 'could not inspect %s: %s\n' "$label" "$path" >&2
    return 1
  }
  owner_uid="${stat_output%% *}"
  mode_text="${stat_output#* }"
  if [[ "$owner_uid" != "0" ]]; then
    printf '%s is owned by uid %s, expected root: %s\n' "$label" "$owner_uid" "$path" >&2
    return 1
  fi
  mode=$((8#$mode_text))
  if (( mode & 022 )); then
    printf '%s has permissions %s, expected no group/other write bits: %s\n' "$label" "$mode_text" "$path" >&2
    return 1
  fi
}

check_root_executable_file_integrity() {
  local path="$1"
  local label="$2"

  check_root_regular_file_integrity "$path" "$label" || return 1
  if [[ ! -x "$path" ]]; then
    printf '%s is not executable: %s\n' "$label" "$path" >&2
    return 1
  fi
}

check_opencpn_command_integrity() {
  local path

  path="$(command -v opencpn 2>/dev/null)" || {
    printf 'OpenCPN command was not found on PATH\n' >&2
    return 1
  }
  case "$path" in
    /*)
      ;;
    *)
      printf 'OpenCPN command path is not absolute: %s\n' "$path" >&2
      return 1
      ;;
  esac
  check_root_directory_integrity "$(dirname "$path")" "OpenCPN command directory" || return 1
  check_root_executable_file_integrity "$path" "OpenCPN command"
}

check_root_directory_integrity() {
  local path="$1"
  local label="$2"
  local stat_output
  local owner_uid
  local mode_text
  local mode
  local symlink_component

  if [[ -L "$path" ]]; then
    printf '%s is a symlink: %s\n' "$label" "$path" >&2
    return 1
  fi
  if symlink_component="$(first_shell_symlink_ancestor "$(dirname "$path")")"; then
    printf '%s path contains a symlink: %s\n' "$label" "$symlink_component" >&2
    return 1
  fi
  if [[ ! -d "$path" ]]; then
    printf '%s is not a directory: %s\n' "$label" "$path" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$path" 2>/dev/null)" || {
    printf 'could not inspect %s: %s\n' "$label" "$path" >&2
    return 1
  }
  owner_uid="${stat_output%% *}"
  mode_text="${stat_output#* }"
  if [[ "$owner_uid" != "0" ]]; then
    printf '%s is owned by uid %s, expected root: %s\n' "$label" "$owner_uid" "$path" >&2
    return 1
  fi
  mode=$((8#$mode_text))
  if (( mode & 022 )); then
    printf '%s has permissions %s, expected no group/other write bits: %s\n' "$label" "$mode_text" "$path" >&2
    return 1
  fi
}

launcher_env_value() {
  local key="$1"
  local default="$2"
  python3 - "$launcher_env" "$key" "$default" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1]).expanduser()
key = sys.argv[2]
default = sys.argv[3]
try:
    lines = path.read_text(encoding="utf-8").splitlines()
except OSError:
    print(default)
    raise SystemExit(0)
for raw_line in lines:
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    found_key, value = line.split("=", 1)
    if found_key.strip() == key:
        print(value.strip())
        raise SystemExit(0)
print(default)
PY
}

positive_integer_or_default() {
  local value="$1"
  local default="$2"
  if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}

non_negative_integer_or_default() {
  local value="$1"
  local default="$2"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}

set_chartplotter_start_timeout_from_launcher_env() {
  local readiness_attempts
  local readiness_retry_delay
  local warning_seconds
  local calculated_timeout
  readiness_attempts="$(positive_integer_or_default "$(launcher_env_value NOAA_NAVIONICS_READINESS_ATTEMPTS 3)" 3)"
  readiness_retry_delay="$(non_negative_integer_or_default "$(launcher_env_value NOAA_NAVIONICS_READINESS_RETRY_DELAY 10)" 10)"
  warning_seconds="$(non_negative_integer_or_default "$(launcher_env_value NOAA_NAVIONICS_WARNING_SECONDS 8)" 8)"
  calculated_timeout=$((gps_seconds * readiness_attempts + readiness_retry_delay * (readiness_attempts - 1) + warning_seconds + 60))
  if [[ "$calculated_timeout" -gt "$chartplotter_start_timeout_floor" ]]; then
    chartplotter_start_timeout="$calculated_timeout"
  else
    chartplotter_start_timeout="$chartplotter_start_timeout_floor"
  fi
}

stable_gps_device_path() {
  case "$1" in
    /dev/serial/by-id/*)
      local suffix="${1#/dev/serial/by-id/}"
      [[ -n "$suffix" && "$suffix" != */* && "$suffix" != "." && "$suffix" != ".." && "$suffix" =~ ^[A-Za-z0-9._:+@-]+$ ]]
      return
      ;;
    /dev/serial0|/dev/serial1|/dev/gps)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

volatile_usb_device_path() {
  case "$(basename "$1")" in
    ttyUSB*|ttyACM*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_unit_install_target() {
  local path="$1"
  local expected_target="$2"
  python3 - "$path" "$expected_target" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1]).expanduser()
expected = sys.argv[2]
if not path.is_file():
    raise SystemExit(f"missing unit file: {path}")
try:
    lines = path.read_text(encoding="utf-8").splitlines()
except OSError as exc:
    raise SystemExit(f"could not read unit file {path}: {exc}") from exc
targets = []
section = ""
for raw_line in lines:
    line = raw_line.strip()
    if not line or line.startswith(("#", ";")):
        continue
    if line.startswith("[") and line.endswith("]"):
        section = line[1:-1].strip()
        continue
    if section == "Install" and line.startswith("WantedBy="):
        targets.extend(target for target in line.split("=", 1)[1].split() if target)
if expected not in targets:
    detail = ",".join(targets) if targets else "<missing>"
    raise SystemExit(f"{path} [Install] WantedBy={detail}, expected {expected}")
PY
}

check_chartplotter_log_after_boot() {
  local path="$1"
  python3 - "$path" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import os
import sys
import time

path = Path(sys.argv[1]).expanduser()
if path.is_symlink():
    raise SystemExit(f"launcher log is a symlink: {path}")
cache_dir = path.parent
if cache_dir.is_symlink():
    raise SystemExit(f"launcher log cache directory is a symlink: {cache_dir}")
if cache_dir.parent.is_symlink():
    raise SystemExit(f"launcher log cache parent directory is a symlink: {cache_dir.parent}")
current = cache_dir.parent
for candidate in [current, *current.parents]:
    if candidate.is_symlink():
        raise SystemExit(f"launcher log cache path contains a symlink: {candidate}")
if not path.exists():
    raise SystemExit(f"missing launcher log: {path}")
if not path.is_file():
    raise SystemExit(f"launcher log is not a regular file: {path}")
try:
    cache_parent_stat = cache_dir.parent.stat()
    cache_stat = cache_dir.stat()
    log_stat = path.stat()
except OSError as exc:
    raise SystemExit(f"could not inspect launcher log path {path}: {exc}") from exc
expected_uid = os.getuid()
if cache_parent_stat.st_uid != expected_uid:
    raise SystemExit(
        f"launcher log cache parent directory is owned by uid {cache_parent_stat.st_uid}, "
        f"expected {expected_uid}: {cache_dir.parent}"
    )
cache_parent_mode = cache_parent_stat.st_mode & 0o777
if cache_parent_mode != 0o700:
    raise SystemExit(
        f"launcher log cache parent directory has permissions {cache_parent_mode:04o}, "
        f"expected private 0700: {cache_dir.parent}"
    )
if cache_stat.st_uid != expected_uid:
    raise SystemExit(
        f"launcher log cache directory is owned by uid {cache_stat.st_uid}, expected {expected_uid}: {cache_dir}"
    )
cache_mode = cache_stat.st_mode & 0o777
if cache_mode != 0o700:
    raise SystemExit(
        f"launcher log cache directory has permissions {cache_mode:04o}, expected private 0700: {cache_dir}"
    )
if log_stat.st_uid != expected_uid:
    raise SystemExit(f"launcher log is owned by uid {log_stat.st_uid}, expected {expected_uid}: {path}")
log_mode = log_stat.st_mode & 0o777
if log_mode != 0o600:
    raise SystemExit(f"launcher log has permissions {log_mode:04o}, expected private 0600: {path}")
text = path.read_text(encoding="utf-8", errors="replace")
startup_marker = "Starting NOAA Navionics chartplotter launcher"
launch_marker = "Launching OpenCPN with ENC processing."
duplicate_marker = "OpenCPN is already running; leaving the existing chartplotter instance in place."
exit_marker = "OpenCPN exited with status"
startup_index = text.rfind(startup_marker)
if startup_index < 0:
    raise SystemExit("launcher log does not contain startup marker")
latest_startup = text[startup_index:]
if launch_marker not in latest_startup and duplicate_marker not in latest_startup:
    raise SystemExit("launcher log does not contain OpenCPN launch or duplicate marker")
if "NOAA Navionics preflight failed" in latest_startup:
    raise SystemExit("launcher reported failed readiness before OpenCPN startup")
if exit_marker in latest_startup:
    raise SystemExit("launcher log shows OpenCPN exited after current-boot startup")
if "xset command(s) failed" in latest_startup:
    raise SystemExit("launcher failed to disable one or more display power settings")
if "xset is unavailable" in latest_startup:
    raise SystemExit("launcher could not find xset for display power settings")
try:
    uptime_seconds = float(Path("/proc/uptime").read_text(encoding="ascii").split()[0])
except Exception as exc:
    raise SystemExit(f"could not read /proc/uptime: {exc}") from exc
boot_epoch = time.time() - uptime_seconds
line_start = text.rfind("\n", 0, startup_index) + 1
line_prefix = text[line_start:startup_index]
if not line_prefix.startswith("[") or "]" not in line_prefix:
    raise SystemExit("launcher startup marker has no timestamp")
timestamp_text = line_prefix[1:line_prefix.index("]")]
try:
    startup_time = datetime.fromisoformat(timestamp_text.replace("Z", "+00:00")).astimezone(timezone.utc)
except ValueError as exc:
    raise SystemExit(f"invalid launcher startup timestamp: {timestamp_text}") from exc
if startup_time.timestamp() + 5 < boot_epoch:
    age = boot_epoch - startup_time.timestamp()
    raise SystemExit(f"launcher startup marker is older than current boot by {age:.0f}s")
mtime = path.stat().st_mtime
if mtime + 5 < boot_epoch:
    age = boot_epoch - mtime
    raise SystemExit(f"launcher log is older than current boot by {age:.0f}s")
PY
}

opencpn_running() {
  local pid
  while IFS= read -r pid; do
    if opencpn_process_active "$pid"; then
      return 0
    fi
  done < <(pgrep -u "$(id -u)" -x opencpn 2>/dev/null || true)
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

opencpn_process_supervised_by_launcher() {
  local pid="$1"
  local launcher_pid="$2"
  local parent_pid=""
  if [[ ! "$pid" =~ ^[0-9]+$ || ! "$launcher_pid" =~ ^[0-9]+$ || ! -r "/proc/${pid}/status" ]]; then
    return 1
  fi
  parent_pid="$(awk '/^PPid:/ {print $2; exit}' "/proc/${pid}/status" 2>/dev/null || true)"
  [[ "$parent_pid" == "$launcher_pid" ]]
}

launcher_lock_pid() {
  local owner_pid=""
  if [[ ! -r "${launcher_lock}/pid" ]]; then
    return 1
  fi
  read -r owner_pid <"${launcher_lock}/pid" || return 1
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$owner_pid"
}

supervised_opencpn_pids() {
  local launcher_pid
  local pid
  launcher_pid="$(launcher_lock_pid)" || return 1
  while IFS= read -r pid; do
    if opencpn_process_active "$pid" && opencpn_process_supervised_by_launcher "$pid" "$launcher_pid"; then
      printf '%s\n' "$pid"
    fi
  done < <(pgrep -u "$(id -u)" -x opencpn 2>/dev/null || true)
}

opencpn_supervised_running() {
  [[ -n "$(supervised_opencpn_pids)" ]]
}

check_opencpn_process_executable_integrity() {
  local pid
  local executable
  local checked=0
  while IFS= read -r pid; do
    checked=1
    executable="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
    if [[ -z "$executable" ]]; then
      printf 'launcher-supervised OpenCPN executable is unreadable for pid %s\n' "$pid" >&2
      return 1
    fi
    case "$executable" in
      /*)
        ;;
      *)
        printf 'launcher-supervised OpenCPN executable path is not absolute for pid %s: %s\n' "$pid" "$executable" >&2
        return 1
        ;;
    esac
    check_root_directory_integrity "$(dirname "$executable")" "launcher-supervised OpenCPN executable directory" || return 1
    check_root_executable_file_integrity "$executable" "launcher-supervised OpenCPN executable" || return 1
  done < <(supervised_opencpn_pids)
  if [[ "$checked" -eq 0 ]]; then
    printf 'no launcher-supervised OpenCPN process found for executable integrity check\n' >&2
    return 1
  fi
}

check_chartplotter_xauthority_integrity() {
  local xauthority="$1"
  if [[ -z "$xauthority" ]]; then
    return 0
  fi
  case "$xauthority" in
    /*)
      ;;
    *)
      printf 'chartplotter launcher XAUTHORITY path is not absolute: %s\n' "$xauthority" >&2
      return 1
      ;;
  esac
  check_user_regular_file_integrity "$xauthority" "chartplotter launcher XAUTHORITY file"
}

check_opencpn_process_display_environment() {
  local launcher_pid
  local key
  local value
  local launcher_display=""
  local launcher_xauthority=""
  local opencpn_display
  local opencpn_xauthority
  local pid
  local checked=0
  launcher_pid="$(launcher_lock_pid)" || {
    printf 'chartplotter launcher lock pid is unreadable; cannot compare OpenCPN display environment\n' >&2
    return 1
  }
  if [[ ! -r "/proc/${launcher_pid}/environ" ]]; then
    printf 'chartplotter launcher environment is unreadable for pid: %s\n' "$launcher_pid" >&2
    return 1
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      DISPLAY)
        launcher_display="$value"
        ;;
      XAUTHORITY)
        launcher_xauthority="$value"
        ;;
    esac
  done < <(tr '\0' '\n' <"/proc/${launcher_pid}/environ" 2>/dev/null || true)
  if [[ -z "$launcher_display" ]]; then
    printf 'chartplotter launcher has no DISPLAY environment; cannot verify OpenCPN display environment\n' >&2
    return 1
  fi
  check_chartplotter_xauthority_integrity "$launcher_xauthority" || return 1
  while IFS= read -r pid; do
    checked=1
    opencpn_display=""
    opencpn_xauthority=""
    if [[ ! -r "/proc/${pid}/environ" ]]; then
      printf 'launcher-supervised OpenCPN environment is unreadable for pid: %s\n' "$pid" >&2
      return 1
    fi
    while IFS='=' read -r key value; do
      case "$key" in
        DISPLAY)
          opencpn_display="$value"
          ;;
        XAUTHORITY)
          opencpn_xauthority="$value"
          ;;
        NOAA_NAVIONICS_*)
          printf 'launcher-supervised OpenCPN inherited NOAA_NAVIONICS_* environment override %s\n' "$key" >&2
          return 1
          ;;
      esac
    done < <(tr '\0' '\n' <"/proc/${pid}/environ" 2>/dev/null || true)
    if [[ "$opencpn_display" != "$launcher_display" ]]; then
      printf 'launcher-supervised OpenCPN DISPLAY %s does not match launcher DISPLAY %s for pid %s\n' "${opencpn_display:-<empty>}" "$launcher_display" "$pid" >&2
      return 1
    fi
    if [[ "$opencpn_xauthority" != "$launcher_xauthority" ]]; then
      printf 'launcher-supervised OpenCPN XAUTHORITY %s does not match launcher XAUTHORITY %s for pid %s\n' "${opencpn_xauthority:-<empty>}" "${launcher_xauthority:-<empty>}" "$pid" >&2
      return 1
    fi
  done < <(supervised_opencpn_pids)
  if [[ "$checked" -eq 0 ]]; then
    printf 'no launcher-supervised OpenCPN process found for display environment check\n' >&2
    return 1
  fi
}

check_opencpn_enc_parse_argument() {
  local pid
  local arg
  local saw_supervised=0
  while IFS= read -r pid; do
    if [[ ! -r "/proc/${pid}/cmdline" ]]; then
      continue
    fi
    saw_supervised=1
    while IFS= read -r -d '' arg; do
      if [[ "$arg" == "-parse_all_enc" ]]; then
        return 0
      fi
    done <"/proc/${pid}/cmdline"
  done < <(supervised_opencpn_pids)
  if [[ "$saw_supervised" -eq 0 ]]; then
    printf 'no active OpenCPN process is supervised by the chartplotter launcher\n' >&2
  else
    printf 'no launcher-supervised OpenCPN process was started with -parse_all_enc\n' >&2
  fi
  return 1
}

check_opencpn_stable() {
  if ! opencpn_supervised_running; then
    printf 'no active OpenCPN process is supervised by the chartplotter launcher before stability wait\n' >&2
    return 1
  fi
  sleep "$opencpn_stability_seconds"
  if ! opencpn_supervised_running; then
    printf 'launcher-supervised OpenCPN exited within %ss of startup verification\n' "$opencpn_stability_seconds" >&2
    return 1
  fi
}

check_launcher_lock_live() {
  local cache_parent
  local cache_dir
  local expected_uid
  local cache_parent_stat_output
  local stat_output
  local cache_parent_owner_uid
  local cache_parent_mode
  local owner_uid
  local cache_mode
  local lock_mode
  local pid_mode
  local boot_id_mode
  local owner_pid=""
  local cmdline=""
  local current_boot_id=""
  local lock_boot_id=""
  local key
  local value
  cache_dir="$(dirname "$launcher_lock")"
  cache_parent="$(dirname "$cache_dir")"
  expected_uid="$(id -u)"
  if [[ -L "$cache_parent" || -L "$cache_dir" || -L "$launcher_lock" || -L "${launcher_lock}/pid" || -L "${launcher_lock}/boot_id" ]]; then
    printf 'chartplotter launcher lock path contains a symlink: %s\n' "$launcher_lock" >&2
    return 1
  fi
  cache_parent_stat_output="$(stat -c '%u %a' "$cache_parent" 2>/dev/null || true)"
  cache_parent_owner_uid="${cache_parent_stat_output%% *}"
  cache_parent_mode="${cache_parent_stat_output#* }"
  if [[ -z "$cache_parent_stat_output" || "$cache_parent_owner_uid" != "$expected_uid" ]]; then
    printf 'chartplotter launcher cache parent directory is owned by uid %s, expected %s: %s\n' "${cache_parent_owner_uid:-<missing>}" "$expected_uid" "$cache_parent" >&2
    return 1
  fi
  if [[ "$cache_parent_mode" != "700" ]]; then
    printf 'chartplotter launcher cache parent directory has permissions %s, expected 700: %s\n' "${cache_parent_mode:-<missing>}" "$cache_parent" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$cache_dir" 2>/dev/null || true)"
  owner_uid="${stat_output%% *}"
  cache_mode="${stat_output#* }"
  if [[ -z "$stat_output" || "$owner_uid" != "$expected_uid" ]]; then
    printf 'chartplotter launcher cache directory is owned by uid %s, expected %s: %s\n' "${owner_uid:-<missing>}" "$expected_uid" "$cache_dir" >&2
    return 1
  fi
  if [[ "$cache_mode" != "700" ]]; then
    printf 'chartplotter launcher cache directory has permissions %s, expected 700: %s\n' "${cache_mode:-<missing>}" "$cache_dir" >&2
    return 1
  fi
  if [[ ! -e "$launcher_lock" ]]; then
    printf 'chartplotter launcher lock is missing while OpenCPN is expected to be supervised: %s\n' "$launcher_lock" >&2
    return 1
  fi
  if [[ ! -d "$launcher_lock" ]]; then
    printf 'chartplotter launcher lock is not a directory: %s\n' "$launcher_lock" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$launcher_lock" 2>/dev/null || true)"
  owner_uid="${stat_output%% *}"
  lock_mode="${stat_output#* }"
  if [[ -z "$stat_output" || "$owner_uid" != "$expected_uid" ]]; then
    printf 'chartplotter launcher lock directory is owned by uid %s, expected %s: %s\n' "${owner_uid:-<missing>}" "$expected_uid" "$launcher_lock" >&2
    return 1
  fi
  if [[ "$lock_mode" != "700" ]]; then
    printf 'chartplotter launcher lock directory has permissions %s, expected 700: %s\n' "${lock_mode:-<missing>}" "$launcher_lock" >&2
    return 1
  fi
  if [[ ! -r "${launcher_lock}/pid" ]]; then
    printf 'chartplotter launcher lock exists without a readable pid file: %s\n' "$launcher_lock" >&2
    return 1
  fi
  if [[ ! -r "${launcher_lock}/boot_id" ]]; then
    printf 'chartplotter launcher lock exists without a readable boot ID file: %s\n' "$launcher_lock" >&2
    return 1
  fi
  if [[ ! -f "${launcher_lock}/pid" ]]; then
    printf 'chartplotter launcher lock pid is not a regular file: %s\n' "${launcher_lock}/pid" >&2
    return 1
  fi
  if [[ ! -f "${launcher_lock}/boot_id" ]]; then
    printf 'chartplotter launcher lock boot ID is not a regular file: %s\n' "${launcher_lock}/boot_id" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "${launcher_lock}/pid" 2>/dev/null || true)"
  owner_uid="${stat_output%% *}"
  pid_mode="${stat_output#* }"
  if [[ -z "$stat_output" || "$owner_uid" != "$expected_uid" ]]; then
    printf 'chartplotter launcher lock pid file is owned by uid %s, expected %s: %s\n' "${owner_uid:-<missing>}" "$expected_uid" "${launcher_lock}/pid" >&2
    return 1
  fi
  if [[ "$pid_mode" != "600" ]]; then
    printf 'chartplotter launcher lock pid file has permissions %s, expected 600: %s\n' "${pid_mode:-<missing>}" "${launcher_lock}/pid" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "${launcher_lock}/boot_id" 2>/dev/null || true)"
  owner_uid="${stat_output%% *}"
  boot_id_mode="${stat_output#* }"
  if [[ -z "$stat_output" || "$owner_uid" != "$expected_uid" ]]; then
    printf 'chartplotter launcher lock boot ID file is owned by uid %s, expected %s: %s\n' "${owner_uid:-<missing>}" "$expected_uid" "${launcher_lock}/boot_id" >&2
    return 1
  fi
  if [[ "$boot_id_mode" != "600" ]]; then
    printf 'chartplotter launcher lock boot ID file has permissions %s, expected 600: %s\n' "${boot_id_mode:-<missing>}" "${launcher_lock}/boot_id" >&2
    return 1
  fi
  current_boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  if [[ -z "$current_boot_id" ]]; then
    printf 'could not read current boot ID for chartplotter launcher lock verification\n' >&2
    return 1
  fi
  read -r lock_boot_id <"${launcher_lock}/boot_id" || lock_boot_id=""
  if [[ "$lock_boot_id" != "$current_boot_id" ]]; then
    printf 'chartplotter launcher lock boot ID %s does not match current boot %s\n' "${lock_boot_id:-<empty>}" "$current_boot_id" >&2
    return 1
  fi
  read -r owner_pid <"${launcher_lock}/pid" || owner_pid=""
  if [[ ! "$owner_pid" =~ ^[0-9]+$ ]]; then
    printf 'chartplotter launcher lock pid is invalid: %s\n' "${owner_pid:-<empty>}" >&2
    return 1
  fi
  if ! kill -0 "$owner_pid" 2>/dev/null; then
    printf 'chartplotter launcher lock owner is not running: %s\n' "$owner_pid" >&2
    return 1
  fi
  if [[ ! -r "/proc/${owner_pid}/cmdline" ]]; then
    printf 'chartplotter launcher lock owner cmdline is unreadable: %s\n' "$owner_pid" >&2
    return 1
  fi
  cmdline="$(tr '\0' ' ' <"/proc/${owner_pid}/cmdline" 2>/dev/null || true)"
  if [[ "$cmdline" != *"noaa-navionics-start-chartplotter"* && "$cmdline" != *"start_chartplotter.sh"* ]]; then
    printf 'chartplotter launcher lock owner is not the launcher: %s\n' "${cmdline:-<empty>}" >&2
    return 1
  fi
  if [[ ! -r "/proc/${owner_pid}/environ" ]]; then
    printf 'chartplotter launcher environment is unreadable for pid: %s\n' "$owner_pid" >&2
    return 1
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      NOAA_NAVIONICS_*)
        printf 'chartplotter launcher live environment overrides %s; production verification requires launcher settings from %s only\n' "$key" "$launcher_env" >&2
        return 1
        ;;
    esac
  done < <(tr '\0' '\n' <"/proc/${owner_pid}/environ" 2>/dev/null || true)
}

check_live_display_power_disabled() {
  local owner_pid=""
  local key
  local value
  local display=""
  local xauthority=""
  local output=""

  if [[ ! -r "${launcher_lock}/pid" ]]; then
    printf 'chartplotter launcher lock pid is unreadable: %s\n' "${launcher_lock}/pid" >&2
    return 1
  fi
  read -r owner_pid <"${launcher_lock}/pid" || owner_pid=""
  if [[ ! "$owner_pid" =~ ^[0-9]+$ || ! -r "/proc/${owner_pid}/environ" ]]; then
    printf 'chartplotter launcher environment is unreadable for pid: %s\n' "${owner_pid:-<empty>}" >&2
    return 1
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      DISPLAY)
        display="$value"
        ;;
      XAUTHORITY)
        xauthority="$value"
        ;;
    esac
  done < <(tr '\0' '\n' <"/proc/${owner_pid}/environ" 2>/dev/null || true)
  if [[ -z "$display" ]]; then
    printf 'chartplotter launcher has no DISPLAY environment; cannot verify live display power settings\n' >&2
    return 1
  fi
  check_chartplotter_xauthority_integrity "$xauthority" || return 1
  if [[ -n "$xauthority" ]]; then
    output="$(DISPLAY="$display" XAUTHORITY="$xauthority" xset q 2>&1)" || {
      printf 'xset q failed for chartplotter display %s: %s\n' "$display" "$output" >&2
      return 1
    }
  else
    output="$(DISPLAY="$display" xset q 2>&1)" || {
      printf 'xset q failed for chartplotter display %s: %s\n' "$display" "$output" >&2
      return 1
    }
  fi
  if ! printf '%s\n' "$output" | grep -Eq 'timeout:[[:space:]]*0([[:space:]]|$)'; then
    printf 'display screen saver timeout is not disabled on %s:\n%s\n' "$display" "$output" >&2
    return 1
  fi
  if ! printf '%s\n' "$output" | grep -Eq 'prefer blanking:[[:space:]]*no'; then
    printf 'display blanking preference is not disabled on %s:\n%s\n' "$display" "$output" >&2
    return 1
  fi
  if printf '%s\n' "$output" | grep -Fq 'Server does not have the DPMS Extension'; then
    return 0
  fi
  if printf '%s\n' "$output" | grep -Fq 'DPMS'; then
    if ! printf '%s\n' "$output" | grep -Fq 'DPMS is Disabled'; then
      printf 'display DPMS is not disabled on %s:\n%s\n' "$display" "$output" >&2
      return 1
    fi
  else
    printf 'display DPMS state is not reported on %s:\n%s\n' "$display" "$output" >&2
    return 1
  fi
}

wait_for_chartplotter_started() {
  local deadline=$((SECONDS + chartplotter_start_timeout))
  local last_detail=""
  local check_output
  check_output="$(mktemp)"
  while true; do
    if check_chartplotter_log_after_boot "$log_file" >"$check_output" 2>&1; then
      if opencpn_running; then
        rm -f "$check_output"
        return 0
      fi
      last_detail="OpenCPN is not running yet"
    else
      last_detail="$(cat "$check_output" 2>/dev/null || true)"
    fi
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf '%s\n' "${last_detail:-chartplotter did not start before timeout}" >&2
      rm -f "$check_output"
      return 1
    fi
    sleep "$chartplotter_start_interval"
  done
}

wait_for_chrony_gps_source() {
  local deadline=$((SECONDS + gps_seconds))
  local output=""
  while true; do
    output="$(chronyc sources -n 2>&1 || true)"
    if printf '%s\n' "$output" | grep -Eq '^#[*+].*GPS'; then
      return 0
    fi
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf '%s\n' "${output:-chrony did not report a usable GPS source}" >&2
      return 1
    fi
    sleep 1
  done
}

check_preflight_service_succeeded() {
  local deadline=$((SECONDS + gps_seconds + 60))
  local state=""
  while true; do
    state="$(systemctl --user show noaa-navionics-preflight.service \
      -p ActiveState \
      -p Result \
      -p ExecMainStatus \
      -p ExecMainStartTimestampMonotonic 2>/dev/null || true)"
    if printf '%s\n' "$state" | grep -Fxq 'Result=success' \
      && printf '%s\n' "$state" | grep -Fxq 'ExecMainStatus=0' \
      && printf '%s\n' "$state" | grep -Eq '^ExecMainStartTimestampMonotonic=[1-9][0-9]*$'; then
      return 0
    fi
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf '%s\n' "${state:-could not read noaa-navionics-preflight.service state}" >&2
      return 1
    fi
    sleep 1
  done
}

check_recent_track_log() {
  local config_path="$1"
  python3 - "$config_path" "$gps_seconds" <<'PY'
from configparser import ConfigParser
from datetime import datetime, timezone
from pathlib import Path
import math
import os
import re
import sys
import time

config_path = Path(sys.argv[1]).expanduser()
timeout = max(10.0, float(sys.argv[2]))
max_trackpoint_age = 600.0
parser = ConfigParser()
if not parser.read(config_path):
    raise SystemExit(f"could not read config: {config_path}")
chart_output = parser.get("charts", "output", fallback="~/charts/noaa-enc").strip()
track_output = parser.get("tracking", "output", fallback=chart_output).strip()
if not track_output:
    raise SystemExit("tracking.output is empty")
track_output_path = Path(track_output).expanduser()
tracks_dir = track_output_path / "tracks"
try:
    uptime_seconds = float(Path("/proc/uptime").read_text(encoding="ascii").split()[0])
except Exception as exc:
    raise SystemExit(f"could not read /proc/uptime: {exc}") from exc
boot_epoch = time.time() - uptime_seconds
deadline = time.monotonic() + timeout
last_detail = ""
def first_symlink_ancestor(path):
    current = Path(path).expanduser()
    for candidate in [current, *current.parents]:
        if candidate.is_symlink():
            return candidate
    return None

def trackpoint_position(trackpoint):
    tag_match = re.search(r"<trkpt\b([^>]*)>", trackpoint)
    if not tag_match:
        return None, "GPX trackpoint has no opening trkpt tag"
    attrs = tag_match.group(1)
    lat_match = re.search(r'\blat="([^"]+)"', attrs)
    lon_match = re.search(r'\blon="([^"]+)"', attrs)
    if not lat_match or not lon_match:
        return None, "GPX trackpoint is missing latitude or longitude"
    try:
        latitude = float(lat_match.group(1))
        longitude = float(lon_match.group(1))
    except ValueError:
        return None, f"GPX trackpoint has non-numeric coordinates: {lat_match.group(1)}, {lon_match.group(1)}"
    if not math.isfinite(latitude) or not math.isfinite(longitude):
        return None, f"GPX trackpoint has non-finite coordinates: {lat_match.group(1)}, {lon_match.group(1)}"
    if not (-90.0 <= latitude <= 90.0):
        return None, f"GPX trackpoint latitude is outside -90..90: {latitude}"
    if not (-180.0 <= longitude <= 180.0):
        return None, f"GPX trackpoint longitude is outside -180..180: {longitude}"
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        return None, "GPX trackpoint has invalid 0,0 coordinates"
    return (latitude, longitude), ""

def trackpoint_quality(trackpoint):
    sat_match = re.search(r"<sat>([^<]+)</sat>", trackpoint)
    hdop_match = re.search(r"<hdop>([^<]+)</hdop>", trackpoint)
    if not sat_match and not hdop_match:
        return None, "GPX trackpoint is missing satellite or HDOP quality fields"
    quality = {"satellites": None, "hdop": None}
    if sat_match:
        sat_text = sat_match.group(1).strip()
        try:
            satellites = int(sat_text)
        except ValueError:
            return None, f"GPX trackpoint has non-numeric satellite count: {sat_text}"
        if satellites < 4:
            return None, f"GPX trackpoint has weak satellite count: {satellites}"
        quality["satellites"] = satellites
    if hdop_match:
        hdop_text = hdop_match.group(1).strip()
        try:
            hdop = float(hdop_text)
        except ValueError:
            return None, f"GPX trackpoint has non-numeric HDOP: {hdop_text}"
        if not math.isfinite(hdop):
            return None, f"GPX trackpoint has non-finite HDOP: {hdop_text}"
        if hdop > 5.0:
            return None, f"GPX trackpoint has weak HDOP: {hdop:g}"
        quality["hdop"] = hdop
    return quality, ""

while True:
    now = time.time()
    symlink_component = first_symlink_ancestor(tracks_dir)
    if symlink_component is not None:
        last_detail = f"{symlink_component} is a symlink, expected real GPX track storage"
        raise SystemExit(last_detail)
    if tracks_dir.exists():
        if tracks_dir.is_symlink():
            last_detail = f"{tracks_dir} is a symlink, expected a private GPX tracks directory"
            resolved_tracks_dir = None
        else:
            try:
                tracks_stat = tracks_dir.stat()
            except OSError as exc:
                last_detail = f"could not inspect GPX tracks directory {tracks_dir}: {exc}"
                tracks_stat = None
            if tracks_stat is not None and tracks_stat.st_uid != os.getuid():
                last_detail = f"{tracks_dir} is owned by uid {tracks_stat.st_uid}, expected {os.getuid()}"
                tracks_stat = None
            if tracks_stat is not None:
                tracks_mode = tracks_stat.st_mode & 0o777
                if tracks_mode & 0o077:
                    last_detail = f"{tracks_dir} permissions are {tracks_mode:04o}, expected private 0700"
                    tracks_stat = None
            try:
                resolved_tracks_dir = tracks_dir.resolve(strict=True) if tracks_stat is not None else None
            except OSError as exc:
                last_detail = f"could not resolve GPX tracks directory {tracks_dir}: {exc}"
                resolved_tracks_dir = None
        if resolved_tracks_dir is not None and not tracks_dir.is_dir():
            last_detail = f"{tracks_dir} is not a directory"
            resolved_tracks_dir = None
        candidates = []
        if resolved_tracks_dir is not None:
            for path in tracks_dir.glob("track-*.gpx"):
                if path.is_symlink():
                    last_detail = f"{path} is a symlink, expected a regular GPX track file"
                    continue
                if not path.is_file():
                    last_detail = f"{path} is not a regular GPX track file"
                    continue
                try:
                    stat = path.stat()
                    resolved_track = path.resolve(strict=True)
                    resolved_track.relative_to(resolved_tracks_dir)
                except OSError as exc:
                    last_detail = f"could not inspect {path}: {exc}"
                    continue
                except ValueError:
                    last_detail = f"{path} resolves outside GPX tracks directory"
                    continue
                if stat.st_uid != os.getuid():
                    last_detail = f"{path} is owned by uid {stat.st_uid}, expected {os.getuid()}"
                    continue
                mode = stat.st_mode & 0o777
                if mode & 0o077:
                    last_detail = f"{path} permissions are {mode:04o}, expected private 0600"
                    continue
                candidates.append((stat.st_mtime, path, stat))
        candidates.sort(reverse=True)
        for _mtime, path, stat in candidates:
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                last_detail = f"could not read {path}: {exc}"
                continue
            if stat.st_mtime + 5 < boot_epoch:
                continue
            trackpoint_times = re.findall(r"<trkpt\b.*?</trkpt>", text, flags=re.DOTALL)
            if not trackpoint_times:
                last_detail = f"{path} is current-boot but has no GPX trackpoint yet"
                continue
            newest_track_time = None
            newest_track_position = None
            newest_track_quality = None
            for trackpoint in trackpoint_times:
                position, position_error = trackpoint_position(trackpoint)
                if position is None:
                    last_detail = f"{path} {position_error}"
                    continue
                quality, quality_error = trackpoint_quality(trackpoint)
                if quality is None:
                    last_detail = f"{path} {quality_error}"
                    continue
                match = re.search(r"<time>([^<]+)</time>", trackpoint)
                if not match:
                    last_detail = f"{path} has GPX trackpoints but no timestamped trackpoint yet"
                    continue
                timestamp_text = match.group(1).strip()
                try:
                    track_time = datetime.fromisoformat(timestamp_text.replace("Z", "+00:00")).astimezone(timezone.utc)
                except ValueError:
                    last_detail = f"{path} has an invalid GPX trackpoint timestamp: {timestamp_text}"
                    continue
                if newest_track_time is None or track_time > newest_track_time:
                    newest_track_time = track_time
                    newest_track_position = position
                    newest_track_quality = quality
            if newest_track_time is None or newest_track_quality is None:
                last_detail = last_detail or f"{path} has GPX trackpoints but no valid timestamped quality position yet"
                continue
            track_epoch = newest_track_time.timestamp()
            if track_epoch + 5 < boot_epoch:
                age = boot_epoch - track_epoch
                last_detail = f"{path} newest GPX trackpoint is older than current boot by {age:.0f}s"
                continue
            age = now - track_epoch
            if age < -30:
                last_detail = f"{path} newest GPX trackpoint timestamp is in the future by {-age:.0f}s"
                continue
            if age > max_trackpoint_age:
                last_detail = f"{path} newest GPX trackpoint is stale: {age:.0f}s old"
                continue
            quality_pieces = []
            if newest_track_quality.get("satellites") is not None:
                quality_pieces.append(f"{newest_track_quality['satellites']} satellites")
            if newest_track_quality.get("hdop") is not None:
                quality_pieces.append(f"HDOP {newest_track_quality['hdop']:g}")
            quality_detail = (" " + "; ".join(quality_pieces)) if quality_pieces else ""
            print(f"{path} {newest_track_position[0]:.6f},{newest_track_position[1]:.6f}{quality_detail}")
            raise SystemExit(0)
    else:
        last_detail = f"{tracks_dir} does not exist"
    if time.monotonic() >= deadline:
        raise SystemExit(last_detail or f"no current-boot GPX trackpoint found under {tracks_dir}")
    time.sleep(1)
PY
}

arch="$(uname -m)"
case "$arch" in
  armv7l|aarch64)
    printf 'OK   Architecture %s\n' "$arch"
    ;;
  *)
    printf 'FAIL Architecture %s is not a Raspberry Pi target\n' "$arch"
    failures=$((failures + 1))
    ;;
esac

check "verification user is not root" check_not_root_user
check "local bin directory integrity" check_user_private_directory_integrity "$bin_dir" "local command directory"
check "app data directory integrity" check_user_private_directory_integrity "$data_dir" "NOAA Navionics data directory"
check "app config directory integrity" check_user_private_directory_integrity "$config_dir" "NOAA Navionics config directory"
check "noaa-navionics command" test -x "$bin"
check "private venv directory integrity" check_user_private_directory_integrity "$venv_dir" "private virtual environment"
check "noaa-navionics command symlink" check_command_symlink_to_private_venv "$bin" "noaa-navionics command" "${venv_dir}/bin/noaa-navionics"
check "noaa-navionics GUI command" test -x "$gui_bin"
if [[ -e "$gui_bin" || -L "$gui_bin" ]]; then
  check "noaa-navionics GUI command symlink" check_command_symlink_to_private_venv "$gui_bin" "noaa-navionics GUI command" "${venv_dir}/bin/noaa-navionics-gui"
fi
check "chartplotter launcher" test -x "$launcher"
if [[ -e "$launcher" || -L "$launcher" ]]; then
  check "chartplotter launcher file integrity" check_user_executable_file_integrity "$launcher" "chartplotter launcher"
fi
check "desktop autologin helper" test -x "$desktop_autologin"
if [[ -e "$desktop_autologin" || -L "$desktop_autologin" ]]; then
  check "desktop autologin helper file integrity" check_user_executable_file_integrity "$desktop_autologin" "desktop autologin helper"
fi
check "GPS time helper" test -x "$gps_time_helper"
if [[ -e "$gps_time_helper" || -L "$gps_time_helper" ]]; then
  check "GPS time helper file integrity" check_user_executable_file_integrity "$gps_time_helper" "GPS time helper"
fi
if [[ -x "$launcher" ]]; then
  check "chartplotter launcher readiness gate" grep -Fq 'status-report --config "$config" --gps-seconds "$gps_seconds" --output "$status_report"' "$launcher"
  check "chartplotter launcher GPS wait config" grep -Fq 'NOAA_NAVIONICS_GPS_SECONDS' "$launcher"
  check "chartplotter launcher readiness retries" grep -Fq 'NOAA_NAVIONICS_READINESS_ATTEMPTS' "$launcher"
  check "chartplotter launcher ambient environment scrub" grep -Fq 'reexec_without_ambient_launcher_settings' "$launcher"
  check "chartplotter launcher ambient environment re-exec" grep -Fq 'exec env "${env_args[@]}" "$0" "$@"' "$launcher"
  check "chartplotter launcher environment directory symlink guard" grep -Fq 'launcher environment directory is a symlink' "$launcher"
  check "chartplotter launcher fail-closed default" grep -Fq 'Not starting OpenCPN automatically because readiness failed' "$launcher"
  check "chartplotter launcher explicit fail-open override" grep -Fq 'NOAA_NAVIONICS_START_ON_FAILED_READINESS' "$launcher"
  check "chartplotter launcher OpenCPN resolver" grep -Fq 'resolve_opencpn_binary' "$launcher"
  check "chartplotter launcher OpenCPN binary integrity" grep -Fq 'validate_opencpn_binary_candidate' "$launcher"
  check "chartplotter launcher Pi OpenCPN root owner" grep -Fq 'expected root on Raspberry Pi' "$launcher"
  check "chartplotter launcher ENC parse" grep -Fq '"$opencpn_bin" -parse_all_enc' "$launcher"
  check "chartplotter launcher display awake" grep -Fq 'keep_display_awake' "$launcher"
  check "chartplotter launcher display failure logging" grep -Fq 'xset command(s) failed' "$launcher"
  check "chartplotter launcher readiness warning" grep -Fq 'show_preflight_warning' "$launcher"
  check "chartplotter launcher fail-closed warning label" grep -Fq 'button_text="Dismiss"' "$launcher"
  check "chartplotter launcher fail-open warning label" grep -Fq 'button_text="Start OpenCPN"' "$launcher"
  check "chartplotter launcher dynamic warning button" grep -Fq 'text=button_text' "$launcher"
  check "chartplotter launcher duplicate guard" grep -Fq 'OpenCPN is already running' "$launcher"
  check "chartplotter launcher OpenCPN restart setting" grep -Fq 'NOAA_NAVIONICS_OPENCPN_RESTARTS' "$launcher"
  check "chartplotter launcher OpenCPN restart loop" grep -Fq 'Restarting OpenCPN after nonzero exit status' "$launcher"
  check "chartplotter launcher lock" grep -Fq 'chartplotter.launch.lock' "$launcher"
  check "chartplotter launcher lock boot ID" grep -Fq 'current_boot_id' "$launcher"
  check "chartplotter launcher lock symlink guard" grep -Fq 'chartplotter launcher lock path contains a symlink' "$launcher"
  check "chartplotter launcher previous-boot lock recovery" grep -Fq 'Launcher lock is from a previous boot; treating lock as stale' "$launcher"
  check "chartplotter launcher lock sync create" grep -Fq 'sync_paths "${launcher_lock_dir}/pid" "${launcher_lock_dir}/boot_id" "$launcher_lock_dir"' "$launcher"
  check "chartplotter launcher lock sync cleanup" grep -Fq 'sync_paths "$launcher_lock_dir"' "$launcher"
  check "chartplotter launcher stale lock recovery" grep -Fq 'is not a chartplotter launcher; treating lock as stale' "$launcher"
fi
check "chartplotter launcher GPS wait persisted" grep -Fxq "NOAA_NAVIONICS_GPS_SECONDS=${gps_seconds}" "$launcher_env"
check "chartplotter launcher OpenCPN restarts persisted" grep -Fxq "NOAA_NAVIONICS_OPENCPN_RESTARTS=${NOAA_NAVIONICS_OPENCPN_RESTARTS:-3}" "$launcher_env"
check "chartplotter launcher OpenCPN restart delay persisted" grep -Fxq "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=${NOAA_NAVIONICS_OPENCPN_RESTART_DELAY:-5}" "$launcher_env"
check "chartplotter launcher env file integrity" check_user_private_regular_file_integrity "$launcher_env" "chartplotter launcher environment"
check "chartplotter launcher fail-open override disabled" check_launcher_env_production_settings "$launcher_env"
set_chartplotter_start_timeout_from_launcher_env
check "desktop autostart directory integrity" check_user_private_directory_integrity "$autostart_dir" "desktop autostart directory"
check "chartplotter autostart" test -f "$autostart"
if [[ -f "$autostart" ]]; then
  check "chartplotter autostart file integrity" check_user_regular_file_integrity "$autostart" "chartplotter autostart file"
  check "chartplotter autostart type" grep -Fxq 'Type=Application' "$autostart"
  check "chartplotter autostart name" grep -Fxq 'Name=NOAA Navionics Chartplotter' "$autostart"
  check "chartplotter autostart exec" grep -Fxq 'Exec=sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"' "$autostart"
  check "chartplotter autostart terminal" grep -Fxq 'Terminal=false' "$autostart"
  check "chartplotter autostart enabled" grep -Fq 'X-GNOME-Autostart-enabled=true' "$autostart"
  check "chartplotter autostart not disabled" sh -c '! grep -Eq "^(Hidden=true|X-GNOME-Autostart-enabled=false)$" "$1"' sh "$autostart"
fi
check "graphical boot target" sh -c 'systemctl get-default 2>/dev/null | grep -qx graphical.target'
check "LightDM unit installed" sh -c 'systemctl --no-pager --no-legend list-unit-files lightdm.service 2>/dev/null | grep -q "^lightdm.service"'
check "LightDM enabled" systemctl is-enabled --quiet lightdm.service
check "LightDM autologin directory integrity" check_root_directory_integrity "$(dirname "$lightdm_autologin")" "LightDM autologin directory"
check "LightDM autologin config" test -f "$lightdm_autologin"
if [[ -f "$lightdm_autologin" ]]; then
  check "LightDM autologin file integrity" check_root_regular_file_integrity "$lightdm_autologin" "LightDM autologin config"
  check "LightDM autologin seat" grep -Fxq '[Seat:*]' "$lightdm_autologin"
  check "LightDM autologin user" grep -Fxq "autologin-user=${USER}" "$lightdm_autologin"
  check "LightDM autologin timeout" grep -Fxq 'autologin-user-timeout=0' "$lightdm_autologin"
  check "LightDM autologin X11 session" check_lightdm_autologin_session "$lightdm_autologin"
fi
if [[ "$require_chartplotter_started" -eq 1 ]]; then
  printf '\n[chartplotter startup]\n'
  check "LightDM active after boot" systemctl is-active --quiet lightdm.service
  check "chartplotter launcher log file integrity" check_user_regular_file_integrity "$log_file" "chartplotter launcher log"
  check "chartplotter rotated launcher log file integrity" check_optional_user_regular_file_integrity "$rotated_log_file" "chartplotter rotated launcher log"
  check "chartplotter started after boot" wait_for_chartplotter_started
  check "chartplotter launcher lock live" check_launcher_lock_live
  check "display power disabled after boot" check_live_display_power_disabled
  if opencpn_supervised_running; then
    check "launcher-supervised OpenCPN running" true
  else
    check "launcher-supervised OpenCPN running" false
  fi
  check "launcher-supervised OpenCPN executable integrity" check_opencpn_process_executable_integrity
  check "launcher-supervised OpenCPN display environment" check_opencpn_process_display_environment
  check "OpenCPN ENC parse argument" check_opencpn_enc_parse_argument
  check "OpenCPN stable after startup" check_opencpn_stable
  check "boot status report JSON ready" check_status_report_json "$status_report" 1 "$config" "$launcher_env"
fi
check "config file" test -f "$config"
if [[ -f "$config" ]]; then
  check "config file integrity" check_user_regular_file_integrity "$config" "NOAA Navionics config"
fi
check "source revision recorded" test -s "$revision_file"
if [[ -s "$revision_file" ]]; then
  check "source revision file integrity" check_user_regular_file_integrity "$revision_file" "source revision file"
fi
if [[ -s "$revision_file" && "${NOAA_NAVIONICS_EXPECTED_REVISION:-unknown}" != "unknown" ]]; then
  installed_revision="$(tr -d '[:space:]' <"$revision_file")"
  check "source revision matches" test "$installed_revision" = "$NOAA_NAVIONICS_EXPECTED_REVISION"
fi
check "OpenCPN command" command -v opencpn
check "OpenCPN command integrity" check_opencpn_command_integrity
check "display power command" command -v xset
check "Tkinter readiness warning support" check_tkinter_available
check "process lookup command" command -v pgrep
check "Pi power command" command -v vcgencmd
check "Pi power state" check_raspberry_pi_throttling_state
check "Chrony command" command -v chronyc
check "Chrony service enabled" systemctl is-enabled --quiet chrony
check "Chrony service active" systemctl is-active --quiet chrony
check "Chrony config directory integrity" check_root_directory_integrity /etc/chrony "chrony config directory"
check "Chrony config file integrity" check_root_regular_file_integrity /etc/chrony/chrony.conf "chrony config"
check "Chrony GPSD time source" check_chrony_gps_time_config
check "Chrony usable GPS source" wait_for_chrony_gps_source
check "GPSD command" command -v gpsd
check "GPSD client command" command -v cgps
check "GPSD socket enabled" systemctl is-enabled --quiet gpsd.socket
check "GPSD socket active" systemctl is-active --quiet gpsd.socket
check "GPSD service enabled" systemctl is-enabled --quiet gpsd
check "GPSD service active" systemctl is-active --quiet gpsd
check "GPSD config directory integrity" check_root_directory_integrity /etc/default "GPSD config directory"
check "GPSD config" test -f /etc/default/gpsd
if [[ -f /etc/default/gpsd ]]; then
  check "GPSD config file integrity" check_root_regular_file_integrity /etc/default/gpsd "GPSD config"
fi
if [[ -r /etc/default/gpsd ]]; then
  check "GPSD daemon enabled" grep -Eq '^START_DAEMON="true"' /etc/default/gpsd
  check "GPSD USB auto disabled" grep -Eq '^USBAUTO="false"' /etc/default/gpsd
  check "GPSD immediate polling" grep -Eq '^GPSD_OPTIONS="[^"]*-n[^"]*"' /etc/default/gpsd
  check "GPSD device configured" grep -Eq '^DEVICES="[^"]+"' /etc/default/gpsd
  gpsd_devices="$(sed -n 's/^DEVICES="\([^"]*\)".*/\1/p' /etc/default/gpsd)"
  gpsd_device_count="$(awk '{print NF}' <<<"$gpsd_devices")"
  check "GPSD single device" test "$gpsd_device_count" -eq 1
  gpsd_device="$(awk '{print $1}' <<<"$gpsd_devices")"
  if [[ -n "$gpsd_device" ]]; then
    check "GPSD device exists" test -e "$gpsd_device"
    check "GPSD device is not directory" test ! -d "$gpsd_device"
    check "GPSD device is character device" test -c "$gpsd_device"
    check "GPSD device matches config" check_gpsd_device_matches_config "$config" "$gpsd_device"
    if [[ -n "${NOAA_NAVIONICS_EXPECTED_GPS_DEVICE:-}" ]]; then
      check "GPSD device matches expected" check_expected_gps_device_matches "$config" "$gpsd_device"
    fi
    if stable_gps_device_path "$gpsd_device"; then
      printf 'OK   GPSD stable device path %s\n' "$gpsd_device"
    elif volatile_usb_device_path "$gpsd_device"; then
      printf 'FAIL GPSD device path %s is volatile; use /dev/serial/by-id/ or a Raspberry Pi serial alias\n' "$gpsd_device"
      failures=$((failures + 1))
    else
      printf 'FAIL GPSD device path %s is not a recognized stable GPS path\n' "$gpsd_device"
      failures=$((failures + 1))
    fi
  fi
else
  printf 'FAIL GPSD config readable\n'
  failures=$((failures + 1))
fi

check_output "version/help" "$bin" --help
check_output "configured packages" "$bin" list-packages

printf '\n[systemd user units]\n'
systemctl --user --no-pager list-unit-files 'noaa-navionics*' || failures=$((failures + 1))
chart_service="${systemd_user_dir}/noaa-navionics.service"
chart_timer="${systemd_user_dir}/noaa-navionics.timer"
track_service="${systemd_user_dir}/noaa-navionics-track.service"
preflight_service="${systemd_user_dir}/noaa-navionics-preflight.service"
check "systemd user directory integrity" check_user_private_directory_integrity "$systemd_user_dir" "systemd user unit directory"
check "chart service file" test -f "$chart_service"
if [[ -f "$chart_service" ]]; then
  check "chart service file integrity" check_user_regular_file_integrity "$chart_service" "chart service unit file"
fi
check "chart service loaded fragment path" sh -c 'systemctl --user show noaa-navionics.service -p FragmentPath 2>/dev/null | grep -Fxq "FragmentPath=$1"' sh "$chart_service"
check "chart service type" grep -Fxq 'Type=oneshot' "$chart_service"
check "chart service loaded type" sh -c 'systemctl --user show noaa-navionics.service -p Type 2>/dev/null | grep -Fxq Type=oneshot'
check "chart service network wait command" grep -Fq 'ExecStartPre=%h/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300' "$chart_service"
check "chart service loaded network wait command" sh -c 'loaded="$(systemctl --user show noaa-navionics.service -p ExecStartPre 2>/dev/null)" && printf "%s\n" "$loaded" | grep -Fq ".local/bin/noaa-navionics" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics wait-network" && printf "%s\n" "$loaded" | grep -Fq -- "--host www.charts.noaa.gov" && printf "%s\n" "$loaded" | grep -Fq -- "--port 443" && printf "%s\n" "$loaded" | grep -Fq -- "--seconds 300"'
check "chart service sync command" grep -Fq 'ExecStart=%h/.local/bin/noaa-navionics sync-charts --config %h/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30' "$chart_service"
check "chart service loaded sync command" sh -c 'loaded="$(systemctl --user show noaa-navionics.service -p ExecStart 2>/dev/null)" && printf "%s\n" "$loaded" | grep -Fq ".local/bin/noaa-navionics" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics sync-charts" && printf "%s\n" "$loaded" | grep -Fq -- "--config" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics/config.ini" && printf "%s\n" "$loaded" | grep -Fq -- "--retries 5" && printf "%s\n" "$loaded" | grep -Fq -- "--retry-delay 30"'
check "chart service timeout" grep -Fxq 'TimeoutStartSec=2h' "$chart_service"
check "chart service loaded timeout" sh -c 'systemctl --user show noaa-navionics.service -p TimeoutStartUSec 2>/dev/null | grep -Fxq TimeoutStartUSec=2h'
check "chart service restart" grep -Fxq 'Restart=on-failure' "$chart_service"
check "chart service loaded restart" sh -c 'systemctl --user show noaa-navionics.service -p Restart 2>/dev/null | grep -Fxq Restart=on-failure'
check "chart service loaded restart delay" sh -c 'systemctl --user show noaa-navionics.service -p RestartUSec 2>/dev/null | grep -Fxq RestartUSec=30min'
check "chart service no new privileges" grep -Fxq 'NoNewPrivileges=true' "$chart_service"
check "chart service loaded no new privileges" sh -c 'systemctl --user show noaa-navionics.service -p NoNewPrivileges 2>/dev/null | grep -Fxq NoNewPrivileges=yes'
check "chart service private tmp" grep -Fxq 'PrivateTmp=true' "$chart_service"
check "chart service loaded private tmp" sh -c 'systemctl --user show noaa-navionics.service -p PrivateTmp 2>/dev/null | grep -Fxq PrivateTmp=yes'
check "chart service protected system" grep -Fxq 'ProtectSystem=full' "$chart_service"
check "chart service loaded protected system" sh -c 'systemctl --user show noaa-navionics.service -p ProtectSystem 2>/dev/null | grep -Fxq ProtectSystem=full'
check "chart service private files" grep -Fxq 'UMask=0077' "$chart_service"
check "chart service loaded private files" sh -c 'systemctl --user show noaa-navionics.service -p UMask 2>/dev/null | grep -Fxq UMask=0077'
check "chart service start limit interval" grep -Fxq 'StartLimitIntervalSec=6h' "$chart_service"
check "chart service loaded start limit interval" sh -c 'systemctl --user show noaa-navionics.service -p StartLimitIntervalUSec 2>/dev/null | grep -Fxq StartLimitIntervalUSec=6h'
check "chart service start limit burst" grep -Fxq 'StartLimitBurst=3' "$chart_service"
check "chart service loaded start limit burst" sh -c 'systemctl --user show noaa-navionics.service -p StartLimitBurst 2>/dev/null | grep -Fxq StartLimitBurst=3'
check "chart timer weekly" grep -Fxq 'OnCalendar=weekly' "$chart_timer"
check "chart timer loaded fragment path" sh -c 'systemctl --user show noaa-navionics.timer -p FragmentPath 2>/dev/null | grep -Fxq "FragmentPath=$1"' sh "$chart_timer"
check "chart timer persistent" grep -Fxq 'Persistent=true' "$chart_timer"
check "chart timer randomized delay" grep -Fxq 'RandomizedDelaySec=30min' "$chart_timer"
if [[ -f "$chart_timer" ]]; then
  check "chart timer file integrity" check_user_regular_file_integrity "$chart_timer" "chart timer unit file"
fi
check "chart timer install target" check_unit_install_target "$chart_timer" timers.target
check "chart timer loaded weekly" sh -c 'systemctl --user show noaa-navionics.timer -p TimersCalendar 2>/dev/null | grep -Fq OnCalendar=weekly'
check "chart timer loaded persistent" sh -c 'systemctl --user show noaa-navionics.timer -p Persistent 2>/dev/null | grep -Fxq Persistent=yes'
check "chart timer loaded randomized delay" sh -c 'systemctl --user show noaa-navionics.timer -p RandomizedDelayUSec 2>/dev/null | grep -Fxq RandomizedDelayUSec=30min'
check "track service file" test -f "$track_service"
if [[ -f "$track_service" ]]; then
  check "track service file integrity" check_user_regular_file_integrity "$track_service" "track service unit file"
fi
check "track service loaded fragment path" sh -c 'systemctl --user show noaa-navionics-track.service -p FragmentPath 2>/dev/null | grep -Fxq "FragmentPath=$1"' sh "$track_service"
check "track service type" grep -Fxq 'Type=simple' "$track_service"
check "track service loaded type" sh -c 'systemctl --user show noaa-navionics-track.service -p Type 2>/dev/null | grep -Fxq Type=simple'
check "track service rotate daily" grep -Fq 'ExecStart=%h/.local/bin/noaa-navionics log-track --config %h/.config/noaa-navionics/config.ini --rotate-daily' "$track_service"
check "track service loaded rotate daily" sh -c 'loaded="$(systemctl --user show noaa-navionics-track.service -p ExecStart 2>/dev/null)" && printf "%s\n" "$loaded" | grep -Fq ".local/bin/noaa-navionics" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics log-track" && printf "%s\n" "$loaded" | grep -Fq -- "--config" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics/config.ini" && printf "%s\n" "$loaded" | grep -Fq -- "--rotate-daily"'
check "track service quiet stdout" grep -Fxq 'StandardOutput=null' "$track_service"
check "track service loaded quiet stdout" sh -c 'systemctl --user show noaa-navionics-track.service -p StandardOutput 2>/dev/null | grep -Fxq StandardOutput=null'
check "track service restart" grep -Fxq 'Restart=on-failure' "$track_service"
check "track service loaded restart" sh -c 'systemctl --user show noaa-navionics-track.service -p Restart 2>/dev/null | grep -Fxq Restart=on-failure'
check "track service loaded restart delay" sh -c 'systemctl --user show noaa-navionics-track.service -p RestartUSec 2>/dev/null | grep -Fxq RestartUSec=10s'
check "track service no new privileges" grep -Fxq 'NoNewPrivileges=true' "$track_service"
check "track service loaded no new privileges" sh -c 'systemctl --user show noaa-navionics-track.service -p NoNewPrivileges 2>/dev/null | grep -Fxq NoNewPrivileges=yes'
check "track service private tmp" grep -Fxq 'PrivateTmp=true' "$track_service"
check "track service loaded private tmp" sh -c 'systemctl --user show noaa-navionics-track.service -p PrivateTmp 2>/dev/null | grep -Fxq PrivateTmp=yes'
check "track service protected system" grep -Fxq 'ProtectSystem=full' "$track_service"
check "track service loaded protected system" sh -c 'systemctl --user show noaa-navionics-track.service -p ProtectSystem 2>/dev/null | grep -Fxq ProtectSystem=full'
check "track service private track files" grep -Fxq 'UMask=0077' "$track_service"
check "track service loaded private track files" sh -c 'systemctl --user show noaa-navionics-track.service -p UMask 2>/dev/null | grep -Fxq UMask=0077'
check "track service start limit interval" grep -Fxq 'StartLimitIntervalSec=10min' "$track_service"
check "track service loaded start limit interval" sh -c 'systemctl --user show noaa-navionics-track.service -p StartLimitIntervalUSec 2>/dev/null | grep -Fxq StartLimitIntervalUSec=10min'
check "track service start limit burst" grep -Fxq 'StartLimitBurst=60' "$track_service"
check "track service loaded start limit burst" sh -c 'systemctl --user show noaa-navionics-track.service -p StartLimitBurst 2>/dev/null | grep -Fxq StartLimitBurst=60'
check "track service install target" check_unit_install_target "$track_service" default.target
check "preflight service file" test -f "$preflight_service"
if [[ -f "$preflight_service" ]]; then
  check "preflight service file integrity" check_user_regular_file_integrity "$preflight_service" "preflight service unit file"
fi
check "preflight service loaded fragment path" sh -c 'systemctl --user show noaa-navionics-preflight.service -p FragmentPath 2>/dev/null | grep -Fxq "FragmentPath=$1"' sh "$preflight_service"
check "preflight service wants track logger" grep -Fxq 'Wants=noaa-navionics-track.service' "$preflight_service"
check "preflight service after track logger" grep -Fxq 'After=noaa-navionics-track.service' "$preflight_service"
check "preflight service loaded wants track logger" sh -c 'systemctl --user show noaa-navionics-preflight.service -p Wants 2>/dev/null | grep -Fq noaa-navionics-track.service'
check "preflight service loaded after track logger" sh -c 'systemctl --user show noaa-navionics-preflight.service -p After 2>/dev/null | grep -Fq noaa-navionics-track.service'
check "preflight service type" grep -Fxq 'Type=oneshot' "$preflight_service"
check "preflight service loaded type" sh -c 'systemctl --user show noaa-navionics-preflight.service -p Type 2>/dev/null | grep -Fxq Type=oneshot'
check "preflight service GPS wait default" grep -Fxq 'Environment=NOAA_NAVIONICS_GPS_SECONDS=60' "$preflight_service"
check "preflight service loaded GPS wait default" sh -c 'systemctl --user show noaa-navionics-preflight.service -p Environment 2>/dev/null | grep -Fq "NOAA_NAVIONICS_GPS_SECONDS=60"'
check "preflight service GPS wait config" grep -Fxq 'EnvironmentFile=-%h/.config/noaa-navionics/launcher.env' "$preflight_service"
check "preflight service status report" grep -Fq 'ExecStart=%h/.local/bin/noaa-navionics status-report --config %h/.config/noaa-navionics/config.ini --gps-seconds ${NOAA_NAVIONICS_GPS_SECONDS} --output %h/.cache/noaa-navionics/status.json' "$preflight_service"
check "preflight service loaded status report" sh -c 'loaded="$(systemctl --user show noaa-navionics-preflight.service -p ExecStart 2>/dev/null)" && printf "%s\n" "$loaded" | grep -Fq ".local/bin/noaa-navionics" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics status-report" && printf "%s\n" "$loaded" | grep -Fq -- "--config" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics/config.ini" && printf "%s\n" "$loaded" | grep -Fq -- "--gps-seconds" && printf "%s\n" "$loaded" | grep -Fq -- "--output" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics/status.json"'
check "preflight service timeout" grep -Fxq 'TimeoutStartSec=0' "$preflight_service"
check "preflight service loaded timeout" sh -c 'systemctl --user show noaa-navionics-preflight.service -p TimeoutStartUSec 2>/dev/null | grep -Fxq TimeoutStartUSec=infinity'
check "preflight service restart" grep -Fxq 'Restart=on-failure' "$preflight_service"
check "preflight service loaded restart" sh -c 'systemctl --user show noaa-navionics-preflight.service -p Restart 2>/dev/null | grep -Fxq Restart=on-failure'
check "preflight service restart delay" grep -Fxq 'RestartSec=30' "$preflight_service"
check "preflight service no new privileges" grep -Fxq 'NoNewPrivileges=true' "$preflight_service"
check "preflight service loaded no new privileges" sh -c 'systemctl --user show noaa-navionics-preflight.service -p NoNewPrivileges 2>/dev/null | grep -Fxq NoNewPrivileges=yes'
check "preflight service private tmp" grep -Fxq 'PrivateTmp=true' "$preflight_service"
check "preflight service loaded private tmp" sh -c 'systemctl --user show noaa-navionics-preflight.service -p PrivateTmp 2>/dev/null | grep -Fxq PrivateTmp=yes'
check "preflight service protected system" grep -Fxq 'ProtectSystem=full' "$preflight_service"
check "preflight service loaded protected system" sh -c 'systemctl --user show noaa-navionics-preflight.service -p ProtectSystem 2>/dev/null | grep -Fxq ProtectSystem=full'
check "preflight service private files" grep -Fxq 'UMask=0077' "$preflight_service"
check "preflight service loaded private files" sh -c 'systemctl --user show noaa-navionics-preflight.service -p UMask 2>/dev/null | grep -Fxq UMask=0077'
check "preflight service loaded GPS wait config" sh -c 'systemctl --user show noaa-navionics-preflight.service -p EnvironmentFiles 2>/dev/null | grep -Fq "noaa-navionics/launcher.env"'
check "preflight service loaded restart delay" sh -c 'systemctl --user show noaa-navionics-preflight.service -p RestartUSec 2>/dev/null | grep -Fxq RestartUSec=30s'
check "preflight service start limit interval" grep -Fxq 'StartLimitIntervalSec=30min' "$preflight_service"
check "preflight service loaded start limit interval" sh -c 'systemctl --user show noaa-navionics-preflight.service -p StartLimitIntervalUSec 2>/dev/null | grep -Fxq StartLimitIntervalUSec=30min'
check "preflight service start limit burst" grep -Fxq 'StartLimitBurst=60' "$preflight_service"
check "preflight service loaded start limit burst" sh -c 'systemctl --user show noaa-navionics-preflight.service -p StartLimitBurst 2>/dev/null | grep -Fxq StartLimitBurst=60'
check "preflight service install target" check_unit_install_target "$preflight_service" default.target
check "user linger enabled" sh -c "loginctl show-user '$USER' -p Linger 2>/dev/null | grep -q '^Linger=yes$'"
check "chart timer enabled" systemctl --user is-enabled --quiet noaa-navionics.timer
check "track service enabled" systemctl --user is-enabled --quiet noaa-navionics-track.service
check "track service active" systemctl --user is-active --quiet noaa-navionics-track.service
check "preflight service enabled" systemctl --user is-enabled --quiet noaa-navionics-preflight.service
check "preflight service last success" check_preflight_service_succeeded
check "chart timer active" systemctl --user is-active --quiet noaa-navionics.timer

printf '\n[preflight]\n'
preflight_ok=0
for attempt in $(seq 1 "$status_attempts"); do
  if "$bin" status-report --config "$config" --gps-seconds "$gps_seconds" --output "$status_report"; then
    printf 'OK   preflight\n'
    printf 'OK   status report %s\n' "$status_report"
    check "status report JSON ready" check_status_report_json "$status_report" 0 "$config" "$launcher_env"
    preflight_ok=1
    break
  fi
  if [[ "$attempt" -lt "$status_attempts" ]]; then
    printf 'WARN preflight attempt %s/%s failed; retrying in %ss\n' "$attempt" "$status_attempts" "$status_retry_delay"
    sleep "$status_retry_delay"
  fi
done
if [[ "$preflight_ok" -eq 0 ]]; then
  printf 'FAIL preflight\n'
  printf 'FAIL status report %s\n' "$status_report"
  failures=$((failures + 1))
fi
check "recent GPX trackpoint" check_recent_track_log "$config"

if [[ "$failures" -eq 0 ]]; then
  printf '\nRaspberry Pi verification passed.\n'
else
  printf '\nRaspberry Pi verification failed: %d issue(s).\n' "$failures"
fi

exit "$failures"
REMOTE
