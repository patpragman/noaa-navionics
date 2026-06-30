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
grep -q 'def _process_state_from_stat_text' src/noaa_navionics/opencpn.py
grep -q '_process_state_from_stat_text' tests/test_downloader.py
grep -q 'status.json' systemd/noaa-navionics-preflight.service
grep -q 'EnvironmentFile=-%h/.config/noaa-navionics/launcher.env' systemd/noaa-navionics-preflight.service
grep -q 'Environment=NOAA_NAVIONICS_GPS_SECONDS=60' systemd/noaa-navionics-preflight.service
grep -q -- '--gps-seconds ${NOAA_NAVIONICS_GPS_SECONDS}' systemd/noaa-navionics-preflight.service
grep -q 'TimeoutStartSec=0' systemd/noaa-navionics-preflight.service
grep -q 'chartplotter.log' scripts/start_chartplotter.sh
grep -q 'chartplotter.launch.lock' scripts/start_chartplotter.sh
grep -q 'umask 077' scripts/start_chartplotter.sh
grep -q 'prepare_private_cache_dir' scripts/start_chartplotter.sh
grep -q 'first_symlink_ancestor' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics cache parent directory is a symlink' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics cache path contains a symlink' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics cache parent directory is owned by uid' scripts/start_chartplotter.sh
grep -q 'Tightening NOAA Navionics cache parent directory permissions' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics cache directory is owned by uid' scripts/start_chartplotter.sh
grep -q 'chmod 0700 "$cache_dir"' scripts/start_chartplotter.sh
grep -q 'chmod 0600 "$log_file"' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher log is not a regular file' scripts/start_chartplotter.sh
grep -q 'chmod 0600 "${launcher_lock_dir}/pid"' scripts/start_chartplotter.sh
grep -q 'check_tkinter_available' scripts/verify_pi.sh
grep -q 'Tkinter readiness warning support' scripts/verify_pi.sh
grep -q 'python3-tk' scripts/install_raspberry_pi.sh
grep -q 'OpenCPN executable directory is owned by uid' scripts/start_chartplotter.sh
grep -q 'acquire_launcher_lock' scripts/start_chartplotter.sh
grep -q 'release_launcher_lock' scripts/start_chartplotter.sh
grep -q 'process_looks_like_launcher' scripts/start_chartplotter.sh
grep -q 'current_boot_id' scripts/start_chartplotter.sh
grep -q 'validate_launcher_lock_path' scripts/start_chartplotter.sh
grep -q 'launcher_lock_path_safe_for_cleanup' scripts/start_chartplotter.sh
grep -q 'chartplotter launcher lock path contains a symlink' scripts/start_chartplotter.sh
grep -q 'chartplotter launcher lock path became unsafe; leaving it in place' scripts/start_chartplotter.sh
grep -q 'validate_launcher_env_path' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment is missing' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment is a symlink' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment directory is a symlink' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment path contains a symlink' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment has permissions' scripts/start_chartplotter.sh
grep -q 'Missing NOAA_NAVIONICS_GPS_SECONDS' scripts/start_chartplotter.sh
grep -q 'Invalid NOAA_NAVIONICS_GPS_SECONDS=.*expected positive integer' scripts/start_chartplotter.sh
grep -q 'Invalid NOAA_NAVIONICS_READINESS_ATTEMPTS=.*expected positive integer' scripts/start_chartplotter.sh
grep -q 'Invalid NOAA_NAVIONICS_OPENCPN_RESTARTS=.*expected non-negative integer' scripts/start_chartplotter.sh
grep -q 'expected private 0600' scripts/start_chartplotter.sh
grep -q 'launcher_lock_from_current_boot' scripts/start_chartplotter.sh
grep -q 'Launcher lock is from a previous boot; treating lock as stale' scripts/start_chartplotter.sh
grep -q 'is not a chartplotter launcher; treating lock as stale' scripts/start_chartplotter.sh
grep -q 'remove_stale_launcher_lock' scripts/start_chartplotter.sh
grep -q 'shutil.rmtree(lock)' scripts/start_chartplotter.sh
grep -q 'shutil.rmtree is not symlink-attack resistant' scripts/start_chartplotter.sh
grep -q 'chartplotter launcher lock path contains a symlink; leaving it in place' scripts/start_chartplotter.sh
grep -q 'refuses symlinked, misowned, or group/world-writable stale lock debris' README.md
grep -q 'refuses symlinked, misowned, or group/world-writable stale lock debris' docs/sailboat-pi.md
! grep -q 'rm -rf "$launcher_lock_dir"' scripts/start_chartplotter.sh
grep -Fq 'sync_paths "${launcher_lock_dir}/pid" "${launcher_lock_dir}/boot_id" "$launcher_lock_dir"' scripts/start_chartplotter.sh
grep -q 'resolve_opencpn_binary' scripts/start_chartplotter.sh
grep -q 'validate_opencpn_binary_candidate' scripts/start_chartplotter.sh
grep -q 'is_raspberry_pi' scripts/start_chartplotter.sh
grep -q 'expected root on Raspberry Pi' scripts/start_chartplotter.sh
grep -q 'Using OpenCPN binary' scripts/start_chartplotter.sh
grep -q 'OpenCPN command integrity' scripts/verify_pi.sh
grep -q 'chartplotter launcher Pi OpenCPN root owner' scripts/verify_pi.sh
grep -q 'OpenCPN command is a symlink' src/noaa_navionics/health.py
grep -q 'expected root' src/noaa_navionics/health.py
grep -q 'test_check_opencpn_requires_root_owner_on_pi' tests/test_downloader.py
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/start_chartplotter.sh").read_text(encoding="utf-8")
opencpn_start = text.index('"$opencpn_bin" -parse_all_enc &')
tail = text[opencpn_start:]
wait_index = tail.index('wait "$opencpn_pid"')
release_index = tail.find("release_launcher_lock")
if release_index != -1 and release_index < wait_index:
    raise SystemExit("chartplotter launcher must keep its launch lock until OpenCPN exits")
PY
grep -q 'max_log_bytes' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics rotated launcher log is a symlink' scripts/start_chartplotter.sh
grep -q 'sync_paths "${log_file}.1"' scripts/start_chartplotter.sh
grep -q 'keep_display_awake' scripts/start_chartplotter.sh
grep -q 'opencpn_running' scripts/start_chartplotter.sh
grep -q 'opencpn_process_active' scripts/start_chartplotter.sh
grep -q 'pgrep -u "$(id -u)" -x opencpn' scripts/start_chartplotter.sh
grep -Fq 'state="${stat_line##*) }"' scripts/start_chartplotter.sh
grep -Fq '[[ -n "$state" && "$state" != "Z" ]]' scripts/start_chartplotter.sh
grep -q 'OpenCPN is already running' scripts/start_chartplotter.sh
grep -q 'OpenCPN exited with status' scripts/start_chartplotter.sh
grep -q 'show_preflight_warning' scripts/start_chartplotter.sh
grep -q 'NOAA_NAVIONICS_WARNING_SECONDS' scripts/start_chartplotter.sh
grep -q 'NOAA_NAVIONICS_READINESS_ATTEMPTS' scripts/start_chartplotter.sh
grep -q 'NOAA_NAVIONICS_START_ON_FAILED_READINESS' scripts/start_chartplotter.sh
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTARTS' scripts/start_chartplotter.sh
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTART_DELAY' scripts/start_chartplotter.sh
grep -q 'reexec_without_ambient_launcher_settings' scripts/start_chartplotter.sh
grep -q 'NOAA_NAVIONICS_\*)' scripts/start_chartplotter.sh
grep -Fq 'exec env "${env_args[@]}" "$0" "$@"' scripts/start_chartplotter.sh
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/start_chartplotter.sh").read_text(encoding="utf-8")
main_flow = text[text.index('reexec_without_ambient_launcher_settings "$@"'):]
reexec_index = main_flow.index('reexec_without_ambient_launcher_settings "$@"')
lock_index = main_flow.index('\nacquire_launcher_lock')
if reexec_index > lock_index:
    raise SystemExit("launcher must sanitize inherited NOAA_NAVIONICS_* environment before taking the launch lock")
for key in (
    "NOAA_NAVIONICS_GPS_SECONDS",
    "NOAA_NAVIONICS_WARNING_SECONDS",
    "NOAA_NAVIONICS_READINESS_ATTEMPTS",
    "NOAA_NAVIONICS_READINESS_RETRY_DELAY",
    "NOAA_NAVIONICS_OPENCPN_RESTARTS",
    "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY",
    "NOAA_NAVIONICS_START_ON_FAILED_READINESS",
):
    if f"${{{key}:-" in text:
        raise SystemExit(f"launcher must not apply ambient {key} overrides")
PY
grep -q 'Malformed launcher environment line' scripts/start_chartplotter.sh
grep -q 'Unknown launcher environment key' scripts/start_chartplotter.sh
grep -q 'run_opencpn_supervised' scripts/start_chartplotter.sh
grep -q 'Restarting OpenCPN after nonzero exit status' scripts/start_chartplotter.sh
grep -q 'OpenCPN exited cleanly; not restarting' scripts/start_chartplotter.sh
grep -q 'terminate_opencpn_child' scripts/start_chartplotter.sh
grep -q 'Forwarding launcher shutdown to OpenCPN child process' scripts/start_chartplotter.sh
grep -q 'trap shutdown_launcher INT TERM' scripts/start_chartplotter.sh
grep -q 'opencpn_child_pid="$opencpn_pid"' scripts/start_chartplotter.sh
grep -q 'while opencpn_process_active "$opencpn_pid"' scripts/start_chartplotter.sh
grep -q 'chartplotter launcher OpenCPN shutdown forwarding' scripts/verify_pi.sh
grep -q 'does not leave an unsupervised chartplotter process behind' README.md
grep -q 'does not leave an unsupervised chartplotter process behind' docs/sailboat-pi.md
grep -q 'import tkinter as tk' scripts/start_chartplotter.sh
grep -q 'import json' scripts/start_chartplotter.sh
grep -q 'def open_trusted_status_report' scripts/start_chartplotter.sh
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' scripts/start_chartplotter.sh
grep -q 'stat.S_ISREG(status.st_mode)' scripts/start_chartplotter.sh
grep -q 'status.st_uid != os.getuid()' scripts/start_chartplotter.sh
grep -q 'mode & 0o077' scripts/start_chartplotter.sh
grep -q 'os.fdopen(fd, encoding="utf-8")' scripts/start_chartplotter.sh
! grep -q 'with path.open(encoding="utf-8") as handle' scripts/start_chartplotter.sh
grep -q 'Failed checks' scripts/start_chartplotter.sh
grep -q 'button_text="Dismiss"' scripts/start_chartplotter.sh
grep -q 'button_text="Start OpenCPN"' scripts/start_chartplotter.sh
grep -q 'text=button_text' scripts/start_chartplotter.sh
grep -q 'Readiness warning displayed' scripts/start_chartplotter.sh
grep -q 'no-follow descriptor-confirmed private status file' README.md
grep -q 'no-follow descriptor-confirmed private status file' docs/sailboat-pi.md
grep -q 'Not starting OpenCPN automatically because readiness failed' scripts/start_chartplotter.sh
grep -q 'xset s noblank' scripts/start_chartplotter.sh
grep -q 'xset command(s) failed' scripts/start_chartplotter.sh
grep -q 'launcher.env' scripts/start_chartplotter.sh
grep -q -- '--gps-seconds "$gps_seconds"' scripts/start_chartplotter.sh
grep -q '.source-revision' scripts/deploy_to_pi.sh
grep -q 'write_remote_source_revision' scripts/deploy_to_pi.sh
grep -q 'Refusing source revision write because {label} has permissions' scripts/deploy_to_pi.sh
grep -q 'Refusing to replace symlink source revision file' scripts/deploy_to_pi.sh
grep -q 'Refusing source revision write under symlinked deployment path' scripts/deploy_to_pi.sh
grep -q 'Deployment directory is not ready for source revision write' scripts/deploy_to_pi.sh
grep -q 'os.chmod(staging, 0o755)' scripts/deploy_to_pi.sh
grep -q 'require_local_command ssh' scripts/deploy_to_pi.sh
grep -q 'require_local_command git' scripts/deploy_to_pi.sh
grep -q 'validate_trusted_local_command' scripts/deploy_to_pi.sh
grep -q 'validate_trusted_local_command "$command_name" "$command_path"' scripts/deploy_to_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS' scripts/deploy_to_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH' scripts/deploy_to_pi.sh
grep -q 'Local ${command_name} command is not in a trusted system directory' scripts/deploy_to_pi.sh
grep -q 'ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)' scripts/deploy_to_pi.sh
grep -q 'ssh_connect_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)' scripts/deploy_to_pi.sh
grep -q 'remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' scripts/deploy_to_pi.sh
grep -q '${remote_system_path} && export PATH && command -v ${command_name}' scripts/deploy_to_pi.sh
grep -q '${remote_system_path} && export PATH && NOAA_NAVIONICS_REMOTE_DIR=' scripts/deploy_to_pi.sh
grep -q -- '--rsync-path="${remote_system_path} rsync"' scripts/deploy_to_pi.sh
grep -q '${remote_system_path} && export PATH && tar -xzf - -C' scripts/deploy_to_pi.sh
grep -q 'rsync -az --delete -e "ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"' scripts/deploy_to_pi.sh
grep -q 'ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)' scripts/verify_pi.sh
grep -q 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' scripts/verify_pi.sh
grep -q 'export PATH' scripts/verify_pi.sh
grep -q 'ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)' scripts/dock_test_pi.sh
grep -q 'ssh_probe_options=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)' scripts/dock_test_pi.sh
grep -q 'remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' scripts/dock_test_pi.sh
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
grep -q 'pins remote deploy command lookup to trusted system directories' README.md
grep -q 'pins remote deploy command lookup to trusted system directories' docs/sailboat-pi.md
grep -q 'Refusing to stage unexpected deployment directory' scripts/deploy_to_pi.sh
grep -q 'Refusing deployment parent symlink' scripts/deploy_to_pi.sh
grep -q 'Refusing deployment path under symlink' scripts/deploy_to_pi.sh
grep -q 'expected no group/other write bits' scripts/deploy_to_pi.sh
grep -q 'Deployment staging directory is not ready' scripts/deploy_to_pi.sh
grep -q 'Refusing to promote deployment staging outside deployment parent' scripts/deploy_to_pi.sh
grep -q 'Restored previous deployment after interrupted promotion' scripts/deploy_to_pi.sh
grep -q 'Refusing to restore non-directory previous deployment path' scripts/deploy_to_pi.sh
grep -q 'previous.rename(repo)' scripts/deploy_to_pi.sh
grep -q 'Deployment cleanup requires Python shutil.rmtree with symlink-attack resistance' scripts/deploy_to_pi.sh
grep -q 'label = "stale deployment staging path" if sibling == staging else "previous deployment path"' scripts/deploy_to_pi.sh
grep -q 'remove_path(previous, label="previous deployment path")' scripts/deploy_to_pi.sh
grep -q 'not getattr(shutil.rmtree, "avoids_symlink_attacks", False)' scripts/deploy_to_pi.sh
grep -q 'deployment cleanup refuses Python runtimes without symlink-attack-resistant `shutil.rmtree`' README.md
grep -q 'deployment cleanup refuses Python runtimes without symlink-attack-resistant `shutil.rmtree`' docs/sailboat-pi.md
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/deploy_to_pi.sh").read_text(encoding="utf-8")
restore_index = text.index("Restored previous deployment after interrupted promotion")
cleanup_index = text.index("for sibling in (staging, previous):", restore_index)
if cleanup_index < restore_index:
    raise SystemExit("deploy staging cleanup must not run before interrupted promotion recovery")
promote_index = text.index('promote_remote_deploy_staging "$remote_dir" "$remote_staging_dir" "$remote_previous_dir"')
revision_index = text.index('write_remote_source_revision "$remote_dir" "$source_revision"')
if revision_index < promote_index:
    raise SystemExit("deploy source revision must be written only after staging promotion")
PY
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
grep -q 'require_local_command git' scripts/verify_pi.sh
grep -q 'validate_trusted_local_command' scripts/dock_test_pi.sh
grep -q 'validate_trusted_local_command' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS' scripts/dock_test_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH' scripts/dock_test_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH' scripts/verify_pi.sh
grep -Fq 'ssh -T "${ssh_batch_options[@]}" "$target"' scripts/verify_pi.sh
grep -Fq 'ssh -T "${ssh_batch_options[@]}" "$target" "cd ${remote_dir_quoted} && ${remote_system_path} && export PATH && scripts/install_raspberry_pi.sh ${remote_install_args[*]}"' scripts/deploy_to_pi.sh
grep -Fq 'ssh -T "${ssh_batch_options[@]}" "$target" "cd ${remote_dir_quoted} && ${remote_system_path} && export PATH && scripts/provision_sailboat_pi.sh ${remote_args[*]}"' scripts/deploy_to_pi.sh
! grep -Fq 'ssh -t "$target"' scripts/deploy_to_pi.sh
grep -q 'tempfile.NamedTemporaryFile' scripts/deploy_to_pi.sh
grep -q 'os.replace(tmp_path, target)' scripts/deploy_to_pi.sh
grep -q 'os.fsync(handle.fileno())' scripts/deploy_to_pi.sh
grep -q -- '--allow-dirty' scripts/deploy_to_pi.sh
grep -q -- '--allow-dirty' scripts/dock_test_pi.sh
grep -q -- '--allow-dirty' scripts/verify_pi.sh
grep -q 'Refusing to verify a dirty local worktree as production evidence' scripts/verify_pi.sh
grep -q 'verify_args+=("$1")' scripts/dock_test_pi.sh
grep -q 'trusted local deployment commands' README.md
grep -q 'trusted local deployment commands' docs/sailboat-pi.md
grep -q -- '--gps-seconds' scripts/dock_test_pi.sh
grep -q -- '--opencpn-restarts' scripts/provision_sailboat_pi.sh
grep -q -- '--opencpn-restart-delay' scripts/provision_sailboat_pi.sh
grep -q -- '--opencpn-restarts' scripts/deploy_to_pi.sh
grep -q -- '--opencpn-restart-delay' scripts/deploy_to_pi.sh
grep -q -- '--opencpn-restarts' scripts/verify_pi.sh
grep -q -- '--opencpn-restart-delay' scripts/verify_pi.sh
grep -q -- '--opencpn-restarts' scripts/dock_test_pi.sh
grep -q -- '--opencpn-restart-delay' scripts/dock_test_pi.sh
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTARTS=${opencpn_restarts_quoted}' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=${opencpn_restart_delay_quoted}' scripts/verify_pi.sh
grep -q 'verify_args+=("$1" "${2:-}")' scripts/dock_test_pi.sh
grep -q 'validate_remote_dir' scripts/deploy_to_pi.sh
grep -q 'quote_remote_dir_for_shell' scripts/deploy_to_pi.sh
grep -Fq 'printf '\''~/%s'\''' scripts/deploy_to_pi.sh
grep -q 'validate_remote_dir' scripts/dock_test_pi.sh
grep -q 'validate_ssh_target' scripts/deploy_to_pi.sh
grep -q 'validate_ssh_target' scripts/dock_test_pi.sh
grep -q 'validate_ssh_target' scripts/verify_pi.sh
grep -q 'validate_gps_device_path_arg' scripts/deploy_to_pi.sh
grep -q 'validate_gps_device_path_arg' scripts/dock_test_pi.sh
grep -q 'validate_gps_device_path_arg' scripts/verify_pi.sh
grep -q 'GPS device path is volatile' scripts/deploy_to_pi.sh
grep -q 'GPS device path is volatile' scripts/dock_test_pi.sh
grep -q 'GPS device path is volatile' scripts/verify_pi.sh
grep -q 'SSH target must not begin with' scripts/deploy_to_pi.sh
grep -q 'SSH target must be user@host' scripts/verify_pi.sh
grep -q 'plain user@host without paths or ports' scripts/deploy_to_pi.sh
grep -q 'plain user@host without paths or ports' scripts/dock_test_pi.sh
grep -q 'plain user@host without paths or ports' scripts/verify_pi.sh
grep -q 'Remote deployment directory must be a dedicated noaa-navionics directory' scripts/deploy_to_pi.sh
grep -q 'Remote deployment directory must end in noaa-navionics' scripts/deploy_to_pi.sh
grep -q 'Remote deployment directory must be under the Pi user' scripts/deploy_to_pi.sh
grep -q 'Remote deployment directory must be under the Pi user' scripts/dock_test_pi.sh
grep -q -- '--skip-gps-time' scripts/deploy_to_pi.sh
grep -q -- '--skip-gps-time' scripts/dock_test_pi.sh
grep -q 'install_args+=("--no-services")' scripts/deploy_to_pi.sh
grep -q 'install_args+=("$1")' scripts/deploy_to_pi.sh
grep -q -- '--skip-services requires --skip-autologin' scripts/deploy_to_pi.sh
grep -q -- '--skip-autologin requires --skip-services' scripts/deploy_to_pi.sh
grep -Fq 'scripts/install_raspberry_pi.sh ${remote_install_args[*]}' scripts/deploy_to_pi.sh
grep -q 'dirty worktree' scripts/deploy_to_pi.sh
grep -q 'source-revision' scripts/install_raspberry_pi.sh
grep -q 'write_source_revision' scripts/install_raspberry_pi.sh
grep -q 'tempfile.NamedTemporaryFile' scripts/install_raspberry_pi.sh
grep -q 'os.replace(tmp_path, target)' scripts/install_raspberry_pi.sh
grep -q 'VERSION_CODENAME' scripts/install_raspberry_pi.sh
grep -q 'install_root_text_atomic' scripts/install_raspberry_pi.sh
grep -q 'sudo python3 - "$target" "$mode" "$text"' scripts/install_raspberry_pi.sh
grep -q 'noaa-navionics-bookworm-backports.list' scripts/install_raspberry_pi.sh
grep -q 'root text target is a symlink' scripts/install_raspberry_pi.sh
grep -q 'root text target directory path contains a symlink' scripts/install_raspberry_pi.sh
grep -q 'root text target directory .* has permissions' scripts/install_raspberry_pi.sh
grep -q 'root text target .* is owned by uid' scripts/install_raspberry_pi.sh
! grep -q 'sudo tee -a /etc/apt/sources.list' scripts/install_raspberry_pi.sh
grep -q 'DEBIAN_FRONTEND=noninteractive apt-get' scripts/install_raspberry_pi.sh
! grep -Eq 'sudo apt( |$)' scripts/install_raspberry_pi.sh
grep -q 'umask 077' scripts/install_raspberry_pi.sh
grep -q 'umask 077' scripts/provision_sailboat_pi.sh
grep -q 'umask 077' scripts/configure_gpsd.sh
grep -q 'umask 077' scripts/configure_gps_time.sh
grep -q 'umask 077' scripts/configure_desktop_autologin.sh
for script in scripts/install_raspberry_pi.sh scripts/provision_sailboat_pi.sh scripts/configure_gpsd.sh scripts/configure_gps_time.sh scripts/configure_desktop_autologin.sh; do
  grep -q 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$script"
  grep -q 'export PATH' "$script"
