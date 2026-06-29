#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  cat >&2 <<'EOF'
Usage: scripts/deploy_to_pi.sh user@raspberrypi.local [remote-dir] [--provision --device /dev/serial/by-id/YOUR_GPS]

Copies this repo to the Raspberry Pi over SSH and runs the Pi installer there.
With --provision, also runs the onboard commissioning sequence on the Pi.
Refuses a dirty local worktree unless --allow-dirty is passed.
Nothing is installed or enabled on the local computer.
EOF
  exit 2
fi

target="$1"
shift
remote_dir="~/noaa-navionics"
provision=0
provision_args=()
install_args=()
saw_provision_option=0
allow_dirty=0
skip_services=0
skip_autologin=0

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
  if [[ "$host_part" == *:* || "$host_part" == */* ]]; then
    echo "SSH target must be plain user@host without paths or ports: $value" >&2
    exit 2
  fi
  if [[ "$user_part" == "root" ]]; then
    cat >&2 <<'EOF'
Do not deploy to root@.
Deploy to the Pi desktop user; remote scripts use sudo only where system changes are required.
EOF
    exit 2
  fi
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

require_local_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required local command: $command_name" >&2
    exit 2
  fi
}

require_remote_command() {
  local command_name="$1"
  if ! ssh -o ConnectTimeout=10 "$target" "command -v ${command_name} >/dev/null 2>&1"; then
    cat >&2 <<EOF
Could not confirm required remote command on the Pi: $command_name
Confirm SSH works and install $command_name on the Pi before deployment, then rerun this script.
EOF
    exit 2
  fi
}

validate_remote_dir() {
  local value="$1"
  local trimmed
  local basename

  trimmed="${value%/}"
  if [[ -z "$trimmed" || "$trimmed" == "." || "$trimmed" == ".." || "$trimmed" == "/" || "$trimmed" == "~" || "$trimmed" == "/home" || "$trimmed" == "/root" ]]; then
    echo "Remote deployment directory must be a dedicated noaa-navionics directory, not: $value" >&2
    exit 2
  fi
  if [[ ! "$value" =~ ^((~)?/)?[A-Za-z0-9._/-]+$ ]]; then
    echo "Remote deployment directory contains unsafe characters: $value" >&2
    exit 2
  fi
  basename="${trimmed##*/}"
  case "$basename" in
    noaa-navionics|noaa-navionics-*|noaa-navionics_*|noaa-navionics.*)
      ;;
    *)
      echo "Remote deployment directory must end in noaa-navionics or a noaa-navionics-* variant: $value" >&2
      exit 2
      ;;
  esac
}

if [[ $# -gt 0 && "$1" != --* ]]; then
  remote_dir="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provision)
      provision=1
      saw_provision_option=1
      provision_args+=("$1")
      shift
      ;;
    --allow-dirty)
      allow_dirty=1
      shift
      ;;
    --device|--config)
      saw_provision_option=1
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      provision_args+=("$1" "${2:-}")
      shift 2
      ;;
    --gps-seconds|--sync-retries)
      saw_provision_option=1
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_integer "$1" "${2:-}"
      provision_args+=("$1" "${2:-}")
      shift 2
      ;;
    --sync-retry-delay)
      saw_provision_option=1
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_non_negative_integer "$1" "${2:-}"
      provision_args+=("$1" "${2:-}")
      shift 2
      ;;
    --skip-services)
      saw_provision_option=1
      skip_services=1
      provision_args+=("$1")
      install_args+=("--no-services")
      shift
      ;;
    --skip-autologin)
      saw_provision_option=1
      skip_autologin=1
      provision_args+=("$1")
      install_args+=("$1")
      shift
      ;;
    --skip-gpsd|--skip-sync|--skip-gps-time|--no-device-check)
      saw_provision_option=1
      provision_args+=("$1")
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

validate_ssh_target "$target"

if [[ "$saw_provision_option" -eq 1 && "$provision" -eq 0 ]]; then
  echo "Provisioning options require --provision" >&2
  exit 2
fi

if [[ "$skip_services" -eq 1 && "$skip_autologin" -eq 0 ]]; then
  cat >&2 <<'EOF'
--skip-services requires --skip-autologin.
Skipping only user services can leave desktop chartplotter autostart enabled without the readiness and track-logging services.
EOF
  exit 2
fi

validate_remote_dir "$remote_dir"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
remote_dir_quoted="$(printf '%q' "$remote_dir")"
source_revision="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
worktree_status="$(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null || true)"
if [[ "$source_revision" != "unknown" && -n "$worktree_status" ]]; then
  if [[ "$allow_dirty" -eq 0 ]]; then
    cat >&2 <<EOF
Refusing to deploy a dirty worktree.
Commit or stash local changes first, or pass --allow-dirty to deploy them and record ${source_revision}-dirty.
EOF
    exit 2
  fi
  source_revision="${source_revision}-dirty"
fi

require_local_command ssh
require_local_command rsync
require_remote_command rsync

write_remote_source_revision() {
  local remote_dir_value="$1"
  local revision_value="$2"
  local remote_dir_env
  local revision_env
  remote_dir_env="$(printf '%q' "$remote_dir_value")"
  revision_env="$(printf '%q' "$revision_value")"
  ssh "$target" "NOAA_NAVIONICS_REMOTE_DIR=${remote_dir_env} NOAA_NAVIONICS_SOURCE_REVISION=${revision_env} python3 - <<'PY'
from pathlib import Path
import os
import tempfile

repo = Path(os.environ['NOAA_NAVIONICS_REMOTE_DIR']).expanduser()
revision = os.environ['NOAA_NAVIONICS_SOURCE_REVISION'].strip() or 'unknown'
repo.mkdir(parents=True, exist_ok=True)
target = repo / '.source-revision'
tmp_path = None
try:
    with tempfile.NamedTemporaryFile(
        'w',
        encoding='utf-8',
        dir=repo,
        prefix='.source-revision.',
        suffix='.part',
        delete=False,
    ) as handle:
        tmp_path = Path(handle.name)
        handle.write(revision + '\n')
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp_path, target)
    fd = os.open(repo, os.O_RDONLY)
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
PY"
}

ssh "$target" "mkdir -p ${remote_dir_quoted}"
rsync -az --delete \
  --exclude '.git/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '.pytest_cache/' \
  --exclude 'charts/' \
  "${repo_root}/" "${target}:${remote_dir}/"
write_remote_source_revision "$remote_dir" "$source_revision"

remote_install_args=()
for arg in "${install_args[@]}"; do
  remote_install_args+=("$(printf '%q' "$arg")")
done
ssh -t "$target" "cd ${remote_dir_quoted} && scripts/install_raspberry_pi.sh ${remote_install_args[*]}"

if [[ "$provision" -eq 1 ]]; then
  remote_args=()
  for arg in "${provision_args[@]}"; do
    [[ "$arg" == "--provision" ]] && continue
    remote_args+=("$(printf '%q' "$arg")")
  done
  ssh -t "$target" "cd ${remote_dir_quoted} && scripts/provision_sailboat_pi.sh ${remote_args[*]}"
fi
