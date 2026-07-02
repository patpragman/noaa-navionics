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
  --track-days N      Export GPX tracks modified in the last N days; 0 exports all (default: 30, max: 3650)
  --gps-seconds N     Override commissioned GPS wait for status/pre-departure
                      checks (1-600)
  --retries N         Chart download attempts on the Pi (default: 5, max: 20)
  --retry-delay N     Seconds between chart download retry attempts
                      (default: 30, max: 3600)
  --force-refresh     Force a NOAA chart redownload on the Pi
  --allow-dirty       Allow verifying a deliberate dirty test deployment
  --opencpn-restarts N
                     Expected OpenCPN nonzero-exit restart attempts after boot (0-20)
  --opencpn-restart-delay N
                     Expected seconds between OpenCPN restart attempts (0-3600)
  --skip-refresh      Skip the chart refresh and post-refresh status report
  --skip-recovery     Skip recovery export and local export verification
  --skip-pre-departure
                     Skip the live strict pre-departure verification

Options for skipped steps are rejected so refresh, recovery, GPS-device, and
pre-departure controls cannot be mistaken for checks that still ran.
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
device_set=0
output_dir="pi-recovery-exports"
output_dir_set=0
track_days=30
track_days_set=0
max_track_days=3650
gps_seconds=""
gps_seconds_set=0
max_gps_seconds=600
retries=5
retries_set=0
max_retries=20
retry_delay=30
retry_delay_set=0
max_retry_delay=3600
force_refresh=0
allow_dirty=0
allow_dirty_set=0
skip_refresh=0
skip_recovery=0
skip_pre_departure=0
opencpn_restarts=""
opencpn_restarts_set=0
max_opencpn_restarts=20
opencpn_restart_delay=""
opencpn_restart_delay_set=0
max_opencpn_restart_delay=3600
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

