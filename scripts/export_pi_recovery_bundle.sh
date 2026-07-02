#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/export_pi_recovery_bundle.sh user@raspberrypi.local [output-dir] [options]

Runs the read-only Pi recovery exports into one timestamped local directory:
commissioning settings, OpenCPN user data, GPX tracks, and a diagnostic
support bundle.

Options:
  --track-days N     Export GPX tracks modified in the last N days; 0 exports all
                     (max: 3650)

Only output-dir is changed locally. Nothing is installed, enabled, rebooted,
shut down, or downloaded, and no persistent Pi state is changed. NOAA chart
archives and extracted ENC cells are not copied by these helpers.
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
output_dir="pi-recovery-exports"
track_days=0
max_track_days=3650
python3_cmd=""
if [[ $# -gt 0 && "$1" != --* ]]; then
  output_dir="$1"
  shift
fi

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
Do not export recovery bundles as root@.
Use the Pi desktop user so settings, OpenCPN data, tracks, and diagnostics match the helm account.
EOF
    exit 2
  fi
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

write_checksum_manifest() {
  local directory="$1"
  "$python3_cmd" - "$directory" <<'PY'
from __future__ import annotations

from pathlib import Path
import hashlib
import os
import stat
import tempfile
import sys


ARCHIVE_PATTERNS = [
    "noaa-navionics-pi-settings-*.tgz",
    "noaa-navionics-pi-opencpn-*.tgz",
    "noaa-navionics-pi-tracks-*.tgz",
    "noaa-navionics-pi-support-*.tgz",
]
MANIFEST_NAME = "SHA256SUMS.txt"


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def assert_private_directory(path: Path) -> None:
    try:
        result = path.lstat()
    except OSError as exc:
        fail(f"Could not inspect recovery directory before checksum manifest: {path}: {exc}")
    if not stat.S_ISDIR(result.st_mode):
        fail(f"Recovery checksum directory is not a real directory: {path}")
    if result.st_uid != os.getuid():
        fail(f"Recovery checksum directory is owned by uid {result.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode != 0o700:
        fail(f"Recovery checksum directory has permissions {mode:04o}, expected private 0700: {path}")


def hash_private_file(path: Path) -> str:
    if path.is_symlink():
        fail(f"Recovery archive must not be a symlink before checksum manifest: {path}")
    try:
        before = path.lstat()
    except OSError as exc:
        fail(f"Could not inspect recovery archive before checksum manifest: {path}: {exc}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"Recovery archive must be regular before checksum manifest: {path}")
    if before.st_uid != os.getuid():
        fail(f"Recovery archive is owned by uid {before.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o600:
        fail(f"Recovery archive has permissions {mode:04o}, expected private 0600: {path}")
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        fail(f"Could not open recovery archive through no-follow descriptor for checksum: {path}: {exc}")
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            fail(f"Recovery archive changed before checksum manifest: {path}")
        digest = hashlib.sha256()
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    finally:
        if fd >= 0:
            os.close(fd)


def cleanup_private_temp(path: Path, expected: os.stat_result | None) -> None:
    if expected is None:
        print(f"recovery checksum temp was not inspected before cleanup; leaving it in place: {path}", file=sys.stderr)
        return
    try:
        current = path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        print(f"could not inspect recovery checksum temp before cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
        return
    if not os.path.samestat(expected, current):
        print(f"recovery checksum temp changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        return
    if not stat.S_ISREG(current.st_mode):
        print(f"recovery checksum temp is not regular before cleanup; leaving it in place: {path}", file=sys.stderr)
        return
    try:
        path.unlink()
    except OSError as exc:
        print(f"could not remove recovery checksum temp after validation: {path}: {exc}", file=sys.stderr)


directory = Path(sys.argv[1])
assert_private_directory(directory)
archive_paths = []
for pattern in ARCHIVE_PATTERNS:
    matches = sorted(directory.glob(pattern))
    if len(matches) != 1:
        fail(f"Expected exactly one archive matching {pattern} before checksum manifest, found {len(matches)}")
    archive_paths.append(matches[0])

manifest_path = directory / MANIFEST_NAME
if manifest_path.exists() or manifest_path.is_symlink():
    fail(f"Refusing to overwrite existing recovery checksum manifest: {manifest_path}")

lines = []
for archive_path in archive_paths:
    lines.append(f"{hash_private_file(archive_path)}  {archive_path.name}\n")
payload = "".join(lines).encode("ascii")
temp_fd = -1
temp_path = None
temp_stat = None
try:
    temp_fd, temp_name = tempfile.mkstemp(
        prefix=f".{MANIFEST_NAME}.",
        suffix=".tmp",
        dir=directory,
    )
    temp_path = Path(temp_name)
    os.fchmod(temp_fd, 0o600)
    temp_stat = os.fstat(temp_fd)
    os.write(temp_fd, payload)
    os.fsync(temp_fd)
    os.close(temp_fd)
    temp_fd = -1
    os.replace(temp_path, manifest_path)
    temp_path = None
    dir_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
except OSError as exc:
    fail(f"Could not write recovery checksum manifest: {exc}")
finally:
    if temp_fd >= 0:
        os.close(temp_fd)
    if temp_path is not None:
        cleanup_private_temp(temp_path, temp_stat)

try:
    final = manifest_path.lstat()
except OSError as exc:
    fail(f"Could not inspect recovery checksum manifest after writing: {manifest_path}: {exc}")
if not stat.S_ISREG(final.st_mode):
    fail(f"Recovery checksum manifest is not a regular file after writing: {manifest_path}")
if final.st_uid != os.getuid():
    fail(f"Recovery checksum manifest is owned by uid {final.st_uid}, expected {os.getuid()}: {manifest_path}")
mode = stat.S_IMODE(final.st_mode)
if mode != 0o600:
    fail(f"Recovery checksum manifest has permissions {mode:04o}, expected private 0600: {manifest_path}")
print(f"Wrote recovery checksum manifest: {manifest_path}")
PY
}

validate_ssh_target "$target"
validate_output_dir_arg "$output_dir"
output_dir="$(strip_trailing_slashes "$output_dir")"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
settings_helper="${repo_root}/scripts/export_pi_settings.sh"
opencpn_helper="${repo_root}/scripts/export_pi_opencpn_data.sh"
tracks_helper="${repo_root}/scripts/export_pi_tracks.sh"
support_helper="${repo_root}/scripts/collect_pi_support_bundle.sh"
verify_helper="${repo_root}/scripts/verify_pi_recovery_exports.sh"
python3_cmd="$(require_local_command python3)"
require_helper "$settings_helper"
require_helper "$opencpn_helper"
require_helper "$tracks_helper"
require_helper "$support_helper"
require_helper "$verify_helper"

prepare_private_output_dir "Output directory" "$output_dir"

timestamp="$(utc_timestamp)"
safe_target="$(printf '%s' "$target" | tr '@.' '___')"
recovery_dir="${output_dir}/noaa-navionics-pi-recovery-${safe_target}-${timestamp}"
if [[ -e "$recovery_dir" ]]; then
  echo "Refusing to overwrite existing recovery directory: $recovery_dir" >&2
  exit 2
fi
prepare_private_output_dir "Recovery output directory" "$recovery_dir"

run_step "Exporting commissioning settings" "$settings_helper" "$target" "$recovery_dir"
run_step "Exporting OpenCPN user data" "$opencpn_helper" "$target" "$recovery_dir"
run_step "Exporting GPX tracks" "$tracks_helper" "$target" "$recovery_dir" --days "$track_days"
run_step "Collecting diagnostic support bundle" "$support_helper" "$target" "$recovery_dir"
write_checksum_manifest "$recovery_dir"
run_step "Verifying recovery export archives" "$verify_helper" "$recovery_dir"

printf '\nPi recovery exports written to: %s\n' "$recovery_dir"
