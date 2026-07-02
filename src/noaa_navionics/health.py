from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Iterable, Iterator, Optional, TextIO
from urllib.parse import urlparse
import hashlib
import importlib.util
import math
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile

from .gps import (
    GPSFix,
    NMEA_MAX_LINE_BYTES,
    gps_fix_has_quality_fields,
    gps_fix_quality_failure,
    iter_fixes,
    iter_gpsd_fixes,
    open_nmea_stream,
)
from .downloader import (
    MANIFEST_NAME,
    MAX_ZIP_MEMBERS,
    MAX_ZIP_MEMBER_UNCOMPRESSED_BYTES,
    MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES,
    package_for,
    read_manifest,
)
from .opencpn import (
    chart_directory_configured,
    enabled_gpsd_connections,
    gpsd_connection_configured,
    normalize_gpsd_host,
    opencpn_config_path,
    read_chart_directories,
)


DEFAULT_SOURCE_REVISION_PATH = Path("~/.local/share/noaa-navionics/source-revision")
RASPBERRY_PI_MODEL_PATH = Path("/proc/device-tree/model")
GPS_BY_ID_SAFE_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:+@-")
REMOVABLE_STORAGE_ROOTS = (Path("/media"), Path("/mnt"), Path("/run/media"))
CHRONY_GPSD_REFCLOCK = "refclock SHM 0 offset 0.5 delay 0.1 refid GPS"
TRUSTED_SYSTEM_COMMAND_DIRS = {
    Path("/usr/local/sbin"),
    Path("/usr/local/bin"),
    Path("/usr/sbin"),
    Path("/usr/bin"),
    Path("/sbin"),
    Path("/bin"),
}
GPS_DEVICE_DISCOVERY_HINT = "run noaa-navionics list-gps-devices on the Pi"


@dataclass(frozen=True)
class CheckResult:
    name: str
    ok: bool
    detail: str
    data: Optional[dict[str, object]] = None


def run_preflight(
    *,
    chart_dir: Path,
    chart_package: str = "",
    chart_value: str = "",
    gpsd: bool = False,
    gpsd_host: str = "127.0.0.1",
    gpsd_port: int = 2947,
    gps_device: Optional[str] = None,
    gps_baud: int = 4800,
    gps_sample: Optional[Path] = None,
    gps_seconds: float = 5.0,
    max_chart_age_days: int = 30,
    min_free_gb: float = 2.0,
    keep_zip: bool = True,
    track_output: Optional[Path] = None,
) -> list[CheckResult]:
    results = [
        check_python(),
        check_source_revision(),
        check_system_clock(),
        check_time_synchronization(),
        check_tkinter(),
        check_opencpn(),
        check_display_power_tool(),
        check_chart_package(chart_package, chart_value),
        check_chart_dir(chart_dir),
        check_chart_update_debris(chart_dir),
        check_chart_manifest(
            chart_dir,
            max_age_days=max_chart_age_days,
            expected_package=chart_package,
            expected_value=chart_value,
            require_archive=keep_zip,
        ),
        check_opencpn_chart_config(chart_dir),
        check_disk_space(chart_dir, min_free_gb=min_free_gb),
        check_pi_throttling(),
        check_pi_temperature(),
    ]
    if track_output is not None and not _same_path(chart_dir, track_output):
        results.append(check_disk_space(track_output, name="Track Disk", min_free_gb=min_free_gb))
    if gpsd:
        if gps_device and gpsd_host in {"127.0.0.1", "localhost", "::1"}:
            results.append(check_gps_device_path(gps_device))
            results.append(check_gpsd_startup_config(gps_device))
        results.append(check_opencpn_gpsd_config(host=gpsd_host, port=gpsd_port))
        results.append(check_chrony_gps_time_config())
        results.append(check_chrony_gps_time_source(seconds=gps_seconds))
        results.append(check_gpsd(host=gpsd_host, port=gpsd_port, seconds=gps_seconds))
    elif gps_sample:
        results.append(check_gps_sample(gps_sample))
    elif gps_device:
        gps_device_check = check_gps_device_path(gps_device)
        results.append(gps_device_check)
        if gps_device_check.ok:
            results.append(check_gps_device(gps_device, baud=gps_baud, seconds=gps_seconds))
        else:
            results.append(
                CheckResult(
                    "GPS",
                    False,
                    _gps_not_checked_detail(gps_device_check.detail),
                )
            )
    else:
        results.append(
            CheckResult(
                "GPS",
                False,
                "not checked; pass --gps-device /dev/serial/by-id/YOUR_GPS_DEVICE "
                f"or --gps-sample file.nmea; {GPS_DEVICE_DISCOVERY_HINT}",
            )
        )
    return results


def check_python() -> CheckResult:
    version = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    ok = sys.version_info >= (3, 9)
    data = {
        "version": version,
        "version_info": [sys.version_info.major, sys.version_info.minor, sys.version_info.micro],
        "min_version": [3, 9],
        "executable": sys.executable,
    }
    return CheckResult("Python", ok, f"running Python {version}", data)


def check_source_revision(path: Optional[Path] = None) -> CheckResult:
    if not _is_raspberry_pi():
        return CheckResult(
            "Source Revision",
            True,
            "not a Raspberry Pi; skipping deployed source revision check",
            {"is_raspberry_pi": False, "skipped": True},
        )
    revision_path = path or _source_revision_path()
    if revision_path.is_symlink():
        return CheckResult("Source Revision", False, f"deployed source revision path is a symlink: {revision_path}")
    symlink_component = _first_symlink_ancestor(revision_path.parent)
    if symlink_component is not None:
        return CheckResult(
            "Source Revision",
            False,
            f"deployed source revision directory is a symlink: {symlink_component}",
        )
    if revision_path.parent.exists():
        if not revision_path.parent.is_dir():
            return CheckResult(
                "Source Revision",
                False,
                f"deployed source revision parent is not a directory: {revision_path.parent}",
            )
        try:
            directory_stat = revision_path.parent.stat()
        except OSError as exc:
            return CheckResult(
                "Source Revision",
                False,
                f"could not inspect deployed source revision directory: {exc}",
            )
        if directory_stat.st_uid != os.getuid():
            return CheckResult(
                "Source Revision",
                False,
                f"deployed source revision directory is owned by uid {directory_stat.st_uid}, "
                f"expected {os.getuid()}: {revision_path.parent}",
            )
        directory_mode = directory_stat.st_mode & 0o777
        if directory_mode & 0o022:
            return CheckResult(
                "Source Revision",
                False,
                f"deployed source revision directory has permissions {directory_mode:04o}, "
                f"expected no group/other write bits: {revision_path.parent}",
            )
    revision_stat: Optional[os.stat_result] = None
    if revision_path.exists():
        if not revision_path.is_file():
            return CheckResult(
                "Source Revision",
                False,
                f"deployed source revision path is not a regular file: {revision_path}",
            )
        try:
            revision_stat = revision_path.stat()
        except OSError as exc:
            return CheckResult("Source Revision", False, f"could not inspect deployed source revision: {exc}")
        if revision_stat.st_uid != os.getuid():
            return CheckResult(
                "Source Revision",
                False,
                f"deployed source revision path is owned by uid {revision_stat.st_uid}, expected {os.getuid()}: {revision_path}",
            )
        mode = revision_stat.st_mode & 0o777
        if mode & 0o022:
            return CheckResult(
                "Source Revision",
                False,
                f"deployed source revision path has permissions {mode:04o}, expected no group/other write bits: {revision_path}",
            )
    try:
        revision = _read_source_revision_text(
            revision_path,
            expected_stat=revision_stat,
        )
    except OSError as exc:
        return CheckResult("Source Revision", False, f"cannot read deployed source revision at {revision_path}: {exc}")
    except RuntimeError as exc:
        return CheckResult("Source Revision", False, str(exc).replace("source revision", "deployed source revision"))
    mode = revision_stat.st_mode & 0o777 if revision_stat is not None else 0
    data = {
        "is_raspberry_pi": True,
        "path": str(revision_path),
        "exists": revision_path.exists(),
        "is_symlink": False,
        "directory_symlink_component": "",
        "is_regular": revision_path.is_file(),
        "uid": revision_stat.st_uid if revision_stat is not None else None,
        "expected_uid": os.getuid(),
        "mode": f"{mode:04o}",
        "revision": revision,
    }
    if not revision or revision == "unknown":
        return CheckResult(
            "Source Revision",
            False,
            f"deployed source revision is not recorded at {revision_path}",
            data,
        )
    if revision.endswith("-dirty"):
        return CheckResult(
            "Source Revision",
            False,
            f"dirty deployed source revision is not production-ready: {revision}",
            data,
        )
    return CheckResult("Source Revision", True, revision, data)


def _read_source_revision_text(path: Path, *, expected_stat: Optional[os.stat_result] = None) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        if path.is_symlink():
            raise RuntimeError(f"source revision path is a symlink: {path}")
        raise
    try:
        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"source revision path is not a regular file: {path}")
        if expected_stat is not None and (stat_result.st_dev, stat_result.st_ino) != (
            expected_stat.st_dev,
            expected_stat.st_ino,
        ):
            raise RuntimeError(f"source revision path changed before it could be read: {path}")
        if stat_result.st_uid != os.getuid():
            raise RuntimeError(
                f"source revision path is owned by uid {stat_result.st_uid}, expected {os.getuid()}: {path}"
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"source revision path has permissions {mode:04o}, expected no group/other write bits: {path}"
            )
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            return handle.read().strip()
    finally:
        if fd >= 0:
            os.close(fd)


def _source_revision_path() -> Path:
    override = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
    return Path(override).expanduser() if override else DEFAULT_SOURCE_REVISION_PATH.expanduser()


def _first_symlink_ancestor(path: Path) -> Optional[Path]:
    current = Path(path).expanduser()
    for candidate in [current, *current.parents]:
        if candidate.is_symlink():
            return candidate
    return None


