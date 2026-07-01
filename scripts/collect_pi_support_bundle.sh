#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/collect_pi_support_bundle.sh user@raspberrypi.local [output-dir]

Collects a read-only diagnostic bundle from an already commissioned
Raspberry Pi over SSH. The bundle includes NOAA Navionics config,
status reports, launcher logs, installed user units, selected OpenCPN/GPSD/
chrony/LightDM config files when readable, recent relevant journal output,
service state, device listings, disk space, and Pi health command output.

The script writes a .tgz bundle into output-dir, or ./pi-support-bundles
by default.
Nothing is installed, enabled, rebooted, downloaded, or changed on the
local computer. The Pi-side temporary collection directory is removed before
the SSH session exits.
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
output_dir="${1:-pi-support-bundles}"
if [[ $# -gt 1 ]]; then
  echo "Unexpected extra arguments" >&2
  usage
  exit 2
fi

ssh_cmd=""
ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
Do not collect support bundles as root@.
Use the Pi desktop user so user services, charts, and logs are collected for the real helm account.
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

validate_ssh_target "$target"
validate_output_dir_arg "$output_dir"
output_dir="$(strip_trailing_slashes "$output_dir")"
ssh_cmd="$(require_local_command ssh)"
remote_python_cmd="$(remote_python_command)"
remote_python_cmd_quoted="$(printf '%q' "$remote_python_cmd")"

prepare_private_output_dir "Output directory" "$output_dir"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_target="$(printf '%s' "$target" | tr '@.' '___')"
bundle_path="${output_dir}/noaa-navionics-pi-support-${safe_target}-${timestamp}.tgz"
if [[ -e "$bundle_path" ]]; then
  echo "Refusing to overwrite existing bundle: $bundle_path" >&2
  exit 2
fi
partial_path="$(mktemp "${output_dir}/.${timestamp}.support-bundle.XXXXXX")"
cleanup_partial() {
  rm -f -- "$partial_path"
}
trap cleanup_partial EXIT

"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && /bin/bash -s -- ${remote_python_cmd_quoted}" >"$partial_path" <<'REMOTE'
set -euo pipefail
python3_cmd="${1:-}"
if [[ "$python3_cmd" != /* || "$python3_cmd" =~ [[:space:]\"\'] ]]; then
  printf 'trusted remote python3 command path is missing or unsafe: %s\n' "$python3_cmd" >&2
  exit 1
fi
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

cache_parent="${HOME}/.cache"
cache_dir="${cache_parent}/noaa-navionics"
if [[ -L "$cache_parent" || -L "$cache_dir" ]]; then
  printf 'support bundle cache path must not be a symlink\n' >&2
  exit 1
fi
mkdir -p "$cache_dir"
chmod 0700 "$cache_parent" "$cache_dir"
if [[ ! -d "$cache_dir" || -L "$cache_dir" ]]; then
  printf 'support bundle cache directory must be a real directory: %s\n' "$cache_dir" >&2
  exit 1
fi
if [[ "$(stat -c '%u %a' "$cache_dir" 2>/dev/null)" != "$(id -u) 700" ]]; then
  printf 'support bundle cache directory must be user-owned private 0700: %s\n' "$cache_dir" >&2
  exit 1
fi
bundle_root="$(mktemp -d "${cache_dir}/support-bundle.XXXXXX")"
files_dir="${bundle_root}/files"
commands_dir="${bundle_root}/commands"
mkdir "$files_dir" "$commands_dir"
cleanup_remote_bundle() {
  case "$bundle_root" in
    "$cache_dir"/support-bundle.*)
      if [[ -d "$bundle_root" && ! -L "$bundle_root" ]]; then
        if ! "$python3_cmd" - "$cache_dir" "$bundle_root" <<'PY'
from __future__ import annotations

from pathlib import Path
import os
import shutil
import stat
import sys

cache_dir = Path(sys.argv[1])
bundle_root = Path(sys.argv[2])

try:
    if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):
        raise RuntimeError(
            "support bundle cleanup requires Python shutil.rmtree with symlink-attack resistance"
        )
    cache_stat = cache_dir.lstat()
    root_stat = bundle_root.lstat()
    if stat.S_ISLNK(cache_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
        raise RuntimeError("support bundle cleanup paths must not be symlinks")
    if not stat.S_ISDIR(cache_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise RuntimeError("support bundle cleanup paths must be real directories")
    if cache_stat.st_uid != os.getuid() or root_stat.st_uid != os.getuid():
        raise RuntimeError("support bundle cleanup paths must be owned by the current user")
    if stat.S_IMODE(cache_stat.st_mode) != 0o700 or stat.S_IMODE(root_stat.st_mode) != 0o700:
        raise RuntimeError("support bundle cleanup paths must be private 0700 directories")
    if bundle_root.parent != cache_dir or not bundle_root.name.startswith("support-bundle."):
        raise RuntimeError(f"refusing to clean unexpected support bundle path: {bundle_root}")
    shutil.rmtree(bundle_root)
except FileNotFoundError:
    pass
except Exception as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1) from exc
PY
        then
          printf 'leaving support bundle temporary directory in place: %s\n' "$bundle_root" >&2
        fi
      fi
      ;;
  esac
}
trap cleanup_remote_bundle EXIT

write_note() {
  printf '%s\n' "$*" >>"${commands_dir}/collection-notes.txt"
}

copy_regular_if_readable() {
  local src="$1"
  local dest
  local copy_error
  if [[ -L "$src" ]]; then
    write_note "skipped symlink: $src"
    return 0
  fi
  if [[ ! -e "$src" ]]; then
    write_note "missing: $src"
    return 0
  fi
  if [[ ! -f "$src" ]]; then
    write_note "skipped non-regular file: $src"
    return 0
  fi
  dest="${files_dir}${src}"
  mkdir -p -- "$(dirname -- "$dest")"
  copy_error="${dest}.copy-error"
  if "$python3_cmd" - "$src" "$dest" 2>"$copy_error" <<'PY'
from __future__ import annotations

from pathlib import Path
import os
import shutil
import stat
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
nofollow = getattr(os, "O_NOFOLLOW", 0)
tmp_path: Path | None = None
src_fd = -1
dst_fd = -1

try:
    expected = source.lstat()
    if stat.S_ISLNK(expected.st_mode):
        raise RuntimeError(f"refusing to copy symlink: {source}")
    if not stat.S_ISREG(expected.st_mode):
        raise RuntimeError(f"refusing to copy non-regular file: {source}")

    src_fd = os.open(source, os.O_RDONLY | nofollow)
    opened = os.fstat(src_fd)
    if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
        raise RuntimeError(f"file changed before copy: {source}")
    if not stat.S_ISREG(opened.st_mode):
        raise RuntimeError(f"opened source is not regular: {source}")

    target.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow
    for attempt in range(100):
        candidate = target.with_name(f".{target.name}.copy-{os.getpid()}-{attempt}")
        try:
            dst_fd = os.open(candidate, flags, 0o600)
            tmp_path = candidate
            break
        except FileExistsError:
            continue
    else:
        raise RuntimeError(f"could not create temporary copy for {target}")

    mode = stat.S_IMODE(opened.st_mode) & 0o777
    os.fchmod(dst_fd, mode)
    with os.fdopen(src_fd, "rb") as src_handle:
        src_fd = -1
        with os.fdopen(dst_fd, "wb") as dst_handle:
            dst_fd = -1
            shutil.copyfileobj(src_handle, dst_handle)
            dst_handle.flush()
            os.fsync(dst_handle.fileno())
    os.utime(tmp_path, ns=(opened.st_atime_ns, opened.st_mtime_ns), follow_symlinks=False)
    os.replace(tmp_path, target)
    tmp_path = None
except Exception as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1) from exc
finally:
    if src_fd >= 0:
        os.close(src_fd)
    if dst_fd >= 0:
        os.close(dst_fd)
    if tmp_path is not None:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
PY
  then
    rm -f -- "$copy_error"
  else
    write_note "could not copy: $src"
  fi
}

run_command() {
  local name="$1"
  shift
  local output="${commands_dir}/${name}.txt"
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } >"$output" 2>&1 || {
    local status=$?
    printf '\n(command exited %s)\n' "$status" >>"$output"
  }
}

support_check_failed() {
  printf '%s\n' "$*"
  return 1
}

check_user_owned_nonwritable_directory() {
  local label="$1"
  local path="$2"
  local current_uid
  local mode
  local mode_tail
  local owner_uid
  local stat_output

  if [[ -L "$path" ]]; then
    support_check_failed "$label is a symlink: $path"
    return 1
  fi
  if [[ ! -d "$path" ]]; then
    support_check_failed "$label is missing or not a directory: $path"
    return 1
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$path" 2>/dev/null)"; then
    support_check_failed "could not inspect $label: $path"
    return 1
  fi
  current_uid="$(id -u)"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    support_check_failed "$label is owned by uid $owner_uid, expected $current_uid: $path"
    return 1
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      support_check_failed "$label has permissions $mode, expected no group/other write: $path"
      return 1
      ;;
  esac
}

check_installed_noaa_command_tree() {
  check_user_owned_nonwritable_directory "home directory" "$HOME" &&
  check_user_owned_nonwritable_directory "installed command directory" "${HOME}/.local" &&
  check_user_owned_nonwritable_directory "installed command directory" "${HOME}/.local/bin" &&
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share" &&
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics" &&
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics/venv" &&
  check_user_owned_nonwritable_directory "installed command venv directory" "${HOME}/.local/share/noaa-navionics/venv/bin"
}

check_installed_noaa_command() {
  local app_bin="${HOME}/.local/bin/noaa-navionics"
  local current_uid
  local expected_venv_bin="${HOME}/.local/share/noaa-navionics/venv/bin/noaa-navionics"
  local mode
  local mode_tail
  local owner_uid
  local resolved
  local stat_output

  check_installed_noaa_command_tree || return 1
  if [[ ! -L "$app_bin" ]]; then
    support_check_failed "installed noaa-navionics command is not the expected private venv symlink: $app_bin"
    return 1
  fi
  if ! resolved="$(readlink -f -- "$app_bin" 2>/dev/null)" || [[ -z "$resolved" ]]; then
    support_check_failed "could not resolve installed noaa-navionics command: $app_bin"
    return 1
  fi
  if [[ "$resolved" != "$expected_venv_bin" ]]; then
    support_check_failed "installed noaa-navionics command resolves to $resolved, expected $expected_venv_bin"
    return 1
  fi
  if [[ ! -f "$resolved" ]]; then
    support_check_failed "installed noaa-navionics command target is not a regular file: $resolved"
    return 1
  fi
  if [[ ! -x "$resolved" ]]; then
    support_check_failed "installed noaa-navionics command is not executable after resolution: $resolved"
    return 1
  fi
  if ! stat_output="$(stat -Lc '%u %a' -- "$resolved" 2>/dev/null)"; then
    support_check_failed "could not inspect installed noaa-navionics command target: $resolved"
    return 1
  fi
  current_uid="$(id -u)"
  owner_uid="${stat_output%% *}"
  mode="${stat_output#* }"
  mode_tail="$(printf '%s\n' "$mode" | sed 's/.*\(...\)$/\1/')"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    support_check_failed "installed noaa-navionics command target is owned by uid $owner_uid, expected $current_uid: $resolved"
    return 1
  fi
  case "$mode_tail" in
    ?[2367]?|??[2367])
      support_check_failed "installed noaa-navionics command target has permissions $mode, expected no group/other write: $resolved"
      return 1
      ;;
  esac
  printf '%s\n' "$resolved"
}

collect_noaa_gps_device_candidates() {
  local app_exec
  if app_exec="$(check_installed_noaa_command)"; then
    run_command noaa-gps-device-candidates "$app_exec" list-gps-devices
  else
    write_note "skipped noaa-navionics list-gps-devices: ${app_exec}"
  fi
}

copy_glob() {
  local matched=0
  local path
  for path in "$@"; do
    if [[ -e "$path" || -L "$path" ]]; then
      matched=1
      copy_regular_if_readable "$path"
    fi
  done
  if [[ "$matched" -eq 0 ]]; then
    write_note "no files matched: $*"
  fi
}

collect_configured_storage_metadata() {
  local config="${HOME}/.config/noaa-navionics/config.ini"
  local path_report="${commands_dir}/configured-storage-paths.txt"
  local key
  local value

  if [[ ! -f "$config" || -L "$config" ]]; then
    write_note "onboard config missing or symlinked; could not parse configured chart and track paths"
    return 0
  fi
  if ! "$python3_cmd" - "$config" >"$path_report" <<'PY'
from configparser import ConfigParser
from pathlib import Path
import os
import stat
import sys

config_path = Path(sys.argv[1]).expanduser()
if config_path.is_symlink():
    raise SystemExit(f"onboard config is a symlink: {config_path}")
for candidate in [config_path.parent, *config_path.parent.parents]:
    if candidate.is_symlink():
        raise SystemExit(f"onboard config parent path contains a symlink: {candidate}")
try:
    expected = config_path.lstat()
except OSError as exc:
    raise SystemExit(f"could not inspect onboard config: {exc}") from exc
if not stat.S_ISREG(expected.st_mode):
    raise SystemExit(f"onboard config is not a regular file: {config_path}")
if expected.st_uid != os.getuid():
    raise SystemExit(f"onboard config is owned by uid {expected.st_uid}, expected {os.getuid()}: {config_path}")
mode = stat.S_IMODE(expected.st_mode)
if mode & 0o077:
    raise SystemExit(f"onboard config has permissions {mode:04o}, expected private 0600: {config_path}")
config_fd = os.open(config_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
opened = os.fstat(config_fd)
if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
    os.close(config_fd)
    raise SystemExit(f"onboard config changed before storage metadata parse: {config_path}")
parser = ConfigParser()
with os.fdopen(config_fd, encoding="utf-8") as config_handle:
    parser.read_file(config_handle)
chart_text = parser.get("charts", "output", fallback="~/charts/noaa-enc")
chart_output = Path(os.path.expanduser(chart_text))
track_text = parser.get("tracking", "output", fallback=str(chart_output))
track_output = Path(os.path.expanduser(track_text))
print(f"chart_output\t{chart_output}")
print(f"chart_manifest\t{chart_output / 'noaa-navionics-manifest.json'}")
print(f"track_output\t{track_output}")
print(f"track_directory\t{track_output / 'tracks'}")
PY
  then
    write_note "could not parse onboard config for chart and track paths"
    return 0
  fi

  while IFS=$'\t' read -r key value; do
    case "$key" in
      chart_manifest)
        copy_regular_if_readable "$value"
        ;;
      chart_output)
        run_command configured-chart-storage-tree bash -lc 'find "$1" -maxdepth 2 -mindepth 1 -ls 2>&1 || true' _ "$value"
        ;;
      track_output)
        run_command configured-track-storage-tree bash -lc 'find "$1" -maxdepth 2 -mindepth 1 \( -type d -o -name "*.gpx" \) -ls 2>&1 || true' _ "$value"
        ;;
    esac
  done <"$path_report"
}

copy_regular_if_readable "${HOME}/.config/noaa-navionics/config.ini"
copy_regular_if_readable "${HOME}/.config/noaa-navionics/launcher.env"
copy_regular_if_readable "${HOME}/.cache/noaa-navionics/status.json"
copy_regular_if_readable "${HOME}/.cache/noaa-navionics/chartplotter.log"
copy_regular_if_readable "${HOME}/.cache/noaa-navionics/chartplotter.log.1"
copy_regular_if_readable "${HOME}/.local/share/noaa-navionics/source-revision"
copy_regular_if_readable "${HOME}/.opencpn/opencpn.conf"
copy_regular_if_readable "${HOME}/.config/autostart/noaa-navionics-chartplotter.desktop"
copy_glob "${HOME}"/.config/systemd/user/noaa-navionics*.service "${HOME}"/.config/systemd/user/noaa-navionics*.timer
copy_regular_if_readable /etc/default/gpsd
copy_regular_if_readable /etc/chrony/conf.d/noaa-navionics-gpsd.conf
copy_regular_if_readable /etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf
collect_configured_storage_metadata

run_command date-utc date -u
run_command uname uname -a
run_command hostname hostname
run_command uptime uptime
run_command df df -h
run_command mount-findmnt findmnt
run_command serial-devices bash -lc 'ls -l /dev/serial /dev/serial/by-id 2>&1 || true'
collect_noaa_gps_device_candidates
run_command noaa-cache-tree bash -lc 'find "$HOME/.cache/noaa-navionics" -maxdepth 3 -mindepth 1 -ls 2>&1 || true'
run_command noaa-config-tree bash -lc 'find "$HOME/.config/noaa-navionics" -maxdepth 3 -mindepth 1 -ls 2>&1 || true'
run_command noaa-data-tree bash -lc 'find "$HOME/.local/share/noaa-navionics" -maxdepth 3 -mindepth 1 -ls 2>&1 || true'
run_command user-units systemctl --user --no-pager status noaa-navionics.timer noaa-navionics.service noaa-navionics-track.service noaa-navionics-preflight.service
run_command user-timers systemctl --user --no-pager list-timers noaa-navionics.timer
run_command user-unit-files systemctl --user --no-pager list-unit-files 'noaa-navionics*'
run_command system-services systemctl --no-pager status gpsd.socket gpsd.service chrony.service lightdm.service
run_command chrony-sources chronyc sources -v
run_command timedatectl timedatectl
run_command pi-throttling bash -lc 'if command -v vcgencmd >/dev/null 2>&1; then vcgencmd get_throttled && vcgencmd measure_temp; else echo "vcgencmd missing"; fi'
run_command recent-user-journal bash -lc 'journalctl --user --no-pager --since "-2 days" -u noaa-navionics.service -u noaa-navionics.timer -u noaa-navionics-track.service -u noaa-navionics-preflight.service 2>&1 || true'
run_command recent-system-journal bash -lc 'journalctl --no-pager --since "-2 days" -u gpsd.socket -u gpsd.service -u chrony.service -u lightdm.service 2>&1 || true'

printf 'NOAA Navionics Raspberry Pi support bundle\n' >"${bundle_root}/README.txt"
printf 'Collected: ' >>"${bundle_root}/README.txt"
date -u >>"${bundle_root}/README.txt"
printf 'Target user: %s\n' "$(id -un 2>/dev/null || printf unknown)" >>"${bundle_root}/README.txt"
printf 'This bundle is diagnostic evidence only. It includes configured chart manifests and storage listings. It does not include downloaded NOAA chart archives, extracted ENC cells, or GPX track contents by default.\n' >>"${bundle_root}/README.txt"

"$python3_cmd" - "$bundle_root" <<'PY'
from __future__ import annotations

from pathlib import Path
import os
import stat
import sys
import tarfile


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def first_symlink_ancestor(path: Path):
    current = path
    for candidate in [current, *current.parents]:
        if candidate.is_symlink():
            return candidate
    return None


def checked_directory(path: Path, label: str) -> os.stat_result:
    try:
        result = path.lstat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if stat.S_ISLNK(result.st_mode):
        fail(f"{label} is a symlink: {path}")
    if not stat.S_ISDIR(result.st_mode):
        fail(f"{label} is not a directory: {path}")
    if result.st_uid != os.getuid():
        fail(f"{label} is owned by uid {result.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode & 0o077:
        fail(f"{label} has permissions {mode:04o}, expected private 0700: {path}")
    return result


def iter_bundle_paths(root: Path):
    stack = [root]
    while stack:
        directory = stack.pop()
        checked_directory(directory, "support bundle directory")
        try:
            children = sorted(directory.iterdir(), key=lambda item: item.name)
        except OSError as exc:
            fail(f"could not list support bundle directory {directory}: {exc}")
        for child in children:
            try:
                child_stat = child.lstat()
            except OSError as exc:
                fail(f"could not inspect support bundle entry {child}: {exc}")
            if stat.S_ISLNK(child_stat.st_mode):
                fail(f"refusing to archive symlinked support bundle entry: {child}")
            if stat.S_ISDIR(child_stat.st_mode):
                stack.append(child)
            elif not stat.S_ISREG(child_stat.st_mode):
                fail(f"refusing to archive non-regular support bundle entry: {child}")
            yield child, child_stat


def archive_directory(archive: tarfile.TarFile, root: Path, path: Path, stat_result: os.stat_result) -> None:
    arcname = path.relative_to(root).as_posix()
    if not arcname:
        return
    info = tarfile.TarInfo(arcname + "/")
    info.type = tarfile.DIRTYPE
    info.mode = stat.S_IMODE(stat_result.st_mode) & 0o700
    info.mtime = int(stat_result.st_mtime)
    info.uid = stat_result.st_uid
    info.gid = stat_result.st_gid
    archive.addfile(info)


def archive_file(archive: tarfile.TarFile, root: Path, path: Path, stat_result: os.stat_result) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    current_stat = os.fstat(fd)
    if (current_stat.st_dev, current_stat.st_ino) != (stat_result.st_dev, stat_result.st_ino):
        os.close(fd)
        fail(f"support bundle file changed before archive: {path}")
    if not stat.S_ISREG(current_stat.st_mode):
        os.close(fd)
        fail(f"opened support bundle entry is not regular: {path}")
    if current_stat.st_uid != os.getuid():
        os.close(fd)
        fail(f"opened support bundle entry is owned by uid {current_stat.st_uid}, expected {os.getuid()}: {path}")
    arcname = path.relative_to(root).as_posix()
    info = tarfile.TarInfo(arcname)
    info.size = current_stat.st_size
    info.mode = stat.S_IMODE(current_stat.st_mode) & 0o777
    info.mtime = int(current_stat.st_mtime)
    info.uid = current_stat.st_uid
    info.gid = current_stat.st_gid
    with os.fdopen(fd, "rb") as handle:
        archive.addfile(info, handle)


bundle_root_path = Path(sys.argv[1]).expanduser()
if first_symlink_ancestor(bundle_root_path.parent) is not None:
    fail(f"support bundle parent path contains a symlink: {first_symlink_ancestor(bundle_root_path.parent)}")
checked_directory(bundle_root_path, "support bundle root")

with tarfile.open(fileobj=sys.stdout.buffer, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
    for path, path_stat in iter_bundle_paths(bundle_root_path):
        if stat.S_ISDIR(path_stat.st_mode):
            archive_directory(archive, bundle_root_path, path, path_stat)
        else:
            archive_file(archive, bundle_root_path, path, path_stat)
PY
REMOTE

if [[ ! -s "$partial_path" ]]; then
  echo "Collected bundle is empty" >&2
  exit 1
fi
mv -- "$partial_path" "$bundle_path"
finalize_private_archive "$bundle_path"
trap - EXIT

printf 'Collected Pi support bundle: %s\n' "$bundle_path"
