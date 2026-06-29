from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional
import importlib.util
import shutil
import sys
import time

from .gps import GPSFix, iter_fixes, iter_gpsd_fixes, open_nmea_stream, read_nmea_lines


@dataclass(frozen=True)
class CheckResult:
    name: str
    ok: bool
    detail: str


def run_preflight(
    *,
    chart_dir: Path,
    gpsd: bool = False,
    gps_device: Optional[str] = None,
    gps_sample: Optional[Path] = None,
    gps_seconds: float = 5.0,
) -> list[CheckResult]:
    results = [
        check_python(),
        check_tkinter(),
        check_opencpn(),
        check_chart_dir(chart_dir),
        check_disk_space(chart_dir),
    ]
    if gpsd:
        results.append(check_gpsd(seconds=gps_seconds))
    elif gps_sample:
        results.append(check_gps_sample(gps_sample))
    elif gps_device:
        results.append(check_gps_device(gps_device, seconds=gps_seconds))
    else:
        results.append(CheckResult("GPS", False, "not checked; pass --gps-device /dev/ttyUSB0 or --gps-sample file.nmea"))
    return results


def check_python() -> CheckResult:
    version = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    ok = sys.version_info >= (3, 9)
    return CheckResult("Python", ok, f"running Python {version}")


def check_tkinter() -> CheckResult:
    ok = importlib.util.find_spec("tkinter") is not None
    return CheckResult("Tkinter", ok, "available" if ok else "missing; install python3-tk")


def check_opencpn() -> CheckResult:
    path = shutil.which("opencpn")
    return CheckResult("OpenCPN", path is not None, path or "missing; install opencpn for chart display")


def check_chart_dir(chart_dir: Path) -> CheckResult:
    path = Path(chart_dir).expanduser()
    if not path.exists():
        return CheckResult("Charts", False, f"{path} does not exist")
    enc_cells = _limited_find(path, suffix=".000", limit=5)
    zips = _limited_find(path, suffix=".zip", limit=5)
    if enc_cells:
        return CheckResult("Charts", True, f"found extracted ENC cells under {path}")
    if zips:
        return CheckResult("Charts", False, f"found ENC ZIP files under {path}; run download with --extract")
    return CheckResult("Charts", False, f"no ENC .000 cells or ZIPs found under {path}")


def check_disk_space(chart_dir: Path) -> CheckResult:
    path = Path(chart_dir).expanduser()
    existing = path if path.exists() else path.parent
    if not existing.exists():
        existing = Path.home()
    usage = shutil.disk_usage(existing)
    free_gb = usage.free / (1024 ** 3)
    ok = free_gb >= 2.0
    return CheckResult("Disk", ok, f"{free_gb:.1f} GB free at {existing}")


def check_gps_sample(sample: Path) -> CheckResult:
    path = Path(sample).expanduser()
    if not path.exists():
        return CheckResult("GPS", False, f"sample file not found: {path}")
    with path.open(encoding="ascii", errors="ignore") as handle:
        fix = first_fix(handle)
    if fix:
        return CheckResult("GPS", True, _fix_detail(fix))
    return CheckResult("GPS", False, f"no valid fix found in {path}")


def check_gps_device(device: str, *, seconds: float = 5.0) -> CheckResult:
    deadline = time.monotonic() + seconds
    try:
        with open_nmea_stream(device) as stream:
            for fix in iter_fixes(_deadline_lines(read_nmea_lines(stream), deadline)):
                return CheckResult("GPS", True, _fix_detail(fix))
    except Exception as exc:
        return CheckResult("GPS", False, f"{device}: {exc}")
    return CheckResult("GPS", False, f"no valid NMEA fix from {device} within {seconds:.0f}s")


def check_gpsd(*, seconds: float = 5.0) -> CheckResult:
    deadline = time.monotonic() + seconds
    try:
        for fix in iter_gpsd_fixes(timeout=seconds):
            if time.monotonic() > deadline:
                break
            return CheckResult("GPSD", True, _fix_detail(fix))
    except Exception as exc:
        return CheckResult("GPSD", False, f"gpsd localhost:2947: {exc}")
    return CheckResult("GPSD", False, f"no valid GPSD fix within {seconds:.0f}s")


def first_fix(lines: Iterable[str]) -> Optional[GPSFix]:
    for fix in iter_fixes(lines):
        return fix
    return None


def _deadline_lines(lines: Iterable[str], deadline: float) -> Iterable[str]:
    for line in lines:
        if time.monotonic() > deadline:
            break
        yield line


def _limited_find(root: Path, *, suffix: str, limit: int) -> list[Path]:
    found: list[Path] = []
    for path in root.rglob(f"*{suffix}"):
        found.append(path)
        if len(found) >= limit:
            break
    return found


def _fix_detail(fix: GPSFix) -> str:
    pieces = [f"{fix.latitude:.6f}, {fix.longitude:.6f}"]
    if fix.satellites is not None:
        pieces.append(f"{fix.satellites} satellites")
    if fix.hdop is not None:
        pieces.append(f"HDOP {fix.hdop}")
    return "; ".join(pieces)