integer_greater_than() {
  local value
  local maximum
  value="$(normalize_decimal_integer "$1")"
  maximum="$(normalize_decimal_integer "$2")"
  if (( ${#value} > ${#maximum} )); then
    return 0
  fi
  if (( ${#value} == ${#maximum} )) && [[ "$value" > "$maximum" ]]; then
    return 0
  fi
  return 1
}

normalize_decimal_integer() {
  local value="$1"
  value="${value#"${value%%[!0]*}"}"
  printf '%s\n' "${value:-0}"
}

require_integer_at_most() {
  local name="$1"
  local value="$2"
  local maximum="$3"
  if integer_greater_than "$value" "$maximum"; then
    echo "$name must be at most ${maximum}" >&2
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
  if [[ ! -f "$resolved_path" ]]; then
    echo "Local ${command_name} command is not a regular file after resolution: $command_path -> $resolved_path" >&2
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
    /dev/serial/by-id/*|/dev/serial/by-path/*)
      suffix="${value#/dev/serial/by-id/}"
      suffix="${suffix#/dev/serial/by-path/}"
      if [[ -n "$suffix" && "$suffix" != */* && "$suffix" != "." && "$suffix" != ".." && "$suffix" =~ ^[A-Za-z0-9._:+@-]+$ ]]; then
        return 0
      fi
      ;;
    /dev/serial0|/dev/serial1|/dev/gps)
      return 0
      ;;
    /dev/ttyUSB*|/dev/ttyACM*)
      echo "GPS device path is volatile; use /dev/serial/by-id/... or /dev/serial/by-path/... instead: $value" >&2
      exit 2
      ;;
  esac
  echo "GPS device path must be /dev/serial/by-id/..., /dev/serial/by-path/..., /dev/serial0, /dev/serial1, or /dev/gps: $value" >&2
  exit 2
}

validate_output_dir_arg() {
  local value="$1"
  value="$(strip_trailing_slashes "$value")"
  if [[ -z "$value" ]]; then
    echo "Output directory is required" >&2
    exit 2
  fi
  if [[ "$value" =~ [\"\'] ]]; then
    echo "Output directory must not contain quotes: $value" >&2
    exit 2
  fi
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    echo "Output directory must not contain control characters" >&2
    exit 2
  fi
  case "$value" in
    ..|../*|*/..|*/../*)
      echo "Output directory must not contain parent-directory components: $value" >&2
      exit 2
      ;;
  esac
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
  local local_hostname_file
  local local_hostname
  local local_hostname_lower
  local local_hostname_short

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
  for local_hostname_file in /proc/sys/kernel/hostname /etc/hostname; do
    if [[ ! -r "$local_hostname_file" ]]; then
      continue
    fi
    IFS= read -r local_hostname <"$local_hostname_file" || local_hostname=""
    local_hostname="${local_hostname%%[[:space:]]*}"
    if [[ -z "$local_hostname" ]]; then
      continue
    fi
    local_hostname_lower="${local_hostname,,}"
    local_hostname_short="${local_hostname_lower%%.*}"
    case "$host_lower" in
      "$local_hostname_lower"|"$local_hostname_short"|"$local_hostname_short.local")
        echo "SSH target must not point at this computer or loopback: $host_part" >&2
        exit 2
        ;;
    esac
  done
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
  local status
  shift
  command_path="$1"
  shift
  require_helper "$command_path"
  printf '==> %s\n' "$label"
  set +e
  "$python3_cmd" - "$command_path" "$@" <<'PY'
from pathlib import Path
import os
import stat
import subprocess
import sys

path = Path(sys.argv[1])
args = sys.argv[2:]
nofollow = getattr(os, "O_NOFOLLOW", 0)


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(124)


if not path.is_absolute():
    fail(f"Helper script path must be absolute before descriptor execution: {path}")

current = Path("/")
for part in path.parts[1:]:
    if part in {"", "."}:
        continue
    current = current / part
    try:
        component = os.lstat(current)
    except OSError as exc:
        fail(f"Could not inspect helper script path component before descriptor execution {current}: {exc}")
    if stat.S_ISLNK(component.st_mode):
        fail(f"Helper script path contains a symlink before descriptor execution: {current}")

try:
    before = os.stat(path, follow_symlinks=False)
except OSError as exc:
    fail(f"Could not inspect helper script before descriptor execution: {path}: {exc}")
if not stat.S_ISREG(before.st_mode):
    fail(f"Helper script must be regular before descriptor execution: {path}")
if before.st_uid != os.getuid():
    fail(f"Helper script is owned by uid {before.st_uid}, expected current user {os.getuid()}: {path}")
mode = stat.S_IMODE(before.st_mode)
if mode & 0o022:
    fail(f"Helper script has permissions {mode:03o}, expected no group/other write bits: {path}")
if not mode & 0o111:
    fail(f"Helper script is not executable before descriptor execution: {path}")

try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except OSError as exc:
    fail(f"Could not open helper script through no-follow descriptor for execution: {path}: {exc}")
try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        fail(f"Helper script changed before descriptor execution: {path}")
    if not stat.S_ISREG(opened.st_mode):
        fail(f"Helper script must be regular when opened for descriptor execution: {path}")
    if opened.st_uid != os.getuid():
        fail(f"Helper script is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}")
    opened_mode = stat.S_IMODE(opened.st_mode)
    if opened_mode & 0o022:
        fail(f"Helper script has permissions {opened_mode:03o}, expected no group/other write bits: {path}")
    if not opened_mode & 0o111:
        fail(f"Helper script is not executable when opened for descriptor execution: {path}")
    try:
        result = subprocess.run([f"/proc/self/fd/{fd}", *args], pass_fds=(fd,))
    except OSError as exc:
        fail(f"Could not execute helper script through validated descriptor: {path}: {exc}")
finally:
    os.close(fd)
raise SystemExit(result.returncode)
PY
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

save_pre_departure_status_snapshot() {
  local directory="$1"
  local command_path="$2"
  local status
  shift 2
  require_helper "$command_path"
  printf '==> Saving local pre-departure status snapshot\n'
  set +e
  "$python3_cmd" - "$command_path" "$directory" "$@" <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import tempfile

path = Path(sys.argv[1])
directory = Path(sys.argv[2])
args = sys.argv[3:]
status_name = "pre-departure-status.json"
checksum_name = "pre-departure-status.sha256"
nofollow = getattr(os, "O_NOFOLLOW", 0)
BOOT_ID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
STATUS_MAX_AGE_SECONDS = 15 * 60
STATUS_FUTURE_TOLERANCE_SECONDS = 5 * 60
GPS_BAUD_RATES = {4800, 9600, 19200, 38400, 57600, 115200}
CORE_READINESS_CHECKS = {
    "Python",
    "Source Revision",
    "Clock",
    "Time Sync",
    "Tkinter",
    "OpenCPN",
    "Display Power",
    "Chart Package",
    "Charts",
    "Chart Update Debris",
    "Manifest",
    "OpenCPN Charts",
    "Disk",
    "Pi Power",
    "Pi Thermal",
}
GPSD_READINESS_CHECKS = {
    "OpenCPN GPSD",
    "GPSD Config",
    "Chrony Config",
    "GPSD",
    "GPS Time Source",
}
SERIAL_READINESS_CHECKS = {"GPS Device", "GPS"}
PI_ONLY_READINESS_CHECKS = {
    "Source Revision",
    "Time Sync",
    "Pi Power",
    "Pi Thermal",
    "Chrony Config",
    "GPS Time Source",
}
CORE_SERVICE_CHECKS = {
    "Chart Sync",
    "Chart Sync Settings",
    "Chart Sync Unit File",
    "Chart Timer",
    "Chart Timer Install",
    "Chart Timer Settings",
    "Chart Timer Unit File",
    "Track Log",
    "Track Logger",
    "Track Logger Install",
    "Track Logger Settings",
    "Track Logger Unit File",
    "Boot Readiness",
    "Boot Readiness Install",
    "Boot Readiness Settings",
    "Boot Readiness Unit File",
    "Boot Readiness Run",
    "Desktop Startup",
    "Launcher Settings",
    "User Linger",
}
GPSD_SERVICE_CHECKS = {"GPSD Socket", "GPSD Service", "Chrony Service"}
EXPECTED_DESKTOP_AUTOSTART_VALUES = {
    "Type": "Application",
    "Name": "NOAA Navionics Chartplotter",
    "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
    "Terminal": "false",
    "X-GNOME-Autostart-enabled": "true",
}
EXPECTED_MOB_LAUNCHER_VALUES = {
    "Type": "Application",
    "Name": "NOAA Navionics MOB",
    "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics mob; printf \'\\nPress Enter to close...\'; read _"',
    "Terminal": "true",
}
EXPECTED_STATUS_LAUNCHER_VALUES = {
    "Type": "Application",
    "Name": "NOAA Navionics Status",
    "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-status-gui"',
    "Terminal": "false",
}


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(124)


def finite_status_float(value: object):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    parsed = float(value)
    return parsed if math.isfinite(parsed) else None


def positive_status_int(value: object):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return None
    return value


def snapshot_text(value: object, label: str) -> str:
    if not isinstance(value, str):
        fail(f"pre-departure status snapshot JSON {label} is not a string")
    text = str(value)
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        fail(f"pre-departure status snapshot JSON {label} contains control characters")
    return text.strip()


def snapshot_absolute_path(value: object, label: str) -> str:
    text = snapshot_text(value, label)
    if not text or not Path(text).is_absolute():
        fail(f"pre-departure status snapshot JSON {label} is not absolute")
    return text


SNAPSHOT_STATIC_DIAGNOSTICS = (
    "pre-departure status snapshot JSON config_path is not absolute",
    "pre-departure status snapshot JSON config chart_output is not absolute",
    "pre-departure status snapshot JSON config track_output is not absolute",
    "pre-departure status snapshot JSON track_log track_output is not absolute",
    "pre-departure status snapshot JSON track_log tracks_dir is not absolute",
    "pre-departure status snapshot JSON track_log latest_path is not absolute",
    "pre-departure status snapshot JSON Manifest path is not absolute",
    "pre-departure status snapshot JSON Manifest download path is not absolute",
    "pre-departure status snapshot JSON Manifest extract path is not absolute",
    "pre-departure status snapshot JSON Charts ENC cell sample path is not absolute",
    "pre-departure status snapshot JSON OpenCPN Charts chart directory is not absolute",
    "pre-departure status snapshot JSON OpenCPN Charts config path is not absolute",
    "pre-departure status snapshot JSON OpenCPN GPSD config path is not absolute",
)


def stable_snapshot_gps_device_path(path: str) -> bool:
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:+@-"
    for prefix in ("/dev/serial/by-id/", "/dev/serial/by-path/"):
        if path.startswith(prefix):
            suffix = path[len(prefix) :]
            return bool(suffix) and "/" not in suffix and suffix not in {".", ".."} and all(
                char in allowed for char in suffix
            )
    return path in {"/dev/serial0", "/dev/serial1", "/dev/gps"}


def parse_snapshot_timestamp(value: object, field: str) -> datetime:
    if not isinstance(value, str) or not value.strip():
        fail(f"pre-departure status snapshot JSON {field} timestamp is missing")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"pre-departure status snapshot JSON {field} timestamp is invalid: {exc}")
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        fail(f"pre-departure status snapshot JSON {field} timestamp must include a timezone")
    return parsed.astimezone(timezone.utc)


def validate_snapshot_age(value: object, *, timestamp: datetime, generated_at: datetime, field: str) -> None:
    reported_age = finite_status_float(value)
    if reported_age is None:
        fail(f"pre-departure status snapshot JSON {field} age_seconds is not numeric")
    if reported_age < 0:
        fail(f"pre-departure status snapshot JSON {field} age_seconds is negative")
    if reported_age > 600:
        fail(f"pre-departure status snapshot JSON {field} age_seconds is stale")
    timestamp_age = (generated_at - timestamp).total_seconds()
    if timestamp_age < -STATUS_FUTURE_TOLERANCE_SECONDS:
        fail(f"pre-departure status snapshot JSON {field} timestamp is after generated_at")
    if abs(reported_age - timestamp_age) > STATUS_FUTURE_TOLERANCE_SECONDS:
        fail(f"pre-departure status snapshot JSON {field} age_seconds is inconsistent with timestamp age")


def validate_snapshot_quality(summary: dict[str, object], *, satellite_field: str, hdop_field: str, label: str) -> None:
    satellites = summary.get(satellite_field)
    hdop = summary.get(hdop_field)
    if satellites is None and hdop is None:
        fail(f"pre-departure status snapshot JSON {label} has no satellite or HDOP quality fields")
    if satellites is not None and (
        isinstance(satellites, bool) or not isinstance(satellites, int) or satellites < 4
    ):
        fail(f"pre-departure status snapshot JSON {label} satellites is weak or invalid")
    parsed_hdop = finite_status_float(hdop)
    if hdop is not None and (parsed_hdop is None or parsed_hdop < 0.0 or parsed_hdop > 5.0):
        fail(f"pre-departure status snapshot JSON {label} HDOP is weak or invalid")


def private_octal_mode(value: object, *, field: str) -> int:
    if not isinstance(value, str):
        fail(f"pre-departure status snapshot JSON track_log {field} is missing or invalid")
    text = value.strip()
    if not text:
        fail(f"pre-departure status snapshot JSON track_log {field} is missing or invalid")
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        fail(f"pre-departure status snapshot JSON track_log {field} is missing or invalid")
    try:
        mode = int(text, 8)
    except ValueError:
        fail(f"pre-departure status snapshot JSON track_log {field} is missing or invalid")
    if mode < 0 or mode > 0o7777:
        fail(f"pre-departure status snapshot JSON track_log {field} is missing or invalid")
    if mode & 0o077:
        fail(f"pre-departure status snapshot JSON track_log {field} is not private")
    return mode


def snapshot_octal_mode(value: object, *, label: str) -> int:
    if not isinstance(value, str):
        fail(f"pre-departure status snapshot JSON {label} mode is invalid")
    text = value.strip()
    if not text:
        fail(f"pre-departure status snapshot JSON {label} mode is invalid")
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        fail(f"pre-departure status snapshot JSON {label} mode is invalid")
    try:
        mode = int(text, 8)
    except ValueError:
        fail(f"pre-departure status snapshot JSON {label} mode is invalid")
    if mode < 0 or mode > 0o7777:
        fail(f"pre-departure status snapshot JSON {label} mode is invalid")
    return mode


def snapshot_uid(value: object, *, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail(f"pre-departure status snapshot JSON {label} owner is invalid")
    return value


def validate_snapshot_autostart(payload: dict[str, object]) -> None:
    desktop = payload.get("desktop")
    if not isinstance(desktop, dict):
        fail("pre-departure status snapshot JSON missing desktop section")
    autostart = desktop.get("autostart")
    if not isinstance(autostart, dict):
        fail("pre-departure status snapshot JSON missing desktop autostart evidence")
    autostart_path = snapshot_text(autostart.get("path", ""), "desktop autostart path")
    if not autostart_path or not Path(autostart_path).is_absolute():
        fail("pre-departure status snapshot JSON desktop autostart path is not absolute")
    if Path(autostart_path).name != "noaa-navionics-chartplotter.desktop":
        fail("pre-departure status snapshot JSON desktop autostart path has unexpected filename")
    if autostart.get("exists") is not True:
        fail("pre-departure status snapshot JSON desktop autostart does not exist")
    if autostart.get("is_symlink") is not False:
        fail("pre-departure status snapshot JSON desktop autostart path is a symlink or missing symlink status")
    if autostart.get("directory_is_symlink") is not False:
        fail("pre-departure status snapshot JSON desktop autostart directory is a symlink or missing symlink status")
    if "path_symlink_component" not in autostart:
        fail("pre-departure status snapshot JSON desktop autostart missing path_symlink_component")
    if snapshot_text(autostart.get("path_symlink_component", ""), "desktop autostart path_symlink_component"):
        fail("pre-departure status snapshot JSON desktop autostart path contains a symlink")
    snapshot_uid(autostart.get("uid"), label="desktop autostart")
    snapshot_uid(autostart.get("directory_uid"), label="desktop autostart directory")
    mode = snapshot_octal_mode(autostart.get("mode"), label="desktop autostart")
    if mode & 0o022:
        fail("pre-departure status snapshot JSON desktop autostart is group/world writable")
    directory_mode = snapshot_octal_mode(
        autostart.get("directory_mode"),
        label="desktop autostart directory",
    )
    if directory_mode & 0o022:
        fail("pre-departure status snapshot JSON desktop autostart directory is group/world writable")
    values = autostart.get("values")
    if not isinstance(values, dict):
        fail("pre-departure status snapshot JSON desktop autostart values were not parsed")
    for key, expected in EXPECTED_DESKTOP_AUTOSTART_VALUES.items():
        actual = str(values.get(key, "")).strip()
        if actual != expected:
            fail(f"pre-departure status snapshot JSON desktop autostart {key} does not match expected value")
    if str(values.get("Hidden", "")).strip().lower() == "true":
        fail("pre-departure status snapshot JSON desktop autostart is hidden")


def validate_snapshot_mob_launcher(payload: dict[str, object]) -> None:
    desktop = payload.get("desktop")
    if not isinstance(desktop, dict):
        fail("pre-departure status snapshot JSON missing desktop section")
    mob_launcher = desktop.get("mob_launcher")
    if not isinstance(mob_launcher, dict):
        fail("pre-departure status snapshot JSON missing MOB desktop launcher evidence")
    launcher_path = snapshot_text(mob_launcher.get("path", ""), "MOB desktop launcher path")
    if not launcher_path or not Path(launcher_path).is_absolute():
        fail("pre-departure status snapshot JSON MOB desktop launcher path is not absolute")
    if Path(launcher_path).name != "noaa-navionics-mob.desktop":
        fail("pre-departure status snapshot JSON MOB desktop launcher path has unexpected filename")
    if mob_launcher.get("exists") is not True:
        fail("pre-departure status snapshot JSON MOB desktop launcher does not exist")
    if mob_launcher.get("is_symlink") is not False:
        fail("pre-departure status snapshot JSON MOB desktop launcher path is a symlink or missing symlink status")
    if mob_launcher.get("directory_is_symlink") is not False:
        fail("pre-departure status snapshot JSON MOB desktop launcher directory is a symlink or missing symlink status")
    if "path_symlink_component" not in mob_launcher:
        fail("pre-departure status snapshot JSON MOB desktop launcher missing path_symlink_component")
    if snapshot_text(mob_launcher.get("path_symlink_component", ""), "MOB desktop launcher path_symlink_component"):
        fail("pre-departure status snapshot JSON MOB desktop launcher path contains a symlink")
    snapshot_uid(mob_launcher.get("uid"), label="MOB desktop launcher")
    snapshot_uid(mob_launcher.get("directory_uid"), label="MOB desktop launcher directory")
    mode = snapshot_octal_mode(mob_launcher.get("mode"), label="MOB desktop launcher")
    if mode & 0o022:
        fail("pre-departure status snapshot JSON MOB desktop launcher is group/world writable")
    if not mode & 0o100:
        fail("pre-departure status snapshot JSON MOB desktop launcher is not user executable")
    directory_mode = snapshot_octal_mode(
        mob_launcher.get("directory_mode"),
        label="MOB desktop launcher directory",
    )
    if directory_mode & 0o022:
        fail("pre-departure status snapshot JSON MOB desktop launcher directory is group/world writable")
    values = mob_launcher.get("values")
    if not isinstance(values, dict):
        fail("pre-departure status snapshot JSON MOB desktop launcher values were not parsed")
    for key, expected in EXPECTED_MOB_LAUNCHER_VALUES.items():
        actual = str(values.get(key, "")).strip()
        if actual != expected:
            fail(f"pre-departure status snapshot JSON MOB desktop launcher {key} does not match expected value")
    if str(values.get("Hidden", "")).strip().lower() == "true":
        fail("pre-departure status snapshot JSON MOB desktop launcher is hidden")
    if str(values.get("X-GNOME-Autostart-enabled", "")).strip().lower() == "true":
        fail("pre-departure status snapshot JSON MOB desktop launcher must not be configured for autostart")


def validate_snapshot_status_launcher(payload: dict[str, object]) -> None:
    desktop = payload.get("desktop")
    if not isinstance(desktop, dict):
        fail("pre-departure status snapshot JSON missing desktop section")
    status_launcher = desktop.get("status_launcher")
    if not isinstance(status_launcher, dict):
        fail("pre-departure status snapshot JSON missing status GUI desktop launcher evidence")
    launcher_path = snapshot_text(status_launcher.get("path", ""), "status GUI desktop launcher path")
    if not launcher_path or not Path(launcher_path).is_absolute():
        fail("pre-departure status snapshot JSON status GUI desktop launcher path is not absolute")
    if Path(launcher_path).name != "noaa-navionics-status.desktop":
        fail("pre-departure status snapshot JSON status GUI desktop launcher path has unexpected filename")
    if status_launcher.get("exists") is not True:
        fail("pre-departure status snapshot JSON status GUI desktop launcher does not exist")
    if status_launcher.get("is_symlink") is not False:
        fail("pre-departure status snapshot JSON status GUI desktop launcher path is a symlink or missing symlink status")
    if status_launcher.get("directory_is_symlink") is not False:
        fail("pre-departure status snapshot JSON status GUI desktop launcher directory is a symlink or missing symlink status")
    if "path_symlink_component" not in status_launcher:
        fail("pre-departure status snapshot JSON status GUI desktop launcher missing path_symlink_component")
    if snapshot_text(status_launcher.get("path_symlink_component", ""), "status GUI desktop launcher path_symlink_component"):
        fail("pre-departure status snapshot JSON status GUI desktop launcher path contains a symlink")
    snapshot_uid(status_launcher.get("uid"), label="status GUI desktop launcher")
    snapshot_uid(status_launcher.get("directory_uid"), label="status GUI desktop launcher directory")
    mode = snapshot_octal_mode(status_launcher.get("mode"), label="status GUI desktop launcher")
    if mode & 0o022:
        fail("pre-departure status snapshot JSON status GUI desktop launcher is group/world writable")
    if not mode & 0o100:
        fail("pre-departure status snapshot JSON status GUI desktop launcher is not user executable")
    directory_mode = snapshot_octal_mode(
        status_launcher.get("directory_mode"),
        label="status GUI desktop launcher directory",
    )
    if directory_mode & 0o022:
        fail("pre-departure status snapshot JSON status GUI desktop launcher directory is group/world writable")
    values = status_launcher.get("values")
    if not isinstance(values, dict):
        fail("pre-departure status snapshot JSON status GUI desktop launcher values were not parsed")
    for key, expected in EXPECTED_STATUS_LAUNCHER_VALUES.items():
        actual = str(values.get(key, "")).strip()
        if actual != expected:
            fail(f"pre-departure status snapshot JSON status GUI desktop launcher {key} does not match expected value")
    if str(values.get("Hidden", "")).strip().lower() == "true":
        fail("pre-departure status snapshot JSON status GUI desktop launcher is hidden")
    if str(values.get("X-GNOME-Autostart-enabled", "")).strip().lower() == "true":
        fail("pre-departure status snapshot JSON status GUI desktop launcher must not be configured for autostart")


def validate_track_log_paths(track_log: dict[str, object]) -> None:
    track_output = snapshot_absolute_path(track_log.get("track_output", ""), "track_log track_output")
    tracks_dir = snapshot_absolute_path(track_log.get("tracks_dir", ""), "track_log tracks_dir")
    latest_path = snapshot_text(track_log.get("latest_path", ""), "track_log latest_path")
    if str(Path(track_output) / "tracks") != tracks_dir:
        fail("pre-departure status snapshot JSON track_log tracks_dir does not match track_output")
    if not latest_path:
        fail("pre-departure status snapshot JSON track_log missing latest_path")
    if not Path(latest_path).is_absolute():
        fail("pre-departure status snapshot JSON track_log latest_path is not absolute")
    normalized_latest = os.path.normpath(latest_path)
    normalized_tracks = os.path.normpath(tracks_dir)
    try:
        latest_common = os.path.commonpath([normalized_latest, normalized_tracks])
    except ValueError:
        latest_common = ""
    if normalized_latest == normalized_tracks or latest_common != normalized_tracks:
        fail("pre-departure status snapshot JSON track_log latest_path is not under tracks_dir")
    latest_name = Path(latest_path).name
    if not latest_name.startswith("track-") or Path(latest_name).suffix.lower() != ".gpx":
        fail("pre-departure status snapshot JSON track_log latest_path is not a track-*.gpx file")
    private_octal_mode(track_log.get("tracks_mode"), field="tracks_mode")
    private_octal_mode(track_log.get("latest_mode"), field="latest_mode")


def validate_snapshot_gps_fix(
    gps_fix: dict[str, object],
    *,
    gps_mode: str,
    generated_at: datetime,
) -> None:
    expected_source = "GPS" if gps_mode == "serial" else "GPSD"
    source = snapshot_text(gps_fix.get("source", ""), "gps_fix source")
    if source != expected_source:
        fail(
            "pre-departure status snapshot JSON gps_fix source "
            + (source or "<missing>")
            + f" does not match {expected_source}"
        )
    latitude = finite_status_float(gps_fix.get("latitude"))
    longitude = finite_status_float(gps_fix.get("longitude"))
    if latitude is None or longitude is None:
        fail("pre-departure status snapshot JSON gps_fix has non-numeric coordinates")
    if not -90.0 <= latitude <= 90.0:
        fail("pre-departure status snapshot JSON gps_fix latitude is outside -90..90")
    if not -180.0 <= longitude <= 180.0:
        fail("pre-departure status snapshot JSON gps_fix longitude is outside -180..180")
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        fail("pre-departure status snapshot JSON gps_fix coordinates are invalid 0,0")
    timestamp = parse_snapshot_timestamp(gps_fix.get("timestamp"), "gps_fix")
    validate_snapshot_age(gps_fix.get("age_seconds"), timestamp=timestamp, generated_at=generated_at, field="gps_fix")
    validate_snapshot_quality(gps_fix, satellite_field="satellites", hdop_field="hdop", label="gps_fix")


def validate_snapshot_track_log(track_log: dict[str, object], *, generated_at: datetime) -> None:
    if track_log.get("track_output_is_symlink") is not False:
        fail("pre-departure status snapshot JSON track_log track_output is a symlink or missing symlink status")
    if "track_storage_symlink_component" not in track_log:
        fail("pre-departure status snapshot JSON track_log missing track_storage_symlink_component")
    if snapshot_text(track_log.get("track_storage_symlink_component", ""), "track_log track_storage_symlink_component"):
        fail("pre-departure status snapshot JSON track_log storage path contains a symlink")
    validate_track_log_paths(track_log)
    latitude = finite_status_float(track_log.get("latest_latitude"))
    longitude = finite_status_float(track_log.get("latest_longitude"))
    if latitude is None or longitude is None:
        fail("pre-departure status snapshot JSON track_log has non-numeric latest coordinates")
    if not -90.0 <= latitude <= 90.0:
        fail("pre-departure status snapshot JSON track_log latest_latitude is outside -90..90")
    if not -180.0 <= longitude <= 180.0:
        fail("pre-departure status snapshot JSON track_log latest_longitude is outside -180..180")
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        fail("pre-departure status snapshot JSON track_log latest coordinates are invalid 0,0")
    latest_time = parse_snapshot_timestamp(track_log.get("latest_time"), "track_log latest_time")
    validate_snapshot_age(
        track_log.get("age_seconds"),
        timestamp=latest_time,
        generated_at=generated_at,
        field="track_log",
    )
    validate_snapshot_quality(
        track_log,
        satellite_field="latest_satellites",
        hdop_field="latest_hdop",
        label="track_log",
    )


def validate_snapshot_gps_row(
    check_rows: dict[str, dict[str, object]],
    *,
    gps_mode: str,
    gps_fix: dict[str, object],
) -> None:
    expected_name = "GPS" if gps_mode == "serial" else "GPSD"
    row = check_rows.get(expected_name)
    if not isinstance(row, dict):
        fail(f"pre-departure status snapshot JSON missing {expected_name} readiness row")
    data = row.get("data")
    if not isinstance(data, dict):
        fail(f"pre-departure status snapshot JSON {expected_name} row has no structured fix data")
    latitude = finite_status_float(data.get("latitude"))
    longitude = finite_status_float(data.get("longitude"))
    if latitude is None or longitude is None:
        fail(f"pre-departure status snapshot JSON {expected_name} row has non-numeric coordinates")
    summary_latitude = finite_status_float(gps_fix.get("latitude"))
    summary_longitude = finite_status_float(gps_fix.get("longitude"))
    if summary_latitude is not None and abs(latitude - summary_latitude) > 1e-7:
        fail(f"pre-departure status snapshot JSON {expected_name} latitude does not match gps_fix")
    if summary_longitude is not None and abs(longitude - summary_longitude) > 1e-7:
        fail(f"pre-departure status snapshot JSON {expected_name} longitude does not match gps_fix")
    timestamp = parse_snapshot_timestamp(data.get("timestamp"), f"{expected_name} row")
    summary_timestamp = parse_snapshot_timestamp(gps_fix.get("timestamp"), "gps_fix")
    if timestamp != summary_timestamp:
        fail(f"pre-departure status snapshot JSON {expected_name} timestamp does not match gps_fix")
    validate_snapshot_quality(data, satellite_field="satellites", hdop_field="hdop", label=f"{expected_name} row")
    if gps_fix.get("satellites") is not None and data.get("satellites") != gps_fix.get("satellites"):
        fail(f"pre-departure status snapshot JSON {expected_name} satellites do not match gps_fix")
    if gps_fix.get("hdop") is not None:
        row_hdop = finite_status_float(data.get("hdop"))
        summary_hdop = finite_status_float(gps_fix.get("hdop"))
        if row_hdop is None or summary_hdop is None or abs(row_hdop - summary_hdop) > 1e-9:
            fail(f"pre-departure status snapshot JSON {expected_name} HDOP does not match gps_fix")


def validate_snapshot_manifest_row(
    check_rows: dict[str, dict[str, object]],
    *,
    config: dict[str, object],
    manifest: object,
) -> None:
    row = check_rows.get("Manifest")
    if not isinstance(row, dict):
        fail("pre-departure status snapshot JSON missing Manifest readiness row")
    data = row.get("data")
    if not isinstance(data, dict):
        fail("pre-departure status snapshot JSON Manifest row has no structured data")
    if not isinstance(manifest, dict):
        fail("pre-departure status snapshot JSON Manifest row has no top-level manifest summary")
    chart_output = snapshot_absolute_path(config.get("chart_output", ""), "config chart_output")
    configured_path = snapshot_absolute_path(data.get("configured_path", ""), "Manifest configured path")
    if configured_path != chart_output:
        fail("pre-departure status snapshot JSON Manifest configured path does not match config chart_output")
    manifest_path = snapshot_absolute_path(data.get("path", ""), "Manifest path")
    if manifest_path != str(Path(chart_output) / "noaa-navionics-manifest.json"):
        fail("pre-departure status snapshot JSON Manifest path does not match config chart_output")
    if manifest_path != snapshot_absolute_path(manifest.get("path", ""), "manifest summary path"):
        fail("pre-departure status snapshot JSON Manifest path does not match manifest summary")
    for row_field, summary_field in (
        ("created_at", "created_at"),
        ("created_at_source", "created_at_source"),
        ("package", "package"),
        ("package_filename", "package_filename"),
        ("package_url", "url"),
        ("download_path", "download_path"),
        ("download_url", "download_url"),
        ("sha256", "sha256"),
        ("extract_path", "extract_path"),
    ):
        row_value = snapshot_text(data.get(row_field, ""), f"Manifest {row_field}")
        summary_value = snapshot_text(manifest.get(summary_field, ""), f"manifest summary {summary_field}")
        if row_value != summary_value:
            fail(f"pre-departure status snapshot JSON Manifest {row_field} does not match manifest summary")
    created_at_source = snapshot_text(data.get("created_at_source", ""), "Manifest created_at_source")
    if created_at_source not in {"download", "previous-manifest"}:
        fail("pre-departure status snapshot JSON Manifest created_at_source is not verified")
    normalized_chart_output = os.path.normpath(chart_output)
    for row_field, label in (
        ("download_path", "Manifest download path"),
        ("extract_path", "Manifest extract path"),
    ):
        manifest_storage_path = snapshot_absolute_path(data.get(row_field, ""), label)
        normalized_storage_path = os.path.normpath(manifest_storage_path)
        try:
            storage_common = os.path.commonpath([normalized_storage_path, normalized_chart_output])
        except ValueError:
            storage_common = ""
        if normalized_storage_path == normalized_chart_output or storage_common != normalized_chart_output:
            if row_field == "download_path":
                fail("pre-departure status snapshot JSON Manifest download path is outside chart_output")
            fail("pre-departure status snapshot JSON Manifest extract path is outside chart_output")
    parse_snapshot_timestamp(data.get("created_at"), "Manifest created_at")
    download_bytes = positive_status_int(data.get("download_bytes"))
    summary_download_bytes = positive_status_int(manifest.get("download_bytes"))
    if download_bytes is None:
        fail("pre-departure status snapshot JSON Manifest download byte count is not positive")
    if summary_download_bytes is not None and download_bytes != summary_download_bytes:
        fail("pre-departure status snapshot JSON Manifest download byte count does not match manifest summary")
    enc_cell_count = positive_status_int(data.get("enc_cell_count"))
    actual_enc_cell_count = positive_status_int(data.get("actual_enc_cell_count"))
    summary_enc_cell_count = positive_status_int(manifest.get("enc_cell_count"))
    summary_actual_enc_cell_count = positive_status_int(manifest.get("actual_enc_cell_count"))
    if enc_cell_count is None:
        fail("pre-departure status snapshot JSON Manifest has no ENC cells")
    if actual_enc_cell_count is None:
        fail("pre-departure status snapshot JSON Manifest actual ENC cell count is not positive")
    if enc_cell_count is not None and actual_enc_cell_count is not None and enc_cell_count != actual_enc_cell_count:
        fail("pre-departure status snapshot JSON Manifest actual ENC cell count does not match recorded count")
    if enc_cell_count is not None and summary_enc_cell_count is not None and enc_cell_count != summary_enc_cell_count:
        fail("pre-departure status snapshot JSON Manifest ENC cell count does not match manifest summary")
    if (
        actual_enc_cell_count is not None
        and summary_actual_enc_cell_count is not None
        and actual_enc_cell_count != summary_actual_enc_cell_count
    ):
        fail("pre-departure status snapshot JSON Manifest actual ENC cell count does not match manifest summary")


def validate_snapshot_storage_rows(check_rows: dict[str, dict[str, object]], *, config: dict[str, object]) -> None:
    chart_output = snapshot_absolute_path(config.get("chart_output", ""), "config chart_output")
    track_output = snapshot_absolute_path(config.get("track_output", ""), "config track_output")
    expected_paths = {"Disk": chart_output}
    if track_output != chart_output:
        expected_paths["Track Disk"] = track_output

    for row_name, expected_path in expected_paths.items():
        row = check_rows.get(row_name)
        if not isinstance(row, dict):
            fail(f"pre-departure status snapshot JSON missing {row_name} readiness row")
        data = row.get("data")
        if not isinstance(data, dict):
            fail(f"pre-departure status snapshot JSON {row_name} row has no structured data")
        configured_path = snapshot_absolute_path(data.get("configured_path", ""), f"{row_name} configured path")
        checked_path = snapshot_absolute_path(data.get("checked_path", ""), f"{row_name} checked path")
        if configured_path != expected_path:
            fail(f"pre-departure status snapshot JSON {row_name} configured path does not match config")
        if data.get("exists") is not True:
            fail(f"pre-departure status snapshot JSON {row_name} checked path does not exist")
        if data.get("is_directory") is not True:
            fail(f"pre-departure status snapshot JSON {row_name} checked path is not a directory")
        if snapshot_text(data.get("storage_symlink_component", ""), f"{row_name} storage_symlink_component"):
            fail(f"pre-departure status snapshot JSON {row_name} storage path contains a symlink")
        if data.get("missing_removable_mount") is True:
            fail(f"pre-departure status snapshot JSON {row_name} removable storage is not mounted")
        uid = data.get("uid")
        expected_uid = data.get("expected_uid")
        if (
            isinstance(uid, bool)
            or isinstance(expected_uid, bool)
            or not isinstance(uid, int)
            or not isinstance(expected_uid, int)
            or uid != expected_uid
        ):
            fail(f"pre-departure status snapshot JSON {row_name} storage owner is invalid")
        mode_text = snapshot_text(data.get("mode", ""), f"{row_name} mode")
        try:
            mode = int(mode_text, 8)
        except ValueError:
            fail(f"pre-departure status snapshot JSON {row_name} storage mode is invalid")
        if mode & 0o022:
            fail(f"pre-departure status snapshot JSON {row_name} storage is group/world writable")
        min_free_gb = finite_status_float(data.get("min_free_gb"))
        free_gb = finite_status_float(data.get("free_gb"))
        if min_free_gb is None or min_free_gb <= 0.0:
            fail(f"pre-departure status snapshot JSON {row_name} missing minimum free-space threshold")
        if free_gb is None or free_gb < 0.0:
            fail(f"pre-departure status snapshot JSON {row_name} missing finite free-space measurement")
        if min_free_gb is not None and free_gb is not None and free_gb < min_free_gb:
            fail(f"pre-departure status snapshot JSON {row_name} free space is below threshold")
        total_inodes = data.get("total_inodes")
        free_inodes = data.get("free_inodes")
        if isinstance(total_inodes, bool) or not isinstance(total_inodes, int) or total_inodes < 0:
            fail(f"pre-departure status snapshot JSON {row_name} missing inode capacity measurement")
        if isinstance(free_inodes, bool) or not isinstance(free_inodes, int) or free_inodes < 0:
            fail(f"pre-departure status snapshot JSON {row_name} missing free inode measurement")
        if isinstance(total_inodes, int) and total_inodes > 0 and isinstance(free_inodes, int) and free_inodes <= 0:
            fail(f"pre-departure status snapshot JSON {row_name} has no free inodes")
        if data.get("writable") is not True:
            fail(f"pre-departure status snapshot JSON {row_name} storage is not writable")


def validate_snapshot_chart_rows(check_rows: dict[str, dict[str, object]], *, config: dict[str, object]) -> None:
    chart_output = snapshot_absolute_path(config.get("chart_output", ""), "config chart_output")

    charts_row = check_rows.get("Charts")
    if not isinstance(charts_row, dict):
        fail("pre-departure status snapshot JSON missing Charts readiness row")
    charts_data = charts_row.get("data")
    if not isinstance(charts_data, dict):
        fail("pre-departure status snapshot JSON Charts row has no structured data")
    configured_path = snapshot_absolute_path(charts_data.get("configured_path", ""), "Charts path")
    if configured_path != chart_output:
        fail("pre-departure status snapshot JSON Charts path does not match config chart_output")
    if charts_data.get("exists") is not True:
        fail("pre-departure status snapshot JSON Charts path does not exist")
    if snapshot_text(charts_data.get("storage_symlink_component", ""), "Charts storage_symlink_component"):
        fail("pre-departure status snapshot JSON Charts path contains a symlink")
    if charts_data.get("has_extracted_enc_cells") is not True:
        fail("pre-departure status snapshot JSON Charts found no extracted ENC cells")
    if charts_data.get("has_unextracted_zips") is not False:
        fail("pre-departure status snapshot JSON Charts found unextracted ZIP chart artifacts")
    zip_samples = charts_data.get("zip_samples")
    if not isinstance(zip_samples, list) or zip_samples:
        fail("pre-departure status snapshot JSON Charts ZIP sample list is not empty")
    enc_cell_samples = charts_data.get("enc_cell_samples")
    if not isinstance(enc_cell_samples, list) or not enc_cell_samples:
        fail("pre-departure status snapshot JSON Charts has no ENC cell sample paths")
    if any(not Path(snapshot_text(sample, "Charts ENC cell sample path")).is_absolute() for sample in enc_cell_samples):
        fail("pre-departure status snapshot JSON Charts ENC cell sample path is not absolute")
    normalized_chart_output = os.path.normpath(chart_output)
    for sample in enc_cell_samples:
        normalized_sample = os.path.normpath(snapshot_text(sample, "Charts ENC cell sample path"))
        try:
            sample_common = os.path.commonpath([normalized_sample, normalized_chart_output])
        except ValueError:
            sample_common = ""
        if normalized_sample == normalized_chart_output or sample_common != normalized_chart_output:
            fail("pre-departure status snapshot JSON Charts ENC cell sample path is outside chart_output")

    debris_row = check_rows.get("Chart Update Debris")
    if not isinstance(debris_row, dict):
        fail("pre-departure status snapshot JSON missing Chart Update Debris readiness row")
    debris_data = debris_row.get("data")
    if not isinstance(debris_data, dict):
        fail("pre-departure status snapshot JSON Chart Update Debris row has no structured data")
    configured_path = snapshot_absolute_path(debris_data.get("configured_path", ""), "Chart Update Debris path")
    if configured_path != chart_output:
        fail("pre-departure status snapshot JSON Chart Update Debris path does not match config chart_output")
    if snapshot_text(debris_data.get("storage_symlink_component", ""), "Chart Update Debris storage_symlink_component"):
        fail("pre-departure status snapshot JSON Chart Update Debris path contains a symlink")
    debris_count = debris_data.get("debris_count")
    if isinstance(debris_count, bool) or not isinstance(debris_count, int) or debris_count != 0:
        fail("pre-departure status snapshot JSON Chart Update Debris found stale update debris")
    debris = debris_data.get("debris")
    if not isinstance(debris, list) or debris:
        fail("pre-departure status snapshot JSON Chart Update Debris debris list is not empty")
    if debris_data.get("clean") is not True:
        fail("pre-departure status snapshot JSON Chart Update Debris did not prove a clean chart directory")

    opencpn_row = check_rows.get("OpenCPN Charts")
    if not isinstance(opencpn_row, dict):
        fail("pre-departure status snapshot JSON missing OpenCPN Charts readiness row")
    opencpn_data = opencpn_row.get("data")
    if not isinstance(opencpn_data, dict):
        fail("pre-departure status snapshot JSON OpenCPN Charts row has no structured data")
    chart_dir = snapshot_absolute_path(opencpn_data.get("chart_dir", ""), "OpenCPN Charts chart directory")
    if chart_dir != chart_output:
        fail("pre-departure status snapshot JSON OpenCPN Charts chart directory does not match config chart_output")
    snapshot_absolute_path(opencpn_data.get("config_path", ""), "OpenCPN Charts config path")
    if opencpn_data.get("config_exists") is not True:
        fail("pre-departure status snapshot JSON OpenCPN Charts config does not exist")
    if opencpn_data.get("chart_dir_exists") is not True:
        fail("pre-departure status snapshot JSON OpenCPN Charts chart directory does not exist")
    if opencpn_data.get("configured") is not True:
        fail("pre-departure status snapshot JSON OpenCPN Charts did not prove configured chart directory")
    chart_directories = opencpn_data.get("chart_directories")
    if not isinstance(chart_directories, list) or not chart_directories:
        fail("pre-departure status snapshot JSON OpenCPN Charts has no parsed chart directories")
    parsed_chart_directories = [snapshot_text(directory, "OpenCPN Charts parsed directory") for directory in chart_directories]
    if not any(directory == chart_output for directory in parsed_chart_directories):
        fail("pre-departure status snapshot JSON OpenCPN Charts parsed directories do not include configured chart output")


def normalize_snapshot_gpsd_host(value: object) -> str:
    host = str(value).strip().lower()
    return "127.0.0.1" if host in {"localhost", "::1"} else host


def validate_snapshot_gpsd_rows(check_rows: dict[str, dict[str, object]], *, config: dict[str, object]) -> None:
    expected_device = snapshot_text(config.get("gps_device", ""), "config gps_device")
    if not expected_device:
        fail("pre-departure status snapshot JSON missing config gps_device")
    expected_host = normalize_snapshot_gpsd_host(snapshot_text(config.get("gpsd_host", ""), "config gpsd_host"))
    if expected_host not in {"127.0.0.1", "0.0.0.0"}:
        fail("pre-departure status snapshot JSON config gpsd_host is not local")
    expected_port = config.get("gpsd_port")
    if isinstance(expected_port, bool) or not isinstance(expected_port, int) or not (1 <= expected_port <= 65535):
        fail("pre-departure status snapshot JSON config gpsd_port is invalid")

    opencpn_row = check_rows.get("OpenCPN GPSD")
    if not isinstance(opencpn_row, dict):
        fail("pre-departure status snapshot JSON missing OpenCPN GPSD readiness row")
    opencpn_data = opencpn_row.get("data")
    if not isinstance(opencpn_data, dict):
        fail("pre-departure status snapshot JSON OpenCPN GPSD row has no structured data")
    snapshot_absolute_path(opencpn_data.get("config_path", ""), "OpenCPN GPSD config path")
    if opencpn_data.get("config_exists") is not True:
        fail("pre-departure status snapshot JSON OpenCPN GPSD config does not exist")
    if normalize_snapshot_gpsd_host(opencpn_data.get("expected_host", "")) != expected_host:
        fail("pre-departure status snapshot JSON OpenCPN GPSD host does not match config gpsd_host")
    if opencpn_data.get("expected_port") != expected_port:
        fail("pre-departure status snapshot JSON OpenCPN GPSD port does not match config gpsd_port")
    if opencpn_data.get("configured") is not True:
        fail("pre-departure status snapshot JSON OpenCPN GPSD did not prove configured endpoint")
    connections = opencpn_data.get("enabled_gpsd_connections")
    if not isinstance(connections, list) or not connections:
        fail("pre-departure status snapshot JSON OpenCPN GPSD has no parsed enabled GPSD connections")
    if not any(
        isinstance(connection, dict)
        and normalize_snapshot_gpsd_host(connection.get("host", "")) == expected_host
        and connection.get("port") == expected_port
        for connection in connections
    ):
        fail("pre-departure status snapshot JSON OpenCPN GPSD parsed connections do not include configured endpoint")
    unexpected = opencpn_data.get("unexpected_connections")
    if not isinstance(unexpected, list):
        fail("pre-departure status snapshot JSON OpenCPN GPSD unexpected connection list was not parsed")
    if unexpected:
        fail("pre-departure status snapshot JSON OpenCPN GPSD found unexpected enabled GPSD connections")

    gpsd_config_row = check_rows.get("GPSD Config")
    if not isinstance(gpsd_config_row, dict):
        fail("pre-departure status snapshot JSON missing GPSD Config readiness row")
    gpsd_config_data = gpsd_config_row.get("data")
    if not isinstance(gpsd_config_data, dict):
        fail("pre-departure status snapshot JSON GPSD Config row has no structured data")
    if snapshot_text(gpsd_config_data.get("path", ""), "GPSD Config path") != "/etc/default/gpsd":
        fail("pre-departure status snapshot JSON GPSD Config path is not /etc/default/gpsd")
    if gpsd_config_data.get("exists") is not True:
        fail("pre-departure status snapshot JSON GPSD Config path does not exist")
    if gpsd_config_data.get("is_symlink") is not False:
        fail("pre-departure status snapshot JSON GPSD Config path is a symlink")
    if snapshot_text(gpsd_config_data.get("directory_symlink_component", ""), "GPSD Config directory_symlink_component"):
        fail("pre-departure status snapshot JSON GPSD Config directory contains a symlink")
    if gpsd_config_data.get("is_regular") is not True:
        fail("pre-departure status snapshot JSON GPSD Config path is not a regular file")
    if gpsd_config_data.get("expected_device") != expected_device:
        fail("pre-departure status snapshot JSON GPSD Config expected device does not match config")
    devices = gpsd_config_data.get("devices")
    if devices != [expected_device]:
        fail("pre-departure status snapshot JSON GPSD Config devices do not match configured GPS device")
    if gpsd_config_data.get("start_daemon") != "true":
        fail("pre-departure status snapshot JSON GPSD Config START_DAEMON is not true")
    if gpsd_config_data.get("usbauto") != "false":
        fail("pre-departure status snapshot JSON GPSD Config USBAUTO is not false")
    if "-n" not in gpsd_config_data.get("gpsd_options", []):
        fail("pre-departure status snapshot JSON GPSD Config does not enable immediate polling")

    chrony_row = check_rows.get("Chrony Config")
    if not isinstance(chrony_row, dict):
        fail("pre-departure status snapshot JSON missing Chrony Config readiness row")
    chrony_data = chrony_row.get("data")
    if not isinstance(chrony_data, dict):
        fail("pre-departure status snapshot JSON Chrony Config row has no structured data")
    if chrony_data.get("is_raspberry_pi") is False and chrony_data.get("skipped") is True:
        fail("pre-departure status snapshot JSON Chrony Config records non-Pi diagnostic skip")
    if snapshot_text(chrony_data.get("path", ""), "Chrony Config path") != "/etc/chrony/chrony.conf":
        fail("pre-departure status snapshot JSON Chrony Config path is not /etc/chrony/chrony.conf")
    if chrony_data.get("exists") is not True:
        fail("pre-departure status snapshot JSON Chrony Config path does not exist")
    if chrony_data.get("is_symlink") is not False:
        fail("pre-departure status snapshot JSON Chrony Config path is a symlink")
    if snapshot_text(chrony_data.get("directory_symlink_component", ""), "Chrony Config directory_symlink_component"):
        fail("pre-departure status snapshot JSON Chrony Config directory contains a symlink")
    if chrony_data.get("is_regular") is not True:
        fail("pre-departure status snapshot JSON Chrony Config path is not a regular file")
    if chrony_data.get("managed_refclock_present") is not True:
        fail("pre-departure status snapshot JSON Chrony Config is missing managed GPSD SHM refclock")
    if snapshot_text(chrony_data.get("refclock_line", ""), "Chrony Config refclock_line") != "refclock SHM 0 offset 0.5 delay 0.1 refid GPS":
        fail("pre-departure status snapshot JSON Chrony Config refclock line is not the managed GPSD SHM source")

    time_row = check_rows.get("GPS Time Source")
    if not isinstance(time_row, dict):
        fail("pre-departure status snapshot JSON missing GPS Time Source readiness row")
    time_data = time_row.get("data")
    if not isinstance(time_data, dict):
        fail("pre-departure status snapshot JSON GPS Time Source row has no structured data")
    if time_data.get("is_raspberry_pi") is False and time_data.get("skipped") is True:
        fail("pre-departure status snapshot JSON GPS Time Source records non-Pi diagnostic skip")
    if time_data.get("is_raspberry_pi") is not True:
        fail("pre-departure status snapshot JSON GPS Time Source did not identify a Raspberry Pi check")
    if time_data.get("chronyc_available") is not True:
        fail("pre-departure status snapshot JSON GPS Time Source did not validate chronyc availability")
    if not isinstance(time_data.get("gps_lines"), list) or not time_data.get("gps_lines"):
        fail("pre-departure status snapshot JSON GPS Time Source has no GPS refclock lines")
    if not isinstance(time_data.get("usable_lines"), list) or not time_data.get("usable_lines"):
        fail("pre-departure status snapshot JSON GPS Time Source has no selected or combined GPS refclock")
    if time_data.get("selected_or_combined") is not True:
        fail("pre-departure status snapshot JSON GPS Time Source did not prove selected or combined GPS time")


def validate_successful_status_snapshot(
    payload: dict[str, object],
    expected_source_revision: str,
    generated_at: datetime,
) -> None:
    checks = payload.get("checks")
    service_checks = payload.get("service_checks")
    if not isinstance(checks, list) or not isinstance(service_checks, list):
        fail("pre-departure status snapshot JSON missing readiness check sections")

    check_rows = {}
    for row in checks:
        if not isinstance(row, dict):
            fail("pre-departure status snapshot JSON has malformed checks row")
        name = str(row.get("name", "")).strip()
        if not name:
            fail("pre-departure status snapshot JSON has unnamed readiness check")
        if not isinstance(row.get("ok"), bool):
            fail(f"pre-departure status snapshot JSON readiness check {name} ok is not boolean")
        if name in check_rows:
            fail(f"pre-departure status snapshot JSON has duplicate readiness check: {name}")
        check_rows[name] = row

    service_rows = {}
    for row in service_checks:
        if not isinstance(row, dict):
            fail("pre-departure status snapshot JSON has malformed service_checks row")
        name = str(row.get("name", "")).strip()
        if not name:
            fail("pre-departure status snapshot JSON has unnamed service check")
        if not isinstance(row.get("ok"), bool):
            fail(f"pre-departure status snapshot JSON service check {name} ok is not boolean")
        if name in service_rows:
            fail(f"pre-departure status snapshot JSON has duplicate service check: {name}")
        service_rows[name] = row

    config_path = snapshot_text(payload.get("config_path", ""), "config_path")
    if not config_path:
        fail("pre-departure status snapshot JSON missing config_path")
    if not Path(config_path).is_absolute():
        fail("pre-departure status snapshot JSON config_path is not absolute")
    config = payload.get("config")
    if not isinstance(config, dict):
        fail("pre-departure status snapshot JSON missing config section")
    gps_mode = snapshot_text(config.get("gps_mode", ""), "config gps_mode").lower()
    if gps_mode not in {"gpsd", "serial"}:
        fail(f"pre-departure status snapshot JSON has invalid gps_mode: {gps_mode or '<missing>'}")
    gps_device = snapshot_text(config.get("gps_device", ""), "config gps_device")
    if not gps_device:
        fail("pre-departure status snapshot JSON missing config gps_device")
    if not stable_snapshot_gps_device_path(gps_device):
        if gps_device.startswith("/dev/ttyUSB") or gps_device.startswith("/dev/ttyACM"):
            fail(
                "pre-departure status snapshot JSON config gps_device is volatile; "
                "use /dev/serial/by-id/... or /dev/serial/by-path/... instead"
            )
        fail("pre-departure status snapshot JSON config gps_device must be /dev/serial/by-id/..., /dev/serial/by-path/..., /dev/serial0, /dev/serial1, or /dev/gps")
    gps_baud = config.get("gps_baud")
    if isinstance(gps_baud, bool) or not isinstance(gps_baud, int) or gps_baud not in GPS_BAUD_RATES:
        fail("pre-departure status snapshot JSON config gps_baud is invalid")
    chart_output = snapshot_text(config.get("chart_output", ""), "config chart_output")
    if not chart_output:
        fail("pre-departure status snapshot JSON missing config chart_output")
    if not Path(chart_output).is_absolute():
        fail("pre-departure status snapshot JSON config chart_output is not absolute")
    configured_track_output = snapshot_text(config.get("track_output", ""), "config track_output")
    if not configured_track_output:
        fail("pre-departure status snapshot JSON missing config track_output")
    if not Path(configured_track_output).is_absolute():
        fail("pre-departure status snapshot JSON config track_output is not absolute")
    gps_fix = payload.get("gps_fix")
    if not isinstance(gps_fix, dict):
        fail("pre-departure status snapshot JSON missing gps_fix section")
    if not isinstance(gps_fix.get("ok"), bool):
        fail("pre-departure status snapshot JSON gps_fix ok is not boolean")
    if gps_fix.get("ok") is not True:
        fail(
            "pre-departure status snapshot JSON gps_fix is not ok: "
            + str(gps_fix.get("detail", "<missing detail>"))
        )
    validate_snapshot_gps_fix(gps_fix, gps_mode=gps_mode, generated_at=generated_at)
    track_log = payload.get("track_log")
    if not isinstance(track_log, dict):
        fail("pre-departure status snapshot JSON missing track_log section")
    if not isinstance(track_log.get("ok"), bool):
        fail("pre-departure status snapshot JSON track_log ok is not boolean")
    if track_log.get("ok") is not True:
        fail(
            "pre-departure status snapshot JSON track_log is not ok: "
            + str(track_log.get("detail", "<missing detail>"))
        )
    validate_snapshot_track_log(track_log, generated_at=generated_at)
    track_output = snapshot_text(track_log.get("track_output", ""), "track_log track_output")
    if not track_output:
        fail("pre-departure status snapshot JSON missing track_log track_output")
    if track_output != configured_track_output:
        fail("pre-departure status snapshot JSON track_log track_output does not match config track_output")
    tracks_dir = snapshot_text(track_log.get("tracks_dir", ""), "track_log tracks_dir")
    expected_tracks_dir = str(Path(configured_track_output) / "tracks")
    if tracks_dir != expected_tracks_dir:
        fail("pre-departure status snapshot JSON track_log tracks_dir does not match config track_output")

    required_checks = set(CORE_READINESS_CHECKS)
    required_service_checks = set(CORE_SERVICE_CHECKS)
    if gps_mode == "serial":
        required_checks.update(SERIAL_READINESS_CHECKS)
    else:
        required_checks.update(GPSD_READINESS_CHECKS)
        required_service_checks.update(GPSD_SERVICE_CHECKS)
    if track_output != chart_output:
        required_checks.add("Track Disk")

    missing_checks = sorted(required_checks - set(check_rows))
    missing_service_checks = sorted(required_service_checks - set(service_rows))
    if missing_checks:
        fail("pre-departure status snapshot JSON missing required readiness check(s): " + ", ".join(missing_checks))
    if missing_service_checks:
        fail("pre-departure status snapshot JSON missing required service check(s): " + ", ".join(missing_service_checks))
    failed_checks = sorted(name for name, row in check_rows.items() if row.get("ok") is not True)
    failed_service_checks = sorted(name for name, row in service_rows.items() if row.get("ok") is not True)
    if failed_checks:
        fail("pre-departure status snapshot JSON has failed readiness check(s): " + ", ".join(failed_checks))
    if failed_service_checks:
        fail("pre-departure status snapshot JSON has failed service check(s): " + ", ".join(failed_service_checks))
    missing_structured_data = sorted(
        name for name in required_checks if not isinstance(check_rows[name].get("data"), dict)
    )
    if missing_structured_data:
        fail(
            "pre-departure status snapshot JSON missing structured readiness data for: "
            + ", ".join(missing_structured_data)
        )
    validate_snapshot_autostart(payload)
    validate_snapshot_status_launcher(payload)
    validate_snapshot_mob_launcher(payload)
    validate_snapshot_storage_rows(check_rows, config=config)
    validate_snapshot_chart_rows(check_rows, config=config)
    validate_snapshot_manifest_row(check_rows, config=config, manifest=payload.get("manifest"))
    validate_snapshot_gps_row(check_rows, gps_mode=gps_mode, gps_fix=gps_fix)
    if gps_mode == "gpsd":
        validate_snapshot_gpsd_rows(check_rows, config=config)
    non_pi_skips = sorted(
        name
        for name in required_checks & PI_ONLY_READINESS_CHECKS
        if check_rows[name].get("data", {}).get("is_raspberry_pi") is False
        and check_rows[name].get("data", {}).get("skipped") is True
    )
    if non_pi_skips:
        fail(
            "pre-departure status snapshot JSON records non-Pi diagnostic skip(s): "
            + ", ".join(non_pi_skips)
        )
    source_data = check_rows["Source Revision"].get("data")
    row_revision = snapshot_text(source_data.get("revision", ""), "Source Revision revision")
    if not row_revision or row_revision == "unknown":
        fail("pre-departure status snapshot JSON Source Revision row missing revision")
    if row_revision.endswith("-dirty"):
        fail("pre-departure status snapshot JSON Source Revision row records a dirty revision")
    if row_revision != expected_source_revision:
        fail("pre-departure status snapshot JSON Source Revision row does not match deployed source_revision")


def inspect_private_directory(target: Path) -> None:
    try:
        result = target.lstat()
    except OSError as exc:
        fail(f"Could not inspect pre-departure status directory: {target}: {exc}")
    if not stat.S_ISDIR(result.st_mode):
        fail(f"Pre-departure status directory must be a real directory: {target}")
    if result.st_uid != os.getuid():
        fail(f"Pre-departure status directory is owned by uid {result.st_uid}, expected {os.getuid()}: {target}")
    mode = stat.S_IMODE(result.st_mode)
    if mode != 0o700:
        fail(f"Pre-departure status directory has permissions {mode:04o}, expected private 0700: {target}")


def validate_helper(script: Path) -> int:
    if not script.is_absolute():
        fail(f"Helper script path must be absolute before status snapshot execution: {script}")
    current = Path("/")
    for part in script.parts[1:]:
        if part in {"", "."}:
            continue
        current = current / part
        try:
            component = os.lstat(current)
        except OSError as exc:
            fail(f"Could not inspect helper script path component before status snapshot execution {current}: {exc}")
        if stat.S_ISLNK(component.st_mode):
            fail(f"Helper script path contains a symlink before status snapshot execution: {current}")
    try:
        before = os.stat(script, follow_symlinks=False)
    except OSError as exc:
        fail(f"Could not inspect helper script before status snapshot execution: {script}: {exc}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"Helper script must be regular before status snapshot execution: {script}")
    if before.st_uid != os.getuid():
        fail(f"Helper script is owned by uid {before.st_uid}, expected current user {os.getuid()}: {script}")
    mode = stat.S_IMODE(before.st_mode)
    if mode & 0o022:
        fail(f"Helper script has permissions {mode:03o}, expected no group/other write bits: {script}")
    if not mode & 0o111:
        fail(f"Helper script is not executable before status snapshot execution: {script}")
    try:
        fd = os.open(script, os.O_RDONLY | nofollow)
    except OSError as exc:
        fail(f"Could not open helper script through no-follow descriptor for status snapshot: {script}: {exc}")
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        os.close(fd)
        fail(f"Helper script changed before status snapshot execution: {script}")
    if not stat.S_ISREG(opened.st_mode):
        os.close(fd)
        fail(f"Helper script must be regular when opened for status snapshot execution: {script}")
    if opened.st_uid != os.getuid():
        os.close(fd)
        fail(f"Helper script is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {script}")
    opened_mode = stat.S_IMODE(opened.st_mode)
    if opened_mode & 0o022:
        os.close(fd)
        fail(f"Helper script has permissions {opened_mode:03o}, expected no group/other write bits: {script}")
    if not opened_mode & 0o111:
        os.close(fd)
        fail(f"Helper script is not executable when opened for status snapshot execution: {script}")
    return fd


def inspect_private_file(file_path: Path, label: str) -> os.stat_result:
    try:
        result = file_path.lstat()
    except OSError as exc:
        fail(f"Could not inspect {label}: {file_path}: {exc}")
    if not stat.S_ISREG(result.st_mode):
        fail(f"{label} must be a regular file: {file_path}")
    if result.st_uid != os.getuid():
        fail(f"{label} is owned by uid {result.st_uid}, expected {os.getuid()}: {file_path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode != 0o600:
        fail(f"{label} has permissions {mode:04o}, expected private 0600: {file_path}")
    return result


def read_private_file(file_path: Path, label: str) -> bytes:
    before = inspect_private_file(file_path, label)
    fd = -1
    try:
        fd = os.open(file_path, os.O_RDONLY | nofollow)
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            fail(f"{label} changed while opening it: {file_path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"{label} must be regular when opened: {file_path}")
        if opened.st_uid != os.getuid():
            fail(f"{label} is owned by uid {opened.st_uid}, expected {os.getuid()} when opened: {file_path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != 0o600:
            fail(f"{label} has permissions {opened_mode:04o}, expected private 0600 when opened: {file_path}")
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            return handle.read()
    finally:
        if fd >= 0:
            os.close(fd)


def cleanup_private_temp(file_path: Path, expected: os.stat_result | None, label: str) -> None:
    if expected is None:
        print(f"{label} was not inspected before cleanup; leaving it in place: {file_path}", file=sys.stderr)
        return
    try:
        current = file_path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        print(f"could not inspect {label} before cleanup; leaving it in place: {file_path}: {exc}", file=sys.stderr)
        return
    if not os.path.samestat(expected, current):
        print(f"{label} changed before cleanup; leaving it in place: {file_path}", file=sys.stderr)
        return
    if not stat.S_ISREG(current.st_mode):
        print(f"{label} is not regular before cleanup; leaving it in place: {file_path}", file=sys.stderr)
        return
    try:
        file_path.unlink()
    except OSError as exc:
        print(f"could not remove {label} after validation: {file_path}: {exc}", file=sys.stderr)


def write_private_file_atomic(file_path: Path, payload: bytes, label: str) -> None:
    if file_path.exists() or file_path.is_symlink():
        fail(f"Refusing to overwrite existing {label}: {file_path}")
    temp_fd = -1
    temp_path = None
    temp_stat = None
    try:
        temp_fd, temp_name = tempfile.mkstemp(prefix=f".{file_path.name}.", suffix=".tmp", dir=directory)
        temp_path = Path(temp_name)
        os.fchmod(temp_fd, 0o600)
        temp_stat = os.fstat(temp_fd)
        os.write(temp_fd, payload)
        os.fsync(temp_fd)
        os.close(temp_fd)
        temp_fd = -1
        os.replace(temp_path, file_path)
        temp_path = None
    except OSError as exc:
        fail(f"Could not write {label}: {exc}")
    finally:
        if temp_fd >= 0:
            os.close(temp_fd)
        if temp_path is not None:
            cleanup_private_temp(temp_path, temp_stat, f"temporary {label}")
    inspect_private_file(file_path, label)


inspect_private_directory(directory)
status_path = directory / status_name
checksum_path = directory / checksum_name
if status_path.exists() or status_path.is_symlink():
    fail(f"Refusing to overwrite existing pre-departure status snapshot: {status_path}")
if checksum_path.exists() or checksum_path.is_symlink():
    fail(f"Refusing to overwrite existing pre-departure status checksum: {checksum_path}")

helper_fd = validate_helper(path)
temp_fd = -1
temp_path = None
temp_stat = None
try:
    temp_fd, temp_name = tempfile.mkstemp(prefix=f".{status_name}.", suffix=".tmp", dir=directory)
    temp_path = Path(temp_name)
    os.fchmod(temp_fd, 0o600)
    temp_stat = os.fstat(temp_fd)
    with os.fdopen(temp_fd, "wb") as output:
        temp_fd = -1
        try:
            result = subprocess.run([f"/proc/self/fd/{helper_fd}", *args], pass_fds=(helper_fd,), stdout=output)
        except OSError as exc:
            fail(f"Could not execute status helper through validated descriptor: {path}: {exc}")
        output.flush()
        os.fsync(output.fileno())
    if result.returncode != 0:
        raise SystemExit(result.returncode)
    payload = read_private_file(temp_path, "temporary pre-departure status snapshot")
    try:
        parsed = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"pre-departure status snapshot is not valid JSON: {exc}")
    if not isinstance(parsed, dict):
        fail("pre-departure status snapshot JSON must be an object")
    if parsed.get("ok") is not True:
        fail("pre-departure status snapshot JSON does not report ok=true")
    for field in ("checks", "service_checks"):
        value = parsed.get(field)
        if not isinstance(value, list) or not value:
            fail(f"pre-departure status snapshot JSON missing non-empty {field} list")
    generated_at = parsed.get("generated_at")
    if not isinstance(generated_at, str):
        fail("pre-departure status snapshot JSON missing generated_at timestamp")
    try:
        parsed_generated_at = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"pre-departure status snapshot JSON has invalid generated_at timestamp: {exc}")
    if parsed_generated_at.tzinfo is None or parsed_generated_at.utcoffset() is None:
        fail("pre-departure status snapshot JSON generated_at timestamp must include a timezone")
    generated_at_utc = parsed_generated_at.astimezone(timezone.utc)
    age_seconds = (datetime.now(timezone.utc) - generated_at_utc).total_seconds()
    if age_seconds > STATUS_MAX_AGE_SECONDS:
        fail(
            "pre-departure status snapshot JSON generated_at timestamp is stale "
            f"({age_seconds:.0f}s old; maximum {STATUS_MAX_AGE_SECONDS}s)"
        )
    if age_seconds < -STATUS_FUTURE_TOLERANCE_SECONDS:
        fail(
            "pre-departure status snapshot JSON generated_at timestamp is too far in the future "
            f"({-age_seconds:.0f}s ahead; maximum {STATUS_FUTURE_TOLERANCE_SECONDS}s)"
        )
    host = parsed.get("host")
    if not isinstance(host, dict):
        fail("pre-departure status snapshot JSON missing valid host boot_id")
    host_boot_id = snapshot_text(host.get("boot_id", ""), "host boot_id")
    if not BOOT_ID_RE.fullmatch(host_boot_id):
        fail("pre-departure status snapshot JSON missing valid host boot_id")
    app = parsed.get("app")
    if not isinstance(app, dict):
        fail("pre-departure status snapshot JSON missing deployed source_revision")
    source_revision_text = snapshot_text(app.get("source_revision", ""), "app source_revision")
    if not source_revision_text or source_revision_text == "unknown":
        fail("pre-departure status snapshot JSON missing deployed source_revision")
    if source_revision_text.endswith("-dirty"):
        fail("pre-departure status snapshot JSON dirty deployed source_revision is not production-ready")
    validate_successful_status_snapshot(parsed, source_revision_text, generated_at_utc)
    os.replace(temp_path, status_path)
    temp_path = None
finally:
    os.close(helper_fd)
    if temp_fd >= 0:
        os.close(temp_fd)
    if temp_path is not None:
        cleanup_private_temp(temp_path, temp_stat, "temporary pre-departure status snapshot")

payload = read_private_file(status_path, "pre-departure status snapshot")
digest = hashlib.sha256(payload).hexdigest()
write_private_file_atomic(checksum_path, f"{digest}  {status_name}\n".encode("ascii"), "pre-departure status checksum")
checksum_payload = read_private_file(checksum_path, "pre-departure status checksum")
if checksum_payload != f"{digest}  {status_name}\n".encode("ascii"):
    fail(f"pre-departure status checksum content changed after writing: {checksum_path}")
dir_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
print(f"Saved pre-departure status snapshot: {status_path}")
print(f"Saved pre-departure status checksum: {checksum_path}")
PY
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
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
      device_set=1
      shift 2
      ;;
    --output-dir)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      validate_output_dir_arg "${2:-}"
      output_dir="${2:-}"
      output_dir_set=1
      shift 2
      ;;
    --track-days)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      require_integer_at_most "$1" "${2:-}" "$max_track_days"
      track_days="$(normalize_decimal_integer "${2:-}")"
      track_days_set=1
      shift 2
      ;;
    --gps-seconds)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_integer "$1" "${2:-}"
      require_integer_at_most "$1" "${2:-}" "$max_gps_seconds"
      gps_seconds="$(normalize_decimal_integer "${2:-}")"
      gps_seconds_set=1
      shift 2
      ;;
    --retries)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_integer "$1" "${2:-}"
      require_integer_at_most "$1" "${2:-}" "$max_retries"
      retries="$(normalize_decimal_integer "${2:-}")"
      retries_set=1
      shift 2
      ;;
    --retry-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      require_integer_at_most "$1" "${2:-}" "$max_retry_delay"
      retry_delay="$(normalize_decimal_integer "${2:-}")"
      retry_delay_set=1
      shift 2
      ;;
    --force-refresh)
      force_refresh=1
      shift
      ;;
    --allow-dirty)
      allow_dirty=1
      allow_dirty_set=1
      shift
      ;;
    --opencpn-restarts)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      require_integer_at_most "$1" "${2:-}" "$max_opencpn_restarts"
      opencpn_restarts="$(normalize_decimal_integer "${2:-}")"
      opencpn_restarts_set=1
      shift 2
      ;;
    --opencpn-restart-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      require_integer_at_most "$1" "${2:-}" "$max_opencpn_restart_delay"
      opencpn_restart_delay="$(normalize_decimal_integer "${2:-}")"
      opencpn_restart_delay_set=1
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

if [[ "$skip_refresh" -eq 1 && ( "$retries_set" -eq 1 || "$retry_delay_set" -eq 1 || "$force_refresh" -eq 1 ) ]]; then
  echo "Chart-refresh options require the refresh step; remove --skip-refresh or omit --retries, --retry-delay, and --force-refresh" >&2
  exit 2
fi

if [[ "$skip_recovery" -eq 1 && ( "$output_dir_set" -eq 1 || "$track_days_set" -eq 1 ) ]]; then
  echo "Recovery export options require the recovery step; remove --skip-recovery or omit --output-dir and --track-days" >&2
  exit 2
fi

if [[ "$skip_pre_departure" -eq 1 && ( "$allow_dirty_set" -eq 1 || "$opencpn_restarts_set" -eq 1 || "$opencpn_restart_delay_set" -eq 1 ) ]]; then
  echo "Pre-departure verification options require the pre-departure step; remove --skip-pre-departure or omit --allow-dirty, --opencpn-restarts, and --opencpn-restart-delay" >&2
  exit 2
fi

if [[ "$skip_refresh" -eq 1 && "$skip_pre_departure" -eq 1 && "$gps_seconds_set" -eq 1 ]]; then
  echo "--gps-seconds requires a status or pre-departure check; remove --skip-refresh/--skip-pre-departure or omit --gps-seconds" >&2
  exit 2
fi

if [[ "$skip_pre_departure" -eq 1 && "$device_set" -eq 1 ]]; then
  echo "--device requires the pre-departure verification step; remove --skip-pre-departure or omit --device" >&2
  exit 2
fi

if [[ "$skip_recovery" -eq 0 ]]; then
  prepare_private_output_dir "Recovery output directory" "$output_dir"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
refresh_helper="${repo_root}/scripts/refresh_pi_charts.sh"
recovery_helper="${repo_root}/scripts/export_pi_recovery_bundle.sh"
verify_recovery_helper="${repo_root}/scripts/verify_pi_recovery_exports.sh"
pre_departure_helper="${repo_root}/scripts/pre_departure_check_pi.sh"
status_helper="${repo_root}/scripts/check_pi_status.sh"
python3_cmd="$(require_local_command python3)"
require_helper "$refresh_helper"
require_helper "$recovery_helper"
require_helper "$verify_recovery_helper"
require_helper "$pre_departure_helper"
require_helper "$status_helper"

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
  if [[ "$skip_recovery" -eq 0 ]]; then
    status_args=("$target")
    if [[ -n "$gps_seconds" ]]; then
      status_args+=(--gps-seconds "$gps_seconds")
    fi
    status_args+=(--json)
    save_pre_departure_status_snapshot "$recovery_dir" "$status_helper" "${status_args[@]}"
  fi
else
  printf '==> Skipping live pre-departure check\n'
fi

printf '\nPre-trip Pi preparation completed for %s.\n' "$target"