done
grep -q 'reset_private_venv' scripts/install_raspberry_pi.sh
grep -q 'sync_tree "$venv_dir"' scripts/install_raspberry_pi.sh
grep -q 'cannot sync missing tree' scripts/install_raspberry_pi.sh
grep -q 'file_path.is_symlink()' scripts/install_raspberry_pi.sh
grep -q 'directory_path.is_symlink()' scripts/install_raspberry_pi.sh
grep -q 'venv tree sync skips symlinked directories' README.md
grep -q 'venv tree sync skips symlinked directories' docs/sailboat-pi.md
grep -q 'validate_user_install_path' scripts/install_raspberry_pi.sh
grep -q 'path contains a symlink' scripts/install_raspberry_pi.sh
grep -q 'expected no group/other write bits' scripts/install_raspberry_pi.sh
grep -q 'validate_user_install_path "${HOME}/.local/bin" "user command directory" directory' scripts/install_raspberry_pi.sh
grep -q 'validate_user_install_path "$data_dir" "NOAA Navionics data directory" directory' scripts/install_raspberry_pi.sh
grep -q 'validate_user_install_path "$revision_file" "source revision file" regular' scripts/install_raspberry_pi.sh
grep -q 'ensure_private_directory "${HOME}/.local/bin" "user command directory"' scripts/install_raspberry_pi.sh
grep -q 'ensure_private_directory "$data_dir" "NOAA Navionics data directory"' scripts/install_raspberry_pi.sh
grep -q 'ensure_private_directory "$config_dir" "NOAA Navionics config directory"' scripts/install_raspberry_pi.sh
grep -q 'ensure_private_directory "$systemd_user_dir" "user systemd directory"' scripts/install_raspberry_pi.sh
grep -q 'chmod 0700 "$target"' scripts/install_raspberry_pi.sh
grep -q 'if path.is_dir():' scripts/install_raspberry_pi.sh
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/install_raspberry_pi.sh)" -ge 4
grep -q 'Installer sync helpers use no-follow directory opens' README.md
grep -q 'Installer sync helpers use no-follow directory opens' docs/sailboat-pi.md
grep -q 'validate_user_directory_path' scripts/provision_sailboat_pi.sh
grep -q 'ensure_private_directory "$(dirname "$config")" "NOAA Navionics config directory"' scripts/provision_sailboat_pi.sh
grep -q 'ensure_private_directory "$systemd_user_dir" "user systemd directory"' scripts/provision_sailboat_pi.sh
grep -q 'ensure_private_directory "$autostart_dir" "desktop autostart directory"' scripts/provision_sailboat_pi.sh
grep -q 'if path.is_dir():' scripts/provision_sailboat_pi.sh
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/provision_sailboat_pi.sh)" -ge 1
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/deploy_to_pi.sh)" -ge 5
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/start_chartplotter.sh)" -ge 2
grep -q 'Deployment, provisioning, and startup sync helpers use no-follow directory opens' README.md
grep -q 'Deployment, provisioning, and startup sync helpers use no-follow directory opens' docs/sailboat-pi.md
grep -q 'refusing to remove unexpected venv path' scripts/install_raspberry_pi.sh
grep -q 'refusing to remove venv outside data directory' scripts/install_raspberry_pi.sh
grep -q 'refusing to remove non-directory private venv path' scripts/install_raspberry_pi.sh
grep -q 'private venv cleanup requires Python shutil.rmtree with symlink-attack resistance' scripts/install_raspberry_pi.sh
grep -q 'not getattr(shutil.rmtree, "avoids_symlink_attacks", False)' scripts/install_raspberry_pi.sh
grep -q 'shutil.rmtree(venv)' scripts/install_raspberry_pi.sh
grep -q 'venv cleanup refuses Python runtimes without symlink-attack-resistant `shutil.rmtree`' README.md
grep -q 'venv cleanup refuses Python runtimes without symlink-attack-resistant `shutil.rmtree`' docs/sailboat-pi.md
grep -q 'usage()' scripts/install_raspberry_pi.sh
grep -q 'usage()' scripts/provision_sailboat_pi.sh
grep -q 'usage()' scripts/configure_gpsd.sh
grep -q 'usage()' scripts/configure_gps_time.sh
grep -q 'usage()' scripts/configure_desktop_autologin.sh
grep -q 'ensure_vcgencmd' scripts/install_raspberry_pi.sh
grep -q 'ensure_gpsd_client_tools' scripts/install_raspberry_pi.sh
grep -q 'raspi-utils' scripts/install_raspberry_pi.sh
grep -q 'libraspberrypi-bin' scripts/install_raspberry_pi.sh
grep -q 'python3 python3-venv python3-tk rsync opencpn' scripts/install_raspberry_pi.sh
grep -q 'python3-setuptools' scripts/install_raspberry_pi.sh
grep -q -- '--disable-pip-version-check' scripts/install_raspberry_pi.sh
grep -q -- '--no-index' scripts/install_raspberry_pi.sh
grep -q -- '--no-build-isolation' scripts/install_raspberry_pi.sh
grep -q -- '--no-use-pep517' scripts/install_raspberry_pi.sh
grep -q 'opencpn gpsd chrony lightdm x11-xserver-utils' scripts/install_raspberry_pi.sh
grep -q 'gpsd-clients' scripts/install_raspberry_pi.sh
grep -q 'gpsd-tools' scripts/install_raspberry_pi.sh
grep -q 'command -v cgps' scripts/install_raspberry_pi.sh
grep -q 'status --porcelain --untracked-files=all' scripts/install_raspberry_pi.sh
grep -q 'revision="${revision}-dirty"' scripts/install_raspberry_pi.sh
grep -q 'Direct installs run on a dirty Pi worktree' README.md
grep -q 'direct installs from a dirty Git worktree' docs/sailboat-pi.md
grep -q 'console_scripts' setup.py
grep -q 'noaa-navionics=noaa_navionics.cli:main' setup.py
grep -q 'noaa-navionics-gui=noaa_navionics.gui:main' setup.py
! grep -q '^build-backend' pyproject.toml
grep -q 'vcgencmd is not available' scripts/install_raspberry_pi.sh
grep -q 'python3-setuptools procps' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic' scripts/install_raspberry_pi.sh
grep -q 'link_user_atomic' scripts/install_raspberry_pi.sh
grep -q 'verify_installed_command_link' scripts/install_raspberry_pi.sh
grep -q 'verify_installed_user_executable' scripts/install_raspberry_pi.sh
grep -q 'mktemp "${target_dir}/.${target_name}.XXXXXX"' scripts/install_raspberry_pi.sh
grep -q 'install -m "$mode" "$source" "$tmp"' scripts/install_raspberry_pi.sh
grep -q 'ln -s "$source" "$tmp"' scripts/install_raspberry_pi.sh
test "$(grep -c 'validate_user_install_path "$target" "installed user file" regular' scripts/install_raspberry_pi.sh)" -ge 2
test "$(grep -c 'validate_user_install_path "$target" "installed command symlink" link' scripts/install_raspberry_pi.sh)" -ge 2
grep -q 'mv -f "$tmp" "$target"' scripts/install_raspberry_pi.sh
grep -q 'sync_paths "$target"' scripts/install_raspberry_pi.sh
grep -q 'Installer revalidates helper, unit, and command-link targets immediately before promotion' README.md
grep -q 'Installer revalidates helper, unit, and command-link targets immediately before promotion' docs/sailboat-pi.md
grep -q 'link_user_atomic "${venv_dir}/bin/noaa-navionics" "${HOME}/.local/bin/noaa-navionics"' scripts/install_raspberry_pi.sh
grep -q 'link_user_atomic "${venv_dir}/bin/noaa-navionics-gui" "${HOME}/.local/bin/noaa-navionics-gui"' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/scripts/start_chartplotter.sh" "${HOME}/.local/bin/noaa-navionics-start-chartplotter" 0755' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/scripts/configure_desktop_autologin.sh" "${HOME}/.local/bin/noaa-navionics-configure-desktop-autologin" 0755' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/scripts/configure_gps_time.sh" "${HOME}/.local/bin/noaa-navionics-configure-gps-time" 0755' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/systemd/noaa-navionics.service" "${systemd_user_dir}/noaa-navionics.service" 0644' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/systemd/noaa-navionics.timer" "${systemd_user_dir}/noaa-navionics.timer" 0644' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/systemd/noaa-navionics-track.service" "${systemd_user_dir}/noaa-navionics-track.service" 0644' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/systemd/noaa-navionics-preflight.service" "${systemd_user_dir}/noaa-navionics-preflight.service" 0644' scripts/install_raspberry_pi.sh
! grep -q 'cp "${repo_root}/systemd' scripts/install_raspberry_pi.sh
grep -q '"${HOME}/.local/bin/noaa-navionics-gui"' scripts/install_raspberry_pi.sh
grep -q 'sync_paths "$revision_file"' scripts/install_raspberry_pi.sh
grep -q 'os.chmod(tmp_path, 0o600)' scripts/install_raspberry_pi.sh
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
! grep -q '^cp systemd/' README.md docs/sailboat-pi.md
grep -q 'source-revision' scripts/verify_pi.sh
grep -q 'source revision matches' scripts/verify_pi.sh
grep -q 'expected_revision="${expected_revision}-dirty"' scripts/verify_pi.sh
grep -q 'allow_dirty=0' scripts/verify_pi.sh
grep -q 'check_status_report_json' scripts/verify_pi.sh
grep -q -- '--require-chartplotter-started' scripts/verify_pi.sh
grep -q -- '--expected-boot-id' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_EXPECTED_BOOT_ID' scripts/verify_pi.sh
grep -q 'current boot ID .* does not match expected reboot boot ID' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_GPS_SECONDS' scripts/verify_pi.sh
grep -q -- '--expected-gps-device' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_EXPECTED_GPS_DEVICE' scripts/verify_pi.sh
grep -q 'check_expected_gps_device_matches' scripts/verify_pi.sh
grep -q 'GPSD device matches expected' scripts/verify_pi.sh
[[ "$(grep -c 'parser.read_string(config_text, source=str(config_path))' scripts/verify_pi.sh)" -ge 3 ]]
grep -q 'config_text = handle.read()' scripts/verify_pi.sh
grep -q 'Do not verify root@' scripts/verify_pi.sh
grep -q 'verification user is not root' scripts/verify_pi.sh
grep -q 'check_chartplotter_log_after_boot' scripts/verify_pi.sh
grep -q 'launcher log cache directory is a symlink' scripts/verify_pi.sh
grep -q 'launcher log has permissions' scripts/verify_pi.sh
grep -q 'launcher log cache path contains a symlink' scripts/verify_pi.sh
grep -q 'flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' scripts/verify_pi.sh
grep -q 'log_stat = os.fstat(fd)' scripts/verify_pi.sh
grep -q 'stat.S_ISREG(log_stat.st_mode)' scripts/verify_pi.sh
grep -q 'os.fdopen(fd, "r", encoding="utf-8", errors="replace")' scripts/verify_pi.sh
! grep -q 'text = path.read_text(encoding="utf-8", errors="replace")' scripts/verify_pi.sh
grep -q 'rotated_log_file="${log_file}.1"' scripts/verify_pi.sh
grep -q 'check_optional_user_regular_file_integrity' scripts/verify_pi.sh
grep -q 'chartplotter launcher log file integrity' scripts/verify_pi.sh
grep -q 'chartplotter rotated launcher log file integrity' scripts/verify_pi.sh
grep -q 'parses the active launcher log only through the no-follow descriptor it verified' README.md
grep -q 'parses the active launcher log only through the no-follow descriptor it verified' docs/sailboat-pi.md
grep -q 'wait_for_chartplotter_started' scripts/verify_pi.sh
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/verify_pi.sh").read_text(encoding="utf-8")
start = text.index("wait_for_chartplotter_started() {")
end = text.index("\n}\n\nwait_for_chrony_gps_source", start)
block = text[start:end]
if "trap " in block:
    raise SystemExit("chartplotter wait temp cleanup must not use RETURN traps")
if block.count('rm -f "$check_output"') < 2:
    raise SystemExit("chartplotter wait temp file must be cleaned up on success and timeout")
PY
grep -q 'check_launcher_lock_live' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock live' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock is missing while OpenCPN is expected to be supervised' scripts/verify_pi.sh
grep -q 'chartplotter launcher cache parent directory is owned by uid' scripts/verify_pi.sh
grep -q 'chartplotter launcher cache parent directory has permissions' scripts/verify_pi.sh
grep -q 'chartplotter launcher cache directory is owned by uid' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock directory is owned by uid' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock is not a directory' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock exists without a readable boot ID file' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock pid is not a regular file' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock boot ID is not a regular file' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock pid file is owned by uid' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock boot ID file is owned by uid' scripts/verify_pi.sh
grep -q 'chartplotter launcher live environment overrides' scripts/verify_pi.sh
grep -q 'production verification requires launcher settings from' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock boot ID' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock symlink guard' scripts/verify_pi.sh
grep -q 'opencpn_stability_seconds=10' scripts/verify_pi.sh
grep -q 'opencpn_process_supervised_by_launcher' scripts/verify_pi.sh
grep -q 'supervised_opencpn_pids' scripts/verify_pi.sh
grep -q 'check_opencpn_process_executable_integrity' scripts/verify_pi.sh
grep -q 'check_opencpn_process_display_environment' scripts/verify_pi.sh
grep -q '/proc/${pid}/exe' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN executable integrity' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN display environment' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN executable is unreadable' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN executable directory' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN DISPLAY' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN XAUTHORITY' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN inherited NOAA_NAVIONICS' scripts/verify_pi.sh
grep -q 'check_chartplotter_xauthority_integrity' scripts/verify_pi.sh
grep -q 'chartplotter launcher XAUTHORITY path is not absolute' scripts/verify_pi.sh
grep -q 'chartplotter launcher XAUTHORITY file' scripts/verify_pi.sh
grep -q 'check_user_regular_file_integrity "$xauthority" "chartplotter launcher XAUTHORITY file"' scripts/verify_pi.sh
grep -q 'check_chartplotter_xauthority_integrity "$launcher_xauthority"' scripts/verify_pi.sh
grep -q 'check_chartplotter_xauthority_integrity "$xauthority"' scripts/verify_pi.sh
grep -q '/^PPid:/' scripts/verify_pi.sh
grep -q 'no active OpenCPN process is supervised by the chartplotter launcher' scripts/verify_pi.sh
grep -q 'no launcher-supervised OpenCPN process was started with -parse_all_enc' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN exited within' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN executable integrity failed after stability wait' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN display environment failed after stability wait' scripts/verify_pi.sh
grep -q 'launcher-supervised `opencpn` child process' README.md
grep -q 'launcher-supervised `opencpn` child process' docs/sailboat-pi.md
grep -q 'trusted root-owned executable with `-parse_all_enc`' README.md
grep -q 'trusted root-owned executable with `-parse_all_enc`' docs/sailboat-pi.md
grep -q 'remain running with that trusted executable and display environment through a short stability check' README.md
grep -q 'remain running with that trusted executable and display environment through a short stability check' docs/sailboat-pi.md
grep -q 'running on that same live X display from a trusted root-owned executable' README.md
grep -q 'running on that same live X display from a trusted root-owned executable' docs/sailboat-pi.md
grep -q 'trusted `XAUTHORITY` file when present' README.md
grep -q 'trusted `XAUTHORITY` file when present' docs/sailboat-pi.md
grep -q 'launcher-supervised OpenCPN is running' docs/sailboat-pi.md
grep -q 'OpenCPN stable after startup' scripts/verify_pi.sh
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/verify_pi.sh").read_text(encoding="utf-8")
start = text.index("check_opencpn_stable() {")
end = text.index("\n}\n\ncheck_launcher_lock_live", start)
block = text[start:end]
for needle in (
    "check_opencpn_process_executable_integrity",
    "check_opencpn_process_display_environment",
    "launcher-supervised OpenCPN executable integrity failed after stability wait",
    "launcher-supervised OpenCPN display environment failed after stability wait",
):
    if needle not in block:
        raise SystemExit(f"missing OpenCPN stability guard: {needle}")
PY
grep -q 'wait_for_chrony_gps_source' scripts/verify_pi.sh
grep -q 'check_recent_track_log' scripts/verify_pi.sh
grep -q 'recent GPX trackpoint' scripts/verify_pi.sh
grep -q 'max_trackpoint_age = 600.0' scripts/verify_pi.sh
grep -q 'newest GPX trackpoint is stale' scripts/verify_pi.sh
grep -q 'timestamped trackpoint' scripts/verify_pi.sh
grep -q 'trackpoint_position' scripts/verify_pi.sh
grep -q 'trackpoint_quality' scripts/verify_pi.sh
grep -q 'read_trusted_track_file' scripts/verify_pi.sh
grep -q 'changed before it could be read' scripts/verify_pi.sh
grep -q 'GPX trackpoint is missing satellite or HDOP quality fields' scripts/verify_pi.sh
grep -q 'GPX trackpoint has non-finite coordinates' scripts/verify_pi.sh
grep -q 'GPX trackpoint latitude is outside -90..90' scripts/verify_pi.sh
grep -q 'GPX trackpoint longitude is outside -180..180' scripts/verify_pi.sh
grep -q 'GPX trackpoint has invalid 0,0 coordinates' scripts/verify_pi.sh
grep -q 'GPX trackpoint has invalid negative HDOP' scripts/verify_pi.sh
test "$(grep -c 'status report track_log latest_hdop is negative' scripts/verify_pi.sh)" -ge 2
test "$(grep -c 'def numeric_track_log_field' scripts/verify_pi.sh)" -ge 2
test "$(grep -c 'status report track_log latest_latitude is outside -90..90' scripts/verify_pi.sh)" -ge 2
test "$(grep -c 'status report track_log latest_longitude is outside -180..180' scripts/verify_pi.sh)" -ge 2
test "$(grep -c 'status report track_log latest coordinates are invalid 0,0' scripts/verify_pi.sh)" -ge 2
test "$(grep -c 'status report track_log age_seconds is negative' scripts/verify_pi.sh)" -ge 2
test "$(grep -c 'status report track_log age_seconds is stale' scripts/verify_pi.sh)" -ge 2
grep -q 'def first_symlink_ancestor' scripts/verify_pi.sh
grep -q 'track_storage_symlink_component' scripts/verify_pi.sh
grep -q 'configured GPX track storage path contains a symlink' scripts/verify_pi.sh
grep -q 'expected real GPX track storage' scripts/verify_pi.sh
grep -q 'expected a regular GPX track file' scripts/verify_pi.sh
grep -q 'resolves outside GPX tracks directory' scripts/verify_pi.sh
grep -q 'expected {os.getuid()}' scripts/verify_pi.sh
grep -q 'tracking.output' scripts/verify_pi.sh
grep -q '<trkpt\\b' scripts/verify_pi.sh
grep -q 'chartplotter_start_timeout=120' scripts/verify_pi.sh
grep -q 'chartplotter_start_timeout_floor=120' scripts/verify_pi.sh
grep -q 'set_chartplotter_start_timeout_from_launcher_env' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_READINESS_ATTEMPTS 3' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_READINESS_RETRY_DELAY 10' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_WARNING_SECONDS 8' scripts/verify_pi.sh
grep -q 'gps_seconds \* readiness_attempts' scripts/verify_pi.sh
grep -q 'launcher failed to disable one or more display power settings' scripts/verify_pi.sh
grep -q 'check_live_display_power_disabled' scripts/verify_pi.sh
grep -q 'display power disabled after boot' scripts/verify_pi.sh
grep -q 'xset q failed for chartplotter display' scripts/verify_pi.sh
grep -q 'display screen saver timeout is not disabled' scripts/verify_pi.sh
grep -q 'display DPMS is not disabled' scripts/verify_pi.sh
grep -q 'launcher log shows OpenCPN exited after current-boot startup' scripts/verify_pi.sh
grep -q 'launcher log does not contain OpenCPN launch or duplicate marker' scripts/verify_pi.sh
grep -q 'pgrep -u "$(id -u)" -x opencpn' scripts/verify_pi.sh
grep -q 'opencpn_process_active' scripts/verify_pi.sh
grep -Fq 'state="${stat_line##*) }"' scripts/verify_pi.sh
grep -Fq '[[ -n "$state" && "$state" != "Z" ]]' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN running' scripts/verify_pi.sh
! grep -q 'check "OpenCPN running"' scripts/verify_pi.sh
grep -q 'status report JSON ready' scripts/verify_pi.sh
grep -q 'boot status report JSON ready' scripts/verify_pi.sh
grep -q 'status_stat = os.fstat(fd)' scripts/verify_pi.sh
grep -q 'not stat.S_ISREG(status_stat.st_mode)' scripts/verify_pi.sh
grep -q 'os.fdopen(fd, encoding="utf-8")' scripts/verify_pi.sh
! grep -q 'with status_path.open(encoding="utf-8") as handle' scripts/verify_pi.sh
grep -q 'def read_private_user_file_text' scripts/verify_pi.sh
grep -q 'def read_trusted_text_file' scripts/verify_pi.sh
grep -q 'launcher_text, launcher_env_stat = read_private_user_file_text' scripts/verify_pi.sh
grep -q 'opencpn_text, opencpn_stat = read_trusted_text_file' scripts/verify_pi.sh
grep -q 'autostart_text, autostart_stat = read_trusted_text_file' scripts/verify_pi.sh
grep -q 'lightdm_text, lightdm_stat = read_trusted_text_file' scripts/verify_pi.sh
grep -q 'config_text, config_stat = read_trusted_text_file' scripts/verify_pi.sh
grep -q 'parser.read_string(config_text, source=expected_config_path)' scripts/verify_pi.sh
grep -q 'parse_opencpn_config_text(opencpn_text)' scripts/verify_pi.sh
grep -q 'parse_key_value_text(autostart_text' scripts/verify_pi.sh
grep -q 'parse_key_value_text(lightdm_text' scripts/verify_pi.sh
! grep -q 'def parse_key_value_file' scripts/verify_pi.sh
! grep -q 'parse_opencpn_config(opencpn_config_path)' scripts/verify_pi.sh
! grep -q 'parser.read(Path(expected_config_path).expanduser())' scripts/verify_pi.sh
grep -q 'expected private 0600' scripts/verify_pi.sh
! grep -q 'launcher_env_file.read_text(encoding="utf-8")' scripts/verify_pi.sh
grep -q 'parsing that status artifact only through the no-follow descriptor it verified' README.md
grep -q 'parses that status artifact only through the no-follow descriptor it verified' docs/sailboat-pi.md
grep -q 'launcher settings matching a no-follow descriptor read of the live private launcher environment' README.md
grep -q 'launcher settings matching a no-follow descriptor read of the live private launcher environment' docs/sailboat-pi.md
grep -q 'onboard app config through a no-follow descriptor read' README.md
grep -q 'onboard app config through a no-follow descriptor read' docs/sailboat-pi.md
grep -q 'GPSD device comparisons through that same trusted config read path' README.md
grep -q 'GPSD device comparisons through that same trusted config read path' docs/sailboat-pi.md
grep -q 'recent GPX trackpoint verification uses that same trusted config read path' README.md
grep -q 'recent GPX trackpoint verification uses that same trusted config read path' docs/sailboat-pi.md
grep -q 'status report boot ID' scripts/verify_pi.sh
grep -q 'status report source revision' scripts/verify_pi.sh
grep -q 'status report source revision path is a symlink' scripts/verify_pi.sh
grep -q 'status report source revision directory is a symlink' scripts/verify_pi.sh
grep -q 'status report config path' scripts/verify_pi.sh
grep -q 'status report config path is a symlink' scripts/verify_pi.sh
grep -q 'status report OpenCPN config directory is a symlink' scripts/verify_pi.sh
grep -q 'status report OpenCPN config path contains a symlink' scripts/verify_pi.sh
grep -q 'status report OpenCPN config directory .* has permissions' scripts/verify_pi.sh
grep -q 'status report OpenCPN config is a symlink' scripts/verify_pi.sh
grep -q 'status report launcher settings path is a symlink' scripts/verify_pi.sh
grep -q 'status report desktop autostart path is a symlink' scripts/verify_pi.sh
grep -q 'status report LightDM autologin config path is a symlink' scripts/verify_pi.sh
grep -q 'def verify_status_file_owner_and_mode' scripts/verify_pi.sh
grep -q 'status report {label} uid' scripts/verify_pi.sh
grep -q 'status report {label} mode' scripts/verify_pi.sh
grep -q 'does not match live owner' scripts/verify_pi.sh
grep -q 'does not match live permissions' scripts/verify_pi.sh
grep -q 'status report desktop autostart is not a regular file' scripts/verify_pi.sh
grep -q 'status report LightDM autologin config is not a regular file' scripts/verify_pi.sh
grep -q 'config file integrity' scripts/verify_pi.sh
grep -q 'source revision file integrity' scripts/verify_pi.sh
grep -q 'Chrony config file integrity' scripts/verify_pi.sh
grep -q 'GPSD config file integrity' scripts/verify_pi.sh
grep -q 'status report config values do not match current config' scripts/verify_pi.sh
grep -q 'status report track_log tracks_dir' scripts/verify_pi.sh
grep -q 'status report track_log track_output is a symlink' scripts/verify_pi.sh
grep -q 'configured GPX track storage path contains a symlink' scripts/verify_pi.sh
grep -q 'is outside {expected_tracks_dir}' scripts/verify_pi.sh
grep -q 'is owned by uid' scripts/verify_pi.sh
grep -q 'expected private 0700' scripts/verify_pi.sh
grep -q 'status report track_log tracks_mode' scripts/verify_pi.sh
grep -q 'expected private 0600' scripts/verify_pi.sh
grep -q 'status report track_log latest_mode' scripts/verify_pi.sh
grep -q '"min_free_gb": float' scripts/verify_pi.sh
grep -q 'require_track_disk_check' scripts/verify_pi.sh
grep -q 'required_checks.add("Track Disk")' scripts/verify_pi.sh
grep -q 'status report manifest path' scripts/verify_pi.sh
grep -q 'status report manifest path is a symlink' scripts/verify_pi.sh
grep -q 'status report manifest path is not a regular file' scripts/verify_pi.sh
grep -q 'verify_status_file_owner_and_mode' scripts/verify_pi.sh
grep -q '"manifest",' scripts/verify_pi.sh
grep -q 'status report manifest does not exist' scripts/verify_pi.sh
grep -q 'status report manifest missing' scripts/verify_pi.sh
grep -q 'status report manifest missing created_at_source' scripts/verify_pi.sh
grep -q 'status report manifest created_at_source' scripts/verify_pi.sh
grep -q 'status report manifest download_skipped' scripts/verify_pi.sh
grep -q 'status report manifest created_at ' scripts/verify_pi.sh
grep -q 'does not match manifest file bytes' scripts/verify_pi.sh
grep -q 'does not match manifest file enc_cell_count' scripts/verify_pi.sh
grep -q 'actual_enc_cell_count' src/noaa_navionics/report.py
grep -q 'status report manifest actual_enc_cell_count' scripts/verify_pi.sh
grep -q 'actual_enc_cell_count: 1' tests/test_downloader.py
grep -q 'manifest-recorded and live ENC cell counts' README.md
grep -q 'manifest-recorded and live ENC cell counts' docs/sailboat-pi.md
grep -q 'manifest_field_pairs' scripts/verify_pi.sh
grep -q 'expected_package_filename' scripts/verify_pi.sh
grep -q 'expected_package_url' scripts/verify_pi.sh
grep -q 'status report manifest package filename' scripts/verify_pi.sh
grep -q 'status report manifest package URL' scripts/verify_pi.sh
grep -q 'status report manifest download URL' scripts/verify_pi.sh
grep -q 'status report manifest download path' scripts/verify_pi.sh
grep -q 'status report manifest download path is a symlink' scripts/verify_pi.sh
grep -q 'status report manifest download path contains a symlink' scripts/verify_pi.sh
grep -q 'status report manifest download path is not a regular file' scripts/verify_pi.sh
grep -q 'verify_status_file_owner_and_mode' scripts/verify_pi.sh
grep -q '"download_path_uid"' scripts/verify_pi.sh
grep -q '"download_path_mode"' scripts/verify_pi.sh
grep -q 'def sha256_trusted_file' scripts/verify_pi.sh
grep -q 'manifest_text, manifest_stat = read_trusted_text_file' scripts/verify_pi.sh
grep -q 'manifest_file = json.loads(manifest_text)' scripts/verify_pi.sh
grep -q 'actual_download_sha256, download_path_stat = sha256_trusted_file' scripts/verify_pi.sh
! grep -q 'with manifest_file_path.open(encoding="utf-8") as manifest_handle' scripts/verify_pi.sh
! grep -q 'def sha256_file' scripts/verify_pi.sh
grep -q 'bytes, expected' scripts/verify_pi.sh
grep -q 'status report manifest download path SHA-256' scripts/verify_pi.sh
grep -q 'def parse_manifest_int' scripts/verify_pi.sh
grep -q 'status report manifest {field} is invalid in {source}' scripts/verify_pi.sh
grep -q '"download_bytes"' scripts/verify_pi.sh
grep -q '"download bytes"' scripts/verify_pi.sh
grep -q 'status report manifest download byte count is not positive' scripts/verify_pi.sh
grep -q 'status report manifest extract path' scripts/verify_pi.sh
grep -q 'status report manifest extract path is a symlink' scripts/verify_pi.sh
grep -q 'status report manifest extract path contains a symlink' scripts/verify_pi.sh
grep -q 'status report manifest extract path is not a directory' scripts/verify_pi.sh
grep -q 'def count_enc_cells' scripts/verify_pi.sh
grep -q 'expected exactly {manifest_file_enc_cell_count}' scripts/verify_pi.sh
grep -q 'exact live ENC cell count' README.md
grep -q 'exact live ENC cell count' docs/sailboat-pi.md
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
grep -q '"Chrony Config"' scripts/verify_pi.sh
grep -q 'temperature sensor unavailable on Raspberry Pi' src/noaa_navionics/health.py
grep -q 'throttling reported since boot' src/noaa_navionics/health.py
! grep -q 'healthy now; historical events' src/noaa_navionics/health.py
grep -q 'measure_temp' src/noaa_navionics/health.py
grep -q 'vcgencmd measure_temp' README.md
grep -q 'vcgencmd measure_temp' docs/sailboat-pi.md
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
grep -q '"Desktop Startup"' scripts/verify_pi.sh
grep -q '"Launcher Settings"' scripts/verify_pi.sh
grep -q 'status report has no unit_files section' scripts/verify_pi.sh
grep -q 'status report {unit} path is a symlink' scripts/verify_pi.sh
grep -q 'status report {unit} directory is a symlink' scripts/verify_pi.sh
grep -q 'status report {unit} uid' scripts/verify_pi.sh
grep -q 'status report {unit} directory_uid' scripts/verify_pi.sh
grep -q 'status report {unit} mode' scripts/verify_pi.sh
grep -q 'status report {unit} directory_mode' scripts/verify_pi.sh
grep -q 'expected no group/other write bits' scripts/verify_pi.sh
grep -q 'GPSD device matches config' scripts/verify_pi.sh
grep -q 'volatile; use /dev/serial/by-id/' scripts/verify_pi.sh
grep -q 'display power command' scripts/verify_pi.sh
grep -q 'process lookup command' scripts/verify_pi.sh
grep -q 'Pi power command' scripts/verify_pi.sh
grep -q 'check_raspberry_pi_throttling_state' scripts/verify_pi.sh
grep -q 'vcgencmd get_throttled failed' scripts/verify_pi.sh
grep -q 'Raspberry Pi power or thermal throttling reported since boot' scripts/verify_pi.sh
grep -q 'Pi power state' scripts/verify_pi.sh
grep -q 'local bin directory integrity' scripts/verify_pi.sh
grep -q 'app data directory integrity' scripts/verify_pi.sh
grep -q 'app config directory integrity' scripts/verify_pi.sh
grep -q 'private venv directory integrity' scripts/verify_pi.sh
grep -q 'check_command_symlink_to_private_venv' scripts/verify_pi.sh
grep -q 'noaa-navionics command symlink' scripts/verify_pi.sh
grep -q 'noaa-navionics GUI command symlink' scripts/verify_pi.sh
grep -q 'chartplotter launcher file integrity' scripts/verify_pi.sh
grep -q 'desktop autologin helper file integrity' scripts/verify_pi.sh
grep -q 'GPS time helper file integrity' scripts/verify_pi.sh
grep -q 'desktop autostart directory integrity' scripts/verify_pi.sh
grep -q 'systemd user directory integrity' scripts/verify_pi.sh
grep -q 'resolves outside private venv' scripts/verify_pi.sh
grep -q 'GPSD service enabled' scripts/verify_pi.sh
grep -q 'GPSD service active' scripts/verify_pi.sh
grep -q 'Chrony service enabled' scripts/verify_pi.sh
grep -q 'Chrony GPSD time source' scripts/verify_pi.sh
grep -q 'check_chrony_gps_time_config' scripts/verify_pi.sh
grep -q 'could not open chrony config' scripts/verify_pi.sh
grep -q 'chrony config is not a regular file' scripts/verify_pi.sh
grep -q 'not line.lstrip().startswith("#")' scripts/verify_pi.sh
grep -q 'uncommented NOAA Navionics GPSD SHM 0 time source' scripts/verify_pi.sh
grep -q 'Chrony usable GPS source' scripts/verify_pi.sh
grep -q 'chartplotter autostart' scripts/verify_pi.sh
grep -q 'chartplotter autostart name' scripts/verify_pi.sh
grep -q 'Exec=sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"' scripts/verify_pi.sh
grep -q 'chartplotter launcher ENC parse' scripts/verify_pi.sh
grep -q 'chartplotter launcher readiness gate' scripts/verify_pi.sh
grep -q 'chartplotter launcher readiness retries' scripts/verify_pi.sh
grep -q 'chartplotter launcher ambient environment scrub' scripts/verify_pi.sh
grep -q 'chartplotter launcher ambient environment re-exec' scripts/verify_pi.sh
grep -q 'chartplotter launcher fail-closed default' scripts/verify_pi.sh
grep -q 'chartplotter launcher explicit fail-open override' scripts/verify_pi.sh
grep -q 'chartplotter launcher readiness warning' scripts/verify_pi.sh
grep -q 'chartplotter launcher fail-closed warning label' scripts/verify_pi.sh
grep -q 'chartplotter launcher fail-open warning label' scripts/verify_pi.sh
grep -q 'chartplotter launcher dynamic warning button' scripts/verify_pi.sh
grep -q 'launcher reported failed readiness before OpenCPN startup' scripts/verify_pi.sh
grep -q 'chartplotter launcher duplicate guard' scripts/verify_pi.sh
grep -q 'chartplotter launcher OpenCPN restart setting' scripts/verify_pi.sh
grep -q 'chartplotter launcher OpenCPN restart loop' scripts/verify_pi.sh
grep -q 'check_opencpn_enc_parse_argument' scripts/verify_pi.sh
grep -q 'OpenCPN ENC parse argument' scripts/verify_pi.sh
grep -q 'no active OpenCPN process is supervised by the chartplotter launcher' scripts/verify_pi.sh
grep -q 'no launcher-supervised OpenCPN process was started with -parse_all_enc' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock boot ID' scripts/verify_pi.sh
grep -q 'chartplotter launcher previous-boot lock recovery' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock sync create' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock sync cleanup' scripts/verify_pi.sh
grep -q 'chartplotter launcher stale lock recovery' scripts/verify_pi.sh
grep -q 'production verification requires launcher settings from' scripts/verify_pi.sh
grep -q 'chartplotter launcher GPS wait persisted' scripts/verify_pi.sh
grep -q 'check_launcher_env_production_settings' scripts/verify_pi.sh
grep -q 'check_launcher_env_expected_value' scripts/verify_pi.sh
grep -q 'check_launcher_env_expected_value "$launcher_env" "NOAA_NAVIONICS_GPS_SECONDS" "$gps_seconds"' scripts/verify_pi.sh
grep -q 'check_launcher_env_expected_value "$launcher_env" "NOAA_NAVIONICS_OPENCPN_RESTARTS"' scripts/verify_pi.sh
grep -q 'check_launcher_env_expected_value "$launcher_env" "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY"' scripts/verify_pi.sh
grep -q 'could not open launcher environment' scripts/verify_pi.sh
grep -q 'launcher environment is not a regular file' scripts/verify_pi.sh
grep -q 'handle.read().splitlines()' scripts/verify_pi.sh
! grep -q 'grep -Fxq "NOAA_NAVIONICS_GPS_SECONDS' scripts/verify_pi.sh
grep -q 'check_root_directory_integrity "$(dirname "$path")" "OpenCPN command directory"' scripts/verify_pi.sh
grep -q 'check_user_regular_file_integrity' scripts/verify_pi.sh
grep -q 'check_user_private_regular_file_integrity "$launcher_env" "chartplotter launcher environment"' scripts/verify_pi.sh
grep -q 'check_root_regular_file_integrity' scripts/verify_pi.sh
grep -q 'check_root_directory_integrity' scripts/verify_pi.sh
grep -q 'first_shell_symlink_ancestor' scripts/verify_pi.sh
grep -q 'path contains a symlink' scripts/verify_pi.sh
grep -q 'chartplotter launcher env file integrity' scripts/verify_pi.sh
grep -q 'chartplotter launcher environment directory symlink guard' scripts/verify_pi.sh
grep -q 'chartplotter autostart file integrity' scripts/verify_pi.sh
grep -q 'LightDM autologin file integrity' scripts/verify_pi.sh
grep -q 'LightDM autologin directory integrity' scripts/verify_pi.sh
grep -q 'Chrony config directory integrity' scripts/verify_pi.sh
grep -q 'GPSD config directory integrity' scripts/verify_pi.sh
grep -q 'chart service file integrity' scripts/verify_pi.sh
grep -q 'chart timer file integrity' scripts/verify_pi.sh
grep -q 'track service file integrity' scripts/verify_pi.sh
grep -q 'preflight service file integrity' scripts/verify_pi.sh
grep -q 'expected no group/other write bits' scripts/verify_pi.sh
grep -q 'chartplotter launcher fail-open override disabled' scripts/verify_pi.sh
grep -q 'production dock verification requires fail-closed chartplotter startup' scripts/verify_pi.sh
grep -q 'status report launcher settings values' scripts/verify_pi.sh
grep -q 'do not match launcher environment' scripts/verify_pi.sh
grep -q '"launcher settings",' scripts/verify_pi.sh
grep -q 'status report launcher GPS wait' scripts/verify_pi.sh
grep -q 'status report OpenCPN chart directories' scripts/verify_pi.sh
grep -q 'do not match live OpenCPN config' scripts/verify_pi.sh
grep -q 'does not contain enabled GPSD connection' scripts/verify_pi.sh
grep -q 'status report has no desktop section' scripts/verify_pi.sh
grep -q 'status report desktop autostart values do not match live desktop file' scripts/verify_pi.sh
grep -q 'status report LightDM autologin values do not match live LightDM config' scripts/verify_pi.sh
grep -q 'chartplotter launcher display failure logging' scripts/verify_pi.sh
grep -q 'chartplotter autostart terminal' scripts/verify_pi.sh
grep -q 'chartplotter autostart not disabled' scripts/verify_pi.sh
grep -q 'graphical boot target' scripts/verify_pi.sh
grep -q 'LightDM active after boot' scripts/verify_pi.sh
grep -q 'systemctl is-active --quiet lightdm.service' scripts/verify_pi.sh
grep -q 'LightDM autologin user' scripts/verify_pi.sh
grep -q 'LightDM autologin X11 session' scripts/verify_pi.sh
grep -q 'could not open LightDM autologin config' scripts/verify_pi.sh
grep -q 'LightDM autologin config is not a regular file' scripts/verify_pi.sh
grep -q '/usr/share/xsessions' scripts/verify_pi.sh
grep -q 'chart service sync command' scripts/verify_pi.sh
grep -q 'chart service network wait command' scripts/verify_pi.sh
grep -q 'chart service loaded network wait command' scripts/verify_pi.sh
grep -q 'chart service loaded fragment path' scripts/verify_pi.sh
grep -q 'ExecStartPre=%h/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300' systemd/noaa-navionics.service
grep -q 'chart service loaded sync command' scripts/verify_pi.sh
grep -q 'chart service loaded timeout' scripts/verify_pi.sh
grep -q 'chart service loaded restart' scripts/verify_pi.sh
grep -q 'chart service loaded restart delay' scripts/verify_pi.sh
grep -q 'chart service loaded start limit interval' scripts/verify_pi.sh
grep -q 'chart service loaded start limit burst' scripts/verify_pi.sh
grep -q 'chart timer loaded weekly' scripts/verify_pi.sh
grep -q 'chart timer loaded fragment path' scripts/verify_pi.sh
grep -q 'chart timer loaded persistent' scripts/verify_pi.sh
grep -q 'chart timer loaded randomized delay' scripts/verify_pi.sh
grep -q 'chart timer install target' scripts/verify_pi.sh
grep -q 'check_unit_install_target' scripts/verify_pi.sh
grep -q 'could not open unit file' scripts/verify_pi.sh
grep -q 'unit file is not a regular file' scripts/verify_pi.sh
grep -q 'section == "Install"' scripts/verify_pi.sh
grep -q 'track service rotate daily' scripts/verify_pi.sh
grep -q 'track service loaded fragment path' scripts/verify_pi.sh
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
grep -q 'preflight service loaded fragment path' scripts/verify_pi.sh
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
grep -q 'GPSD client command' scripts/verify_pi.sh
grep -q 'command -v cgps' scripts/verify_pi.sh
grep -q 'GPSD socket enabled' scripts/verify_pi.sh
grep -q 'GPSD socket active' scripts/verify_pi.sh
grep -Fq 'suffix="${1#/dev/serial/by-id/}"' scripts/verify_pi.sh
grep -Fq '"$suffix" != */*' scripts/verify_pi.sh
grep -q 'def check_gpsd_startup_config' src/noaa_navionics/health.py
grep -q 'GPSD config directory is a symlink' src/noaa_navionics/health.py
grep -q 'GPSD config path is not a regular file' src/noaa_navionics/health.py
grep -q 'GPSD config .* is owned by uid' src/noaa_navionics/health.py
grep -q 'GPSD config .* has permissions' src/noaa_navionics/health.py
grep -q 'test_check_gpsd_startup_config_rejects_symlinked_config_ancestor' tests/test_downloader.py
grep -q 'test_check_gpsd_startup_config_rejects_nonregular_config' tests/test_downloader.py
grep -q 'test_check_gpsd_startup_config_rejects_writable_config' tests/test_downloader.py
grep -q 'symlinked, non-regular, writable, or misowned GPSD config' README.md
grep -q 'symlinked, non-regular, writable, or misowned GPSD config' docs/sailboat-pi.md
grep -q '"gpsd.socket"' src/noaa_navionics/report.py
grep -q '"GPSD Socket"' src/noaa_navionics/report.py
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
grep -q 'Do not configure desktop autologin as root' scripts/configure_desktop_autologin.sh
grep -q 'systemctl set-default graphical.target' scripts/configure_desktop_autologin.sh
grep -q 'systemctl enable lightdm.service' scripts/configure_desktop_autologin.sh
grep -q 'install_root_file_atomic "$tmp" "$autologin_conf" 0644' scripts/configure_desktop_autologin.sh
grep -q 'validate_lightdm_autologin_path' scripts/configure_desktop_autologin.sh
grep -q 'first_symlink_ancestor' scripts/configure_desktop_autologin.sh
grep -q 'has permissions {mode:04o}, expected no group/other write bits' scripts/configure_desktop_autologin.sh
grep -q 'LightDM autologin config is a symlink' scripts/configure_desktop_autologin.sh
grep -q 'LightDM autologin config path contains a symlink' scripts/configure_desktop_autologin.sh
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/configure_desktop_autologin.sh)" -ge 1
grep -q 'pwd.getpwnam' scripts/configure_desktop_autologin.sh
grep -q 'Autologin user home does not exist' scripts/configure_desktop_autologin.sh
grep -q 'Autologin user does not own home directory' scripts/configure_desktop_autologin.sh
grep -q 'GPS device must be an absolute /dev path' scripts/configure_gpsd.sh
grep -q 'GPS device path is volatile' scripts/configure_gpsd.sh
grep -q 'GPS device path is not a recognized stable path' scripts/configure_gpsd.sh
grep -q 'Do not configure GPSD as root' scripts/configure_gpsd.sh
grep -q 'GPS device path is a directory' scripts/configure_gpsd.sh
grep -q 'GPS device path is not a character device' scripts/configure_gpsd.sh
grep -q 'validate_updated_app_config' scripts/configure_gpsd.sh
grep -q 'prepare_app_config_path' scripts/configure_gpsd.sh
grep -q 'validate_gpsd_config_path' scripts/configure_gpsd.sh
grep -q -- '--gpsd-conf PATH' scripts/configure_gpsd.sh
grep -q 'first_symlink_ancestor' scripts/configure_gpsd.sh
grep -q 'GPSD config is a symlink' scripts/configure_gpsd.sh
grep -q 'GPSD config directory is a symlink' scripts/configure_gpsd.sh
grep -q 'GPSD config directory .* has permissions' scripts/configure_gpsd.sh
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/configure_gpsd.sh)" -ge 3
grep -q 'Refusing to write a non-standard GPSD config path' scripts/configure_gpsd.sh
grep -q 'from noaa_navionics.config import _prepare_config_parent, _read_existing_config, _reject_unsafe_config_path' scripts/configure_gpsd.sh
grep -q 'from noaa_navionics.config import _read_existing_config, _reject_unsafe_config_path, read_config' scripts/configure_gpsd.sh
grep -q '_read_existing_config(parser, config_path)' scripts/configure_gpsd.sh
! grep -q 'parser.read(config_path)' scripts/configure_gpsd.sh
grep -q 'app_config = read_config(tmp_path)' scripts/configure_gpsd.sh
grep -Fq 'suffix="${1#/dev/serial/by-id/}"' scripts/configure_gpsd.sh
grep -Fq '"$suffix" != */*' scripts/configure_gpsd.sh
grep -Fq '"$suffix" =~ ^[A-Za-z0-9._:+@-]+$' scripts/configure_gpsd.sh
grep -q 'install_root_file_atomic "$tmp" "$gpsd_conf" 0644' scripts/configure_gpsd.sh
grep -q 'systemctl daemon-reload' scripts/configure_gpsd.sh
grep -q 'systemctl enable --now gpsd.socket gpsd.service' scripts/configure_gpsd.sh
grep -q 'systemctl restart gpsd.socket gpsd.service' scripts/configure_gpsd.sh
grep -q 'backup_root_file_private "$gpsd_conf" "$backup"' scripts/configure_gpsd.sh
grep -q 'os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow, 0o600' scripts/configure_gpsd.sh
grep -q 'os.fchmod(dst_fd, 0o600)' scripts/configure_gpsd.sh
! grep -q 'sudo cp -a /etc/default/gpsd' scripts/configure_gpsd.sh
grep -q 'tempfile.NamedTemporaryFile' scripts/configure_gpsd.sh
grep -q 'os.chmod(tmp_path, 0o600)' scripts/configure_gpsd.sh
grep -q 'os.replace(tmp_path, config_path)' scripts/configure_gpsd.sh
for script in scripts/configure_gpsd.sh scripts/configure_gps_time.sh scripts/configure_desktop_autologin.sh; do
  grep -q 'install_root_file_atomic' "$script"
  grep -q 'sudo mktemp "${target_dir}/.${target_name}.XXXXXX"' "$script"
  grep -q 'sudo install -m "$mode" "$source" "$target_tmp"' "$script"
  grep -q 'sync_path "$target_tmp"' "$script"
  grep -q 'sudo mv -f "$target_tmp" "$target"' "$script"
  grep -q 'sync_path "$target"' "$script"
