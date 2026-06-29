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

validate_gps_device_path_arg() {
  local value="$1"
  local suffix
  if [[ -z "$value" ]]; then
    echo "GPS device path is required" >&2
    exit 2
  fi
  if [[ "$value" =~ [[:space:]\"\'] ]]; then
    echo "GPS device path must not contain whitespace or quotes: $value" >&2
    exit 2
  fi
  case "$value" in
    /dev/serial/by-id/*)
      suffix="${value#/dev/serial/by-id/}"
      if [[ -n "$suffix" && "$suffix" != */* && "$suffix" != "." && "$suffix" != ".." && "$suffix" =~ ^[A-Za-z0-9._:+@-]+$ ]]; then
        return 0
      fi
      ;;
    /dev/serial0|/dev/serial1|/dev/gps)
      return 0
      ;;
    /dev/ttyUSB*|/dev/ttyACM*)
      echo "GPS device path is volatile; use /dev/serial/by-id/... instead: $value" >&2
      exit 2
      ;;
  esac
  echo "GPS device path must be /dev/serial/by-id/..., /dev/serial0, /dev/serial1, or /dev/gps: $value" >&2
  exit 2
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

local_command_exists() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1
}

remote_command_exists() {
  local command_name="$1"
  case "$command_name" in
    python3|rsync|tar)
      ;;
    *)
      echo "Unsupported remote command check: $command_name" >&2
      return 2
      ;;
  esac
  ssh -o ConnectTimeout=10 "$target" "command -v ${command_name} >/dev/null 2>&1"
}

