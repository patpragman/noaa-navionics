from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
import os
import re
import tempfile


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
    _reject_unsafe_config_path(path)
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8", errors="ignore")
    return [Path(value).expanduser() for _, value in _chart_dir_entries(text)]


def chart_directory_configured(chart_dir: Path, config_path: Optional[Path] = None) -> bool:
    wanted = _normalize_chart_dir(chart_dir)
    return any(_normalize_chart_dir(existing) == wanted for existing in read_chart_directories(config_path))


def read_data_connections(config_path: Optional[Path] = None) -> list[str]:
    path = opencpn_config_path(config_path)
    _reject_unsafe_config_path(path)
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8", errors="ignore")
    value = _data_connections_value(text)
    return [part for part in value.split("|") if part] if value else []


def gpsd_connection_configured(
    *,
    host: str = "127.0.0.1",
    port: int = 2947,
    config_path: Optional[Path] = None,
) -> bool:
    wanted_host = _normalize_host(host)
    for connection in read_data_connections(config_path):
        fields = connection.split(";")
        if len(fields) < 18:
            continue
        if fields[0] != "1" or fields[1] != "2":
            continue
        if _normalize_host(fields[2]) == wanted_host and _int_or_none(fields[3]) == port and fields[17] == "1":
            return True
    return False


def configure_chart_directory(
    chart_dir: Path,
    *,
    config_path: Optional[Path] = None,
    backup: bool = True,
    dry_run: bool = False,
) -> OpenCPNConfigResult:
    target = opencpn_config_path(config_path)
    _reject_unsafe_config_path(target)
    wanted = _normalize_chart_dir(chart_dir)
    original = target.read_text(encoding="utf-8", errors="ignore") if target.exists() else ""
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
    _reject_unsafe_config_path(target)
    original = target.read_text(encoding="utf-8", errors="ignore") if target.exists() else ""
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
    if not proc.exists():
        return False
    current_uid = os.getuid()
    for process in proc.glob("[0-9]*"):
        try:
            if process.stat().st_uid != current_uid:
                continue
            state = _process_state_from_stat_text((process / "stat").read_text(encoding="ascii", errors="ignore"))
            if state == "Z":
                continue
            if (process / "comm").read_text(encoding="utf-8", errors="ignore").strip() == "opencpn":
                return True
        except OSError:
            continue
    return False


def _process_state_from_stat_text(text: str) -> str:
    _, separator, after_command = text.rpartition(") ")
    if not separator:
        return ""
    parts = after_command.split(maxsplit=1)
    return parts[0] if parts else ""


def _write_backup(target: Path) -> Path:
    _reject_unsafe_config_path(target)
    _prepare_config_parent(target)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_path = _available_backup_path(target, stamp)
    fd = os.open(backup_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(target.read_bytes())
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
            handle.write(text)
            handle.flush()
            os.chmod(tmp_path, 0o600)
            os.fsync(handle.fileno())
        os.replace(tmp_path, target)
        _fsync_directory(target.parent)
    finally:
        if tmp_path is not None:
            try:
                tmp_path.unlink()
            except FileNotFoundError:
                pass


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


def _reject_unsafe_config_path(path: Path) -> None:
    if path.is_symlink():
        raise RuntimeError(f"OpenCPN config path is a symlink: {path}")
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        raise RuntimeError(f"OpenCPN config directory is a symlink: {symlink_component}")
    if not path.exists():
        return
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


def _first_symlink_ancestor(path: Path) -> Optional[Path]:
    current = Path(path).expanduser()
    candidates = [current, *current.parents]
    for candidate in candidates:
        if candidate.is_symlink():
            return candidate
    return None


def _fsync_directory(path: Path) -> None:
    try:
        fd = os.open(Path(path), os.O_RDONLY)
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
    if any(_same_gpsd_connection(connection, host, port) for connection in connections):
        return text, False
    connections.append(wanted)
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
    if len(fields) < 18:
        return False
    return (
        fields[0] == "1"
        and fields[1] == "2"
        and _normalize_host(fields[2]) == _normalize_host(host)
        and _int_or_none(fields[3]) == port
        and fields[17] == "1"
    )


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