done
grep -q 'validate_existing_gps_config' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_system_service' scripts/provision_sailboat_pi.sh
grep -q 'Existing config is required when --skip-gpsd is used with unattended startup' scripts/provision_sailboat_pi.sh
grep -q 'Existing GPS config is a symlink when --skip-gpsd is used' scripts/provision_sailboat_pi.sh
grep -q 'Existing GPS config is not a regular file when --skip-gpsd is used' scripts/provision_sailboat_pi.sh
grep -q 'could not open existing GPS config when --skip-gpsd is used' scripts/provision_sailboat_pi.sh
grep -q 'Existing GPS config is not a regular file when opened' scripts/provision_sailboat_pi.sh
grep -q 'with os.fdopen(fd, encoding="utf-8") as handle' scripts/provision_sailboat_pi.sh
grep -q 'parser.read_string(read_existing_gps_config(config_path), source=str(config_path))' scripts/provision_sailboat_pi.sh
! grep -q 'parser.read(config_path)' scripts/provision_sailboat_pi.sh
grep -q 'Existing GPS config .* is owned by uid' scripts/provision_sailboat_pi.sh
grep -q 'Existing GPS config .* has permissions' scripts/provision_sailboat_pi.sh
grep -q 'gps.device must name the already configured GPS receiver when --skip-gpsd is used' scripts/provision_sailboat_pi.sh
grep -q 'does not match requested --device' scripts/provision_sailboat_pi.sh
grep -q 'gps.gpsd_host must be local when --skip-gpsd is used' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_system_service gpsd.socket "GPSD socket" --skip-gpsd' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_system_service gpsd.service GPSD --skip-gpsd' scripts/provision_sailboat_pi.sh
grep -Fq 'suffix not in {".", ".."}' scripts/provision_sailboat_pi.sh
grep -q 'safe_by_id_chars' scripts/provision_sailboat_pi.sh
grep -q 'GPS device path is not a character device' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_gps_time_config' scripts/provision_sailboat_pi.sh
grep -q 'systemctl restart gpsd.socket gpsd.service' scripts/configure_gps_time.sh
grep -q 'Existing chrony GPS time config is required when --skip-gps-time is used with unattended startup' scripts/provision_sailboat_pi.sh
grep -q 'Existing chrony GPS time config is a symlink when --skip-gps-time is used' scripts/provision_sailboat_pi.sh
grep -q 'Existing chrony GPS time config is not a regular file when --skip-gps-time is used' scripts/provision_sailboat_pi.sh
grep -q 'Existing chrony GPS time config is not a regular file when opened' scripts/provision_sailboat_pi.sh
grep -q 'could not open chrony config' scripts/provision_sailboat_pi.sh
grep -q 'Existing chrony GPS time config .* is owned by uid' scripts/provision_sailboat_pi.sh
grep -q 'Existing chrony GPS time config .* has permissions' scripts/provision_sailboat_pi.sh
grep -q 'chrony config must already contain the NOAA Navionics GPSD SHM 0 time source when --skip-gps-time is used' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_system_service chrony.service chrony --skip-gps-time' scripts/provision_sailboat_pi.sh
grep -q 'not line.lstrip().startswith("#")' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_charts' scripts/provision_sailboat_pi.sh
grep -q 'Existing chart config is required when --skip-sync is used with unattended startup' scripts/provision_sailboat_pi.sh
grep -q 'existing complete charts are required when --skip-sync is used with unattended startup' scripts/provision_sailboat_pi.sh
grep -q 'check_chart_manifest' scripts/provision_sailboat_pi.sh
grep -q 'check_disk_space(app_config.chart_output' scripts/provision_sailboat_pi.sh
grep -q 'validate_user_install_path' scripts/provision_sailboat_pi.sh
grep -q 'path contains a symlink' scripts/provision_sailboat_pi.sh
grep -q 'expected no group/other write bits' scripts/provision_sailboat_pi.sh
grep -q 'validate_user_install_path "$launcher_env" "chartplotter launcher environment"' scripts/provision_sailboat_pi.sh
grep -q 'validate_user_install_path "$chart_service" "chart refresh user service"' scripts/provision_sailboat_pi.sh
grep -q 'validate_user_install_path "$autostart_entry" "chartplotter desktop autostart"' scripts/provision_sailboat_pi.sh
grep -q -- '--no-device-check cannot be used while unattended startup is enabled' scripts/provision_sailboat_pi.sh
grep -q 'pass both --skip-services and --skip-autologin for manual testing' scripts/provision_sailboat_pi.sh
grep -q 'refclock SHM 0 offset 0.5 delay 0.1 refid GPS' scripts/configure_gps_time.sh
grep -q 'sudo systemctl restart gpsd' scripts/configure_gps_time.sh
grep -q 'Do not configure GPS time as root' scripts/configure_gps_time.sh
grep -q 'validate_chrony_config_path' scripts/configure_gps_time.sh
grep -q 'first_symlink_ancestor' scripts/configure_gps_time.sh
grep -q 'Chrony config is a symlink' scripts/configure_gps_time.sh
grep -q 'Chrony config directory is a symlink' scripts/configure_gps_time.sh
grep -q 'Chrony config directory .* has permissions' scripts/configure_gps_time.sh
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/configure_gps_time.sh)" -ge 2
grep -q 'expected no group/other write bits' scripts/configure_gps_time.sh
grep -q 'Refusing to write a non-standard chrony config path' scripts/configure_gps_time.sh
grep -q 'could not open chrony config' scripts/configure_gps_time.sh
grep -q 'chrony config is not a regular file when opened' scripts/configure_gps_time.sh
grep -q 'with os.fdopen(fd, encoding="utf-8") as handle' scripts/configure_gps_time.sh
grep -q 'root or current user' scripts/configure_gps_time.sh
grep -q 'unterminated NOAA Navionics GPS time block' scripts/configure_gps_time.sh
grep -q 'END marker without BEGIN' scripts/configure_gps_time.sh
grep -q 'install_root_file_atomic "$tmp" "$chrony_conf" 0644' scripts/configure_gps_time.sh
grep -q 'backup_root_file_private "$chrony_conf" "$backup"' scripts/configure_gps_time.sh
grep -q 'os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow, 0o600' scripts/configure_gps_time.sh
grep -q 'os.fchmod(dst_fd, 0o600)' scripts/configure_gps_time.sh
! grep -q 'source.read_text(encoding="utf-8")' scripts/configure_gps_time.sh
! grep -q 'sudo cp -a "$chrony_conf"' scripts/configure_gps_time.sh
grep -q 'status_attempts=3' scripts/verify_pi.sh
grep -q 'Time Sync' src/noaa_navionics/health.py
grep -q 'Source Revision' src/noaa_navionics/health.py
grep -q 'NOAA_NAVIONICS_SOURCE_REVISION_PATH' src/noaa_navionics/health.py
grep -q 'deployed source revision path is a symlink' src/noaa_navionics/health.py
grep -q 'deployed source revision is not recorded' src/noaa_navionics/health.py
grep -q 'SystemClockSynchronized' src/noaa_navionics/health.py
grep -q 'GPS Time Source' src/noaa_navionics/health.py
grep -q 'def check_chrony_gps_time_config' src/noaa_navionics/health.py
grep -q 'check_chrony_gps_time_config()' src/noaa_navionics/health.py
grep -q 'check_chrony_gps_time_source(seconds=gps_seconds)' src/noaa_navionics/health.py
grep -q 'CHRONY_GPSD_REFCLOCK' src/noaa_navionics/health.py
grep -q 'Chrony config is not a regular file' src/noaa_navionics/health.py
grep -q 'Chrony config .* is owned by uid' src/noaa_navionics/health.py
grep -q 'Chrony config .* has permissions' src/noaa_navionics/health.py
grep -q 'def _read_trusted_config_lines' src/noaa_navionics/health.py
grep -q 'flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/health.py
grep -q 'test_check_chrony_gps_time_config_accepts_managed_refclock' tests/test_downloader.py
grep -q 'test_check_chrony_gps_time_config_rejects_writable_config' tests/test_downloader.py
grep -q 'test_read_trusted_config_lines_rejects_writable_config_before_parsing' tests/test_downloader.py
grep -q 'GPS time setup reads existing chrony config, and readiness and production skip checks read GPSD and chrony config files, only after a no-follow descriptor' README.md
grep -q 'GPS time setup reads existing chrony config, and readiness and production skip checks read GPSD and chrony config files, only after a no-follow descriptor' docs/sailboat-pi.md
grep -q 'Production provisioning reads the existing onboard GPS config only after a no-follow descriptor' README.md
grep -q 'provisioning reads the existing onboard GPS config only after a no-follow descriptor' docs/sailboat-pi.md
grep -q 'The GPSD setup script reads any existing onboard app config through a no-follow descriptor' README.md
grep -q 'reads any existing onboard app config through a no-follow descriptor' docs/sailboat-pi.md
grep -q 'Readiness also rejects unsafe chrony config paths' README.md
grep -q 'Readiness requires the managed chrony GPSD SHM refclock config' docs/sailboat-pi.md
grep -q 'chronyc.*sources.*-n' src/noaa_navionics/health.py
grep -Fq 'line[1] in "*+"' src/noaa_navionics/health.py
grep -Fq '^#[*+].*GPS' scripts/verify_pi.sh
grep -q 'uncommented chrony GPSD time-source config' README.md
grep -q 'uncommented GPSD time-source config' docs/sailboat-pi.md
grep -q 'symlinked, non-regular, writable, or misowned chrony config paths' README.md
grep -q 'symlinked, non-regular, writable, or misowned chrony config paths' docs/sailboat-pi.md
grep -q 'chart directory does not exist' src/noaa_navionics/health.py
grep -q 'no fresh navigation-quality GPSD fix' src/noaa_navionics/health.py
grep -q 'GPSD fix missing satellite or HDOP quality fields' src/noaa_navionics/health.py
grep -q 'NMEA fix missing satellite or HDOP quality fields' src/noaa_navionics/health.py
grep -q 'test_check_gps_sample_rejects_missing_quality_fields' tests/test_downloader.py
grep -q 'test_check_gps_device_rejects_missing_quality_fields' tests/test_downloader.py
grep -q 'GPSD and direct NMEA readiness require satellite-count or HDOP quality fields' README.md
grep -q 'GPSD and direct NMEA readiness require satellite-count or HDOP quality fields' docs/sailboat-pi.md
grep -q 'Fresh navigation-quality GPSD or direct NMEA fix with satellite or HDOP quality fields' docs/sailboat-pi.md
! grep -q 'When the receiver reports satellite count or HDOP' README.md docs/sailboat-pi.md
grep -q 'no fresh navigation-quality NMEA fix' src/noaa_navionics/health.py
grep -q 'cannot verify freshness' src/noaa_navionics/health.py
grep -q 'weak GPS fix' src/noaa_navionics/gps.py
grep -q 'non-finite coordinates' src/noaa_navionics/gps.py
grep -q 'outside -90..90' src/noaa_navionics/gps.py
grep -q 'outside -180..180' src/noaa_navionics/gps.py
grep -q 'invalid GPS fix: 0.000000, 0.000000 coordinates' src/noaa_navionics/gps.py
grep -q 'invalid GPS fix: negative HDOP' src/noaa_navionics/gps.py
grep -q 'test_shared_gps_quality_rejects_negative_hdop' tests/test_downloader.py
grep -q 'missing_quality_detail' src/noaa_navionics/health.py
! grep -q 'pending_without_quality' src/noaa_navionics/health.py
grep -q 'def gps_fix_has_quality_fields' src/noaa_navionics/gps.py
grep -q 'manifest recorded' src/noaa_navionics/health.py
grep -q 'manifest recorded {manifest_cell_count} ENC cells but found {actual_cell_count}' src/noaa_navionics/health.py
grep -q 'test_manifest_with_extra_unrecorded_cells_fails' tests/test_downloader.py
grep -q 'exactly the manifest-recorded ENC cell count' README.md
grep -q 'exactly the manifest-recorded ENC cell count' docs/sailboat-pi.md
grep -q 'unverified-cache' src/noaa_navionics/health.py
grep -q 'chart directory is a symlink' src/noaa_navionics/health.py
grep -q 'manifest path is a symlink' src/noaa_navionics/health.py
grep -q 'manifest path is not a regular file' src/noaa_navionics/health.py
grep -q 'manifest path .* is owned by uid' src/noaa_navionics/health.py
grep -q 'manifest path .* has permissions' src/noaa_navionics/health.py
grep -q 'test_manifest_nonregular_path_fails' tests/test_downloader.py
grep -q 'test_manifest_writable_file_fails' tests/test_downloader.py
grep -q 'manifest extract path is a symlink' src/noaa_navionics/health.py
grep -q 'manifest extract path contains a symlink' src/noaa_navionics/health.py
grep -q 'manifest extract path is outside chart directory' src/noaa_navionics/health.py
grep -q 'unexpected ENC chart directories' src/noaa_navionics/health.py
grep -q 'manifest package URL' src/noaa_navionics/health.py
grep -q 'manifest download URL' src/noaa_navionics/health.py
grep -q 'manifest does not record a download URL' src/noaa_navionics/health.py
grep -q 'does not match configured' src/noaa_navionics/health.py
grep -q 'manifest download path is a symlink' src/noaa_navionics/health.py
grep -q 'manifest download path contains a symlink' src/noaa_navionics/health.py
grep -q 'manifest download path is outside chart directory' src/noaa_navionics/health.py
grep -q 'f"{label} is not a regular file' src/noaa_navionics/health.py
grep -q 'f"{label} {path} is owned by uid' src/noaa_navionics/health.py
grep -q 'f"{label} {path} has permissions' src/noaa_navionics/health.py
grep -q 'test_manifest_archive_nonregular_path_fails' tests/test_downloader.py
grep -q 'test_manifest_archive_writable_file_fails' tests/test_downloader.py
grep -q 'def _sha256_trusted_file' src/noaa_navionics/health.py
grep -q 'actual_bytes, actual_sha256 = _sha256_trusted_file' src/noaa_navionics/health.py
grep -q 'os.fdopen(fd, "rb")' src/noaa_navionics/health.py
grep -q 'test_sha256_trusted_file_rejects_writable_archive_before_hashing' tests/test_downloader.py
grep -q 'retained ZIP hashes are computed from the same no-follow descriptor' README.md
grep -q 'retained ZIP hashes are computed from the same no-follow descriptor' docs/sailboat-pi.md
grep -q 'positive download byte count' src/noaa_navionics/health.py
grep -q 'download SHA-256' src/noaa_navionics/health.py
grep -q 'manifest SHA-256 does not match' src/noaa_navionics/health.py
python3 - <<'PY'
from pathlib import Path

