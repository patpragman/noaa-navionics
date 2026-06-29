#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 -m py_compile src/noaa_navionics/*.py
python3 -m py_compile setup.py
python3 -m unittest discover -s tests -v

bash -n \
  scripts/install_raspberry_pi.sh \
  scripts/deploy_to_pi.sh \
  scripts/verify_pi.sh \
  scripts/start_chartplotter.sh \
  scripts/configure_desktop_autologin.sh \
  scripts/configure_gpsd.sh \
  scripts/configure_gps_time.sh \
  scripts/provision_sailboat_pi.sh \
  scripts/dock_test_pi.sh \
  scripts/check.sh

grep -q 'unterminated Python heredoc' scripts/check.sh

python3 - <<'PY'
from pathlib import Path
import re

scripts = [
    Path("scripts/deploy_to_pi.sh"),
    Path("scripts/install_raspberry_pi.sh"),
    Path("scripts/verify_pi.sh"),
    Path("scripts/start_chartplotter.sh"),
    Path("scripts/configure_gpsd.sh"),
    Path("scripts/configure_gps_time.sh"),
    Path("scripts/provision_sailboat_pi.sh"),
]
for path in scripts:
    lines = path.read_text(encoding="utf-8").splitlines()
    index = 0
    terminator = re.compile(r'^PY"?$')
    while index < len(lines):
        line = lines[index]
        if not re.search(r"<<\s*'PY'\s*$", line):
            index += 1
            continue
        start = index + 1
        block = []
        index += 1
        while index < len(lines) and not terminator.fullmatch(lines[index]):
            block.append(lines[index])
            index += 1
        if index >= len(lines):
            raise SystemExit(f"{path}:{start}: unterminated Python heredoc")
        source = "\n".join(block) + "\n"
        compile(source, f"{path}:heredoc:{start + 1}", "exec")
        index += 1
PY

