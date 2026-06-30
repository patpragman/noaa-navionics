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
  scripts/pre_trip_prepare_pi.sh \
  scripts/post_trip_collect_pi.sh \
  scripts/pre_departure_check_pi.sh \
  scripts/check_pi_status.sh \
  scripts/refresh_pi_charts.sh \
  scripts/collect_pi_support_bundle.sh \
  scripts/verify_pi_recovery_exports.sh \
  scripts/restore_pi_recovery_user_data.sh \
  scripts/shutdown_pi_safely.sh \
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
grep -q -- '--gps-seconds-from-launcher-env %h/.config/noaa-navionics/launcher.env' systemd/noaa-navionics-preflight.service
! grep -q '^Environment=' systemd/noaa-navionics-preflight.service
! grep -q '^EnvironmentFile=' systemd/noaa-navionics-preflight.service
grep -q 'def _gps_seconds_from_launcher_env' src/noaa_navionics/cli.py
grep -q 'test_status_report_rejects_symlinked_launcher_environment_for_gps_wait' tests/test_downloader.py
grep -q 'test_status_report_rejects_unknown_launcher_environment_key_for_gps_wait' tests/test_downloader.py
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
grep -q 'NOAA Navionics cache parent directory became a symlink after permission tightening' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics cache parent directory has permissions .* expected private 0700' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics cache directory is owned by uid' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics cache directory became a symlink after creation' scripts/start_chartplotter.sh
grep -q 'Tightening NOAA Navionics cache directory permissions' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics cache directory became a symlink after permission tightening' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics cache directory has permissions .* expected private 0700' scripts/start_chartplotter.sh
grep -q 'chmod 0700 "$cache_dir"' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher log is not a regular file' scripts/start_chartplotter.sh
grep -q 'os.O_WRONLY | os.O_APPEND | os.O_CREAT | nofollow' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher log is owned by uid' scripts/start_chartplotter.sh
grep -q 'os.fchmod(fd, 0o600)' scripts/start_chartplotter.sh
grep -q 'opened = os.fstat(fd)' scripts/start_chartplotter.sh
grep -q 'stat.S_ISREG(opened.st_mode)' scripts/start_chartplotter.sh
grep -q 'stat.S_ISLNK(initial.st_mode)' scripts/start_chartplotter.sh
! grep -q 'with path.open("rb") as handle' scripts/start_chartplotter.sh
grep -q 'write_private_file("pid", pid_text)' scripts/start_chartplotter.sh
grep -q 'write_private_file("boot_id", boot_id_text)' scripts/start_chartplotter.sh
grep -q 'read_launcher_lock_file()' scripts/start_chartplotter.sh
grep -q 'read_launcher_lock_file boot_id "chartplotter launcher lock boot ID"' scripts/start_chartplotter.sh
grep -q 'read_launcher_lock_file pid "chartplotter launcher lock pid"' scripts/start_chartplotter.sh
grep -q 'os.open(name, flags, 0o600, dir_fd=dir_fd)' scripts/start_chartplotter.sh
grep -q 'lock_mode = lock_stat.st_mode & 0o777' scripts/start_chartplotter.sh
grep -q 'expected private 0700: {lock}' scripts/start_chartplotter.sh
grep -q 'expected private 0600' scripts/start_chartplotter.sh
grep -q 'chartplotter launcher lock directory has permissions' scripts/start_chartplotter.sh
grep -q 'requires existing launcher lock directories to be private `0700` and PID/boot-ID files to be private `0600` before trusting them' README.md
grep -q 'requires existing launcher lock directories to be private `0700` and PID/boot-ID files to be private `0600` before trusting them' docs/sailboat-pi.md
grep -q 'writes and reads lock PID and boot-ID files through no-follow descriptor opens' README.md
grep -q 'writes and reads lock PID and boot-ID files through no-follow descriptor opens' docs/sailboat-pi.md
! grep -q 'chmod 0600 "${launcher_lock_dir}/pid"' scripts/start_chartplotter.sh
! grep -Fq '>"${launcher_lock_dir}/pid"' scripts/start_chartplotter.sh
! grep -Fq '>"${launcher_lock_dir}/boot_id"' scripts/start_chartplotter.sh
! grep -q 'read -r owner_pid <"${launcher_lock_dir}/pid"' scripts/start_chartplotter.sh
! grep -q 'read -r lock_boot_id <"${launcher_lock_dir}/boot_id"' scripts/start_chartplotter.sh
grep -q 'check_tkinter_available' scripts/verify_pi.sh
grep -q 'Tkinter readiness warning support' scripts/verify_pi.sh
grep -q 'python3-tk' scripts/install_raspberry_pi.sh
grep -q 'OpenCPN executable directory is owned by uid' scripts/start_chartplotter.sh
grep -q 'acquire_launcher_lock' scripts/start_chartplotter.sh
grep -q 'release_launcher_lock' scripts/start_chartplotter.sh
grep -q 'process_looks_like_launcher' scripts/start_chartplotter.sh
grep -q 'Path(f"/proc/{pid}/cmdline").read_bytes()' scripts/start_chartplotter.sh
grep -Fq 'data.split(b"\0")' scripts/start_chartplotter.sh
grep -q 'surrogateescape' scripts/start_chartplotter.sh
grep -q 'parses live `/proc` state and NUL-delimited process arguments' README.md
grep -q 'parses live `/proc` state and NUL-delimited process arguments' docs/sailboat-pi.md
! grep -Fq 'cmdline="$(tr '\''\0'\'' '\'' '\'' <"/proc/${pid}/cmdline"' scripts/start_chartplotter.sh
! grep -q 'done <"/proc/${pid}/cmdline"' scripts/start_chartplotter.sh
grep -q 'current_boot_id' scripts/start_chartplotter.sh
grep -q 'validate_launcher_lock_path' scripts/start_chartplotter.sh
grep -q 'launcher_lock_path_safe_for_cleanup' scripts/start_chartplotter.sh
grep -q 'chartplotter launcher lock path contains a symlink' scripts/start_chartplotter.sh
grep -q 'chartplotter launcher lock path became unsafe; leaving it in place' scripts/start_chartplotter.sh
grep -q 'validate_launcher_env_path' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment is missing' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment is a symlink' scripts/start_chartplotter.sh
grep -q 'read_trusted_launcher_env' scripts/start_chartplotter.sh
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment directory is a symlink' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment path contains a symlink' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment directory is owned by uid' scripts/start_chartplotter.sh
grep -q 'NOAA Navionics launcher environment directory has permissions' scripts/start_chartplotter.sh
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
grep -q 'refuses symlinked, misowned, non-private lock metadata, or group/world-writable stale lock debris' README.md
grep -q 'refuses symlinked, misowned, non-private lock metadata, or group/world-writable stale lock debris' docs/sailboat-pi.md
grep -q 'appends output to the private `0600` file `~/.cache/noaa-navionics/chartplotter.log` only after opening it through a no-follow descriptor' README.md
grep -q 'through a no-follow descriptor, rotates and syncs that log after 1 MB' docs/sailboat-pi.md
grep -q 'revalidates both cache directories after creation or tightening before creating runtime files' README.md
grep -q 'revalidates both cache directories after creation or tightening before creating runtime files' docs/sailboat-pi.md
! grep -q 'rm -rf "$launcher_lock_dir"' scripts/start_chartplotter.sh
grep -Fq 'sync_paths "$launcher_lock_dir" || true' scripts/start_chartplotter.sh
grep -q 'resolve_opencpn_binary' scripts/start_chartplotter.sh
grep -q 'validate_opencpn_binary_candidate' scripts/start_chartplotter.sh
grep -q 'is_raspberry_pi' scripts/start_chartplotter.sh
grep -q 'trusted_system_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' scripts/start_chartplotter.sh
grep -q 'read -r -d .*device_tree_model </proc/device-tree/model' scripts/start_chartplotter.sh
grep -q 'PATH="$trusted_system_path"' scripts/start_chartplotter.sh
grep -q 'export PATH' scripts/start_chartplotter.sh
grep -q 'expected root on Raspberry Pi' scripts/start_chartplotter.sh
grep -q 'validate_python_command_candidate' scripts/start_chartplotter.sh
grep -q 'python3_command_path' scripts/start_chartplotter.sh
grep -q 'Python command python3 was not found on PATH' scripts/start_chartplotter.sh
grep -q 'Python command path is not absolute' scripts/start_chartplotter.sh
grep -q 'path_in_trusted_system_dir' scripts/start_chartplotter.sh
grep -q 'readlink -f -- "$candidate"' scripts/start_chartplotter.sh
grep -q 'Python command is not in a trusted system directory' scripts/start_chartplotter.sh
grep -q 'Python command resolves outside trusted system directories' scripts/start_chartplotter.sh
grep -q 'Python command is not a regular file after resolution' scripts/start_chartplotter.sh
grep -q 'Python command directory is owned by uid .* expected root on Raspberry Pi' scripts/start_chartplotter.sh
grep -q 'Python command is owned by uid .* expected root on Raspberry Pi' scripts/start_chartplotter.sh
grep -Fq 'python3_bin="$(python3_command_path)" || exit 127' scripts/start_chartplotter.sh
grep -Fq '"$python3_bin" - "$@"' scripts/start_chartplotter.sh
grep -Fq 'if "$python3_bin" - "$status_report"' scripts/start_chartplotter.sh
! grep -Eq '(^|[[:space:]])python3[[:space:]]+-' scripts/start_chartplotter.sh
grep -q 'resolves Python to a trusted executable path before running descriptor-safe helper snippets' README.md
grep -q 'resolves Python to a trusted executable path before running descriptor-safe helper snippets' docs/sailboat-pi.md
grep -q 'Using OpenCPN binary' scripts/start_chartplotter.sh
grep -q 'OpenCPN command integrity' scripts/verify_pi.sh
grep -q 'chartplotter launcher Pi OpenCPN root owner' scripts/verify_pi.sh
grep -q 'OpenCPN command is a symlink' src/noaa_navionics/health.py
grep -q 'OpenCPN command directory is not a trusted system directory' src/noaa_navionics/health.py
grep -q 'expected root' src/noaa_navionics/health.py
grep -q 'test_check_opencpn_requires_root_owner_on_pi' tests/test_downloader.py
grep -q 'test_check_opencpn_rejects_untrusted_directory_on_pi' tests/test_downloader.py
grep -q 'untrusted-directory OpenCPN commands' README.md
grep -q 'untrusted-directory OpenCPN commands' docs/sailboat-pi.md
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/start_chartplotter.sh").read_text(encoding="utf-8")
path_pin = text.index('PATH="$trusted_system_path"')
ambient_reexec = text.index('reexec_without_ambient_launcher_settings "$@"')
first_command_lookup = text.index('command -v')
if not path_pin < ambient_reexec:
    raise SystemExit("chartplotter launcher must pin PATH on Pi before ambient environment re-exec")
if not path_pin < first_command_lookup:
    raise SystemExit("chartplotter launcher must pin PATH on Pi before command lookup")
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
grep -q 'validate_process_lookup_command_candidate' scripts/start_chartplotter.sh
grep -q 'process_lookup_command_path' scripts/start_chartplotter.sh
grep -q 'Process lookup command pgrep was not found on PATH' scripts/start_chartplotter.sh
grep -q 'Process lookup command path is not absolute' scripts/start_chartplotter.sh
grep -q 'Process lookup command is a symlink' scripts/start_chartplotter.sh
grep -q 'Process lookup command directory is owned by uid .* expected root on Raspberry Pi' scripts/start_chartplotter.sh
grep -q 'Process lookup command is owned by uid .* expected root on Raspberry Pi' scripts/start_chartplotter.sh
grep -q '"$pgrep_bin" -u "$(id -u)" -x opencpn' scripts/start_chartplotter.sh
! grep -q 'pgrep -u "$(id -u)" -x opencpn' scripts/start_chartplotter.sh
grep -q 'resolves `pgrep` to a trusted executable path' README.md
grep -q 'resolves `pgrep` to a trusted executable path' docs/sailboat-pi.md
grep -q 'stat_text.rsplit(") ", 1)' scripts/start_chartplotter.sh
grep -q 'raise SystemExit(0 if fields\[0\] != "Z" else 1)' scripts/start_chartplotter.sh
! grep -q 'cat "/proc/${pid}/stat"' scripts/start_chartplotter.sh
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
grep -q 'validate_display_power_command_candidate' scripts/start_chartplotter.sh
grep -q 'display_power_command_path' scripts/start_chartplotter.sh
grep -q 'Display power command xset was not found on PATH' scripts/start_chartplotter.sh
grep -q 'Display power command path is not absolute' scripts/start_chartplotter.sh
grep -q 'Display power command is a symlink' scripts/start_chartplotter.sh
grep -q 'Display power command directory is owned by uid .* expected root on Raspberry Pi' scripts/start_chartplotter.sh
grep -q 'Display power command is owned by uid .* expected root on Raspberry Pi' scripts/start_chartplotter.sh
grep -q '"$xset_bin" s off' scripts/start_chartplotter.sh
grep -q '"$xset_bin" s noblank' scripts/start_chartplotter.sh
grep -q '"$xset_bin" -dpms' scripts/start_chartplotter.sh
grep -q 'resolves `xset` to a trusted executable path' README.md
grep -q 'resolves `xset` to a trusted executable path' docs/sailboat-pi.md
grep -q 'xset command(s) failed' scripts/start_chartplotter.sh
grep -q 'xset is unavailable or not trusted' scripts/start_chartplotter.sh
grep -q 'launcher.env' scripts/start_chartplotter.sh
grep -q -- '--gps-seconds "$gps_seconds"' scripts/start_chartplotter.sh
grep -q '.source-revision' scripts/deploy_to_pi.sh
grep -q 'write_remote_source_revision' scripts/deploy_to_pi.sh
grep -q 'Refusing source revision write because {label} has permissions' scripts/deploy_to_pi.sh
grep -q 'Refusing to replace symlink source revision file' scripts/deploy_to_pi.sh
grep -q 'Refusing source revision write under symlinked deployment path' scripts/deploy_to_pi.sh
grep -q 'Deployment directory is not ready for source revision write' scripts/deploy_to_pi.sh
grep -q 'Promoted source revision file is a symlink' scripts/deploy_to_pi.sh
grep -q 'Promoted source revision path is not a regular file' scripts/deploy_to_pi.sh
grep -q 'Promoted source revision content mismatch' scripts/deploy_to_pi.sh
grep -q 'fd = os.open(target, flags)' scripts/deploy_to_pi.sh
grep -q 'stat.S_ISREG(opened.st_mode)' scripts/deploy_to_pi.sh
grep -q 'os.fsync(fd)' scripts/deploy_to_pi.sh
grep -q 'reopens that promoted revision file through a no-follow descriptor before syncing it' README.md
grep -q 'reopens that promoted revision file through a no-follow descriptor before syncing it' docs/sailboat-pi.md
grep -q 'os.chmod(staging, 0o755)' scripts/deploy_to_pi.sh
grep -q 'ssh_cmd="$(require_local_command ssh)"' scripts/deploy_to_pi.sh
grep -q 'git_cmd="$(require_local_command git)"' scripts/deploy_to_pi.sh
grep -q 'source_revision="$("$git_cmd" -C "$repo_root" rev-parse --short HEAD' scripts/deploy_to_pi.sh
grep -q 'validate_trusted_local_command' scripts/deploy_to_pi.sh
grep -q 'validate_trusted_local_command "$command_name" "$command_path"' scripts/deploy_to_pi.sh
grep -q 'printf '\''%s\\n'\'' "$command_path"' scripts/deploy_to_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS' scripts/deploy_to_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH' scripts/deploy_to_pi.sh
grep -q 'Local ${command_name} command is not in a trusted system directory' scripts/deploy_to_pi.sh
grep -q 'Local ${command_name} command is not executable after resolution' scripts/deploy_to_pi.sh
grep -q '"$ssh_cmd" "${ssh_batch_options\[@\]}" "$target"' scripts/deploy_to_pi.sh
grep -q 'ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)' scripts/deploy_to_pi.sh
grep -q 'ssh_connect_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)' scripts/deploy_to_pi.sh
grep -q 'remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' scripts/deploy_to_pi.sh
grep -q '${remote_system_path} && export PATH && command -v ${command_name}' scripts/deploy_to_pi.sh
grep -q 'remote_command_path()' scripts/deploy_to_pi.sh
grep -q 'remote_command_path "$command_name" >/dev/null' scripts/deploy_to_pi.sh
grep -q 'if ! validate_remote_deploy_command_trust "$command_name" "$command_path"; then' scripts/deploy_to_pi.sh
grep -q 'remote_path_in_trusted_system_dir' scripts/deploy_to_pi.sh
grep -q 'Remote deploy command ${command_name} is not in a trusted system directory' scripts/deploy_to_pi.sh
grep -q 'Remote deploy command ${command_name} resolves outside trusted system directories' scripts/deploy_to_pi.sh
grep -q 'Remote deploy command ${command_name} ${item_kind} is owned by uid' scripts/deploy_to_pi.sh
grep -q 'Remote deploy command ${command_name} ${item_kind} has permissions' scripts/deploy_to_pi.sh
grep -q 'readlink -f -- "$command_path"' scripts/deploy_to_pi.sh
grep -q 'remote_python_cmd="$(require_remote_command_available python3)"' scripts/deploy_to_pi.sh
grep -q 'remote_python_cmd_quoted="$(printf '\''%q'\'' "$remote_python_cmd")"' scripts/deploy_to_pi.sh
grep -q '${remote_system_path} && export PATH && NOAA_NAVIONICS_REMOTE_DIR=' scripts/deploy_to_pi.sh
grep -Fq '${remote_system_path} && export PATH && NOAA_NAVIONICS_REMOTE_DIR=${remote_dir_env} NOAA_NAVIONICS_SOURCE_REVISION=${revision_env} ${remote_python_cmd_quoted} -' scripts/deploy_to_pi.sh
grep -Fq '${remote_system_path} && export PATH && NOAA_NAVIONICS_REMOTE_DIR=${remote_dir_env} NOAA_NAVIONICS_STAGING_DIR=${staging_dir_env} NOAA_NAVIONICS_PREVIOUS_DIR=${previous_dir_env} ${remote_python_cmd_quoted} -' scripts/deploy_to_pi.sh
! grep -q '${remote_system_path} && export PATH && .* python3 -' scripts/deploy_to_pi.sh
grep -q 'remote_rsync_cmd="$(remote_command_path rsync)"' scripts/deploy_to_pi.sh
grep -q 'local_rsync_cmd="$(local_command_path rsync)"' scripts/deploy_to_pi.sh
grep -q 'deploy_with_rsync "$local_rsync_cmd" "$remote_rsync_cmd"' scripts/deploy_to_pi.sh
grep -q 'remote_tar_cmd="$(require_remote_command_available tar)"' scripts/deploy_to_pi.sh
grep -q 'local_tar_cmd="$(require_local_command tar)"' scripts/deploy_to_pi.sh
grep -q 'deploy_with_tar "$local_tar_cmd" "$remote_tar_cmd"' scripts/deploy_to_pi.sh
grep -q -- '--rsync-path="${remote_system_path} && export PATH && ${remote_rsync_cmd_quoted}"' scripts/deploy_to_pi.sh
grep -q '${remote_system_path} && export PATH && ${remote_tar_cmd_quoted} -xzf - -C' scripts/deploy_to_pi.sh
! grep -q -- '--rsync-path="${remote_system_path} rsync"' scripts/deploy_to_pi.sh
! grep -q '${remote_system_path} && export PATH && tar -xzf - -C' scripts/deploy_to_pi.sh
grep -q '"$local_rsync_cmd" -az --delete -e "$ssh_cmd -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"' scripts/deploy_to_pi.sh
grep -q '"$local_tar_cmd" \\' scripts/deploy_to_pi.sh
grep -q 'ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)' scripts/verify_pi.sh
grep -q 'remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' scripts/verify_pi.sh
grep -q 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' scripts/verify_pi.sh
grep -q 'export PATH' scripts/verify_pi.sh
grep -q 'ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)' scripts/dock_test_pi.sh
grep -q 'ssh_probe_options=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)' scripts/dock_test_pi.sh
grep -q 'remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' scripts/dock_test_pi.sh
grep -q 'local_command_path rsync' scripts/deploy_to_pi.sh
grep -q 'remote_command_path rsync' scripts/deploy_to_pi.sh
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
grep -q 'validates remote deploy command paths, ownership, permissions, and parent directories' README.md
grep -q 'validates remote deploy command paths, ownership, permissions, and parent directories' docs/sailboat-pi.md
grep -q 'uses the validated absolute local and remote `rsync` or `tar` paths for the actual copy command' README.md
grep -q 'uses the validated absolute local and remote `rsync` or `tar` paths for the actual copy command' docs/sailboat-pi.md
grep -q 'uses the validated absolute remote `python3` path for deployment staging and source-revision helpers' README.md
grep -q 'uses the validated absolute remote `python3` path for deployment staging and source-revision helpers' docs/sailboat-pi.md
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
grep -q 'ssh_cmd="$(require_local_command ssh)"' scripts/dock_test_pi.sh
grep -q 'ssh_cmd="$(require_local_command ssh)"' scripts/verify_pi.sh
grep -q 'git_cmd="$(require_local_command git)"' scripts/verify_pi.sh
grep -q 'validate_trusted_local_command' scripts/dock_test_pi.sh
grep -q 'validate_trusted_local_command' scripts/verify_pi.sh
grep -q 'printf '\''%s\\n'\'' "$command_path"' scripts/dock_test_pi.sh
grep -q 'printf '\''%s\\n'\'' "$command_path"' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS' scripts/dock_test_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH' scripts/dock_test_pi.sh
grep -q 'NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH' scripts/verify_pi.sh
grep -q 'Local ${command_name} command is not executable after resolution' scripts/dock_test_pi.sh
grep -q 'Local ${command_name} command is not executable after resolution' scripts/verify_pi.sh
grep -Fq '"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target"' scripts/verify_pi.sh
grep -Fq '${remote_system_path} && export PATH && NOAA_NAVIONICS_EXPECTED_REVISION=' scripts/verify_pi.sh
! grep -Fq '"NOAA_NAVIONICS_EXPECTED_REVISION=${expected_revision_quoted}' scripts/verify_pi.sh
grep -q 'pins its remote command path to trusted system directories before launching the remote verifier' README.md
grep -q 'pins its remote command path to trusted system directories before launching the remote verifier' docs/sailboat-pi.md
grep -Fq '"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "cd ${remote_dir_quoted} && ${remote_system_path} && export PATH && scripts/install_raspberry_pi.sh ${remote_install_args[*]}"' scripts/deploy_to_pi.sh
grep -Fq '"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "cd ${remote_dir_quoted} && ${remote_system_path} && export PATH && scripts/provision_sailboat_pi.sh ${remote_args[*]}"' scripts/deploy_to_pi.sh
! grep -Fq 'ssh -t "$target"' scripts/deploy_to_pi.sh
grep -q 'tempfile.NamedTemporaryFile' scripts/deploy_to_pi.sh
grep -q 'os.replace(tmp_path, target)' scripts/deploy_to_pi.sh
grep -q 'os.fsync(handle.fileno())' scripts/deploy_to_pi.sh
grep -q -- '--allow-dirty' scripts/deploy_to_pi.sh
grep -q -- '--allow-dirty' scripts/dock_test_pi.sh
grep -q -- '--allow-dirty' scripts/verify_pi.sh
grep -q -- '--allow-dirty' scripts/pre_departure_check_pi.sh
grep -q 'Refusing to verify a dirty local worktree as production evidence' scripts/verify_pi.sh
grep -q 'verify_args+=("$1")' scripts/dock_test_pi.sh
grep -q 'verify_args+=("$1")' scripts/pre_departure_check_pi.sh
grep -q 'trusted executable local deployment commands' README.md
grep -q 'trusted executable local deployment commands' docs/sailboat-pi.md
grep -q 'no-deploy, no-reboot pre-departure check' README.md
grep -q 'no-deploy, no-reboot pre-departure check' docs/sailboat-pi.md
grep -q 'scripts/pre_departure_check_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE' README.md
grep -q 'scripts/pre_departure_check_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE' docs/sailboat-pi.md
grep -q 'scripts/pre_trip_prepare_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE' README.md
grep -q 'scripts/pre_trip_prepare_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE' docs/sailboat-pi.md
grep -q 'refreshes NOAA charts on the Pi with a post-refresh status report, tightens the local recovery export directory to user-owned private `0700`, exports and verifies a local recovery bundle' README.md
grep -q 'refreshes NOAA charts on the Pi with a post-refresh status report, tightens the local recovery export directory to user-owned private `0700`, exports and verifies a local recovery bundle' docs/sailboat-pi.md
grep -q 'tightens the local export directory and trip folder to user-owned private `0700`, saves a local private `0600` JSON status snapshot' README.md
grep -q 'tightens the local export directory and trip folder to user-owned private `0700`, saves a local private `0600` JSON status snapshot' docs/sailboat-pi.md
grep -q 'scripts/check_pi_status.sh pi@raspberrypi.local --gps-seconds 10' README.md
grep -q 'scripts/check_pi_status.sh pi@raspberrypi.local --gps-seconds 10' docs/sailboat-pi.md
grep -q 'lightweight read-only status snapshot' README.md
grep -q 'lightweight read-only status snapshot' docs/sailboat-pi.md
grep -q "status helper validates the Pi's installed private venv command path and runs that resolved executable" README.md
grep -q "status helper validates the Pi's installed private venv command path and runs that resolved executable" docs/sailboat-pi.md
grep -q 'It does not deploy, reboot, download charts, or write the Pi status artifact' README.md
grep -q 'It does not deploy, reboot, download charts, or write the Pi status artifact' docs/sailboat-pi.md
grep -q 'scripts/refresh_pi_charts.sh pi@raspberrypi.local --retries 5 --retry-delay 30 --status' README.md
grep -q 'scripts/refresh_pi_charts.sh pi@raspberrypi.local --retries 5 --retry-delay 30 --status' docs/sailboat-pi.md
grep -q "refresh helper validates the SSH target and the Pi's installed private venv command path" README.md
grep -q "refresh helper validates the SSH target and the Pi's installed private venv command path" docs/sailboat-pi.md
grep -q 'Add `--status --gps-seconds N` to run a read-only status report after the refreshed chart sync succeeds' README.md
grep -q 'Add `--status --gps-seconds N` to run a read-only status report after the refreshed chart sync succeeds' docs/sailboat-pi.md
grep -q 'live fix time, signed age, position' README.md
grep -q 'live fix time, signed age, position' docs/sailboat-pi.md
grep -q 'No chart data is downloaded on the local computer' README.md
grep -q 'No chart data is downloaded on the local computer' docs/sailboat-pi.md
grep -q 'scripts/collect_pi_support_bundle.sh pi@raspberrypi.local' README.md
grep -q 'scripts/collect_pi_support_bundle.sh pi@raspberrypi.local' docs/sailboat-pi.md
grep -q 'support bundle helper tightens the local output directory to user-owned private `0700`' README.md
grep -q 'support bundle helper tightens the local output directory to user-owned private `0700`' docs/sailboat-pi.md
grep -q 'writes a local private `0600` `.tgz` containing Pi-side NOAA Navionics config' README.md
grep -q 'writes a local private `0600` `.tgz` containing Pi-side NOAA Navionics config' docs/sailboat-pi.md
grep -q 'Pi-side temporary collection directory only under a private user-owned support cache with `mktemp -d`' README.md
grep -q 'Pi-side temporary collection directory only under a private user-owned support cache with `mktemp -d`' docs/sailboat-pi.md
grep -q 'scripts/export_pi_tracks.sh pi@raspberrypi.local' README.md
grep -q 'scripts/export_pi_tracks.sh pi@raspberrypi.local' docs/sailboat-pi.md
grep -q 'track export helper validates the SSH target, tightens the local output directory to user-owned private `0700`' README.md
grep -q 'track export helper validates the SSH target, tightens the local output directory to user-owned private `0700`' docs/sailboat-pi.md
grep -q 'writes a local private `0600` `.tgz` containing only regular private `.gpx` files' README.md
grep -q 'writes a local private `0600` `.tgz` containing only regular private `.gpx` files' docs/sailboat-pi.md
grep -q 'scripts/post_trip_collect_pi.sh pi@raspberrypi.local' README.md
grep -q 'scripts/post_trip_collect_pi.sh pi@raspberrypi.local' docs/sailboat-pi.md
grep -q 'noaa-navionics mark-position --mob' README.md
grep -q 'noaa-navionics mark-position --mob' docs/sailboat-pi.md
grep -q "reads one fresh quality-checked GPSD or serial fix" README.md
grep -q "reads one fresh quality-checked GPSD or serial fix" docs/sailboat-pi.md
grep -q 'noaa-navionics anchor-watch' README.md
grep -q 'noaa-navionics anchor-watch' docs/sailboat-pi.md
grep -q -- '--anchor-samples N' README.md
grep -q -- '--anchor-samples N' docs/sailboat-pi.md
grep -q -- '--interval-seconds N' README.md
grep -q -- '--interval-seconds N' docs/sailboat-pi.md
grep -q 'when drift exceeds `\[anchor\].radius_meters`' README.md
grep -q 'when drift exceeds `\[anchor\].radius_meters`' docs/sailboat-pi.md
grep -q '`--radius-meters N` for a one-off radius override' README.md
grep -q '`--radius-meters N` for a one-off radius override' docs/sailboat-pi.md
grep -q 'Status reports and Pi verification include the configured anchor radius' README.md
grep -q 'Status reports and Pi verification include the configured anchor radius' docs/sailboat-pi.md
grep -q 'saves a local private `0600` JSON status snapshot, exports GPX tracks, collects a diagnostic support bundle' README.md
grep -q 'saves a local private `0600` JSON status snapshot, exports GPX tracks, collects a diagnostic support bundle' docs/sailboat-pi.md
grep -q 'continues exporting tracks/support even when the status snapshot reports unhealthy state' README.md
grep -q 'continues exporting tracks/support even when the status snapshot reports unhealthy state' docs/sailboat-pi.md
grep -q 'scripts/export_pi_opencpn_data.sh pi@raspberrypi.local' README.md
grep -q 'scripts/export_pi_opencpn_data.sh pi@raspberrypi.local' docs/sailboat-pi.md
grep -q 'OpenCPN export helper tightens the local output directory to user-owned private `0700`' README.md
grep -q 'OpenCPN export helper tightens the local output directory to user-owned private `0700`' docs/sailboat-pi.md
grep -q 'writes a local private `0600` `.tgz` containing trusted regular OpenCPN config' README.md
grep -q 'writes a local private `0600` `.tgz` containing trusted regular OpenCPN config' docs/sailboat-pi.md
grep -q 'scripts/export_pi_settings.sh pi@raspberrypi.local' README.md
grep -q 'scripts/export_pi_settings.sh pi@raspberrypi.local' docs/sailboat-pi.md
grep -q 'settings export helper tightens the local output directory to user-owned private `0700`' README.md
grep -q 'settings export helper tightens the local output directory to user-owned private `0700`' docs/sailboat-pi.md
grep -q 'writes a local private `0600` `.tgz` containing trusted NOAA Navionics config' README.md
grep -q 'writes a local private `0600` `.tgz` containing trusted NOAA Navionics config' docs/sailboat-pi.md
grep -q 'scripts/export_pi_recovery_bundle.sh pi@raspberrypi.local --track-days 30' README.md
grep -q 'scripts/export_pi_recovery_bundle.sh pi@raspberrypi.local --track-days 30' docs/sailboat-pi.md
grep -q 'recovery export helper tightens the local output directory and timestamped recovery folder to user-owned private `0700`' README.md
grep -q 'recovery export helper tightens the local output directory and timestamped recovery folder to user-owned private `0700`' docs/sailboat-pi.md
grep -q 'scripts/verify_pi_recovery_exports.sh pi-recovery-exports/noaa-navionics-pi-recovery-pi_raspberrypi_local-YYYYMMDDTHHMMSSZ' README.md
grep -q 'scripts/verify_pi_recovery_exports.sh pi-recovery-exports/noaa-navionics-pi-recovery-pi_raspberrypi_local-YYYYMMDDTHHMMSSZ' docs/sailboat-pi.md
grep -q 'recovery verifier also requires the timestamped recovery directory to be user-owned private `0700` storage and each archive to be a user-owned private `0600` file' README.md
grep -q 'recovery verifier also requires the timestamped recovery directory to be user-owned private `0700` storage and each archive to be a user-owned private `0600` file' docs/sailboat-pi.md
grep -q 'It does not contact the Pi' README.md
grep -q 'It does not contact the Pi' docs/sailboat-pi.md
grep -q 'scripts/restore_pi_recovery_user_data.sh /path/to/noaa-navionics-pi-recovery-... --apply' README.md
grep -q 'scripts/restore_pi_recovery_user_data.sh /path/to/noaa-navionics-pi-recovery-... --apply' docs/sailboat-pi.md
grep -q 'rejecting parent-directory traversal in the recovered track output path' README.md
grep -q 'rejecting parent-directory traversal in the recovered track output path' docs/sailboat-pi.md
grep -q 'dry-run by default and requires `--apply` before writing' README.md
grep -q 'dry-run by default and requires `--apply` before writing' docs/sailboat-pi.md
grep -q 'does not restore root-owned GPSD, chrony, LightDM' README.md
grep -q 'does not restore root-owned GPSD, chrony, LightDM' docs/sailboat-pi.md
grep -q 'configured chart manifests and storage listings' README.md
grep -q 'configured chart manifests and storage listings' docs/sailboat-pi.md
grep -q 'extracted ENC cells, or GPX track contents' README.md
grep -q 'extracted ENC cells, or GPX track contents' docs/sailboat-pi.md
grep -q 'containing only regular private `.gpx` files' README.md
grep -q 'containing only regular private `.gpx` files' docs/sailboat-pi.md
grep -q '`navobj.xml` route/waypoint data' README.md
grep -q '`navobj.xml` route/waypoint data' docs/sailboat-pi.md
grep -q 'trusted NOAA Navionics config, launcher policy, source revision' README.md
grep -q 'trusted NOAA Navionics config, launcher policy, source revision' docs/sailboat-pi.md
grep -q 'read-only settings, OpenCPN user-data, GPX track, and support-bundle exports' README.md
grep -q 'read-only settings, OpenCPN user-data, GPX track, and support-bundle exports' docs/sailboat-pi.md
grep -q 'read one fresh timestamped quality-checked GPSD or serial GPS fix' README.md
grep -q 'read one fresh timestamped quality-checked GPSD or serial GPS fix' docs/sailboat-pi.md
grep -q 'scripts/shutdown_pi_safely.sh pi@raspberrypi.local --confirm' README.md
grep -q 'scripts/shutdown_pi_safely.sh pi@raspberrypi.local --confirm' docs/sailboat-pi.md
grep -q 'shutdown helper validates the SSH target plus trusted remote `sync`, `sudo`, and `systemctl` command paths and parent directories' README.md
grep -q 'shutdown helper validates the SSH target plus trusted remote `sync`, `sudo`, and `systemctl` command paths and parent directories' docs/sailboat-pi.md
grep -q 'read-only diagnostic evidence' README.md
grep -q 'read-only diagnostic evidence' docs/sailboat-pi.md
grep -q 'Use `--dry-run` to prove that path without powering off' README.md
grep -q 'Use `--dry-run` to prove that path without powering off' docs/sailboat-pi.md
grep -q -- '--gps-seconds' scripts/dock_test_pi.sh
grep -q -- '--gps-seconds' scripts/pre_departure_check_pi.sh
grep -q -- '--opencpn-restarts' scripts/provision_sailboat_pi.sh
grep -q -- '--opencpn-restart-delay' scripts/provision_sailboat_pi.sh
grep -q -- '--opencpn-restarts' scripts/deploy_to_pi.sh
grep -q -- '--opencpn-restart-delay' scripts/deploy_to_pi.sh
grep -q -- '--opencpn-restarts' scripts/verify_pi.sh
grep -q -- '--opencpn-restart-delay' scripts/verify_pi.sh
grep -q -- '--opencpn-restarts' scripts/dock_test_pi.sh
grep -q -- '--opencpn-restart-delay' scripts/dock_test_pi.sh
grep -q -- '--opencpn-restarts' scripts/pre_departure_check_pi.sh
grep -q -- '--opencpn-restart-delay' scripts/pre_departure_check_pi.sh
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
grep -q 'validate_ssh_target' scripts/collect_pi_support_bundle.sh
grep -q 'validate_ssh_target' scripts/shutdown_pi_safely.sh
grep -q 'validate_ssh_target' scripts/refresh_pi_charts.sh
grep -q 'validate_gps_device_path_arg' scripts/deploy_to_pi.sh
grep -q 'validate_gps_device_path_arg' scripts/dock_test_pi.sh
grep -q 'validate_gps_device_path_arg' scripts/verify_pi.sh
grep -q 'validate_gps_device_path_arg' scripts/pre_departure_check_pi.sh
grep -q 'GPS device path is volatile' scripts/deploy_to_pi.sh
grep -q 'GPS device path is volatile' scripts/dock_test_pi.sh
grep -q 'GPS device path is volatile' scripts/verify_pi.sh
grep -q 'GPS device path is volatile' scripts/pre_departure_check_pi.sh
grep -q 'SSH target must not begin with' scripts/deploy_to_pi.sh
grep -q 'SSH target must be user@host' scripts/verify_pi.sh
grep -q 'SSH target must be user@host' scripts/collect_pi_support_bundle.sh
grep -q 'SSH target must be user@host' scripts/shutdown_pi_safely.sh
grep -q 'SSH target must be user@host' scripts/refresh_pi_charts.sh
grep -q 'SSH target user contains unsafe characters' scripts/deploy_to_pi.sh
grep -q 'SSH target user contains unsafe characters' scripts/dock_test_pi.sh
grep -q 'SSH target user contains unsafe characters' scripts/verify_pi.sh
grep -q 'SSH target host contains unsafe characters' scripts/deploy_to_pi.sh
grep -q 'SSH target host contains unsafe characters' scripts/dock_test_pi.sh
grep -q 'SSH target host contains unsafe characters' scripts/verify_pi.sh
grep -q 'SSH target host contains unsafe characters' scripts/collect_pi_support_bundle.sh
grep -q 'SSH target host contains unsafe characters' scripts/shutdown_pi_safely.sh
grep -q 'SSH target host contains unsafe characters' scripts/refresh_pi_charts.sh
grep -q 'plain user@host without paths or ports' scripts/deploy_to_pi.sh
grep -q 'plain user@host without paths or ports' scripts/dock_test_pi.sh
grep -q 'plain user@host without paths or ports' scripts/verify_pi.sh
grep -q 'Remote deployment directory must be a dedicated noaa-navionics directory' scripts/deploy_to_pi.sh
grep -q 'Remote deployment directory must end in noaa-navionics' scripts/deploy_to_pi.sh
grep -q 'Remote deployment directory must be under the Pi user' scripts/deploy_to_pi.sh
grep -q 'Remote deployment directory must not contain parent-directory components' scripts/deploy_to_pi.sh
grep -q 'Remote deployment directory must be under the Pi user' scripts/dock_test_pi.sh
grep -q 'Remote deployment directory must not contain parent-directory components' scripts/dock_test_pi.sh
grep -q 'parent-directory components such as `..` are rejected' README.md
grep -q 'parent-directory components such as `..` are rejected' docs/sailboat-pi.md
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
grep -q 'sudo_cmd="$(trusted_root_command_path sudo "Sudo command")"' scripts/install_raspberry_pi.sh
grep -q 'python3_cmd="$(trusted_root_command_path python3 "Python command")"' scripts/install_raspberry_pi.sh
grep -q 'python3_cmd="$(python3_command)" || exit 2' scripts/install_raspberry_pi.sh
grep -q 'sudo_cmd_value="$(sudo_command)" || return 1' scripts/install_raspberry_pi.sh
grep -q '"$sudo_cmd_value" "$python3_cmd" - "$target" "$mode" "$text"' scripts/install_raspberry_pi.sh
grep -q '"$python3_cmd" -m venv "$venv_dir"' scripts/install_raspberry_pi.sh
grep -q 'noaa-navionics-bookworm-backports.list' scripts/install_raspberry_pi.sh
grep -q 'root text target is a symlink' scripts/install_raspberry_pi.sh
grep -q 'root text target directory path contains a symlink' scripts/install_raspberry_pi.sh
grep -q 'root text target directory .* has permissions' scripts/install_raspberry_pi.sh
grep -q 'root text target .* is owned by uid' scripts/install_raspberry_pi.sh
! grep -q 'sudo tee -a /etc/apt/sources.list' scripts/install_raspberry_pi.sh
grep -q 'DEBIAN_FRONTEND=noninteractive "$apt_get_bin"' scripts/install_raspberry_pi.sh
! grep -Eq 'sudo apt( |$)' scripts/install_raspberry_pi.sh
! grep -q 'sudo python3 - "$target" "$mode" "$text"' scripts/install_raspberry_pi.sh
! grep -q '"$sudo_cmd_value" python3' scripts/install_raspberry_pi.sh
! grep -Eq '(^|[[:space:]])python3[[:space:]]+-' scripts/install_raspberry_pi.sh
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
grep -q 'cannot sync symlinked tree' scripts/install_raspberry_pi.sh
grep -q 'stat.S_ISLNK(initial.st_mode)' scripts/install_raspberry_pi.sh
grep -q 'os.open(path, os.O_RDONLY | nofollow)' scripts/install_raspberry_pi.sh
grep -q 'os.open(file_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))' scripts/install_raspberry_pi.sh
grep -q 'stat.S_ISREG(opened.st_mode)' scripts/install_raspberry_pi.sh
! grep -q 'with path.open("rb") as handle' scripts/install_raspberry_pi.sh
! grep -q 'with file_path.open("rb") as handle' scripts/install_raspberry_pi.sh
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
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/install_raspberry_pi.sh)" -ge 4
grep -q 'Installer sync helpers use no-follow opens for directories and regular files' README.md
grep -q 'Installer sync helpers use no-follow opens for directories and regular files' docs/sailboat-pi.md
grep -q 'validate_user_directory_path' scripts/provision_sailboat_pi.sh
grep -q 'ensure_private_directory "$(dirname "$config")" "NOAA Navionics config directory"' scripts/provision_sailboat_pi.sh
grep -q 'ensure_private_directory "$systemd_user_dir" "user systemd directory"' scripts/provision_sailboat_pi.sh
grep -q 'ensure_private_directory "$autostart_dir" "desktop autostart directory"' scripts/provision_sailboat_pi.sh
grep -q 'stat.S_ISLNK(initial.st_mode)' scripts/provision_sailboat_pi.sh
grep -q 'os.open(path, os.O_RDONLY | nofollow)' scripts/provision_sailboat_pi.sh
grep -q 'stat.S_ISREG(opened.st_mode)' scripts/provision_sailboat_pi.sh
! grep -q 'with path.open("rb") as handle' scripts/provision_sailboat_pi.sh
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/provision_sailboat_pi.sh)" -ge 1
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/deploy_to_pi.sh)" -ge 5
test "$(grep -c 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' scripts/start_chartplotter.sh)" -ge 2
grep -q 'Deployment sync helpers use no-follow directory opens; provisioning and startup sync helpers use no-follow opens for directories and regular files' README.md
grep -q 'Deployment sync helpers use no-follow directory opens; provisioning and startup sync helpers use no-follow opens for directories and regular files' docs/sailboat-pi.md
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
grep -q 'path_in_trusted_system_dir()' scripts/install_raspberry_pi.sh
grep -q 'trusted_root_command_path()' scripts/install_raspberry_pi.sh
grep -q 'check_root_command_integrity()' scripts/install_raspberry_pi.sh
grep -q 'apt_get_command()' scripts/install_raspberry_pi.sh
grep -q 'sudo_command()' scripts/install_raspberry_pi.sh
grep -q 'python3_command()' scripts/install_raspberry_pi.sh
grep -q 'apt_get_cmd="$(trusted_root_command_path apt-get "APT command")"' scripts/install_raspberry_pi.sh
grep -q 'sudo_cmd="$(trusted_root_command_path sudo "Sudo command")"' scripts/install_raspberry_pi.sh
grep -q 'python3_cmd="$(trusted_root_command_path python3 "Python command")"' scripts/install_raspberry_pi.sh
grep -q 'apt_get_bin="$(apt_get_command)"' scripts/install_raspberry_pi.sh
grep -q '"$sudo_cmd_value" env DEBIAN_FRONTEND=noninteractive "$apt_get_bin" update' scripts/install_raspberry_pi.sh
grep -q '"$sudo_cmd_value" env DEBIAN_FRONTEND=noninteractive "$apt_get_bin" install -y "$@"' scripts/install_raspberry_pi.sh
! grep -q 'sudo env DEBIAN_FRONTEND=noninteractive apt-get' scripts/install_raspberry_pi.sh
! grep -q 'sudo env DEBIAN_FRONTEND=noninteractive "$apt_get_bin"' scripts/install_raspberry_pi.sh
grep -q 'is not in a trusted system directory' scripts/install_raspberry_pi.sh
grep -q 'is owned by uid .* expected root' scripts/install_raspberry_pi.sh
grep -q 'directory is owned by uid .* expected root' scripts/install_raspberry_pi.sh
grep -q 'expected no group/other write bits' scripts/install_raspberry_pi.sh
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
grep -q 'check_root_command_integrity cgps "GPSD client command"' scripts/install_raspberry_pi.sh
grep -q 'check_root_command_integrity vcgencmd "Pi power command"' scripts/install_raspberry_pi.sh
grep -q 'trusted cgps is not available after installing GPSD client tools' scripts/install_raspberry_pi.sh
grep -q 'trusted vcgencmd is not available after installing Raspberry Pi utilities' scripts/install_raspberry_pi.sh
grep -q 'trusted root-owned `cgps`' README.md
grep -q 'trusted root-owned `vcgencmd`' README.md
grep -q 'resolves sudo, apt-get, and Python through trusted root-owned command checks' README.md
grep -q 'trusted root-owned `cgps`' docs/sailboat-pi.md
grep -q 'trusted root-owned `vcgencmd`' docs/sailboat-pi.md
grep -q 'resolves sudo, apt-get, and Python through trusted root-owned command checks' docs/sailboat-pi.md
grep -q 'status --porcelain --untracked-files=all' scripts/install_raspberry_pi.sh
grep -q 'revision="${revision}-dirty"' scripts/install_raspberry_pi.sh
grep -q 'Direct installs run on a dirty Pi worktree' README.md
grep -q 'direct installs from a dirty Git worktree' docs/sailboat-pi.md
grep -q 'console_scripts' setup.py
grep -q 'noaa-navionics=noaa_navionics.cli:main' setup.py
grep -q 'noaa-navionics-gui=noaa_navionics.gui:main' setup.py
grep -q 'noaa-navionics-status-gui=noaa_navionics.status_gui:main' setup.py
grep -q 'noaa-navionics-status-gui = "noaa_navionics.status_gui:main"' pyproject.toml
! grep -q '^build-backend' pyproject.toml
grep -q 'trusted vcgencmd is not available' scripts/install_raspberry_pi.sh
grep -q 'python3-setuptools procps' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic' scripts/install_raspberry_pi.sh
grep -q 'link_user_atomic' scripts/install_raspberry_pi.sh
grep -q 'verify_installed_command_link' scripts/install_raspberry_pi.sh
grep -q 'verify_installed_user_executable' scripts/install_raspberry_pi.sh
grep -q 'mktemp "${target_dir}/.${target_name}.XXXXXX"' scripts/install_raspberry_pi.sh
grep -q 'install -m "$mode" "$source" "$tmp"' scripts/install_raspberry_pi.sh
grep -q 'ln -s "$source" "$tmp"' scripts/install_raspberry_pi.sh
grep -q 'validate_user_install_path "$target_dir" "installed user file directory" directory' scripts/install_raspberry_pi.sh
grep -q 'validate_user_install_path "$target_dir" "installed command symlink directory" directory' scripts/install_raspberry_pi.sh
test "$(grep -c 'validate_user_install_path "$target" "installed user file" regular' scripts/install_raspberry_pi.sh)" -ge 2
test "$(grep -c 'validate_user_install_path "$target" "installed command symlink" link' scripts/install_raspberry_pi.sh)" -ge 2
grep -q 'mv -f "$tmp" "$target"' scripts/install_raspberry_pi.sh
grep -q 'sync_paths "$target"' scripts/install_raspberry_pi.sh
grep -q 'Installer revalidates user directories after creating or tightening them before placing temporary files there' README.md
grep -q 'Installer revalidates user directories after creating or tightening them before placing temporary files there' docs/sailboat-pi.md
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/install_raspberry_pi.sh").read_text(encoding="utf-8")
ensure_start = text.index("ensure_private_directory()")
ensure_mkdir = text.index('mkdir -p "$target"', ensure_start)
ensure_validate_after_mkdir = text.index('validate_user_install_path "$target" "$label" directory', ensure_mkdir)
ensure_chmod = text.index('chmod 0700 "$target"', ensure_validate_after_mkdir)
ensure_validate_after_chmod = text.index('validate_user_install_path "$target" "$label" directory', ensure_chmod)
ensure_sync = text.index('sync_paths "$target"', ensure_validate_after_chmod)
file_start = text.index("install_user_file_atomic()")
file_mkdir = text.index('mkdir -p "$target_dir"', file_start)
file_validate_dir = text.index('validate_user_install_path "$target_dir" "installed user file directory" directory', file_mkdir)
file_mktemp = text.index('mktemp "${target_dir}/.${target_name}.XXXXXX"', file_validate_dir)
file_promote = text.index('mv -f "$tmp" "$target"', file_mktemp)
link_start = text.index("link_user_atomic()")
link_mkdir = text.index('mkdir -p "$target_dir"', link_start)
link_validate_dir = text.index('validate_user_install_path "$target_dir" "installed command symlink directory" directory', link_mkdir)
link_mktemp = text.index('mktemp "${target_dir}/.${target_name}.XXXXXX"', link_validate_dir)
link_promote = text.index('mv -f "$tmp" "$target"', link_mktemp)
if not ensure_mkdir < ensure_validate_after_mkdir < ensure_chmod < ensure_validate_after_chmod < ensure_sync:
    raise SystemExit("installer private directories must be revalidated after mkdir and chmod before syncing")
