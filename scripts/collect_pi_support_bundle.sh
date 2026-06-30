#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/collect_pi_support_bundle.sh user@raspberrypi.local [output-dir]

Collects a read-only diagnostic bundle from an already commissioned
Raspberry Pi over SSH. The bundle includes NOAA Navionics config,
status reports, launcher logs, installed user units, selected OpenCPN/GPSD/
chrony/LightDM config files when readable, recent relevant journal output,
service state, device listings, disk space, and Pi health command output.

The script writes a .tgz bundle into output-dir, or ./pi-support-bundles
by default.
Nothing is installed, enabled, rebooted, downloaded, or changed on the
local computer. The Pi-side temporary collection directory is removed before
the SSH session exits.
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

target="$1"
shift
output_dir="${1:-pi-support-bundles}"
if [[ $# -gt 1 ]]; then
  echo "Unexpected extra arguments" >&2
  usage
  exit 2
fi

ssh_cmd=""
ssh_batch_options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
remote_system_path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

validate_ssh_target() {
  local value="$1"
  local user_part
  local host_part

  if [[ -z "$value" ]]; then
    echo "SSH target is required" >&2
    exit 2
  fi
  if [[ "$value" == -* ]]; then
    echo "SSH target must not begin with '-': $value" >&2
    exit 2
  fi
  if [[ "$value" =~ [[:space:]\"\'] ]]; then
    echo "SSH target must not contain whitespace or quotes: $value" >&2
    exit 2
  fi
  if [[ "$value" != *@* ]]; then
    echo "SSH target must be user@host: $value" >&2
    exit 2
  fi
  user_part="${value%@*}"
  host_part="${value#*@}"
  if [[ -z "$user_part" || -z "$host_part" ]]; then
    echo "SSH target must be user@host: $value" >&2
    exit 2
  fi
  if [[ ! "$user_part" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]; then
    echo "SSH target user contains unsafe characters: $user_part" >&2
    exit 2
  fi
  if [[ "$host_part" == *:* || "$host_part" == */* ]]; then
    echo "SSH target must be plain user@host without paths or ports: $value" >&2
    exit 2
  fi
  if [[ ! "$host_part" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    echo "SSH target host contains unsafe characters: $host_part" >&2
    exit 2
  fi
  if [[ "$user_part" == "root" ]]; then
    cat >&2 <<'EOF'
Do not collect support bundles as root@.
Use the Pi desktop user so user services, charts, and logs are collected for the real helm account.
EOF
    exit 2
  fi
}

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
  local stat_output
  local owner_uid
  local mode
  local mode_tail

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

  if [[ "${NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS:-0}" == "1" || ( "$command_name" == "ssh" && "${NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_SSH:-0}" == "1" ) ]]; then
    return 0
  fi
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

validate_output_dir_arg() {
  local value="$1"
  if [[ -z "$value" ]]; then
    echo "Output directory is required" >&2
    exit 2
  fi
  if [[ "$value" =~ [\"\'] ]]; then
    echo "Output directory must not contain quotes: $value" >&2
    exit 2
  fi
  if [[ -L "$value" ]]; then
    echo "Output directory must not be a symlink: $value" >&2
    exit 2
  fi
}

validate_ssh_target "$target"
validate_output_dir_arg "$output_dir"
ssh_cmd="$(require_local_command ssh)"

mkdir -p -- "$output_dir"
if [[ ! -d "$output_dir" || -L "$output_dir" ]]; then
  echo "Output path must be a real directory: $output_dir" >&2
  exit 2
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_target="$(printf '%s' "$target" | tr '@.' '___')"
bundle_path="${output_dir}/noaa-navionics-pi-support-${safe_target}-${timestamp}.tgz"
if [[ -e "$bundle_path" ]]; then
  echo "Refusing to overwrite existing bundle: $bundle_path" >&2
  exit 2
fi
partial_path="$(mktemp "${output_dir}/.${timestamp}.support-bundle.XXXXXX")"
cleanup_partial() {
  rm -f -- "$partial_path"
}
trap cleanup_partial EXIT

"$ssh_cmd" -T "${ssh_batch_options[@]}" "$target" "${remote_system_path} && export PATH && bash -s" >"$partial_path" <<'REMOTE'
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

bundle_root="${HOME}/.cache/noaa-navionics/support-bundle.$$"
files_dir="${bundle_root}/files"
commands_dir="${bundle_root}/commands"
mkdir -p "$files_dir" "$commands_dir"
cleanup_remote_bundle() {
  rm -rf -- "$bundle_root"
}
trap cleanup_remote_bundle EXIT

write_note() {
  printf '%s\n' "$*" >>"${commands_dir}/collection-notes.txt"
}

copy_regular_if_readable() {
  local src="$1"
  local dest
  if [[ -L "$src" ]]; then
    write_note "skipped symlink: $src"
    return 0
  fi
  if [[ ! -e "$src" ]]; then
    write_note "missing: $src"
    return 0
  fi
  if [[ ! -f "$src" ]]; then
    write_note "skipped non-regular file: $src"
    return 0
  fi
  dest="${files_dir}${src}"
  mkdir -p -- "$(dirname -- "$dest")"
  if cp -p -- "$src" "$dest" 2>"${dest}.copy-error"; then
    rm -f -- "${dest}.copy-error"
  else
    write_note "could not copy: $src"
  fi
}

run_command() {
  local name="$1"
  shift
  local output="${commands_dir}/${name}.txt"
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } >"$output" 2>&1 || {
    local status=$?
    printf '\n(command exited %s)\n' "$status" >>"$output"
  }
}

copy_glob() {
  local matched=0
  local path
  for path in "$@"; do
    if [[ -e "$path" || -L "$path" ]]; then
      matched=1
      copy_regular_if_readable "$path"
    fi
  done
  if [[ "$matched" -eq 0 ]]; then
    write_note "no files matched: $*"
  fi
}

collect_configured_storage_metadata() {
  local config="${HOME}/.config/noaa-navionics/config.ini"
  local path_report="${commands_dir}/configured-storage-paths.txt"
  local key
  local value

  if ! command -v python3 >/dev/null 2>&1; then
    write_note "python3 missing; could not parse configured chart and track paths"
    return 0
  fi
  if [[ ! -f "$config" || -L "$config" ]]; then
    write_note "onboard config missing or symlinked; could not parse configured chart and track paths"
    return 0
  fi
  if ! python3 - "$config" >"$path_report" <<'PY'
from configparser import ConfigParser
from pathlib import Path
import os
import sys

config_path = Path(sys.argv[1]).expanduser()
parser = ConfigParser()
parser.read(config_path)
chart_text = parser.get("charts", "output", fallback="~/charts/noaa-enc")
chart_output = Path(os.path.expanduser(chart_text))
track_text = parser.get("tracking", "output", fallback=str(chart_output))
track_output = Path(os.path.expanduser(track_text))
print(f"chart_output\t{chart_output}")
print(f"chart_manifest\t{chart_output / 'noaa-navionics-manifest.json'}")
print(f"track_output\t{track_output}")
print(f"track_directory\t{track_output / 'tracks'}")
PY
  then
    write_note "could not parse onboard config for chart and track paths"
    return 0
  fi

  while IFS=$'\t' read -r key value; do
    case "$key" in
      chart_manifest)
        copy_regular_if_readable "$value"
        ;;
      chart_output)
        run_command configured-chart-storage-tree bash -lc 'find "$1" -maxdepth 2 -mindepth 1 -ls 2>&1 || true' _ "$value"
        ;;
      track_output)
        run_command configured-track-storage-tree bash -lc 'find "$1" -maxdepth 2 -mindepth 1 \( -type d -o -name "*.gpx" \) -ls 2>&1 || true' _ "$value"
        ;;
    esac
  done <"$path_report"
}

copy_regular_if_readable "${HOME}/.config/noaa-navionics/config.ini"
copy_regular_if_readable "${HOME}/.config/noaa-navionics/launcher.env"
copy_regular_if_readable "${HOME}/.cache/noaa-navionics/status.json"
copy_regular_if_readable "${HOME}/.cache/noaa-navionics/chartplotter.log"
copy_regular_if_readable "${HOME}/.cache/noaa-navionics/chartplotter.log.1"
copy_regular_if_readable "${HOME}/.local/share/noaa-navionics/source-revision"
copy_regular_if_readable "${HOME}/.opencpn/opencpn.conf"
copy_regular_if_readable "${HOME}/.config/autostart/noaa-navionics-chartplotter.desktop"
copy_glob "${HOME}"/.config/systemd/user/noaa-navionics*.service "${HOME}"/.config/systemd/user/noaa-navionics*.timer
copy_regular_if_readable /etc/default/gpsd
copy_regular_if_readable /etc/chrony/conf.d/noaa-navionics-gpsd.conf
copy_regular_if_readable /etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf
collect_configured_storage_metadata

run_command date-utc date -u
run_command uname uname -a
run_command hostname hostname
run_command uptime uptime
run_command df df -h
run_command mount-findmnt findmnt
run_command serial-devices bash -lc 'ls -l /dev/serial /dev/serial/by-id 2>&1 || true'
run_command noaa-cache-tree bash -lc 'find "$HOME/.cache/noaa-navionics" -maxdepth 3 -mindepth 1 -ls 2>&1 || true'
run_command noaa-config-tree bash -lc 'find "$HOME/.config/noaa-navionics" -maxdepth 3 -mindepth 1 -ls 2>&1 || true'
run_command noaa-data-tree bash -lc 'find "$HOME/.local/share/noaa-navionics" -maxdepth 3 -mindepth 1 -ls 2>&1 || true'
run_command user-units systemctl --user --no-pager status noaa-navionics.timer noaa-navionics.service noaa-navionics-track.service noaa-navionics-preflight.service
run_command user-timers systemctl --user --no-pager list-timers noaa-navionics.timer
run_command user-unit-files systemctl --user --no-pager list-unit-files 'noaa-navionics*'
run_command system-services systemctl --no-pager status gpsd.socket gpsd.service chrony.service lightdm.service
run_command chrony-sources chronyc sources -v
run_command timedatectl timedatectl
run_command pi-throttling bash -lc 'if command -v vcgencmd >/dev/null 2>&1; then vcgencmd get_throttled && vcgencmd measure_temp; else echo "vcgencmd missing"; fi'
run_command recent-user-journal bash -lc 'journalctl --user --no-pager --since "-2 days" -u noaa-navionics.service -u noaa-navionics.timer -u noaa-navionics-track.service -u noaa-navionics-preflight.service 2>&1 || true'
run_command recent-system-journal bash -lc 'journalctl --no-pager --since "-2 days" -u gpsd.socket -u gpsd.service -u chrony.service -u lightdm.service 2>&1 || true'

printf 'NOAA Navionics Raspberry Pi support bundle\n' >"${bundle_root}/README.txt"
printf 'Collected: ' >>"${bundle_root}/README.txt"
date -u >>"${bundle_root}/README.txt"
printf 'Target user: %s\n' "$(id -un 2>/dev/null || printf unknown)" >>"${bundle_root}/README.txt"
printf 'This bundle is diagnostic evidence only. It includes configured chart manifests and storage listings. It does not include downloaded NOAA chart archives, extracted ENC cells, or GPX track contents by default.\n' >>"${bundle_root}/README.txt"

tar -C "$bundle_root" -czf - .
REMOTE

if [[ ! -s "$partial_path" ]]; then
  echo "Collected bundle is empty" >&2
  exit 1
fi
mv -- "$partial_path" "$bundle_path"
trap - EXIT

printf 'Collected Pi support bundle: %s\n' "$bundle_path"
