#!/usr/bin/env bash
set -euo pipefail
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_config="${HOME}/.config/noaa-navionics/config.ini"
config="$default_config"
device=""
allow_non_pi=0
check_device=1
dry_run=0
skip_gpsd=0
skip_sync=0
skip_services=0
skip_autologin=0
skip_gps_time=0
gps_seconds=60
opencpn_restarts=3
opencpn_restart_delay=5
sync_retries=5
sync_retry_delay=30

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

usage() {
  cat >&2 <<'EOF'
Usage: scripts/provision_sailboat_pi.sh --device /dev/serial/by-id/YOUR_GPS [options]

Options:
  --config PATH       NOAA Navionics config path
  --gps-seconds N     Seconds to wait for a GPS fix during final status report
  --opencpn-restarts N
                     OpenCPN nonzero-exit restart attempts after boot
  --opencpn-restart-delay N
                     Seconds between OpenCPN restart attempts
  --sync-retries N    Chart download attempts during initial commissioning
  --sync-retry-delay N
                     Seconds between chart download retry attempts
  --dry-run           Print commands without changing the Pi
  --skip-gpsd         Do not configure GPSD
  --skip-sync         Do not download charts
  --skip-services     Do not enable user systemd services
  --skip-autologin    Do not configure desktop graphical autologin; requires
                      --skip-services
  --skip-gps-time     Do not configure chrony to use GPSD time
  --no-device-check   Do not require the GPS device path to exist now; requires
                      --skip-services and --skip-autologin
  --allow-non-pi      Allow running on non-Raspberry Pi architecture

Runs the onboard commissioning sequence on the Raspberry Pi:
GPSD, chart sync, OpenCPN config, services, and final readiness report.
EOF
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer" >&2
    exit 2
  fi
}

require_non_negative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a non-negative integer" >&2
    exit 2
  fi
}

same_path() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys

left = Path(sys.argv[1]).expanduser().resolve(strict=False)
right = Path(sys.argv[2]).expanduser().resolve(strict=False)
raise SystemExit(0 if left == right else 1)
PY
}

validate_existing_gps_config() {
  if ! python3 - "$config" "$check_device" "$device" <<'PY'
from configparser import ConfigParser
from pathlib import Path
import os
import sys

config_path = Path(sys.argv[1]).expanduser()
check_device = sys.argv[2] == "1"
expected_device = sys.argv[3].strip()

def first_symlink_ancestor(path):
    current = Path(path).expanduser()
    for candidate in [current, *current.parents]:
        if candidate.is_symlink():
            return candidate
    return None

if not config_path.exists():
    raise SystemExit("Existing config is required when --skip-gpsd is used with unattended startup")
if config_path.is_symlink():
    raise SystemExit(f"Existing GPS config is a symlink when --skip-gpsd is used: {config_path}")
symlink_component = first_symlink_ancestor(config_path.parent)
if symlink_component is not None:
    raise SystemExit(f"Existing GPS config directory is a symlink when --skip-gpsd is used: {symlink_component}")
if not config_path.is_file():
    raise SystemExit(f"Existing GPS config is not a regular file when --skip-gpsd is used: {config_path}")
try:
    stat_result = config_path.stat()
except OSError as exc:
    raise SystemExit(f"could not inspect existing GPS config when --skip-gpsd is used: {config_path}: {exc}") from exc
if stat_result.st_uid != os.getuid():
    raise SystemExit(
        f"Existing GPS config {config_path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
    )
mode_bits = stat_result.st_mode & 0o777
if mode_bits & 0o022:
    raise SystemExit(
        f"Existing GPS config {config_path} has permissions {mode_bits:04o}, expected no group/other write bits"
    )
parser = ConfigParser()
if not parser.read(config_path):
    raise SystemExit(f"could not read config: {config_path}")
mode = parser.get("gps", "mode", fallback="").strip().lower()
if mode != "gpsd":
    raise SystemExit(f"gps.mode must be gpsd when --skip-gpsd is used with unattended startup, not {mode or '<empty>'}")
host = parser.get("gps", "gpsd_host", fallback="").strip().lower()
if host not in {"127.0.0.1", "localhost", "::1"}:
    raise SystemExit("gps.gpsd_host must be local when --skip-gpsd is used with unattended startup")
device = parser.get("gps", "device", fallback="").strip()
if not device or device == "/dev/serial/by-id/YOUR_GPS_DEVICE":
    raise SystemExit("gps.device must name the already configured GPS receiver when --skip-gpsd is used")
if expected_device and device != expected_device:
    raise SystemExit(
        f"gps.device {device} does not match requested --device {expected_device} when --skip-gpsd is used"
    )
by_id_prefix = "/dev/serial/by-id/"
safe_by_id_chars = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:+@-")
if device.startswith(by_id_prefix):
    suffix = device[len(by_id_prefix):]
    stable = bool(suffix) and "/" not in suffix and suffix not in {".", ".."} and all(
        char in safe_by_id_chars for char in suffix
    )
else:
    stable = device in {"/dev/serial0", "/dev/serial1", "/dev/gps"}
name = Path(device).name
if name.startswith(("ttyUSB", "ttyACM")):
    raise SystemExit("gps.device uses a volatile USB name; use /dev/serial/by-id/... instead")
if not stable:
    raise SystemExit("gps.device must be /dev/serial/by-id/..., /dev/serial0, /dev/serial1, or /dev/gps")
path = Path(device).expanduser()
if check_device and not path.exists():
    raise SystemExit(f"GPS device does not exist: {path}")
if check_device and path.is_dir():
    raise SystemExit(f"GPS device path is a directory, not a GPS device: {path}")
if check_device and not path.is_char_device():
    raise SystemExit(f"GPS device path is not a character device: {path}")
PY
  then
    exit 2
  fi
}