text = Path("src/noaa_navionics/health.py").read_text(encoding="utf-8")
start = text.index("def _check_manifest_archive")
end = text.index("\ndef _expected_manifest_package", start)
block = text[start:end]
bytes_index = block.index('expected_bytes = int(download.get("bytes", 0))')
sha_index = block.index('expected_sha256 = str(download.get("sha256", "")).strip().lower()')
exists_index = block.index('if not archive_path.exists():')
if not (bytes_index < exists_index and sha_index < exists_index):
    raise SystemExit("manifest download byte count and SHA-256 must be validated before retained ZIP existence")
PY
grep -q 'create or mount the configured storage path' src/noaa_navionics/health.py
grep -q 'use a real mounted storage directory' src/noaa_navionics/health.py
grep -q 'def _first_storage_symlink' src/noaa_navionics/health.py
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
grep -q 'procps' README.md
grep -q 'procps' docs/sailboat-pi.md
grep -q 'track_output=app_config.track_output' src/noaa_navionics/report.py
grep -q '"extract": app_config.extract' src/noaa_navionics/report.py
grep -q '"keep_zip": app_config.keep_zip' src/noaa_navionics/report.py
grep -q '"force": app_config.force' src/noaa_navionics/report.py
grep -q 'boot_id' src/noaa_navionics/report.py
grep -q 'BOOT_ID_PATH' src/noaa_navionics/report.py
grep -q 'extracted ZIP contains no ENC .000 cells' src/noaa_navionics/downloader.py
grep -q 'def _validate_downloaded_zip' src/noaa_navionics/downloader.py
grep -q 'def _zip_member_path_is_unsafe' src/noaa_navionics/downloader.py
grep -q 'downloaded ZIP has unsafe member path' src/noaa_navionics/downloader.py
grep -q 'downloaded ZIP is not a valid archive' src/noaa_navionics/downloader.py
grep -q 'downloaded ZIP contains no ENC .000 cells' src/noaa_navionics/downloader.py
grep -q 'or uses a non-HTTPS redirect' src/noaa_navionics/downloader.py
grep -q 'def _download_url_matches_package' src/noaa_navionics/downloader.py
grep -q 'test_download_rejects_http_redirect_before_writing_archive' tests/test_downloader.py
grep -q 'test_download_rejects_redirect_to_wrong_filename_before_writing_archive' tests/test_downloader.py
grep -q 'test_forced_download_rejects_bad_zip_before_replacing_archive' tests/test_downloader.py
grep -q 'test_forced_download_rejects_unsafe_zip_before_replacing_archive' tests/test_downloader.py
grep -q 'test_forced_download_rejects_zip_without_enc_cells_before_replacing_archive' tests/test_downloader.py
grep -q 'chart download path is not a regular file' src/noaa_navionics/downloader.py
grep -q 'chart download path .* is owned by uid' src/noaa_navionics/downloader.py
grep -q 'chart download path .* has permissions' src/noaa_navionics/downloader.py
grep -q 'def _hash_existing_download_path' src/noaa_navionics/downloader.py
grep -q 'destination_stat, digest = _hash_existing_download_path(destination)' src/noaa_navionics/downloader.py
grep -q 'os.fdopen(fd, "rb")' src/noaa_navionics/downloader.py
! grep -q 'digest = sha256_file(destination)' src/noaa_navionics/downloader.py
grep -q 'test_existing_zip_nonregular_path_fails_before_reading_cache' tests/test_downloader.py
grep -q 'test_existing_zip_writable_file_fails_before_reading_cache' tests/test_downloader.py
grep -q 'test_hash_existing_download_path_rejects_writable_zip_before_hashing' tests/test_downloader.py
grep -q 'previous chart manifest path is a symlink' src/noaa_navionics/downloader.py
grep -q 'previous chart manifest path is not a regular file' src/noaa_navionics/downloader.py
grep -q 'previous chart manifest path .* is owned by uid' src/noaa_navionics/downloader.py
grep -q 'previous chart manifest path .* has permissions' src/noaa_navionics/downloader.py
grep -q 'def _open_manifest_for_read' src/noaa_navionics/downloader.py
grep -q 'manifest directory contains a symlink' src/noaa_navionics/downloader.py
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/downloader.py
grep -q 'test_read_manifest_rejects_symlinked_manifest' tests/test_downloader.py
grep -q 'test_read_manifest_rejects_symlinked_manifest_directory' tests/test_downloader.py
grep -q 'test_read_manifest_rejects_writable_manifest' tests/test_downloader.py
grep -q 'test_existing_zip_symlinked_previous_manifest_fails_before_extracting' tests/test_downloader.py
grep -q 'test_existing_zip_writable_previous_manifest_fails_before_extracting' tests/test_downloader.py
grep -q 'unsafe ownership or permissions' README.md
grep -q 'unsafe ownership or permissions' docs/sailboat-pi.md
grep -q 'cache-reuse hashes are computed from the same no-follow descriptor' README.md
grep -q 'cache-reuse hashes are computed from the same no-follow descriptor' docs/sailboat-pi.md
grep -q 'Manifest reads reject symlinked manifest files or parent path components' README.md
grep -q 'Manifest reads reject symlinked manifest files or parent path components' docs/sailboat-pi.md
grep -q 'trusted previous manifest' README.md
grep -q 'trusted previous manifest' docs/sailboat-pi.md
grep -q 'HTTP or change filenames fail before archive replacement' README.md
grep -q 'HTTP or change filenames fail before archive replacement' docs/sailboat-pi.md
grep -q 'chart update already in progress' src/noaa_navionics/downloader.py
grep -q 'chart update lock path is a symlink' src/noaa_navionics/downloader.py
grep -q 'test_download_lock_rejects_symlinked_lock_path' tests/test_downloader.py
grep -q 'def _validate_stale_lock_for_cleanup' src/noaa_navionics/downloader.py
grep -q 'def _read_chart_update_lock_text' src/noaa_navionics/downloader.py
grep -q 'fd = os.open(lock_path, flags)' src/noaa_navionics/downloader.py
grep -q 'chart update lock path has permissions' src/noaa_navionics/downloader.py
grep -q 'chart update lock path is not a regular file; leaving it in place' src/noaa_navionics/downloader.py
grep -q 'with os.fdopen(fd, encoding="ascii", errors="ignore") as handle' src/noaa_navionics/downloader.py
! grep -q 'lock_path.read_text(encoding="ascii", errors="ignore")' src/noaa_navionics/downloader.py
grep -q 'test_stale_download_lock_cleanup_rejects_writable_lock_file' tests/test_downloader.py
grep -q 'stale lock reads use a no-follow descriptor, stale lock cleanup refuses misowned or group/world-writable lock files' README.md
grep -q 'stale lock reads use a no-follow descriptor, stale lock cleanup refuses misowned or group/world-writable lock files' docs/sailboat-pi.md
grep -q 'boot_id=' src/noaa_navionics/downloader.py
grep -q 'lock_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/downloader.py
grep -q 'os.fchmod(lock_fd, 0o600)' src/noaa_navionics/downloader.py
grep -q 'partial download already exists; remove interrupted chart update debris' src/noaa_navionics/downloader.py
grep -q 'chart archive path is a symlink' src/noaa_navionics/downloader.py
grep -q 'tmp_path.exists() or tmp_path.is_symlink()' src/noaa_navionics/downloader.py
grep -q 'os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/downloader.py
grep -q 'os.fchmod(fd, 0o600)' src/noaa_navionics/downloader.py
grep -q 'chart extraction destination is a symlink' src/noaa_navionics/downloader.py
grep -q 'chart extraction destination is not a directory' src/noaa_navionics/downloader.py
grep -q 'test_extract_zip_rejects_symlinked_destination_parent' tests/test_downloader.py
grep -q 'test_extract_zip_rejects_non_directory_destination' tests/test_downloader.py
grep -q 'moved_existing_to_previous' src/noaa_navionics/downloader.py
grep -q 'def _validate_removable_chart_tree' src/noaa_navionics/downloader.py
grep -q 'previous chart extraction path is a symlink before cleanup' tests/test_downloader.py
grep -q 'test_extract_zip_rejects_symlinked_previous_debris_without_promoting_it' tests/test_downloader.py
grep -q 'test_extract_zip_rejects_previous_debris_with_symlinked_child' tests/test_downloader.py
grep -q 'unsafe `.previous` extraction debris' README.md
grep -q 'unsafe `.previous` extraction debris' docs/sailboat-pi.md
grep -q 'shutil.rmtree is not symlink-attack resistant' src/noaa_navionics/downloader.py
grep -q '_remove_path(staging, missing_ok=True, label="chart extraction staging")' src/noaa_navionics/downloader.py
grep -q 'test_extract_zip_cleanup_requires_symlink_safe_rmtree' tests/test_downloader.py
grep -q 'test_extract_zip_failed_staging_cleanup_requires_symlink_safe_rmtree' tests/test_downloader.py
grep -q 'Python runtime without symlink-attack-resistant `shutil.rmtree`' README.md
grep -q 'Python runtime without symlink-attack-resistant `shutil.rmtree`' docs/sailboat-pi.md
grep -q 'def _pid_is_running' src/noaa_navionics/downloader.py
grep -q 'def _current_boot_id' src/noaa_navionics/downloader.py
grep -q 'STATE_PACKAGES' src/noaa_navionics/downloader.py
grep -q 'COAST_GUARD_DISTRICT_PACKAGES' src/noaa_navionics/downloader.py
grep -q 'REGION_PACKAGES' src/noaa_navionics/downloader.py
grep -q 'if not keep_zip' src/noaa_navionics/downloader.py
grep -q 'def _remove_download_archive' src/noaa_navionics/downloader.py
grep -q 'chart archive path is a symlink before removal' src/noaa_navionics/downloader.py
grep -q 'test_existing_zip_no_keep_zip_rejects_symlink_swapped_before_removal' tests/test_downloader.py
grep -q 'ZIP is revalidated as a regular trusted archive immediately before removal' README.md
grep -q 'ZIP is revalidated as a regular trusted archive immediately before removal' docs/sailboat-pi.md
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/downloader.py
grep -q 'os.fsync(handle.fileno())' src/noaa_navionics/downloader.py
grep -q 'def _fsync_directory' src/noaa_navionics/downloader.py
grep -q 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/downloader.py
grep -q 'def _fsync_tree' src/noaa_navionics/downloader.py
grep -q 'test_chart_directory_sync_uses_no_follow_open' tests/test_downloader.py
grep -q 'Chart directory sync uses no-follow directory opens' README.md
grep -q 'Chart directory sync uses no-follow directory opens' docs/sailboat-pi.md
grep -q 'os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/gps.py
grep -q 'os.fsync(self.file.fileno())' src/noaa_navionics/gps.py
grep -q 'def _fsync_directory' src/noaa_navionics/gps.py
grep -q 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/gps.py
grep -q 'test_gpx_logger_directory_sync_uses_no_follow_open' tests/test_downloader.py
grep -q 'GPX directory sync uses no-follow directory opens' README.md
grep -q 'GPX directory sync uses no-follow directory opens' docs/sailboat-pi.md
grep -q 'expected a new regular GPX track file' src/noaa_navionics/gps.py
grep -q 'def _coordinate_in_range' src/noaa_navionics/gps.py
grep -q '_coordinate_in_range(self.latitude, latitude=True)' src/noaa_navionics/gps.py
grep -q '_coordinate_in_range(self.longitude, latitude=False)' src/noaa_navionics/gps.py
grep -q 'self.fix_quality is not None' src/noaa_navionics/gps.py
grep -q 'self.fix_quality != 0' src/noaa_navionics/gps.py
grep -q 'test_parse_nmea_rejects_impossible_coordinate_values' tests/test_downloader.py
grep -q 'test_parse_gpsd_tpv_rejects_out_of_range_position' tests/test_downloader.py
grep -q 'if gps_fix_quality_failure(fix):' src/noaa_navionics/gps.py
grep -q 'invalid GPS fix: missing coordinates' src/noaa_navionics/gps.py
grep -q 'hemisphere not in ("N", "S")' src/noaa_navionics/gps.py
grep -q 'hemisphere not in ("E", "W")' src/noaa_navionics/gps.py
grep -q 'if lat is None or lon is None:' src/noaa_navionics/gps.py
grep -q 'minutes < 0.0 or minutes >= 60.0' src/noaa_navionics/gps.py
grep -q 'def _finite_float_or_none' src/noaa_navionics/gps.py
grep -q 'math.isfinite(parsed)' src/noaa_navionics/gps.py
grep -q 'def _non_negative_float_or_none' src/noaa_navionics/gps.py
grep -q 'def _course_degrees_or_none' src/noaa_navionics/gps.py
grep -q 'speed_mps = _non_negative_float_or_none' src/noaa_navionics/gps.py
grep -q 'track = _course_degrees_or_none' src/noaa_navionics/gps.py
grep -q 'hdop = _non_negative_float_or_none' src/noaa_navionics/gps.py
grep -q 'speed_knots=_non_negative_float_or_none' src/noaa_navionics/gps.py
grep -q 'course_degrees=_course_degrees_or_none' src/noaa_navionics/gps.py
grep -q 'test_parse_nmea_drops_impossible_optional_quality_and_motion' tests/test_downloader.py
grep -q 'test_parse_gpsd_tpv_drops_impossible_optional_motion' tests/test_downloader.py
grep -q 'test_parse_gpsd_sky_drops_negative_hdop' tests/test_downloader.py
grep -q 'ignore malformed, non-finite, negative, or out-of-range optional speed, course, satellite-count, or HDOP values' README.md
grep -q 'ignore malformed, non-finite, negative, or out-of-range optional speed, course, satellite-count, or HDOP values' docs/sailboat-pi.md
grep -q 'def _non_negative_int_or_none' src/noaa_navionics/gps.py
grep -q 'mode = _non_negative_int_or_none' src/noaa_navionics/gps.py
grep -q 'return _finite_float_or_none(value)' src/noaa_navionics/gps.py
grep -q 'return _non_negative_int_or_none(value)' src/noaa_navionics/gps.py
grep -q 'day_carry' src/noaa_navionics/gps.py
grep -q 'not math.isfinite(seconds)' src/noaa_navionics/gps.py
grep -q 'isinstance(time_value, str)' src/noaa_navionics/gps.py
grep -q 'Malformed or non-finite NMEA timestamps and malformed GPSD timestamps are treated as missing timestamps' README.md
grep -q 'Malformed or non-finite NMEA timestamps and malformed GPSD timestamps are treated as missing timestamps' docs/sailboat-pi.md
grep -q 'fix.timestamp is None' src/noaa_navionics/gps.py
grep -q 'signal.SIGTERM' src/noaa_navionics/cli.py
grep -q 'Skipping weak track fix' src/noaa_navionics/cli.py
grep -q 'Skipping untimestamped track fix' src/noaa_navionics/cli.py
grep -q 'Skipping low-detail track fix' src/noaa_navionics/cli.py
grep -q 'fix timestamp is stale' src/noaa_navionics/cli.py
grep -q 'fix timestamp is in the future' src/noaa_navionics/cli.py
grep -q 'skips invalid coordinates, missing satellite/HDOP quality fields, untimestamped fixes, stale or future-dated timestamps, and weak satellite/HDOP fixes' README.md
grep -q 'skips invalid coordinates, missing satellite/HDOP quality fields, untimestamped fixes, stale or future-dated timestamps, and weak satellite/HDOP fixes' docs/sailboat-pi.md
! grep -q 'pending_without_quality' src/noaa_navionics/cli.py
grep -q 'gps_fix_quality_failure' src/noaa_navionics/cli.py
grep -q 'gps_fix_has_quality_fields' src/noaa_navionics/cli.py
grep -q 'gps_fix_has_quality_fields(fix)' src/noaa_navionics/gps.py
grep -q '<sat>{fix.satellites}</sat>' src/noaa_navionics/gps.py
grep -q '<hdop>{fix.hdop:g}</hdop>' src/noaa_navionics/gps.py
grep -q 'Live GPS stream ended unexpectedly' src/noaa_navionics/cli.py
grep -q 'logger = GPXTrackLogger(output)' src/noaa_navionics/cli.py
grep -q 'first_symlink_ancestor' src/noaa_navionics/gps.py
grep -q 'expected real GPX track storage' src/noaa_navionics/gps.py
grep -q 'os.chmod(parent, 0o700)' src/noaa_navionics/gps.py
grep -q 'test_gpx_logger_tightens_public_track_parent' tests/test_downloader.py
grep -q 'test_gpx_logger_rejects_misowned_track_parent' tests/test_downloader.py
grep -q 'test_gpx_logger_rejects_symlinked_track_parent' tests/test_downloader.py
grep -q 'test_gpx_logger_rejects_symlinked_track_file' tests/test_downloader.py
grep -q 'def _prepare_private_tracks_dir' src/noaa_navionics/cli.py
grep -q 'first_symlink_ancestor' src/noaa_navionics/cli.py
grep -q 'is a symlink, expected a private tracks directory' src/noaa_navionics/cli.py
grep -q 'is owned by uid .* expected' src/noaa_navionics/cli.py
grep -q 'test_log_rotating_tracks_rejects_symlinked_base_directory' tests/test_downloader.py
grep -q 'GPX logging rejects symlinked track-output parent components' README.md
grep -q 'GPX logger also refuses symlinked track-output parent components' docs/sailboat-pi.md
grep -q 'symlinked GPX output files' README.md
grep -q 'symlinked GPX output files' docs/sailboat-pi.md
grep -q 'os.chmod(path, 0o700)' src/noaa_navionics/cli.py
grep -q 'refusing to prune GPX track logs' src/noaa_navionics/cli.py
grep -q 'not a regular GPX track file' src/noaa_navionics/cli.py
grep -q 'test_prune_old_track_logs_rejects_symlinked_old_track' tests/test_downloader.py
grep -q 'test_prune_old_track_logs_rejects_nonregular_old_track' tests/test_downloader.py
grep -q 'Retention pruning refuses symlinked, non-regular, misowned, or group/world-writable old GPX entries' README.md
grep -q 'Retention pruning refuses symlinked, non-regular, misowned, or group/world-writable old GPX entries' docs/sailboat-pi.md
grep -q 'def _prepare_private_status_parent' src/noaa_navionics/report.py
grep -q 'def _prepare_home_status_cache_parent' src/noaa_navionics/report.py
grep -q 'status report parent directory' src/noaa_navionics/report.py
grep -q 'status report parent path contains a symlink' src/noaa_navionics/report.py
grep -q 'status report cache parent directory' src/noaa_navionics/report.py
grep -q 'os.chmod(cache_parent, 0o700)' src/noaa_navionics/report.py
grep -q 'os.chmod(tmp_path, 0o600)' src/noaa_navionics/report.py
grep -q 'os.chmod(path, 0o700)' src/noaa_navionics/report.py
grep -q 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/report.py
grep -q 'status report cache directory' scripts/verify_pi.sh
grep -q 'status report cache parent directory is a symlink' scripts/verify_pi.sh
grep -q 'status report cache parent directory .* is owned by uid' scripts/verify_pi.sh
grep -q 'status report cache parent directory .* has permissions' scripts/verify_pi.sh
grep -q 'expected private 0600' scripts/verify_pi.sh
grep -q 'test_write_status_report_tightens_public_home_cache_parent' tests/test_downloader.py
grep -q 'test_write_status_report_rejects_symlinked_output_parent' tests/test_downloader.py
grep -q 'test_write_status_report_rejects_symlinked_output_ancestor' tests/test_downloader.py
grep -q 'test_write_status_report_directory_sync_uses_no_follow_open' tests/test_downloader.py
grep -q 'Status report directory sync uses no-follow directory opens' README.md
grep -q 'Status report directory sync uses no-follow directory opens' docs/sailboat-pi.md
grep -q 'chartplotter launcher cache directory has permissions' scripts/verify_pi.sh
grep -q 'launcher log cache parent directory is owned by uid' scripts/verify_pi.sh
grep -q 'launcher log cache parent directory has permissions' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock pid file has permissions' scripts/verify_pi.sh
grep -q 'def _fsync_directory' src/noaa_navionics/cli.py
grep -q 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/cli.py
grep -q '_fsync_directory(tracks_dir)' src/noaa_navionics/cli.py
grep -q 'test_gpx_track_directory_sync_uses_no_follow_open' tests/test_downloader.py
grep -q 'charts.package must be one of' src/noaa_navionics/config.py
grep -q 'package can be: state, cgd, region, chart, all' src/noaa_navionics/config.py
grep -q 'package can be: state, cgd, region, chart, all' examples/noaa-navionics.ini
grep -q '/dev/serial/by-id/YOUR_GPS_DEVICE' src/noaa_navionics/config.py
grep -q '/dev/serial/by-id/YOUR_GPS_DEVICE' examples/noaa-navionics.ini
grep -q 'min_free_gb = 2.0' examples/noaa-navionics.ini
grep -q 'UNSAFE_STORAGE_NAMES' src/noaa_navionics/config.py
grep -q 'FORBIDDEN_STORAGE_ROOTS' src/noaa_navionics/config.py
grep -q 'ALLOWED_STORAGE_ROOTS' src/noaa_navionics/config.py
grep -q 'must be a dedicated storage directory' src/noaa_navionics/config.py
grep -q 'must not be under volatile or system directory' src/noaa_navionics/config.py
grep -q 'broad system, volatile, or home directories' README.md
grep -q 'broad system, volatile, or home directories' docs/sailboat-pi.md
grep -q 'mounted storage under `/mnt`, `/media`, or `/run/media`' README.md
grep -q 'mounted storage under `/mnt`, `/media`, or `/run/media`' docs/sailboat-pi.md
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
grep -q 'sock.settimeout(None)' src/noaa_navionics/gps.py
grep -q 'keeps the connected stream unbounded through temporary GPSD quiet periods' README.md
grep -q 'keeps the connected stream unbounded through temporary GPSD quiet periods' docs/sailboat-pi.md
grep -q 'max_duration=seconds' src/noaa_navionics/health.py
grep -q 'max_duration=max_duration' src/noaa_navionics/cli.py
grep -q 'def _positive_float' src/noaa_navionics/cli.py
grep -q 'gps.add_argument("--seconds", type=_positive_float' src/noaa_navionics/cli.py
grep -q 'deadline = time.monotonic() + args.seconds if args.seconds else None' src/noaa_navionics/cli.py
grep -q 'instead of waiting forever when GPSD is connected but no fix arrives' README.md
grep -q 'instead of waiting forever when GPSD is connected but no fix arrives' docs/sailboat-pi.md
grep -q 'def _non_negative_int' src/noaa_navionics/cli.py
grep -q 'def _non_negative_float' src/noaa_navionics/cli.py
grep -q 'chart_dir = Path(args.charts).expanduser() if args.charts else app_config.chart_output' src/noaa_navionics/cli.py
grep -q 'pass `--charts PATH` to check a different mounted chart directory explicitly' README.md
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/config.py
grep -q 'def _write_text_atomic' src/noaa_navionics/config.py
grep -q 'def _prepare_config_parent' src/noaa_navionics/config.py
grep -q 'def _first_symlink_ancestor' src/noaa_navionics/config.py
grep -q 'parent.mkdir(parents=True, mode=0o700, exist_ok=True)' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config directory .* has permissions' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config is a symlink' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config is not a regular file' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config .* is owned by uid' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config .* has permissions' src/noaa_navionics/config.py
grep -q 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/config.py
grep -q 'test_write_default_config_rejects_symlinked_ancestor' tests/test_downloader.py
grep -q 'test_write_default_config_rejects_symlinked_config_file_when_overwriting' tests/test_downloader.py
grep -q 'test_write_default_config_rejects_unsafe_existing_config_when_overwriting' tests/test_downloader.py
grep -q 'test_write_default_config_directory_sync_uses_no_follow_open' tests/test_downloader.py
grep -q 'test_read_config_rejects_symlinked_config_file' tests/test_downloader.py
grep -q 'test_read_config_rejects_symlinked_parent' tests/test_downloader.py
grep -q 'test_read_config_rejects_symlinked_ancestor' tests/test_downloader.py
grep -q 'test_read_config_rejects_symlinked_parent_when_config_missing' tests/test_downloader.py
grep -q 'test_read_config_rejects_nonregular_config_file' tests/test_downloader.py
grep -q 'Config directory sync uses no-follow directory opens' README.md
grep -q 'Config directory sync uses no-follow directory opens' docs/sailboat-pi.md
grep -q 'test_read_config_rejects_writable_config_file' tests/test_downloader.py
grep -q 'symlinked config path components' README.md
grep -q 'symlinked config path components' docs/sailboat-pi.md
grep -q 'os.chmod(tmp_path, 0o600)' src/noaa_navionics/config.py
grep -q 'GPSD skipped: gps.mode' src/noaa_navionics/cli.py
grep -q 'sync-charts requires writable chart storage with enough free space' src/noaa_navionics/cli.py
grep -q 'gpsd_connect_retry=use_gpsd and deadline is None and not args.sample' src/noaa_navionics/cli.py
grep -q 'yielded_fix = True' src/noaa_navionics/cli.py
grep -q 'or yielded_fix' src/noaa_navionics/cli.py
grep -q 'GPSD unavailable at' src/noaa_navionics/cli.py
grep -q 'retrying in' src/noaa_navionics/cli.py
python3 - <<'PY'
from pathlib import Path

text = Path("src/noaa_navionics/cli.py").read_text(encoding="utf-8")
sync_start = text.index('if args.command == "sync-charts":')
sync_end = text.index('if args.command == "search-catalog":')
sync_block = text[sync_start:sync_end]
disk_index = sync_block.index("disk_check = check_disk_space")
mkdir_index = sync_block.index("app_config.chart_output.mkdir")
if mkdir_index < disk_index:
    raise SystemExit("sync-charts must check chart storage before creating chart output")
PY
grep -q 'PACKAGE_KIND_OPTIONS = ("state", "cgd", "region", "chart", "all")' src/noaa_navionics/gui.py
grep -q 'values=PACKAGE_KIND_OPTIONS' src/noaa_navionics/gui.py
grep -q 'def run_configured_preflight' src/noaa_navionics/gui.py
grep -q 'def sync_configured_charts' src/noaa_navionics/gui.py
grep -q 'sync requires a complete onboard chart package' src/noaa_navionics/gui.py
grep -q 'sync requires writable chart storage with enough free space' src/noaa_navionics/gui.py
python3 - <<'PY'
from pathlib import Path

