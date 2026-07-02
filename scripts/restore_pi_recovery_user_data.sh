#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/restore_pi_recovery_user_data.sh RECOVERY_DIR [options]

Restores user-owned navigation data from a local recovery export directory
that has been copied onto the Raspberry Pi. By default this is a dry run.

Options:
  --apply       Write files instead of printing the restore plan
  --overwrite   Replace existing regular files after backing them up

Restores:
  - NOAA Navionics config.ini and launcher.env
  - Status GUI and MOB desktop launchers
  - OpenCPN user config, routes, waypoints, and layers
  - GPX track logs into the restored configured tracking directory

Does not restore root-owned GPSD, chrony, LightDM, service unit, chart, or
NOAA ENC files. Re-run provisioning and verification after restore.
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

recovery_dir="$1"
shift
apply=0
overwrite=0
python3_cmd=""

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      apply=1
      shift
      ;;
    --overwrite)
      overwrite=1
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

if [[ -z "$recovery_dir" ]]; then
  echo "Recovery directory is required" >&2
  exit 2
fi
if [[ "$recovery_dir" =~ [\"\'] ]]; then
  echo "Recovery directory must not contain quotes: $recovery_dir" >&2
  exit 2
fi
if [[ "$recovery_dir" =~ [[:cntrl:]] ]]; then
  echo "Recovery directory must not contain control characters" >&2
  exit 2
fi
case "$recovery_dir" in
  */../*|*/..|../*|..)
    echo "Recovery directory must not contain parent-directory components: $recovery_dir" >&2
    exit 2
    ;;
esac
if [[ -L "$recovery_dir" ]]; then
  echo "Recovery directory must not be a symlink: $recovery_dir" >&2
  exit 2
fi
reject_symlinked_path_components "Recovery directory" "$recovery_dir"
if [[ ! -d "$recovery_dir" ]]; then
  echo "Recovery directory must be a real directory: $recovery_dir" >&2
  exit 2
fi
python3_cmd="$(require_local_command python3)"

NOAA_NAVIONICS_RESTORE_APPLY="$apply" \
NOAA_NAVIONICS_RESTORE_OVERWRITE="$overwrite" \
"$python3_cmd" - "$recovery_dir" <<'PY'
from configparser import ConfigParser, Error as ConfigParserError
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Optional
import hashlib
import io
import json
import os
import re
import stat
import sys
import tarfile
import tempfile


CHECKSUM_MANIFEST_NAME = "SHA256SUMS.txt"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GPS_BAUD_RATES = {4800, 9600, 19200, 38400, 57600, 115200}
GPSD_LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}
GPS_UDEV_SAFE_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:+@-")
STABLE_GPS_DEVICE_PATHS = {"/dev/serial0", "/dev/serial1", "/dev/gps"}
CORE_SUPPORT_COMMAND_FILES = [
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
    "commands/recent-system-journal.txt",
]
NOAA_SUPPORT_COMMAND_FILES = [
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
NOAA_SUPPORT_FILE_PATTERNS = [
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
CORE_RESTORE_SETTINGS_FILES = [
    "noaa-navionics/config.ini",
    "noaa-navionics/launcher.env",
    "desktop/noaa-navionics-status.desktop",
    "desktop/noaa-navionics-mob.desktop",
]
MAX_SETTING_ARCHIVE_MEMBER_BYTES = 4 * 1024 * 1024
MAX_OPENCPN_ARCHIVE_MEMBER_BYTES = 50 * 1024 * 1024
MAX_TRACK_ARCHIVE_MEMBER_BYTES = 100 * 1024 * 1024
MAX_SUPPORT_ARCHIVE_MEMBER_BYTES = 10 * 1024 * 1024
ARCHIVES = [
    ("settings", "noaa-navionics-pi-settings-*.tgz", "file_count", CORE_RESTORE_SETTINGS_FILES, MAX_SETTING_ARCHIVE_MEMBER_BYTES),
    ("opencpn", "noaa-navionics-pi-opencpn-*.tgz", "file_count", [], MAX_OPENCPN_ARCHIVE_MEMBER_BYTES),
    ("tracks", "noaa-navionics-pi-tracks-*.tgz", "track_count", [], MAX_TRACK_ARCHIVE_MEMBER_BYTES),
    (
        "support",
        "noaa-navionics-pi-support-*.tgz",
        None,
        [*CORE_SUPPORT_COMMAND_FILES, *NOAA_SUPPORT_COMMAND_FILES],
        MAX_SUPPORT_ARCHIVE_MEMBER_BYTES,
    ),
]


def fail(message: str, exit_code: int = 1) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(exit_code)


def normalized_member_name(name: str) -> str:
    while name.startswith("./"):
        name = name[2:]
    return name.rstrip("/")


def validate_member_name(name: str, archive_path: Path) -> str:
    normalized = normalized_member_name(name)
    parts = normalized.split("/") if normalized else []
    if not parts or any(part in {"", ".", ".."} for part in parts):
        fail(f"{archive_path.name} contains unsafe member path: {name}")
    if "\\" in normalized:
        fail(f"{archive_path.name} contains unsafe backslash member: {name}")
    path = PurePosixPath(normalized)
    if path.is_absolute() or ".." in path.parts:
        fail(f"{archive_path.name} contains unsafe member path: {name}")
    return normalized


def inspect_private_file(path: Path, label: str) -> os.stat_result:
    if path.is_symlink():
        fail(f"{label} must not be a symlink: {path}")
    try:
        result = path.lstat()
    except OSError as exc:
        fail(f"could not inspect {label} {path}: {exc}")
    if not stat.S_ISREG(result.st_mode):
        fail(f"{label} must be a regular file: {path}")
    if result.st_uid != os.getuid():
        fail(f"{label} is owned by uid {result.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode != 0o600:
        fail(f"{label} has permissions {mode:04o}, expected private 0600: {path}")
    return result


def inspect_archive(
    archive_path: Path,
    required_count_key: Optional[str],
    required_members: list[str],
    max_member_bytes: int,
    *,
    load_contents: bool = True,
) -> dict[str, bytes]:
    result = inspect_private_file(archive_path, "archive")
    if result.st_size <= 0:
        fail(f"archive is empty: {archive_path}")

    files: dict[str, bytes] = {}
    names: set[str] = set()
    members_by_name = {}
    regular_file_count = 0
    data_file_count = 0
    data_member_names = []
    fd = -1
    try:
        fd = os.open(archive_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            fail(f"archive must be a regular file after opening: {archive_path}")
        if (opened.st_dev, opened.st_ino) != (result.st_dev, result.st_ino):
            fail(f"archive changed while being opened: {archive_path}")
        if opened.st_uid != os.getuid():
            fail(f"archive is owned by uid {opened.st_uid}, expected {os.getuid()}: {archive_path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != 0o600:
            fail(f"archive has permissions {opened_mode:04o}, expected private 0600: {archive_path}")
        with os.fdopen(fd, "rb") as archive_file:
            fd = -1
            with tarfile.open(fileobj=archive_file, mode="r:gz") as archive:
                for member in archive.getmembers():
                    normalized = validate_member_name(member.name, archive_path)
                    if normalized in names:
                        fail(f"{archive_path.name} contains duplicate member: {normalized}")
                    names.add(normalized)
                    members_by_name[normalized] = member
                    if member.issym() or member.islnk() or member.isdev():
                        fail(f"{archive_path.name} contains unsupported non-regular member: {member.name}")
                    if member.isdir():
                        continue
                    if not member.isfile():
                        fail(f"{archive_path.name} contains unsupported member type: {member.name}")
                    if not normalized:
                        fail(f"{archive_path.name} contains blank file member name")
                    if member.size < 0:
                        fail(f"{archive_path.name} contains negative-size member: {member.name}")
                    if member.size > max_member_bytes:
                        fail(
                            f"{archive_path.name} member is too large to restore safely: "
                            f"{member.name} ({member.size} bytes > {max_member_bytes})"
                        )
                    regular_file_count += 1
                    if normalized not in {"README.txt", "manifest.json"}:
                        if required_count_key == "track_count":
                            if not normalized.startswith("tracks/") or not normalized.endswith(".gpx"):
                                fail(f"{archive_path.name} contains non-GPX track data member: {member.name}")
                            track_name = normalized.removeprefix("tracks/")
                            if not track_name or "/" in track_name:
                                fail(f"{archive_path.name} contains nested or empty track data member: {member.name}")
                            data_member_names.append(track_name)
                        else:
                            data_member_names.append(normalized)
                        data_file_count += 1
                    if not load_contents:
                        continue
                    extracted = archive.extractfile(member)
                    if extracted is None:
                        fail(f"{archive_path.name} member is not readable: {member.name}")
                    files[normalized] = extracted.read()
    except (OSError, tarfile.TarError) as exc:
        fail(f"{archive_path.name} is not a readable trusted gzip tar archive: {exc}")
    finally:
        if fd >= 0:
            os.close(fd)

    readme = members_by_name.get("README.txt")
    if readme is None:
        fail(f"{archive_path.name} is missing README.txt")
    if not readme.isfile():
        fail(f"{archive_path.name} README.txt is not a regular file")
    missing_members = [
        name for name in required_members
        if name not in members_by_name or not members_by_name[name].isfile()
    ]
    if missing_members:
        fail(
            f"{archive_path.name} is missing required archive member(s): "
            f"{', '.join(missing_members)}"
        )
    if archive_path.name.startswith("noaa-navionics-pi-support-"):
        missing_pattern_labels = [
            pattern_label
            for pattern_label, pattern in NOAA_SUPPORT_FILE_PATTERNS
            if not any(member.isfile() and pattern.fullmatch(name) for name, member in members_by_name.items())
        ]
        if missing_pattern_labels:
            fail(
                f"{archive_path.name} is missing required diagnostic evidence file(s): "
                f"{', '.join(missing_pattern_labels)}"
            )
    if required_count_key is not None:
        manifest_member = members_by_name.get("manifest.json")
        if manifest_member is None:
            fail(f"{archive_path.name} is missing manifest.json")
        if not manifest_member.isfile():
            fail(f"{archive_path.name} manifest.json is not a regular file")
        if "manifest.json" not in files:
            fail(f"{archive_path.name} manifest.json was not loaded")
        try:
            manifest = json.loads(files["manifest.json"].decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            fail(f"{archive_path.name} manifest.json is invalid JSON: {exc}")
        count = manifest.get(required_count_key)
        if not isinstance(count, int) or count <= 0:
            fail(f"{archive_path.name} manifest {required_count_key} must be a positive integer")
        if count != data_file_count:
            fail(
                f"{archive_path.name} manifest {required_count_key} does not match data file count: "
                f"{count} != {data_file_count}"
            )
        if required_count_key == "file_count":
            files_manifest = manifest.get("files")
            if not isinstance(files_manifest, list):
                fail(f"{archive_path.name} manifest files must be a list")
            manifest_file_names = []
            for index, file_entry in enumerate(files_manifest):
                if not isinstance(file_entry, dict):
                    fail(f"{archive_path.name} manifest files[{index}] must be an object")
                archive_path_value = file_entry.get("archive_path")
                if not isinstance(archive_path_value, str):
                    fail(
                        f"{archive_path.name} manifest files[{index}].archive_path is invalid: "
                        f"{archive_path_value!r}"
                    )
                manifest_file_names.append(validate_member_name(archive_path_value, archive_path))
            if sorted(manifest_file_names) != sorted(data_member_names):
                fail(
                    f"{archive_path.name} manifest file names do not match data files: "
                    f"{sorted(manifest_file_names)!r} != {sorted(data_member_names)!r}"
                )
        elif required_count_key == "track_count":
            tracks = manifest.get("tracks")
            if not isinstance(tracks, list):
                fail(f"{archive_path.name} manifest tracks must be a list")
            manifest_track_names = []
            for index, track in enumerate(tracks):
                if not isinstance(track, dict):
                    fail(f"{archive_path.name} manifest tracks[{index}] must be an object")
                name = track.get("name")
                if not isinstance(name, str) or not name or "/" in name or "\\" in name or name in {".", ".."}:
                    fail(f"{archive_path.name} manifest tracks[{index}].name is invalid: {name!r}")
                manifest_track_names.append(name)
            if sorted(manifest_track_names) != sorted(data_member_names):
                fail(
                    f"{archive_path.name} manifest track names do not match data files: "
                    f"{sorted(manifest_track_names)!r} != {sorted(data_member_names)!r}"
                )
    if regular_file_count <= 0:
        fail(f"{archive_path.name} does not contain any regular files")
    return files


def hash_private_archive(archive_path: Path) -> str:
    result = inspect_private_file(archive_path, "archive")
    fd = -1
    try:
        fd = os.open(archive_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(fd)
        if not os.path.samestat(result, opened):
            fail(f"archive changed before checksum verification: {archive_path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"archive must be regular when opened for checksum verification: {archive_path}")
        if opened.st_uid != os.getuid():
            fail(f"archive is owned by uid {opened.st_uid}, expected {os.getuid()} during checksum verification: {archive_path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != 0o600:
            fail(f"archive has permissions {opened_mode:04o}, expected private 0600 during checksum verification: {archive_path}")
        digest = hashlib.sha256()
        with os.fdopen(fd, "rb") as archive_file:
            fd = -1
            for chunk in iter(lambda: archive_file.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError as exc:
        fail(f"could not read archive for checksum verification {archive_path}: {exc}")
    finally:
        if fd >= 0:
            os.close(fd)


def read_checksum_manifest(recovery_dir: Path) -> dict[str, str]:
    manifest_path = recovery_dir / CHECKSUM_MANIFEST_NAME
    result = inspect_private_file(manifest_path, "checksum manifest")
    fd = -1
    try:
        fd = os.open(manifest_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(fd)
        if not os.path.samestat(result, opened):
            fail(f"checksum manifest changed while being opened: {manifest_path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"checksum manifest must be regular when opened: {manifest_path}")
        if opened.st_uid != os.getuid():
            fail(f"checksum manifest is owned by uid {opened.st_uid}, expected {os.getuid()} when opened: {manifest_path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != 0o600:
            fail(f"checksum manifest has permissions {opened_mode:04o}, expected private 0600 when opened: {manifest_path}")
        with os.fdopen(fd, "rb") as manifest_file:
            fd = -1
            try:
                text = manifest_file.read().decode("ascii")
            except UnicodeDecodeError as exc:
                fail(f"checksum manifest is not ASCII: {exc}")
    except OSError as exc:
        fail(f"could not read checksum manifest {manifest_path}: {exc}")
    finally:
        if fd >= 0:
            os.close(fd)

    entries: dict[str, str] = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip():
            continue
        if "  " not in raw_line:
            fail(f"checksum manifest line {line_number} must use two-space sha256 filename format")
        digest, name = raw_line.split("  ", 1)
        if not SHA256_RE.fullmatch(digest):
            fail(f"checksum manifest line {line_number} has invalid SHA-256 digest")
        normalized = validate_member_name(name, manifest_path)
        if "/" in normalized:
            fail(f"checksum manifest line {line_number} must name an archive in the recovery directory: {name}")
        if normalized != name:
            fail(f"checksum manifest line {line_number} uses a non-normal archive name: {name}")
        if normalized in entries:
            fail(f"checksum manifest contains duplicate archive name: {normalized}")
        entries[normalized] = digest
    if not entries:
        fail("checksum manifest is empty")
    return entries


def verify_checksum_manifest(recovery_dir: Path, archive_paths: dict[str, Path]) -> None:
    entries = read_checksum_manifest(recovery_dir)
    expected_names = {path.name for path in archive_paths.values()}
    actual_names = set(entries)
    missing = sorted(expected_names - actual_names)
    extra = sorted(actual_names - expected_names)
    if missing:
        fail(f"checksum manifest is missing archive(s): {', '.join(missing)}")
    if extra:
        fail(f"checksum manifest lists unexpected archive(s): {', '.join(extra)}")
    for archive_path in archive_paths.values():
        actual_digest = hash_private_archive(archive_path)
        expected_digest = entries[archive_path.name]
        if actual_digest != expected_digest:
            fail(f"checksum mismatch for {archive_path.name}: expected {expected_digest}, got {actual_digest}")


def assert_private_recovery_directory(path: Path) -> None:
    if path.is_symlink():
        fail(f"recovery directory is a symlink: {path}")
    symlink = first_symlink_ancestor(path.parent)
    if symlink is not None:
        fail(f"recovery directory parent path contains a symlink: {symlink}")
    try:
        result = path.lstat()
    except OSError as exc:
        fail(f"could not inspect recovery directory {path}: {exc}")
    if not stat.S_ISDIR(result.st_mode):
        fail(f"recovery directory must be a real directory: {path}")
    if result.st_uid != os.getuid():
        fail(f"recovery directory is owned by uid {result.st_uid}, expected {os.getuid()}: {path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode != 0o700:
        fail(f"recovery directory has permissions {mode:04o}, expected private 0700: {path}")


def find_archives(recovery_dir: Path) -> dict[str, dict[str, bytes]]:
    assert_private_recovery_directory(recovery_dir)
    archive_paths = {}
    for label, pattern, _required_count_key, _required_members, _max_member_bytes in ARCHIVES:
        matches = sorted(recovery_dir.glob(pattern))
        if not matches:
            fail(f"missing {label} archive matching {pattern}")
        if len(matches) > 1:
            fail(f"expected one {label} archive, found {len(matches)}")
        archive_paths[label] = matches[0]
    verify_checksum_manifest(recovery_dir, archive_paths)

    result = {}
    for label, pattern, required_count_key, required_members, max_member_bytes in ARCHIVES:
        result[label] = inspect_archive(
            archive_paths[label],
            required_count_key,
            required_members,
            max_member_bytes,
            load_contents=(label != "support"),
        )
    return result


def first_symlink_ancestor(path: Path) -> Optional[Path]:
    current = path.expanduser()
    for candidate in [current, *current.parents]:
        try:
            if candidate.is_symlink():
                return candidate
        except OSError:
            continue
    return None


def reject_unsafe_target(path: Path, label: str) -> None:
    if path.is_symlink():
        fail(f"{label} target is a symlink: {path}")
    symlink = first_symlink_ancestor(path.parent)
    if symlink is not None:
        fail(f"{label} target parent path contains a symlink: {symlink}")
    if path.exists() and not path.is_file():
        fail(f"{label} target exists and is not a regular file: {path}")


def restore_target_stat_matches(current: os.stat_result, expected: os.stat_result) -> bool:
    return (
        os.path.samestat(current, expected)
        and current.st_size == expected.st_size
        and current.st_mtime_ns == expected.st_mtime_ns
        and current.st_ctime_ns == expected.st_ctime_ns
    )


def inspect_existing_restore_target(path: Path, label: str) -> Optional[os.stat_result]:
    reject_unsafe_target(path, label)
    try:
        result = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError as exc:
        fail(f"could not inspect {label} {path}: {exc}")
    if not stat.S_ISREG(result.st_mode):
        fail(f"{label} is not a regular file: {path}")
    if result.st_uid != os.getuid():
        fail(f"{label} {path} is owned by uid {result.st_uid}, expected {os.getuid()}")
    mode = stat.S_IMODE(result.st_mode)
    if mode & 0o022:
        fail(f"{label} {path} has permissions {mode:04o}, expected no group/other write bits")
    return result


def validate_restore_target_state_before_promotion(path: Path, expected_stat: Optional[os.stat_result]) -> None:
    current = inspect_existing_restore_target(path, "restore target")
    if expected_stat is None:
        if current is not None:
            fail(f"restore target appeared before promotion; refusing to overwrite it: {path}")
        return
    if current is None:
        fail(f"restore target disappeared after backup; refusing to promote restored file: {path}")
    if not restore_target_stat_matches(current, expected_stat):
        fail(f"restore target changed after backup; refusing to overwrite it: {path}")


def ensure_private_directory(path: Path, apply: bool) -> None:
    symlink = first_symlink_ancestor(path)
    if symlink is not None:
        fail(f"restore directory path contains a symlink: {symlink}")
    if not apply:
        return
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
    directory_fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(directory_fd)
        if not stat.S_ISDIR(opened.st_mode):
            fail(f"restore path is not a directory after creation: {path}")
        if opened.st_uid != os.getuid():
            fail(f"restore directory {path} is owned by uid {opened.st_uid}, expected {os.getuid()}")
        mode = stat.S_IMODE(opened.st_mode)
        if mode & 0o077:
            fail(f"restore directory {path} has permissions {mode:04o}, expected private 0700")
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    fsync_parent(path)


def ensure_private_directory_tree(path: Path, root: Path, apply: bool) -> None:
    root = root.resolve()
    target = path.resolve() if path.exists() else path
    try:
        target.relative_to(root)
    except ValueError:
        fail(f"restore backup directory escapes backup root: {path}")
    relative_parts = path.relative_to(root).parts
    current = root
    ensure_private_directory(current, apply)
    for part in relative_parts:
        current = current / part
        ensure_private_directory(current, apply)


def fsync_parent(path: Path) -> None:
    try:
        fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read_trusted_restore_file(path: Path, label: str, expected_stat: os.stat_result, max_bytes: int) -> bytes:
    inspected_stat = inspect_existing_restore_target(path, label)
    if inspected_stat is None:
        fail(f"{label} is missing before backup: {path}")
    if not restore_target_stat_matches(inspected_stat, expected_stat):
        fail(f"{label} changed before backup read: {path}")
    if inspected_stat.st_size > max_bytes:
        fail(f"{label} is too large to back up safely: {path} ({inspected_stat.st_size} bytes > {max_bytes})")

    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        fail(f"could not open {label} {path}: {exc}")
    try:
        opened = os.fstat(fd)
        if not restore_target_stat_matches(opened, expected_stat):
            fail(f"{label} changed while opening: {path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"{label} is not a regular file when opened: {path}")
        if opened.st_uid != os.getuid():
            fail(f"{label} {path} is owned by uid {opened.st_uid}, expected {os.getuid()}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode & 0o022:
            fail(f"{label} {path} has permissions {opened_mode:04o}, expected no group/other write bits")
        if opened.st_size > max_bytes:
            fail(f"opened {label} is too large to back up safely: {path} ({opened.st_size} bytes > {max_bytes})")
        chunks = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def validate_private_file_content(path: Path, expected_data: bytes, label: str, expected_mode: int = 0o600) -> None:
    reject_unsafe_target(path, label)
    try:
        expected_stat = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        fail(f"could not inspect {label} {path}: {exc}")
    if not stat.S_ISREG(expected_stat.st_mode):
        fail(f"{label} is not regular: {path}")
    if expected_stat.st_uid != os.getuid():
        fail(f"{label} {path} is owned by uid {expected_stat.st_uid}, expected {os.getuid()}")
    mode = stat.S_IMODE(expected_stat.st_mode)
    if mode != expected_mode:
        fail(f"{label} {path} has permissions {mode:04o}, expected {expected_mode:04o}")

    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        fail(f"could not open {label} {path}: {exc}")
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (expected_stat.st_dev, expected_stat.st_ino):
            fail(f"{label} changed while validating: {path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"{label} is not regular when opened: {path}")
        if opened.st_uid != os.getuid():
            fail(f"{label} {path} is owned by uid {opened.st_uid}, expected {os.getuid()}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != expected_mode:
            fail(f"{label} {path} has permissions {opened_mode:04o}, expected {expected_mode:04o}")
        chunks = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        current_data = b"".join(chunks)
        if current_data != expected_data:
            fail(f"{label} {path} does not match expected data")
    finally:
        os.close(fd)


def backup_existing(path: Path, backup_root: Path, expected_stat: Optional[os.stat_result], max_existing_bytes: int) -> None:
    if expected_stat is None:
        return
    source_data = read_trusted_restore_file(path, "backup source", expected_stat, max_existing_bytes)
    backup_path = backup_root / path.resolve().relative_to("/")
    ensure_private_directory_tree(backup_path.parent, backup_root, apply=True)
    try:
        backup_fd = os.open(backup_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except FileExistsError:
        fail(f"restore backup already exists: {backup_path}")
    except OSError as exc:
        fail(f"could not create restore backup {backup_path}: {exc}")
    try:
        offset = 0
        while offset < len(source_data):
            offset += os.write(backup_fd, source_data[offset:])
        os.fchmod(backup_fd, 0o600)
        os.fsync(backup_fd)
    finally:
        os.close(backup_fd)
    validate_private_file_content(backup_path, source_data, "promoted restore backup")
    fsync_parent(backup_path)


def validate_promoted_restore_file(path: Path, expected_data: bytes, expected_mode: int) -> None:
    validate_private_file_content(path, expected_data, "promoted restored file", expected_mode)


def cleanup_private_restore_temp(path: Path) -> None:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as exc:
        print(f"restore temp could not be inspected for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
        return
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) & 0o022:
        print(f"restore temp is not a trusted private file; leaving it in place: {path}", file=sys.stderr)
        return
    try:
        parent_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
    except OSError as exc:
        print(f"restore temp directory could not be opened for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
        return
    try:
        parent_stat = os.fstat(parent_fd)
        parent_mode = stat.S_IMODE(parent_stat.st_mode)
        if not stat.S_ISDIR(parent_stat.st_mode) or parent_stat.st_uid != os.getuid() or parent_mode != 0o700:
            print(f"restore temp directory is not trusted for cleanup; leaving it in place: {path}", file=sys.stderr)
            return
        try:
            fd = os.open(path.name, os.O_RDONLY | nofollow, dir_fd=parent_fd)
        except FileNotFoundError:
            return
        except OSError as exc:
            print(f"restore temp could not be opened for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
            return
        try:
            opened = os.fstat(fd)
        finally:
            os.close(fd)
        if not os.path.samestat(before, opened):
            print(f"restore temp changed before cleanup; leaving it in place: {path}", file=sys.stderr)
            return
        os.unlink(path.name, dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def validate_restore_temp_for_promotion(path: Path, expected_stat: os.stat_result, expected_mode: int) -> None:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        fail(f"restore temp could not be inspected before promotion; leaving it in place: {path}: {exc}")
    if not os.path.samestat(before, expected_stat):
        fail(f"restore temp changed before promotion; leaving it in place: {path}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"restore temp is not a regular file before promotion; leaving it in place: {path}")
    if before.st_uid != os.getuid():
        fail(
            f"restore temp is owned by uid {before.st_uid}, expected {os.getuid()} "
            f"before promotion; leaving it in place: {path}"
        )
    mode = stat.S_IMODE(before.st_mode)
    if mode != expected_mode:
        fail(
            f"restore temp has permissions {mode:04o}, expected {expected_mode:04o} "
            f"before promotion; leaving it in place: {path}"
        )
    try:
        fd = os.open(path, os.O_RDONLY | nofollow)
    except OSError as exc:
        fail(f"restore temp could not be opened before promotion; leaving it in place: {path}: {exc}")
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(opened, expected_stat):
            fail(f"restore temp changed while being opened for promotion; leaving it in place: {path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"restore temp is not regular when opened for promotion; leaving it in place: {path}")
        if opened.st_uid != os.getuid():
            fail(
                f"restore temp is owned by uid {opened.st_uid}, expected {os.getuid()} "
                f"when opened for promotion; leaving it in place: {path}"
            )
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != expected_mode:
            fail(
                f"restore temp has permissions {opened_mode:04o}, expected {expected_mode:04o} "
                f"when opened for promotion; leaving it in place: {path}"
            )
    finally:
        os.close(fd)


def write_file_atomic(
    path: Path,
    data: bytes,
    backup_root: Optional[Path],
    *,
    overwrite: bool,
    apply: bool,
    max_existing_bytes: int,
    mode: int = 0o600,
) -> str:
    existing_stat = inspect_existing_restore_target(path, "restore")
    if existing_stat is not None and not overwrite:
        fail(f"restore target already exists; use --overwrite to replace it: {path}")
    if not apply:
        return "would restore"
    ensure_private_directory(path.parent, apply=True)
    if backup_root is not None:
        backup_existing(path, backup_root, existing_stat, max_existing_bytes)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fchmod(handle.fileno(), mode)
            os.fsync(handle.fileno())
            tmp_stat = os.fstat(handle.fileno())
        validate_restore_temp_for_promotion(tmp_path, tmp_stat, mode)
        validate_restore_target_state_before_promotion(path, existing_stat)
        os.replace(tmp_path, path)
        validate_promoted_restore_file(path, data, mode)
        fsync_parent(path)
    finally:
        cleanup_private_restore_temp(tmp_path)
    return "restored"


def safe_relative(parts: tuple[str, ...], label: str) -> Path:
    if not parts or any(part in {"", ".", ".."} for part in parts):
        fail(f"unsafe {label} member path")
    return Path(*parts)


def opencpn_restore_relative(name: str) -> Optional[Path]:
    if name in {"README.txt", "manifest.json"}:
        return None
    parts = PurePosixPath(name).parts
    if not parts or parts[0] != "opencpn":
        fail(f"OpenCPN archive contains unexpected restore member: {name}")
    relative = safe_relative(parts[1:], "OpenCPN")
    if len(parts) == 2 and parts[1] in {"opencpn.conf", "navobj.xml"}:
        return relative
    if len(parts) == 2 and parts[1].startswith("navobj.xml."):
        return relative
    if len(parts) >= 3 and parts[1] in {"layers", "Layers"} and relative.suffix.lower() in {".gpx", ".xml"}:
        return relative
    fail(f"OpenCPN archive contains unexpected restore member: {name}")


def parse_restored_config(config_text: str) -> ConfigParser:
    parser = ConfigParser()
    try:
        parser.read_string(config_text)
    except ConfigParserError as exc:
        fail(f"restored config.ini is invalid: {exc}")
    return parser


def restored_config_text(parser: ConfigParser, section: str, key: str, default: str, *, label: str) -> str:
    raw = parser.get(section, key, fallback=default)
    value = str(raw).strip()
    if not value:
        fail(f"restored {label} must not be empty")
    return value


def parse_restored_config_int(
    parser: ConfigParser,
    section: str,
    key: str,
    default: int,
    *,
    label: str,
    minimum: Optional[int] = None,
    maximum: Optional[int] = None,
) -> int:
    raw = parser.get(section, key, fallback=str(default))
    try:
        value = int(str(raw).strip())
    except ValueError:
        fail(f"restored {label} must be an integer")
    if minimum is not None and value < minimum:
        fail(f"restored {label} must be at least {minimum}")
    if maximum is not None and value > maximum:
        fail(f"restored {label} must be at most {maximum}")
    return value


def parse_restored_config_float(
    parser: ConfigParser,
    section: str,
    key: str,
    default: float,
    *,
    label: str,
    minimum: Optional[float] = None,
) -> float:
    raw = parser.get(section, key, fallback=str(default))
    try:
        value = float(str(raw).strip())
    except ValueError:
        fail(f"restored {label} must be a number")
    if value != value or value in {float("inf"), float("-inf")}:
        fail(f"restored {label} must be finite")
    if minimum is not None and value < minimum:
        fail(f"restored {label} must be at least {minimum:g}")
    return value


def safe_storage_output_from_config(home: Path, label: str, value: str) -> Path:
    expanded = Path(os.path.expanduser(value))
    if not expanded.is_absolute():
        fail(f"restored {label} is not absolute after expansion: {value}")
    if ".." in expanded.parts:
        fail(f"restored {label} must not contain parent-directory components: {value}")

    resolved_home = home.resolve()
    if expanded == resolved_home or expanded in resolved_home.parents:
        fail(f"restored {label} is too broad: {expanded}")
    if expanded.is_relative_to(resolved_home):
        first = expanded.relative_to(resolved_home).parts[0]
        if first in {".cache", ".config", ".local"}:
            fail(f"restored {label} must not be inside home {first}: {expanded}")
        return expanded
    forbidden_roots = {Path("/"), Path("/boot"), Path("/dev"), Path("/etc"), Path("/opt"), Path("/proc"), Path("/root"), Path("/sys"), Path("/tmp"), Path("/usr"), Path("/var")}
    if expanded in forbidden_roots or any(root in expanded.parents for root in forbidden_roots if root != Path("/")):
        fail(f"restored {label} is not safe storage: {expanded}")
    allowed_roots = (Path("/media"), Path("/mnt"), Path("/run/media"))
    for root in allowed_roots:
        if expanded == root:
            fail(f"restored {label} is too broad: {expanded}")
        if root in expanded.parents:
            return expanded
    fail(f"restored {label} must be under the Pi home, /media, /mnt, or /run/media: {expanded}")


def safe_gps_device_path(path: str) -> bool:
    for prefix in ("/dev/serial/by-id/", "/dev/serial/by-path/"):
        if path.startswith(prefix):
            suffix = path[len(prefix):]
            return bool(suffix) and "/" not in suffix and suffix not in {".", ".."} and all(
                char in GPS_UDEV_SAFE_CHARS for char in suffix
            )
    return path in STABLE_GPS_DEVICE_PATHS


def safe_track_output_from_config(config_text: str, home: Path) -> Path:
    parser = parse_restored_config(config_text)
    chart_output_text = restored_config_text(
        parser,
        "charts",
        "output",
        "~/charts/noaa-enc",
        label="charts.output",
    )
    chart_output = safe_storage_output_from_config(home, "charts.output", chart_output_text)

    gps_mode = restored_config_text(parser, "gps", "mode", "gpsd", label="gps.mode").lower()
    if gps_mode not in {"gpsd", "serial"}:
        fail("restored gps.mode must be either gpsd or serial")
    gps_device = restored_config_text(
        parser,
        "gps",
        "device",
        "/dev/serial/by-id/YOUR_GPS_DEVICE",
        label="gps.device",
    )
    if not safe_gps_device_path(gps_device):
        fail("restored gps.device must be /dev/serial/by-id/..., /dev/serial/by-path/..., /dev/serial0, /dev/serial1, or /dev/gps")
    gps_baud = parse_restored_config_int(parser, "gps", "baud", 4800, label="gps.baud")
    if gps_baud not in GPS_BAUD_RATES:
        fail("restored gps.baud must be one of: 4800, 9600, 19200, 38400, 57600, 115200")
    gpsd_host = restored_config_text(parser, "gps", "gpsd_host", "127.0.0.1", label="gps.gpsd_host")
    if any(separator in gpsd_host for separator in (";", "|")) or any(char.isspace() for char in gpsd_host):
        fail("restored gps.gpsd_host must be a hostname or IP address without spaces, semicolons, or pipes")
    if gps_mode == "gpsd" and gpsd_host.lower() not in GPSD_LOCAL_HOSTS:
        fail("restored gps.gpsd_host must be local for onboard gpsd mode: 127.0.0.1, localhost, or ::1")
    parse_restored_config_int(parser, "gps", "gpsd_port", 2947, label="gps.gpsd_port", minimum=1, maximum=65535)
    parse_restored_config_int(parser, "tracking", "retention_days", 90, label="tracking.retention_days", minimum=0)
    parse_restored_config_float(parser, "anchor", "radius_meters", 50.0, label="anchor.radius_meters", minimum=1.0)

    track_output_text = restored_config_text(
        parser,
        "tracking",
        "output",
        str(chart_output),
        label="tracking.output",
    )
    return safe_storage_output_from_config(home, "tracking.output", track_output_text)


def main() -> None:
    if os.geteuid() == 0:
        fail("do not restore recovery user data as root; run as the Pi desktop user", exit_code=2)

    recovery_dir = Path(sys.argv[1])
    apply = os.environ.get("NOAA_NAVIONICS_RESTORE_APPLY") == "1"
    overwrite = os.environ.get("NOAA_NAVIONICS_RESTORE_OVERWRITE") == "1"
    home = Path.home()

    archives = find_archives(recovery_dir)
    settings = archives["settings"]
    opencpn = archives["opencpn"]
    tracks = archives["tracks"]

    config_bytes = settings.get("noaa-navionics/config.ini")
    if config_bytes is None:
        fail("settings archive is missing noaa-navionics/config.ini")
    try:
        config_text = config_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"restored config.ini is not UTF-8: {exc}")
    track_dir = safe_track_output_from_config(config_text, home) / "tracks"

    backup_root = None
    if apply and overwrite:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup_root = home / ".cache" / "noaa-navionics" / "recovery-restore-backups" / stamp
        ensure_private_directory_tree(backup_root, home / ".cache", apply=True)

    planned: list[tuple[str, Path, bytes, int, int]] = [
        (
            "settings",
            home / ".config" / "noaa-navionics" / "config.ini",
            config_bytes,
            MAX_SETTING_ARCHIVE_MEMBER_BYTES,
            0o600,
        ),
    ]
    launcher = settings["noaa-navionics/launcher.env"]
    planned.append((
        "settings",
        home / ".config" / "noaa-navionics" / "launcher.env",
        launcher,
        MAX_SETTING_ARCHIVE_MEMBER_BYTES,
        0o600,
    ))
    status_launcher = settings["desktop/noaa-navionics-status.desktop"]
    planned.append((
        "settings",
        home / "Desktop" / "noaa-navionics-status.desktop",
        status_launcher,
        MAX_SETTING_ARCHIVE_MEMBER_BYTES,
        0o755,
    ))
    mob_launcher = settings["desktop/noaa-navionics-mob.desktop"]
    planned.append((
        "settings",
        home / "Desktop" / "noaa-navionics-mob.desktop",
        mob_launcher,
        MAX_SETTING_ARCHIVE_MEMBER_BYTES,
        0o755,
    ))

    for name, data in sorted(opencpn.items()):
        relative = opencpn_restore_relative(name)
        if relative is None:
            continue
        planned.append(("opencpn", home / ".opencpn" / relative, data, MAX_OPENCPN_ARCHIVE_MEMBER_BYTES, 0o600))

    for name, data in sorted(tracks.items()):
        if name in {"README.txt", "manifest.json"}:
            continue
        parts = PurePosixPath(name).parts
        if len(parts) != 2 or parts[0] != "tracks" or not parts[1].endswith(".gpx"):
            fail(f"tracks archive contains unexpected restore member: {name}")
        planned.append(("tracks", track_dir / parts[1], data, MAX_TRACK_ARCHIVE_MEMBER_BYTES, 0o600))

    if not apply:
        print("Dry run only. Re-run with --apply to write files.")

    restored = 0
    for category, target, data, max_existing_bytes, mode in planned:
        action = write_file_atomic(
            target,
            data,
            backup_root,
            overwrite=overwrite,
            apply=apply,
            max_existing_bytes=max_existing_bytes,
            mode=mode,
        )
        restored += 1
        print(f"{action} {category}: {target}")

    if apply:
        print(f"Restored {restored} recovery user data file(s).")
        if backup_root is not None:
            print(f"Backed up replaced files under: {backup_root}")
        print("Re-run provisioning, then scripts/verify_pi.sh or scripts/dock_test_pi.sh before relying on the Pi.")


main()
PY