validate_existing_gps_time_config() {
  if ! python3 - <<'PY'
from pathlib import Path
import os

chrony_conf = Path("/etc/chrony/chrony.conf")
expected = "refclock SHM 0 offset 0.5 delay 0.1 refid GPS"

def first_symlink_ancestor(path):
    current = Path(path).expanduser()
    for candidate in [current, *current.parents]:
        if candidate.is_symlink():
            return candidate
    return None

if not chrony_conf.exists():
    raise SystemExit("Existing chrony GPS time config is required when --skip-gps-time is used with unattended startup")
if chrony_conf.is_symlink():
    raise SystemExit(f"Existing chrony GPS time config is a symlink when --skip-gps-time is used: {chrony_conf}")
symlink_component = first_symlink_ancestor(chrony_conf.parent)
if symlink_component is not None:
    raise SystemExit(
        f"Existing chrony GPS time config directory is a symlink when --skip-gps-time is used: {symlink_component}"
    )
if not chrony_conf.is_file():
    raise SystemExit(
        f"Existing chrony GPS time config is not a regular file when --skip-gps-time is used: {chrony_conf}"
    )
try:
    stat_result = chrony_conf.stat()
except OSError as exc:
    raise SystemExit(f"could not inspect chrony config: {chrony_conf}: {exc}") from exc
if stat_result.st_uid != 0:
    raise SystemExit(
        f"Existing chrony GPS time config {chrony_conf} is owned by uid {stat_result.st_uid}, expected 0"
    )
mode_bits = stat_result.st_mode & 0o777
if mode_bits & 0o022:
    raise SystemExit(
        f"Existing chrony GPS time config {chrony_conf} has permissions {mode_bits:04o}, "
        "expected no group/other write bits"
    )
try:
    text = chrony_conf.read_text(encoding="utf-8")
except OSError as exc:
    raise SystemExit(f"could not read chrony config: {chrony_conf}: {exc}") from exc
configured = any(line.strip() == expected for line in text.splitlines() if not line.lstrip().startswith("#"))
if not configured:
    raise SystemExit("chrony config must already contain the NOAA Navionics GPSD SHM 0 time source when --skip-gps-time is used")
PY
  then
    exit 2
  fi
}

validate_existing_system_service() {
  local unit="$1"
  local label="$2"
  local skip_flag="$3"
  local enabled
  local active
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl is required to validate existing ${label} service state when ${skip_flag} is used" >&2
    exit 2
  fi
  if ! systemctl is-enabled --quiet "$unit"; then
    enabled="$(systemctl is-enabled "$unit" 2>&1 || true)"
    echo "${label} service must already be enabled when ${skip_flag} is used with unattended startup: ${unit} is ${enabled:-unknown}" >&2
    exit 2
  fi
  if ! systemctl is-active --quiet "$unit"; then
    active="$(systemctl is-active "$unit" 2>&1 || true)"
    echo "${label} service must already be active when ${skip_flag} is used with unattended startup: ${unit} is ${active:-unknown}" >&2
    exit 2
  fi
}

