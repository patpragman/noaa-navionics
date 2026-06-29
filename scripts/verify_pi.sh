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

ssh -t "$target" 'bash -s' <<'REMOTE'
set -euo pipefail

failures=0
config="${HOME}/.config/noaa-navionics/config.ini"
bin="${HOME}/.local/bin/noaa-navionics"
status_report="${HOME}/.cache/noaa-navionics/status.json"

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
check "config file" test -f "$config"
check "OpenCPN command" command -v opencpn
check "GPSD command" command -v gpsd
check "GPSD config" test -f /etc/default/gpsd
if [[ -r /etc/default/gpsd ]]; then
  check "GPSD device configured" grep -Eq '^DEVICES="[^"]+"' /etc/default/gpsd
else
  printf 'FAIL GPSD config readable\n'
  failures=$((failures + 1))
fi

check_output "version/help" "$bin" --help
check_output "configured packages" "$bin" list-packages

printf '\n[systemd user units]\n'
systemctl --user --no-pager list-unit-files 'noaa-navionics*' || failures=$((failures + 1))

printf '\n[preflight]\n'
if "$bin" status-report --config "$config" --gps-seconds 10 --output "$status_report"; then
  printf 'OK   preflight\n'
  printf 'OK   status report %s\n' "$status_report"
else
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
