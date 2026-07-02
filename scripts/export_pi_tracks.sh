#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/export_pi_tracks.sh user@raspberrypi.local [output-dir] [options]

Exports GPX track logs from the commissioned Raspberry Pi over SSH.
The helper reads the Pi's onboard NOAA Navionics config, packages only
regular private .gpx files from the configured track directory, and writes
a .tgz archive into output-dir, or ./pi-track-exports by default.

Options:
  --days N           Export tracks modified in the last N days; 0 exports all
                     (max: 3650)

Only output-dir is changed locally. Nothing is installed, enabled, rebooted,
shut down, or downloaded, and no persistent Pi state is changed. NOAA chart
archives and extracted ENC cells are not copied.
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
output_dir="pi-track-exports"
days=0
max_days=3650
if [[ $# -gt 0 && "$1" != --* ]]; then
  output_dir="$1"
  shift
fi

ssh_cmd=""
python3_cmd=""
ssh_batch_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      require_integer_at_most "$1" "${2:-}" "$max_days"
      days="$(normalize_decimal_integer "${2:-}")"
      shift 2
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
Do not export tracks as root@.
Use the Pi desktop user so GPX track ownership matches the real helm account.
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

capture_private_partial_file_identity() {
  local path="$1"
  local label="$2"
  "$python3_cmd" - "$path" "$label" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
label = sys.argv[2]

try:
    result = os.stat(path, follow_symlinks=False)
except OSError as exc:
    print(f"Could not inspect {label}: {path}: {exc}", file=sys.stderr)
    raise SystemExit(1)
if not stat.S_ISREG(result.st_mode):
    print(f"{label} must be a regular file: {path}", file=sys.stderr)
    raise SystemExit(1)
if result.st_uid != os.getuid():
    print(f"{label} is owned by uid {result.st_uid}, expected {os.getuid()}: {path}", file=sys.stderr)
    raise SystemExit(1)
mode = stat.S_IMODE(result.st_mode)
if mode & 0o077:
    print(f"{label} has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
    raise SystemExit(1)
print(f"{result.st_dev}:{result.st_ino}")
PY
}

cleanup_private_partial_file() {
  local path="$1"
  local expected_identity="$2"
  "$python3_cmd" - "$path" "$expected_identity" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
expected_identity = sys.argv[2]
nofollow = getattr(os, "O_NOFOLLOW", 0)

try:
    expected_dev_text, expected_ino_text = expected_identity.split(":", 1)
    expected_identity_tuple = (int(expected_dev_text), int(expected_ino_text))
except ValueError:
    print(f"Could not parse partial export archive identity for cleanup; leaving it in place: {path}", file=sys.stderr)
    raise SystemExit(0)

try:
    before = os.stat(path, follow_symlinks=False)
except FileNotFoundError:
    raise SystemExit(0)
except OSError as exc:
    print(f"Could not inspect partial export archive for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

if (before.st_dev, before.st_ino) != expected_identity_tuple:
    print(f"Partial export archive changed before cleanup; leaving it in place: {path}", file=sys.stderr)
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
  local expected_identity="$3"
  local label="$4"
  "$python3_cmd" - "$partial" "$final" "$expected_identity" "$label" <<'PY'
from pathlib import Path
import os
import stat
import sys

partial = Path(sys.argv[1])
final = Path(sys.argv[2])
expected_identity = sys.argv[3]
label = sys.argv[4]
nofollow = getattr(os, "O_NOFOLLOW", 0)

def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)

if partial.parent != final.parent:
    fail(f"{label} partial and final paths must be in the same directory")

try:
    expected_dev_text, expected_ino_text = expected_identity.split(":", 1)
    expected_identity_tuple = (int(expected_dev_text), int(expected_ino_text))
except ValueError:
    fail(f"Could not parse partial {label} identity: {expected_identity!r}")

try:
    dir_fd = os.open(partial.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
except OSError as exc:
    fail(f"Could not open {label} directory for promotion: {partial.parent}: {exc}")

try:
    try:
        partial_before = os.stat(partial.name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError as exc:
        fail(f"Could not inspect partial {label} before promotion: {partial}: {exc}")
    if (partial_before.st_dev, partial_before.st_ino) != expected_identity_tuple:
        fail(f"Partial {label} changed before promotion: {partial}")
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
                        if count_field == "track_count":
                            if not normalized.startswith("tracks/") or not normalized.endswith(".gpx"):
                                fail(f"Export archive contains non-GPX track data member: {member.name}")
                            track_name = normalized.removeprefix("tracks/")
                            if not track_name or "/" in track_name:
                                fail(f"Export archive contains nested or empty track data member: {member.name}")
                            data_member_names.append(track_name)
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
if count_field == "track_count":
    tracks = manifest.get("tracks")
    if not isinstance(tracks, list):
        fail("Export archive manifest tracks must be a list")
    manifest_track_names = []
    for index, track in enumerate(tracks):
        if not isinstance(track, dict):
            fail(f"Export archive manifest tracks[{index}] must be an object")
        name = track.get("name")
        if not isinstance(name, str) or not name or "/" in name or "\\" in name or name in {".", ".."}:
            fail(f"Export archive manifest tracks[{index}].name is invalid: {name!r}")
        manifest_track_names.append(name)
    if sorted(manifest_track_names) != sorted(data_member_names):
        fail(
            "Export archive manifest track names do not match data files: "
            f"{sorted(manifest_track_names)!r} != {sorted(data_member_names)!r}"
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
archive_path="${output_dir}/noaa-navionics-pi-tracks-${safe_target}-${timestamp}.tgz"
if [[ -e "$archive_path" ]]; then
  echo "Refusing to overwrite existing archive: $archive_path" >&2
  exit 2
fi
partial_path="$(mktemp "${output_dir}/.${timestamp}.track-export.XXXXXX")"
partial_identity="$(capture_private_partial_file_identity "$partial_path" "export archive partial")"
cleanup_partial() {
  cleanup_private_partial_file "$partial_path" "$partial_identity" || true
}
trap cleanup_partial EXIT

"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && NOAA_NAVIONICS_EXPORT_DAYS=${days} ${remote_python_cmd_quoted} -s" >"$partial_path" <<'PY'
from configparser import ConfigParser
from datetime import datetime, timezone
from pathlib import Path
import io
import json
import os
import stat
import sys
import tarfile
import time

MAX_TRACK_FILE_BYTES = 100 * 1024 * 1024


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
    if mode & 0o077:
        fail(f"{label} has permissions {mode:04o}, expected private 0700: {path}")
    return result


def assert_private_track(path: Path):
    try:
        result = path.lstat()
    except OSError:
        return None
    if stat.S_ISLNK(result.st_mode):
        fail(f"refusing to export symlinked GPX track: {path}")
    if not stat.S_ISREG(result.st_mode):
        fail(f"refusing to export non-regular GPX track: {path}")
    if result.st_uid != os.getuid():
        fail(f"GPX track is owned by uid {result.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode & 0o077:
        fail(f"GPX track has permissions {mode:04o}, expected private 0600: {path}")
    if result.st_size > MAX_TRACK_FILE_BYTES:
        fail(f"GPX track is too large to export safely: {path} ({result.st_size} bytes > {MAX_TRACK_FILE_BYTES})")
    return result


def parse_days() -> int:
    raw = os.environ.get("NOAA_NAVIONICS_EXPORT_DAYS", "0")
    if not raw.isdigit():
        fail(f"NOAA_NAVIONICS_EXPORT_DAYS must be a non-negative integer: {raw}")
    return int(raw)


home = Path.home()
config_path = home / ".config" / "noaa-navionics" / "config.ini"
if config_path.is_symlink():
    fail(f"onboard config is a symlink: {config_path}")
if first_symlink_ancestor(config_path.parent) is not None:
    fail(f"onboard config parent path contains a symlink: {first_symlink_ancestor(config_path.parent)}")
if not config_path.exists():
    fail(f"onboard config is missing: {config_path}")
if not config_path.is_file():
    fail(f"onboard config is not a regular file: {config_path}")
config_stat = config_path.stat()
if config_stat.st_uid != os.getuid():
    fail(f"onboard config is owned by uid {config_stat.st_uid}, expected {os.getuid()}: {config_path}")
if stat.S_IMODE(config_stat.st_mode) & 0o077:
    fail(f"onboard config has permissions {stat.S_IMODE(config_stat.st_mode):04o}, expected private 0600: {config_path}")

parser = ConfigParser()
config_fd = os.open(config_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
config_current_stat = os.fstat(config_fd)
if (config_current_stat.st_dev, config_current_stat.st_ino) != (config_stat.st_dev, config_stat.st_ino):
    os.close(config_fd)
    fail(f"onboard config changed before export: {config_path}")
with os.fdopen(config_fd, encoding="utf-8") as config_handle:
    parser.read_file(config_handle)
chart_output = Path(os.path.expanduser(parser.get("charts", "output", fallback="~/charts/noaa-enc")))
track_output = Path(os.path.expanduser(parser.get("tracking", "output", fallback=str(chart_output))))
track_dir = track_output / "tracks"
if not track_output.is_absolute():
    fail(f"configured track output is not absolute after expansion: {track_output}")
assert_private_directory(track_output, "configured track output")
assert_private_directory(track_dir, "configured GPX track directory")

days = parse_days()
cutoff = time.time() - days * 86400 if days > 0 else None
tracks: list[tuple[Path, os.stat_result]] = []
for candidate in sorted(track_dir.glob("*.gpx")):
    track_stat = assert_private_track(candidate)
    if track_stat is None:
        continue
    if cutoff is not None and track_stat.st_mtime < cutoff:
        continue
    tracks.append((candidate, track_stat))
if not tracks:
    if days > 0:
        fail(f"no private GPX track files modified in the last {days} day(s) under {track_dir}")
    fail(f"no private GPX track files found under {track_dir}")

manifest = {
    "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "config_path": str(config_path),
    "track_output": str(track_output),
    "track_directory": str(track_dir),
    "days": days,
    "track_count": len(tracks),
    "tracks": [
        {
            "name": path.name,
            "size": track_stat.st_size,
            "mtime": datetime.fromtimestamp(track_stat.st_mtime, timezone.utc).isoformat().replace("+00:00", "Z"),
        }
        for path, track_stat in tracks
    ],
}
readme = (
    "NOAA Navionics Raspberry Pi GPX track export\n"
    f"Generated: {manifest['generated_at']}\n"
    f"Track directory: {track_dir}\n"
    f"Track files: {len(tracks)}\n"
    "This archive contains GPX track logs only; NOAA chart archives and extracted ENC cells are not included.\n"
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
    for path, track_stat in tracks:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        current_stat = os.fstat(fd)
        if (current_stat.st_dev, current_stat.st_ino) != (track_stat.st_dev, track_stat.st_ino):
            os.close(fd)
            fail(f"GPX track changed before export: {path}")
        if not stat.S_ISREG(current_stat.st_mode):
            os.close(fd)
            fail(f"opened GPX track is not regular: {path}")
        if current_stat.st_uid != os.getuid():
            os.close(fd)
            fail(f"opened GPX track is owned by uid {current_stat.st_uid}, expected {os.getuid()}: {path}")
        if stat.S_IMODE(current_stat.st_mode) & 0o077:
            os.close(fd)
            fail(f"opened GPX track has permissions {stat.S_IMODE(current_stat.st_mode):04o}, expected private 0600: {path}")
        if current_stat.st_size > MAX_TRACK_FILE_BYTES:
            os.close(fd)
            fail(f"opened GPX track is too large to export safely: {path} ({current_stat.st_size} bytes > {MAX_TRACK_FILE_BYTES})")
        info = tarfile.TarInfo(f"tracks/{path.name}")
        info.size = current_stat.st_size
        info.mode = 0o600
        info.mtime = int(current_stat.st_mtime)
        info.uid = current_stat.st_uid
        info.gid = current_stat.st_gid
        with os.fdopen(fd, "rb") as handle:
            archive.addfile(info, handle)
PY

if [[ ! -s "$partial_path" ]]; then
  echo "Track export archive is empty" >&2
  exit 1
fi
promote_private_partial_archive "$partial_path" "$archive_path" "$partial_identity" "export archive"
finalize_private_archive "$archive_path"
validate_private_archive "$archive_path" "track_count"
trap - EXIT
printf 'Exported Pi GPX tracks: %s\n' "$archive_path"
