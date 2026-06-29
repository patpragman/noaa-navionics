#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_dir="${HOME}/.config/noaa-navionics"
systemd_user_dir="${HOME}/.config/systemd/user"
autostart_dir="${HOME}/.config/autostart"

skip_apt=0
enable_services=1
allow_non_pi=0

for arg in "$@"; do
  case "$arg" in
    --skip-apt)
      skip_apt=1
      ;;
    --no-services)
      enable_services=0
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
  sudo apt update
  if ! grep -Rqs '^deb .*bookworm-backports' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    echo 'deb https://deb.debian.org/debian bookworm-backports main' | sudo tee -a /etc/apt/sources.list >/dev/null
    sudo apt update
  fi
  sudo apt install -y python3 python3-tk opencpn gpsd gpsd-clients
fi

python3 -m pip install --user "${repo_root}"

mkdir -p "$config_dir" "$systemd_user_dir" "$autostart_dir"
if [[ ! -f "${config_dir}/config.ini" ]]; then
  "${HOME}/.local/bin/noaa-navionics" init-config --config "${config_dir}/config.ini"
fi

cp "${repo_root}/systemd/noaa-navionics.service" \
   "${repo_root}/systemd/noaa-navionics.timer" \
   "${repo_root}/systemd/noaa-navionics-track.service" \
   "${repo_root}/systemd/noaa-navionics-preflight.service" \
   "$systemd_user_dir/"

cp "${repo_root}/templates/noaa-navionics-opencpn.desktop" "$autostart_dir/"

systemctl --user daemon-reload
if [[ "$enable_services" -eq 1 ]]; then
  systemctl --user enable --now noaa-navionics.timer
  systemctl --user enable --now noaa-navionics-track.service
fi

cat <<EOF
Installed NOAA Navionics.

Next steps:
1. Edit ${config_dir}/config.ini for your cruising area and GPS.
2. Configure GPSD using ${repo_root}/templates/gpsd.default as a reference.
3. Run: noaa-navionics sync-charts
4. Run: noaa-navionics preflight
5. Add the extracted chart directory to OpenCPN.
EOF
