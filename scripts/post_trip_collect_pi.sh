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
  --track-days N       Export GPX tracks modified in the last N days; 0 exports all (default: 30)
  --gps-seconds N      Seconds to wait for a GPS fix in the status snapshot (default: 10)
  --skip-status        Skip the local private JSON status snapshot
  --skip-tracks        Skip GPX track export
  --skip-support       Skip diagnostic support bundle collection
  --shutdown-dry-run   Validate the remote shutdown path without powering off
  --shutdown-confirm   Request a clean Pi poweroff after collection

This wrapper does not install, enable, reboot, download charts, or change
anything on the local computer. Shutdown is opt-in only.
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
gps_seconds=10
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

utc_timestamp() {
  local stamp
  TZ=UTC0 printf -v stamp '%(%Y%m%dT%H%M%SZ)T' -1
  printf '%s\n' "$stamp"
}

verify_private_output_file() {
  local label="$1"
  local path="$2"
  local current_uid
  local mode
  local owner_uid
  local stat_output

  current_uid="$(id -u)"
  if [[ -L "$path" || ! -f "$path" ]]; then
    echo "$label must be a regular non-symlink file: $path" >&2
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
  if [[ "$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')" != "600" ]]; then
    echo "$label has permissions ${mode}, expected private 0600: $path" >&2
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
        result = subprocess.run(command, stdout=output)
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
import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)

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
if not isinstance(payload.get("generated_at"), str) or not payload["generated_at"].strip():
    print(f"status snapshot JSON missing generated_at field: {path}", file=sys.stderr)
    raise SystemExit(124)
for field in ("checks", "service_checks"):
    rows = payload.get(field)
    if not isinstance(rows, list):
        print(f"status snapshot JSON missing {field} list: {path}", file=sys.stderr)
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

import os
import stat
import sys
import tarfile
from pathlib import Path

label = sys.argv[1]
path = Path(sys.argv[2]).expanduser()
parent = Path(sys.argv[3]).expanduser()
if not path.is_absolute():
    path = Path.cwd() / path
if not parent.is_absolute():
    parent = Path.cwd() / parent
nofollow = getattr(os, "O_NOFOLLOW", 0)

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
                names = archive.getnames()
        except (tarfile.TarError, OSError) as exc:
            print(f"{label} is not a readable gzip tar archive: {path}: {exc}", file=sys.stderr)
            raise SystemExit(124) from exc
finally:
    if fd >= 0:
        os.close(fd)

if not names:
    print(f"{label} archive is empty: {path}", file=sys.stderr)
    raise SystemExit(124)
for name in names:
    normalized = Path(name)
    if name in {"", ".", ".."} or name.startswith("/") or any(part in {"", ".", ".."} for part in normalized.parts):
        print(f"{label} archive contains unsafe member name: {name}", file=sys.stderr)
        raise SystemExit(124)
PY
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

run_artifact_step() {
  local label="$1"
  local marker="$2"
  local archive_label="$3"
  local parent="$4"
  local output
  local status
  local artifact_path
  shift 4

  printf '==> %s\n' "$label"
  set +e
  output="$("$@" 2>&1)"
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
  local current_uid
  local mode
  local mode_tail
  local owner_uid
  local stat_output

  if [[ -L "$path" ]]; then
    echo "Helper script must not be a symlink: $path" >&2
    exit 2
  fi
  reject_symlinked_path_components "Helper script" "$path"
  if [[ ! -f "$path" || ! -x "$path" ]]; then
    echo "Helper script is missing or not executable: $path" >&2
    exit 2
  fi
  current_uid="$(id -u)"
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    echo "Could not inspect helper script owner and permissions: $path" >&2
    exit 2
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    echo "Helper script is owned by uid ${owner_uid}, expected current user ${current_uid}: $path" >&2
    exit 2
  fi
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  case "$mode_tail" in
    ?[2367]?|??[2367])
      echo "Helper script has permissions ${mode}, expected no group/other write bits: $path" >&2
      exit 2
      ;;
  esac
}

run_step() {
  local label="$1"
  shift
  printf '==> %s\n' "$label"
  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
if [[ "$skip_status" -eq 1 && "$skip_tracks" -eq 1 && "$skip_support" -eq 1 && -z "$shutdown_mode" ]]; then
  echo "At least one post-trip collection or shutdown step must run" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status_helper="${repo_root}/scripts/check_pi_status.sh"
tracks_helper="${repo_root}/scripts/export_pi_tracks.sh"
support_helper="${repo_root}/scripts/collect_pi_support_bundle.sh"
shutdown_helper="${repo_root}/scripts/shutdown_pi_safely.sh"
require_helper "$status_helper"
require_helper "$tracks_helper"
require_helper "$support_helper"
require_helper "$shutdown_helper"
if [[ "$skip_status" -eq 0 || "$skip_tracks" -eq 0 || "$skip_support" -eq 0 ]]; then
  python3_cmd="$(require_local_command python3)"
fi

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
  write_private_status_snapshot "$status_path" "$status_helper" "$target" --gps-seconds "$gps_seconds" --json
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

printf '\nPost-trip Pi artifacts written to: %s\n' "$trip_dir"
if [[ "$status_code" -ne 0 ]]; then
  echo "Post-trip collection completed, but the status snapshot reported a failure." >&2
  exit 1
fi
printf 'Post-trip Pi collection completed for %s.\n' "$target"