validate_existing_charts() {
  if ! python3 - "$repo_root" "$config" <<'PY'
from pathlib import Path
import sys

repo_root = Path(sys.argv[1])
config_path = Path(sys.argv[2]).expanduser()
if not config_path.exists():
    raise SystemExit("Existing chart config is required when --skip-sync is used with unattended startup")
sys.path.insert(0, str(repo_root / "src"))
from noaa_navionics.config import read_config
from noaa_navionics.health import (
    check_chart_dir,
    check_chart_manifest,
    check_chart_package,
    check_chart_update_debris,
)

app_config = read_config(config_path)
checks = [
    check_chart_package(app_config.chart_package, app_config.chart_value),
    check_chart_dir(app_config.chart_output),
    check_chart_update_debris(app_config.chart_output),
    check_chart_manifest(
        app_config.chart_output,
        max_age_days=app_config.max_chart_age_days,
        expected_package=app_config.chart_package,
        expected_value=app_config.chart_value,
        require_archive=app_config.keep_zip,
    ),
]
failures = [f"{check.name}: {check.detail}" for check in checks if not check.ok]
if failures:
    raise SystemExit(
        "existing complete charts are required when --skip-sync is used with unattended startup: "
        + "; ".join(failures)
    )
PY
  then
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      device="${2:-}"
      shift 2
      ;;
    --config)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      config="${2:-}"
      shift 2
      ;;
    --gps-seconds)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      gps_seconds="${2:-}"
      shift 2
      ;;
    --sync-retries)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      sync_retries="${2:-}"
      shift 2
      ;;
    --opencpn-restarts)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      opencpn_restarts="${2:-}"
      shift 2
      ;;
    --opencpn-restart-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      opencpn_restart_delay="${2:-}"
      shift 2
      ;;
    --sync-retry-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      sync_retry_delay="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --skip-gpsd)
      skip_gpsd=1
      shift
      ;;
    --skip-sync)
      skip_sync=1
      shift
      ;;
    --skip-services)
      skip_services=1
      shift
      ;;
    --skip-autologin)
      skip_autologin=1
      shift
      ;;
    --skip-gps-time)
      skip_gps_time=1
      shift
      ;;
    --no-device-check)
      check_device=0
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

require_positive_integer "--gps-seconds" "$gps_seconds"
require_positive_integer "--sync-retries" "$sync_retries"
require_non_negative_integer "--opencpn-restarts" "$opencpn_restarts"
require_non_negative_integer "--opencpn-restart-delay" "$opencpn_restart_delay"
require_non_negative_integer "--sync-retry-delay" "$sync_retry_delay"

if [[ "$dry_run" -eq 0 && "$(id -u)" -eq 0 ]]; then
  cat >&2 <<'EOF'
Do not run sailboat Pi provisioning as root.
Run it as the Pi desktop user; the script uses sudo only for system changes.
EOF
  exit 2
fi

if [[ "$skip_gpsd" -eq 0 && -z "$device" ]]; then
  echo "--device is required unless --skip-gpsd is used" >&2
  usage
  exit 2
fi

if [[ "$skip_services" -eq 1 && "$skip_autologin" -eq 0 ]]; then
  cat >&2 <<'EOF'
--skip-services requires --skip-autologin.
Skipping only user services can leave desktop chartplotter autostart enabled without the readiness and track-logging services.
EOF
  exit 2
fi

if [[ "$skip_autologin" -eq 1 && "$skip_services" -eq 0 ]]; then
  cat >&2 <<'EOF'
--skip-autologin requires --skip-services.
Readiness now verifies desktop startup, so services and chartplotter autostart must be provisioned together for unattended startup.
EOF
  exit 2
fi

arch="$(uname -m)"
if [[ "$allow_non_pi" -eq 0 && "$arch" != armv7l && "$arch" != aarch64 ]]; then
  cat >&2 <<EOF
Refusing to provision sailboat Pi on architecture '$arch'.
Run this on the Raspberry Pi, or pass --allow-non-pi for development-only testing.
EOF
  exit 2
fi

if [[ "$skip_gpsd" -eq 0 && "$check_device" -eq 1 && "$dry_run" -eq 0 && ! -e "$device" ]]; then
  cat >&2 <<EOF
GPS device does not exist: $device
Use a stable path from /dev/serial/by-id/, or pass --no-device-check if it is not plugged in yet.
EOF
  exit 2