if not file_mkdir < file_validate_dir < file_mktemp < file_promote:
    raise SystemExit("installer user file directory must be revalidated before creating a temp file")
if not link_mkdir < link_validate_dir < link_mktemp < link_promote:
    raise SystemExit("installer command-link directory must be revalidated before creating a temp link")
PY
grep -q 'link_user_atomic "${venv_dir}/bin/noaa-navionics" "${HOME}/.local/bin/noaa-navionics"' scripts/install_raspberry_pi.sh
grep -q 'link_user_atomic "${venv_dir}/bin/noaa-navionics-gui" "${HOME}/.local/bin/noaa-navionics-gui"' scripts/install_raspberry_pi.sh
grep -q 'link_user_atomic "${venv_dir}/bin/noaa-navionics-status-gui" "${HOME}/.local/bin/noaa-navionics-status-gui"' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/scripts/start_chartplotter.sh" "${HOME}/.local/bin/noaa-navionics-start-chartplotter" 0755' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/scripts/configure_desktop_autologin.sh" "${HOME}/.local/bin/noaa-navionics-configure-desktop-autologin" 0755' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/scripts/configure_gps_time.sh" "${HOME}/.local/bin/noaa-navionics-configure-gps-time" 0755' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/systemd/noaa-navionics.service" "${systemd_user_dir}/noaa-navionics.service" 0644' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/systemd/noaa-navionics.timer" "${systemd_user_dir}/noaa-navionics.timer" 0644' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/systemd/noaa-navionics-track.service" "${systemd_user_dir}/noaa-navionics-track.service" 0644' scripts/install_raspberry_pi.sh
grep -q 'install_user_file_atomic "${repo_root}/systemd/noaa-navionics-preflight.service" "${systemd_user_dir}/noaa-navionics-preflight.service" 0644' scripts/install_raspberry_pi.sh
! grep -q 'cp "${repo_root}/systemd' scripts/install_raspberry_pi.sh
grep -q '"${HOME}/.local/bin/noaa-navionics-gui"' scripts/install_raspberry_pi.sh
grep -q '"${HOME}/.local/bin/noaa-navionics-status-gui"' scripts/install_raspberry_pi.sh
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
grep -q -- '--require-chartplotter-started' scripts/pre_departure_check_pi.sh
grep -q 'recent-user-journal' scripts/collect_pi_support_bundle.sh
grep -q 'recent-system-journal' scripts/collect_pi_support_bundle.sh
grep -q 'chartplotter.log' scripts/collect_pi_support_bundle.sh
grep -q 'status.json' scripts/collect_pi_support_bundle.sh
grep -q 'noaa-navionics-manifest.json' scripts/collect_pi_support_bundle.sh
grep -q 'configured-chart-storage-tree' scripts/collect_pi_support_bundle.sh
grep -q 'configured-track-storage-tree' scripts/collect_pi_support_bundle.sh
grep -q 'does not include downloaded NOAA chart archives' scripts/collect_pi_support_bundle.sh
grep -q 'prepare_private_output_dir "Output directory" "$output_dir"' scripts/collect_pi_support_bundle.sh
grep -q 'finalize_private_archive "$bundle_path"' scripts/collect_pi_support_bundle.sh
grep -q 'expected current user ${current_uid}' scripts/collect_pi_support_bundle.sh
grep -q 'mktemp -d "${cache_dir}/support-bundle.XXXXXX"' scripts/collect_pi_support_bundle.sh
grep -q 'support bundle cache directory must be user-owned private 0700' scripts/collect_pi_support_bundle.sh
grep -q '"$cache_dir"/support-bundle.\*)' scripts/collect_pi_support_bundle.sh
grep -q 'tarfile.open' scripts/export_pi_tracks.sh
grep -q 'NOAA_NAVIONICS_EXPORT_DAYS' scripts/export_pi_tracks.sh
grep -q 'configured GPX track directory' scripts/export_pi_tracks.sh
grep -q 'refusing to export symlinked GPX track' scripts/export_pi_tracks.sh
grep -q 'NOAA chart archives and extracted ENC cells are not included' scripts/export_pi_tracks.sh
grep -q 'prepare_private_output_dir "Output directory" "$output_dir"' scripts/export_pi_tracks.sh
grep -q 'finalize_private_archive "$archive_path"' scripts/export_pi_tracks.sh
grep -q 'expected current user ${current_uid}' scripts/export_pi_tracks.sh
grep -q 'mark-position' src/noaa_navionics/cli.py
grep -q 'anchor-watch' src/noaa_navionics/cli.py
grep -q 'anchor_samples=args.anchor_samples' src/noaa_navionics/cli.py
grep -q 'interval_seconds=args.interval_seconds' src/noaa_navionics/cli.py
grep -q 'distance_meters' src/noaa_navionics/cli.py
grep -q 'ANCHOR ALARM' src/noaa_navionics/cli.py
grep -q 'No usable GPS fix was available for anchor watch' src/noaa_navionics/cli.py
grep -q 'app_config.anchor_radius_meters' src/noaa_navionics/cli.py
grep -q 'gpx_position_mark_path' src/noaa_navionics/cli.py
grep -q 'write_gpx_position_mark' src/noaa_navionics/cli.py
grep -q 'No usable GPS fix was available for a position mark' src/noaa_navionics/cli.py
grep -q 'Marked position:' src/noaa_navionics/cli.py
grep -q 'Man overboard position mark' src/noaa_navionics/cli.py
grep -q 'navobj.xml' scripts/export_pi_opencpn_data.sh
grep -q 'OpenCPN user config, routes, waypoints' scripts/export_pi_opencpn_data.sh
grep -q 'refusing to export symlinked OpenCPN file' scripts/export_pi_opencpn_data.sh
grep -q 'NOAA chart archives and extracted ENC cells are not included' scripts/export_pi_opencpn_data.sh
grep -q 'prepare_private_output_dir "Output directory" "$output_dir"' scripts/export_pi_opencpn_data.sh
grep -q 'finalize_private_archive "$archive_path"' scripts/export_pi_opencpn_data.sh
grep -q 'expected current user ${current_uid}' scripts/export_pi_opencpn_data.sh
grep -q 'commissioning-settings snapshot' scripts/export_pi_settings.sh
grep -q 'launcher.env' scripts/export_pi_settings.sh
grep -q 'source-revision' scripts/export_pi_settings.sh
grep -q '50-noaa-navionics-autologin.conf' scripts/export_pi_settings.sh
grep -q 'finalize_private_archive "$archive_path"' scripts/export_pi_settings.sh
grep -q 'noaa-navionics-preflight.service' scripts/export_pi_settings.sh
grep -q 'It does not include logs, GPX tracks, NOAA chart archives, or extracted ENC cells' scripts/export_pi_settings.sh
grep -q 'prepare_private_output_dir "Output directory" "$output_dir"' scripts/export_pi_settings.sh
grep -q 'expected current user ${current_uid}' scripts/export_pi_settings.sh
grep -q 'export_pi_settings.sh' scripts/export_pi_recovery_bundle.sh
grep -q 'export_pi_opencpn_data.sh' scripts/export_pi_recovery_bundle.sh
grep -q 'export_pi_tracks.sh' scripts/export_pi_recovery_bundle.sh
grep -q 'collect_pi_support_bundle.sh' scripts/export_pi_recovery_bundle.sh
grep -q 'GPX tracks" "$tracks_helper" "$target" "$recovery_dir" --days "$track_days"' scripts/export_pi_recovery_bundle.sh
grep -q 'prepare_private_output_dir "Output directory" "$output_dir"' scripts/export_pi_recovery_bundle.sh
grep -q 'prepare_private_output_dir "Recovery output directory" "$recovery_dir"' scripts/export_pi_recovery_bundle.sh
grep -q 'expected current user ${current_uid}' scripts/export_pi_recovery_bundle.sh
grep -q 'tarfile.open' scripts/verify_pi_recovery_exports.sh
grep -q 'noaa-navionics-pi-settings-\*.tgz' scripts/verify_pi_recovery_exports.sh
grep -q 'noaa-navionics-pi-opencpn-\*.tgz' scripts/verify_pi_recovery_exports.sh
grep -q 'noaa-navionics-pi-tracks-\*.tgz' scripts/verify_pi_recovery_exports.sh
grep -q 'noaa-navionics-pi-support-\*.tgz' scripts/verify_pi_recovery_exports.sh
grep -q 'manifest.json' scripts/verify_pi_recovery_exports.sh
grep -q 'README.txt' scripts/verify_pi_recovery_exports.sh
grep -q 'file_count' scripts/verify_pi_recovery_exports.sh
grep -q 'track_count' scripts/verify_pi_recovery_exports.sh
grep -q 'unsupported non-regular member' scripts/verify_pi_recovery_exports.sh
grep -q 'recovery directory has permissions .* expected private 0700' scripts/verify_pi_recovery_exports.sh
grep -q 'archive has permissions .* expected private 0600' scripts/verify_pi_recovery_exports.sh
grep -q 'Verified Pi recovery exports' scripts/verify_pi_recovery_exports.sh
grep -q 'NOAA_NAVIONICS_RESTORE_APPLY' scripts/restore_pi_recovery_user_data.sh
grep -q 'Dry run only. Re-run with --apply to write files.' scripts/restore_pi_recovery_user_data.sh
grep -q 'do not restore recovery user data as root' scripts/restore_pi_recovery_user_data.sh
grep -q 'noaa-navionics/config.ini' scripts/restore_pi_recovery_user_data.sh
grep -q 'opencpn' scripts/restore_pi_recovery_user_data.sh
grep -q 'tracks archive contains unexpected restore member' scripts/restore_pi_recovery_user_data.sh
grep -q 'restored tracking.output must not contain parent-directory components' scripts/restore_pi_recovery_user_data.sh
grep -q 'recovery-restore-backups' scripts/restore_pi_recovery_user_data.sh
grep -q 'def ensure_private_directory_tree' scripts/restore_pi_recovery_user_data.sh
grep -q 'restore directory .* expected private 0700' scripts/restore_pi_recovery_user_data.sh
grep -q 'Restore-created directories and overwrite backup directories are revalidated as user-owned private `0700` paths' README.md
grep -q 'Restore-created directories and overwrite backup directories are revalidated as user-owned private `0700` paths' docs/sailboat-pi.md
grep -q 'Re-run provisioning, then scripts/verify_pi.sh or scripts/dock_test_pi.sh' scripts/restore_pi_recovery_user_data.sh
grep -q 'systemctl.*poweroff' scripts/shutdown_pi_safely.sh
grep -q 'NOAA_NAVIONICS_SHUTDOWN_DRY_RUN' scripts/shutdown_pi_safely.sh
grep -q 'check_remote_directory_chain "$resolved_path"' scripts/shutdown_pi_safely.sh
grep -q 'wait-network --host www.charts.noaa.gov --port 443 --seconds 300' scripts/refresh_pi_charts.sh
grep -q 'sync-charts --config "$config" --retries "$retries" --retry-delay "$retry_delay"' scripts/refresh_pi_charts.sh
grep -q 'NOAA_NAVIONICS_REFRESH_STATUS' scripts/refresh_pi_charts.sh
grep -q 'NOAA_NAVIONICS_REFRESH_GPS_SECONDS' scripts/refresh_pi_charts.sh
grep -q 'check_installed_noaa_command_tree' scripts/refresh_pi_charts.sh
grep -q 'app_exec="$(check_installed_noaa_command)"' scripts/refresh_pi_charts.sh
grep -q 'status-report --config "$config" --gps-seconds "$gps_seconds"' scripts/refresh_pi_charts.sh
grep -q 'Post-refresh status report' scripts/refresh_pi_charts.sh
grep -q -- '--expected-boot-id' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_EXPECTED_BOOT_ID' scripts/verify_pi.sh
grep -q 'current boot ID .* does not match expected reboot boot ID' scripts/verify_pi.sh
grep -Fq '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' scripts/verify_pi.sh
grep -q 'NOAA_NAVIONICS_GPS_SECONDS' scripts/verify_pi.sh
grep -q -- '--expected-gps-device' scripts/verify_pi.sh
grep -Fq -- '--expected-gps-device "$device"' scripts/pre_departure_check_pi.sh
grep -q 'NOAA_NAVIONICS_EXPECTED_GPS_DEVICE' scripts/verify_pi.sh
grep -q 'check_expected_gps_device_matches' scripts/verify_pi.sh
grep -q 'GPSD device matches expected' scripts/verify_pi.sh
grep -q '_monitorable_fixes' src/noaa_navionics/cli.py
grep -q 'Skipping low-detail GPS monitor fix' tests/test_downloader.py
grep -q 'gps-monitor --once` exits successfully only after a fresh timestamped GPS fix with satellite or HDOP quality data' README.md
grep -q 'gps-monitor --once` exits successfully only after a fresh timestamped GPS fix with satellite or HDOP quality data' docs/sailboat-pi.md
grep -q 'export_pi_recovery_bundle.sh' scripts/pre_trip_prepare_pi.sh
grep -q 'verify_pi_recovery_exports.sh' scripts/pre_trip_prepare_pi.sh
grep -q 'refresh_pi_charts.sh' scripts/pre_trip_prepare_pi.sh
grep -q 'pre_departure_check_pi.sh' scripts/pre_trip_prepare_pi.sh
grep -q -- '--status --gps-seconds "$gps_seconds"' scripts/pre_trip_prepare_pi.sh
grep -q 'Pi recovery exports written to:' scripts/pre_trip_prepare_pi.sh
grep -q 'At least one pre-trip preparation step must run' scripts/pre_trip_prepare_pi.sh
grep -q 'prepare_private_output_dir "Recovery output directory" "$output_dir"' scripts/pre_trip_prepare_pi.sh
grep -q 'expected current user ${current_uid}' scripts/pre_trip_prepare_pi.sh
grep -q 'check_pi_status.sh' scripts/post_trip_collect_pi.sh
grep -q 'export_pi_tracks.sh' scripts/post_trip_collect_pi.sh
grep -q 'collect_pi_support_bundle.sh' scripts/post_trip_collect_pi.sh
grep -q 'shutdown_pi_safely.sh' scripts/post_trip_collect_pi.sh
grep -q 'Post-trip Pi artifacts written to:' scripts/post_trip_collect_pi.sh
grep -q 'Post-trip collection completed, but the status snapshot reported a failure' scripts/post_trip_collect_pi.sh
grep -q 'At least one post-trip collection or shutdown step must run' scripts/post_trip_collect_pi.sh
grep -q 'prepare_private_output_dir "Output directory" "$output_dir"' scripts/post_trip_collect_pi.sh
grep -q 'prepare_private_output_dir "Post-trip output directory" "$trip_dir"' scripts/post_trip_collect_pi.sh
grep -q 'expected current user ${current_uid}' scripts/post_trip_collect_pi.sh
grep -q 'prepare_private_output_file "status snapshot" "$status_path"' scripts/post_trip_collect_pi.sh
grep -q 'verify_private_output_file "status snapshot" "$status_path"' scripts/post_trip_collect_pi.sh
grep -q 'NOAA_NAVIONICS_STATUS_GPS_SECONDS' scripts/check_pi_status.sh
grep -q 'NOAA_NAVIONICS_STATUS_JSON' scripts/check_pi_status.sh
grep -q 'status-report' scripts/check_pi_status.sh
grep -q -- '--config "${HOME}/.config/noaa-navionics/config.ini"' scripts/check_pi_status.sh
grep -q 'expected private venv symlink' scripts/check_pi_status.sh
grep -q 'check_installed_command_tree' scripts/check_pi_status.sh
grep -q 'app_exec="$(check_installed_noaa_command)"' scripts/check_pi_status.sh
grep -q 'Do not check NOAA Navionics status as root@' scripts/check_pi_status.sh
! grep -q -- '--output' scripts/check_pi_status.sh
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
grep -q 'read_private_user_file()' scripts/verify_pi.sh
grep -q 'read_private_user_file "${launcher_lock}/pid" "chartplotter launcher lock pid"' scripts/verify_pi.sh
grep -q 'read_private_user_file "${launcher_lock}/boot_id" "chartplotter launcher lock boot ID"' scripts/verify_pi.sh
grep -q 'current_boot_id()' scripts/verify_pi.sh
grep -q 'current boot ID is not a Linux boot_id value' scripts/verify_pi.sh
grep -q 'current_boot_id="$(current_boot_id 2>/dev/null || true)"' scripts/verify_pi.sh
grep -q 'read_proc_env_value()' scripts/verify_pi.sh
grep -q 'reject_proc_env_prefix()' scripts/verify_pi.sh
grep -q 'data.split(b"\\0")' scripts/verify_pi.sh
grep -q 'entry.split(b"=", 1)' scripts/verify_pi.sh
grep -q 'read_proc_env_value "$launcher_pid" DISPLAY "chartplotter launcher environment"' scripts/verify_pi.sh
grep -q 'reject_proc_env_prefix "$pid" "NOAA_NAVIONICS_"' scripts/verify_pi.sh
grep -q 'reject_proc_env_prefix "$owner_pid" "NOAA_NAVIONICS_"' scripts/verify_pi.sh
! grep -q 'read -r owner_pid <"${launcher_lock}/pid"' scripts/verify_pi.sh
! grep -q 'read -r lock_boot_id <"${launcher_lock}/boot_id"' scripts/verify_pi.sh
! grep -Fq 'tr '\''\0'\'' '\''\n'\'' <"/proc/${launcher_pid}/environ"' scripts/verify_pi.sh
! grep -Fq 'tr '\''\0'\'' '\''\n'\'' <"/proc/${pid}/environ"' scripts/verify_pi.sh
! grep -Fq 'tr '\''\0'\'' '\''\n'\'' <"/proc/${owner_pid}/environ"' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock boot ID' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock symlink guard' scripts/verify_pi.sh
grep -q 'opencpn_stability_seconds=10' scripts/verify_pi.sh
grep -q 'opencpn_process_supervised_by_launcher' scripts/verify_pi.sh
grep -q 'process_cmdline_has_launcher_name' scripts/verify_pi.sh
grep -q 'process_cmdline_has_arg' scripts/verify_pi.sh
grep -q 'stat_text.rsplit(") ", 1)' scripts/verify_pi.sh
grep -q 'raise SystemExit(0 if fields\[1\] == launcher_pid else 1)' scripts/verify_pi.sh
grep -q 'Path(f"/proc/{pid}/cmdline").read_bytes()' scripts/verify_pi.sh
grep -q 'raw_arg.decode("utf-8", "surrogateescape") == expected_arg' scripts/verify_pi.sh
grep -q 'process_cmdline_has_launcher_name "$owner_pid"' scripts/verify_pi.sh
! grep -Fq 'cmdline="$(tr '\''\0'\'' '\'' '\'' <"/proc/${owner_pid}/cmdline"' scripts/verify_pi.sh
! grep -q 'done <"/proc/${pid}/cmdline"' scripts/verify_pi.sh
! grep -q 'cat "/proc/${pid}/stat"' scripts/verify_pi.sh
! grep -q 'awk .*"/proc/${pid}/status"' scripts/verify_pi.sh
grep -q 'supervised_opencpn_pids' scripts/verify_pi.sh
grep -q 'check_opencpn_process_executable_integrity' scripts/verify_pi.sh
grep -q 'check_opencpn_process_display_environment' scripts/verify_pi.sh
grep -q 'read_proc_exe_path()' scripts/verify_pi.sh
grep -q 'target = os.readlink(proc_exe)' scripts/verify_pi.sh
grep -q 'resolved = Path(target).resolve(strict=True)' scripts/verify_pi.sh
grep -q 'read_proc_exe_path "$pid"' scripts/verify_pi.sh
grep -q 'proc_exe = f"/proc/{pid}/exe"' scripts/verify_pi.sh
! grep -Fq 'readlink -f "/proc/${pid}/exe"' scripts/verify_pi.sh
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
grep -q 'fields\[1\] == launcher_pid' scripts/verify_pi.sh
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
grep -q 'parses live launcher and OpenCPN process state, parentage, command lines, executable links, and environments as explicit `/proc` data' README.md
grep -q 'parses live launcher and OpenCPN process state, parentage, command lines, executable links, and environments as explicit `/proc` data' docs/sailboat-pi.md
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
grep -q 'display_power_command_path()' scripts/verify_pi.sh
grep -q 'check_display_power_command_integrity()' scripts/verify_pi.sh
grep -q 'display power command xset was not found on PATH' scripts/verify_pi.sh
grep -q 'display power command path is not absolute' scripts/verify_pi.sh
grep -q 'check_root_directory_integrity "$(dirname "$path")" "display power command directory"' scripts/verify_pi.sh
grep -q 'check_root_executable_file_integrity "$path" "display power command"' scripts/verify_pi.sh
grep -q 'xset_path="$(display_power_command_path)"' scripts/verify_pi.sh
grep -q 'DISPLAY="$display" XAUTHORITY="$xauthority" "$xset_path" q' scripts/verify_pi.sh
grep -q 'DISPLAY="$display" "$xset_path" q' scripts/verify_pi.sh
grep -q 'def _trusted_system_command' src/noaa_navionics/health.py
grep -q 'TRUSTED_SYSTEM_COMMAND_DIRS' src/noaa_navionics/health.py
grep -q '_trusted_system_command("xset", "Display Power command")' src/noaa_navionics/health.py
grep -q 'test_check_display_power_tool_rejects_user_owned_xset_on_pi' tests/test_downloader.py
grep -q 'trusted root-owned `xset` from `x11-xserver-utils`' README.md
grep -q 'trusted root-owned `xset`' docs/sailboat-pi.md
grep -q 'display screen saver timeout is not disabled' scripts/verify_pi.sh
grep -q 'display DPMS is not disabled' scripts/verify_pi.sh
grep -q 'launcher log shows OpenCPN exited after current-boot startup' scripts/verify_pi.sh
grep -q 'launcher log does not contain OpenCPN launch or duplicate marker' scripts/verify_pi.sh
grep -q 'pgrep -u "$(id -u)" -x opencpn' scripts/verify_pi.sh
grep -q 'opencpn_process_active' scripts/verify_pi.sh
grep -q 'raise SystemExit(0 if fields\[0\] != "Z" else 1)' scripts/verify_pi.sh
grep -q 'launcher-supervised OpenCPN running' scripts/verify_pi.sh
! grep -q 'check "OpenCPN running"' scripts/verify_pi.sh
grep -q 'status report JSON ready' scripts/verify_pi.sh
grep -q 'boot status report JSON ready' scripts/verify_pi.sh
grep -q 'status report has no gps_fix section' scripts/verify_pi.sh
grep -q 'status report gps_fix data does not match' scripts/verify_pi.sh
grep -q 'status report gps_fix latitude is outside -90..90' scripts/verify_pi.sh
grep -q 'status report gps_fix timestamp is stale' scripts/verify_pi.sh
grep -q 'status report gps_fix age_seconds is negative' scripts/verify_pi.sh
grep -q 'status report gps_fix age_seconds is stale' scripts/verify_pi.sh
grep -q 'status report gps_fix has no satellite or HDOP quality fields' scripts/verify_pi.sh
grep -q 'status report gps_fix source' scripts/verify_pi.sh
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
grep -q 'launcher settings matching a no-follow descriptor read of the same inspected live private launcher environment' README.md
grep -q 'launcher settings matching a no-follow descriptor read of the same inspected live private launcher environment' docs/sailboat-pi.md
grep -q 'onboard app config through a no-follow descriptor read' README.md
grep -q 'onboard app config through a no-follow descriptor read' docs/sailboat-pi.md
grep -q 'GPSD device comparisons through that same trusted config read path' README.md
grep -q 'GPSD device comparisons through that same trusted config read path' docs/sailboat-pi.md
grep -q 'recent GPX trackpoint verification uses that same trusted config read path' README.md
grep -q 'recent GPX trackpoint verification uses that same trusted config read path' docs/sailboat-pi.md
grep -q 'status report boot ID' scripts/verify_pi.sh
grep -q 'valid_boot_id(report_boot_id)' scripts/verify_pi.sh
grep -q 'current boot ID is not a Linux boot_id value' scripts/verify_pi.sh
grep -q 'BOOT_ID_RE.fullmatch' src/noaa_navionics/report.py
grep -q 'test_boot_id_rejects_malformed_values' tests/test_downloader.py
grep -q 'boot_id` UUID shape' README.md
grep -q 'boot_id` UUID shape' docs/sailboat-pi.md
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
grep -q '"anchor_radius_meters": float' scripts/verify_pi.sh
grep -q 'configured GPX track storage path contains a symlink' scripts/verify_pi.sh
grep -q 'is outside {expected_tracks_dir}' scripts/verify_pi.sh
grep -q 'is owned by uid' scripts/verify_pi.sh
grep -q 'expected private 0700' scripts/verify_pi.sh
grep -q 'status report track_log tracks_mode' scripts/verify_pi.sh
grep -q 'could not open status report track_log latest_path' scripts/verify_pi.sh
grep -q 'status report track_log latest_path changed before it could be verified' scripts/verify_pi.sh
grep -q 'latest_track_fd = os.open(latest_track_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))' scripts/verify_pi.sh
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
grep -q 'manifest-recorded and live regular non-symlink ENC cell counts' README.md
grep -q 'manifest-recorded and live regular non-symlink ENC cell counts' docs/sailboat-pi.md
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
grep -q 'def trusted_enc_cell_tree_count' scripts/verify_pi.sh
grep -q 'status report manifest extract {label} {candidate} has permissions' scripts/verify_pi.sh
grep -q '"extract_path_error"' src/noaa_navionics/report.py
grep -q 'test_manifest_summary_marks_writable_extract_tree' tests/test_downloader.py
grep -q 'user-owned non-writable extracted chart tree' README.md
grep -q 'user-owned non-writable extracted chart tree' docs/sailboat-pi.md
python3 - <<'PY'
from pathlib import Path
import os
import stat
import tempfile

