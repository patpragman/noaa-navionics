#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/pre_trip_prepare_pi.sh user@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE [options]

Runs the normal pre-trip dock workflow against an already commissioned
Raspberry Pi:
  1. Refresh NOAA charts on the Pi and run a post-refresh status report.
  2. Export a local recovery bundle and verify the exported archives.
  3. Run the live no-deploy, no-reboot pre-departure check.

Options:
  --device PATH       Stable GPS device path expected on the Pi
  --output-dir DIR    Local recovery export parent directory (default: pi-recovery-exports)
  --track-days N      Export GPX tracks modified in the last N days; 0 exports all (default: 30)
  --gps-seconds N     Override commissioned GPS wait for status/pre-departure checks
  --retries N         Chart download attempts on the Pi (default: 5)
  --retry-delay N     Seconds between chart download retry attempts (default: 30)
  --force-refresh     Force a NOAA chart redownload on the Pi
  --allow-dirty       Allow verifying a deliberate dirty test deployment
  --opencpn-restarts N
                     Expected OpenCPN nonzero-exit restart attempts after boot
  --opencpn-restart-delay N
                     Expected seconds between OpenCPN restart attempts
  --skip-refresh      Skip the chart refresh and post-refresh status report
  --skip-recovery     Skip recovery export and local export verification
  --skip-pre-departure
                     Skip the live strict pre-departure verification

This wrapper does not install, enable, reboot, shut down, or download charts
on the local computer. Chart downloads, if not skipped, run on the Raspberry Pi.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

target="$1"
shift
device=""
output_dir="pi-recovery-exports"
track_days=30
gps_seconds=""
retries=5
retry_delay=30
force_refresh=0
allow_dirty=0
skip_refresh=0
skip_recovery=0
skip_pre_departure=0
opencpn_restarts=""
opencpn_restart_delay=""
python3_cmd=""

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer" >&2
    exit 2
  fi
}

require_non_negative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a non-negative integer" >&2
    exit 2
  fi
}

local_path_in_trusted_system_dir() {
  case "$1" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*)
      return 0
      ;;
  esac
  return 1
}

check_local_owner_and_mode() {
  local item_kind="$1"
  local item_path="$2"
  local mode
  local mode_tail
  local owner_uid
  local stat_output

  if ! stat_output="$(stat -Lc '%u %a' -- "$item_path" 2>/dev/null)"; then
    echo "Could not inspect local command ${item_kind}: $item_path" >&2
    exit 2
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"

  if [[ "$owner_uid" != "0" ]]; then
    echo "Local command ${item_kind} is owned by uid ${owner_uid}, expected 0: ${item_path}" >&2
    exit 2
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      echo "Local command ${item_kind} has permissions ${mode}, expected no group/other write: ${item_path}" >&2
      exit 2
      ;;
  esac
}

check_local_directory_chain() {
  local directory
  directory="$(dirname -- "$1")"
  while :; do
    check_local_owner_and_mode directory "$directory"
    [[ "$directory" == "/" ]] && break
    directory="$(dirname -- "$directory")"
  done
}

validate_trusted_local_command() {
  local command_name="$1"
  local command_path="$2"
  local resolved_path

  if ! local_path_in_trusted_system_dir "$command_path"; then
    echo "Local ${command_name} command is not in a trusted system directory: $command_path" >&2
    exit 2
  fi
  if [[ ! -x "$command_path" ]]; then
    echo "Local ${command_name} command is not executable: $command_path" >&2
    exit 2
  fi
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    echo "Could not resolve local ${command_name} command: $command_path" >&2
    exit 2
  fi
  if ! local_path_in_trusted_system_dir "$resolved_path"; then
    echo "Resolved local ${command_name} command is not in a trusted system directory: $resolved_path" >&2
    exit 2
  fi
  if [[ ! -x "$resolved_path" ]]; then
    echo "Local ${command_name} command is not executable after resolution: $resolved_path" >&2
    exit 2
  fi
  check_local_owner_and_mode "$command_name" "$resolved_path"
  check_local_directory_chain "$resolved_path"
}

