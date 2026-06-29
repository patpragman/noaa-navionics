#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify_pi.sh [--require-chartplotter-started] user@raspberrypi.local

Runs onboard verification on the Raspberry Pi over SSH.
With --require-chartplotter-started, also requires a post-boot launcher log
and a running OpenCPN process.
Nothing is installed or enabled on the local computer.
EOF
}

target=""
require_chartplotter_started=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-chartplotter-started)
      require_chartplotter_started=1
      shift
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

if [[ -z "$target" ]]; then
  usage
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_revision="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
worktree_status="$(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null || true)"
if [[ "$expected_revision" != "unknown" && -n "$worktree_status" ]]; then
  expected_revision="${expected_revision}-dirty"
fi
expected_revision_quoted="$(printf '%q' "$expected_revision")"
require_chartplotter_started_quoted="$(printf '%q' "$require_chartplotter_started")"

ssh -t "$target" "NOAA_NAVIONICS_EXPECTED_REVISION=${expected_revision_quoted} NOAA_NAVIONICS_REQUIRE_CHARTPLOTTER_STARTED=${require_chartplotter_started_quoted} bash -s" <<'REMOTE'
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
revision_file="${HOME}/.local/share/noaa-navionics/source-revision"
status_attempts=3
status_retry_delay=30
require_chartplotter_started="${NOAA_NAVIONICS_REQUIRE_CHARTPLOTTER_STARTED:-0}"
chartplotter_start_timeout=120
chartplotter_start_interval=5

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