fi

if ! same_path "$config" "$default_config" && [[ "$skip_services" -eq 0 || "$skip_autologin" -eq 0 ]]; then
  cat >&2 <<EOF
Custom --config path does not match the unattended onboard config: $config
Installed systemd services and desktop autostart use: $default_config
Use the default config for production provisioning, or pass both --skip-services and --skip-autologin for manual testing.
EOF
  exit 2
fi

if [[ "$check_device" -eq 0 && ( "$skip_services" -eq 0 || "$skip_autologin" -eq 0 ) ]]; then
  cat >&2 <<EOF
--no-device-check cannot be used while unattended startup is enabled.
Plug in the GPS receiver and use a stable device path, or pass both --skip-services and --skip-autologin for manual testing.
EOF
  exit 2
fi

if [[ "$skip_gpsd" -eq 1 && ( "$skip_services" -eq 0 || "$skip_autologin" -eq 0 ) ]]; then
  validate_existing_gps_config
  if [[ "$dry_run" -eq 0 ]]; then
    validate_existing_system_service gpsd.socket "GPSD socket" --skip-gpsd
    validate_existing_system_service gpsd.service GPSD --skip-gpsd
  fi
fi

if [[ "$skip_gps_time" -eq 1 && ( "$skip_services" -eq 0 || "$skip_autologin" -eq 0 ) ]]; then
  validate_existing_gps_time_config
  if [[ "$dry_run" -eq 0 ]]; then
    validate_existing_system_service chrony.service chrony --skip-gps-time
  fi
fi

if [[ "$skip_sync" -eq 1 && ( "$skip_services" -eq 0 || "$skip_autologin" -eq 0 ) ]]; then
  validate_existing_charts
fi

bin="${HOME}/.local/bin/noaa-navionics"
if [[ ! -x "$bin" && "$dry_run" -eq 0 ]]; then
  if command -v noaa-navionics >/dev/null 2>&1; then
    bin="$(command -v noaa-navionics)"
  else
    echo "noaa-navionics is not installed; run scripts/install_raspberry_pi.sh first" >&2
    exit 2
  fi
fi

run() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

validate_user_install_path() {
  local target="$1"
  local label="$2"
  python3 - "$target" "$label" <<'PY'
from pathlib import Path
import os
import sys

target = Path(sys.argv[1]).expanduser()
label = sys.argv[2]
home = Path.home().resolve(strict=False)
path_chain = []
cursor = target
while True:
    path_chain.append(cursor)
    if cursor == home or cursor == cursor.parent:
        break
    cursor = cursor.parent
if path_chain[-1] != home:
    raise SystemExit(f"{label} path must be under the deploying user's home directory: {target}")

for path in path_chain:
    if path.is_symlink():
        raise SystemExit(f"{label} path contains a symlink: {path}")

try:
    resolved_target = target.resolve(strict=False)
except RuntimeError as exc:
    raise SystemExit(f"{label} path could not be resolved: {target}: {exc}") from exc
if resolved_target != home and home not in resolved_target.parents:
    raise SystemExit(f"{label} path must stay under the deploying user's home directory: {target}")

expected_uid = os.getuid()
for directory in path_chain[1:]:
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

if target.exists():
    if not target.is_file():
        raise SystemExit(f"{label} is not a regular file: {target}")
    stat_result = target.stat()
    mode = stat_result.st_mode & 0o777
    if stat_result.st_uid != expected_uid:
        raise SystemExit(f"{label} {target} is owned by uid {stat_result.st_uid}, expected {expected_uid}")
    if mode & 0o022:
        raise SystemExit(f"{label} {target} has permissions {mode:04o}, expected no group/other write bits")
PY
}