require_local_command() {
  local command_name="$1"
  local command_path

  if ! command_path="$(command -v "$command_name" 2>/dev/null)" || [[ -z "$command_path" ]]; then
    echo "Missing required local command: $command_name" >&2
    exit 2
  fi
  validate_trusted_local_command "$command_name" "$command_path"
  printf '%s\n' "$command_path"
}

validate_gps_device_path_arg() {
  local value="$1"
  local suffix
  if [[ -z "$value" ]]; then
    echo "GPS device path is required" >&2
    exit 2
  fi
  if [[ "$value" =~ [[:space:]\"\'] ]]; then
    echo "GPS device path must not contain whitespace or quotes: $value" >&2
    exit 2
  fi
  case "$value" in
    /dev/serial/by-id/*)
      suffix="${value#/dev/serial/by-id/}"
      if [[ -n "$suffix" && "$suffix" != */* && "$suffix" != "." && "$suffix" != ".." && "$suffix" =~ ^[A-Za-z0-9._:+@-]+$ ]]; then
        return 0
      fi
      ;;
    /dev/serial0|/dev/serial1|/dev/gps)
      return 0
      ;;
    /dev/ttyUSB*|/dev/ttyACM*)
      echo "GPS device path is volatile; use /dev/serial/by-id/... instead: $value" >&2
      exit 2
      ;;
  esac
  echo "GPS device path must be /dev/serial/by-id/..., /dev/serial0, /dev/serial1, or /dev/gps: $value" >&2
  exit 2
}

