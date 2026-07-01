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
from pathlib import Path, PurePosixPath
import json
import os
import stat
import sys
import tarfile


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
    },
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
                    elif not member.isdir():
                        fail(f"{archive_path.name} contains unsupported member type: {member.name}")

                if "README.txt" not in names:
                    fail(f"{archive_path.name} is missing README.txt")

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

                if regular_file_count <= 0:
                    fail(f"{archive_path.name} does not contain any regular files")
                return regular_file_count
    except (OSError, tarfile.TarError) as exc:
        fail(f"{archive_path.name} is not a readable gzip tar archive: {exc}")
    finally:
        if fd >= 0:
            os.close(fd)


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
    for spec in ARCHIVES:
        archive_path = find_archive(recovery_dir, spec)
        file_count = inspect_archive(archive_path, spec)
        summaries.append((str(spec["label"]), archive_path.name, file_count))

    print(f"Verified Pi recovery exports: {recovery_dir}")
    for label, name, file_count in summaries:
        print(f"- {label}: {name} ({file_count} regular file(s))")


main()
PY