text = Path("src/noaa_navionics/gui.py").read_text(encoding="utf-8")
sync_start = text.index("def sync_configured_charts")
sync_end = text.index("class DownloaderApp")
sync_block = text[sync_start:sync_end]
disk_index = sync_block.index("disk_check = check_disk_space")
mkdir_index = sync_block.index("app_config.chart_output.mkdir")
if mkdir_index < disk_index:
    raise SystemExit("GUI sync must check chart storage before creating chart output")
PY
grep -q 'gpsd_host=app_config.gpsd_host' src/noaa_navionics/gui.py
grep -q 'max_chart_age_days=app_config.max_chart_age_days' src/noaa_navionics/gui.py
grep -q 'min_free_gb=app_config.min_free_gb' src/noaa_navionics/gui.py
grep -q 'track_output=app_config.track_output' src/noaa_navionics/gui.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/opencpn.py
grep -q 'class OpenCPNGPSDConnection' src/noaa_navionics/opencpn.py
grep -q 'def enabled_gpsd_connections' src/noaa_navionics/opencpn.py
grep -q 'def enabled_gpsd_connections_from_values' src/noaa_navionics/opencpn.py
grep -q 'def _is_enabled_gpsd_connection' src/noaa_navionics/opencpn.py
grep -q 'def _write_text_atomic' src/noaa_navionics/opencpn.py
grep -q 'def _write_backup' src/noaa_navionics/opencpn.py
grep -q 'backup_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/opencpn.py
grep -q 'os.fchmod(handle.fileno(), 0o600)' src/noaa_navionics/opencpn.py
grep -q 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/opencpn.py
grep -q 'test_opencpn_backup_uses_no_follow_private_open' tests/test_downloader.py
grep -q 'test_opencpn_directory_sync_uses_no_follow_open' tests/test_downloader.py
grep -q 'OpenCPN backup and directory sync use no-follow opens' README.md
grep -q 'OpenCPN backup and directory sync use no-follow opens' docs/sailboat-pi.md
grep -q 'def _prepare_config_parent' src/noaa_navionics/opencpn.py
grep -q 'def _reject_unsafe_config_path' src/noaa_navionics/opencpn.py
grep -q 'def _validate_chart_directory_for_opencpn' src/noaa_navionics/opencpn.py
grep -q 'def _first_symlink_ancestor' src/noaa_navionics/opencpn.py
grep -q 'OpenCPN chart directory does not exist' src/noaa_navionics/opencpn.py
grep -q 'OpenCPN chart directory path contains a symlink' src/noaa_navionics/opencpn.py
grep -q 'parent.mkdir(parents=True, mode=0o700, exist_ok=True)' src/noaa_navionics/opencpn.py
grep -q 'OpenCPN config path is a symlink' src/noaa_navionics/opencpn.py
grep -q 'OpenCPN config path is not a regular file' src/noaa_navionics/opencpn.py
grep -q 'OpenCPN config path .* has permissions' src/noaa_navionics/opencpn.py
grep -q 'OpenCPN config directory .* has permissions' src/noaa_navionics/opencpn.py
grep -q 'os.chmod(parent, 0o700)' src/noaa_navionics/opencpn.py
grep -q 'expected private 0700' src/noaa_navionics/opencpn.py
grep -q 'expected no group/other write bits' src/noaa_navionics/opencpn.py
grep -q 'unexpected enabled GPSD connection' src/noaa_navionics/health.py
grep -q 'unexpected enabled GPSD connections' scripts/verify_pi.sh
grep -q 'test_check_opencpn_gpsd_config_rejects_extra_enabled_gpsd_source' tests/test_downloader.py
grep -q 'test_configure_gpsd_connection_removes_stale_enabled_gpsd_sources' tests/test_downloader.py
grep -q 'removes stale enabled OpenCPN GPSD endpoints' README.md
grep -q 'removes stale enabled OpenCPN GPSD endpoints' docs/sailboat-pi.md
grep -q 'rejects extra enabled OpenCPN GPSD endpoints' README.md
grep -q 'rejects extra enabled OpenCPN GPSD endpoints' docs/sailboat-pi.md
grep -q 'test_configure_chart_directory_rejects_symlinked_config_ancestor' tests/test_downloader.py
grep -q 'test_configure_chart_directory_rejects_missing_chart_directory' tests/test_downloader.py
grep -q 'test_configure_chart_directory_rejects_non_directory_chart_path' tests/test_downloader.py
grep -q 'test_configure_chart_directory_rejects_symlinked_chart_directory' tests/test_downloader.py
grep -q 'test_configure_chart_directory_tightens_public_config_parent' tests/test_downloader.py
grep -q 'test_read_chart_directories_rejects_symlinked_config_file' tests/test_downloader.py
grep -q 'test_read_chart_directories_rejects_nonregular_config_file' tests/test_downloader.py
grep -q 'test_read_chart_directories_rejects_writable_config_file' tests/test_downloader.py
grep -q 'test_read_data_connections_rejects_writable_config_file' tests/test_downloader.py
grep -q 'symlinked, non-regular, misowned, or group/world-writable OpenCPN config files' README.md
grep -q 'symlinked, non-regular, misowned, or group/world-writable OpenCPN config files' docs/sailboat-pi.md
grep -q 'def _open_trusted_config' src/noaa_navionics/opencpn.py
grep -q 'flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/opencpn.py
grep -q 'OpenCPN chart and GPSD config reads use a no-follow descriptor' README.md
grep -q 'OpenCPN chart and GPSD config reads use a no-follow descriptor' docs/sailboat-pi.md
grep -q 'refuses to register missing, non-directory, or symlinked chart directories' README.md
grep -q 'refuses to register missing, non-directory, or symlinked chart directories' docs/sailboat-pi.md
grep -q 'def _available_backup_path' src/noaa_navionics/opencpn.py
grep -q 'os.open(backup_path, backup_flags, 0o600)' src/noaa_navionics/opencpn.py
grep -q 'os.chmod(tmp_path, 0o600)' src/noaa_navionics/opencpn.py
grep -q 'if active == "failed"' src/noaa_navionics/report.py
grep -q 'Chart Sync Settings' src/noaa_navionics/report.py
grep -q 'Chart Timer Settings' src/noaa_navionics/report.py
grep -q 'Chart Timer Install' src/noaa_navionics/report.py
grep -q 'RandomizedDelayUSec.*30min' src/noaa_navionics/report.py
grep -q 'Track Logger Settings' src/noaa_navionics/report.py
grep -q 'Track Logger Install' src/noaa_navionics/report.py
grep -q 'Track Log' src/noaa_navionics/report.py
grep -q 'def _user_summary' src/noaa_navionics/report.py
grep -q 'loginctl", "show-user"' src/noaa_navionics/report.py
grep -q 'User Linger' src/noaa_navionics/report.py
grep -q 'status report user linger' scripts/verify_pi.sh
grep -q '"User Linger"' scripts/verify_pi.sh
grep -q 'test_service_readiness_checks_include_user_linger' tests/test_downloader.py
grep -q 'test_disk_check_rejects_symlinked_storage_directory' tests/test_downloader.py
grep -q 'test_disk_check_rejects_storage_under_symlinked_parent' tests/test_downloader.py
grep -q 'def _track_log_summary' src/noaa_navionics/report.py
grep -q 'def _read_trusted_gpx_track_file' src/noaa_navionics/report.py
grep -q 'def _first_symlink_ancestor' src/noaa_navionics/report.py
grep -q '"track_output_is_symlink"' src/noaa_navionics/report.py
grep -q '"track_storage_symlink_component"' src/noaa_navionics/report.py
grep -q 'expected real GPX track storage' src/noaa_navionics/report.py
grep -q 'is a symlink, expected a regular GPX track file' src/noaa_navionics/report.py
grep -q 'permissions are .*expected private 0600' src/noaa_navionics/report.py
grep -q 'def _gpx_trackpoint_quality' src/noaa_navionics/report.py
grep -q 'latest_satellites' src/noaa_navionics/report.py
grep -q 'latest_hdop' src/noaa_navionics/report.py
grep -q 'GPX trackpoint is missing satellite or HDOP quality fields' src/noaa_navionics/report.py
grep -q 'GPX trackpoint has non-finite coordinates' src/noaa_navionics/report.py
grep -q 'GPX trackpoint has invalid negative HDOP' src/noaa_navionics/report.py
grep -q 'test_track_log_summary_rejects_non_finite_trackpoint_coordinates' tests/test_downloader.py
grep -q 'test_track_log_summary_rejects_negative_hdop' tests/test_downloader.py
grep -q 'negative GPX HDOP' README.md
grep -q 'negative GPX HDOP' docs/sailboat-pi.md
grep -q 'test_track_log_summary_rejects_missing_trackpoint_quality' tests/test_downloader.py
grep -q 'test_read_trusted_gpx_track_file_rejects_writable_track_file_before_parsing' tests/test_downloader.py
grep -q 'test_track_log_summary_rejects_symlinked_track_output' tests/test_downloader.py
grep -q 'test_track_log_summary_rejects_symlinked_track_output_ancestor' tests/test_downloader.py
grep -q 'Status reports and Pi verification read candidate GPX track files only after a no-follow descriptor' README.md
grep -q 'Status reports and Pi verification read candidate GPX track files only after a no-follow descriptor' docs/sailboat-pi.md
grep -q 'wait_seconds=min(max(float(gps_seconds), 10.0), 60.0)' src/noaa_navionics/report.py
grep -q 'latest_latitude' src/noaa_navionics/report.py
grep -q 'Boot Readiness Settings' src/noaa_navionics/report.py
grep -q 'Boot Readiness Run' src/noaa_navionics/report.py
grep -q 'Boot Readiness Install' src/noaa_navionics/report.py
grep -q '".local/bin/noaa-navionics"' src/noaa_navionics/report.py
grep -q 'test_service_readiness_checks_fail_loaded_command_wrong_path' tests/test_downloader.py
grep -q 'Desktop Startup' src/noaa_navionics/report.py
grep -q 'DEFAULT_AUTOSTART_PATH' src/noaa_navionics/report.py
grep -q 'DEFAULT_LIGHTDM_AUTOLOGIN_PATH' src/noaa_navionics/report.py
grep -q 'Launcher Settings' src/noaa_navionics/report.py
grep -q 'LAUNCHER_ENV_KEYS' src/noaa_navionics/report.py
grep -q 'OpenCPN config path is a symlink' src/noaa_navionics/report.py
grep -q 'OpenCPN config path is not a regular file' src/noaa_navionics/report.py
grep -q 'OpenCPN config directory is a symlink' src/noaa_navionics/report.py
grep -q '"config_symlink_component"' src/noaa_navionics/report.py
grep -q '"uid"' src/noaa_navionics/report.py
grep -q '"mode"' src/noaa_navionics/report.py
grep -q '"directory_uid"' src/noaa_navionics/report.py
grep -q '"directory_mode"' src/noaa_navionics/report.py
grep -q 'test_opencpn_config_summary_rejects_symlinked_config_ancestor' tests/test_downloader.py
grep -q 'test_opencpn_config_summary_rejects_nonregular_config' tests/test_downloader.py
grep -q 'test_opencpn_config_summary_records_owner_and_mode' tests/test_downloader.py
grep -q 'test_opencpn_config_summary_records_public_directory_mode' tests/test_downloader.py
grep -q 'OpenCPN chart and GPSD config reads use a no-follow descriptor' README.md
grep -q 'OpenCPN chart and GPSD config reads use a no-follow descriptor' docs/sailboat-pi.md
grep -q 'launcher environment path is a symlink' src/noaa_navionics/report.py
grep -q 'launcher environment is not a regular file' src/noaa_navionics/report.py
grep -q 'launcher environment is owned by uid' src/noaa_navionics/report.py
grep -q 'malformed launcher environment line' src/noaa_navionics/report.py
grep -q 'unknown launcher environment key' src/noaa_navionics/report.py
grep -q 'launcher environment has permissions.*expected private 0600' src/noaa_navionics/report.py
grep -q 'def _read_launcher_settings_lines' src/noaa_navionics/report.py
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/report.py
grep -q 'test_launcher_settings_summary_rejects_nonregular_environment' tests/test_downloader.py
grep -q 'test_launcher_settings_summary_records_owner_and_mode' tests/test_downloader.py
grep -q 'test_launcher_settings_summary_rejects_public_environment_before_parsing' tests/test_downloader.py
grep -q 'test_launcher_settings_check_fails_misowned_environment' tests/test_downloader.py
grep -q 'key-value file path is a symlink' src/noaa_navionics/report.py
grep -q 'key-value file path is not a regular file' src/noaa_navionics/report.py
grep -q 'key-value file directory is a symlink' src/noaa_navionics/report.py
grep -q 'def _read_key_value_file_lines' src/noaa_navionics/report.py
grep -q 'key-value file path .* has permissions' src/noaa_navionics/report.py
grep -q 'def _key_value_file_integrity_failures' src/noaa_navionics/report.py
grep -q 'is owned by uid' src/noaa_navionics/report.py
grep -q 'has permissions.*expected no group/other write bits' src/noaa_navionics/report.py
grep -q '"path_symlink_component"' src/noaa_navionics/report.py
grep -q 'test_key_value_file_summary_rejects_nonregular_startup_file' tests/test_downloader.py
grep -q 'test_key_value_file_summary_records_owner_and_mode' tests/test_downloader.py
grep -q 'test_key_value_file_summary_rejects_writable_startup_file_before_parsing' tests/test_downloader.py
grep -q 'test_service_readiness_checks_fail_unsafe_desktop_startup_files' tests/test_downloader.py
grep -q 'desktop autostart path is a symlink' src/noaa_navionics/report.py
grep -q 'desktop autostart directory is a symlink' src/noaa_navionics/report.py
grep -q 'desktop autostart path contains a symlink' src/noaa_navionics/report.py
grep -q 'LightDM autologin config path is a symlink' src/noaa_navionics/report.py
grep -q 'LightDM autologin config directory is a symlink' src/noaa_navionics/report.py
grep -q 'LightDM autologin config path contains a symlink' src/noaa_navionics/report.py
grep -q 'NOAA_NAVIONICS_START_ON_FAILED_READINESS is enabled' src/noaa_navionics/report.py
grep -q 'NOAA_NAVIONICS_WARNING_SECONDS' src/noaa_navionics/report.py
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTARTS' src/noaa_navionics/report.py
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTART_DELAY' src/noaa_navionics/report.py
grep -q 'status report launcher settings contain invalid {key}' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTART_DELAY' scripts/verify_pi.sh
grep -q 'optional_non_negative_integer("NOAA_NAVIONICS_WARNING_SECONDS")' scripts/verify_pi.sh
grep -q 'optional_non_negative_integer("NOAA_NAVIONICS_OPENCPN_RESTARTS")' scripts/verify_pi.sh
grep -q 'test_launcher_settings_check_fails_invalid_optional_timing_values' tests/test_downloader.py
grep -q 'test_launcher_settings_summary_records_malformed_environment_lines' tests/test_downloader.py
grep -q 'test_launcher_settings_check_fails_unknown_environment_keys' tests/test_downloader.py
grep -q 'test_launcher_settings_check_fails_malformed_environment_lines' tests/test_downloader.py
grep -q 'test_launcher_settings_summary_rejects_symlinked_environment' tests/test_downloader.py
grep -q 'test_launcher_settings_summary_rejects_symlinked_environment_directory' tests/test_downloader.py
grep -q 'test_launcher_settings_check_fails_symlinked_environment' tests/test_downloader.py
grep -q 'test_launcher_settings_check_fails_symlinked_environment_directory' tests/test_downloader.py
grep -q 'test_key_value_file_summary_rejects_symlinked_startup_file' tests/test_downloader.py
grep -q 'test_key_value_file_summary_rejects_symlinked_startup_directory' tests/test_downloader.py
grep -q 'test_key_value_file_summary_rejects_symlinked_startup_ancestor' tests/test_downloader.py
grep -q 'test_service_readiness_checks_fail_symlinked_desktop_startup_directories' tests/test_downloader.py
grep -q 'test_service_readiness_checks_fail_symlinked_desktop_startup_ancestors' tests/test_downloader.py
grep -q 'test_opencpn_config_summary_rejects_symlinked_config' tests/test_downloader.py
grep -q 'test_opencpn_config_summary_rejects_symlinked_config_directory' tests/test_downloader.py
grep -q 'test_service_readiness_checks_fail_symlinked_desktop_startup_files' tests/test_downloader.py
grep -q 'ExecMainStartTimestampMonotonic' src/noaa_navionics/report.py
grep -q 'USER_UNIT_INSTALL_TARGETS' src/noaa_navionics/report.py
grep -q 'def _install_wanted_by_targets' src/noaa_navionics/report.py
grep -q 'user unit file path is a symlink' src/noaa_navionics/report.py
grep -q 'user unit file directory is a symlink' src/noaa_navionics/report.py
grep -q 'unit file path contains a symlink' src/noaa_navionics/report.py
grep -q 'def _read_user_unit_file_lines' src/noaa_navionics/report.py
grep -q 'user unit file path .* has permissions' src/noaa_navionics/report.py
grep -q 'directory_uid' src/noaa_navionics/report.py
grep -q 'expected no group/other write bits' src/noaa_navionics/report.py
grep -q 'status report {unit} path contains a symlink' scripts/verify_pi.sh
grep -q 'section != "Install"' src/noaa_navionics/report.py
grep -q 'wanted_by' src/noaa_navionics/report.py
grep -q 'test_user_unit_file_summary_rejects_symlinked_unit_file' tests/test_downloader.py
grep -q 'test_user_unit_file_summary_rejects_symlinked_unit_directory' tests/test_downloader.py
grep -q 'test_user_unit_file_summary_rejects_symlinked_unit_ancestor' tests/test_downloader.py
grep -q 'test_user_unit_file_summary_records_owner_and_permissions' tests/test_downloader.py
grep -q 'test_user_unit_file_summary_rejects_writable_unit_file_before_parsing' tests/test_downloader.py
grep -q 'Status reports and Pi verification parse user systemd unit install targets only after a no-follow descriptor read' README.md
grep -q 'Status reports and Pi verification parse user systemd unit install targets only after a no-follow descriptor read' docs/sailboat-pi.md
grep -q 'test_service_readiness_checks_fail_public_unit_file_permissions' tests/test_downloader.py
grep -q 'test_service_readiness_checks_fail_public_unit_directory_permissions' tests/test_downloader.py
grep -q 'test_service_readiness_checks_fail_misowned_unit_file' tests/test_downloader.py
grep -q 'test_service_readiness_checks_fail_symlinked_unit_file_install_target' tests/test_downloader.py
grep -q 'test_service_readiness_checks_fail_symlinked_unit_file_directory' tests/test_downloader.py
grep -q 'test_service_readiness_checks_fail_symlinked_unit_file_ancestor' tests/test_downloader.py
grep -q 'test_app_summary_rejects_symlinked_source_revision' tests/test_downloader.py
grep -q 'test_check_source_revision_rejects_symlinked_revision_on_pi' tests/test_downloader.py
grep -q 'sync-charts requires a complete onboard chart package' src/noaa_navionics/cli.py
grep -q 'wait-network' src/noaa_navionics/cli.py
grep -q 'socket.create_connection' src/noaa_navionics/cli.py
grep -q 'noaa-navionics sync-charts' src/noaa_navionics/report.py
grep -q 'noaa-navionics wait-network' src/noaa_navionics/report.py
grep -q '"ExecStartPre"' src/noaa_navionics/report.py
grep -q 'noaa-navionics log-track' src/noaa_navionics/report.py
grep -q 'noaa-navionics status-report' src/noaa_navionics/report.py
grep -q '"Type": "oneshot"' src/noaa_navionics/report.py
grep -q '"Type": "simple"' src/noaa_navionics/report.py
grep -q '"Restart": "on-failure"' src/noaa_navionics/report.py
grep -q 'GPSD Service' src/noaa_navionics/report.py
grep -q 'Chrony Service' src/noaa_navionics/report.py
grep -q 'def _unit_query_failed' src/noaa_navionics/report.py
grep -q 'enabled_text not in {"static", "generated"}' src/noaa_navionics/report.py
grep -q 'def _systemctl_user_show' src/noaa_navionics/report.py
grep -q 'loaded settings match expected values' src/noaa_navionics/report.py
grep -q 'chart manifest freshness decides navigation readiness' src/noaa_navionics/report.py
grep -q 'missing or disabled chart-refresh service still fails readiness' README.md
grep -q 'missing or disabled chart-refresh service still fails readiness' docs/sailboat-pi.md
grep -q 'user unit path-component integrity' README.md
grep -q 'user unit path-component integrity' docs/sailboat-pi.md
grep -q 'unit-directory owner/mode checks' docs/sailboat-pi.md
grep -q 'status-reported user unit, OpenCPN config, desktop autostart, and LightDM autologin owner/mode' README.md
grep -q "status artifact's user unit, OpenCPN config, desktop autostart, and LightDM autologin owner/mode fields" docs/sailboat-pi.md
grep -q 'requires a root-owned OpenCPN executable and executable directory on Raspberry Pi hardware' README.md
grep -q 'rejects non-root OpenCPN executables or executable directories on Raspberry Pi hardware' docs/sailboat-pi.md
grep -q 'rejects symlinked, misowned, or public cache parents' README.md
grep -q 'rejects symlinked, misowned, or public cache parents' docs/sailboat-pi.md
grep -q '"package_filename"' src/noaa_navionics/report.py
grep -q '"is_symlink"' src/noaa_navionics/report.py
grep -q '"source_revision_path_is_symlink"' src/noaa_navionics/report.py
grep -q '"source_revision_directory_is_symlink"' src/noaa_navionics/report.py
grep -q '"source_revision_symlink_component"' src/noaa_navionics/report.py
grep -q '"source_revision_mode"' src/noaa_navionics/report.py
grep -q 'source revision path is not a regular file' src/noaa_navionics/report.py
grep -q 'source revision path .* has permissions' src/noaa_navionics/report.py
grep -q 'def _read_source_revision_text' src/noaa_navionics/report.py
grep -q 'def _read_source_revision_text' src/noaa_navionics/health.py
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/report.py
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/health.py
grep -q 'source revision directory is a symlink' src/noaa_navionics/report.py
grep -q 'deployed source revision directory is a symlink' src/noaa_navionics/health.py
grep -q 'deployed source revision path is not a regular file' src/noaa_navionics/health.py
grep -q 'deployed source revision path has permissions' src/noaa_navionics/health.py
grep -q 'status report source revision path contains a symlink' scripts/verify_pi.sh
grep -q 'test_app_summary_rejects_symlinked_source_revision_directory' tests/test_downloader.py
grep -q 'test_app_summary_rejects_symlinked_source_revision_ancestor' tests/test_downloader.py
grep -q 'test_app_summary_rejects_nonregular_source_revision' tests/test_downloader.py
grep -q 'test_app_summary_rejects_writable_source_revision' tests/test_downloader.py
grep -q 'test_source_revision_reader_rejects_writable_file' tests/test_downloader.py
grep -q 'test_check_source_revision_rejects_symlinked_revision_directory_on_pi' tests/test_downloader.py
grep -q 'test_check_source_revision_rejects_symlinked_revision_ancestor_on_pi' tests/test_downloader.py
grep -q 'test_check_source_revision_rejects_nonregular_revision_on_pi' tests/test_downloader.py
grep -q 'test_check_source_revision_rejects_writable_revision_on_pi' tests/test_downloader.py
grep -q 'test_health_source_revision_reader_rejects_writable_revision' tests/test_downloader.py
grep -q 'recorded through a symlinked path component' README.md
grep -q 'recorded through a symlinked path component' docs/sailboat-pi.md
grep -q 'Status reports and Pi readiness read that revision through a no-follow descriptor' README.md
grep -q 'Status reports and Pi readiness read that revision through a no-follow descriptor' docs/sailboat-pi.md
grep -q '"directory_is_symlink"' src/noaa_navionics/report.py
grep -q '"manifest_symlink_component"' src/noaa_navionics/report.py
grep -q '"download_path_exists"' src/noaa_navionics/report.py
grep -q '"download_path_symlink_component"' src/noaa_navionics/report.py
grep -q '"download_path_uid"' src/noaa_navionics/report.py
grep -q '"download_path_mode"' src/noaa_navionics/report.py
grep -q '"download_path_error"' src/noaa_navionics/report.py
grep -q '"extract_path_symlink_component"' src/noaa_navionics/report.py
grep -q '"launcher_settings_symlink_component"' src/noaa_navionics/report.py
grep -q 'launcher environment directory is a symlink' src/noaa_navionics/report.py
grep -q 'launcher environment directory is a symlink' scripts/start_chartplotter.sh
grep -q 'status report launcher settings path contains a symlink' scripts/verify_pi.sh
grep -q 'manifest directory is a symlink' src/noaa_navionics/report.py
grep -q 'manifest path is not a regular file' src/noaa_navionics/report.py
grep -q 'test_manifest_summary_rejects_nonregular_manifest' tests/test_downloader.py
grep -q 'test_manifest_summary_records_owner_and_mode' tests/test_downloader.py
grep -q 'status report manifest directory is a symlink' scripts/verify_pi.sh
grep -q 'status report manifest path contains a symlink' scripts/verify_pi.sh
grep -q 'status report manifest download path contains a symlink' scripts/verify_pi.sh
grep -q 'status report manifest extract path contains a symlink' scripts/verify_pi.sh
grep -q 'status report desktop autostart directory is a symlink' scripts/verify_pi.sh
grep -q 'status report LightDM autologin config directory is a symlink' scripts/verify_pi.sh
grep -q 'status report desktop autostart path contains a symlink' scripts/verify_pi.sh
grep -q 'status report LightDM autologin config path contains a symlink' scripts/verify_pi.sh
grep -q 'test_manifest_summary_rejects_symlinked_manifest_directory' tests/test_downloader.py
grep -q 'test_launcher_settings_summary_rejects_symlinked_environment_ancestor' tests/test_downloader.py
grep -q 'test_launcher_settings_check_fails_symlinked_environment_ancestor' tests/test_downloader.py
grep -q 'test_manifest_summary_rejects_symlinked_manifest_ancestor' tests/test_downloader.py
grep -q 'test_manifest_summary_marks_recorded_path_symlink_ancestors' tests/test_downloader.py
grep -q 'test_manifest_summary_marks_nonregular_download_path' tests/test_downloader.py
grep -q 'test_manifest_extract_path_under_symlinked_parent_fails' tests/test_downloader.py
grep -q 'test_manifest_archive_path_under_symlinked_parent_fails' tests/test_downloader.py
grep -q 'desktop autostart, LightDM autologin, and manifest files through no-follow descriptor reads' README.md
grep -q 'desktop autostart, LightDM autologin, and manifest files through no-follow descriptor reads' docs/sailboat-pi.md
grep -q 'readiness report fails if the persisted launcher environment is missing, not regular, owned by the wrong account, group/world-writable' README.md
grep -q 'Missing or invalid launcher timing and fail-open values stop launcher startup' README.md
grep -q 'Status reports parse launcher settings only after a no-follow descriptor read' README.md
grep -q 'Pi verification compares status-reported launcher settings only after a no-follow descriptor read' docs/sailboat-pi.md
grep -q 'def _read_existing_config' src/noaa_navionics/config.py
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config is not a regular file when opened' src/noaa_navionics/config.py
grep -q 'parser.read_file(handle, source=str(path))' src/noaa_navionics/config.py
! grep -q 'parser.read(cfg_path)' src/noaa_navionics/config.py
grep -q 'Onboard config reads use a no-follow descriptor' README.md
grep -q 'Config reads use a no-follow descriptor' docs/sailboat-pi.md
grep -q 'Production Pi verification reads that private launcher environment through a no-follow descriptor before comparing persisted timing and restart policy, sizing strict startup waits, and rejecting fail-open startup' README.md
grep -q 'Production Pi verification reads that private launcher environment through a no-follow descriptor before comparing persisted timing and restart policy, sizing strict startup waits, and rejecting fail-open startup' docs/sailboat-pi.md
grep -q 'Status reports and Pi verification parse desktop autostart and LightDM autologin files only after a no-follow descriptor read' README.md
grep -q 'Pi verification reads the live LightDM autologin session and chrony GPSD refclock config through no-follow descriptors' README.md
grep -q 'Status reports and Pi verification parse user systemd unit install targets only after a no-follow descriptor read' README.md
grep -q 'rejects missing or invalid launcher timing and fail-open values instead of falling back to defaults' docs/sailboat-pi.md
grep -q 'records launcher settings in status reports only after a no-follow descriptor read' docs/sailboat-pi.md
grep -q 'Status reports and Pi verification parse desktop autostart and LightDM autologin files only after a no-follow descriptor read' docs/sailboat-pi.md
grep -q 'Pi verification reads the live LightDM autologin session and chrony GPSD refclock config through no-follow descriptors' docs/sailboat-pi.md
grep -q 'Status reports and Pi verification parse user systemd unit install targets only after a no-follow descriptor read' docs/sailboat-pi.md
grep -q 'launcher environment path-component integrity' docs/sailboat-pi.md
grep -q 'desktop autostart and LightDM autologin path-component integrity' README.md
grep -q 'desktop autostart and LightDM autologin path-component integrity' docs/sailboat-pi.md
grep -q 'user unit path-component integrity' README.md
grep -q 'user unit path-component integrity' docs/sailboat-pi.md
grep -q 'Status reports and Pi verification also reject symlinked, non-regular, writable, or misowned desktop autostart' README.md
grep -q 'Status reports and Pi verification also reject symlinked, non-regular, writable, or misowned desktop autostart' docs/sailboat-pi.md
grep -q '"download_bytes"' src/noaa_navionics/report.py
grep -q '"download_path_is_symlink"' src/noaa_navionics/report.py
grep -q '"extract_path_is_symlink"' src/noaa_navionics/report.py
grep -q 'def _prepare_output_dir' src/noaa_navionics/downloader.py
grep -q 'chart output path contains a symlink' src/noaa_navionics/downloader.py
grep -q 'chart output directory .* expected private 0700' src/noaa_navionics/downloader.py
grep -q 'os.chmod(output_path, 0o700)' src/noaa_navionics/downloader.py
grep -q 'expected no group/other write bits' src/noaa_navionics/health.py
grep -q 'test_download_tightens_chart_output_directory' tests/test_downloader.py
grep -q 'test_disk_check_rejects_public_storage_directory' tests/test_downloader.py
grep -q 'test_download_rejects_symlinked_output_ancestor' tests/test_downloader.py
grep -q 'test_write_manifest_rejects_symlinked_output_ancestor' tests/test_downloader.py
grep -q '"min_free_gb": app_config.min_free_gb' src/noaa_navionics/report.py
grep -q '"extract_path": extract_path' src/noaa_navionics/report.py
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/report.py
grep -q 'def _fsync_directory' src/noaa_navionics/report.py
grep -q 'TimeoutStartSec=2h' systemd/noaa-navionics.service
grep -q 'ExecStartPre=%h/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300' systemd/noaa-navionics.service
grep -q 'RandomizedDelaySec=30min' systemd/noaa-navionics.timer
grep -q 'Type=oneshot' systemd/noaa-navionics.service
grep -q 'Type=oneshot' systemd/noaa-navionics-preflight.service
grep -q 'NoNewPrivileges=true' systemd/noaa-navionics.service
grep -q 'PrivateTmp=true' systemd/noaa-navionics-track.service
grep -q 'ProtectSystem=full' systemd/noaa-navionics.service
grep -q 'ProtectSystem=full' systemd/noaa-navionics-track.service
grep -q 'ProtectSystem=full' systemd/noaa-navionics-preflight.service
grep -q 'UMask=0077' systemd/noaa-navionics.service
grep -q 'UMask=0077' systemd/noaa-navionics-preflight.service
grep -q 'NoNewPrivileges.*yes' src/noaa_navionics/report.py
grep -q 'PrivateTmp.*yes' src/noaa_navionics/report.py
grep -q 'ProtectSystem.*full' src/noaa_navionics/report.py
grep -q 'UMask.*0077' src/noaa_navionics/report.py
python3 - <<'PY'
import sys