grep -q 'status-report' systemd/noaa-navionics-preflight.service
grep -q 'status.json' systemd/noaa-navionics-preflight.service
grep -q 'EnvironmentFile=-%h/.config/noaa-navionics/launcher.env' systemd/noaa-navionics-preflight.service
grep -q -- '--gps-seconds ${NOAA_NAVIONICS_GPS_SECONDS}' systemd/noaa-navionics-preflight.service
grep -q 'TimeoutStartSec=0' systemd/noaa-navionics-preflight.service
grep -q 'chartplotter.log' scripts/start_chartplotter.sh
grep -q 'chartplotter.launch.lock' scripts/start_chartplotter.sh
grep -q 'acquire_launcher_lock' scripts/start_chartplotter.sh
grep -q 'release_launcher_lock' scripts/start_chartplotter.sh
grep -q 'process_looks_like_launcher' scripts/start_chartplotter.sh
grep -q 'is not a chartplotter launcher; treating lock as stale' scripts/start_chartplotter.sh
grep -q 'rm -rf "$launcher_lock_dir"' scripts/start_chartplotter.sh
grep -Fq 'sync_paths "${launcher_lock_dir}/pid" "$launcher_lock_dir"' scripts/start_chartplotter.sh
grep -Fq 'sync_paths "$launcher_lock_dir"' scripts/start_chartplotter.sh
grep -q 'max_log_bytes' scripts/start_chartplotter.sh
grep -q 'sync_paths "${log_file}.1"' scripts/start_chartplotter.sh
grep -q 'keep_display_awake' scripts/start_chartplotter.sh
grep -q 'opencpn_running' scripts/start_chartplotter.sh
grep -q 'pgrep -u "$(id -u)" -x opencpn' scripts/start_chartplotter.sh
grep -q 'OpenCPN is already running' scripts/start_chartplotter.sh
grep -q 'OpenCPN exited with status' scripts/start_chartplotter.sh
grep -q 'show_preflight_warning' scripts/start_chartplotter.sh
grep -q 'NOAA_NAVIONICS_WARNING_SECONDS' scripts/start_chartplotter.sh
grep -q 'import tkinter as tk' scripts/start_chartplotter.sh
grep -q 'import json' scripts/start_chartplotter.sh
grep -q 'Failed checks' scripts/start_chartplotter.sh
grep -q 'Readiness warning displayed' scripts/start_chartplotter.sh
grep -q 'xset s noblank' scripts/start_chartplotter.sh
grep -q 'xset command(s) failed' scripts/start_chartplotter.sh
grep -q 'launcher.env' scripts/start_chartplotter.sh
grep -q -- '--gps-seconds "$gps_seconds"' scripts/start_chartplotter.sh
grep -q '.source-revision' scripts/deploy_to_pi.sh
grep -q 'write_remote_source_revision' scripts/deploy_to_pi.sh
grep -q 'require_local_command ssh' scripts/deploy_to_pi.sh
grep -q 'local_command_exists rsync' scripts/deploy_to_pi.sh
grep -q 'remote_command_exists rsync' scripts/deploy_to_pi.sh
grep -q 'require_remote_command_available python3' scripts/deploy_to_pi.sh
grep -q 'require_remote_command_available tar' scripts/deploy_to_pi.sh
grep -q 'deploy_with_rsync' scripts/deploy_to_pi.sh
grep -q 'deploy_with_tar' scripts/deploy_to_pi.sh
grep -q 'prepare_remote_deploy_staging' scripts/deploy_to_pi.sh
grep -q 'promote_remote_deploy_staging' scripts/deploy_to_pi.sh
grep -q '"${target}:${remote_staging_dir}/"' scripts/deploy_to_pi.sh
grep -q 'promote_remote_deploy_staging "$remote_dir" "$remote_staging_dir" "$remote_previous_dir"' scripts/deploy_to_pi.sh
grep -q 'remote_staging_dir="${remote_dir_trimmed}.deploying"' scripts/deploy_to_pi.sh
grep -q 'remote_previous_dir="${remote_dir_trimmed}.previous"' scripts/deploy_to_pi.sh
grep -q 'bootstrapping copy with tar over SSH' scripts/deploy_to_pi.sh
grep -q 'Refusing to stage unexpected deployment directory' scripts/deploy_to_pi.sh
grep -q 'Deployment staging directory is not ready' scripts/deploy_to_pi.sh
grep -q 'Refusing to promote deployment staging outside deployment parent' scripts/deploy_to_pi.sh
grep -q 'previous.rename(repo)' scripts/deploy_to_pi.sh
grep -q -- "--exclude='./.git'" scripts/deploy_to_pi.sh
grep -Fq -- "--exclude '*.egg-info/'" scripts/deploy_to_pi.sh
grep -Fq -- "--exclude '.venv/'" scripts/deploy_to_pi.sh
grep -Fq -- "--exclude='*.zip'" scripts/deploy_to_pi.sh
grep -Fq -- "--exclude='ENCProdCat_19115.xml'" scripts/deploy_to_pi.sh
grep -Fq -- "--exclude='*.egg-info'" scripts/deploy_to_pi.sh
grep -Fq -- "--exclude='*/.venv'" scripts/deploy_to_pi.sh
grep -q -- '-czf - .' scripts/deploy_to_pi.sh
grep -q 'Could not confirm required remote command on the Pi' scripts/deploy_to_pi.sh
grep -q 'require_local_command ssh' scripts/dock_test_pi.sh
grep -q 'require_local_command ssh' scripts/verify_pi.sh
grep -Fq 'ssh -T "$target"' scripts/verify_pi.sh
grep -Fq 'ssh -T "$target" "cd ${remote_dir_quoted} && scripts/install_raspberry_pi.sh ${remote_install_args[*]}"' scripts/deploy_to_pi.sh
grep -Fq 'ssh -T "$target" "cd ${remote_dir_quoted} && scripts/provision_sailboat_pi.sh ${remote_args[*]}"' scripts/deploy_to_pi.sh
! grep -Fq 'ssh -t "$target"' scripts/deploy_to_pi.sh
grep -q 'tempfile.NamedTemporaryFile' scripts/deploy_to_pi.sh
grep -q 'os.replace(tmp_path, target)' scripts/deploy_to_pi.sh
grep -q 'os.fsync(handle.fileno())' scripts/deploy_to_pi.sh
grep -q -- '--allow-dirty' scripts/deploy_to_pi.sh
grep -q -- '--allow-dirty' scripts/dock_test_pi.sh
grep -q -- '--gps-seconds' scripts/dock_test_pi.sh
grep -q 'validate_remote_dir' scripts/deploy_to_pi.sh
grep -q 'quote_remote_dir_for_shell' scripts/deploy_to_pi.sh
grep -Fq 'printf '\''~/%s'\''' scripts/deploy_to_pi.sh
grep -q 'validate_remote_dir' scripts/dock_test_pi.sh
grep -q 'validate_ssh_target' scripts/deploy_to_pi.sh
grep -q 'validate_ssh_target' scripts/dock_test_pi.sh
grep -q 'validate_ssh_target' scripts/verify_pi.sh
grep -q 'SSH target must not begin with' scripts/deploy_to_pi.sh
grep -q 'SSH target must be user@host' scripts/verify_pi.sh
grep -q 'plain user@host without paths or ports' scripts/deploy_to_pi.sh
grep -q 'plain user@host without paths or ports' scripts/dock_test_pi.sh
grep -q 'plain user@host without paths or ports' scripts/verify_pi.sh
grep -q 'Remote deployment directory must be a dedicated noaa-navionics directory' scripts/deploy_to_pi.sh
grep -q 'Remote deployment directory must end in noaa-navionics' scripts/deploy_to_pi.sh
grep -q -- '--skip-gps-time' scripts/deploy_to_pi.sh
grep -q -- '--skip-gps-time' scripts/dock_test_pi.sh
grep -q 'install_args+=("--no-services")' scripts/deploy_to_pi.sh
grep -q 'install_args+=("$1")' scripts/deploy_to_pi.sh
grep -q -- '--skip-services requires --skip-autologin' scripts/deploy_to_pi.sh
grep -Fq 'scripts/install_raspberry_pi.sh ${remote_install_args[*]}' scripts/deploy_to_pi.sh
grep -q 'dirty worktree' scripts/deploy_to_pi.sh
grep -q 'source-revision' scripts/install_raspberry_pi.sh
grep -q 'write_source_revision' scripts/install_raspberry_pi.sh
grep -q 'tempfile.NamedTemporaryFile' scripts/install_raspberry_pi.sh
grep -q 'os.replace(tmp_path, target)' scripts/install_raspberry_pi.sh
grep -q 'VERSION_CODENAME' scripts/install_raspberry_pi.sh
grep -q 'DEBIAN_FRONTEND=noninteractive apt-get' scripts/install_raspberry_pi.sh
! grep -Eq 'sudo apt( |$)' scripts/install_raspberry_pi.sh
grep -q 'reset_private_venv' scripts/install_raspberry_pi.sh
grep -q 'sync_tree "$venv_dir"' scripts/install_raspberry_pi.sh
grep -q 'cannot sync missing tree' scripts/install_raspberry_pi.sh
grep -q 'file_path.is_symlink()' scripts/install_raspberry_pi.sh
grep -q 'refusing to remove unexpected venv path' scripts/install_raspberry_pi.sh
grep -q 'refusing to remove venv outside data directory' scripts/install_raspberry_pi.sh
grep -q 'refusing to remove non-directory private venv path' scripts/install_raspberry_pi.sh
grep -q 'shutil.rmtree(venv)' scripts/install_raspberry_pi.sh
grep -q 'ensure_vcgencmd' scripts/install_raspberry_pi.sh
grep -q 'raspi-utils' scripts/install_raspberry_pi.sh
grep -q 'libraspberrypi-bin' scripts/install_raspberry_pi.sh
grep -q 'python3 python3-venv python3-tk rsync opencpn' scripts/install_raspberry_pi.sh
grep -q 'python3-setuptools' scripts/install_raspberry_pi.sh
grep -q -- '--no-build-isolation' scripts/install_raspberry_pi.sh
grep -q -- '--no-use-pep517' scripts/install_raspberry_pi.sh
grep -q 'gpsd-clients chrony lightdm x11-xserver-utils' scripts/install_raspberry_pi.sh
grep -q 'console_scripts' setup.py
grep -q 'noaa-navionics=noaa_navionics.cli:main' setup.py
grep -q 'noaa-navionics-gui=noaa_navionics.gui:main' setup.py
! grep -q '^build-backend' pyproject.toml
grep -q 'vcgencmd is not available' scripts/install_raspberry_pi.sh
grep -q 'install -m 0755' scripts/install_raspberry_pi.sh
grep -q '"${HOME}/.local/bin/noaa-navionics-gui"' scripts/install_raspberry_pi.sh
grep -q 'sync_paths "$revision_file"' scripts/install_raspberry_pi.sh
grep -q 'Do not run the Raspberry Pi installer as root' scripts/install_raspberry_pi.sh
! grep -q 'noaa-navionics-chartplotter.desktop' scripts/install_raspberry_pi.sh
grep -q 'configure_desktop_autologin.sh' scripts/install_raspberry_pi.sh
! grep -q '"${repo_root}/scripts/configure_desktop_autologin.sh" --user' scripts/install_raspberry_pi.sh
grep -q 'noaa-navionics-configure-gps-time' scripts/install_raspberry_pi.sh
! grep -q 'systemctl --user enable noaa-navionics.timer' scripts/install_raspberry_pi.sh
! grep -q 'systemctl --user enable --now noaa-navionics.timer' scripts/install_raspberry_pi.sh
! grep -q 'systemctl --user enable noaa-navionics-track.service' scripts/install_raspberry_pi.sh
! grep -q 'systemctl --user daemon-reload' scripts/install_raspberry_pi.sh
! grep -q 'loginctl enable-linger' scripts/install_raspberry_pi.sh
grep -q 'User systemd unit files were installed but not enabled' scripts/install_raspberry_pi.sh
grep -q 'Desktop autologin and chartplotter autostart are also configured by provisioning' scripts/install_raspberry_pi.sh
! grep -q -- '--no-services requires --skip-autologin' scripts/install_raspberry_pi.sh
grep -q 'source-revision' scripts/verify_pi.sh
grep -q 'source revision matches' scripts/verify_pi.sh
grep -q 'expected_revision="${expected_revision}-dirty"' scripts/verify_pi.sh
grep -q 'check_status_report_json' scripts/verify_pi.sh
grep -q -- '--require-chartplotter-started' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_GPS_SECONDS' scripts/verify_pi.sh
grep -q 'Do not verify root@' scripts/verify_pi.sh
grep -q 'verification user is not root' scripts/verify_pi.sh
grep -q 'check_chartplotter_log_after_boot' scripts/verify_pi.sh
grep -q 'wait_for_chartplotter_started' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock clear' scripts/verify_pi.sh
grep -q 'opencpn_stability_seconds=10' scripts/verify_pi.sh
grep -q 'OpenCPN stable after startup' scripts/verify_pi.sh
grep -q 'wait_for_chrony_gps_source' scripts/verify_pi.sh
grep -q 'check_recent_track_log' scripts/verify_pi.sh
grep -q 'recent GPX trackpoint' scripts/verify_pi.sh
grep -q 'max_trackpoint_age = 600.0' scripts/verify_pi.sh
grep -q 'newest GPX trackpoint is stale' scripts/verify_pi.sh
grep -q 'timestamped trackpoint' scripts/verify_pi.sh
grep -q 'tracking.output' scripts/verify_pi.sh
grep -q '<trkpt\\b' scripts/verify_pi.sh
grep -q 'chartplotter_start_timeout=120' scripts/verify_pi.sh
grep -q 'launcher failed to disable one or more display power settings' scripts/verify_pi.sh
grep -q 'launcher log shows OpenCPN exited after current-boot startup' scripts/verify_pi.sh
grep -q 'launcher log does not contain OpenCPN launch or duplicate marker' scripts/verify_pi.sh
grep -q 'pgrep -u "$(id -u)" -x opencpn' scripts/verify_pi.sh
grep -q 'OpenCPN running' scripts/verify_pi.sh
grep -q 'status report JSON ready' scripts/verify_pi.sh
grep -q 'boot status report JSON ready' scripts/verify_pi.sh
grep -q 'status report boot ID' scripts/verify_pi.sh
grep -q 'status report source revision' scripts/verify_pi.sh
grep -q 'status report config path' scripts/verify_pi.sh
grep -q 'status report config values do not match current config' scripts/verify_pi.sh
grep -q '"min_free_gb": float' scripts/verify_pi.sh
grep -q 'require_track_disk_check' scripts/verify_pi.sh
grep -q 'required_checks.add("Track Disk")' scripts/verify_pi.sh
grep -q 'status report manifest path' scripts/verify_pi.sh
grep -q 'status report manifest does not exist' scripts/verify_pi.sh
grep -q 'status report manifest missing' scripts/verify_pi.sh
grep -q 'status report manifest missing created_at_source' scripts/verify_pi.sh
grep -q 'status report manifest created_at_source' scripts/verify_pi.sh
grep -q 'status report manifest download_skipped' scripts/verify_pi.sh
grep -q 'status report manifest created_at ' scripts/verify_pi.sh
grep -q 'does not match manifest file bytes' scripts/verify_pi.sh
grep -q 'does not match manifest file enc_cell_count' scripts/verify_pi.sh
grep -q 'manifest_field_pairs' scripts/verify_pi.sh
grep -q 'expected_package_filename' scripts/verify_pi.sh
grep -q 'expected_package_url' scripts/verify_pi.sh
grep -q 'status report manifest package filename' scripts/verify_pi.sh
grep -q 'status report manifest package URL' scripts/verify_pi.sh
grep -q 'status report manifest download URL' scripts/verify_pi.sh
grep -q 'status report manifest download path' scripts/verify_pi.sh
grep -q 'def parse_manifest_int' scripts/verify_pi.sh
grep -q 'status report manifest {field} is invalid in {source}' scripts/verify_pi.sh
grep -q '"download_bytes"' scripts/verify_pi.sh
grep -q '"download bytes"' scripts/verify_pi.sh
grep -q 'status report manifest download byte count is not positive' scripts/verify_pi.sh
grep -q 'status report manifest extract path' scripts/verify_pi.sh
grep -q '"ENC cell count"' scripts/verify_pi.sh
grep -q 'status report manifest has no ENC cells' scripts/verify_pi.sh
grep -q 'def config_bool' scripts/verify_pi.sh
grep -q 'status report missing readiness checks' scripts/verify_pi.sh
grep -q '"Source Revision"' scripts/verify_pi.sh
grep -q '"Time Sync"' scripts/verify_pi.sh
grep -q '"Display Power"' scripts/verify_pi.sh
grep -q '"Chart Package"' scripts/verify_pi.sh
grep -q '"Chart Update Debris"' scripts/verify_pi.sh
grep -q '"Pi Power"' scripts/verify_pi.sh
grep -q '"Pi Thermal"' scripts/verify_pi.sh
grep -q '"GPSD Config"' scripts/verify_pi.sh
grep -q 'status report missing service checks' scripts/verify_pi.sh
grep -q '"Chart Sync Settings"' scripts/verify_pi.sh
grep -q '"Chart Timer Settings"' scripts/verify_pi.sh
grep -q '"Chart Timer Install"' scripts/verify_pi.sh
grep -q '"Track Logger Settings"' scripts/verify_pi.sh
grep -q '"Track Logger Install"' scripts/verify_pi.sh
grep -q '"Boot Readiness Settings"' scripts/verify_pi.sh
grep -q '"Boot Readiness Run"' scripts/verify_pi.sh
grep -q '"Boot Readiness Install"' scripts/verify_pi.sh
grep -q 'GPSD device matches config' scripts/verify_pi.sh
grep -q 'volatile; use /dev/serial/by-id/' scripts/verify_pi.sh
grep -q 'display power command' scripts/verify_pi.sh
grep -q 'Pi power command' scripts/verify_pi.sh
grep -q 'GPSD service enabled' scripts/verify_pi.sh
grep -q 'GPSD service active' scripts/verify_pi.sh
grep -q 'Chrony service enabled' scripts/verify_pi.sh
grep -q 'Chrony GPSD time source' scripts/verify_pi.sh
grep -q 'Chrony usable GPS source' scripts/verify_pi.sh
grep -q 'chartplotter autostart' scripts/verify_pi.sh
grep -q 'chartplotter autostart name' scripts/verify_pi.sh
grep -q 'Exec=sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"' scripts/verify_pi.sh
grep -q 'chartplotter launcher ENC parse' scripts/verify_pi.sh
grep -q 'chartplotter launcher readiness gate' scripts/verify_pi.sh
grep -q 'chartplotter launcher readiness warning' scripts/verify_pi.sh
grep -q 'launcher reported failed readiness before OpenCPN startup' scripts/verify_pi.sh
grep -q 'chartplotter launcher duplicate guard' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock sync create' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock sync cleanup' scripts/verify_pi.sh
grep -q 'chartplotter launcher stale lock recovery' scripts/verify_pi.sh
grep -q 'chartplotter launcher GPS wait persisted' scripts/verify_pi.sh
grep -q 'chartplotter launcher display failure logging' scripts/verify_pi.sh
grep -q 'chartplotter autostart terminal' scripts/verify_pi.sh
grep -q 'chartplotter autostart not disabled' scripts/verify_pi.sh
grep -q 'graphical boot target' scripts/verify_pi.sh
grep -q 'LightDM autologin user' scripts/verify_pi.sh
grep -q 'LightDM autologin X11 session' scripts/verify_pi.sh
grep -q '/usr/share/xsessions' scripts/verify_pi.sh
grep -q 'chart service sync command' scripts/verify_pi.sh
grep -q 'chart service loaded sync command' scripts/verify_pi.sh
grep -q 'chart service loaded timeout' scripts/verify_pi.sh
grep -q 'chart service loaded restart' scripts/verify_pi.sh
grep -q 'chart service loaded restart delay' scripts/verify_pi.sh
grep -q 'chart service loaded start limit interval' scripts/verify_pi.sh
grep -q 'chart service loaded start limit burst' scripts/verify_pi.sh
grep -q 'chart timer loaded weekly' scripts/verify_pi.sh
grep -q 'chart timer loaded persistent' scripts/verify_pi.sh
grep -q 'chart timer loaded randomized delay' scripts/verify_pi.sh
grep -q 'chart timer install target' scripts/verify_pi.sh
grep -q 'check_unit_install_target' scripts/verify_pi.sh
grep -q 'section == "Install"' scripts/verify_pi.sh
grep -q 'track service rotate daily' scripts/verify_pi.sh
grep -q 'track service loaded rotate daily' scripts/verify_pi.sh
grep -q 'track service quiet stdout' scripts/verify_pi.sh
grep -q 'track service loaded quiet stdout' scripts/verify_pi.sh
grep -q 'track service loaded restart' scripts/verify_pi.sh
grep -q 'track service loaded restart delay' scripts/verify_pi.sh
grep -q 'track service start limit burst' scripts/verify_pi.sh
grep -q 'track service loaded start limit interval' scripts/verify_pi.sh
grep -q 'track service loaded start limit burst' scripts/verify_pi.sh
grep -q 'track service install target' scripts/verify_pi.sh
grep -q 'track service active' scripts/verify_pi.sh
grep -q 'preflight service status report' scripts/verify_pi.sh
grep -q 'preflight service GPS wait config' scripts/verify_pi.sh
grep -q 'preflight service loaded GPS wait default' scripts/verify_pi.sh
grep -q 'preflight service loaded restart' scripts/verify_pi.sh
grep -q 'preflight service loaded GPS wait config' scripts/verify_pi.sh
grep -q 'preflight service loaded status report' scripts/verify_pi.sh
grep -q 'preflight service loaded timeout' scripts/verify_pi.sh
grep -q 'preflight service loaded restart delay' scripts/verify_pi.sh
grep -q 'preflight service loaded start limit interval' scripts/verify_pi.sh
grep -q 'preflight service loaded start limit burst' scripts/verify_pi.sh
grep -q 'preflight service install target' scripts/verify_pi.sh
grep -q 'preflight service last success' scripts/verify_pi.sh
grep -q 'ExecMainStartTimestampMonotonic' scripts/verify_pi.sh
grep -q 'GPSD immediate polling' scripts/verify_pi.sh
grep -q 'GPSD single device' scripts/verify_pi.sh
grep -q 'GPSD device is not directory' scripts/verify_pi.sh
grep -q 'GPSD device is character device' scripts/verify_pi.sh
grep -Fq 'suffix="${1#/dev/serial/by-id/}"' scripts/verify_pi.sh
grep -Fq '"$suffix" != */*' scripts/verify_pi.sh
grep -q 'def check_gpsd_startup_config' src/noaa_navionics/health.py
grep -q 'START_DAEMON is not true' src/noaa_navionics/health.py
grep -q 'USBAUTO is not false' src/noaa_navionics/health.py
grep -q 'must contain exactly' src/noaa_navionics/health.py
grep -q 'Exec=sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"' templates/noaa-navionics-chartplotter.desktop
grep -q 'autologin-user=' scripts/configure_desktop_autologin.sh
grep -q 'autologin-session=' scripts/configure_desktop_autologin.sh
grep -q 'choose_xsession' scripts/configure_desktop_autologin.sh
grep -q '/usr/share/xsessions' scripts/configure_desktop_autologin.sh
grep -q 'No LightDM X11 sessions are installed' scripts/configure_desktop_autologin.sh
grep -q 'Refusing to configure graphical autologin for root' scripts/configure_desktop_autologin.sh
grep -q 'systemctl set-default graphical.target' scripts/configure_desktop_autologin.sh
grep -q 'systemctl enable lightdm.service' scripts/configure_desktop_autologin.sh
grep -q 'sync_path "$autologin_conf"' scripts/configure_desktop_autologin.sh
grep -q 'pwd.getpwnam' scripts/configure_desktop_autologin.sh
grep -q 'Autologin user home does not exist' scripts/configure_desktop_autologin.sh
grep -q 'Autologin user does not own home directory' scripts/configure_desktop_autologin.sh
grep -q 'GPS device must be an absolute /dev path' scripts/configure_gpsd.sh
grep -q 'GPS device path is volatile' scripts/configure_gpsd.sh
grep -q 'GPS device path is not a recognized stable path' scripts/configure_gpsd.sh
grep -q 'Do not configure GPSD as root' scripts/configure_gpsd.sh
grep -q 'GPS device path is a directory' scripts/configure_gpsd.sh
grep -q 'GPS device path is not a character device' scripts/configure_gpsd.sh
grep -Fq 'suffix="${1#/dev/serial/by-id/}"' scripts/configure_gpsd.sh
grep -Fq '"$suffix" != */*' scripts/configure_gpsd.sh
grep -Fq '"$suffix" =~ ^[A-Za-z0-9._:+@-]+$' scripts/configure_gpsd.sh
grep -q 'sync_path /etc/default/gpsd' scripts/configure_gpsd.sh
grep -q 'sync_path "$backup"' scripts/configure_gpsd.sh
grep -q 'tempfile.NamedTemporaryFile' scripts/configure_gpsd.sh
grep -q 'os.replace(tmp_path, config_path)' scripts/configure_gpsd.sh
grep -q 'validate_existing_gps_config' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_system_service' scripts/provision_sailboat_pi.sh
grep -q 'Existing config is required when --skip-gpsd is used with unattended startup' scripts/provision_sailboat_pi.sh
grep -q 'gps.device must name the already configured GPS receiver when --skip-gpsd is used' scripts/provision_sailboat_pi.sh
grep -q 'gps.gpsd_host must be local when --skip-gpsd is used' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_system_service gpsd.service GPSD --skip-gpsd' scripts/provision_sailboat_pi.sh
grep -Fq 'suffix not in {".", ".."}' scripts/provision_sailboat_pi.sh
grep -q 'safe_by_id_chars' scripts/provision_sailboat_pi.sh
grep -q 'GPS device path is not a character device' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_gps_time_config' scripts/provision_sailboat_pi.sh
grep -q 'Existing chrony GPS time config is required when --skip-gps-time is used with unattended startup' scripts/provision_sailboat_pi.sh
grep -q 'chrony config must already contain the NOAA Navionics GPSD SHM 0 time source when --skip-gps-time is used' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_system_service chrony.service chrony --skip-gps-time' scripts/provision_sailboat_pi.sh
grep -q 'not line.lstrip().startswith("#")' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_charts' scripts/provision_sailboat_pi.sh
grep -q 'Existing chart config is required when --skip-sync is used with unattended startup' scripts/provision_sailboat_pi.sh
grep -q 'existing complete charts are required when --skip-sync is used with unattended startup' scripts/provision_sailboat_pi.sh
grep -q 'check_chart_manifest' scripts/provision_sailboat_pi.sh
grep -q -- '--no-device-check cannot be used while unattended startup is enabled' scripts/provision_sailboat_pi.sh
grep -q 'pass both --skip-services and --skip-autologin for manual testing' scripts/provision_sailboat_pi.sh
grep -q 'refclock SHM 0 offset 0.5 delay 0.1 refid GPS' scripts/configure_gps_time.sh
grep -q 'sudo systemctl restart gpsd' scripts/configure_gps_time.sh
grep -q 'Do not configure GPS time as root' scripts/configure_gps_time.sh
grep -q 'Refusing to write a non-standard chrony config path' scripts/configure_gps_time.sh
grep -q 'sync_path "$chrony_conf"' scripts/configure_gps_time.sh
grep -q 'status_attempts=3' scripts/verify_pi.sh
grep -q 'Time Sync' src/noaa_navionics/health.py
grep -q 'Source Revision' src/noaa_navionics/health.py
grep -q 'NOAA_NAVIONICS_SOURCE_REVISION_PATH' src/noaa_navionics/health.py
grep -q 'deployed source revision is not recorded' src/noaa_navionics/health.py
grep -q 'SystemClockSynchronized' src/noaa_navionics/health.py
grep -q 'GPS Time Source' src/noaa_navionics/health.py
grep -q 'check_chrony_gps_time_source(seconds=gps_seconds)' src/noaa_navionics/health.py
grep -q 'chronyc.*sources.*-n' src/noaa_navionics/health.py
grep -Fq 'line[1] in "*+"' src/noaa_navionics/health.py
grep -Fq '^#[*+].*GPS' scripts/verify_pi.sh
grep -q 'chart directory does not exist' src/noaa_navionics/health.py
grep -q 'no fresh navigation-quality GPSD fix' src/noaa_navionics/health.py
grep -q 'no fresh navigation-quality NMEA fix' src/noaa_navionics/health.py
grep -q 'cannot verify freshness' src/noaa_navionics/health.py
grep -q 'weak GPS fix' src/noaa_navionics/gps.py
grep -q 'non-finite coordinates' src/noaa_navionics/gps.py
grep -q 'outside -90..90' src/noaa_navionics/gps.py
grep -q 'outside -180..180' src/noaa_navionics/gps.py
grep -q 'invalid GPS fix: 0.000000, 0.000000 coordinates' src/noaa_navionics/gps.py
grep -q 'pending_without_quality' src/noaa_navionics/health.py
grep -q 'def gps_fix_has_quality_fields' src/noaa_navionics/gps.py
grep -q 'manifest recorded' src/noaa_navionics/health.py
grep -q 'unverified-cache' src/noaa_navionics/health.py
grep -q 'manifest extract path is outside chart directory' src/noaa_navionics/health.py
grep -q 'unexpected ENC chart directories' src/noaa_navionics/health.py
grep -q 'manifest package URL' src/noaa_navionics/health.py
grep -q 'manifest download URL' src/noaa_navionics/health.py
grep -q 'manifest does not record a download URL' src/noaa_navionics/health.py
grep -q 'does not match configured' src/noaa_navionics/health.py
grep -q 'manifest download path is outside chart directory' src/noaa_navionics/health.py
grep -q 'positive download byte count' src/noaa_navionics/health.py
grep -q 'download SHA-256' src/noaa_navionics/health.py
grep -q 'manifest SHA-256 does not match' src/noaa_navionics/health.py
grep -q 'create or mount the configured storage path' src/noaa_navionics/health.py
grep -q 'REMOVABLE_STORAGE_ROOTS' src/noaa_navionics/health.py
grep -q 'no mounted storage device' src/noaa_navionics/health.py
grep -q 'os.path.ismount' src/noaa_navionics/health.py
grep -q 'Chart Update Debris' src/noaa_navionics/health.py
grep -q 'endswith(".part")' src/noaa_navionics/health.py
grep -q 'def _manifest_archive_path' src/noaa_navionics/health.py
grep -q 'suffix.lower() == ".zip"' src/noaa_navionics/health.py
grep -q 'Track Disk' src/noaa_navionics/health.py
grep -q 'Display Power' src/noaa_navionics/health.py
grep -q 'def _is_raspberry_pi' src/noaa_navionics/health.py
grep -q 'def _volatile_usb_device_path' src/noaa_navionics/health.py
grep -q 'is a directory, not a GPS device' src/noaa_navionics/health.py
grep -q 'is not a character device' src/noaa_navionics/health.py
grep -q 'not a recognized stable GPS path' src/noaa_navionics/health.py
grep -q 'x11-xserver-utils' src/noaa_navionics/health.py
grep -q 'track_output=app_config.track_output' src/noaa_navionics/report.py
grep -q '"extract": app_config.extract' src/noaa_navionics/report.py
grep -q '"keep_zip": app_config.keep_zip' src/noaa_navionics/report.py
grep -q '"force": app_config.force' src/noaa_navionics/report.py
grep -q 'boot_id' src/noaa_navionics/report.py
grep -q 'BOOT_ID_PATH' src/noaa_navionics/report.py
grep -q 'extracted ZIP contains no ENC .000 cells' src/noaa_navionics/downloader.py
grep -q 'chart update already in progress' src/noaa_navionics/downloader.py
grep -q 'boot_id=' src/noaa_navionics/downloader.py
grep -q 'partial download already exists; remove interrupted chart update debris' src/noaa_navionics/downloader.py
grep -q 'def _pid_is_running' src/noaa_navionics/downloader.py
grep -q 'def _current_boot_id' src/noaa_navionics/downloader.py
grep -q 'STATE_PACKAGES' src/noaa_navionics/downloader.py
grep -q 'COAST_GUARD_DISTRICT_PACKAGES' src/noaa_navionics/downloader.py
grep -q 'REGION_PACKAGES' src/noaa_navionics/downloader.py
grep -q 'if not keep_zip' src/noaa_navionics/downloader.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/downloader.py
grep -q 'os.fsync(handle.fileno())' src/noaa_navionics/downloader.py
grep -q 'def _fsync_directory' src/noaa_navionics/downloader.py
grep -q 'def _fsync_tree' src/noaa_navionics/downloader.py
grep -q 'self.path.open("x", encoding="utf-8")' src/noaa_navionics/gps.py
grep -q 'os.fsync(self.file.fileno())' src/noaa_navionics/gps.py
grep -q 'def _fsync_directory' src/noaa_navionics/gps.py
grep -q 'day_carry' src/noaa_navionics/gps.py
grep -q 'signal.SIGTERM' src/noaa_navionics/cli.py
grep -q 'Skipping weak track fix' src/noaa_navionics/cli.py
grep -q 'pending_without_quality' src/noaa_navionics/cli.py
grep -q 'gps_fix_quality_failure' src/noaa_navionics/cli.py
grep -q 'gps_fix_has_quality_fields' src/noaa_navionics/cli.py
grep -q 'Live GPS stream ended unexpectedly' src/noaa_navionics/cli.py
grep -q 'logger = GPXTrackLogger(output)' src/noaa_navionics/cli.py
grep -q 'def _fsync_directory' src/noaa_navionics/cli.py
grep -q '_fsync_directory(tracks_dir)' src/noaa_navionics/cli.py
grep -q 'charts.package must be one of' src/noaa_navionics/config.py
grep -q 'package can be: state, cgd, region, chart, all' src/noaa_navionics/config.py
grep -q 'package can be: state, cgd, region, chart, all' examples/noaa-navionics.ini
grep -q '/dev/serial/by-id/YOUR_GPS_DEVICE' src/noaa_navionics/config.py
grep -q '/dev/serial/by-id/YOUR_GPS_DEVICE' examples/noaa-navionics.ini
grep -q 'min_free_gb = 2.0' examples/noaa-navionics.ini
grep -q 'UNSAFE_STORAGE_NAMES' src/noaa_navionics/config.py
grep -q 'must be a dedicated storage directory' src/noaa_navionics/config.py
grep -q 'broad system or home directories' README.md
grep -q 'broad system or home directories' docs/sailboat-pi.md
grep -q 'charts.min_free_gb' src/noaa_navionics/config.py
grep -q 'def _get_float' src/noaa_navionics/config.py
grep -q 'def _validate_chart_package_value' src/noaa_navionics/config.py
grep -q 'gps.gpsd_host must be a hostname or IP address' src/noaa_navionics/config.py
grep -q 'gps.gpsd_host must be local for onboard gpsd mode' src/noaa_navionics/config.py
grep -q 'GPSD_LOCAL_HOSTS' src/noaa_navionics/config.py
grep -q 'gps.mode must be either gpsd or serial' src/noaa_navionics/config.py
grep -q 'gps.device is required when gps.mode is' src/noaa_navionics/config.py
grep -q 'STABLE_GPS_DEVICE_PATHS' src/noaa_navionics/config.py
grep -q 'def _stable_gps_device_path' src/noaa_navionics/config.py
grep -Fq 'suffix not in {".", ".."}' src/noaa_navionics/config.py
grep -Fq 'suffix not in {".", ".."}' src/noaa_navionics/health.py
grep -q 'volatile USB name' src/noaa_navionics/config.py
grep -q 'gps.device must be /dev/serial/by-id/' src/noaa_navionics/config.py
grep -q 'def parse_gpsd_sky' src/noaa_navionics/gps.py
grep -q 'uSat' src/noaa_navionics/gps.py
grep -q 'used' src/noaa_navionics/gps.py
grep -q 'sky_max_age_seconds' src/noaa_navionics/gps.py
grep -q 'max_duration' src/noaa_navionics/gps.py
grep -q 'sock.settimeout' src/noaa_navionics/gps.py
grep -q 'max_duration=seconds' src/noaa_navionics/health.py
grep -q 'max_duration=max_duration' src/noaa_navionics/cli.py
grep -q 'def _positive_float' src/noaa_navionics/cli.py
grep -q 'def _non_negative_int' src/noaa_navionics/cli.py
grep -q 'def _non_negative_float' src/noaa_navionics/cli.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/config.py
grep -q 'def _write_text_atomic' src/noaa_navionics/config.py
grep -q 'GPSD skipped: gps.mode' src/noaa_navionics/cli.py
grep -q 'sync-charts requires writable chart storage with enough free space' src/noaa_navionics/cli.py
grep -q 'gpsd_connect_retry=use_gpsd and deadline is None and not args.sample' src/noaa_navionics/cli.py
grep -q 'yielded_fix = True' src/noaa_navionics/cli.py
grep -q 'or yielded_fix' src/noaa_navionics/cli.py
grep -q 'GPSD unavailable at' src/noaa_navionics/cli.py
grep -q 'retrying in' src/noaa_navionics/cli.py
grep -q 'PACKAGE_KIND_OPTIONS = ("state", "cgd", "region", "chart", "all")' src/noaa_navionics/gui.py
grep -q 'values=PACKAGE_KIND_OPTIONS' src/noaa_navionics/gui.py
grep -q 'def run_configured_preflight' src/noaa_navionics/gui.py
grep -q 'def sync_configured_charts' src/noaa_navionics/gui.py
grep -q 'sync requires a complete onboard chart package' src/noaa_navionics/gui.py
grep -q 'sync requires writable chart storage with enough free space' src/noaa_navionics/gui.py
grep -q 'gpsd_host=app_config.gpsd_host' src/noaa_navionics/gui.py
grep -q 'max_chart_age_days=app_config.max_chart_age_days' src/noaa_navionics/gui.py
grep -q 'min_free_gb=app_config.min_free_gb' src/noaa_navionics/gui.py
grep -q 'track_output=app_config.track_output' src/noaa_navionics/gui.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/opencpn.py
grep -q 'def _write_text_atomic' src/noaa_navionics/opencpn.py
grep -q 'def _write_backup' src/noaa_navionics/opencpn.py
grep -q 'def _available_backup_path' src/noaa_navionics/opencpn.py
grep -q 'backup_path.open("xb")' src/noaa_navionics/opencpn.py
grep -q 'if active == "failed"' src/noaa_navionics/report.py
grep -q 'Chart Sync Settings' src/noaa_navionics/report.py
grep -q 'Chart Timer Settings' src/noaa_navionics/report.py
grep -q 'Chart Timer Install' src/noaa_navionics/report.py
grep -q 'RandomizedDelayUSec.*30min' src/noaa_navionics/report.py
grep -q 'Track Logger Settings' src/noaa_navionics/report.py
grep -q 'Track Logger Install' src/noaa_navionics/report.py
grep -q 'Boot Readiness Settings' src/noaa_navionics/report.py
grep -q 'Boot Readiness Run' src/noaa_navionics/report.py
grep -q 'Boot Readiness Install' src/noaa_navionics/report.py
grep -q 'ExecMainStartTimestampMonotonic' src/noaa_navionics/report.py
grep -q 'USER_UNIT_INSTALL_TARGETS' src/noaa_navionics/report.py
grep -q 'def _install_wanted_by_targets' src/noaa_navionics/report.py
grep -q 'section != "Install"' src/noaa_navionics/report.py
grep -q 'wanted_by' src/noaa_navionics/report.py
grep -q 'sync-charts requires a complete onboard chart package' src/noaa_navionics/cli.py
grep -q 'noaa-navionics sync-charts' src/noaa_navionics/report.py
grep -q 'noaa-navionics log-track' src/noaa_navionics/report.py
grep -q 'noaa-navionics status-report' src/noaa_navionics/report.py
grep -q '"Type": "oneshot"' src/noaa_navionics/report.py
grep -q '"Type": "simple"' src/noaa_navionics/report.py
grep -q '"Restart": "on-failure"' src/noaa_navionics/report.py
grep -q 'GPSD Service' src/noaa_navionics/report.py
grep -q 'Chrony Service' src/noaa_navionics/report.py
grep -q 'def _unit_query_failed' src/noaa_navionics/report.py
grep -q 'def _systemctl_user_show' src/noaa_navionics/report.py
grep -q 'loaded settings match expected values' src/noaa_navionics/report.py
grep -q 'chart manifest freshness decides navigation readiness' src/noaa_navionics/report.py
grep -q '"package_filename"' src/noaa_navionics/report.py
grep -q '"download_bytes"' src/noaa_navionics/report.py
grep -q '"min_free_gb": app_config.min_free_gb' src/noaa_navionics/report.py
grep -q '"extract_path": extract.get("path", "")' src/noaa_navionics/report.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/report.py
grep -q 'def _fsync_directory' src/noaa_navionics/report.py
grep -q 'TimeoutStartSec=2h' systemd/noaa-navionics.service
grep -q 'RandomizedDelaySec=30min' systemd/noaa-navionics.timer
grep -q 'Type=oneshot' systemd/noaa-navionics.service
grep -q 'Type=oneshot' systemd/noaa-navionics-preflight.service
grep -q 'NoNewPrivileges=true' systemd/noaa-navionics.service
grep -q 'PrivateTmp=true' systemd/noaa-navionics-track.service
grep -q 'NoNewPrivileges.*yes' src/noaa_navionics/report.py
grep -q 'PrivateTmp.*yes' src/noaa_navionics/report.py
grep -q 'loaded no new privileges' scripts/verify_pi.sh
grep -q 'loaded private tmp' scripts/verify_pi.sh
grep -q 'TimeoutStartUSec.*infinity' src/noaa_navionics/report.py
grep -q 'StartLimitIntervalSec=30min' systemd/noaa-navionics-preflight.service
grep -q 'StartLimitIntervalUSec.*30min' src/noaa_navionics/report.py
grep -q 'StartLimitBurst=60' systemd/noaa-navionics-preflight.service
grep -q 'Type=simple' systemd/noaa-navionics-track.service
grep -q 'chart service loaded type' scripts/verify_pi.sh
grep -q 'track service loaded type' scripts/verify_pi.sh
grep -q 'preflight service loaded type' scripts/verify_pi.sh
grep -q 'RestartSec=30min' systemd/noaa-navionics.service
grep -q 'StandardOutput=null' systemd/noaa-navionics-track.service
grep -q 'StartLimitBurst=60' systemd/noaa-navionics-track.service
grep -q -- '--retries "$sync_retries" --retry-delay "$sync_retry_delay"' scripts/provision_sailboat_pi.sh
grep -q 'NOAA_NAVIONICS_GPS_SECONDS=%s' scripts/provision_sailboat_pi.sh
grep -q 'mktemp "${launcher_env_dir}/launcher.env.XXXXXX"' scripts/provision_sailboat_pi.sh
grep -q 'sync_paths "$launcher_env_tmp"' scripts/provision_sailboat_pi.sh
grep -q 'mv -f "$launcher_env_tmp" "$launcher_env"' scripts/provision_sailboat_pi.sh
grep -q 'Custom --config path does not match the unattended onboard config' scripts/provision_sailboat_pi.sh
grep -q 'Do not run sailboat Pi provisioning as root' scripts/provision_sailboat_pi.sh
grep -q 'pass both --skip-services and --skip-autologin' scripts/provision_sailboat_pi.sh
grep -q -- '--skip-services requires --skip-autologin' scripts/provision_sailboat_pi.sh
grep -q 'configure_gps_time.sh' scripts/provision_sailboat_pi.sh
grep -q -- '--skip-gps-time' scripts/provision_sailboat_pi.sh
grep -q 'configure_desktop_autologin.sh' scripts/provision_sailboat_pi.sh
grep -q 'noaa-navionics-chartplotter.desktop' scripts/provision_sailboat_pi.sh
grep -q 'run sync_paths "$autostart_entry"' scripts/provision_sailboat_pi.sh
grep -q 'run sync_paths "$chart_service" "$chart_timer" "$track_service" "$preflight_service"' scripts/provision_sailboat_pi.sh
grep -q 'sudo loginctl enable-linger "$USER"' scripts/provision_sailboat_pi.sh
grep -q 'systemctl --user reset-failed noaa-navionics-track.service noaa-navionics-preflight.service' scripts/provision_sailboat_pi.sh
grep -q 'systemctl --user enable --now noaa-navionics-track.service' scripts/provision_sailboat_pi.sh
grep -q 'systemctl --user enable --now noaa-navionics.timer' scripts/provision_sailboat_pi.sh
grep -q 'systemctl --user restart noaa-navionics-track.service' scripts/provision_sailboat_pi.sh
grep -q 'systemctl --user enable noaa-navionics-preflight.service' scripts/provision_sailboat_pi.sh
grep -q 'systemctl --user restart noaa-navionics-preflight.service' scripts/provision_sailboat_pi.sh
grep -q 'must be a positive integer' scripts/provision_sailboat_pi.sh
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/provision_sailboat_pi.sh").read_text(encoding="utf-8")
status_index = text.index('run "$bin" status-report')
autologin_index = text.index('configure_desktop_autologin.sh" "${desktop_args[@]}"')
if autologin_index < status_index:
    raise SystemExit("desktop autologin must be configured after final status-report succeeds")