require_remote_command_available() {
  local command_name="$1"
  local status
  if remote_command_exists "$command_name"; then
    return 0
  fi
  status="$?"
  if [[ "$status" -eq 255 ]]; then
    cat >&2 <<EOF
Could not connect to the Pi over SSH while checking for: $command_name
Confirm SSH works, then rerun this script.
EOF
    exit 2
  fi
  if [[ "$command_name" == "python3" ]]; then
    cat >&2 <<EOF
Could not confirm required remote command on the Pi: python3
Install Raspberry Pi OS with Python 3 available, then rerun this script.
EOF
    exit 2
  fi
  cat >&2 <<EOF
Could not confirm required remote command on the Pi: $command_name
Install $command_name on the Pi before deployment, then rerun this script.
EOF
  exit 2
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

quote_remote_dir_for_shell() {
  local value="$1"
  if [[ "$value" == "~/"* ]]; then
    printf '~/%s' "${value#~/}"
  else
    printf '%q' "$value"
  fi
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
      if [[ "$1" == "--device" ]]; then
        validate_gps_device_path_arg "${2:-}"
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
remote_dir_quoted="$(quote_remote_dir_for_shell "$remote_dir")"
remote_dir_trimmed="${remote_dir%/}"
remote_staging_dir="${remote_dir_trimmed}.deploying"
remote_previous_dir="${remote_dir_trimmed}.previous"
remote_staging_dir_quoted="$(quote_remote_dir_for_shell "$remote_staging_dir")"
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
require_remote_command_available python3

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

prepare_remote_deploy_staging() {
  local remote_dir_value="$1"
  local staging_dir_value="$2"
  local previous_dir_value="$3"
  local remote_dir_env
  local staging_dir_env
  local previous_dir_env
  remote_dir_env="$(printf '%q' "$remote_dir_value")"
  staging_dir_env="$(printf '%q' "$staging_dir_value")"
  previous_dir_env="$(printf '%q' "$previous_dir_value")"
  ssh "$target" "NOAA_NAVIONICS_REMOTE_DIR=${remote_dir_env} NOAA_NAVIONICS_STAGING_DIR=${staging_dir_env} NOAA_NAVIONICS_PREVIOUS_DIR=${previous_dir_env} python3 - <<'PY'
from pathlib import Path
import os
import shutil

repo = Path(os.environ['NOAA_NAVIONICS_REMOTE_DIR']).expanduser()
staging = Path(os.environ['NOAA_NAVIONICS_STAGING_DIR']).expanduser()
previous = Path(os.environ['NOAA_NAVIONICS_PREVIOUS_DIR']).expanduser()
name = repo.name
valid_name = (
    name == 'noaa-navionics'
    or name.startswith('noaa-navionics-')
    or name.startswith('noaa-navionics_')
    or name.startswith('noaa-navionics.')
)
if not valid_name:
    raise SystemExit(f'Refusing to stage unexpected deployment directory: {repo}')
if repo.exists() and repo.is_symlink():
    raise SystemExit(f'Refusing to stage over symlink deployment directory: {repo}')
if repo.exists() and not repo.is_dir():
    raise SystemExit(f'Refusing to stage over non-directory deployment path: {repo}')
resolved = repo.resolve(strict=False)
unsafe = {Path('/'), Path.home(), Path('/home'), Path('/root')}
if resolved in unsafe:
    raise SystemExit(f'Refusing to stage broad deployment directory: {repo}')
for sibling in (staging, previous):
    if sibling.parent != repo.parent:
        raise SystemExit(f'Refusing staging path outside deployment parent: {sibling}')
    if not sibling.name.startswith(repo.name + '.'):
        raise SystemExit(f'Refusing unexpected deployment staging path: {sibling}')

def fsync_parent() -> None:
    fd = os.open(repo.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

if not repo.exists() and not repo.is_symlink() and (previous.exists() or previous.is_symlink()):
    if previous.is_symlink() or not previous.is_dir():
        raise SystemExit(f'Refusing to restore non-directory previous deployment path: {previous}')
    previous.rename(repo)
    fsync_parent()
    print(f'Restored previous deployment after interrupted promotion: {repo}', flush=True)

for sibling in (staging, previous):
    if sibling.exists() or sibling.is_symlink():
        if sibling.is_dir() and not sibling.is_symlink():
            shutil.rmtree(sibling)
        else:
            sibling.unlink()
repo.parent.mkdir(parents=True, exist_ok=True)
staging.mkdir(parents=True)
fsync_parent()
PY"
}

promote_remote_deploy_staging() {
  local remote_dir_value="$1"
  local staging_dir_value="$2"
  local previous_dir_value="$3"
  local remote_dir_env
  local staging_dir_env
  local previous_dir_env
  remote_dir_env="$(printf '%q' "$remote_dir_value")"
  staging_dir_env="$(printf '%q' "$staging_dir_value")"
  previous_dir_env="$(printf '%q' "$previous_dir_value")"
  ssh "$target" "NOAA_NAVIONICS_REMOTE_DIR=${remote_dir_env} NOAA_NAVIONICS_STAGING_DIR=${staging_dir_env} NOAA_NAVIONICS_PREVIOUS_DIR=${previous_dir_env} python3 - <<'PY'
from pathlib import Path
import os
import shutil

repo = Path(os.environ['NOAA_NAVIONICS_REMOTE_DIR']).expanduser()
staging = Path(os.environ['NOAA_NAVIONICS_STAGING_DIR']).expanduser()
previous = Path(os.environ['NOAA_NAVIONICS_PREVIOUS_DIR']).expanduser()

def remove_path(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()

if not staging.exists() or not staging.is_dir() or staging.is_symlink():
    raise SystemExit(f'Deployment staging directory is not ready: {staging}')
if staging.parent != repo.parent or previous.parent != repo.parent:
    raise SystemExit('Refusing to promote deployment staging outside deployment parent')
if not staging.name.startswith(repo.name + '.') or not previous.name.startswith(repo.name + '.'):
    raise SystemExit('Refusing to promote unexpected deployment staging paths')
try:
    if previous.exists() or previous.is_symlink():
        remove_path(previous)
    if repo.exists() or repo.is_symlink():
        if repo.is_symlink() or not repo.is_dir():
            raise RuntimeError(f'Refusing to replace non-directory deployment path: {repo}')
        repo.rename(previous)
    staging.rename(repo)
    fd = os.open(repo.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
except Exception:
    if not repo.exists() and previous.exists():
        previous.rename(repo)
        fd = os.open(repo.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    raise
else:
    if previous.exists() or previous.is_symlink():
        remove_path(previous)
    fd = os.open(repo.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY"
}

deploy_with_rsync() {
  prepare_remote_deploy_staging "$remote_dir" "$remote_staging_dir" "$remote_previous_dir"
  rsync -az --delete \
    --exclude '.git/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude '*.egg-info/' \
    --exclude '.pytest_cache/' \
    --exclude '.mypy_cache/' \
    --exclude '.ruff_cache/' \
    --exclude '.venv/' \
    --exclude 'build/' \
    --exclude 'dist/' \
    --exclude 'charts/' \
    --exclude '*.part' \
    --exclude '*.zip' \
    --exclude 'ENCProdCat_19115.xml' \
    "${repo_root}/" "${target}:${remote_staging_dir}/"
  promote_remote_deploy_staging "$remote_dir" "$remote_staging_dir" "$remote_previous_dir"
}

deploy_with_tar() {
  prepare_remote_deploy_staging "$remote_dir" "$remote_staging_dir" "$remote_previous_dir"
  (
    cd "$repo_root"
    tar \
      --exclude='./.git' \
      --exclude='./__pycache__' \
      --exclude='*/__pycache__' \
      --exclude='*.pyc' \
      --exclude='*.egg-info' \
      --exclude='*.egg-info/*' \
      --exclude='./.pytest_cache' \
      --exclude='*/.pytest_cache' \
      --exclude='./.mypy_cache' \
      --exclude='*/.mypy_cache' \
      --exclude='./.ruff_cache' \
      --exclude='*/.ruff_cache' \
      --exclude='./.venv' \
      --exclude='*/.venv' \
      --exclude='./build' \
      --exclude='*/build' \
      --exclude='./dist' \
      --exclude='*/dist' \
      --exclude='./charts' \
      --exclude='*/charts' \
      --exclude='*.part' \
      --exclude='*.zip' \
      --exclude='ENCProdCat_19115.xml' \
      -czf - .
  ) | ssh "$target" "tar -xzf - -C ${remote_staging_dir_quoted}"
  promote_remote_deploy_staging "$remote_dir" "$remote_staging_dir" "$remote_previous_dir"
}

deploy_sources() {
  local rsync_status

  if local_command_exists rsync; then
    if remote_command_exists rsync; then
      deploy_with_rsync
      return 0
    fi
    rsync_status="$?"
    if [[ "$rsync_status" -eq 255 ]]; then
      cat >&2 <<'EOF'
Could not connect to the Pi over SSH while checking for rsync.
Confirm SSH works, then rerun this script.
EOF
      exit 2
    fi
    echo "Remote rsync is unavailable; bootstrapping copy with tar over SSH." >&2
  else
    echo "Local rsync is unavailable; bootstrapping copy with tar over SSH." >&2
  fi

  require_local_command tar
  require_remote_command_available tar
  deploy_with_tar
}

deploy_sources
write_remote_source_revision "$remote_dir" "$source_revision"

remote_install_args=()
for arg in "${install_args[@]}"; do
  remote_install_args+=("$(printf '%q' "$arg")")
done
ssh -T "$target" "cd ${remote_dir_quoted} && scripts/install_raspberry_pi.sh ${remote_install_args[*]}"

if [[ "$provision" -eq 1 ]]; then
  remote_args=()
  for arg in "${provision_args[@]}"; do
    [[ "$arg" == "--provision" ]] && continue
    remote_args+=("$(printf '%q' "$arg")")
  done
  ssh -T "$target" "cd ${remote_dir_quoted} && scripts/provision_sailboat_pi.sh ${remote_args[*]}"
fi
