#!/usr/bin/env bash
set -euo pipefail
umask 077

config="${HOME}/.config/noaa-navionics/config.ini"
launcher_env="${HOME}/.config/noaa-navionics/launcher.env"
status_report="${HOME}/.cache/noaa-navionics/status.json"
log_file="${HOME}/.cache/noaa-navionics/chartplotter.log"
launcher_lock_dir="${HOME}/.cache/noaa-navionics/chartplotter.launch.lock"
cache_dir="$(dirname "$status_report")"
max_log_bytes=$((1024 * 1024))
bin="${HOME}/.local/bin/noaa-navionics"
gps_seconds=60
warning_seconds=8
readiness_attempts=3
readiness_retry_delay=10
start_on_failed_readiness=0
opencpn_restarts=3
opencpn_restart_delay=5
opencpn_shutdown_grace_seconds=10
lock_acquired=0
opencpn_bin=""
opencpn_child_pid=""
python3_bin=""
trusted_system_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
device_tree_model_path="/proc/device-tree/model"

read_raspberry_pi_model_text() {
  local python_candidate
  for python_candidate in /usr/bin/python3 /bin/python3; do
    [[ -x "$python_candidate" ]] || continue
    "$python_candidate" - "$device_tree_model_path" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
try:
    before = os.stat(path, follow_symlinks=False)
except OSError:
    raise SystemExit(1)
if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
    raise SystemExit(1)
try:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
except OSError:
    raise SystemExit(1)
try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened) or not stat.S_ISREG(opened.st_mode):
        raise SystemExit(1)
    text = os.read(fd, 4096).decode("ascii", "ignore").strip("\x00\r\n ")
finally:
    os.close(fd)
if not text:
    raise SystemExit(1)
sys.stdout.write(text)
PY
    return "$?"
  done
  return 1
}

is_raspberry_pi() {
  local model
  model="$(read_raspberry_pi_model_text 2>/dev/null)" || return 1
  [[ "$model" == *"Raspberry Pi"* ]]
}

if is_raspberry_pi; then
  PATH="$trusted_system_path"
  export PATH
fi

utc_log_timestamp() {
  local stamp
  TZ=UTC0 printf -v stamp '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  printf '%s\n' "$stamp"
}

reexec_without_ambient_launcher_settings() {
  local key
  local removed=0
  local env_args=()
  while IFS='=' read -r key _; do
    case "$key" in
      NOAA_NAVIONICS_*)
        env_args+=("-u" "$key")
        removed=$((removed + 1))
        ;;
    esac
  done < <(env)
  if [[ "$removed" -gt 0 ]]; then
    exec env "${env_args[@]}" "$0" "$@"
  fi
}