PY
grep -q 'must be a non-negative integer' scripts/deploy_to_pi.sh
grep -q 'Do not deploy to root@' scripts/deploy_to_pi.sh
grep -q 'must be a positive integer' scripts/dock_test_pi.sh
grep -q 'Do not run the dock test as root@' scripts/dock_test_pi.sh
grep -q -- '--require-chartplotter-started' scripts/dock_test_pi.sh
grep -q 'request_reboot' scripts/dock_test_pi.sh
grep -q 'sudo -n reboot' scripts/dock_test_pi.sh
grep -q 'Failed to request reboot with passwordless sudo' scripts/dock_test_pi.sh
grep -q 'remote_boot_id' scripts/dock_test_pi.sh
grep -q 'boot ID changed after reboot' scripts/dock_test_pi.sh
grep -q 'Pre-reboot verification passed; reboot and chartplotter autostart proof were skipped' scripts/dock_test_pi.sh
grep -q -- '--skip-autologin cannot be used for the rebooted dock acceptance test' scripts/dock_test_pi.sh

install_output="$(mktemp)"
provision_output="$(mktemp)"
gpsd_output="$(mktemp)"
deploy_output="$(mktemp)"
dock_output="$(mktemp)"
verify_output="$(mktemp)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir:-}" "$install_output" "$provision_output" "$gpsd_output" "$deploy_output" "$dock_output" "$verify_output"' EXIT

