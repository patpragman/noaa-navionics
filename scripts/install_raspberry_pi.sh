#!/usr/bin/env bash
set -euo pipefail

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
target.parent.mkdir(parents=True, exist_ok=True)
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

mkdir -p "${HOME}/.local/bin" "$data_dir"
reset_private_venv
python3 -m venv "$venv_dir"
"${venv_dir}/bin/python" -m pip install --no-build-isolation --no-use-pep517 "${repo_root}"
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

mkdir -p "$config_dir" "$systemd_user_dir"
if [[ ! -f "${config_dir}/config.ini" ]]; then
  "${HOME}/.local/bin/noaa-navionics" init-config --config "${config_dir}/config.ini"
fi

install_user_file_atomic "${repo_root}/systemd/noaa-navionics.service" "${systemd_user_dir}/noaa-navionics.service" 0644
install_user_file_atomic "${repo_root}/systemd/noaa-navionics.timer" "${systemd_user_dir}/noaa-navionics.timer" 0644
install_user_file_atomic "${repo_root}/systemd/noaa-navionics-track.service" "${systemd_user_dir}/noaa-navionics-track.service" 0644
install_user_file_atomic "${repo_root}/systemd/noaa-navionics-preflight.service" "${systemd_user_dir}/noaa-navionics-preflight.service" 0644

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
