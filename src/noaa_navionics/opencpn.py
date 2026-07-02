from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
import os
import re
import stat
import tempfile

from ._safeio import cleanup_private_temp_file


DEFAULT_OPENCPN_CONFIG_PATH = Path("~/.opencpn/opencpn.conf")
FLATPAK_OPENCPN_CONFIG_PATH = Path("~/.var/app/org.opencpn.OpenCPN/config/opencpn/opencpn.conf")

_SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*$")
_CHART_DIR_RE = re.compile(r"^\s*ChartDir(\d+)\s*=\s*(.*?)\s*$")
_DATA_CONNECTIONS_RE = re.compile(r"^\s*DataConnections\s*=\s*(.*?)\s*$")
_NMEA_DATA_SOURCE_SECTION = "Settings/NMEADataSource"


@dataclass(frozen=True)
class OpenCPNConfigResult:
    config_path: Path
    chart_dir: Path
    changed: bool
    key: str
    backup_path: Optional[Path] = None
    dry_run: bool = False


@dataclass(frozen=True)
class OpenCPNGPSDConfigResult:
    config_path: Path
    host: str
    port: int
    changed: bool
    backup_path: Optional[Path] = None
    dry_run: bool = False


@dataclass(frozen=True)
class OpenCPNGPSDConnection:
    host: str
    port: Optional[int]
    raw: str


def opencpn_config_path(explicit: Optional[Path] = None) -> Path:
    if explicit:
        return Path(explicit).expanduser()
    candidates = [DEFAULT_OPENCPN_CONFIG_PATH.expanduser(), FLATPAK_OPENCPN_CONFIG_PATH.expanduser()]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def read_chart_directories(config_path: Optional[Path] = None) -> list[Path]:
    path = opencpn_config_path(config_path)
    expected_config_stat = _reject_unsafe_config_path(path)
    if expected_config_stat is None:
        return []
    text = _read_config_text(path, expected_stat=expected_config_stat)
    return [Path(value).expanduser() for _, value in _chart_dir_entries(text)]


def chart_directory_configured(chart_dir: Path, config_path: Optional[Path] = None) -> bool:
    wanted = _normalize_chart_dir(chart_dir)
    return any(_normalize_chart_dir(existing) == wanted for existing in read_chart_directories(config_path))


def read_data_connections(config_path: Optional[Path] = None) -> list[str]:
    path = opencpn_config_path(config_path)
    expected_config_stat = _reject_unsafe_config_path(path)
    if expected_config_stat is None:
        return []
    text = _read_config_text(path, expected_stat=expected_config_stat)
    value = _data_connections_value(text)
    return [part for part in value.split("|") if part] if value else []


def gpsd_connection_configured(
    *,
    host: str = "127.0.0.1",
    port: int = 2947,
    config_path: Optional[Path] = None,
) -> bool:
    wanted_host = _normalize_host(host)
    for connection in enabled_gpsd_connections(config_path):
        if connection.host == wanted_host and connection.port == port:
            return True
    return False


def enabled_gpsd_connections(config_path: Optional[Path] = None) -> list[OpenCPNGPSDConnection]:
    return enabled_gpsd_connections_from_values(read_data_connections(config_path))


def enabled_gpsd_connections_from_values(connections: list[str]) -> list[OpenCPNGPSDConnection]:
    enabled: list[OpenCPNGPSDConnection] = []
    for connection in connections:
        fields = connection.split(";")
        if len(fields) < 18:
            continue
        if fields[0] == "1" and fields[1] == "2" and fields[17] == "1":
            enabled.append(
                OpenCPNGPSDConnection(
                    host=_normalize_host(fields[2]),
                    port=_int_or_none(fields[3]),
                    raw=connection,
                )
            )
    return enabled


def normalize_gpsd_host(host: str) -> str:
    return _normalize_host(host)


