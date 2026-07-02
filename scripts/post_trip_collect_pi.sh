#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/post_trip_collect_pi.sh user@raspberrypi.local [output-dir] [options]

Collects post-trip evidence from an already commissioned Raspberry Pi:
  1. Save a local private JSON status snapshot.
  2. Export GPX track logs.
  3. Collect a diagnostic support bundle.
  4. Optionally dry-run or request a clean Pi shutdown.

Options:
  --track-days N       Export GPX tracks modified in the last N days; 0 exports all
                       (default: 30, max: 3650)
  --gps-seconds N      Override the commissioned GPS fix wait in the status snapshot
                       (1-600)
  --skip-status        Skip the local private JSON status snapshot
  --skip-tracks        Skip GPX track export
  --skip-support       Skip diagnostic support bundle collection
  --shutdown-dry-run   Validate the remote shutdown path without powering off
  --shutdown-confirm   Request a clean Pi poweroff after collection

Options for skipped steps are rejected so status and track controls cannot be
mistaken for collection steps that still ran. Shutdown-only dry runs or
shutdown-only poweroff requests belong in scripts/shutdown_pi_safely.sh.
This wrapper writes local artifacts into output-dir. It does not install,
enable, reboot, download charts, or change persistent Pi state. Shutdown is
opt-in only.
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
output_dir="pi-post-trip-exports"
track_days=30
track_days_set=0
max_track_days=3650
gps_seconds=""
gps_seconds_set=0
max_gps_seconds=600
skip_status=0
skip_tracks=0
skip_support=0
shutdown_mode=""
python3_cmd=""

