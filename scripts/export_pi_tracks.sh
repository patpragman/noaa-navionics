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

Nothing is installed, enabled, rebooted, shut down, downloaded, or changed
on the local computer. NOAA chart archives and extracted ENC cells are not
copied.
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
if [[ $# -gt 0 && "$1" != --* ]]; then
  output_dir="$1"
  shift
fi

ssh_cmd=""
ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

require_non_negative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a non-negative integer" >&2
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
      days="${2:-}"
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

prepare_private_output_dir() {
  local label="$1"
  local path="$2"
  local current_uid
  local mode
  local owner_uid
  local stat_output

  current_uid="$(id -u)"
  mkdir -p -- "$path"
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
ssh_cmd="$(require_local_command ssh)"

prepare_private_output_dir "Output directory" "$output_dir"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_target="$(printf '%s' "$target" | tr '@.' '___')"
archive_path="${output_dir}/noaa-navionics-pi-tracks-${safe_target}-${timestamp}.tgz"
if [[ -e "$archive_path" ]]; then
  echo "Refusing to overwrite existing archive: $archive_path" >&2
  exit 2
fi
partial_path="$(mktemp "${output_dir}/.${timestamp}.track-export.XXXXXX")"
cleanup_partial() {
  rm -f -- "$partial_path"
}
trap cleanup_partial EXIT

"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && NOAA_NAVIONICS_EXPORT_DAYS=${days} python3 -s" >"$partial_path" <<'PY'
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
        info = archive.gettarinfo(str(path), arcname=f"tracks/{path.name}")
        info.mode = 0o600
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        current_stat = os.fstat(fd)
        if (current_stat.st_dev, current_stat.st_ino) != (track_stat.st_dev, track_stat.st_ino):
            os.close(fd)
            fail(f"GPX track changed before export: {path}")
        with os.fdopen(fd, "rb") as handle:
            archive.addfile(info, handle)
PY

if [[ ! -s "$partial_path" ]]; then
  echo "Track export archive is empty" >&2
  exit 1
fi
mv -- "$partial_path" "$archive_path"
finalize_private_archive "$archive_path"
trap - EXIT
printf 'Exported Pi GPX tracks: %s\n' "$archive_path"
