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
Nothing is installed, enabled, rebooted, shut down, downloaded, or changed
on the local computer.
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
  if [[ -L "$value" ]]; then
    echo "Output directory must not be a symlink: $value" >&2
    exit 2
  fi
}

validate_ssh_target "$target"
validate_output_dir_arg "$output_dir"
ssh_cmd="$(require_local_command ssh)"

mkdir -p -- "$output_dir"
if [[ ! -d "$output_dir" || -L "$output_dir" ]]; then
  echo "Output path must be a real directory: $output_dir" >&2
  exit 2
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_target="$(printf '%s' "$target" | tr '@.' '___')"
archive_path="${output_dir}/noaa-navionics-pi-opencpn-${safe_target}-${timestamp}.tgz"
if [[ -e "$archive_path" ]]; then
  echo "Refusing to overwrite existing archive: $archive_path" >&2
  exit 2
fi
partial_path="$(mktemp "${output_dir}/.${timestamp}.opencpn-export.XXXXXX")"
cleanup_partial() {
  rm -f -- "$partial_path"
}
trap cleanup_partial EXIT

"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && python3 -s" >"$partial_path" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import io
import json
import os
import stat
import sys
import tarfile
import time


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
    return result


def add_trusted_file(archive: tarfile.TarFile, path: Path, stat_result: os.stat_result, arcname: str) -> None:
    info = archive.gettarinfo(str(path), arcname=arcname)
    info.mode = stat.S_IMODE(stat_result.st_mode) & 0o755
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    current_stat = os.fstat(fd)
    if (current_stat.st_dev, current_stat.st_ino) != (stat_result.st_dev, stat_result.st_ino):
        os.close(fd)
        fail(f"OpenCPN file changed before export: {path}")
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
mv -- "$partial_path" "$archive_path"
trap - EXIT
printf 'Exported Pi OpenCPN user data: %s\n' "$archive_path"