text = Path("scripts/verify_pi.sh").read_text(encoding="utf-8")
start = text.index("def trusted_enc_cell_tree_count(path):")
end = text.index("\ndef normalize_path", start)
namespace = {"Path": Path, "os": os, "stat": stat}
exec(text[start:end], namespace)

with tempfile.TemporaryDirectory() as tmpdir:
    root = Path(tmpdir)
    charts = root / "charts"
    real_cell = charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
    real_cell.parent.mkdir(parents=True)
    real_cell.write_text("trusted chart cell", encoding="ascii")
    outside = root / "outside.000"
    outside.write_text("outside chart root", encoding="ascii")
    symlink_cell = charts / "AK_ENCs" / "US5AK4CM" / "US5AK4CM.000"
    symlink_cell.parent.mkdir(parents=True)
    try:
        symlink_cell.symlink_to(outside)
    except OSError as exc:
        raise SystemExit(f"could not create symlinked ENC test cell: {exc}") from exc

    try:
        namespace["trusted_enc_cell_tree_count"](charts)
    except SystemExit as exc:
        if "contains a symlink" not in str(exc):
            raise
    else:
        raise SystemExit("verify_pi trusted_enc_cell_tree_count accepted a symlinked ENC cell")

with tempfile.TemporaryDirectory() as tmpdir:
    charts = Path(tmpdir) / "charts"
    cell = charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
    cell.parent.mkdir(parents=True)
    cell.write_text("trusted chart cell", encoding="ascii")
    cell.chmod(0o666)
    try:
        namespace["trusted_enc_cell_tree_count"](charts)
    except SystemExit as exc:
        if "has permissions 0666" not in str(exc):
            raise
    else:
        raise SystemExit("verify_pi trusted_enc_cell_tree_count accepted a writable ENC cell")
PY
grep -q 'expected exactly {manifest_file_enc_cell_count}' scripts/verify_pi.sh
grep -q 'exact live regular non-symlink ENC cell count' README.md
grep -q 'exact live regular non-symlink ENC cell count' docs/sailboat-pi.md
grep -q 'path.is_file() and not path.is_symlink()' src/noaa_navionics/downloader.py
grep -q 'path.is_symlink() or not path.is_file()' src/noaa_navionics/health.py
grep -q 'test_count_enc_cells_ignores_symlinked_cells' tests/test_downloader.py
grep -q 'test_manifest_symlinked_enc_cell_does_not_satisfy_count' tests/test_downloader.py
grep -q 'test_chart_check_ignores_symlinked_enc_cells' tests/test_downloader.py
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
grep -q 'temperature sensor returned a non-finite value' src/noaa_navionics/health.py
grep -q 'throttling reported since boot' src/noaa_navionics/health.py
grep -q '_trusted_system_command("vcgencmd", "Pi power command")' src/noaa_navionics/health.py
grep -q 'test_check_pi_throttling_rejects_user_owned_vcgencmd_on_pi' tests/test_downloader.py
grep -q 're.fullmatch(r"throttled=' src/noaa_navionics/health.py
grep -Fq '[[ ! "$output" =~ ^throttled=(0x[[:xdigit:]]+|[0-9]+)$ ]]' scripts/verify_pi.sh
! grep -q 'healthy now; historical events' src/noaa_navionics/health.py
grep -q 'measure_temp' src/noaa_navionics/health.py
grep -q "re.fullmatch(r\"temp=.*'C\"" src/noaa_navionics/health.py
grep -q 'math.isfinite(temperature)' src/noaa_navionics/health.py
grep -q 'vcgencmd measure_temp' README.md
grep -q 'vcgencmd measure_temp' docs/sailboat-pi.md
grep -q 'well-formed `vcgencmd get_throttled` value' README.md
grep -q 'well-formed `vcgencmd get_throttled` value' docs/sailboat-pi.md
grep -q 'well-formed finite `vcgencmd measure_temp` value' README.md
grep -q 'well-formed finite `vcgencmd measure_temp` value' docs/sailboat-pi.md
grep -q '"GPSD Config"' scripts/verify_pi.sh
grep -q 'status report missing service checks' scripts/verify_pi.sh
grep -q '"Chart Sync Settings"' scripts/verify_pi.sh
grep -q '"Chart Sync Unit File"' scripts/verify_pi.sh
grep -q '"Chart Timer Settings"' scripts/verify_pi.sh
grep -q '"Chart Timer Unit File"' scripts/verify_pi.sh
grep -q '"Chart Timer Install"' scripts/verify_pi.sh
grep -q '"Track Logger Settings"' scripts/verify_pi.sh
grep -q '"Track Logger Unit File"' scripts/verify_pi.sh
grep -q '"Track Logger Install"' scripts/verify_pi.sh
grep -q '"Boot Readiness Settings"' scripts/verify_pi.sh
grep -q '"Boot Readiness Unit File"' scripts/verify_pi.sh
grep -q '"Boot Readiness Run"' scripts/verify_pi.sh
grep -q '"Boot Readiness Install"' scripts/verify_pi.sh
grep -q 'installed unit-file directives' README.md
grep -q 'full core readiness/service/unit-file/loaded-setting/service-run check names' README.md
grep -q 'installed unit-file directives' docs/sailboat-pi.md
grep -q 'full core readiness/service/unit-file/loaded-setting/service-run checks' docs/sailboat-pi.md
grep -q '"Desktop Startup"' scripts/verify_pi.sh
grep -q '"Launcher Settings"' scripts/verify_pi.sh
grep -q 'status report has no unit_files section' scripts/verify_pi.sh
grep -q 'status report {unit} path is a symlink' scripts/verify_pi.sh
grep -q 'status report {unit} directory is a symlink' scripts/verify_pi.sh
grep -q 'status report {unit} uid' scripts/verify_pi.sh
grep -q 'status report {unit} directory_uid' scripts/verify_pi.sh
grep -q 'status report {unit} mode' scripts/verify_pi.sh
grep -q 'status report {unit} directory_mode' scripts/verify_pi.sh
grep -q 'status report {unit} has no parsed unit file lines' scripts/verify_pi.sh
grep -q 'status report {unit} lines do not match live unit file' scripts/verify_pi.sh
grep -q 'expected no group/other write bits' scripts/verify_pi.sh
grep -q 'def install_wanted_by_targets' scripts/verify_pi.sh
grep -q 'unit_text, unit_stat = read_trusted_text_file' scripts/verify_pi.sh
grep -q 'live_wanted_by = install_wanted_by_targets' scripts/verify_pi.sh
grep -q 'does not match live unit file' scripts/verify_pi.sh
grep -q 'GPSD device matches config' scripts/verify_pi.sh
grep -q 'volatile; use /dev/serial/by-id/' scripts/verify_pi.sh
grep -q 'check_root_command_integrity()' scripts/verify_pi.sh
grep -q 'root_command_path()' scripts/verify_pi.sh
grep -q 'systemctl_command()' scripts/verify_pi.sh
grep -q 'loginctl_command()' scripts/verify_pi.sh
grep -q 'chronyc_command()' scripts/verify_pi.sh
grep -q 'python3_command()' scripts/verify_pi.sh
grep -q 'check_root_directory_integrity "$(dirname "$path")" "${label} directory"' scripts/verify_pi.sh
grep -q 'check_root_executable_file_integrity "$path" "$label"' scripts/verify_pi.sh
grep -q 'check "Python command integrity" python3_command' scripts/verify_pi.sh
grep -q 'python3_cmd="$(python3_command)" || python3_cmd="/bin/false"' scripts/verify_pi.sh
grep -q 'check "display power command integrity" check_display_power_command_integrity' scripts/verify_pi.sh
! grep -q 'check "display power command" command -v xset' scripts/verify_pi.sh
! grep -q 'DISPLAY="$display" XAUTHORITY="$xauthority" xset q' scripts/verify_pi.sh
! grep -q 'DISPLAY="$display" xset q' scripts/verify_pi.sh
grep -q 'check "process lookup command integrity" check_root_command_integrity pgrep "process lookup command"' scripts/verify_pi.sh
grep -q 'check "Pi power command integrity" check_root_command_integrity vcgencmd "Pi power command"' scripts/verify_pi.sh
grep -q 'check "Systemctl command integrity" systemctl_command' scripts/verify_pi.sh
grep -q 'check "Loginctl command integrity" loginctl_command' scripts/verify_pi.sh
grep -q 'systemctl_cmd="$(systemctl_command)" || systemctl_cmd="/bin/false"' scripts/verify_pi.sh
grep -q 'loginctl_cmd="$(loginctl_command)" || loginctl_cmd="/bin/false"' scripts/verify_pi.sh
grep -q 'check "Chrony command integrity" chronyc_command' scripts/verify_pi.sh
grep -q 'chronyc_path="$(chronyc_command)" || return 1' scripts/verify_pi.sh
grep -q 'systemctl_path="$(systemctl_command)" || return 1' scripts/verify_pi.sh
grep -q 'check "Chrony service enabled" "$systemctl_cmd" is-enabled --quiet chrony' scripts/verify_pi.sh
grep -q 'check "GPSD socket enabled" "$systemctl_cmd" is-enabled --quiet gpsd.socket' scripts/verify_pi.sh
grep -q 'check "LightDM enabled" "$systemctl_cmd" is-enabled --quiet lightdm.service' scripts/verify_pi.sh
grep -q 'check "chart timer enabled" "$systemctl_cmd" --user is-enabled --quiet noaa-navionics.timer' scripts/verify_pi.sh
grep -q 'check "user linger enabled" sh -c' scripts/verify_pi.sh
grep -q '"$loginctl_cmd" "$USER"' scripts/verify_pi.sh
grep -q 'loaded_unit_property_equals()' scripts/verify_pi.sh
grep -q 'loaded_unit_property_contains_all()' scripts/verify_pi.sh
grep -q 'loaded="$("$systemctl_cmd" --user show "$unit" -p "$property" 2>/dev/null)"' scripts/verify_pi.sh
grep -q 'check "chart service loaded fragment path" loaded_unit_property_equals noaa-navionics.service FragmentPath "$chart_service"' scripts/verify_pi.sh
grep -q 'check "chart service loaded network wait command" loaded_unit_property_contains_all noaa-navionics.service ExecStartPre' scripts/verify_pi.sh
grep -q 'check "track service loaded rotate daily" loaded_unit_property_contains_all noaa-navionics-track.service ExecStart' scripts/verify_pi.sh
grep -q 'check "preflight service loaded status report" loaded_unit_property_contains_all noaa-navionics-preflight.service ExecStart' scripts/verify_pi.sh
! grep -q 'check "Chrony command integrity" check_root_command_integrity chronyc "Chrony command"' scripts/verify_pi.sh
! grep -q 'check "LightDM enabled" systemctl is-enabled --quiet lightdm.service' scripts/verify_pi.sh
! grep -q 'check "GPSD socket enabled" systemctl is-enabled --quiet gpsd.socket' scripts/verify_pi.sh
! grep -q 'check "chart timer enabled" systemctl --user is-enabled --quiet noaa-navionics.timer' scripts/verify_pi.sh
! grep -q 'chronyc sources -n' scripts/verify_pi.sh
! grep -q "sh -c 'systemctl --user show" scripts/verify_pi.sh
! grep -q 'loaded="$(systemctl --user show' scripts/verify_pi.sh
grep -q 'check "GPSD command integrity" check_root_command_integrity gpsd "GPSD command"' scripts/verify_pi.sh
grep -q 'check "GPSD client command integrity" check_root_command_integrity cgps "GPSD client command"' scripts/verify_pi.sh
grep -q '"$python3_cmd" - "$path" "$require_current_boot" "$expected_config_path" "$expected_launcher_env_path"' scripts/verify_pi.sh
grep -q '"$python3_cmd" - "$launcher_env" "$key" "$default"' scripts/verify_pi.sh
! grep -Eq '(^|[[:space:]])python3[[:space:]]+-' scripts/verify_pi.sh
! grep -q 'check "process lookup command" command -v pgrep' scripts/verify_pi.sh
! grep -q 'check "Pi power command" command -v vcgencmd' scripts/verify_pi.sh
! grep -q 'check "Chrony command" command -v chronyc' scripts/verify_pi.sh
! grep -q 'check "GPSD command" command -v gpsd' scripts/verify_pi.sh
! grep -q 'check "GPSD client command" command -v cgps' scripts/verify_pi.sh
grep -q 'trusted root-owned `python3`, `systemctl`, `loginctl`, `pgrep`, `vcgencmd`, `chronyc`, `gpsd`, and `cgps` commands' README.md
grep -q 'installed root-owned command dependencies' docs/sailboat-pi.md
grep -q 'resolves `python3`, `systemctl`, `loginctl`, and `chronyc` through trusted root-owned command checks' docs/sailboat-pi.md
grep -q 'check_raspberry_pi_throttling_state' scripts/verify_pi.sh
grep -q 'vcgencmd get_throttled failed' scripts/verify_pi.sh
grep -q 'unexpected vcgencmd get_throttled output' scripts/verify_pi.sh
grep -q 'Raspberry Pi power or thermal throttling reported since boot' scripts/verify_pi.sh
grep -q 'Pi power state' scripts/verify_pi.sh
grep -q 'local bin directory integrity' scripts/verify_pi.sh
grep -q 'app data directory integrity' scripts/verify_pi.sh
grep -q 'app config directory integrity' scripts/verify_pi.sh
grep -q 'private venv directory integrity' scripts/verify_pi.sh
grep -q 'check_command_symlink_to_private_venv' scripts/verify_pi.sh
grep -q 'noaa-navionics command symlink' scripts/verify_pi.sh
grep -q 'noaa-navionics GUI command symlink' scripts/verify_pi.sh
grep -q 'status_gui_bin="${HOME}/.local/bin/noaa-navionics-status-gui"' scripts/verify_pi.sh
grep -q 'noaa-navionics status GUI command symlink' scripts/verify_pi.sh
grep -q '${venv_dir}/bin/noaa-navionics-status-gui' scripts/verify_pi.sh
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
grep -q 'chartplotter launcher trusted PATH' scripts/verify_pi.sh
grep -q 'chartplotter launcher Pi PATH pin' scripts/verify_pi.sh
grep -q 'chartplotter launcher trusted Python resolver' scripts/verify_pi.sh
grep -q 'chartplotter launcher Python path resolver' scripts/verify_pi.sh
grep -q 'chartplotter launcher resolved Python trust check' scripts/verify_pi.sh
grep -q 'chartplotter launcher Python resolution command' scripts/verify_pi.sh
grep -q 'chartplotter launcher resolved Python execution' scripts/verify_pi.sh
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
grep -q 'chartplotter launcher lock descriptor write' scripts/verify_pi.sh
grep -q 'chartplotter launcher lock directory sync create' scripts/verify_pi.sh
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
grep -q 'check "LightDM active after boot" "$systemctl_cmd" is-active --quiet lightdm.service' scripts/verify_pi.sh
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
grep -q 'chart service restart delay' scripts/verify_pi.sh
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
grep -q 'track service restart delay' scripts/verify_pi.sh
grep -q 'track service loaded restart delay' scripts/verify_pi.sh
grep -q 'track service start limit burst' scripts/verify_pi.sh
grep -q 'track service loaded start limit interval' scripts/verify_pi.sh
grep -q 'track service loaded start limit burst' scripts/verify_pi.sh
grep -q 'track service install target' scripts/verify_pi.sh
grep -q 'track service active' scripts/verify_pi.sh
grep -q 'preflight service status report' scripts/verify_pi.sh
grep -q 'preflight service no systemd GPS environment' scripts/verify_pi.sh
grep -q 'preflight service loaded fragment path' scripts/verify_pi.sh
grep -q 'preflight service loaded no systemd GPS environment' scripts/verify_pi.sh
grep -q 'preflight service loaded restart' scripts/verify_pi.sh
grep -q -- '--gps-seconds-from-launcher-env' scripts/verify_pi.sh
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
grep -q 'GPSD by-id device is symlink' scripts/verify_pi.sh
grep -q 'GPSD device is character device' scripts/verify_pi.sh
grep -q 'GPSD client command integrity' scripts/verify_pi.sh
grep -q 'GPSD socket enabled' scripts/verify_pi.sh
grep -q 'GPSD socket active' scripts/verify_pi.sh
grep -Fq 'suffix="${1#/dev/serial/by-id/}"' scripts/verify_pi.sh
grep -Fq '"$suffix" != */*' scripts/verify_pi.sh
grep -q 'def check_gpsd_startup_config' src/noaa_navionics/health.py
grep -q 'GPSD config directory is a symlink' src/noaa_navionics/health.py
grep -q 'GPSD config path is not a regular file' src/noaa_navionics/health.py
grep -q 'GPSD config .* is owned by uid' src/noaa_navionics/health.py
grep -q 'GPSD config .* has permissions' src/noaa_navionics/health.py
grep -q 'GPSD config changed before it could be read' tests/test_downloader.py
grep -q 'test_check_gpsd_startup_config_rejects_replaced_config_before_parsing' tests/test_downloader.py
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
grep -q 'require_trusted_system_command()' scripts/configure_desktop_autologin.sh
grep -q 'path_in_trusted_system_dir()' scripts/configure_desktop_autologin.sh
grep -q 'systemctl_cmd="$(require_trusted_system_command systemctl "Systemctl command")"' scripts/configure_desktop_autologin.sh
grep -q 'sudo_cmd="$(require_trusted_system_command sudo "Sudo command")"' scripts/configure_desktop_autologin.sh
grep -q 'python3_cmd="$(require_trusted_system_command python3 "Python command")"' scripts/configure_desktop_autologin.sh
grep -q 'sudo_cmd="$(sudo_command)" || exit 2' scripts/configure_desktop_autologin.sh
grep -q 'systemctl_cmd="$(systemctl_command)" || exit 2' scripts/configure_desktop_autologin.sh
grep -q 'python3_cmd="$(python3_command)" || exit 2' scripts/configure_desktop_autologin.sh
grep -q '"$python3_cmd" - "$lightdm_dir" "$lightdm_conf_dir" "$autologin_conf" "$dry_run"' scripts/configure_desktop_autologin.sh
grep -q '"$python3_cmd" - "$autologin_user"' scripts/configure_desktop_autologin.sh
grep -q '"$sudo_cmd" "$python3_cmd" - "$path"' scripts/configure_desktop_autologin.sh
grep -q '"$sudo_cmd" "$python3_cmd" - "$source" "$target" "$mode"' scripts/configure_desktop_autologin.sh
grep -q 'run "$sudo_cmd" "$systemctl_cmd" set-default graphical.target' scripts/configure_desktop_autologin.sh
grep -q 'run "$sudo_cmd" "$systemctl_cmd" enable lightdm.service' scripts/configure_desktop_autologin.sh
! grep -q 'run sudo systemctl' scripts/configure_desktop_autologin.sh
! grep -Eq '(^|[[:space:]])python3[[:space:]]+-' scripts/configure_desktop_autologin.sh
! grep -q '"$sudo_cmd" python3' scripts/configure_desktop_autologin.sh
grep -q 'Desktop autologin setup resolves sudo, systemctl, and Python through trusted root-owned command checks' README.md
grep -q 'Desktop autologin setup resolves sudo, systemctl, and Python through trusted root-owned command checks' docs/sailboat-pi.md
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/configure_desktop_autologin.sh").read_text(encoding="utf-8")
python_resolve = text.index('python3_cmd="$(python3_command)" || exit 2')
user_validate = text.index('"$python3_cmd" - "$autologin_user"', python_resolve)
path_validate = text.index('validate_lightdm_autologin_path', user_validate)
sudo_resolve = text.index('sudo_cmd="$(sudo_command)" || exit 2', path_validate)
systemctl_resolve = text.index('systemctl_cmd="$(systemctl_command)" || exit 2', sudo_resolve)
install = text.index('install_root_file_atomic "$tmp" "$autologin_conf" 0644', systemctl_resolve)
target = text.index('run "$sudo_cmd" "$systemctl_cmd" set-default graphical.target', install)
if not python_resolve < user_validate < path_validate < sudo_resolve < systemctl_resolve < install < target:
    raise SystemExit("desktop autologin setup must validate Python before helper checks and sudo/systemctl before root changes")
PY
grep -q 'install_root_file_atomic "$tmp" "$autologin_conf" 0644' scripts/configure_desktop_autologin.sh
grep -q 'validate_lightdm_autologin_path' scripts/configure_desktop_autologin.sh
test "$(grep -c 'validate_lightdm_autologin_path' scripts/configure_desktop_autologin.sh)" -ge 5
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
grep -q 'GPS by-id device path is not a symlink' scripts/configure_gpsd.sh
grep -q 'GPS device path is not a character device' scripts/configure_gpsd.sh
grep -q 'validate_updated_app_config' scripts/configure_gpsd.sh
grep -q 'prepare_app_config_path' scripts/configure_gpsd.sh
grep -q 'validate_gpsd_config_path' scripts/configure_gpsd.sh
test "$(grep -c 'validate_gpsd_config_path' scripts/configure_gpsd.sh)" -ge 5
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
grep -q 'require_trusted_system_command()' scripts/configure_gpsd.sh
grep -q 'path_in_trusted_system_dir()' scripts/configure_gpsd.sh
grep -q 'systemctl_cmd="$(require_trusted_system_command systemctl "Systemctl command")"' scripts/configure_gpsd.sh
grep -q 'sudo_cmd="$(require_trusted_system_command sudo "Sudo command")"' scripts/configure_gpsd.sh
grep -q 'python3_cmd="$(require_trusted_system_command python3 "Python command")"' scripts/configure_gpsd.sh
grep -q 'sudo_cmd="$(sudo_command)" || exit 2' scripts/configure_gpsd.sh
grep -q 'systemctl_cmd="$(systemctl_command)" || exit 2' scripts/configure_gpsd.sh
grep -q 'python3_cmd="$(python3_command)" || exit 2' scripts/configure_gpsd.sh
grep -q '"$python3_cmd" - "$repo_root" "$config" "$device"' scripts/configure_gpsd.sh
grep -q '"$python3_cmd" - "$repo_root" "$config" "$dry_run"' scripts/configure_gpsd.sh
grep -q '"$python3_cmd" - "$gpsd_conf" "$dry_run"' scripts/configure_gpsd.sh
grep -q '"$sudo_cmd" "$python3_cmd" - "$path"' scripts/configure_gpsd.sh
grep -q '"$sudo_cmd" "$python3_cmd" - "$source" "$target" "$mode"' scripts/configure_gpsd.sh
grep -q '"$sudo_cmd" "$python3_cmd" - "$source" "$backup"' scripts/configure_gpsd.sh
grep -q '"$sudo_cmd" "$systemctl_cmd" daemon-reload' scripts/configure_gpsd.sh
grep -q '"$sudo_cmd" "$systemctl_cmd" enable --now gpsd.socket gpsd.service' scripts/configure_gpsd.sh
grep -q '"$sudo_cmd" "$systemctl_cmd" restart gpsd.socket gpsd.service' scripts/configure_gpsd.sh
! grep -q 'sudo systemctl' scripts/configure_gpsd.sh
! grep -q '"$sudo_cmd" python3' scripts/configure_gpsd.sh
! grep -Eq '(^|[[:space:]])python3[[:space:]]+-' scripts/configure_gpsd.sh
grep -q 'backup_root_file_private "$gpsd_conf" "$backup"' scripts/configure_gpsd.sh
grep -q 'os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow, 0o600' scripts/configure_gpsd.sh
grep -q 'os.fchmod(dst_fd, 0o600)' scripts/configure_gpsd.sh
! grep -q 'sudo cp -a /etc/default/gpsd' scripts/configure_gpsd.sh
grep -q 'GPSD setup resolves sudo, systemctl, and Python through trusted root-owned command checks' README.md
grep -q 'GPSD setup resolves sudo, systemctl, and Python through trusted root-owned command checks' docs/sailboat-pi.md
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/configure_gpsd.sh").read_text(encoding="utf-8")
python_resolve = text.index('python3_cmd="$(python3_command)" || exit 2')
prepare = text.index('prepare_app_config_path', python_resolve)
validate_app = text.index('validate_updated_app_config', python_resolve)
validate_gpsd = text.index('validate_gpsd_config_path', python_resolve)
sudo_resolve = text.index('sudo_cmd="$(sudo_command)" || exit 2', validate_gpsd)
systemctl_resolve = text.index('systemctl_cmd="$(systemctl_command)" || exit 2', sudo_resolve)
backup = text.index('backup_root_file_private "$gpsd_conf" "$backup"')
install = text.index('install_root_file_atomic "$tmp" "$gpsd_conf" 0644')
reload = text.index('"$sudo_cmd" "$systemctl_cmd" daemon-reload')
if not python_resolve < prepare < validate_app < validate_gpsd < sudo_resolve < systemctl_resolve < backup < install < reload:
    raise SystemExit("GPSD setup must validate Python before app/GPSD config helpers and sudo/systemctl before root changes")
PY
grep -q 'revalidate root target paths before temporary-file creation and immediately before promotion' README.md
grep -q 'revalidate root target paths before temporary-file creation and immediately before promotion' docs/sailboat-pi.md
grep -q 'tempfile.NamedTemporaryFile' scripts/configure_gpsd.sh
grep -q 'dir=str(config_path.parent)' scripts/configure_gpsd.sh
grep -q 'os.chmod(tmp_path, 0o600)' scripts/configure_gpsd.sh
grep -q 'os.replace(tmp_path, config_path)' scripts/configure_gpsd.sh
for script in scripts/configure_gpsd.sh scripts/configure_gps_time.sh scripts/configure_desktop_autologin.sh; do
  grep -q 'install_root_file_atomic' "$script"
  grep -q 'verify_promoted_root_file' "$script"
  grep -q 'verify_root_temp_file' "$script"
  grep -q '"$sudo_cmd" mktemp "${target_dir}/.${target_name}.XXXXXX"' "$script"
  grep -q 'verify_root_temp_file "$target_tmp" 0600' "$script"
  grep -q '"$sudo_cmd" install -m "$mode" "$source" "$target_tmp"' "$script"
  grep -q 'verify_root_temp_file "$target_tmp" "$mode"' "$script"
  grep -q 'sync_path "$target_tmp"' "$script"
  grep -q '"$sudo_cmd" mv -f "$target_tmp" "$target"' "$script"
  grep -q 'verify_promoted_root_file "$source" "$target" "$mode"' "$script"
  grep -q 'sync_path "$target"' "$script"
  grep -q 'sudo_command()' "$script"
  grep -q 'python3_command()' "$script"
  grep -q 'python3_cmd="$(require_trusted_system_command python3 "Python command")"' "$script"
  grep -q '"$sudo_cmd" "$python3_cmd" -' "$script"
  ! grep -q '"$sudo_cmd" python3' "$script"
  grep -q 'root file sync target is a symlink' "$script"
  grep -q 'root file sync target is not a regular file' "$script"
  grep -q 'root config temporary file is a symlink' "$script"
  grep -q 'root config temporary file is not a regular file' "$script"
  grep -q 'root config temporary file .* expected root' "$script"
  grep -q 'root config temporary file .* expected {expected_mode:04o}' "$script"
  grep -q 'promoted root config does not match source' "$script"
  grep -q 'promoted root config.*expected' "$script"
  grep -q 'os.open(path, os.O_RDONLY | nofollow)' "$script"
  grep -q 'stat.S_ISREG(opened.st_mode)' "$script"
  ! grep -q 'with path.open("rb") as handle' "$script"
