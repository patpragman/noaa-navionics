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
  scripts/configure_desktop_autologin.sh \
  scripts/configure_gpsd.sh \
  scripts/provision_sailboat_pi.sh \
  scripts/dock_test_pi.sh \
  scripts/check.sh

grep -q 'status-report' systemd/noaa-navionics-preflight.service
grep -q 'status.json' systemd/noaa-navionics-preflight.service
grep -q 'EnvironmentFile=-%h/.config/noaa-navionics/launcher.env' systemd/noaa-navionics-preflight.service
grep -q -- '--gps-seconds ${NOAA_NAVIONICS_GPS_SECONDS}' systemd/noaa-navionics-preflight.service
grep -q 'chartplotter.log' scripts/start_chartplotter.sh
grep -q 'max_log_bytes' scripts/start_chartplotter.sh
grep -q 'keep_display_awake' scripts/start_chartplotter.sh
grep -q 'xset s noblank' scripts/start_chartplotter.sh
grep -q 'xset command(s) failed' scripts/start_chartplotter.sh
grep -q 'launcher.env' scripts/start_chartplotter.sh
grep -q -- '--gps-seconds "$gps_seconds"' scripts/start_chartplotter.sh
grep -q '.source-revision' scripts/deploy_to_pi.sh
grep -q -- '--allow-dirty' scripts/deploy_to_pi.sh
grep -q -- '--allow-dirty' scripts/dock_test_pi.sh
grep -q -- '--gps-seconds' scripts/dock_test_pi.sh
grep -q 'dirty worktree' scripts/deploy_to_pi.sh
grep -q 'source-revision' scripts/install_raspberry_pi.sh
grep -q 'VERSION_CODENAME' scripts/install_raspberry_pi.sh
grep -q 'ensure_vcgencmd' scripts/install_raspberry_pi.sh
grep -q 'raspi-utils' scripts/install_raspberry_pi.sh
grep -q 'libraspberrypi-bin' scripts/install_raspberry_pi.sh
grep -q 'vcgencmd is not available' scripts/install_raspberry_pi.sh
grep -q 'install -m 0755' scripts/install_raspberry_pi.sh
grep -q '"${HOME}/.local/bin/noaa-navionics-gui"' scripts/install_raspberry_pi.sh
grep -q 'sync_paths "$revision_file"' scripts/install_raspberry_pi.sh
grep -q 'noaa-navionics-chartplotter.desktop' scripts/install_raspberry_pi.sh
grep -q 'configure_desktop_autologin.sh' scripts/install_raspberry_pi.sh
grep -q 'systemctl --user enable noaa-navionics-track.service' scripts/install_raspberry_pi.sh
grep -q 'source-revision' scripts/verify_pi.sh
grep -q 'source revision matches' scripts/verify_pi.sh
grep -q 'expected_revision="${expected_revision}-dirty"' scripts/verify_pi.sh
grep -q 'check_status_report_json' scripts/verify_pi.sh
grep -q -- '--require-chartplotter-started' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_GPS_SECONDS' scripts/verify_pi.sh
grep -q 'check_chartplotter_log_after_boot' scripts/verify_pi.sh
grep -q 'wait_for_chartplotter_started' scripts/verify_pi.sh
grep -q 'chartplotter_start_timeout=120' scripts/verify_pi.sh
grep -q 'launcher failed to disable one or more display power settings' scripts/verify_pi.sh
grep -q 'OpenCPN running' scripts/verify_pi.sh
grep -q 'status report JSON ready' scripts/verify_pi.sh
grep -q 'status report source revision' scripts/verify_pi.sh
grep -q 'GPSD device matches config' scripts/verify_pi.sh
grep -q 'volatile; use /dev/serial/by-id/' scripts/verify_pi.sh
grep -q 'display power command' scripts/verify_pi.sh
grep -q 'Pi power command' scripts/verify_pi.sh
grep -q 'GPSD service enabled' scripts/verify_pi.sh
grep -q 'chartplotter autostart' scripts/verify_pi.sh
grep -q 'chartplotter autostart name' scripts/verify_pi.sh
grep -q 'Exec=sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"' scripts/verify_pi.sh
grep -q 'chartplotter launcher ENC parse' scripts/verify_pi.sh
grep -q 'chartplotter launcher readiness gate' scripts/verify_pi.sh
grep -q 'chartplotter launcher GPS wait persisted' scripts/verify_pi.sh
grep -q 'chartplotter launcher display failure logging' scripts/verify_pi.sh
grep -q 'chartplotter autostart terminal' scripts/verify_pi.sh
grep -q 'graphical boot target' scripts/verify_pi.sh
grep -q 'LightDM autologin user' scripts/verify_pi.sh
grep -q 'chart service sync command' scripts/verify_pi.sh
grep -q 'track service rotate daily' scripts/verify_pi.sh
grep -q 'track service start limit burst' scripts/verify_pi.sh
grep -q 'preflight service status report' scripts/verify_pi.sh
grep -q 'preflight service GPS wait config' scripts/verify_pi.sh
grep -q 'GPSD immediate polling' scripts/verify_pi.sh
grep -q 'Exec=sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"' templates/noaa-navionics-chartplotter.desktop
grep -q 'autologin-user=' scripts/configure_desktop_autologin.sh
grep -q 'systemctl set-default graphical.target' scripts/configure_desktop_autologin.sh
grep -q 'systemctl enable lightdm.service' scripts/configure_desktop_autologin.sh
grep -q 'sync_path "$autologin_conf"' scripts/configure_desktop_autologin.sh
grep -q 'GPS device must be an absolute /dev path' scripts/configure_gpsd.sh
grep -q 'GPS device path is volatile' scripts/configure_gpsd.sh
grep -q 'GPS device path is not a recognized stable path' scripts/configure_gpsd.sh
grep -q 'sync_path /etc/default/gpsd' scripts/configure_gpsd.sh
grep -q 'sync_path "$backup"' scripts/configure_gpsd.sh
grep -q 'tempfile.NamedTemporaryFile' scripts/configure_gpsd.sh
grep -q 'os.replace(tmp_path, config_path)' scripts/configure_gpsd.sh
grep -q 'status_attempts=3' scripts/verify_pi.sh
grep -q 'no fresh navigation-quality GPSD fix' src/noaa_navionics/health.py
grep -q 'no fresh navigation-quality NMEA fix' src/noaa_navionics/health.py
grep -q 'weak GPS fix' src/noaa_navionics/gps.py
grep -q 'pending_without_quality' src/noaa_navionics/health.py
grep -q 'def gps_fix_has_quality_fields' src/noaa_navionics/gps.py
grep -q 'manifest recorded' src/noaa_navionics/health.py
grep -q 'manifest extract path is outside chart directory' src/noaa_navionics/health.py
grep -q 'does not match configured' src/noaa_navionics/health.py
grep -q 'manifest download path is outside chart directory' src/noaa_navionics/health.py
grep -q 'manifest SHA-256 does not match' src/noaa_navionics/health.py
grep -q 'Track Disk' src/noaa_navionics/health.py
grep -q 'Display Power' src/noaa_navionics/health.py
grep -q 'def _is_raspberry_pi' src/noaa_navionics/health.py
grep -q 'def _volatile_usb_device_path' src/noaa_navionics/health.py
grep -q 'not a recognized stable GPS path' src/noaa_navionics/health.py
grep -q 'x11-xserver-utils' src/noaa_navionics/health.py
grep -q 'track_output=app_config.track_output' src/noaa_navionics/report.py
grep -q 'extracted ZIP contains no ENC .000 cells' src/noaa_navionics/downloader.py
grep -q 'chart update already in progress' src/noaa_navionics/downloader.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/downloader.py
grep -q 'os.fsync(handle.fileno())' src/noaa_navionics/downloader.py
grep -q 'def _fsync_directory' src/noaa_navionics/downloader.py
grep -q 'def _fsync_tree' src/noaa_navionics/downloader.py
grep -q 'self.path.open("x", encoding="utf-8")' src/noaa_navionics/gps.py
grep -q 'os.fsync(self.file.fileno())' src/noaa_navionics/gps.py
grep -q 'day_carry' src/noaa_navionics/gps.py
grep -q 'signal.SIGTERM' src/noaa_navionics/cli.py
grep -q 'Skipping weak track fix' src/noaa_navionics/cli.py
grep -q 'pending_without_quality' src/noaa_navionics/cli.py
grep -q 'gps_fix_quality_failure' src/noaa_navionics/cli.py
grep -q 'gps_fix_has_quality_fields' src/noaa_navionics/cli.py
grep -q 'logger = GPXTrackLogger(output)' src/noaa_navionics/cli.py
grep -q 'charts.package must be one of' src/noaa_navionics/config.py
grep -q '/dev/serial/by-id/YOUR_GPS_DEVICE' src/noaa_navionics/config.py
grep -q '/dev/serial/by-id/YOUR_GPS_DEVICE' examples/noaa-navionics.ini
grep -q 'gps.gpsd_host must be a hostname or IP address' src/noaa_navionics/config.py
grep -q 'gps.mode must be either gpsd or serial' src/noaa_navionics/config.py
grep -q 'def parse_gpsd_sky' src/noaa_navionics/gps.py
grep -q 'uSat' src/noaa_navionics/gps.py
grep -q 'used' src/noaa_navionics/gps.py
grep -q 'sky_max_age_seconds' src/noaa_navionics/gps.py
grep -q 'def _positive_float' src/noaa_navionics/cli.py
grep -q 'def _non_negative_int' src/noaa_navionics/cli.py
grep -q 'def _non_negative_float' src/noaa_navionics/cli.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/config.py
grep -q 'def _write_text_atomic' src/noaa_navionics/config.py
grep -q 'GPSD skipped: gps.mode' src/noaa_navionics/cli.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/opencpn.py
grep -q 'def _write_text_atomic' src/noaa_navionics/opencpn.py
grep -q 'def _write_backup' src/noaa_navionics/opencpn.py
grep -q 'if active == "failed"' src/noaa_navionics/report.py
grep -q 'GPSD Service' src/noaa_navionics/report.py
grep -q 'def _unit_query_failed' src/noaa_navionics/report.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/report.py
grep -q 'def _fsync_directory' src/noaa_navionics/report.py
grep -q 'TimeoutStartSec=2h' systemd/noaa-navionics.service
grep -q 'RestartSec=30min' systemd/noaa-navionics.service
grep -q 'StartLimitBurst=60' systemd/noaa-navionics-track.service
grep -q -- '--retries "$sync_retries" --retry-delay "$sync_retry_delay"' scripts/provision_sailboat_pi.sh
grep -q 'NOAA_NAVIONICS_GPS_SECONDS=%s' scripts/provision_sailboat_pi.sh
grep -q 'configure_desktop_autologin.sh' scripts/provision_sailboat_pi.sh
grep -q 'run sync_paths "$chart_service" "$chart_timer" "$track_service" "$preflight_service"' scripts/provision_sailboat_pi.sh
grep -q 'systemctl --user enable --now noaa-navionics-track.service' scripts/provision_sailboat_pi.sh
grep -q 'must be a positive integer' scripts/provision_sailboat_pi.sh
grep -q 'must be a non-negative integer' scripts/deploy_to_pi.sh
grep -q 'must be a positive integer' scripts/dock_test_pi.sh
grep -q -- '--require-chartplotter-started' scripts/dock_test_pi.sh

