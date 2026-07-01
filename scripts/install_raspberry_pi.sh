#!/usr/bin/env bash
set -euo pipefail
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_dir="${HOME}/.config/noaa-navionics"
systemd_user_dir="${HOME}/.config/systemd/user"
venv_dir="${HOME}/.local/share/noaa-navionics/venv"
data_dir="${HOME}/.local/share/noaa-navionics"
revision_file="${data_dir}/source-revision"

skip_apt=0
allow_non_pi=0
apt_get_cmd=""
sudo_cmd=""
python3_cmd=""

usage() {
  cat >&2 <<'EOF'
Usage: scripts/install_raspberry_pi.sh [options]

Options:
  --skip-apt        Do not install system packages
  --allow-non-pi   Allow development smoke tests on non-Raspberry Pi hosts
  --no-services    Accepted for deploy-script compatibility
  --skip-autologin Accepted for deploy-script compatibility

Installs NOAA Navionics into a private user virtual environment on the
Raspberry Pi. User services and desktop autostart are enabled later by
provisioning after GPSD, charts, and the onboard config are commissioned.
EOF
}

sync_paths() {
  "$python3_cmd" - "$@" <<'PY'
from pathlib import Path
import os
import stat
import sys

synced_dirs: set[Path] = set()
for arg in sys.argv[1:]:
    path = Path(arg).expanduser()
    try:
        initial = path.lstat()
    except OSError:
        continue
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if stat.S_ISLNK(initial.st_mode):
        synced_dirs.add(path.parent)
        continue
    if stat.S_ISDIR(initial.st_mode):
        try:
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow
            fd = os.open(path, flags)
        except OSError:
            synced_dirs.add(path.parent)
            continue
        try:
            opened = os.fstat(fd)
            if stat.S_ISDIR(opened.st_mode):
                os.fsync(fd)
        except OSError:
            pass
        finally:
            os.close(fd)
        synced_dirs.add(path)
        synced_dirs.add(path.parent)
        continue
    try:
        fd = os.open(path, os.O_RDONLY | nofollow)
    except OSError:
        continue
    try:
        opened = os.fstat(fd)
        if stat.S_ISREG(opened.st_mode):
            os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)
    synced_dirs.add(path.parent)
for directory in synced_dirs:
    try:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(directory, flags)
    except OSError:
        continue
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

sync_tree() {
  "$python3_cmd" - "$1" <<'PY'
from pathlib import Path
import os
import stat
import sys

root = Path(sys.argv[1]).expanduser()
if not root.exists():
    raise SystemExit(f"cannot sync missing tree: {root}")
if root.is_symlink():
    raise SystemExit(f"cannot sync symlinked tree: {root}")

def fsync_dir(path: Path) -> None:
    try:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
    except OSError:
        return
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

for current_root, dirnames, filenames in os.walk(root):
    current = Path(current_root)
    for filename in filenames:
        file_path = current / filename
        try:
            initial = file_path.lstat()
        except OSError:
            continue
        if not stat.S_ISREG(initial.st_mode):
            continue
        try:
            fd = os.open(file_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError:
            continue
        try:
            opened = os.fstat(fd)
            if stat.S_ISREG(opened.st_mode):
                os.fsync(fd)
        except OSError:
            pass
        finally:
            os.close(fd)
    for dirname in dirnames:
        directory_path = current / dirname
        if directory_path.is_symlink():
            continue
        fsync_dir(directory_path)
    fsync_dir(current)
fsync_dir(root.parent)
PY
}

reset_private_venv() {
  "$python3_cmd" - "$venv_dir" "$data_dir" <<'PY'
from pathlib import Path
import shutil
import sys

venv = Path(sys.argv[1]).expanduser()
data = Path(sys.argv[2]).expanduser()
try:
    venv_resolved = venv.resolve(strict=False)
    data_resolved = data.resolve(strict=False)
except OSError as exc:
    raise SystemExit(f"could not resolve private venv path: {exc}") from exc
if venv_resolved.name != "venv" or data_resolved.name != "noaa-navionics":
    raise SystemExit(f"refusing to remove unexpected venv path: {venv}")
try:
    venv_resolved.relative_to(data_resolved)
except ValueError as exc:
    raise SystemExit(f"refusing to remove venv outside data directory: {venv}") from exc
if venv.exists() or venv.is_symlink():
    if venv.is_symlink() or not venv.is_dir():
        raise SystemExit(f"refusing to remove non-directory private venv path: {venv}")
    if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):
        raise SystemExit(
            "private venv cleanup requires Python shutil.rmtree with symlink-attack resistance; "
            f"leaving existing private venv in place: {venv}"
        )
    shutil.rmtree(venv)
PY
}