done
grep -q 'validate_existing_gps_config' scripts/provision_sailboat_pi.sh
grep -q 'validate_gps_device_path_arg' scripts/provision_sailboat_pi.sh
grep -q 'GPS device path is volatile' scripts/provision_sailboat_pi.sh
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
grep -q 'GPS by-id device path is not a symlink' scripts/provision_sailboat_pi.sh
grep -q 'validate_existing_gps_time_config' scripts/provision_sailboat_pi.sh
grep -q 'require_trusted_system_command()' scripts/configure_gps_time.sh
grep -q 'path_in_trusted_system_dir()' scripts/configure_gps_time.sh
grep -q 'systemctl_cmd="$(require_trusted_system_command systemctl "Systemctl command")"' scripts/configure_gps_time.sh
grep -q 'sudo_cmd="$(require_trusted_system_command sudo "Sudo command")"' scripts/configure_gps_time.sh
grep -q 'python3_cmd="$(require_trusted_system_command python3 "Python command")"' scripts/configure_gps_time.sh
grep -q 'sudo_cmd="$(sudo_command)" || exit 2' scripts/configure_gps_time.sh
grep -q 'systemctl_cmd="$(systemctl_command)" || exit 2' scripts/configure_gps_time.sh
grep -q 'python3_cmd="$(python3_command)" || exit 2' scripts/configure_gps_time.sh
grep -q '"$python3_cmd" - "$chrony_conf" "$dry_run"' scripts/configure_gps_time.sh
grep -q '"$python3_cmd" - "$chrony_conf" "$tmp" "$dry_run"' scripts/configure_gps_time.sh
grep -q '"$sudo_cmd" "$python3_cmd" - "$path"' scripts/configure_gps_time.sh
grep -q '"$sudo_cmd" "$python3_cmd" - "$source" "$target" "$mode"' scripts/configure_gps_time.sh
grep -q '"$sudo_cmd" "$python3_cmd" - "$source" "$backup"' scripts/configure_gps_time.sh
grep -q '"$sudo_cmd" "$systemctl_cmd" enable --now chrony' scripts/configure_gps_time.sh
grep -q '"$sudo_cmd" "$systemctl_cmd" restart chrony' scripts/configure_gps_time.sh
grep -q '"$sudo_cmd" "$systemctl_cmd" restart gpsd.socket gpsd.service' scripts/configure_gps_time.sh
! grep -q 'sudo systemctl' scripts/configure_gps_time.sh
! grep -Eq '(^|[[:space:]])python3[[:space:]]+-' scripts/configure_gps_time.sh
! grep -q '"$sudo_cmd" python3' scripts/configure_gps_time.sh
grep -q 'GPS time setup resolves sudo, systemctl, and Python through trusted root-owned command checks' README.md
grep -q 'GPS time setup resolves sudo, systemctl, and Python through trusted root-owned command checks' docs/sailboat-pi.md
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/configure_gps_time.sh").read_text(encoding="utf-8")
python_resolve = text.index('python3_cmd="$(python3_command)" || exit 2')
validate = text.index('validate_chrony_config_path', python_resolve)
generate = text.index('"$python3_cmd" - "$chrony_conf" "$tmp" "$dry_run"', validate)
sudo_resolve = text.index('sudo_cmd="$(sudo_command)" || exit 2', generate)
systemctl_resolve = text.index('systemctl_cmd="$(systemctl_command)" || exit 2', sudo_resolve)
backup = text.index('backup_root_file_private "$chrony_conf" "$backup"', systemctl_resolve)
install = text.index('install_root_file_atomic "$tmp" "$chrony_conf" 0644', backup)
restart = text.index('"$sudo_cmd" "$systemctl_cmd" restart chrony', install)
if not python_resolve < validate < generate < sudo_resolve < systemctl_resolve < backup < install < restart:
    raise SystemExit("GPS time setup must validate Python before chrony config helpers and sudo/systemctl before root changes")
PY
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
grep -q 'verify_installed_noaa_navionics_command "$bin" "${venv_dir}/bin/noaa-navionics"' scripts/provision_sailboat_pi.sh
grep -q 'installed noaa-navionics command must resolve to the private venv command' scripts/provision_sailboat_pi.sh
! grep -q 'command -v noaa-navionics' scripts/provision_sailboat_pi.sh
grep -q 'path contains a symlink' scripts/provision_sailboat_pi.sh
grep -q 'expected no group/other write bits' scripts/provision_sailboat_pi.sh
grep -q 'validate_user_install_path "$launcher_env" "chartplotter launcher environment"' scripts/provision_sailboat_pi.sh
grep -q 'validate_user_install_path "$chart_service" "chart refresh user service"' scripts/provision_sailboat_pi.sh
grep -q 'validate_user_install_path "$autostart_entry" "chartplotter desktop autostart"' scripts/provision_sailboat_pi.sh
grep -q -- '--no-device-check cannot be used while unattended startup is enabled' scripts/provision_sailboat_pi.sh
grep -q 'pass both --skip-services and --skip-autologin for manual testing' scripts/provision_sailboat_pi.sh
grep -q 'refclock SHM 0 offset 0.5 delay 0.1 refid GPS' scripts/configure_gps_time.sh
! grep -q 'sudo "$systemctl_cmd" restart gpsd' scripts/configure_gps_time.sh
grep -q 'Do not configure GPS time as root' scripts/configure_gps_time.sh
grep -q 'validate_chrony_config_path' scripts/configure_gps_time.sh
test "$(grep -c 'validate_chrony_config_path' scripts/configure_gps_time.sh)" -ge 5
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
! grep -q 'sudo mkdir -p "$(dirname "$chrony_conf")"' scripts/configure_gps_time.sh
! grep -q 'source.read_text(encoding="utf-8")' scripts/configure_gps_time.sh
! grep -q 'sudo cp -a "$chrony_conf"' scripts/configure_gps_time.sh
grep -q 'status_attempts=3' scripts/verify_pi.sh
grep -q 'Time Sync' src/noaa_navionics/health.py
grep -q 'Source Revision' src/noaa_navionics/health.py
grep -q 'NOAA_NAVIONICS_SOURCE_REVISION_PATH' src/noaa_navionics/health.py
grep -q 'deployed source revision path is a symlink' src/noaa_navionics/health.py
grep -q 'deployed source revision is not recorded' src/noaa_navionics/health.py
grep -q 'SystemClockSynchronized' src/noaa_navionics/health.py
grep -q '_trusted_system_command("timedatectl", "Time sync command")' src/noaa_navionics/health.py
grep -q 'test_check_time_synchronization_rejects_user_owned_timedatectl_on_pi' tests/test_downloader.py
grep -q 'GPS Time Source' src/noaa_navionics/health.py
grep -q 'def check_chrony_gps_time_config' src/noaa_navionics/health.py
grep -q 'check_chrony_gps_time_config()' src/noaa_navionics/health.py
grep -q 'check_chrony_gps_time_source(seconds=gps_seconds)' src/noaa_navionics/health.py
grep -q '_trusted_system_command("chronyc", "Chrony command")' src/noaa_navionics/health.py
grep -q 'test_check_chrony_gps_time_source_rejects_user_owned_chronyc_on_pi' tests/test_downloader.py
grep -q 'CHRONY_GPSD_REFCLOCK' src/noaa_navionics/health.py
grep -q 'Chrony config is not a regular file' src/noaa_navionics/health.py
grep -q 'Chrony config .* is owned by uid' src/noaa_navionics/health.py
grep -q 'Chrony config .* has permissions' src/noaa_navionics/health.py
grep -q 'def _read_trusted_config_lines' src/noaa_navionics/health.py
grep -q 'flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/health.py
grep -q 'expected_stat: Optional\[os.stat_result\] = None' src/noaa_navionics/health.py
grep -q 'Chrony config changed before it could be read' tests/test_downloader.py
grep -q 'test_check_chrony_gps_time_config_rejects_replaced_config_before_parsing' tests/test_downloader.py
grep -q 'test_read_trusted_config_lines_rejects_replaced_config_before_parsing' tests/test_downloader.py
grep -q 'test_check_chrony_gps_time_config_accepts_managed_refclock' tests/test_downloader.py
grep -q 'test_check_chrony_gps_time_config_rejects_writable_config' tests/test_downloader.py
grep -q 'test_read_trusted_config_lines_rejects_writable_config_before_parsing' tests/test_downloader.py
grep -q 'Readiness compares GPSD and chrony config no-follow descriptors against the inspected file' README.md
grep -q 'Readiness compares GPSD and chrony config no-follow descriptors against the inspected file' docs/sailboat-pi.md
grep -q 'GPS time setup reads existing chrony config, and readiness and production skip checks read GPSD and chrony config files, only after a no-follow descriptor' README.md
grep -q 'GPS time setup reads existing chrony config, and readiness and production skip checks read GPSD and chrony config files, only after a no-follow descriptor' docs/sailboat-pi.md
grep -q 'GPSD setup, GPS time setup, and desktop autologin revalidate root target paths before temporary-file creation and immediately before promotion' README.md
grep -q 'verify their root-owned temporary config files through no-follow descriptors before and after copying content' README.md
grep -q 'Promoted root config files are verified against their source through regular no-follow file descriptors before syncing' docs/sailboat-pi.md
grep -q 'verify root-owned temporary config files through no-follow descriptors before and after copying content' docs/sailboat-pi.md
grep -q 'verifies the promoted config against its source through regular no-follow file descriptors before syncing' docs/sailboat-pi.md
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
grep -q 'if age_seconds < 0.0:' src/noaa_navionics/health.py
grep -q 'test_check_gpsd_rejects_future_timestamped_fix' tests/test_downloader.py
grep -q 'NMEA fix missing satellite or HDOP quality fields' src/noaa_navionics/health.py
grep -q 'def _rmc_mode_has_fix' src/noaa_navionics/gps.py
grep -q 'test_parse_rmc_rejects_non_navigation_mode_fix' tests/test_downloader.py
grep -q 'explicit RMC simulator/manual/estimated/no-fix mode flags' README.md
grep -q 'explicit RMC simulator/manual/estimated/no-fix mode flags' docs/sailboat-pi.md
grep -q 'sentence_type == "GSA"' src/noaa_navionics/gps.py
grep -q 'def _parse_gsa' src/noaa_navionics/gps.py
grep -q 'test_parse_nmea_gsa_quality' tests/test_downloader.py
grep -q 'test_check_gps_device_accepts_rmc_with_gsa_quality' tests/test_downloader.py
grep -q 'test_check_gps_sample_rejects_missing_quality_fields' tests/test_downloader.py
grep -q 'test_check_gps_device_rejects_missing_quality_fields' tests/test_downloader.py
grep -q 'GPSD and direct NMEA readiness require satellite-count or HDOP quality fields' README.md
grep -q 'GPSD and direct NMEA readiness require satellite-count or HDOP quality fields' docs/sailboat-pi.md
grep -q 'Direct NMEA readiness accepts GGA position/quality fixes and RMC position fixes merged with GSA satellite/HDOP quality' README.md
grep -q 'Direct NMEA readiness accepts GGA position/quality fixes and RMC position fixes merged with GSA satellite/HDOP quality' docs/sailboat-pi.md
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
grep -q 'def _trusted_enc_cell_tree_count' src/noaa_navionics/health.py
grep -q 'manifest extract {label} {path} has permissions' src/noaa_navionics/health.py
grep -q 'test_manifest_writable_enc_cell_fails' tests/test_downloader.py
grep -q 'test_manifest_writable_extract_directory_fails' tests/test_downloader.py
grep -q 'live chart tree is user-owned with no group/other write bits' README.md
grep -q 'live chart tree is user-owned with no group/other write bits' docs/sailboat-pi.md
grep -q 'exactly the manifest-recorded regular non-symlink ENC cell count' README.md
grep -q 'exactly the manifest-recorded regular non-symlink ENC cell count' docs/sailboat-pi.md
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
grep -q 'def _parse_proc_uptime_seconds' src/noaa_navionics/report.py
grep -q 'math.isfinite(uptime_seconds)' src/noaa_navionics/report.py
grep -q 'test_parse_proc_uptime_seconds_requires_finite_non_negative_value' tests/test_downloader.py
grep -q 'finite non-negative `/proc/uptime`' README.md
grep -q 'finite non-negative `/proc/uptime`' docs/sailboat-pi.md
grep -q 'extracted ZIP contains no ENC .000 cells' src/noaa_navionics/downloader.py
grep -q 'def _validate_downloaded_zip' src/noaa_navionics/downloader.py
grep -q 'def _validate_zip_members_and_crc' src/noaa_navionics/downloader.py
grep -q 'def _harden_extracted_chart_tree' src/noaa_navionics/downloader.py
grep -q 'os.chmod(path, mode)' src/noaa_navionics/downloader.py
grep -q 'test_download_tightens_extracted_chart_tree' tests/test_downloader.py
grep -q 'def _zip_member_path_is_unsafe' src/noaa_navionics/downloader.py
grep -q '{label} has unsafe member path' src/noaa_navionics/downloader.py
grep -q 'chart ZIP has a failed CRC member' tests/test_downloader.py
grep -q 'test_extract_zip_rejects_crc_failure_before_staging' tests/test_downloader.py
grep -q '{label} is not a valid archive' src/noaa_navionics/downloader.py
grep -q 'downloaded ZIP contains no ENC .000 cells' src/noaa_navionics/downloader.py
grep -q 'pass CRC checks' README.md
grep -q 'pass CRC checks' docs/sailboat-pi.md
grep -q 'or uses a non-HTTPS redirect' src/noaa_navionics/downloader.py
grep -q 'def _download_url_matches_package' src/noaa_navionics/downloader.py
grep -q 'test_download_rejects_http_redirect_before_writing_archive' tests/test_downloader.py
grep -q 'test_download_rejects_redirect_to_wrong_filename_before_writing_archive' tests/test_downloader.py
grep -q 'test_forced_download_rejects_bad_zip_before_replacing_archive' tests/test_downloader.py
grep -q 'test_forced_download_rejects_unsafe_zip_before_replacing_archive' tests/test_downloader.py
grep -q 'test_forced_download_rejects_zip_without_enc_cells_before_replacing_archive' tests/test_downloader.py
grep -q 'test_download_revalidates_archive_target_before_promotion' tests/test_downloader.py
grep -q 'chart archive path is a symlink before promotion' src/noaa_navionics/downloader.py
grep -q 'test_extract_zip_revalidates_destination_before_promotion' tests/test_downloader.py
grep -q 'chart extraction destination is a symlink before promotion' src/noaa_navionics/downloader.py
grep -q 'test_write_manifest_revalidates_manifest_target_before_promotion' tests/test_downloader.py
grep -q 'Chart archive, extraction, and manifest promotion revalidate output paths immediately before replacement' README.md
grep -q 'Chart archive, extraction, and manifest promotion revalidate output paths immediately before replacement' docs/sailboat-pi.md
grep -q 'extracted ENC directories/files are tightened to private `0700`/`0600` before promotion' README.md
grep -q 'extracted ENC directories/files are tightened to private `0700`/`0600` before promotion' docs/sailboat-pi.md
grep -q 'chart download path is not a regular file' src/noaa_navionics/downloader.py
grep -q 'chart download path .* is owned by uid' src/noaa_navionics/downloader.py
grep -q 'chart download path .* has permissions' src/noaa_navionics/downloader.py
grep -q 'def _hash_existing_download_path' src/noaa_navionics/downloader.py
grep -q 'chart download path contains a symlink' src/noaa_navionics/downloader.py
grep -q 'destination_stat, digest = _hash_existing_download_path(destination)' src/noaa_navionics/downloader.py
grep -q 'os.fdopen(fd, "rb")' src/noaa_navionics/downloader.py
! grep -q 'digest = sha256_file(destination)' src/noaa_navionics/downloader.py
grep -q 'def sha256_file' src/noaa_navionics/downloader.py
grep -q '_, digest = _hash_existing_download_path' src/noaa_navionics/downloader.py
! grep -q 'with Path(path).open("rb") as handle' src/noaa_navionics/downloader.py
grep -q 'test_existing_zip_nonregular_path_fails_before_reading_cache' tests/test_downloader.py
grep -q 'test_existing_zip_writable_file_fails_before_reading_cache' tests/test_downloader.py
grep -q 'test_hash_existing_download_path_rejects_writable_zip_before_hashing' tests/test_downloader.py
grep -q 'test_sha256_file_rejects_symlinked_archive_before_hashing' tests/test_downloader.py
grep -q 'test_sha256_file_rejects_writable_archive_before_hashing' tests/test_downloader.py
grep -q 'test_sha256_file_rejects_archive_under_symlinked_parent' tests/test_downloader.py
grep -q 'previous chart manifest path is a symlink' src/noaa_navionics/downloader.py
grep -q 'previous chart manifest path is not a regular file' src/noaa_navionics/downloader.py
grep -q 'previous chart manifest path .* is owned by uid' src/noaa_navionics/downloader.py
grep -q 'previous chart manifest path .* has permissions' src/noaa_navionics/downloader.py
grep -q 'def _open_manifest_for_read' src/noaa_navionics/downloader.py
grep -q 'manifest directory contains a symlink' src/noaa_navionics/downloader.py
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/downloader.py
grep -q 'manifest path changed before it could be read' src/noaa_navionics/downloader.py
grep -q 'read_manifest(chart_output, expected_stat=stat_result)' src/noaa_navionics/report.py
grep -q 'read_manifest(path, expected_stat=manifest_stat)' src/noaa_navionics/health.py
grep -q 'test_read_manifest_rejects_symlinked_manifest' tests/test_downloader.py
grep -q 'test_read_manifest_rejects_symlinked_manifest_directory' tests/test_downloader.py
grep -q 'test_read_manifest_rejects_writable_manifest' tests/test_downloader.py
grep -q 'test_read_manifest_rejects_replaced_manifest_before_parsing' tests/test_downloader.py
grep -q 'test_existing_zip_symlinked_previous_manifest_fails_before_extracting' tests/test_downloader.py
grep -q 'test_existing_zip_writable_previous_manifest_fails_before_extracting' tests/test_downloader.py
grep -q 'test_existing_zip_mismatched_previous_manifest_download_url_fails_before_extracting' tests/test_downloader.py
grep -q '_download_url_matches_package(previous_url, package.url)' src/noaa_navionics/downloader.py
grep -q 'unsafe ownership or permissions' README.md
grep -q 'unsafe ownership or permissions' docs/sailboat-pi.md
grep -q 'mismatched source metadata' README.md
grep -q 'mismatched source metadata' docs/sailboat-pi.md
grep -q 'cache-reuse hashes are computed from the same no-follow descriptor' README.md
grep -q 'cache-reuse hashes are computed from the same no-follow descriptor' docs/sailboat-pi.md
grep -q 'Manifest fallback ZIP hashes use the same trusted no-follow archive hash path' README.md
grep -q 'Manifest fallback ZIP hashes use the same trusted no-follow archive hash path' docs/sailboat-pi.md
grep -q 'Manifest reads reject symlinked manifest files or parent path components' README.md
grep -q 'Manifest reads reject symlinked manifest files or parent path components' docs/sailboat-pi.md
grep -q 'unsafe manifest directory ownership or permissions' README.md
grep -q 'unsafe manifest directory ownership or permissions' docs/sailboat-pi.md
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
grep -q 'expected private 0600; leaving it in place: {lock_path}' src/noaa_navionics/downloader.py
grep -q '_validate_stale_lock_for_cleanup(lock_path)' src/noaa_navionics/downloader.py
grep -q 'test_download_lock_rejects_public_active_lock_file' tests/test_downloader.py
grep -q 'test_stale_download_lock_cleanup_rejects_public_lock_file' tests/test_downloader.py
grep -q 'stale lock reads use a no-follow descriptor, stale lock cleanup refuses misowned or non-private lock files' README.md
grep -q 'stale lock reads use a no-follow descriptor, stale lock cleanup refuses misowned or non-private lock files' docs/sailboat-pi.md
grep -q 'boot_id=' src/noaa_navionics/downloader.py
grep -q 'BOOT_ID_RE.fullmatch' src/noaa_navionics/downloader.py
grep -q '_valid_boot_id(owner_boot_id) and _valid_boot_id(current_boot_id)' src/noaa_navionics/downloader.py
grep -q 'test_old_download_lock_with_malformed_current_boot_id_keeps_live_owner' tests/test_downloader.py
grep -q 'test_old_download_lock_with_malformed_owner_boot_id_keeps_live_owner' tests/test_downloader.py
grep -q 'valid Linux `boot_id` UUID shape' README.md
grep -q 'valid Linux `boot_id` UUID shape' docs/sailboat-pi.md
grep -q 'lock_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/downloader.py
grep -q 'os.fchmod(lock_fd, 0o600)' src/noaa_navionics/downloader.py
grep -q 'partial download already exists; remove interrupted chart update debris' src/noaa_navionics/downloader.py
grep -q 'def _remove_interrupted_download_partial' src/noaa_navionics/downloader.py
grep -q 'partial download path is a symlink before cleanup' src/noaa_navionics/downloader.py
grep -q 'test_download_cleanup_rejects_symlinked_interrupted_partial' tests/test_downloader.py
grep -q 'test_download_cleanup_rejects_writable_interrupted_partial' tests/test_downloader.py
grep -q 'Failed download cleanup revalidates interrupted `.part` files' README.md
grep -q 'Failed download cleanup revalidates interrupted `.part` files' docs/sailboat-pi.md
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
grep -q 'dirnames\[:\] = \[dirname for dirname in dirnames if not (current / dirname).is_symlink()\]' src/noaa_navionics/downloader.py
grep -q 'os.open(file_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))' src/noaa_navionics/downloader.py
grep -q 'stat.S_ISREG(opened.st_mode)' src/noaa_navionics/downloader.py
! grep -q 'with file_path.open("rb") as handle' src/noaa_navionics/downloader.py
grep -q 'test_fsync_tree_uses_no_follow_file_opens' tests/test_downloader.py
grep -q 'test_chart_directory_sync_uses_no_follow_open' tests/test_downloader.py
grep -q 'Chart tree sync uses no-follow opens for directories and regular files' README.md
grep -q 'Chart tree sync uses no-follow opens for directories and regular files' docs/sailboat-pi.md
grep -q 'os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/gps.py
grep -q 'os.fsync(self.file.fileno())' src/noaa_navionics/gps.py
grep -q 'def _fsync_directory' src/noaa_navionics/gps.py
grep -q 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/gps.py
grep -q 'test_gpx_logger_directory_sync_uses_no_follow_open' tests/test_downloader.py
grep -q 'GPX directory sync uses no-follow directory opens' README.md
grep -q 'GPX directory sync uses no-follow directory opens' docs/sailboat-pi.md
grep -q 'expected a new regular GPX track file' src/noaa_navionics/gps.py
grep -q 'def write_gpx_position_mark' src/noaa_navionics/gps.py
grep -q 'def gpx_position_mark_path' src/noaa_navionics/gps.py
grep -q 'def distance_meters' src/noaa_navionics/gps.py
grep -q 'EARTH_RADIUS_METERS' src/noaa_navionics/gps.py
grep -q 'anchor_radius_meters' src/noaa_navionics/config.py
grep -q '\[anchor\]' src/noaa_navionics/config.py
grep -q 'radius_meters = 50' examples/noaa-navionics.ini
grep -q '<wpt lat=' src/noaa_navionics/gps.py
grep -q 'position mark requires satellite or HDOP quality data' src/noaa_navionics/gps.py
grep -q 'expected a new regular GPX position mark file' src/noaa_navionics/gps.py
grep -q 'test_gpx_position_mark_writes_private_waypoint_file' tests/test_downloader.py
grep -q 'test_gpx_position_mark_rejects_missing_quality_fields' tests/test_downloader.py
grep -q 'test_gpx_position_mark_rejects_symlinked_target_file' tests/test_downloader.py
grep -q 'test_gpx_position_mark_does_not_overwrite_existing_file' tests/test_downloader.py
grep -q 'will not follow symlinked targets or overwrite an existing waypoint' README.md
grep -q 'will not follow symlinked targets or overwrite an existing waypoint' docs/sailboat-pi.md
grep -q 'test_cli_anchor_watch_alarms_on_drift_from_explicit_anchor' tests/test_downloader.py
grep -q 'test_cli_anchor_watch_sets_anchor_from_first_fix_and_accepts_inside_radius' tests/test_downloader.py
grep -q 'test_cli_anchor_watch_rejects_run_without_post_anchor_fix' tests/test_downloader.py
grep -q 'test_cli_anchor_watch_averages_anchor_samples' tests/test_downloader.py
grep -q 'test_cli_anchor_watch_rejects_insufficient_anchor_samples' tests/test_downloader.py
grep -q 'test_cli_anchor_watch_uses_configured_radius_by_default' tests/test_downloader.py
grep -q 'test_cli_anchor_watch_interval_suppresses_non_alarm_updates_only' tests/test_downloader.py
grep -q 'need at least one drift check' src/noaa_navionics/cli.py
grep -q 'A finite anchor-watch run succeeds only after at least one post-anchor drift fix has been checked' README.md
grep -q 'A finite anchor-watch run succeeds only after at least one post-anchor drift fix has been checked' docs/sailboat-pi.md
grep -q 'test_distance_meters_uses_haversine_distance' tests/test_downloader.py
grep -q 'mark-position", "--seconds", "0"' tests/test_downloader.py
grep -q 'anchor-watch", "--anchor-samples", "0"' tests/test_downloader.py
grep -q 'anchor-watch", "--radius-meters", "0"' tests/test_downloader.py
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
grep -q 'NMEA_MAX_LINE_BYTES' src/noaa_navionics/gps.py
grep -q 'NMEA sentence exceeded' src/noaa_navionics/gps.py
grep -q 'NMEA sentence exceeded' src/noaa_navionics/cli.py
grep -q 'NMEA sentence exceeded' src/noaa_navionics/health.py
grep -q 'test_read_nmea_lines_rejects_overlong_unterminated_fragment' tests/test_downloader.py
grep -q 'test_cli_deadline_nmea_reader_rejects_overlong_unterminated_fragment' tests/test_downloader.py
grep -q 'test_check_gps_device_rejects_overlong_unterminated_nmea_fragment' tests/test_downloader.py
grep -q 'NMEA readers and GPSD streams reject overlong messages' README.md
grep -q 'NMEA readers and GPSD streams reject overlong messages' docs/sailboat-pi.md
grep -q 'Diagnostic NMEA sample files are read only through same-file no-follow descriptor checks' README.md
grep -q 'Diagnostic NMEA sample files are read only through same-file no-follow descriptor checks' docs/sailboat-pi.md
grep -q 'Malformed or non-finite NMEA timestamps and malformed GPSD timestamps are treated as missing timestamps' README.md
grep -q 'Malformed or non-finite NMEA timestamps and malformed GPSD timestamps are treated as missing timestamps' docs/sailboat-pi.md
grep -q 'fix.timestamp is None' src/noaa_navionics/gps.py
grep -q 'signal.SIGTERM' src/noaa_navionics/cli.py
grep -q 'Skipping weak {skip_subject} fix' src/noaa_navionics/cli.py
grep -q 'Skipping untimestamped {skip_subject} fix' src/noaa_navionics/cli.py
grep -q 'Skipping low-detail {skip_subject} fix' src/noaa_navionics/cli.py
grep -q 'Skipping weak track fix' tests/test_downloader.py
grep -q 'Skipping untimestamped track fix' tests/test_downloader.py
grep -q 'Skipping low-detail track fix' tests/test_downloader.py
grep -q 'future_tolerance_seconds: float = 0.0' src/noaa_navionics/cli.py
grep -q 'fix timestamp is stale' src/noaa_navionics/cli.py
grep -q 'fix timestamp is in the future' src/noaa_navionics/cli.py
grep -q 'test_trackable_fixes_skip_slightly_future_timestamped_fix' tests/test_downloader.py
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
grep -q 'became a symlink after permission tightening' src/noaa_navionics/gps.py
grep -q 'has permissions .* expected private 0700' src/noaa_navionics/gps.py
grep -q 'test_gpx_logger_tightens_public_track_parent' tests/test_downloader.py
grep -q 'test_gpx_logger_rejects_track_parent_when_tightening_fails' tests/test_downloader.py
grep -q 'test_gpx_logger_rejects_misowned_track_parent' tests/test_downloader.py
grep -q 'test_gpx_logger_rejects_symlinked_track_parent' tests/test_downloader.py
grep -q 'test_gpx_logger_rejects_symlinked_track_file' tests/test_downloader.py
grep -q 'def _prepare_private_tracks_dir' src/noaa_navionics/cli.py
grep -q 'first_symlink_ancestor' src/noaa_navionics/cli.py
grep -q 'is a symlink, expected a private tracks directory' src/noaa_navionics/cli.py
grep -q 'is owned by uid .* expected' src/noaa_navionics/cli.py
grep -q 'became a symlink after permission tightening' src/noaa_navionics/cli.py
grep -q 'has permissions .* expected private 0700' src/noaa_navionics/cli.py
grep -q 'test_prepare_private_tracks_dir_rejects_directory_when_tightening_fails' tests/test_downloader.py
grep -q 'test_log_rotating_tracks_rejects_symlinked_base_directory' tests/test_downloader.py
grep -q 'GPX logging rejects symlinked track-output parent components' README.md
grep -q 'GPX logger also refuses symlinked track-output parent components' docs/sailboat-pi.md
grep -q 'GPX track directory permission tightening is revalidated before track files are created' README.md
grep -q 'GPX track directory permission tightening is revalidated before track files are created' docs/sailboat-pi.md
grep -q 'symlinked GPX output files' README.md
grep -q 'symlinked GPX output files' docs/sailboat-pi.md
grep -q 'os.chmod(path, 0o700)' src/noaa_navionics/cli.py
grep -q 'refusing to prune GPX track logs' src/noaa_navionics/cli.py
grep -q 'not a regular GPX track file' src/noaa_navionics/cli.py
grep -q 'os.open(path.name, flags, dir_fd=tracks_fd)' src/noaa_navionics/cli.py
grep -q 'os.unlink(path.name, dir_fd=tracks_fd)' src/noaa_navionics/cli.py
grep -q 'test_prune_old_track_logs_rejects_symlinked_old_track' tests/test_downloader.py
grep -q 'test_prune_old_track_logs_rejects_nonregular_old_track' tests/test_downloader.py
grep -q 'test_prune_old_track_logs_rejects_public_old_track' tests/test_downloader.py
grep -q 'test_prune_old_track_logs_uses_no_follow_descriptor_before_unlink' tests/test_downloader.py
grep -q 'Retention pruning validates old GPX entries through no-follow descriptors' README.md
grep -q 'Retention pruning validates old GPX entries through no-follow descriptors' docs/sailboat-pi.md
grep -q 'expected private 0600' src/noaa_navionics/cli.py
grep -q 'non-private old GPX entries' README.md
grep -q 'non-private old GPX entries' docs/sailboat-pi.md
grep -q 'def _prepare_private_status_parent' src/noaa_navionics/report.py
grep -q 'def _prepare_home_status_cache_parent' src/noaa_navionics/report.py
grep -q 'status report parent directory' src/noaa_navionics/report.py
grep -q 'status report parent path contains a symlink' src/noaa_navionics/report.py
grep -q 'status report cache parent directory' src/noaa_navionics/report.py
grep -q 'status report directory .* expected private 0700' src/noaa_navionics/report.py
grep -q 'status report cache parent directory .* expected private 0700' src/noaa_navionics/report.py
grep -q 'became a symlink after permission tightening' src/noaa_navionics/report.py
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
grep -q 'test_write_status_report_rejects_output_directory_when_tightening_fails' tests/test_downloader.py
grep -q 'test_write_status_report_rejects_home_cache_parent_when_tightening_fails' tests/test_downloader.py
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
grep -q 'def _validate_live_serial_device' src/noaa_navionics/cli.py
grep -q 'GPS serial device uses a volatile USB name' src/noaa_navionics/cli.py
grep -q 'GPS serial device {path} is not a udev by-id symlink' src/noaa_navionics/cli.py
grep -q 'test_cli_log_track_rejects_volatile_explicit_serial_device' tests/test_downloader.py
grep -q 'test_cli_gps_monitor_rejects_volatile_explicit_serial_device' tests/test_downloader.py
grep -q 'test_cli_log_track_rejects_by_id_device_that_is_not_symlink' tests/test_downloader.py
grep -q 'test_cli_gps_monitor_rejects_by_id_device_that_is_not_symlink' tests/test_downloader.py
grep -q 'gps_device_check = check_gps_device_path(gps_device)' src/noaa_navionics/health.py
grep -q 'not checked because {gps_device_check.detail}' src/noaa_navionics/health.py
grep -q 'test_preflight_rejects_volatile_direct_serial_device_before_opening' tests/test_downloader.py
grep -q 'def check_gps_device' src/noaa_navionics/health.py
grep -q 'gps_device_check = check_gps_device_path(device)' src/noaa_navionics/health.py
grep -q 'test_check_gps_device_rejects_volatile_path_before_opening' tests/test_downloader.py
grep -q 'test_check_gps_device_path_rejects_by_id_character_node_without_symlink' tests/test_downloader.py
grep -q 'is not a udev by-id symlink' src/noaa_navionics/health.py
grep -Fq 'suffix not in {".", ".."}' src/noaa_navionics/config.py
grep -Fq 'suffix not in {".", ".."}' src/noaa_navionics/health.py
grep -q 'volatile USB name' src/noaa_navionics/config.py
grep -q 'gps.device must be /dev/serial/by-id/' src/noaa_navionics/config.py
grep -q 'actual udev symlinks' README.md
grep -q 'actual udev symlinks' docs/sailboat-pi.md
grep -q 'def parse_gpsd_sky' src/noaa_navionics/gps.py
grep -q 'uSat' src/noaa_navionics/gps.py
grep -q 'used' src/noaa_navionics/gps.py
grep -q 'NMEA_CHECKSUM_HEX' src/noaa_navionics/gps.py
grep -q 'len(supplied) != 2' src/noaa_navionics/gps.py
grep -q 'test_parse_nmea_rejects_bad_checksum' tests/test_downloader.py
grep -q 'test_parse_nmea_rejects_malformed_checksum_suffix' tests/test_downloader.py
grep -q 'trailing-garbage checksum suffixes' README.md
grep -q 'trailing-garbage checksum suffixes' docs/sailboat-pi.md
grep -q 'sky_max_age_seconds' src/noaa_navionics/gps.py
grep -q 'max_duration' src/noaa_navionics/gps.py
grep -q 'idle_timeout' src/noaa_navionics/gps.py
grep -q 'GPSD_MAX_MESSAGE_BYTES' src/noaa_navionics/gps.py
grep -q 'GPSD message exceeded' src/noaa_navionics/gps.py
grep -q 'test_iter_gpsd_fixes_rejects_overlong_message' tests/test_downloader.py
grep -q 'NMEA readers and GPSD streams reject overlong messages' README.md
grep -q 'NMEA readers and GPSD streams reject overlong messages' docs/sailboat-pi.md
grep -q 'sock.settimeout' src/noaa_navionics/gps.py
grep -q 'sock.settimeout(idle_timeout)' src/noaa_navionics/gps.py
grep -q 'no GPSD messages within' src/noaa_navionics/gps.py
grep -q 'no NMEA bytes within' src/noaa_navionics/gps.py
grep -q 'test_iter_gpsd_fixes_raises_on_idle_timeout' tests/test_downloader.py
grep -q 'test_read_fixes_passes_live_gpsd_idle_timeout' tests/test_downloader.py
grep -q 'test_read_fixes_retries_empty_gpsd_stream_before_first_fix' tests/test_downloader.py
grep -q 'ended before any fixes' src/noaa_navionics/cli.py
grep -q 'first connected GPSD stream ends before any fix arrives' README.md
grep -q 'first connected GPSD stream ends before any fix arrives' docs/sailboat-pi.md
grep -q 'test_read_fixes_passes_live_serial_idle_timeout' tests/test_downloader.py
grep -q 'test_read_nmea_lines_raises_on_idle_timeout' tests/test_downloader.py
grep -q 'def _live_idle_timeout' src/noaa_navionics/cli.py
grep -q 'test_cli_log_track_zero_gpsd_idle_timeout_disables_live_timeout' tests/test_downloader.py
grep -q 'test_cli_log_track_zero_serial_idle_timeout_disables_live_timeout' tests/test_downloader.py
grep -q 'after 300 quiet seconds by default' README.md
grep -q 'after 300 quiet seconds by default' docs/sailboat-pi.md
grep -q 'Live serial logging uses the same 300-second quiet limit' README.md
grep -q 'Live serial logging uses the same 300-second quiet limit' docs/sailboat-pi.md
grep -q 'max_duration = max(0.001, remaining)' src/noaa_navionics/health.py
grep -q 'test_check_gpsd_retries_initial_connection_until_bounded_wait' tests/test_downloader.py
grep -q 'test_check_gpsd_reports_last_connection_error_after_bounded_wait' tests/test_downloader.py
grep -q 'last GPSD connection error' src/noaa_navionics/health.py
grep -q 'GPSD readiness check retries initial connection refusals inside the configured GPS wait' README.md
grep -q 'GPSD readiness check retries initial connection refusals inside the configured GPS wait' docs/sailboat-pi.md
grep -q 'retries initial GPSD connection refusals inside that wait' README.md
grep -q 'retries initial GPSD connection refusals inside that wait' docs/sailboat-pi.md
grep -q '"max_duration": max_duration' src/noaa_navionics/cli.py
grep -q 'gpsd_idle_timeout' src/noaa_navionics/cli.py
grep -q 'serial_idle_timeout' src/noaa_navionics/cli.py
grep -q -- '--gpsd-idle-timeout' src/noaa_navionics/cli.py
grep -q -- '--serial-idle-timeout' src/noaa_navionics/cli.py
grep -q 'def _positive_float' src/noaa_navionics/cli.py
grep -q 'gps.add_argument("--seconds", type=_positive_float' src/noaa_navionics/cli.py
grep -q 'deadline = time.monotonic() + args.seconds if args.seconds else None' src/noaa_navionics/cli.py
grep -q 'instead of waiting forever when GPSD is starting slowly, refusing connections, or connected but not producing a fix' README.md
grep -q 'instead of waiting forever when GPSD is starting slowly, refusing connections, or connected but no fix arrives' docs/sailboat-pi.md
grep -q 'def _non_negative_int' src/noaa_navionics/cli.py
grep -q 'def _non_negative_float' src/noaa_navionics/cli.py
grep -q 'chart_dir = Path(args.charts).expanduser() if args.charts else app_config.chart_output' src/noaa_navionics/cli.py
grep -q 'pass `--charts PATH` to check a different mounted chart directory explicitly' README.md
grep -q 'tempfile.NamedTemporaryFile' src/noaa_navionics/config.py
grep -q 'def _write_text_atomic' src/noaa_navionics/config.py
grep -q 'def _prepare_config_parent' src/noaa_navionics/config.py
grep -q 'def _first_symlink_ancestor' src/noaa_navionics/config.py
grep -q 'def _validate_manifest_replace_target' src/noaa_navionics/downloader.py
grep -q 'refusing to replace symlinked chart manifest path' src/noaa_navionics/downloader.py
grep -q 'test_write_manifest_rejects_symlinked_manifest_target' tests/test_downloader.py
grep -q 'test_write_manifest_rejects_nonregular_manifest_target' tests/test_downloader.py
grep -q 'test_write_manifest_rejects_writable_manifest_target' tests/test_downloader.py
grep -q 'Manifest writes refuse existing symlinked or non-regular manifest targets' README.md
grep -q 'Manifest writes refuse existing symlinked or non-regular manifest targets' docs/sailboat-pi.md
grep -q 'parent.mkdir(parents=True, mode=0o700, exist_ok=True)' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config parent is not a directory' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config directory .* is owned by uid' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config directory .* has permissions' src/noaa_navionics/config.py
grep -q 'could not make NOAA Navionics config directory private' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config directory became a symlink after permission tightening' src/noaa_navionics/config.py
grep -q 'expected private 0700' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config is a symlink' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config is not a regular file' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config .* is owned by uid' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config .* has permissions' src/noaa_navionics/config.py
grep -q 'os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/config.py
grep -q 'test_write_default_config_rejects_symlinked_ancestor' tests/test_downloader.py
grep -q 'test_write_default_config_rejects_symlinked_config_file_when_overwriting' tests/test_downloader.py
grep -q 'test_write_default_config_rejects_unsafe_existing_config_when_overwriting' tests/test_downloader.py
grep -q 'test_write_default_config_tightens_public_parent' tests/test_downloader.py
grep -q 'test_write_default_config_rejects_parent_when_tightening_fails' tests/test_downloader.py
grep -q 'test_write_default_config_directory_sync_uses_no_follow_open' tests/test_downloader.py
grep -q 'test_read_config_rejects_symlinked_config_file' tests/test_downloader.py
grep -q 'test_read_config_rejects_symlinked_parent' tests/test_downloader.py
grep -q 'test_read_config_rejects_symlinked_ancestor' tests/test_downloader.py
grep -q 'test_read_config_rejects_symlinked_parent_when_config_missing' tests/test_downloader.py
grep -q 'test_read_config_rejects_nonregular_config_file' tests/test_downloader.py
grep -q 'test_read_config_rejects_non_directory_parent' tests/test_downloader.py
grep -q 'test_read_config_rejects_writable_parent' tests/test_downloader.py
grep -q 'Writes create or tighten the config directory to private `0700` permissions' README.md
grep -q 'creates or tightens the config directory to private `0700` permissions' docs/sailboat-pi.md
grep -q 'misowned or group/world-writable config directories' README.md
grep -q 'misowned or group/world-writable config directories' docs/sailboat-pi.md
grep -q 'Config directory sync uses no-follow directory opens' README.md
grep -q 'Config directory sync uses no-follow directory opens' docs/sailboat-pi.md
grep -q 'test_read_config_rejects_writable_config_file' tests/test_downloader.py
grep -q 'symlinked config path components' README.md
grep -q 'symlinked config path components' docs/sailboat-pi.md
grep -q 'os.chmod(tmp_path, 0o600)' src/noaa_navionics/config.py
grep -q 'GPSD skipped: gps.mode' src/noaa_navionics/cli.py
grep -q 'sync-charts requires writable chart storage with enough free space' src/noaa_navionics/cli.py
grep -q 'live_stream = deadline is None and not args.sample' src/noaa_navionics/cli.py
grep -q 'gpsd_connect_retry=use_gpsd and not args.sample' src/noaa_navionics/cli.py
grep -q 'test_read_fixes_retries_initial_gpsd_connection_for_bounded_wait' tests/test_downloader.py
grep -q 'retry_delay = min(retry_delay, remaining)' src/noaa_navionics/cli.py
grep -q 'Bounded live GPSD commands retry initial GPSD connection failures inside their wait window' README.md
grep -q 'Bounded live GPSD commands retry initial GPSD connection failures inside their wait window' docs/sailboat-pi.md
grep -q 'log-track --seconds 30` retries initial GPSD connection refusals inside the timeout' README.md
grep -q 'log-track --seconds 30` retries initial GPSD connection refusals inside the timeout' docs/sailboat-pi.md
grep -q 'open_trusted_gps_sample(Path(sample))' src/noaa_navionics/cli.py
grep -q 'GPS sample path changed before it could be read' src/noaa_navionics/health.py
grep -q 'test_check_gps_sample_rejects_replaced_sample_before_parsing' tests/test_downloader.py
grep -q 'test_cli_sample_reader_rejects_symlinked_sample' tests/test_downloader.py
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
grep -q 'def read_configured_gps_fix' src/noaa_navionics/gui.py
grep -q 'def read_configured_gps_fixes' src/noaa_navionics/gui.py
grep -q 'def _gps_fix_freshness_failure' src/noaa_navionics/gui.py
grep -q 'future_tolerance_seconds: float = 0.0' src/noaa_navionics/gui.py
grep -q 'fix timestamp is in the future' src/noaa_navionics/gui.py
grep -q 'def format_gps_fix' src/noaa_navionics/gui.py
grep -q 'def download_selected_package' src/noaa_navionics/gui.py
grep -q 'text="GPS Fix"' src/noaa_navionics/gui.py
grep -q 'without satellite or HDOP quality data' src/noaa_navionics/gui.py
grep -q 'fix has no timestamp' src/noaa_navionics/gui.py
grep -q 'download requires writable chart storage with enough free space' src/noaa_navionics/gui.py
grep -q 'sync requires a complete onboard chart package' src/noaa_navionics/gui.py
grep -q 'sync requires writable chart storage with enough free space' src/noaa_navionics/gui.py
grep -q 'class StatusApp' src/noaa_navionics/status_gui.py
grep -q 'def status_rows' src/noaa_navionics/status_gui.py
grep -q 'def status_headline' src/noaa_navionics/status_gui.py
grep -q 'def format_gps_summary' src/noaa_navionics/status_gui.py
grep -q 'def write_current_position_mark' src/noaa_navionics/status_gui.py
grep -q 'def _position_mark_freshness_failure' src/noaa_navionics/status_gui.py
grep -q 'def _gps_fix_freshness_failure' src/noaa_navionics/status_gui.py
grep -q 'position mark requires a fresh GPS fix' src/noaa_navionics/status_gui.py
grep -q 'def check_anchor_drift' src/noaa_navionics/status_gui.py
grep -q 'anchor check requires fresh GPS fix' src/noaa_navionics/status_gui.py
grep -q 'future_tolerance_seconds: float = 0.0' src/noaa_navionics/status_gui.py
grep -q 'def format_anchor_check' src/noaa_navionics/status_gui.py
grep -q 'def _format_anchor_fix_detail' src/noaa_navionics/status_gui.py
grep -q 'def anchor_alarm_active' src/noaa_navionics/status_gui.py
grep -q 'def _configured_anchor_radius' src/noaa_navionics/status_gui.py
grep -q 'def available_position_mark_path' src/noaa_navionics/status_gui.py
grep -q 'READY' src/noaa_navionics/status_gui.py
grep -q 'NOT READY' src/noaa_navionics/status_gui.py
grep -q 'text="MOB"' src/noaa_navionics/status_gui.py
grep -q 'text="Anchor Check"' src/noaa_navionics/status_gui.py
grep -q 'anchor-radius-meters' src/noaa_navionics/status_gui.py
grep -q 'anchor-samples' src/noaa_navionics/status_gui.py
grep -q 'anchor_samples=args.anchor_samples' src/noaa_navionics/status_gui.py
grep -q 'anchor_samples=args.anchor_samples' src/noaa_navionics/cli.py
grep -q 'write_gpx_position_mark(path, fix, name=name, description=description)' src/noaa_navionics/status_gui.py
grep -q 'read_configured_gps_fixes(app_config, count=anchor_samples + 1, gps_seconds=gps_seconds)' src/noaa_navionics/status_gui.py
grep -q 'build_status_report(config_path=self.config_path, gps_seconds=self.gps_seconds)' src/noaa_navionics/status_gui.py
grep -q 'write_status_report(report, self.output_path)' src/noaa_navionics/status_gui.py
grep -q 'status-gui' src/noaa_navionics/cli.py
grep -q 'anchor-radius-meters' src/noaa_navionics/cli.py
grep -q 'noaa-navionics-status-gui' README.md
grep -q 'noaa-navionics-status-gui' docs/sailboat-pi.md
grep -q 'large READY/NOT READY headline, a dedicated live GPS fix summary' README.md
grep -q 'large READY/NOT READY headline, a dedicated live GPS fix summary' docs/sailboat-pi.md
grep -q 'Use its Mark or MOB buttons to write a private GPX waypoint from a fresh quality-checked GPS fix' README.md
grep -q 'Use its Mark or MOB buttons to write a private GPX waypoint from a fresh quality-checked GPS fix' docs/sailboat-pi.md
grep -q 'Mark, MOB, and Anchor Check reject stale or future-dated GPS fixes' README.md
grep -q 'Mark, MOB, and Anchor Check reject stale or future-dated GPS fixes' docs/sailboat-pi.md
grep -q 'use Anchor Check for a bounded fresh-fix drift check with an optional averaged anchor sample count' README.md
grep -q 'use Anchor Check for a bounded fresh-fix drift check with an optional averaged anchor sample count' docs/sailboat-pi.md
grep -q 'shows anchor/current GPS quality and rings the display bell' README.md
grep -q 'shows anchor/current GPS quality and rings the display bell' docs/sailboat-pi.md
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
python3 - <<'PY'
from pathlib import Path