def check_system_clock(now: Optional[datetime] = None, *, min_year: int = 2024) -> CheckResult:
    current_time = now or datetime.now(timezone.utc)
    if current_time.tzinfo is None or current_time.utcoffset() is None:
        return CheckResult(
            "Clock",
            False,
            "system clock current time must include a timezone before relying on chart age checks",
            {"timestamp": None, "min_year": min_year},
        )
    current = current_time.astimezone(timezone.utc)
    data = {"timestamp": current.isoformat(), "min_year": min_year}
    if current.year < min_year:
        return CheckResult(
            "Clock",
            False,
            f"system clock is {current.isoformat()}; set time or enable time sync before relying on chart age checks",
            data,
        )
    return CheckResult("Clock", True, current.isoformat(), data)


def check_time_synchronization() -> CheckResult:
    if not _is_raspberry_pi():
        return CheckResult(
            "Time Sync",
            True,
            "not a Raspberry Pi; skipping time synchronization check",
            {"is_raspberry_pi": False, "skipped": True},
        )
    timedatectl, error = _trusted_system_command("timedatectl", "Time sync command")
    if error:
        return CheckResult(
            "Time Sync",
            False,
            f"{error}; cannot verify Raspberry Pi clock sync",
            {"is_raspberry_pi": True, "timedatectl_available": False},
        )
    assert timedatectl is not None
    try:
        completed = subprocess.run(
            [str(timedatectl), "show", "-p", "SystemClockSynchronized", "-p", "NTPSynchronized"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
    except Exception as exc:
        return CheckResult("Time Sync", False, f"timedatectl failed: {exc}")
    output = completed.stdout.strip() or completed.stderr.strip()
    if completed.returncode != 0:
        return CheckResult(
            "Time Sync",
            False,
            f"timedatectl failed: {output}",
            {"is_raspberry_pi": True, "timedatectl_returncode": completed.returncode},
        )
    values = {}
    for line in completed.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().lower()
    system_clock_sync = values.get("SystemClockSynchronized")
    ntp_sync = values.get("NTPSynchronized")
    data = {
        "is_raspberry_pi": True,
        "system_clock_synchronized": system_clock_sync or "",
        "ntp_synchronized": ntp_sync or "",
    }
    if system_clock_sync == "yes":
        detail = "system clock is synchronized"
        if ntp_sync in {"yes", "no"}:
            detail += f" (NTPSynchronized={ntp_sync})"
        return CheckResult("Time Sync", True, detail, data)
    if system_clock_sync == "no":
        detail = (
            "system clock is not synchronized; connect network time or configure GPS time before relying on chart age and GPX timestamps"
        )
        if ntp_sync in {"yes", "no"}:
            detail += f" (SystemClockSynchronized=no, NTPSynchronized={ntp_sync})"
        return CheckResult(
            "Time Sync",
            False,
            detail,
            data,
        )
    if ntp_sync in {"yes", "no"}:
        return CheckResult(
            "Time Sync",
            False,
            f"timedatectl did not report SystemClockSynchronized=yes (NTPSynchronized={ntp_sync}); "
            "connect network time or configure GPS time before relying on chart age and GPX timestamps",
            data,
        )
    return CheckResult(
        "Time Sync",
        False,
        f"could not determine clock synchronization from timedatectl: {output}",
        data,
    )


def check_tkinter() -> CheckResult:
    spec = importlib.util.find_spec("tkinter")
    ok = spec is not None
    data = {
        "module": "tkinter",
        "available": ok,
        "origin": str(spec.origin) if spec is not None and spec.origin is not None else "",
    }
    return CheckResult("Tkinter", ok, "available" if ok else "missing; install python3-tk", data)


def check_opencpn() -> CheckResult:
    command = shutil.which("opencpn")
    if command is None:
        return CheckResult("OpenCPN", False, "missing; install opencpn for chart display")
    path = Path(command)
    if not path.is_absolute():
        return CheckResult("OpenCPN", False, f"OpenCPN command path is not absolute: {path}")
    if path.is_symlink():
        return CheckResult("OpenCPN", False, f"OpenCPN command is a symlink: {path}")
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        return CheckResult("OpenCPN", False, f"OpenCPN command path contains a symlink: {symlink_component}")
    if not path.is_file():
        return CheckResult("OpenCPN", False, f"OpenCPN command is not a regular file: {path}")
    if not os.access(path, os.X_OK):
        return CheckResult("OpenCPN", False, f"OpenCPN command is not executable: {path}")
    try:
        stat_result = path.stat()
        parent_stat = path.parent.stat()
    except OSError as exc:
        return CheckResult("OpenCPN", False, f"could not inspect OpenCPN command {path}: {exc}")
    mode = stat_result.st_mode & 0o777
    if mode & 0o022:
        return CheckResult(
            "OpenCPN",
            False,
            f"OpenCPN command has permissions {mode:04o}, expected no group/other write bits: {path}",
        )
    parent_mode = parent_stat.st_mode & 0o777
    if parent_mode & 0o022:
        return CheckResult(
            "OpenCPN",
            False,
            f"OpenCPN command directory has permissions {parent_mode:04o}, expected no group/other write bits: {path.parent}",
        )
    if _is_raspberry_pi() and parent_stat.st_uid != 0:
        return CheckResult(
            "OpenCPN",
            False,
            f"OpenCPN command directory is owned by uid {parent_stat.st_uid}, expected root: {path.parent}",
        )
    if not _is_raspberry_pi() and parent_stat.st_uid not in {0, os.getuid()}:
        return CheckResult(
            "OpenCPN",
            False,
            f"OpenCPN command directory is owned by uid {parent_stat.st_uid}, expected root or {os.getuid()}: {path.parent}",
        )
    if _is_raspberry_pi() and stat_result.st_uid != 0:
        return CheckResult(
            "OpenCPN",
            False,
            f"OpenCPN command is owned by uid {stat_result.st_uid}, expected root: {path}",
        )
    if not _is_raspberry_pi() and stat_result.st_uid not in {0, os.getuid()}:
        return CheckResult(
            "OpenCPN",
            False,
            f"OpenCPN command is owned by uid {stat_result.st_uid}, expected root or {os.getuid()}: {path}",
        )
    if _is_raspberry_pi() and path.parent not in TRUSTED_SYSTEM_COMMAND_DIRS:
        return CheckResult(
            "OpenCPN",
            False,
            f"OpenCPN command directory is not a trusted system directory: {path.parent}",
        )
    data = _trusted_command_evidence(
        "opencpn",
        path,
        stat_result=stat_result,
        parent_stat=parent_stat,
    )
    return CheckResult("OpenCPN", True, f"trusted executable at {path}", data)


def check_display_power_tool() -> CheckResult:
    path, error = _trusted_system_command("xset", "Display Power command")
    if error:
        return CheckResult(
            "Display Power",
            False,
            f"{error}; install x11-xserver-utils so the launcher can disable display blanking",
        )
    assert path is not None
    return CheckResult("Display Power", True, f"trusted executable at {path}", _trusted_command_evidence("xset", path))


def _trusted_command_evidence(
    command: str,
    path: Path,
    *,
    stat_result: Optional[os.stat_result] = None,
    parent_stat: Optional[os.stat_result] = None,
) -> dict[str, object]:
    path = Path(path)
    symlink_component = _first_symlink_ancestor(path.parent)
    if stat_result is None:
        stat_result = path.stat()
    if parent_stat is None:
        parent_stat = path.parent.stat()
    command_mode = stat_result.st_mode & 0o777
    parent_mode = parent_stat.st_mode & 0o777
    expected_uids = {0} if _is_raspberry_pi() else {0, os.getuid()}
    return {
        "command": command,
        "path": str(path),
        "directory": str(path.parent),
        "is_absolute": path.is_absolute(),
        "is_symlink": path.is_symlink(),
        "path_symlink_component": "" if symlink_component is None else str(symlink_component),
        "trusted_system_directory": path.parent in TRUSTED_SYSTEM_COMMAND_DIRS,
        "is_regular": path.is_file(),
        "executable": os.access(path, os.X_OK),
        "uid": stat_result.st_uid,
        "directory_uid": parent_stat.st_uid,
        "expected_uids": sorted(expected_uids),
        "mode": f"{command_mode:04o}",
        "directory_mode": f"{parent_mode:04o}",
    }


def _trusted_system_command(command: str, label: str) -> tuple[Optional[Path], str]:
    found = shutil.which(command)
    if found is None:
        return None, f"{command} not found"
    path = Path(found)
    if not path.is_absolute():
        return None, f"{label} path is not absolute: {path}"
    if path.is_symlink():
        return None, f"{label} is a symlink: {path}"
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        return None, f"{label} path contains a symlink: {symlink_component}"
    if _is_raspberry_pi() and path.parent not in TRUSTED_SYSTEM_COMMAND_DIRS:
        return None, f"{label} directory is not a trusted system directory: {path.parent}"
    if not path.is_file():
        return None, f"{label} is not a regular file: {path}"
    if not os.access(path, os.X_OK):
        return None, f"{label} is not executable: {path}"
    try:
        stat_result = path.stat()
        parent_stat = path.parent.stat()
    except OSError as exc:
        return None, f"could not inspect {label} {path}: {exc}"
    mode = stat_result.st_mode & 0o777
    if mode & 0o022:
        return None, f"{label} has permissions {mode:04o}, expected no group/other write bits: {path}"
    parent_mode = parent_stat.st_mode & 0o777
    if parent_mode & 0o022:
        return None, (
            f"{label} directory has permissions {parent_mode:04o}, "
            f"expected no group/other write bits: {path.parent}"
        )
    expected_uids = {0} if _is_raspberry_pi() else {0, os.getuid()}
    expected_text = "root" if _is_raspberry_pi() else f"root or {os.getuid()}"
    if parent_stat.st_uid not in expected_uids:
        return None, f"{label} directory is owned by uid {parent_stat.st_uid}, expected {expected_text}: {path.parent}"
    if stat_result.st_uid not in expected_uids:
        return None, f"{label} is owned by uid {stat_result.st_uid}, expected {expected_text}: {path}"
    return path, ""


def check_chrony_gps_time_config(config_path: Path = Path("/etc/chrony/chrony.conf")) -> CheckResult:
    if not _is_raspberry_pi():
        return CheckResult(
            "Chrony Config",
            True,
            "not a Raspberry Pi; skipping chrony config check",
            {"is_raspberry_pi": False, "skipped": True},
        )
    path = Path(config_path).expanduser()
    if path.is_symlink():
        return CheckResult("Chrony Config", False, f"Chrony config is a symlink: {path}")
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        return CheckResult("Chrony Config", False, f"Chrony config directory is a symlink: {symlink_component}")
    if path.exists() and not path.is_file():
        return CheckResult("Chrony Config", False, f"Chrony config is not a regular file: {path}")
    if path.exists():
        try:
            stat_result = path.stat()
        except OSError as exc:
            return CheckResult("Chrony Config", False, f"could not inspect Chrony config {path}: {exc}")
        expected_uid = 0 if path == Path("/etc/chrony/chrony.conf") else os.getuid()
        if stat_result.st_uid != expected_uid:
            return CheckResult(
                "Chrony Config",
                False,
                f"Chrony config {path} is owned by uid {stat_result.st_uid}, expected {expected_uid}",
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            return CheckResult(
                "Chrony Config",
                False,
                f"Chrony config {path} has permissions {mode:04o}, expected no group/other write bits",
            )
    else:
        stat_result = None
    expected_uid = 0 if path == Path("/etc/chrony/chrony.conf") else os.getuid()
    try:
        lines = _read_trusted_config_lines(
            path,
            label="Chrony config",
            expected_uid=expected_uid,
            expected_stat=stat_result,
        )
    except OSError as exc:
        return CheckResult("Chrony Config", False, f"could not read Chrony config {path}: {exc}")
    except RuntimeError as exc:
        return CheckResult("Chrony Config", False, str(exc))
    configured = any(
        line.strip() == CHRONY_GPSD_REFCLOCK
        for line in lines
        if not line.lstrip().startswith("#")
    )
    mode = stat_result.st_mode & 0o777 if stat_result is not None else 0
    data: dict[str, object] = {
        "is_raspberry_pi": True,
        "path": str(path),
        "exists": path.exists(),
        "is_symlink": False,
        "directory_symlink_component": "",
        "is_regular": path.is_file(),
        "uid": stat_result.st_uid if stat_result is not None else None,
        "expected_uid": expected_uid,
        "mode": f"{mode:04o}",
        "managed_refclock_present": configured,
        "refclock_line": CHRONY_GPSD_REFCLOCK,
    }
    if not configured:
        return CheckResult(
            "Chrony Config",
            False,
            f"{path} does not contain an uncommented NOAA Navionics GPSD SHM 0 time source",
            data,
        )
    return CheckResult(
        "Chrony Config",
        True,
        f"{path} contains the NOAA Navionics GPSD SHM 0 time source",
        data,
    )


def check_chrony_gps_time_source(*, seconds: float = 5.0, poll_interval: float = 1.0) -> CheckResult:
    if not _is_raspberry_pi():
        return CheckResult(
            "GPS Time Source",
            True,
            "not a Raspberry Pi; skipping chrony GPS source check",
            {"is_raspberry_pi": False, "skipped": True},
        )
    chronyc, error = _trusted_system_command("chronyc", "Chrony command")
    if error:
        return CheckResult(
            "GPS Time Source",
            False,
            f"{error}; install chrony",
            {"is_raspberry_pi": True, "chronyc_available": False, "command_error": error},
        )
    assert chronyc is not None
    deadline = time.monotonic() + max(0.0, seconds)
    result = _check_chrony_gps_time_source_once(chronyc)
    while not result.ok and time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        time.sleep(min(max(0.01, poll_interval), remaining))
        result = _check_chrony_gps_time_source_once(chronyc)
    if not result.ok and seconds > 0:
        return CheckResult(result.name, False, f"{result.detail} within {seconds:.0f}s", result.data)
    return result


def _check_chrony_gps_time_source_once(chronyc: Path) -> CheckResult:
    base_data: dict[str, object] = {
        "is_raspberry_pi": True,
        "chronyc_path": str(chronyc),
        "chronyc_available": True,
    }
    try:
        completed = subprocess.run(
            [str(chronyc), "sources", "-n"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
    except Exception as exc:
        data = dict(base_data)
        data.update({"returncode": None, "gps_lines": [], "usable_lines": [], "selected_or_combined": False})
        return CheckResult("GPS Time Source", False, f"chronyc sources failed: {exc}", data)
    output = completed.stdout.strip() or completed.stderr.strip()
    gps_lines = [
        line.strip()
        for line in completed.stdout.splitlines()
        if line.startswith("#") and "GPS" in line.upper()
    ]
    usable = [line for line in gps_lines if len(line) > 1 and line[1] in "*+"]
    data = dict(base_data)
    data.update(
        {
            "returncode": completed.returncode,
            "gps_lines": gps_lines,
            "usable_lines": usable,
            "selected_or_combined": bool(usable),
        }
    )
    if completed.returncode != 0:
        return CheckResult("GPS Time Source", False, f"chronyc sources failed: {output}", data)
    if usable:
        return CheckResult("GPS Time Source", True, "chrony GPS source: " + usable[0], data)
    if gps_lines:
        return CheckResult("GPS Time Source", False, "chrony GPS source is not usable yet: " + gps_lines[0], data)
    return CheckResult("GPS Time Source", False, "chrony does not report a GPS refclock source", data)


def check_chart_package(package: str, value: str = "") -> CheckResult:
    package = package.strip().lower()
    value = value.strip()
    data: dict[str, object] = {
        "package": package,
        "value": value,
        "complete_chart_set": False,
        "expected_filename": "",
        "expected_url": "",
    }
    if not package:
        return CheckResult("Chart Package", True, "not checked", data)
    if package == "updates":
        detail = f"updates {value}" if value else "updates"
        return CheckResult(
            "Chart Package",
            False,
            f"{detail} is not a complete chart set; use state, cgd, region, chart, or all",
            data,
        )
    if package == "catalog":
        return CheckResult(
            "Chart Package",
            False,
            "catalog is metadata only; use state, cgd, region, chart, or all",
            data,
        )
    if package in {"state", "cgd", "region", "chart", "all"}:
        filename, url = _expected_manifest_package(package, value)
        data.update({"expected_filename": filename, "expected_url": url, "complete_chart_set": bool(filename)})
        if not filename:
            return CheckResult(
                "Chart Package",
                False,
                f"{package} {value}".strip() + " is not a supported NOAA ENC package",
                data,
            )
        label = f"{package} {value}".strip()
        return CheckResult("Chart Package", True, label, data)
    return CheckResult(
        "Chart Package",
        False,
        "unknown package; use state, cgd, region, chart, or all",
        data,
    )


def check_opencpn_chart_config(chart_dir: Path, config_path: Optional[Path] = None) -> CheckResult:
    config_path = opencpn_config_path(config_path)
    chart_path = Path(chart_dir).expanduser()
    data: dict[str, object] = {
        "config_path": str(config_path),
        "chart_dir": str(chart_path),
        "config_exists": config_path.exists(),
        "chart_dir_exists": chart_path.exists(),
        "configured": False,
        "chart_directories": [],
    }
    if not config_path.exists():
        return CheckResult(
            "OpenCPN Charts",
            False,
            f"missing {config_path}; run noaa-navionics configure-opencpn after chart sync",
            data,
        )
    if not chart_path.exists():
        return CheckResult("OpenCPN Charts", False, f"chart directory does not exist: {chart_path}", data)
    chart_directories = read_chart_directories(config_path)
    configured = chart_directory_configured(chart_dir, config_path)
    data.update(
        {
            "configured": configured,
            "chart_directories": [str(directory) for directory in chart_directories],
        }
    )
    if configured:
        return CheckResult("OpenCPN Charts", True, f"{chart_path} listed in {config_path}", data)
    return CheckResult(
        "OpenCPN Charts",
        False,
        f"{chart_path} not listed in {config_path}; run noaa-navionics configure-opencpn",
        data,
    )


def check_opencpn_gpsd_config(
    *,
    host: str = "127.0.0.1",
    port: int = 2947,
    config_path: Optional[Path] = None,
) -> CheckResult:
    config_path = opencpn_config_path(config_path)
    expected_host = normalize_gpsd_host(host)
    data: dict[str, object] = {
        "config_path": str(config_path),
        "expected_host": expected_host,
        "expected_port": port,
        "config_exists": config_path.exists(),
        "configured": False,
        "enabled_gpsd_connections": [],
        "unexpected_connections": [],
    }
    if not config_path.exists():
        return CheckResult(
            "OpenCPN GPSD",
            False,
            f"missing {config_path}; run noaa-navionics configure-opencpn",
            data,
        )
    enabled_connections = enabled_gpsd_connections(config_path)
    unexpected = [
        connection
        for connection in enabled_connections
        if connection.host != expected_host or connection.port != port
    ]
    configured = gpsd_connection_configured(host=host, port=port, config_path=config_path)
    data.update(
        {
            "configured": configured,
            "enabled_gpsd_connections": [
                {"host": connection.host, "port": connection.port, "raw": connection.raw}
                for connection in enabled_connections
            ],
            "unexpected_connections": [
                {"host": connection.host, "port": connection.port, "raw": connection.raw}
                for connection in unexpected
            ],
        }
    )
    if configured:
        if unexpected:
            endpoints = ", ".join(
                f"{connection.host}:{connection.port if connection.port is not None else '<invalid-port>'}"
                for connection in unexpected
            )
            return CheckResult(
                "OpenCPN GPSD",
                False,
                f"unexpected enabled GPSD connection in {config_path}: {endpoints}; remove stale OpenCPN GPSD sources",
                data,
            )
        return CheckResult("OpenCPN GPSD", True, f"GPSD {host}:{port} listed in {config_path}", data)
    return CheckResult(
        "OpenCPN GPSD",
        False,
        f"GPSD {host}:{port} not listed in {config_path}; run noaa-navionics configure-opencpn",
        data,
    )


def check_chart_dir(chart_dir: Path) -> CheckResult:
    path = Path(chart_dir).expanduser()
    symlink = _first_storage_symlink(path)
    data: dict[str, object] = {
        "configured_path": str(path),
        "exists": path.exists(),
        "storage_symlink_component": str(symlink) if symlink is not None else "",
        "enc_cell_samples": [],
        "zip_samples": [],
        "has_extracted_enc_cells": False,
        "has_unextracted_zips": False,
    }
    if symlink is not None:
        if symlink == path:
            return CheckResult("Charts", False, f"chart directory is a symlink: {path}", data)
        return CheckResult("Charts", False, f"chart directory path contains a symlink: {symlink}", data)
    if not path.exists():
        return CheckResult("Charts", False, f"{path} does not exist", data)
    enc_cells = _limited_find(path, suffix=".000", limit=5)
    zips = _limited_find(path, suffix=".zip", limit=5)
    data.update(
        {
            "enc_cell_samples": [str(cell) for cell in enc_cells],
            "zip_samples": [str(zip_path) for zip_path in zips],
            "has_extracted_enc_cells": bool(enc_cells),
            "has_unextracted_zips": bool(zips),
        }
    )
    if enc_cells:
        return CheckResult("Charts", True, f"found extracted ENC cells under {path}", data)
    if zips:
        return CheckResult("Charts", False, f"found ENC ZIP files under {path}; run download with --extract", data)
    return CheckResult("Charts", False, f"no ENC .000 cells or ZIPs found under {path}", data)


def check_chart_update_debris(chart_dir: Path) -> CheckResult:
    path = Path(chart_dir).expanduser()
    symlink = _first_storage_symlink(path)
    data: dict[str, object] = {
        "configured_path": str(path),
        "exists": path.exists(),
        "storage_symlink_component": str(symlink) if symlink is not None else "",
        "debris": [],
        "debris_count": 0,
        "clean": False,
    }
    if symlink is not None:
        if symlink == path:
            return CheckResult("Chart Update Debris", False, f"chart directory is a symlink: {path}", data)
        return CheckResult("Chart Update Debris", False, f"chart directory path contains a symlink: {symlink}", data)
    if not path.exists():
        data["clean"] = True
        return CheckResult("Chart Update Debris", True, f"not checked; {path} does not exist", data)
    try:
        retained_archive = _manifest_archive_path(path)
        debris = sorted(
            child
            for child in path.iterdir()
            if (
                child.name.endswith(".part")
                or (child.is_file() and child.suffix.lower() == ".zip" and not _same_path(child, retained_archive))
                or (
                    child.name.startswith(".")
                    and (child.name.endswith(".extracting") or child.name.endswith(".previous"))
                )
            )
        )
    except OSError as exc:
        return CheckResult("Chart Update Debris", False, f"cannot inspect chart directory: {exc}", data)
    data.update({"debris": [str(child) for child in debris[:5]], "debris_count": len(debris), "clean": not debris})
    if debris:
        names = ", ".join(child.name for child in debris[:5])
        suffix = "" if len(debris) <= 5 else f", and {len(debris) - 5} more"
        return CheckResult(
            "Chart Update Debris",
            False,
            f"remove stale chart update debris before departure: {names}{suffix}",
            data,
        )
    return CheckResult("Chart Update Debris", True, "no interrupted chart updates found", data)


def _manifest_archive_path(chart_dir: Path) -> Path:
    try:
        manifest = read_manifest(chart_dir)
    except Exception:
        return Path()
    download = manifest.get("download", {})
    if not isinstance(download, dict):
        return Path()
    return Path(str(download.get("path", "")).strip()).expanduser()


def check_chart_manifest(
    chart_dir: Path,
    *,
    max_age_days: int = 30,
    expected_package: str = "",
    expected_value: str = "",
    require_archive: bool = False,
) -> CheckResult:
    path = Path(chart_dir).expanduser()
    symlink = _first_storage_symlink(path)
    if symlink is not None:
        if symlink == path:
            return CheckResult("Manifest", False, f"chart directory is a symlink: {path}")
        return CheckResult("Manifest", False, f"chart directory path contains a symlink: {symlink}")
    manifest_path = path / MANIFEST_NAME
    if manifest_path.is_symlink():
        return CheckResult("Manifest", False, f"manifest path is a symlink: {manifest_path}")
    if manifest_path.parent.exists():
        if not manifest_path.parent.is_dir():
            return CheckResult("Manifest", False, f"manifest parent is not a directory: {manifest_path.parent}")
        try:
            directory_stat = manifest_path.parent.stat()
        except OSError as exc:
            return CheckResult("Manifest", False, f"could not inspect manifest directory {manifest_path.parent}: {exc}")
        if directory_stat.st_uid != os.getuid():
            return CheckResult(
                "Manifest",
                False,
                f"manifest directory {manifest_path.parent} is owned by uid "
                f"{directory_stat.st_uid}, expected {os.getuid()}",
            )
        directory_mode = directory_stat.st_mode & 0o777
        if directory_mode & 0o022:
            return CheckResult(
                "Manifest",
                False,
                f"manifest directory {manifest_path.parent} has permissions {directory_mode:04o}, "
                "expected no group/other write bits",
            )
    if not manifest_path.exists():
        return CheckResult("Manifest", False, f"missing {manifest_path}")
    if not manifest_path.is_file():
        return CheckResult("Manifest", False, f"manifest path is not a regular file: {manifest_path}")
    try:
        manifest_stat = manifest_path.stat()
    except OSError as exc:
        return CheckResult("Manifest", False, f"could not inspect manifest path {manifest_path}: {exc}")
    if manifest_stat.st_uid != os.getuid():
        return CheckResult(
            "Manifest",
            False,
            f"manifest path {manifest_path} is owned by uid {manifest_stat.st_uid}, expected {os.getuid()}",
        )
    manifest_mode = manifest_stat.st_mode & 0o777
    if manifest_mode & 0o022:
        return CheckResult(
            "Manifest",
            False,
            f"manifest path {manifest_path} has permissions {manifest_mode:04o}, expected no group/other write bits",
        )
    try:
        manifest = read_manifest(path, expected_stat=manifest_stat)
        created = _parse_manifest_time(str(manifest.get("created_at", "")))
    except Exception as exc:
        return CheckResult("Manifest", False, f"invalid {manifest_path}: {exc}")
    if str(manifest.get("created_at_source", "")).strip() == "unverified-cache":
        return CheckResult(
            "Manifest",
            False,
            "manifest was created from an existing ZIP without a prior verified manifest; run sync-charts --force",
        )
    if created is None:
        return CheckResult("Manifest", False, f"manifest has no valid created_at: {manifest_path}")
    age_days = (datetime.now(timezone.utc) - created).total_seconds() / 86400
    if age_days < -0.01:
        return CheckResult("Manifest", False, "chart manifest timestamp is in the future")
    if age_days > max_age_days:
        return CheckResult("Manifest", False, f"chart manifest is {age_days:.1f} days old; max is {max_age_days}")
    extract = manifest.get("extract", {})
    if not isinstance(extract, dict):
        return CheckResult("Manifest", False, "manifest has no extract section")
    extract_path_text = str(extract.get("path", "")).strip()
    if not extract_path_text:
        return CheckResult("Manifest", False, "manifest does not record an extracted chart path")
    extract_path = Path(extract_path_text).expanduser()
    if extract_path.is_symlink():
        return CheckResult("Manifest", False, f"manifest extract path is a symlink: {extract_path}")
    if not extract_path.exists():
        return CheckResult("Manifest", False, f"manifest extract path does not exist: {extract_path}")
    try:
        extract_path.resolve().relative_to(path.resolve())
    except ValueError:
        return CheckResult("Manifest", False, f"manifest extract path is outside chart directory: {extract_path}")
    symlink_component = _first_path_symlink_between(extract_path, path)
    if symlink_component is not None:
        return CheckResult("Manifest", False, f"manifest extract path contains a symlink: {symlink_component}")
    try:
        manifest_cell_count = int(extract.get("enc_cell_count", 0))
    except (TypeError, ValueError):
        return CheckResult("Manifest", False, "manifest has invalid ENC cell count")
    if manifest_cell_count <= 0:
        return CheckResult("Manifest", False, "manifest reports no extracted ENC cells")
    actual_cell_count, extract_tree_error = _trusted_enc_cell_tree_count(extract_path)
    if extract_tree_error:
        return CheckResult("Manifest", False, extract_tree_error)
    if actual_cell_count <= 0:
        return CheckResult("Manifest", False, f"no ENC cells found at manifest extract path: {extract_path}")
    if actual_cell_count != manifest_cell_count:
        return CheckResult(
            "Manifest",
            False,
            f"manifest recorded {manifest_cell_count} ENC cells but found {actual_cell_count} at {extract_path}",
        )
    stale_chart_dirs = _unexpected_enc_dirs(path, extract_path)
    if stale_chart_dirs:
        names = ", ".join(str(chart_dir) for chart_dir in stale_chart_dirs[:5])
        suffix = "" if len(stale_chart_dirs) <= 5 else f", and {len(stale_chart_dirs) - 5} more"
        return CheckResult(
            "Manifest",
            False,
            f"unexpected ENC chart directories outside manifest extract path: {names}{suffix}",
        )
    package = manifest.get("package", {})
    label = package.get("label", "unknown package") if isinstance(package, dict) else "unknown package"
    expected_filename, expected_url = _expected_manifest_package(expected_package, expected_value)
    if expected_filename:
        actual_filename = package.get("filename", "") if isinstance(package, dict) else ""
        if actual_filename != expected_filename:
            actual_detail = actual_filename or label
            return CheckResult(
                "Manifest",
                False,
                f"manifest package {actual_detail} does not match configured {expected_filename}",
            )
    if expected_url:
        actual_url = package.get("url", "") if isinstance(package, dict) else ""
        if actual_url != expected_url:
            actual_detail = actual_url or label
            return CheckResult(
                "Manifest",
                False,
                f"manifest package URL {actual_detail} does not match configured {expected_url}",
            )
    archive_check = _check_manifest_archive(path, manifest, required=require_archive)
    if archive_check is not None:
        return archive_check
    download_url_check = _check_manifest_download_url(manifest)
    if download_url_check is not None:
        return download_url_check
    download = manifest.get("download", {})
    data = {
        "configured_path": str(path),
        "path": str(manifest_path),
        "created_at": manifest.get("created_at", ""),
        "created_at_source": manifest.get("created_at_source", ""),
        "max_age_days": max_age_days,
        "age_days": age_days,
        "package": label,
        "package_filename": package.get("filename", "") if isinstance(package, dict) else "",
        "package_url": package.get("url", "") if isinstance(package, dict) else "",
        "expected_filename": expected_filename,
        "expected_url": expected_url,
        "download_path": download.get("path", "") if isinstance(download, dict) else "",
        "download_url": download.get("url", "") if isinstance(download, dict) else "",
        "download_bytes": download.get("bytes", 0) if isinstance(download, dict) else 0,
        "sha256": download.get("sha256", "") if isinstance(download, dict) else "",
        "extract_path": str(extract_path),
        "enc_cell_count": manifest_cell_count,
        "actual_enc_cell_count": actual_cell_count,
        "require_archive": require_archive,
    }
    return CheckResult(
        "Manifest",
        True,
        f"{label}; {actual_cell_count} ENC cells; updated {age_days:.1f} days ago",
        data,
    )


def _trusted_enc_cell_tree_count(root: Path) -> tuple[int, str]:
    expected_uid = os.getuid()

    def validate_entry(path: Path, *, expected_directory: bool = False) -> str:
        try:
            stat_result = path.lstat()
        except OSError as exc:
            return f"could not inspect manifest extract path {path}: {exc}"
        if stat.S_ISLNK(stat_result.st_mode):
            return f"manifest extract path contains a symlink: {path}"
        if expected_directory:
            if not stat.S_ISDIR(stat_result.st_mode):
                return f"manifest extract path entry is not a directory: {path}"
            label = "directory"
        else:
            if not stat.S_ISREG(stat_result.st_mode):
                return f"manifest extract path entry is not a regular file: {path}"
            label = "file"
        if stat_result.st_uid != expected_uid:
            return (
                f"manifest extract {label} {path} is owned by uid "
                f"{stat_result.st_uid}, expected {expected_uid}"
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            return (
                f"manifest extract {label} {path} has permissions {mode:04o}, "
                "expected no group/other write bits"
            )
        return ""

    root_error = validate_entry(root, expected_directory=True)
    if root_error:
        return 0, root_error

    walk_errors: list[str] = []

    def on_walk_error(exc: OSError) -> None:
        walk_errors.append(f"could not inspect manifest extract path {exc.filename}: {exc}")

    cell_count = 0
    for current_root, dirnames, filenames in os.walk(root, onerror=on_walk_error):
        if walk_errors:
            return 0, walk_errors[0]
        current = Path(current_root)
        current_error = validate_entry(current, expected_directory=True)
        if current_error:
            return 0, current_error
        for dirname in dirnames:
            directory_error = validate_entry(current / dirname, expected_directory=True)
            if directory_error:
                return 0, directory_error
        for filename in filenames:
            file_path = current / filename
            file_error = validate_entry(file_path)
            if file_error:
                return 0, file_error
            if file_path.name.lower().endswith(".000"):
                cell_count += 1
    if walk_errors:
        return 0, walk_errors[0]
    return cell_count, ""


def _check_manifest_download_url(manifest: dict[str, object]) -> Optional[CheckResult]:
    package = manifest.get("package", {})
    download = manifest.get("download", {})
    if not isinstance(package, dict) or not isinstance(download, dict):
        return CheckResult("Manifest", False, "manifest has no package or download section")
    package_url = str(package.get("url", "")).strip()
    download_url = str(download.get("url", "")).strip()
    if not download_url:
        return CheckResult("Manifest", False, "manifest does not record a download URL")
    if package_url and not _download_url_matches_package(download_url, package_url):
        return CheckResult(
            "Manifest",
            False,
            f"manifest download URL {download_url} does not match package filename from {package_url} or uses a non-HTTPS redirect or non-NOAA host",
        )
    return None


def _download_url_matches_package(download_url: str, package_url: str) -> bool:
    if download_url == package_url:
        return True
    parsed_download = urlparse(download_url)
    parsed_package = urlparse(package_url)
    if parsed_download.scheme.lower() != "https":
        return False
    download_filename = Path(parsed_download.path).name
    package_filename = Path(parsed_package.path).name
    if not download_filename or not package_filename or download_filename != package_filename:
        return False
    return _is_noaa_host(parsed_package.hostname) and _is_noaa_host(parsed_download.hostname)


def _is_noaa_host(hostname: Optional[str]) -> bool:
    host = (hostname or "").strip(".").lower()
    return host == "noaa.gov" or host.endswith(".noaa.gov")


def _check_manifest_archive(
    chart_dir: Path,
    manifest: dict[str, object],
    *,
    required: bool = False,
) -> Optional[CheckResult]:
    download = manifest.get("download", {})
    if not isinstance(download, dict):
        return CheckResult("Manifest", False, "manifest has no download section")
    archive_path_text = str(download.get("path", "")).strip()
    if not archive_path_text:
        if required:
            return CheckResult("Manifest", False, "manifest does not record a retained download path")
        return None
    archive_path = Path(archive_path_text).expanduser()
    if archive_path.is_symlink():
        return CheckResult("Manifest", False, f"manifest download path is a symlink: {archive_path}")
    try:
        archive_path.resolve().relative_to(chart_dir.resolve())
    except ValueError:
        return CheckResult("Manifest", False, f"manifest download path is outside chart directory: {archive_path}")
    symlink_component = _first_path_symlink_between(archive_path, chart_dir)
    if symlink_component is not None:
        return CheckResult("Manifest", False, f"manifest download path contains a symlink: {symlink_component}")
    try:
        expected_bytes = int(download.get("bytes", 0))
    except (TypeError, ValueError):
        return CheckResult("Manifest", False, "manifest has invalid download byte count")
    if expected_bytes <= 0:
        return CheckResult("Manifest", False, "manifest does not record a positive download byte count")
    expected_sha256 = str(download.get("sha256", "")).strip().lower()
    if not expected_sha256:
        return CheckResult("Manifest", False, "manifest does not record a download SHA-256")
    if not archive_path.exists():
        if required:
            return CheckResult("Manifest", False, f"manifest retained download path is missing: {archive_path}")
        return None
    try:
        actual_bytes, actual_sha256 = _sha256_trusted_file(
            archive_path,
            label="manifest download path",
            expected_uid=os.getuid(),
        )
    except OSError as exc:
        return CheckResult("Manifest", False, f"could not read manifest download path {archive_path}: {exc}")
    except RuntimeError as exc:
        return CheckResult("Manifest", False, str(exc))
    if actual_bytes != expected_bytes:
        return CheckResult(
            "Manifest",
            False,
            f"manifest recorded {expected_bytes} downloaded bytes but {archive_path} has {actual_bytes}",
        )
    if actual_sha256.lower() != expected_sha256:
        return CheckResult("Manifest", False, f"manifest SHA-256 does not match {archive_path}")
    retained_archive_error = _validate_retained_enc_archive(archive_path)
    if retained_archive_error:
        return CheckResult("Manifest", False, retained_archive_error)
    return None


def _validate_retained_enc_archive(path: Path) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        if path.is_symlink():
            return f"retained chart archive is a symlink: {path}"
        return f"could not open retained chart archive {path}: {exc}"
    try:
        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode):
            return f"retained chart archive is not a regular file: {path}"
        if stat_result.st_uid != os.getuid():
            return f"retained chart archive {path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            return f"retained chart archive {path} has permissions {mode:04o}, expected no group/other write bits"
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            try:
                with zipfile.ZipFile(handle) as archive:
                    members = archive.infolist()
                    if len(members) > MAX_ZIP_MEMBERS:
                        return f"retained chart archive has too many members: {len(members)} > {MAX_ZIP_MEMBERS}"
                    total_uncompressed = 0
                    for member in members:
                        if _zip_member_path_is_unsafe(member.filename):
                            return f"retained chart archive has unsafe member path: {member.filename}"
                        if not member.is_dir():
                            if member.file_size > MAX_ZIP_MEMBER_UNCOMPRESSED_BYTES:
                                return (
                                    "retained chart archive member is too large: "
                                    f"{member.filename} ({member.file_size} bytes > "
                                    f"{MAX_ZIP_MEMBER_UNCOMPRESSED_BYTES})"
                                )
                            total_uncompressed += member.file_size
                            if total_uncompressed > MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES:
                                return (
                                    "retained chart archive uncompressed size is too large: "
                                    f"{total_uncompressed} bytes > {MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES}"
                                )
                    bad_member = archive.testzip()
                    if bad_member is not None:
                        return f"retained chart archive has a failed CRC member: {bad_member}"
                    enc_cell_count = sum(
                        1
                        for member in members
                        if not member.is_dir() and member.filename.lower().endswith(".000")
                    )
            except zipfile.BadZipFile:
                return f"retained chart archive is not a valid ZIP: {path}"
        if enc_cell_count <= 0:
            return f"retained chart archive contains no ENC .000 cells: {path}"
        return ""
    finally:
        if fd >= 0:
            os.close(fd)


def _zip_member_path_is_unsafe(filename: str) -> bool:
    if not filename or "\\" in filename:
        return True
    member_path = PurePosixPath(filename)
    if member_path.is_absolute():
        return True
    stripped = filename.rstrip("/")
    if not stripped:
        return True
    parts = stripped.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        return True
    if ":" in parts[0]:
        return True
    return False


def _sha256_trusted_file(path: Path, *, label: str, expected_uid: int) -> tuple[int, str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        if path.is_symlink():
            raise RuntimeError(f"{label} is a symlink: {path}")
        raise
    try:
        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"{label} is not a regular file: {path}")
        if stat_result.st_uid != expected_uid:
            raise RuntimeError(
                f"{label} {path} is owned by uid {stat_result.st_uid}, expected {expected_uid}"
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"{label} {path} has permissions {mode:04o}, expected no group/other write bits"
            )
        hasher = hashlib.sha256()
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                hasher.update(chunk)
        return stat_result.st_size, hasher.hexdigest()
    finally:
        if fd >= 0:
            os.close(fd)


def _first_path_symlink_between(path: Path, root: Path) -> Optional[Path]:
    root_path = Path(root).expanduser()
    current = Path(path).expanduser()
    while True:
        if current.is_symlink():
            return current
        if current == root_path:
            return None
        parent = current.parent
        if parent == current:
            return None
        current = parent


def _expected_manifest_package(package: str, value: str = "") -> tuple[str, str]:
    package = package.strip().lower()
    value = value.strip()
    if not package:
        return "", ""
    kwargs: dict[str, object]
    if package == "state":
        kwargs = {"state": value}
    elif package == "cgd":
        kwargs = {"cgd": value}
    elif package == "region":
        kwargs = {"region": value}
    elif package == "updates":
        kwargs = {"updates": value}
    elif package == "chart":
        kwargs = {"chart": value}
    elif package == "all":
        kwargs = {"all_charts": True}
    elif package == "catalog":
        kwargs = {"catalog": True}
    else:
        return "", ""
    try:
        expected = package_for(**kwargs)
        return expected.filename, expected.url
    except ValueError:
        return "", ""


def _unexpected_enc_dirs(chart_dir: Path, extract_path: Path) -> list[Path]:
    try:
        chart_root = Path(chart_dir).expanduser().resolve()
        extract_root = Path(extract_path).expanduser().resolve()
    except OSError:
        return []
    try:
        relative_extract = extract_root.relative_to(chart_root)
    except ValueError:
        return []
    protected = chart_root / relative_extract.parts[0] if relative_extract.parts else chart_root
    try:
        children = sorted(chart_root.iterdir())
    except OSError:
        return []
    unexpected = []
    for child in children:
        if child.name.startswith(".") or not child.is_dir():
            continue
        try:
            child_root = child.resolve()
        except OSError:
            continue
        if child_root == protected:
            continue
        if _limited_find(child_root, suffix=".000", limit=1):
            unexpected.append(child)
    return unexpected


def check_disk_space(chart_dir: Path, *, name: str = "Disk", min_free_gb: float = 2.0) -> CheckResult:
    path = Path(chart_dir).expanduser()
    existing = path if path.exists() else path.parent
    data: dict[str, object] = {
        "configured_path": str(path),
        "checked_path": str(existing),
        "exists": existing.exists(),
        "min_free_gb": float(min_free_gb),
    }
    if not existing.exists():
        data["is_directory"] = False
        return CheckResult(
            name,
            False,
            f"{existing} does not exist; create or mount the configured storage path",
            data,
        )
    symlink = _first_storage_symlink(path)
    if symlink is not None:
        data["storage_symlink_component"] = str(symlink)
        return CheckResult(name, False, f"{symlink} is a symlink; use a real mounted storage directory", data)
    data["storage_symlink_component"] = ""
    data["is_directory"] = existing.is_dir()
    if not existing.is_dir():
        return CheckResult(name, False, f"{existing} is not a directory", data)
    mount_detail = _missing_removable_mount(path, existing)
    data["missing_removable_mount"] = bool(mount_detail)
    if mount_detail:
        return CheckResult(name, False, mount_detail, data)
    stat_result = existing.stat()
    data["uid"] = stat_result.st_uid
    data["expected_uid"] = os.getuid()
    if stat_result.st_uid != os.getuid():
        return CheckResult(
            name,
            False,
            f"{existing} is owned by uid {stat_result.st_uid}, expected {os.getuid()}",
            data,
        )
    mode = stat_result.st_mode & 0o777
    data["mode"] = f"{mode:04o}"
    if mode & 0o022:
        return CheckResult(
            name,
            False,
            f"{existing} has permissions {mode:04o}, expected no group/other write bits",
            data,
        )
    usage = shutil.disk_usage(existing)
    free_gb = usage.free / (1024 ** 3)
    writable = _directory_writable(existing)
    data["free_gb"] = free_gb
    data["writable"] = writable
    ok = free_gb >= min_free_gb and writable
    detail = f"{free_gb:.1f} GB free at {existing}; minimum {min_free_gb:.1f} GB"
    if not writable:
        detail += "; not writable"
    return CheckResult(name, ok, detail, data)


def _first_storage_symlink(configured_path: Path) -> Optional[Path]:
    current = configured_path
    while True:
        if current.is_symlink():
            return current
        parent = current.parent
        if parent == current:
            return None
        current = parent


def _missing_removable_mount(configured_path: Path, existing_path: Path) -> str:
    try:
        configured = Path(configured_path).expanduser().resolve(strict=False)
        existing = Path(existing_path).expanduser().resolve(strict=False)
    except OSError:
        return ""
    root = _removable_storage_root(configured)
    if root is None:
        return ""
    current = existing
    while True:
        try:
            current.relative_to(root)
        except ValueError:
            break
        if os.path.ismount(current):
            return ""
        if current == root or current.parent == current:
            break
        current = current.parent
    return f"{configured} is under {root} but no mounted storage device was found; mount the configured storage path"


def _removable_storage_root(path: Path) -> Optional[Path]:
    for root in REMOVABLE_STORAGE_ROOTS:
        try:
            path.relative_to(root)
        except ValueError:
            continue
        return root
    return None


def check_pi_throttling() -> CheckResult:
    is_pi = _is_raspberry_pi()
    vcgencmd, error = _trusted_system_command("vcgencmd", "Pi power command")
    if error:
        data = {
            "is_raspberry_pi": is_pi,
            "vcgencmd_available": False,
        }
        if is_pi:
            return CheckResult(
                "Pi Power",
                False,
                f"{error}; install the Raspberry Pi firmware utilities",
                data,
            )
        data["skipped"] = True
        return CheckResult("Pi Power", True, f"{error}; skipping Raspberry Pi throttling check", data)
    assert vcgencmd is not None
    data = {
        "is_raspberry_pi": is_pi,
        "vcgencmd_available": True,
    }
    try:
        completed = subprocess.run(
            [str(vcgencmd), "get_throttled"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
    except Exception as exc:
        return CheckResult("Pi Power", False, f"vcgencmd get_throttled failed: {exc}", data)
    output = completed.stdout.strip() or completed.stderr.strip()
    data["throttled_output"] = output
    if completed.returncode != 0:
        return CheckResult("Pi Power", False, f"vcgencmd get_throttled failed: {output}", data)
    value = _parse_throttled_value(output)
    if value is None:
        return CheckResult("Pi Power", False, f"unexpected throttling output: {output}", data)
    data["throttled_value"] = value
    reported = []
    for bit, label in _THROTTLE_BITS.items():
        if value & (1 << bit):
            reported.append(label)
    data["reported_flags"] = reported
    if reported:
        return CheckResult("Pi Power", False, "throttling reported since boot: " + ", ".join(reported), data)
    return CheckResult("Pi Power", True, "no under-voltage or throttling reported", data)


def _is_raspberry_pi() -> bool:
    try:
        return "Raspberry Pi" in _read_raspberry_pi_model_text(RASPBERRY_PI_MODEL_PATH)
    except (OSError, RuntimeError):
        return False


def _read_raspberry_pi_model_text(path: Path) -> str:
    target = Path(path)
    try:
        before = os.stat(target, follow_symlinks=False)
    except OSError:
        raise
    if stat.S_ISLNK(before.st_mode):
        raise RuntimeError(f"Raspberry Pi model path is a symlink: {target}")
    if not stat.S_ISREG(before.st_mode):
        raise RuntimeError(f"Raspberry Pi model path is not a regular file: {target}")
    fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            raise RuntimeError(f"Raspberry Pi model path changed before it could be read: {target}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"Raspberry Pi model path is not a regular file when opened: {target}")
        text = os.read(fd, 4096).decode("ascii", errors="ignore").strip("\x00\r\n ")
    finally:
        os.close(fd)
    if not text:
        raise RuntimeError(f"Raspberry Pi model path is empty: {target}")
    return text


def check_pi_temperature(*, warn_c: float = 70.0, fail_c: float = 80.0) -> CheckResult:
    is_pi = _is_raspberry_pi()
    temperature = _read_pi_temperature()
    data = {
        "is_raspberry_pi": is_pi,
        "temperature_available": temperature is not None,
        "warn_c": warn_c,
        "fail_c": fail_c,
    }
    if temperature is None:
        if is_pi:
            return CheckResult(
                "Pi Thermal",
                False,
                "temperature sensor unavailable on Raspberry Pi; cannot verify enclosure thermal margin",
                data,
            )
        data["skipped"] = True
        return CheckResult("Pi Thermal", True, "temperature sensor not found; skipping Raspberry Pi thermal check", data)
    data["temperature_c"] = temperature
    if not math.isfinite(temperature):
        return CheckResult("Pi Thermal", False, "temperature sensor returned a non-finite value", data)
    if temperature >= fail_c:
        return CheckResult("Pi Thermal", False, f"{temperature:.1f} C; above {fail_c:.0f} C limit", data)
    if temperature >= warn_c:
        return CheckResult("Pi Thermal", True, f"{temperature:.1f} C; warm, check airflow and enclosure", data)
    return CheckResult("Pi Thermal", True, f"{temperature:.1f} C", data)


def check_gps_sample(sample: Path) -> CheckResult:
    path = Path(sample).expanduser()
    if not path.exists():
        return CheckResult("GPS", False, f"sample file not found: {path}")
    quality_detail = ""
    missing_quality_detail = ""
    try:
        with open_trusted_gps_sample(path) as handle:
            for fix in iter_fixes(handle):
                quality_detail = gps_fix_quality_failure(fix)
                if quality_detail:
                    continue
                if not gps_fix_has_quality_fields(fix):
                    missing_quality_detail = "NMEA fix missing satellite or HDOP quality fields"
                    continue
                return CheckResult("GPS", True, _fix_detail(fix), _fix_data(fix))
    except OSError as exc:
        return CheckResult("GPS", False, f"cannot read sample file {path}: {exc}")
    except RuntimeError as exc:
        return CheckResult("GPS", False, str(exc))
    suffix = f"; {quality_detail}" if quality_detail else (f"; {missing_quality_detail}" if missing_quality_detail else "")
    return CheckResult("GPS", False, f"no valid fix found in {path}{suffix}")


@contextmanager
def open_trusted_gps_sample(sample: Path) -> Iterator[TextIO]:
    path = Path(sample).expanduser()
    if path.is_symlink():
        raise RuntimeError(f"GPS sample path is a symlink: {path}")
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        raise RuntimeError(f"GPS sample directory is a symlink: {symlink_component}")
    try:
        expected_stat = path.stat()
    except FileNotFoundError:
        raise
    except OSError as exc:
        raise RuntimeError(f"could not inspect GPS sample path {path}: {exc}") from exc
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        stat_result = os.fstat(fd)
        if stat_result.st_dev != expected_stat.st_dev or stat_result.st_ino != expected_stat.st_ino:
            raise RuntimeError(f"GPS sample path changed before it could be read: {path}")
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"GPS sample path is not a regular file: {path}")
        if stat_result.st_uid != os.getuid():
            raise RuntimeError(
                f"GPS sample path {path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"GPS sample path {path} has permissions {mode:04o}, expected no group/other write bits"
            )
        with os.fdopen(fd, encoding="ascii", errors="ignore") as handle:
            fd = -1
            yield handle
    finally:
        if fd >= 0:
            os.close(fd)


def check_gps_device_path(device: str) -> CheckResult:
    if not device:
        return CheckResult("GPS Device", False, "no GPS device configured", {"configured_path": ""})
    path = Path(device).expanduser()
    path_text = str(path)
    is_by_id_path = path_text.startswith("/dev/serial/by-id/")
    data: dict[str, object] = {
        "configured_path": path_text,
        "stable_path": _stable_gps_device_path(path_text),
        "volatile_path": _volatile_usb_device_path(path_text),
        "is_by_id_path": is_by_id_path,
    }
    if is_by_id_path and not _stable_gps_device_path(path_text):
        return CheckResult(
            "GPS Device",
            False,
            f"{path} is not a safe /dev/serial/by-id/ GPS path",
            data,
        )
    data["is_symlink"] = path.is_symlink()
    data["exists"] = path.exists()
    if is_by_id_path and data["is_symlink"] and not data["exists"]:
        try:
            target = path.resolve(strict=False)
        except OSError:
            target = path
        data["resolved_path"] = str(target)
        return CheckResult("GPS Device", False, f"{path} is a broken by-id symlink to {target}", data)
    if not data["exists"]:
        return CheckResult("GPS Device", False, f"{path} does not exist", data)
    data["is_directory"] = path.is_dir()
    if data["is_directory"]:
        return CheckResult("GPS Device", False, f"{path} is a directory, not a GPS device", data)
    if is_by_id_path and not data["is_symlink"]:
        return CheckResult("GPS Device", False, f"{path} is not a udev by-id symlink", data)
    try:
        resolved = path.resolve()
    except OSError:
        resolved = path
    data["resolved_path"] = str(resolved)
    if _volatile_usb_device_path(path_text):
        return CheckResult(
            "GPS Device",
            False,
            f"{path} exists but is not stable; use /dev/serial/by-id/ or a Raspberry Pi serial alias",
            data,
        )
    if _stable_gps_device_path(path_text):
        data["is_character_device"] = path.is_char_device()
        if not data["is_character_device"]:
            return CheckResult("GPS Device", False, f"{path} exists but is not a character device", data)
        return CheckResult("GPS Device", True, f"{path} -> {resolved}", data)
    return CheckResult(
        "GPS Device",
        False,
        f"{path} exists but is not a recognized stable GPS path; use /dev/serial/by-id/, /dev/serial0, /dev/serial1, or /dev/gps",
        data,
    )


def check_gpsd_startup_config(device: str, config_path: Path = Path("/etc/default/gpsd")) -> CheckResult:
    expected_device = str(device).strip()
    if not expected_device:
        return CheckResult("GPSD Config", False, "no expected GPSD device configured")
    if not _stable_gps_device_path(expected_device):
        return CheckResult("GPSD Config", False, f"expected GPSD device is not a safe stable path: {expected_device}")
    path = Path(config_path).expanduser()
    if path.is_symlink():
        return CheckResult("GPSD Config", False, f"GPSD config path is a symlink: {path}")
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        return CheckResult("GPSD Config", False, f"GPSD config directory is a symlink: {symlink_component}")
    if path.exists() and not path.is_file():
        return CheckResult("GPSD Config", False, f"GPSD config path is not a regular file: {path}")
    if path.exists():
        try:
            stat_result = path.stat()
        except OSError as exc:
            return CheckResult("GPSD Config", False, f"cannot inspect {path}: {exc}")
        expected_uid = 0 if path == Path("/etc/default/gpsd") else os.getuid()
        if stat_result.st_uid != expected_uid:
            return CheckResult(
                "GPSD Config",
                False,
                f"GPSD config {path} is owned by uid {stat_result.st_uid}, expected {expected_uid}",
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            return CheckResult(
                "GPSD Config",
                False,
                f"GPSD config {path} has permissions {mode:04o}, expected no group/other write bits",
            )
    else:
        stat_result = None
    try:
        expected_uid = 0 if path == Path("/etc/default/gpsd") else os.getuid()
        values = _read_gpsd_default_config(path, expected_uid=expected_uid, expected_stat=stat_result)
    except OSError as exc:
        return CheckResult("GPSD Config", False, f"cannot read {path}: {exc}")
    except RuntimeError as exc:
        return CheckResult("GPSD Config", False, str(exc))
    devices = _split_shell_words(values.get("DEVICES", ""))
    options = _split_shell_words(values.get("GPSD_OPTIONS", ""))
    failures = []
    if values.get("START_DAEMON") != "true":
        failures.append("START_DAEMON is not true")
    if values.get("USBAUTO") != "false":
        failures.append("USBAUTO is not false")
    if "-n" not in options:
        failures.append("GPSD_OPTIONS does not include -n")
    if devices != [expected_device]:
        configured = " ".join(devices) if devices else "<empty>"
        failures.append(f"DEVICES {configured} must contain exactly {expected_device}")
    if failures:
        return CheckResult("GPSD Config", False, f"{path}: " + "; ".join(failures))
    if stat_result is None:
        try:
            stat_result = path.stat()
        except OSError:
            stat_result = None
    mode = (stat_result.st_mode & 0o777) if stat_result is not None else 0
    data = {
        "path": str(path),
        "expected_device": expected_device,
        "exists": path.exists(),
        "is_symlink": path.is_symlink(),
        "directory_symlink_component": "",
        "is_regular": path.is_file(),
        "uid": stat_result.st_uid if stat_result is not None else None,
        "expected_uid": 0 if path == Path("/etc/default/gpsd") else os.getuid(),
        "mode": f"{mode:04o}",
        "values": values,
        "devices": devices,
        "gpsd_options": options,
        "start_daemon": values.get("START_DAEMON", ""),
        "usbauto": values.get("USBAUTO", ""),
        "immediate_polling": "-n" in options,
    }
    return CheckResult("GPSD Config", True, f"{path} uses {expected_device} with immediate polling", data)


def _read_gpsd_default_config(
    path: Path,
    *,
    expected_uid: int,
    expected_stat: Optional[os.stat_result] = None,
) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in _read_trusted_config_lines(
        path,
        label="GPSD config",
        expected_uid=expected_uid,
        expected_stat=expected_stat,
    ):
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        try:
            parsed = shlex.split(value, comments=False, posix=True)
        except ValueError:
            parsed = []
        values[key] = parsed[0] if len(parsed) == 1 else value.strip("\"'")
    return values


def _read_trusted_config_lines(
    path: Path,
    *,
    label: str,
    expected_uid: int,
    expected_stat: Optional[os.stat_result] = None,
) -> list[str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        if path.is_symlink():
            raise RuntimeError(f"{label} is a symlink: {path}")
        raise
    try:
        stat_result = os.fstat(fd)
        if expected_stat is not None and (stat_result.st_dev, stat_result.st_ino) != (
            expected_stat.st_dev,
            expected_stat.st_ino,
        ):
            raise RuntimeError(f"{label} changed before it could be read: {path}")
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"{label} is not a regular file: {path}")
        if stat_result.st_uid != expected_uid:
            raise RuntimeError(
                f"{label} {path} is owned by uid {stat_result.st_uid}, expected {expected_uid}"
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"{label} {path} has permissions {mode:04o}, expected no group/other write bits"
            )
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            return handle.read().splitlines()
    finally:
        if fd >= 0:
            os.close(fd)


def _split_shell_words(value: str) -> list[str]:
    try:
        return shlex.split(value)
    except ValueError:
        return []


def _stable_gps_device_path(path: str) -> bool:
    by_id_prefix = "/dev/serial/by-id/"
    if path.startswith(by_id_prefix):
        suffix = path[len(by_id_prefix) :]
        return bool(suffix) and "/" not in suffix and suffix not in {".", ".."} and _safe_gps_by_id_suffix(suffix)
    return path in {"/dev/serial0", "/dev/serial1", "/dev/gps"}


def _safe_gps_by_id_suffix(suffix: str) -> bool:
    return bool(suffix) and all(char in GPS_BY_ID_SAFE_CHARS for char in suffix)


def _volatile_usb_device_path(path: str) -> bool:
    name = Path(path).name
    return name.startswith("ttyUSB") or name.startswith("ttyACM")


def _gps_not_checked_detail(reason: str) -> str:
    return f"not checked because {reason}; {GPS_DEVICE_DISCOVERY_HINT}"


def check_gps_device(
    device: str,
    *,
    baud: int = 4800,
    seconds: float = 5.0,
    max_fix_age_seconds: float = 300.0,
) -> CheckResult:
    gps_device_check = check_gps_device_path(device)
    if not gps_device_check.ok:
        return CheckResult("GPS", False, _gps_not_checked_detail(gps_device_check.detail))
    deadline = time.monotonic() + seconds
    stale_detail = ""
    quality_detail = ""
    missing_quality_detail = ""
    try:
        with open_nmea_stream(device, baud=baud) as stream:
            for fix in iter_fixes(_read_nmea_lines_until(stream, deadline)):
                freshness_detail = _fix_freshness_failure(fix, max_fix_age_seconds=max_fix_age_seconds)
                if freshness_detail:
                    stale_detail = f"; {freshness_detail}"
                    continue
                quality_detail = gps_fix_quality_failure(fix)
                if quality_detail:
                    continue
                if not gps_fix_has_quality_fields(fix):
                    missing_quality_detail = "; NMEA fix missing satellite or HDOP quality fields"
                    continue
                return CheckResult("GPS", True, _fix_detail(fix), _fix_data(fix))
    except Exception as exc:
        return CheckResult("GPS", False, f"{device}: {exc}{missing_quality_detail}")
    fix_detail = (
        (f"; {quality_detail}" if quality_detail else "")
        or missing_quality_detail
        or stale_detail
    )
    return CheckResult(
        "GPS",
        False,
        f"no fresh navigation-quality NMEA fix from {device} at {baud} baud within {seconds:.0f}s{fix_detail}",
    )


def check_gpsd(
    *,
    host: str = "127.0.0.1",
    port: int = 2947,
    seconds: float = 5.0,
    max_fix_age_seconds: float = 300.0,
) -> CheckResult:
    deadline = time.monotonic() + seconds
    stale_detail = ""
    quality_detail = ""
    missing_quality_detail = ""
    connection_detail = ""
    saw_fix = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            timeout = max(0.1, remaining)
            max_duration = max(0.001, remaining)
            for fix in iter_gpsd_fixes(host=host, port=port, timeout=timeout, max_duration=max_duration):
                if time.monotonic() > deadline:
                    break
                saw_fix = True
                freshness_detail = _fix_freshness_failure(fix, max_fix_age_seconds=max_fix_age_seconds)
                if freshness_detail:
                    stale_detail = f"; {freshness_detail}"
                    continue
                quality_detail = gps_fix_quality_failure(fix)
                if quality_detail:
                    continue
                if not gps_fix_has_quality_fields(fix):
                    missing_quality_detail = "; GPSD fix missing satellite or HDOP quality fields"
                    continue
                return CheckResult("GPSD", True, _fix_detail(fix), _fix_data(fix))
            break
        except OSError as exc:
            if saw_fix:
                return CheckResult("GPSD", False, f"gpsd {host}:{port}: {exc}{missing_quality_detail}")
            remaining = deadline - time.monotonic()
            connection_detail = f"; last GPSD connection error: {exc}"
            if remaining <= 0:
                break
            time.sleep(min(1.0, max(0.1, remaining)))
        except Exception as exc:
            return CheckResult("GPSD", False, f"gpsd {host}:{port}: {exc}{missing_quality_detail}")
    fix_detail = (
        (f"; {quality_detail}" if quality_detail else "")
        or missing_quality_detail
        or stale_detail
        or connection_detail
    )
    return CheckResult("GPSD", False, f"no fresh navigation-quality GPSD fix within {seconds:.0f}s{fix_detail}")


def first_fix(lines: Iterable[str]) -> Optional[GPSFix]:
    for fix in iter_fixes(lines):
        return fix
    return None


def _read_nmea_lines_until(stream, deadline: float) -> Iterable[str]:
    buffer = b""
    while time.monotonic() <= deadline:
        chunk = stream.read(1)
        if not chunk:
            time.sleep(0.05)
            continue
        buffer += chunk
        if len(buffer) > NMEA_MAX_LINE_BYTES:
            raise ValueError(f"NMEA sentence exceeded {NMEA_MAX_LINE_BYTES} bytes without a line ending")
        if chunk in (b"\n", b"\r"):
            line = buffer.decode("ascii", errors="ignore").strip()
            buffer = b""
            if line:
                yield line


def _limited_find(root: Path, *, suffix: str, limit: int) -> list[Path]:
    found: list[Path] = []
    for path in root.rglob(f"*{suffix}"):
        if path.is_symlink() or not path.is_file():
            continue
        found.append(path)
        if len(found) >= limit:
            break
    return found


def _directory_writable(path: Path) -> bool:
    try:
        with tempfile.NamedTemporaryFile(prefix=".noaa-navionics.", dir=path):
            return True
    except OSError:
        return False


def _same_path(left: Path, right: Path) -> bool:
    try:
        return Path(left).expanduser().resolve() == Path(right).expanduser().resolve()
    except OSError:
        return Path(left).expanduser() == Path(right).expanduser()


def _fix_detail(fix: GPSFix) -> str:
    pieces = [f"{fix.latitude:.6f}, {fix.longitude:.6f}"]
    if fix.timestamp is not None:
        pieces.append(f"time {fix.timestamp.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')}")
    if fix.satellites is not None:
        pieces.append(f"{fix.satellites} satellites")
    if fix.hdop is not None:
        pieces.append(f"HDOP {fix.hdop}")
    if fix.speed_knots is not None:
        pieces.append(f"speed {fix.speed_knots:.1f} kt")
    if fix.course_degrees is not None:
        pieces.append(f"course {fix.course_degrees:.1f} deg")
    if fix.altitude_m is not None:
        pieces.append(f"altitude {fix.altitude_m:.1f} m")
    return "; ".join(pieces)


def _fix_data(fix: GPSFix) -> dict[str, object]:
    data: dict[str, object] = {
        "latitude": fix.latitude,
        "longitude": fix.longitude,
    }
    if fix.timestamp is not None:
        data["timestamp"] = fix.timestamp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    if fix.speed_knots is not None:
        data["speed_knots"] = fix.speed_knots
    if fix.course_degrees is not None:
        data["course_degrees"] = fix.course_degrees
    if fix.fix_quality is not None:
        data["fix_quality"] = fix.fix_quality
    if fix.satellites is not None:
        data["satellites"] = fix.satellites
    if fix.hdop is not None:
        data["hdop"] = fix.hdop
    if fix.altitude_m is not None:
        data["altitude_m"] = fix.altitude_m
    return data


def _fix_freshness_failure(fix: GPSFix, *, max_fix_age_seconds: float) -> str:
    if fix.timestamp is None:
        return "fix has no timestamp; cannot verify freshness"
    if fix.timestamp.tzinfo is None or fix.timestamp.utcoffset() is None:
        return "fix timestamp has no timezone; cannot verify freshness"
    age_seconds = (datetime.now(timezone.utc) - fix.timestamp.astimezone(timezone.utc)).total_seconds()
    if age_seconds > max_fix_age_seconds:
        return f"last timestamped fix was stale ({age_seconds:.0f}s old)"
    if age_seconds < 0.0:
        return "fix timestamp is in the future"
    return ""


def _parse_manifest_time(value: str) -> Optional[datetime]:
    if not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed.astimezone(timezone.utc)


_THROTTLE_BITS = {
    0: "under-voltage",
    1: "frequency capped",
    2: "currently throttled",
    3: "soft temperature limit active",
    16: "under-voltage occurred",
    17: "frequency cap occurred",
    18: "throttling occurred",
    19: "soft temperature limit occurred",
}


def _parse_throttled_value(output: str) -> Optional[int]:
    match = re.fullmatch(r"throttled=(0x[0-9A-Fa-f]+|[0-9]+)", output.strip())
    if not match:
        return None
    value = match.group(1)
    try:
        return int(value, 16 if value.lower().startswith("0x") else 10)
    except ValueError:
        return None


def _read_pi_temperature() -> Optional[float]:
    sysfs_temperature = _read_sysfs_pi_temperature(Path("/sys/class/thermal/thermal_zone0/temp"))
    if sysfs_temperature is not None:
        return sysfs_temperature
    return _read_vcgencmd_temperature()


def _read_sysfs_pi_temperature(path: Path) -> Optional[float]:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError:
        return None
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        return None
    fd = -1
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened) or not stat.S_ISREG(opened.st_mode):
            return None
        with os.fdopen(fd, encoding="ascii") as handle:
            fd = -1
            raw = handle.read().strip()
    except OSError:
        return None
    finally:
        if fd >= 0:
            os.close(fd)
    try:
        temperature = float(raw) / 1000
    except ValueError:
        return None
    return temperature if math.isfinite(temperature) else None


def _read_vcgencmd_temperature() -> Optional[float]:
    vcgencmd, error = _trusted_system_command("vcgencmd", "Pi power command")
    if error:
        return None
    try:
        completed = subprocess.run(
            [str(vcgencmd), "measure_temp"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
    except Exception:
        return None
    if completed.returncode != 0:
        return None
    return _parse_vcgencmd_temperature(completed.stdout.strip() or completed.stderr.strip())


def _parse_vcgencmd_temperature(output: str) -> Optional[float]:
    match = re.fullmatch(r"temp=([+-]?(?:\d+(?:\.\d*)?|\.\d+))'C", output.strip())
    if not match:
        return None
    try:
        temperature = float(match.group(1))
    except ValueError:
        return None
    return temperature if math.isfinite(temperature) else None
