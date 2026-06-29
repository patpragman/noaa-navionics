#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify_pi.sh [--require-chartplotter-started] [--gps-seconds N] user@raspberrypi.local

Runs onboard verification on the Raspberry Pi over SSH.
With --require-chartplotter-started, also requires a post-boot launcher log
and a running OpenCPN process.
Use --gps-seconds to allow a longer GPS fix wait during the status report.
Nothing is installed or enabled on the local computer.
EOF
}

target=""
require_chartplotter_started=0
gps_seconds=10

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer" >&2
    exit 2
  fi
}

require_local_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required local command: $command_name" >&2
    exit 2
  fi
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-chartplotter-started)
      require_chartplotter_started=1
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
expected_revision="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
worktree_status="$(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null || true)"
if [[ "$expected_revision" != "unknown" && -n "$worktree_status" ]]; then
  expected_revision="${expected_revision}-dirty"
fi
expected_revision_quoted="$(printf '%q' "$expected_revision")"
require_chartplotter_started_quoted="$(printf '%q' "$require_chartplotter_started")"
gps_seconds_quoted="$(printf '%q' "$gps_seconds")"

ssh -T "$target" "NOAA_NAVIONICS_EXPECTED_REVISION=${expected_revision_quoted} NOAA_NAVIONICS_REQUIRE_CHARTPLOTTER_STARTED=${require_chartplotter_started_quoted} NOAA_NAVIONICS_GPS_SECONDS=${gps_seconds_quoted} bash -s" <<'REMOTE'
set -euo pipefail

failures=0
config="${HOME}/.config/noaa-navionics/config.ini"
bin="${HOME}/.local/bin/noaa-navionics"
launcher="${HOME}/.local/bin/noaa-navionics-start-chartplotter"
desktop_autologin="${HOME}/.local/bin/noaa-navionics-configure-desktop-autologin"
autostart="${HOME}/.config/autostart/noaa-navionics-chartplotter.desktop"
lightdm_autologin="/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf"
status_report="${HOME}/.cache/noaa-navionics/status.json"
log_file="${HOME}/.cache/noaa-navionics/chartplotter.log"
launcher_lock="${HOME}/.cache/noaa-navionics/chartplotter.launch.lock"
revision_file="${HOME}/.local/share/noaa-navionics/source-revision"
launcher_env="${HOME}/.config/noaa-navionics/launcher.env"
status_attempts=3
status_retry_delay=30
require_chartplotter_started="${NOAA_NAVIONICS_REQUIRE_CHARTPLOTTER_STARTED:-0}"
gps_seconds="${NOAA_NAVIONICS_GPS_SECONDS:-10}"
chartplotter_start_timeout=120
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
  python3 - "$path" "$require_current_boot" "$expected_config_path" <<'PY'
from pathlib import Path
from configparser import ConfigParser
from datetime import datetime, timezone
import json
import os
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

def parse_manifest_int(value, field, source):
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"status report manifest {field} is invalid in {source}: {value!r}") from exc

path = sys.argv[1]
require_current_boot = sys.argv[2] == "1"
expected_config_path = sys.argv[3]
require_track_disk_check = False
with open(path, encoding="utf-8") as handle:
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
    with Path(expected_manifest_path).open(encoding="utf-8") as manifest_handle:
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
    if expected_package_source_url and manifest_download_url != expected_package_source_url:
        raise SystemExit(
            f"status report manifest download URL {manifest_download_url} "
            f"does not match configured {expected_package_source_url}"
        )
    download_path = Path(str(manifest.get("download_path", "")).strip()).expanduser()
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
    if status_download_bytes <= 0:
        raise SystemExit(f"status report manifest download byte count is not positive: {expected_manifest_path}")
    extract_path = Path(str(manifest.get("extract_path", "")).strip()).expanduser()
    try:
        extract_path.resolve().relative_to(chart_output.resolve())
    except ValueError as exc:
        raise SystemExit(
            f"status report manifest extract path {extract_path} is outside {chart_output}"
        ) from exc
    if not extract_path.exists():
        raise SystemExit(f"status report manifest extract path does not exist: {extract_path}")
    if status_enc_cell_count <= 0:
        raise SystemExit(f"status report manifest has no ENC cells: {expected_manifest_path}")
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
    "GPSD",
    "GPS Time Source",
}
if require_track_disk_check:
    required_checks.add("Track Disk")