install_output="$(mktemp)"
provision_output="$(mktemp)"
gpsd_output="$(mktemp)"
deploy_output="$(mktemp)"
dock_output="$(mktemp)"
verify_output="$(mktemp)"
trap 'rm -rf "${tmpdir:-}" "$install_output" "$provision_output" "$gpsd_output" "$deploy_output" "$dock_output" "$verify_output"' EXIT

set +e
scripts/verify_pi.sh --bad-option pi@example.invalid >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject unknown options with exit 2" >&2
  exit 1
fi

set +e
scripts/configure_desktop_autologin.sh --allow-non-pi --user "bad user" >"$install_output" 2>&1
desktop_code=$?
set -e
if [[ "$desktop_code" -ne 2 ]]; then
  cat "$install_output" >&2
  echo "expected configure_desktop_autologin.sh to reject unsafe username with exit 2" >&2
  exit 1
fi

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
scripts/provision_sailboat_pi.sh --allow-non-pi --dry-run --skip-gpsd --gps-seconds nope >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject invalid --gps-seconds with exit 2" >&2
  exit 1
fi

set +e
scripts/deploy_to_pi.sh pi@example.invalid --provision --sync-retries 0 >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject invalid --sync-retries with exit 2" >&2
  exit 1
fi

set +e
scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --timeout nope >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject invalid --timeout with exit 2" >&2
  exit 1