validate_user_directory_path() {
  local target="$1"
  local label="$2"
  python3 - "$target" "$label" <<'PY'
from pathlib import Path
import os
import sys

target = Path(sys.argv[1]).expanduser()
label = sys.argv[2]
home = Path.home().resolve(strict=False)
path_chain = []
cursor = target
while True:
    path_chain.append(cursor)
    if cursor == home or cursor == cursor.parent:
        break
    cursor = cursor.parent
if path_chain[-1] != home:
    raise SystemExit(f"{label} path must be under the deploying user's home directory: {target}")

for path in path_chain:
    if path.is_symlink():
        raise SystemExit(f"{label} path contains a symlink: {path}")

try:
    resolved_target = target.resolve(strict=False)
except RuntimeError as exc:
    raise SystemExit(f"{label} path could not be resolved: {target}: {exc}") from exc
if resolved_target != home and home not in resolved_target.parents:
    raise SystemExit(f"{label} path must stay under the deploying user's home directory: {target}")

expected_uid = os.getuid()
for directory in path_chain:
    if not directory.exists():
        continue
    if not directory.is_dir():
        raise SystemExit(f"{label} path is not a directory: {directory}")
    stat_result = directory.stat()
    mode = stat_result.st_mode & 0o777
    if stat_result.st_uid != expected_uid:
        raise SystemExit(
            f"{label} path {directory} is owned by uid {stat_result.st_uid}, expected {expected_uid}"
        )
    if mode & 0o022:
        raise SystemExit(
            f"{label} path {directory} has permissions {mode:04o}, expected no group/other write bits"
        )
PY
}

ensure_private_directory() {
  local target="$1"
  local label="$2"
  validate_user_directory_path "$target" "$label"
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ ensure_private_directory %q %q\n' "$target" "$label"
    return 0
  fi
  mkdir -p "$target"
  chmod 0700 "$target"
  sync_paths "$target"
}

install_file_atomic() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local target_dir
  local target_name
  local tmp
  validate_user_install_path "$target" "provisioned user file"
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ install_file_atomic %q %q %q\n' "$source" "$target" "$mode"
    return 0
  fi
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

require_loaded_user_unit_property() {
  local unit="$1"
  local property="$2"
  local expected="$3"
  local label="$4"
  local loaded
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ require_loaded_user_unit_property %q %q %q %q\n' "$unit" "$property" "$expected" "$label"
    return 0
  fi
  if ! loaded="$(systemctl --user show "$unit" -p "$property" 2>/dev/null)"; then
    cat >&2 <<EOF
Could not inspect loaded user unit property: $unit $property
The unattended startup services were installed but not enabled. Check the user systemd manager with: systemctl --user status $unit
EOF
    exit 2
  fi
  if [[ "$loaded" != "${property}=${expected}" ]]; then
    cat >&2 <<EOF
Loaded user unit setting mismatch for $label.
Expected: ${property}=${expected}
Loaded:   ${loaded:-<empty>}
The unattended startup services were installed but not enabled. Check systemd support for the installed unit settings, then run: systemctl --user daemon-reload
EOF
    exit 2
  fi
}

require_loaded_user_units() {
  require_loaded_user_unit_property noaa-navionics.service FragmentPath "$chart_service" "chart refresh service"
  require_loaded_user_unit_property noaa-navionics.timer FragmentPath "$chart_timer" "chart refresh timer"
  require_loaded_user_unit_property noaa-navionics-track.service FragmentPath "$track_service" "track logger service"
  require_loaded_user_unit_property noaa-navionics-preflight.service FragmentPath "$preflight_service" "boot readiness service"
  require_loaded_user_unit_property noaa-navionics.service Type oneshot "chart refresh service"
  require_loaded_user_unit_property noaa-navionics-track.service Type simple "track logger service"
  require_loaded_user_unit_property noaa-navionics-preflight.service Type oneshot "boot readiness service"
  require_loaded_user_unit_property noaa-navionics.service NoNewPrivileges yes "chart refresh service"
  require_loaded_user_unit_property noaa-navionics-track.service NoNewPrivileges yes "track logger service"
  require_loaded_user_unit_property noaa-navionics-preflight.service NoNewPrivileges yes "boot readiness service"
  require_loaded_user_unit_property noaa-navionics.service PrivateTmp yes "chart refresh service"
  require_loaded_user_unit_property noaa-navionics-track.service PrivateTmp yes "track logger service"
  require_loaded_user_unit_property noaa-navionics-preflight.service PrivateTmp yes "boot readiness service"
  require_loaded_user_unit_property noaa-navionics.service ProtectSystem full "chart refresh service"
  require_loaded_user_unit_property noaa-navionics-track.service ProtectSystem full "track logger service"
  require_loaded_user_unit_property noaa-navionics-preflight.service ProtectSystem full "boot readiness service"
  require_loaded_user_unit_property noaa-navionics.service UMask 0077 "chart refresh service"
  require_loaded_user_unit_property noaa-navionics-track.service UMask 0077 "track logger service"
  require_loaded_user_unit_property noaa-navionics-preflight.service UMask 0077 "boot readiness service"
}