write_source_revision() {
  local revision="$1"
  validate_user_install_path "$revision_file" "source revision file" regular
  "$python3_cmd" - "$revision_file" "$revision" <<'PY'
from pathlib import Path
import os
import sys
import tempfile

target = Path(sys.argv[1]).expanduser()
revision = sys.argv[2].strip() or "unknown"
target.parent.mkdir(parents=True, exist_ok=True)
tmp_path = None
try:
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=target.parent,
        prefix=f".{target.name}.",
        suffix=".part",
        delete=False,
    ) as handle:
        tmp_path = Path(handle.name)
        os.chmod(tmp_path, 0o600)
        handle.write(revision + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp_path, target)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(target.parent, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
finally:
    if tmp_path is not None:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
PY
}

validate_user_install_path() {
  local target="$1"
  local label="$2"
  local expected_kind="$3"
  "$python3_cmd" - "$target" "$label" "$expected_kind" <<'PY'
from pathlib import Path
import os
import sys

target = Path(sys.argv[1]).expanduser()
label = sys.argv[2]
expected_kind = sys.argv[3]
home = Path.home().resolve(strict=False)
expected_uid = os.getuid()

if expected_kind not in {"directory", "regular", "link"}:
    raise SystemExit(f"unsupported install path kind: {expected_kind}")

path_chain = []
cursor = target if expected_kind == "directory" else target.parent
while True:
    path_chain.append(cursor)
    if cursor == home or cursor == cursor.parent:
        break
    cursor = cursor.parent
if path_chain[-1] != home:
    raise SystemExit(f"{label} path must be under the installing user's home directory: {target}")

for path in path_chain:
    if path.is_symlink():
        raise SystemExit(f"{label} path contains a symlink: {path}")

try:
    resolved_target = target.resolve(strict=False)
except RuntimeError as exc:
    raise SystemExit(f"{label} path could not be resolved: {target}: {exc}") from exc
if resolved_target != home and home not in resolved_target.parents:
    raise SystemExit(f"{label} path must stay under the installing user's home directory: {target}")

for directory in path_chain:
    if not directory.exists():
        continue
    if not directory.is_dir():
        raise SystemExit(f"{label} parent is not a directory: {directory}")
    stat_result = directory.stat()
    mode = stat_result.st_mode & 0o777
    if stat_result.st_uid != expected_uid:
        raise SystemExit(
            f"{label} parent {directory} is owned by uid {stat_result.st_uid}, expected {expected_uid}"
        )
    if mode & 0o022:
        raise SystemExit(
            f"{label} parent {directory} has permissions {mode:04o}, expected no group/other write bits"
        )

if expected_kind == "directory":
    if target.exists() and not target.is_dir():
        raise SystemExit(f"{label} is not a directory: {target}")
elif expected_kind == "regular":
    if target.is_symlink():
        raise SystemExit(f"{label} is a symlink: {target}")
    if target.exists() and not target.is_file():
        raise SystemExit(f"{label} is not a regular file: {target}")
elif expected_kind == "link":
    if target.exists() and not target.is_symlink() and not target.is_file():
        raise SystemExit(f"{label} is not a replaceable file or symlink: {target}")

if expected_kind in {"regular", "link"} and target.exists() and not target.is_symlink():
    stat_result = target.stat()
    mode = stat_result.st_mode & 0o777
    if stat_result.st_uid != expected_uid:
        raise SystemExit(f"{label} {target} is owned by uid {stat_result.st_uid}, expected {expected_uid}")
    if mode & 0o022:
        raise SystemExit(f"{label} {target} has permissions {mode:04o}, expected no group/other write bits")
PY
}

