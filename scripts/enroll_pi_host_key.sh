#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/enroll_pi_host_key.sh user@raspberrypi.local --expected-sha256 SHA256:FINGERPRINT [options]

Scans the Pi SSH host key, verifies it against a fingerprint from a trusted
channel, and writes only matching key lines to known_hosts.

Options:
  --expected-sha256 VALUE  Required trusted host-key fingerprint
  --known-hosts PATH       known_hosts file to update (default: ~/.ssh/known_hosts)
  --port N                 SSH port to scan (default: 22)
  --dry-run                Print matching key lines without updating known_hosts

Get the expected fingerprint from the Pi console or another trusted channel:
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
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
expected_sha256=""
known_hosts="${HOME}/.ssh/known_hosts"
port=22
dry_run=0
host_part=""
ssh_keyscan_cmd=""
ssh_keygen_cmd=""
python3_cmd=""

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
  local mode
  local mode_tail
  local owner_uid
  local stat_output

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

  if [[ "${NOAA_NAVIONICS_ALLOW_UNTRUSTED_LOCAL_COMMANDS:-0}" == "1" ]]; then
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

validate_ssh_target() {
  local value="$1"
  local user_part
  local host_lower

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
  host_lower="${host_part,,}"
  case "$host_lower" in
    localhost|localhost.localdomain|*.localhost|ip6-localhost|ip6-loopback|loopback|127.*|0|0.0.0.0)
      echo "SSH target must not point at this computer or loopback: $host_part" >&2
      exit 2
      ;;
  esac
  if [[ "$user_part" == "root" ]]; then
    cat >&2 <<'EOF'
Do not enroll a host key using root@.
Use the Pi desktop user so the enrollment command matches the deployment and verification target.
EOF
    exit 2
  fi
}

require_positive_port() {
  local value="$1"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ || "$value" -gt 65535 ]]; then
    echo "--port must be an integer from 1 to 65535" >&2
    exit 2
  fi
}

validate_expected_sha256() {
  local value="$1"
  if [[ ! "$value" =~ ^SHA256:[A-Za-z0-9+/]{20,}$ ]]; then
    echo "--expected-sha256 must look like an OpenSSH SHA256 fingerprint: SHA256:..." >&2
    exit 2
  fi
}

