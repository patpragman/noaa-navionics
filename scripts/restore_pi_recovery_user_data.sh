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
if [[ -L "$recovery_dir" ]]; then
  echo "Recovery directory must not be a symlink: $recovery_dir" >&2
  exit 2
fi
if [[ ! -d "$recovery_dir" ]]; then
  echo "Recovery directory must be a real directory: $recovery_dir" >&2
  exit 2
fi
python3_cmd="$(require_local_command python3)"

NOAA_NAVIONICS_RESTORE_APPLY="$apply" \
NOAA_NAVIONICS_RESTORE_OVERWRITE="$overwrite" \
"$python3_cmd" - "$recovery_dir" <<'PY'
from configparser import ConfigParser
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Optional
import io
import json
import os
import stat
import sys
import tarfile
import tempfile


ARCHIVES = [
    ("settings", "noaa-navionics-pi-settings-*.tgz", "file_count"),
    ("opencpn", "noaa-navionics-pi-opencpn-*.tgz", "file_count"),
    ("tracks", "noaa-navionics-pi-tracks-*.tgz", "track_count"),
    ("support", "noaa-navionics-pi-support-*.tgz", None),
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


def inspect_archive(archive_path: Path, required_count_key: Optional[str], *, load_contents: bool = True) -> dict[str, bytes]:
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

    files: dict[str, bytes] = {}
    names: set[str] = set()
    regular_file_count = 0
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
                    if member.issym() or member.islnk() or member.isdev():
                        fail(f"{archive_path.name} contains unsupported non-regular member: {member.name}")
                    if member.isdir():
                        continue
                    if not member.isfile():
                        fail(f"{archive_path.name} contains unsupported member type: {member.name}")
                    if not normalized:
                        fail(f"{archive_path.name} contains blank file member name")
                    if normalized in names:
                        fail(f"{archive_path.name} contains duplicate member: {normalized}")
                    names.add(normalized)
                    regular_file_count += 1
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

    if "README.txt" not in names:
        fail(f"{archive_path.name} is missing README.txt")
    if required_count_key is not None:
        if "manifest.json" not in names:
            fail(f"{archive_path.name} is missing manifest.json")
        if "manifest.json" not in files:
            fail(f"{archive_path.name} manifest.json was not loaded")
        try:
            manifest = json.loads(files["manifest.json"].decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            fail(f"{archive_path.name} manifest.json is invalid JSON: {exc}")
        count = manifest.get(required_count_key)
        if not isinstance(count, int) or count <= 0:
            fail(f"{archive_path.name} manifest {required_count_key} must be a positive integer")
    if regular_file_count <= 0:
        fail(f"{archive_path.name} does not contain any regular files")
    return files


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
    result = {}
    for label, pattern, required_count_key in ARCHIVES:
        matches = sorted(recovery_dir.glob(pattern))
        if not matches:
            fail(f"missing {label} archive matching {pattern}")
        if len(matches) > 1:
            fail(f"expected one {label} archive, found {len(matches)}")
        result[label] = inspect_archive(
            matches[0],
            required_count_key,
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


def read_trusted_restore_file(path: Path, label: str) -> bytes:
    reject_unsafe_target(path, label)
    try:
        expected_stat = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        fail(f"could not inspect {label} {path}: {exc}")
    if not stat.S_ISREG(expected_stat.st_mode):
        fail(f"{label} is not a regular file: {path}")
    if expected_stat.st_uid != os.getuid():
        fail(f"{label} {path} is owned by uid {expected_stat.st_uid}, expected {os.getuid()}")
    mode = stat.S_IMODE(expected_stat.st_mode)
    if mode & 0o022:
        fail(f"{label} {path} has permissions {mode:04o}, expected no group/other write bits")

    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        fail(f"could not open {label} {path}: {exc}")
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (expected_stat.st_dev, expected_stat.st_ino):
            fail(f"{label} changed while opening: {path}")
        if not stat.S_ISREG(opened.st_mode):
            fail(f"{label} is not a regular file when opened: {path}")
        if opened.st_uid != os.getuid():
            fail(f"{label} {path} is owned by uid {opened.st_uid}, expected {os.getuid()}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened_mode & 0o022:
            fail(f"{label} {path} has permissions {opened_mode:04o}, expected no group/other write bits")
        chunks = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def validate_private_file_content(path: Path, expected_data: bytes, label: str) -> None:
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
    if mode != 0o600:
        fail(f"{label} {path} has permissions {mode:04o}, expected 0600")

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
        if opened_mode != 0o600:
            fail(f"{label} {path} has permissions {opened_mode:04o}, expected 0600")
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


def backup_existing(path: Path, backup_root: Path) -> None:
    if not path.exists():
        return
    source_data = read_trusted_restore_file(path, "backup source")
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


def validate_promoted_restore_file(path: Path, expected_data: bytes) -> None:
    validate_private_file_content(path, expected_data, "promoted restored file")


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


def write_file_atomic(path: Path, data: bytes, backup_root: Optional[Path], *, overwrite: bool, apply: bool) -> str:
    reject_unsafe_target(path, "restore")
    if path.exists() and not overwrite:
        fail(f"restore target already exists; use --overwrite to replace it: {path}")
    if not apply:
        return "would restore"
    ensure_private_directory(path.parent, apply=True)
    if backup_root is not None:
        backup_existing(path, backup_root)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, path)
        validate_promoted_restore_file(path, data)
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


def safe_track_output_from_config(config_text: str, home: Path) -> Path:
    parser = ConfigParser()
    parser.read_string(config_text)
    chart_output = parser.get("charts", "output", fallback="~/charts/noaa-enc")
    track_output = parser.get("tracking", "output", fallback=chart_output)
    expanded = Path(os.path.expanduser(track_output))
    if not expanded.is_absolute():
        fail(f"restored tracking.output is not absolute after expansion: {track_output}")
    if ".." in expanded.parts:
        fail(f"restored tracking.output must not contain parent-directory components: {track_output}")

    resolved_home = home.resolve()
    if expanded == resolved_home or expanded in resolved_home.parents:
        fail(f"restored tracking.output is too broad: {expanded}")
    if expanded.is_relative_to(resolved_home):
        first = expanded.relative_to(resolved_home).parts[0]
        if first in {".cache", ".config", ".local"}:
            fail(f"restored tracking.output must not be inside home {first}: {expanded}")
        return expanded
    forbidden_roots = {Path("/"), Path("/boot"), Path("/dev"), Path("/etc"), Path("/opt"), Path("/proc"), Path("/root"), Path("/sys"), Path("/tmp"), Path("/usr"), Path("/var")}
    if expanded in forbidden_roots or any(root in expanded.parents for root in forbidden_roots if root != Path("/")):
        fail(f"restored tracking.output is not safe storage: {expanded}")
    allowed_roots = (Path("/media"), Path("/mnt"), Path("/run/media"))
    for root in allowed_roots:
        if expanded == root:
            fail(f"restored tracking.output is too broad: {expanded}")
        if root in expanded.parents:
            return expanded
    fail(f"restored tracking.output must be under the Pi home, /media, /mnt, or /run/media: {expanded}")


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

    planned: list[tuple[str, Path, bytes]] = [
        ("settings", home / ".config" / "noaa-navionics" / "config.ini", config_bytes),
    ]
    launcher = settings.get("noaa-navionics/launcher.env")
    if launcher is not None:
        planned.append(("settings", home / ".config" / "noaa-navionics" / "launcher.env", launcher))

    for name, data in sorted(opencpn.items()):
        relative = opencpn_restore_relative(name)
        if relative is None:
            continue
        planned.append(("opencpn", home / ".opencpn" / relative, data))

    for name, data in sorted(tracks.items()):
        if name in {"README.txt", "manifest.json"}:
            continue
        parts = PurePosixPath(name).parts
        if len(parts) != 2 or parts[0] != "tracks" or not parts[1].endswith(".gpx"):
            fail(f"tracks archive contains unexpected restore member: {name}")
        planned.append(("tracks", track_dir / parts[1], data))

    if not apply:
        print("Dry run only. Re-run with --apply to write files.")

    restored = 0
    for category, target, data in planned:
        action = write_file_atomic(target, data, backup_root, overwrite=overwrite, apply=apply)
        restored += 1
        print(f"{action} {category}: {target}")

    if apply:
        print(f"Restored {restored} recovery user data file(s).")
        if backup_root is not None:
            print(f"Backed up replaced files under: {backup_root}")
        print("Re-run provisioning, then scripts/verify_pi.sh or scripts/dock_test_pi.sh before relying on the Pi.")


main()
PY
