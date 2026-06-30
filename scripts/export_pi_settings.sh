#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/export_pi_settings.sh user@raspberrypi.local [output-dir]

Exports a compact commissioning-settings snapshot from the Raspberry Pi over
SSH. The archive contains trusted NOAA Navionics app config, launcher policy,
source revision, user service/autostart files, and readable GPSD/chrony/LightDM
settings. It does not include logs, GPX tracks, NOAA chart archives, or
extracted ENC cells.

The script writes a .tgz archive into output-dir, or ./pi-settings-exports
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
output_dir="${1:-pi-settings-exports}"
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
Do not export settings as root@.
Use the Pi desktop user so the snapshot matches the helm account.
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
  local mode

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
  if ! mode="$(stat -Lc '%a' -- "$path" 2>/dev/null)"; then
    echo "Could not inspect $label permissions: $path" >&2
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
archive_path="${output_dir}/noaa-navionics-pi-settings-${safe_target}-${timestamp}.tgz"
if [[ -e "$archive_path" ]]; then
  echo "Refusing to overwrite existing archive: $archive_path" >&2
  exit 2
fi
partial_path="$(mktemp "${output_dir}/.${timestamp}.settings-export.XXXXXX")"
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


def trusted_regular_file(path: Path, *, expected_uid):
    if path.is_symlink():
        fail(f"refusing to export symlinked setting: {path}")
    symlink = first_symlink_ancestor(path.parent)
    if symlink is not None:
        fail(f"setting path contains a symlink: {symlink}")
    try:
        result = path.lstat()
    except OSError:
        return None
    if not stat.S_ISREG(result.st_mode):
        fail(f"refusing to export non-regular setting: {path}")
    if expected_uid is not None and result.st_uid != expected_uid:
        fail(f"setting is owned by uid {result.st_uid}, expected {expected_uid}: {path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode & 0o022:
        fail(f"setting has permissions {mode:04o}, expected no group/other write bits: {path}")
    return result


def add_trusted_file(archive: tarfile.TarFile, path: Path, stat_result: os.stat_result, arcname: str) -> None:
    info = archive.gettarinfo(str(path), arcname=arcname)
    info.mode = stat.S_IMODE(stat_result.st_mode) & 0o755
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    current_stat = os.fstat(fd)
    if (current_stat.st_dev, current_stat.st_ino) != (stat_result.st_dev, stat_result.st_ino):
        os.close(fd)
        fail(f"setting changed before export: {path}")
    with os.fdopen(fd, "rb") as handle:
        archive.addfile(info, handle)


home = Path.home()
uid = os.getuid()
files: list[tuple[Path, os.stat_result, str]] = []
missing: list[str] = []
skipped: list[str] = []

candidates = [
    (home / ".config" / "noaa-navionics" / "config.ini", uid, "noaa-navionics/config.ini"),
    (home / ".config" / "noaa-navionics" / "launcher.env", uid, "noaa-navionics/launcher.env"),
    (home / ".local" / "share" / "noaa-navionics" / "source-revision", uid, "noaa-navionics/source-revision"),
    (home / ".config" / "autostart" / "noaa-navionics-chartplotter.desktop", uid, "desktop/noaa-navionics-chartplotter.desktop"),
    (Path("/etc/default/gpsd"), 0, "system/etc-default-gpsd"),
    (Path("/etc/chrony/conf.d/noaa-navionics-gpsd.conf"), 0, "system/noaa-navionics-gpsd.conf"),
    (Path("/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf"), 0, "system/50-noaa-navionics-autologin.conf"),
]
for unit_name in ("noaa-navionics.service", "noaa-navionics.timer", "noaa-navionics-track.service", "noaa-navionics-preflight.service"):
    candidates.append((home / ".config" / "systemd" / "user" / unit_name, uid, f"systemd/user/{unit_name}"))

for path, expected_uid, arcname in candidates:
    if not path.exists() and not path.is_symlink():
        missing.append(str(path))
        continue
    try:
        result = trusted_regular_file(path, expected_uid=expected_uid)
    except PermissionError:
        skipped.append(f"unreadable: {path}")
        continue
    if result is not None:
        if not os.access(path, os.R_OK):
            skipped.append(f"unreadable: {path}")
            continue
        files.append((path, result, arcname))

if not files:
    fail("no trusted commissioning settings were found to export")

manifest = {
    "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "user": os.environ.get("USER", ""),
    "home": str(home),
    "file_count": len(files),
    "files": [
        {
            "archive_path": arcname,
            "source_path": str(path),
            "owner_uid": stat_result.st_uid,
            "mode": f"{stat.S_IMODE(stat_result.st_mode):04o}",
            "size": stat_result.st_size,
            "mtime": datetime.fromtimestamp(stat_result.st_mtime, timezone.utc).isoformat().replace("+00:00", "Z"),
        }
        for path, stat_result, arcname in files
    ],
    "missing": missing,
    "skipped": skipped,
}
readme = (
    "NOAA Navionics Raspberry Pi commissioning settings export\n"
    f"Generated: {manifest['generated_at']}\n"
    f"Files: {len(files)}\n"
    "This archive contains settings only. It does not include logs, GPX tracks, NOAA chart archives, or extracted ENC cells.\n"
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
  echo "Settings export archive is empty" >&2
  exit 1
fi
mv -- "$partial_path" "$archive_path"
finalize_private_archive "$archive_path"
trap - EXIT
printf 'Exported Pi commissioning settings: %s\n' "$archive_path"
