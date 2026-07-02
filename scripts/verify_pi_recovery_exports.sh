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

"$python3_cmd" - "$recovery_dir" <<'PY'
import configparser
from datetime import datetime, timezone
import fnmatch
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
GPS_BAUD_RATES = {4800, 9600, 19200, 38400, 57600, 115200}
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
CORE_SUPPORT_NOAA_COMMAND_FILES = [
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
CORE_SUPPORT_HOME_FILE_PATTERNS = [
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
CORE_SETTINGS_FILES = [
    "noaa-navionics/config.ini",
    "noaa-navionics/launcher.env",
    "noaa-navionics/source-revision",
    "desktop/noaa-navionics-chartplotter.desktop",
    "desktop/noaa-navionics-status.desktop",
    "desktop/noaa-navionics-mob.desktop",
    "system/etc-default-gpsd",
    "system/chrony.conf",
    "system/noaa-navionics-gpsd.conf",
    "system/50-noaa-navionics-autologin.conf",
    "systemd/user/noaa-navionics.service",
    "systemd/user/noaa-navionics.timer",
    "systemd/user/noaa-navionics-track.service",
    "systemd/user/noaa-navionics-preflight.service",
]
MAX_SETTING_ARCHIVE_MEMBER_BYTES = 4 * 1024 * 1024
MAX_OPENCPN_ARCHIVE_MEMBER_BYTES = 50 * 1024 * 1024
MAX_TRACK_ARCHIVE_MEMBER_BYTES = 100 * 1024 * 1024
MAX_SUPPORT_ARCHIVE_MEMBER_BYTES = 10 * 1024 * 1024
ARCHIVES = [
    {
        "label": "commissioning settings",
        "pattern": "noaa-navionics-pi-settings-*.tgz",
        "manifest_key": "file_count",
        "required_members": CORE_SETTINGS_FILES,
        "desktop_entries": True,
        "max_member_bytes": MAX_SETTING_ARCHIVE_MEMBER_BYTES,
    },
    {
        "label": "OpenCPN user data",
        "pattern": "noaa-navionics-pi-opencpn-*.tgz",
        "manifest_key": "file_count",
        "max_member_bytes": MAX_OPENCPN_ARCHIVE_MEMBER_BYTES,
    },
    {
        "label": "GPX tracks",
        "pattern": "noaa-navionics-pi-tracks-*.tgz",
        "manifest_key": "track_count",
        "max_member_bytes": MAX_TRACK_ARCHIVE_MEMBER_BYTES,
    },
    {
        "label": "diagnostic support bundle",
        "pattern": "noaa-navionics-pi-support-*.tgz",
        "manifest_key": None,
        "required_members": CORE_SUPPORT_COMMAND_FILES + CORE_SUPPORT_NOAA_COMMAND_FILES,
        "required_member_patterns": CORE_SUPPORT_HOME_FILE_PATTERNS,
        "max_member_bytes": MAX_SUPPORT_ARCHIVE_MEMBER_BYTES,
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
EXPECTED_CHARTPLOTTER_DESKTOP_ENTRY_VALUES = {
    "Type": "Application",
    "Name": "NOAA Navionics Chartplotter",
    "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
    "Terminal": "false",
    "X-GNOME-Autostart-enabled": "true",
}
EXPECTED_MOB_LAUNCHER_VALUES = {
    "Type": "Application",
    "Name": "NOAA Navionics MOB",
    "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics mob; printf \'\\nPress Enter to close...\'; read _"',
    "Terminal": "true",
}
EXPECTED_STATUS_LAUNCHER_VALUES = {
    "Type": "Application",
    "Name": "NOAA Navionics Status",
    "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-status-gui"',
    "Terminal": "false",
}
EXPECTED_SETTINGS_DESKTOP_ENTRIES = {
    "desktop/noaa-navionics-chartplotter.desktop": {
        "label": "chartplotter desktop autostart",
        "values": EXPECTED_CHARTPLOTTER_DESKTOP_ENTRY_VALUES,
        "forbid_autostart": False,
    },
    "desktop/noaa-navionics-status.desktop": {
        "label": "status GUI desktop launcher",
        "values": EXPECTED_STATUS_LAUNCHER_VALUES,
        "forbid_autostart": True,
    },
    "desktop/noaa-navionics-mob.desktop": {
        "label": "MOB desktop launcher",
        "values": EXPECTED_MOB_LAUNCHER_VALUES,
        "forbid_autostart": True,
    },
}


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


def parse_settings_desktop_entry(
    archive: tarfile.TarFile,
    member: tarfile.TarInfo,
    archive_path: Path,
    label: str,
) -> dict[str, str]:
    try:
        member_file = archive.extractfile(member)
    except (KeyError, OSError, tarfile.TarError) as exc:
        fail(f"{archive_path.name} {label} could not be read: {exc}")
    if member_file is None:
        fail(f"{archive_path.name} {label} is not a regular file")
    try:
        text = member_file.read().decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"{archive_path.name} {label} is not UTF-8: {exc}")

    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    try:
        parser.read_string(text)
    except configparser.Error as exc:
        fail(f"{archive_path.name} {label} is invalid desktop entry syntax: {exc}")
    if not parser.has_section("Desktop Entry"):
        fail(f"{archive_path.name} {label} is missing [Desktop Entry]")
    return {key: value.strip() for key, value in parser.items("Desktop Entry", raw=True)}


def validate_settings_desktop_entries(
    archive: tarfile.TarFile,
    members_by_name: dict[str, tarfile.TarInfo],
    archive_path: Path,
) -> None:
    for member_name, spec in EXPECTED_SETTINGS_DESKTOP_ENTRIES.items():
        member = members_by_name.get(member_name)
        label = str(spec["label"])
        if member is None or not member.isfile():
            fail(f"{archive_path.name} is missing required archive member(s): {member_name}")
        values = parse_settings_desktop_entry(archive, member, archive_path, label)
        expected_values = spec["values"]
        for key, expected in expected_values.items():
            actual = values.get(key, "")
            if actual != expected:
                fail(f"{archive_path.name} {label} {key}={actual or '<missing>'} expected {expected}")
        if values.get("Hidden", "").lower() == "true":
            fail(f"{archive_path.name} {label} must not be hidden")
        if spec.get("forbid_autostart") and values.get("X-GNOME-Autostart-enabled", "").lower() == "true":
            fail(f"{archive_path.name} {label} must not be configured for autostart")


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


def open_trusted_recovery_directory(path: Path) -> int:
    symlink = first_symlink_ancestor(path.parent)
    if symlink is not None:
        fail(f"recovery directory parent path contains a symlink: {symlink}")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        fail(f"could not inspect recovery directory {path}: {exc}")
    if stat.S_ISLNK(before.st_mode):
        fail(f"recovery directory is a symlink: {path}")
    if not stat.S_ISDIR(before.st_mode):
        fail(f"recovery directory must be a real directory: {path}")
    try:
        directory_fd = os.open(path, flags)
    except OSError as exc:
        fail(f"could not open recovery directory {path}: {exc}")
    try:
        opened = os.fstat(directory_fd)
        if not os.path.samestat(before, opened):
            fail(f"recovery directory changed before it could be verified: {path}")
        if not stat.S_ISDIR(opened.st_mode):
            fail(f"recovery directory must be a real directory when opened: {path}")
        if opened.st_uid != os.getuid():
            fail(f"recovery directory is owned by uid {opened.st_uid}, expected {os.getuid()}: {path}")
        mode = stat.S_IMODE(opened.st_mode)
        if mode != 0o700:
            fail(f"recovery directory has permissions {mode:04o}, expected private 0700: {path}")
        return directory_fd
    except BaseException:
        os.close(directory_fd)
        raise


def stat_recovery_child(recovery_fd: int, file_name: str, label: str, path: Path) -> os.stat_result:
    if "/" in file_name or file_name in {"", ".", ".."}:
        fail(f"{label} has unsafe recovery-directory file name: {file_name}")
    try:
        return os.stat(file_name, dir_fd=recovery_fd, follow_symlinks=False)
    except FileNotFoundError as exc:
        fail(f"missing {label}: {path}: {exc}")
    except OSError as exc:
        fail(f"could not inspect {label} {path}: {exc}")


def recovery_child_exists(recovery_fd: int, file_name: str) -> bool:
    try:
        os.stat(file_name, dir_fd=recovery_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def inspect_archive(archive_path: Path, spec: dict[str, object], recovery_fd: int) -> int:
    result = stat_recovery_child(recovery_fd, archive_path.name, "archive", archive_path)
    if stat.S_ISLNK(result.st_mode):
        fail(f"archive must not be a symlink: {archive_path}")
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
        fd = os.open(archive_path.name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=recovery_fd)
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
                max_member_bytes = int(spec["max_member_bytes"])
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
                        if member.size < 0:
                            fail(f"{archive_path.name} contains negative-size member: {member.name}")
                        if member.size > max_member_bytes:
                            fail(
                                f"{archive_path.name} member is too large to verify safely: "
                                f"{member.name} ({member.size} bytes > {max_member_bytes})"
                            )
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

                required_members = list(spec.get("required_members", []))
                missing_members = [
                    name for name in required_members
                    if name not in members_by_name or not members_by_name[name].isfile()
                ]
                if missing_members:
                    fail(
                        f"{archive_path.name} is missing required archive member(s): "
                        f"{', '.join(missing_members)}"
                    )
                if spec.get("desktop_entries"):
                    validate_settings_desktop_entries(archive, members_by_name, archive_path)
                required_member_patterns = list(spec.get("required_member_patterns", []))
                missing_pattern_labels = [
                    label
                    for label, pattern in required_member_patterns
                    if not any(member.isfile() and pattern.fullmatch(name) for name, member in members_by_name.items())
                ]
                if missing_pattern_labels:
                    fail(
                        f"{archive_path.name} is missing required archive evidence file(s): "
                        f"{', '.join(missing_pattern_labels)}"
                    )

                if regular_file_count <= 0:
                    fail(f"{archive_path.name} does not contain any regular files")
                return regular_file_count
    except (OSError, tarfile.TarError) as exc:
        fail(f"{archive_path.name} is not a readable gzip tar archive: {exc}")
    finally:
        if fd >= 0:
            os.close(fd)


def hash_private_archive(archive_path: Path, recovery_fd: int) -> str:
    before = stat_recovery_child(recovery_fd, archive_path.name, "archive before checksum verification", archive_path)
    if not stat.S_ISREG(before.st_mode):
        fail(f"archive must be a regular file before checksum verification: {archive_path}")
    if before.st_uid != os.getuid():
        fail(f"archive is owned by uid {before.st_uid}, expected {os.getuid()} before checksum verification: {archive_path}")
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o600:
        fail(f"archive has permissions {mode:04o}, expected private 0600 before checksum verification: {archive_path}")
    fd = -1
    try:
        fd = os.open(archive_path.name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=recovery_fd)
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


def read_checksum_manifest(recovery_dir: Path, recovery_fd: int) -> dict[str, str]:
    manifest_path = recovery_dir / CHECKSUM_MANIFEST_NAME
    before = stat_recovery_child(
        recovery_fd,
        CHECKSUM_MANIFEST_NAME,
        f"checksum manifest {CHECKSUM_MANIFEST_NAME}",
        manifest_path,
    )
    if stat.S_ISLNK(before.st_mode):
        fail(f"checksum manifest must not be a symlink: {manifest_path}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"checksum manifest must be a regular file: {manifest_path}")
    if before.st_uid != os.getuid():
        fail(f"checksum manifest is owned by uid {before.st_uid}, expected {os.getuid()}: {manifest_path}")
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o600:
        fail(f"checksum manifest has permissions {mode:04o}, expected private 0600: {manifest_path}")
    fd = -1
    try:
        fd = os.open(CHECKSUM_MANIFEST_NAME, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=recovery_fd)
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
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


def read_private_file(file_path: Path, label: str, recovery_fd: int) -> bytes:
    before = stat_recovery_child(recovery_fd, file_path.name, label, file_path)
    if stat.S_ISLNK(before.st_mode):
        fail(f"{label} must not be a symlink: {file_path}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"{label} must be a regular file: {file_path}")
    if before.st_uid != os.getuid():
        fail(f"{label} is owned by uid {before.st_uid}, expected {os.getuid()}: {file_path}")
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o600:
        fail(f"{label} has permissions {mode:04o}, expected private 0600: {file_path}")
    fd = -1
    try:
        fd = os.open(file_path.name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=recovery_fd)
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


def verify_optional_pre_departure_status(recovery_dir: Path, recovery_fd: int) -> bool:
    status_path = recovery_dir / PRE_DEPARTURE_STATUS_NAME
    checksum_path = recovery_dir / PRE_DEPARTURE_STATUS_CHECKSUM_NAME
    status_present = recovery_child_exists(recovery_fd, PRE_DEPARTURE_STATUS_NAME)
    checksum_present = recovery_child_exists(recovery_fd, PRE_DEPARTURE_STATUS_CHECKSUM_NAME)
    if not status_present and not checksum_present:
        return False
    if not status_present:
        fail(f"missing optional pre-departure status snapshot {PRE_DEPARTURE_STATUS_NAME}")
    if not checksum_present:
        fail(f"missing optional pre-departure status checksum {PRE_DEPARTURE_STATUS_CHECKSUM_NAME}")

    status_payload = read_private_file(status_path, "pre-departure status snapshot", recovery_fd)
    checksum_payload = read_private_file(checksum_path, "pre-departure status checksum", recovery_fd)
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


def positive_status_int(value: object):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return None
    return value


def snapshot_text(value: object, label: str) -> str:
    if not isinstance(value, str):
        fail(f"pre-departure status snapshot JSON {label} is not a string")
    text = str(value)
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        fail(f"pre-departure status snapshot JSON {label} contains control characters")
    return text.strip()


def snapshot_absolute_path(value: object, label: str) -> str:
    text = snapshot_text(value, label)
    if not text or not Path(text).is_absolute():
        fail(f"pre-departure status snapshot JSON {label} is not absolute")
    return text


SNAPSHOT_STATIC_DIAGNOSTICS = (
    "pre-departure status snapshot JSON config_path is not absolute",
    "pre-departure status snapshot JSON config chart_output is not absolute",
    "pre-departure status snapshot JSON config track_output is not absolute",
    "pre-departure status snapshot JSON track_log track_output is not absolute",
    "pre-departure status snapshot JSON track_log tracks_dir is not absolute",
    "pre-departure status snapshot JSON track_log latest_path is not absolute",
    "pre-departure status snapshot JSON Manifest path is not absolute",
    "pre-departure status snapshot JSON Manifest download path is not absolute",
    "pre-departure status snapshot JSON Manifest extract path is not absolute",
    "pre-departure status snapshot JSON Charts ENC cell sample path is not absolute",
    "pre-departure status snapshot JSON OpenCPN Charts chart directory is not absolute",
    "pre-departure status snapshot JSON OpenCPN Charts config path is not absolute",
    "pre-departure status snapshot JSON OpenCPN GPSD config path is not absolute",
)


def stable_snapshot_gps_device_path(path: str) -> bool:
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:+@-"
    for prefix in ("/dev/serial/by-id/", "/dev/serial/by-path/"):
        if path.startswith(prefix):
            suffix = path[len(prefix) :]
            return bool(suffix) and "/" not in suffix and suffix not in {".", ".."} and all(
                char in allowed for char in suffix
            )
    return path in {"/dev/serial0", "/dev/serial1", "/dev/gps"}


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


def private_octal_mode(value: object, *, field: str) -> int:
    text = str(value).strip()
    if not text:
        fail(f"pre-departure status snapshot JSON track_log {field} is missing or invalid")
    try:
        mode = int(text, 8)
    except ValueError:
        fail(f"pre-departure status snapshot JSON track_log {field} is missing or invalid")
    if mode < 0 or mode > 0o7777:
        fail(f"pre-departure status snapshot JSON track_log {field} is missing or invalid")
    if mode & 0o077:
        fail(f"pre-departure status snapshot JSON track_log {field} is not private")
    return mode


def snapshot_octal_mode(value: object, *, label: str) -> int:
    text = str(value).strip()
    if not text:
        fail(f"pre-departure status snapshot JSON {label} mode is invalid")
    try:
        mode = int(text, 8)
    except ValueError:
        fail(f"pre-departure status snapshot JSON {label} mode is invalid")
    if mode < 0 or mode > 0o7777:
        fail(f"pre-departure status snapshot JSON {label} mode is invalid")
    return mode


def snapshot_uid(value: object, *, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail(f"pre-departure status snapshot JSON {label} owner is invalid")
    return value


def validate_snapshot_autostart(status: dict[str, object]) -> None:
    desktop = status.get("desktop")
    if not isinstance(desktop, dict):
        fail("pre-departure status snapshot JSON missing desktop section")
    autostart = desktop.get("autostart")
    if not isinstance(autostart, dict):
        fail("pre-departure status snapshot JSON missing desktop autostart evidence")
    autostart_path = snapshot_text(autostart.get("path", ""), "desktop autostart path")
    if not autostart_path or not Path(autostart_path).is_absolute():
        fail("pre-departure status snapshot JSON desktop autostart path is not absolute")
    if Path(autostart_path).name != "noaa-navionics-chartplotter.desktop":
        fail("pre-departure status snapshot JSON desktop autostart path has unexpected filename")
    if autostart.get("exists") is not True:
        fail("pre-departure status snapshot JSON desktop autostart does not exist")
    if autostart.get("is_symlink") is not False:
        fail("pre-departure status snapshot JSON desktop autostart path is a symlink or missing symlink status")
    if autostart.get("directory_is_symlink") is not False:
        fail("pre-departure status snapshot JSON desktop autostart directory is a symlink or missing symlink status")
    if "path_symlink_component" not in autostart:
        fail("pre-departure status snapshot JSON desktop autostart missing path_symlink_component")
    if snapshot_text(autostart.get("path_symlink_component", ""), "desktop autostart path_symlink_component"):
        fail("pre-departure status snapshot JSON desktop autostart path contains a symlink")
    snapshot_uid(autostart.get("uid"), label="desktop autostart")
    snapshot_uid(autostart.get("directory_uid"), label="desktop autostart directory")
    mode = snapshot_octal_mode(autostart.get("mode"), label="desktop autostart")
    if mode & 0o022:
        fail("pre-departure status snapshot JSON desktop autostart is group/world writable")
    directory_mode = snapshot_octal_mode(
        autostart.get("directory_mode"),
        label="desktop autostart directory",
    )
    if directory_mode & 0o022:
        fail("pre-departure status snapshot JSON desktop autostart directory is group/world writable")
    values = autostart.get("values")
    if not isinstance(values, dict):
        fail("pre-departure status snapshot JSON desktop autostart values were not parsed")
    for key, expected in EXPECTED_CHARTPLOTTER_DESKTOP_ENTRY_VALUES.items():
        actual = str(values.get(key, "")).strip()
        if actual != expected:
            fail(f"pre-departure status snapshot JSON desktop autostart {key} does not match expected value")
    if str(values.get("Hidden", "")).strip().lower() == "true":
        fail("pre-departure status snapshot JSON desktop autostart is hidden")


def validate_snapshot_mob_launcher(status: dict[str, object]) -> None:
    desktop = status.get("desktop")
    if not isinstance(desktop, dict):
        fail("pre-departure status snapshot JSON missing desktop section")
    mob_launcher = desktop.get("mob_launcher")
    if not isinstance(mob_launcher, dict):
        fail("pre-departure status snapshot JSON missing MOB desktop launcher evidence")
    launcher_path = snapshot_text(mob_launcher.get("path", ""), "MOB desktop launcher path")
    if not launcher_path or not Path(launcher_path).is_absolute():
        fail("pre-departure status snapshot JSON MOB desktop launcher path is not absolute")
    if Path(launcher_path).name != "noaa-navionics-mob.desktop":
        fail("pre-departure status snapshot JSON MOB desktop launcher path has unexpected filename")
    if mob_launcher.get("exists") is not True:
        fail("pre-departure status snapshot JSON MOB desktop launcher does not exist")
    if mob_launcher.get("is_symlink") is not False:
        fail("pre-departure status snapshot JSON MOB desktop launcher path is a symlink or missing symlink status")
    if mob_launcher.get("directory_is_symlink") is not False:
        fail("pre-departure status snapshot JSON MOB desktop launcher directory is a symlink or missing symlink status")
    if "path_symlink_component" not in mob_launcher:
        fail("pre-departure status snapshot JSON MOB desktop launcher missing path_symlink_component")
    if snapshot_text(mob_launcher.get("path_symlink_component", ""), "MOB desktop launcher path_symlink_component"):
        fail("pre-departure status snapshot JSON MOB desktop launcher path contains a symlink")
    snapshot_uid(mob_launcher.get("uid"), label="MOB desktop launcher")
    snapshot_uid(mob_launcher.get("directory_uid"), label="MOB desktop launcher directory")
    mode = snapshot_octal_mode(mob_launcher.get("mode"), label="MOB desktop launcher")
    if mode & 0o022:
        fail("pre-departure status snapshot JSON MOB desktop launcher is group/world writable")
    if not mode & 0o100:
        fail("pre-departure status snapshot JSON MOB desktop launcher is not user executable")
    directory_mode = snapshot_octal_mode(
        mob_launcher.get("directory_mode"),
        label="MOB desktop launcher directory",
    )
    if directory_mode & 0o022:
        fail("pre-departure status snapshot JSON MOB desktop launcher directory is group/world writable")
    values = mob_launcher.get("values")
    if not isinstance(values, dict):
        fail("pre-departure status snapshot JSON MOB desktop launcher values were not parsed")
    for key, expected in EXPECTED_MOB_LAUNCHER_VALUES.items():
        actual = str(values.get(key, "")).strip()
        if actual != expected:
            fail(f"pre-departure status snapshot JSON MOB desktop launcher {key} does not match expected value")
    if str(values.get("Hidden", "")).strip().lower() == "true":
        fail("pre-departure status snapshot JSON MOB desktop launcher is hidden")
    if str(values.get("X-GNOME-Autostart-enabled", "")).strip().lower() == "true":
        fail("pre-departure status snapshot JSON MOB desktop launcher must not be configured for autostart")


def validate_snapshot_status_launcher(status: dict[str, object]) -> None:
    desktop = status.get("desktop")
    if not isinstance(desktop, dict):
        fail("pre-departure status snapshot JSON missing desktop section")
    status_launcher = desktop.get("status_launcher")
    if not isinstance(status_launcher, dict):
        fail("pre-departure status snapshot JSON missing status GUI desktop launcher evidence")
    launcher_path = snapshot_text(status_launcher.get("path", ""), "status GUI desktop launcher path")
    if not launcher_path or not Path(launcher_path).is_absolute():
        fail("pre-departure status snapshot JSON status GUI desktop launcher path is not absolute")
    if Path(launcher_path).name != "noaa-navionics-status.desktop":
        fail("pre-departure status snapshot JSON status GUI desktop launcher path has unexpected filename")
    if status_launcher.get("exists") is not True:
        fail("pre-departure status snapshot JSON status GUI desktop launcher does not exist")
    if status_launcher.get("is_symlink") is not False:
        fail("pre-departure status snapshot JSON status GUI desktop launcher path is a symlink or missing symlink status")
    if status_launcher.get("directory_is_symlink") is not False:
        fail("pre-departure status snapshot JSON status GUI desktop launcher directory is a symlink or missing symlink status")
    if "path_symlink_component" not in status_launcher:
        fail("pre-departure status snapshot JSON status GUI desktop launcher missing path_symlink_component")
    if snapshot_text(status_launcher.get("path_symlink_component", ""), "status GUI desktop launcher path_symlink_component"):
        fail("pre-departure status snapshot JSON status GUI desktop launcher path contains a symlink")
    snapshot_uid(status_launcher.get("uid"), label="status GUI desktop launcher")
    snapshot_uid(status_launcher.get("directory_uid"), label="status GUI desktop launcher directory")
    mode = snapshot_octal_mode(status_launcher.get("mode"), label="status GUI desktop launcher")
    if mode & 0o022:
        fail("pre-departure status snapshot JSON status GUI desktop launcher is group/world writable")
    if not mode & 0o100:
        fail("pre-departure status snapshot JSON status GUI desktop launcher is not user executable")
    directory_mode = snapshot_octal_mode(
        status_launcher.get("directory_mode"),
        label="status GUI desktop launcher directory",
    )
    if directory_mode & 0o022:
        fail("pre-departure status snapshot JSON status GUI desktop launcher directory is group/world writable")
    values = status_launcher.get("values")
    if not isinstance(values, dict):
        fail("pre-departure status snapshot JSON status GUI desktop launcher values were not parsed")
    for key, expected in EXPECTED_STATUS_LAUNCHER_VALUES.items():
        actual = str(values.get(key, "")).strip()
        if actual != expected:
            fail(f"pre-departure status snapshot JSON status GUI desktop launcher {key} does not match expected value")
    if str(values.get("Hidden", "")).strip().lower() == "true":
        fail("pre-departure status snapshot JSON status GUI desktop launcher is hidden")
    if str(values.get("X-GNOME-Autostart-enabled", "")).strip().lower() == "true":
        fail("pre-departure status snapshot JSON status GUI desktop launcher must not be configured for autostart")


def validate_track_log_paths(track_log: dict[str, object]) -> None:
    track_output = snapshot_absolute_path(track_log.get("track_output", ""), "track_log track_output")
    tracks_dir = snapshot_absolute_path(track_log.get("tracks_dir", ""), "track_log tracks_dir")
    latest_path = snapshot_text(track_log.get("latest_path", ""), "track_log latest_path")
    if str(Path(track_output) / "tracks") != tracks_dir:
        fail("pre-departure status snapshot JSON track_log tracks_dir does not match track_output")
    if not latest_path:
        fail("pre-departure status snapshot JSON track_log missing latest_path")
    if not Path(latest_path).is_absolute():
        fail("pre-departure status snapshot JSON track_log latest_path is not absolute")
    normalized_latest = os.path.normpath(latest_path)
    normalized_tracks = os.path.normpath(tracks_dir)
    try:
        latest_common = os.path.commonpath([normalized_latest, normalized_tracks])
    except ValueError:
        latest_common = ""
    if normalized_latest == normalized_tracks or latest_common != normalized_tracks:
        fail("pre-departure status snapshot JSON track_log latest_path is not under tracks_dir")
    latest_name = Path(latest_path).name
    if not latest_name.startswith("track-") or Path(latest_name).suffix.lower() != ".gpx":
        fail("pre-departure status snapshot JSON track_log latest_path is not a track-*.gpx file")
    private_octal_mode(track_log.get("tracks_mode"), field="tracks_mode")
    private_octal_mode(track_log.get("latest_mode"), field="latest_mode")


def validate_snapshot_gps_fix(
    gps_fix: dict[str, object],
    *,
    gps_mode: str,
    generated_at: datetime,
) -> None:
    expected_source = "GPS" if gps_mode == "serial" else "GPSD"
    source = snapshot_text(gps_fix.get("source", ""), "gps_fix source")
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
    if snapshot_text(track_log.get("track_storage_symlink_component", ""), "track_log track_storage_symlink_component"):
        fail("pre-departure status snapshot JSON track_log storage path contains a symlink")
    validate_track_log_paths(track_log)
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


def validate_snapshot_manifest_row(
    check_rows: dict[str, dict[str, object]],
    *,
    config: dict[str, object],
    manifest: object,
) -> None:
    row = check_rows.get("Manifest")
    if not isinstance(row, dict):
        fail("pre-departure status snapshot JSON missing Manifest readiness row")
    data = row.get("data")
    if not isinstance(data, dict):
        fail("pre-departure status snapshot JSON Manifest row has no structured data")
    if not isinstance(manifest, dict):
        fail("pre-departure status snapshot JSON Manifest row has no top-level manifest summary")
    chart_output = snapshot_absolute_path(config.get("chart_output", ""), "config chart_output")
    configured_path = snapshot_absolute_path(data.get("configured_path", ""), "Manifest configured path")
    if configured_path != chart_output:
        fail("pre-departure status snapshot JSON Manifest configured path does not match config chart_output")
    manifest_path = snapshot_absolute_path(data.get("path", ""), "Manifest path")
    if manifest_path != str(Path(chart_output) / "noaa-navionics-manifest.json"):
        fail("pre-departure status snapshot JSON Manifest path does not match config chart_output")
    if manifest_path != snapshot_absolute_path(manifest.get("path", ""), "manifest summary path"):
        fail("pre-departure status snapshot JSON Manifest path does not match manifest summary")
    for row_field, summary_field in (
        ("created_at", "created_at"),
        ("created_at_source", "created_at_source"),
        ("package", "package"),
        ("package_filename", "package_filename"),
        ("package_url", "url"),
        ("download_path", "download_path"),
        ("download_url", "download_url"),
        ("sha256", "sha256"),
        ("extract_path", "extract_path"),
    ):
        row_value = snapshot_text(data.get(row_field, ""), f"Manifest {row_field}")
        summary_value = snapshot_text(manifest.get(summary_field, ""), f"manifest summary {summary_field}")
        if row_value != summary_value:
            fail(f"pre-departure status snapshot JSON Manifest {row_field} does not match manifest summary")
    created_at_source = snapshot_text(data.get("created_at_source", ""), "Manifest created_at_source")
    if created_at_source not in {"download", "previous-manifest"}:
        fail("pre-departure status snapshot JSON Manifest created_at_source is not verified")
    normalized_chart_output = os.path.normpath(chart_output)
    for row_field, label in (
        ("download_path", "Manifest download path"),
        ("extract_path", "Manifest extract path"),
    ):
        manifest_storage_path = snapshot_absolute_path(data.get(row_field, ""), label)
        normalized_storage_path = os.path.normpath(manifest_storage_path)
        try:
            storage_common = os.path.commonpath([normalized_storage_path, normalized_chart_output])
        except ValueError:
            storage_common = ""
        if normalized_storage_path == normalized_chart_output or storage_common != normalized_chart_output:
            if row_field == "download_path":
                fail("pre-departure status snapshot JSON Manifest download path is outside chart_output")
            fail("pre-departure status snapshot JSON Manifest extract path is outside chart_output")
    parse_snapshot_timestamp(data.get("created_at"), "Manifest created_at")
    download_bytes = positive_status_int(data.get("download_bytes"))
    summary_download_bytes = positive_status_int(manifest.get("download_bytes"))
    if download_bytes is None:
        fail("pre-departure status snapshot JSON Manifest download byte count is not positive")
    if summary_download_bytes is not None and download_bytes != summary_download_bytes:
        fail("pre-departure status snapshot JSON Manifest download byte count does not match manifest summary")
    enc_cell_count = positive_status_int(data.get("enc_cell_count"))
    actual_enc_cell_count = positive_status_int(data.get("actual_enc_cell_count"))
    summary_enc_cell_count = positive_status_int(manifest.get("enc_cell_count"))
    summary_actual_enc_cell_count = positive_status_int(manifest.get("actual_enc_cell_count"))
    if enc_cell_count is None:
        fail("pre-departure status snapshot JSON Manifest has no ENC cells")
    if actual_enc_cell_count is None:
        fail("pre-departure status snapshot JSON Manifest actual ENC cell count is not positive")
    if enc_cell_count is not None and actual_enc_cell_count is not None and enc_cell_count != actual_enc_cell_count:
        fail("pre-departure status snapshot JSON Manifest actual ENC cell count does not match recorded count")
    if enc_cell_count is not None and summary_enc_cell_count is not None and enc_cell_count != summary_enc_cell_count:
        fail("pre-departure status snapshot JSON Manifest ENC cell count does not match manifest summary")
    if (
        actual_enc_cell_count is not None
        and summary_actual_enc_cell_count is not None
        and actual_enc_cell_count != summary_actual_enc_cell_count
    ):
        fail("pre-departure status snapshot JSON Manifest actual ENC cell count does not match manifest summary")


def validate_snapshot_storage_rows(check_rows: dict[str, dict[str, object]], *, config: dict[str, object]) -> None:
    chart_output = snapshot_absolute_path(config.get("chart_output", ""), "config chart_output")
    track_output = snapshot_absolute_path(config.get("track_output", ""), "config track_output")
    expected_paths = {"Disk": chart_output}
    if track_output != chart_output:
        expected_paths["Track Disk"] = track_output

    for row_name, expected_path in expected_paths.items():
        row = check_rows.get(row_name)
        if not isinstance(row, dict):
            fail(f"pre-departure status snapshot JSON missing {row_name} readiness row")
        data = row.get("data")
        if not isinstance(data, dict):
            fail(f"pre-departure status snapshot JSON {row_name} row has no structured data")
        configured_path = snapshot_absolute_path(data.get("configured_path", ""), f"{row_name} configured path")
        checked_path = snapshot_absolute_path(data.get("checked_path", ""), f"{row_name} checked path")
        if configured_path != expected_path:
            fail(f"pre-departure status snapshot JSON {row_name} configured path does not match config")
        if data.get("exists") is not True:
            fail(f"pre-departure status snapshot JSON {row_name} checked path does not exist")
        if data.get("is_directory") is not True:
            fail(f"pre-departure status snapshot JSON {row_name} checked path is not a directory")
        if str(data.get("storage_symlink_component", "")).strip():
            fail(f"pre-departure status snapshot JSON {row_name} storage path contains a symlink")
        if data.get("missing_removable_mount") is True:
            fail(f"pre-departure status snapshot JSON {row_name} removable storage is not mounted")
        uid = data.get("uid")
        expected_uid = data.get("expected_uid")
        if (
            isinstance(uid, bool)
            or isinstance(expected_uid, bool)
            or not isinstance(uid, int)
            or not isinstance(expected_uid, int)
            or uid != expected_uid
        ):
            fail(f"pre-departure status snapshot JSON {row_name} storage owner is invalid")
        mode_text = str(data.get("mode", "")).strip()
        try:
            mode = int(mode_text, 8)
        except ValueError:
            fail(f"pre-departure status snapshot JSON {row_name} storage mode is invalid")
        if mode & 0o022:
            fail(f"pre-departure status snapshot JSON {row_name} storage is group/world writable")
        min_free_gb = finite_status_float(data.get("min_free_gb"))
        free_gb = finite_status_float(data.get("free_gb"))
        if min_free_gb is None or min_free_gb <= 0.0:
            fail(f"pre-departure status snapshot JSON {row_name} missing minimum free-space threshold")
        if free_gb is None or free_gb < 0.0:
            fail(f"pre-departure status snapshot JSON {row_name} missing finite free-space measurement")
        if min_free_gb is not None and free_gb is not None and free_gb < min_free_gb:
            fail(f"pre-departure status snapshot JSON {row_name} free space is below threshold")
        total_inodes = data.get("total_inodes")
        free_inodes = data.get("free_inodes")
        if isinstance(total_inodes, bool) or not isinstance(total_inodes, int) or total_inodes < 0:
            fail(f"pre-departure status snapshot JSON {row_name} missing inode capacity measurement")
        if isinstance(free_inodes, bool) or not isinstance(free_inodes, int) or free_inodes < 0:
            fail(f"pre-departure status snapshot JSON {row_name} missing free inode measurement")
        if isinstance(total_inodes, int) and total_inodes > 0 and isinstance(free_inodes, int) and free_inodes <= 0:
            fail(f"pre-departure status snapshot JSON {row_name} has no free inodes")
        if data.get("writable") is not True:
            fail(f"pre-departure status snapshot JSON {row_name} storage is not writable")


def validate_snapshot_chart_rows(check_rows: dict[str, dict[str, object]], *, config: dict[str, object]) -> None:
    chart_output = snapshot_absolute_path(config.get("chart_output", ""), "config chart_output")

    charts_row = check_rows.get("Charts")
    if not isinstance(charts_row, dict):
        fail("pre-departure status snapshot JSON missing Charts readiness row")
    charts_data = charts_row.get("data")
    if not isinstance(charts_data, dict):
        fail("pre-departure status snapshot JSON Charts row has no structured data")
    configured_path = snapshot_absolute_path(charts_data.get("configured_path", ""), "Charts path")
    if configured_path != chart_output:
        fail("pre-departure status snapshot JSON Charts path does not match config chart_output")
    if charts_data.get("exists") is not True:
        fail("pre-departure status snapshot JSON Charts path does not exist")
    if str(charts_data.get("storage_symlink_component", "")).strip():
        fail("pre-departure status snapshot JSON Charts path contains a symlink")
    if charts_data.get("has_extracted_enc_cells") is not True:
        fail("pre-departure status snapshot JSON Charts found no extracted ENC cells")
    if charts_data.get("has_unextracted_zips") is not False:
        fail("pre-departure status snapshot JSON Charts found unextracted ZIP chart artifacts")
    zip_samples = charts_data.get("zip_samples")
    if not isinstance(zip_samples, list) or zip_samples:
        fail("pre-departure status snapshot JSON Charts ZIP sample list is not empty")
    enc_cell_samples = charts_data.get("enc_cell_samples")
    if not isinstance(enc_cell_samples, list) or not enc_cell_samples:
        fail("pre-departure status snapshot JSON Charts has no ENC cell sample paths")
    if any(not Path(snapshot_text(sample, "Charts ENC cell sample path")).is_absolute() for sample in enc_cell_samples):
        fail("pre-departure status snapshot JSON Charts ENC cell sample path is not absolute")
    normalized_chart_output = os.path.normpath(chart_output)
    for sample in enc_cell_samples:
        normalized_sample = os.path.normpath(snapshot_text(sample, "Charts ENC cell sample path"))
        try:
            sample_common = os.path.commonpath([normalized_sample, normalized_chart_output])
        except ValueError:
            sample_common = ""
        if normalized_sample == normalized_chart_output or sample_common != normalized_chart_output:
            fail("pre-departure status snapshot JSON Charts ENC cell sample path is outside chart_output")

    debris_row = check_rows.get("Chart Update Debris")
    if not isinstance(debris_row, dict):
        fail("pre-departure status snapshot JSON missing Chart Update Debris readiness row")
    debris_data = debris_row.get("data")
    if not isinstance(debris_data, dict):
        fail("pre-departure status snapshot JSON Chart Update Debris row has no structured data")
    configured_path = snapshot_absolute_path(debris_data.get("configured_path", ""), "Chart Update Debris path")
    if configured_path != chart_output:
        fail("pre-departure status snapshot JSON Chart Update Debris path does not match config chart_output")
    if str(debris_data.get("storage_symlink_component", "")).strip():
        fail("pre-departure status snapshot JSON Chart Update Debris path contains a symlink")
    debris_count = debris_data.get("debris_count")
    if isinstance(debris_count, bool) or not isinstance(debris_count, int) or debris_count != 0:
        fail("pre-departure status snapshot JSON Chart Update Debris found stale update debris")
    debris = debris_data.get("debris")
    if not isinstance(debris, list) or debris:
        fail("pre-departure status snapshot JSON Chart Update Debris debris list is not empty")
    if debris_data.get("clean") is not True:
        fail("pre-departure status snapshot JSON Chart Update Debris did not prove a clean chart directory")

    opencpn_row = check_rows.get("OpenCPN Charts")
    if not isinstance(opencpn_row, dict):
        fail("pre-departure status snapshot JSON missing OpenCPN Charts readiness row")
    opencpn_data = opencpn_row.get("data")
    if not isinstance(opencpn_data, dict):
        fail("pre-departure status snapshot JSON OpenCPN Charts row has no structured data")
    chart_dir = snapshot_absolute_path(opencpn_data.get("chart_dir", ""), "OpenCPN Charts chart directory")
    if chart_dir != chart_output:
        fail("pre-departure status snapshot JSON OpenCPN Charts chart directory does not match config chart_output")
    snapshot_absolute_path(opencpn_data.get("config_path", ""), "OpenCPN Charts config path")
    if opencpn_data.get("config_exists") is not True:
        fail("pre-departure status snapshot JSON OpenCPN Charts config does not exist")
    if opencpn_data.get("chart_dir_exists") is not True:
        fail("pre-departure status snapshot JSON OpenCPN Charts chart directory does not exist")
    if opencpn_data.get("configured") is not True:
        fail("pre-departure status snapshot JSON OpenCPN Charts did not prove configured chart directory")
    chart_directories = opencpn_data.get("chart_directories")
    if not isinstance(chart_directories, list) or not chart_directories:
        fail("pre-departure status snapshot JSON OpenCPN Charts has no parsed chart directories")
    parsed_chart_directories = [snapshot_text(directory, "OpenCPN Charts parsed directory") for directory in chart_directories]
    if not any(directory == chart_output for directory in parsed_chart_directories):
        fail("pre-departure status snapshot JSON OpenCPN Charts parsed directories do not include configured chart output")


def normalize_snapshot_gpsd_host(value: object) -> str:
    host = str(value).strip().lower()
    return "127.0.0.1" if host in {"localhost", "::1"} else host


def validate_snapshot_gpsd_rows(check_rows: dict[str, dict[str, object]], *, config: dict[str, object]) -> None:
    expected_device = str(config.get("gps_device", "")).strip()
    if not expected_device:
        fail("pre-departure status snapshot JSON missing config gps_device")
    expected_host = normalize_snapshot_gpsd_host(snapshot_text(config.get("gpsd_host", ""), "config gpsd_host"))
    if expected_host not in {"127.0.0.1", "0.0.0.0"}:
        fail("pre-departure status snapshot JSON config gpsd_host is not local")
    expected_port = config.get("gpsd_port")
    if isinstance(expected_port, bool) or not isinstance(expected_port, int) or not (1 <= expected_port <= 65535):
        fail("pre-departure status snapshot JSON config gpsd_port is invalid")

    opencpn_row = check_rows.get("OpenCPN GPSD")
    if not isinstance(opencpn_row, dict):
        fail("pre-departure status snapshot JSON missing OpenCPN GPSD readiness row")
    opencpn_data = opencpn_row.get("data")
    if not isinstance(opencpn_data, dict):
        fail("pre-departure status snapshot JSON OpenCPN GPSD row has no structured data")
    snapshot_absolute_path(opencpn_data.get("config_path", ""), "OpenCPN GPSD config path")
    if opencpn_data.get("config_exists") is not True:
        fail("pre-departure status snapshot JSON OpenCPN GPSD config does not exist")
    if normalize_snapshot_gpsd_host(opencpn_data.get("expected_host", "")) != expected_host:
        fail("pre-departure status snapshot JSON OpenCPN GPSD host does not match config gpsd_host")
    if opencpn_data.get("expected_port") != expected_port:
        fail("pre-departure status snapshot JSON OpenCPN GPSD port does not match config gpsd_port")
    if opencpn_data.get("configured") is not True:
        fail("pre-departure status snapshot JSON OpenCPN GPSD did not prove configured endpoint")
    connections = opencpn_data.get("enabled_gpsd_connections")
    if not isinstance(connections, list) or not connections:
        fail("pre-departure status snapshot JSON OpenCPN GPSD has no parsed enabled GPSD connections")
    if not any(
        isinstance(connection, dict)
        and normalize_snapshot_gpsd_host(connection.get("host", "")) == expected_host
        and connection.get("port") == expected_port
        for connection in connections
    ):
        fail("pre-departure status snapshot JSON OpenCPN GPSD parsed connections do not include configured endpoint")
    unexpected = opencpn_data.get("unexpected_connections")
    if not isinstance(unexpected, list):
        fail("pre-departure status snapshot JSON OpenCPN GPSD unexpected connection list was not parsed")
    if unexpected:
        fail("pre-departure status snapshot JSON OpenCPN GPSD found unexpected enabled GPSD connections")

    gpsd_config_row = check_rows.get("GPSD Config")
    if not isinstance(gpsd_config_row, dict):
        fail("pre-departure status snapshot JSON missing GPSD Config readiness row")
    gpsd_config_data = gpsd_config_row.get("data")
    if not isinstance(gpsd_config_data, dict):
        fail("pre-departure status snapshot JSON GPSD Config row has no structured data")
    if snapshot_text(gpsd_config_data.get("path", ""), "GPSD Config path") != "/etc/default/gpsd":
        fail("pre-departure status snapshot JSON GPSD Config path is not /etc/default/gpsd")
    if gpsd_config_data.get("exists") is not True:
        fail("pre-departure status snapshot JSON GPSD Config path does not exist")
    if gpsd_config_data.get("is_symlink") is not False:
        fail("pre-departure status snapshot JSON GPSD Config path is a symlink")
    if snapshot_text(gpsd_config_data.get("directory_symlink_component", ""), "GPSD Config directory_symlink_component"):
        fail("pre-departure status snapshot JSON GPSD Config directory contains a symlink")
    if gpsd_config_data.get("is_regular") is not True:
        fail("pre-departure status snapshot JSON GPSD Config path is not a regular file")
    if gpsd_config_data.get("expected_device") != expected_device:
        fail("pre-departure status snapshot JSON GPSD Config expected device does not match config")
    devices = gpsd_config_data.get("devices")
    if devices != [expected_device]:
        fail("pre-departure status snapshot JSON GPSD Config devices do not match configured GPS device")
    if gpsd_config_data.get("start_daemon") != "true":
        fail("pre-departure status snapshot JSON GPSD Config START_DAEMON is not true")
    if gpsd_config_data.get("usbauto") != "false":
        fail("pre-departure status snapshot JSON GPSD Config USBAUTO is not false")
    if "-n" not in gpsd_config_data.get("gpsd_options", []):
        fail("pre-departure status snapshot JSON GPSD Config does not enable immediate polling")

    chrony_row = check_rows.get("Chrony Config")
    if not isinstance(chrony_row, dict):
        fail("pre-departure status snapshot JSON missing Chrony Config readiness row")
    chrony_data = chrony_row.get("data")
    if not isinstance(chrony_data, dict):
        fail("pre-departure status snapshot JSON Chrony Config row has no structured data")
    if chrony_data.get("is_raspberry_pi") is False and chrony_data.get("skipped") is True:
        fail("pre-departure status snapshot JSON Chrony Config records non-Pi diagnostic skip")
    if snapshot_text(chrony_data.get("path", ""), "Chrony Config path") != "/etc/chrony/chrony.conf":
        fail("pre-departure status snapshot JSON Chrony Config path is not /etc/chrony/chrony.conf")
    if chrony_data.get("exists") is not True:
        fail("pre-departure status snapshot JSON Chrony Config path does not exist")
    if chrony_data.get("is_symlink") is not False:
        fail("pre-departure status snapshot JSON Chrony Config path is a symlink")
    if snapshot_text(chrony_data.get("directory_symlink_component", ""), "Chrony Config directory_symlink_component"):
        fail("pre-departure status snapshot JSON Chrony Config directory contains a symlink")
    if chrony_data.get("is_regular") is not True:
        fail("pre-departure status snapshot JSON Chrony Config path is not a regular file")
    if chrony_data.get("managed_refclock_present") is not True:
        fail("pre-departure status snapshot JSON Chrony Config is missing managed GPSD SHM refclock")
    if snapshot_text(chrony_data.get("refclock_line", ""), "Chrony Config refclock_line") != "refclock SHM 0 offset 0.5 delay 0.1 refid GPS":
        fail("pre-departure status snapshot JSON Chrony Config refclock line is not the managed GPSD SHM source")

    time_row = check_rows.get("GPS Time Source")
    if not isinstance(time_row, dict):
        fail("pre-departure status snapshot JSON missing GPS Time Source readiness row")
    time_data = time_row.get("data")
    if not isinstance(time_data, dict):
        fail("pre-departure status snapshot JSON GPS Time Source row has no structured data")
    if time_data.get("is_raspberry_pi") is False and time_data.get("skipped") is True:
        fail("pre-departure status snapshot JSON GPS Time Source records non-Pi diagnostic skip")
    if time_data.get("is_raspberry_pi") is not True:
        fail("pre-departure status snapshot JSON GPS Time Source did not identify a Raspberry Pi check")
    if time_data.get("chronyc_available") is not True:
        fail("pre-departure status snapshot JSON GPS Time Source did not validate chronyc availability")
    if not isinstance(time_data.get("gps_lines"), list) or not time_data.get("gps_lines"):
        fail("pre-departure status snapshot JSON GPS Time Source has no GPS refclock lines")
    if not isinstance(time_data.get("usable_lines"), list) or not time_data.get("usable_lines"):
        fail("pre-departure status snapshot JSON GPS Time Source has no selected or combined GPS refclock")
    if time_data.get("selected_or_combined") is not True:
        fail("pre-departure status snapshot JSON GPS Time Source did not prove selected or combined GPS time")


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

    config_path = snapshot_text(status.get("config_path", ""), "config_path")
    if not config_path:
        fail("pre-departure status snapshot JSON missing config_path")
    if not Path(config_path).is_absolute():
        fail("pre-departure status snapshot JSON config_path is not absolute")
    config = status.get("config")
    if not isinstance(config, dict):
        fail("pre-departure status snapshot JSON missing config section")
    gps_mode = snapshot_text(config.get("gps_mode", ""), "config gps_mode").lower()
    if gps_mode not in {"gpsd", "serial"}:
        fail(
            "pre-departure status snapshot JSON has invalid gps_mode: "
            + (gps_mode or "<missing>")
        )
    gps_device = snapshot_text(config.get("gps_device", ""), "config gps_device")
    if not gps_device:
        fail("pre-departure status snapshot JSON missing config gps_device")
    if not stable_snapshot_gps_device_path(gps_device):
        if gps_device.startswith("/dev/ttyUSB") or gps_device.startswith("/dev/ttyACM"):
            fail(
                "pre-departure status snapshot JSON config gps_device is volatile; "
                "use /dev/serial/by-id/... or /dev/serial/by-path/... instead"
            )
        fail("pre-departure status snapshot JSON config gps_device must be /dev/serial/by-id/..., /dev/serial/by-path/..., /dev/serial0, /dev/serial1, or /dev/gps")
    gps_baud = config.get("gps_baud")
    if isinstance(gps_baud, bool) or not isinstance(gps_baud, int) or gps_baud not in GPS_BAUD_RATES:
        fail("pre-departure status snapshot JSON config gps_baud is invalid")
    chart_output = snapshot_text(config.get("chart_output", ""), "config chart_output")
    if not chart_output:
        fail("pre-departure status snapshot JSON missing config chart_output")
    if not Path(chart_output).is_absolute():
        fail("pre-departure status snapshot JSON config chart_output is not absolute")
    configured_track_output = snapshot_text(config.get("track_output", ""), "config track_output")
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
    track_output = snapshot_text(track_log.get("track_output", ""), "track_log track_output")
    if not track_output:
        fail("pre-departure status snapshot JSON missing track_log track_output")
    if track_output != configured_track_output:
        fail("pre-departure status snapshot JSON track_log track_output does not match config track_output")
    tracks_dir = snapshot_text(track_log.get("tracks_dir", ""), "track_log tracks_dir")
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
    validate_snapshot_autostart(status)
    validate_snapshot_status_launcher(status)
    validate_snapshot_mob_launcher(status)
    validate_snapshot_storage_rows(check_rows, config=config)
    validate_snapshot_chart_rows(check_rows, config=config)
    validate_snapshot_manifest_row(check_rows, config=config, manifest=status.get("manifest"))
    validate_snapshot_gps_row(check_rows, gps_mode=gps_mode, gps_fix=gps_fix)
    if gps_mode == "gpsd":
        validate_snapshot_gpsd_rows(check_rows, config=config)
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


def verify_checksum_manifest(recovery_dir: Path, recovery_fd: int, archive_paths: list[Path]) -> None:
    entries = read_checksum_manifest(recovery_dir, recovery_fd)
    expected_names = {path.name for path in archive_paths}
    actual_names = set(entries)
    missing = sorted(expected_names - actual_names)
    extra = sorted(actual_names - expected_names)
    if missing:
        fail(f"checksum manifest is missing archive(s): {', '.join(missing)}")
    if extra:
        fail(f"checksum manifest lists unexpected archive(s): {', '.join(extra)}")
    for archive_path in archive_paths:
        actual_digest = hash_private_archive(archive_path, recovery_fd)
        expected_digest = entries[archive_path.name]
        if actual_digest != expected_digest:
            fail(f"checksum mismatch for {archive_path.name}: expected {expected_digest}, got {actual_digest}")


def find_archive(recovery_dir: Path, recovery_fd: int, spec: dict[str, object]) -> Path:
    pattern = str(spec["pattern"])
    try:
        names = os.listdir(recovery_fd)
    except OSError as exc:
        fail(f"could not list recovery directory {recovery_dir}: {exc}")
    matches = sorted(
        recovery_dir / name
        for name in names
        if "/" not in name and fnmatch.fnmatchcase(name, pattern)
    )
    if not matches:
        fail(f"missing {spec['label']} archive matching {pattern}")
    if len(matches) > 1:
        fail(f"expected one {spec['label']} archive, found {len(matches)}")
    return matches[0]


def main() -> None:
    recovery_dir = Path(sys.argv[1])
    recovery_fd = open_trusted_recovery_directory(recovery_dir)
    try:
        summaries = []
        archive_paths = []
        for spec in ARCHIVES:
            archive_path = find_archive(recovery_dir, recovery_fd, spec)
            file_count = inspect_archive(archive_path, spec, recovery_fd)
            summaries.append((str(spec["label"]), archive_path.name, file_count))
            archive_paths.append(archive_path)
        verify_checksum_manifest(recovery_dir, recovery_fd, archive_paths)
        verified_pre_departure_status = verify_optional_pre_departure_status(recovery_dir, recovery_fd)
    finally:
        os.close(recovery_fd)

    print(f"Verified Pi recovery exports: {recovery_dir}")
    for label, name, file_count in summaries:
        print(f"- {label}: {name} ({file_count} regular file(s))")
    if verified_pre_departure_status:
        print(f"- pre-departure status: {PRE_DEPARTURE_STATUS_NAME} (checksum verified)")


main()
PY
