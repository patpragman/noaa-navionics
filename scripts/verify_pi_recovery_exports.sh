#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify_pi_recovery_exports.sh RECOVERY_DIR

Verifies a local recovery export directory created by
scripts/export_pi_recovery_bundle.sh. This checks archive presence,
permissions, tar readability, safe member names, README files, and export
manifests. It does not contact the Raspberry Pi.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

recovery_dir="$1"
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

if [[ -z "$recovery_dir" ]]; then
  echo "Recovery directory is required" >&2
  exit 2
fi
if [[ "$recovery_dir" =~ [\"\'] ]]; then
  echo "Recovery directory must not contain quotes: $recovery_dir" >&2
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
if [[ ! -d "$recovery_dir" ]]; then
  echo "Recovery directory must be a real directory: $recovery_dir" >&2
  exit 2
fi
python3_cmd="$(require_local_command python3)"

"$python3_cmd" - "$recovery_dir" <<'PY'
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
import json
import hashlib
import math
import os
import re
import stat
import sys
import tarfile


CHECKSUM_MANIFEST_NAME = "SHA256SUMS.txt"
PRE_DEPARTURE_STATUS_NAME = "pre-departure-status.json"
PRE_DEPARTURE_STATUS_CHECKSUM_NAME = "pre-departure-status.sha256"
STATUS_FUTURE_TOLERANCE_SECONDS = 300
BOOT_ID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CORE_SUPPORT_COMMAND_FILES = [
    "commands/system-command-integrity.txt",
    "commands/date-utc.txt",
    "commands/uname.txt",
    "commands/hostname.txt",
    "commands/uptime.txt",
    "commands/package-versions.txt",
    "commands/df.txt",
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
ARCHIVES = [
    {
        "label": "commissioning settings",
        "pattern": "noaa-navionics-pi-settings-*.tgz",
        "manifest_key": "file_count",
    },
    {
        "label": "OpenCPN user data",
        "pattern": "noaa-navionics-pi-opencpn-*.tgz",
        "manifest_key": "file_count",
    },
    {
        "label": "GPX tracks",
        "pattern": "noaa-navionics-pi-tracks-*.tgz",
        "manifest_key": "track_count",
    },
    {
        "label": "diagnostic support bundle",
        "pattern": "noaa-navionics-pi-support-*.tgz",
        "manifest_key": None,
        "required_members": CORE_SUPPORT_COMMAND_FILES,
    },
]
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
    member_path = PurePosixPath(normalized)
    if member_path.is_absolute() or ".." in member_path.parts:
        fail(f"{archive_path.name} contains unsafe member path: {name}")
    return normalized


def first_symlink_ancestor(path: Path):
    current = Path(path).expanduser()
    for candidate in [current, *current.parents]:
        if candidate.is_symlink():
            return candidate
    return None


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


def inspect_archive(archive_path: Path, spec: dict[str, object]) -> int:
    if archive_path.is_symlink():
        fail(f"archive must not be a symlink: {archive_path}")
    try:
        result = archive_path.lstat()
    except OSError as exc:
        fail(f"could not inspect archive {archive_path}: {exc}")
    if not stat.S_ISREG(result.st_mode):
        fail(f"archive must be a regular file: {archive_path}")
    if result.st_uid != os.getuid():
        fail(f"archive is owned by uid {result.st_uid}, expected {os.getuid()}: {archive_path}")
    mode = stat.S_IMODE(result.st_mode)
    if mode != 0o600:
        fail(f"archive has permissions {mode:04o}, expected private 0600: {archive_path}")
    if result.st_size <= 0:
        fail(f"archive is empty: {archive_path}")
    if not os.access(archive_path, os.R_OK):
        fail(f"archive is not readable: {archive_path}")

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
                members = archive.getmembers()
                names = set()
                members_by_name = {}
                regular_file_count = 0
                data_file_count = 0
                data_member_names = []
                for member in members:
                    normalized = validate_member_name(member.name, archive_path)
                    if normalized:
                        if normalized in names:
                            fail(f"{archive_path.name} contains duplicate member: {normalized}")
                        names.add(normalized)
                        members_by_name[normalized] = member
                    if member.issym() or member.islnk() or member.isdev():
                        fail(f"{archive_path.name} contains unsupported non-regular member: {member.name}")
                    if member.isfile():
                        regular_file_count += 1
                        if normalized not in {"README.txt", "manifest.json"}:
                            if spec["manifest_key"] == "track_count":
                                if not normalized.startswith("tracks/") or not normalized.endswith(".gpx"):
                                    fail(f"{archive_path.name} contains non-GPX track data member: {member.name}")
                                track_name = normalized.removeprefix("tracks/")
                                if not track_name or "/" in track_name:
                                    fail(f"{archive_path.name} contains nested or empty track data member: {member.name}")
                                data_member_names.append(track_name)
                            else:
                                data_member_names.append(normalized)
                            data_file_count += 1
                    elif not member.isdir():
                        fail(f"{archive_path.name} contains unsupported member type: {member.name}")

                if "README.txt" not in names:
                    fail(f"{archive_path.name} is missing README.txt")
                if not members_by_name["README.txt"].isfile():
                    fail(f"{archive_path.name} README.txt is not a regular file")

                required_members = list(spec.get("required_members", []))
                missing_members = [
                    name for name in required_members
                    if name not in members_by_name or not members_by_name[name].isfile()
                ]
                if missing_members:
                    fail(
                        f"{archive_path.name} is missing required support diagnostic file(s): "
                        f"{', '.join(missing_members)}"
                    )

                manifest_key = spec["manifest_key"]
                if manifest_key is not None:
                    if "manifest.json" not in names:
                        fail(f"{archive_path.name} is missing manifest.json")
                    try:
                        manifest_file = archive.extractfile(members_by_name["manifest.json"])
                    except (KeyError, OSError, tarfile.TarError) as exc:
                        fail(f"{archive_path.name} manifest.json could not be read: {exc}")
                    if manifest_file is None:
                        fail(f"{archive_path.name} manifest.json is not a regular file")
                    try:
                        manifest = json.loads(manifest_file.read().decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                        fail(f"{archive_path.name} manifest.json is invalid JSON: {exc}")
                    count = manifest.get(str(manifest_key))
                    if not isinstance(count, int) or count <= 0:
                        fail(f"{archive_path.name} manifest {manifest_key} must be a positive integer")
                    if count != data_file_count:
                        fail(
                            f"{archive_path.name} manifest {manifest_key} does not match data file count: "
                            f"{count} != {data_file_count}"
                        )
                    if manifest_key == "file_count":
                        files = manifest.get("files")
                        if not isinstance(files, list):
                            fail(f"{archive_path.name} manifest files must be a list")
                        manifest_file_names = []
                        for index, file_entry in enumerate(files):
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
                    elif manifest_key == "track_count":
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
                return regular_file_count
    except (OSError, tarfile.TarError) as exc:
        fail(f"{archive_path.name} is not a readable gzip tar archive: {exc}")
    finally:
        if fd >= 0:
            os.close(fd)


def hash_private_archive(archive_path: Path) -> str:
    try:
        before = archive_path.lstat()
    except OSError as exc:
        fail(f"could not inspect archive before checksum verification {archive_path}: {exc}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"archive must be a regular file before checksum verification: {archive_path}")
    if before.st_uid != os.getuid():
        fail(f"archive is owned by uid {before.st_uid}, expected {os.getuid()} before checksum verification: {archive_path}")
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o600:
        fail(f"archive has permissions {mode:04o}, expected private 0600 before checksum verification: {archive_path}")
    fd = -1
    try:
        fd = os.open(archive_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            fail(f"archive changed before checksum verification: {archive_path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"archive must be regular when opened for checksum verification: {archive_path}")
        if opened.st_uid != os.getuid():
            fail(f"archive is owned by uid {opened.st_uid}, expected {os.getuid()} when opened for checksum verification: {archive_path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != 0o600:
            fail(f"archive has permissions {opened_mode:04o}, expected private 0600 when opened for checksum verification: {archive_path}")
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
    if manifest_path.is_symlink():
        fail(f"checksum manifest must not be a symlink: {manifest_path}")
    try:
        before = manifest_path.lstat()
    except OSError as exc:
        fail(f"missing checksum manifest {CHECKSUM_MANIFEST_NAME}: {exc}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"checksum manifest must be a regular file: {manifest_path}")
    if before.st_uid != os.getuid():
        fail(f"checksum manifest is owned by uid {before.st_uid}, expected {os.getuid()}: {manifest_path}")
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o600:
        fail(f"checksum manifest has permissions {mode:04o}, expected private 0600: {manifest_path}")
    fd = -1
    try:
        fd = os.open(manifest_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            fail(f"checksum manifest changed while being opened: {manifest_path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"checksum manifest must be regular when opened: {manifest_path}")
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


def read_private_file(file_path: Path, label: str) -> bytes:
    if file_path.is_symlink():
        fail(f"{label} must not be a symlink: {file_path}")
    try:
        before = file_path.lstat()
    except OSError as exc:
        fail(f"missing {label}: {file_path}: {exc}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"{label} must be a regular file: {file_path}")
    if before.st_uid != os.getuid():
        fail(f"{label} is owned by uid {before.st_uid}, expected {os.getuid()}: {file_path}")
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o600:
        fail(f"{label} has permissions {mode:04o}, expected private 0600: {file_path}")
    fd = -1
    try:
        fd = os.open(file_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            fail(f"{label} changed while being opened: {file_path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"{label} must be regular when opened: {file_path}")
        if opened.st_uid != os.getuid():
            fail(f"{label} is owned by uid {opened.st_uid}, expected {os.getuid()} when opened: {file_path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode != 0o600:
            fail(f"{label} has permissions {opened_mode:04o}, expected private 0600 when opened: {file_path}")
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            return handle.read()
    except OSError as exc:
        fail(f"could not read {label} {file_path}: {exc}")
    finally:
        if fd >= 0:
            os.close(fd)


def verify_optional_pre_departure_status(recovery_dir: Path) -> bool:
    status_path = recovery_dir / PRE_DEPARTURE_STATUS_NAME
    checksum_path = recovery_dir / PRE_DEPARTURE_STATUS_CHECKSUM_NAME
    status_present = status_path.exists() or status_path.is_symlink()
    checksum_present = checksum_path.exists() or checksum_path.is_symlink()
    if not status_present and not checksum_present:
        return False
    if not status_present:
        fail(f"missing optional pre-departure status snapshot {PRE_DEPARTURE_STATUS_NAME}")
    if not checksum_present:
        fail(f"missing optional pre-departure status checksum {PRE_DEPARTURE_STATUS_CHECKSUM_NAME}")

    status_payload = read_private_file(status_path, "pre-departure status snapshot")
    checksum_payload = read_private_file(checksum_path, "pre-departure status checksum")
    try:
        checksum_text = checksum_payload.decode("ascii")
    except UnicodeDecodeError as exc:
        fail(f"pre-departure status checksum is not ASCII: {exc}")
    checksum_lines = [line for line in checksum_text.splitlines() if line.strip()]
    if len(checksum_lines) != 1:
        fail("pre-departure status checksum must contain exactly one checksum line")
    if "  " not in checksum_lines[0]:
        fail("pre-departure status checksum must use two-space sha256 filename format")
    expected_digest, name = checksum_lines[0].split("  ", 1)
    if not SHA256_RE.fullmatch(expected_digest):
        fail("pre-departure status checksum has invalid SHA-256 digest")
    if name != PRE_DEPARTURE_STATUS_NAME:
        fail(f"pre-departure status checksum must name {PRE_DEPARTURE_STATUS_NAME}, got {name}")
    actual_digest = hashlib.sha256(status_payload).hexdigest()
    if actual_digest != expected_digest:
        fail(f"pre-departure status checksum mismatch: expected {expected_digest}, got {actual_digest}")
    try:
        status = json.loads(status_payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"pre-departure status snapshot is not valid JSON: {exc}")
    if not isinstance(status, dict):
        fail("pre-departure status snapshot JSON must be an object")
    if status.get("ok") is not True:
        fail("pre-departure status snapshot JSON does not report ok=true")
    for field in ("checks", "service_checks"):
        value = status.get(field)
        if not isinstance(value, list) or not value:
            fail(f"pre-departure status snapshot JSON missing non-empty {field} list")
        if any(not isinstance(item, dict) for item in value):
            fail(f"pre-departure status snapshot JSON has malformed {field} row")
    generated_at = status.get("generated_at")
    if not isinstance(generated_at, str):
        fail("pre-departure status snapshot JSON missing generated_at timestamp")
    try:
        parsed_generated_at = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"pre-departure status snapshot JSON has invalid generated_at timestamp: {exc}")
    if parsed_generated_at.tzinfo is None or parsed_generated_at.utcoffset() is None:
        fail("pre-departure status snapshot JSON generated_at timestamp must include a timezone")
    generated_at_utc = parsed_generated_at.astimezone(timezone.utc)
    age_seconds = (datetime.now(timezone.utc) - generated_at_utc).total_seconds()
    if age_seconds < -STATUS_FUTURE_TOLERANCE_SECONDS:
        fail(
            "pre-departure status snapshot JSON generated_at timestamp is too far in the future "
            f"({-age_seconds:.0f}s ahead; maximum {STATUS_FUTURE_TOLERANCE_SECONDS}s)"
        )
    host = status.get("host")
    if not isinstance(host, dict) or not BOOT_ID_RE.fullmatch(str(host.get("boot_id", ""))):
        fail("pre-departure status snapshot JSON missing valid host boot_id")
    app = status.get("app")
    source_revision = app.get("source_revision") if isinstance(app, dict) else None
    if not isinstance(source_revision, str):
        fail("pre-departure status snapshot JSON missing deployed source_revision")
    source_revision_text = source_revision.strip()
    if not source_revision_text or source_revision_text == "unknown":
        fail("pre-departure status snapshot JSON missing deployed source_revision")
    if source_revision_text.endswith("-dirty"):
        fail("pre-departure status snapshot JSON dirty deployed source_revision is not production-ready")
    validate_pre_departure_status_checks(status, source_revision_text, generated_at_utc)
    return True


def finite_status_float(value: object):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    parsed = float(value)
    return parsed if math.isfinite(parsed) else None


def parse_snapshot_timestamp(value: object, field: str) -> datetime:
    if not isinstance(value, str) or not value.strip():
        fail(f"pre-departure status snapshot JSON {field} timestamp is missing")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"pre-departure status snapshot JSON {field} timestamp is invalid: {exc}")
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        fail(f"pre-departure status snapshot JSON {field} timestamp must include a timezone")
    return parsed.astimezone(timezone.utc)


def validate_snapshot_age(value: object, *, timestamp: datetime, generated_at: datetime, field: str) -> None:
    reported_age = finite_status_float(value)
    if reported_age is None:
        fail(f"pre-departure status snapshot JSON {field} age_seconds is not numeric")
    if reported_age < 0:
        fail(f"pre-departure status snapshot JSON {field} age_seconds is negative")
    if reported_age > 600:
        fail(f"pre-departure status snapshot JSON {field} age_seconds is stale")
    timestamp_age = (generated_at - timestamp).total_seconds()
    if timestamp_age < -STATUS_FUTURE_TOLERANCE_SECONDS:
        fail(f"pre-departure status snapshot JSON {field} timestamp is after generated_at")
    if abs(reported_age - timestamp_age) > STATUS_FUTURE_TOLERANCE_SECONDS:
        fail(f"pre-departure status snapshot JSON {field} age_seconds is inconsistent with timestamp age")


def validate_snapshot_quality(summary: dict[str, object], *, satellite_field: str, hdop_field: str, label: str) -> None:
    satellites = summary.get(satellite_field)
    hdop = summary.get(hdop_field)
    if satellites is None and hdop is None:
        fail(f"pre-departure status snapshot JSON {label} has no satellite or HDOP quality fields")
    if satellites is not None and (
        isinstance(satellites, bool) or not isinstance(satellites, int) or satellites < 4
    ):
        fail(f"pre-departure status snapshot JSON {label} satellites is weak or invalid")
    parsed_hdop = finite_status_float(hdop)
    if hdop is not None and (parsed_hdop is None or parsed_hdop < 0.0 or parsed_hdop > 5.0):
        fail(f"pre-departure status snapshot JSON {label} HDOP is weak or invalid")


def validate_snapshot_gps_fix(
    gps_fix: dict[str, object],
    *,
    gps_mode: str,
    generated_at: datetime,
) -> None:
    expected_source = "GPS" if gps_mode == "serial" else "GPSD"
    source = str(gps_fix.get("source", "")).strip()
    if source != expected_source:
        fail(
            "pre-departure status snapshot JSON gps_fix source "
            + (source or "<missing>")
            + f" does not match {expected_source}"
        )
    latitude = finite_status_float(gps_fix.get("latitude"))
    longitude = finite_status_float(gps_fix.get("longitude"))
    if latitude is None or longitude is None:
        fail("pre-departure status snapshot JSON gps_fix has non-numeric coordinates")
    if not -90.0 <= latitude <= 90.0:
        fail("pre-departure status snapshot JSON gps_fix latitude is outside -90..90")
    if not -180.0 <= longitude <= 180.0:
        fail("pre-departure status snapshot JSON gps_fix longitude is outside -180..180")
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        fail("pre-departure status snapshot JSON gps_fix coordinates are invalid 0,0")
    timestamp = parse_snapshot_timestamp(gps_fix.get("timestamp"), "gps_fix")
    validate_snapshot_age(gps_fix.get("age_seconds"), timestamp=timestamp, generated_at=generated_at, field="gps_fix")
    validate_snapshot_quality(gps_fix, satellite_field="satellites", hdop_field="hdop", label="gps_fix")


def validate_snapshot_track_log(track_log: dict[str, object], *, generated_at: datetime) -> None:
    if track_log.get("track_output_is_symlink") is not False:
        fail("pre-departure status snapshot JSON track_log track_output is a symlink or missing symlink status")
    if "track_storage_symlink_component" not in track_log:
        fail("pre-departure status snapshot JSON track_log missing track_storage_symlink_component")
    if str(track_log.get("track_storage_symlink_component", "")).strip():
        fail("pre-departure status snapshot JSON track_log storage path contains a symlink")
    if not str(track_log.get("latest_path", "")).strip():
        fail("pre-departure status snapshot JSON track_log missing latest_path")
    latitude = finite_status_float(track_log.get("latest_latitude"))
    longitude = finite_status_float(track_log.get("latest_longitude"))
    if latitude is None or longitude is None:
        fail("pre-departure status snapshot JSON track_log has non-numeric latest coordinates")
    if not -90.0 <= latitude <= 90.0:
        fail("pre-departure status snapshot JSON track_log latest_latitude is outside -90..90")
    if not -180.0 <= longitude <= 180.0:
        fail("pre-departure status snapshot JSON track_log latest_longitude is outside -180..180")
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        fail("pre-departure status snapshot JSON track_log latest coordinates are invalid 0,0")
    latest_time = parse_snapshot_timestamp(track_log.get("latest_time"), "track_log latest_time")
    validate_snapshot_age(
        track_log.get("age_seconds"),
        timestamp=latest_time,
        generated_at=generated_at,
        field="track_log",
    )
    validate_snapshot_quality(
        track_log,
        satellite_field="latest_satellites",
        hdop_field="latest_hdop",
        label="track_log",
    )


def validate_snapshot_gps_row(
    check_rows: dict[str, dict[str, object]],
    *,
    gps_mode: str,
    gps_fix: dict[str, object],
) -> None:
    expected_name = "GPS" if gps_mode == "serial" else "GPSD"
    row = check_rows.get(expected_name)
    if not isinstance(row, dict):
        fail(f"pre-departure status snapshot JSON missing {expected_name} readiness row")
    data = row.get("data")
    if not isinstance(data, dict):
        fail(f"pre-departure status snapshot JSON {expected_name} row has no structured fix data")
    latitude = finite_status_float(data.get("latitude"))
    longitude = finite_status_float(data.get("longitude"))
    if latitude is None or longitude is None:
        fail(f"pre-departure status snapshot JSON {expected_name} row has non-numeric coordinates")
    summary_latitude = finite_status_float(gps_fix.get("latitude"))
    summary_longitude = finite_status_float(gps_fix.get("longitude"))
    if summary_latitude is not None and abs(latitude - summary_latitude) > 1e-7:
        fail(f"pre-departure status snapshot JSON {expected_name} latitude does not match gps_fix")
    if summary_longitude is not None and abs(longitude - summary_longitude) > 1e-7:
        fail(f"pre-departure status snapshot JSON {expected_name} longitude does not match gps_fix")
    timestamp = parse_snapshot_timestamp(data.get("timestamp"), f"{expected_name} row")
    summary_timestamp = parse_snapshot_timestamp(gps_fix.get("timestamp"), "gps_fix")
    if timestamp != summary_timestamp:
        fail(f"pre-departure status snapshot JSON {expected_name} timestamp does not match gps_fix")
    validate_snapshot_quality(data, satellite_field="satellites", hdop_field="hdop", label=f"{expected_name} row")
    if gps_fix.get("satellites") is not None and data.get("satellites") != gps_fix.get("satellites"):
        fail(f"pre-departure status snapshot JSON {expected_name} satellites do not match gps_fix")
    if gps_fix.get("hdop") is not None:
        row_hdop = finite_status_float(data.get("hdop"))
        summary_hdop = finite_status_float(gps_fix.get("hdop"))
        if row_hdop is None or summary_hdop is None or abs(row_hdop - summary_hdop) > 1e-9:
            fail(f"pre-departure status snapshot JSON {expected_name} HDOP does not match gps_fix")


def validate_pre_departure_status_checks(
    status: dict[str, object],
    expected_source_revision: str,
    generated_at: datetime,
) -> None:
    checks = status.get("checks")
    service_checks = status.get("service_checks")
    if not isinstance(checks, list) or not isinstance(service_checks, list):
        fail("pre-departure status snapshot JSON missing readiness check sections")

    check_rows = {}
    for row in checks:
        if not isinstance(row, dict):
            fail("pre-departure status snapshot JSON has malformed checks row")
        name = str(row.get("name", "")).strip()
        if not name:
            fail("pre-departure status snapshot JSON has unnamed readiness check")
        if not isinstance(row.get("ok"), bool):
            fail(f"pre-departure status snapshot JSON readiness check {name} ok is not boolean")
        if name in check_rows:
            fail(f"pre-departure status snapshot JSON has duplicate readiness check: {name}")
        check_rows[name] = row

    service_rows = {}
    for row in service_checks:
        if not isinstance(row, dict):
            fail("pre-departure status snapshot JSON has malformed service_checks row")
        name = str(row.get("name", "")).strip()
        if not name:
            fail("pre-departure status snapshot JSON has unnamed service check")
        if not isinstance(row.get("ok"), bool):
            fail(f"pre-departure status snapshot JSON service check {name} ok is not boolean")
        if name in service_rows:
            fail(f"pre-departure status snapshot JSON has duplicate service check: {name}")
        service_rows[name] = row

    config = status.get("config")
    if not isinstance(config, dict):
        fail("pre-departure status snapshot JSON missing config section")
    gps_mode = str(config.get("gps_mode", "")).strip().lower()
    if gps_mode not in {"gpsd", "serial"}:
        fail(
            "pre-departure status snapshot JSON has invalid gps_mode: "
            + (gps_mode or "<missing>")
        )
    chart_output = str(config.get("chart_output", "")).strip()
    if not chart_output:
        fail("pre-departure status snapshot JSON missing config chart_output")
    if not Path(chart_output).is_absolute():
        fail("pre-departure status snapshot JSON config chart_output is not absolute")
    configured_track_output = str(config.get("track_output", "")).strip()
    if not configured_track_output:
        fail("pre-departure status snapshot JSON missing config track_output")
    if not Path(configured_track_output).is_absolute():
        fail("pre-departure status snapshot JSON config track_output is not absolute")
    gps_fix = status.get("gps_fix")
    if not isinstance(gps_fix, dict):
        fail("pre-departure status snapshot JSON missing gps_fix section")
    if not isinstance(gps_fix.get("ok"), bool):
        fail("pre-departure status snapshot JSON gps_fix ok is not boolean")
    if gps_fix.get("ok") is not True:
        fail(
            "pre-departure status snapshot JSON gps_fix is not ok: "
            + str(gps_fix.get("detail", "<missing detail>"))
        )
    validate_snapshot_gps_fix(gps_fix, gps_mode=gps_mode, generated_at=generated_at)
    track_log = status.get("track_log")
    if not isinstance(track_log, dict):
        fail("pre-departure status snapshot JSON missing track_log section")
    if not isinstance(track_log.get("ok"), bool):
        fail("pre-departure status snapshot JSON track_log ok is not boolean")
    if track_log.get("ok") is not True:
        fail(
            "pre-departure status snapshot JSON track_log is not ok: "
            + str(track_log.get("detail", "<missing detail>"))
        )
    validate_snapshot_track_log(track_log, generated_at=generated_at)
    track_output = str(track_log.get("track_output", "")).strip()
    if not track_output:
        fail("pre-departure status snapshot JSON missing track_log track_output")
    if track_output != configured_track_output:
        fail("pre-departure status snapshot JSON track_log track_output does not match config track_output")
    tracks_dir = str(track_log.get("tracks_dir", "")).strip()
    expected_tracks_dir = str(Path(configured_track_output) / "tracks")
    if tracks_dir != expected_tracks_dir:
        fail("pre-departure status snapshot JSON track_log tracks_dir does not match config track_output")

    required_checks = set(CORE_READINESS_CHECKS)
    required_service_checks = set(CORE_SERVICE_CHECKS)
    if gps_mode == "serial":
        required_checks.update(SERIAL_READINESS_CHECKS)
    else:
        required_checks.update(GPSD_READINESS_CHECKS)
        required_service_checks.update(GPSD_SERVICE_CHECKS)
    if track_output != chart_output:
        required_checks.add("Track Disk")

    missing_checks = sorted(required_checks - set(check_rows))
    missing_service_checks = sorted(required_service_checks - set(service_rows))
    if missing_checks:
        fail(
            "pre-departure status snapshot JSON missing required readiness check(s): "
            + ", ".join(missing_checks)
        )
    if missing_service_checks:
        fail(
            "pre-departure status snapshot JSON missing required service check(s): "
            + ", ".join(missing_service_checks)
        )
    failed_checks = sorted(name for name, row in check_rows.items() if row.get("ok") is not True)
    failed_service_checks = sorted(name for name, row in service_rows.items() if row.get("ok") is not True)
    if failed_checks:
        fail(
            "pre-departure status snapshot JSON has failed readiness check(s): "
            + ", ".join(failed_checks)
        )
    if failed_service_checks:
        fail(
            "pre-departure status snapshot JSON has failed service check(s): "
            + ", ".join(failed_service_checks)
        )
    missing_structured_data = sorted(
        name for name in required_checks if not isinstance(check_rows[name].get("data"), dict)
    )
    if missing_structured_data:
        fail(
            "pre-departure status snapshot JSON missing structured readiness data for: "
            + ", ".join(missing_structured_data)
        )
    validate_snapshot_gps_row(check_rows, gps_mode=gps_mode, gps_fix=gps_fix)
    non_pi_skips = sorted(
        name
        for name in required_checks & PI_ONLY_READINESS_CHECKS
        if check_rows[name].get("data", {}).get("is_raspberry_pi") is False
        and check_rows[name].get("data", {}).get("skipped") is True
    )
    if non_pi_skips:
        fail(
            "pre-departure status snapshot JSON records non-Pi diagnostic skip(s): "
            + ", ".join(non_pi_skips)
        )
    source_data = check_rows["Source Revision"].get("data")
    row_revision = str(source_data.get("revision", "")).strip()
    if not row_revision or row_revision == "unknown":
        fail("pre-departure status snapshot JSON Source Revision row missing revision")
    if row_revision.endswith("-dirty"):
        fail("pre-departure status snapshot JSON Source Revision row records a dirty revision")
    if row_revision != expected_source_revision:
        fail("pre-departure status snapshot JSON Source Revision row does not match deployed source_revision")


def verify_checksum_manifest(recovery_dir: Path, archive_paths: list[Path]) -> None:
    entries = read_checksum_manifest(recovery_dir)
    expected_names = {path.name for path in archive_paths}
    actual_names = set(entries)
    missing = sorted(expected_names - actual_names)
    extra = sorted(actual_names - expected_names)
    if missing:
        fail(f"checksum manifest is missing archive(s): {', '.join(missing)}")
    if extra:
        fail(f"checksum manifest lists unexpected archive(s): {', '.join(extra)}")
    for archive_path in archive_paths:
        actual_digest = hash_private_archive(archive_path)
        expected_digest = entries[archive_path.name]
        if actual_digest != expected_digest:
            fail(f"checksum mismatch for {archive_path.name}: expected {expected_digest}, got {actual_digest}")


def find_archive(recovery_dir: Path, spec: dict[str, object]) -> Path:
    matches = sorted(recovery_dir.glob(str(spec["pattern"])))
    if not matches:
        fail(f"missing {spec['label']} archive matching {spec['pattern']}")
    if len(matches) > 1:
        fail(f"expected one {spec['label']} archive, found {len(matches)}")
    return matches[0]


def main() -> None:
    recovery_dir = Path(sys.argv[1])
    assert_private_recovery_directory(recovery_dir)
    summaries = []
    archive_paths = []
    for spec in ARCHIVES:
        archive_path = find_archive(recovery_dir, spec)
        file_count = inspect_archive(archive_path, spec)
        summaries.append((str(spec["label"]), archive_path.name, file_count))
        archive_paths.append(archive_path)
    verify_checksum_manifest(recovery_dir, archive_paths)
    verified_pre_departure_status = verify_optional_pre_departure_status(recovery_dir)

    print(f"Verified Pi recovery exports: {recovery_dir}")
    for label, name, file_count in summaries:
        print(f"- {label}: {name} ({file_count} regular file(s))")
    if verified_pre_departure_status:
        print(f"- pre-departure status: {PRE_DEPARTURE_STATUS_NAME} (checksum verified)")


main()
PY