install_smoke_home="$tmpdir/install-smoke-home"
mkdir -p "$install_smoke_home"
HOME="$install_smoke_home" scripts/install_raspberry_pi.sh --skip-apt --allow-non-pi >"$install_output"
test -x "$install_smoke_home/.local/bin/noaa-navionics"
"$install_smoke_home/.local/bin/noaa-navionics" list-packages >/dev/null
test -f "$install_smoke_home/.config/noaa-navionics/config.ini"
test -d "$install_smoke_home/.local/share/noaa-navionics/venv"

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
scripts/verify_pi.sh root@example.invalid >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject root SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'Do not verify root@' "$verify_output"

set +e
scripts/verify_pi.sh -oProxyCommand=bad >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject option-like SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'SSH target must not begin with' "$verify_output"

set +e
scripts/verify_pi.sh raspberrypi.local >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to require user@host SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'SSH target must be user@host' "$verify_output"

set +e
scripts/verify_pi.sh pi@example.invalid:repo >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject scp-style SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'plain user@host without paths or ports' "$verify_output"

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
scripts/configure_desktop_autologin.sh --allow-non-pi --dry-run --user root >"$install_output" 2>&1
desktop_code=$?
set -e
if [[ "$desktop_code" -ne 2 ]]; then
  cat "$install_output" >&2
  echo "expected configure_desktop_autologin.sh to reject root autologin with exit 2" >&2
  exit 1