required_service_checks = {
    "Chart Sync",
    "Chart Sync Settings",
    "Chart Timer",
    "Chart Timer Settings",
    "Track Logger",
    "Track Logger Settings",
    "Boot Readiness",
    "Boot Readiness Settings",
    "Boot Readiness Run",
    "GPSD Service",
    "Chrony Service",
}
missing_checks = sorted(required_checks - check_names)
if missing_checks:
    raise SystemExit("status report missing readiness checks: " + ", ".join(missing_checks))
missing_service_checks = sorted(required_service_checks - service_check_names)
if missing_service_checks:
    raise SystemExit("status report missing service checks: " + ", ".join(missing_service_checks))
expected_revision = os.environ.get("NOAA_NAVIONICS_EXPECTED_REVISION", "unknown")
app = report.get("app")
if not isinstance(app, dict):
    raise SystemExit("status report has no app section")
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
    if report_boot_id != current_boot_id:
        raise SystemExit(
            f"status report boot ID {report_boot_id} does not match current boot {current_boot_id}"
        )
if any(not isinstance(check, dict) or check.get("ok") is not True for check in checks):
    raise SystemExit("status report contains a failed readiness check")
if any(not isinstance(check, dict) or check.get("ok") is not True for check in service_checks):
    raise SystemExit("status report contains a failed service check")
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

check_chartplotter_log_after_boot() {
  local path="$1"
  python3 - "$path" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import sys
import time

path = Path(sys.argv[1]).expanduser()
if not path.exists():
    raise SystemExit(f"missing launcher log: {path}")
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
  pgrep -u "$(id -u)" -x opencpn >/dev/null
}

check_opencpn_stable() {
  if ! opencpn_running; then
    printf 'OpenCPN is not running before stability wait\n' >&2
    return 1
  fi
  sleep "$opencpn_stability_seconds"
  if ! opencpn_running; then
    printf 'OpenCPN exited within %ss of startup verification\n' "$opencpn_stability_seconds" >&2
    return 1
  fi
}