text = Path("src/noaa_navionics/gui.py").read_text(encoding="utf-8")
download_start = text.index("def download_selected_package")
download_end = text.index("class DownloaderApp")
download_block = text[download_start:download_end]
disk_index = download_block.index("disk_check = check_disk_space")
mkdir_index = download_block.index("output.mkdir")
if mkdir_index < disk_index:
    raise SystemExit("GUI download must check chart storage before creating chart output")
PY
grep -q 'test_gui_download_rejects_low_disk_before_download' tests/test_downloader.py
grep -q 'test_gui_download_rejects_missing_storage_before_creating_directory' tests/test_downloader.py
grep -q 'test_gui_gps_fix_reads_configured_gpsd_and_formats_position' tests/test_downloader.py
grep -q 'test_gui_gps_fix_skips_stale_before_fresh_fix' tests/test_downloader.py
grep -q 'test_gui_gps_fix_rejects_stale_timestamped_fix' tests/test_downloader.py
grep -q 'test_gui_gps_fix_rejects_future_timestamped_fix' tests/test_downloader.py
grep -q 'test_gui_gps_fix_rejects_untimestamped_fix' tests/test_downloader.py
grep -q 'test_gui_gps_fix_rejects_volatile_serial_override' tests/test_downloader.py
grep -q 'test_gui_gps_fix_rejects_fix_without_quality_fields' tests/test_downloader.py
grep -q 'test_status_gui_summarizes_readiness_rows' tests/test_downloader.py
grep -q 'test_status_gui_reports_ready_when_all_rows_pass' tests/test_downloader.py
grep -q 'test_status_gui_formats_structured_gps_summary' tests/test_downloader.py
grep -q 'test_cli_status_gui_forwards_arguments' tests/test_downloader.py
grep -q 'test_status_gui_write_current_position_mark_uses_configured_track_output' tests/test_downloader.py
grep -q 'test_status_gui_position_mark_rejects_stale_fix' tests/test_downloader.py
grep -q 'test_status_gui_position_mark_rejects_future_fix' tests/test_downloader.py
grep -q 'test_status_gui_anchor_check_rejects_stale_fix' tests/test_downloader.py
grep -q 'test_status_gui_anchor_check_rejects_future_fix' tests/test_downloader.py
grep -q 'test_status_gui_anchor_check_uses_configured_gps_fixes' tests/test_downloader.py
grep -q 'test_status_gui_anchor_check_averages_anchor_samples' tests/test_downloader.py
grep -q 'test_status_gui_formats_anchor_fix_quality_detail' tests/test_downloader.py
grep -q 'test_status_gui_reads_configured_anchor_radius' tests/test_downloader.py
grep -q 'test_cli_mark_position_writes_mob_waypoint_to_configured_track_output' tests/test_downloader.py
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
grep -q 'OpenCPN config directory became a symlink after permission tightening' src/noaa_navionics/opencpn.py
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
grep -q 'test_configure_chart_directory_rejects_config_parent_when_tightening_fails' tests/test_downloader.py
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
grep -q 'Chart Sync Unit File' src/noaa_navionics/report.py
grep -q 'Chart Timer Settings' src/noaa_navionics/report.py
grep -q 'Chart Timer Unit File' src/noaa_navionics/report.py
grep -q 'Chart Timer Install' src/noaa_navionics/report.py
grep -q 'RandomizedDelayUSec.*30min' src/noaa_navionics/report.py
grep -q 'Track Logger Settings' src/noaa_navionics/report.py
grep -q 'Track Logger Unit File' src/noaa_navionics/report.py
grep -q 'Track Logger Install' src/noaa_navionics/report.py
grep -q 'Track Log' src/noaa_navionics/report.py
grep -q 'Boot Readiness Unit File' src/noaa_navionics/report.py
grep -q 'def _unit_file_contains_check' src/noaa_navionics/report.py
grep -q 'state\["lines"\] = lines' src/noaa_navionics/report.py
grep -q 'test_service_readiness_checks_fail_stale_installed_unit_file_settings' tests/test_downloader.py
grep -q 'trusted_unit_file_lines' tests/test_downloader.py
grep -q 'def _user_summary' src/noaa_navionics/report.py
grep -q '_trusted_system_command("loginctl", "Loginctl command")' src/noaa_navionics/report.py
grep -q 'str(loginctl), "show-user"' src/noaa_navionics/report.py
grep -q '_trusted_system_command("systemctl", "Systemctl command")' src/noaa_navionics/report.py
grep -q 'test_service_summary_rejects_user_owned_systemctl_on_pi' tests/test_downloader.py
grep -q 'test_user_summary_rejects_user_owned_loginctl_on_pi' tests/test_downloader.py
grep -q 'User Linger' src/noaa_navionics/report.py
grep -q 'status report user linger' scripts/verify_pi.sh
grep -q '"User Linger"' scripts/verify_pi.sh
grep -q 'test_service_readiness_checks_include_user_linger' tests/test_downloader.py
grep -q 'test_disk_check_rejects_symlinked_storage_directory' tests/test_downloader.py
grep -q 'test_disk_check_rejects_storage_under_symlinked_parent' tests/test_downloader.py
grep -q 'def _track_log_summary' src/noaa_navionics/report.py
grep -q 'def _read_trusted_gpx_track_file' src/noaa_navionics/report.py
grep -q 'expected_stat: Optional\[os.stat_result\] = None' src/noaa_navionics/report.py
grep -q 'changed before it could be read' src/noaa_navionics/report.py
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
grep -q 'newest GPX trackpoint timestamp is in the future' src/noaa_navionics/report.py
grep -q 'GPX trackpoint has invalid negative HDOP' src/noaa_navionics/report.py
grep -q 'test_track_log_summary_rejects_non_finite_trackpoint_coordinates' tests/test_downloader.py
grep -q 'test_track_log_summary_rejects_future_trackpoint' tests/test_downloader.py
grep -q 'test_track_log_summary_rejects_negative_hdop' tests/test_downloader.py
grep -q 'future-dated GPX trackpoint timestamps' README.md
grep -q 'future-dated GPX trackpoint timestamps' docs/sailboat-pi.md
grep -q 'negative GPX HDOP' README.md
grep -q 'negative GPX HDOP' docs/sailboat-pi.md
grep -q 'test_track_log_summary_rejects_missing_trackpoint_quality' tests/test_downloader.py
grep -q 'test_read_trusted_gpx_track_file_rejects_writable_track_file_before_parsing' tests/test_downloader.py
grep -q 'test_read_trusted_gpx_track_file_rejects_replaced_file_before_parsing' tests/test_downloader.py
grep -q 'test_track_log_summary_rejects_symlinked_track_output' tests/test_downloader.py
grep -q 'test_track_log_summary_rejects_symlinked_track_output_ancestor' tests/test_downloader.py
grep -q 'Status reports and Pi verification read candidate GPX track files only after a no-follow descriptor confirms the opened file is still the inspected file' README.md
grep -q 'Status reports and Pi verification read candidate GPX track files only after a no-follow descriptor confirms the opened file is still the inspected file' docs/sailboat-pi.md
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
grep -q 'check_opencpn_gpsd_config' src/noaa_navionics/report.py
grep -q '"config_symlink_component"' src/noaa_navionics/report.py
grep -q '"uid"' src/noaa_navionics/report.py
grep -q '"mode"' src/noaa_navionics/report.py
grep -q '"directory_uid"' src/noaa_navionics/report.py
grep -q '"directory_mode"' src/noaa_navionics/report.py
grep -q 'test_opencpn_config_summary_rejects_symlinked_config_ancestor' tests/test_downloader.py
grep -q 'test_opencpn_config_summary_rejects_nonregular_config' tests/test_downloader.py
grep -q 'test_opencpn_config_summary_records_owner_and_mode' tests/test_downloader.py
grep -q 'test_opencpn_config_summary_records_public_directory_mode' tests/test_downloader.py
grep -q 'test_status_report_with_gps_sample_still_checks_opencpn_gpsd_config' tests/test_downloader.py
grep -q 'status-report --gps-sample.*still checks OpenCPN' README.md
grep -q 'Sample-based status reports substitute only the live GPS fix read' docs/sailboat-pi.md
grep -q 'summary\["age_seconds"\] = (current - timestamp).total_seconds()' src/noaa_navionics/report.py
grep -q 'test_gps_fix_summary_preserves_future_timestamp_age' tests/test_downloader.py
grep -q 'OpenCPN chart and GPSD config reads use a no-follow descriptor' README.md
grep -q 'OpenCPN chart and GPSD config reads use a no-follow descriptor' docs/sailboat-pi.md
grep -q 'launcher environment path is a symlink' src/noaa_navionics/report.py
grep -q 'launcher environment is not a regular file' src/noaa_navionics/report.py
grep -q 'launcher environment is owned by uid' src/noaa_navionics/report.py
grep -q 'malformed launcher environment line' src/noaa_navionics/report.py
grep -q 'unknown launcher environment key' src/noaa_navionics/report.py
grep -q 'launcher environment has permissions.*expected private 0600' src/noaa_navionics/report.py
grep -q 'launcher environment directory .* has permissions' src/noaa_navionics/cli.py
grep -q 'launcher environment directory .* has permissions' src/noaa_navionics/report.py
grep -q 'directory_uid' src/noaa_navionics/report.py
grep -q 'directory_mode' src/noaa_navionics/report.py
grep -q 'def _read_launcher_settings_lines' src/noaa_navionics/report.py
grep -q 'launcher environment changed before it could be read' src/noaa_navionics/report.py
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/report.py
grep -q 'test_status_report_rejects_writable_launcher_environment_parent_for_gps_wait' tests/test_downloader.py
grep -q 'test_launcher_settings_summary_rejects_nonregular_environment' tests/test_downloader.py
grep -q 'test_launcher_settings_summary_records_owner_and_mode' tests/test_downloader.py
grep -q 'test_launcher_settings_summary_records_public_environment_directory' tests/test_downloader.py
grep -q 'test_launcher_settings_summary_rejects_public_environment_before_parsing' tests/test_downloader.py
grep -q 'test_launcher_settings_reader_rejects_replaced_environment_before_parsing' tests/test_downloader.py
grep -q 'test_launcher_settings_check_fails_misowned_environment' tests/test_downloader.py
grep -q 'test_launcher_settings_check_fails_public_environment_directory' tests/test_downloader.py
grep -q 'key-value file path is a symlink' src/noaa_navionics/report.py
grep -q 'key-value file path is not a regular file' src/noaa_navionics/report.py
grep -q 'key-value file directory is a symlink' src/noaa_navionics/report.py
grep -q 'def _read_key_value_file_lines' src/noaa_navionics/report.py
grep -q 'key-value file path changed before it could be read' src/noaa_navionics/report.py
grep -q 'key-value file path .* has permissions' src/noaa_navionics/report.py
grep -q 'def _key_value_file_integrity_failures' src/noaa_navionics/report.py
grep -q 'is owned by uid' src/noaa_navionics/report.py
grep -q 'has permissions.*expected no group/other write bits' src/noaa_navionics/report.py
grep -q '"path_symlink_component"' src/noaa_navionics/report.py
grep -q 'test_key_value_file_summary_rejects_nonregular_startup_file' tests/test_downloader.py
grep -q 'test_key_value_file_summary_records_owner_and_mode' tests/test_downloader.py
grep -q 'test_key_value_file_summary_rejects_writable_startup_file_before_parsing' tests/test_downloader.py
grep -q 'test_key_value_file_reader_rejects_replaced_startup_file_before_parsing' tests/test_downloader.py
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
grep -q 'user unit file path changed before it could be read' src/noaa_navionics/report.py
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
grep -q 'test_user_unit_file_reader_rejects_replaced_unit_before_parsing' tests/test_downloader.py
grep -q 'Status reports and Pi verification parse user systemd unit install targets only after a no-follow descriptor read confirms the opened unit file is still the inspected file' README.md
grep -q 'Status reports and Pi verification parse user systemd unit install targets only after a no-follow descriptor read confirms the opened unit file is still the inspected file' docs/sailboat-pi.md
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
grep -q 'def _network_host' src/noaa_navionics/cli.py
grep -q 'must not contain whitespace, quotes, semicolons, or pipes' src/noaa_navionics/cli.py
grep -q 'wait_network.add_argument("--host", type=_network_host' src/noaa_navionics/cli.py
grep -q 'def _tcp_port' src/noaa_navionics/cli.py
grep -q 'must be between 1 and 65535' src/noaa_navionics/cli.py
grep -q 'wait_network.add_argument("--port", type=_tcp_port' src/noaa_navionics/cli.py
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
grep -q 'pins command lookup to trusted system directories on Raspberry Pi hardware' README.md
grep -q 'pins command lookup to trusted system directories on Raspberry Pi hardware' docs/sailboat-pi.md
grep -q 'requires a root-owned OpenCPN executable and executable directory on Raspberry Pi hardware' README.md
grep -q 'rejects non-root OpenCPN executables or executable directories on Raspberry Pi hardware' docs/sailboat-pi.md
grep -q 'rejects symlinked, misowned, or public cache parents' README.md
grep -q 'rejects symlinked, misowned, or public cache parents' docs/sailboat-pi.md
grep -q '"package_filename"' src/noaa_navionics/report.py
grep -q '"is_symlink"' src/noaa_navionics/report.py
grep -q '"source_revision_path_is_symlink"' src/noaa_navionics/report.py
grep -q '"source_revision_directory_is_symlink"' src/noaa_navionics/report.py
grep -q '"source_revision_symlink_component"' src/noaa_navionics/report.py
grep -q '"source_revision_directory_uid"' src/noaa_navionics/report.py
grep -q '"source_revision_directory_mode"' src/noaa_navionics/report.py
grep -q '"source_revision_mode"' src/noaa_navionics/report.py
grep -q 'source revision directory .* has permissions' src/noaa_navionics/report.py
grep -q 'deployed source revision directory has permissions' src/noaa_navionics/health.py
grep -q 'source revision path is not a regular file' src/noaa_navionics/report.py
grep -q 'source revision path .* has permissions' src/noaa_navionics/report.py
grep -q 'def _read_source_revision_text' src/noaa_navionics/report.py
grep -q 'def _read_source_revision_text' src/noaa_navionics/health.py
grep -q 'source revision path changed before it could be read' src/noaa_navionics/report.py
grep -q 'source revision path changed before it could be read' src/noaa_navionics/health.py
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/report.py
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/health.py
grep -q 'source revision directory is a symlink' src/noaa_navionics/report.py
grep -q 'deployed source revision directory is a symlink' src/noaa_navionics/health.py
grep -q 'deployed source revision path is not a regular file' src/noaa_navionics/health.py
grep -q 'deployed source revision path has permissions' src/noaa_navionics/health.py
grep -q 'status report source revision path contains a symlink' scripts/verify_pi.sh
grep -q 'test_app_summary_rejects_symlinked_source_revision_directory' tests/test_downloader.py
grep -q 'test_source_revision_reader_rejects_replaced_file_before_parsing' tests/test_downloader.py
grep -q 'test_health_source_revision_reader_rejects_replaced_revision' tests/test_downloader.py
grep -q 'Status reports and Pi readiness read that revision through a no-follow descriptor after confirming the source revision directory is user-owned and not group/world-writable' README.md
grep -q 'Status reports and Pi readiness read that revision through a no-follow descriptor after confirming the source revision directory is user-owned and not group/world-writable' docs/sailboat-pi.md
grep -q 'test_app_summary_rejects_symlinked_source_revision_ancestor' tests/test_downloader.py
grep -q 'test_app_summary_rejects_nonregular_source_revision' tests/test_downloader.py
grep -q 'test_app_summary_rejects_writable_source_revision' tests/test_downloader.py
grep -q 'test_app_summary_rejects_writable_source_revision_directory' tests/test_downloader.py
grep -q 'test_source_revision_reader_rejects_writable_file' tests/test_downloader.py
grep -q 'test_check_source_revision_rejects_symlinked_revision_directory_on_pi' tests/test_downloader.py
grep -q 'test_check_source_revision_rejects_symlinked_revision_ancestor_on_pi' tests/test_downloader.py
grep -q 'test_check_source_revision_rejects_nonregular_revision_on_pi' tests/test_downloader.py
grep -q 'test_check_source_revision_rejects_writable_revision_on_pi' tests/test_downloader.py
grep -q 'test_check_source_revision_rejects_writable_revision_directory_on_pi' tests/test_downloader.py
grep -q 'test_health_source_revision_reader_rejects_writable_revision' tests/test_downloader.py
grep -q 'source revision directory is misowned or group/world-writable' README.md
grep -q 'source revision directory is misowned or group/world-writable' docs/sailboat-pi.md
grep -q 'recorded through a symlinked path component' README.md
grep -q 'recorded through a symlinked path component' docs/sailboat-pi.md
grep -q 'Status reports and Pi readiness read that revision through a no-follow descriptor' README.md
grep -q 'Status reports and Pi readiness read that revision through a no-follow descriptor' docs/sailboat-pi.md
grep -q '"directory_is_symlink"' src/noaa_navionics/report.py
grep -q '"manifest_symlink_component"' src/noaa_navionics/report.py
grep -q '"directory_uid"' src/noaa_navionics/report.py
grep -q '"directory_mode"' src/noaa_navionics/report.py
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
grep -q 'manifest directory .* has permissions' src/noaa_navionics/report.py
grep -q 'manifest directory .* has permissions' src/noaa_navionics/health.py
grep -q 'manifest directory .* has permissions' src/noaa_navionics/downloader.py
grep -q 'manifest path is not a regular file' src/noaa_navionics/report.py
grep -q 'test_manifest_summary_rejects_nonregular_manifest' tests/test_downloader.py
grep -q 'test_manifest_summary_records_owner_and_mode' tests/test_downloader.py
grep -q 'test_manifest_summary_rejects_writable_manifest_directory' tests/test_downloader.py
grep -q 'test_manifest_writable_directory_fails' tests/test_downloader.py
grep -q 'test_read_manifest_rejects_non_directory_manifest_parent' tests/test_downloader.py
grep -q 'test_read_manifest_rejects_writable_manifest_directory' tests/test_downloader.py
grep -q 'status report manifest directory has permissions' scripts/verify_pi.sh
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
grep -q 'desktop autostart, LightDM autologin, and manifest files through same-file no-follow descriptor reads' README.md
grep -q 'desktop autostart, LightDM autologin, and manifest files through same-file no-follow descriptor reads' docs/sailboat-pi.md
grep -q 'readiness report fails if the persisted launcher environment directory is owned by the wrong account or group/world-writable' README.md
grep -q 'Missing or invalid launcher timing and fail-open values stop launcher startup' README.md
grep -q 'Status reports parse launcher settings only after checking the launcher environment directory ownership and permissions' README.md
grep -q 'Pi verification compares status-reported launcher settings only after a no-follow descriptor read' docs/sailboat-pi.md
grep -q 'def _read_existing_config' src/noaa_navionics/config.py
grep -q 'os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' src/noaa_navionics/config.py
grep -q 'NOAA Navionics config is not a regular file when opened' src/noaa_navionics/config.py
grep -q 'parser.read_file(handle, source=str(path))' src/noaa_navionics/config.py
! grep -q 'parser.read(cfg_path)' src/noaa_navionics/config.py
grep -q 'Onboard config reads use a no-follow descriptor' README.md
grep -q 'Config reads use a no-follow descriptor' docs/sailboat-pi.md
grep -q 'Status reports parse launcher settings only after checking the launcher environment directory ownership and permissions' README.md
grep -q 'records launcher settings in status reports only after checking the launcher environment directory ownership and permissions' docs/sailboat-pi.md
grep -q 'launcher.env` through a no-follow descriptor only after rejecting a missing launcher environment' README.md
grep -q 'launcher.env` through a no-follow descriptor only after rejecting a missing launcher environment' docs/sailboat-pi.md
grep -q 'Status reports and Pi verification parse desktop autostart and LightDM autologin files only after a no-follow descriptor read confirms the opened file is still the inspected file' README.md
grep -q 'Pi verification reads the live LightDM autologin session and chrony GPSD refclock config through no-follow descriptors' README.md
grep -q 'Status reports and Pi verification parse user systemd unit install targets only after a no-follow descriptor read confirms the opened unit file is still the inspected file' README.md
grep -q 'rejects missing or invalid launcher timing and fail-open values instead of falling back to defaults' docs/sailboat-pi.md
grep -q 'records launcher settings in status reports only after checking the launcher environment directory ownership and permissions' docs/sailboat-pi.md
grep -q 'Status reports and Pi verification parse desktop autostart and LightDM autologin files only after a no-follow descriptor read confirms the opened file is still the inspected file' docs/sailboat-pi.md
grep -q 'Pi verification reads the live LightDM autologin session and chrony GPSD refclock config through no-follow descriptors' docs/sailboat-pi.md
grep -q 'Status reports and Pi verification parse user systemd unit install targets only after a no-follow descriptor read confirms the opened unit file is still the inspected file' docs/sailboat-pi.md
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
grep -q 'chart output directory .* became a symlink after permission tightening' src/noaa_navionics/downloader.py
grep -q 'chart output directory .* is owned by uid' src/noaa_navionics/downloader.py
grep -q 'os.chmod(output_path, 0o700)' src/noaa_navionics/downloader.py
grep -q 'expected no group/other write bits' src/noaa_navionics/health.py
grep -q 'test_download_tightens_chart_output_directory' tests/test_downloader.py
grep -q 'test_download_rejects_chart_output_directory_when_tightening_fails' tests/test_downloader.py
grep -q 'test_disk_check_rejects_public_storage_directory' tests/test_downloader.py
grep -q 'test_download_rejects_symlinked_output_ancestor' tests/test_downloader.py
grep -q 'test_write_manifest_rejects_symlinked_output_ancestor' tests/test_downloader.py
grep -q 'Chart output directory permission tightening is revalidated before creating locks, archives, extracted trees, or manifests' README.md
grep -q 'Chart output directory permission tightening is revalidated before creating locks, archives, extracted trees, or manifests' docs/sailboat-pi.md
grep -q '"min_free_gb": app_config.min_free_gb' src/noaa_navionics/report.py
grep -q '"anchor_radius_meters": app_config.anchor_radius_meters' src/noaa_navionics/report.py
grep -q 'Anchor radius:' src/noaa_navionics/report.py
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
grep -q 'LockPersonality=true' systemd/noaa-navionics.service
grep -q 'LockPersonality=true' systemd/noaa-navionics-track.service
grep -q 'LockPersonality=true' systemd/noaa-navionics-preflight.service
grep -q 'RestrictSUIDSGID=true' systemd/noaa-navionics.service
grep -q 'RestrictSUIDSGID=true' systemd/noaa-navionics-track.service
grep -q 'RestrictSUIDSGID=true' systemd/noaa-navionics-preflight.service
grep -q 'MemoryDenyWriteExecute=true' systemd/noaa-navionics.service
grep -q 'MemoryDenyWriteExecute=true' systemd/noaa-navionics-track.service
grep -q 'MemoryDenyWriteExecute=true' systemd/noaa-navionics-preflight.service
grep -q 'RestrictRealtime=true' systemd/noaa-navionics.service
grep -q 'RestrictRealtime=true' systemd/noaa-navionics-track.service
grep -q 'RestrictRealtime=true' systemd/noaa-navionics-preflight.service
grep -q 'UMask=0077' systemd/noaa-navionics.service
grep -q 'UMask=0077' systemd/noaa-navionics-preflight.service
grep -q 'NoNewPrivileges.*yes' src/noaa_navionics/report.py
grep -q 'PrivateTmp.*yes' src/noaa_navionics/report.py
grep -q 'ProtectSystem.*full' src/noaa_navionics/report.py
grep -q 'LockPersonality.*yes' src/noaa_navionics/report.py
grep -q 'RestrictSUIDSGID.*yes' src/noaa_navionics/report.py
grep -q 'MemoryDenyWriteExecute.*yes' src/noaa_navionics/report.py
grep -q 'RestrictRealtime.*yes' src/noaa_navionics/report.py
grep -q 'LockPersonality' tests/test_downloader.py
grep -q 'RestrictSUIDSGID' tests/test_downloader.py
grep -q 'MemoryDenyWriteExecute' tests/test_downloader.py
grep -q 'RestrictRealtime' tests/test_downloader.py
grep -q 'chart service lock personality' scripts/verify_pi.sh
grep -q 'track service restrict suid sgid' scripts/verify_pi.sh
grep -q 'preflight service loaded lock personality' scripts/verify_pi.sh
grep -q 'chart service deny writable executable memory' scripts/verify_pi.sh
grep -q 'track service loaded restrict realtime' scripts/verify_pi.sh
grep -q 'preflight service loaded deny writable executable memory' scripts/verify_pi.sh
grep -q 'LockPersonality' README.md
grep -q 'RestrictSUIDSGID' README.md
grep -q 'MemoryDenyWriteExecute' README.md
grep -q 'RestrictRealtime' README.md
grep -q 'LockPersonality' docs/sailboat-pi.md
grep -q 'RestrictSUIDSGID' docs/sailboat-pi.md
grep -q 'MemoryDenyWriteExecute' docs/sailboat-pi.md
grep -q 'RestrictRealtime' docs/sailboat-pi.md
grep -q 'UMask.*0077' src/noaa_navionics/report.py
python3 - <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, "src")
from noaa_navionics import report