ensure_private_directory() {
  local target="$1"
  local label="$2"
  validate_user_install_path "$target" "$label" directory
  mkdir -p "$target"
  validate_user_install_path "$target" "$label" directory
  chmod 0700 "$target"
  validate_user_install_path "$target" "$label" directory
  sync_paths "$target"
}

install_root_text_atomic() {
  local target="$1"
  local mode="$2"
  local text="$3"
  local sudo_cmd_value
  sudo_cmd_value="$(sudo_command)" || return 1
  "$sudo_cmd_value" "$python3_cmd" - "$target" "$mode" "$text" <<'PY'
from pathlib import Path
import os
import sys
import tempfile

target = Path(sys.argv[1])
mode = int(sys.argv[2], 8)
text = sys.argv[3]
parent = target.parent

def first_symlink_ancestor(path: Path):
    current = path.expanduser()
    for component in [current, *current.parents]:
        if component.is_symlink():
            return component
    return None

if target.is_symlink():
    raise SystemExit(f"root text target is a symlink: {target}")
if target.exists() and not target.is_file():
    raise SystemExit(f"root text target is not a regular file: {target}")
if parent.is_symlink():
    raise SystemExit(f"root text target directory is a symlink: {parent}")
symlink_component = first_symlink_ancestor(parent)
if symlink_component is not None:
    raise SystemExit(f"root text target directory path contains a symlink: {symlink_component}")

if parent.exists():
    if not parent.is_dir():
        raise SystemExit(f"root text target parent is not a directory: {parent}")
    parent_stat = parent.stat()
    parent_mode = parent_stat.st_mode & 0o777
    if parent_stat.st_uid != 0:
        raise SystemExit(f"root text target directory {parent} is owned by uid {parent_stat.st_uid}, expected root")
    if parent_mode & 0o022:
        raise SystemExit(
            f"root text target directory {parent} has permissions {parent_mode:04o}, "
            "expected no group/other write bits"
        )
else:
    ancestor = parent.parent
    if not ancestor.exists() or not ancestor.is_dir():
        raise SystemExit(f"root text target parent ancestor is not a directory: {ancestor}")
    ancestor_stat = ancestor.stat()
    ancestor_mode = ancestor_stat.st_mode & 0o777
    if ancestor_stat.st_uid != 0:
        raise SystemExit(
            f"root text target parent ancestor {ancestor} is owned by uid {ancestor_stat.st_uid}, expected root"
        )
    if ancestor_mode & 0o022:
        raise SystemExit(
            f"root text target parent ancestor {ancestor} has permissions {ancestor_mode:04o}, "
            "expected no group/other write bits"
        )
    parent.mkdir(parents=True, exist_ok=True)

if target.exists():
    target_stat = target.stat()
    target_mode = target_stat.st_mode & 0o777
    if target_stat.st_uid != 0:
        raise SystemExit(f"root text target {target} is owned by uid {target_stat.st_uid}, expected root")
    if target_mode & 0o022:
        raise SystemExit(
            f"root text target {target} has permissions {target_mode:04o}, expected no group/other write bits"
        )

tmp_path = None
try:
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=target.parent,
        prefix=f".{target.name}.",
        delete=False,
    ) as handle:
        tmp_path = Path(handle.name)
        handle.write(text)
        if not text.endswith("\n"):
            handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_path, mode)
    with tmp_path.open("rb") as handle:
        os.fsync(handle.fileno())
    os.replace(tmp_path, target)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(target.parent, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
finally:
    if tmp_path is not None:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
PY
}

cleanup_user_temp_path() {
  local path="$1"
  local label="$2"
  [[ -n "$path" ]] || return 0
  "$python3_cmd" - "$path" "$label" <<'PY'
from __future__ import annotations

from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1]).expanduser()
label = sys.argv[2]
nofollow = getattr(os, "O_NOFOLLOW", 0)

try:
    parent_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
except FileNotFoundError:
    raise SystemExit(0)
