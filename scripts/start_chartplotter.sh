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
lock_acquired=0
opencpn_bin=""
opencpn_child_pid=""
trusted_system_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
device_tree_model=""

if [[ -r /proc/device-tree/model ]]; then
  IFS= read -r -d '' device_tree_model </proc/device-tree/model || true
fi
if [[ "$device_tree_model" == *"Raspberry Pi"* ]]; then
  PATH="$trusted_system_path"
  export PATH
fi

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

sync_paths() {
  python3 - "$@" <<'PY'
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
  mkdir -p "$cache_dir"
  cache_dir_stat="$(stat -c '%u' "$cache_dir" 2>/dev/null || true)"
  if [[ -z "$cache_dir_stat" ]]; then
    echo "Could not inspect NOAA Navionics cache directory: $cache_dir" >&2
    exit 1
  fi
  cache_dir_uid="$cache_dir_stat"
  if [[ "$cache_dir_uid" != "$(id -u)" ]]; then
    echo "NOAA Navionics cache directory is owned by uid ${cache_dir_uid}, expected $(id -u): $cache_dir" >&2
    exit 1
  fi
  chmod 0700 "$cache_dir"
  sync_paths "$cache_parent" "$cache_dir" || true
}

prepare_private_log_file() {
  python3 - "$log_file" <<'PY'
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

read_trusted_launcher_env() {
  python3 - "$launcher_env" <<'PY'
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

keep_display_awake() {
  if [[ -n "${DISPLAY:-}" ]] && command -v xset >/dev/null 2>&1; then
    local failures=0
    xset s off >/dev/null 2>&1 || failures=$((failures + 1))
    xset s noblank >/dev/null 2>&1 || failures=$((failures + 1))
    xset -dpms >/dev/null 2>&1 || failures=$((failures + 1))
    if [[ "$failures" -eq 0 ]]; then
      echo "Requested display sleep and blanking disabled."
    else
      echo "Display session found, but ${failures} xset command(s) failed; leaving some display power settings unchanged." >&2
    fi
  elif [[ -n "${DISPLAY:-}" ]]; then
    echo "Display session found, but xset is unavailable; leaving display power settings unchanged."
  fi
  return 0
}

opencpn_running() {
  local pid
  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r pid; do
      if opencpn_process_active "$pid"; then
        return 0
      fi
    done < <(pgrep -u "$(id -u)" -x opencpn 2>/dev/null || true)
  fi
  return 1
}

opencpn_process_active() {
  local pid="$1"
  local stat_line
  local state
  if [[ ! "$pid" =~ ^[0-9]+$ || ! -r "/proc/${pid}/stat" ]]; then
    return 1
  fi
  stat_line="$(cat "/proc/${pid}/stat" 2>/dev/null || true)"
  state="${stat_line##*) }"
  state="${state%% *}"
  [[ -n "$state" && "$state" != "Z" ]]
}

process_looks_like_launcher() {
  local pid="$1"
  local arg
  local arg_name
  if [[ ! "$pid" =~ ^[0-9]+$ || ! -r "/proc/${pid}/cmdline" ]]; then
    return 1
  fi
  while IFS= read -r -d '' arg; do
    arg_name="${arg##*/}"
    if [[ "$arg_name" == "noaa-navionics-start-chartplotter" || "$arg_name" == "start_chartplotter.sh" ]]; then
      return 0
    fi
  done <"/proc/${pid}/cmdline"
  return 1
}

current_boot_id() {
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    head -n 1 /proc/sys/kernel/random/boot_id 2>/dev/null || true
  fi
}

is_raspberry_pi() {
  [[ -r /proc/device-tree/model ]] && grep -Fq 'Raspberry Pi' /proc/device-tree/model 2>/dev/null
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
  python3 - "$launcher_lock_dir" "$name" "$label" <<'PY'
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
    fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=dir_fd)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise SystemExit(f"{label} is not a regular file")
        if opened.st_uid != expected_uid:
            raise SystemExit(f"{label} is owned by uid {opened.st_uid}, expected {expected_uid}")
        mode = opened.st_mode & 0o777
        if mode & 0o022:
            raise SystemExit(f"{label} has permissions {mode:04o}, expected no group/other write bits")
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
  python3 - "$cache_dir" "$launcher_lock_dir" <<'PY'
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
  python3 - "$launcher_lock_dir" "$$" "$boot_id" <<'PY'
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

    def write_private_file(name: str, value: str) -> None:
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(name, flags, 0o600, dir_fd=dir_fd)
        try:
            opened = os.fstat(fd)
            if not stat.S_ISREG(opened.st_mode):
                raise SystemExit(f"chartplotter launcher lock {name} is not a regular file")
            if opened.st_uid != expected_uid:
                raise SystemExit(
                    f"chartplotter launcher lock {name} is owned by uid {opened.st_uid}, expected {expected_uid}"
                )
            os.fchmod(fd, 0o600)
            os.write(fd, f"{value}\n".encode("ascii"))
            os.fsync(fd)
        finally:
            os.close(fd)

    write_private_file("pid", pid_text)
    if boot_id_text:
        write_private_file("boot_id", boot_id_text)
    else:
        try:
            existing = os.stat("boot_id", dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISREG(existing.st_mode):
                raise SystemExit("chartplotter launcher lock boot_id is not a regular file")
            os.unlink("boot_id", dir_fd=dir_fd)
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
  sync_paths "$launcher_lock_dir" || true
}

release_launcher_lock() {
  if [[ "$lock_acquired" -eq 1 ]]; then
    if ! launcher_lock_path_safe_for_cleanup; then
      lock_acquired=0
      return
    fi
    rm -f "${launcher_lock_dir}/pid" "${launcher_lock_dir}/boot_id"
    rmdir "$launcher_lock_dir" 2>/dev/null || true
    sync_paths "$launcher_lock_dir" || true
    lock_acquired=0
  fi
}

terminate_opencpn_child() {
  local child_pid="$opencpn_child_pid"
  if [[ -n "$child_pid" && "$child_pid" =~ ^[0-9]+$ ]] && kill -0 "$child_pid" 2>/dev/null; then
    echo "Forwarding launcher shutdown to OpenCPN child process ${child_pid}."
    kill -TERM "$child_pid" 2>/dev/null || true
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
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is unavailable for readiness warning; waiting ${warning_seconds}s before continuing." >&2
    sleep "$warning_seconds"
    return 0
  fi
  if python3 - "$status_report" "$warning_seconds" "$action_text" "$button_text" <<'PY'
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
    printf '[%s] OpenCPN exited with status %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$opencpn_status"
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

prepare_private_cache_dir
if [[ -L "$log_file" ]]; then
  echo "NOAA Navionics launcher log is a symlink: $log_file" >&2
  exit 1
fi
if [[ -e "$log_file" && ! -f "$log_file" ]]; then
  echo "NOAA Navionics launcher log is not a regular file: $log_file" >&2
  exit 1
fi
if [[ -f "$log_file" ]]; then
  log_bytes="$(wc -c <"$log_file" 2>/dev/null || printf '0')"
  if [[ "$log_bytes" -gt "$max_log_bytes" ]]; then
    if [[ -L "${log_file}.1" ]]; then
      echo "NOAA Navionics rotated launcher log is a symlink: ${log_file}.1" >&2
      exit 1
    fi
    if [[ -e "${log_file}.1" && ! -f "${log_file}.1" ]]; then
      echo "NOAA Navionics rotated launcher log is not a regular file: ${log_file}.1" >&2
      exit 1
    fi
    mv -f "$log_file" "${log_file}.1"
    chmod 0600 "${log_file}.1"
    sync_paths "${log_file}.1" || true
  fi
fi
prepare_private_log_file
exec > >(tee -a "$log_file") 2>&1

printf '\n[%s] Starting NOAA Navionics chartplotter launcher\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