require_user_unit_enabled() {
  local unit="$1"
  local label="$2"
  local state
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ require_user_unit_enabled %q %q\n' "$unit" "$label"
    return 0
  fi
  if ! systemctl --user is-enabled --quiet "$unit"; then
    state="$(systemctl --user is-enabled "$unit" 2>&1 || true)"
    cat >&2 <<EOF
Provisioning did not leave $label enabled.
Expected: systemctl --user is-enabled $unit -> enabled
Actual:   ${state:-unknown}
EOF
    exit 2
  fi
}

require_user_unit_active() {
  local unit="$1"
  local label="$2"
  local state
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ require_user_unit_active %q %q\n' "$unit" "$label"
    return 0
  fi
  if ! systemctl --user is-active --quiet "$unit"; then
    state="$(systemctl --user is-active "$unit" 2>&1 || true)"
    cat >&2 <<EOF
Provisioning did not leave $label active.
Expected: systemctl --user is-active $unit -> active
Actual:   ${state:-unknown}
EOF
    exit 2
  fi
}

require_user_unit_result_success() {
  local unit="$1"
  local label="$2"
  local result
  local status
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ require_user_unit_result_success %q %q\n' "$unit" "$label"
    return 0
  fi
  result="$(systemctl --user show "$unit" -p Result --value 2>/dev/null || true)"
  status="$(systemctl --user show "$unit" -p ExecMainStatus --value 2>/dev/null || true)"
  if [[ "$result" != "success" || "$status" != "0" ]]; then
    cat >&2 <<EOF
Provisioning did not leave $label with a successful last run.
Expected: Result=success and ExecMainStatus=0 for $unit
Actual:   Result=${result:-unknown} ExecMainStatus=${status:-unknown}
EOF
    exit 2
  fi
}

status_report="${HOME}/.cache/noaa-navionics/status.json"
launcher_env="${HOME}/.config/noaa-navionics/launcher.env"
autostart_dir="${HOME}/.config/autostart"
autostart_entry="${autostart_dir}/noaa-navionics-chartplotter.desktop"
systemd_user_dir="${HOME}/.config/systemd/user"
chart_service="${systemd_user_dir}/noaa-navionics.service"
chart_timer="${systemd_user_dir}/noaa-navionics.timer"
track_service="${systemd_user_dir}/noaa-navionics-track.service"
preflight_service="${systemd_user_dir}/noaa-navionics-preflight.service"

write_launcher_env() {
  local launcher_env_dir
  local launcher_env_tmp
  validate_user_install_path "$launcher_env" "chartplotter launcher environment"
  if [[ "$dry_run" -eq 1 ]]; then
    printf '+ write %q with NOAA_NAVIONICS_GPS_SECONDS=%q NOAA_NAVIONICS_OPENCPN_RESTARTS=%q NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=%q\n' \
      "$launcher_env" "$gps_seconds" "$opencpn_restarts" "$opencpn_restart_delay"
  else
    launcher_env_dir="$(dirname "$launcher_env")"
    ensure_private_directory "$launcher_env_dir" "chartplotter launcher environment directory"
    launcher_env_tmp="$(mktemp "${launcher_env_dir}/.launcher.env.XXXXXX")"
    if ! printf 'NOAA_NAVIONICS_GPS_SECONDS=%s\nNOAA_NAVIONICS_OPENCPN_RESTARTS=%s\nNOAA_NAVIONICS_OPENCPN_RESTART_DELAY=%s\n' \
      "$gps_seconds" "$opencpn_restarts" "$opencpn_restart_delay" >"$launcher_env_tmp"; then
      rm -f "$launcher_env_tmp"
      return 1
    fi
    if ! chmod 0600 "$launcher_env_tmp"; then
      rm -f "$launcher_env_tmp"
      return 1
    fi
    if ! sync_paths "$launcher_env_tmp"; then
      rm -f "$launcher_env_tmp"
      return 1
    fi
    if ! mv -f "$launcher_env_tmp" "$launcher_env"; then
      rm -f "$launcher_env_tmp"
      return 1
    fi
    sync_paths "$launcher_env"
  fi
}

if same_path "$config" "$default_config"; then
  ensure_private_directory "$(dirname "$config")" "NOAA Navionics config directory"
else
  run mkdir -p "$(dirname "$config")"