check_status_report_json() {
  local path="$1"
  python3 - "$path" <<'PY'
from datetime import datetime, timezone
import json
import os
import sys

path = sys.argv[1]
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
expected_revision = os.environ.get("NOAA_NAVIONICS_EXPECTED_REVISION", "unknown")
app = report.get("app")
if not isinstance(app, dict):
    raise SystemExit("status report has no app section")
actual_revision = str(app.get("source_revision", "unknown"))
if expected_revision != "unknown" and actual_revision != expected_revision:
    raise SystemExit(f"status report source revision {actual_revision} does not match {expected_revision}")
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
startup_index = text.rfind(startup_marker)
launch_index = text.rfind(launch_marker)
if startup_index < 0:
    raise SystemExit("launcher log does not contain startup marker")
if launch_index < startup_index:
    raise SystemExit("launcher log does not contain OpenCPN launch marker")
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
  pgrep -x opencpn >/dev/null
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

check "noaa-navionics command" test -x "$bin"
check "chartplotter launcher" test -x "$launcher"
check "desktop autologin helper" test -x "$desktop_autologin"
if [[ -x "$launcher" ]]; then
  check "chartplotter launcher readiness gate" grep -Fq 'status-report --config "$config" --gps-seconds 10 --output "$status_report"' "$launcher"
  check "chartplotter launcher ENC parse" grep -Fq 'opencpn -parse_all_enc' "$launcher"
  check "chartplotter launcher display awake" grep -Fq 'keep_display_awake' "$launcher"
fi
check "chartplotter autostart" test -f "$autostart"
if [[ -f "$autostart" ]]; then
  check "chartplotter autostart type" grep -Fxq 'Type=Application' "$autostart"
  check "chartplotter autostart exec" grep -Fq 'noaa-navionics-start-chartplotter' "$autostart"
  check "chartplotter autostart terminal" grep -Fxq 'Terminal=false' "$autostart"
  check "chartplotter autostart enabled" grep -Fq 'X-GNOME-Autostart-enabled=true' "$autostart"
fi
check "graphical boot target" sh -c 'systemctl get-default 2>/dev/null | grep -qx graphical.target'
check "LightDM unit installed" sh -c 'systemctl --no-pager --no-legend list-unit-files lightdm.service 2>/dev/null | grep -q "^lightdm.service"'
check "LightDM enabled" systemctl is-enabled --quiet lightdm.service
check "LightDM autologin config" test -f "$lightdm_autologin"
if [[ -f "$lightdm_autologin" ]]; then
  check "LightDM autologin seat" grep -Fxq '[Seat:*]' "$lightdm_autologin"
  check "LightDM autologin user" grep -Fxq "autologin-user=${USER}" "$lightdm_autologin"
  check "LightDM autologin timeout" grep -Fxq 'autologin-user-timeout=0' "$lightdm_autologin"
fi
if [[ "$require_chartplotter_started" -eq 1 ]]; then
  printf '\n[chartplotter startup]\n'
  check "chartplotter started after boot" wait_for_chartplotter_started
  if opencpn_running; then
    check "OpenCPN running" true
  else
    check "OpenCPN running" false
  fi
fi
check "config file" test -f "$config"
check "source revision recorded" test -s "$revision_file"
if [[ -s "$revision_file" && "${NOAA_NAVIONICS_EXPECTED_REVISION:-unknown}" != "unknown" ]]; then
  installed_revision="$(tr -d '[:space:]' <"$revision_file")"
  check "source revision matches" test "$installed_revision" = "$NOAA_NAVIONICS_EXPECTED_REVISION"
fi
check "OpenCPN command" command -v opencpn
check "GPSD command" command -v gpsd
check "GPSD config" test -f /etc/default/gpsd
if [[ -r /etc/default/gpsd ]]; then
  check "GPSD daemon enabled" grep -Eq '^START_DAEMON="true"' /etc/default/gpsd
  check "GPSD USB auto disabled" grep -Eq '^USBAUTO="false"' /etc/default/gpsd
  check "GPSD immediate polling" grep -Eq '^GPSD_OPTIONS="[^"]*-n[^"]*"' /etc/default/gpsd
  check "GPSD device configured" grep -Eq '^DEVICES="[^"]+"' /etc/default/gpsd
  gpsd_device="$(sed -n 's/^DEVICES="\([^"]*\)".*/\1/p' /etc/default/gpsd | awk '{print $1}')"
  if [[ -n "$gpsd_device" ]]; then
    check "GPSD device exists" test -e "$gpsd_device"
    check "GPSD device matches config" check_gpsd_device_matches_config "$config" "$gpsd_device"
    case "$gpsd_device" in
      /dev/serial/by-id/*)
        printf 'OK   GPSD stable device path %s\n' "$gpsd_device"
        ;;
      *)
        printf 'WARN GPSD device path %s is not under /dev/serial/by-id/\n' "$gpsd_device"
        ;;
    esac
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
check "chart service sync command" grep -Fq 'ExecStart=%h/.local/bin/noaa-navionics sync-charts --config %h/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30' "$chart_service"
check "chart service timeout" grep -Fxq 'TimeoutStartSec=2h' "$chart_service"
check "chart timer weekly" grep -Fxq 'OnCalendar=weekly' "$chart_timer"
check "chart timer persistent" grep -Fxq 'Persistent=true' "$chart_timer"
check "track service file" test -f "$track_service"
check "track service rotate daily" grep -Fq 'ExecStart=%h/.local/bin/noaa-navionics log-track --config %h/.config/noaa-navionics/config.ini --rotate-daily' "$track_service"
check "track service restart" grep -Fxq 'Restart=on-failure' "$track_service"
check "preflight service file" test -f "$preflight_service"
check "preflight service status report" grep -Fq 'ExecStart=%h/.local/bin/noaa-navionics status-report --config %h/.config/noaa-navionics/config.ini --gps-seconds 10 --output %h/.cache/noaa-navionics/status.json' "$preflight_service"
check "preflight service restart delay" grep -Fxq 'RestartSec=30' "$preflight_service"
check "user linger enabled" sh -c "loginctl show-user '$USER' -p Linger 2>/dev/null | grep -q '^Linger=yes$'"
check "chart timer enabled" systemctl --user is-enabled --quiet noaa-navionics.timer
check "track service enabled" systemctl --user is-enabled --quiet noaa-navionics-track.service
check "preflight service enabled" systemctl --user is-enabled --quiet noaa-navionics-preflight.service
check "chart timer active" systemctl --user is-active --quiet noaa-navionics.timer

printf '\n[preflight]\n'
preflight_ok=0
for attempt in $(seq 1 "$status_attempts"); do
  if "$bin" status-report --config "$config" --gps-seconds 10 --output "$status_report"; then
    printf 'OK   preflight\n'
    printf 'OK   status report %s\n' "$status_report"
    check "status report JSON ready" check_status_report_json "$status_report"
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

if [[ "$failures" -eq 0 ]]; then
  printf '\nRaspberry Pi verification passed.\n'
else
  printf '\nRaspberry Pi verification failed: %d issue(s).\n' "$failures"
fi

exit "$failures"
REMOTE
