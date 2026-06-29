#!/usr/bin/env bash
set -euo pipefail

allow_non_pi=0
dry_run=0
chrony_conf="/etc/chrony/chrony.conf"
restart_gpsd=1

usage() {
  cat >&2 <<'EOF'
Usage: scripts/configure_gps_time.sh [options]

Options:
  --chrony-conf PATH  Chrony config path
  --dry-run           Print intended changes without writing system files
  --no-gpsd-restart   Do not restart GPSD after restarting chrony
  --allow-non-pi      Allow running on non-Raspberry Pi architecture

Configures chrony to use GPSD's message-based SHM 0 time source.
EOF
}

sync_path() {
  local path="$1"
  sudo python3 - "$path" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
with path.open("rb") as handle:
    os.fsync(handle.fileno())
try:
    fd = os.open(path.parent, os.O_RDONLY)
except OSError:
    fd = None
if fd is not None:
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chrony-conf)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      chrony_conf="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --no-gpsd-restart)
      restart_gpsd=0
      shift
      ;;
    --allow-non-pi)
      allow_non_pi=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$dry_run" -eq 0 && "$(id -u)" -eq 0 ]]; then
  cat >&2 <<'EOF'
Do not configure GPS time as root.
Run this as the Pi desktop user; the script uses sudo only for system chrony changes.
EOF
  exit 2
fi

case "$chrony_conf" in
  /*)
    ;;
  *)
    echo "Chrony config path must be absolute: $chrony_conf" >&2
    exit 2
    ;;
esac

if [[ "$chrony_conf" =~ [[:space:]\"\'] ]]; then
  echo "Chrony config path must not contain whitespace or quotes: $chrony_conf" >&2
  exit 2
fi

if [[ "$dry_run" -eq 0 && "$chrony_conf" != "/etc/chrony/chrony.conf" ]]; then
  cat >&2 <<EOF
Refusing to write a non-standard chrony config path: $chrony_conf
Use /etc/chrony/chrony.conf for production, or --dry-run for custom-path inspection.
EOF
  exit 2
fi

arch="$(uname -m)"
if [[ "$allow_non_pi" -eq 0 && "$arch" != armv7l && "$arch" != aarch64 ]]; then
  cat >&2 <<EOF
Refusing to configure GPS time on architecture '$arch'.
Run this on the Raspberry Pi, or pass --allow-non-pi for development-only testing.
EOF
  exit 2
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

python3 - "$chrony_conf" "$tmp" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
begin = "# BEGIN NOAA Navionics GPS time"
end = "# END NOAA Navionics GPS time"
block = """# BEGIN NOAA Navionics GPS time
# GPSD publishes message-based GPS time on SHM 0. This is sufficient for
# chart-age checks and GPX timestamps; add PPS hardware for sub-second timing.
refclock SHM 0 offset 0.5 delay 0.1 refid GPS
makestep 1.0 3
# END NOAA Navionics GPS time
"""

try:
    text = source.read_text(encoding="utf-8")
except FileNotFoundError:
    text = ""

lines = text.splitlines(keepends=True)
filtered: list[str] = []
skipping = False
for line in lines:
    stripped = line.strip()
    if stripped == begin:
        skipping = True
        continue
    if stripped == end and skipping:
        skipping = False
        continue
    if not skipping:
        filtered.append(line)

if filtered and filtered[-1].strip():
    filtered.append("\n")
filtered.append(block)
target.write_text("".join(filtered), encoding="utf-8")
PY

if [[ "$dry_run" -eq 1 ]]; then
  echo "Would update $chrony_conf with NOAA Navionics GPS time block:"
  sed -n '/BEGIN NOAA Navionics GPS time/,$p' "$tmp"
  if [[ "$restart_gpsd" -eq 1 ]]; then
    echo "Would restart chrony and GPSD so GPSD attaches to chrony after restart."
  else
    echo "Would restart chrony."
  fi
  exit 0
fi

if ! command -v chronyd >/dev/null 2>&1 && ! command -v chronyc >/dev/null 2>&1; then
  echo "chrony is not installed; run scripts/install_raspberry_pi.sh first" >&2
  exit 2
fi

sudo mkdir -p "$(dirname "$chrony_conf")"
if [[ -e "$chrony_conf" ]]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${chrony_conf}.noaa-navionics.${stamp}.bak"
  sudo cp -a "$chrony_conf" "$backup"
  sync_path "$backup"
fi

sudo install -m 0644 "$tmp" "$chrony_conf"
sync_path "$chrony_conf"
sudo systemctl enable --now chrony
sudo systemctl restart chrony
if [[ "$restart_gpsd" -eq 1 ]]; then
  sudo systemctl restart gpsd
fi

cat <<EOF
Configured chrony GPS time source.

Chrony config: $chrony_conf
Then verify: timedatectl show -p SystemClockSynchronized
EOF
