#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 -m py_compile src/noaa_navionics/*.py
python3 -m unittest discover -s tests -v

bash -n \
  scripts/install_raspberry_pi.sh \
  scripts/deploy_to_pi.sh \
  scripts/verify_pi.sh \
  scripts/start_chartplotter.sh \
  scripts/configure_gpsd.sh \
  scripts/provision_sailboat_pi.sh \
  scripts/dock_test_pi.sh \
  scripts/check.sh

grep -q 'status-report' systemd/noaa-navionics-preflight.service
grep -q 'status.json' systemd/noaa-navionics-preflight.service
grep -q 'chartplotter.log' scripts/start_chartplotter.sh
grep -q 'max_log_bytes' scripts/start_chartplotter.sh
grep -q 'keep_display_awake' scripts/start_chartplotter.sh
grep -q 'xset s noblank' scripts/start_chartplotter.sh
grep -q -- '--gps-seconds 10' scripts/start_chartplotter.sh
grep -q '.source-revision' scripts/deploy_to_pi.sh
grep -q -- '--allow-dirty' scripts/deploy_to_pi.sh
grep -q -- '--allow-dirty' scripts/dock_test_pi.sh
grep -q 'dirty worktree' scripts/deploy_to_pi.sh
grep -q 'source-revision' scripts/install_raspberry_pi.sh
grep -q 'VERSION_CODENAME' scripts/install_raspberry_pi.sh
grep -q 'install -m 0755' scripts/install_raspberry_pi.sh
grep -q 'source-revision' scripts/verify_pi.sh
grep -q 'source revision matches' scripts/verify_pi.sh
grep -q 'expected_revision="${expected_revision}-dirty"' scripts/verify_pi.sh
grep -q 'chartplotter autostart' scripts/verify_pi.sh
grep -q 'GPSD immediate polling' scripts/verify_pi.sh
grep -q 'GPS device must be an absolute /dev path' scripts/configure_gpsd.sh
grep -q 'status_attempts=3' scripts/verify_pi.sh
grep -q 'no fresh GPSD fix' src/noaa_navionics/health.py
grep -q 'no fresh NMEA fix' src/noaa_navionics/health.py
grep -q 'manifest recorded' src/noaa_navionics/health.py
grep -q 'manifest extract path is outside chart directory' src/noaa_navionics/health.py
grep -q 'extracted ZIP contains no ENC .000 cells' src/noaa_navionics/downloader.py
grep -q 'chart update already in progress' src/noaa_navionics/downloader.py
grep -q 'self.path.open("x", encoding="utf-8")' src/noaa_navionics/gps.py
grep -q 'signal.SIGTERM' src/noaa_navionics/cli.py
grep -q 'charts.package must be one of' src/noaa_navionics/config.py
grep -q 'gps.gpsd_host must be a hostname or IP address' src/noaa_navionics/config.py
grep -q 'gps.mode must be either gpsd or serial' src/noaa_navionics/config.py
grep -q 'GPSD skipped: gps.mode' src/noaa_navionics/cli.py
grep -q 'if active == "failed"' src/noaa_navionics/report.py
grep -q 'def _unit_query_failed' src/noaa_navionics/report.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/report.py
grep -q 'TimeoutStartSec=2h' systemd/noaa-navionics.service
grep -q 'RestartSec=30min' systemd/noaa-navionics.service
grep -q -- '--retries "$sync_retries" --retry-delay "$sync_retry_delay"' scripts/provision_sailboat_pi.sh

install_output="$(mktemp)"
provision_output="$(mktemp)"
gpsd_output="$(mktemp)"
trap 'rm -rf "${tmpdir:-}" "$install_output" "$provision_output" "$gpsd_output"' EXIT

set +e
scripts/install_raspberry_pi.sh --skip-apt --no-services >"$install_output" 2>&1
install_code=$?
set -e
if [[ "$install_code" -ne 2 ]]; then
  cat "$install_output" >&2
  echo "expected install_raspberry_pi.sh to refuse non-Pi architecture with exit 2" >&2
  exit 1
fi

set +e
scripts/provision_sailboat_pi.sh --device /dev/ttyUSB0 >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to refuse non-Pi architecture with exit 2" >&2
  exit 1
fi

set +e
scripts/configure_gpsd.sh --allow-non-pi --dry-run --no-device-check --device relative-gps >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject non-/dev GPS path with exit 2" >&2
  exit 1
fi

set +e
scripts/configure_gpsd.sh --allow-non-pi --dry-run --no-device-check --device "/dev/tty USB0" >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject GPS path containing whitespace with exit 2" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --device /dev/ttyUSB0 \
  --config "$tmpdir/config.ini" \
  --sync-retries 7 \
  --sync-retry-delay 15 >/dev/null

launcher_home="$tmpdir/launcher-home"
mkdir -p "$launcher_home/.local/bin" "$launcher_home/.cache/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\necho fake opencpn\n' >"$tmpdir/opencpn"
printf '#!/usr/bin/env bash\nprintf "xset %%s\\n" "$*" >>"$HOME/.cache/noaa-navionics/xset.log"\n' >"$tmpdir/xset"
chmod +x "$launcher_home/.local/bin/noaa-navionics" "$tmpdir/opencpn" "$tmpdir/xset"
head -c 1048577 /dev/zero >"$launcher_home/.cache/noaa-navionics/chartplotter.log"
HOME="$launcher_home" DISPLAY=:99 PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
test -f "$launcher_home/.cache/noaa-navionics/chartplotter.log.1"
test -f "$launcher_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'xset s off' "$launcher_home/.cache/noaa-navionics/xset.log"
grep -q 'xset s noblank' "$launcher_home/.cache/noaa-navionics/xset.log"
grep -q 'xset -dpms' "$launcher_home/.cache/noaa-navionics/xset.log"

echo "All checks passed."