wait_for_chartplotter_started() {
  local deadline=$((SECONDS + chartplotter_start_timeout))
  local last_detail=""
  local check_output
  check_output="$(mktemp)"
  trap 'rm -f "$check_output"' RETURN
  while true; do
    if check_chartplotter_log_after_boot "$log_file" >"$check_output" 2>&1; then
      if opencpn_running; then
        return 0
      fi
      last_detail="OpenCPN is not running yet"
    else
      last_detail="$(cat "$check_output" 2>/dev/null || true)"
    fi
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf '%s\n' "${last_detail:-chartplotter did not start before timeout}" >&2
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
tracks_dir = Path(track_output).expanduser() / "tracks"
try:
    uptime_seconds = float(Path("/proc/uptime").read_text(encoding="ascii").split()[0])
except Exception as exc:
    raise SystemExit(f"could not read /proc/uptime: {exc}") from exc
boot_epoch = time.time() - uptime_seconds
deadline = time.monotonic() + timeout
last_detail = ""
while True:
    now = time.time()
    if tracks_dir.exists():
        candidates = []
        for path in tracks_dir.glob("track-*.gpx"):
            try:
                stat = path.stat()
            except OSError as exc:
                last_detail = f"could not inspect {path}: {exc}"
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
            for trackpoint in trackpoint_times:
                match = re.search(r"<time>([^<]+)</time>", trackpoint)
                if not match:
                    continue
                timestamp_text = match.group(1).strip()
                try:
                    track_time = datetime.fromisoformat(timestamp_text.replace("Z", "+00:00")).astimezone(timezone.utc)
                except ValueError:
                    last_detail = f"{path} has an invalid GPX trackpoint timestamp: {timestamp_text}"
                    continue
                if newest_track_time is None or track_time > newest_track_time:
                    newest_track_time = track_time
            if newest_track_time is None:
                last_detail = f"{path} has GPX trackpoints but no timestamped trackpoint yet"
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
            print(path)
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
check "noaa-navionics command" test -x "$bin"
check "chartplotter launcher" test -x "$launcher"
check "desktop autologin helper" test -x "$desktop_autologin"
if [[ -x "$launcher" ]]; then
  check "chartplotter launcher readiness gate" grep -Fq 'status-report --config "$config" --gps-seconds "$gps_seconds" --output "$status_report"' "$launcher"
  check "chartplotter launcher GPS wait config" grep -Fq 'NOAA_NAVIONICS_GPS_SECONDS' "$launcher"
  check "chartplotter launcher ENC parse" grep -Fq 'opencpn -parse_all_enc' "$launcher"
  check "chartplotter launcher display awake" grep -Fq 'keep_display_awake' "$launcher"
  check "chartplotter launcher display failure logging" grep -Fq 'xset command(s) failed' "$launcher"
  check "chartplotter launcher readiness warning" grep -Fq 'show_preflight_warning' "$launcher"
  check "chartplotter launcher duplicate guard" grep -Fq 'OpenCPN is already running' "$launcher"
  check "chartplotter launcher lock" grep -Fq 'chartplotter.launch.lock' "$launcher"
  check "chartplotter launcher lock sync create" grep -Fq 'sync_paths "${launcher_lock_dir}/pid" "$launcher_lock_dir"' "$launcher"
  check "chartplotter launcher lock sync cleanup" grep -Fq 'sync_paths "$launcher_lock_dir"' "$launcher"
  check "chartplotter launcher stale lock recovery" grep -Fq 'is not a chartplotter launcher; treating lock as stale' "$launcher"
fi
check "chartplotter launcher GPS wait persisted" grep -Fxq "NOAA_NAVIONICS_GPS_SECONDS=${gps_seconds}" "$launcher_env"
check "chartplotter autostart" test -f "$autostart"
if [[ -f "$autostart" ]]; then
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
check "LightDM autologin config" test -f "$lightdm_autologin"
if [[ -f "$lightdm_autologin" ]]; then
  check "LightDM autologin seat" grep -Fxq '[Seat:*]' "$lightdm_autologin"
  check "LightDM autologin user" grep -Fxq "autologin-user=${USER}" "$lightdm_autologin"
  check "LightDM autologin timeout" grep -Fxq 'autologin-user-timeout=0' "$lightdm_autologin"
  check "LightDM autologin X11 session" check_lightdm_autologin_session "$lightdm_autologin"
fi
if [[ "$require_chartplotter_started" -eq 1 ]]; then
  printf '\n[chartplotter startup]\n'
  check "chartplotter started after boot" wait_for_chartplotter_started
  check "chartplotter launcher lock clear" test ! -e "$launcher_lock"
  if opencpn_running; then
    check "OpenCPN running" true
  else
    check "OpenCPN running" false
  fi
  check "OpenCPN stable after startup" check_opencpn_stable
  check "boot status report JSON ready" check_status_report_json "$status_report" 1 "$config"
fi
check "config file" test -f "$config"
check "source revision recorded" test -s "$revision_file"
if [[ -s "$revision_file" && "${NOAA_NAVIONICS_EXPECTED_REVISION:-unknown}" != "unknown" ]]; then
  installed_revision="$(tr -d '[:space:]' <"$revision_file")"
  check "source revision matches" test "$installed_revision" = "$NOAA_NAVIONICS_EXPECTED_REVISION"
fi
check "OpenCPN command" command -v opencpn
check "display power command" command -v xset
check "Pi power command" command -v vcgencmd
check "Chrony command" command -v chronyc
check "Chrony service enabled" systemctl is-enabled --quiet chrony
check "Chrony service active" systemctl is-active --quiet chrony
check "Chrony GPSD time source" grep -Fq 'refclock SHM 0 offset 0.5 delay 0.1 refid GPS' /etc/chrony/chrony.conf
check "Chrony usable GPS source" wait_for_chrony_gps_source
check "GPSD command" command -v gpsd
check "GPSD service enabled" systemctl is-enabled --quiet gpsd
check "GPSD service active" systemctl is-active --quiet gpsd
check "GPSD config" test -f /etc/default/gpsd
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
systemd_user_dir="${HOME}/.config/systemd/user"
chart_service="${systemd_user_dir}/noaa-navionics.service"
chart_timer="${systemd_user_dir}/noaa-navionics.timer"
track_service="${systemd_user_dir}/noaa-navionics-track.service"
preflight_service="${systemd_user_dir}/noaa-navionics-preflight.service"
check "chart service file" test -f "$chart_service"
check "chart service type" grep -Fxq 'Type=oneshot' "$chart_service"
check "chart service loaded type" sh -c 'systemctl --user show noaa-navionics.service -p Type 2>/dev/null | grep -Fxq Type=oneshot'
check "chart service sync command" grep -Fq 'ExecStart=%h/.local/bin/noaa-navionics sync-charts --config %h/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30' "$chart_service"
check "chart service loaded sync command" sh -c 'loaded="$(systemctl --user show noaa-navionics.service -p ExecStart 2>/dev/null)" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics sync-charts" && printf "%s\n" "$loaded" | grep -Fq -- "--config" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics/config.ini" && printf "%s\n" "$loaded" | grep -Fq -- "--retries 5" && printf "%s\n" "$loaded" | grep -Fq -- "--retry-delay 30"'
check "chart service timeout" grep -Fxq 'TimeoutStartSec=2h' "$chart_service"
check "chart service loaded timeout" sh -c 'systemctl --user show noaa-navionics.service -p TimeoutStartUSec 2>/dev/null | grep -Fxq TimeoutStartUSec=2h'
check "chart service restart" grep -Fxq 'Restart=on-failure' "$chart_service"
check "chart service loaded restart" sh -c 'systemctl --user show noaa-navionics.service -p Restart 2>/dev/null | grep -Fxq Restart=on-failure'
check "chart service loaded restart delay" sh -c 'systemctl --user show noaa-navionics.service -p RestartUSec 2>/dev/null | grep -Fxq RestartUSec=30min'
check "chart service no new privileges" grep -Fxq 'NoNewPrivileges=true' "$chart_service"
check "chart service loaded no new privileges" sh -c 'systemctl --user show noaa-navionics.service -p NoNewPrivileges 2>/dev/null | grep -Fxq NoNewPrivileges=yes'
check "chart service private tmp" grep -Fxq 'PrivateTmp=true' "$chart_service"
check "chart service loaded private tmp" sh -c 'systemctl --user show noaa-navionics.service -p PrivateTmp 2>/dev/null | grep -Fxq PrivateTmp=yes'
check "chart service start limit interval" grep -Fxq 'StartLimitIntervalSec=6h' "$chart_service"
check "chart service loaded start limit interval" sh -c 'systemctl --user show noaa-navionics.service -p StartLimitIntervalUSec 2>/dev/null | grep -Fxq StartLimitIntervalUSec=6h'
check "chart service start limit burst" grep -Fxq 'StartLimitBurst=3' "$chart_service"
check "chart service loaded start limit burst" sh -c 'systemctl --user show noaa-navionics.service -p StartLimitBurst 2>/dev/null | grep -Fxq StartLimitBurst=3'
check "chart timer weekly" grep -Fxq 'OnCalendar=weekly' "$chart_timer"
check "chart timer persistent" grep -Fxq 'Persistent=true' "$chart_timer"
check "chart timer randomized delay" grep -Fxq 'RandomizedDelaySec=30min' "$chart_timer"
check "chart timer install target" grep -Fxq 'WantedBy=timers.target' "$chart_timer"
check "chart timer loaded weekly" sh -c 'systemctl --user show noaa-navionics.timer -p TimersCalendar 2>/dev/null | grep -Fq OnCalendar=weekly'
check "chart timer loaded persistent" sh -c 'systemctl --user show noaa-navionics.timer -p Persistent 2>/dev/null | grep -Fxq Persistent=yes'
check "chart timer loaded randomized delay" sh -c 'systemctl --user show noaa-navionics.timer -p RandomizedDelayUSec 2>/dev/null | grep -Fxq RandomizedDelayUSec=30min'
check "track service file" test -f "$track_service"
check "track service type" grep -Fxq 'Type=simple' "$track_service"
check "track service loaded type" sh -c 'systemctl --user show noaa-navionics-track.service -p Type 2>/dev/null | grep -Fxq Type=simple'
check "track service rotate daily" grep -Fq 'ExecStart=%h/.local/bin/noaa-navionics log-track --config %h/.config/noaa-navionics/config.ini --rotate-daily' "$track_service"
check "track service loaded rotate daily" sh -c 'loaded="$(systemctl --user show noaa-navionics-track.service -p ExecStart 2>/dev/null)" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics log-track" && printf "%s\n" "$loaded" | grep -Fq -- "--config" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics/config.ini" && printf "%s\n" "$loaded" | grep -Fq -- "--rotate-daily"'
check "track service quiet stdout" grep -Fxq 'StandardOutput=null' "$track_service"
check "track service loaded quiet stdout" sh -c 'systemctl --user show noaa-navionics-track.service -p StandardOutput 2>/dev/null | grep -Fxq StandardOutput=null'
check "track service restart" grep -Fxq 'Restart=on-failure' "$track_service"
check "track service loaded restart" sh -c 'systemctl --user show noaa-navionics-track.service -p Restart 2>/dev/null | grep -Fxq Restart=on-failure'
check "track service loaded restart delay" sh -c 'systemctl --user show noaa-navionics-track.service -p RestartUSec 2>/dev/null | grep -Fxq RestartUSec=10s'
check "track service no new privileges" grep -Fxq 'NoNewPrivileges=true' "$track_service"
check "track service loaded no new privileges" sh -c 'systemctl --user show noaa-navionics-track.service -p NoNewPrivileges 2>/dev/null | grep -Fxq NoNewPrivileges=yes'
check "track service private tmp" grep -Fxq 'PrivateTmp=true' "$track_service"
check "track service loaded private tmp" sh -c 'systemctl --user show noaa-navionics-track.service -p PrivateTmp 2>/dev/null | grep -Fxq PrivateTmp=yes'
check "track service start limit interval" grep -Fxq 'StartLimitIntervalSec=10min' "$track_service"
check "track service loaded start limit interval" sh -c 'systemctl --user show noaa-navionics-track.service -p StartLimitIntervalUSec 2>/dev/null | grep -Fxq StartLimitIntervalUSec=10min'
check "track service start limit burst" grep -Fxq 'StartLimitBurst=60' "$track_service"
check "track service loaded start limit burst" sh -c 'systemctl --user show noaa-navionics-track.service -p StartLimitBurst 2>/dev/null | grep -Fxq StartLimitBurst=60'
check "track service install target" grep -Fxq 'WantedBy=default.target' "$track_service"
check "preflight service file" test -f "$preflight_service"
check "preflight service type" grep -Fxq 'Type=oneshot' "$preflight_service"
check "preflight service loaded type" sh -c 'systemctl --user show noaa-navionics-preflight.service -p Type 2>/dev/null | grep -Fxq Type=oneshot'
check "preflight service GPS wait default" grep -Fxq 'Environment=NOAA_NAVIONICS_GPS_SECONDS=10' "$preflight_service"
check "preflight service loaded GPS wait default" sh -c 'systemctl --user show noaa-navionics-preflight.service -p Environment 2>/dev/null | grep -Fq "NOAA_NAVIONICS_GPS_SECONDS=10"'
check "preflight service GPS wait config" grep -Fxq 'EnvironmentFile=-%h/.config/noaa-navionics/launcher.env' "$preflight_service"
check "preflight service status report" grep -Fq 'ExecStart=%h/.local/bin/noaa-navionics status-report --config %h/.config/noaa-navionics/config.ini --gps-seconds ${NOAA_NAVIONICS_GPS_SECONDS} --output %h/.cache/noaa-navionics/status.json' "$preflight_service"
check "preflight service loaded status report" sh -c 'loaded="$(systemctl --user show noaa-navionics-preflight.service -p ExecStart 2>/dev/null)" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics status-report" && printf "%s\n" "$loaded" | grep -Fq -- "--config" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics/config.ini" && printf "%s\n" "$loaded" | grep -Fq -- "--gps-seconds" && printf "%s\n" "$loaded" | grep -Fq -- "--output" && printf "%s\n" "$loaded" | grep -Fq "noaa-navionics/status.json"'
check "preflight service timeout" grep -Fxq 'TimeoutStartSec=0' "$preflight_service"
check "preflight service loaded timeout" sh -c 'systemctl --user show noaa-navionics-preflight.service -p TimeoutStartUSec 2>/dev/null | grep -Fxq TimeoutStartUSec=infinity'
check "preflight service restart" grep -Fxq 'Restart=on-failure' "$preflight_service"
check "preflight service loaded restart" sh -c 'systemctl --user show noaa-navionics-preflight.service -p Restart 2>/dev/null | grep -Fxq Restart=on-failure'
check "preflight service restart delay" grep -Fxq 'RestartSec=30' "$preflight_service"
check "preflight service no new privileges" grep -Fxq 'NoNewPrivileges=true' "$preflight_service"
check "preflight service loaded no new privileges" sh -c 'systemctl --user show noaa-navionics-preflight.service -p NoNewPrivileges 2>/dev/null | grep -Fxq NoNewPrivileges=yes'
check "preflight service private tmp" grep -Fxq 'PrivateTmp=true' "$preflight_service"
check "preflight service loaded private tmp" sh -c 'systemctl --user show noaa-navionics-preflight.service -p PrivateTmp 2>/dev/null | grep -Fxq PrivateTmp=yes'
check "preflight service loaded GPS wait config" sh -c 'systemctl --user show noaa-navionics-preflight.service -p EnvironmentFiles 2>/dev/null | grep -Fq "noaa-navionics/launcher.env"'
check "preflight service loaded restart delay" sh -c 'systemctl --user show noaa-navionics-preflight.service -p RestartUSec 2>/dev/null | grep -Fxq RestartUSec=30s'
check "preflight service start limit interval" grep -Fxq 'StartLimitIntervalSec=30min' "$preflight_service"
check "preflight service loaded start limit interval" sh -c 'systemctl --user show noaa-navionics-preflight.service -p StartLimitIntervalUSec 2>/dev/null | grep -Fxq StartLimitIntervalUSec=30min'
check "preflight service start limit burst" grep -Fxq 'StartLimitBurst=60' "$preflight_service"
check "preflight service loaded start limit burst" sh -c 'systemctl --user show noaa-navionics-preflight.service -p StartLimitBurst 2>/dev/null | grep -Fxq StartLimitBurst=60'
check "preflight service install target" grep -Fxq 'WantedBy=default.target' "$preflight_service"
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
    check "status report JSON ready" check_status_report_json "$status_report" 0 "$config"
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