validate_output_dir_arg() {
  local value="$1"
  if [[ -z "$value" ]]; then
    echo "Output directory is required" >&2
    exit 2
  fi
  if [[ "$value" =~ [\"\'] ]]; then
    echo "Output directory must not contain quotes: $value" >&2
    exit 2
  fi
  case "$value" in
    .|..|/|/home|/tmp|/var|/etc|/usr|/bin|/sbin|/opt|"$HOME"|"$HOME"/)
      echo "Output directory must be a dedicated export directory, not a broad or system path: $value" >&2
      exit 2
      ;;
  esac
  if [[ -L "$value" ]]; then
    echo "Output directory must not be a symlink: $value" >&2
    exit 2
  fi
}

reject_symlinked_path_components() {
  local label="$1"
  local path="$2"
  local current
  local component
  local remaining

  if [[ "$path" == /* ]]; then
    current="/"
    remaining="${path#/}"
  else
    current="."
    remaining="$path"
  fi

  while [[ -n "$remaining" ]]; do
    component="${remaining%%/*}"
    if [[ "$component" == "$remaining" ]]; then
      remaining=""
    else
      remaining="${remaining#*/}"
    fi
    if [[ -z "$component" || "$component" == "." ]]; then
      continue
    fi
    if [[ "$current" == "/" ]]; then
      current="/$component"
    else
      current="${current}/${component}"
    fi
    if [[ -L "$current" ]]; then
      echo "$label path contains a symlink: $current" >&2
      exit 2
    fi
  done
}

prepare_private_output_dir() {
  local label="$1"
  local path="$2"
  local current_uid
  local mode
  local owner_uid
  local stat_output

  current_uid="$(id -u)"
  reject_symlinked_path_components "$label" "$path"
  mkdir -p -- "$path"
  reject_symlinked_path_components "$label" "$path"
  if [[ ! -d "$path" || -L "$path" ]]; then
    echo "$label must be a real directory: $path" >&2
    exit 2
  fi
  if ! chmod 0700 -- "$path"; then
    echo "Could not tighten $label permissions to 0700: $path" >&2
    exit 2
  fi
  if [[ ! -d "$path" || -L "$path" ]]; then
    echo "$label must remain a real directory after tightening: $path" >&2
    exit 2
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    echo "Could not inspect $label owner and permissions: $path" >&2
    exit 2
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    echo "$label is owned by uid ${owner_uid}, expected current user ${current_uid}: $path" >&2
    exit 2
  fi
  if [[ "$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')" != "700" ]]; then
    echo "$label has permissions ${mode}, expected private 0700: $path" >&2
    exit 2
  fi
}

strip_trailing_slashes() {
  local value="$1"
  while [[ "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s' "$value"
}

require_recovery_dir_from_output() {
  local recovery_dir="$1"
  local output_root="$2"
  local child_name
  local current_uid
  local mode
  local owner_uid
  local stat_output

  recovery_dir="$(strip_trailing_slashes "$recovery_dir")"
  output_root="$(strip_trailing_slashes "$output_root")"
  if [[ -z "$recovery_dir" ]]; then
    echo "Recovery export directory is empty" >&2
    exit 1
  fi
  case "$recovery_dir" in
    "$output_root"/noaa-navionics-pi-recovery-*)
      ;;
    *)
      echo "Recovery export directory must be an immediate noaa-navionics-pi-recovery-* child of $output_root: $recovery_dir" >&2
      exit 2
      ;;
  esac
  child_name="${recovery_dir#"$output_root"/}"
  if [[ "$child_name" == */* ]]; then
    echo "Recovery export directory must be an immediate child of $output_root: $recovery_dir" >&2
    exit 2
  fi
  reject_symlinked_path_components "Recovery export directory" "$recovery_dir"
  if [[ ! -d "$recovery_dir" || -L "$recovery_dir" ]]; then
    echo "Recovery export directory must be a real directory: $recovery_dir" >&2
    exit 2
  fi
  current_uid="$(id -u)"
  if ! stat_output="$(stat -Lc '%u %a' -- "$recovery_dir" 2>/dev/null)"; then
    echo "Could not inspect recovery export directory owner and permissions: $recovery_dir" >&2
    exit 2
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    echo "Recovery export directory is owned by uid ${owner_uid}, expected current user ${current_uid}: $recovery_dir" >&2
    exit 2
  fi
  if [[ "$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')" != "700" ]]; then
    echo "Recovery export directory has permissions ${mode}, expected private 0700: $recovery_dir" >&2
    exit 2
  fi
}

create_private_recovery_output_capture() {
  local directory="$1"
  local status
  set +e
  "$python3_cmd" - "$directory" <<'PY'
from __future__ import annotations

import os
import stat
import sys
import tempfile
from pathlib import Path

directory = Path(sys.argv[1])


def sync_private_capture_directory(path: Path) -> None:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        print(f"Could not inspect recovery output capture directory before sync {path}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    if not stat.S_ISDIR(before.st_mode):
        print(f"Recovery output capture directory must be a real directory: {path}", file=sys.stderr)
        raise SystemExit(124)
    if before.st_uid != os.getuid():
        print(
            f"Recovery output capture directory is owned by uid {before.st_uid}, expected current user {os.getuid()}: {path}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o700:
        print(f"Recovery output capture directory has permissions {mode:04o}, expected private 0700: {path}", file=sys.stderr)
        raise SystemExit(124)
    try:
        directory_fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
    except OSError as exc:
        print(f"Could not open recovery output capture directory for sync {path}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    try:
        opened = os.fstat(directory_fd)
        if not os.path.samestat(before, opened):
            print(f"Recovery output capture directory changed before sync: {path}", file=sys.stderr)
            raise SystemExit(124)
        os.fsync(directory_fd)
    except OSError as exc:
        print(f"Could not sync recovery output capture directory {path}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    finally:
        os.close(directory_fd)


try:
    fd, path = tempfile.mkstemp(
        prefix=".noaa-navionics-pre-trip-recovery-output-",
        dir=directory,
        text=True,
    )
except OSError as exc:
    print(f"Could not create private recovery output capture in {directory}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc

try:
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        print(f"Recovery output capture must be a regular file: {path}", file=sys.stderr)
        raise SystemExit(124)
    if opened.st_uid != os.getuid():
        print(
            f"Recovery output capture is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        print(f"Recovery output capture has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
        raise SystemExit(124)
finally:
    os.close(fd)

sync_private_capture_directory(directory)
print(path)
PY
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

capture_recovery_output() {
  local path="$1"
  local status
  set +e
  "$python3_cmd" -c '
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
flags = os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)

try:
    before = os.stat(path, follow_symlinks=False)
    fd = os.open(path, flags)
except OSError as exc:
    print(f"Could not open recovery output capture for writing {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc

try:
    opened = os.fstat(fd)
    if before.st_dev != opened.st_dev or before.st_ino != opened.st_ino:
        print(f"Recovery output capture changed while opening it: {path}", file=sys.stderr)
        raise SystemExit(124)
    if not stat.S_ISREG(opened.st_mode):
        print(f"Recovery output capture must be a regular file: {path}", file=sys.stderr)
        raise SystemExit(124)
    if opened.st_uid != os.getuid():
        print(
            f"Recovery output capture is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        print(f"Recovery output capture has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
        raise SystemExit(124)
    with os.fdopen(fd, "wb") as capture:
        fd = -1
        while True:
            chunk = sys.stdin.buffer.read(65536)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            capture.write(chunk)
        capture.flush()
        os.fsync(capture.fileno())
except OSError as exc:
    print(f"Could not write recovery output capture {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
finally:
    if fd >= 0:
        os.close(fd)
' "$path"
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

extract_recovery_dir_from_output() {
  local path="$1"
  local status
  set +e
  "$python3_cmd" - "$path" <<'PY'
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
prefix = "Pi recovery exports written to: "
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)

try:
    before = os.stat(path, follow_symlinks=False)
    fd = os.open(path, flags)
except OSError as exc:
    print(f"Could not open recovery output capture for parsing {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc

try:
    opened = os.fstat(fd)
    if before.st_dev != opened.st_dev or before.st_ino != opened.st_ino:
        print(f"Recovery output capture changed while opening it: {path}", file=sys.stderr)
        raise SystemExit(124)
    if not stat.S_ISREG(opened.st_mode):
        print(f"Recovery output capture must be a regular file: {path}", file=sys.stderr)
        raise SystemExit(124)
    if opened.st_uid != os.getuid():
        print(
            f"Recovery output capture is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        print(f"Recovery output capture has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
        raise SystemExit(124)
    with os.fdopen(fd, "r", encoding="utf-8", errors="replace") as handle:
        fd = -1
        matches = [line[len(prefix):].strip() for line in handle if line.startswith(prefix)]
except OSError as exc:
    print(f"Could not parse recovery output capture {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
finally:
    if fd >= 0:
        os.close(fd)

if matches:
    print(matches[-1])
PY
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

cleanup_private_recovery_output_capture() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  "$python3_cmd" - "$path" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
nofollow = getattr(os, "O_NOFOLLOW", 0)

try:
    before = os.stat(path, follow_symlinks=False)
except FileNotFoundError:
    raise SystemExit(0)
except OSError as exc:
    print(f"Could not inspect recovery output capture for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600:
    print(f"Recovery output capture is not a trusted private file; leaving it in place: {path}", file=sys.stderr)
    raise SystemExit(0)

try:
    dir_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
except OSError as exc:
    print(f"Could not open recovery output capture directory for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)
try:
    try:
        fd = os.open(path.name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
    except FileNotFoundError:
        raise SystemExit(0)
    try:
        opened = os.fstat(fd)
    finally:
        os.close(fd)
    if not os.path.samestat(before, opened):
        print(f"Recovery output capture changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    os.unlink(path.name, dir_fd=dir_fd)
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
}

validate_ssh_target() {
  local value="$1"
  local user_part
  local host_part
  local host_lower

  if [[ -z "$value" ]]; then
    echo "SSH target is required" >&2
    exit 2
  fi
  if [[ "$value" == -* ]]; then
    echo "SSH target must not begin with '-': $value" >&2
    exit 2
  fi
  if [[ "$value" =~ [[:space:]\"\'] ]]; then
    echo "SSH target must not contain whitespace or quotes: $value" >&2
    exit 2
  fi
  if [[ "$value" != *@* ]]; then
    echo "SSH target must be user@host: $value" >&2
    exit 2
  fi
  user_part="${value%@*}"
  host_part="${value#*@}"
  if [[ -z "$user_part" || -z "$host_part" ]]; then
    echo "SSH target must be user@host: $value" >&2
    exit 2
  fi
  if [[ ! "$user_part" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]; then
    echo "SSH target user contains unsafe characters: $user_part" >&2
    exit 2
  fi
  if [[ "$host_part" == *:* || "$host_part" == */* ]]; then
    echo "SSH target must be plain user@host without paths or ports: $value" >&2
    exit 2
  fi
  if [[ ! "$host_part" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    echo "SSH target host contains unsafe characters: $host_part" >&2
    exit 2
  fi
  host_lower="${host_part,,}"
  case "$host_lower" in
    localhost|localhost.localdomain|*.localhost|ip6-localhost|ip6-loopback|loopback|127.*|0|0.0.0.0)
      echo "SSH target must not point at this computer or loopback: $host_part" >&2
      exit 2
      ;;
  esac
  if [[ "$user_part" == "root" ]]; then
    cat >&2 <<'EOF'
Do not run pre-trip preparation as root@.
Use the Pi desktop user so charts, GPX tracks, OpenCPN data, and status checks match the helm account.
EOF
    exit 2
  fi
}

require_helper() {
  local path="$1"

  if [[ -L "$path" ]]; then
    echo "Helper script must not be a symlink: $path" >&2
    exit 2
  fi
  reject_symlinked_path_components "Helper script" "$path"
  if [[ ! -f "$path" || ! -x "$path" ]]; then
    echo "Helper script is missing or not executable: $path" >&2
    exit 2
  fi
  if ! "$python3_cmd" - "$path" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
nofollow = getattr(os, "O_NOFOLLOW", 0)
try:
    before = os.stat(path, follow_symlinks=False)
except OSError as exc:
    print(f"Could not inspect helper script owner and permissions: {path}: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
if stat.S_ISLNK(before.st_mode):
    print(f"Helper script must not be a symlink: {path}", file=sys.stderr)
    raise SystemExit(1)
if not stat.S_ISREG(before.st_mode):
    print(f"Helper script is not a regular file: {path}", file=sys.stderr)
    raise SystemExit(1)
if before.st_uid != os.getuid():
    print(f"Helper script is owned by uid {before.st_uid}, expected current user {os.getuid()}: {path}", file=sys.stderr)
    raise SystemExit(1)
mode = stat.S_IMODE(before.st_mode)
if mode & 0o022:
    print(f"Helper script has permissions {mode:03o}, expected no group/other write bits: {path}", file=sys.stderr)
    raise SystemExit(1)
if not mode & 0o111:
    print(f"Helper script is not executable: {path}", file=sys.stderr)
    raise SystemExit(1)
try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except OSError as exc:
    print(f"Could not open helper script through no-follow descriptor: {path}: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        print(f"Helper script changed before it could be validated: {path}", file=sys.stderr)
        raise SystemExit(1)
    if not stat.S_ISREG(opened.st_mode):
        print(f"Helper script is not a regular file when opened: {path}", file=sys.stderr)
        raise SystemExit(1)
    if opened.st_uid != os.getuid():
        print(f"Helper script is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}", file=sys.stderr)
        raise SystemExit(1)
    opened_mode = stat.S_IMODE(opened.st_mode)
    if opened_mode & 0o022:
        print(f"Helper script has permissions {opened_mode:03o}, expected no group/other write bits: {path}", file=sys.stderr)
        raise SystemExit(1)
    if not opened_mode & 0o111:
        print(f"Helper script is not executable when opened: {path}", file=sys.stderr)
        raise SystemExit(1)
finally:
    os.close(fd)
PY
  then
    exit 2
  fi
}

run_step() {
  local label="$1"
  local command_path
  shift
  command_path="$1"
  shift
  require_helper "$command_path"
  printf '==> %s\n' "$label"
  "$command_path" "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      validate_gps_device_path_arg "${2:-}"
      device="${2:-}"
      shift 2
      ;;
    --output-dir)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      validate_output_dir_arg "${2:-}"
      output_dir="${2:-}"
      shift 2
      ;;
    --track-days)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      track_days="${2:-}"
      shift 2
      ;;
    --gps-seconds)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_integer "$1" "${2:-}"
      gps_seconds="${2:-}"
      shift 2
      ;;
    --retries)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_integer "$1" "${2:-}"
      retries="${2:-}"
      shift 2
      ;;
    --retry-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      retry_delay="${2:-}"
      shift 2
      ;;
    --force-refresh)
      force_refresh=1
      shift
      ;;
    --allow-dirty)
      allow_dirty=1
      shift
      ;;
    --opencpn-restarts)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      opencpn_restarts="${2:-}"
      shift 2
      ;;
    --opencpn-restart-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      opencpn_restart_delay="${2:-}"
      shift 2
      ;;
    --skip-refresh)
      skip_refresh=1
      shift
      ;;
    --skip-recovery)
      skip_recovery=1
      shift
      ;;
    --skip-pre-departure)
      skip_pre_departure=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