fi
if [[ ! -f "$config" ]]; then
  run "$bin" init-config --config "$config"
fi
write_launcher_env

if [[ "$skip_gpsd" -eq 0 ]]; then
  gpsd_args=(--device "$device" --config "$config")
  if [[ "$check_device" -eq 0 ]]; then
    gpsd_args+=(--no-device-check)
  fi
  if [[ "$allow_non_pi" -eq 1 ]]; then
    gpsd_args+=(--allow-non-pi)
  fi
  if [[ "$dry_run" -eq 1 ]]; then
    gpsd_args+=(--dry-run)
  fi
  run "${repo_root}/scripts/configure_gpsd.sh" "${gpsd_args[@]}"
fi

if [[ "$skip_gps_time" -eq 0 ]]; then
  gps_time_args=()
  if [[ "$allow_non_pi" -eq 1 ]]; then
    gps_time_args+=(--allow-non-pi)
  fi
  if [[ "$dry_run" -eq 1 ]]; then
    gps_time_args+=(--dry-run)
  fi
  run "${repo_root}/scripts/configure_gps_time.sh" "${gps_time_args[@]}"
fi

if [[ "$skip_sync" -eq 0 ]]; then
  run "$bin" sync-charts --config "$config" --retries "$sync_retries" --retry-delay "$sync_retry_delay"
fi

run "$bin" configure-opencpn --config "$config"

if [[ "$skip_services" -eq 0 ]]; then
  validate_user_install_path "$chart_service" "chart refresh user service"
  validate_user_install_path "$chart_timer" "chart refresh user timer"
  validate_user_install_path "$track_service" "track logger user service"
  validate_user_install_path "$preflight_service" "boot readiness user service"
  ensure_private_directory "$systemd_user_dir" "user systemd directory"
  install_file_atomic "${repo_root}/systemd/noaa-navionics.service" "$chart_service" 0644
  install_file_atomic "${repo_root}/systemd/noaa-navionics.timer" "$chart_timer" 0644
  install_file_atomic "${repo_root}/systemd/noaa-navionics-track.service" "$track_service" 0644
  install_file_atomic "${repo_root}/systemd/noaa-navionics-preflight.service" "$preflight_service" 0644
  run systemctl --user daemon-reload
  require_loaded_user_units
  run sudo loginctl enable-linger "$USER"
  run systemctl --user reset-failed noaa-navionics.service noaa-navionics-track.service noaa-navionics-preflight.service
  run systemctl --user enable --now noaa-navionics.timer
  run systemctl --user enable --now noaa-navionics-track.service
  run systemctl --user restart noaa-navionics-track.service
  run systemctl --user enable noaa-navionics-preflight.service
  require_user_unit_enabled noaa-navionics.timer "chart refresh timer"
  require_user_unit_enabled noaa-navionics-track.service "track logger service"
  require_user_unit_enabled noaa-navionics-preflight.service "boot readiness service"
  require_user_unit_active noaa-navionics.timer "chart refresh timer"
  require_user_unit_active noaa-navionics-track.service "track logger service"
fi

if [[ "$skip_autologin" -eq 0 ]]; then
  validate_user_install_path "$autostart_entry" "chartplotter desktop autostart"
  ensure_private_directory "$autostart_dir" "desktop autostart directory"
  install_file_atomic "${repo_root}/templates/noaa-navionics-chartplotter.desktop" "$autostart_entry" 0644
  desktop_args=(--user "$USER")
  if [[ "$allow_non_pi" -eq 1 ]]; then
    desktop_args+=(--allow-non-pi)
  fi
  if [[ "$dry_run" -eq 1 ]]; then
    desktop_args+=(--dry-run)
  fi
  run "${repo_root}/scripts/configure_desktop_autologin.sh" "${desktop_args[@]}"
fi

if [[ "$skip_services" -eq 0 ]]; then
  run systemctl --user restart noaa-navionics-preflight.service
  require_user_unit_result_success noaa-navionics-preflight.service "boot readiness service"
fi

run "$bin" status-report --config "$config" --gps-seconds "$gps_seconds" --output "$status_report"

if [[ "$dry_run" -eq 1 ]]; then
  result_label="Dry run complete; no changes were made."
else
  result_label="Provisioning complete."
fi

cat <<EOF
$result_label

Config: $config
Status report: $status_report
Start chartplotter: noaa-navionics-start-chartplotter
EOF
