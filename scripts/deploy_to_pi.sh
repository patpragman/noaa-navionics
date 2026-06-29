#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  cat >&2 <<'EOF'
Usage: scripts/deploy_to_pi.sh user@raspberrypi.local [remote-dir]

Copies this repo to the Raspberry Pi over SSH and runs the Pi installer there.
Nothing is installed or enabled on the local computer.
EOF
  exit 2
fi

target="$1"
remote_dir="${2:-~/noaa-navionics}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
remote_dir_quoted="$(printf '%q' "$remote_dir")"

ssh "$target" "mkdir -p ${remote_dir_quoted}"
rsync -az --delete \
  --exclude '.git/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '.pytest_cache/' \
  --exclude 'charts/' \
  "${repo_root}/" "${target}:${remote_dir}/"

ssh -t "$target" "cd ${remote_dir_quoted} && scripts/install_raspberry_pi.sh"