validate_ssh_target "$target"
if [[ -z "$device" && "$skip_pre_departure" -eq 0 ]]; then
  echo "--device is required unless --skip-pre-departure is used" >&2
  echo "Use the commissioned path from the Pi, usually reported by: noaa-navionics list-gps-devices" >&2
  exit 2
fi
validate_output_dir_arg "$output_dir"
output_dir="$(strip_trailing_slashes "$output_dir")"

if [[ "$skip_refresh" -eq 1 && "$skip_recovery" -eq 1 && "$skip_pre_departure" -eq 1 ]]; then
  echo "At least one pre-trip preparation step must run" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
refresh_helper="${repo_root}/scripts/refresh_pi_charts.sh"
recovery_helper="${repo_root}/scripts/export_pi_recovery_bundle.sh"
verify_recovery_helper="${repo_root}/scripts/verify_pi_recovery_exports.sh"
pre_departure_helper="${repo_root}/scripts/pre_departure_check_pi.sh"
python3_cmd="$(require_local_command python3)"
require_helper "$refresh_helper"
require_helper "$recovery_helper"
require_helper "$verify_recovery_helper"
require_helper "$pre_departure_helper"

if [[ "$skip_refresh" -eq 0 ]]; then
  refresh_args=("$target" --retries "$retries" --retry-delay "$retry_delay" --status)
  if [[ -n "$gps_seconds" ]]; then
    refresh_args+=(--gps-seconds "$gps_seconds")
  fi
  if [[ "$force_refresh" -eq 1 ]]; then
    refresh_args+=(--force)
  fi
  run_step "Refreshing Pi NOAA charts and status" "$refresh_helper" "${refresh_args[@]}"