except OSError as exc:
    print(f"Could not open {label} directory for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

try:
    parent_stat = os.fstat(parent_fd)
    parent_mode = stat.S_IMODE(parent_stat.st_mode)
    if not stat.S_ISDIR(parent_stat.st_mode) or parent_stat.st_uid != os.getuid() or parent_mode & 0o022:
        print(f"{label} directory is not trusted for cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)

    try:
        before = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    if before.st_uid != os.getuid():
        print(f"{label} is not owned by the current user; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    if stat.S_ISREG(before.st_mode):
        if stat.S_IMODE(before.st_mode) & 0o022:
            print(f"{label} is group/world-writable; leaving it in place: {path}", file=sys.stderr)
            raise SystemExit(0)
        try:
            fd = os.open(path.name, os.O_RDONLY | nofollow, dir_fd=parent_fd)
        except FileNotFoundError:
            raise SystemExit(0)
        try:
            opened = os.fstat(fd)
        finally:
            os.close(fd)
        if not os.path.samestat(before, opened):
            print(f"{label} changed before cleanup; leaving it in place: {path}", file=sys.stderr)
            raise SystemExit(0)
    elif not stat.S_ISLNK(before.st_mode):
        print(f"{label} is not a regular file or symlink; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)

    try:
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    if not os.path.samestat(before, current):
        print(f"{label} changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    os.unlink(path.name, dir_fd=parent_fd)
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
PY
}

install_user_file_atomic() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local target_dir
  local target_name
  local tmp
  validate_user_install_path "$target" "installed user file" regular
  target_dir="$(dirname "$target")"
  target_name="$(basename "$target")"
  mkdir -p "$target_dir"
  validate_user_install_path "$target_dir" "installed user file directory" directory
  tmp="$(mktemp "${target_dir}/.${target_name}.XXXXXX")"
  if ! install -m "$mode" "$source" "$tmp"; then
    cleanup_user_temp_path "$tmp" "installed user file temporary path" || true
    return 1
  fi
  if ! sync_paths "$tmp"; then
    cleanup_user_temp_path "$tmp" "installed user file temporary path" || true
    return 1
  fi
  if ! validate_user_install_path "$target" "installed user file" regular; then
    cleanup_user_temp_path "$tmp" "installed user file temporary path" || true
    return 1
  fi
  if ! mv -f "$tmp" "$target"; then
    cleanup_user_temp_path "$tmp" "installed user file temporary path" || true
    return 1
  fi
  if ! verify_promoted_user_file "$source" "$target" "$mode" "installed user file"; then
    return 1
  fi
  sync_paths "$target"
}

verify_promoted_user_file() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local label="$4"
  validate_user_install_path "$target" "$label" regular
  "$python3_cmd" - "$source" "$target" "$mode" "$label" <<'PY'
from pathlib import Path
import os
import stat
import sys

source = Path(sys.argv[1]).expanduser()
target = Path(sys.argv[2]).expanduser()
expected_mode = int(sys.argv[3], 8)
label = sys.argv[4]
expected_uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)


def read_regular_nofollow(
    path: Path,
    description: str,
    *,
    expected_uid_value=None,
    expected_mode_value=None,
) -> bytes:
    try:
        initial = path.lstat()
    except OSError as exc:
        raise SystemExit(f"{description} is not accessible: {path}: {exc}") from exc
    if stat.S_ISLNK(initial.st_mode):
        raise SystemExit(f"{description} is a symlink: {path}")
    if not stat.S_ISREG(initial.st_mode):
        raise SystemExit(f"{description} is not a regular file: {path}")
    if expected_uid_value is not None and initial.st_uid != expected_uid_value:
        raise SystemExit(
            f"{description} {path} is owned by uid {initial.st_uid}, expected {expected_uid_value}"
        )
    actual_mode = initial.st_mode & 0o777
    if expected_mode_value is not None and actual_mode != expected_mode_value:
        raise SystemExit(
            f"{description} {path} has permissions {actual_mode:04o}, expected {expected_mode_value:04o}"
        )

    try:
        fd = os.open(path, os.O_RDONLY | nofollow)
    except OSError as exc:
        raise SystemExit(f"{description} could not be opened safely: {path}: {exc}") from exc
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(initial, opened):
            raise SystemExit(f"{description} changed while being opened: {path}")
        if not stat.S_ISREG(opened.st_mode):
            raise SystemExit(f"{description} is not a regular file after open: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


source_bytes = read_regular_nofollow(source, f"{label} source")
target_bytes = read_regular_nofollow(
    target,
    f"{label} target",
    expected_uid_value=expected_uid,
    expected_mode_value=expected_mode,
)
if target_bytes != source_bytes:
    raise SystemExit(f"{label} target content does not match source: {target}")
PY
}

link_user_atomic() {
  local source="$1"
  local target="$2"
  local target_dir
  local target_name
  local tmp
  validate_user_install_path "$target" "installed command symlink" link
  target_dir="$(dirname "$target")"
  target_name="$(basename "$target")"
  mkdir -p "$target_dir"
  validate_user_install_path "$target_dir" "installed command symlink directory" directory
  tmp="$(mktemp "${target_dir}/.${target_name}.XXXXXX")"
  cleanup_user_temp_path "$tmp" "installed command symlink temporary path" || true
  if ! ln -s "$source" "$tmp"; then
    cleanup_user_temp_path "$tmp" "installed command symlink temporary path" || true
    return 1
  fi
  if ! validate_user_install_path "$target" "installed command symlink" link; then
    cleanup_user_temp_path "$tmp" "installed command symlink temporary path" || true
    return 1
  fi
  if ! mv -f "$tmp" "$target"; then
    cleanup_user_temp_path "$tmp" "installed command symlink temporary path" || true
    return 1
  fi
  sync_paths "$target"
}

verify_installed_command_link() {
  local target="$1"
  local label="$2"
  validate_user_install_path "$target" "$label" link
  "$python3_cmd" - "$target" "$label" "$venv_dir" <<'PY'
from pathlib import Path
import os
import stat
import sys

target = Path(sys.argv[1]).expanduser()
label = sys.argv[2]
venv = Path(sys.argv[3]).expanduser()
expected_uid = os.getuid()

if not target.is_symlink():
    raise SystemExit(f"{label} is not a symlink: {target}")

try:
    resolved_target = target.resolve(strict=True)
    resolved_venv = venv.resolve(strict=True)
except OSError as exc:
    raise SystemExit(f"{label} could not be resolved: {target}: {exc}") from exc

try:
    resolved_target.relative_to(resolved_venv)
except ValueError as exc:
    raise SystemExit(f"{label} does not resolve inside the private venv: {target} -> {resolved_target}") from exc

stat_result = resolved_target.stat()
if stat_result.st_uid != expected_uid:
    raise SystemExit(
        f"{label} target {resolved_target} is owned by uid {stat_result.st_uid}, expected {expected_uid}"
    )
mode = stat_result.st_mode
if not stat.S_ISREG(mode):
    raise SystemExit(f"{label} target is not a regular file: {resolved_target}")
if not mode & stat.S_IXUSR:
    raise SystemExit(f"{label} target is not executable by the installing user: {resolved_target}")
if mode & 0o022:
    raise SystemExit(
        f"{label} target {resolved_target} has permissions {mode & 0o777:04o}, "
        "expected no group/other write bits"
    )
PY
}

verify_installed_user_executable() {
  local target="$1"
  local label="$2"
  validate_user_install_path "$target" "$label" regular
  "$python3_cmd" - "$target" "$label" <<'PY'
from pathlib import Path
import os
import stat
import sys

target = Path(sys.argv[1]).expanduser()
label = sys.argv[2]
expected_uid = os.getuid()

if target.is_symlink():
    raise SystemExit(f"{label} is a symlink: {target}")
try:
    stat_result = target.stat()
except OSError as exc:
    raise SystemExit(f"{label} is not accessible: {target}: {exc}") from exc
mode = stat_result.st_mode
if not stat.S_ISREG(mode):
    raise SystemExit(f"{label} is not a regular file: {target}")
if stat_result.st_uid != expected_uid:
    raise SystemExit(f"{label} {target} is owned by uid {stat_result.st_uid}, expected {expected_uid}")
if not mode & stat.S_IXUSR:
    raise SystemExit(f"{label} is not executable by the installing user: {target}")
if mode & 0o022:
    raise SystemExit(
        f"{label} {target} has permissions {mode & 0o777:04o}, expected no group/other write bits"
    )
PY
}

apt_update() {
  local apt_get_bin
  local sudo_cmd_value
  apt_get_bin="$(apt_get_command)" || return 1
  sudo_cmd_value="$(sudo_command)" || return 1
  "$sudo_cmd_value" env DEBIAN_FRONTEND=noninteractive "$apt_get_bin" update
}

apt_install() {
  local apt_get_bin
  local sudo_cmd_value
  apt_get_bin="$(apt_get_command)" || return 1
  sudo_cmd_value="$(sudo_command)" || return 1
  "$sudo_cmd_value" env DEBIAN_FRONTEND=noninteractive "$apt_get_bin" install -y "$@"
}

path_in_trusted_system_dir() {
  case "$1" in
    /usr/local/sbin/*|/usr/local/bin/*|/usr/sbin/*|/usr/bin/*|/sbin/*|/bin/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

trusted_root_command_path() {
  local command_name="$1"
  local label="$2"
  local command_path
  local resolved_path
  local stat_output
  local owner_uid
  local mode_text
  local mode
  local parent_dir
  local parent_stat
  local parent_owner_uid
  local parent_mode_text
  local parent_mode

  if ! command_path="$(command -v "$command_name" 2>/dev/null)" || [[ -z "$command_path" ]]; then
    echo "${label} was not found on PATH" >&2
    return 1
  fi
  case "$command_path" in
    /*)
      ;;
    *)
      echo "${label} path is not absolute: $command_path" >&2
      return 1
      ;;
  esac
  if ! path_in_trusted_system_dir "$command_path"; then
    echo "${label} is not in a trusted system directory: $command_path" >&2
    return 1
  fi
  if ! resolved_path="$(readlink -f -- "$command_path" 2>/dev/null)" || [[ -z "$resolved_path" ]]; then
    echo "Could not resolve ${label}: $command_path" >&2
    return 1
  fi
  if ! path_in_trusted_system_dir "$resolved_path"; then
    echo "${label} resolves outside trusted system directories: $command_path -> $resolved_path" >&2
    return 1
  fi
  if [[ ! -f "$resolved_path" ]]; then
    echo "${label} is not a regular file after resolution: $command_path -> $resolved_path" >&2
    return 1
  fi
  if [[ ! -x "$resolved_path" ]]; then
    echo "${label} is not executable: $resolved_path" >&2
    return 1
  fi
  stat_output="$(stat -c '%u %a' "$resolved_path" 2>/dev/null)" || {
    echo "Could not inspect ${label}: $resolved_path" >&2
    return 1
  }
  owner_uid="${stat_output%% *}"
  mode_text="${stat_output#* }"
  if [[ "$owner_uid" != "0" ]]; then
    echo "${label} is owned by uid ${owner_uid}, expected root: $resolved_path" >&2
    return 1
  fi
  mode=$((8#$mode_text))
  if (( mode & 022 )); then
    echo "${label} has permissions ${mode_text}, expected no group/other write bits: $resolved_path" >&2
    return 1
  fi
  parent_dir="$(dirname "$resolved_path")"
  parent_stat="$(stat -c '%u %a' "$parent_dir" 2>/dev/null)" || {
    echo "Could not inspect ${label} directory: $parent_dir" >&2
    return 1
  }
  parent_owner_uid="${parent_stat%% *}"
  parent_mode_text="${parent_stat#* }"
  if [[ "$parent_owner_uid" != "0" ]]; then
    echo "${label} directory is owned by uid ${parent_owner_uid}, expected root: $parent_dir" >&2
    return 1
  fi
  parent_mode=$((8#$parent_mode_text))
  if (( parent_mode & 022 )); then
    echo "${label} directory has permissions ${parent_mode_text}, expected no group/other write bits: $parent_dir" >&2
    return 1
  fi
  printf '%s\n' "$resolved_path"
}

check_root_command_integrity() {
  trusted_root_command_path "$1" "$2" >/dev/null
}

apt_get_command() {
  if [[ -z "$apt_get_cmd" ]]; then
    apt_get_cmd="$(trusted_root_command_path apt-get "APT command")" || return 1
  fi
  printf '%s\n' "$apt_get_cmd"
}

sudo_command() {
  if [[ -z "$sudo_cmd" ]]; then
    sudo_cmd="$(trusted_root_command_path sudo "Sudo command")" || return 1
  fi
  printf '%s\n' "$sudo_cmd"
}

python3_command() {
  if [[ -z "$python3_cmd" ]]; then
    python3_cmd="$(trusted_root_command_path python3 "Python command")" || return 1
  fi
  printf '%s\n' "$python3_cmd"
}

ensure_gpsd_client_tools() {
  if check_root_command_integrity cgps "GPSD client command"; then
    return 0
  fi

  if apt_install gpsd-clients; then
    if check_root_command_integrity cgps "GPSD client command"; then
      return 0
    fi
    echo "gpsd-clients installed but trusted cgps is unavailable; trying gpsd-tools." >&2
  else
    echo "gpsd-clients install did not complete; trying gpsd-tools." >&2
  fi

  if apt_install gpsd-tools; then
    if check_root_command_integrity cgps "GPSD client command"; then
      return 0
    fi
  fi

  echo "trusted cgps is not available after installing GPSD client tools; GPS manual verification will fail." >&2
  return 1
}

ensure_vcgencmd() {
  if check_root_command_integrity vcgencmd "Pi power command"; then
    return 0
  fi

  # raspi-utils is current on Raspberry Pi OS Bookworm; libraspberrypi-bin
  # covers older images that still package vcgencmd there.
  if apt_install raspi-utils; then
    if check_root_command_integrity vcgencmd "Pi power command"; then
      return 0
    fi
  else
    echo "raspi-utils install did not complete; trying legacy Raspberry Pi utilities package." >&2
  fi

  if apt_install libraspberrypi-bin; then
    if check_root_command_integrity vcgencmd "Pi power command"; then
      return 0
    fi
  fi

  echo "trusted vcgencmd is not available after installing Raspberry Pi utilities; Pi power readiness checks will fail." >&2
  return 1
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --skip-apt)
      skip_apt=1
      ;;
    --no-services|--skip-autologin)
      # Accepted for deploy-script compatibility. Unattended startup is
      # configured only by provisioning after GPSD and charts are commissioned.
      ;;
    --allow-non-pi)
      allow_non_pi=1
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$(id -u)" -eq 0 ]]; then
  cat >&2 <<'EOF'
Do not run the Raspberry Pi installer as root.
Run it as the Pi desktop user; the script uses sudo only for system package changes.
EOF
  exit 2
fi

arch="$(uname -m)"
if [[ "$allow_non_pi" -eq 0 && "$arch" != armv7l && "$arch" != aarch64 ]]; then
  cat >&2 <<EOF
Refusing to run the Raspberry Pi installer on architecture '$arch'.
Run this on the Raspberry Pi, or use scripts/deploy_to_pi.sh user@raspberrypi.
For development-only testing, pass --allow-non-pi.
EOF
  exit 2
fi

python3_cmd="$(python3_command)" || exit 2

validate_user_install_path "${HOME}/.local/bin" "user command directory" directory
validate_user_install_path "$data_dir" "NOAA Navionics data directory" directory
validate_user_install_path "$venv_dir" "private virtual environment" directory
validate_user_install_path "$config_dir" "NOAA Navionics config directory" directory
validate_user_install_path "$systemd_user_dir" "user systemd directory" directory

if [[ "$skip_apt" -eq 0 ]]; then
  apt_update
  os_codename=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_codename="${VERSION_CODENAME:-}"
  fi
  if [[ "$os_codename" == "bookworm" ]] && ! grep -Rqs '^deb .*bookworm-backports' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    install_root_text_atomic \
      "/etc/apt/sources.list.d/noaa-navionics-bookworm-backports.list" \
      0644 \
      "deb https://deb.debian.org/debian bookworm-backports main"
    apt_update
  elif [[ "$os_codename" != "bookworm" ]]; then
    echo "Skipping bookworm-backports on OS codename '${os_codename:-unknown}'."
  fi
  apt_install python3 python3-venv python3-tk rsync opencpn gpsd chrony lightdm x11-xserver-utils python3-setuptools procps
  ensure_gpsd_client_tools
  ensure_vcgencmd
fi

ensure_private_directory "${HOME}/.local/bin" "user command directory"
ensure_private_directory "$data_dir" "NOAA Navionics data directory"
ensure_private_directory "$config_dir" "NOAA Navionics config directory"
ensure_private_directory "$systemd_user_dir" "user systemd directory"
reset_private_venv
"$python3_cmd" -m venv "$venv_dir"
"${venv_dir}/bin/python" -m pip install --disable-pip-version-check --no-index --no-build-isolation --no-use-pep517 "${repo_root}"
sync_tree "$venv_dir"
link_user_atomic "${venv_dir}/bin/noaa-navionics" "${HOME}/.local/bin/noaa-navionics"
link_user_atomic "${venv_dir}/bin/noaa-navionics-gui" "${HOME}/.local/bin/noaa-navionics-gui"
link_user_atomic "${venv_dir}/bin/noaa-navionics-status-gui" "${HOME}/.local/bin/noaa-navionics-status-gui"
install_user_file_atomic "${repo_root}/scripts/start_chartplotter.sh" "${HOME}/.local/bin/noaa-navionics-start-chartplotter" 0755
install_user_file_atomic "${repo_root}/scripts/configure_desktop_autologin.sh" "${HOME}/.local/bin/noaa-navionics-configure-desktop-autologin" 0755
install_user_file_atomic "${repo_root}/scripts/configure_gps_time.sh" "${HOME}/.local/bin/noaa-navionics-configure-gps-time" 0755

if [[ -f "${repo_root}/.source-revision" ]]; then
  revision="$(tr -d '[:space:]' <"${repo_root}/.source-revision")"
elif revision="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null)"; then
  if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null || true)" ]]; then
    revision="${revision}-dirty"
  fi
else
  revision="unknown"
fi
write_source_revision "$revision"
sync_paths "$revision_file"

if [[ ! -f "${config_dir}/config.ini" ]]; then
  "${HOME}/.local/bin/noaa-navionics" init-config --config "${config_dir}/config.ini"
fi

install_user_file_atomic "${repo_root}/systemd/noaa-navionics.service" "${systemd_user_dir}/noaa-navionics.service" 0644
install_user_file_atomic "${repo_root}/systemd/noaa-navionics.timer" "${systemd_user_dir}/noaa-navionics.timer" 0644
install_user_file_atomic "${repo_root}/systemd/noaa-navionics-track.service" "${systemd_user_dir}/noaa-navionics-track.service" 0644
install_user_file_atomic "${repo_root}/systemd/noaa-navionics-preflight.service" "${systemd_user_dir}/noaa-navionics-preflight.service" 0644

verify_installed_command_link "${HOME}/.local/bin/noaa-navionics" "installed CLI command symlink"
verify_installed_command_link "${HOME}/.local/bin/noaa-navionics-gui" "installed GUI command symlink"
verify_installed_command_link "${HOME}/.local/bin/noaa-navionics-status-gui" "installed status GUI command symlink"
verify_installed_user_executable "${HOME}/.local/bin/noaa-navionics-start-chartplotter" "installed chartplotter launcher"
verify_installed_user_executable "${HOME}/.local/bin/noaa-navionics-configure-desktop-autologin" "installed desktop autologin helper"
verify_installed_user_executable "${HOME}/.local/bin/noaa-navionics-configure-gps-time" "installed GPS time helper"

cat <<EOF
Installed NOAA Navionics.

User systemd unit files were installed but not enabled. Provisioning enables
them after GPSD, charts, and the onboard config are commissioned.
Desktop autologin and chartplotter autostart are also configured by provisioning
after commissioning succeeds.

Next steps:
1. Plug in the GPS and run: noaa-navionics list-gps-devices
2. Edit ${config_dir}/config.ini for your cruising area and GPS.
3. Run: scripts/provision_sailboat_pi.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
4. Start OpenCPN with: noaa-navionics-start-chartplotter
EOF