def configure_chart_directory(
    chart_dir: Path,
    *,
    config_path: Optional[Path] = None,
    backup: bool = True,
    dry_run: bool = False,
) -> OpenCPNConfigResult:
    target = opencpn_config_path(config_path)
    expected_config_stat = _reject_unsafe_config_path(target)
    _validate_chart_directory_for_opencpn(Path(chart_dir).expanduser())
    wanted = _normalize_chart_dir(chart_dir)
    original = (
        _read_config_text(target, expected_stat=expected_config_stat)
        if expected_config_stat is not None
        else ""
    )
    updated, changed, key = _set_chart_directory(original, wanted)
    backup_path = None

    if changed and not dry_run:
        _prepare_config_parent(target)
        if backup and target.exists():
            backup_path = _write_backup(target)
        _write_text_atomic(target, updated)

    return OpenCPNConfigResult(
        config_path=target,
        chart_dir=wanted,
        changed=changed,
        key=key,
        backup_path=backup_path,
        dry_run=dry_run,
    )


def configure_gpsd_connection(
    *,
    host: str = "127.0.0.1",
    port: int = 2947,
    config_path: Optional[Path] = None,
    backup: bool = True,
    dry_run: bool = False,
) -> OpenCPNGPSDConfigResult:
    target = opencpn_config_path(config_path)
    expected_config_stat = _reject_unsafe_config_path(target)
    original = (
        _read_config_text(target, expected_stat=expected_config_stat)
        if expected_config_stat is not None
        else ""
    )
    updated, changed = _set_gpsd_connection(original, host, port)
    backup_path = None

    if changed and not dry_run:
        _prepare_config_parent(target)
        if backup and target.exists():
            backup_path = _write_backup(target)
        _write_text_atomic(target, updated)

    return OpenCPNGPSDConfigResult(
        config_path=target,
        host=host,
        port=port,
        changed=changed,
        backup_path=backup_path,
        dry_run=dry_run,
    )


def opencpn_running() -> bool:
    proc = Path("/proc")
    return _opencpn_running_from_proc(proc)


def _opencpn_running_from_proc(proc: Path) -> bool:
    if not proc.exists():
        return False
    current_uid = os.getuid()
    for process in proc.glob("[0-9]*"):
        details = _read_process_state_and_comm(process, expected_uid=current_uid)
        if details is None:
            continue
        state, comm = details
        if state == "Z":
            continue
        if comm == "opencpn":
            return True
    return False


def _read_process_state_and_comm(process: Path, *, expected_uid: int) -> Optional[tuple[str, str]]:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(process, follow_symlinks=False)
    except OSError:
        return None
    if not stat.S_ISDIR(before.st_mode) or before.st_uid != expected_uid:
        return None
    try:
        process_fd = os.open(process, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
    except OSError:
        return None
    try:
        opened = os.fstat(process_fd)
        if not os.path.samestat(before, opened) or not stat.S_ISDIR(opened.st_mode) or opened.st_uid != expected_uid:
            return None
        stat_text = _read_process_file_text(process_fd, "stat", encoding="ascii")
        comm = _read_process_file_text(process_fd, "comm", encoding="utf-8").strip()
    except OSError:
        return None
    finally:
        os.close(process_fd)
    return _process_state_from_stat_text(stat_text), comm


def _read_process_file_text(process_fd: int, name: str, *, encoding: str) -> str:
    fd = os.open(name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=process_fd)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise OSError(f"process {name} is not a regular file")
        return os.read(fd, 4096).decode(encoding, errors="ignore")
    finally:
        os.close(fd)


def _process_state_from_stat_text(text: str) -> str:
    _, separator, after_command = text.rpartition(") ")
    if not separator:
        return ""
    parts = after_command.split(maxsplit=1)
    return parts[0] if parts else ""


def _write_backup(target: Path) -> Path:
    expected_config_stat = _reject_unsafe_config_path(target)
    _prepare_config_parent(target)
    if expected_config_stat is None:
        raise RuntimeError(f"OpenCPN config path disappeared before backup: {target}")
    source_bytes = _read_config_bytes(target, expected_stat=expected_config_stat)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_path = _available_backup_path(target, stamp)
    backup_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(backup_path, backup_flags, 0o600)
    with os.fdopen(fd, "wb") as handle:
        os.fchmod(handle.fileno(), 0o600)
        handle.write(source_bytes)
        handle.flush()
        os.fsync(handle.fileno())
    _fsync_directory(backup_path.parent)
    return backup_path


def _available_backup_path(target: Path, stamp: str) -> Path:
    backup_path = target.with_name(f"{target.name}.noaa-navionics.{stamp}.bak")
    if not backup_path.exists():
        return backup_path
    for index in range(1, 1000):
        candidate = target.with_name(f"{target.name}.noaa-navionics.{stamp}.{index}.bak")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"could not find available backup filename near {backup_path}")


