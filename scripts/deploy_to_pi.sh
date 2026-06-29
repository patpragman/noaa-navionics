#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  cat >&2 <<'EOF'
Usage: scripts/deploy_to_pi.sh user@raspberrypi.local [remote-dir] [--provision --device /dev/serial/by-id/YOUR_GPS]

Copies this repo to the Raspberry Pi over SSH and runs the Pi installer there.
With --provision, also runs the onboard commissioning sequence on the Pi.
Nothing is installed or enabled on the local computer.
EOF
  exit 2
fi

target="$1"
shift
remote_dir="~/noaa-navionics"
provision=0
provision_args=()
saw_provision_option=0

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
    --device|--config|--gps-seconds|--sync-retries|--sync-retry-delay)
      saw_provision_option=1
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      provision_args+=("$1" "${2:-}")
      shift 2
      ;;
    --skip-gpsd|--skip-sync|--skip-services|--no-device-check)
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

if [[ "$saw_provision_option" -eq 1 && "$provision" -eq 0 ]]; then
  echo "Provisioning options require --provision" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
remote_dir_quoted="$(printf '%q' "$remote_dir")"
source_revision="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

ssh "$target" "mkdir -p ${remote_dir_quoted}"
rsync -az --delete \
  --exclude '.git/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '.pytest_cache/' \
  --exclude 'charts/' \
  "${repo_root}/" "${target}:${remote_dir}/"
printf '%s\n' "$source_revision" | ssh "$target" "cat > ${remote_dir_quoted}/.source-revision"

ssh -t "$target" "cd ${remote_dir_quoted} && scripts/install_raspberry_pi.sh"

if [[ "$provision" -eq 1 ]]; then
  remote_args=()
  for arg in "${provision_args[@]}"; do
    [[ "$arg" == "--provision" ]] && continue
    remote_args+=("$(printf '%q' "$arg")")
  done
  ssh -t "$target" "cd ${remote_dir_quoted} && scripts/provision_sailboat_pi.sh ${remote_args[*]}"
fi