fi

set +e
scripts/verify_pi.sh --gps-seconds nope pi@example.invalid >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject invalid --gps-seconds with exit 2" >&2
  exit 1
fi

set +e
scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --gps-seconds nope >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject invalid --gps-seconds with exit 2" >&2
  exit 1
fi

set +e
scripts/configure_gpsd.sh --allow-non-pi --dry-run --device >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject missing --device value with exit 2" >&2
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

set +e
scripts/configure_gpsd.sh --allow-non-pi --dry-run --no-device-check --device /dev/ttyUSB0 >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject volatile GPS device paths with exit 2" >&2
  exit 1
fi

set +e
scripts/configure_gpsd.sh --allow-non-pi --dry-run --no-device-check --device /dev/ttyAMA0 >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject unrecognized GPS device paths with exit 2" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --device /dev/serial/by-id/mock-gps \
  --skip-autologin \
  --config "$tmpdir/config.ini" \
  --gps-seconds 17 \
  --sync-retries 7 \
  --sync-retry-delay 15 >"$provision_output"
grep -q 'NOAA_NAVIONICS_GPS_SECONDS=17' "$provision_output"

launcher_home="$tmpdir/launcher-home"
mkdir -p "$launcher_home/.local/bin" "$launcher_home/.cache/noaa-navionics" "$launcher_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=17\n' >"$launcher_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nprintf "noaa-navionics %%s\\n" "$*" >>"$HOME/.cache/noaa-navionics/noaa.log"\nexit 0\n' >"$launcher_home/.local/bin/noaa-navionics"
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
grep -q -- '--gps-seconds 17' "$launcher_home/.cache/noaa-navionics/noaa.log"

launcher_fail_home="$tmpdir/launcher-fail-home"
mkdir -p "$launcher_fail_home/.local/bin" "$launcher_fail_home/.cache/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_fail_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/xset"
chmod +x "$launcher_fail_home/.local/bin/noaa-navionics" "$tmpdir/xset"
HOME="$launcher_fail_home" DISPLAY=:99 PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
grep -q 'Display session found, but 3 xset command(s) failed' "$launcher_fail_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_fail_home/.cache/noaa-navionics/chartplotter.log"

echo "All checks passed."