sys.path.insert(0, "src")
from noaa_navionics import report

for unit in (
    "noaa-navionics.service",
    "noaa-navionics-track.service",
    "noaa-navionics-preflight.service",
):
    properties = report.USER_UNIT_PROPERTIES[unit]
    if "UMask" not in properties:
        raise SystemExit(f"status report must query loaded {unit} UMask")
    if "ProtectSystem" not in properties:
        raise SystemExit(f"status report must query loaded {unit} ProtectSystem")
PY
grep -q 'FragmentPath' src/noaa_navionics/report.py
grep -q 'def _with_loaded_fragment_path' src/noaa_navionics/report.py
grep -q 'loaded no new privileges' scripts/verify_pi.sh
grep -q 'loaded private tmp' scripts/verify_pi.sh
grep -q 'loaded protected system' scripts/verify_pi.sh
grep -q 'TimeoutStartUSec.*infinity' src/noaa_navionics/report.py
grep -q 'StartLimitIntervalSec=30min' systemd/noaa-navionics-preflight.service
grep -q 'Wants=noaa-navionics-track.service' systemd/noaa-navionics-preflight.service
grep -q 'After=noaa-navionics-track.service' systemd/noaa-navionics-preflight.service
grep -q 'preflight service loaded wants track logger' scripts/verify_pi.sh
grep -q 'preflight service loaded after track logger' scripts/verify_pi.sh
grep -q '"Wants": "noaa-navionics-track.service"' src/noaa_navionics/report.py
grep -q '"After": "noaa-navionics-track.service"' src/noaa_navionics/report.py
grep -q 'StartLimitIntervalUSec.*30min' src/noaa_navionics/report.py
grep -q 'StartLimitBurst=60' systemd/noaa-navionics-preflight.service
grep -q 'Type=simple' systemd/noaa-navionics-track.service
grep -q 'chart service loaded type' scripts/verify_pi.sh
grep -q 'track service loaded type' scripts/verify_pi.sh
grep -q 'preflight service loaded type' scripts/verify_pi.sh
grep -q 'RestartSec=30min' systemd/noaa-navionics.service
grep -q 'StandardOutput=null' systemd/noaa-navionics-track.service
grep -q 'UMask=0077' systemd/noaa-navionics-track.service
grep -q 'chart service private files' scripts/verify_pi.sh
grep -q 'chart service loaded private files' scripts/verify_pi.sh
grep -q 'track service private track files' scripts/verify_pi.sh
grep -q 'track service loaded private track files' scripts/verify_pi.sh
grep -q 'preflight service private files' scripts/verify_pi.sh
grep -q 'preflight service loaded private files' scripts/verify_pi.sh
grep -q 'os.O_WRONLY | os.O_CREAT | os.O_EXCL' src/noaa_navionics/gps.py
grep -q '0o600' src/noaa_navionics/gps.py
grep -q 'mode=0o700' src/noaa_navionics/gps.py
grep -q 'latest_mode' src/noaa_navionics/report.py
grep -q 'tracks_mode' src/noaa_navionics/report.py
grep -q 'permissions are.*expected private 0700' src/noaa_navionics/report.py
grep -q 'permissions are.*expected private 0600' src/noaa_navionics/report.py
grep -q 'private user-owned `0700` tracks directory' README.md
grep -q 'private user-owned `0700` tracks directory' docs/sailboat-pi.md
grep -q 'private `0600` no-follow opens' README.md
grep -q 'private `0600` no-follow opens' docs/sailboat-pi.md
grep -q 'service-created track files also use a private `0077` umask' README.md
grep -q 'service-created track files also use a private `0077` umask' docs/sailboat-pi.md
grep -q 'StartLimitBurst=60' systemd/noaa-navionics-track.service
grep -q -- '--retries "$sync_retries" --retry-delay "$sync_retry_delay"' scripts/provision_sailboat_pi.sh
grep -q 'NOAA_NAVIONICS_GPS_SECONDS=%s' scripts/provision_sailboat_pi.sh
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTARTS=%s' scripts/provision_sailboat_pi.sh
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=%s' scripts/provision_sailboat_pi.sh
grep -q 'mktemp "${launcher_env_dir}/.launcher.env.XXXXXX"' scripts/provision_sailboat_pi.sh
grep -q 'chmod 0600 "$launcher_env_tmp"' scripts/provision_sailboat_pi.sh
grep -q 'sync_paths "$launcher_env_tmp"' scripts/provision_sailboat_pi.sh
test "$(grep -c 'validate_user_install_path "$launcher_env" "chartplotter launcher environment"' scripts/provision_sailboat_pi.sh)" -ge 2
grep -q 'mv -f "$launcher_env_tmp" "$launcher_env"' scripts/provision_sailboat_pi.sh
grep -q 'Provisioning revalidates launcher environment and user-file targets immediately before promotion' README.md
grep -q 'Provisioning revalidates launcher environment and user-file targets immediately before promotion' docs/sailboat-pi.md
grep -q 'Custom --config path does not match the unattended onboard config' scripts/provision_sailboat_pi.sh
grep -q 'Do not run sailboat Pi provisioning as root' scripts/provision_sailboat_pi.sh
grep -q 'pass both --skip-services and --skip-autologin' scripts/provision_sailboat_pi.sh
grep -q -- '--skip-services requires --skip-autologin' scripts/provision_sailboat_pi.sh
grep -q -- '--skip-autologin requires --skip-services' scripts/provision_sailboat_pi.sh
grep -q 'configure_gps_time.sh' scripts/provision_sailboat_pi.sh
grep -q -- '--skip-gps-time' scripts/provision_sailboat_pi.sh
grep -q 'configure_desktop_autologin.sh' scripts/provision_sailboat_pi.sh
grep -q 'noaa-navionics-chartplotter.desktop' scripts/provision_sailboat_pi.sh
grep -q 'install_file_atomic' scripts/provision_sailboat_pi.sh
grep -q 'mktemp "${target_dir}/.${target_name}.XXXXXX"' scripts/provision_sailboat_pi.sh
grep -q 'install -m "$mode" "$source" "$tmp"' scripts/provision_sailboat_pi.sh
grep -q 'sync_paths "$tmp"' scripts/provision_sailboat_pi.sh
test "$(grep -c 'validate_user_install_path "$target" "provisioned user file"' scripts/provision_sailboat_pi.sh)" -ge 2
grep -q 'mv -f "$tmp" "$target"' scripts/provision_sailboat_pi.sh
grep -q 'sync_paths "$target"' scripts/provision_sailboat_pi.sh
grep -q 'install_file_atomic "${repo_root}/systemd/noaa-navionics.service" "$chart_service" 0644' scripts/provision_sailboat_pi.sh
grep -q 'install_file_atomic "${repo_root}/systemd/noaa-navionics.timer" "$chart_timer" 0644' scripts/provision_sailboat_pi.sh
grep -q 'install_file_atomic "${repo_root}/systemd/noaa-navionics-track.service" "$track_service" 0644' scripts/provision_sailboat_pi.sh
grep -q 'install_file_atomic "${repo_root}/systemd/noaa-navionics-preflight.service" "$preflight_service" 0644' scripts/provision_sailboat_pi.sh
grep -q 'install_file_atomic "${repo_root}/templates/noaa-navionics-chartplotter.desktop" "$autostart_entry" 0644' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_units' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_unit_property noaa-navionics.service ProtectSystem full "chart refresh service"' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_unit_property noaa-navionics-track.service ProtectSystem full "track logger service"' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_unit_property noaa-navionics-preflight.service ProtectSystem full "boot readiness service"' scripts/provision_sailboat_pi.sh
grep -q 'The unattended startup services were installed but not enabled' scripts/provision_sailboat_pi.sh
grep -q 'require_user_unit_enabled noaa-navionics.timer "chart refresh timer"' scripts/provision_sailboat_pi.sh
grep -q 'require_user_unit_enabled noaa-navionics-track.service "track logger service"' scripts/provision_sailboat_pi.sh
grep -q 'require_user_unit_enabled noaa-navionics-preflight.service "boot readiness service"' scripts/provision_sailboat_pi.sh
grep -q 'require_user_unit_active noaa-navionics.timer "chart refresh timer"' scripts/provision_sailboat_pi.sh
grep -q 'require_user_unit_active noaa-navionics-track.service "track logger service"' scripts/provision_sailboat_pi.sh
grep -q 'require_user_unit_result_success noaa-navionics-preflight.service "boot readiness service"' scripts/provision_sailboat_pi.sh
grep -q 'Provisioning did not leave .* enabled' scripts/provision_sailboat_pi.sh
grep -q 'Provisioning did not leave .* active' scripts/provision_sailboat_pi.sh
grep -q 'Provisioning did not leave .* with a successful last run' scripts/provision_sailboat_pi.sh
grep -q 'sudo loginctl enable-linger "$USER"' scripts/provision_sailboat_pi.sh
grep -q 'systemctl --user reset-failed noaa-navionics.service noaa-navionics-track.service noaa-navionics-preflight.service' scripts/provision_sailboat_pi.sh
grep -q 'clears stale failed states for the chart refresh, track logger, and boot readiness services' README.md
grep -q 'clears stale failed states for the chart refresh, track logger, and boot readiness services' docs/sailboat-pi.md
grep -q 'confirms systemd loaded the installed user-unit fragments and hardening settings before enabling unattended startup' README.md
grep -q 'confirms systemd loaded the installed user-unit fragments and hardening settings before enabling unattended startup' docs/sailboat-pi.md
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
if status_index < autologin_index:
    raise SystemExit("final status-report must run after desktop autologin is configured")
PY
grep -q 'must be a non-negative integer' scripts/deploy_to_pi.sh
grep -q 'Do not deploy to root@' scripts/deploy_to_pi.sh
grep -q 'usage()' scripts/deploy_to_pi.sh
grep -q 'must be a positive integer' scripts/dock_test_pi.sh
grep -q 'Do not run the dock test as root@' scripts/dock_test_pi.sh
grep -q -- '--require-chartplotter-started' scripts/dock_test_pi.sh
grep -q 'check_remote_noninteractive_reboot_available' scripts/dock_test_pi.sh
grep -q 'remote_reboot_command' scripts/dock_test_pi.sh
grep -q 'validate_remote_reboot_command_trust' scripts/dock_test_pi.sh
grep -q 'Remote reboot command is not in a trusted system directory' scripts/dock_test_pi.sh
grep -q 'Remote reboot command ${item_kind} is owned by uid' scripts/dock_test_pi.sh
grep -q 'Remote reboot command ${item_kind} has permissions' scripts/dock_test_pi.sh
grep -Fq 'readlink -f -- "$reboot_cmd"' scripts/dock_test_pi.sh
grep -q '${remote_system_path} && export PATH && true' scripts/dock_test_pi.sh
grep -q '${remote_system_path} && export PATH && cat /proc/sys/kernel/random/boot_id' scripts/dock_test_pi.sh
grep -q '${remote_system_path} && export PATH && command -v reboot' scripts/dock_test_pi.sh
grep -q '${remote_system_path} && export PATH && sudo -n -l' scripts/dock_test_pi.sh
grep -Fq '${remote_system_path} && export PATH && sudo -n '"'"'$remote_reboot_cmd'"'" scripts/dock_test_pi.sh
grep -q 'sudo -n -l' scripts/dock_test_pi.sh
grep -q "sudo -n '\$remote_reboot_cmd'" scripts/dock_test_pi.sh
! grep -q 'sudo -n reboot' scripts/dock_test_pi.sh
grep -q 'ssh -T "${ssh_batch_options\[@\]}" "$target"' scripts/verify_pi.sh
grep -q 'ServerAliveInterval=30' scripts/deploy_to_pi.sh
grep -q 'ServerAliveInterval=30' scripts/verify_pi.sh
grep -q 'ServerAliveInterval=30' scripts/dock_test_pi.sh
grep -q 'reboot sudo preflight' scripts/dock_test_pi.sh
grep -q 'request_reboot' scripts/dock_test_pi.sh
grep -q 'Failed to request reboot with passwordless sudo' scripts/dock_test_pi.sh
grep -q 'remote_boot_id' scripts/dock_test_pi.sh
grep -q 'boot ID changed after reboot' scripts/dock_test_pi.sh
grep -q -- '--expected-boot-id "$after_boot_id"' scripts/dock_test_pi.sh
grep -q 'verify_args+=("--expected-gps-device" "$device")' scripts/dock_test_pi.sh
grep -q -- '--device is required for the rebooted dock acceptance test' scripts/dock_test_pi.sh
grep -q 'Pre-reboot verification passed; reboot and chartplotter autostart proof were skipped' scripts/dock_test_pi.sh
grep -q -- '--skip-autologin cannot be used for the dock acceptance test' scripts/dock_test_pi.sh
grep -q 'use deploy_to_pi.sh --provision --skip-autologin --skip-services' scripts/dock_test_pi.sh
grep -q 'preflights noninteractive sudo reboot access before deploying or provisioning' README.md
grep -q 'preflights noninteractive sudo reboot access before deploying or provisioning' docs/sailboat-pi.md
grep -q 'root-owned, non-group/world-writable command in a trusted system directory' README.md
grep -q 'root-owned, non-group/world-writable command in a trusted system directory' docs/sailboat-pi.md
grep -q 'pins remote reboot probes and sudo calls to trusted system command directories' README.md
grep -q 'pins remote reboot probes and sudo calls to trusted system command directories' docs/sailboat-pi.md
grep -q 'pins its remote command path to trusted system directories' README.md
grep -q 'pins its remote command path to trusted system directories' docs/sailboat-pi.md
grep -q 'passes that observed post-reboot boot ID into strict verification' README.md
grep -q 'passes that observed post-reboot boot ID into strict verification' docs/sailboat-pi.md
grep -q 'only after rejecting a missing launcher environment, symlinked launcher environment files or path components' README.md
grep -q 'only after rejecting a missing launcher environment, symlinked launcher environment files or path components' docs/sailboat-pi.md

python3 - <<'PY'
from pathlib import Path

text = Path("scripts/dock_test_pi.sh").read_text(encoding="utf-8")
preflight_block_index = text.index('if [[ "$no_reboot" -eq 0 ]]; then')
preflight_call_index = text.index("check_remote_noninteractive_reboot_available", preflight_block_index)
deploy_index = text.index('"${repo_root}/scripts/deploy_to_pi.sh"', preflight_call_index)
if deploy_index < preflight_call_index:
    raise SystemExit("dock test reboot sudo preflight must run before deploy/provision")
PY

install_output="$(mktemp)"
provision_output="$(mktemp)"
gpsd_output="$(mktemp)"
deploy_output="$(mktemp)"
dock_output="$(mktemp)"
verify_output="$(mktemp)"
tmpdir="$(mktemp -d)"
workspace_tmpdir="$(mktemp -d "$repo_root/.check-tmp.XXXXXX")"
trap 'rm -rf "${tmpdir:-}" "${workspace_tmpdir:-}" "$install_output" "$provision_output" "$gpsd_output" "$deploy_output" "$dock_output" "$verify_output"' EXIT

write_test_launcher_env() {
  local home_dir="$1"
  mkdir -p "$home_dir/.config/noaa-navionics"
  printf 'NOAA_NAVIONICS_GPS_SECONDS=60\n' >"$home_dir/.config/noaa-navionics/launcher.env"
  chmod 0600 "$home_dir/.config/noaa-navionics/launcher.env"
}

install_smoke_home="$tmpdir/install-smoke-home"
mkdir -p "$install_smoke_home"
(umask 000; HOME="$install_smoke_home" scripts/install_raspberry_pi.sh --skip-apt --allow-non-pi >"$install_output")
test -x "$install_smoke_home/.local/bin/noaa-navionics"
"$install_smoke_home/.local/bin/noaa-navionics" list-packages >/dev/null
test -f "$install_smoke_home/.config/noaa-navionics/config.ini"
test -d "$install_smoke_home/.local/share/noaa-navionics/venv"
test "$(stat -c '%a' "$install_smoke_home/.local")" = 700
test "$(stat -c '%a' "$install_smoke_home/.local/bin")" = 700
test "$(stat -c '%a' "$install_smoke_home/.local/share")" = 700
test "$(stat -c '%a' "$install_smoke_home/.local/share/noaa-navionics")" = 700
test "$(stat -c '%a' "$install_smoke_home/.config")" = 700
test "$(stat -c '%a' "$install_smoke_home/.config/noaa-navionics")" = 700
test "$(stat -c '%a' "$install_smoke_home/.config/systemd")" = 700
test "$(stat -c '%a' "$install_smoke_home/.config/systemd/user")" = 700
python3 - "$install_smoke_home" <<'PY'
from pathlib import Path
import os
import stat
import sys

home = Path(sys.argv[1]).resolve(strict=True)
venv = home / ".local/share/noaa-navionics/venv"

for relative in [
    ".local/bin/noaa-navionics",
    ".local/bin/noaa-navionics-gui",
]:
    path = home / relative
    if not path.is_symlink():
        raise SystemExit(f"expected command link: {path}")
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(venv.resolve(strict=True))
    except ValueError as exc:
        raise SystemExit(f"command link escaped venv: {path} -> {resolved}") from exc
    mode = resolved.stat().st_mode
    if not stat.S_ISREG(mode) or not mode & stat.S_IXUSR or mode & 0o022:
        raise SystemExit(f"unexpected command target mode: {resolved} {mode & 0o777:04o}")

for relative in [
    ".local/bin/noaa-navionics-start-chartplotter",
    ".local/bin/noaa-navionics-configure-desktop-autologin",
    ".local/bin/noaa-navionics-configure-gps-time",
]:
    path = home / relative
    if path.is_symlink():
        raise SystemExit(f"helper should not be a symlink: {path}")
    mode = path.stat().st_mode
    if not stat.S_ISREG(mode) or not mode & stat.S_IXUSR or mode & 0o022:
        raise SystemExit(f"unexpected helper mode: {path} {mode & 0o777:04o}")
PY
install_expected_revision="$(git rev-parse --short HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  install_expected_revision="${install_expected_revision}-dirty"
fi
test "$(tr -d '[:space:]' <"$install_smoke_home/.local/share/noaa-navionics/source-revision")" = "$install_expected_revision"

unsafe_install_home="$tmpdir/unsafe-install-home"
mkdir -p "$unsafe_install_home/.local/bin"
chmod 0777 "$unsafe_install_home/.local/bin"
set +e
HOME="$unsafe_install_home" scripts/install_raspberry_pi.sh --skip-apt --allow-non-pi >"$install_output" 2>&1
install_code=$?
set -e
chmod 0700 "$unsafe_install_home/.local/bin"
if [[ "$install_code" -eq 0 ]]; then
  cat "$install_output" >&2
  echo "expected install_raspberry_pi.sh to reject an unsafe user command directory" >&2
  exit 1
fi
grep -q 'user command directory parent .* expected no group/other write bits' "$install_output"
test ! -e "$unsafe_install_home/.local/share/noaa-navionics/venv"

install_symlink_home="$tmpdir/install-symlink-home"
install_symlink_target="$tmpdir/install-symlink-real-data"
mkdir -p "$install_symlink_home/.local/share" "$install_symlink_target"
ln -s "$install_symlink_target" "$install_symlink_home/.local/share/noaa-navionics"
set +e
HOME="$install_symlink_home" scripts/install_raspberry_pi.sh --skip-apt --allow-non-pi >"$install_output" 2>&1
install_code=$?
set -e
if [[ "$install_code" -eq 0 ]]; then
  cat "$install_output" >&2
  echo "expected install_raspberry_pi.sh to reject a symlinked data directory" >&2
  exit 1
fi
grep -q 'NOAA Navionics data directory path contains a symlink' "$install_output"
test -L "$install_symlink_home/.local/share/noaa-navionics"

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
grep -q 'strict chartplotter-started mode, verification also requires LightDM to be active' README.md
grep -q 'requires LightDM to be active' docs/sailboat-pi.md
grep -q 'using X11 session LXDE-pi' "$install_output"

unsafe_lightdm_dir="$tmpdir/unsafe-lightdm"
mkdir -p "$unsafe_lightdm_dir/lightdm.conf.d"
chmod 0777 "$unsafe_lightdm_dir/lightdm.conf.d"
set +e
NOAA_NAVIONICS_LIGHTDM_DIR="$unsafe_lightdm_dir" \
  scripts/configure_desktop_autologin.sh --allow-non-pi --dry-run --user "$USER" --session LXDE-pi >"$install_output" 2>&1
desktop_code=$?
set -e
chmod 0755 "$unsafe_lightdm_dir/lightdm.conf.d"
if [[ "$desktop_code" -eq 0 ]]; then
  cat "$install_output" >&2
  echo "expected configure_desktop_autologin.sh to reject an unsafe LightDM autologin directory" >&2
  exit 1
fi
grep -q 'expected no group/other write bits' "$install_output"
! grep -q 'Would write' "$install_output"

lightdm_real_conf="$tmpdir/lightdm-real.conf"
lightdm_link_dir="$tmpdir/lightdm-link"
mkdir -p "$lightdm_link_dir/lightdm.conf.d"
printf '[Seat:*]\n' >"$lightdm_real_conf"
ln -s "$lightdm_real_conf" "$lightdm_link_dir/lightdm.conf.d/50-noaa-navionics-autologin.conf"
set +e
NOAA_NAVIONICS_LIGHTDM_DIR="$lightdm_link_dir" \
  scripts/configure_desktop_autologin.sh --allow-non-pi --dry-run --user "$USER" --session LXDE-pi >"$install_output" 2>&1
desktop_code=$?
set -e
if [[ "$desktop_code" -eq 0 ]]; then
  cat "$install_output" >&2
  echo "expected configure_desktop_autologin.sh to reject a symlinked LightDM autologin config" >&2
  exit 1
fi
grep -q 'LightDM autologin config is a symlink' "$install_output"
! grep -q 'Would write' "$install_output"

lightdm_real_root="$tmpdir/lightdm-real-root"
lightdm_link_root="$tmpdir/lightdm-link-root"
mkdir -p "$lightdm_real_root/lightdm/lightdm.conf.d"
ln -s "$lightdm_real_root" "$lightdm_link_root"
set +e
NOAA_NAVIONICS_LIGHTDM_DIR="$lightdm_link_root/lightdm" \
  scripts/configure_desktop_autologin.sh --allow-non-pi --dry-run --user "$USER" --session LXDE-pi >"$install_output" 2>&1
desktop_code=$?
set -e
if [[ "$desktop_code" -eq 0 ]]; then
  cat "$install_output" >&2
  echo "expected configure_desktop_autologin.sh to reject a symlinked LightDM autologin ancestor" >&2
  exit 1
fi
grep -q 'LightDM config directory path contains a symlink' "$install_output"
grep -q "$lightdm_link_root" "$install_output"
! grep -q 'Would write' "$install_output"

set +e
scripts/provision_sailboat_pi.sh --help >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 0 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/provision_sailboat_pi.sh' "$provision_output"

set +e
scripts/configure_gpsd.sh --help >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -ne 0 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/configure_gpsd.sh' "$gpsd_output"