expected_unit_properties = {
    "NoNewPrivileges": "true",
    "PrivateTmp": "true",
    "ProtectSystem": "full",
    "LockPersonality": "true",
    "RestrictSUIDSGID": "true",
    "MemoryDenyWriteExecute": "true",
    "RestrictRealtime": "true",
    "UMask": "0077",
}

for unit in (
    "noaa-navionics.service",
    "noaa-navionics-track.service",
    "noaa-navionics-preflight.service",
):
    unit_text = Path("systemd", unit).read_text(encoding="utf-8")
    unit_lines = set(unit_text.splitlines())
    for property_name, expected_value in expected_unit_properties.items():
        expected_line = f"{property_name}={expected_value}"
        if expected_line not in unit_lines:
            raise SystemExit(f"{unit} must set {expected_line}")
    properties = report.USER_UNIT_PROPERTIES[unit]
    for property_name in expected_unit_properties:
        if property_name not in properties:
            raise SystemExit(f"status report must query loaded {unit} {property_name}")
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
grep -q 'RestartSec=10' systemd/noaa-navionics-track.service
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
grep -q 'NOAA_NAVIONICS_WARNING_SECONDS=%s' scripts/provision_sailboat_pi.sh
grep -q 'NOAA_NAVIONICS_READINESS_ATTEMPTS=%s' scripts/provision_sailboat_pi.sh
grep -q 'NOAA_NAVIONICS_READINESS_RETRY_DELAY=%s' scripts/provision_sailboat_pi.sh
grep -q 'NOAA_NAVIONICS_START_ON_FAILED_READINESS=%s' scripts/provision_sailboat_pi.sh
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTARTS=%s' scripts/provision_sailboat_pi.sh
grep -q 'NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=%s' scripts/provision_sailboat_pi.sh
grep -q 'mktemp "${launcher_env_dir}/.launcher.env.XXXXXX"' scripts/provision_sailboat_pi.sh
grep -q 'chmod 0600 "$launcher_env_tmp"' scripts/provision_sailboat_pi.sh
grep -q 'sync_paths "$launcher_env_tmp"' scripts/provision_sailboat_pi.sh
test "$(grep -c 'validate_user_install_path "$launcher_env" "chartplotter launcher environment"' scripts/provision_sailboat_pi.sh)" -ge 2
grep -q 'mv -f "$launcher_env_tmp" "$launcher_env"' scripts/provision_sailboat_pi.sh
grep -q 'verify_launcher_env "$launcher_env" "$gps_seconds" "$warning_seconds" "$readiness_attempts" "$readiness_retry_delay" "$start_on_failed_readiness" "$opencpn_restarts" "$opencpn_restart_delay"' scripts/provision_sailboat_pi.sh
grep -q 'flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)' scripts/provision_sailboat_pi.sh
grep -q 'promoted launcher environment .* expected 0600' scripts/provision_sailboat_pi.sh
grep -q 'has values .* expected' scripts/provision_sailboat_pi.sh
grep -q 'Provisioning revalidates user directories after creating or tightening them before placing temporary files there' README.md
grep -q 'Provisioning revalidates user directories after creating or tightening them before placing temporary files there' docs/sailboat-pi.md
grep -q 'Provisioning requires the installed private `~/.local/bin/noaa-navionics` symlink to resolve into `~/.local/share/noaa-navionics/venv/bin/noaa-navionics`' README.md
grep -q 'Provisioning requires the installed private `~/.local/bin/noaa-navionics` symlink to resolve into `~/.local/share/noaa-navionics/venv/bin/noaa-navionics`' docs/sailboat-pi.md
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
test "$(grep -c 'validate_user_directory_path "$target" "$label"' scripts/provision_sailboat_pi.sh)" -ge 3
grep -q 'validate_user_directory_path "$target_dir" "provisioned user file directory"' scripts/provision_sailboat_pi.sh
test "$(grep -c 'validate_user_install_path "$target" "provisioned user file"' scripts/provision_sailboat_pi.sh)" -ge 2
grep -q 'mv -f "$tmp" "$target"' scripts/provision_sailboat_pi.sh
grep -q 'sync_paths "$target"' scripts/provision_sailboat_pi.sh
grep -q 'verify_promoted_user_file "$source" "$target" "$mode"' scripts/provision_sailboat_pi.sh
grep -q 'promoted provisioned user file .* expected' scripts/provision_sailboat_pi.sh
grep -q 'does not match source' scripts/provision_sailboat_pi.sh
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/provision_sailboat_pi.sh").read_text(encoding="utf-8")
install_start = text.index("install_file_atomic()")
install_mkdir = text.index('mkdir -p "$target_dir"', install_start)
install_validate_dir = text.index('validate_user_directory_path "$target_dir" "provisioned user file directory"', install_mkdir)
install_mktemp = text.index('mktemp "${target_dir}/.${target_name}.XXXXXX"', install_validate_dir)
promote = text.index('mv -f "$tmp" "$target"', install_start)
verify = text.index('verify_promoted_user_file "$source" "$target" "$mode"', promote)
sync = text.index('sync_paths "$target"', verify)
daemon = text.index('run "$systemctl_cmd" --user daemon-reload')
ensure_start = text.index("ensure_private_directory()")
ensure_mkdir = text.index('mkdir -p "$target"', ensure_start)
ensure_validate_after_mkdir = text.index('validate_user_directory_path "$target" "$label"', ensure_mkdir)
ensure_chmod = text.index('chmod 0700 "$target"', ensure_validate_after_mkdir)
ensure_validate_after_chmod = text.index('validate_user_directory_path "$target" "$label"', ensure_chmod)
ensure_sync = text.index('sync_paths "$target"', ensure_validate_after_chmod)
if not install_mkdir < install_validate_dir < install_mktemp < promote < verify < sync < daemon:
    raise SystemExit("promoted user files must be verified before sync and daemon reload")
if not ensure_mkdir < ensure_validate_after_mkdir < ensure_chmod < ensure_validate_after_chmod < ensure_sync:
    raise SystemExit("private directory provisioning must revalidate after mkdir and chmod before syncing")
PY
grep -q 'install_file_atomic "${repo_root}/systemd/noaa-navionics.service" "$chart_service" 0644' scripts/provision_sailboat_pi.sh
grep -q 'install_file_atomic "${repo_root}/systemd/noaa-navionics.timer" "$chart_timer" 0644' scripts/provision_sailboat_pi.sh
grep -q 'install_file_atomic "${repo_root}/systemd/noaa-navionics-track.service" "$track_service" 0644' scripts/provision_sailboat_pi.sh
grep -q 'install_file_atomic "${repo_root}/systemd/noaa-navionics-preflight.service" "$preflight_service" 0644' scripts/provision_sailboat_pi.sh
grep -q 'install_file_atomic "${repo_root}/templates/noaa-navionics-chartplotter.desktop" "$autostart_entry" 0644' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_units' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_unit_property noaa-navionics.service ProtectSystem full "chart refresh service"' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_unit_property noaa-navionics-track.service ProtectSystem full "track logger service"' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_unit_property noaa-navionics-preflight.service ProtectSystem full "boot readiness service"' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_unit_property noaa-navionics.service MemoryDenyWriteExecute yes "chart refresh service"' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_unit_property noaa-navionics-track.service RestrictRealtime yes "track logger service"' scripts/provision_sailboat_pi.sh
grep -q 'require_loaded_user_unit_property noaa-navionics-preflight.service MemoryDenyWriteExecute yes "boot readiness service"' scripts/provision_sailboat_pi.sh
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/provision_sailboat_pi.sh").read_text(encoding="utf-8")
units = {
    "noaa-navionics.service": "chart refresh service",
    "noaa-navionics-track.service": "track logger service",
    "noaa-navionics-preflight.service": "boot readiness service",
}
expected_properties = {
    "NoNewPrivileges": "yes",
    "PrivateTmp": "yes",
    "ProtectSystem": "full",
    "LockPersonality": "yes",
    "RestrictSUIDSGID": "yes",
    "MemoryDenyWriteExecute": "yes",
    "RestrictRealtime": "yes",
    "UMask": "0077",
}
for unit, label in units.items():
    for property_name, expected_value in expected_properties.items():
        needle = (
            f'require_loaded_user_unit_property {unit} {property_name} '
            f'{expected_value} "{label}"'
        )
        if needle not in text:
            raise SystemExit(f"provisioning must verify loaded {unit} {property_name}")
PY
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
grep -q 'require_trusted_system_command()' scripts/provision_sailboat_pi.sh
grep -q 'path_in_trusted_system_dir()' scripts/provision_sailboat_pi.sh
grep -q 'systemctl_cmd="$(require_trusted_system_command systemctl "Systemctl command")"' scripts/provision_sailboat_pi.sh
grep -q 'loginctl_cmd="$(require_trusted_system_command loginctl "Loginctl command")"' scripts/provision_sailboat_pi.sh
grep -q 'sudo_cmd="$(require_trusted_system_command sudo "Sudo command")"' scripts/provision_sailboat_pi.sh
grep -q 'python3_command()' scripts/provision_sailboat_pi.sh
grep -q 'python3_cmd="$(require_trusted_system_command python3 "Python command")"' scripts/provision_sailboat_pi.sh
grep -q 'python3_cmd="$(python3_command)" || exit 2' scripts/provision_sailboat_pi.sh
grep -q '"$python3_cmd" - "$@"' scripts/provision_sailboat_pi.sh
grep -q '"$python3_cmd" - "$target" "$label"' scripts/provision_sailboat_pi.sh
grep -q 'sudo_cmd="$(sudo_command)" || exit 2' scripts/provision_sailboat_pi.sh
grep -q 'trusted systemctl is required to validate existing' scripts/provision_sailboat_pi.sh
grep -q 'run "$sudo_cmd" "$loginctl_cmd" enable-linger "$USER"' scripts/provision_sailboat_pi.sh
! grep -q 'run sudo "$loginctl_cmd" enable-linger "$USER"' scripts/provision_sailboat_pi.sh
! grep -Eq '(^|[[:space:]])python3[[:space:]]+-' scripts/provision_sailboat_pi.sh
grep -q 'run "$systemctl_cmd" --user reset-failed noaa-navionics.service noaa-navionics-track.service noaa-navionics-preflight.service' scripts/provision_sailboat_pi.sh
grep -q 'clears stale failed states for the chart refresh, track logger, and boot readiness services' README.md
grep -q 'clears stale failed states for the chart refresh, track logger, and boot readiness services' docs/sailboat-pi.md
grep -q 'confirms systemd loaded the installed user-unit fragments and hardening settings before enabling unattended startup' README.md
grep -q 'confirms systemd loaded the installed user-unit fragments and hardening settings before enabling unattended startup' docs/sailboat-pi.md
grep -q 'resolves sudo, systemctl, loginctl, and Python through trusted root-owned command checks' README.md
grep -q 'resolves sudo, systemctl, loginctl, and Python through trusted root-owned command checks' docs/sailboat-pi.md
grep -q 'run "$systemctl_cmd" --user enable --now noaa-navionics-track.service' scripts/provision_sailboat_pi.sh
grep -q 'run "$systemctl_cmd" --user enable --now noaa-navionics.timer' scripts/provision_sailboat_pi.sh
grep -q 'run "$systemctl_cmd" --user restart noaa-navionics-track.service' scripts/provision_sailboat_pi.sh
grep -q 'run "$systemctl_cmd" --user enable noaa-navionics-preflight.service' scripts/provision_sailboat_pi.sh
grep -q 'run "$systemctl_cmd" --user restart noaa-navionics-preflight.service' scripts/provision_sailboat_pi.sh
grep -q 'must be a positive integer' scripts/provision_sailboat_pi.sh
python3 - <<'PY'
from pathlib import Path

text = Path("scripts/provision_sailboat_pi.sh").read_text(encoding="utf-8")
python_resolve = text.index('python3_cmd="$(python3_command)" || exit 2')
same_path = text.index('if ! same_path "$config" "$default_config"')
status_index = text.index('run "$bin" status-report')
autologin_index = text.index('configure_desktop_autologin.sh" "${desktop_args[@]}"')
if python_resolve > same_path:
    raise SystemExit("provisioning must validate Python before Python-backed path helpers")
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
grep -q 'remote_sudo_command' scripts/dock_test_pi.sh
grep -q 'remote_python_command' scripts/dock_test_pi.sh
grep -q 'validate_remote_root_command_trust' scripts/dock_test_pi.sh
grep -q 'validate_remote_reboot_command_trust' scripts/dock_test_pi.sh
grep -q 'Remote ${command_label} command is not in a trusted system directory' scripts/dock_test_pi.sh
grep -q 'Remote ${command_label} command ${item_kind} is owned by uid' scripts/dock_test_pi.sh
grep -q 'Remote ${command_label} command ${item_kind} has permissions' scripts/dock_test_pi.sh
grep -Fq 'readlink -f -- "$command_path"' scripts/dock_test_pi.sh
grep -q 'Remote ${command_label} command is not executable after resolution' scripts/dock_test_pi.sh
grep -q '${remote_system_path} && export PATH && true' scripts/dock_test_pi.sh
grep -Fq '${remote_system_path} && export PATH && '"'"'$remote_python_cmd'"'"' -' scripts/dock_test_pi.sh
! grep -q '${remote_system_path} && export PATH && python3 -' scripts/dock_test_pi.sh
grep -q 'Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()' scripts/dock_test_pi.sh
grep -q 'remote boot ID is invalid; expected Linux boot_id value' scripts/dock_test_pi.sh
! grep -q '${remote_system_path} && export PATH && cat /proc/sys/kernel/random/boot_id' scripts/dock_test_pi.sh
grep -q '${remote_system_path} && export PATH && command -v reboot' scripts/dock_test_pi.sh
grep -q '${remote_system_path} && export PATH && command -v sudo' scripts/dock_test_pi.sh
grep -q '${remote_system_path} && export PATH && command -v python3' scripts/dock_test_pi.sh
grep -q '${remote_system_path} && export PATH && '"'"'$remote_sudo_cmd'"'"' -n -l' scripts/dock_test_pi.sh
grep -Fq '${remote_system_path} && export PATH && '"'"'$remote_sudo_cmd'"'"' -n '"'"'$remote_reboot_cmd'"'" scripts/dock_test_pi.sh
grep -q -- "-n -l '\$remote_reboot_cmd'" scripts/dock_test_pi.sh
grep -q "'\$remote_sudo_cmd' -n '\$remote_reboot_cmd'" scripts/dock_test_pi.sh
! grep -q 'sudo -n reboot' scripts/dock_test_pi.sh
grep -q '"$ssh_cmd" -T "${ssh_batch_options\[@\]}" "$target"' scripts/verify_pi.sh
grep -q 'ServerAliveInterval=30' scripts/deploy_to_pi.sh
grep -q 'ServerAliveInterval=30' scripts/verify_pi.sh
grep -q 'ServerAliveInterval=30' scripts/dock_test_pi.sh
grep -q 'reboot sudo preflight' scripts/dock_test_pi.sh
grep -q 'request_reboot' scripts/dock_test_pi.sh
grep -q 'Failed to request reboot with passwordless sudo' scripts/dock_test_pi.sh
grep -q 'remote_boot_id' scripts/dock_test_pi.sh
grep -q 'validate_boot_id_value' scripts/dock_test_pi.sh
grep -q 'validate_boot_id_value "pre-reboot" "$before_boot_id"' scripts/dock_test_pi.sh
grep -q 'validate_boot_id_value "post-reboot" "$after_boot_id"' scripts/dock_test_pi.sh
grep -q 'expected Linux boot_id value' scripts/dock_test_pi.sh
grep -q 'boot ID changed after reboot' scripts/dock_test_pi.sh
grep -q -- '--expected-boot-id "$after_boot_id"' scripts/dock_test_pi.sh
grep -q 'verify_args+=("--expected-gps-device" "$device")' scripts/dock_test_pi.sh
grep -q -- '--device is required for the rebooted dock acceptance test' scripts/dock_test_pi.sh
grep -q 'Pre-reboot verification passed; reboot and chartplotter autostart proof were skipped' scripts/dock_test_pi.sh
grep -q -- '--skip-autologin cannot be used for the dock acceptance test' scripts/dock_test_pi.sh
grep -q 'use deploy_to_pi.sh --provision --skip-autologin --skip-services' scripts/dock_test_pi.sh
grep -q 'preflights noninteractive sudo reboot access before deploying or provisioning' README.md
grep -q 'preflights noninteractive sudo reboot access before deploying or provisioning' docs/sailboat-pi.md
grep -q 'validates the remote absolute `reboot` and `sudo` command paths' README.md
grep -q 'validates the remote absolute `reboot` and `sudo` command paths' docs/sailboat-pi.md
grep -q 'validates the remote absolute `python3` command path before reading boot IDs' README.md
grep -q 'validates the remote absolute `python3` command path before reading boot IDs' docs/sailboat-pi.md
grep -q 'root-owned, executable, non-group/world-writable commands in trusted system directories' README.md
grep -q 'root-owned, executable, non-group/world-writable commands in trusted system directories' docs/sailboat-pi.md
grep -q 'pins remote reboot probes and sudo calls to trusted system command directories' README.md
grep -q 'pins remote reboot probes and sudo calls to trusted system command directories' docs/sailboat-pi.md
grep -q 'pins its remote command path to trusted system directories' README.md
grep -q 'pins its remote command path to trusted system directories' docs/sailboat-pi.md
grep -q 'reads and validates the Pi pre- and post-reboot boot IDs as Linux `boot_id` values on the Pi before comparing them' README.md
grep -q 'reads and validates the Pi pre- and post-reboot boot IDs as Linux `boot_id` values on the Pi before comparing them' docs/sailboat-pi.md
grep -q 'passes that observed post-reboot boot ID into strict verification' README.md
grep -q 'passes that observed post-reboot boot ID into strict verification' docs/sailboat-pi.md
grep -q 'misowned or group/world-writable launcher environment directories' README.md
grep -q 'misowned or group/world-writable launcher environment directories' docs/sailboat-pi.md
grep -q 'checking the launcher environment directory ownership and permissions' README.md
grep -q 'checking the launcher environment directory ownership and permissions' docs/sailboat-pi.md

python3 - <<'PY'
from pathlib import Path

text = Path("scripts/dock_test_pi.sh").read_text(encoding="utf-8")
preflight_block_index = text.index('if [[ "$no_reboot" -eq 0 ]]; then')
preflight_call_index = text.index("check_remote_noninteractive_reboot_available", preflight_block_index)
deploy_index = text.index('"${repo_root}/scripts/deploy_to_pi.sh"', preflight_call_index)
if deploy_index < preflight_call_index:
    raise SystemExit("dock test reboot sudo preflight must run before deploy/provision")

before_index = text.index('before_boot_id="$(remote_boot_id)"')
before_guard_index = text.index('validate_boot_id_value "pre-reboot" "$before_boot_id"', before_index)
request_reboot_index = text.index('\nrequest_reboot\n', before_guard_index)
after_index = text.index('after_boot_id="$(remote_boot_id)"', request_reboot_index)
after_guard_index = text.index('validate_boot_id_value "post-reboot" "$after_boot_id"', after_index)
strict_verify_index = text.index('--expected-boot-id "$after_boot_id"', after_guard_index)
if not before_index < before_guard_index < request_reboot_index < after_index < after_guard_index < strict_verify_index:
    raise SystemExit("dock test must validate collected boot IDs before reboot comparison and strict verify")
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

support_remote_heredoc="$tmpdir/support-remote-heredoc.sh"
awk "/<<'REMOTE'/{capture=1; next} /^REMOTE$/{capture=0} capture" scripts/collect_pi_support_bundle.sh >"$support_remote_heredoc"
bash -n "$support_remote_heredoc"
refresh_remote_heredoc="$tmpdir/refresh-remote-heredoc.sh"
awk "/<<'REMOTE'/{capture=1; next} /^REMOTE$/{capture=0} capture" scripts/refresh_pi_charts.sh >"$refresh_remote_heredoc"
bash -n "$refresh_remote_heredoc"
shutdown_remote_heredoc="$tmpdir/shutdown-remote-heredoc.sh"
awk "/<<'REMOTE'/{capture=1; next} /^REMOTE$/{capture=0} capture" scripts/shutdown_pi_safely.sh >"$shutdown_remote_heredoc"
bash -n "$shutdown_remote_heredoc"

write_test_launcher_env() {
  local home_dir="$1"
  mkdir -p "$home_dir/.config/noaa-navionics"
  chmod 0700 "$home_dir/.config/noaa-navionics"
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
scripts/verify_pi.sh 'bad;user@example.invalid' >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject unsafe SSH target users with exit 2" >&2
  exit 1
fi
grep -q 'SSH target user contains unsafe characters' "$verify_output"

set +e
scripts/verify_pi.sh 'pi@example.invalid;bad' >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject unsafe SSH target hosts with exit 2" >&2
  exit 1
fi
grep -q 'SSH target host contains unsafe characters' "$verify_output"

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
scripts/pre_departure_check_pi.sh --help >"$verify_output" 2>&1
pre_departure_code=$?
set -e
if [[ "$pre_departure_code" -ne 0 ]]; then
  cat "$verify_output" >&2
  echo "expected pre_departure_check_pi.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/pre_departure_check_pi.sh' "$verify_output"

set +e
scripts/refresh_pi_charts.sh --help >"$verify_output" 2>&1
refresh_code=$?
set -e
if [[ "$refresh_code" -ne 0 ]]; then
  cat "$verify_output" >&2
  echo "expected refresh_pi_charts.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/refresh_pi_charts.sh' "$verify_output"

set +e
scripts/collect_pi_support_bundle.sh --help >"$verify_output" 2>&1
support_bundle_code=$?
set -e
if [[ "$support_bundle_code" -ne 0 ]]; then
  cat "$verify_output" >&2
  echo "expected collect_pi_support_bundle.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/collect_pi_support_bundle.sh' "$verify_output"

set +e
scripts/shutdown_pi_safely.sh --help >"$verify_output" 2>&1
shutdown_code=$?
set -e
if [[ "$shutdown_code" -ne 0 ]]; then
  cat "$verify_output" >&2
  echo "expected shutdown_pi_safely.sh --help to exit 0" >&2
  exit 1
fi
grep -q 'Usage: scripts/shutdown_pi_safely.sh' "$verify_output"

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
scripts/deploy_to_pi.sh 'bad;user@example.invalid' --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject unsafe SSH target users with exit 2" >&2
  exit 1
fi
grep -q 'SSH target user contains unsafe characters' "$deploy_output"

set +e
scripts/deploy_to_pi.sh 'pi@example.invalid;bad' --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject unsafe SSH target hosts with exit 2" >&2
  exit 1
fi
grep -q 'SSH target host contains unsafe characters' "$deploy_output"

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
scripts/deploy_to_pi.sh pi@example.invalid '~/../../tmp/noaa-navionics' --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject parent-directory remote deployment paths with exit 2" >&2
  exit 1
fi
grep -q 'Remote deployment directory must not contain parent-directory components' "$deploy_output"

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
scripts/dock_test_pi.sh 'bad;user@example.invalid' --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject unsafe SSH target users with exit 2" >&2
  exit 1
fi
grep -q 'SSH target user contains unsafe characters' "$dock_output"

set +e
scripts/dock_test_pi.sh 'pi@example.invalid;bad' --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject unsafe SSH target hosts with exit 2" >&2
  exit 1
fi
grep -q 'SSH target host contains unsafe characters' "$dock_output"

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
scripts/dock_test_pi.sh pi@example.invalid '~/../../tmp/noaa-navionics' --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 2 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject parent-directory remote deployment paths with exit 2" >&2
  exit 1
fi
grep -q 'Remote deployment directory must not contain parent-directory components' "$dock_output"

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
  --skip-services \
  --skip-autologin \
  --device /dev/ttyUSB0 >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to reject a volatile supplied GPS device path even when GPSD setup is skipped" >&2
  exit 1
fi
grep -q 'GPS device path is volatile' "$provision_output"

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

provision_verify_home="$tmpdir/provision-verify-home"
mkdir -p "$provision_verify_home/.local/bin" "$provision_verify_home/.local/share/noaa-navionics/venv/bin"
cat >"$provision_verify_home/.local/share/noaa-navionics/venv/bin/noaa-navionics" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  init-config)
    shift
    config=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --config)
          config="${2:-}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    mkdir -p "$(dirname "$config")"
    printf '[charts]\noutput = %s/charts\n[gps]\nmode = gpsd\ndevice = /dev/serial/by-id/mock-gps\n' "$HOME" >"$config"
    ;;
  configure-opencpn)
    exit 0
    ;;
  status-report)
    output=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --output)
          output="${2:-}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    mkdir -p "$(dirname "$output")"
    printf '{"ready":true}\n' >"$output"
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod 0700 "$provision_verify_home/.local/share" "$provision_verify_home/.local/share/noaa-navionics" "$provision_verify_home/.local/share/noaa-navionics/venv" "$provision_verify_home/.local/share/noaa-navionics/venv/bin"
chmod 0755 "$provision_verify_home/.local/share/noaa-navionics/venv/bin/noaa-navionics"
ln -s "$provision_verify_home/.local/share/noaa-navionics/venv/bin/noaa-navionics" "$provision_verify_home/.local/bin/noaa-navionics"
HOME="$provision_verify_home" \
  scripts/provision_sailboat_pi.sh \
    --allow-non-pi \
    --skip-gpsd \
    --skip-gps-time \
    --skip-sync \
    --skip-services \
    --skip-autologin \
    --gps-seconds 37 \
    --opencpn-restarts 2 \
    --opencpn-restart-delay 4 >"$provision_output" 2>&1
grep -q 'Provisioning complete.' "$provision_output"
test "$(stat -c '%a' "$provision_verify_home/.config/noaa-navionics/launcher.env")" = 600
grep -Fxq 'NOAA_NAVIONICS_GPS_SECONDS=37' "$provision_verify_home/.config/noaa-navionics/launcher.env"
grep -Fxq 'NOAA_NAVIONICS_OPENCPN_RESTARTS=2' "$provision_verify_home/.config/noaa-navionics/launcher.env"
grep -Fxq 'NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=4' "$provision_verify_home/.config/noaa-navionics/launcher.env"

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

deploy_fake_ssh_bin="$tmpdir/deploy-fake-ssh-bin"
mkdir -p "$deploy_fake_ssh_bin"
cat >"$deploy_fake_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"command -v python3"*)
    printf '%s\n' /usr/bin/python3
    exit 0
    ;;
  *"sh -s -- /usr/bin/python3 python3"*)
    exit 0
    ;;
  *"command -v rsync"*)
    exit 1
    ;;
  *"command -v tar"*)
    printf '%s\n' /home/pi/bin/tar
    exit 0
    ;;
esac
echo "unexpected fake deploy ssh invocation: $args" >&2
exit 1
EOF
chmod +x "$deploy_fake_ssh_bin/ssh"

set +e
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$deploy_fake_ssh_bin:$PATH" \
  scripts/deploy_to_pi.sh pi@example.invalid --allow-dirty --provision --device /dev/serial/by-id/mock-gps >"$deploy_output" 2>&1
deploy_code=$?
set -e
if [[ "$deploy_code" -ne 2 ]]; then
  cat "$deploy_output" >&2
  echo "expected deploy_to_pi.sh to reject untrusted remote tar with exit 2" >&2
  exit 1
fi
grep -q 'Remote deploy command tar is not in a trusted system directory: /home/pi/bin/tar' "$deploy_output"
grep -q 'Could not confirm required remote command on the Pi: tar' "$deploy_output"

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

dock_smoke_ssh_bin="$tmpdir/dock-smoke-ssh-bin"
dock_smoke_ssh_log="$tmpdir/dock-smoke-ssh-log"
mkdir -p "$dock_smoke_ssh_bin"
cat >"$dock_smoke_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NOAA_NAVIONICS_FAKE_SSH_LOG"
case "$*" in
  *"command -v reboot"*|*"command -v sudo"*|*"boot_id"*|*--expected-gps-device*)
    exit 99
    ;;
esac
exit 0
EOF
chmod +x "$dock_smoke_ssh_bin/ssh"
NOAA_NAVIONICS_FAKE_SSH_LOG="$dock_smoke_ssh_log" \
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$dock_smoke_ssh_bin:$PATH" \
  scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --no-reboot --allow-dirty >"$dock_output" 2>&1
grep -q 'Pre-reboot verification passed; reboot and chartplotter autostart proof were skipped' "$dock_output"
grep -q 'NOAA_NAVIONICS_EXPECTED_GPS_DEVICE=' "$dock_smoke_ssh_log"
! grep -q -- '--expected-gps-device' "$dock_smoke_ssh_log"
! grep -q 'command -v reboot' "$dock_smoke_ssh_log"
! grep -q 'command -v sudo' "$dock_smoke_ssh_log"
! grep -q 'boot_id' "$dock_smoke_ssh_log"

dock_fake_ssh_bin="$tmpdir/dock-fake-ssh-bin"
mkdir -p "$dock_fake_ssh_bin"
cat >"$dock_fake_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"command -v reboot"* ]]; then
  printf '%s\n' "${NOAA_NAVIONICS_FAKE_REBOOT_PATH:-/usr/sbin/reboot}"
  exit 0
fi
if [[ "$args" == *"command -v sudo"* ]]; then
  printf '%s\n' "${NOAA_NAVIONICS_FAKE_SUDO_PATH:-/usr/bin/sudo}"
  exit 0
fi
if [[ "$args" == *"command -v python3"* ]]; then
  printf '%s\n' "${NOAA_NAVIONICS_FAKE_PYTHON_PATH:-/usr/bin/python3}"
  exit 0