fi
grep -q 'Refusing to configure graphical autologin for root' "$install_output"

scripts/configure_desktop_autologin.sh --allow-non-pi --dry-run --user "$USER" --session LXDE-pi >"$install_output"
grep -q 'autologin-session=LXDE-pi' "$install_output"
grep -q 'Configured graphical autologin for' "$install_output"
grep -q 'using X11 session LXDE-pi' "$install_output"

set +e
scripts/install_raspberry_pi.sh --bad-option >"$install_output" 2>&1
install_code=$?
set -e
if [[ "$install_code" -ne 2 ]]; then
  cat "$install_output" >&2
  echo "expected install_raspberry_pi.sh to reject unknown options with exit 2" >&2
  exit 1
fi
grep -q 'Unknown argument: --bad-option' "$install_output"

set +e
scripts/deploy_to_pi.sh root@example.invalid --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject root SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'Do not deploy to root@' "$deploy_output"

set +e
scripts/deploy_to_pi.sh -oProxyCommand=bad --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject option-like SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'SSH target must not begin with' "$deploy_output"

set +e
scripts/deploy_to_pi.sh raspberrypi.local --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to require user@host SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'SSH target must be user@host' "$deploy_output"

set +e
scripts/deploy_to_pi.sh pi@example.invalid:repo --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject scp-style SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'plain user@host without paths or ports' "$deploy_output"