first_symlink_ancestor() {
  local path="$1"
  local current

  current="$path"
  while [[ -n "$current" && "$current" != "." ]]; do
    if [[ -L "$current" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    if [[ "$current" == "/" ]]; then
      return 1
    fi
    current="$(dirname "$current")"
  done
  return 1
}

path_in_trusted_system_dir() {
  case "$1" in
    /usr/local/sbin/*|/usr/local/bin/*|/usr/sbin/*|/usr/bin/*|/sbin/*|/bin/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_python_command_candidate() {
  local candidate="$1"
  local resolved_candidate
  local stat_output
  local owner_uid
  local mode_text
  local mode
  local parent_dir
  local parent_stat
  local parent_owner_uid
  local parent_mode_text
  local parent_mode
  local symlink_component

  if [[ -z "$candidate" ]]; then
    echo "Python command python3 was not found on PATH" >&2
    return 1
  fi
  case "$candidate" in
    /*)
      ;;
    *)
      echo "Python command path is not absolute: $candidate" >&2
      return 1
      ;;
  esac
  if is_raspberry_pi && ! path_in_trusted_system_dir "$candidate"; then
    echo "Python command is not in a trusted system directory: $candidate" >&2
    return 1
  fi
  parent_dir="$(dirname "$candidate")"
  if symlink_component="$(first_symlink_ancestor "$parent_dir")"; then
    echo "Python command path contains a symlink: $symlink_component" >&2
    return 1
  fi
  if ! resolved_candidate="$(readlink -f -- "$candidate" 2>/dev/null)" || [[ -z "$resolved_candidate" ]]; then
    echo "Could not resolve Python command: $candidate" >&2
    return 1
  fi
  if is_raspberry_pi && ! path_in_trusted_system_dir "$resolved_candidate"; then
    echo "Python command resolves outside trusted system directories: $candidate -> $resolved_candidate" >&2
    return 1
  fi
  if [[ ! -f "$resolved_candidate" ]]; then
    echo "Python command is not a regular file after resolution: $candidate -> $resolved_candidate" >&2
    return 1
  fi
  if [[ ! -x "$resolved_candidate" ]]; then
    echo "Python command is not executable: $resolved_candidate" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$resolved_candidate" 2>/dev/null)" || {
    echo "Could not inspect Python command: $resolved_candidate" >&2
    return 1
  }
  owner_uid="${stat_output%% *}"
  mode_text="${stat_output#* }"
  mode=$((8#$mode_text))
  if (( mode & 022 )); then
    echo "Python command has permissions ${mode_text}, expected no group/other write bits: $resolved_candidate" >&2
    return 1
  fi
  parent_dir="$(dirname "$resolved_candidate")"
  if symlink_component="$(first_symlink_ancestor "$parent_dir")"; then
    echo "Resolved Python command path contains a symlink: $symlink_component" >&2
    return 1
  fi
  parent_stat="$(stat -c '%u %a' "$parent_dir" 2>/dev/null)" || {
    echo "Could not inspect Python command directory: $parent_dir" >&2
    return 1
  }
  parent_owner_uid="${parent_stat%% *}"
  parent_mode_text="${parent_stat#* }"
  parent_mode=$((8#$parent_mode_text))
  if (( parent_mode & 022 )); then
    echo "Python command directory has permissions ${parent_mode_text}, expected no group/other write bits: $parent_dir" >&2
    return 1
  fi
  if is_raspberry_pi && [[ "$parent_owner_uid" != "0" ]]; then
    echo "Python command directory is owned by uid ${parent_owner_uid}, expected root on Raspberry Pi: $parent_dir" >&2
    return 1
  fi
  if [[ "$parent_owner_uid" != "0" && "$parent_owner_uid" != "$(id -u)" ]]; then
    echo "Python command directory is owned by uid ${parent_owner_uid}, expected root or $(id -u): $parent_dir" >&2
    return 1
  fi
  if is_raspberry_pi && [[ "$owner_uid" != "0" ]]; then
    echo "Python command is owned by uid ${owner_uid}, expected root on Raspberry Pi: $resolved_candidate" >&2
    return 1
  fi
  if [[ "$owner_uid" != "0" && "$owner_uid" != "$(id -u)" ]]; then
    echo "Python command is owned by uid ${owner_uid}, expected root or $(id -u): $resolved_candidate" >&2
    return 1
  fi
  printf '%s\n' "$resolved_candidate"
  return 0
}

python3_command_path() {
  local path_candidate

  path_candidate="$(command -v python3 2>/dev/null || true)"
  validate_python_command_candidate "$path_candidate" || return 1
}

sync_paths() {
  "$python3_bin" - "$@" <<'PY'
from pathlib import Path
import os
import stat
import sys

synced_dirs = set()
for arg in sys.argv[1:]:
    path = Path(arg).expanduser()
    try:
        initial = path.lstat()
    except OSError:
        synced_dirs.add(path.parent)
        continue
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if stat.S_ISLNK(initial.st_mode):
        synced_dirs.add(path.parent)
        continue
    if stat.S_ISDIR(initial.st_mode):
        try:
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow
            fd = os.open(path, flags)
        except OSError:
            synced_dirs.add(path.parent)
            continue
        try:
            opened = os.fstat(fd)
            if stat.S_ISDIR(opened.st_mode):
                os.fsync(fd)
        except OSError:
            pass
        finally:
            os.close(fd)
        synced_dirs.add(path)
        synced_dirs.add(path.parent)
        continue
    try:
        fd = os.open(path, os.O_RDONLY | nofollow)
    except OSError:
        synced_dirs.add(path.parent)
        continue
    try:
        opened = os.fstat(fd)
        if stat.S_ISREG(opened.st_mode):
            os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)
    synced_dirs.add(path.parent)
for directory in synced_dirs:
    try:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(directory, flags)
    except OSError:
        continue
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

prepare_private_cache_dir() {
  local cache_parent
  local cache_parent_stat
  local cache_parent_uid
  local cache_parent_mode_text
  local cache_parent_mode
  local cache_dir_stat
  local cache_dir_uid
  local cache_dir_mode_text
  local cache_dir_mode
  local symlink_component
  cache_parent="$(dirname "$cache_dir")"
  if [[ -L "$cache_parent" ]]; then
    echo "NOAA Navionics cache parent directory is a symlink: $cache_parent" >&2
    exit 1
  fi
  if symlink_component="$(first_symlink_ancestor "$(dirname "$cache_parent")")"; then
    echo "NOAA Navionics cache path contains a symlink: $symlink_component" >&2
    exit 1
  fi
  if [[ -L "$cache_dir" ]]; then
    echo "NOAA Navionics cache directory is a symlink: $cache_dir" >&2
    exit 1
  fi
  mkdir -p "$cache_parent"
  cache_parent_stat="$(stat -c '%u %a' "$cache_parent" 2>/dev/null || true)"
  if [[ -z "$cache_parent_stat" ]]; then
    echo "Could not inspect NOAA Navionics cache parent directory: $cache_parent" >&2
    exit 1
  fi
  cache_parent_uid="${cache_parent_stat%% *}"
  cache_parent_mode_text="${cache_parent_stat#* }"
  if [[ "$cache_parent_uid" != "$(id -u)" ]]; then
    echo "NOAA Navionics cache parent directory is owned by uid ${cache_parent_uid}, expected $(id -u): $cache_parent" >&2
    exit 1
  fi
  cache_parent_mode=$((8#$cache_parent_mode_text))
  if (( cache_parent_mode & 077 )); then
    echo "Tightening NOAA Navionics cache parent directory permissions from ${cache_parent_mode_text} to 700: $cache_parent"
    chmod 0700 "$cache_parent"
  fi
  if [[ -L "$cache_parent" ]]; then
    echo "NOAA Navionics cache parent directory became a symlink after permission tightening: $cache_parent" >&2
    exit 1
  fi
  cache_parent_stat="$(stat -c '%u %a' "$cache_parent" 2>/dev/null || true)"
  if [[ -z "$cache_parent_stat" ]]; then
    echo "Could not reinspect NOAA Navionics cache parent directory: $cache_parent" >&2
    exit 1
  fi
  cache_parent_uid="${cache_parent_stat%% *}"
  cache_parent_mode_text="${cache_parent_stat#* }"
  if [[ "$cache_parent_uid" != "$(id -u)" ]]; then
    echo "NOAA Navionics cache parent directory is owned by uid ${cache_parent_uid}, expected $(id -u): $cache_parent" >&2
    exit 1
  fi
  cache_parent_mode=$((8#$cache_parent_mode_text))
  if (( cache_parent_mode & 077 )); then
    printf 'NOAA Navionics cache parent directory has permissions %04o, expected private 0700: %s\n' "$cache_parent_mode" "$cache_parent" >&2
    exit 1
  fi
  mkdir -p "$cache_dir"
  if [[ -L "$cache_dir" ]]; then
    echo "NOAA Navionics cache directory became a symlink after creation: $cache_dir" >&2
    exit 1
  fi
  cache_dir_stat="$(stat -c '%u %a' "$cache_dir" 2>/dev/null || true)"
  if [[ -z "$cache_dir_stat" ]]; then
    echo "Could not inspect NOAA Navionics cache directory: $cache_dir" >&2
    exit 1
  fi
  cache_dir_uid="${cache_dir_stat%% *}"
  cache_dir_mode_text="${cache_dir_stat#* }"
  if [[ "$cache_dir_uid" != "$(id -u)" ]]; then
    echo "NOAA Navionics cache directory is owned by uid ${cache_dir_uid}, expected $(id -u): $cache_dir" >&2
    exit 1
  fi
  cache_dir_mode=$((8#$cache_dir_mode_text))
  if (( cache_dir_mode & 077 )); then
    echo "Tightening NOAA Navionics cache directory permissions from ${cache_dir_mode_text} to 700: $cache_dir"
  fi
  chmod 0700 "$cache_dir"
  if [[ -L "$cache_dir" ]]; then
    echo "NOAA Navionics cache directory became a symlink after permission tightening: $cache_dir" >&2
    exit 1
  fi
  cache_dir_stat="$(stat -c '%u %a' "$cache_dir" 2>/dev/null || true)"
  if [[ -z "$cache_dir_stat" ]]; then
    echo "Could not reinspect NOAA Navionics cache directory: $cache_dir" >&2
    exit 1
  fi
  cache_dir_uid="${cache_dir_stat%% *}"
  cache_dir_mode_text="${cache_dir_stat#* }"
  if [[ "$cache_dir_uid" != "$(id -u)" ]]; then
    echo "NOAA Navionics cache directory is owned by uid ${cache_dir_uid}, expected $(id -u): $cache_dir" >&2
    exit 1
  fi
  cache_dir_mode=$((8#$cache_dir_mode_text))
  if (( cache_dir_mode & 077 )); then
    printf 'NOAA Navionics cache directory has permissions %04o, expected private 0700: %s\n' "$cache_dir_mode" "$cache_dir" >&2
    exit 1
  fi
  sync_paths "$cache_parent" "$cache_dir" || true
}

prepare_private_log_file() {
  "$python3_bin" - "$log_file" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1]).expanduser()
nofollow = getattr(os, "O_NOFOLLOW", 0)
flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | nofollow
try:
    fd = os.open(path, flags, 0o600)
except OSError as exc:
    if path.is_symlink():
        raise SystemExit(f"NOAA Navionics launcher log is a symlink: {path}") from exc
    raise SystemExit(f"Could not open NOAA Navionics launcher log: {path}: {exc}") from exc
try:
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        raise SystemExit(f"NOAA Navionics launcher log is not a regular file: {path}")
    if opened.st_uid != os.getuid():
        raise SystemExit(
            f"NOAA Navionics launcher log is owned by uid {opened.st_uid}, expected {os.getuid()}: {path}"
        )
    mode = opened.st_mode & 0o777
    if mode != 0o600:
        os.fchmod(fd, 0o600)
    os.fsync(fd)
finally:
    os.close(fd)
try:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow
    fd = os.open(path.parent, flags)
except OSError:
    fd = None
if fd is not None:
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

rotate_launcher_log_if_needed() {
  "$python3_bin" - "$log_file" "$max_log_bytes" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1]).expanduser()
max_bytes = int(sys.argv[2])
rotated = path.with_name(path.name + ".1")
expected_uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)

try:
    initial = path.lstat()
except FileNotFoundError:
    raise SystemExit(0)
except OSError as exc:
    raise SystemExit(f"Could not inspect NOAA Navionics launcher log: {path}: {exc}") from exc
if stat.S_ISLNK(initial.st_mode):
    raise SystemExit(f"NOAA Navionics launcher log is a symlink: {path}")
if not stat.S_ISREG(initial.st_mode):
    raise SystemExit(f"NOAA Navionics launcher log is not a regular file: {path}")
if initial.st_uid != expected_uid:
    raise SystemExit(
        f"NOAA Navionics launcher log is owned by uid {initial.st_uid}, expected {expected_uid}: {path}"
    )
if initial.st_size <= max_bytes:
    raise SystemExit(0)

source_fd = os.open(path, os.O_RDONLY | nofollow)
rotated_fd = None
parent_fd = None
try:
    opened = os.fstat(source_fd)
    if not os.path.samestat(initial, opened):
        raise SystemExit(f"NOAA Navionics launcher log changed while being opened: {path}")
    if not stat.S_ISREG(opened.st_mode):
        raise SystemExit(f"NOAA Navionics launcher log is not a regular file after open: {path}")
    if opened.st_uid != expected_uid:
        raise SystemExit(
            f"NOAA Navionics launcher log is owned by uid {opened.st_uid}, expected {expected_uid}: {path}"
        )

    try:
        rotated_initial = rotated.lstat()
    except FileNotFoundError:
        rotated_initial = None
    if rotated_initial is not None:
        if stat.S_ISLNK(rotated_initial.st_mode):
            raise SystemExit(f"NOAA Navionics rotated launcher log is a symlink: {rotated}")
        if not stat.S_ISREG(rotated_initial.st_mode):
            raise SystemExit(f"NOAA Navionics rotated launcher log is not a regular file: {rotated}")
        if rotated_initial.st_uid != expected_uid:
            raise SystemExit(
                f"NOAA Navionics rotated launcher log is owned by uid {rotated_initial.st_uid}, "
                f"expected {expected_uid}: {rotated}"
            )

    os.replace(path, rotated)
    rotated_fd = os.open(rotated, os.O_RDONLY | nofollow)
    rotated_opened = os.fstat(rotated_fd)
    if not os.path.samestat(opened, rotated_opened):
        raise SystemExit(f"NOAA Navionics launcher log changed while being rotated: {path}")
    os.fchmod(rotated_fd, 0o600)
    os.fsync(rotated_fd)
    parent_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow
    parent_fd = os.open(path.parent, parent_flags)
    os.fsync(parent_fd)
finally:
    if parent_fd is not None:
        os.close(parent_fd)
    if rotated_fd is not None:
        os.close(rotated_fd)
    os.close(source_fd)
PY
}

append_private_log_stream() {
  "$python3_bin" -c '
import os
import stat
import sys

path = sys.argv[1]
expected_uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)
flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | nofollow


def write_all(fd, data):
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written == 0:
            raise OSError("short write")
        view = view[written:]


try:
    log_fd = os.open(path, flags, 0o600)
except OSError as exc:
    raise SystemExit(f"Could not open NOAA Navionics launcher log stream safely: {path}: {exc}") from exc
try:
    opened = os.fstat(log_fd)
    if not stat.S_ISREG(opened.st_mode):
        raise SystemExit(f"NOAA Navionics launcher log stream is not a regular file: {path}")
    if opened.st_uid != expected_uid:
        raise SystemExit(
            f"NOAA Navionics launcher log stream is owned by uid {opened.st_uid}, "
            f"expected {expected_uid}: {path}"
        )
    mode = opened.st_mode & 0o777
    if mode != 0o600:
        os.fchmod(log_fd, 0o600)
    while True:
        chunk = os.read(0, 65536)
        if not chunk:
            break
        write_all(1, chunk)
        write_all(log_fd, chunk)
    os.fsync(log_fd)
finally:
    os.close(log_fd)
' "$log_file"
}

finish_private_log_stream() {
  local status=$?
  exec 1>&- 2>&-
  if [[ -n "${launcher_log_stream_pid:-}" ]]; then
    wait "$launcher_log_stream_pid" || true
  fi
  exit "$status"
}

cleanup_private_log_pipe() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  "$python3_bin" - "$path" <<'PY'
from __future__ import annotations

from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1]).expanduser()
nofollow = getattr(os, "O_NOFOLLOW", 0)
opath = getattr(os, "O_PATH", None)
if opath is None:
    print(f"Python runtime cannot safely inspect launcher log pipe for cleanup; leaving it in place: {path}", file=sys.stderr)
    raise SystemExit(0)

try:
    parent_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
except FileNotFoundError:
    raise SystemExit(0)
except OSError as exc:
    print(f"Could not open launcher log pipe directory for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

try:
    parent_stat = os.fstat(parent_fd)
    parent_mode = stat.S_IMODE(parent_stat.st_mode)
    if not stat.S_ISDIR(parent_stat.st_mode) or parent_stat.st_uid != os.getuid() or parent_mode & 0o077:
        print(f"Launcher log pipe directory is not trusted for cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    try:
        before = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    if not stat.S_ISFIFO(before.st_mode) or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600:
        print(f"Launcher log pipe is not a trusted private FIFO; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    try:
        fd = os.open(path.name, opath | nofollow, dir_fd=parent_fd)
    except FileNotFoundError:
        raise SystemExit(0)
    try:
        opened = os.fstat(fd)
    finally:
        os.close(fd)
    if not os.path.samestat(before, opened):
        print(f"Launcher log pipe changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    try:
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    if not os.path.samestat(before, current):
        print(f"Launcher log pipe changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    os.unlink(path.name, dir_fd=parent_fd)
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
PY
}

start_private_log_stream() {
  local log_pipe="${cache_dir}/.chartplotter-log-${$}.pipe"
  if [[ -e "$log_pipe" || -L "$log_pipe" ]]; then
    echo "NOAA Navionics launcher log pipe already exists: $log_pipe" >&2
    exit 1
  fi
  mkfifo -m 0600 "$log_pipe"
  append_private_log_stream <"$log_pipe" &
  launcher_log_stream_pid=$!
  exec >"$log_pipe" 2>&1
  cleanup_private_log_pipe "$log_pipe" || true
  trap finish_private_log_stream EXIT
}

read_trusted_launcher_env() {
  "$python3_bin" - "$launcher_env" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1]).expanduser()
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags)
except OSError as exc:
    if path.is_symlink():
        raise SystemExit(f"NOAA Navionics launcher environment is a symlink: {path}")
    raise SystemExit(f"Could not open NOAA Navionics launcher environment: {path}: {exc}") from exc

try:
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        raise SystemExit(f"NOAA Navionics launcher environment is not a regular file: {path}")
    if opened.st_uid != os.getuid():
        raise SystemExit(
            f"NOAA Navionics launcher environment is owned by uid {opened.st_uid}, expected {os.getuid()}: {path}"
        )
    mode = opened.st_mode & 0o777
    if mode != 0o600:
        raise SystemExit(
            f"NOAA Navionics launcher environment has permissions {mode:04o}, expected private 0600: {path}"
        )
    with os.fdopen(fd, encoding="utf-8") as handle:
        fd = -1
        print(handle.read(), end="")
finally:
    if fd >= 0:
        os.close(fd)
PY
}

load_launcher_settings() {
  local key
  local launcher_env_text
  local raw_line
  local trimmed
  local value
  local start_on_failed_text
  local seen_gps_seconds=0
  if [[ -r "$launcher_env" ]]; then
    if ! launcher_env_text="$(read_trusted_launcher_env)"; then
      return 1
    fi
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
      trimmed="${raw_line#"${raw_line%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      if [[ -z "$trimmed" || "$trimmed" == \#* ]]; then
        continue
      fi
      if [[ "$trimmed" != *=* ]]; then
        echo "Malformed launcher environment line in $launcher_env: $raw_line" >&2
        return 1
      fi
      key="${trimmed%%=*}"
      value="${trimmed#*=}"
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      case "$key" in
        NOAA_NAVIONICS_GPS_SECONDS)
          gps_seconds="$value"
          seen_gps_seconds=1
          ;;
        NOAA_NAVIONICS_WARNING_SECONDS)
          warning_seconds="$value"
          ;;
        NOAA_NAVIONICS_READINESS_ATTEMPTS)
          readiness_attempts="$value"
          ;;
        NOAA_NAVIONICS_READINESS_RETRY_DELAY)
          readiness_retry_delay="$value"
          ;;
        NOAA_NAVIONICS_START_ON_FAILED_READINESS)
          start_on_failed_text="$value"
          ;;
        NOAA_NAVIONICS_OPENCPN_RESTARTS)
          opencpn_restarts="$value"
          ;;
        NOAA_NAVIONICS_OPENCPN_RESTART_DELAY)
          opencpn_restart_delay="$value"
          ;;
        *)
          echo "Unknown launcher environment key in $launcher_env: $key" >&2
          return 1
          ;;
      esac
    done <<<"$launcher_env_text"
  fi
  start_on_failed_text="${start_on_failed_text:-no}"
  if [[ "$seen_gps_seconds" -ne 1 ]]; then
    echo "Missing NOAA_NAVIONICS_GPS_SECONDS in $launcher_env; refusing chartplotter startup." >&2
    return 1
  fi
  if [[ ! "$gps_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid NOAA_NAVIONICS_GPS_SECONDS=${gps_seconds}; expected positive integer." >&2
    return 1
  fi
  if [[ ! "$warning_seconds" =~ ^[0-9]+$ ]]; then
    echo "Invalid NOAA_NAVIONICS_WARNING_SECONDS=${warning_seconds}; expected non-negative integer." >&2
    return 1
  fi
  if [[ ! "$readiness_attempts" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid NOAA_NAVIONICS_READINESS_ATTEMPTS=${readiness_attempts}; expected positive integer." >&2
    return 1
  fi
  if [[ ! "$readiness_retry_delay" =~ ^[0-9]+$ ]]; then
    echo "Invalid NOAA_NAVIONICS_READINESS_RETRY_DELAY=${readiness_retry_delay}; expected non-negative integer." >&2
    return 1
  fi
  if [[ ! "$opencpn_restarts" =~ ^[0-9]+$ ]]; then
    echo "Invalid NOAA_NAVIONICS_OPENCPN_RESTARTS=${opencpn_restarts}; expected non-negative integer." >&2
    return 1
  fi
  if [[ ! "$opencpn_restart_delay" =~ ^[0-9]+$ ]]; then
    echo "Invalid NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=${opencpn_restart_delay}; expected non-negative integer." >&2
    return 1
  fi
  case "${start_on_failed_text,,}" in
    1|yes|true|on)
      start_on_failed_readiness=1
      ;;
    0|no|false|off)
      start_on_failed_readiness=0
      ;;
    *)
      echo "Invalid NOAA_NAVIONICS_START_ON_FAILED_READINESS=${start_on_failed_text}; expected yes/no." >&2
      return 1
      ;;
  esac
}

validate_launcher_env_path() {
  local launcher_env_dir
  local launcher_env_dir_stat
  local launcher_env_dir_uid
  local launcher_env_dir_mode_text
  local launcher_env_dir_mode
  local env_stat
  local env_uid
  local env_mode
  local symlink_component
  launcher_env_dir="$(dirname "$launcher_env")"
  if [[ -L "$launcher_env_dir" ]]; then
    echo "NOAA Navionics launcher environment directory is a symlink: $launcher_env_dir" >&2
    exit 1
  fi
  if symlink_component="$(first_symlink_ancestor "$(dirname "$launcher_env_dir")")"; then
    echo "NOAA Navionics launcher environment path contains a symlink: $symlink_component" >&2
    exit 1
  fi
  if [[ ! -d "$launcher_env_dir" ]]; then
    echo "NOAA Navionics launcher environment directory is not a directory: $launcher_env_dir" >&2
    exit 1
  fi
  launcher_env_dir_stat="$(stat -c '%u %a' "$launcher_env_dir" 2>/dev/null || true)"
  if [[ -z "$launcher_env_dir_stat" ]]; then
    echo "Could not inspect NOAA Navionics launcher environment directory: $launcher_env_dir" >&2
    exit 1
  fi
  read -r launcher_env_dir_uid launcher_env_dir_mode_text <<<"$launcher_env_dir_stat"
  if [[ "$launcher_env_dir_uid" != "$(id -u)" ]]; then
    echo "NOAA Navionics launcher environment directory is owned by uid ${launcher_env_dir_uid}, expected $(id -u): $launcher_env_dir" >&2
    exit 1
  fi
  launcher_env_dir_mode=$((8#$launcher_env_dir_mode_text))
  if (( launcher_env_dir_mode & 077 )); then
    printf 'NOAA Navionics launcher environment directory has permissions %04o, expected private 0700: %s\n' "$launcher_env_dir_mode" "$launcher_env_dir" >&2
    exit 1
  fi
  if [[ ! -e "$launcher_env" ]]; then
    echo "NOAA Navionics launcher environment is missing: $launcher_env" >&2
    exit 1
  fi
  if [[ -L "$launcher_env" ]]; then
    echo "NOAA Navionics launcher environment is a symlink: $launcher_env" >&2
    exit 1
  fi
  if [[ ! -f "$launcher_env" ]]; then
    echo "NOAA Navionics launcher environment is not a regular file: $launcher_env" >&2
    exit 1
  fi
  env_stat="$(stat -c '%u %a' "$launcher_env" 2>/dev/null || true)"
  if [[ -z "$env_stat" ]]; then
    echo "Could not inspect NOAA Navionics launcher environment: $launcher_env" >&2
    exit 1
  fi
  read -r env_uid env_mode <<<"$env_stat"
  if [[ "$env_uid" != "$(id -u)" ]]; then
    echo "NOAA Navionics launcher environment is owned by uid ${env_uid}, expected $(id -u): $launcher_env" >&2
    exit 1
  fi
  if [[ "$env_mode" != "600" && "$env_mode" != "0600" ]]; then
    echo "NOAA Navionics launcher environment has permissions ${env_mode}, expected private 0600: $launcher_env" >&2
    exit 1
  fi
}

validate_display_power_command_candidate() {
  local candidate="$1"
  local stat_output
  local owner_uid
  local mode_text
  local mode
  local parent_dir
  local parent_stat
  local parent_owner_uid
  local parent_mode_text
  local parent_mode
  local symlink_component

  if [[ -z "$candidate" ]]; then
    echo "Display power command xset was not found on PATH" >&2
    return 1
  fi
  case "$candidate" in
    /*)
      ;;
    *)
      echo "Display power command path is not absolute: $candidate" >&2
      return 1
      ;;
  esac
  if [[ -L "$candidate" ]]; then
    echo "Display power command is a symlink: $candidate" >&2
    return 1
  fi
  parent_dir="$(dirname "$candidate")"
  if symlink_component="$(first_symlink_ancestor "$parent_dir")"; then
    echo "Display power command path contains a symlink: $symlink_component" >&2
    return 1
  fi
  if [[ ! -f "$candidate" ]]; then
    echo "Display power command is not a regular file: $candidate" >&2
    return 1
  fi
  if [[ ! -x "$candidate" ]]; then
    echo "Display power command is not executable: $candidate" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$candidate" 2>/dev/null)" || {
    echo "Could not inspect display power command: $candidate" >&2
    return 1
  }
  owner_uid="${stat_output%% *}"
  mode_text="${stat_output#* }"
  mode=$((8#$mode_text))
  if (( mode & 022 )); then
    echo "Display power command has permissions ${mode_text}, expected no group/other write bits: $candidate" >&2
    return 1
  fi
  parent_stat="$(stat -c '%u %a' "$parent_dir" 2>/dev/null)" || {
    echo "Could not inspect display power command directory: $parent_dir" >&2
    return 1
  }
  parent_owner_uid="${parent_stat%% *}"
  parent_mode_text="${parent_stat#* }"
  parent_mode=$((8#$parent_mode_text))
  if (( parent_mode & 022 )); then
    echo "Display power command directory has permissions ${parent_mode_text}, expected no group/other write bits: $parent_dir" >&2
    return 1
  fi
  if is_raspberry_pi && [[ "$parent_owner_uid" != "0" ]]; then
    echo "Display power command directory is owned by uid ${parent_owner_uid}, expected root on Raspberry Pi: $parent_dir" >&2
    return 1
  fi
  if [[ "$parent_owner_uid" != "0" && "$parent_owner_uid" != "$(id -u)" ]]; then
    echo "Display power command directory is owned by uid ${parent_owner_uid}, expected root or $(id -u): $parent_dir" >&2
    return 1
  fi
  if is_raspberry_pi && [[ "$owner_uid" != "0" ]]; then
    echo "Display power command is owned by uid ${owner_uid}, expected root on Raspberry Pi: $candidate" >&2
    return 1
  fi
  if [[ "$owner_uid" != "0" && "$owner_uid" != "$(id -u)" ]]; then
    echo "Display power command is owned by uid ${owner_uid}, expected root or $(id -u): $candidate" >&2
    return 1
  fi
  return 0
}

display_power_command_path() {
  local path_candidate

  path_candidate="$(command -v xset 2>/dev/null || true)"
  validate_display_power_command_candidate "$path_candidate" || return 1
  printf '%s\n' "$path_candidate"
}

validate_process_lookup_command_candidate() {
  local candidate="$1"
  local stat_output
  local owner_uid
  local mode_text
  local mode
  local parent_dir
  local parent_stat
  local parent_owner_uid
  local parent_mode_text
  local parent_mode
  local symlink_component

  if [[ -z "$candidate" ]]; then
    echo "Process lookup command pgrep was not found on PATH" >&2
    return 1
  fi
  case "$candidate" in
    /*)
      ;;
    *)
      echo "Process lookup command path is not absolute: $candidate" >&2
      return 1
      ;;
  esac
  if [[ -L "$candidate" ]]; then
    echo "Process lookup command is a symlink: $candidate" >&2
    return 1
  fi
  parent_dir="$(dirname "$candidate")"
  if symlink_component="$(first_symlink_ancestor "$parent_dir")"; then
    echo "Process lookup command path contains a symlink: $symlink_component" >&2
    return 1
  fi
  if [[ ! -f "$candidate" ]]; then
    echo "Process lookup command is not a regular file: $candidate" >&2
    return 1
  fi
  if [[ ! -x "$candidate" ]]; then
    echo "Process lookup command is not executable: $candidate" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$candidate" 2>/dev/null)" || {
    echo "Could not inspect process lookup command: $candidate" >&2
    return 1
  }
  owner_uid="${stat_output%% *}"
  mode_text="${stat_output#* }"
  mode=$((8#$mode_text))
  if (( mode & 022 )); then
    echo "Process lookup command has permissions ${mode_text}, expected no group/other write bits: $candidate" >&2
    return 1
  fi
  parent_stat="$(stat -c '%u %a' "$parent_dir" 2>/dev/null)" || {
    echo "Could not inspect process lookup command directory: $parent_dir" >&2
    return 1
  }
  parent_owner_uid="${parent_stat%% *}"
  parent_mode_text="${parent_stat#* }"
  parent_mode=$((8#$parent_mode_text))
  if (( parent_mode & 022 )); then
    echo "Process lookup command directory has permissions ${parent_mode_text}, expected no group/other write bits: $parent_dir" >&2
    return 1
  fi
  if is_raspberry_pi && [[ "$parent_owner_uid" != "0" ]]; then
    echo "Process lookup command directory is owned by uid ${parent_owner_uid}, expected root on Raspberry Pi: $parent_dir" >&2
    return 1
  fi
  if [[ "$parent_owner_uid" != "0" && "$parent_owner_uid" != "$(id -u)" ]]; then
    echo "Process lookup command directory is owned by uid ${parent_owner_uid}, expected root or $(id -u): $parent_dir" >&2
    return 1
  fi
  if is_raspberry_pi && [[ "$owner_uid" != "0" ]]; then
    echo "Process lookup command is owned by uid ${owner_uid}, expected root on Raspberry Pi: $candidate" >&2
    return 1
  fi
  if [[ "$owner_uid" != "0" && "$owner_uid" != "$(id -u)" ]]; then
    echo "Process lookup command is owned by uid ${owner_uid}, expected root or $(id -u): $candidate" >&2
    return 1
  fi
  return 0
}

process_lookup_command_path() {
  local path_candidate

  path_candidate="$(command -v pgrep 2>/dev/null || true)"
  validate_process_lookup_command_candidate "$path_candidate" || return 1
  printf '%s\n' "$path_candidate"
}

keep_display_awake() {
  local xset_bin=""
  if [[ -n "${DISPLAY:-}" ]] && xset_bin="$(display_power_command_path)"; then
    local failures=0
    "$xset_bin" s off >/dev/null 2>&1 || failures=$((failures + 1))
    "$xset_bin" s noblank >/dev/null 2>&1 || failures=$((failures + 1))
    "$xset_bin" -dpms >/dev/null 2>&1 || failures=$((failures + 1))
    if [[ "$failures" -eq 0 ]]; then
      echo "Requested display sleep and blanking disabled."
    else
      echo "Display session found, but ${failures} xset command(s) failed; leaving some display power settings unchanged." >&2
    fi
  elif [[ -n "${DISPLAY:-}" ]]; then
    echo "Display session found, but xset is unavailable or not trusted; leaving display power settings unchanged." >&2
  fi
  return 0
}

opencpn_running() {
  local pid
  local pgrep_bin
  if pgrep_bin="$(process_lookup_command_path)"; then
    while IFS= read -r pid; do
      if opencpn_process_active "$pid"; then
        return 0
      fi
    done < <("$pgrep_bin" -u "$(id -u)" -x opencpn 2>/dev/null || true)
  fi
  return 1
}

opencpn_process_active() {
  local pid="$1"
  "$python3_bin" - "$pid" <<'PY'
import sys

pid = sys.argv[1]
if not pid.isdigit():
    raise SystemExit(1)
try:
    stat_text = open(f"/proc/{pid}/stat", encoding="ascii", errors="ignore").read()
except OSError:
    raise SystemExit(1)
try:
    tail = stat_text.rsplit(") ", 1)[1]
except IndexError:
    raise SystemExit(1)
fields = tail.split()
if not fields:
    raise SystemExit(1)
raise SystemExit(0 if fields[0] != "Z" else 1)
PY
}

process_looks_like_launcher() {
  local pid="$1"
  "$python3_bin" - "$pid" <<'PY'
from pathlib import Path
import sys

pid = sys.argv[1]
if not pid.isdigit():
    raise SystemExit(1)
try:
    data = Path(f"/proc/{pid}/cmdline").read_bytes()
except OSError:
    raise SystemExit(1)
for raw_arg in data.split(b"\0"):
    if not raw_arg:
        continue
    arg_name = Path(raw_arg.decode("utf-8", "surrogateescape")).name
    if arg_name in {"noaa-navionics-start-chartplotter", "start_chartplotter.sh"}:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

current_boot_id() {
  "$python3_bin" - <<'PY' 2>/dev/null || true
from pathlib import Path
import os
import re
import stat
import sys

path = Path("/proc/sys/kernel/random/boot_id")
boot_id_re = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

try:
    before = os.stat(path, follow_symlinks=False)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise OSError("boot ID path is not a trusted regular file")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
except OSError:
    raise SystemExit(0)

try:
    opened = os.fstat(fd)
    if before.st_dev != opened.st_dev or before.st_ino != opened.st_ino:
        raise SystemExit(0)
    if not stat.S_ISREG(opened.st_mode):
        raise SystemExit(0)
    lines = os.read(fd, 4096).decode("ascii", "ignore").splitlines()
finally:
    os.close(fd)

if not lines:
    raise SystemExit(0)
value = lines[0].strip()
if boot_id_re.fullmatch(value):
    sys.stdout.write(value)
PY
}

validate_launcher_lock_path() {
  if [[ -L "$cache_dir" || -L "$launcher_lock_dir" || -L "${launcher_lock_dir}/pid" || -L "${launcher_lock_dir}/boot_id" ]]; then
    echo "chartplotter launcher lock path contains a symlink: $launcher_lock_dir" >&2
    exit 1
  fi
  if [[ -e "$launcher_lock_dir" && ! -d "$launcher_lock_dir" ]]; then
    echo "chartplotter launcher lock path is not a directory: $launcher_lock_dir" >&2
    exit 1
  fi
}

launcher_lock_path_safe_for_cleanup() {
  if [[ -L "$cache_dir" || -L "$launcher_lock_dir" || -L "${launcher_lock_dir}/pid" || -L "${launcher_lock_dir}/boot_id" ]]; then
    echo "chartplotter launcher lock path became unsafe; leaving it in place: $launcher_lock_dir" >&2
    return 1
  fi
  if [[ -e "$launcher_lock_dir" && ! -d "$launcher_lock_dir" ]]; then
    echo "chartplotter launcher lock path is no longer a directory; leaving it in place: $launcher_lock_dir" >&2
    return 1
  fi
  return 0
}

read_launcher_lock_file() {
  local name="$1"
  local label="$2"
  "$python3_bin" - "$launcher_lock_dir" "$name" "$label" <<'PY'
from pathlib import Path
import os
import stat
import sys

lock = Path(sys.argv[1]).expanduser()
name = sys.argv[2]
label = sys.argv[3]
expected_uid = os.getuid()

if "/" in name or name in {"", ".", ".."}:
    raise SystemExit(f"{label} name is unsafe: {name}")
if lock.is_symlink():
    raise SystemExit(f"chartplotter launcher lock path contains a symlink: {lock}")

dir_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
dir_fd = os.open(lock, dir_flags)
try:
    lock_stat = os.fstat(dir_fd)
    if not stat.S_ISDIR(lock_stat.st_mode):
        raise SystemExit(f"chartplotter launcher lock path is not a directory after opening: {lock}")
    if lock_stat.st_uid != expected_uid:
        raise SystemExit(
            f"chartplotter launcher lock directory is owned by uid {lock_stat.st_uid}, expected {expected_uid}: {lock}"
        )
    lock_mode = lock_stat.st_mode & 0o777
    if lock_mode & 0o077:
        raise SystemExit(f"chartplotter launcher lock directory has permissions {lock_mode:04o}, expected private 0700: {lock}")
    fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=dir_fd)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise SystemExit(f"{label} is not a regular file")
        if opened.st_uid != expected_uid:
            raise SystemExit(f"{label} is owned by uid {opened.st_uid}, expected {expected_uid}")
        mode = opened.st_mode & 0o777
        if mode != 0o600:
            raise SystemExit(f"{label} has permissions {mode:04o}, expected private 0600")
        data = os.read(fd, 4096).decode("ascii", "ignore").splitlines()
        if data:
            sys.stdout.write(data[0])
    finally:
        os.close(fd)
finally:
    os.close(dir_fd)
PY
}

remove_stale_launcher_lock() {
  "$python3_bin" - "$cache_dir" "$launcher_lock_dir" <<'PY'
from pathlib import Path
import os
import shutil
import stat
import sys

cache = Path(sys.argv[1]).expanduser()
lock = Path(sys.argv[2]).expanduser()
expected_uid = os.getuid()

def fail(message: str) -> None:
    raise SystemExit(message)

if cache.is_symlink():
    fail(f"chartplotter launcher cache path became unsafe; leaving lock in place: {cache}")
if lock.is_symlink():
    fail(f"chartplotter launcher lock path became unsafe; leaving it in place: {lock}")
if not lock.exists():
    raise SystemExit(0)
if not lock.is_dir():
    fail(f"chartplotter launcher lock path is no longer a directory; leaving it in place: {lock}")
try:
    lock.resolve(strict=False).relative_to(cache.resolve(strict=True))
except ValueError:
    fail(f"chartplotter launcher lock path is outside cache directory: {lock}")
except OSError as exc:
    fail(f"could not inspect chartplotter launcher lock path: {exc}")

for path in [lock, *lock.rglob("*")]:
    try:
        path_stat = path.lstat()
    except OSError as exc:
        fail(f"could not inspect chartplotter launcher lock path before cleanup: {path}: {exc}")
    if stat.S_ISLNK(path_stat.st_mode):
        fail(f"chartplotter launcher lock path contains a symlink; leaving it in place: {path}")
    mode = path_stat.st_mode & 0o777
    if path_stat.st_uid != expected_uid:
        fail(
            f"chartplotter launcher lock path is owned by uid {path_stat.st_uid}, "
            f"expected {expected_uid}; leaving it in place: {path}"
        )
    if path == lock and mode != 0o700:
        fail(
            f"chartplotter launcher lock path has permissions {mode:04o}, "
            f"expected private 0700; leaving it in place: {path}"
        )
    if path.parent == lock and path.name in {"pid", "boot_id"}:
        if not stat.S_ISREG(path_stat.st_mode):
            fail(f"chartplotter launcher lock {path.name} is not a regular file; leaving it in place: {path}")
        if mode != 0o600:
            fail(
                f"chartplotter launcher lock {path.name} has permissions {mode:04o}, "
                f"expected private 0600; leaving it in place: {path}"
            )
    if mode & 0o022:
        fail(
            f"chartplotter launcher lock path has permissions {mode:04o}, "
            f"expected no group/other write bits; leaving it in place: {path}"
        )

if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):
    fail("Python shutil.rmtree is not symlink-attack resistant on this platform; leaving stale launcher lock in place")
shutil.rmtree(lock)
try:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(cache, flags)
except OSError:
    fd = None
if fd is not None:
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

launcher_lock_from_current_boot() {
  local current
  local lock_boot_id=""
  current="$(current_boot_id)"
  if [[ -z "$current" || ! -r "${launcher_lock_dir}/boot_id" ]]; then
    return 0
  fi
  lock_boot_id="$(read_launcher_lock_file boot_id "chartplotter launcher lock boot ID" 2>/dev/null || true)"
  [[ "$lock_boot_id" == "$current" ]]
}

write_launcher_lock_files() {
  local boot_id
  boot_id="$(current_boot_id)"
  "$python3_bin" - "$launcher_lock_dir" "$$" "$boot_id" <<'PY'
from pathlib import Path
import os
import stat
import sys

lock = Path(sys.argv[1]).expanduser()
pid_text = sys.argv[2]
boot_id_text = sys.argv[3]
expected_uid = os.getuid()

if not pid_text.isdigit():
    raise SystemExit(f"chartplotter launcher lock pid is invalid: {pid_text}")
if lock.is_symlink():
    raise SystemExit(f"chartplotter launcher lock path contains a symlink: {lock}")
if not lock.is_dir():
    raise SystemExit(f"chartplotter launcher lock path is not a directory: {lock}")

dir_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
dir_fd = os.open(lock, dir_flags)
try:
    lock_stat = os.fstat(dir_fd)
    if not stat.S_ISDIR(lock_stat.st_mode):
        raise SystemExit(f"chartplotter launcher lock path is not a directory after opening: {lock}")
    if lock_stat.st_uid != expected_uid:
        raise SystemExit(
            f"chartplotter launcher lock directory is owned by uid {lock_stat.st_uid}, expected {expected_uid}: {lock}"
        )
    lock_mode = lock_stat.st_mode & 0o777
    if lock_mode & 0o077:
        raise SystemExit(f"chartplotter launcher lock directory has permissions {lock_mode:04o}, expected private 0700: {lock}")

    nofollow = getattr(os, "O_NOFOLLOW", 0)

    def validate_private_file_fd(fd: int, name: str) -> None:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise SystemExit(f"chartplotter launcher lock {name} is not a regular file")
        if opened.st_uid != expected_uid:
            raise SystemExit(
                f"chartplotter launcher lock {name} is owned by uid {opened.st_uid}, expected {expected_uid}"
            )
        mode = opened.st_mode & 0o777
        if mode != 0o600:
            raise SystemExit(f"chartplotter launcher lock {name} has permissions {mode:04o}, expected private 0600")

    def write_all(fd: int, data: bytes) -> None:
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise SystemExit("could not write chartplotter launcher lock metadata")
            view = view[written:]

    def validate_lock_file_content(name: str, value: str) -> None:
        fd = os.open(name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
        try:
            validate_private_file_fd(fd, name)
            data = os.read(fd, 4096).decode("ascii", "ignore")
        finally:
            os.close(fd)
        if data != f"{value}\n":
            raise SystemExit(f"chartplotter launcher lock {name} content changed during promotion")

    def write_private_file(name: str, value: str) -> None:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow
        data = f"{value}\n".encode("ascii")
        tmp_name = None
        fd = -1
        for attempt in range(100):
            candidate = f".{name}.{os.getpid()}.{attempt}.tmp"
            try:
                fd = os.open(candidate, flags, 0o600, dir_fd=dir_fd)
            except FileExistsError:
                continue
            tmp_name = candidate
            break
        if tmp_name is None:
            raise SystemExit(f"could not create private temporary chartplotter launcher lock {name}")
        try:
            try:
                validate_private_file_fd(fd, tmp_name)
                os.fchmod(fd, 0o600)
                write_all(fd, data)
                os.fsync(fd)
            finally:
                if fd >= 0:
                    os.close(fd)
            os.replace(tmp_name, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
            tmp_name = None
            validate_lock_file_content(name, value)
        finally:
            if tmp_name is not None:
                try:
                    os.unlink(tmp_name, dir_fd=dir_fd)
                except FileNotFoundError:
                    pass

    def unlink_optional_private_file(name: str) -> None:
        try:
            fd = os.open(name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
        except FileNotFoundError:
            return
        try:
            validate_private_file_fd(fd, name)
        finally:
            os.close(fd)
        os.unlink(name, dir_fd=dir_fd)

    write_private_file("pid", pid_text)
    if boot_id_text:
        write_private_file("boot_id", boot_id_text)
    else:
        unlink_optional_private_file("boot_id")
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
  sync_paths "$launcher_lock_dir" || true
}

release_owned_launcher_lock() {
  local boot_id
  boot_id="$(current_boot_id)"
  "$python3_bin" - "$cache_dir" "$launcher_lock_dir" "$$" "$boot_id" <<'PY'
from pathlib import Path
import os
import stat
import sys

cache = Path(sys.argv[1]).expanduser()
lock = Path(sys.argv[2]).expanduser()
pid_text = sys.argv[3]
boot_id_text = sys.argv[4]
expected_uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)

def note(message: str) -> None:
    print(message, file=sys.stderr)

def leave(message: str) -> None:
    note(message)
    raise SystemExit(0)

def open_private_file(dir_fd: int, name: str, label: str) -> str:
    try:
        fd = os.open(name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
    except FileNotFoundError:
        leave(f"{label} is missing; leaving launcher lock in place: {lock}")
    except OSError as exc:
        leave(f"could not open {label}; leaving launcher lock in place: {exc}")
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            leave(f"{label} is not a regular file; leaving launcher lock in place: {lock}")
        if opened.st_uid != expected_uid:
            leave(f"{label} is owned by uid {opened.st_uid}, expected {expected_uid}; leaving launcher lock in place: {lock}")
        mode = opened.st_mode & 0o777
        if mode != 0o600:
            leave(f"{label} has permissions {mode:04o}, expected private 0600; leaving launcher lock in place: {lock}")
        lines = os.read(fd, 4096).decode("ascii", "ignore").splitlines()
        return lines[0] if lines else ""
    finally:
        os.close(fd)

if cache.is_symlink() or lock.is_symlink():
    leave(f"chartplotter launcher lock path became unsafe; leaving it in place: {lock}")
if not lock.exists():
    raise SystemExit(0)
if not lock.is_dir():
    leave(f"chartplotter launcher lock path is no longer a directory; leaving it in place: {lock}")
try:
    lock.resolve(strict=False).relative_to(cache.resolve(strict=True))
except ValueError:
    leave(f"chartplotter launcher lock path is outside cache directory; leaving it in place: {lock}")
except OSError as exc:
    leave(f"could not inspect chartplotter launcher lock path; leaving it in place: {exc}")

dir_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow
try:
    dir_fd = os.open(lock, dir_flags)
except OSError as exc:
    leave(f"could not open chartplotter launcher lock directory; leaving it in place: {exc}")
try:
    lock_stat = os.fstat(dir_fd)
    if not stat.S_ISDIR(lock_stat.st_mode):
        leave(f"chartplotter launcher lock path is not a directory after opening; leaving it in place: {lock}")
    if lock_stat.st_uid != expected_uid:
        leave(
            f"chartplotter launcher lock directory is owned by uid {lock_stat.st_uid}, "
            f"expected {expected_uid}; leaving it in place: {lock}"
        )
    lock_mode = lock_stat.st_mode & 0o777
    if lock_mode != 0o700:
        leave(f"chartplotter launcher lock directory has permissions {lock_mode:04o}, expected private 0700; leaving it in place: {lock}")

    lock_pid = open_private_file(dir_fd, "pid", "chartplotter launcher lock pid")
    if lock_pid != pid_text:
        leave("chartplotter launcher lock no longer belongs to this launcher; leaving it in place")
    if boot_id_text:
        lock_boot_id = open_private_file(dir_fd, "boot_id", "chartplotter launcher lock boot ID")
        if lock_boot_id != boot_id_text:
            leave("chartplotter launcher lock boot ID no longer matches this launcher; leaving it in place")
    else:
        try:
            boot_fd = os.open("boot_id", os.O_RDONLY | nofollow, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
        else:
            os.close(boot_fd)
            leave("chartplotter launcher lock has unexpected boot ID metadata; leaving it in place")

    for name in ("pid", "boot_id"):
        try:
            os.unlink(name, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)

try:
    cache_fd = os.open(cache, dir_flags)
except OSError:
    cache_fd = -1
if cache_fd >= 0:
    try:
        try:
            current_lock_stat = os.stat(lock.name, dir_fd=cache_fd, follow_symlinks=False)
        except FileNotFoundError:
            current_lock_stat = None
        if current_lock_stat is not None and not os.path.samestat(lock_stat, current_lock_stat):
            leave("chartplotter launcher lock directory changed before release cleanup; leaving it in place")
        try:
            os.rmdir(lock.name, dir_fd=cache_fd)
        except FileNotFoundError:
            pass
        except OSError as exc:
            leave(f"could not remove chartplotter launcher lock directory; leaving it in place: {exc}")
        os.fsync(cache_fd)
    finally:
        os.close(cache_fd)
PY
}

release_launcher_lock() {
  if [[ "$lock_acquired" -eq 1 ]]; then
    release_owned_launcher_lock || true
    sync_paths "$launcher_lock_dir" || true
    lock_acquired=0
  fi
}

terminate_opencpn_child() {
  local child_pid="$opencpn_child_pid"
  local waited=0
  if [[ -n "$child_pid" && "$child_pid" =~ ^[0-9]+$ ]] && kill -0 "$child_pid" 2>/dev/null; then
    echo "Forwarding launcher shutdown to OpenCPN child process ${child_pid}."
    kill -TERM "$child_pid" 2>/dev/null || true
    while opencpn_process_active "$child_pid" && [[ "$waited" -lt "$opencpn_shutdown_grace_seconds" ]]; do
      sleep 1
      waited=$((waited + 1))
    done
    if opencpn_process_active "$child_pid"; then
      echo "OpenCPN child process ${child_pid} did not exit after ${opencpn_shutdown_grace_seconds}s; sending KILL." >&2
      kill -KILL "$child_pid" 2>/dev/null || true
    fi
    wait "$child_pid" 2>/dev/null || true
  fi
  opencpn_child_pid=""
}

shutdown_launcher() {
  trap - INT TERM
  terminate_opencpn_child
  exit 143
}

acquire_launcher_lock() {
  local owner_pid=""
  validate_launcher_lock_path
  if mkdir "$launcher_lock_dir" 2>/dev/null; then
    chmod 0700 "$launcher_lock_dir"
    write_launcher_lock_files
    lock_acquired=1
    trap release_launcher_lock EXIT
    return 0
  fi
  if ! launcher_lock_from_current_boot; then
    echo "Launcher lock is from a previous boot; treating lock as stale."
  else
    if [[ -r "${launcher_lock_dir}/pid" ]]; then
      owner_pid="$(read_launcher_lock_file pid "chartplotter launcher lock pid" 2>/dev/null || true)"
    fi
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null && process_looks_like_launcher "$owner_pid"; then
      if opencpn_running; then
        echo "OpenCPN is already running; leaving the existing chartplotter instance in place."
      else
        echo "Another NOAA Navionics chartplotter launcher is already running; leaving it in charge."
      fi
      exit 0
    fi
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      echo "Launcher lock PID ${owner_pid} is not a chartplotter launcher; treating lock as stale."
    fi
  fi
  echo "Removing stale chartplotter launcher lock."
  if ! launcher_lock_path_safe_for_cleanup; then
    exit 1
  fi
  if ! remove_stale_launcher_lock; then
    exit 1
  fi
  if mkdir "$launcher_lock_dir" 2>/dev/null; then
    chmod 0700 "$launcher_lock_dir"
    write_launcher_lock_files
    lock_acquired=1
    trap release_launcher_lock EXIT
    return 0
  fi
  echo "Could not acquire chartplotter launcher lock; leaving any active launcher in charge." >&2
  exit 0
}

show_preflight_warning() {
  local action_text
  local button_text
  if [[ "$start_on_failed_readiness" -eq 1 ]]; then
    action_text="OpenCPN will start anyway. Keep backup navigation available."
    button_text="Start OpenCPN"
  else
    action_text="OpenCPN will not start automatically. Keep backup navigation available and fix readiness before departure."
    button_text="Dismiss"
  fi
  if [[ "$warning_seconds" -eq 0 ]]; then
    echo "Readiness warning timeout is 0 seconds; continuing immediately."
    return 0
  fi
  if [[ -z "${DISPLAY:-}" ]]; then
    echo "No display session found for readiness warning; waiting ${warning_seconds}s before continuing."
    sleep "$warning_seconds"
    return 0
  fi
  if "$python3_bin" - "$status_report" "$warning_seconds" "$action_text" "$button_text" <<'PY'
from pathlib import Path
import json
import os
import stat
import sys
import tkinter as tk

status_report = Path(sys.argv[1]).expanduser()
seconds = int(sys.argv[2])
action_text = sys.argv[3]
button_text = sys.argv[4]

def open_trusted_status_report(path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        return None
    try:
        status = os.fstat(fd)
        if not stat.S_ISREG(status.st_mode):
            return None
        if status.st_uid != os.getuid():
            return None
        mode = status.st_mode & 0o777
        if mode & 0o077:
            return None
        handle = os.fdopen(fd, encoding="utf-8")
        fd = -1
        return handle
    finally:
        if fd >= 0:
            os.close(fd)

def failed_checks(path):
    handle = open_trusted_status_report(path)
    if handle is None:
        return []
    try:
        with handle:
            report = json.load(handle)
    except Exception:
        return []
    failed = []
    for section in ("checks", "service_checks"):
        rows = report.get(section, [])
        if not isinstance(rows, list):
            continue
        for row in rows:
            if not isinstance(row, dict) or row.get("ok") is True:
                continue
            name = str(row.get("name", "Check")).strip() or "Check"
            detail = str(row.get("detail", "")).strip()
            failed.append(f"{name}: {detail}" if detail else name)
    return failed

failures = failed_checks(status_report)
if failures:
    visible = failures[:6]
    extra = len(failures) - len(visible)
    failure_text = "Failed checks:\n" + "\n".join(f"- {item}" for item in visible)
    if extra > 0:
        failure_text += f"\n- and {extra} more"
else:
    failure_text = "Failed checks could not be read from the status report."

root = tk.Tk()
root.title("NOAA Navionics Readiness")
root.attributes("-topmost", True)
root.resizable(False, False)
message = (
    "NOAA Navionics readiness failed.\n\n"
    f"{failure_text}\n\n"
    f"Status report:\n{status_report}\n\n"
    f"{action_text}"
)
frame = tk.Frame(root, padx=24, pady=20)
frame.pack(fill="both", expand=True)
label = tk.Label(frame, text=message, justify="left", wraplength=520)
label.pack(pady=(0, 16))
button = tk.Button(frame, text=button_text, command=root.destroy)
button.pack()
root.after(seconds * 1000, root.destroy)
root.mainloop()
PY
  then
    echo "Readiness warning displayed for ${warning_seconds}s."
  else
    echo "Readiness warning dialog unavailable; waiting ${warning_seconds}s before continuing." >&2
    sleep "$warning_seconds"
  fi
}

run_readiness_report() {
  local attempt=1
  while [[ "$attempt" -le "$readiness_attempts" ]]; do
    if "$bin" status-report --config "$config" --gps-seconds "$gps_seconds" --output "$status_report"; then
      if [[ "$attempt" -eq 1 ]]; then
        echo "NOAA Navionics preflight passed."
      else
        echo "NOAA Navionics preflight passed on attempt ${attempt}/${readiness_attempts}."
      fi
      return 0
    fi
    echo "NOAA Navionics preflight failed on attempt ${attempt}/${readiness_attempts}. Status report: $status_report" >&2
    if [[ "$attempt" -lt "$readiness_attempts" ]]; then
      echo "Retrying readiness in ${readiness_retry_delay}s." >&2
      sleep "$readiness_retry_delay"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

validate_opencpn_binary_candidate() {
  local candidate="$1"
  local stat_output
  local owner_uid
  local mode_text
  local mode
  local parent_dir
  local parent_stat
  local parent_owner_uid
  local parent_mode_text
  local parent_mode
  local symlink_component

  if [[ -z "$candidate" ]]; then
    return 1
  fi
  case "$candidate" in
    /*)
      ;;
    *)
      echo "OpenCPN executable path is not absolute: $candidate" >&2
      return 1
      ;;
  esac
  if [[ -L "$candidate" ]]; then
    echo "OpenCPN executable is a symlink: $candidate" >&2
    return 1
  fi
  parent_dir="$(dirname "$candidate")"
  if symlink_component="$(first_symlink_ancestor "$parent_dir")"; then
    echo "OpenCPN executable path contains a symlink: $symlink_component" >&2
    return 1
  fi
  if [[ ! -f "$candidate" ]]; then
    echo "OpenCPN executable is not a regular file: $candidate" >&2
    return 1
  fi
  if [[ ! -x "$candidate" ]]; then
    echo "OpenCPN executable is not executable: $candidate" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$candidate" 2>/dev/null)" || {
    echo "Could not inspect OpenCPN executable: $candidate" >&2
    return 1
  }
  owner_uid="${stat_output%% *}"
  mode_text="${stat_output#* }"
  mode=$((8#$mode_text))
  if (( mode & 022 )); then
    echo "OpenCPN executable has permissions ${mode_text}, expected no group/other write bits: $candidate" >&2
    return 1
  fi
  parent_stat="$(stat -c '%u %a' "$parent_dir" 2>/dev/null)" || {
    echo "Could not inspect OpenCPN executable directory: $parent_dir" >&2
    return 1
  }
  parent_owner_uid="${parent_stat%% *}"
  parent_mode_text="${parent_stat#* }"
  parent_mode=$((8#$parent_mode_text))
  if (( parent_mode & 022 )); then
    echo "OpenCPN executable directory has permissions ${parent_mode_text}, expected no group/other write bits: $parent_dir" >&2
    return 1
  fi
  if is_raspberry_pi && [[ "$parent_owner_uid" != "0" ]]; then
    echo "OpenCPN executable directory is owned by uid ${parent_owner_uid}, expected root on Raspberry Pi: $parent_dir" >&2
    return 1
  fi
  if [[ "$parent_owner_uid" != "0" && "$parent_owner_uid" != "$(id -u)" ]]; then
    echo "OpenCPN executable directory is owned by uid ${parent_owner_uid}, expected root or $(id -u): $parent_dir" >&2
    return 1
  fi
  if is_raspberry_pi && [[ "$owner_uid" != "0" ]]; then
    echo "OpenCPN executable is owned by uid ${owner_uid}, expected root on Raspberry Pi: $candidate" >&2
    return 1
  fi
  if [[ "$owner_uid" != "0" && "$owner_uid" != "$(id -u)" ]]; then
    echo "OpenCPN executable is owned by uid ${owner_uid}, expected root or $(id -u): $candidate" >&2
    return 1
  fi
  return 0
}

resolve_opencpn_binary() {
  local path_candidate

  path_candidate="$(command -v opencpn 2>/dev/null || true)"
  if validate_opencpn_binary_candidate "$path_candidate"; then
    opencpn_bin="$path_candidate"
    echo "Using OpenCPN binary: $opencpn_bin"
    return 0
  fi
  echo "OpenCPN is not installed at a trusted executable path; install opencpn before launching chartplotter." >&2
  return 127
}

run_opencpn_supervised() {
  local restart_count=0
  local opencpn_pid
  local opencpn_status
  while true; do
    if opencpn_running; then
      echo "OpenCPN is already running; leaving the existing chartplotter instance in place."
      return 0
    fi
    echo "Launching OpenCPN with ENC processing."
    "$opencpn_bin" -parse_all_enc &
    opencpn_pid=$!
    opencpn_child_pid="$opencpn_pid"
    for _ in 1 2 3 4 5; do
      if opencpn_running || ! kill -0 "$opencpn_pid" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    while opencpn_process_active "$opencpn_pid"; do
      sleep 1
    done
    set +e
    wait "$opencpn_pid"
    opencpn_status=$?
    set -e
    opencpn_child_pid=""
    printf '[%s] OpenCPN exited with status %s\n' "$(utc_log_timestamp)" "$opencpn_status"
    if [[ "$opencpn_status" -eq 0 ]]; then
      echo "OpenCPN exited cleanly; not restarting."
      return 0
    fi
    if [[ "$restart_count" -ge "$opencpn_restarts" ]]; then
      echo "OpenCPN exited with status ${opencpn_status} after ${restart_count} restart(s); no restart attempts remain." >&2
      return "$opencpn_status"
    fi
    restart_count=$((restart_count + 1))
    echo "Restarting OpenCPN after nonzero exit status ${opencpn_status} (restart ${restart_count}/${opencpn_restarts}) in ${opencpn_restart_delay}s." >&2
    sleep "$opencpn_restart_delay"
  done
}

reexec_without_ambient_launcher_settings "$@"

if [[ ! -x "$bin" ]]; then
  echo "noaa-navionics is not installed at $bin" >&2
  exit 127
fi

python3_bin="$(python3_command_path)" || exit 127

prepare_private_cache_dir
rotate_launcher_log_if_needed
prepare_private_log_file
start_private_log_stream

printf '\n[%s] Starting NOAA Navionics chartplotter launcher\n' "$(utc_log_timestamp)"
acquire_launcher_lock
trap shutdown_launcher INT TERM
validate_launcher_env_path
load_launcher_settings
keep_display_awake

if ! run_readiness_report; then
  echo "NOAA Navionics readiness failed after ${readiness_attempts} attempt(s). Status report: $status_report" >&2
  show_preflight_warning
  if [[ "$start_on_failed_readiness" -ne 1 ]]; then
    echo "Not starting OpenCPN automatically because readiness failed." >&2
    exit 1
  fi
  echo "Starting OpenCPN despite failed readiness because NOAA_NAVIONICS_START_ON_FAILED_READINESS is enabled." >&2
fi

resolve_opencpn_binary

run_opencpn_supervised