fi
if [[ "$args" == *"sh -s -- /usr/sbin/reboot reboot"* ]]; then
  if [[ -n "${NOAA_NAVIONICS_FAKE_REBOOT_TRUST_ERROR:-}" ]]; then
    printf '%s\n' "$NOAA_NAVIONICS_FAKE_REBOOT_TRUST_ERROR" >&2
    exit 1
  fi
  if [[ "${NOAA_NAVIONICS_FAKE_REBOOT_NOT_EXECUTABLE:-0}" == "1" ]]; then
    printf '%s\n' "Remote reboot command is not executable after resolution: /usr/sbin/reboot -> /usr/sbin/reboot" >&2
    exit 1
  fi
  exit 0
fi
if [[ "$args" == *"sh -s -- /usr/bin/sudo sudo"* ]]; then
  if [[ -n "${NOAA_NAVIONICS_FAKE_SUDO_TRUST_ERROR:-}" ]]; then
    printf '%s\n' "$NOAA_NAVIONICS_FAKE_SUDO_TRUST_ERROR" >&2
    exit 1
  fi
  exit 0
fi
if [[ "$args" == *"sh -s -- /usr/bin/python3 python3"* ]]; then
  if [[ -n "${NOAA_NAVIONICS_FAKE_PYTHON_TRUST_ERROR:-}" ]]; then
    printf '%s\n' "$NOAA_NAVIONICS_FAKE_PYTHON_TRUST_ERROR" >&2
    exit 1
  fi
  exit 0
fi
if [[ "$args" == *"-n -l"* ]]; then
  exit 0
fi
if [[ "$args" == *"NOAA_NAVIONICS_EXPECTED_REVISION="* ]]; then
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
NOAA_NAVIONICS_FAKE_REBOOT_PATH=/usr/sbin/reboot \
NOAA_NAVIONICS_FAKE_REBOOT_NOT_EXECUTABLE=1 \
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$dock_fake_ssh_bin:$PATH" \
  scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 1 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject non-executable reboot commands with exit 1" >&2
  exit 1
fi
grep -q 'Remote reboot command is not executable after resolution' "$dock_output"

set +e
NOAA_NAVIONICS_FAKE_REBOOT_PATH=/usr/sbin/reboot \
NOAA_NAVIONICS_FAKE_SUDO_PATH=/home/pi/bin/sudo \
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$dock_fake_ssh_bin:$PATH" \
  scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 1 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject user-writable-looking sudo commands with exit 1" >&2
  exit 1
fi
grep -q 'Remote sudo command is not in a trusted system directory: /home/pi/bin/sudo' "$dock_output"

set +e
NOAA_NAVIONICS_FAKE_REBOOT_PATH=/usr/sbin/reboot \
NOAA_NAVIONICS_FAKE_SUDO_PATH=/usr/bin/sudo \
NOAA_NAVIONICS_FAKE_SUDO_TRUST_ERROR='Remote sudo command file is owned by uid 1000, expected 0: /usr/bin/sudo' \
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$dock_fake_ssh_bin:$PATH" \
  scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 1 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject non-root sudo commands with exit 1" >&2
  exit 1
fi
grep -q 'Remote sudo command file is owned by uid 1000, expected 0: /usr/bin/sudo' "$dock_output"

set +e
NOAA_NAVIONICS_FAKE_REBOOT_PATH=/usr/sbin/reboot \
NOAA_NAVIONICS_FAKE_SUDO_PATH=/usr/bin/sudo \
NOAA_NAVIONICS_FAKE_PYTHON_PATH=/home/pi/bin/python3 \
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  PATH="$dock_fake_ssh_bin:$PATH" \
  scripts/dock_test_pi.sh pi@example.invalid --skip-deploy --allow-dirty --device /dev/serial/by-id/mock-gps >"$dock_output" 2>&1
dock_code=$?
set -e
if [[ "$dock_code" -ne 1 ]]; then
  cat "$dock_output" >&2
  echo "expected dock_test_pi.sh to reject user-writable-looking python3 commands with exit 1" >&2
  exit 1
