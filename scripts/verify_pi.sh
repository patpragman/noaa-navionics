#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 1 ]]; then
  cat >&2 <<'EOF'
Usage: scripts/verify_pi.sh user@raspberrypi.local

Runs onboard verification on the Raspberry Pi over SSH.
Nothing is installed or enabled on the local computer.
EOF
  exit 2
fi

target="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_revision="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
worktree_status="$(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null || true)"
if [[ "$expected_revision" != "unknown" && -n "$worktree_status" ]]; then
  expected_revision="${expected_revision}-dirty"
fi
expected_revision_quoted="$(printf '%q' "$expected_revision")"

ssh -t "$target" "NOAA_NAVIONICS_EXPECTED_REVISION=${expected_revision_quoted} bash -s" <<'REMOTE'
set -euo pipefail

failures=0
config="${HOME}/.config/noaa-navionics/config.ini"
bin="${HOME}/.local/bin/noaa-navionics"
launcher="${HOME}/.local/bin/noaa-navionics-start-chartplotter"
autostart="${HOME}/.config/autostart/noaa-navionics-chartplotter.desktop"
status_report="${HOME}/.cache/noaa-navionics/status.json"
revision_file="${HOME}/.local/share/noaa-navionics/source-revision"
status_attempts=3
status_retry_delay=30

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
check "chartplotter autostart" test -f "$autostart"
if [[ -f "$autostart" ]]; then
  check "chartplotter autostart exec" grep -Fq 'noaa-navionics-start-chartplotter' "$autostart"
  check "chartplotter autostart enabled" grep -Fq 'X-GNOME-Autostart-enabled=true' "$autostart"
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
