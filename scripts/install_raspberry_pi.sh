#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_dir="${HOME}/.config/noaa-navionics"
systemd_user_dir="${HOME}/.config/systemd/user"
autostart_dir="${HOME}/.config/autostart"
venv_dir="${HOME}/.local/share/noaa-navionics/venv"
data_dir="${HOME}/.local/share/noaa-navionics"
revision_file="${data_dir}/source-revision"

skip_apt=0
enable_services=1
allow_non_pi=0
configure_autologin=1

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

apt_update() {
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update
}

apt_install() {
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
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
    --skip-apt)
      skip_apt=1
      ;;
    --no-services)
      enable_services=0
      ;;
    --skip-autologin)
      configure_autologin=0
      ;;
    --allow-non-pi)
      allow_non_pi=1
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$enable_services" -eq 0 && "$configure_autologin" -eq 1 ]]; then
  cat >&2 <<'EOF'
--no-services requires --skip-autologin.
Skipping only user services can leave desktop chartplotter autostart enabled without the readiness and track-logging services.
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
    echo 'deb https://deb.debian.org/debian bookworm-backports main' | sudo tee -a /etc/apt/sources.list >/dev/null
    apt_update
  elif [[ "$os_codename" != "bookworm" ]]; then
    echo "Skipping bookworm-backports on OS codename '${os_codename:-unknown}'."
  fi
  apt_install python3 python3-venv python3-tk opencpn gpsd gpsd-clients chrony lightdm x11-xserver-utils
  ensure_vcgencmd
fi

mkdir -p "${HOME}/.local/bin" "$data_dir"
python3 -m venv "$venv_dir"
"${venv_dir}/bin/python" -m pip install "${repo_root}"
ln -sf "${venv_dir}/bin/noaa-navionics" "${HOME}/.local/bin/noaa-navionics"
ln -sf "${venv_dir}/bin/noaa-navionics-gui" "${HOME}/.local/bin/noaa-navionics-gui"
install -m 0755 "${repo_root}/scripts/start_chartplotter.sh" "${HOME}/.local/bin/noaa-navionics-start-chartplotter"
install -m 0755 "${repo_root}/scripts/configure_desktop_autologin.sh" "${HOME}/.local/bin/noaa-navionics-configure-desktop-autologin"
install -m 0755 "${repo_root}/scripts/configure_gps_time.sh" "${HOME}/.local/bin/noaa-navionics-configure-gps-time"
sync_paths \
  "${HOME}/.local/bin/noaa-navionics" \
  "${HOME}/.local/bin/noaa-navionics-gui" \
  "${HOME}/.local/bin/noaa-navionics-start-chartplotter" \
  "${HOME}/.local/bin/noaa-navionics-configure-desktop-autologin" \
  "${HOME}/.local/bin/noaa-navionics-configure-gps-time"

if [[ -f "${repo_root}/.source-revision" ]]; then
  cp "${repo_root}/.source-revision" "$revision_file"
elif revision="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null)"; then
  printf '%s\n' "$revision" >"$revision_file"
else
  printf 'unknown\n' >"$revision_file"
fi
sync_paths "$revision_file"

mkdir -p "$config_dir" "$systemd_user_dir" "$autostart_dir"
if [[ ! -f "${config_dir}/config.ini" ]]; then
  "${HOME}/.local/bin/noaa-navionics" init-config --config "${config_dir}/config.ini"
fi

cp "${repo_root}/systemd/noaa-navionics.service" \
   "${repo_root}/systemd/noaa-navionics.timer" \
   "${repo_root}/systemd/noaa-navionics-track.service" \
   "${repo_root}/systemd/noaa-navionics-preflight.service" \
   "$systemd_user_dir/"

install -m 0644 "${repo_root}/templates/noaa-navionics-chartplotter.desktop" "$autostart_dir/"
sync_paths \
  "${systemd_user_dir}/noaa-navionics.service" \
  "${systemd_user_dir}/noaa-navionics.timer" \
  "${systemd_user_dir}/noaa-navionics-track.service" \
  "${systemd_user_dir}/noaa-navionics-preflight.service" \
  "${autostart_dir}/noaa-navionics-chartplotter.desktop"

if [[ "$configure_autologin" -eq 1 ]]; then
  autologin_args=()
  if [[ "$allow_non_pi" -eq 1 ]]; then
    autologin_args+=(--allow-non-pi)
  fi
  "${repo_root}/scripts/configure_desktop_autologin.sh" --user "$USER" "${autologin_args[@]}"
fi

systemctl --user daemon-reload

cat <<EOF
Installed NOAA Navionics.

User systemd unit files were installed but not enabled. Provisioning enables
them after GPSD, charts, and the onboard config are commissioned.

Next steps:
1. Edit ${config_dir}/config.ini for your cruising area and GPS.
2. Run: scripts/provision_sailboat_pi.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
3. Start OpenCPN with: noaa-navionics-start-chartplotter
EOF