set +e
scripts/deploy_to_pi.sh pi@example.invalid / --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject dangerous remote directories with exit 2" >&2
  exit 1
fi
grep -q 'Remote deployment directory must be a dedicated noaa-navionics directory' "$deploy_output"

set +e
scripts/deploy_to_pi.sh pi@example.invalid ~/bad-target --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to require a noaa-navionics remote directory with exit 2" >&2
  exit 1
fi
grep -q 'Remote deployment directory must end in noaa-navionics' "$deploy_output"

set +e
scripts/dock_test_pi.sh root@example.invalid --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject root SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'Do not run the dock test as root@' "$dock_output"

set +e
scripts/dock_test_pi.sh -oProxyCommand=bad --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject option-like SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'SSH target must not begin with' "$dock_output"

set +e
scripts/dock_test_pi.sh raspberrypi.local --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to require user@host SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'SSH target must be user@host' "$dock_output"

set +e
scripts/dock_test_pi.sh pi@example.invalid:repo --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject scp-style SSH targets with exit 2" >&2
  exit 1
fi
grep -q 'plain user@host without paths or ports' "$dock_output"

set +e
scripts/dock_test_pi.sh pi@example.invalid / --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject dangerous remote directories with exit 2" >&2
  exit 1
fi
grep -q 'Remote deployment directory must be a dedicated noaa-navionics directory' "$dock_output"

