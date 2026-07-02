#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/export_pi_opencpn_data.sh user@raspberrypi.local [output-dir]

Exports OpenCPN user navigation data from the commissioned Raspberry Pi over
SSH. The archive includes trusted regular files such as opencpn.conf,
navobj.xml route/waypoint data, and GPX/XML layer files when present.
NOAA chart archives and extracted ENC cells are not copied.

The script writes a .tgz archive into output-dir, or ./pi-opencpn-exports
by default.
Only output-dir is changed locally. Nothing is installed, enabled, rebooted,
shut down, or downloaded, and no persistent Pi state is changed.
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
output_dir="${1:-pi-opencpn-exports}"
if [[ $# -gt 1 ]]; then
  echo "Unexpected extra arguments" >&2
  usage
  exit 2
fi

ssh_cmd=""
python3_cmd=""
ssh_batch_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
Do not export OpenCPN data as root@.
Use the Pi desktop user so routes, waypoints, and OpenCPN config match the helm account.
EOF
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
  local stat_output
  local owner_uid
  local mode
  local mode_tail

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

  if [[ "${NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS:-0}" == "1" || ( "$command_name" == "ssh" && "${NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH:-0}" == "1" ) ]]; then
    return 0
  fi
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

remote_path_in_trusted_system_dir() {
  case "$1" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*)
      return 0
      ;;
  esac
  return 1
}

validate_remote_python_command_trust() {
  local command_path="$1"
  local command_path_quoted

  if [[ "$command_path" != /* || "$command_path" =~ [[:space:]\"\'] ]]; then
    echo "Remote python3 command path is unsafe: $command_path" >&2
    return 1
  fi
  if ! remote_path_in_trusted_system_dir "$command_path"; then
    echo "Remote python3 command is not in a trusted system directory: $command_path" >&2
    return 1
  fi

  command_path_quoted="$(printf '%q' "$command_path")"
  "$ssh_cmd" "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && /bin/sh -s -- ${command_path_quoted}" <<'REMOTE_PYTHON_COMMAND_TRUST'
set -eu

command_path="$1"

check_trusted_system_path() {
  case "$1" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*)
      return 0
      ;;
  esac
  echo "Remote python3 command resolves outside trusted system directories: $1" >&2
  return 1
}

check_owner_and_mode() {
  item_kind="$1"
  item_path="$2"
  stat_output="$(stat -Lc '%u %a' -- "$item_path")"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"

  if [ "$owner_uid" != "0" ]; then
    echo "Remote python3 command ${item_kind} is owned by uid ${owner_uid}, expected 0: ${item_path}" >&2
    return 1
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      echo "Remote python3 command ${item_kind} has permissions ${mode}, expected no group/other write: ${item_path}" >&2
      return 1
      ;;
  esac
}

check_directory_chain() {
  directory="$(dirname -- "$1")"
  while :; do
    check_owner_and_mode directory "$directory"
    [ "$directory" = "/" ] && break
    directory="$(dirname -- "$directory")"
  done
}

check_trusted_system_path "$command_path"
resolved_cmd="$(readlink -f -- "$command_path")"
check_trusted_system_path "$resolved_cmd"
if [ ! -f "$resolved_cmd" ]; then
  echo "Remote python3 command is not a regular file after resolution: ${command_path} -> ${resolved_cmd}" >&2
  exit 1
fi
if [ ! -x "$resolved_cmd" ]; then
  echo "Remote python3 command is not executable after resolution: ${command_path} -> ${resolved_cmd}" >&2
  exit 1
fi
check_directory_chain "$command_path"
check_directory_chain "$resolved_cmd"
check_owner_and_mode file "$resolved_cmd"
REMOTE_PYTHON_COMMAND_TRUST
}

remote_python_command() {
  local python_cmd

  if ! python_cmd="$("$ssh_cmd" "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && command -v python3" 2>/dev/null)" || [[ -z "$python_cmd" ]]; then
    echo "Could not find the remote python3 command on $target." >&2
    return 1
  fi
  if ! validate_remote_python_command_trust "$python_cmd"; then
    return 1
  fi
  printf '%s\n' "$python_cmd"
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

finalize_private_archive() {
  local path="$1"
  local mode
  local owner_uid
  local stat_output

  if [[ -L "$path" || ! -f "$path" ]]; then
    echo "Export archive must be a regular non-symlink file: $path" >&2
    exit 1
  fi
  if ! chmod 0600 -- "$path"; then
    echo "Could not tighten export archive permissions to 0600: $path" >&2
    exit 1
  fi
  if [[ -L "$path" || ! -f "$path" ]]; then
    echo "Export archive must remain a regular non-symlink file after permission tightening: $path" >&2
    exit 1
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    echo "Could not inspect export archive permissions: $path" >&2
    exit 1
  fi
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  if [[ "$owner_uid" != "$(id -u)" ]]; then
    echo "Export archive is owned by uid ${owner_uid}, expected $(id -u): $path" >&2
    exit 1
  fi
  if [[ "$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')" != "600" ]]; then
    echo "Export archive has permissions ${mode}, expected private 0600: $path" >&2
    exit 1
  fi
}

cleanup_private_partial_file() {
  local path="$1"
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
    print(f"Could not inspect partial export archive for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) & 0o022:
    print(f"Partial export archive is not a trusted private file; leaving it in place: {path}", file=sys.stderr)
    raise SystemExit(0)

try:
    dir_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
except OSError as exc:
    print(f"Could not open partial export archive directory for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
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
        print(f"Partial export archive changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    os.unlink(path.name, dir_fd=dir_fd)
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
}

promote_private_partial_archive() {
  local partial="$1"
  local final="$2"
  local label="$3"
  "$python3_cmd" - "$partial" "$final" "$label" <<'PY'
from pathlib import Path
import os
import stat
import sys

partial = Path(sys.argv[1])
final = Path(sys.argv[2])
label = sys.argv[3]
nofollow = getattr(os, "O_NOFOLLOW", 0)

def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)

if partial.parent != final.parent:
    fail(f"{label} partial and final paths must be in the same directory")

try:
    dir_fd = os.open(partial.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
except OSError as exc:
    fail(f"Could not open {label} directory for promotion: {partial.parent}: {exc}")

try:
    try:
        partial_before = os.stat(partial.name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError as exc:
        fail(f"Could not inspect partial {label} before promotion: {partial}: {exc}")
    if not stat.S_ISREG(partial_before.st_mode):
        fail(f"Partial {label} must be a regular file: {partial}")
    if partial_before.st_uid != os.getuid():
        fail(f"Partial {label} is owned by uid {partial_before.st_uid}, expected {os.getuid()}: {partial}")
    mode = stat.S_IMODE(partial_before.st_mode)
    if mode & 0o077:
        fail(f"Partial {label} has permissions {mode:04o}, expected private 0600: {partial}")
    if partial_before.st_size <= 0:
        fail(f"Partial {label} is empty: {partial}")

    fd = os.open(partial.name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
    try:
        partial_opened = os.fstat(fd)
        if not os.path.samestat(partial_before, partial_opened):
            fail(f"Partial {label} changed while being opened: {partial}")
        os.fchmod(fd, 0o600)
        os.fsync(fd)
    finally:
        os.close(fd)

    try:
        os.stat(final.name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        fail(f"Refusing to overwrite existing {label}: {final}")

    os.link(partial.name, final.name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd, follow_symlinks=False)
    final_fd = os.open(final.name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
    try:
        final_opened = os.fstat(final_fd)
        if not os.path.samestat(partial_opened, final_opened):
            fail(f"Promoted {label} does not match partial file: {final}")
    finally:
        os.close(final_fd)
    os.unlink(partial.name, dir_fd=dir_fd)
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
}

validate_private_archive() {
  local path="$1"
  local count_field="$2"
  "$python3_cmd" - "$path" "$count_field" <<'PY'
from __future__ import annotations

import json
import os
import stat
import sys
import tarfile

archive_path = sys.argv[1]
count_field = sys.argv[2]


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def normalized_member_name(name: str) -> str:
    if "\\" in name:
        fail(f"Export archive contains unsafe backslash member: {name}")
    if name.startswith("/"):
        fail(f"Export archive contains unsafe member path: {name}")
    normalized = name
    while normalized.startswith("./"):
        normalized = normalized[2:]
    normalized = normalized.rstrip("/")
    parts = normalized.split("/") if normalized else []
    if not parts or any(part in {"", ".", ".."} for part in parts):
        fail(f"Export archive contains unsafe member path: {name}")
    return normalized


try:
    before = os.stat(archive_path, follow_symlinks=False)
    fd = os.open(archive_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
except OSError as exc:
    fail(f"Could not open export archive for validation: {archive_path}: {exc}")

try:
    opened = os.fstat(fd)
    if before.st_dev != opened.st_dev or before.st_ino != opened.st_ino:
        fail(f"Export archive changed while being opened: {archive_path}")
    if not stat.S_ISREG(opened.st_mode):
        fail(f"Export archive must be a regular file: {archive_path}")
    if opened.st_uid != os.getuid():
        fail(f"Export archive is owned by uid {opened.st_uid}, expected {os.getuid()}: {archive_path}")
    mode = stat.S_IMODE(opened.st_mode)
    if mode != 0o600:
        fail(f"Export archive has permissions {mode:04o}, expected private 0600: {archive_path}")
    with os.fdopen(fd, "rb") as handle:
        fd = -1
        try:
            with tarfile.open(fileobj=handle, mode="r:gz") as archive:
                members = archive.getmembers()
                by_name = {}
                data_member_names = []
                data_file_count = 0
                for member in members:
                    normalized = normalized_member_name(member.name)
                    if normalized in by_name:
                        fail(f"Export archive contains duplicate member: {normalized}")
                    by_name[normalized] = member
                    if not member.isreg():
                        fail(f"Export archive contains unsupported non-regular member: {member.name}")
                    if normalized not in {"README.txt", "manifest.json"}:
                        data_member_names.append(normalized)
                        data_file_count += 1
                if "README.txt" not in by_name:
                    fail("Export archive is missing README.txt")
                manifest_member = by_name.get("manifest.json")
                if manifest_member is None:
                    fail("Export archive is missing manifest.json")
                manifest_handle = archive.extractfile(manifest_member)
                if manifest_handle is None:
                    fail("Export archive manifest is not readable")
                manifest = json.load(manifest_handle)
        except (tarfile.TarError, json.JSONDecodeError, OSError) as exc:
            fail(f"Export archive is not a readable gzip tar with JSON manifest: {archive_path}: {exc}")
finally:
    if fd >= 0:
        os.close(fd)

if not isinstance(manifest, dict):
    fail("Export archive manifest must be a JSON object")
count = manifest.get(count_field)
if not isinstance(count, int) or count <= 0:
    fail(f"Export archive manifest has invalid {count_field}: {count!r}")
if count != data_file_count:
    fail(f"Export archive manifest {count_field} does not match data file count: {count} != {data_file_count}")
if count_field == "file_count":
    files = manifest.get("files")
    if not isinstance(files, list):
        fail("Export archive manifest files must be a list")
    manifest_file_names = []
    for index, file_entry in enumerate(files):
        if not isinstance(file_entry, dict):
            fail(f"Export archive manifest files[{index}] must be an object")
        archive_path = file_entry.get("archive_path")
        if not isinstance(archive_path, str):
            fail(f"Export archive manifest files[{index}].archive_path is invalid: {archive_path!r}")
        manifest_file_names.append(normalized_member_name(archive_path))
    if sorted(manifest_file_names) != sorted(data_member_names):
        fail(
            "Export archive manifest file names do not match data files: "
            f"{sorted(manifest_file_names)!r} != {sorted(data_member_names)!r}"
        )
PY
}

validate_ssh_target "$target"
validate_output_dir_arg "$output_dir"
output_dir="$(strip_trailing_slashes "$output_dir")"
prepare_private_output_dir "Output directory" "$output_dir"

ssh_cmd="$(require_local_command ssh)"
python3_cmd="$(require_local_command python3)"
remote_python_cmd="$(remote_python_command)"
remote_python_cmd_quoted="$(printf '%q' "$remote_python_cmd")"

timestamp="$(utc_timestamp)"
safe_target="$(printf '%s' "$target" | tr '@.' '___')"
archive_path="${output_dir}/noaa-navionics-pi-opencpn-${safe_target}-${timestamp}.tgz"
if [[ -e "$archive_path" ]]; then
  echo "Refusing to overwrite existing archive: $archive_path" >&2
  exit 2
fi
partial_path="$(mktemp "${output_dir}/.${timestamp}.opencpn-export.XXXXXX")"
cleanup_partial() {
  cleanup_private_partial_file "$partial_path" || true
}
trap cleanup_partial EXIT

"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && ${remote_python_cmd_quoted} -s" >"$partial_path" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import io
import json
import os
import stat
import sys
import tarfile
import time

MAX_OPENCPN_FILE_BYTES = 50 * 1024 * 1024


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def first_symlink_ancestor(path: Path):
    current = Path(path).expanduser()
    for candidate in [current, *current.parents]:
        if candidate.is_symlink():
            return candidate
    return None


def assert_private_directory(path: Path, label: str) -> os.stat_result:
    if path.is_symlink():
        fail(f"{label} is a symlink: {path}")
    symlink = first_symlink_ancestor(path.parent)
    if symlink is not None:
        fail(f"{label} parent path contains a symlink: {symlink}")
    if not path.exists():
        fail(f"{label} does not exist: {path}")
    if not path.is_dir():
        fail(f"{label} is not a directory: {path}")
    try:
        result = path.stat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if result.st_uid != os.getuid():
        fail(f"{label} is owned by uid {result.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode & 0o022:
        fail(f"{label} has permissions {mode:04o}, expected no group/other write bits: {path}")
    return result


def trusted_regular_file(path: Path):
    if first_symlink_ancestor(path.parent) is not None:
        fail(f"OpenCPN export path contains a symlink: {first_symlink_ancestor(path.parent)}")
    try:
        result = path.lstat()
    except OSError:
        return None
    if stat.S_ISLNK(result.st_mode):
        fail(f"refusing to export symlinked OpenCPN file: {path}")
    if not stat.S_ISREG(result.st_mode):
        fail(f"refusing to export non-regular OpenCPN file: {path}")
    if result.st_uid != os.getuid():
        fail(f"OpenCPN file is owned by uid {result.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode & 0o022:
        fail(f"OpenCPN file has permissions {mode:04o}, expected no group/other write bits: {path}")
    if result.st_size > MAX_OPENCPN_FILE_BYTES:
        fail(f"OpenCPN file is too large to export safely: {path} ({result.st_size} bytes > {MAX_OPENCPN_FILE_BYTES})")
    return result


def add_trusted_file(archive: tarfile.TarFile, path: Path, stat_result: os.stat_result, arcname: str) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    current_stat = os.fstat(fd)
    if (current_stat.st_dev, current_stat.st_ino) != (stat_result.st_dev, stat_result.st_ino):
        os.close(fd)
        fail(f"OpenCPN file changed before export: {path}")
    if not stat.S_ISREG(current_stat.st_mode):
        os.close(fd)
        fail(f"opened OpenCPN file is not regular: {path}")
    if current_stat.st_uid != os.getuid():
        os.close(fd)
        fail(f"opened OpenCPN file is owned by uid {current_stat.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(current_stat.st_mode)
    if mode & 0o022:
        os.close(fd)
        fail(f"opened OpenCPN file has permissions {mode:04o}, expected no group/other write bits: {path}")
    if current_stat.st_size > MAX_OPENCPN_FILE_BYTES:
        os.close(fd)
        fail(f"opened OpenCPN file is too large to export safely: {path} ({current_stat.st_size} bytes > {MAX_OPENCPN_FILE_BYTES})")
    info = tarfile.TarInfo(arcname)
    info.size = current_stat.st_size
    info.mode = mode & 0o755
    info.mtime = int(current_stat.st_mtime)
    info.uid = current_stat.st_uid
    info.gid = current_stat.st_gid
    with os.fdopen(fd, "rb") as handle:
        archive.addfile(info, handle)


opencpn_dir = Path.home() / ".opencpn"
assert_private_directory(opencpn_dir, "OpenCPN config directory")

files: list[tuple[Path, os.stat_result, str]] = []
for name in ("opencpn.conf", "navobj.xml"):
    path = opencpn_dir / name
    result = trusted_regular_file(path)
    if result is not None:
        files.append((path, result, f"opencpn/{name}"))
for path in sorted(opencpn_dir.glob("navobj.xml.*")):
    result = trusted_regular_file(path)
    if result is not None:
        files.append((path, result, f"opencpn/{path.name}"))
for layers_dir_name in ("layers", "Layers"):
    layers_dir = opencpn_dir / layers_dir_name
    if not layers_dir.exists():
        continue
    assert_private_directory(layers_dir, f"OpenCPN {layers_dir_name} directory")
    for path in sorted(layers_dir.rglob("*")):
        if path.is_dir():
            assert_private_directory(path, f"OpenCPN {layers_dir_name} subdirectory")
            continue
        if path.suffix.lower() not in {".gpx", ".xml"}:
            continue
        result = trusted_regular_file(path)
        if result is not None:
            files.append((path, result, f"opencpn/{layers_dir_name}/{path.relative_to(layers_dir)}"))

if not files:
    fail(f"no trusted OpenCPN config, navobj.xml, or layer GPX/XML files found under {opencpn_dir}")

manifest = {
    "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "opencpn_directory": str(opencpn_dir),
    "file_count": len(files),
    "files": [
        {
            "archive_path": arcname,
            "source_path": str(path),
            "size": stat_result.st_size,
            "mtime": datetime.fromtimestamp(stat_result.st_mtime, timezone.utc).isoformat().replace("+00:00", "Z"),
        }
        for path, stat_result, arcname in files
    ],
}
readme = (
    "NOAA Navionics Raspberry Pi OpenCPN user-data export\n"
    f"Generated: {manifest['generated_at']}\n"
    f"OpenCPN directory: {opencpn_dir}\n"
    f"Files: {len(files)}\n"
    "This archive contains OpenCPN user config, routes, waypoints, and layer GPX/XML files only; "
    "NOAA chart archives and extracted ENC cells are not included.\n"
)

with tarfile.open(fileobj=sys.stdout.buffer, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
    for name, text in {
        "README.txt": readme,
        "manifest.json": json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    }.items():
        data = text.encode("utf-8")
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = 0o600
        info.mtime = int(time.time())
        archive.addfile(info, io.BytesIO(data))
    for path, stat_result, arcname in files:
        add_trusted_file(archive, path, stat_result, arcname)
PY

if [[ ! -s "$partial_path" ]]; then
  echo "OpenCPN export archive is empty" >&2
  exit 1
fi
promote_private_partial_archive "$partial_path" "$archive_path" "export archive"
finalize_private_archive "$archive_path"
validate_private_archive "$archive_path" "file_count"
trap - EXIT
printf 'Exported Pi OpenCPN user data: %s\n' "$archive_path"