else
  printf '==> Skipping Pi NOAA chart refresh\n'
fi

if [[ "$skip_recovery" -eq 0 ]]; then
  prepare_private_output_dir "Recovery output directory" "$output_dir"
  recovery_output="$(create_private_recovery_output_capture "$output_dir")"
  cleanup_recovery_output() {
    cleanup_private_recovery_output_capture "${recovery_output:-}" || true
  }
  trap cleanup_recovery_output EXIT
  run_step "Exporting Pi recovery bundle" "$recovery_helper" "$target" "$output_dir" --track-days "$track_days" | capture_recovery_output "$recovery_output"
  recovery_dir="$(extract_recovery_dir_from_output "$recovery_output")"
  if [[ -z "$recovery_dir" ]]; then
    echo "Could not determine recovery export directory from export output" >&2
    exit 1
  fi
  require_recovery_dir_from_output "$recovery_dir" "$output_dir"
  run_step "Verifying Pi recovery export archives" "$verify_recovery_helper" "$recovery_dir"
else
  printf '==> Skipping Pi recovery export\n'
fi

if [[ "$skip_pre_departure" -eq 0 ]]; then
  pre_departure_args=("$target" --device "$device")
  if [[ -n "$gps_seconds" ]]; then
    pre_departure_args+=(--gps-seconds "$gps_seconds")
  fi
  if [[ "$allow_dirty" -eq 1 ]]; then
    pre_departure_args+=(--allow-dirty)
  fi
  if [[ -n "$opencpn_restarts" ]]; then
    pre_departure_args+=(--opencpn-restarts "$opencpn_restarts")
  fi
  if [[ -n "$opencpn_restart_delay" ]]; then
    pre_departure_args+=(--opencpn-restart-delay "$opencpn_restart_delay")
  fi
  run_step "Running live pre-departure check" "$pre_departure_helper" "${pre_departure_args[@]}"
else
  printf '==> Skipping live pre-departure check\n'
fi

printf '\nPre-trip Pi preparation completed for %s.\n' "$target"
