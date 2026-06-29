#!/usr/bin/env bash
set -euo pipefail

autologin_user="${USER}"
allow_non_pi=0
dry_run=0

usage() {
  cat >&2 <<'EOF'
Usage: scripts/configure_desktop_autologin.sh [options]

Options:
  --user USER         User to log in automatically; defaults to current user
  --dry-run           Print intended changes without writing system files
  --allow-non-pi      Allow running on non-Raspberry Pi architecture

Configures Raspberry Pi OS Desktop/LightDM to boot into a graphical session
and log in the selected user so the NOAA Navionics chartplotter autostart
entry can launch OpenCPN after power-up.
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

run() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      autologin_user="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
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

if [[ ! "$autologin_user" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
  echo "Autologin user is not a safe local username: $autologin_user" >&2
  exit 2
fi

if [[ "$autologin_user" == "root" ]]; then
  echo "Refusing to configure graphical autologin for root." >&2
  exit 2
fi

arch="$(uname -m)"
if [[ "$allow_non_pi" -eq 0 && "$arch" != armv7l && "$arch" != aarch64 ]]; then
  cat >&2 <<EOF
Refusing to configure desktop autologin on architecture '$arch'.
Run this on the Raspberry Pi, or pass --allow-non-pi for development-only testing.
EOF
  exit 2
fi

if [[ "$dry_run" -eq 0 ]] && ! id "$autologin_user" >/dev/null 2>&1; then
  echo "Autologin user does not exist: $autologin_user" >&2
  exit 2
fi

if [[ "$dry_run" -eq 0 ]]; then
  if ! python3 - "$autologin_user" <<'PY'
from pathlib import Path
import pwd
import sys

username = sys.argv[1]
try:
    entry = pwd.getpwnam(username)
except KeyError as exc:
    raise SystemExit(f"Autologin user does not exist: {username}") from exc
home = Path(entry.pw_dir)
if not home.is_absolute():
    raise SystemExit(f"Autologin user home is not absolute: {home}")
if not home.exists():
    raise SystemExit(f"Autologin user home does not exist: {home}")
if not home.is_dir():
    raise SystemExit(f"Autologin user home is not a directory: {home}")
if home.stat().st_uid != entry.pw_uid:
    raise SystemExit(f"Autologin user does not own home directory: {home}")
PY
  then
    exit 2
  fi
fi

lightdm_dir="/etc/lightdm"
lightdm_conf_dir="${lightdm_dir}/lightdm.conf.d"
autologin_conf="${lightdm_conf_dir}/50-noaa-navionics-autologin.conf"

if [[ "$dry_run" -eq 0 && ! -d "$lightdm_dir" ]]; then
  cat >&2 <<EOF
LightDM is not installed at $lightdm_dir.
Use Raspberry Pi OS with Desktop, or install and configure a display manager before relying on chartplotter autostart.
EOF
  exit 2
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat >"$tmp" <<EOF
[Seat:*]
autologin-user=${autologin_user}
autologin-user-timeout=0
EOF

if [[ "$dry_run" -eq 1 ]]; then
  echo "Would write $autologin_conf:"
  cat "$tmp"
  echo
fi

run sudo install -d -m 0755 "$lightdm_conf_dir"
run sudo install -m 0644 "$tmp" "$autologin_conf"
if [[ "$dry_run" -eq 0 ]]; then
  sync_path "$autologin_conf"
fi
run sudo systemctl set-default graphical.target
run sudo systemctl enable lightdm.service

echo "Configured graphical autologin for $autologin_user"
