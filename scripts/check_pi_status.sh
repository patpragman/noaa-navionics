#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/check_pi_status.sh user@raspberrypi.local [options]

Runs a read-only NOAA Navionics status-report on an already commissioned
Raspberry Pi over SSH. This is a lightweight status snapshot for maintenance
or underway checks; it does not replace verify_pi.sh or dock_test_pi.sh.

Options:
  --gps-seconds N   Override the commissioned GPS fix wait from launcher.env (1-600)
  --json            Print the raw JSON status report

Nothing is installed, enabled, rebooted, shut down, downloaded, or written on
the local computer or the Raspberry Pi.
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
gps_seconds=""
json=0
ssh_cmd=""
local_python_cmd=""
max_status_gps_seconds=600
max_status_json_bytes=$((1024 * 1024))
ssh_batch_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer" >&2
    exit 2
  fi
}

integer_greater_than() {
  local value
  local maximum
  value="$(normalize_decimal_integer "$1")"
  maximum="$(normalize_decimal_integer "$2")"
  if (( ${#value} > ${#maximum} )); then
    return 0
  fi
  if (( ${#value} == ${#maximum} )) && [[ "$value" > "$maximum" ]]; then
    return 0
  fi
  return 1
}

normalize_decimal_integer() {
  local value="$1"
  value="${value#"${value%%[!0]*}"}"
  printf '%s\n' "${value:-0}"
}

require_integer_at_most() {
  local name="$1"
  local value="$2"
  local maximum="$3"
  if integer_greater_than "$value" "$maximum"; then
    echo "$name must be at most ${maximum}" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gps-seconds)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      gps_seconds_value="${2:-}"
      require_positive_integer "$1" "$gps_seconds_value"
      require_integer_at_most "$1" "$gps_seconds_value" "$max_status_gps_seconds"
      gps_seconds="$(normalize_decimal_integer "$gps_seconds_value")"
      shift 2
      ;;
    --json)
      json=1
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

validate_ssh_target() {
  local value="$1"
  local user_part
  local host_part
  local host_lower
  local local_hostname_file
  local local_hostname
  local local_hostname_lower
  local local_hostname_short

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
  host_lower="${host_part,,}"
  case "$host_lower" in
    localhost|localhost.localdomain|*.localhost|ip6-localhost|ip6-loopback|loopback|127.*|0|0.0.0.0)
      echo "SSH target must not point at this computer or loopback: $host_part" >&2
      exit 2
      ;;
  esac
  for local_hostname_file in /proc/sys/kernel/hostname /etc/hostname; do
    if [[ ! -r "$local_hostname_file" ]]; then
      continue
    fi
    IFS= read -r local_hostname <"$local_hostname_file" || local_hostname=""
    local_hostname="${local_hostname%%[[:space:]]*}"
    if [[ -z "$local_hostname" ]]; then
      continue
    fi
    local_hostname_lower="${local_hostname,,}"
    local_hostname_short="${local_hostname_lower%%.*}"
    case "$host_lower" in
      "$local_hostname_lower"|"$local_hostname_short"|"$local_hostname_short.local")
        echo "SSH target must not point at this computer or loopback: $host_part" >&2
        exit 2
        ;;
    esac
  done
  if [[ "$user_part" == "root" ]]; then
    cat >&2 <<'EOF'
Do not check NOAA Navionics status as root@.
Use the Pi desktop user so the same config, services, tracks, and OpenCPN data are inspected.
EOF
    exit 2
  fi
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
  if [[ ! -f "$resolved_path" ]]; then
    echo "Local ${command_name} command is not a regular file after resolution: $command_path -> $resolved_path" >&2
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

validate_remote_bash_entrypoint() {
  "$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && /bin/sh -s -- /bin/bash bash" <<'BASH_ENTRYPOINT_TRUST' >/dev/null
set -eu

command_path="$1"
command_label="$2"

check_trusted_system_path() {
  case "$1" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*)
      return 0
      ;;
  esac
  echo "Remote ${command_label} command is not in a trusted system directory: $1" >&2
  exit 1
}

check_owner_and_mode() {
  item_kind="$1"
  item_path="$2"
  stat_output="$(stat -Lc '%u %a' -- "$item_path")" || {
    echo "Could not inspect remote ${command_label} ${item_kind}: ${item_path}" >&2
    exit 1
  }
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [ "$owner_uid" != "0" ]; then
    echo "Remote ${command_label} ${item_kind} is owned by uid ${owner_uid}, expected 0: ${item_path}" >&2
    exit 1
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      echo "Remote ${command_label} ${item_kind} has permissions ${mode}, expected no group/other write: ${item_path}" >&2
      exit 1
      ;;
  esac
}

check_directory_chain() {
  directory="$(dirname -- "$1")"
  while :; do
    check_owner_and_mode directory "$directory"
    [ "$directory" = "/" ] && break
    directory="$(dirname -- "$directory")"
  done
}

check_trusted_system_path "$command_path"
resolved_cmd="$(readlink -f -- "$command_path")"
check_trusted_system_path "$resolved_cmd"
if [ ! -f "$resolved_cmd" ]; then
  echo "Remote ${command_label} command is not a regular file after resolution: ${command_path} -> ${resolved_cmd}" >&2
  exit 1
fi
if [ ! -x "$resolved_cmd" ]; then
  echo "Remote ${command_label} command is not executable after resolution: ${resolved_cmd}" >&2
  exit 1
fi
check_directory_chain "$command_path"
check_directory_chain "$resolved_cmd"
check_owner_and_mode file "$resolved_cmd"
BASH_ENTRYPOINT_TRUST
}

validate_status_json_output() {
  local payload="$1"
  if [[ -z "$payload" ]]; then
    echo "status JSON validation failed: empty output" >&2
    return 1
  fi
  printf '%s' "$payload" | "$local_python_cmd" -c '
from datetime import datetime, timezone
import json
import math
import posixpath
import re
import sys


def fail(message):
    print(f"status JSON validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def status_text(value, label):
    if not isinstance(value, str):
        fail(f"{label} is not a string")
    text = str(value)
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        fail(f"{label} contains control characters")
    return text.strip()


def validate_optional_text_fields(section, label, fields):
    if not isinstance(section, dict):
        return
    for field in fields:
        if field in section:
            status_text(section.get(field, ""), f"{label} {field}")


def status_required_text(section, label, field):
    if field not in section:
        fail(f"missing {label} {field}")
    text = status_text(section.get(field, ""), f"{label} {field}")
    if not text:
        fail(f"{label} {field} is empty")
    return text


def status_integer(section, label, field, *, minimum=None, maximum=None):
    value = section.get(field)
    if isinstance(value, bool) or not isinstance(value, int):
        fail(f"{label} {field} is not an integer")
    if minimum is not None and value < minimum:
        fail(f"{label} {field} is below {minimum}")
    if maximum is not None and value > maximum:
        fail(f"{label} {field} is above {maximum}")
    return value


def status_number(section, label, field):
    value = section.get(field)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"{label} {field} is not numeric")
    parsed = float(value)
    if not math.isfinite(parsed):
        fail(f"{label} {field} is not finite")
    return parsed


def status_nonnegative_number(section, label, field):
    parsed = status_number(section, label, field)
    if parsed < 0.0:
        fail(f"{label} {field} is negative")
    return parsed


def status_timestamp(value, label):
    text = status_text(value, label)
    if not text:
        fail(f"{label} is missing")
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"{label} is invalid: {exc}")
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        fail(f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def validate_position_summary(
    summary,
    label,
    *,
    latitude_field,
    longitude_field,
    timestamp_field,
    satellites_field,
    hdop_field,
    generated_at_utc,
):
    if summary.get("ok") is not True:
        return
    latitude = status_number(summary, label, latitude_field)
    longitude = status_number(summary, label, longitude_field)
    if not -90.0 <= latitude <= 90.0:
        fail(f"{label} {latitude_field} is outside -90..90")
    if not -180.0 <= longitude <= 180.0:
        fail(f"{label} {longitude_field} is outside -180..180")
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        fail(f"{label} coordinates are invalid 0,0")
    timestamp = status_timestamp(summary.get(timestamp_field, ""), f"{label} {timestamp_field}")
    age_seconds = status_number(summary, label, "age_seconds")
    if age_seconds < 0.0:
        fail(f"{label} age_seconds is negative")
    if age_seconds > 600.0:
        fail(f"{label} age_seconds is stale")
    timestamp_age = (generated_at_utc - timestamp).total_seconds()
    if timestamp_age < -30.0:
        fail(f"{label} {timestamp_field} is after generated_at")
    if abs(age_seconds - timestamp_age) > 30.0:
        fail(f"{label} age_seconds is inconsistent with {timestamp_field}")
    satellites = summary.get(satellites_field)
    hdop = summary.get(hdop_field)
    if satellites is None and hdop is None:
        fail(f"{label} has no satellite or HDOP quality fields")
    if satellites is not None:
        if isinstance(satellites, bool) or not isinstance(satellites, int):
            fail(f"{label} {satellites_field} is not an integer")
        if satellites < 4:
            fail(f"{label} {satellites_field} is weak")
    if hdop is not None:
        parsed_hdop = status_number(summary, label, hdop_field)
        if parsed_hdop < 0.0:
            fail(f"{label} {hdop_field} is negative")
        if parsed_hdop > 5.0:
            fail(f"{label} {hdop_field} is weak")


def validate_gps_readiness_row(gps_fix, readiness_rows):
    if gps_fix.get("ok") is not True:
        return
    source = status_text(gps_fix.get("source", ""), "gps_fix source")
    if source not in {"GPS", "GPSD"}:
        source_label = source or "<missing>"
        fail(f"gps_fix source is not GPS or GPSD: {source_label}")
    row = readiness_rows.get(source)
    if not isinstance(row, dict):
        fail(f"missing {source} readiness check for gps_fix")
    if row.get("ok") is not True:
        fail(f"{source} readiness check is not ok")
    data = row.get("data")
    if not isinstance(data, dict):
        fail(f"{source} readiness check has no structured fix data")
    for field in (
        "latitude",
        "longitude",
        "timestamp",
        "speed_knots",
        "course_degrees",
        "fix_quality",
        "satellites",
        "hdop",
        "altitude_m",
    ):
        if field in gps_fix and data.get(field) != gps_fix.get(field):
            fail(f"gps_fix data does not match {source} readiness check data for {field}")


def validate_track_log_service_row(track_log, service_rows):
    if track_log.get("ok") is not True:
        return
    row = service_rows.get("Track Log")
    if not isinstance(row, dict):
        fail("missing Track Log service check for track_log")
    if row.get("ok") is not True:
        fail("Track Log service check is not ok")
    data = row.get("data")
    if not isinstance(data, dict):
        fail("Track Log service check has no structured track data")
    for field in (
        "track_output",
        "tracks_dir",
        "latest_path",
        "latest_time",
        "latest_latitude",
        "latest_longitude",
        "age_seconds",
        "latest_satellites",
        "latest_hdop",
    ):
        if field in track_log and data.get(field) != track_log.get(field):
            fail(f"track_log data does not match Track Log service check data for {field}")


CORE_READINESS_CHECKS = {
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
}
GPSD_READINESS_CHECKS = {
    "OpenCPN GPSD",
    "GPSD Config",
    "Chrony Config",
    "GPSD",
    "GPS Time Source",
}
SERIAL_READINESS_CHECKS = {"GPS Device", "GPS"}
CORE_SERVICE_CHECKS = {
    "Chart Sync",
    "Chart Sync Settings",
    "Chart Sync Unit File",
    "Chart Timer",
    "Chart Timer Install",
    "Chart Timer Settings",
    "Chart Timer Unit File",
    "Track Log",
    "Track Logger",
    "Track Logger Install",
    "Track Logger Settings",
    "Track Logger Unit File",
    "Boot Readiness",
    "Boot Readiness Install",
    "Boot Readiness Settings",
    "Boot Readiness Unit File",
    "Boot Readiness Run",
    "Desktop Startup",
    "Launcher Settings",
    "User Linger",
}
GPSD_SERVICE_CHECKS = {"GPSD Socket", "GPSD Service", "Chrony Service"}


def validate_required_rows(config, readiness_rows, service_rows):
    gps_mode = status_text(config.get("gps_mode", ""), "config gps_mode")
    required_readiness = set(CORE_READINESS_CHECKS)
    required_services = set(CORE_SERVICE_CHECKS)
    if gps_mode == "gpsd":
        required_readiness.update(GPSD_READINESS_CHECKS)
        required_services.update(GPSD_SERVICE_CHECKS)
    elif gps_mode == "serial":
        required_readiness.update(SERIAL_READINESS_CHECKS)
    else:
        gps_mode_label = gps_mode or "<missing>"
        fail(f"config gps_mode is unsupported: {gps_mode_label}")
    separator = ", "
    missing_readiness = sorted(required_readiness - set(readiness_rows))
    if missing_readiness:
        missing_readiness_label = separator.join(missing_readiness)
        fail(f"missing required readiness check(s): {missing_readiness_label}")
    missing_services = sorted(required_services - set(service_rows))
    if missing_services:
        missing_services_label = separator.join(missing_services)
        fail(f"missing required service check(s): {missing_services_label}")


def validate_config_summary(config):
    if not isinstance(config, dict):
        fail("missing config summary")
    for field in (
        "chart_package",
        "chart_value",
        "gps_mode",
        "gps_device",
        "gpsd_host",
    ):
        status_required_text(config, "config", field)
    for field in ("chart_output", "track_output"):
        value = status_required_text(config, "config", field)
        if not posixpath.isabs(value):
            fail(f"config {field} is not absolute")
    gps_device = status_required_text(config, "config", "gps_device")
    if gps_device.startswith(("/dev/tty", "/dev/cu.", "/dev/disk")):
        fail("config gps_device is volatile")
    if not (
        gps_device.startswith("/dev/serial/by-id/")
        or gps_device.startswith("/dev/serial/by-path/")
        or gps_device in {"/dev/serial0", "/dev/serial1", "/dev/gps"}
    ):
        fail("config gps_device must be /dev/serial/by-id/..., /dev/serial/by-path/..., /dev/serial0, /dev/serial1, or /dev/gps")
    gps_baud = status_integer(config, "config", "gps_baud")
    if gps_baud not in {4800, 9600, 19200, 38400, 57600, 115200}:
        fail("config gps_baud is invalid")
    status_integer(config, "config", "gpsd_port", minimum=1, maximum=65535)
    status_integer(config, "config", "track_retention_days", minimum=0)
    status_nonnegative_number(config, "config", "track_fsync_interval_seconds")
    anchor_radius = status_number(config, "config", "anchor_radius_meters")
    if anchor_radius < 1.0:
        fail("config anchor_radius_meters is below 1.0")


BOOT_ID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


try:
    report = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    fail(f"not valid JSON: {exc}")

if not isinstance(report, dict):
    fail("top-level JSON value is not an object")
if not isinstance(report.get("ok"), bool):
    fail("top-level ok is not boolean")
if report.get("ok") is not True:
    fail("top-level ok is false")

generated_at = report.get("generated_at")
if not isinstance(generated_at, str) or not generated_at.strip():
    fail("generated_at timestamp is missing")
try:
    parsed_generated_at = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
except ValueError as exc:
    fail(f"generated_at timestamp is invalid: {exc}")
if parsed_generated_at.tzinfo is None or parsed_generated_at.utcoffset() is None:
    fail("generated_at timestamp must include a timezone")
status_age_seconds = (datetime.now(timezone.utc) - parsed_generated_at.astimezone(timezone.utc)).total_seconds()
if status_age_seconds < -30.0:
    fail("generated_at timestamp is in the future")
if status_age_seconds > 600.0:
    fail("generated_at timestamp is stale")
host = report.get("host")
if not isinstance(host, dict):
    fail("missing host summary")
host_boot_id = status_text(host.get("boot_id", ""), "host boot_id")
if not BOOT_ID_RE.fullmatch(host_boot_id):
    fail("host boot_id is not a Linux boot_id value")

readiness_rows = {}
service_rows = {}
for section_name, row_label in (("checks", "readiness check"), ("service_checks", "service check")):
    rows = report.get(section_name)
    if not isinstance(rows, list) or not rows:
        fail(f"missing non-empty {section_name} list")
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            fail(f"malformed {section_name} row")
        name = row.get("name")
        if not isinstance(name, str) or not name.strip():
            fail(f"unnamed {row_label}")
        normalized = status_text(name, f"{row_label} name")
        if normalized in seen:
            fail(f"duplicate {row_label}: {normalized}")
        seen.add(normalized)
        if not isinstance(row.get("ok"), bool):
            fail(f"{normalized} ok is not boolean")
        if section_name == "checks":
            readiness_rows[normalized] = row
        else:
            service_rows[normalized] = row

validate_optional_text_fields(
    report.get("config"),
    "config",
    (
        "chart_package",
        "chart_value",
        "chart_output",
        "track_output",
        "gps_mode",
        "gps_device",
        "gpsd_host",
    ),
)
validate_optional_text_fields(
    report.get("manifest"),
    "manifest",
    ("path", "download_path", "extract_path"),
)
config = report.get("config")
validate_config_summary(config)
validate_required_rows(config, readiness_rows, service_rows)

for section_name in ("gps_fix", "track_log"):
    summary = report.get(section_name)
    if not isinstance(summary, dict):
        fail(f"missing {section_name} summary")
    if not isinstance(summary.get("ok"), bool):
        fail(f"{section_name} ok is not boolean")
    if section_name == "gps_fix":
        validate_optional_text_fields(summary, section_name, ("source",))
    else:
        validate_optional_text_fields(
            summary,
            section_name,
            ("track_output", "tracks_dir", "latest_path", "track_storage_symlink_component"),
        )
validate_position_summary(
    report["gps_fix"],
    "gps_fix",
    latitude_field="latitude",
    longitude_field="longitude",
    timestamp_field="timestamp",
    satellites_field="satellites",
    hdop_field="hdop",
    generated_at_utc=parsed_generated_at.astimezone(timezone.utc),
)
validate_position_summary(
    report["track_log"],
    "track_log",
    latitude_field="latest_latitude",
    longitude_field="latest_longitude",
    timestamp_field="latest_time",
    satellites_field="latest_satellites",
    hdop_field="latest_hdop",
    generated_at_utc=parsed_generated_at.astimezone(timezone.utc),
)
validate_gps_readiness_row(report["gps_fix"], readiness_rows)
validate_track_log_service_row(report["track_log"], service_rows)
'
}

create_private_status_json_capture() {
  local status
  set +e
  "$local_python_cmd" - <<'PY'
from __future__ import annotations

import os
import stat
import sys
import tempfile

try:
    fd, path = tempfile.mkstemp(prefix=".noaa-navionics-status-json-")
except OSError as exc:
    print(f"Could not create private status JSON capture: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
try:
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        print(f"status JSON capture must be a regular file: {path}", file=sys.stderr)
        raise SystemExit(124)
    if opened.st_uid != os.getuid():
        print(
            f"status JSON capture is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        print(f"status JSON capture has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
        raise SystemExit(124)
finally:
    os.close(fd)
print(path)
PY
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

cleanup_private_status_json_capture() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  "$local_python_cmd" - "$path" <<'PY'
from __future__ import annotations

from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
nofollow = getattr(os, "O_NOFOLLOW", 0)

try:
    before = os.stat(path, follow_symlinks=False)
except FileNotFoundError:
    raise SystemExit(0)
except OSError as exc:
    print(f"Could not inspect status JSON capture for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600:
    print(f"status JSON capture is not a trusted private file; leaving it in place: {path}", file=sys.stderr)
    raise SystemExit(0)

try:
    dir_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
except OSError as exc:
    print(f"Could not open status JSON capture directory for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)
try:
    try:
        fd = os.open(path.name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
    except FileNotFoundError:
        raise SystemExit(0)
    try:
        opened = os.fstat(fd)
    finally:
        os.close(fd)
    if not os.path.samestat(before, opened):
        print(f"status JSON capture changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    os.unlink(path.name, dir_fd=dir_fd)
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
}

capture_remote_status_json() {
  local path="$1"
  local capture_code
  local -a pipe_statuses
  local remote_code
  set +e
  run_remote_status | "$local_python_cmd" -c '
from __future__ import annotations

from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
max_bytes = int(sys.argv[2])
flags = os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)

try:
    before = os.stat(path, follow_symlinks=False)
    fd = os.open(path, flags)
except OSError as exc:
    print(f"Could not open status JSON capture for writing {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc

try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        print(f"status JSON capture changed while opening it: {path}", file=sys.stderr)
        raise SystemExit(124)
    if not stat.S_ISREG(opened.st_mode):
        print(f"status JSON capture must be a regular file: {path}", file=sys.stderr)
        raise SystemExit(124)
    if opened.st_uid != os.getuid():
        print(
            f"status JSON capture is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        print(f"status JSON capture has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
        raise SystemExit(124)
    with os.fdopen(fd, "wb") as capture:
        fd = -1
        written = 0
        while True:
            chunk = sys.stdin.buffer.read(65536)
            if not chunk:
                break
            next_written = written + len(chunk)
            if next_written > max_bytes:
                print(
                    f"status JSON output exceeds size limit ({next_written} > {max_bytes} bytes)",
                    file=sys.stderr,
                )
                raise SystemExit(124)
            capture.write(chunk)
            written = next_written
        capture.flush()
        os.fsync(capture.fileno())
except OSError as exc:
    print(f"Could not write status JSON capture {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
finally:
    if fd >= 0:
        os.close(fd)
' "$path" "$max_status_json_bytes"
  pipe_statuses=("${PIPESTATUS[@]}")
  remote_code="${pipe_statuses[0]}"
  capture_code="${pipe_statuses[1]}"
  if [[ "$capture_code" -eq 124 ]]; then
    return 124
  fi
  if [[ "$capture_code" -ne 0 ]]; then
    return 124
  fi
  return "$remote_code"
}

read_private_status_json_capture() {
  local path="$1"
  "$local_python_cmd" - "$path" <<'PY'
from __future__ import annotations

from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)

try:
    before = os.stat(path, follow_symlinks=False)
    fd = os.open(path, flags)
except OSError as exc:
    print(f"Could not open status JSON capture for reading {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc

try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        print(f"status JSON capture changed while opening it for reading: {path}", file=sys.stderr)
        raise SystemExit(124)
    if not stat.S_ISREG(opened.st_mode):
        print(f"status JSON capture must be a regular file when read: {path}", file=sys.stderr)
        raise SystemExit(124)
    if opened.st_uid != os.getuid():
        print(
            f"status JSON capture is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        print(f"status JSON capture has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
        raise SystemExit(124)
    with os.fdopen(fd, "rb") as handle:
        fd = -1
        sys.stdout.buffer.write(handle.read())
finally:
    if fd >= 0:
        os.close(fd)
PY
}

validate_ssh_target "$target"
ssh_cmd="$(require_local_command ssh)"
if [[ "$json" -eq 1 ]]; then
  local_python_cmd="$(require_local_command python3)"
fi
gps_seconds_quoted="$(printf '%q' "$gps_seconds")"
json_quoted="$(printf '%q' "$json")"
validate_remote_bash_entrypoint

run_remote_status() {
  "$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" \
    "${remote_system_path} && export PATH && NOAA_NAVIONICS_STATUS_GPS_SECONDS=${gps_seconds_quoted} NOAA_NAVIONICS_STATUS_JSON=${json_quoted} /bin/bash -s" <<'REMOTE'
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

command_path="${HOME}/.local/bin/noaa-navionics"
expected_resolved="${HOME}/.local/share/noaa-navionics/venv/bin/noaa-navionics"
config_path="${HOME}/.config/noaa-navionics/config.ini"
launcher_env_path="${HOME}/.config/noaa-navionics/launcher.env"
python3_cmd=""
max_status_gps_seconds=600

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_remote_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    fail "$name must be a positive integer"
  fi
}

integer_greater_than() {
  local value
  local maximum
  value="$(normalize_decimal_integer "$1")"
  maximum="$(normalize_decimal_integer "$2")"
  if (( ${#value} > ${#maximum} )); then
    return 0
  fi
  if (( ${#value} == ${#maximum} )) && [[ "$value" > "$maximum" ]]; then
    return 0
  fi
  return 1
}

normalize_decimal_integer() {
  local value="$1"
  value="${value#"${value%%[!0]*}"}"
  printf '%s\n' "${value:-0}"
}

require_remote_integer_at_most() {
  local name="$1"
  local value="$2"
  local maximum="$3"
  if integer_greater_than "$value" "$maximum"; then
    fail "$name must be at most ${maximum}"
  fi
}

validate_status_controls() {
  if [[ -n "${NOAA_NAVIONICS_STATUS_GPS_SECONDS:-}" ]]; then
    require_remote_positive_integer "NOAA_NAVIONICS_STATUS_GPS_SECONDS" "$NOAA_NAVIONICS_STATUS_GPS_SECONDS"
    require_remote_integer_at_most "NOAA_NAVIONICS_STATUS_GPS_SECONDS" "$NOAA_NAVIONICS_STATUS_GPS_SECONDS" "$max_status_gps_seconds"
  fi
  case "${NOAA_NAVIONICS_STATUS_JSON:-}" in
    0|1)
      ;;
    *)
      fail "NOAA_NAVIONICS_STATUS_JSON must be 0 or 1"
      ;;
  esac
}

remote_path_in_trusted_system_dir() {
  case "$1" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*)
      return 0
      ;;
  esac
  return 1
}

check_remote_owner_and_mode() {
  local item_kind="$1"
  local item_path="$2"
  local mode
  local mode_tail
  local owner_uid
  local stat_output

  if ! stat_output="$(stat -Lc '%u %a' -- "$item_path" 2>/dev/null)"; then
    fail "could not inspect remote command ${item_kind}: $item_path"
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"

  if [[ "$owner_uid" != "0" ]]; then
    fail "remote ${item_kind} command is owned by uid ${owner_uid}, expected 0: ${item_path}"
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      fail "remote ${item_kind} command has permissions ${mode}, expected no group/other write: ${item_path}"
      ;;
  esac
}

check_remote_directory_chain() {
  local directory
  directory="$(dirname -- "$1")"
  while :; do
    check_remote_owner_and_mode directory "$directory"
    [[ "$directory" == "/" ]] && break
    directory="$(dirname -- "$directory")"
  done
}

require_remote_command() {
  local command_name="$1"
  local command_path
  local resolved_path

  if ! command_path="$(command -v "$command_name" 2>/dev/null)" || [[ -z "$command_path" ]]; then
    fail "missing required remote command: $command_name"
  fi
  if ! remote_path_in_trusted_system_dir "$command_path"; then
    fail "remote ${command_name} command is not in a trusted system directory: $command_path"
  fi
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    fail "could not resolve remote ${command_name} command: $command_path"
  fi
  if ! remote_path_in_trusted_system_dir "$resolved_path"; then
    fail "resolved remote ${command_name} command is not in a trusted system directory: $resolved_path"
  fi
  if [[ ! -f "$resolved_path" ]]; then
    fail "remote ${command_name} command is not a regular file after resolution: $command_path -> $resolved_path"
  fi
  if [[ ! -x "$resolved_path" ]]; then
    fail "remote ${command_name} command is not executable after resolution: $resolved_path"
  fi
  check_remote_directory_chain "$resolved_path"
  check_remote_owner_and_mode "$command_name" "$resolved_path"
  printf '%s\n' "$resolved_path"
}

reject_symlinked_path_components() {
  local label="$1"
  local path="$2"
  local current="$path"

  if [[ "$path" != /* ]]; then
    fail "$label path must be absolute: $path"
  fi
  while [[ "$current" != "/" ]]; do
    if [[ -L "$current" ]]; then
      fail "$label path contains a symlink: $current"
    fi
    current="$(dirname -- "$current")"
  done
}

reject_symlinked_parent_components() {
  local label="$1"
  local path="$2"

  if [[ "$path" != /* ]]; then
    fail "$label path must be absolute: $path"
  fi
  reject_symlinked_path_components "$label parent" "$(dirname -- "$path")"
}

check_user_owned_nonwritable_directory() {
  local label="$1"
  local path="$2"
  local current_uid
  local mode
  local mode_tail
  local owner_uid
  local stat_output

  reject_symlinked_path_components "$label" "$path"
  if [[ -L "$path" ]]; then
    fail "$label is a symlink: $path"
  fi
  if [[ ! -d "$path" ]]; then
    fail "$label is missing or not a directory: $path"
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    fail "could not inspect $label: $path"
  fi
  current_uid="$(id -u)"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    fail "$label is owned by uid $owner_uid, expected $current_uid: $path"
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      fail "$label has permissions $mode, expected no group/other write: $path"
      ;;
  esac
}

check_user_owned_private_file() {
  local label="$1"
  local path="$2"
  local current_uid
  local mode
  local mode_tail
  local owner_uid
  local stat_output

  reject_symlinked_path_components "$label" "$path"
  if [[ -L "$path" ]]; then
    fail "$label must not be a symlink: $path"
  fi
  if [[ ! -f "$path" ]]; then
    fail "$label is missing or not a regular file: $path"
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    fail "could not inspect $label: $path"
  fi
  current_uid="$(id -u)"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    fail "$label is owned by uid $owner_uid, expected $current_uid: $path"
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      fail "$label has permissions $mode, expected no group/other write: $path"
      ;;
  esac
}

check_installed_command_tree() {
  check_user_owned_nonwritable_directory "home directory" "$HOME"
  check_user_owned_nonwritable_directory "installed command directory" "${HOME}/.local"
  check_user_owned_nonwritable_directory "installed command directory" "${HOME}/.local/bin"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics/venv"
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics/venv/bin"
}

check_installed_noaa_command() {
  local current_uid
  local mode
  local mode_tail
  local owner_uid
  local resolved_path
  local stat_output

  check_installed_command_tree
  reject_symlinked_parent_components "installed noaa-navionics command" "$command_path"
  if [[ ! -L "$command_path" ]]; then
    fail "installed noaa-navionics command is not the expected private venv symlink: $command_path"
  fi
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    fail "could not resolve installed noaa-navionics command: $command_path"
  fi
  if [[ "$resolved_path" != "$expected_resolved" ]]; then
    fail "installed noaa-navionics command resolves to $resolved_path, expected $expected_resolved"
  fi
  if [[ ! -f "$resolved_path" ]]; then
    fail "installed noaa-navionics command target is not a regular file: $resolved_path"
  fi
  if [[ ! -x "$resolved_path" ]]; then
    fail "installed noaa-navionics command is not executable after resolution: $resolved_path"
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$resolved_path" 2>/dev/null)"; then
    fail "could not inspect installed noaa-navionics command target: $resolved_path"
  fi
  current_uid="$(id -u)"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    fail "installed noaa-navionics command target is owned by uid $owner_uid, expected $current_uid: $resolved_path"
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      fail "installed noaa-navionics command target has permissions $mode, expected no group/other write: $resolved_path"
      ;;
  esac
  "$python3_cmd" - "$resolved_path" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
nofollow = getattr(os, "O_NOFOLLOW", 0)
try:
    before = os.stat(path, follow_symlinks=False)
except OSError as exc:
    print(f"could not inspect installed noaa-navionics command target through no-follow stat: {path}: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
if not stat.S_ISREG(before.st_mode):
    print(f"installed noaa-navionics command target is not a regular non-symlink file: {path}", file=sys.stderr)
    raise SystemExit(1)
if before.st_uid != os.getuid():
    print(
        f"installed noaa-navionics command target is owned by uid {before.st_uid}, expected current user {os.getuid()}: {path}",
        file=sys.stderr,
    )
    raise SystemExit(1)
mode = stat.S_IMODE(before.st_mode)
if mode & 0o022:
    print(f"installed noaa-navionics command target has permissions {mode:03o}, expected no group/other write: {path}", file=sys.stderr)
    raise SystemExit(1)
if not mode & 0o111:
    print(f"installed noaa-navionics command target is not executable: {path}", file=sys.stderr)
    raise SystemExit(1)
try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except OSError as exc:
    print(f"could not open installed noaa-navionics command through no-follow descriptor: {path}: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        print(f"installed noaa-navionics command changed before it could be validated: {path}", file=sys.stderr)
        raise SystemExit(1)
    if not stat.S_ISREG(opened.st_mode):
        print(f"opened installed noaa-navionics command is not regular: {path}", file=sys.stderr)
        raise SystemExit(1)
finally:
    os.close(fd)
PY
  printf '%s\n' "$resolved_path"
}

run_noaa_navionics() {
  local app_exec
  app_exec="$(check_installed_noaa_command)"
  "$python3_cmd" - "$app_exec" "$@" <<'PY'
from pathlib import Path
import os
import stat
import subprocess
import sys

path = Path(sys.argv[1])
args = sys.argv[2:]
nofollow = getattr(os, "O_NOFOLLOW", 0)


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


try:
    before = os.stat(path, follow_symlinks=False)
except OSError as exc:
    fail(f"could not inspect installed noaa-navionics command before descriptor execution: {path}: {exc}")
if not stat.S_ISREG(before.st_mode):
    fail(f"installed noaa-navionics command must be regular before descriptor execution: {path}")
if before.st_uid != os.getuid():
    fail(f"installed noaa-navionics command is owned by uid {before.st_uid}, expected current user {os.getuid()}: {path}")
mode = stat.S_IMODE(before.st_mode)
if mode & 0o022:
    fail(f"installed noaa-navionics command has permissions {mode:03o}, expected no group/other write bits: {path}")
if not mode & 0o111:
    fail(f"installed noaa-navionics command is not executable before descriptor execution: {path}")

try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except OSError as exc:
    fail(f"could not open installed noaa-navionics command through no-follow descriptor for execution: {path}: {exc}")
try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        fail(f"installed noaa-navionics command changed before descriptor execution: {path}")
    if not stat.S_ISREG(opened.st_mode):
        fail(f"installed noaa-navionics command must be regular when opened for descriptor execution: {path}")
    if opened.st_uid != os.getuid():
        fail(f"installed noaa-navionics command is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}")
    opened_mode = stat.S_IMODE(opened.st_mode)
    if opened_mode & 0o022:
        fail(f"installed noaa-navionics command has permissions {opened_mode:03o}, expected no group/other write bits: {path}")
    if not opened_mode & 0o111:
        fail(f"installed noaa-navionics command is not executable when opened for descriptor execution: {path}")
    try:
        result = subprocess.run([f"/proc/self/fd/{fd}", *args], pass_fds=(fd,))
    except OSError as exc:
        fail(f"could not execute installed noaa-navionics command through validated descriptor: {path}: {exc}")
finally:
    os.close(fd)
raise SystemExit(result.returncode)
PY
}

python3_cmd="$(require_remote_command python3)"
validate_status_controls
check_user_owned_private_file "onboard NOAA Navionics config" "$config_path"
if [[ -z "$NOAA_NAVIONICS_STATUS_GPS_SECONDS" ]]; then
  check_user_owned_private_file "NOAA Navionics launcher environment" "$launcher_env_path"
fi

status_args=(
  status-report
  --config "$config_path"
)
if [[ -n "$NOAA_NAVIONICS_STATUS_GPS_SECONDS" ]]; then
  status_args+=(--gps-seconds "$NOAA_NAVIONICS_STATUS_GPS_SECONDS")
else
  status_args+=(--gps-seconds-from-launcher-env "$launcher_env_path")
fi
if [[ "$NOAA_NAVIONICS_STATUS_JSON" == "1" ]]; then
  status_args+=(--json)
fi

run_noaa_navionics "${status_args[@]}"
REMOTE
}

if [[ "$json" -eq 1 ]]; then
  status_capture="$(create_private_status_json_capture)"
  cleanup_status_capture() {
    cleanup_private_status_json_capture "${status_capture:-}" || true
  }
  trap cleanup_status_capture EXIT
  set +e
  capture_remote_status_json "$status_capture"
  status_code=$?
  set -e
  if [[ "$status_code" -eq 124 ]]; then
    exit 2
  fi
  set +e
  status_output="$(read_private_status_json_capture "$status_capture")"
  read_status=$?
  set -e
  if [[ "$read_status" -eq 124 ]]; then
    exit 2
  fi
  if [[ "$read_status" -ne 0 ]]; then
    exit "$read_status"
  fi
  if [[ -n "$status_output" ]]; then
    printf '%s\n' "$status_output"
  fi
  set +e
  validate_status_json_output "$status_output"
  json_validation_code=$?
  set -e
  if [[ "$status_code" -ne 0 ]]; then
    exit "$status_code"
  fi
  exit "$json_validation_code"
fi

run_remote_status