set +e
scripts/configure_gps_time.sh --help >"$gpsd_output" 2>&1
gps_time_code=$?
set -e
if [[ "$gps_time_code" -ne 0 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gps_time.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/configure_gps_time.sh' "$gpsd_output"

set +e
scripts/configure_desktop_autologin.sh --help >"$install_output" 2>&1
desktop_code=$?
set -e
if [[ "$desktop_code" -ne 0 ]]; then
  cat "$install_output" >&2
  echo "expected configure_desktop_autologin.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/configure_desktop_autologin.sh' "$install_output"

set +e
scripts/verify_pi.sh --help >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 0 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/verify_pi.sh' "$verify_output"

set +e
scripts/dock_test_pi.sh --help >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 0 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/dock_test_pi.sh' "$dock_output"

set +e
scripts/install_raspberry_pi.sh --help >"$install_output" 2>&1
install_code=$?
set -e
if [[ "$install_code" -ne 0 ]]; then
  cat "$install_output" >&2
  echo "expected install_raspberry_pi.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/install_raspberry_pi.sh' "$install_output"

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
scripts/deploy_to_pi.sh --help >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 0 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/deploy_to_pi.sh' "$deploy_output"

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
scripts/deploy_to_pi.sh pi@example.invalid --provision --device /dev/ttyUSB0 >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject volatile GPS device paths with exit 2" >&2
  exit 1
fi
grep -q 'GPS device path is volatile' "$deploy_output"

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
scripts/deploy_to_pi.sh pi@example.invalid /tmp/noaa-navionics --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject volatile remote deployment directories with exit 2" >&2
  exit 1
fi
grep -q 'Remote deployment directory must be under the Pi user' "$deploy_output"

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
scripts/dock_test_pi.sh pi@example.invalid /tmp/noaa-navionics --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject volatile remote deployment directories with exit 2" >&2
  exit 1
fi
grep -q 'Remote deployment directory must be under the Pi user' "$dock_output"

set +e
scripts/dock_test_pi.sh pi@example.invalid --device /dev/ttyUSB0 >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject volatile GPS device paths with exit 2" >&2
  exit 1
fi
grep -q 'GPS device path is volatile' "$dock_output"

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
scripts/deploy_to_pi.sh pi@example.invalid --provision --skip-autologin >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject --skip-autologin without --skip-services with exit 2" >&2
  exit 1
fi
grep -q -- '--skip-autologin requires --skip-services' "$deploy_output"

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
scripts/provision_sailboat_pi.sh --allow-non-pi --dry-run --skip-gpsd --opencpn-restarts nope >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject invalid --opencpn-restarts with exit 2" >&2
  exit 1
fi
grep -q -- '--opencpn-restarts must be a non-negative integer' "$provision_output"

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

unsafe_provision_home="$tmpdir/unsafe-provision-home"
mkdir -p "$unsafe_provision_home/.config/noaa-navionics"
chmod 0777 "$unsafe_provision_home/.config/noaa-navionics"
set +e
HOME="$unsafe_provision_home" \
  scripts/provision_sailboat_pi.sh \
    --allow-non-pi \
    --dry-run \
    --skip-gpsd \
    --skip-sync \
    --skip-services \
    --skip-autologin >"$provision_output" 2>&1
provision_code=$?
set -e
chmod 0700 "$unsafe_provision_home/.config/noaa-navionics"
if [[ "$provision_code" -eq 0 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject an unsafe launcher environment directory" >&2
  exit 1
fi
grep -q 'NOAA Navionics config directory path .* expected no group/other write bits' "$provision_output"
! grep -q 'NOAA_NAVIONICS_GPS_SECONDS' "$provision_output"

provision_link_home="$tmpdir/provision-link-home"
provision_link_target="$tmpdir/provision-link-real.env"
mkdir -p "$provision_link_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=60\n' >"$provision_link_target"
ln -s "$provision_link_target" "$provision_link_home/.config/noaa-navionics/launcher.env"
set +e
HOME="$provision_link_home" \
  scripts/provision_sailboat_pi.sh \
    --allow-non-pi \
    --dry-run \
    --skip-gpsd \
    --skip-sync \
    --skip-services \
    --skip-autologin >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -eq 0 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject a symlinked launcher environment file" >&2
  exit 1
fi
grep -q 'chartplotter launcher environment path contains a symlink' "$provision_output"
! grep -q 'NOAA_NAVIONICS_GPS_SECONDS' "$provision_output"

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
scripts/deploy_to_pi.sh pi@example.invalid --provision --opencpn-restart-delay soon >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject invalid --opencpn-restart-delay with exit 2" >&2
  exit 1
fi
grep -q -- '--opencpn-restart-delay must be a non-negative integer' "$deploy_output"

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
scripts/dock_test_pi.sh pi@example.invalid --skip-deploy >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to require --device for rebooted --skip-deploy acceptance tests with exit 2" >&2
  exit 1
fi
grep -q -- '--device is required for the rebooted dock acceptance test' "$dock_output"

dock_fake_ssh_bin="$tmpdir/dock-fake-ssh-bin"
mkdir -p "$dock_fake_ssh_bin"
cat >"$dock_fake_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"command -v reboot"* ]]; then
  printf '%s\n' "${NOAA_NAVIONICS_FAKE_REBOOT_PATH:-/usr/sbin/reboot}"
  exit 0
fi
if [[ "$args" == *"sh -s -- '/usr/sbin/reboot'"* ]]; then
  if [[ -n "${NOAA_NAVIONICS_FAKE_REBOOT_TRUST_ERROR:-}" ]]; then
    printf '%s\n' "$NOAA_NAVIONICS_FAKE_REBOOT_TRUST_ERROR" >&2
    exit 1
  fi
  exit 0
fi
echo "unexpected fake ssh invocation: $args" >&2
exit 1
EOF
chmod +x "$dock_fake_ssh_bin/ssh"

set +e
NOAA_NAVIONICS_FAKE_REBOOT_PATH=/home/pi/bin/reboot \
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$dock_fake_ssh_bin:$PATH" \
  scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 1 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject user-writable-looking reboot commands with exit 1" >&2
  exit 1
fi
grep -q 'Remote reboot command is not in a trusted system directory: /home/pi/bin/reboot' "$dock_output"

set +e
NOAA_NAVIONICS_FAKE_REBOOT_PATH=/usr/sbin/reboot \
NOAA_NAVIONICS_FAKE_REBOOT_TRUST_ERROR='Remote reboot command file is owned by uid 1000, expected 0: /usr/sbin/reboot' \
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$dock_fake_ssh_bin:$PATH" \
  scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 1 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject non-root reboot commands with exit 1" >&2
  exit 1
fi
grep -q 'Remote reboot command file is owned by uid 1000, expected 0: /usr/sbin/reboot' "$dock_output"

set +e
scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --no-reboot --timeout nope >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh no-reboot smoke test to still reject invalid --timeout with exit 2" >&2
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
scripts/verify_pi.sh --opencpn-restart-delay soon pi@example.invalid >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject invalid --opencpn-restart-delay with exit 2" >&2
  exit 1
fi
grep -q -- '--opencpn-restart-delay must be a non-negative integer' "$verify_output"

set +e
scripts/verify_pi.sh --expected-gps-device >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject missing --expected-gps-device value with exit 2" >&2
  exit 1
fi
grep -q -- '--expected-gps-device requires a value' "$verify_output"

set +e
scripts/verify_pi.sh --expected-gps-device /dev/ttyUSB0 pi@example.invalid >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject volatile expected GPS device paths with exit 2" >&2
  exit 1
fi
grep -q 'GPS device path is volatile' "$verify_output"

set +e
scripts/verify_pi.sh --expected-boot-id >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject missing --expected-boot-id value with exit 2" >&2
  exit 1
fi
grep -q -- '--expected-boot-id requires a value' "$verify_output"

set +e
scripts/verify_pi.sh --expected-boot-id not-a-boot-id pi@example.invalid >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject invalid --expected-boot-id values with exit 2" >&2
  exit 1
fi
grep -q 'boot ID must be the Linux boot_id value' "$verify_output"

untrusted_local_ssh_bin="$tmpdir/untrusted-local-ssh-bin"
mkdir -p "$untrusted_local_ssh_bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$untrusted_local_ssh_bin/ssh"
chmod +x "$untrusted_local_ssh_bin/ssh"
set +e
PATH="$untrusted_local_ssh_bin:$PATH" \
  scripts/verify_pi.sh --allow-dirty pi@example.invalid >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject an untrusted local ssh command with exit 2" >&2
  exit 1
fi
grep -q 'Local ssh command is not in a trusted system directory' "$verify_output"

untrusted_local_git_bin="$tmpdir/untrusted-local-git-bin"
mkdir -p "$untrusted_local_git_bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$untrusted_local_git_bin/git"
chmod +x "$untrusted_local_git_bin/git"
set +e
PATH="$untrusted_local_git_bin:$PATH" \
  scripts/verify_pi.sh --allow-dirty pi@example.invalid >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject an untrusted local git command with exit 2" >&2
  exit 1
fi
grep -q 'Local git command is not in a trusted system directory' "$verify_output"

verify_revision_repo="$tmpdir/verify-revision-repo"
mkdir -p "$verify_revision_repo/scripts" "$verify_revision_repo/bin"
cp scripts/verify_pi.sh "$verify_revision_repo/scripts/verify_pi.sh"
chmod +x "$verify_revision_repo/scripts/verify_pi.sh"
cat >"$verify_revision_repo/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$NOAA_NAVIONICS_FAKE_SSH_ARGS"
exit 0
EOF
chmod +x "$verify_revision_repo/bin/ssh"
git -C "$verify_revision_repo" init -q
git -C "$verify_revision_repo" config user.email check@example.invalid
git -C "$verify_revision_repo" config user.name "NOAA Navionics Check"
git -C "$verify_revision_repo" add scripts/verify_pi.sh bin/ssh
git -C "$verify_revision_repo" commit -q -m initial
verify_clean_revision="$(git -C "$verify_revision_repo" rev-parse --short HEAD)"
verify_fake_ssh_args="$tmpdir/verify-fake-ssh-args"
NOAA_NAVIONICS_FAKE_SSH_ARGS="$verify_fake_ssh_args" \
  NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$verify_revision_repo/bin:$PATH" \
  "$verify_revision_repo/scripts/verify_pi.sh" pi@example.invalid >"$verify_output" 2>&1
grep -Fq "NOAA_NAVIONICS_EXPECTED_REVISION=${verify_clean_revision}" "$verify_fake_ssh_args"
printf '# dirty change\n' >>"$verify_revision_repo/scripts/verify_pi.sh"
set +e
NOAA_NAVIONICS_FAKE_SSH_ARGS="$verify_fake_ssh_args" \
  NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$verify_revision_repo/bin:$PATH" \
  "$verify_revision_repo/scripts/verify_pi.sh" pi@example.invalid >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject a dirty local worktree without --allow-dirty" >&2
  exit 1
fi
grep -q 'Refusing to verify a dirty local worktree as production evidence' "$verify_output"
NOAA_NAVIONICS_FAKE_SSH_ARGS="$verify_fake_ssh_args" \
  NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$verify_revision_repo/bin:$PATH" \
  "$verify_revision_repo/scripts/verify_pi.sh" --allow-dirty pi@example.invalid >"$verify_output" 2>&1
grep -Fq "NOAA_NAVIONICS_EXPECTED_REVISION=${verify_clean_revision}-dirty" "$verify_fake_ssh_args"

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
scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --opencpn-restarts nope >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject invalid --opencpn-restarts with exit 2" >&2
  exit 1
fi
grep -q -- '--opencpn-restarts must be a non-negative integer' "$dock_output"

set +e
scripts/dock_test_pi.sh pi@example.invalid --device /dev/serial/by-id/mock-gps --skip-autologin >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject --skip-autologin for dock acceptance with exit 2" >&2
  exit 1
fi
grep -q -- '--skip-autologin cannot be used for the dock acceptance test' "$dock_output"

set +e
scripts/dock_test_pi.sh pi@example.invalid --device /dev/serial/by-id/mock-gps --no-reboot --skip-autologin >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject --skip-autologin even with --no-reboot with exit 2" >&2
  exit 1
fi
grep -q -- '--skip-autologin cannot be used for the dock acceptance test' "$dock_output"

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

unsafe_chrony_parent="$tmpdir/unsafe-chrony-parent"
mkdir -p "$unsafe_chrony_parent"
chmod 0777 "$unsafe_chrony_parent"
set +e
scripts/configure_gps_time.sh \
  --allow-non-pi \
  --dry-run \
  --chrony-conf "$unsafe_chrony_parent/chrony.conf" >"$gpsd_output" 2>&1
gps_time_code=$?
set -e
chmod 0700 "$unsafe_chrony_parent"
if [[ "$gps_time_code" -eq 0 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gps_time.sh to reject an unsafe chrony config directory" >&2
  exit 1
fi
grep -q 'expected no group/other write bits' "$gpsd_output"
! grep -q 'Would update' "$gpsd_output"

chrony_real_file="$tmpdir/real-chrony.conf"
chrony_link_file="$tmpdir/link-chrony.conf"
printf 'pool time.example iburst\n' >"$chrony_real_file"
ln -s "$chrony_real_file" "$chrony_link_file"
set +e
scripts/configure_gps_time.sh \
  --allow-non-pi \
  --dry-run \
  --chrony-conf "$chrony_link_file" >"$gpsd_output" 2>&1
gps_time_code=$?
set -e
if [[ "$gps_time_code" -eq 0 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gps_time.sh to reject a symlinked chrony config" >&2
  exit 1
fi
grep -q 'Chrony config is a symlink' "$gpsd_output"
! grep -q 'Would update' "$gpsd_output"

chrony_real_root="$tmpdir/real-chrony-root"
chrony_link_root="$tmpdir/link-chrony-root"
mkdir -p "$chrony_real_root/chrony"
printf 'pool time.example iburst\n' >"$chrony_real_root/chrony/chrony.conf"
ln -s "$chrony_real_root" "$chrony_link_root"
set +e
scripts/configure_gps_time.sh \
  --allow-non-pi \
  --dry-run \
  --chrony-conf "$chrony_link_root/chrony/chrony.conf" >"$gpsd_output" 2>&1
gps_time_code=$?
set -e
if [[ "$gps_time_code" -eq 0 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gps_time.sh to reject a symlinked chrony config ancestor" >&2
  exit 1
fi
grep -q 'Chrony config directory is a symlink' "$gpsd_output"
grep -q "$chrony_link_root" "$gpsd_output"
! grep -q 'Would update' "$gpsd_output"

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

cat >"$tmpdir/unsafe-gpsd-config.ini" <<'EOF'
[charts]
output = /tmp
EOF
set +e
scripts/configure_gpsd.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --config "$tmpdir/unsafe-gpsd-config.ini" \
  --device /dev/serial/by-id/mock-gps >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -eq 0 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject an unsafe existing app config before GPSD setup" >&2
  exit 1
fi
grep -q 'charts.output must be a dedicated storage directory' "$gpsd_output"
! grep -q 'Would write /etc/default/gpsd' "$gpsd_output"

unsafe_gpsd_config_parent="$tmpdir/unsafe-gpsd-config-parent"
mkdir -p "$unsafe_gpsd_config_parent"
chmod 0777 "$unsafe_gpsd_config_parent"
set +e
scripts/configure_gpsd.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --config "$unsafe_gpsd_config_parent/config.ini" \
  --device /dev/serial/by-id/mock-gps >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
chmod 0700 "$unsafe_gpsd_config_parent"
if [[ "$gpsd_code" -eq 0 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject an unsafe app config directory before GPSD setup" >&2
  exit 1
fi
grep -q 'expected no group/other write bits' "$gpsd_output"
! grep -q 'Would write /etc/default/gpsd' "$gpsd_output"

gpsd_config_real_parent="$tmpdir/real-gpsd-config-parent"
gpsd_config_link_parent="$tmpdir/link-gpsd-config-parent"
mkdir -p "$gpsd_config_real_parent"
ln -s "$gpsd_config_real_parent" "$gpsd_config_link_parent"
set +e
scripts/configure_gpsd.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --config "$gpsd_config_link_parent/config.ini" \
  --device /dev/serial/by-id/mock-gps >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -eq 0 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject a symlinked app config directory before GPSD setup" >&2
  exit 1
fi
grep -q 'NOAA Navionics config directory is a symlink' "$gpsd_output"
! grep -q 'Would write /etc/default/gpsd' "$gpsd_output"

gpsd_system_real_root="$tmpdir/real-gpsd-system-root"
gpsd_system_link_root="$tmpdir/link-gpsd-system-root"
mkdir -p "$gpsd_system_real_root/default"
ln -s "$gpsd_system_real_root" "$gpsd_system_link_root"
set +e
scripts/configure_gpsd.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --config "$tmpdir/config.ini" \
  --gpsd-conf "$gpsd_system_link_root/default/gpsd" \
  --device /dev/serial/by-id/mock-gps >"$gpsd_output" 2>&1
gpsd_code=$?
set -e
if [[ "$gpsd_code" -eq 0 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gpsd.sh to reject a symlinked GPSD config ancestor" >&2
  exit 1
fi
grep -q 'GPSD config directory is a symlink' "$gpsd_output"
grep -q "$gpsd_system_link_root" "$gpsd_output"
! grep -q 'Would write' "$gpsd_output"

scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --device /dev/serial/by-id/mock-gps \
  --skip-autologin \
  --skip-services \
  --config "$tmpdir/config.ini" \
  --gps-seconds 17 \
  --opencpn-restarts 4 \
  --opencpn-restart-delay 2 \
  --sync-retries 7 \
  --sync-retry-delay 15 >"$provision_output"
grep -q 'NOAA_NAVIONICS_GPS_SECONDS=17' "$provision_output"
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTARTS=4' "$provision_output"
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=2' "$provision_output"
! grep -q 'NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes' "$provision_output"
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

full_provision_home="$tmpdir/provision-full-home"
mkdir -p "$full_provision_home"
chmod 0700 "$full_provision_home"
HOME="$full_provision_home" scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --device /dev/serial/by-id/mock-gps >"$provision_output"
grep -q 'systemctl --user daemon-reload' "$provision_output"
grep -q 'require_loaded_user_unit_property noaa-navionics.service ProtectSystem full' "$provision_output"
grep -q 'require_loaded_user_unit_property noaa-navionics-track.service ProtectSystem full' "$provision_output"
grep -q 'require_loaded_user_unit_property noaa-navionics-preflight.service ProtectSystem full' "$provision_output"
grep -q 'require_user_unit_enabled noaa-navionics.timer' "$provision_output"
grep -q 'require_user_unit_enabled noaa-navionics-track.service' "$provision_output"
grep -q 'require_user_unit_enabled noaa-navionics-preflight.service' "$provision_output"
grep -q 'require_user_unit_active noaa-navionics.timer' "$provision_output"
grep -q 'require_user_unit_active noaa-navionics-track.service' "$provision_output"
grep -q 'require_user_unit_result_success noaa-navionics-preflight.service' "$provision_output"
python3 - "$provision_output" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
guard_index = text.index("require_loaded_user_unit_property noaa-navionics.service ProtectSystem full")
linger_index = text.index("sudo loginctl enable-linger")
enabled_index = text.index("require_user_unit_enabled noaa-navionics.timer")
preflight_restart_index = text.index("systemctl --user restart noaa-navionics-preflight.service")
preflight_success_index = text.index("require_user_unit_result_success noaa-navionics-preflight.service")
if guard_index > linger_index:
    raise SystemExit("loaded user-unit guard must run before user linger and service enablement")
if enabled_index < text.index("systemctl --user enable --now noaa-navionics.timer"):
    raise SystemExit("enabled-state guard must run after timer enablement")
if preflight_success_index < preflight_restart_index:
    raise SystemExit("boot readiness success guard must run after preflight restart")
PY

set +e
scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --device /dev/serial/by-id/mock-gps \
  --skip-autologin >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject --skip-autologin without --skip-services with exit 2" >&2
  exit 1
fi
grep -q -- '--skip-autologin requires --skip-services' "$provision_output"

set +e
scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --device /dev/serial/by-id/mock-gps >"$provision_output" 2>&1
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
  --skip-sync >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject --skip-gpsd without an existing unattended GPS config" >&2
  exit 1
fi
grep -q 'Existing config is required when --skip-gpsd is used with unattended startup' "$provision_output"

skip_gpsd_mismatch_home="$tmpdir/skip-gpsd-mismatch-home"
mkdir -p "$skip_gpsd_mismatch_home/.config/noaa-navionics"
cat >"$skip_gpsd_mismatch_home/.config/noaa-navionics/config.ini" <<EOF
[charts]
package = state
value = AK
output = ~/charts/noaa-enc
extract = yes
keep_zip = yes
force = yes
max_age_days = 30
min_free_gb = 2.0

[gps]
mode = gpsd
device = /dev/serial/by-id/other-gps
baud = 4800
gpsd_host = 127.0.0.1
gpsd_port = 2947

[tracking]
output = ~/charts/noaa-enc
retention_days = 90
EOF
set +e
HOME="$skip_gpsd_mismatch_home" scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --skip-gpsd \
  --device /dev/serial/by-id/mock-gps >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject --skip-gpsd when existing config uses a different requested GPS device" >&2
  exit 1
fi
grep -q 'does not match requested --device' "$provision_output"

skip_gpsd_writable_home="$tmpdir/skip-gpsd-writable-home"
mkdir -p "$skip_gpsd_writable_home/.config/noaa-navionics"
cat >"$skip_gpsd_writable_home/.config/noaa-navionics/config.ini" <<EOF
[charts]
package = state
value = AK
output = ~/charts/noaa-enc
extract = yes
keep_zip = yes
force = yes
max_age_days = 30
min_free_gb = 2.0

[gps]
mode = gpsd
device = /dev/serial/by-id/mock-gps
baud = 4800
gpsd_host = 127.0.0.1
gpsd_port = 2947

[tracking]
output = ~/charts/noaa-enc
retention_days = 90
EOF
chmod 0622 "$skip_gpsd_writable_home/.config/noaa-navionics/config.ini"
set +e
HOME="$skip_gpsd_writable_home" scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --skip-gpsd \
  --skip-sync \
  --device /dev/serial/by-id/mock-gps >"$provision_output" 2>&1
provision_code=$?
set -e
chmod 0600 "$skip_gpsd_writable_home/.config/noaa-navionics/config.ini"
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject --skip-gpsd with a group/world-writable existing config" >&2
  exit 1
fi
grep -q 'Existing GPS config .* has permissions 0622' "$provision_output"

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
  --skip-sync >"$provision_output" 2>&1
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
  --skip-sync >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject --skip-sync without existing complete charts" >&2
  exit 1
fi
grep -q 'Existing chart config is required when --skip-sync is used with unattended startup' "$provision_output"

skip_sync_unsafe_home="$workspace_tmpdir/skip-sync-unsafe-home"
skip_sync_unsafe_charts="$skip_sync_unsafe_home/charts/noaa-enc"
mkdir -p "$skip_sync_unsafe_home/.config/noaa-navionics" "$skip_sync_unsafe_charts/AK_ENCs/US5AK3CM"
cat >"$skip_sync_unsafe_home/.config/noaa-navionics/config.ini" <<EOF
[charts]
package = state
value = AK
output = ~/charts/noaa-enc
extract = yes
keep_zip = no
force = yes
max_age_days = 30
min_free_gb = 0.1

[gps]
mode = gpsd
device = /dev/serial/by-id/mock-gps
baud = 4800
gpsd_host = 127.0.0.1
gpsd_port = 2947

[tracking]
output = ~/charts/noaa-enc
retention_days = 90
EOF
printf 'cell\n' >"$skip_sync_unsafe_charts/AK_ENCs/US5AK3CM/US5AK3CM.000"
python3 - "$skip_sync_unsafe_charts" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import json
import sys

chart_dir = Path(sys.argv[1])
manifest = {
    "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "created_at_source": "download",
    "package": {
        "label": "State AK",
        "filename": "AK_ENCs.zip",
        "url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
    },
    "download": {
        "path": "",
        "url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
        "bytes": 1,
        "sha256": "abc",
    },
    "extract": {
        "path": str(chart_dir / "AK_ENCs"),
        "enc_cell_count": 1,
    },
}
(chart_dir / "noaa-navionics-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
(chart_dir / "noaa-navionics-manifest.json").chmod(0o600)
PY
chmod 0777 "$skip_sync_unsafe_charts"
set +e
HOME="$skip_sync_unsafe_home" scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --skip-sync \
  --device /dev/serial/by-id/mock-gps >"$provision_output" 2>&1
provision_code=$?
set -e
chmod 0700 "$skip_sync_unsafe_charts"
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject --skip-sync with unsafe chart storage permissions" >&2
  exit 1
fi
grep -q 'existing complete charts are required when --skip-sync is used with unattended startup' "$provision_output"
grep -q 'has permissions 0777, expected no group/other write bits' "$provision_output"

scripts/configure_gps_time.sh --allow-non-pi --dry-run --chrony-conf "$tmpdir/chrony.conf" >"$gpsd_output"
grep -q 'refclock SHM 0 offset 0.5 delay 0.1 refid GPS' "$gpsd_output"
grep -q 'Would restart chrony and GPSD' "$gpsd_output"

printf '# BEGIN NOAA Navionics GPS time\nrefclock SHM 0 offset 0.5 delay 0.1 refid GPS\n' >"$tmpdir/bad-chrony.conf"
set +e
scripts/configure_gps_time.sh --allow-non-pi --dry-run --chrony-conf "$tmpdir/bad-chrony.conf" >"$gpsd_output" 2>&1
gps_time_code=$?
set -e
if [[ "$gps_time_code" -eq 0 ]]; then
  cat "$gpsd_output" >&2
  echo "expected configure_gps_time.sh to reject unterminated managed chrony block" >&2
  exit 1
fi
grep -q 'unterminated NOAA Navionics GPS time block' "$gpsd_output"

launcher_symlink_cache_parent_home="$tmpdir/launcher-symlink-cache-parent-home"
launcher_symlink_cache_parent_target="$tmpdir/launcher-symlink-cache-parent-target"
launcher_symlink_cache_parent_output="$tmpdir/launcher-symlink-cache-parent.out"
mkdir -p "$launcher_symlink_cache_parent_home/.local/bin" "$launcher_symlink_cache_parent_target"
ln -s "$launcher_symlink_cache_parent_target" "$launcher_symlink_cache_parent_home/.cache"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_symlink_cache_parent_home/.local/bin/noaa-navionics"
chmod +x "$launcher_symlink_cache_parent_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_symlink_cache_parent_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >"$launcher_symlink_cache_parent_output" 2>&1
launcher_symlink_cache_parent_code=$?
set -e
if [[ "$launcher_symlink_cache_parent_code" -eq 0 ]]; then
  cat "$launcher_symlink_cache_parent_output" >&2
  echo "expected chartplotter launcher to reject a symlinked cache parent directory" >&2
  exit 1
fi
grep -q 'NOAA Navionics cache parent directory is a symlink' "$launcher_symlink_cache_parent_output"
test ! -e "$launcher_symlink_cache_parent_target/noaa-navionics"

launcher_symlink_cache_ancestor_real_home="$tmpdir/launcher-symlink-cache-ancestor-real-home"
launcher_symlink_cache_ancestor_home="$tmpdir/launcher-symlink-cache-ancestor-home"
launcher_symlink_cache_ancestor_output="$tmpdir/launcher-symlink-cache-ancestor.out"
mkdir -p "$launcher_symlink_cache_ancestor_real_home/.local/bin"
ln -s "$launcher_symlink_cache_ancestor_real_home" "$launcher_symlink_cache_ancestor_home"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_symlink_cache_ancestor_real_home/.local/bin/noaa-navionics"
chmod +x "$launcher_symlink_cache_ancestor_real_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_symlink_cache_ancestor_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >"$launcher_symlink_cache_ancestor_output" 2>&1
launcher_symlink_cache_ancestor_code=$?
set -e
if [[ "$launcher_symlink_cache_ancestor_code" -eq 0 ]]; then
  cat "$launcher_symlink_cache_ancestor_output" >&2
  echo "expected chartplotter launcher to reject a symlinked cache ancestor" >&2
  exit 1
fi
grep -q 'NOAA Navionics cache path contains a symlink' "$launcher_symlink_cache_ancestor_output"
grep -q "$launcher_symlink_cache_ancestor_home" "$launcher_symlink_cache_ancestor_output"
test ! -e "$launcher_symlink_cache_ancestor_real_home/.cache/noaa-navionics"

launcher_public_cache_parent_home="$tmpdir/launcher-public-cache-parent-home"
launcher_public_cache_parent_output="$tmpdir/launcher-public-cache-parent.out"
mkdir -p "$launcher_public_cache_parent_home/.local/bin" "$launcher_public_cache_parent_home/.config/noaa-navionics" "$launcher_public_cache_parent_home/.cache"
printf 'NOAA_NAVIONICS_GPS_SECONDS=60\n' >"$launcher_public_cache_parent_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_public_cache_parent_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_public_cache_parent_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\necho fake opencpn\n' >"$tmpdir/opencpn"
chmod +x "$launcher_public_cache_parent_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
chmod 0755 "$launcher_public_cache_parent_home/.cache"
HOME="$launcher_public_cache_parent_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >"$launcher_public_cache_parent_output" 2>&1
test "$(stat -c '%a' "$launcher_public_cache_parent_home/.cache")" = 700
grep -q 'Tightening NOAA Navionics cache parent directory permissions from 755 to 700' "$launcher_public_cache_parent_output"
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_public_cache_parent_home/.cache/noaa-navionics/chartplotter.log"

launcher_symlink_rotated_log_home="$tmpdir/launcher-symlink-rotated-log-home"
launcher_symlink_rotated_log_target="$tmpdir/launcher-symlink-rotated-log-target"
launcher_symlink_rotated_log_output="$tmpdir/launcher-symlink-rotated-log.out"
mkdir -p "$launcher_symlink_rotated_log_home/.local/bin" "$launcher_symlink_rotated_log_home/.cache/noaa-navionics" "$launcher_symlink_rotated_log_target"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_symlink_rotated_log_home/.local/bin/noaa-navionics"
head -c 1048577 /dev/zero >"$launcher_symlink_rotated_log_home/.cache/noaa-navionics/chartplotter.log"
ln -s "$launcher_symlink_rotated_log_target" "$launcher_symlink_rotated_log_home/.cache/noaa-navionics/chartplotter.log.1"
chmod +x "$launcher_symlink_rotated_log_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_symlink_rotated_log_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >"$launcher_symlink_rotated_log_output" 2>&1
launcher_symlink_rotated_log_code=$?
set -e
if [[ "$launcher_symlink_rotated_log_code" -eq 0 ]]; then
  cat "$launcher_symlink_rotated_log_output" >&2
  echo "expected chartplotter launcher to reject a symlinked rotated launcher log" >&2
  exit 1
fi
grep -q 'NOAA Navionics rotated launcher log is a symlink' "$launcher_symlink_rotated_log_output"
test -L "$launcher_symlink_rotated_log_home/.cache/noaa-navionics/chartplotter.log.1"
test ! -e "$launcher_symlink_rotated_log_target/chartplotter.log"

launcher_nonregular_log_home="$tmpdir/launcher-nonregular-log-home"
launcher_nonregular_log_output="$tmpdir/launcher-nonregular-log.out"
mkdir -p "$launcher_nonregular_log_home/.local/bin" "$launcher_nonregular_log_home/.cache/noaa-navionics/chartplotter.log"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_nonregular_log_home/.local/bin/noaa-navionics"
chmod +x "$launcher_nonregular_log_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_nonregular_log_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >"$launcher_nonregular_log_output" 2>&1
launcher_nonregular_log_code=$?
set -e
if [[ "$launcher_nonregular_log_code" -eq 0 ]]; then
  cat "$launcher_nonregular_log_output" >&2
  echo "expected chartplotter launcher to reject a non-regular launcher log" >&2
  exit 1
fi
grep -q 'NOAA Navionics launcher log is not a regular file' "$launcher_nonregular_log_output"
test -d "$launcher_nonregular_log_home/.cache/noaa-navionics/chartplotter.log"

launcher_home="$tmpdir/launcher-home"
mkdir -p "$launcher_home/.local/bin" "$launcher_home/.cache/noaa-navionics" "$launcher_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=17\n' >"$launcher_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_home/.config/noaa-navionics/launcher.env"
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
test "$(stat -c '%a' "$launcher_home/.cache/noaa-navionics")" = 700
test "$(stat -c '%a' "$launcher_home/.cache/noaa-navionics/chartplotter.log")" = 600
test "$(stat -c '%a' "$launcher_home/.cache/noaa-navionics/chartplotter.log.1")" = 600
test ! -e "$launcher_home/.cache/noaa-navionics/chartplotter.launch.lock"
grep -q 'xset s off' "$launcher_home/.cache/noaa-navionics/xset.log"
grep -q 'xset s noblank' "$launcher_home/.cache/noaa-navionics/xset.log"
grep -q 'xset -dpms' "$launcher_home/.cache/noaa-navionics/xset.log"
grep -q -- '--gps-seconds 17' "$launcher_home/.cache/noaa-navionics/noaa.log"
grep -q "Using OpenCPN binary: $tmpdir/opencpn" "$launcher_home/.cache/noaa-navionics/chartplotter.log"

launcher_missing_env_home="$tmpdir/launcher-missing-env-home"
mkdir -p "$launcher_missing_env_home/.local/bin" "$launcher_missing_env_home/.cache/noaa-navionics" "$launcher_missing_env_home/.config/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_missing_env_home/.local/bin/noaa-navionics"
chmod +x "$launcher_missing_env_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_missing_env_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_missing_env_code=$?
set -e
if [[ "$launcher_missing_env_code" -eq 0 ]]; then
  cat "$launcher_missing_env_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a missing launcher environment" >&2
  exit 1
fi
grep -q 'NOAA Navionics launcher environment is missing' "$launcher_missing_env_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_missing_env_home/.cache/noaa-navionics/chartplotter.log"

launcher_symlink_env_home="$tmpdir/launcher-symlink-env-home"
launcher_symlink_env_target="$tmpdir/launcher-symlink-env-target"
mkdir -p "$launcher_symlink_env_home/.local/bin" "$launcher_symlink_env_home/.cache/noaa-navionics" "$launcher_symlink_env_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes\n' >"$launcher_symlink_env_target"
ln -s "$launcher_symlink_env_target" "$launcher_symlink_env_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_symlink_env_home/.local/bin/noaa-navionics"
chmod +x "$launcher_symlink_env_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_symlink_env_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_symlink_env_code=$?
set -e
if [[ "$launcher_symlink_env_code" -eq 0 ]]; then
  cat "$launcher_symlink_env_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a symlinked launcher environment" >&2
  exit 1
fi
grep -q 'NOAA Navionics launcher environment is a symlink' "$launcher_symlink_env_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_symlink_env_home/.cache/noaa-navionics/chartplotter.log"

launcher_symlink_env_dir_home="$tmpdir/launcher-symlink-env-dir-home"
launcher_symlink_env_dir_target="$tmpdir/launcher-symlink-env-dir-target"
mkdir -p "$launcher_symlink_env_dir_home/.local/bin" "$launcher_symlink_env_dir_home/.cache/noaa-navionics" "$launcher_symlink_env_dir_home/.config" "$launcher_symlink_env_dir_target"
printf 'NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes\n' >"$launcher_symlink_env_dir_target/launcher.env"
ln -s "$launcher_symlink_env_dir_target" "$launcher_symlink_env_dir_home/.config/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_symlink_env_dir_home/.local/bin/noaa-navionics"
chmod +x "$launcher_symlink_env_dir_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_symlink_env_dir_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_symlink_env_dir_code=$?
set -e
if [[ "$launcher_symlink_env_dir_code" -eq 0 ]]; then
  cat "$launcher_symlink_env_dir_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a symlinked launcher environment directory" >&2
  exit 1
fi
grep -q 'NOAA Navionics launcher environment directory is a symlink' "$launcher_symlink_env_dir_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_symlink_env_dir_home/.cache/noaa-navionics/chartplotter.log"

launcher_symlink_env_ancestor_home="$tmpdir/launcher-symlink-env-ancestor-home"
launcher_symlink_env_ancestor_target="$tmpdir/launcher-symlink-env-ancestor-target"
mkdir -p "$launcher_symlink_env_ancestor_home/.local/bin" "$launcher_symlink_env_ancestor_home/.cache/noaa-navionics" "$launcher_symlink_env_ancestor_target/noaa-navionics"
printf 'NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes\n' >"$launcher_symlink_env_ancestor_target/noaa-navionics/launcher.env"
ln -s "$launcher_symlink_env_ancestor_target" "$launcher_symlink_env_ancestor_home/.config"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_symlink_env_ancestor_home/.local/bin/noaa-navionics"
chmod +x "$launcher_symlink_env_ancestor_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_symlink_env_ancestor_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_symlink_env_ancestor_code=$?
set -e
if [[ "$launcher_symlink_env_ancestor_code" -eq 0 ]]; then
  cat "$launcher_symlink_env_ancestor_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a symlinked launcher environment ancestor" >&2
  exit 1
fi
grep -q 'NOAA Navionics launcher environment path contains a symlink' "$launcher_symlink_env_ancestor_home/.cache/noaa-navionics/chartplotter.log"
grep -q "$launcher_symlink_env_ancestor_home/.config" "$launcher_symlink_env_ancestor_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_symlink_env_ancestor_home/.cache/noaa-navionics/chartplotter.log"

launcher_public_env_home="$tmpdir/launcher-public-env-home"
mkdir -p "$launcher_public_env_home/.local/bin" "$launcher_public_env_home/.cache/noaa-navionics" "$launcher_public_env_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes\n' >"$launcher_public_env_home/.config/noaa-navionics/launcher.env"
chmod 0644 "$launcher_public_env_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_public_env_home/.local/bin/noaa-navionics"
chmod +x "$launcher_public_env_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_public_env_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_public_env_code=$?
set -e
if [[ "$launcher_public_env_code" -eq 0 ]]; then
  cat "$launcher_public_env_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a non-private launcher environment" >&2
  exit 1
fi
grep -q 'NOAA Navionics launcher environment has permissions 644, expected private 0600' "$launcher_public_env_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_public_env_home/.cache/noaa-navionics/chartplotter.log"

launcher_unknown_env_home="$tmpdir/launcher-unknown-env-home"
mkdir -p "$launcher_unknown_env_home/.local/bin" "$launcher_unknown_env_home/.cache/noaa-navionics" "$launcher_unknown_env_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=17\nNOAA_NAVIONICS_EXTRA=1\n' >"$launcher_unknown_env_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_unknown_env_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_unknown_env_home/.local/bin/noaa-navionics"
chmod +x "$launcher_unknown_env_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_unknown_env_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_unknown_env_code=$?
set -e
if [[ "$launcher_unknown_env_code" -eq 0 ]]; then
  cat "$launcher_unknown_env_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject an unknown launcher environment key" >&2
  exit 1
fi
grep -q 'Unknown launcher environment key' "$launcher_unknown_env_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'NOAA_NAVIONICS_EXTRA' "$launcher_unknown_env_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_unknown_env_home/.cache/noaa-navionics/chartplotter.log"

launcher_malformed_env_home="$tmpdir/launcher-malformed-env-home"
mkdir -p "$launcher_malformed_env_home/.local/bin" "$launcher_malformed_env_home/.cache/noaa-navionics" "$launcher_malformed_env_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS 17\n' >"$launcher_malformed_env_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_malformed_env_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_malformed_env_home/.local/bin/noaa-navionics"
chmod +x "$launcher_malformed_env_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_malformed_env_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_malformed_env_code=$?
set -e
if [[ "$launcher_malformed_env_code" -eq 0 ]]; then
  cat "$launcher_malformed_env_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a malformed launcher environment line" >&2
  exit 1
fi
grep -q 'Malformed launcher environment line' "$launcher_malformed_env_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'NOAA_NAVIONICS_GPS_SECONDS 17' "$launcher_malformed_env_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_malformed_env_home/.cache/noaa-navionics/chartplotter.log"

launcher_missing_gps_seconds_home="$tmpdir/launcher-missing-gps-seconds-home"
mkdir -p "$launcher_missing_gps_seconds_home/.local/bin" "$launcher_missing_gps_seconds_home/.cache/noaa-navionics" "$launcher_missing_gps_seconds_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_WARNING_SECONDS=0\n' >"$launcher_missing_gps_seconds_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_missing_gps_seconds_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_missing_gps_seconds_home/.local/bin/noaa-navionics"
chmod +x "$launcher_missing_gps_seconds_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_missing_gps_seconds_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_missing_gps_seconds_code=$?
set -e
if [[ "$launcher_missing_gps_seconds_code" -eq 0 ]]; then
  cat "$launcher_missing_gps_seconds_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a launcher environment missing GPS seconds" >&2
  exit 1
fi
grep -q 'Missing NOAA_NAVIONICS_GPS_SECONDS' "$launcher_missing_gps_seconds_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_missing_gps_seconds_home/.cache/noaa-navionics/chartplotter.log"

launcher_invalid_timing_home="$tmpdir/launcher-invalid-timing-home"
mkdir -p "$launcher_invalid_timing_home/.local/bin" "$launcher_invalid_timing_home/.cache/noaa-navionics" "$launcher_invalid_timing_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=soon\n' >"$launcher_invalid_timing_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_invalid_timing_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_invalid_timing_home/.local/bin/noaa-navionics"
chmod +x "$launcher_invalid_timing_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_invalid_timing_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_invalid_timing_code=$?
set -e
if [[ "$launcher_invalid_timing_code" -eq 0 ]]; then
  cat "$launcher_invalid_timing_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject invalid launcher timing values" >&2
  exit 1
fi
grep -q 'Invalid NOAA_NAVIONICS_GPS_SECONDS=soon; expected positive integer' "$launcher_invalid_timing_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_invalid_timing_home/.cache/noaa-navionics/chartplotter.log"

launcher_preflight_fail_home="$tmpdir/launcher-preflight-fail-home"
mkdir -p "$launcher_preflight_fail_home/.local/bin" "$launcher_preflight_fail_home/.cache/noaa-navionics" "$launcher_preflight_fail_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=60\nNOAA_NAVIONICS_WARNING_SECONDS=0\nNOAA_NAVIONICS_READINESS_ATTEMPTS=1\n' >"$launcher_preflight_fail_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_preflight_fail_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 1\n' >"$launcher_preflight_fail_home/.local/bin/noaa-navionics"
chmod +x "$launcher_preflight_fail_home/.local/bin/noaa-navionics"
set +e
HOME="$launcher_preflight_fail_home" NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes NOAA_NAVIONICS_READINESS_ATTEMPTS=2 PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_preflight_code=$?
set -e
if [[ "$launcher_preflight_code" -eq 0 ]]; then
  cat "$launcher_preflight_fail_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to fail closed when readiness fails" >&2
  exit 1
fi
grep -q 'NOAA Navionics preflight failed on attempt 1/1' "$launcher_preflight_fail_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Readiness warning timeout is 0 seconds' "$launcher_preflight_fail_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Not starting OpenCPN automatically because readiness failed' "$launcher_preflight_fail_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_preflight_fail_home/.cache/noaa-navionics/chartplotter.log"

launcher_preflight_override_home="$tmpdir/launcher-preflight-override-home"
mkdir -p "$launcher_preflight_override_home/.local/bin" "$launcher_preflight_override_home/.cache/noaa-navionics" "$launcher_preflight_override_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=60\nNOAA_NAVIONICS_WARNING_SECONDS=0\nNOAA_NAVIONICS_READINESS_ATTEMPTS=1\nNOAA_NAVIONICS_START_ON_FAILED_READINESS=yes\n' >"$launcher_preflight_override_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_preflight_override_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 1\n' >"$launcher_preflight_override_home/.local/bin/noaa-navionics"
chmod +x "$launcher_preflight_override_home/.local/bin/noaa-navionics"
HOME="$launcher_preflight_override_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
grep -q 'Starting OpenCPN despite failed readiness because NOAA_NAVIONICS_START_ON_FAILED_READINESS is enabled' "$launcher_preflight_override_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_preflight_override_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'OpenCPN exited with status 0' "$launcher_preflight_override_home/.cache/noaa-navionics/chartplotter.log"

launcher_retry_home="$tmpdir/launcher-retry-home"
mkdir -p "$launcher_retry_home/.local/bin" "$launcher_retry_home/.cache/noaa-navionics" "$launcher_retry_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=60\nNOAA_NAVIONICS_READINESS_ATTEMPTS=2\nNOAA_NAVIONICS_READINESS_RETRY_DELAY=0\n' >"$launcher_retry_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_retry_home/.config/noaa-navionics/launcher.env"
cat >"$launcher_retry_home/.local/bin/noaa-navionics" <<'EOF'
#!/usr/bin/env bash
count_file="$HOME/.cache/noaa-navionics/readiness-count"
count=0
if [[ -r "$count_file" ]]; then
  read -r count <"$count_file" || count=0
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [[ "$count" -lt 2 ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$launcher_retry_home/.local/bin/noaa-navionics"
HOME="$launcher_retry_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
grep -q 'NOAA Navionics preflight failed on attempt 1/2' "$launcher_retry_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Retrying readiness in 0s' "$launcher_retry_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'NOAA Navionics preflight passed on attempt 2/2' "$launcher_retry_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_retry_home/.cache/noaa-navionics/chartplotter.log"
test "$(cat "$launcher_retry_home/.cache/noaa-navionics/readiness-count")" -eq 2

launcher_opencpn_restart_home="$tmpdir/launcher-opencpn-restart-home"
mkdir -p "$launcher_opencpn_restart_home/.local/bin" "$launcher_opencpn_restart_home/.cache/noaa-navionics" "$launcher_opencpn_restart_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=60\nNOAA_NAVIONICS_OPENCPN_RESTARTS=2\nNOAA_NAVIONICS_OPENCPN_RESTART_DELAY=0\n' >"$launcher_opencpn_restart_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_opencpn_restart_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_opencpn_restart_home/.local/bin/noaa-navionics"
cat >"$tmpdir/opencpn" <<'EOF'
#!/usr/bin/env bash
count_file="$HOME/.cache/noaa-navionics/opencpn-count"
count=0
if [[ -r "$count_file" ]]; then
  read -r count <"$count_file" || count=0
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [[ "$count" -lt 3 ]]; then
  exit 7
fi
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
chmod +x "$launcher_opencpn_restart_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
HOME="$launcher_opencpn_restart_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
test "$(cat "$launcher_opencpn_restart_home/.cache/noaa-navionics/opencpn-count")" -eq 3
grep -q 'Restarting OpenCPN after nonzero exit status 7 (restart 1/2) in 0s.' "$launcher_opencpn_restart_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Restarting OpenCPN after nonzero exit status 7 (restart 2/2) in 0s.' "$launcher_opencpn_restart_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'OpenCPN exited cleanly; not restarting.' "$launcher_opencpn_restart_home/.cache/noaa-navionics/chartplotter.log"

launcher_fail_home="$tmpdir/launcher-fail-home"
mkdir -p "$launcher_fail_home/.local/bin" "$launcher_fail_home/.cache/noaa-navionics"
write_test_launcher_env "$launcher_fail_home"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_fail_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/xset"
chmod +x "$launcher_fail_home/.local/bin/noaa-navionics" "$tmpdir/xset"
HOME="$launcher_fail_home" DISPLAY=:99 PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
test ! -e "$launcher_fail_home/.cache/noaa-navionics/chartplotter.launch.lock"
grep -q 'Display session found, but 3 xset command(s) failed' "$launcher_fail_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_fail_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'OpenCPN exited with status 0' "$launcher_fail_home/.cache/noaa-navionics/chartplotter.log"

launcher_symlink_lock_home="$tmpdir/launcher-symlink-lock-home"
launcher_symlink_lock_target="$tmpdir/launcher-symlink-lock-real"
mkdir -p "$launcher_symlink_lock_home/.local/bin" "$launcher_symlink_lock_home/.cache/noaa-navionics" "$launcher_symlink_lock_target"
ln -s "$launcher_symlink_lock_target" "$launcher_symlink_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_symlink_lock_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nprintf "opencpn launched\\n" >"$HOME/.cache/noaa-navionics/opencpn-started"\nexit 0\n' >"$tmpdir/opencpn"
chmod +x "$launcher_symlink_lock_home/.local/bin/noaa-navionics" "$tmpdir/opencpn"
set +e
HOME="$launcher_symlink_lock_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_symlink_lock_code=$?
set -e
if [[ "$launcher_symlink_lock_code" -eq 0 ]]; then
  cat "$launcher_symlink_lock_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a symlinked launch lock" >&2
  exit 1
fi
test -L "$launcher_symlink_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
test ! -e "$launcher_symlink_lock_home/.cache/noaa-navionics/opencpn-started"
grep -q 'chartplotter launcher lock path contains a symlink' "$launcher_symlink_lock_home/.cache/noaa-navionics/chartplotter.log"

launcher_lock_home="$tmpdir/launcher-lock-home"
mkdir -p "$launcher_lock_home/.local/bin" "$launcher_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
write_test_launcher_env "$launcher_lock_home"
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
write_test_launcher_env "$launcher_dirty_lock_home"
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

launcher_symlink_child_lock_home="$tmpdir/launcher-symlink-child-lock-home"
launcher_symlink_child_target="$tmpdir/launcher-symlink-child-target"
mkdir -p "$launcher_symlink_child_lock_home/.local/bin" "$launcher_symlink_child_lock_home/.cache/noaa-navionics/chartplotter.launch.lock" "$launcher_symlink_child_target"
printf '%s\n' "$$" >"$launcher_symlink_child_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
ln -s "$launcher_symlink_child_target" "$launcher_symlink_child_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/extra-link"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_symlink_child_lock_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\nprintf "fake opencpn start\\n" >"$HOME/.cache/noaa-navionics/opencpn-started"\n' >"$tmpdir/opencpn"
chmod +x "$launcher_symlink_child_lock_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
set +e
HOME="$launcher_symlink_child_lock_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_symlink_child_lock_code=$?
set -e
if [[ "$launcher_symlink_child_lock_code" -eq 0 ]]; then
  cat "$launcher_symlink_child_lock_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject stale lock cleanup with symlink debris" >&2
  exit 1
fi
test -L "$launcher_symlink_child_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/extra-link"
test -d "$launcher_symlink_child_target"
test ! -e "$launcher_symlink_child_lock_home/.cache/noaa-navionics/opencpn-started"
grep -q 'chartplotter launcher lock path contains a symlink; leaving it in place' "$launcher_symlink_child_lock_home/.cache/noaa-navionics/chartplotter.log"

launcher_old_boot_lock_home="$tmpdir/launcher-old-boot-lock-home"
mkdir -p "$launcher_old_boot_lock_home/.local/bin" "$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
write_test_launcher_env "$launcher_old_boot_lock_home"
bash -c 'while :; do sleep 1; done' start_chartplotter.sh &
old_boot_launcher_pid=$!
printf '%s\n' "$old_boot_launcher_pid" >"$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
printf 'previous-boot\n' >"$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/boot_id"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_old_boot_lock_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\necho fake opencpn\n' >"$tmpdir/opencpn"
chmod +x "$launcher_old_boot_lock_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
HOME="$launcher_old_boot_lock_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
kill "$old_boot_launcher_pid" 2>/dev/null || true
wait "$old_boot_launcher_pid" 2>/dev/null || true
test ! -e "$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
grep -q 'Launcher lock is from a previous boot; treating lock as stale.' "$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Removing stale chartplotter launcher lock' "$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'OpenCPN exited with status 0' "$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.log"

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

launcher_live_lock_home="$tmpdir/launcher-live-lock-home"
mkdir -p "$launcher_live_lock_home/.local/bin" "$launcher_live_lock_home/.cache/noaa-navionics"
write_test_launcher_env "$launcher_live_lock_home"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_live_lock_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nprintf "fake opencpn start\\n" >>"$HOME/.cache/noaa-navionics/opencpn-starts.log"\nsleep 2\n' >"$tmpdir/opencpn"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
chmod +x "$launcher_live_lock_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
HOME="$launcher_live_lock_home" NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null &
live_launcher_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [[ -r "$launcher_live_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid" ]]; then
    break
  fi
  sleep 0.1
done
test -r "$launcher_live_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
test -r "$launcher_live_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/boot_id"
launcher_live_lock_pid="$(cat "$launcher_live_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid")"
if tr '\0' '\n' <"/proc/${launcher_live_lock_pid}/environ" 2>/dev/null | grep -q '^NOAA_NAVIONICS_'; then
  tr '\0' '\n' <"/proc/${launcher_live_lock_pid}/environ" >&2 || true
  echo "expected chartplotter launcher process environment to be sanitized before taking the launch lock" >&2
  exit 1
fi
test "$(stat -c '%a' "$launcher_live_lock_home/.cache/noaa-navionics")" = 700
test "$(stat -c '%a' "$launcher_live_lock_home/.cache/noaa-navionics/chartplotter.launch.lock")" = 700
test "$(stat -c '%a' "$launcher_live_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid")" = 600
test "$(stat -c '%a' "$launcher_live_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/boot_id")" = 600
if [[ -r /proc/sys/kernel/random/boot_id ]]; then
  test "$(cat "$launcher_live_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/boot_id")" = "$(cat /proc/sys/kernel/random/boot_id)"
fi
HOME="$launcher_live_lock_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
wait "$live_launcher_pid"
test ! -e "$launcher_live_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
test "$(grep -c '^fake opencpn start$' "$launcher_live_lock_home/.cache/noaa-navionics/opencpn-starts.log")" -eq 1
grep -q 'Another NOAA Navionics chartplotter launcher is already running' "$launcher_live_lock_home/.cache/noaa-navionics/chartplotter.log"

launcher_replaced_lock_home="$tmpdir/launcher-replaced-lock-home"
mkdir -p "$launcher_replaced_lock_home/.local/bin" "$launcher_replaced_lock_home/.cache/noaa-navionics"
write_test_launcher_env "$launcher_replaced_lock_home"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_replaced_lock_home/.local/bin/noaa-navionics"
cat >"$tmpdir/opencpn" <<'EOF'
#!/usr/bin/env bash
lock="$HOME/.cache/noaa-navionics/chartplotter.launch.lock"
target="$HOME/.cache/noaa-navionics/replaced-lock-target"
mkdir -p "$target"
printf 'keep pid\n' >"$target/pid"
printf 'keep boot\n' >"$target/boot_id"
rm -rf "$lock"
ln -s "$target" "$lock"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
chmod +x "$launcher_replaced_lock_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
HOME="$launcher_replaced_lock_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
test -L "$launcher_replaced_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
test "$(cat "$launcher_replaced_lock_home/.cache/noaa-navionics/replaced-lock-target/pid")" = "keep pid"
test "$(cat "$launcher_replaced_lock_home/.cache/noaa-navionics/replaced-lock-target/boot_id")" = "keep boot"
grep -q 'chartplotter launcher lock path became unsafe; leaving it in place' "$launcher_replaced_lock_home/.cache/noaa-navionics/chartplotter.log"

launcher_duplicate_home="$tmpdir/launcher-duplicate-home"
mkdir -p "$launcher_duplicate_home/.local/bin" "$launcher_duplicate_home/.cache/noaa-navionics"
write_test_launcher_env "$launcher_duplicate_home"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_duplicate_home/.local/bin/noaa-navionics"
bash -c 'while :; do sleep 1; done' opencpn &
duplicate_opencpn_pid=$!
printf '#!/usr/bin/env bash\nprintf "%%s\\n" '"$duplicate_opencpn_pid"'\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\necho "opencpn should not be launched" >&2\nexit 9\n' >"$tmpdir/opencpn"
chmod +x "$launcher_duplicate_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
HOME="$launcher_duplicate_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
kill "$duplicate_opencpn_pid" 2>/dev/null || true
wait "$duplicate_opencpn_pid" 2>/dev/null || true
grep -q 'OpenCPN is already running' "$launcher_duplicate_home/.cache/noaa-navionics/chartplotter.log"

launcher_empty_pgrep_home="$tmpdir/launcher-empty-pgrep-home"
mkdir -p "$launcher_empty_pgrep_home/.local/bin" "$launcher_empty_pgrep_home/.cache/noaa-navionics"
write_test_launcher_env "$launcher_empty_pgrep_home"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_empty_pgrep_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\necho fake opencpn\n' >"$tmpdir/opencpn"
chmod +x "$launcher_empty_pgrep_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
HOME="$launcher_empty_pgrep_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
grep -q 'Launching OpenCPN with ENC processing.' "$launcher_empty_pgrep_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'OpenCPN exited with status 0' "$launcher_empty_pgrep_home/.cache/noaa-navionics/chartplotter.log"
grep -q 'OpenCPN exited cleanly; not restarting.' "$launcher_empty_pgrep_home/.cache/noaa-navionics/chartplotter.log"

echo "All checks passed."