fi
grep -q 'Remote python3 command is not in a trusted system directory: /home/pi/bin/python3' "$dock_output"

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
scripts/pre_departure_check_pi.sh pi@example.invalid >"$verify_output" 2>&1
pre_departure_code=$?
set -e
if [[ "$pre_departure_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected pre_departure_check_pi.sh to require --device with exit 2" >&2
  exit 1
fi
grep -q -- '--device is required for the pre-departure check' "$verify_output"

set +e
scripts/pre_departure_check_pi.sh pi@example.invalid --device /dev/ttyUSB0 >"$verify_output" 2>&1
pre_departure_code=$?
set -e
if [[ "$pre_departure_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected pre_departure_check_pi.sh to reject volatile GPS device paths with exit 2" >&2
  exit 1
fi
grep -q 'GPS device path is volatile' "$verify_output"

set +e
scripts/pre_trip_prepare_pi.sh pi@example.invalid >"$verify_output" 2>&1
pre_trip_code=$?
set -e
if [[ "$pre_trip_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected pre_trip_prepare_pi.sh to require --device with exit 2" >&2
  exit 1
fi
grep -q -- '--device is required unless --skip-pre-departure is used' "$verify_output"

set +e
scripts/pre_trip_prepare_pi.sh root@example.invalid --device /dev/serial/by-id/mock-gps >"$verify_output" 2>&1
pre_trip_code=$?
set -e
if [[ "$pre_trip_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected pre_trip_prepare_pi.sh to reject root SSH target with exit 2" >&2
  exit 1
fi
grep -q 'Do not run pre-trip preparation as root@' "$verify_output"

set +e
scripts/pre_trip_prepare_pi.sh pi@example.invalid --device /dev/ttyUSB0 >"$verify_output" 2>&1
pre_trip_code=$?
set -e
if [[ "$pre_trip_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected pre_trip_prepare_pi.sh to reject volatile GPS device paths with exit 2" >&2
  exit 1
fi
grep -q 'GPS device path is volatile' "$verify_output"

set +e
scripts/pre_trip_prepare_pi.sh pi@example.invalid --skip-refresh --skip-recovery --skip-pre-departure >"$verify_output" 2>&1
pre_trip_code=$?
set -e
if [[ "$pre_trip_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected pre_trip_prepare_pi.sh to reject running no preparation steps with exit 2" >&2
  exit 1
fi
grep -q 'At least one pre-trip preparation step must run' "$verify_output"

pre_trip_repo="$tmpdir/pre-trip-repo"
pre_trip_log="$tmpdir/pre-trip-helper-calls"
pre_trip_output_dir="$tmpdir/pre-trip-output"
mkdir -p "$pre_trip_repo/scripts"
cp scripts/pre_trip_prepare_pi.sh "$pre_trip_repo/scripts/pre_trip_prepare_pi.sh"
cat >"$pre_trip_repo/scripts/refresh_pi_charts.sh" <<'EOF'
#!/usr/bin/env bash
printf 'refresh|%s\n' "$*" >>"$NOAA_NAVIONICS_FAKE_PRE_TRIP_LOG"
printf 'fake refresh\n'
EOF
cat >"$pre_trip_repo/scripts/export_pi_recovery_bundle.sh" <<'EOF'
#!/usr/bin/env bash
printf 'recovery|%s\n' "$*" >>"$NOAA_NAVIONICS_FAKE_PRE_TRIP_LOG"
mkdir -p "$2/noaa-navionics-pi-recovery-test"
printf 'Pi recovery exports written to: %s/noaa-navionics-pi-recovery-test\n' "$2"
EOF
cat >"$pre_trip_repo/scripts/verify_pi_recovery_exports.sh" <<'EOF'
#!/usr/bin/env bash
printf 'verify-recovery|%s\n' "$*" >>"$NOAA_NAVIONICS_FAKE_PRE_TRIP_LOG"
printf 'fake verify recovery\n'
EOF
cat >"$pre_trip_repo/scripts/pre_departure_check_pi.sh" <<'EOF'
#!/usr/bin/env bash
printf 'pre-departure|%s\n' "$*" >>"$NOAA_NAVIONICS_FAKE_PRE_TRIP_LOG"
printf 'fake pre-departure\n'
EOF
chmod +x "$pre_trip_repo/scripts/"*.sh
mkdir -p "$pre_trip_output_dir"
chmod 0777 "$pre_trip_output_dir"
NOAA_NAVIONICS_FAKE_PRE_TRIP_LOG="$pre_trip_log" \
  "$pre_trip_repo/scripts/pre_trip_prepare_pi.sh" \
  pi@example.invalid \
  --device /dev/serial/by-id/mock-gps \
  --output-dir "$pre_trip_output_dir" \
  --track-days 14 \
  --gps-seconds 17 \
  --retries 6 \
  --retry-delay 9 \
  --force-refresh \
  --allow-dirty \
  --opencpn-restarts 2 \
  --opencpn-restart-delay 3 >"$verify_output" 2>&1
grep -q 'Pre-trip Pi preparation completed for pi@example.invalid' "$verify_output"
grep -Fxq "refresh|pi@example.invalid --retries 6 --retry-delay 9 --status --gps-seconds 17 --force" "$pre_trip_log"
grep -Fxq "recovery|pi@example.invalid $pre_trip_output_dir --track-days 14" "$pre_trip_log"
grep -Fxq "verify-recovery|$pre_trip_output_dir/noaa-navionics-pi-recovery-test" "$pre_trip_log"
grep -Fxq "pre-departure|pi@example.invalid --device /dev/serial/by-id/mock-gps --gps-seconds 17 --allow-dirty --opencpn-restarts 2 --opencpn-restart-delay 3" "$pre_trip_log"
test "$(stat -c '%a' "$pre_trip_output_dir")" = 700
test "$(stat -c '%u' "$pre_trip_output_dir")" = "$(id -u)"

set +e
scripts/post_trip_collect_pi.sh root@example.invalid >"$verify_output" 2>&1
post_trip_code=$?
set -e
if [[ "$post_trip_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected post_trip_collect_pi.sh to reject root SSH target with exit 2" >&2
  exit 1
fi
grep -q 'Do not collect post-trip artifacts as root@' "$verify_output"

set +e
scripts/post_trip_collect_pi.sh pi@example.invalid --track-days nope >"$verify_output" 2>&1
post_trip_code=$?
set -e
if [[ "$post_trip_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected post_trip_collect_pi.sh to reject invalid --track-days with exit 2" >&2
  exit 1
fi
grep -q -- '--track-days must be a non-negative integer' "$verify_output"

set +e
scripts/post_trip_collect_pi.sh pi@example.invalid --shutdown-dry-run --shutdown-confirm >"$verify_output" 2>&1
post_trip_code=$?
set -e
if [[ "$post_trip_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected post_trip_collect_pi.sh to reject conflicting shutdown modes with exit 2" >&2
  exit 1
fi
grep -q -- '--shutdown-dry-run and --shutdown-confirm cannot be used together' "$verify_output"

set +e
scripts/post_trip_collect_pi.sh pi@example.invalid --skip-status --skip-tracks --skip-support >"$verify_output" 2>&1
post_trip_code=$?
set -e
if [[ "$post_trip_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected post_trip_collect_pi.sh to reject running no post-trip steps with exit 2" >&2
  exit 1
fi
grep -q 'At least one post-trip collection or shutdown step must run' "$verify_output"

post_trip_repo="$tmpdir/post-trip-repo"
post_trip_log="$tmpdir/post-trip-helper-calls"
post_trip_output_dir="$tmpdir/post-trip-output"
mkdir -p "$post_trip_repo/scripts"
cp scripts/post_trip_collect_pi.sh "$post_trip_repo/scripts/post_trip_collect_pi.sh"
cat >"$post_trip_repo/scripts/check_pi_status.sh" <<'EOF'
#!/usr/bin/env bash
printf 'status|%s\n' "$*" >>"$NOAA_NAVIONICS_FAKE_POST_TRIP_LOG"
printf '{"ok": true}\n'
exit "${NOAA_NAVIONICS_FAKE_POST_TRIP_STATUS_EXIT:-0}"
EOF
cat >"$post_trip_repo/scripts/export_pi_tracks.sh" <<'EOF'
#!/usr/bin/env bash
printf 'tracks|%s\n' "$*" >>"$NOAA_NAVIONICS_FAKE_POST_TRIP_LOG"
mkdir -p "$2"
touch "$2/noaa-navionics-pi-tracks-fixture.tgz"
printf 'Exported Pi GPX tracks: %s/noaa-navionics-pi-tracks-fixture.tgz\n' "$2"
EOF
cat >"$post_trip_repo/scripts/collect_pi_support_bundle.sh" <<'EOF'
#!/usr/bin/env bash
printf 'support|%s\n' "$*" >>"$NOAA_NAVIONICS_FAKE_POST_TRIP_LOG"
mkdir -p "$2"
touch "$2/noaa-navionics-pi-support-fixture.tgz"
printf 'Collected Pi support bundle: %s/noaa-navionics-pi-support-fixture.tgz\n' "$2"
EOF
cat >"$post_trip_repo/scripts/shutdown_pi_safely.sh" <<'EOF'
#!/usr/bin/env bash
printf 'shutdown|%s\n' "$*" >>"$NOAA_NAVIONICS_FAKE_POST_TRIP_LOG"
printf 'fake shutdown\n'
EOF
chmod +x "$post_trip_repo/scripts/"*.sh
mkdir -p "$post_trip_output_dir"
chmod 0777 "$post_trip_output_dir"
NOAA_NAVIONICS_FAKE_POST_TRIP_LOG="$post_trip_log" \
  "$post_trip_repo/scripts/post_trip_collect_pi.sh" \
  pi@example.invalid "$post_trip_output_dir" \
  --track-days 9 \
  --gps-seconds 15 \
  --shutdown-dry-run >"$verify_output" 2>&1
grep -q 'Post-trip Pi collection completed for pi@example.invalid' "$verify_output"
post_trip_dir="$(sed -n 's/^Post-trip Pi artifacts written to: //p' "$verify_output")"
test -d "$post_trip_dir"
test "$(stat -c '%a' "$post_trip_output_dir")" = 700
test "$(stat -c '%a' "$post_trip_dir")" = 700
test "$(stat -c '%a' "$post_trip_dir/status.json")" = 600
test "$(stat -c '%u' "$post_trip_output_dir")" = "$(id -u)"
test "$(stat -c '%u' "$post_trip_dir")" = "$(id -u)"
test "$(stat -c '%u' "$post_trip_dir/status.json")" = "$(id -u)"
grep -q '"ok": true' "$post_trip_dir/status.json"
grep -Eq '^status\|pi@example.invalid --gps-seconds 15 --json$' "$post_trip_log"
grep -Eq '^tracks\|pi@example.invalid .*/noaa-navionics-pi-post-trip-pi_example_invalid-[0-9]{8}T[0-9]{6}Z --days 9$' "$post_trip_log"
grep -Eq '^support\|pi@example.invalid .*/noaa-navionics-pi-post-trip-pi_example_invalid-[0-9]{8}T[0-9]{6}Z$' "$post_trip_log"
grep -Eq '^shutdown\|pi@example.invalid --dry-run$' "$post_trip_log"

post_trip_failure_log="$tmpdir/post-trip-failure-helper-calls"
post_trip_failure_output_dir="$tmpdir/post-trip-failure-output"
set +e
NOAA_NAVIONICS_FAKE_POST_TRIP_LOG="$post_trip_failure_log" \
  NOAA_NAVIONICS_FAKE_POST_TRIP_STATUS_EXIT=1 \
  "$post_trip_repo/scripts/post_trip_collect_pi.sh" \
  pi@example.invalid "$post_trip_failure_output_dir" \
  --track-days 3 \
  --gps-seconds 12 >"$verify_output" 2>&1
post_trip_code=$?
set -e
if [[ "$post_trip_code" -ne 1 ]]; then
  cat "$verify_output" >&2
  echo "expected post_trip_collect_pi.sh to exit 1 after a failed status snapshot" >&2
  exit 1
fi
grep -q 'Post-trip collection completed, but the status snapshot reported a failure' "$verify_output"
post_trip_failure_dir="$(sed -n 's/^Post-trip Pi artifacts written to: //p' "$verify_output")"
test -d "$post_trip_failure_dir"
test "$(stat -c '%a' "$post_trip_failure_dir/status.json")" = 600
test "$(stat -c '%u' "$post_trip_failure_dir/status.json")" = "$(id -u)"
grep -q '"ok": true' "$post_trip_failure_dir/status.json"
grep -Eq '^status\|pi@example.invalid --gps-seconds 12 --json$' "$post_trip_failure_log"
grep -Eq '^tracks\|pi@example.invalid .*/noaa-navionics-pi-post-trip-pi_example_invalid-[0-9]{8}T[0-9]{6}Z --days 3$' "$post_trip_failure_log"
grep -Eq '^support\|pi@example.invalid .*/noaa-navionics-pi-post-trip-pi_example_invalid-[0-9]{8}T[0-9]{6}Z$' "$post_trip_failure_log"

pre_departure_repo="$tmpdir/pre-departure-repo"
pre_departure_args="$tmpdir/pre-departure-args"
mkdir -p "$pre_departure_repo/scripts"
cp scripts/pre_departure_check_pi.sh "$pre_departure_repo/scripts/pre_departure_check_pi.sh"
cat >"$pre_departure_repo/scripts/verify_pi.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$NOAA_NAVIONICS_FAKE_VERIFY_ARGS"
exit 0
EOF
chmod +x "$pre_departure_repo/scripts/pre_departure_check_pi.sh" "$pre_departure_repo/scripts/verify_pi.sh"
NOAA_NAVIONICS_FAKE_VERIFY_ARGS="$pre_departure_args" \
  "$pre_departure_repo/scripts/pre_departure_check_pi.sh" \
  pi@example.invalid \
  --device /dev/serial/by-id/mock-gps \
  --gps-seconds 17 \
  --opencpn-restarts 2 \
  --opencpn-restart-delay 3 \
  --allow-dirty >"$verify_output" 2>&1
grep -Fxq -- '--require-chartplotter-started' "$pre_departure_args"
grep -Fxq -- '--expected-gps-device' "$pre_departure_args"
grep -Fxq -- '/dev/serial/by-id/mock-gps' "$pre_departure_args"
grep -Fxq -- '--gps-seconds' "$pre_departure_args"
grep -Fxq -- '17' "$pre_departure_args"
grep -Fxq -- '--opencpn-restarts' "$pre_departure_args"
grep -Fxq -- '2' "$pre_departure_args"
grep -Fxq -- '--opencpn-restart-delay' "$pre_departure_args"
grep -Fxq -- '3' "$pre_departure_args"
grep -Fxq -- '--allow-dirty' "$pre_departure_args"
grep -Fxq -- 'pi@example.invalid' "$pre_departure_args"
grep -q 'Pre-departure check passed' "$verify_output"

set +e
scripts/check_pi_status.sh root@example.invalid >"$verify_output" 2>&1
status_snapshot_code=$?
set -e
if [[ "$status_snapshot_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected check_pi_status.sh to reject root SSH target with exit 2" >&2
  exit 1
fi
grep -q 'Do not check NOAA Navionics status as root@' "$verify_output"

set +e
scripts/check_pi_status.sh pi@example.invalid --gps-seconds nope >"$verify_output" 2>&1
status_snapshot_code=$?
set -e
if [[ "$status_snapshot_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected check_pi_status.sh to reject invalid --gps-seconds with exit 2" >&2
  exit 1
fi
grep -q -- '--gps-seconds must be a positive integer' "$verify_output"

status_fake_ssh_bin="$tmpdir/status-fake-ssh-bin"
status_fake_ssh_args="$tmpdir/status-fake-ssh-args"
status_fake_ssh_stdin="$tmpdir/status-fake-ssh-stdin"
mkdir -p "$status_fake_ssh_bin"
cat >"$status_fake_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$NOAA_NAVIONICS_FAKE_SSH_ARGS"
cat >"$NOAA_NAVIONICS_FAKE_SSH_STDIN"
printf 'fake status report\n'
EOF
chmod +x "$status_fake_ssh_bin/ssh"
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  NOAA_NAVIONICS_FAKE_SSH_ARGS="$status_fake_ssh_args" \
  NOAA_NAVIONICS_FAKE_SSH_STDIN="$status_fake_ssh_stdin" \
  PATH="$status_fake_ssh_bin:$PATH" \
  scripts/check_pi_status.sh pi@example.invalid --gps-seconds 12 --json >"$verify_output" 2>&1
grep -q 'fake status report' "$verify_output"
grep -q -- '-o BatchMode=yes' "$status_fake_ssh_args"
grep -q 'NOAA_NAVIONICS_STATUS_GPS_SECONDS=12' "$status_fake_ssh_args"
grep -q 'NOAA_NAVIONICS_STATUS_JSON=1' "$status_fake_ssh_args"
grep -q 'pi@example.invalid' "$status_fake_ssh_args"
grep -q 'expected_resolved="${HOME}/.local/share/noaa-navionics/venv/bin/noaa-navionics"' "$status_fake_ssh_stdin"
grep -q 'check_installed_command_tree' "$status_fake_ssh_stdin"
grep -q 'installed noaa-navionics command target has permissions' "$status_fake_ssh_stdin"
grep -q 'app_exec="$(check_installed_noaa_command)"' "$status_fake_ssh_stdin"
grep -q 'status-report' "$status_fake_ssh_stdin"
grep -q -- '--gps-seconds "$NOAA_NAVIONICS_STATUS_GPS_SECONDS"' "$status_fake_ssh_stdin"
grep -q 'status_args+=(--json)' "$status_fake_ssh_stdin"
grep -q '"$app_exec" "${status_args\[@\]}"' "$status_fake_ssh_stdin"
! grep -q -- '--output' "$status_fake_ssh_stdin"

set +e
scripts/refresh_pi_charts.sh root@example.invalid >"$verify_output" 2>&1
refresh_code=$?
set -e
if [[ "$refresh_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected refresh_pi_charts.sh to reject root SSH target with exit 2" >&2
  exit 1
fi
grep -q 'Do not refresh charts as root@' "$verify_output"

set +e
scripts/refresh_pi_charts.sh pi@example.invalid --retries 0 >"$verify_output" 2>&1
refresh_code=$?
set -e
if [[ "$refresh_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected refresh_pi_charts.sh to reject invalid --retries with exit 2" >&2
  exit 1
fi
grep -q -- '--retries must be a positive integer' "$verify_output"

set +e
scripts/refresh_pi_charts.sh pi@example.invalid --retry-delay soon >"$verify_output" 2>&1
refresh_code=$?
set -e
if [[ "$refresh_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected refresh_pi_charts.sh to reject invalid --retry-delay with exit 2" >&2
  exit 1
fi
grep -q -- '--retry-delay must be a non-negative integer' "$verify_output"

set +e
scripts/refresh_pi_charts.sh pi@example.invalid --status --gps-seconds nope >"$verify_output" 2>&1
refresh_code=$?
set -e
if [[ "$refresh_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected refresh_pi_charts.sh to reject invalid --gps-seconds with exit 2" >&2
  exit 1
fi
grep -q -- '--gps-seconds must be a positive integer' "$verify_output"

refresh_fake_ssh_bin="$tmpdir/refresh-fake-ssh-bin"
refresh_fake_ssh_args="$tmpdir/refresh-fake-ssh-args"
refresh_fake_ssh_stdin="$tmpdir/refresh-fake-ssh-stdin"
mkdir -p "$refresh_fake_ssh_bin"
cat >"$refresh_fake_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$NOAA_NAVIONICS_FAKE_SSH_ARGS"
cat >"$NOAA_NAVIONICS_FAKE_SSH_STDIN"
printf 'fake refresh ssh completed\n'
EOF
chmod +x "$refresh_fake_ssh_bin/ssh"
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  NOAA_NAVIONICS_FAKE_SSH_ARGS="$refresh_fake_ssh_args" \
  NOAA_NAVIONICS_FAKE_SSH_STDIN="$refresh_fake_ssh_stdin" \
  PATH="$refresh_fake_ssh_bin:$PATH" \
  scripts/refresh_pi_charts.sh pi@example.invalid --force --retries 7 --retry-delay 11 --status --gps-seconds 13 >"$verify_output" 2>&1
grep -q 'Pi NOAA chart refresh completed for pi@example.invalid' "$verify_output"
grep -q 'NOAA_NAVIONICS_REFRESH_FORCE=1' "$refresh_fake_ssh_args"
grep -q 'NOAA_NAVIONICS_REFRESH_RETRIES=7' "$refresh_fake_ssh_args"
grep -q 'NOAA_NAVIONICS_REFRESH_RETRY_DELAY=11' "$refresh_fake_ssh_args"
grep -q 'NOAA_NAVIONICS_REFRESH_STATUS=1' "$refresh_fake_ssh_args"
grep -q 'NOAA_NAVIONICS_REFRESH_GPS_SECONDS=13' "$refresh_fake_ssh_args"
grep -q 'pi@example.invalid' "$refresh_fake_ssh_args"
grep -q 'wait-network --host www.charts.noaa.gov --port 443 --seconds 300' "$refresh_fake_ssh_stdin"
grep -q 'sync-charts --config "$config" --retries "$retries" --retry-delay "$retry_delay"' "$refresh_fake_ssh_stdin"
grep -q 'sync_args+=(--force)' "$refresh_fake_ssh_stdin"
grep -q 'Post-refresh status report' "$refresh_fake_ssh_stdin"
grep -q 'status-report --config "$config" --gps-seconds "$gps_seconds"' "$refresh_fake_ssh_stdin"
grep -q 'expected_venv_bin="${HOME}/.local/share/noaa-navionics/venv/bin/noaa-navionics"' "$refresh_fake_ssh_stdin"
grep -q 'check_installed_noaa_command_tree' "$refresh_fake_ssh_stdin"
grep -q 'Installed noaa-navionics command target has permissions' "$refresh_fake_ssh_stdin"
grep -q 'app_exec="$(check_installed_noaa_command)"' "$refresh_fake_ssh_stdin"
grep -q '"$app_exec" wait-network --host www.charts.noaa.gov --port 443 --seconds 300' "$refresh_fake_ssh_stdin"

set +e
scripts/collect_pi_support_bundle.sh root@example.invalid >"$verify_output" 2>&1
support_bundle_code=$?
set -e
if [[ "$support_bundle_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected collect_pi_support_bundle.sh to reject root SSH target with exit 2" >&2
  exit 1
fi
grep -q 'Do not collect support bundles as root@' "$verify_output"

support_symlink="$tmpdir/support-output-link"
ln -s "$tmpdir" "$support_symlink"
set +e
scripts/collect_pi_support_bundle.sh pi@example.invalid "$support_symlink" >"$verify_output" 2>&1
support_bundle_code=$?
set -e
if [[ "$support_bundle_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected collect_pi_support_bundle.sh to reject symlinked output directory with exit 2" >&2
  exit 1
fi
grep -q 'Output directory must not be a symlink' "$verify_output"

support_fake_ssh_bin="$tmpdir/support-fake-ssh-bin"
support_fake_ssh_args="$tmpdir/support-fake-ssh-args"
support_fake_ssh_stdin="$tmpdir/support-fake-ssh-stdin"
support_output_dir="$tmpdir/support-bundles"
mkdir -p "$support_fake_ssh_bin"
cat >"$support_fake_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$NOAA_NAVIONICS_FAKE_SSH_ARGS"
cat >"$NOAA_NAVIONICS_FAKE_SSH_STDIN"
printf 'fake-support-bundle\n'
EOF
chmod +x "$support_fake_ssh_bin/ssh"
mkdir -p "$support_output_dir"
chmod 0777 "$support_output_dir"
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  NOAA_NAVIONICS_FAKE_SSH_ARGS="$support_fake_ssh_args" \
  NOAA_NAVIONICS_FAKE_SSH_STDIN="$support_fake_ssh_stdin" \
  PATH="$support_fake_ssh_bin:$PATH" \
  scripts/collect_pi_support_bundle.sh pi@example.invalid "$support_output_dir" >"$verify_output" 2>&1
grep -q 'Collected Pi support bundle:' "$verify_output"
support_bundle_path="$(sed -n 's/^Collected Pi support bundle: //p' "$verify_output")"
test -s "$support_bundle_path"
test "$(stat -c '%a' "$support_output_dir")" = 700
test "$(stat -c '%a' "$support_bundle_path")" = 600
test "$(stat -c '%u' "$support_output_dir")" = "$(id -u)"
grep -q -- '-o BatchMode=yes' "$support_fake_ssh_args"
grep -q 'pi@example.invalid' "$support_fake_ssh_args"
grep -q 'bash -s' "$support_fake_ssh_args"
grep -q 'support-bundle' "$support_fake_ssh_stdin"
grep -q 'recent-user-journal' "$support_fake_ssh_stdin"
grep -q 'tar -C "$bundle_root" -czf - .' "$support_fake_ssh_stdin"
grep -q 'configured-storage-paths.txt' "$support_fake_ssh_stdin"
grep -q 'noaa-navionics-manifest.json' "$support_fake_ssh_stdin"
grep -q 'configured-chart-storage-tree' "$support_fake_ssh_stdin"
grep -q 'configured-track-storage-tree' "$support_fake_ssh_stdin"

set +e
scripts/export_pi_tracks.sh root@example.invalid >"$verify_output" 2>&1
track_export_code=$?
set -e
if [[ "$track_export_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected export_pi_tracks.sh to reject root SSH target with exit 2" >&2
  exit 1
fi
grep -q 'Do not export tracks as root@' "$verify_output"

track_export_symlink="$tmpdir/track-export-output-link"
ln -s "$tmpdir" "$track_export_symlink"
set +e
scripts/export_pi_tracks.sh pi@example.invalid "$track_export_symlink" >"$verify_output" 2>&1
track_export_code=$?
set -e
if [[ "$track_export_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected export_pi_tracks.sh to reject symlinked output directory with exit 2" >&2
  exit 1
fi
grep -q 'Output directory must not be a symlink' "$verify_output"

set +e
scripts/export_pi_tracks.sh pi@example.invalid --days nope >"$verify_output" 2>&1
track_export_code=$?
set -e
if [[ "$track_export_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected export_pi_tracks.sh to reject invalid --days with exit 2" >&2
  exit 1
fi
grep -q -- '--days must be a non-negative integer' "$verify_output"

track_export_fake_ssh_bin="$tmpdir/track-export-fake-ssh-bin"
track_export_fake_ssh_args="$tmpdir/track-export-fake-ssh-args"
track_export_fake_ssh_stdin="$tmpdir/track-export-fake-ssh-stdin"
track_export_output_dir="$tmpdir/track-exports"
mkdir -p "$track_export_fake_ssh_bin"
cat >"$track_export_fake_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$NOAA_NAVIONICS_FAKE_SSH_ARGS"
cat >"$NOAA_NAVIONICS_FAKE_SSH_STDIN"
printf 'fake-track-export\n'
EOF
chmod +x "$track_export_fake_ssh_bin/ssh"
mkdir -p "$track_export_output_dir"
chmod 0777 "$track_export_output_dir"
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  NOAA_NAVIONICS_FAKE_SSH_ARGS="$track_export_fake_ssh_args" \
  NOAA_NAVIONICS_FAKE_SSH_STDIN="$track_export_fake_ssh_stdin" \
  PATH="$track_export_fake_ssh_bin:$PATH" \
  scripts/export_pi_tracks.sh pi@example.invalid "$track_export_output_dir" --days 7 >"$verify_output" 2>&1
grep -q 'Exported Pi GPX tracks:' "$verify_output"
track_export_path="$(sed -n 's/^Exported Pi GPX tracks: //p' "$verify_output")"
test -s "$track_export_path"
test "$(stat -c '%a' "$track_export_output_dir")" = 700
test "$(stat -c '%a' "$track_export_path")" = 600
test "$(stat -c '%u' "$track_export_output_dir")" = "$(id -u)"
grep -q -- '-o BatchMode=yes' "$track_export_fake_ssh_args"
grep -q 'pi@example.invalid' "$track_export_fake_ssh_args"
grep -q 'NOAA_NAVIONICS_EXPORT_DAYS=7 python3 -s' "$track_export_fake_ssh_args"
grep -q 'tarfile.open' "$track_export_fake_ssh_stdin"
grep -q 'configured GPX track directory' "$track_export_fake_ssh_stdin"
grep -q 'refusing to export symlinked GPX track' "$track_export_fake_ssh_stdin"
grep -q 'tracks/{path.name}' "$track_export_fake_ssh_stdin"
grep -q 'NOAA chart archives and extracted ENC cells are not included' "$track_export_fake_ssh_stdin"

set +e
scripts/export_pi_opencpn_data.sh root@example.invalid >"$verify_output" 2>&1
opencpn_export_code=$?
set -e
if [[ "$opencpn_export_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected export_pi_opencpn_data.sh to reject root SSH target with exit 2" >&2
  exit 1
fi
grep -q 'Do not export OpenCPN data as root@' "$verify_output"

opencpn_export_symlink="$tmpdir/opencpn-export-output-link"
ln -s "$tmpdir" "$opencpn_export_symlink"
set +e
scripts/export_pi_opencpn_data.sh pi@example.invalid "$opencpn_export_symlink" >"$verify_output" 2>&1
opencpn_export_code=$?
set -e
if [[ "$opencpn_export_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected export_pi_opencpn_data.sh to reject symlinked output directory with exit 2" >&2
  exit 1
fi
grep -q 'Output directory must not be a symlink' "$verify_output"

opencpn_export_fake_ssh_bin="$tmpdir/opencpn-export-fake-ssh-bin"
opencpn_export_fake_ssh_args="$tmpdir/opencpn-export-fake-ssh-args"
opencpn_export_fake_ssh_stdin="$tmpdir/opencpn-export-fake-ssh-stdin"
opencpn_export_output_dir="$tmpdir/opencpn-exports"
mkdir -p "$opencpn_export_fake_ssh_bin"
cat >"$opencpn_export_fake_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$NOAA_NAVIONICS_FAKE_SSH_ARGS"
cat >"$NOAA_NAVIONICS_FAKE_SSH_STDIN"
printf 'fake-opencpn-export\n'
EOF
chmod +x "$opencpn_export_fake_ssh_bin/ssh"
mkdir -p "$opencpn_export_output_dir"
chmod 0777 "$opencpn_export_output_dir"
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  NOAA_NAVIONICS_FAKE_SSH_ARGS="$opencpn_export_fake_ssh_args" \
  NOAA_NAVIONICS_FAKE_SSH_STDIN="$opencpn_export_fake_ssh_stdin" \
  PATH="$opencpn_export_fake_ssh_bin:$PATH" \
  scripts/export_pi_opencpn_data.sh pi@example.invalid "$opencpn_export_output_dir" >"$verify_output" 2>&1
grep -q 'Exported Pi OpenCPN user data:' "$verify_output"
opencpn_export_path="$(sed -n 's/^Exported Pi OpenCPN user data: //p' "$verify_output")"
test -s "$opencpn_export_path"
test "$(stat -c '%a' "$opencpn_export_output_dir")" = 700
test "$(stat -c '%a' "$opencpn_export_path")" = 600
test "$(stat -c '%u' "$opencpn_export_output_dir")" = "$(id -u)"
grep -q -- '-o BatchMode=yes' "$opencpn_export_fake_ssh_args"
grep -q 'pi@example.invalid' "$opencpn_export_fake_ssh_args"
grep -q 'python3 -s' "$opencpn_export_fake_ssh_args"
grep -q 'tarfile.open' "$opencpn_export_fake_ssh_stdin"
grep -q 'navobj.xml' "$opencpn_export_fake_ssh_stdin"
grep -q 'refusing to export symlinked OpenCPN file' "$opencpn_export_fake_ssh_stdin"
grep -q 'OpenCPN user config, routes, waypoints' "$opencpn_export_fake_ssh_stdin"
grep -q 'NOAA chart archives and extracted ENC cells are not included' "$opencpn_export_fake_ssh_stdin"

set +e
scripts/export_pi_settings.sh root@example.invalid >"$verify_output" 2>&1
settings_export_code=$?
set -e
if [[ "$settings_export_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected export_pi_settings.sh to reject root SSH target with exit 2" >&2
  exit 1
fi
grep -q 'Do not export settings as root@' "$verify_output"

settings_export_symlink="$tmpdir/settings-export-output-link"
ln -s "$tmpdir" "$settings_export_symlink"
set +e
scripts/export_pi_settings.sh pi@example.invalid "$settings_export_symlink" >"$verify_output" 2>&1
settings_export_code=$?
set -e
if [[ "$settings_export_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected export_pi_settings.sh to reject symlinked output directory with exit 2" >&2
  exit 1
fi
grep -q 'Output directory must not be a symlink' "$verify_output"

settings_export_fake_ssh_bin="$tmpdir/settings-export-fake-ssh-bin"
settings_export_fake_ssh_args="$tmpdir/settings-export-fake-ssh-args"
settings_export_fake_ssh_stdin="$tmpdir/settings-export-fake-ssh-stdin"
settings_export_output_dir="$tmpdir/settings-exports"
mkdir -p "$settings_export_fake_ssh_bin"
cat >"$settings_export_fake_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$NOAA_NAVIONICS_FAKE_SSH_ARGS"
cat >"$NOAA_NAVIONICS_FAKE_SSH_STDIN"
printf 'fake-settings-export\n'
EOF
chmod +x "$settings_export_fake_ssh_bin/ssh"
mkdir -p "$settings_export_output_dir"
chmod 0777 "$settings_export_output_dir"
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  NOAA_NAVIONICS_FAKE_SSH_ARGS="$settings_export_fake_ssh_args" \
  NOAA_NAVIONICS_FAKE_SSH_STDIN="$settings_export_fake_ssh_stdin" \
  PATH="$settings_export_fake_ssh_bin:$PATH" \
  scripts/export_pi_settings.sh pi@example.invalid "$settings_export_output_dir" >"$verify_output" 2>&1
grep -q 'Exported Pi commissioning settings:' "$verify_output"
settings_export_path="$(sed -n 's/^Exported Pi commissioning settings: //p' "$verify_output")"
test -s "$settings_export_path"
test "$(stat -c '%a' "$settings_export_output_dir")" = 700
test "$(stat -c '%a' "$settings_export_path")" = 600
test "$(stat -c '%u' "$settings_export_output_dir")" = "$(id -u)"
grep -q -- '-o BatchMode=yes' "$settings_export_fake_ssh_args"
grep -q 'pi@example.invalid' "$settings_export_fake_ssh_args"
grep -q 'python3 -s' "$settings_export_fake_ssh_args"
grep -q 'tarfile.open' "$settings_export_fake_ssh_stdin"
grep -q 'launcher.env' "$settings_export_fake_ssh_stdin"
grep -q 'source-revision' "$settings_export_fake_ssh_stdin"
grep -q 'noaa-navionics-preflight.service' "$settings_export_fake_ssh_stdin"
grep -q '50-noaa-navionics-autologin.conf' "$settings_export_fake_ssh_stdin"
grep -q 'It does not include logs, GPX tracks, NOAA chart archives, or extracted ENC cells' "$settings_export_fake_ssh_stdin"

set +e
scripts/export_pi_recovery_bundle.sh root@example.invalid >"$verify_output" 2>&1
recovery_export_code=$?
set -e
if [[ "$recovery_export_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected export_pi_recovery_bundle.sh to reject root SSH target with exit 2" >&2
  exit 1
fi
grep -q 'Do not export recovery bundles as root@' "$verify_output"

set +e
scripts/export_pi_recovery_bundle.sh pi@example.invalid --track-days nope >"$verify_output" 2>&1
recovery_export_code=$?
set -e
if [[ "$recovery_export_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected export_pi_recovery_bundle.sh to reject invalid --track-days with exit 2" >&2
  exit 1
fi
grep -q -- '--track-days must be a non-negative integer' "$verify_output"

recovery_export_symlink="$tmpdir/recovery-export-output-link"
ln -s "$tmpdir" "$recovery_export_symlink"
set +e
scripts/export_pi_recovery_bundle.sh pi@example.invalid "$recovery_export_symlink" >"$verify_output" 2>&1
recovery_export_code=$?
set -e
if [[ "$recovery_export_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected export_pi_recovery_bundle.sh to reject symlinked output directory with exit 2" >&2
  exit 1
fi
grep -q 'Output directory must not be a symlink' "$verify_output"

recovery_repo="$tmpdir/recovery-repo"
recovery_log="$tmpdir/recovery-helper-calls"
recovery_output_dir="$tmpdir/recovery-output"
mkdir -p "$recovery_repo/scripts"
cp scripts/export_pi_recovery_bundle.sh "$recovery_repo/scripts/export_pi_recovery_bundle.sh"
for helper in export_pi_settings.sh export_pi_opencpn_data.sh export_pi_tracks.sh collect_pi_support_bundle.sh; do
  cat >"$recovery_repo/scripts/$helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")|$*" >>"$NOAA_NAVIONICS_FAKE_RECOVERY_LOG"
printf 'fake %s\n' "$(basename "$0")"
EOF
  chmod +x "$recovery_repo/scripts/$helper"
done
mkdir -p "$recovery_output_dir"
chmod 0777 "$recovery_output_dir"
NOAA_NAVIONICS_FAKE_RECOVERY_LOG="$recovery_log" \
  "$recovery_repo/scripts/export_pi_recovery_bundle.sh" \
  pi@example.invalid "$recovery_output_dir" --track-days 14 >"$verify_output" 2>&1
grep -q 'Pi recovery exports written to:' "$verify_output"
grep -q 'Exporting commissioning settings' "$verify_output"
grep -q 'Exporting OpenCPN user data' "$verify_output"
grep -q 'Exporting GPX tracks' "$verify_output"
grep -q 'Collecting diagnostic support bundle' "$verify_output"
recovery_export_dir="$(sed -n 's/^Pi recovery exports written to: //p' "$verify_output")"
test -d "$recovery_export_dir"
test "$(stat -c '%a' "$recovery_output_dir")" = 700
test "$(stat -c '%a' "$recovery_export_dir")" = 700
test "$(stat -c '%u' "$recovery_output_dir")" = "$(id -u)"
test "$(stat -c '%u' "$recovery_export_dir")" = "$(id -u)"
grep -Eq '^export_pi_settings.sh\|pi@example.invalid .*/noaa-navionics-pi-recovery-pi_example_invalid-[0-9]{8}T[0-9]{6}Z$' "$recovery_log"
grep -Eq '^export_pi_opencpn_data.sh\|pi@example.invalid .*/noaa-navionics-pi-recovery-pi_example_invalid-[0-9]{8}T[0-9]{6}Z$' "$recovery_log"
grep -Eq '^export_pi_tracks.sh\|pi@example.invalid .*/noaa-navionics-pi-recovery-pi_example_invalid-[0-9]{8}T[0-9]{6}Z --days 14$' "$recovery_log"
grep -Eq '^collect_pi_support_bundle.sh\|pi@example.invalid .*/noaa-navionics-pi-recovery-pi_example_invalid-[0-9]{8}T[0-9]{6}Z$' "$recovery_log"

recovery_verify_dir="$tmpdir/recovery-verify"
mkdir -p "$recovery_verify_dir"
python3 - "$recovery_verify_dir" <<'PY'
from pathlib import Path
import io
import json
import sys
import tarfile
import time


def add_text(archive, name, text):
    data = text.encode("utf-8")
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o600
    info.mtime = int(time.time())
    archive.addfile(info, io.BytesIO(data))


def build_archive(directory, name, manifest, extra_member):
    path = directory / name
    with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        add_text(archive, "README.txt", "recovery fixture\n")
        if manifest is not None:
            add_text(archive, "manifest.json", json.dumps(manifest) + "\n")
        add_text(archive, extra_member, "fixture\n")
    path.chmod(0o600)


root = Path(sys.argv[1])
build_archive(
    root,
    "noaa-navionics-pi-settings-pi_example_invalid-20260101T000000Z.tgz",
    {"file_count": 1},
    "noaa-navionics/config.ini",
)
build_archive(
    root,
    "noaa-navionics-pi-opencpn-pi_example_invalid-20260101T000000Z.tgz",
    {"file_count": 1},
    "opencpn/navobj.xml",
)
build_archive(
    root,
    "noaa-navionics-pi-tracks-pi_example_invalid-20260101T000000Z.tgz",
    {"track_count": 1},
    "tracks/track.gpx",
)
with tarfile.open(
    root / "noaa-navionics-pi-support-pi_example_invalid-20260101T000000Z.tgz",
    "w:gz",
    format=tarfile.PAX_FORMAT,
) as archive:
    add_text(archive, "./README.txt", "support fixture\n")
    add_text(archive, "./commands/date-utc.txt", "2026-01-01\n")
(root / "noaa-navionics-pi-support-pi_example_invalid-20260101T000000Z.tgz").chmod(0o600)
PY
chmod 0700 "$recovery_verify_dir"

scripts/verify_pi_recovery_exports.sh "$recovery_verify_dir" >"$verify_output" 2>&1
grep -q 'Verified Pi recovery exports:' "$verify_output"
grep -q 'commissioning settings:' "$verify_output"
grep -q 'OpenCPN user data:' "$verify_output"
grep -q 'GPX tracks:' "$verify_output"
grep -q 'diagnostic support bundle:' "$verify_output"

chmod 0755 "$recovery_verify_dir"
set +e
scripts/verify_pi_recovery_exports.sh "$recovery_verify_dir" >"$verify_output" 2>&1
recovery_verify_code=$?
set -e
chmod 0700 "$recovery_verify_dir"
if [[ "$recovery_verify_code" -ne 1 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi_recovery_exports.sh to reject public recovery directory with exit 1" >&2
  exit 1
fi
grep -q 'recovery directory has permissions 0755, expected private 0700' "$verify_output"

rm -f "$recovery_verify_dir"/noaa-navionics-pi-support-*.tgz
set +e
scripts/verify_pi_recovery_exports.sh "$recovery_verify_dir" >"$verify_output" 2>&1
recovery_verify_code=$?
set -e
if [[ "$recovery_verify_code" -ne 1 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi_recovery_exports.sh to reject missing support archive with exit 1" >&2
  exit 1
fi
grep -q 'missing diagnostic support bundle archive' "$verify_output"

recovery_verify_link="$tmpdir/recovery-verify-link"
ln -s "$recovery_verify_dir" "$recovery_verify_link"
set +e
scripts/verify_pi_recovery_exports.sh "$recovery_verify_link" >"$verify_output" 2>&1
recovery_verify_code=$?
set -e
if [[ "$recovery_verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi_recovery_exports.sh to reject symlinked recovery directory with exit 2" >&2
  exit 1
fi
grep -q 'Recovery directory must not be a symlink' "$verify_output"

recovery_restore_dir="$tmpdir/recovery-restore"
recovery_restore_parent_dir="$tmpdir/recovery-restore-parent-dir"
restore_home="$tmpdir/restore-home"
mkdir -p "$recovery_restore_dir" "$recovery_restore_parent_dir" "$restore_home"
python3 - "$recovery_restore_dir" "$recovery_restore_parent_dir" <<'PY'
from pathlib import Path
import io
import json
import sys
import tarfile
import time


def add_text(archive, name, text):
    data = text.encode("utf-8")
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o600
    info.mtime = int(time.time())
    archive.addfile(info, io.BytesIO(data))


def build_archive(directory, name, manifest, members):
    with tarfile.open(directory / name, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        add_text(archive, "README.txt", "restore fixture\n")
        if manifest is not None:
            add_text(archive, "manifest.json", json.dumps(manifest) + "\n")
        for member_name, text in members.items():
            add_text(archive, member_name, text)


def build_restore_fixture(root, config):
    build_archive(
        root,
        "noaa-navionics-pi-settings-pi_example_invalid-20260101T000000Z.tgz",
        {"file_count": 2},
        {
            "noaa-navionics/config.ini": config,
            "noaa-navionics/launcher.env": "NOAA_NAVIONICS_GPS_SECONDS=60\n",
        },
    )
    build_archive(
        root,
        "noaa-navionics-pi-opencpn-pi_example_invalid-20260101T000000Z.tgz",
        {"file_count": 2},
        {
            "opencpn/navobj.xml": "<navobj />\n",
            "opencpn/layers/route.gpx": "<gpx />\n",
        },
    )
    build_archive(
        root,
        "noaa-navionics-pi-tracks-pi_example_invalid-20260101T000000Z.tgz",
        {"track_count": 1},
        {"tracks/underway.gpx": "<gpx><trk /></gpx>\n"},
    )
    build_archive(
        root,
        "noaa-navionics-pi-support-pi_example_invalid-20260101T000000Z.tgz",
        None,
        {"commands/date-utc.txt": "2026-01-01\n"},
    )


config = """[charts]
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
output = ~/tracks-store
retention_days = 90
"""
bad_config = config.replace("output = ~/tracks-store", "output = ~/../../etc/noaa-navionics-restore")
build_restore_fixture(Path(sys.argv[1]), config)
build_restore_fixture(Path(sys.argv[2]), bad_config)
PY

set +e
HOME="$restore_home" scripts/restore_pi_recovery_user_data.sh "$recovery_restore_parent_dir" >"$verify_output" 2>&1
recovery_restore_code=$?
set -e
if [[ "$recovery_restore_code" -ne 1 ]]; then
  cat "$verify_output" >&2
  echo "expected restore_pi_recovery_user_data.sh to reject tracking output parent traversal with exit 1" >&2
  exit 1
fi
grep -q 'restored tracking.output must not contain parent-directory components' "$verify_output"

HOME="$restore_home" scripts/restore_pi_recovery_user_data.sh "$recovery_restore_dir" >"$verify_output" 2>&1
grep -q 'Dry run only. Re-run with --apply to write files.' "$verify_output"
grep -q 'would restore settings:' "$verify_output"
test ! -e "$restore_home/.config/noaa-navionics/config.ini"

HOME="$restore_home" scripts/restore_pi_recovery_user_data.sh "$recovery_restore_dir" --apply >"$verify_output" 2>&1
grep -q 'Restored 5 recovery user data file(s).' "$verify_output"
grep -q 'Re-run provisioning, then scripts/verify_pi.sh or scripts/dock_test_pi.sh' "$verify_output"
grep -q 'device = /dev/serial/by-id/mock-gps' "$restore_home/.config/noaa-navionics/config.ini"
grep -q 'NOAA_NAVIONICS_GPS_SECONDS=60' "$restore_home/.config/noaa-navionics/launcher.env"
grep -q '<navobj />' "$restore_home/.opencpn/navobj.xml"
grep -q '<gpx />' "$restore_home/.opencpn/layers/route.gpx"
grep -q '<gpx><trk /></gpx>' "$restore_home/tracks-store/tracks/underway.gpx"
RESTORE_HOME="$restore_home" python3 - <<'PY'
from pathlib import Path
import os
import stat

home = Path(os.environ["RESTORE_HOME"])
for path in (
    home / ".config" / "noaa-navionics",
    home / ".opencpn",
    home / ".opencpn" / "layers",
    home / "tracks-store" / "tracks",
):
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o700:
        raise SystemExit(f"{path} has mode {mode:04o}, expected 0700")
PY

set +e
HOME="$restore_home" scripts/restore_pi_recovery_user_data.sh "$recovery_restore_dir" --apply >"$verify_output" 2>&1
recovery_restore_code=$?
set -e
if [[ "$recovery_restore_code" -ne 1 ]]; then
  cat "$verify_output" >&2
  echo "expected restore_pi_recovery_user_data.sh to reject existing targets without --overwrite with exit 1" >&2
  exit 1
fi
grep -q 'restore target already exists; use --overwrite' "$verify_output"

HOME="$restore_home" scripts/restore_pi_recovery_user_data.sh "$recovery_restore_dir" --apply --overwrite >"$verify_output" 2>&1
grep -q 'Backed up replaced files under:' "$verify_output"
test -f "$(find "$restore_home/.cache/noaa-navionics/recovery-restore-backups" -path '*/.config/noaa-navionics/config.ini' -type f | head -n 1)"
RESTORE_HOME="$restore_home" python3 - <<'PY'
from pathlib import Path
import os
import stat

home = Path(os.environ["RESTORE_HOME"])
backup_root = home / ".cache" / "noaa-navionics" / "recovery-restore-backups"
for path in (backup_root, *backup_root.rglob("*")):
    mode = stat.S_IMODE(path.stat().st_mode)
    if path.is_dir() and mode != 0o700:
        raise SystemExit(f"{path} has mode {mode:04o}, expected 0700")
    if path.is_file() and mode != 0o600:
        raise SystemExit(f"{path} has mode {mode:04o}, expected 0600")
PY

set +e
scripts/shutdown_pi_safely.sh pi@example.invalid >"$verify_output" 2>&1
shutdown_code=$?
set -e
if [[ "$shutdown_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected shutdown_pi_safely.sh to require --confirm or --dry-run with exit 2" >&2
  exit 1
fi
grep -q -- '--confirm is required for a real Pi shutdown' "$verify_output"

set +e
scripts/shutdown_pi_safely.sh root@example.invalid --dry-run >"$verify_output" 2>&1
shutdown_code=$?
set -e
if [[ "$shutdown_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected shutdown_pi_safely.sh to reject root SSH target with exit 2" >&2
  exit 1
fi
grep -q 'Do not shut down root@' "$verify_output"

set +e
scripts/shutdown_pi_safely.sh pi@example.invalid --confirm --dry-run >"$verify_output" 2>&1
shutdown_code=$?
set -e
if [[ "$shutdown_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected shutdown_pi_safely.sh to reject conflicting shutdown modes with exit 2" >&2
  exit 1
fi
grep -q -- '--confirm and --dry-run cannot be used together' "$verify_output"

shutdown_fake_ssh_bin="$tmpdir/shutdown-fake-ssh-bin"
shutdown_fake_ssh_args="$tmpdir/shutdown-fake-ssh-args"
shutdown_fake_ssh_stdin="$tmpdir/shutdown-fake-ssh-stdin"
mkdir -p "$shutdown_fake_ssh_bin"
cat >"$shutdown_fake_ssh_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$NOAA_NAVIONICS_FAKE_SSH_ARGS"
cat >"$NOAA_NAVIONICS_FAKE_SSH_STDIN"
printf 'fake shutdown ssh completed\n'
EOF
chmod +x "$shutdown_fake_ssh_bin/ssh"
NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH=1 \
  NOAA_NAVIONICS_FAKE_SSH_ARGS="$shutdown_fake_ssh_args" \
  NOAA_NAVIONICS_FAKE_SSH_STDIN="$shutdown_fake_ssh_stdin" \
  PATH="$shutdown_fake_ssh_bin:$PATH" \
  scripts/shutdown_pi_safely.sh pi@example.invalid --dry-run >"$verify_output" 2>&1
grep -q 'Pi shutdown dry run passed for pi@example.invalid' "$verify_output"
grep -q 'NOAA_NAVIONICS_SHUTDOWN_DRY_RUN=1' "$shutdown_fake_ssh_args"
grep -q 'pi@example.invalid' "$shutdown_fake_ssh_args"
grep -q 'require_remote_command sync' "$shutdown_fake_ssh_stdin"
grep -q 'require_remote_command sudo' "$shutdown_fake_ssh_stdin"
grep -q 'require_remote_command systemctl' "$shutdown_fake_ssh_stdin"
grep -q 'check_remote_directory_chain "$resolved_path"' "$shutdown_fake_ssh_stdin"
grep -q 'check_remote_owner_and_mode directory "$directory"' "$shutdown_fake_ssh_stdin"
grep -Fq '"$sudo_cmd" -n "$systemctl_cmd" poweroff' "$shutdown_fake_ssh_stdin"

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

set +e
scripts/verify_pi.sh --expected-boot-id 0123456789abcdef0123456789abcdef pi@example.invalid >"$verify_output" 2>&1
verify_code=$?
set -e
if [[ "$verify_code" -ne 2 ]]; then
  cat "$verify_output" >&2
  echo "expected verify_pi.sh to reject boot IDs without Linux boot_id hyphens with exit 2" >&2
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
grep -Fq "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && export PATH && NOAA_NAVIONICS_EXPECTED_REVISION=${verify_clean_revision}" "$verify_fake_ssh_args"
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
grep -q 'NOAA_NAVIONICS_WARNING_SECONDS=8' "$provision_output"
grep -q 'NOAA_NAVIONICS_READINESS_ATTEMPTS=3' "$provision_output"
grep -q 'NOAA_NAVIONICS_READINESS_RETRY_DELAY=10' "$provision_output"
grep -q 'NOAA_NAVIONICS_START_ON_FAILED_READINESS=no' "$provision_output"
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
grep -q 'require_loaded_user_unit_property noaa-navionics.service MemoryDenyWriteExecute yes' "$provision_output"
grep -q 'require_loaded_user_unit_property noaa-navionics-track.service RestrictRealtime yes' "$provision_output"
grep -q 'require_loaded_user_unit_property noaa-navionics-preflight.service MemoryDenyWriteExecute yes' "$provision_output"
for unit in noaa-navionics.service noaa-navionics-track.service noaa-navionics-preflight.service; do
  for loaded_property in NoNewPrivileges PrivateTmp ProtectSystem LockPersonality RestrictSUIDSGID MemoryDenyWriteExecute RestrictRealtime UMask; do
    case "$loaded_property" in
      ProtectSystem)
        expected_value=full
        ;;
      UMask)
        expected_value=0077
        ;;
      *)
        expected_value=yes
        ;;
    esac
    grep -q "require_loaded_user_unit_property ${unit} ${loaded_property} ${expected_value}" "$provision_output"
  done
done
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
linger_index = text.index("loginctl enable-linger")
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
chmod 0700 "$launcher_public_cache_parent_home/.config/noaa-navionics"
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

launcher_public_cache_dir_home="$tmpdir/launcher-public-cache-dir-home"
launcher_public_cache_dir_output="$tmpdir/launcher-public-cache-dir.out"
mkdir -p "$launcher_public_cache_dir_home/.local/bin" "$launcher_public_cache_dir_home/.config/noaa-navionics" "$launcher_public_cache_dir_home/.cache/noaa-navionics"
chmod 0700 "$launcher_public_cache_dir_home/.config/noaa-navionics" "$launcher_public_cache_dir_home/.cache"
printf 'NOAA_NAVIONICS_GPS_SECONDS=60\n' >"$launcher_public_cache_dir_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_public_cache_dir_home/.config/noaa-navionics/launcher.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_public_cache_dir_home/.local/bin/noaa-navionics"
chmod +x "$launcher_public_cache_dir_home/.local/bin/noaa-navionics"
chmod 0755 "$launcher_public_cache_dir_home/.cache/noaa-navionics"
HOME="$launcher_public_cache_dir_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >"$launcher_public_cache_dir_output" 2>&1
test "$(stat -c '%a' "$launcher_public_cache_dir_home/.cache/noaa-navionics")" = 700
grep -q 'Tightening NOAA Navionics cache directory permissions from 755 to 700' "$launcher_public_cache_dir_output"

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
chmod 0700 "$launcher_home/.config/noaa-navionics"
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
chmod 0700 "$launcher_missing_env_home/.config/noaa-navionics"
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
chmod 0700 "$launcher_symlink_env_home/.config/noaa-navionics"
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

launcher_swapped_env_home="$tmpdir/launcher-swapped-env-home"
launcher_swapped_env_target="$tmpdir/launcher-swapped-env-target"
mkdir -p "$launcher_swapped_env_home/.local/bin" "$launcher_swapped_env_home/.cache/noaa-navionics" "$launcher_swapped_env_home/.config/noaa-navionics"
chmod 0700 "$launcher_swapped_env_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=60\n' >"$launcher_swapped_env_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_swapped_env_home/.config/noaa-navionics/launcher.env"
printf 'NOAA_NAVIONICS_GPS_SECONDS=60\nNOAA_NAVIONICS_START_ON_FAILED_READINESS=yes\n' >"$launcher_swapped_env_target"
cat >"$tmpdir/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/.config/noaa-navionics/launcher.env"* ]]; then
  /usr/bin/stat "$@"
  code=$?
  if [[ "$code" -eq 0 ]]; then
    rm -f "$HOME/.config/noaa-navionics/launcher.env"
    ln -s "$HOME/.config/noaa-navionics/swapped-launcher.env" "$HOME/.config/noaa-navionics/launcher.env"
  fi
  exit "$code"
fi
exec /usr/bin/stat "$@"
EOF
ln -s "$launcher_swapped_env_target" "$launcher_swapped_env_home/.config/noaa-navionics/swapped-launcher.env"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_swapped_env_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nprintf "opencpn launched\\n" >"$HOME/.cache/noaa-navionics/opencpn-started"\nexit 0\n' >"$tmpdir/opencpn"
chmod +x "$launcher_swapped_env_home/.local/bin/noaa-navionics" "$tmpdir/stat" "$tmpdir/opencpn"
set +e
HOME="$launcher_swapped_env_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_swapped_env_code=$?
set -e
if [[ "$launcher_swapped_env_code" -eq 0 ]]; then
  cat "$launcher_swapped_env_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject launcher environment replaced with a symlink after validation" >&2
  exit 1
fi
test -L "$launcher_swapped_env_home/.config/noaa-navionics/launcher.env"
test ! -e "$launcher_swapped_env_home/.cache/noaa-navionics/opencpn-started"
grep -q 'NOAA Navionics launcher environment is a symlink' "$launcher_swapped_env_home/.cache/noaa-navionics/chartplotter.log"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_swapped_env_home/.cache/noaa-navionics/chartplotter.log"
rm -f "$tmpdir/stat"

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
chmod 0700 "$launcher_public_env_home/.config/noaa-navionics"
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

launcher_public_env_dir_home="$tmpdir/launcher-public-env-dir-home"
mkdir -p "$launcher_public_env_dir_home/.local/bin" "$launcher_public_env_dir_home/.cache/noaa-navionics" "$launcher_public_env_dir_home/.config/noaa-navionics"
printf 'NOAA_NAVIONICS_GPS_SECONDS=60\n' >"$launcher_public_env_dir_home/.config/noaa-navionics/launcher.env"
chmod 0600 "$launcher_public_env_dir_home/.config/noaa-navionics/launcher.env"
chmod 0770 "$launcher_public_env_dir_home/.config/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_public_env_dir_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nprintf "opencpn launched\\n" >"$HOME/.cache/noaa-navionics/opencpn-started"\nexit 0\n' >"$tmpdir/opencpn"
chmod +x "$launcher_public_env_dir_home/.local/bin/noaa-navionics" "$tmpdir/opencpn"
set +e
HOME="$launcher_public_env_dir_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_public_env_dir_code=$?
set -e
chmod 0700 "$launcher_public_env_dir_home/.config/noaa-navionics"
if [[ "$launcher_public_env_dir_code" -eq 0 ]]; then
  cat "$launcher_public_env_dir_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a public launcher environment directory" >&2
  exit 1
fi
grep -q 'NOAA Navionics launcher environment directory has permissions 0770, expected private 0700' "$launcher_public_env_dir_home/.cache/noaa-navionics/chartplotter.log"
test ! -e "$launcher_public_env_dir_home/.cache/noaa-navionics/opencpn-started"
! grep -q 'Launching OpenCPN with ENC processing.' "$launcher_public_env_dir_home/.cache/noaa-navionics/chartplotter.log"

launcher_unknown_env_home="$tmpdir/launcher-unknown-env-home"
mkdir -p "$launcher_unknown_env_home/.local/bin" "$launcher_unknown_env_home/.cache/noaa-navionics" "$launcher_unknown_env_home/.config/noaa-navionics"
chmod 0700 "$launcher_unknown_env_home/.config/noaa-navionics"
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
chmod 0700 "$launcher_malformed_env_home/.config/noaa-navionics"
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
chmod 0700 "$launcher_missing_gps_seconds_home/.config/noaa-navionics"
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
chmod 0700 "$launcher_invalid_timing_home/.config/noaa-navionics"
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
chmod 0700 "$launcher_preflight_fail_home/.config/noaa-navionics"
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
chmod 0700 "$launcher_preflight_override_home/.config/noaa-navionics"
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
chmod 0700 "$launcher_retry_home/.config/noaa-navionics"
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
chmod 0700 "$launcher_opencpn_restart_home/.config/noaa-navionics"
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
chmod 0700 "$launcher_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
write_test_launcher_env "$launcher_lock_home"
printf '%s\n' "$$" >"$launcher_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
chmod 0600 "$launcher_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
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

launcher_public_lock_home="$tmpdir/launcher-public-lock-home"
mkdir -p "$launcher_public_lock_home/.local/bin" "$launcher_public_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
write_test_launcher_env "$launcher_public_lock_home"
printf '%s\n' "$$" >"$launcher_public_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
chmod 0770 "$launcher_public_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_public_lock_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\nprintf "opencpn launched\\n" >"$HOME/.cache/noaa-navionics/opencpn-started"\nexit 0\n' >"$tmpdir/opencpn"
chmod +x "$launcher_public_lock_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
set +e
HOME="$launcher_public_lock_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_public_lock_code=$?
set -e
if [[ "$launcher_public_lock_code" -eq 0 ]]; then
  cat "$launcher_public_lock_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a public launcher lock directory" >&2
  exit 1
fi
test -d "$launcher_public_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
test ! -e "$launcher_public_lock_home/.cache/noaa-navionics/opencpn-started"
grep -q 'chartplotter launcher lock path has permissions 0770, expected private 0700; leaving it in place' "$launcher_public_lock_home/.cache/noaa-navionics/chartplotter.log"

launcher_public_lock_file_home="$tmpdir/launcher-public-lock-file-home"
mkdir -p "$launcher_public_lock_file_home/.local/bin" "$launcher_public_lock_file_home/.cache/noaa-navionics/chartplotter.launch.lock"
chmod 0700 "$launcher_public_lock_file_home/.cache/noaa-navionics/chartplotter.launch.lock"
write_test_launcher_env "$launcher_public_lock_file_home"
printf '%s\n' "$$" >"$launcher_public_lock_file_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
chmod 0644 "$launcher_public_lock_file_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
printf '#!/usr/bin/env bash\nexit 0\n' >"$launcher_public_lock_file_home/.local/bin/noaa-navionics"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmpdir/pgrep"
printf '#!/usr/bin/env bash\nprintf "opencpn launched\\n" >"$HOME/.cache/noaa-navionics/opencpn-started"\nexit 0\n' >"$tmpdir/opencpn"
chmod +x "$launcher_public_lock_file_home/.local/bin/noaa-navionics" "$tmpdir/pgrep" "$tmpdir/opencpn"
set +e
HOME="$launcher_public_lock_file_home" PATH="$tmpdir:$PATH" scripts/start_chartplotter.sh >/dev/null
launcher_public_lock_file_code=$?
set -e
if [[ "$launcher_public_lock_file_code" -eq 0 ]]; then
  cat "$launcher_public_lock_file_home/.cache/noaa-navionics/chartplotter.log" >&2
  echo "expected chartplotter launcher to reject a public launcher lock pid file" >&2
  exit 1
fi
test -d "$launcher_public_lock_file_home/.cache/noaa-navionics/chartplotter.launch.lock"
test ! -e "$launcher_public_lock_file_home/.cache/noaa-navionics/opencpn-started"
grep -q 'chartplotter launcher lock pid has permissions 0644, expected private 0600; leaving it in place' "$launcher_public_lock_file_home/.cache/noaa-navionics/chartplotter.log"

launcher_dirty_lock_home="$tmpdir/launcher-dirty-lock-home"
mkdir -p "$launcher_dirty_lock_home/.local/bin" "$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
chmod 0700 "$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
write_test_launcher_env "$launcher_dirty_lock_home"
printf '%s\n' "$$" >"$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
chmod 0600 "$launcher_dirty_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
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
chmod 0700 "$launcher_symlink_child_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
printf '%s\n' "$$" >"$launcher_symlink_child_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
chmod 0600 "$launcher_symlink_child_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
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
chmod 0700 "$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
write_test_launcher_env "$launcher_old_boot_lock_home"
bash -c 'while :; do sleep 1; done' start_chartplotter.sh &
old_boot_launcher_pid=$!
printf '%s\n' "$old_boot_launcher_pid" >"$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
printf 'previous-boot\n' >"$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/boot_id"
chmod 0600 "$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid" "$launcher_old_boot_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/boot_id"
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
chmod 0700 "$launcher_active_lock_home/.cache/noaa-navionics/chartplotter.launch.lock"
bash -c 'while :; do sleep 1; done' start_chartplotter.sh &
active_launcher_pid=$!
printf '%s\n' "$active_launcher_pid" >"$launcher_active_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
chmod 0600 "$launcher_active_lock_home/.cache/noaa-navionics/chartplotter.launch.lock/pid"
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