set +e
scripts/deploy_to_pi.sh pi@example.invalid --provision --skip-services >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject --skip-services without --skip-autologin with exit 2" >&2
  exit 1
fi
grep -q -- '--skip-services requires --skip-autologin' "$deploy_output"

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
scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --skip-gpsd \
  --skip-sync \
  --config /tmp/noaa-navionics-custom.ini >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject custom --config for unattended provisioning with exit 2" >&2
  exit 1
fi
grep -q 'Custom --config path does not match the unattended onboard config' "$provision_output"

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
scripts/dock_test_pi.sh pi@example.invalid --device /dev/serial/by-id/mock-gps --skip-autologin >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject --skip-autologin for rebooted dock test with exit 2" >&2
  exit 1
fi
grep -q -- '--skip-autologin cannot be used for the rebooted dock acceptance test' "$dock_output"

set +e
scripts/configure_gps_time.sh --allow-non-pi --dry-run --chrony-conf relative.conf >"$gpsd_output" 2>&1
gps_time_code=$?
set -e
if [[ "$gps_time_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gps_time.sh to reject relative chrony config path with exit 2" >&2
  exit 1
fi

set +e
scripts/configure_gps_time.sh --allow-non-pi --chrony-conf /etc/passwd >"$gpsd_output" 2>&1
gps_time_code=$?
set -e
if [[ "$gps_time_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gps_time.sh to reject non-standard chrony config paths with exit 2" >&2
  exit 1
fi
grep -q 'Refusing to write a non-standard chrony config path' "$gpsd_output"

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

set +e
scripts/configure_gpsd.sh --allow-non-pi --dry-run --no-device-check --device /dev/serial/by-id/ >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject bare GPS by-id directory paths with exit 2" >&2
  exit 1
fi

set +e
scripts/configure_gpsd.sh --allow-non-pi --dry-run --no-device-check --device /dev/serial/by-id/../ttyS0 >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject nested GPS by-id parent paths with exit 2" >&2
  exit 1
fi

set +e
scripts/configure_gpsd.sh --allow-non-pi --dry-run --no-device-check --device /dev/serial/by-id/mock/extra >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject nested GPS by-id paths with exit 2" >&2
  exit 1
fi

set +e
scripts/configure_gpsd.sh --allow-non-pi --dry-run --no-device-check --device '/dev/serial/by-id/$(id)' >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -ne 2 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject shell metacharacters in GPS by-id paths with exit 2" >&2
  exit 1
fi
grep -q 'GPS device path is not a recognized stable path' "$gpsd_output"

scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --device /dev/serial/by-id/mock-gps \
  --skip-autologin \
  --skip-services \
  --config "$tmpdir/config.ini" \
  --gps-seconds 17 \
  --sync-retries 7 \
  --sync-retry-delay 15 >"$provision_output"
grep -q 'NOAA_NAVIONICS_GPS_SECONDS=17' "$provision_output"
grep -q 'configure_gps_time.sh --allow-non-pi --dry-run' "$provision_output"

scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --skip-gpsd \
  --skip-sync \
  --skip-autologin \
  --skip-services \
  --config "$tmpdir/skip-gpsd-manual.ini" >"$provision_output"
grep -q 'configure_gps_time.sh --allow-non-pi --dry-run' "$provision_output"

set +e
scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --device /dev/serial/by-id/mock-gps \
  --skip-autologin >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject --no-device-check with unattended autostart enabled" >&2
  exit 1
fi
grep -q -- '--no-device-check cannot be used while unattended startup is enabled' "$provision_output"

skip_gpsd_home="$tmpdir/skip-gpsd-home"
mkdir -p "$skip_gpsd_home"
set +e
HOME="$skip_gpsd_home" scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --skip-gpsd \
  --skip-sync \
  --skip-autologin >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject --skip-gpsd without an existing unattended GPS config" >&2
  exit 1
fi
grep -q 'Existing config is required when --skip-gpsd is used with unattended startup' "$provision_output"

skip_gps_time_home="$tmpdir/skip-gps-time-home"
mkdir -p "$skip_gps_time_home/.local/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$skip_gps_time_home/.local/bin/noaa-navionics"
chmod +x "$skip_gps_time_home/.local/bin/noaa-navionics"
set +e
HOME="$skip_gps_time_home" scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --device /dev/serial/by-id/mock-gps \
  --skip-gps-time \
  --skip-sync \
  --skip-autologin >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject --skip-gps-time without an existing chrony GPS time config" >&2
  exit 1
fi
grep -Eq 'Existing chrony GPS time config is required|chrony config must already contain the NOAA Navionics GPSD SHM 0 time source' "$provision_output"

skip_sync_home="$tmpdir/skip-sync-home"
mkdir -p "$skip_sync_home/.local/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$skip_sync_home/.local/bin/noaa-navionics"
chmod +x "$skip_sync_home/.local/bin/noaa-navionics"
set +e
HOME="$skip_sync_home" scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --device /dev/serial/by-id/mock-gps \
  --skip-sync \
  --skip-autologin >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject --skip-sync without existing complete charts" >&2
  exit 1
fi
grep -q 'Existing chart config is required when --skip-sync is used with unattended startup' "$provision_output"

scripts/configure_gps_time.sh --allow-non-pi --dry-run --chrony-conf "$tmpdir/chrony.conf" >"$gpsd_output"
grep -q 'refclock SHM 0 offset 0.5 delay 0.1 refid GPS' "$gpsd_output"
grep -q 'Would restart chrony and GPSD' "$gpsd_output"

launcher_home="$tmpdir/launcher-home"
mkdir -p "$launcher_home/.local/bin" "$launcher_home/.cache/noaa-navionics" "$launcher_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=17\n' >"$launcher_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nprintf "noaa-navionics %%s\\n" "$*" >>"$HOME/.cache/noaa-navionics/noaa.log"\nexit 0\n' >"$launcher_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\necho fake opencpn\n' >"$tmpdir/opencpn"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\nprintf "xset %%s\\n" "$*" >>"$HOME/.cache/noaa-navionics/xset.log"\n' >"$tmpdir/xset"
chmod +x "$launcher_home/.local/bin/noaa-navionics" "$tmpdir/opencpn" "$tmpdir/pgrep" "$tmpdir/xset"
head -c 1048577 /dev/zero >"$launcher_home/.cache/noaa-navionics/chartplotter.log"
HOME="$launcher_home" DISPLAY=:99 PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
test -f "$launcher_home/.cache/noaa-navionics/chartplotter.log.1"
test -f "$launcher_home/.cache/noaa-navionics/chartplotter.log"
test "$(wc -c <"$launcher_home/.cache/noaa-navionics/chartplotter.log.1")" -eq 1048577
test ! -e "$launcher_home/.cache/noaa-navionics/chartplotter.launch.lock"
grep -q 'xset s off' "$launcher_home/.cache/noaa-navionics/xset.log"
grep -q 'xset s noblank' "$launcher_home/.cache/noaa-navionics/xset.log"
grep -q 'xset -dpms' "$launcher_home/.cache/noaa-navionics/xset.log"
grep -q -- '--gps-seconds 17' "$launcher_home/.cache/noaa-navionics/noaa.log"

launcher_preflight_fail_home="$tmpdir/launcher-preflight-fail-home"
mkdir -p "$launcher_preflight_fail_home/.local/bin" "$launcher_preflight_fail_home/.cache/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$launcher_preflight_fail_home/.local/bin/noaa-navionics"
chmod +x "$launcher_preflight_fail_home/.local/bin/noaa-navionics"
HOME="$launcher_preflight_fail_home" NOAA_NAVIONICS_WARNING_SECONDS=0 PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
grep -q 'NOAA Navionics preflight failed' "$launcher_preflight_fail_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Readiness warning timeout is 0 seconds' "$launcher_preflight_fail_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_preflight_fail_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'OpenCPN exited with status 0' "$launcher_preflight_fail_home/.cache/noaa-navionics/chartplotter.log"

launcher_fail_home="$tmpdir/launcher-fail-home"
mkdir -p "$launcher_fail_home/.local/bin" "$launcher_fail_home/.cache/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_fail_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/xset"
chmod +x "$launcher_fail_home/.local/bin/noaa-navionics" "$tmpdir/xset"
HOME="$launcher_fail_home" DISPLAY=:99 PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
test ! -e "$launcher_fail_home/.cache/noaa-navionics/chartplotter.launch.lock"
grep -q 'Display session found, but 3 xset command(s) failed' "$launcher_fail_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_fail_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'OpenCPN exited with status 0' "$launcher_fail_home/.cache/noaa-navionics/chartplotter.log"

launcher_lock_home="$tmpdir/launcher-lock-home"
mkdir -p "$launcher_lock_home/.local/bin" "$launcher_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
printf '%s\n' "$$" >"$launcher_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_lock_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\necho fake opencpn\n' >"$tmpdir/opencpn"
chmod +x "$launcher_lock_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
HOME="$launcher_lock_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
test ! -e "$launcher_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
grep -q 'is not a chartplotter launcher; treating lock as stale' "$launcher_lock_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Removing stale chartplotter launcher lock' "$launcher_lock_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_lock_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'OpenCPN exited with status 0' "$launcher_lock_home/.cache/noaa-navionics/chartplotter.log"

launcher_dirty_lock_home="$tmpdir/launcher-dirty-lock-home"
mkdir -p "$launcher_dirty_lock_home/.local/bin" "$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
printf '%s\n' "$$" >"$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
printf 'stale\n' >"$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/extra"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_dirty_lock_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\necho fake opencpn\n' >"$tmpdir/opencpn"
chmod +x "$launcher_dirty_lock_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
HOME="$launcher_dirty_lock_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
test ! -e "$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
grep -q 'Removing stale chartplotter launcher lock' "$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'OpenCPN exited with status 0' "$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.log"

launcher_active_lock_home="$tmpdir/launcher-active-lock-home"
mkdir -p "$launcher_active_lock_home/.local/bin" "$launcher_active_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
bash -c 'while :; do sleep 1; done' start_chartplotter.sh &
active_launcher_pid=$!
printf '%s\n' "$active_launcher_pid" >"$launcher_active_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_active_lock_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\necho "opencpn should not be launched" >&2\nexit 9\n' >"$tmpdir/opencpn"
chmod +x "$launcher_active_lock_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
HOME="$launcher_active_lock_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
kill "$active_launcher_pid" 2>/dev/null || true
wait "$active_launcher_pid" 2>/dev/null || true
grep -q 'Another NOAA Navionics chartplotter launcher is already running' "$launcher_active_lock_home/.cache/noaa-navionics/chartplotter.log"

launcher_duplicate_home="$tmpdir/launcher-duplicate-home"
mkdir -p "$launcher_duplicate_home/.local/bin" "$launcher_duplicate_home/.cache/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_duplicate_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\necho "opencpn should not be launched" >&2\nexit 9\n' >"$tmpdir/opencpn"
chmod +x "$launcher_duplicate_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
HOME="$launcher_duplicate_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
grep -q 'OpenCPN is already running' "$launcher_duplicate_home/.cache/noaa-navionics/chartplotter.log"

echo "All checks passed."
