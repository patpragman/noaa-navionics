#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_dir="${HOME}/.config/noaa-navionics"
systemd_user_dir="${HOME}/.config/systemd/user"
venv_dir="${HOME}/.local/share/noaa-navionics/venv"
data_dir="${HOME}/.local/share/noaa-navionics"
revision_file="${data_dir}/source-revision"

skip_apt=0
allow_non_pi=0

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
  python3 - "$@" <<'PY'
from pathlib import Path
import os
import sys

synced_dirs: set[Path] = set()
for arg in sys.argv[1:]:
    path = Path(arg).expanduser()
    if path.is_dir():
        synced_dirs.add(path)
        synced_dirs.add(path.parent)
        continue
    try:
        with path.open("rb") as handle:
            os.fsync(handle.fileno())
    except OSError:
        continue
    synced_dirs.add(path.parent)
for directory in synced_dirs:
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        continue
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

sync_tree() {
  python3 - "$1" <<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1]).expanduser()
if not root.exists():
    raise SystemExit(f"cannot sync missing tree: {root}")

def fsync_dir(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY)
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
        if file_path.is_symlink():
            continue
        try:
            with file_path.open("rb") as handle:
                os.fsync(handle.fileno())
        except OSError:
            continue
    for dirname in dirnames:
        fsync_dir(current / dirname)
    fsync_dir(current)
fsync_dir(root.parent)
PY
}

reset_private_venv() {
  python3 - "$venv_dir" "$data_dir" <<'PY'
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
    shutil.rmtree(venv)
PY
}

write_source_revision() {
  local revision="$1"
  validate_user_install_path "$revision_file" "source revision file" regular
  python3 - "$revision_file" "$revision" <<'PY'
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
    fd = os.open(target.parent, os.O_RDONLY)
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
  python3 - "$target" "$label" "$expected_kind" <<'PY'
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
  chmod 0700 "$target"
  sync_paths "$target"
}

install_root_text_atomic() {
  local target="$1"
  local mode="$2"
  local text="$3"
  sudo python3 - "$target" "$mode" "$text" <<'PY'
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
    fd = os.open(target.parent, os.O_RDONLY)
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
  tmp="$(mktemp "${target_dir}/.${target_name}.XXXXXX")"
  if ! install -m "$mode" "$source" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! sync_paths "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
  sync_paths "$target"
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
  tmp="$(mktemp "${target_dir}/.${target_name}.XXXXXX")"
  rm -f "$tmp"
  if ! ln -s "$source" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
  sync_paths "$target"
}

verify_installed_command_link() {
  local target="$1"
  local label="$2"
  validate_user_install_path "$target" "$label" link
  python3 - "$target" "$label" "$venv_dir" <<'PY'
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
  python3 - "$target" "$label" <<'PY'
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
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update
}

apt_install() {
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_gpsd_client_tools() {
  if command -v cgps >/dev/null 2>&1; then
    return 0
  fi

  if apt_install gpsd-clients; then
    if command -v cgps >/dev/null 2>&1; then
      return 0
    fi
    echo "gpsd-clients installed but cgps is unavailable; trying gpsd-tools." >&2
  else
    echo "gpsd-clients install did not complete; trying gpsd-tools." >&2
  fi

  if apt_install gpsd-tools; then
    if command -v cgps >/dev/null 2>&1; then
      return 0
    fi
  fi

  echo "cgps is not available after installing GPSD client tools; GPS manual verification will fail." >&2
  return 1
}

ensure_vcgencmd() {
  if command -v vcgencmd >/dev/null 2>&1; then
    return 0
  fi

  # raspi-utils is current on Raspberry Pi OS Bookworm; libraspberrypi-bin
  # covers older images that still package vcgencmd there.
  if apt_install raspi-utils; then
    if command -v vcgencmd >/dev/null 2>&1; then
      return 0
    fi
  else
    echo "raspi-utils install did not complete; trying legacy Raspberry Pi utilities package." >&2
  fi

  if apt_install libraspberrypi-bin; then
    if command -v vcgencmd >/dev/null 2>&1; then
      return 0
    fi
  fi

  echo "vcgencmd is not available after installing Raspberry Pi utilities; Pi power readiness checks will fail." >&2
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
python3 -m venv "$venv_dir"
"${venv_dir}/bin/python" -m pip install --disable-pip-version-check --no-index --no-build-isolation --no-use-pep517 "${repo_root}"
sync_tree "$venv_dir"
link_user_atomic "${venv_dir}/bin/noaa-navionics" "${HOME}/.local/bin/noaa-navionics"
link_user_atomic "${venv_dir}/bin/noaa-navionics-gui" "${HOME}/.local/bin/noaa-navionics-gui"
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
1. Edit ${config_dir}/config.ini for your cruising area and GPS.
2. Run: scripts/provision_sailboat_pi.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
3. Start OpenCPN with: noaa-navionics-start-chartplotter
EOF