if [[ $# -gt 0 && "$1" != --* ]]; then
  output_dir="$1"
  shift
fi

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

utc_timestamp() {
  local stamp
  TZ=UTC0 printf -v stamp '%(%Y%m%dT%H%M%SZ)T' -1
  printf '%s\n' "$stamp"
}

verify_private_output_file() {
  local label="$1"
  local path="$2"
  if ! "$python3_cmd" - "$label" "$path" <<'PY'
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

label = sys.argv[1]
path = Path(sys.argv[2])
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


try:
    before = os.stat(path, follow_symlinks=False)
except OSError as exc:
    fail(f"Could not inspect {label}: {path}: {exc}")
if not stat.S_ISREG(before.st_mode):
    fail(f"{label} must be a regular non-symlink file: {path}")

try:
    fd = os.open(path, flags)
except OSError as exc:
    fail(f"Could not open {label} through no-follow descriptor: {path}: {exc}")
try:
    opened = os.fstat(fd)
    if not os.path.samestat(before, opened):
        fail(f"{label} changed while opening it: {path}")
    if not stat.S_ISREG(opened.st_mode):
        fail(f"{label} must be a regular file when opened: {path}")
    if opened.st_uid != os.getuid():
        fail(f"{label} is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}")
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        fail(f"{label} has permissions {mode:04o}, expected private 0600: {path}")
finally:
    os.close(fd)
PY
  then
    exit 2
  fi
}

write_private_status_snapshot() {
  local path="$1"
  shift
  "$python3_cmd" - "$path" "$@" <<'PY'
from __future__ import annotations

import os
import stat
import subprocess
import sys
from pathlib import Path

path = Path(sys.argv[1])
command = sys.argv[2:]
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)


def descriptor_helper_command(command: list[str]) -> tuple[list[str], int]:
    if not command:
        print("status snapshot helper command is missing", file=sys.stderr)
        raise SystemExit(124)
    helper = Path(command[0])
    if not helper.is_absolute():
        print(f"status snapshot helper command must be absolute: {helper}", file=sys.stderr)
        raise SystemExit(124)

    current = Path("/")
    for part in helper.parts[1:]:
        if part in {"", "."}:
            continue
        current = current / part
        try:
            component = os.lstat(current)
        except OSError as exc:
            print(f"Could not inspect status snapshot helper path component {current}: {exc}", file=sys.stderr)
            raise SystemExit(124) from exc
        if stat.S_ISLNK(component.st_mode):
            print(f"status snapshot helper path contains a symlink: {current}", file=sys.stderr)
            raise SystemExit(124)

    try:
        before = os.stat(helper, follow_symlinks=False)
    except OSError as exc:
        print(f"Could not inspect status snapshot helper before execution {helper}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    if not stat.S_ISREG(before.st_mode):
        print(f"status snapshot helper must be a regular file: {helper}", file=sys.stderr)
        raise SystemExit(124)
    if before.st_uid != os.getuid():
        print(
            f"status snapshot helper is owned by uid {before.st_uid}, expected current user {os.getuid()}: {helper}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(before.st_mode)
    if mode & 0o022:
        print(f"status snapshot helper has permissions {mode:03o}, expected no group/other write bits: {helper}", file=sys.stderr)
        raise SystemExit(124)
    if not mode & 0o111:
        print(f"status snapshot helper is not executable: {helper}", file=sys.stderr)
        raise SystemExit(124)

    try:
        helper_fd = os.open(helper, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        print(f"Could not open status snapshot helper through no-follow descriptor {helper}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    try:
        opened = os.fstat(helper_fd)
        if not os.path.samestat(before, opened):
            print(f"status snapshot helper changed before execution: {helper}", file=sys.stderr)
            raise SystemExit(124)
        if not stat.S_ISREG(opened.st_mode):
            print(f"status snapshot helper must be regular when opened: {helper}", file=sys.stderr)
            raise SystemExit(124)
        if opened.st_uid != os.getuid():
            print(
                f"status snapshot helper is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {helper}",
                file=sys.stderr,
            )
            raise SystemExit(124)
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode & 0o022:
            print(
                f"status snapshot helper has permissions {opened_mode:03o}, expected no group/other write bits: {helper}",
                file=sys.stderr,
            )
            raise SystemExit(124)
        if not opened_mode & 0o111:
            print(f"status snapshot helper is not executable when opened: {helper}", file=sys.stderr)
            raise SystemExit(124)
        return [f"/proc/self/fd/{helper_fd}", *command[1:]], helper_fd
    except BaseException:
        os.close(helper_fd)
        raise


def sync_private_parent_directory(target: Path) -> None:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(target.parent, follow_symlinks=False)
    except OSError as exc:
        print(f"Could not inspect status snapshot directory before sync {target.parent}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    if not stat.S_ISDIR(before.st_mode):
        print(f"status snapshot directory must be a real directory: {target.parent}", file=sys.stderr)
        raise SystemExit(124)
    if before.st_uid != os.getuid():
        print(
            f"status snapshot directory is owned by uid {before.st_uid}, expected current user {os.getuid()}: {target.parent}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o700:
        print(f"status snapshot directory has permissions {mode:04o}, expected private 0700: {target.parent}", file=sys.stderr)
        raise SystemExit(124)
    try:
        parent_fd = os.open(target.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
    except OSError as exc:
        print(f"Could not open status snapshot directory for sync {target.parent}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    try:
        opened = os.fstat(parent_fd)
        if not os.path.samestat(before, opened):
            print(f"status snapshot directory changed before sync: {target.parent}", file=sys.stderr)
            raise SystemExit(124)
        os.fsync(parent_fd)
    except OSError as exc:
        print(f"Could not sync status snapshot directory {target.parent}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    finally:
        os.close(parent_fd)


try:
    fd = os.open(path, flags, 0o600)
except OSError as exc:
    print(f"Could not create private status snapshot {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc

try:
    opened = os.fstat(fd)
    if not stat.S_ISREG(opened.st_mode):
        print(f"status snapshot must be a regular file: {path}", file=sys.stderr)
        raise SystemExit(124)
    if opened.st_uid != os.getuid():
        print(
            f"status snapshot is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        print(f"status snapshot has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
        raise SystemExit(124)
    with os.fdopen(fd, "wb") as output:
        fd = -1
        helper_command, helper_fd = descriptor_helper_command(command)
        try:
            result = subprocess.run(helper_command, stdout=output, pass_fds=(helper_fd,))
        finally:
            os.close(helper_fd)
        try:
            output.flush()
            os.fsync(output.fileno())
        except OSError as exc:
            print(f"Could not sync status snapshot file {path}: {exc}", file=sys.stderr)
            raise SystemExit(124) from exc
    sync_private_parent_directory(path)
    raise SystemExit(result.returncode)
finally:
    if fd >= 0:
        os.close(fd)
PY
  local status=$?
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

verify_status_snapshot_json() {
  local path="$1"
  local status
  set +e
  "$python3_cmd" - "$path" <<'PY'
from __future__ import annotations

import json
import math
import os
import re
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
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


def snapshot_text(value: object, label: str, path: Path) -> str:
    if not isinstance(value, str):
        fail(f"status snapshot JSON {label} is not a string: {path}")
    text = str(value)
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        fail(f"status snapshot JSON {label} contains control characters: {path}")
    return text.strip()


def snapshot_absolute_path(value: object, label: str, path: Path) -> str:
    text = snapshot_text(value, label, path)
    if not text or not Path(text).is_absolute():
        fail(f"status snapshot JSON {label} is not absolute: {path}")
    return text


SNAPSHOT_STATIC_DIAGNOSTICS = (
    "status snapshot JSON config_path is not absolute",
    "status snapshot JSON config chart_output is not absolute",
    "status snapshot JSON config track_output is not absolute",
    "status snapshot JSON track_log track_output is not absolute",
    "status snapshot JSON track_log tracks_dir is not absolute",
    "status snapshot JSON track_log latest_path is not absolute",
    "status snapshot JSON Manifest path is not absolute",
    "status snapshot JSON Manifest download path is not absolute",
    "status snapshot JSON Manifest extract path is not absolute",
    "status snapshot JSON Charts ENC cell sample path is not absolute",
    "status snapshot JSON OpenCPN Charts chart directory is not absolute",
    "status snapshot JSON OpenCPN Charts config path is not absolute",
    "status snapshot JSON OpenCPN GPSD config path is not absolute",
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


def validate_snapshot_gps_device_row(
    check_rows: dict[str, dict[str, object]],
    *,
    expected_device: str,
    path: Path,
) -> None:
    row = check_rows.get("GPS Device")
    if not isinstance(row, dict):
        fail(f"status snapshot JSON missing GPS Device readiness row: {path}")
    data = row.get("data")
    if not isinstance(data, dict):
        fail(f"status snapshot JSON GPS Device row has no structured data: {path}")
    configured_path = snapshot_text(data.get("configured_path", ""), "GPS Device path", path)
    if configured_path != expected_device:
        fail(f"status snapshot JSON GPS Device path does not match config gps_device: {path}")
    if not Path(configured_path).is_absolute():
        fail(f"status snapshot JSON GPS Device path is not absolute: {path}")
    if not stable_snapshot_gps_device_path(configured_path):
        fail(f"status snapshot JSON GPS Device path is not stable: {path}")
    if data.get("stable_path") is not True:
        fail(f"status snapshot JSON GPS Device missing stable path evidence: {path}")
    if data.get("volatile_path") is True:
        fail(f"status snapshot JSON GPS Device path is volatile: {path}")
    if data.get("exists") is not True:
        fail(f"status snapshot JSON GPS Device path does not exist: {path}")
    if data.get("is_directory") is True:
        fail(f"status snapshot JSON GPS Device path is a directory: {path}")
    if configured_path.startswith(("/dev/serial/by-id/", "/dev/serial/by-path/")) and data.get("is_symlink") is not True:
        fail(f"status snapshot JSON GPS Device udev path is not a symlink: {path}")
    if data.get("is_character_device") is not True:
        fail(f"status snapshot JSON GPS Device is not a character device: {path}")
    resolved_path = snapshot_text(data.get("resolved_path", ""), "GPS Device resolved path", path)
    if not Path(resolved_path).is_absolute():
        fail(f"status snapshot JSON GPS Device resolved path is not absolute: {path}")


def parse_snapshot_timestamp(value: object, field: str, path: Path) -> datetime:
    if not isinstance(value, str) or not value.strip():
        fail(f"status snapshot JSON {field} timestamp is missing: {path}")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"status snapshot JSON {field} timestamp is invalid: {path}: {exc}")
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        fail(f"status snapshot JSON {field} timestamp must include a timezone: {path}")
    return parsed.astimezone(timezone.utc)


def validate_snapshot_age(
    value: object,
    *,
    timestamp: datetime,
    generated_at: datetime,
    field: str,
    path: Path,
) -> None:
    reported_age = finite_status_float(value)
    if reported_age is None:
        fail(f"status snapshot JSON {field} age_seconds is not numeric: {path}")
    if reported_age < 0:
        fail(f"status snapshot JSON {field} age_seconds is negative: {path}")
    if reported_age > 600:
        fail(f"status snapshot JSON {field} age_seconds is stale: {path}")
    timestamp_age = (generated_at - timestamp).total_seconds()
    if timestamp_age < -STATUS_FUTURE_TOLERANCE_SECONDS:
        fail(f"status snapshot JSON {field} timestamp is after generated_at: {path}")
    if abs(reported_age - timestamp_age) > STATUS_FUTURE_TOLERANCE_SECONDS:
        fail(f"status snapshot JSON {field} age_seconds is inconsistent with timestamp age: {path}")


def validate_snapshot_quality(
    summary: dict[str, object],
    *,
    satellite_field: str,
    hdop_field: str,
    label: str,
    path: Path,
) -> None:
    satellites = summary.get(satellite_field)
    hdop = summary.get(hdop_field)
    if satellites is None and hdop is None:
        fail(f"status snapshot JSON {label} has no satellite or HDOP quality fields: {path}")
    if satellites is not None and (
        isinstance(satellites, bool) or not isinstance(satellites, int) or satellites < 4
    ):
        fail(f"status snapshot JSON {label} satellites is weak or invalid: {path}")
    parsed_hdop = finite_status_float(hdop)
    if hdop is not None and (parsed_hdop is None or parsed_hdop < 0.0 or parsed_hdop > 5.0):
        fail(f"status snapshot JSON {label} HDOP is weak or invalid: {path}")


def private_octal_mode(value: object, *, field: str, path: Path) -> int:
    if not isinstance(value, str):
        fail(f"status snapshot JSON track_log {field} is missing or invalid: {path}")
    text = value.strip()
    if not text:
        fail(f"status snapshot JSON track_log {field} is missing or invalid: {path}")
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        fail(f"status snapshot JSON track_log {field} is missing or invalid: {path}")
    try:
        mode = int(text, 8)
    except ValueError:
        fail(f"status snapshot JSON track_log {field} is missing or invalid: {path}")
    if mode < 0 or mode > 0o7777:
        fail(f"status snapshot JSON track_log {field} is missing or invalid: {path}")
    if mode & 0o077:
        fail(f"status snapshot JSON track_log {field} is not private: {path}")
    return mode


def snapshot_octal_mode(value: object, *, label: str, path: Path) -> int:
    if not isinstance(value, str):
        fail(f"status snapshot JSON {label} mode is invalid: {path}")
    text = value.strip()
    if not text:
        fail(f"status snapshot JSON {label} mode is invalid: {path}")
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        fail(f"status snapshot JSON {label} mode is invalid: {path}")
    try:
        mode = int(text, 8)
    except ValueError:
        fail(f"status snapshot JSON {label} mode is invalid: {path}")
    if mode < 0 or mode > 0o7777:
        fail(f"status snapshot JSON {label} mode is invalid: {path}")
    return mode


def snapshot_uid(value: object, *, label: str, path: Path) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail(f"status snapshot JSON {label} owner is invalid: {path}")
    return value


def validate_snapshot_autostart(payload: dict[str, object], *, path: Path) -> None:
    desktop = payload.get("desktop")
    if not isinstance(desktop, dict):
        fail(f"status snapshot JSON missing desktop section: {path}")
    autostart = desktop.get("autostart")
    if not isinstance(autostart, dict):
        fail(f"status snapshot JSON missing desktop autostart evidence: {path}")
    autostart_path = snapshot_text(autostart.get("path", ""), "desktop autostart path", path)
    if not autostart_path or not Path(autostart_path).is_absolute():
        fail(f"status snapshot JSON desktop autostart path is not absolute: {path}")
    if Path(autostart_path).name != "noaa-navionics-chartplotter.desktop":
        fail(f"status snapshot JSON desktop autostart path has unexpected filename: {path}")
    if autostart.get("exists") is not True:
        fail(f"status snapshot JSON desktop autostart does not exist: {path}")
    if autostart.get("is_symlink") is not False:
        fail(f"status snapshot JSON desktop autostart path is a symlink or missing symlink status: {path}")
    if autostart.get("directory_is_symlink") is not False:
        fail(f"status snapshot JSON desktop autostart directory is a symlink or missing symlink status: {path}")
    if "path_symlink_component" not in autostart:
        fail(f"status snapshot JSON desktop autostart missing path_symlink_component: {path}")
    if snapshot_text(autostart.get("path_symlink_component", ""), "desktop autostart path_symlink_component", path):
        fail(f"status snapshot JSON desktop autostart path contains a symlink: {path}")
    snapshot_uid(autostart.get("uid"), label="desktop autostart", path=path)
    snapshot_uid(autostart.get("directory_uid"), label="desktop autostart directory", path=path)
    mode = snapshot_octal_mode(autostart.get("mode"), label="desktop autostart", path=path)
    if mode & 0o022:
        fail(f"status snapshot JSON desktop autostart is group/world writable: {path}")
    directory_mode = snapshot_octal_mode(
        autostart.get("directory_mode"),
        label="desktop autostart directory",
        path=path,
    )
    if directory_mode & 0o022:
        fail(f"status snapshot JSON desktop autostart directory is group/world writable: {path}")
    values = autostart.get("values")
    if not isinstance(values, dict):
        fail(f"status snapshot JSON desktop autostart values were not parsed: {path}")
    for key, expected in EXPECTED_DESKTOP_AUTOSTART_VALUES.items():
        actual = str(values.get(key, "")).strip()
        if actual != expected:
            fail(f"status snapshot JSON desktop autostart {key} does not match expected value: {path}")
    if str(values.get("Hidden", "")).strip().lower() == "true":
        fail(f"status snapshot JSON desktop autostart is hidden: {path}")


def validate_snapshot_mob_launcher(payload: dict[str, object], *, path: Path) -> None:
    desktop = payload.get("desktop")
    if not isinstance(desktop, dict):
        fail(f"status snapshot JSON missing desktop section: {path}")
    mob_launcher = desktop.get("mob_launcher")
    if not isinstance(mob_launcher, dict):
        fail(f"status snapshot JSON missing MOB desktop launcher evidence: {path}")
    launcher_path = snapshot_text(mob_launcher.get("path", ""), "MOB desktop launcher path", path)
    if not launcher_path or not Path(launcher_path).is_absolute():
        fail(f"status snapshot JSON MOB desktop launcher path is not absolute: {path}")
    if Path(launcher_path).name != "noaa-navionics-mob.desktop":
        fail(f"status snapshot JSON MOB desktop launcher path has unexpected filename: {path}")
    if mob_launcher.get("exists") is not True:
        fail(f"status snapshot JSON MOB desktop launcher does not exist: {path}")
    if mob_launcher.get("is_symlink") is not False:
        fail(f"status snapshot JSON MOB desktop launcher path is a symlink or missing symlink status: {path}")
    if mob_launcher.get("directory_is_symlink") is not False:
        fail(f"status snapshot JSON MOB desktop launcher directory is a symlink or missing symlink status: {path}")
    if "path_symlink_component" not in mob_launcher:
        fail(f"status snapshot JSON MOB desktop launcher missing path_symlink_component: {path}")
    if snapshot_text(mob_launcher.get("path_symlink_component", ""), "MOB desktop launcher path_symlink_component", path):
        fail(f"status snapshot JSON MOB desktop launcher path contains a symlink: {path}")
    snapshot_uid(mob_launcher.get("uid"), label="MOB desktop launcher", path=path)
    snapshot_uid(mob_launcher.get("directory_uid"), label="MOB desktop launcher directory", path=path)
    mode = snapshot_octal_mode(mob_launcher.get("mode"), label="MOB desktop launcher", path=path)
    if mode & 0o022:
        fail(f"status snapshot JSON MOB desktop launcher is group/world writable: {path}")
    if not mode & 0o100:
        fail(f"status snapshot JSON MOB desktop launcher is not user executable: {path}")
    directory_mode = snapshot_octal_mode(
        mob_launcher.get("directory_mode"),
        label="MOB desktop launcher directory",
        path=path,
    )
    if directory_mode & 0o022:
        fail(f"status snapshot JSON MOB desktop launcher directory is group/world writable: {path}")
    values = mob_launcher.get("values")
    if not isinstance(values, dict):
        fail(f"status snapshot JSON MOB desktop launcher values were not parsed: {path}")
    for key, expected in EXPECTED_MOB_LAUNCHER_VALUES.items():
        actual = str(values.get(key, "")).strip()
        if actual != expected:
            fail(f"status snapshot JSON MOB desktop launcher {key} does not match expected value: {path}")
    if str(values.get("Hidden", "")).strip().lower() == "true":
        fail(f"status snapshot JSON MOB desktop launcher is hidden: {path}")
    if str(values.get("X-GNOME-Autostart-enabled", "")).strip().lower() == "true":
        fail(f"status snapshot JSON MOB desktop launcher must not be configured for autostart: {path}")


def validate_snapshot_status_launcher(payload: dict[str, object], *, path: Path) -> None:
    desktop = payload.get("desktop")
    if not isinstance(desktop, dict):
        fail(f"status snapshot JSON missing desktop section: {path}")
    status_launcher = desktop.get("status_launcher")
    if not isinstance(status_launcher, dict):
        fail(f"status snapshot JSON missing status GUI desktop launcher evidence: {path}")
    launcher_path = snapshot_text(status_launcher.get("path", ""), "status GUI desktop launcher path", path)
    if not launcher_path or not Path(launcher_path).is_absolute():
        fail(f"status snapshot JSON status GUI desktop launcher path is not absolute: {path}")
    if Path(launcher_path).name != "noaa-navionics-status.desktop":
        fail(f"status snapshot JSON status GUI desktop launcher path has unexpected filename: {path}")
    if status_launcher.get("exists") is not True:
        fail(f"status snapshot JSON status GUI desktop launcher does not exist: {path}")
    if status_launcher.get("is_symlink") is not False:
        fail(f"status snapshot JSON status GUI desktop launcher path is a symlink or missing symlink status: {path}")
    if status_launcher.get("directory_is_symlink") is not False:
        fail(f"status snapshot JSON status GUI desktop launcher directory is a symlink or missing symlink status: {path}")
    if "path_symlink_component" not in status_launcher:
        fail(f"status snapshot JSON status GUI desktop launcher missing path_symlink_component: {path}")
    if snapshot_text(status_launcher.get("path_symlink_component", ""), "status GUI desktop launcher path_symlink_component", path):
        fail(f"status snapshot JSON status GUI desktop launcher path contains a symlink: {path}")
    snapshot_uid(status_launcher.get("uid"), label="status GUI desktop launcher", path=path)
    snapshot_uid(status_launcher.get("directory_uid"), label="status GUI desktop launcher directory", path=path)
    mode = snapshot_octal_mode(status_launcher.get("mode"), label="status GUI desktop launcher", path=path)
    if mode & 0o022:
        fail(f"status snapshot JSON status GUI desktop launcher is group/world writable: {path}")
    if not mode & 0o100:
        fail(f"status snapshot JSON status GUI desktop launcher is not user executable: {path}")
    directory_mode = snapshot_octal_mode(
        status_launcher.get("directory_mode"),
        label="status GUI desktop launcher directory",
        path=path,
    )
    if directory_mode & 0o022:
        fail(f"status snapshot JSON status GUI desktop launcher directory is group/world writable: {path}")
    values = status_launcher.get("values")
    if not isinstance(values, dict):
        fail(f"status snapshot JSON status GUI desktop launcher values were not parsed: {path}")
    for key, expected in EXPECTED_STATUS_LAUNCHER_VALUES.items():
        actual = str(values.get(key, "")).strip()
        if actual != expected:
            fail(f"status snapshot JSON status GUI desktop launcher {key} does not match expected value: {path}")
    if str(values.get("Hidden", "")).strip().lower() == "true":
        fail(f"status snapshot JSON status GUI desktop launcher is hidden: {path}")
    if str(values.get("X-GNOME-Autostart-enabled", "")).strip().lower() == "true":
        fail(f"status snapshot JSON status GUI desktop launcher must not be configured for autostart: {path}")


def validate_track_log_paths(track_log: dict[str, object], *, path: Path) -> None:
    track_output = snapshot_absolute_path(track_log.get("track_output", ""), "track_log track_output", path)
    tracks_dir = snapshot_absolute_path(track_log.get("tracks_dir", ""), "track_log tracks_dir", path)
    latest_path = snapshot_text(track_log.get("latest_path", ""), "track_log latest_path", path)
    if str(Path(track_output) / "tracks") != tracks_dir:
        fail(f"status snapshot JSON track_log tracks_dir does not match track_output: {path}")
    if not latest_path:
        fail(f"status snapshot JSON track_log missing latest_path: {path}")
    if not Path(latest_path).is_absolute():
        fail(f"status snapshot JSON track_log latest_path is not absolute: {path}")
    normalized_latest = os.path.normpath(latest_path)
    normalized_tracks = os.path.normpath(tracks_dir)
    try:
        latest_common = os.path.commonpath([normalized_latest, normalized_tracks])
    except ValueError:
        latest_common = ""
    if normalized_latest == normalized_tracks or latest_common != normalized_tracks:
        fail(f"status snapshot JSON track_log latest_path is not under tracks_dir: {path}")
    latest_name = Path(latest_path).name
    if not latest_name.startswith("track-") or Path(latest_name).suffix.lower() != ".gpx":
        fail(f"status snapshot JSON track_log latest_path is not a track-*.gpx file: {path}")
    private_octal_mode(track_log.get("tracks_mode"), field="tracks_mode", path=path)
    private_octal_mode(track_log.get("latest_mode"), field="latest_mode", path=path)


def validate_snapshot_gps_fix(
    gps_fix: dict[str, object],
    *,
    gps_mode: str,
    generated_at: datetime,
    path: Path,
) -> None:
    expected_source = "GPS" if gps_mode == "serial" else "GPSD"
    source = snapshot_text(gps_fix.get("source", ""), "gps_fix source", path)
    if source != expected_source:
        fail(f"status snapshot JSON gps_fix source {source or '<missing>'} does not match {expected_source}: {path}")
    latitude = finite_status_float(gps_fix.get("latitude"))
    longitude = finite_status_float(gps_fix.get("longitude"))
    if latitude is None or longitude is None:
        fail(f"status snapshot JSON gps_fix has non-numeric coordinates: {path}")
    if not -90.0 <= latitude <= 90.0:
        fail(f"status snapshot JSON gps_fix latitude is outside -90..90: {path}")
    if not -180.0 <= longitude <= 180.0:
        fail(f"status snapshot JSON gps_fix longitude is outside -180..180: {path}")
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        fail(f"status snapshot JSON gps_fix coordinates are invalid 0,0: {path}")
    timestamp = parse_snapshot_timestamp(gps_fix.get("timestamp"), "gps_fix", path)
    validate_snapshot_age(
        gps_fix.get("age_seconds"),
        timestamp=timestamp,
        generated_at=generated_at,
        field="gps_fix",
        path=path,
    )
    validate_snapshot_quality(gps_fix, satellite_field="satellites", hdop_field="hdop", label="gps_fix", path=path)


def validate_snapshot_track_log(track_log: dict[str, object], *, generated_at: datetime, path: Path) -> None:
    if track_log.get("track_output_is_symlink") is not False:
        fail(f"status snapshot JSON track_log track_output is a symlink or missing symlink status: {path}")
    if "track_storage_symlink_component" not in track_log:
        fail(f"status snapshot JSON track_log missing track_storage_symlink_component: {path}")
    if snapshot_text(track_log.get("track_storage_symlink_component", ""), "track_log track_storage_symlink_component", path):
        fail(f"status snapshot JSON track_log storage path contains a symlink: {path}")
    validate_track_log_paths(track_log, path=path)
    latitude = finite_status_float(track_log.get("latest_latitude"))
    longitude = finite_status_float(track_log.get("latest_longitude"))
    if latitude is None or longitude is None:
        fail(f"status snapshot JSON track_log has non-numeric latest coordinates: {path}")
    if not -90.0 <= latitude <= 90.0:
        fail(f"status snapshot JSON track_log latest_latitude is outside -90..90: {path}")
    if not -180.0 <= longitude <= 180.0:
        fail(f"status snapshot JSON track_log latest_longitude is outside -180..180: {path}")
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        fail(f"status snapshot JSON track_log latest coordinates are invalid 0,0: {path}")
    latest_time = parse_snapshot_timestamp(track_log.get("latest_time"), "track_log latest_time", path)
    validate_snapshot_age(
        track_log.get("age_seconds"),
        timestamp=latest_time,
        generated_at=generated_at,
        field="track_log",
        path=path,
    )
    validate_snapshot_quality(
        track_log,
        satellite_field="latest_satellites",
        hdop_field="latest_hdop",
        label="track_log",
        path=path,
    )


def validate_snapshot_gps_row(
    check_rows: dict[str, dict[str, object]],
    *,
    gps_mode: str,
    gps_fix: dict[str, object],
    path: Path,
) -> None:
    expected_name = "GPS" if gps_mode == "serial" else "GPSD"
    row = check_rows.get(expected_name)
    if not isinstance(row, dict):
        fail(f"status snapshot JSON missing {expected_name} readiness row: {path}")
    data = row.get("data")
    if not isinstance(data, dict):
        fail(f"status snapshot JSON {expected_name} row has no structured fix data: {path}")
    latitude = finite_status_float(data.get("latitude"))
    longitude = finite_status_float(data.get("longitude"))
    if latitude is None or longitude is None:
        fail(f"status snapshot JSON {expected_name} row has non-numeric coordinates: {path}")
    summary_latitude = finite_status_float(gps_fix.get("latitude"))
    summary_longitude = finite_status_float(gps_fix.get("longitude"))
    if summary_latitude is not None and abs(latitude - summary_latitude) > 1e-7:
        fail(f"status snapshot JSON {expected_name} latitude does not match gps_fix: {path}")
    if summary_longitude is not None and abs(longitude - summary_longitude) > 1e-7:
        fail(f"status snapshot JSON {expected_name} longitude does not match gps_fix: {path}")
    timestamp = parse_snapshot_timestamp(data.get("timestamp"), f"{expected_name} row", path)
    summary_timestamp = parse_snapshot_timestamp(gps_fix.get("timestamp"), "gps_fix", path)
    if timestamp != summary_timestamp:
        fail(f"status snapshot JSON {expected_name} timestamp does not match gps_fix: {path}")
    validate_snapshot_quality(data, satellite_field="satellites", hdop_field="hdop", label=f"{expected_name} row", path=path)
    if gps_fix.get("satellites") is not None and data.get("satellites") != gps_fix.get("satellites"):
        fail(f"status snapshot JSON {expected_name} satellites do not match gps_fix: {path}")
    if gps_fix.get("hdop") is not None:
        row_hdop = finite_status_float(data.get("hdop"))
        summary_hdop = finite_status_float(gps_fix.get("hdop"))
        if row_hdop is None or summary_hdop is None or abs(row_hdop - summary_hdop) > 1e-9:
            fail(f"status snapshot JSON {expected_name} HDOP does not match gps_fix: {path}")


def validate_snapshot_track_log_row(
    service_rows: dict[str, dict[str, object]],
    *,
    track_log: dict[str, object],
    path: Path,
) -> None:
    row = service_rows.get("Track Log")
    if not isinstance(row, dict):
        fail(f"status snapshot JSON missing Track Log service row: {path}")
    data = row.get("data")
    if not isinstance(data, dict):
        fail(f"status snapshot JSON Track Log service row has no structured track_log data: {path}")
    for field in (
        "track_output",
        "tracks_dir",
        "latest_path",
        "latest_time",
        "latest_latitude",
        "latest_longitude",
        "age_seconds",
        "latest_satellites",
        "latest_hdop",
    ):
        if field in track_log and data.get(field) != track_log.get(field):
            fail(f"status snapshot JSON Track Log {field} does not match track_log: {path}")


def validate_snapshot_manifest_row(
    check_rows: dict[str, dict[str, object]],
    *,
    config: dict[str, object],
    manifest: object,
    path: Path,
) -> None:
    row = check_rows.get("Manifest")
    if not isinstance(row, dict):
        fail(f"status snapshot JSON missing Manifest readiness row: {path}")
    data = row.get("data")
    if not isinstance(data, dict):
        fail(f"status snapshot JSON Manifest row has no structured data: {path}")
    if not isinstance(manifest, dict):
        fail(f"status snapshot JSON Manifest row has no top-level manifest summary: {path}")
    chart_output = snapshot_absolute_path(config.get("chart_output", ""), "config chart_output", path)
    configured_path = snapshot_absolute_path(data.get("configured_path", ""), "Manifest configured path", path)
    if configured_path != chart_output:
        fail(f"status snapshot JSON Manifest configured path does not match config chart_output: {path}")
    manifest_path = snapshot_absolute_path(data.get("path", ""), "Manifest path", path)
    if manifest_path != str(Path(chart_output) / "noaa-navionics-manifest.json"):
        fail(f"status snapshot JSON Manifest path does not match config chart_output: {path}")
    if manifest_path != snapshot_absolute_path(manifest.get("path", ""), "manifest summary path", path):
        fail(f"status snapshot JSON Manifest path does not match manifest summary: {path}")
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
        row_value = snapshot_text(data.get(row_field, ""), f"Manifest {row_field}", path)
        summary_value = snapshot_text(manifest.get(summary_field, ""), f"manifest summary {summary_field}", path)
        if row_value != summary_value:
            fail(f"status snapshot JSON Manifest {row_field} does not match manifest summary: {path}")
    created_at_source = snapshot_text(data.get("created_at_source", ""), "Manifest created_at_source", path)
    if created_at_source not in {"download", "previous-manifest"}:
        fail(f"status snapshot JSON Manifest created_at_source is not verified: {path}")
    normalized_chart_output = os.path.normpath(chart_output)
    for row_field, label in (
        ("download_path", "Manifest download path"),
        ("extract_path", "Manifest extract path"),
    ):
        manifest_storage_path = snapshot_absolute_path(data.get(row_field, ""), label, path)
        normalized_storage_path = os.path.normpath(manifest_storage_path)
        try:
            storage_common = os.path.commonpath([normalized_storage_path, normalized_chart_output])
        except ValueError:
            storage_common = ""
        if normalized_storage_path == normalized_chart_output or storage_common != normalized_chart_output:
            if row_field == "download_path":
                fail(f"status snapshot JSON Manifest download path is outside chart_output: {path}")
            fail(f"status snapshot JSON Manifest extract path is outside chart_output: {path}")
    parse_snapshot_timestamp(data.get("created_at"), "Manifest created_at", path)
    download_bytes = positive_status_int(data.get("download_bytes"))
    summary_download_bytes = positive_status_int(manifest.get("download_bytes"))
    if download_bytes is None:
        fail(f"status snapshot JSON Manifest download byte count is not positive: {path}")
    if summary_download_bytes is not None and download_bytes != summary_download_bytes:
        fail(f"status snapshot JSON Manifest download byte count does not match manifest summary: {path}")
    enc_cell_count = positive_status_int(data.get("enc_cell_count"))
    actual_enc_cell_count = positive_status_int(data.get("actual_enc_cell_count"))
    summary_enc_cell_count = positive_status_int(manifest.get("enc_cell_count"))
    summary_actual_enc_cell_count = positive_status_int(manifest.get("actual_enc_cell_count"))
    if enc_cell_count is None:
        fail(f"status snapshot JSON Manifest has no ENC cells: {path}")
    if actual_enc_cell_count is None:
        fail(f"status snapshot JSON Manifest actual ENC cell count is not positive: {path}")
    if enc_cell_count is not None and actual_enc_cell_count is not None and enc_cell_count != actual_enc_cell_count:
        fail(f"status snapshot JSON Manifest actual ENC cell count does not match recorded count: {path}")
    if enc_cell_count is not None and summary_enc_cell_count is not None and enc_cell_count != summary_enc_cell_count:
        fail(f"status snapshot JSON Manifest ENC cell count does not match manifest summary: {path}")
    if (
        actual_enc_cell_count is not None
        and summary_actual_enc_cell_count is not None
        and actual_enc_cell_count != summary_actual_enc_cell_count
    ):
        fail(f"status snapshot JSON Manifest actual ENC cell count does not match manifest summary: {path}")


def validate_snapshot_chart_rows(check_rows: dict[str, dict[str, object]], *, config: dict[str, object], path: Path) -> None:
    chart_output = snapshot_absolute_path(config.get("chart_output", ""), "config chart_output", path)

    charts_row = check_rows.get("Charts")
    if not isinstance(charts_row, dict):
        fail(f"status snapshot JSON missing Charts readiness row: {path}")
    charts_data = charts_row.get("data")
    if not isinstance(charts_data, dict):
        fail(f"status snapshot JSON Charts row has no structured data: {path}")
    configured_path = snapshot_absolute_path(charts_data.get("configured_path", ""), "Charts path", path)
    if configured_path != chart_output:
        fail(f"status snapshot JSON Charts path does not match config chart_output: {path}")
    if charts_data.get("exists") is not True:
        fail(f"status snapshot JSON Charts path does not exist: {path}")
    if snapshot_text(charts_data.get("storage_symlink_component", ""), "Charts storage_symlink_component", path):
        fail(f"status snapshot JSON Charts path contains a symlink: {path}")
    if charts_data.get("has_extracted_enc_cells") is not True:
        fail(f"status snapshot JSON Charts found no extracted ENC cells: {path}")
    if charts_data.get("has_unextracted_zips") is not False:
        fail(f"status snapshot JSON Charts found unextracted ZIP chart artifacts: {path}")
    zip_samples = charts_data.get("zip_samples")
    if not isinstance(zip_samples, list) or zip_samples:
        fail(f"status snapshot JSON Charts ZIP sample list is not empty: {path}")
    enc_cell_samples = charts_data.get("enc_cell_samples")
    if not isinstance(enc_cell_samples, list) or not enc_cell_samples:
        fail(f"status snapshot JSON Charts has no ENC cell sample paths: {path}")
    if any(not Path(snapshot_text(sample, "Charts ENC cell sample path", path)).is_absolute() for sample in enc_cell_samples):
        fail(f"status snapshot JSON Charts ENC cell sample path is not absolute: {path}")
    normalized_chart_output = os.path.normpath(chart_output)
    for sample in enc_cell_samples:
        normalized_sample = os.path.normpath(snapshot_text(sample, "Charts ENC cell sample path", path))
        try:
            sample_common = os.path.commonpath([normalized_sample, normalized_chart_output])
        except ValueError:
            sample_common = ""
        if normalized_sample == normalized_chart_output or sample_common != normalized_chart_output:
            fail(f"status snapshot JSON Charts ENC cell sample path is outside chart_output: {path}")

    debris_row = check_rows.get("Chart Update Debris")
    if not isinstance(debris_row, dict):
        fail(f"status snapshot JSON missing Chart Update Debris readiness row: {path}")
    debris_data = debris_row.get("data")
    if not isinstance(debris_data, dict):
        fail(f"status snapshot JSON Chart Update Debris row has no structured data: {path}")
    configured_path = snapshot_absolute_path(debris_data.get("configured_path", ""), "Chart Update Debris path", path)
    if configured_path != chart_output:
        fail(f"status snapshot JSON Chart Update Debris path does not match config chart_output: {path}")
    if snapshot_text(debris_data.get("storage_symlink_component", ""), "Chart Update Debris storage_symlink_component", path):
        fail(f"status snapshot JSON Chart Update Debris path contains a symlink: {path}")
    debris_count = debris_data.get("debris_count")
    if isinstance(debris_count, bool) or not isinstance(debris_count, int) or debris_count != 0:
        fail(f"status snapshot JSON Chart Update Debris found stale update debris: {path}")
    debris = debris_data.get("debris")
    if not isinstance(debris, list) or debris:
        fail(f"status snapshot JSON Chart Update Debris debris list is not empty: {path}")
    if debris_data.get("clean") is not True:
        fail(f"status snapshot JSON Chart Update Debris did not prove a clean chart directory: {path}")

    opencpn_row = check_rows.get("OpenCPN Charts")
    if not isinstance(opencpn_row, dict):
        fail(f"status snapshot JSON missing OpenCPN Charts readiness row: {path}")
    opencpn_data = opencpn_row.get("data")
    if not isinstance(opencpn_data, dict):
        fail(f"status snapshot JSON OpenCPN Charts row has no structured data: {path}")
    chart_dir = snapshot_absolute_path(opencpn_data.get("chart_dir", ""), "OpenCPN Charts chart directory", path)
    if chart_dir != chart_output:
        fail(f"status snapshot JSON OpenCPN Charts chart directory does not match config chart_output: {path}")
    snapshot_absolute_path(opencpn_data.get("config_path", ""), "OpenCPN Charts config path", path)
    if opencpn_data.get("config_exists") is not True:
        fail(f"status snapshot JSON OpenCPN Charts config does not exist: {path}")
    if opencpn_data.get("chart_dir_exists") is not True:
        fail(f"status snapshot JSON OpenCPN Charts chart directory does not exist: {path}")
    if opencpn_data.get("configured") is not True:
        fail(f"status snapshot JSON OpenCPN Charts did not prove configured chart directory: {path}")
    chart_directories = opencpn_data.get("chart_directories")
    if not isinstance(chart_directories, list) or not chart_directories:
        fail(f"status snapshot JSON OpenCPN Charts has no parsed chart directories: {path}")
    parsed_chart_directories = [snapshot_text(directory, "OpenCPN Charts parsed directory", path) for directory in chart_directories]
    if not any(directory == chart_output for directory in parsed_chart_directories):
        fail(f"status snapshot JSON OpenCPN Charts parsed directories do not include configured chart output: {path}")


def normalize_snapshot_gpsd_host(value: object) -> str:
    host = str(value).strip().lower()
    return "127.0.0.1" if host in {"localhost", "::1"} else host


def validate_snapshot_gpsd_rows(
    check_rows: dict[str, dict[str, object]],
    *,
    config: dict[str, object],
    path: Path,
) -> None:
    expected_device = snapshot_text(config.get("gps_device", ""), "config gps_device", path)
    if not expected_device:
        fail(f"status snapshot JSON missing config gps_device: {path}")
    expected_host = normalize_snapshot_gpsd_host(snapshot_text(config.get("gpsd_host", ""), "config gpsd_host", path))
    if expected_host not in {"127.0.0.1", "0.0.0.0"}:
        fail(f"status snapshot JSON config gpsd_host is not local: {path}")
    expected_port = config.get("gpsd_port")
    if isinstance(expected_port, bool) or not isinstance(expected_port, int) or not (1 <= expected_port <= 65535):
        fail(f"status snapshot JSON config gpsd_port is invalid: {path}")

    opencpn_row = check_rows.get("OpenCPN GPSD")
    if not isinstance(opencpn_row, dict):
        fail(f"status snapshot JSON missing OpenCPN GPSD readiness row: {path}")
    opencpn_data = opencpn_row.get("data")
    if not isinstance(opencpn_data, dict):
        fail(f"status snapshot JSON OpenCPN GPSD row has no structured data: {path}")
    snapshot_absolute_path(opencpn_data.get("config_path", ""), "OpenCPN GPSD config path", path)
    if opencpn_data.get("config_exists") is not True:
        fail(f"status snapshot JSON OpenCPN GPSD config does not exist: {path}")
    if normalize_snapshot_gpsd_host(opencpn_data.get("expected_host", "")) != expected_host:
        fail(f"status snapshot JSON OpenCPN GPSD host does not match config gpsd_host: {path}")
    if opencpn_data.get("expected_port") != expected_port:
        fail(f"status snapshot JSON OpenCPN GPSD port does not match config gpsd_port: {path}")
    if opencpn_data.get("configured") is not True:
        fail(f"status snapshot JSON OpenCPN GPSD did not prove configured endpoint: {path}")
    connections = opencpn_data.get("enabled_gpsd_connections")
    if not isinstance(connections, list) or not connections:
        fail(f"status snapshot JSON OpenCPN GPSD has no parsed enabled GPSD connections: {path}")
    if not any(
        isinstance(connection, dict)
        and normalize_snapshot_gpsd_host(connection.get("host", "")) == expected_host
        and connection.get("port") == expected_port
        for connection in connections
    ):
        fail(f"status snapshot JSON OpenCPN GPSD parsed connections do not include configured endpoint: {path}")
    unexpected = opencpn_data.get("unexpected_connections")
    if not isinstance(unexpected, list):
        fail(f"status snapshot JSON OpenCPN GPSD unexpected connection list was not parsed: {path}")
    if unexpected:
        fail(f"status snapshot JSON OpenCPN GPSD found unexpected enabled GPSD connections: {path}")

    gpsd_config_row = check_rows.get("GPSD Config")
    if not isinstance(gpsd_config_row, dict):
        fail(f"status snapshot JSON missing GPSD Config readiness row: {path}")
    gpsd_config_data = gpsd_config_row.get("data")
    if not isinstance(gpsd_config_data, dict):
        fail(f"status snapshot JSON GPSD Config row has no structured data: {path}")
    if snapshot_text(gpsd_config_data.get("path", ""), "GPSD Config path", path) != "/etc/default/gpsd":
        fail(f"status snapshot JSON GPSD Config path is not /etc/default/gpsd: {path}")
    if gpsd_config_data.get("exists") is not True:
        fail(f"status snapshot JSON GPSD Config path does not exist: {path}")
    if gpsd_config_data.get("is_symlink") is not False:
        fail(f"status snapshot JSON GPSD Config path is a symlink: {path}")
    if snapshot_text(gpsd_config_data.get("directory_symlink_component", ""), "GPSD Config directory_symlink_component", path):
        fail(f"status snapshot JSON GPSD Config directory contains a symlink: {path}")
    if gpsd_config_data.get("is_regular") is not True:
        fail(f"status snapshot JSON GPSD Config path is not a regular file: {path}")
    if gpsd_config_data.get("expected_device") != expected_device:
        fail(f"status snapshot JSON GPSD Config expected device does not match config: {path}")
    devices = gpsd_config_data.get("devices")
    if devices != [expected_device]:
        fail(f"status snapshot JSON GPSD Config devices do not match configured GPS device: {path}")
    if gpsd_config_data.get("start_daemon") != "true":
        fail(f"status snapshot JSON GPSD Config START_DAEMON is not true: {path}")
    if gpsd_config_data.get("usbauto") != "false":
        fail(f"status snapshot JSON GPSD Config USBAUTO is not false: {path}")
    if "-n" not in gpsd_config_data.get("gpsd_options", []):
        fail(f"status snapshot JSON GPSD Config does not enable immediate polling: {path}")

    chrony_row = check_rows.get("Chrony Config")
    if not isinstance(chrony_row, dict):
        fail(f"status snapshot JSON missing Chrony Config readiness row: {path}")
    chrony_data = chrony_row.get("data")
    if not isinstance(chrony_data, dict):
        fail(f"status snapshot JSON Chrony Config row has no structured data: {path}")
    if chrony_data.get("is_raspberry_pi") is False and chrony_data.get("skipped") is True:
        fail(f"status snapshot JSON Chrony Config records non-Pi diagnostic skip: {path}")
    if snapshot_text(chrony_data.get("path", ""), "Chrony Config path", path) != "/etc/chrony/chrony.conf":
        fail(f"status snapshot JSON Chrony Config path is not /etc/chrony/chrony.conf: {path}")
    if chrony_data.get("exists") is not True:
        fail(f"status snapshot JSON Chrony Config path does not exist: {path}")
    if chrony_data.get("is_symlink") is not False:
        fail(f"status snapshot JSON Chrony Config path is a symlink: {path}")
    if snapshot_text(chrony_data.get("directory_symlink_component", ""), "Chrony Config directory_symlink_component", path):
        fail(f"status snapshot JSON Chrony Config directory contains a symlink: {path}")
    if chrony_data.get("is_regular") is not True:
        fail(f"status snapshot JSON Chrony Config path is not a regular file: {path}")
    if chrony_data.get("managed_refclock_present") is not True:
        fail(f"status snapshot JSON Chrony Config is missing managed GPSD SHM refclock: {path}")
    if snapshot_text(chrony_data.get("refclock_line", ""), "Chrony Config refclock_line", path) != "refclock SHM 0 offset 0.5 delay 0.1 refid GPS":
        fail(f"status snapshot JSON Chrony Config refclock line is not the managed GPSD SHM source: {path}")

    time_row = check_rows.get("GPS Time Source")
    if not isinstance(time_row, dict):
        fail(f"status snapshot JSON missing GPS Time Source readiness row: {path}")
    time_data = time_row.get("data")
    if not isinstance(time_data, dict):
        fail(f"status snapshot JSON GPS Time Source row has no structured data: {path}")
    if time_data.get("is_raspberry_pi") is False and time_data.get("skipped") is True:
        fail(f"status snapshot JSON GPS Time Source records non-Pi diagnostic skip: {path}")
    if time_data.get("is_raspberry_pi") is not True:
        fail(f"status snapshot JSON GPS Time Source did not identify a Raspberry Pi check: {path}")
    if time_data.get("chronyc_available") is not True:
        fail(f"status snapshot JSON GPS Time Source did not validate chronyc availability: {path}")
    if not isinstance(time_data.get("gps_lines"), list) or not time_data.get("gps_lines"):
        fail(f"status snapshot JSON GPS Time Source has no GPS refclock lines: {path}")
    if not isinstance(time_data.get("usable_lines"), list) or not time_data.get("usable_lines"):
        fail(f"status snapshot JSON GPS Time Source has no selected or combined GPS refclock: {path}")
    if time_data.get("selected_or_combined") is not True:
        fail(f"status snapshot JSON GPS Time Source did not prove selected or combined GPS time: {path}")


def validate_successful_status_snapshot(
    payload: dict[str, object],
    path: Path,
    expected_source_revision: str,
    generated_at: datetime,
) -> None:
    checks = payload.get("checks")
    service_checks = payload.get("service_checks")
    if not isinstance(checks, list) or not isinstance(service_checks, list):
        fail(f"status snapshot JSON missing readiness check sections: {path}")

    check_rows = {}
    for row in checks:
        if not isinstance(row, dict):
            fail(f"status snapshot JSON has malformed checks row: {path}")
        name = str(row.get("name", "")).strip()
        if not name:
            fail(f"status snapshot JSON has unnamed readiness check: {path}")
        if not isinstance(row.get("ok"), bool):
            fail(f"status snapshot JSON readiness check {name} ok is not boolean: {path}")
        if name in check_rows:
            fail(f"status snapshot JSON has duplicate readiness check: {name}: {path}")
        check_rows[name] = row

    service_rows = {}
    for row in service_checks:
        if not isinstance(row, dict):
            fail(f"status snapshot JSON has malformed service_checks row: {path}")
        name = str(row.get("name", "")).strip()
        if not name:
            fail(f"status snapshot JSON has unnamed service check: {path}")
        if not isinstance(row.get("ok"), bool):
            fail(f"status snapshot JSON service check {name} ok is not boolean: {path}")
        if name in service_rows:
            fail(f"status snapshot JSON has duplicate service check: {name}: {path}")
        service_rows[name] = row

    config_path = snapshot_text(payload.get("config_path", ""), "config_path", path)
    if not config_path:
        fail(f"status snapshot JSON missing config_path: {path}")
    if not Path(config_path).is_absolute():
        fail(f"status snapshot JSON config_path is not absolute: {path}")
    config = payload.get("config")
    if not isinstance(config, dict):
        fail(f"status snapshot JSON missing config section: {path}")
    chart_package = snapshot_text(config.get("chart_package", ""), "config chart_package", path).lower()
    if chart_package not in {"state", "cgd", "region", "chart", "all"}:
        fail(f"status snapshot JSON config chart_package is invalid: {path}")
    chart_value = snapshot_text(config.get("chart_value", ""), "config chart_value", path)
    if chart_package != "all" and not chart_value:
        fail(f"status snapshot JSON missing config chart_value: {path}")
    gps_mode = snapshot_text(config.get("gps_mode", ""), "config gps_mode", path).lower()
    if gps_mode not in {"gpsd", "serial"}:
        fail(f"status snapshot JSON has invalid gps_mode: {gps_mode or '<missing>'}: {path}")
    gps_device = snapshot_text(config.get("gps_device", ""), "config gps_device", path)
    if not gps_device:
        fail(f"status snapshot JSON missing config gps_device: {path}")
    if not stable_snapshot_gps_device_path(gps_device):
        if gps_device.startswith("/dev/ttyUSB") or gps_device.startswith("/dev/ttyACM"):
            fail(
                "status snapshot JSON config gps_device is volatile; "
                f"use /dev/serial/by-id/... or /dev/serial/by-path/... instead: {path}"
            )
        fail(f"status snapshot JSON config gps_device must be /dev/serial/by-id/..., /dev/serial/by-path/..., /dev/serial0, /dev/serial1, or /dev/gps: {path}")
    gps_baud = config.get("gps_baud")
    if isinstance(gps_baud, bool) or not isinstance(gps_baud, int) or gps_baud not in GPS_BAUD_RATES:
        fail(f"status snapshot JSON config gps_baud is invalid: {path}")
    gpsd_port = config.get("gpsd_port")
    if isinstance(gpsd_port, bool) or not isinstance(gpsd_port, int) or not (1 <= gpsd_port <= 65535):
        fail(f"status snapshot JSON config gpsd_port is invalid: {path}")
    chart_output = snapshot_text(config.get("chart_output", ""), "config chart_output", path)
    if not chart_output:
        fail(f"status snapshot JSON missing config chart_output: {path}")
    if not Path(chart_output).is_absolute():
        fail(f"status snapshot JSON config chart_output is not absolute: {path}")
    configured_track_output = snapshot_text(config.get("track_output", ""), "config track_output", path)
    if not configured_track_output:
        fail(f"status snapshot JSON missing config track_output: {path}")
    if not Path(configured_track_output).is_absolute():
        fail(f"status snapshot JSON config track_output is not absolute: {path}")
    track_retention_days = config.get("track_retention_days")
    if isinstance(track_retention_days, bool) or not isinstance(track_retention_days, int) or track_retention_days < 0:
        fail(f"status snapshot JSON config track_retention_days is negative or invalid: {path}")
    track_fsync_interval_seconds = finite_status_float(config.get("track_fsync_interval_seconds"))
    if track_fsync_interval_seconds is None or track_fsync_interval_seconds < 0.0:
        fail(f"status snapshot JSON config track_fsync_interval_seconds is negative or invalid: {path}")
    anchor_radius_meters = finite_status_float(config.get("anchor_radius_meters"))
    if anchor_radius_meters is None or anchor_radius_meters < 1.0:
        fail(f"status snapshot JSON config anchor_radius_meters is below 1.0: {path}")
    gps_fix = payload.get("gps_fix")
    if not isinstance(gps_fix, dict):
        fail(f"status snapshot JSON missing gps_fix section: {path}")
    if not isinstance(gps_fix.get("ok"), bool):
        fail(f"status snapshot JSON gps_fix ok is not boolean: {path}")
    if gps_fix.get("ok") is not True:
        fail(
            "status snapshot JSON gps_fix is not ok: "
            + str(gps_fix.get("detail", "<missing detail>"))
            + f": {path}"
        )
    validate_snapshot_gps_fix(gps_fix, gps_mode=gps_mode, generated_at=generated_at, path=path)
    track_log = payload.get("track_log")
    if not isinstance(track_log, dict):
        fail(f"status snapshot JSON missing track_log section: {path}")
    if not isinstance(track_log.get("ok"), bool):
        fail(f"status snapshot JSON track_log ok is not boolean: {path}")
    if track_log.get("ok") is not True:
        fail(
            "status snapshot JSON track_log is not ok: "
            + str(track_log.get("detail", "<missing detail>"))
            + f": {path}"
        )
    validate_snapshot_track_log(track_log, generated_at=generated_at, path=path)
    track_output = snapshot_text(track_log.get("track_output", ""), "track_log track_output", path)
    if not track_output:
        fail(f"status snapshot JSON missing track_log track_output: {path}")
    if track_output != configured_track_output:
        fail(f"status snapshot JSON track_log track_output does not match config track_output: {path}")
    tracks_dir = snapshot_text(track_log.get("tracks_dir", ""), "track_log tracks_dir", path)
    expected_tracks_dir = str(Path(configured_track_output) / "tracks")
    if tracks_dir != expected_tracks_dir:
        fail(f"status snapshot JSON track_log tracks_dir does not match config track_output: {path}")

    required_checks = set(CORE_READINESS_CHECKS)
    required_service_checks = set(CORE_SERVICE_CHECKS)
    if gps_mode == "serial":
        required_checks.update(SERIAL_READINESS_CHECKS)
    else:
        required_checks.update(GPSD_READINESS_CHECKS)
        required_checks.add("GPS Device")
        required_service_checks.update(GPSD_SERVICE_CHECKS)
    if track_output != chart_output:
        required_checks.add("Track Disk")

    missing_checks = sorted(required_checks - set(check_rows))
    missing_service_checks = sorted(required_service_checks - set(service_rows))
    if missing_checks:
        fail(f"status snapshot JSON missing required readiness check(s): {', '.join(missing_checks)}: {path}")
    if missing_service_checks:
        fail(f"status snapshot JSON missing required service check(s): {', '.join(missing_service_checks)}: {path}")
    failed_checks = sorted(name for name, row in check_rows.items() if row.get("ok") is not True)
    failed_service_checks = sorted(name for name, row in service_rows.items() if row.get("ok") is not True)
    if failed_checks:
        fail(f"status snapshot JSON has failed readiness check(s): {', '.join(failed_checks)}: {path}")
    if failed_service_checks:
        fail(f"status snapshot JSON has failed service check(s): {', '.join(failed_service_checks)}: {path}")
    missing_structured_data = sorted(
        name for name in required_checks if not isinstance(check_rows[name].get("data"), dict)
    )
    if missing_structured_data:
        fail(f"status snapshot JSON missing structured readiness data for: {', '.join(missing_structured_data)}: {path}")
    validate_snapshot_gps_device_row(check_rows, expected_device=gps_device, path=path)
    validate_snapshot_autostart(payload, path=path)
    validate_snapshot_status_launcher(payload, path=path)
    validate_snapshot_mob_launcher(payload, path=path)
    validate_snapshot_chart_rows(check_rows, config=config, path=path)
    validate_snapshot_manifest_row(check_rows, config=config, manifest=payload.get("manifest"), path=path)
    validate_snapshot_gps_row(check_rows, gps_mode=gps_mode, gps_fix=gps_fix, path=path)
    validate_snapshot_track_log_row(service_rows, track_log=track_log, path=path)
    if gps_mode == "gpsd":
        validate_snapshot_gpsd_rows(check_rows, config=config, path=path)
    non_pi_skips = sorted(
        name
        for name in required_checks & PI_ONLY_READINESS_CHECKS
        if check_rows[name].get("data", {}).get("is_raspberry_pi") is False
        and check_rows[name].get("data", {}).get("skipped") is True
    )
    if non_pi_skips:
        fail(f"status snapshot JSON records non-Pi diagnostic skip(s): {', '.join(non_pi_skips)}: {path}")
    source_data = check_rows["Source Revision"].get("data")
    row_revision = snapshot_text(source_data.get("revision", ""), "Source Revision revision", path)
    if not row_revision or row_revision == "unknown":
        fail(f"status snapshot JSON Source Revision row missing revision: {path}")
    if row_revision.endswith("-dirty"):
        fail(f"status snapshot JSON Source Revision row records a dirty revision: {path}")
    if row_revision != expected_source_revision:
        fail(f"status snapshot JSON Source Revision row does not match deployed source_revision: {path}")

try:
    before = os.stat(path, follow_symlinks=False)
    fd = os.open(path, flags)
except OSError as exc:
    print(f"Could not open status snapshot for JSON validation {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc

try:
    opened = os.fstat(fd)
    if before.st_dev != opened.st_dev or before.st_ino != opened.st_ino:
        print(f"status snapshot changed while opening it: {path}", file=sys.stderr)
        raise SystemExit(124)
    if not stat.S_ISREG(opened.st_mode):
        print(f"status snapshot must be a regular file: {path}", file=sys.stderr)
        raise SystemExit(124)
    if opened.st_uid != os.getuid():
        print(
            f"status snapshot is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        print(f"status snapshot has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
        raise SystemExit(124)
    with os.fdopen(fd, "r", encoding="utf-8") as handle:
        fd = -1
        try:
            payload = json.load(handle)
        except json.JSONDecodeError as exc:
            print(f"status snapshot is not valid JSON: {path}: {exc}", file=sys.stderr)
            raise SystemExit(124) from exc
except OSError as exc:
    print(f"Could not validate status snapshot {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
finally:
    if fd >= 0:
        os.close(fd)

if not isinstance(payload, dict):
    print(f"status snapshot JSON must be an object: {path}", file=sys.stderr)
    raise SystemExit(124)
if not isinstance(payload.get("ok"), bool):
    print(f"status snapshot JSON missing boolean ok field: {path}", file=sys.stderr)
    raise SystemExit(124)
generated_at = payload.get("generated_at")
if not isinstance(generated_at, str) or not generated_at.strip():
    print(f"status snapshot JSON missing generated_at field: {path}", file=sys.stderr)
    raise SystemExit(124)
try:
    parsed_generated_at = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
except ValueError as exc:
    print(f"status snapshot JSON has invalid generated_at timestamp: {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
if parsed_generated_at.tzinfo is None or parsed_generated_at.utcoffset() is None:
    print(f"status snapshot JSON generated_at timestamp must include a timezone: {path}", file=sys.stderr)
    raise SystemExit(124)
generated_at_utc = parsed_generated_at.astimezone(timezone.utc)
age_seconds = (datetime.now(timezone.utc) - generated_at_utc).total_seconds()
if age_seconds > STATUS_MAX_AGE_SECONDS:
    print(
        f"status snapshot JSON generated_at timestamp is stale: {path}: "
        f"{age_seconds:.0f}s old; maximum {STATUS_MAX_AGE_SECONDS}s",
        file=sys.stderr,
    )
    raise SystemExit(124)
if age_seconds < -STATUS_FUTURE_TOLERANCE_SECONDS:
    print(
        f"status snapshot JSON generated_at timestamp is too far in the future: {path}: "
        f"{-age_seconds:.0f}s ahead; maximum {STATUS_FUTURE_TOLERANCE_SECONDS}s",
        file=sys.stderr,
    )
    raise SystemExit(124)
host = payload.get("host")
if not isinstance(host, dict):
    print(f"status snapshot JSON missing valid host boot_id: {path}", file=sys.stderr)
    raise SystemExit(124)
host_boot_id = snapshot_text(host.get("boot_id", ""), "host boot_id", path)
if not BOOT_ID_RE.fullmatch(host_boot_id):
    print(f"status snapshot JSON missing valid host boot_id: {path}", file=sys.stderr)
    raise SystemExit(124)
app = payload.get("app")
if not isinstance(app, dict):
    print(f"status snapshot JSON missing deployed source_revision: {path}", file=sys.stderr)
    raise SystemExit(124)
source_revision_text = snapshot_text(app.get("source_revision", ""), "app source_revision", path)
if not source_revision_text or source_revision_text == "unknown":
    print(f"status snapshot JSON missing deployed source_revision: {path}", file=sys.stderr)
    raise SystemExit(124)
if source_revision_text.endswith("-dirty"):
    print(f"status snapshot JSON dirty deployed source_revision is not production-ready: {path}", file=sys.stderr)
    raise SystemExit(124)
for field in ("checks", "service_checks"):
    rows = payload.get(field)
    if not isinstance(rows, list) or not rows:
        print(f"status snapshot JSON missing non-empty {field} list: {path}", file=sys.stderr)
        raise SystemExit(124)
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            print(f"status snapshot JSON {field}[{index}] must be an object: {path}", file=sys.stderr)
            raise SystemExit(124)
        if not isinstance(row.get("name"), str) or not row["name"].strip():
            print(f"status snapshot JSON {field}[{index}] missing name: {path}", file=sys.stderr)
            raise SystemExit(124)
        if not isinstance(row.get("ok"), bool):
            print(f"status snapshot JSON {field}[{index}] missing boolean ok: {path}", file=sys.stderr)
            raise SystemExit(124)
        if not isinstance(row.get("detail"), str):
            print(f"status snapshot JSON {field}[{index}] missing detail: {path}", file=sys.stderr)
            raise SystemExit(124)
if payload.get("ok") is True:
    validate_successful_status_snapshot(payload, path, source_revision_text, generated_at_utc)
else:
    print(f"status snapshot JSON does not report ok=true: {path}", file=sys.stderr)
    raise SystemExit(124)
PY
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

validate_post_trip_archive() {
  local label="$1"
  local path="$2"
  local parent="$3"
  local status
  set +e
  "$python3_cmd" - "$label" "$path" "$parent" <<'PY'
from __future__ import annotations

import json
import os
import re
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath

label = sys.argv[1]
path = Path(sys.argv[2]).expanduser()
parent = Path(sys.argv[3]).expanduser()
if not path.is_absolute():
    path = Path.cwd() / path
if not parent.is_absolute():
    parent = Path.cwd() / parent
nofollow = getattr(os, "O_NOFOLLOW", 0)
MAX_METADATA_MEMBER_BYTES = 1024 * 1024
MAX_TRACK_MEMBER_BYTES = 100 * 1024 * 1024
MAX_SUPPORT_MEMBER_BYTES = 10 * 1024 * 1024

try:
    parent_initial = parent.lstat()
except OSError as exc:
    print(f"Could not inspect post-trip output directory {parent}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
if stat.S_ISLNK(parent_initial.st_mode) or not stat.S_ISDIR(parent_initial.st_mode):
    print(f"post-trip output directory must be a real directory: {parent}", file=sys.stderr)
    raise SystemExit(124)

try:
    parent_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
except OSError as exc:
    print(f"Could not open post-trip output directory safely {parent}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
try:
    parent_opened = os.fstat(parent_fd)
    if not os.path.samestat(parent_initial, parent_opened):
        print(f"post-trip output directory changed while opening it: {parent}", file=sys.stderr)
        raise SystemExit(124)
finally:
    os.close(parent_fd)

try:
    if path.parent.resolve(strict=True) != parent.resolve(strict=True):
        print(f"{label} must be an immediate child of the post-trip output directory: {path}", file=sys.stderr)
        raise SystemExit(124)
except OSError as exc:
    print(f"Could not resolve {label} parent {path.parent}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
if path.suffix != ".tgz":
    print(f"{label} must be a .tgz archive: {path}", file=sys.stderr)
    raise SystemExit(124)

try:
    initial = path.lstat()
except OSError as exc:
    print(f"Could not inspect {label} {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
if stat.S_ISLNK(initial.st_mode):
    print(f"{label} must not be a symlink: {path}", file=sys.stderr)
    raise SystemExit(124)
if not stat.S_ISREG(initial.st_mode):
    print(f"{label} must be a regular file: {path}", file=sys.stderr)
    raise SystemExit(124)
if initial.st_uid != os.getuid():
    print(f"{label} is owned by uid {initial.st_uid}, expected current user {os.getuid()}: {path}", file=sys.stderr)
    raise SystemExit(124)
mode = stat.S_IMODE(initial.st_mode)
if mode != 0o600:
    print(f"{label} has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
    raise SystemExit(124)

try:
    fd = os.open(path, os.O_RDONLY | nofollow)
except OSError as exc:
    print(f"Could not open {label} safely {path}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
try:
    opened = os.fstat(fd)
    if not os.path.samestat(initial, opened):
        print(f"{label} changed while opening it: {path}", file=sys.stderr)
        raise SystemExit(124)
    if not stat.S_ISREG(opened.st_mode):
        print(f"{label} must be regular after open: {path}", file=sys.stderr)
        raise SystemExit(124)
    with os.fdopen(fd, "rb") as handle:
        fd = -1
        try:
            with tarfile.open(fileobj=handle, mode="r:gz") as archive:
                members = archive.getmembers()
        except (tarfile.TarError, OSError) as exc:
            print(f"{label} is not a readable gzip tar archive: {path}: {exc}", file=sys.stderr)
            raise SystemExit(124) from exc
finally:
    if fd >= 0:
        os.close(fd)

if not members:
    print(f"{label} is empty: {path}", file=sys.stderr)
    raise SystemExit(124)
seen_names = set()
members_by_name = {}
data_file_count = 0
data_member_names = []
for member in members:
    name = member.name
    normalized = PurePosixPath(name)
    if "\\" in name:
        print(f"{label} contains unsafe backslash member name: {name}", file=sys.stderr)
        raise SystemExit(124)
    if name in {"", ".", ".."} or name.startswith("/") or any(part in {"", ".", ".."} for part in normalized.parts):
        print(f"{label} contains unsafe member name: {name}", file=sys.stderr)
        raise SystemExit(124)
    normalized_name = normalized.as_posix()
    if normalized_name in seen_names:
        print(f"{label} contains duplicate normalized member name: {name}", file=sys.stderr)
        raise SystemExit(124)
    seen_names.add(normalized_name)
    members_by_name[normalized_name] = member
    if not (member.isfile() or member.isdir()):
        print(f"{label} contains unsupported member type: {name}", file=sys.stderr)
        raise SystemExit(124)
    if member.isfile():
        if member.size < 0:
            print(f"{label} member has invalid negative size: {name}", file=sys.stderr)
            raise SystemExit(124)
        if normalized_name in {"README.txt", "manifest.json"}:
            max_member_size = MAX_METADATA_MEMBER_BYTES
        elif label == "track export archive":
            max_member_size = MAX_TRACK_MEMBER_BYTES
        else:
            max_member_size = MAX_SUPPORT_MEMBER_BYTES
        if member.size > max_member_size:
            print(
                f"{label} member exceeds size limit ({member.size} > {max_member_size} bytes): {name}",
                file=sys.stderr,
            )
            raise SystemExit(124)
    if member.isfile() and normalized_name not in {"README.txt", "manifest.json"}:
        if label == "track export archive" and not (
            normalized_name.startswith("tracks/")
            and normalized_name.endswith(".gpx")
            and normalized_name != "tracks/.gpx"
        ):
            print(f"{label} contains non-GPX track data member: {name}", file=sys.stderr)
            raise SystemExit(124)
        if label == "track export archive":
            track_name = normalized_name.removeprefix("tracks/")
            if not track_name or "/" in track_name:
                print(f"{label} contains nested or empty track data member: {name}", file=sys.stderr)
                raise SystemExit(124)
            data_member_names.append(track_name)
        data_file_count += 1
readme = members_by_name.get("README.txt")
if readme is None:
    print(f"{label} is missing README.txt", file=sys.stderr)
    raise SystemExit(124)
if not readme.isfile():
    print(f"{label} README.txt is not a regular file", file=sys.stderr)
    raise SystemExit(124)
if label == "track export archive":
    manifest = members_by_name.get("manifest.json")
    if manifest is None:
        print(f"{label} is missing manifest.json", file=sys.stderr)
        raise SystemExit(124)
    if not manifest.isfile():
        print(f"{label} manifest.json is not a regular file", file=sys.stderr)
        raise SystemExit(124)
    try:
        fd = os.open(path, os.O_RDONLY | nofollow)
        try:
            opened = os.fstat(fd)
            if not os.path.samestat(initial, opened):
                print(f"{label} changed before manifest validation: {path}", file=sys.stderr)
                raise SystemExit(124)
            with os.fdopen(fd, "rb") as handle:
                fd = -1
                with tarfile.open(fileobj=handle, mode="r:gz") as archive:
                    manifest_file = archive.extractfile("manifest.json")
                    if manifest_file is None:
                        print(f"{label} manifest.json is not readable", file=sys.stderr)
                        raise SystemExit(124)
                    manifest_payload = json.loads(manifest_file.read().decode("utf-8"))
        finally:
            if fd >= 0:
                os.close(fd)
    except (json.JSONDecodeError, UnicodeDecodeError, tarfile.TarError, OSError) as exc:
        print(f"{label} manifest.json is invalid or unreadable: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    if not isinstance(manifest_payload, dict):
        print(f"{label} manifest.json must be a JSON object", file=sys.stderr)
        raise SystemExit(124)
    track_count = manifest_payload.get("track_count")
    if not isinstance(track_count, int) or track_count <= 0:
        print(f"{label} manifest track_count must be a positive integer", file=sys.stderr)
        raise SystemExit(124)
    if track_count != data_file_count:
        print(
            f"{label} manifest track_count does not match data file count: {track_count} != {data_file_count}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    tracks = manifest_payload.get("tracks")
    if not isinstance(tracks, list):
        print(f"{label} manifest tracks must be a list", file=sys.stderr)
        raise SystemExit(124)
    manifest_track_names = []
    for index, track in enumerate(tracks):
        if not isinstance(track, dict):
            print(f"{label} manifest tracks[{index}] must be an object", file=sys.stderr)
            raise SystemExit(124)
        name = track.get("name")
        if not isinstance(name, str) or not name or "/" in name or "\\" in name or name in {".", ".."}:
            print(f"{label} manifest tracks[{index}].name is invalid: {name!r}", file=sys.stderr)
            raise SystemExit(124)
        manifest_track_names.append(name)
    if sorted(manifest_track_names) != sorted(data_member_names):
        print(
            f"{label} manifest track names do not match data files: "
            f"{sorted(manifest_track_names)!r} != {sorted(data_member_names)!r}",
            file=sys.stderr,
        )
        raise SystemExit(124)
elif label == "support bundle archive":
    if data_file_count <= 0:
        print(f"{label} contains no diagnostic files", file=sys.stderr)
        raise SystemExit(124)
    required_members = [
        "commands/system-command-integrity.txt",
        "commands/date-utc.txt",
        "commands/uname.txt",
        "commands/hostname.txt",
        "commands/uptime.txt",
        "commands/package-versions.txt",
        "commands/df.txt",
        "commands/df-inodes.txt",
        "commands/mount-findmnt.txt",
        "commands/serial-devices.txt",
        "commands/user-units.txt",
        "commands/user-unit-properties.txt",
        "commands/system-services.txt",
        "commands/system-service-properties.txt",
        "commands/chrony-sources.txt",
        "commands/timedatectl.txt",
        "commands/pi-throttling.txt",
        "commands/recent-user-journal.txt",
        "commands/recent-track-journal.txt",
        "commands/recent-system-journal.txt",
        "commands/configured-storage-paths.txt",
        "commands/configured-chart-storage-tree.txt",
        "commands/configured-track-storage-tree.txt",
        "commands/noaa-gps-device-candidates.txt",
        "commands/noaa-status-report-json.txt",
        "commands/noaa-status-report-commissioned-json.txt",
        "commands/noaa-cache-tree.txt",
        "commands/noaa-config-tree.txt",
        "commands/noaa-data-tree.txt",
    ]
    missing_members = [
        name for name in required_members
        if name not in members_by_name or not members_by_name[name].isfile()
    ]
    if missing_members:
        print(
            f"{label} is missing required diagnostic file(s): {', '.join(missing_members)}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    required_member_patterns = [
        (
            "NOAA Navionics config copy",
            re.compile(r"^files/home/[^/]+/\.config/noaa-navionics/config\.ini$"),
        ),
        (
            "NOAA Navionics launcher environment copy",
            re.compile(r"^files/home/[^/]+/\.config/noaa-navionics/launcher\.env$"),
        ),
        (
            "NOAA Navionics saved status copy",
            re.compile(r"^files/home/[^/]+/\.cache/noaa-navionics/status\.json$"),
        ),
        (
            "NOAA Navionics source revision copy",
            re.compile(r"^files/home/[^/]+/\.local/share/noaa-navionics/source-revision$"),
        ),
    ]
    missing_pattern_labels = [
        pattern_label
        for pattern_label, pattern in required_member_patterns
        if not any(member.isfile() and pattern.fullmatch(name) for name, member in members_by_name.items())
    ]
    if missing_pattern_labels:
        print(
            f"{label} is missing required diagnostic evidence file(s): {', '.join(missing_pattern_labels)}",
            file=sys.stderr,
        )
        raise SystemExit(124)
PY
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

write_post_trip_checksum_manifest() {
  local directory="$1"
  "$python3_cmd" - "$directory" <<'PY'
from __future__ import annotations

from pathlib import Path
import hashlib
import os
import secrets
import stat
import sys

MANIFEST_NAME = "SHA256SUMS.txt"


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(124)


def open_trusted_post_trip_directory(path: Path) -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        fail(f"Could not inspect post-trip directory before checksum manifest: {path}: {exc}")
    if stat.S_ISLNK(before.st_mode):
        fail(f"Post-trip checksum directory is a symlink: {path}")
    if not stat.S_ISDIR(before.st_mode):
        fail(f"Post-trip checksum directory is not a real directory: {path}")
    try:
        directory_fd = os.open(path, flags)
    except OSError as exc:
        fail(f"Could not open post-trip directory before checksum manifest: {path}: {exc}")
    try:
        opened = os.fstat(directory_fd)
        if not os.path.samestat(before, opened):
            fail(f"Post-trip checksum directory changed before it could be opened: {path}")
        if not stat.S_ISDIR(opened.st_mode):
            fail(f"Post-trip checksum directory is not a real directory when opened: {path}")
        if opened.st_uid != os.getuid():
            fail(f"Post-trip checksum directory is owned by uid {opened.st_uid}, expected {os.getuid()}: {path}")
        mode = stat.S_IMODE(opened.st_mode)
        if mode != 0o700:
            fail(f"Post-trip checksum directory has permissions {mode:04o}, expected private 0700: {path}")
        return directory_fd
    except BaseException:
        os.close(directory_fd)
        raise


def stat_post_trip_child(directory_fd: int, file_name: str, label: str, path: Path) -> os.stat_result:
    if "/" in file_name or file_name in {"", ".", ".."}:
        fail(f"{label} has unsafe post-trip artifact name: {file_name}")
    try:
        return os.stat(file_name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError as exc:
        fail(f"Missing {label}: {path}: {exc}")
    except OSError as exc:
        fail(f"Could not inspect {label}: {path}: {exc}")


def post_trip_child_exists(directory_fd: int, file_name: str) -> bool:
    try:
        os.stat(file_name, dir_fd=directory_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def post_trip_artifact_names(directory_fd: int) -> list[str]:
    try:
        names = os.listdir(directory_fd)
    except OSError as exc:
        fail(f"Could not list post-trip checksum directory: {exc}")
    artifact_names = []
    if "status.json" in names:
        artifact_names.append("status.json")
    artifact_names.extend(sorted(name for name in names if name.endswith(".tgz") and "/" not in name))
    return artifact_names


def hash_private_file(path: Path, directory_fd: int) -> str:
    before = stat_post_trip_child(directory_fd, path.name, "post-trip artifact before checksum manifest", path)
    if stat.S_ISLNK(before.st_mode):
        fail(f"Post-trip artifact must not be a symlink before checksum manifest: {path}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"Post-trip artifact must be regular before checksum manifest: {path}")
    if before.st_uid != os.getuid():
        fail(f"Post-trip artifact is owned by uid {before.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o600:
        fail(f"Post-trip artifact has permissions {mode:04o}, expected private 0600: {path}")
    fd = -1
    try:
        fd = os.open(path.name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            fail(f"Post-trip artifact changed before checksum manifest: {path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"Post-trip artifact must be regular when opened for checksum: {path}")
        if opened.st_uid != os.getuid():
            fail(f"Post-trip artifact is owned by uid {opened.st_uid}, expected {os.getuid()} when opened: {path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != 0o600:
            fail(f"Post-trip artifact has permissions {opened_mode:04o}, expected private 0600 when opened: {path}")
        digest = hashlib.sha256()
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    finally:
        if fd >= 0:
            os.close(fd)


def cleanup_private_temp(directory_fd: int, path: Path, expected: os.stat_result | None) -> None:
    if expected is None:
        print(f"post-trip checksum temp was not inspected before cleanup; leaving it in place: {path}", file=sys.stderr)
        return
    try:
        current = os.stat(path.name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as exc:
        print(f"could not inspect post-trip checksum temp before cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
        return
    if not os.path.samestat(expected, current):
        print(f"post-trip checksum temp changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        return
    if not stat.S_ISREG(current.st_mode):
        print(f"post-trip checksum temp is not regular before cleanup; leaving it in place: {path}", file=sys.stderr)
        return
    try:
        os.unlink(path.name, dir_fd=directory_fd)
    except OSError as exc:
        print(f"could not remove post-trip checksum temp after validation: {path}: {exc}", file=sys.stderr)


directory = Path(sys.argv[1])
directory_fd = open_trusted_post_trip_directory(directory)
temp_fd = -1
temp_name = None
temp_stat = None
try:
    artifact_names = post_trip_artifact_names(directory_fd)
    if not artifact_names:
        print(f"No post-trip artifacts to checksum in: {directory}")
        raise SystemExit(0)

    manifest_path = directory / MANIFEST_NAME
    if post_trip_child_exists(directory_fd, MANIFEST_NAME):
        fail(f"Refusing to overwrite existing post-trip checksum manifest: {manifest_path}")

    artifact_paths = [directory / name for name in artifact_names]
    lines = [f"{hash_private_file(path, directory_fd)}  {path.name}\n" for path in artifact_paths]
    payload = "".join(lines).encode("ascii")
    temp_name = f".{MANIFEST_NAME}.{secrets.token_hex(16)}.tmp"
    temp_fd = os.open(
        temp_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=directory_fd,
    )
    temp_stat = os.fstat(temp_fd)
    os.write(temp_fd, payload)
    os.fsync(temp_fd)
    os.close(temp_fd)
    temp_fd = -1
    os.replace(temp_name, MANIFEST_NAME, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    temp_name = None
    os.fsync(directory_fd)
except OSError as exc:
    fail(f"Could not write post-trip checksum manifest: {exc}")
finally:
    if temp_fd >= 0:
        os.close(temp_fd)
    if temp_name is not None:
        cleanup_private_temp(directory_fd, directory / temp_name, temp_stat)

try:
    final = stat_post_trip_child(directory_fd, MANIFEST_NAME, "post-trip checksum manifest after writing", manifest_path)
except OSError as exc:
    fail(f"Could not inspect post-trip checksum manifest after writing: {manifest_path}: {exc}")
try:
    if not stat.S_ISREG(final.st_mode):
        fail(f"Post-trip checksum manifest is not a regular file after writing: {manifest_path}")
    if final.st_uid != os.getuid():
        fail(f"Post-trip checksum manifest is owned by uid {final.st_uid}, expected {os.getuid()}: {manifest_path}")
    mode = stat.S_IMODE(final.st_mode)
    if mode != 0o600:
        fail(f"Post-trip checksum manifest has permissions {mode:04o}, expected private 0600: {manifest_path}")
    print(f"Wrote post-trip checksum manifest: {manifest_path}")
finally:
    os.close(directory_fd)
PY
  local status=$?
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

verify_post_trip_checksum_manifest() {
  local directory="$1"
  "$python3_cmd" - "$directory" <<'PY'
from __future__ import annotations

from pathlib import Path
import hashlib
import os
import re
import stat
import sys

MANIFEST_NAME = "SHA256SUMS.txt"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(124)


def open_trusted_post_trip_directory(path: Path) -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        fail(f"Could not inspect post-trip checksum directory: {path}: {exc}")
    if stat.S_ISLNK(before.st_mode):
        fail(f"post-trip checksum directory must not be a symlink: {path}")
    if not stat.S_ISDIR(before.st_mode):
        fail(f"post-trip checksum directory must be a real directory: {path}")
    try:
        directory_fd = os.open(path, flags)
    except OSError as exc:
        fail(f"Could not open post-trip checksum directory: {path}: {exc}")
    try:
        opened = os.fstat(directory_fd)
        if not os.path.samestat(before, opened):
            fail(f"post-trip checksum directory changed before verification: {path}")
        if not stat.S_ISDIR(opened.st_mode):
            fail(f"post-trip checksum directory must be real when opened: {path}")
        if opened.st_uid != os.getuid():
            fail(f"post-trip checksum directory is owned by uid {opened.st_uid}, expected {os.getuid()}: {path}")
        mode = stat.S_IMODE(opened.st_mode)
        if mode != 0o700:
            fail(f"post-trip checksum directory has permissions {mode:04o}, expected private 0700: {path}")
        return directory_fd
    except BaseException:
        os.close(directory_fd)
        raise


def stat_post_trip_child(directory_fd: int, file_name: str, label: str, path: Path) -> os.stat_result:
    if "/" in file_name or file_name in {"", ".", ".."}:
        fail(f"{label} has unsafe post-trip artifact name: {file_name}")
    try:
        return os.stat(file_name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError as exc:
        fail(f"Missing {label}: {path}: {exc}")
    except OSError as exc:
        fail(f"Could not inspect {label}: {path}: {exc}")


def post_trip_child_exists(directory_fd: int, file_name: str) -> bool:
    try:
        os.stat(file_name, dir_fd=directory_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def post_trip_artifact_names(directory_fd: int) -> list[str]:
    try:
        names = os.listdir(directory_fd)
    except OSError as exc:
        fail(f"Could not list post-trip checksum directory: {exc}")
    artifact_names = []
    if "status.json" in names:
        artifact_names.append("status.json")
    artifact_names.extend(sorted(name for name in names if name.endswith(".tgz") and "/" not in name))
    return artifact_names


def inspect_private_file(path: Path, label: str, directory_fd: int) -> os.stat_result:
    result = stat_post_trip_child(directory_fd, path.name, label, path)
    if stat.S_ISLNK(result.st_mode):
        fail(f"{label} must not be a symlink: {path}")
    if not stat.S_ISREG(result.st_mode):
        fail(f"{label} must be a regular file: {path}")
    if result.st_uid != os.getuid():
        fail(f"{label} is owned by uid {result.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode != 0o600:
        fail(f"{label} has permissions {mode:04o}, expected private 0600: {path}")
    return result


def read_private_file(path: Path, label: str, directory_fd: int) -> bytes:
    before = inspect_private_file(path, label, directory_fd)
    fd = -1
    try:
        fd = os.open(path.name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            fail(f"{label} changed while opening it: {path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"{label} must be regular when opened: {path}")
        if opened.st_uid != os.getuid():
            fail(f"{label} is owned by uid {opened.st_uid}, expected {os.getuid()} when opened: {path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != 0o600:
            fail(f"{label} has permissions {opened_mode:04o}, expected private 0600 when opened: {path}")
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            return handle.read()
    finally:
        if fd >= 0:
            os.close(fd)


def hash_private_file(path: Path, directory_fd: int) -> str:
    before = inspect_private_file(path, "post-trip artifact", directory_fd)
    fd = -1
    try:
        fd = os.open(path.name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=directory_fd)
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            fail(f"post-trip artifact changed before checksum verification: {path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"post-trip artifact must be regular when opened for checksum verification: {path}")
        if opened.st_uid != os.getuid():
            fail(f"post-trip artifact is owned by uid {opened.st_uid}, expected {os.getuid()} when opened for checksum verification: {path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != 0o600:
            fail(f"post-trip artifact has permissions {opened_mode:04o}, expected private 0600 when opened for checksum verification: {path}")
        digest = hashlib.sha256()
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    finally:
        if fd >= 0:
            os.close(fd)


directory = Path(sys.argv[1])
directory_fd = open_trusted_post_trip_directory(directory)
try:
    manifest_path = directory / MANIFEST_NAME
    manifest_exists = post_trip_child_exists(directory_fd, MANIFEST_NAME)
    if not manifest_exists:
        if not post_trip_artifact_names(directory_fd):
            print(f"No post-trip artifacts to verify in: {directory}")
            raise SystemExit(0)
    try:
        text = read_private_file(manifest_path, "post-trip checksum manifest", directory_fd).decode("ascii")
    except UnicodeDecodeError as exc:
        fail(f"post-trip checksum manifest is not ASCII: {exc}")
    entries: dict[str, str] = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip():
            continue
        if "  " not in raw_line:
            fail(f"post-trip checksum manifest line {line_number} must use two-space sha256 filename format")
        digest, name = raw_line.split("  ", 1)
        if not SHA256_RE.fullmatch(digest):
            fail(f"post-trip checksum manifest line {line_number} has invalid SHA-256 digest")
        if "/" in name or name in {"", ".", ".."} or "\\" in name:
            fail(f"post-trip checksum manifest line {line_number} has unsafe artifact name: {name}")
        if name in entries:
            fail(f"post-trip checksum manifest contains duplicate artifact name: {name}")
        entries[name] = digest
    if not entries:
        fail("post-trip checksum manifest is empty")

    expected_names = set(post_trip_artifact_names(directory_fd))
    missing = sorted(expected_names - set(entries))
    extra = sorted(set(entries) - expected_names)
    if missing:
        fail(f"post-trip checksum manifest is missing artifact(s): {', '.join(missing)}")
    if extra:
        fail(f"post-trip checksum manifest lists unexpected artifact(s): {', '.join(extra)}")
    for name, expected_digest in entries.items():
        artifact_path = directory / name
        actual_digest = hash_private_file(artifact_path, directory_fd)
        if actual_digest != expected_digest:
            fail(f"post-trip checksum mismatch for {name}: expected {expected_digest}, got {actual_digest}")
    print(f"Verified post-trip checksum manifest: {manifest_path}")
finally:
    os.close(directory_fd)
PY
  local status=$?
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

run_helper_descriptor() {
  local command_path="$1"
  local status
  shift

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
  if [[ "$status" -eq 124 ]]; then
    return 2
  fi
  return "$status"
}

run_artifact_step() {
  local label="$1"
  local marker="$2"
  local archive_label="$3"
  local parent="$4"
  local command_path="$5"
  local output
  local status
  local artifact_path
  shift 5

  require_helper "$command_path"
  printf '==> %s\n' "$label"
  set +e
  output="$(run_helper_descriptor "$command_path" "$@" 2>&1)"
  status=$?
  set -e
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
  if [[ "$status" -ne 0 ]]; then
    return "$status"
  fi
  artifact_path="$(printf '%s\n' "$output" | sed -n "s/^${marker}: //p" | tail -n 1)"
  if [[ -z "$artifact_path" ]]; then
    echo "$archive_label helper did not report an archive path" >&2
    exit 2
  fi
  validate_post_trip_archive "$archive_label" "$artifact_path" "$parent"
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
Do not collect post-trip artifacts as root@.
Use the Pi desktop user so status, GPX tracks, OpenCPN data, and support logs match the helm account.
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
  run_helper_descriptor "$command_path" "$@"
  status=$?
  set -e
  if [[ "$status" -eq 2 ]]; then
    exit 2
  fi
  return "$status"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --skip-status)
      skip_status=1
      shift
      ;;
    --skip-tracks)
      skip_tracks=1
      shift
      ;;
    --skip-support)
      skip_support=1
      shift
      ;;
    --shutdown-dry-run)
      if [[ -n "$shutdown_mode" ]]; then
        echo "--shutdown-dry-run and --shutdown-confirm cannot be used together" >&2
        exit 2
      fi
      shutdown_mode="dry-run"
      shift
      ;;
    --shutdown-confirm)
      if [[ -n "$shutdown_mode" ]]; then
        echo "--shutdown-dry-run and --shutdown-confirm cannot be used together" >&2
        exit 2
      fi
      shutdown_mode="confirm"
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
validate_output_dir_arg "$output_dir"
output_dir="$(strip_trailing_slashes "$output_dir")"
reject_symlinked_path_components "Output directory" "$output_dir"
if [[ "$skip_status" -eq 1 && "$skip_tracks" -eq 1 && "$skip_support" -eq 1 && -z "$shutdown_mode" ]]; then
  echo "At least one post-trip collection or shutdown step must run" >&2
  exit 2
fi
if [[ "$skip_status" -eq 1 && "$gps_seconds_set" -eq 1 ]]; then
  echo "--gps-seconds requires the status snapshot step; remove --skip-status or omit --gps-seconds" >&2
  exit 2
fi
if [[ "$skip_tracks" -eq 1 && "$track_days_set" -eq 1 ]]; then
  echo "--track-days requires the GPX track export step; remove --skip-tracks or omit --track-days" >&2
  exit 2
fi
if [[ "$skip_status" -eq 1 && "$skip_tracks" -eq 1 && "$skip_support" -eq 1 ]]; then
  echo "Post-trip shutdown options require collecting at least one artifact first; use scripts/shutdown_pi_safely.sh for shutdown-only checks" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status_helper="${repo_root}/scripts/check_pi_status.sh"
tracks_helper="${repo_root}/scripts/export_pi_tracks.sh"
support_helper="${repo_root}/scripts/collect_pi_support_bundle.sh"
shutdown_helper="${repo_root}/scripts/shutdown_pi_safely.sh"
python3_cmd="$(require_local_command python3)"
require_helper "$status_helper"
require_helper "$tracks_helper"
require_helper "$support_helper"
require_helper "$shutdown_helper"

prepare_private_output_dir "Output directory" "$output_dir"

timestamp="$(utc_timestamp)"
safe_target="$(printf '%s' "$target" | tr '@.' '___')"
trip_dir="${output_dir}/noaa-navionics-pi-post-trip-${safe_target}-${timestamp}"
if [[ -e "$trip_dir" ]]; then
  echo "Refusing to overwrite existing post-trip directory: $trip_dir" >&2
  exit 2
fi
prepare_private_output_dir "Post-trip output directory" "$trip_dir"

status_code=0
if [[ "$skip_status" -eq 0 ]]; then
  status_path="${trip_dir}/status.json"
  printf '==> Saving Pi status snapshot\n'
  set +e
  require_helper "$status_helper"
  status_args=("$target")
  if [[ -n "$gps_seconds" ]]; then
    status_args+=(--gps-seconds "$gps_seconds")
  fi
  status_args+=(--json)
  write_private_status_snapshot "$status_path" "$status_helper" "${status_args[@]}"
  status_code=$?
  set -e
  verify_private_output_file "status snapshot" "$status_path"
  if [[ "$status_code" -eq 0 ]]; then
    verify_status_snapshot_json "$status_path"
    printf 'Saved Pi status snapshot: %s\n' "$status_path"
  else
    printf 'Pi status snapshot exited %s; saved output for diagnosis: %s\n' "$status_code" "$status_path" >&2
  fi
else
  printf '==> Skipping Pi status snapshot\n'
fi

if [[ "$skip_tracks" -eq 0 ]]; then
  run_artifact_step \
    "Exporting Pi GPX tracks" \
    "Exported Pi GPX tracks" \
    "track export archive" \
    "$trip_dir" \
    "$tracks_helper" "$target" "$trip_dir" --days "$track_days"
else
  printf '==> Skipping Pi GPX track export\n'
fi

if [[ "$skip_support" -eq 0 ]]; then
  run_artifact_step \
    "Collecting Pi diagnostic support bundle" \
    "Collected Pi support bundle" \
    "support bundle archive" \
    "$trip_dir" \
    "$support_helper" "$target" "$trip_dir"
else
  printf '==> Skipping Pi diagnostic support bundle\n'
fi

write_post_trip_checksum_manifest "$trip_dir"
verify_post_trip_checksum_manifest "$trip_dir"
printf '\nPost-trip Pi artifacts written to: %s\n' "$trip_dir"

if [[ "$status_code" -ne 0 ]]; then
  echo "Post-trip collection completed, but the status snapshot reported a failure." >&2
  if [[ -n "$shutdown_mode" ]]; then
    echo "Continuing with requested clean Pi shutdown after preserving post-trip artifacts." >&2
  fi
fi

case "$shutdown_mode" in
  dry-run)
    run_step "Dry-running clean Pi shutdown path" "$shutdown_helper" "$target" --dry-run
    ;;
  confirm)
    run_step "Requesting clean Pi shutdown" "$shutdown_helper" "$target" --confirm
    ;;
  "")
    ;;
esac

if [[ "$status_code" -ne 0 ]]; then
  exit 1
fi

printf 'Post-trip Pi collection completed for %s.\n' "$target"