def _write_text_atomic(target: Path, text: str) -> None:
    _reject_unsafe_config_path(target)
    _prepare_config_parent(target)
    tmp_path = None
    tmp_stat = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=target.parent,
            prefix=f".{target.name}.",
            suffix=".part",
            delete=False,
        ) as handle:
            tmp_path = Path(handle.name)
            os.fchmod(handle.fileno(), 0o600)
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
            tmp_stat = os.fstat(handle.fileno())
        _validate_opencpn_temp_for_promotion(tmp_path, expected_stat=tmp_stat)
        os.replace(tmp_path, target)
        _validate_written_config(target, text)
        _fsync_directory(target.parent)
    finally:
        if tmp_path is not None:
            cleanup_private_temp_file(tmp_path, label="OpenCPN config temp", expected_stat=tmp_stat)


def _validate_opencpn_temp_for_promotion(path: Path, *, expected_stat: Optional[os.stat_result]) -> None:
    if expected_stat is None:
        raise RuntimeError(f"OpenCPN config temp was not opened safely before promotion: {path}")
    try:
        current = path.lstat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect OpenCPN config temp before promotion {path}: {exc}") from exc
    if stat.S_ISLNK(current.st_mode):
        raise RuntimeError(f"OpenCPN config temp is a symlink before promotion: {path}")
    if not stat.S_ISREG(current.st_mode):
        raise RuntimeError(f"OpenCPN config temp is not a regular file before promotion: {path}")
    if current.st_uid != os.getuid():
        raise RuntimeError(f"OpenCPN config temp {path} is owned by uid {current.st_uid}, expected {os.getuid()}")
    mode = stat.S_IMODE(current.st_mode)
    if mode != 0o600:
        raise RuntimeError(f"OpenCPN config temp {path} has permissions {mode:04o}, expected private 0600")
    if not os.path.samestat(current, expected_stat):
        raise RuntimeError(f"OpenCPN config temp changed before promotion; leaving it in place: {path}")

    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(opened, expected_stat):
            raise RuntimeError(f"OpenCPN config temp changed while being opened for promotion: {path}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"OpenCPN config temp is not regular when opened for promotion: {path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened.st_uid != os.getuid() or opened_mode != 0o600:
            raise RuntimeError(f"OpenCPN config temp {path} is not private current-user storage before promotion")
        os.fsync(fd)
    finally:
        os.close(fd)


def _validate_written_config(path: Path, expected_text: str) -> None:
    _reject_unsafe_config_path(path)
    try:
        expected = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        raise RuntimeError(f"could not inspect promoted OpenCPN config {path}: {exc}") from exc
    if not stat.S_ISREG(expected.st_mode):
        raise RuntimeError(f"promoted OpenCPN config is not a regular file: {path}")
    if expected.st_uid != os.getuid():
        raise RuntimeError(f"promoted OpenCPN config {path} is owned by uid {expected.st_uid}, expected {os.getuid()}")
    mode = expected.st_mode & 0o777
    if mode != 0o600:
        raise RuntimeError(f"promoted OpenCPN config {path} has permissions {mode:04o}, expected 0600")

    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        if path.is_symlink():
            raise RuntimeError(f"promoted OpenCPN config is a symlink: {path}") from exc
        raise RuntimeError(f"could not open promoted OpenCPN config {path}: {exc}") from exc
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
            raise RuntimeError(f"promoted OpenCPN config changed while validating: {path}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"promoted OpenCPN config is not a regular file when opened: {path}")
        if opened.st_uid != os.getuid():
            raise RuntimeError(f"promoted OpenCPN config {path} is owned by uid {opened.st_uid}, expected {os.getuid()}")
        opened_mode = opened.st_mode & 0o777
        if opened_mode != 0o600:
            raise RuntimeError(f"promoted OpenCPN config {path} has permissions {opened_mode:04o}, expected 0600")
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            promoted_text = handle.read()
        if promoted_text != expected_text:
            raise RuntimeError(f"promoted OpenCPN config {path} does not match expected content")
    finally:
        if fd >= 0:
            os.close(fd)


def _prepare_config_parent(target: Path) -> None:
    parent = target.parent
    symlink_component = _first_symlink_ancestor(parent)
    if symlink_component is not None:
        raise RuntimeError(f"OpenCPN config directory is a symlink: {symlink_component}")
    parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    symlink_component = _first_symlink_ancestor(parent)
    if symlink_component is not None:
        raise RuntimeError(f"OpenCPN config directory is a symlink: {symlink_component}")
    if not parent.is_dir():
        raise RuntimeError(f"OpenCPN config parent is not a directory: {parent}")
    try:
        parent_stat = parent.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect OpenCPN config directory {parent}: {exc}") from exc
    if parent_stat.st_uid != os.getuid():
        raise RuntimeError(
            f"OpenCPN config directory {parent} is owned by uid {parent_stat.st_uid}, expected {os.getuid()}"
        )
    parent_mode = parent_stat.st_mode & 0o777
    if parent_mode & 0o022:
        raise RuntimeError(
            f"OpenCPN config directory {parent} has permissions {parent_mode:04o}, "
            "expected no group/other write bits"
        )
    if parent_mode & 0o077:
        try:
            os.chmod(parent, 0o700)
        except OSError as exc:
            raise RuntimeError(f"could not make OpenCPN config directory private: {parent}: {exc}") from exc
    symlink_component = _first_symlink_ancestor(parent)
    if symlink_component is not None:
        raise RuntimeError(f"OpenCPN config directory became a symlink after permission tightening: {symlink_component}")
    try:
        parent_stat = parent.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect OpenCPN config directory {parent}: {exc}") from exc
    if parent_stat.st_uid != os.getuid():
        raise RuntimeError(
            f"OpenCPN config directory {parent} is owned by uid {parent_stat.st_uid}, expected {os.getuid()}"
        )
    parent_mode = parent_stat.st_mode & 0o777
    if parent_mode & 0o077:
        raise RuntimeError(
            f"OpenCPN config directory {parent} has permissions {parent_mode:04o}, "
            "expected private 0700"
        )


def _reject_unsafe_config_path(path: Path) -> Optional[os.stat_result]:
    if path.is_symlink():
        raise RuntimeError(f"OpenCPN config path is a symlink: {path}")
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        raise RuntimeError(f"OpenCPN config directory is a symlink: {symlink_component}")
    if not path.exists():
        return None
    if not path.is_file():
        raise RuntimeError(f"OpenCPN config path is not a regular file: {path}")
    try:
        path_stat = path.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect OpenCPN config path {path}: {exc}") from exc
    if path_stat.st_uid != os.getuid():
        raise RuntimeError(f"OpenCPN config path {path} is owned by uid {path_stat.st_uid}, expected {os.getuid()}")
    mode = path_stat.st_mode & 0o777
    if mode & 0o022:
        raise RuntimeError(
            f"OpenCPN config path {path} has permissions {mode:04o}, expected no group/other write bits"
        )
    return path_stat


def _open_trusted_config(path: Path, *, expected_stat: Optional[os.stat_result] = None) -> int:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        if expected_stat is not None:
            raise RuntimeError(f"OpenCPN config path disappeared while being opened: {path}") from None
        raise
    except OSError:
        if path.is_symlink():
            raise RuntimeError(f"OpenCPN config path is a symlink: {path}")
        raise
    try:
        stat_result = os.fstat(fd)
        if expected_stat is not None and not os.path.samestat(stat_result, expected_stat):
            raise RuntimeError(f"OpenCPN config path changed while being opened: {path}")
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"OpenCPN config path is not a regular file: {path}")
        if stat_result.st_uid != os.getuid():
            raise RuntimeError(
                f"OpenCPN config path {path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"OpenCPN config path {path} has permissions {mode:04o}, expected no group/other write bits"
            )
        return fd
    except Exception:
        os.close(fd)
        raise


def _read_config_text(path: Path, *, expected_stat: Optional[os.stat_result] = None) -> str:
    fd = _open_trusted_config(path, expected_stat=expected_stat)
    with os.fdopen(fd, encoding="utf-8", errors="ignore") as handle:
        return handle.read()


def _read_config_bytes(path: Path, *, expected_stat: Optional[os.stat_result] = None) -> bytes:
    fd = _open_trusted_config(path, expected_stat=expected_stat)
    with os.fdopen(fd, "rb") as handle:
        return handle.read()


def _validate_chart_directory_for_opencpn(path: Path) -> None:
    symlink_component = _first_symlink_ancestor(path)
    if symlink_component is not None:
        raise RuntimeError(f"OpenCPN chart directory path contains a symlink: {symlink_component}")
    if not path.exists():
        raise RuntimeError(f"OpenCPN chart directory does not exist: {path}")
    if not path.is_dir():
        raise RuntimeError(f"OpenCPN chart directory is not a directory: {path}")


def _first_symlink_ancestor(path: Path) -> Optional[Path]:
    current = Path(path).expanduser()
    candidates = [current, *current.parents]
    for candidate in candidates:
        if candidate.is_symlink():
            return candidate
    return None


def _fsync_directory(path: Path) -> None:
    try:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(Path(path), flags)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _set_chart_directory(text: str, chart_dir: Path) -> tuple[str, bool, str]:
    lines = text.splitlines(keepends=True)
    existing = _chart_dir_entries(text)
    for key, value in existing:
        if _normalize_chart_dir(Path(value)) == chart_dir:
            return text, False, key

    numbers = [_chart_dir_number(key) for key, _ in existing]
    next_number = max([number for number in numbers if number is not None], default=0) + 1
    key = f"ChartDir{next_number}"
    new_line = f"{key}={chart_dir}\n"

    start, end = _section_bounds(lines, "ChartDirectories")
    if start is None:
        if lines and not lines[-1].endswith(("\n", "\r")):
            lines[-1] = lines[-1] + "\n"
        if lines and any(line.strip() for line in lines):
            lines.append("\n")
        lines.extend(["[ChartDirectories]\n", new_line])
        return "".join(lines), True, key

    insert_at = end if end is not None else len(lines)
    if insert_at > 0 and not lines[insert_at - 1].endswith(("\n", "\r")):
        lines[insert_at - 1] = lines[insert_at - 1] + "\n"
    lines.insert(insert_at, new_line)
    return "".join(lines), True, key


def _set_gpsd_connection(text: str, host: str, port: int) -> tuple[str, bool]:
    connections = read_data_connections_from_text(text)
    wanted = _gpsd_connection_string(host, port)
    updated_connections = []
    found_wanted = False
    changed = False
    for connection in connections:
        if _same_gpsd_connection(connection, host, port):
            if found_wanted:
                changed = True
                continue
            found_wanted = True
            updated_connections.append(connection)
            continue
        if _is_enabled_gpsd_connection(connection):
            changed = True
            continue
        updated_connections.append(connection)
    if not found_wanted:
        updated_connections.append(wanted)
        changed = True
    if not changed:
        return text, False
    connections = updated_connections
    value = "|".join(connections)
    return _set_section_key(text, _NMEA_DATA_SOURCE_SECTION, "DataConnections", value), True


def read_data_connections_from_text(text: str) -> list[str]:
    value = _data_connections_value(text)
    return [part for part in value.split("|") if part] if value else []


def _data_connections_value(text: str) -> str:
    in_section = False
    for line in text.splitlines():
        section = _SECTION_RE.match(line)
        if section:
            in_section = section.group(1).strip().lower() == _NMEA_DATA_SOURCE_SECTION.lower()
            continue
        if not in_section:
            continue
        match = _DATA_CONNECTIONS_RE.match(line)
        if match:
            return match.group(1).strip()
    return ""


def _same_gpsd_connection(connection: str, host: str, port: int) -> bool:
    fields = connection.split(";")
    return (
        _is_enabled_gpsd_connection(connection)
        and _normalize_host(fields[2]) == _normalize_host(host)
        and _int_or_none(fields[3]) == port
    )


def _is_enabled_gpsd_connection(connection: str) -> bool:
    fields = connection.split(";")
    return len(fields) >= 18 and fields[0] == "1" and fields[1] == "2" and fields[17] == "1"


def _gpsd_connection_string(host: str, port: int) -> str:
    return ";".join(
        [
            "1",
            "2",
            host,
            str(port),
            "0",
            "",
            "4800",
            "1",
            "0",
            "0",
            "",
            "0",
            "",
            "0",
            "0",
            "0",
            "0",
            "1",
            f"GPSd: {host} TCP port {port}",
            "0",
            "",
            "0",
            "0",
            "",
        ]
    )


def _set_section_key(text: str, section_name: str, key: str, value: str) -> str:
    lines = text.splitlines(keepends=True)
    start, end = _section_bounds(lines, section_name)
    new_line = f"{key}={value}\n"
    if start is None:
        if lines and not lines[-1].endswith(("\n", "\r")):
            lines[-1] = lines[-1] + "\n"
        if lines and any(line.strip() for line in lines):
            lines.append("\n")
        lines.extend([f"[{section_name}]\n", new_line])
        return "".join(lines)

    insert_at = end if end is not None else len(lines)
    for index in range(start + 1, insert_at):
        if re.match(rf"^\s*{re.escape(key)}\s*=", lines[index]):
            lines[index] = new_line
            return "".join(lines)
    if insert_at > 0 and not lines[insert_at - 1].endswith(("\n", "\r")):
        lines[insert_at - 1] = lines[insert_at - 1] + "\n"
    lines.insert(insert_at, new_line)
    return "".join(lines)


def _chart_dir_entries(text: str) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    in_section = False
    for line in text.splitlines():
        section = _SECTION_RE.match(line)
        if section:
            in_section = section.group(1).strip().lower() == "chartdirectories"
            continue
        if not in_section:
            continue
        match = _CHART_DIR_RE.match(line)
        if match:
            entries.append((f"ChartDir{match.group(1)}", match.group(2).strip()))
    return entries


def _section_bounds(lines: list[str], section_name: str) -> tuple[Optional[int], Optional[int]]:
    start = None
    for index, line in enumerate(lines):
        section = _SECTION_RE.match(line)
        if not section:
            continue
        if section.group(1).strip().lower() == section_name.lower():
            start = index
            continue
        if start is not None:
            return start, index
    return start, None


def _chart_dir_number(key: str) -> Optional[int]:
    match = re.match(r"ChartDir(\d+)$", key)
    return int(match.group(1)) if match else None


def _normalize_chart_dir(path: Path) -> Path:
    return Path(path).expanduser().resolve(strict=False)


def _normalize_host(host: str) -> str:
    value = host.strip().lower()
    return "127.0.0.1" if value == "localhost" else value


def _int_or_none(value: str) -> Optional[int]:
    try:
        return int(value)
    except ValueError:
        return None
