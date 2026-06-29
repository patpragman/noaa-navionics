#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 -m py_compile src/noaa_navionics/*.py
python3 -m unittest discover -s tests -v

bash -n \
  scripts/install_raspberry_pi.sh \
  scripts/deploy_to_pi.sh \
  scripts/verify_pi.sh \
  scripts/start_chartplotter.sh \
  scripts/configure_gpsd.sh \
  scripts/provision_sailboat_pi.sh \
  scripts/dock_test_pi.sh \
  scripts/check.sh

install_output="$(mktemp)"
provision_output="$(mktemp)"
trap 'rm -rf "${tmpdir:-}" "$install_output" "$provision_output"' EXIT

set +e
scripts/install_raspberry_pi.sh --skip-apt --no-services >"$install_output" 2>&1
install_code=$?
set -e
if [[ "$install_code" -ne 2 ]]; then
  cat "$install_output" >&2
  echo "expected install_raspberry_pi.sh to refuse non-Pi architecture with exit 2" >&2
  exit 1
fi

set +e
scripts/provision_sailboat_pi.sh --device /dev/ttyUSB0 >"$provision_output" 2>&1
provision_code=$?
set -e
if [[ "$provision_code" -ne 2 ]]; then
  cat "$provision_output" >&2
  echo "expected provision_sailboat_pi.sh to refuse non-Pi architecture with exit 2" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
scripts/provision_sailboat_pi.sh \
  --allow-non-pi \
  --dry-run \
  --no-device-check \
  --device /dev/ttyUSB0 \
  --config "$tmpdir/config.ini" \
  --skip-sync >/dev/null

echo "All checks passed."
