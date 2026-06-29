#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/dock_test_pi.sh user@raspberrypi.local [remote-dir] --device /dev/serial/by-id/YOUR_GPS [options]

Options:
  --device PATH       Stable GPS device path on the Pi
  --allow-dirty       Allow deploying a dirty local worktree for deliberate test runs
  --skip-deploy       Do not deploy/provision; verify the existing Pi setup
  --no-reboot         Do not reboot; run only the pre-reboot verification
  --timeout SECONDS   Time to wait for SSH after reboot
  --sync-retries N    Chart download attempts during provisioning
  --sync-retry-delay N
                     Seconds between chart download retry attempts

Runs a dock acceptance test over SSH:
deploy/provision, verify, reboot, wait for the Pi, and verify again.
Nothing is installed or enabled on the local computer.
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
remote_dir="~/noaa-navionics"
device=""
skip_deploy=0
no_reboot=0
timeout=180
deploy_args=()
provision_args=()

if [[ $# -gt 0 && "$1" != --* ]]; then
  remote_dir="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      device="$2"
      provision_args+=("--device" "$device")
      shift 2
      ;;
    --sync-retries|--sync-retry-delay)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      provision_args+=("$1" "${2:-}")
      shift 2
      ;;
    --allow-dirty)
      deploy_args+=("$1")
      shift
      ;;
    --skip-deploy)
      skip_deploy=1
      shift
      ;;
    --no-reboot)
      no_reboot=1
      shift
      ;;
    --timeout)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      timeout="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$skip_deploy" -eq 0 && -z "$device" ]]; then
  echo "--device is required unless --skip-deploy is used" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

wait_for_ssh_down() {
  local deadline=$((SECONDS + 60))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" "true" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "warning: SSH did not drop after reboot request; continuing to wait for availability" >&2
}

wait_for_ssh_up() {
  local deadline=$((SECONDS + timeout))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" "true" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  echo "Pi did not return on SSH within ${timeout}s: $target" >&2
  return 1
}

if [[ "$skip_deploy" -eq 0 ]]; then
  "${repo_root}/scripts/deploy_to_pi.sh" "$target" "$remote_dir" "${deploy_args[@]}" --provision "${provision_args[@]}"
fi

printf '\n[verify before reboot]\n'
"${repo_root}/scripts/verify_pi.sh" "$target"

if [[ "$no_reboot" -eq 1 ]]; then
  printf '\nDock test passed without reboot.\n'
  exit 0
fi

printf '\n[reboot]\n'
ssh "$target" "sudo reboot" >/dev/null 2>&1 || true
wait_for_ssh_down
wait_for_ssh_up

printf '\n[verify after reboot]\n'
"${repo_root}/scripts/verify_pi.sh" "$target"

printf '\nDock test passed after reboot.\n'