reject_symlinked_path_components() {
  local label="$1"
  local path="$2"
  local current
  local component
  local remaining

  if [[ "$path" == /* ]]; then
    current="/"
    remaining="${path#/}"
  else
    current="."
    remaining="$path"
  fi

  while [[ -n "$remaining" ]]; do
    component="${remaining%%/*}"
    if [[ "$component" == "$remaining" ]]; then
      remaining=""
    else
      remaining="${remaining#*/}"
    fi
    if [[ -z "$component" || "$component" == "." ]]; then
      continue
    fi
    if [[ "$current" == "/" ]]; then
      current="/$component"
    else
      current="${current}/${component}"
    fi
    if [[ -L "$current" ]]; then
      echo "$label path contains a symlink: $current" >&2
      exit 2
    fi
  done
}

prepare_known_hosts_file() {
  local path="$1"
  local status
  set +e
  "$python3_cmd" - "$path" <<'PY'
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
if not path.is_absolute():
    path = Path.cwd() / path
parent = path.parent
nofollow = getattr(os, "O_NOFOLLOW", 0)
directory_flag = getattr(os, "O_DIRECTORY", 0)


def reject_symlinked_components(label: str, target: Path) -> None:
    parts = target.parts
    if target.is_absolute():
        current = Path(parts[0])
        iterable = parts[1:]
    else:
        current = Path(".")
        iterable = parts
    for part in iterable:
        if part in ("", "."):
            continue
        current = current / part
        try:
            st = os.lstat(current)
        except FileNotFoundError:
            continue
        except OSError as exc:
            print(f"Could not inspect {label} path component {current}: {exc}", file=sys.stderr)
            raise SystemExit(124) from exc
        if stat.S_ISLNK(st.st_mode):
            print(f"{label} path contains a symlink: {current}", file=sys.stderr)
            raise SystemExit(124)


def require_private_dir(target: Path) -> os.stat_result:
    try:
        before = os.stat(target, follow_symlinks=False)
    except OSError as exc:
        print(f"Could not inspect known_hosts directory owner and permissions: {target}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    if not stat.S_ISDIR(before.st_mode):
        print(f"known_hosts directory must be a real directory: {target}", file=sys.stderr)
        raise SystemExit(124)
    if before.st_uid != os.getuid():
        print(
            f"known_hosts directory is owned by uid {before.st_uid}, expected current user {os.getuid()}: {target}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    mode = stat.S_IMODE(before.st_mode)
    if mode != 0o700:
        print(f"known_hosts directory has permissions {mode:04o}, expected private 0700: {target}", file=sys.stderr)
        raise SystemExit(124)
    return before


reject_symlinked_components("known_hosts", parent)
try:
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(parent, 0o700, follow_symlinks=False)
except OSError as exc:
    print(f"Could not create or tighten known_hosts directory {parent}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
reject_symlinked_components("known_hosts", path)
parent_before = require_private_dir(parent)

try:
    parent_fd = os.open(parent, os.O_RDONLY | directory_flag | nofollow)
except OSError as exc:
    print(f"Could not open known_hosts directory safely {parent}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
try:
    opened_parent = os.fstat(parent_fd)
    if not os.path.samestat(parent_before, opened_parent):
        print(f"known_hosts directory changed while opening it: {parent}", file=sys.stderr)
        raise SystemExit(124)
    flags = os.O_RDWR | os.O_CREAT | nofollow
    try:
        fd = os.open(path.name, flags, 0o600, dir_fd=parent_fd)
    except OSError as exc:
        print(f"Could not open known_hosts through no-follow descriptor {path}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            print(f"known_hosts must be a regular non-symlink file: {path}", file=sys.stderr)
            raise SystemExit(124)
        if opened.st_uid != os.getuid():
            print(
                f"known_hosts is owned by uid {opened.st_uid}, expected current user {os.getuid()}: {path}",
                file=sys.stderr,
            )
            raise SystemExit(124)
        os.fchmod(fd, 0o600)
        opened = os.fstat(fd)
        mode = stat.S_IMODE(opened.st_mode)
        if mode != 0o600:
            print(f"known_hosts has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
            raise SystemExit(124)
        os.fsync(fd)
        os.fsync(parent_fd)
    except OSError as exc:
        print(f"Could not validate known_hosts {path}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    finally:
        os.close(fd)
finally:
    os.close(parent_fd)
PY
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

append_verified_known_hosts() {
  local path="$1"
  local match_file="$2"
  local status
  set +e
  "$python3_cmd" - "$path" "$match_file" <<'PY'
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
if not path.is_absolute():
    path = Path.cwd() / path
match_file = Path(sys.argv[2])
parent = path.parent
nofollow = getattr(os, "O_NOFOLLOW", 0)
directory_flag = getattr(os, "O_DIRECTORY", 0)

try:
    parent_before = os.stat(parent, follow_symlinks=False)
except OSError as exc:
    print(f"Could not inspect known_hosts directory before append {parent}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
if not stat.S_ISDIR(parent_before.st_mode):
    print(f"known_hosts directory must be a real directory before append: {parent}", file=sys.stderr)
    raise SystemExit(124)
if parent_before.st_uid != os.getuid() or stat.S_IMODE(parent_before.st_mode) != 0o700:
    print(f"known_hosts directory must be current-user-owned private 0700 before append: {parent}", file=sys.stderr)
    raise SystemExit(124)

try:
    data = match_file.read_bytes()
except OSError as exc:
    print(f"Could not read verified host-key matches {match_file}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
if not data:
    print(f"verified host-key match file is empty: {match_file}", file=sys.stderr)
    raise SystemExit(124)
if not data.endswith(b"\n"):
    data += b"\n"

try:
    parent_fd = os.open(parent, os.O_RDONLY | directory_flag | nofollow)
except OSError as exc:
    print(f"Could not open known_hosts directory safely before append {parent}: {exc}", file=sys.stderr)
    raise SystemExit(124) from exc
try:
    opened_parent = os.fstat(parent_fd)
    if not os.path.samestat(parent_before, opened_parent):
        print(f"known_hosts directory changed before append: {parent}", file=sys.stderr)
        raise SystemExit(124)
    try:
        before = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        fd = os.open(path.name, os.O_WRONLY | os.O_APPEND | nofollow, dir_fd=parent_fd)
    except OSError as exc:
        print(f"Could not open known_hosts through no-follow append descriptor {path}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            print(f"known_hosts changed before append: {path}", file=sys.stderr)
            raise SystemExit(124)
        if not stat.S_ISREG(opened.st_mode):
            print(f"known_hosts must be a regular file before append: {path}", file=sys.stderr)
            raise SystemExit(124)
        if opened.st_uid != os.getuid() or stat.S_IMODE(opened.st_mode) != 0o600:
            print(f"known_hosts must be current-user-owned private 0600 before append: {path}", file=sys.stderr)
            raise SystemExit(124)
        os.write(fd, data)
        os.fsync(fd)
    except OSError as exc:
        print(f"Could not append verified host key to known_hosts {path}: {exc}", file=sys.stderr)
        raise SystemExit(124) from exc
    finally:
        os.close(fd)
finally:
    os.close(parent_fd)
PY
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    exit 2
  fi
  return "$status"
}

private_temp_identity() {
  local path="$1"
  local label="$2"
  "$python3_cmd" - "$path" "$label" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
label = sys.argv[2]
try:
    st = os.stat(path, follow_symlinks=False)
except OSError as exc:
    print(f"Could not inspect {label}: {path}: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
if stat.S_ISLNK(st.st_mode):
    print(f"{label} is a symlink: {path}", file=sys.stderr)
    raise SystemExit(1)
if not stat.S_ISREG(st.st_mode):
    print(f"{label} is not a regular file: {path}", file=sys.stderr)
    raise SystemExit(1)
if st.st_uid != os.getuid():
    print(f"{label} is owned by uid {st.st_uid}, expected current user {os.getuid()}: {path}", file=sys.stderr)
    raise SystemExit(1)
mode = stat.S_IMODE(st.st_mode)
if mode != 0o600:
    print(f"{label} has permissions {mode:04o}, expected private 0600: {path}", file=sys.stderr)
    raise SystemExit(1)
print(f"{st.st_dev}:{st.st_ino}")
PY
}

cleanup_private_host_key_temp() {
  local path="$1"
  local identity="$2"
  local label="$3"
  [[ -n "$path" && -n "$identity" ]] || return 0
  "$python3_cmd" - "$path" "$identity" "$label" <<'PY'
from pathlib import Path
import os
import stat
import sys

path = Path(sys.argv[1])
identity = sys.argv[2]
label = sys.argv[3]
try:
    expected_dev_text, expected_ino_text = identity.split(":", 1)
    expected_dev = int(expected_dev_text)
    expected_ino = int(expected_ino_text)
except ValueError:
    print(f"{label} cleanup identity is invalid; leaving it in place: {path}", file=sys.stderr)
    raise SystemExit(0)

nofollow = getattr(os, "O_NOFOLLOW", 0)
directory = getattr(os, "O_DIRECTORY", 0)
opath = getattr(os, "O_PATH", os.O_RDONLY)

try:
    parent_fd = os.open(path.parent, os.O_RDONLY | directory | nofollow)
except FileNotFoundError:
    raise SystemExit(0)
except OSError as exc:
    print(f"Could not open {label} directory for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
    raise SystemExit(0)

try:
    try:
        before = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    except OSError as exc:
        print(f"Could not inspect {label} before cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
        raise SystemExit(0)
    if (before.st_dev, before.st_ino) != (expected_dev, expected_ino):
        print(f"{label} changed before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    if stat.S_ISLNK(before.st_mode):
        print(f"{label} became a symlink before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    if not stat.S_ISREG(before.st_mode):
        print(f"{label} is not a regular file before cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    if before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600:
        print(f"{label} is no longer a trusted private temp file; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    try:
        fd = os.open(path.name, opath | nofollow, dir_fd=parent_fd)
    except FileNotFoundError:
        raise SystemExit(0)
    except OSError as exc:
        print(f"Could not open {label} for cleanup; leaving it in place: {path}: {exc}", file=sys.stderr)
        raise SystemExit(0)
    try:
        opened = os.fstat(fd)
    finally:
        os.close(fd)
    if not os.path.samestat(before, opened):
        print(f"{label} changed while opening for cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    try:
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    if not os.path.samestat(before, current):
        print(f"{label} changed before unlink cleanup; leaving it in place: {path}", file=sys.stderr)
        raise SystemExit(0)
    os.unlink(path.name, dir_fd=parent_fd)
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
PY
}

host_marker() {
  if [[ "$port" == "22" ]]; then
    printf '%s\n' "$host_part"
  else
    printf '[%s]:%s\n' "$host_part" "$port"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-sha256)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      expected_sha256="${2:-}"
      shift 2
      ;;
    --known-hosts)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      known_hosts="${2:-}"
      shift 2
      ;;
    --port)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$1 requires a value" >&2
        exit 2
      fi
      require_positive_port "${2:-}"
      port="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

validate_ssh_target "$target"
if [[ -z "$expected_sha256" ]]; then
  echo "--expected-sha256 is required; get it from the Pi console or another trusted channel" >&2
  exit 2
fi
validate_expected_sha256 "$expected_sha256"
require_positive_port "$port"

ssh_keyscan_cmd="$(require_local_command ssh-keyscan)"
ssh_keygen_cmd="$(require_local_command ssh-keygen)"
python3_cmd="$(require_local_command python3)"

scan_path="$(mktemp)"
match_path="$(mktemp)"
one_key_path="$(mktemp)"
scan_identity="$(private_temp_identity "$scan_path" "SSH host-key scan temp")"
match_identity="$(private_temp_identity "$match_path" "SSH host-key match temp")"
one_key_identity="$(private_temp_identity "$one_key_path" "SSH host-key one-key temp")"
cleanup() {
  cleanup_private_host_key_temp "$scan_path" "$scan_identity" "SSH host-key scan temp" || true
  cleanup_private_host_key_temp "$match_path" "$match_identity" "SSH host-key match temp" || true
  cleanup_private_host_key_temp "$one_key_path" "$one_key_identity" "SSH host-key one-key temp" || true
}
trap cleanup EXIT

if ! "$ssh_keyscan_cmd" -T 10 -p "$port" "$host_part" >"$scan_path" 2>/dev/null || [[ ! -s "$scan_path" ]]; then
  echo "Could not scan SSH host keys from ${host_part}:${port}" >&2
  exit 1
fi

printf 'Scanned SSH host key fingerprints for %s:%s:\n' "$host_part" "$port"
"$ssh_keygen_cmd" -lf "$scan_path" -E sha256

while IFS= read -r key_line; do
  [[ -z "$key_line" || "$key_line" == \#* ]] && continue
  printf '%s\n' "$key_line" >"$one_key_path"
  keygen_output="$("$ssh_keygen_cmd" -lf "$one_key_path" -E sha256 2>/dev/null || true)"
  [[ -z "$keygen_output" ]] && continue
  read -r _bits fingerprint _rest <<<"$keygen_output"
  if [[ "$fingerprint" == "$expected_sha256" ]]; then
    printf '%s\n' "$key_line" >>"$match_path"
  fi
done <"$scan_path"

if [[ ! -s "$match_path" ]]; then
  echo "No scanned SSH host key matched expected fingerprint: $expected_sha256" >&2
  exit 1
fi

printf '\nVerified matching known_hosts line(s):\n'
cat "$match_path"

if [[ "$dry_run" -eq 1 ]]; then
  printf '\nDry run only; known_hosts was not changed.\n'
  exit 0
fi

prepare_known_hosts_file "$known_hosts"
marker="$(host_marker)"
"$ssh_keygen_cmd" -R "$marker" -f "$known_hosts" >/dev/null 2>&1 || true
prepare_known_hosts_file "$known_hosts"
append_verified_known_hosts "$known_hosts" "$match_path"
printf '\nEnrolled verified SSH host key for %s in %s.\n' "$marker" "$known_hosts"
