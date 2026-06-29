from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional
import importlib.util
import shutil
import subprocess
import sys
import time

from .gps import GPSFix, iter_fixes, iter_gpsd_fixes, open_nmea_stream, read_nmea_lines
from .downloader import MANIFEST_NAME, read_manifest
from .opencpn import chart_directory_configured, gpsd_connection_configured, opencpn_config_path


@dataclass(frozen=True)
class CheckResult:
    name: str
    ok: bool
    detail: str


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
) -> list[CheckResult]:
    results = [
        check_python(),
        check_tkinter(),
        check_opencpn(),
        check_chart_package(chart_package, chart_value),
        check_chart_dir(chart_dir),
        check_chart_manifest(chart_dir, max_age_days=max_chart_age_days),
        check_opencpn_chart_config(chart_dir),
        check_disk_space(chart_dir),
        check_pi_throttling(),
        check_pi_temperature(),
    ]
    if gpsd:
        if gps_device and gpsd_host in {"127.0.0.1", "localhost", "::1"}:
            results.append(check_gps_device_path(gps_device))
        results.append(check_opencpn_gpsd_config(host=gpsd_host, port=gpsd_port))
        results.append(check_gpsd(host=gpsd_host, port=gpsd_port, seconds=gps_seconds))
    elif gps_sample:
        results.append(check_gps_sample(gps_sample))
    elif gps_device:
        results.append(check_gps_device(gps_device, baud=gps_baud, seconds=gps_seconds))
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


def check_chart_package(package: str, value: str = "") -> CheckResult:
    package = package.strip().lower()
    value = value.strip()
    if not package:
        return CheckResult("Chart Package", True, "not checked")
    if package == "updates":
        detail = f"updates {value}" if value else "updates"
        return CheckResult(
            "Chart Package",
            False,
            f"{detail} is not a complete chart set; use state, cgd, region, chart, or all",
        )
    if package == "catalog":
        return CheckResult(
            "Chart Package",
            False,
            "catalog is metadata only; use state, cgd, region, chart, or all",
        )
    if package in {"state", "cgd", "region", "chart", "all"}:
        label = f"{package} {value}".strip()
        return CheckResult("Chart Package", True, label)
    return CheckResult(
        "Chart Package",
        False,
        "unknown package; use state, cgd, region, chart, or all",
    )


def check_opencpn_chart_config(chart_dir: Path, config_path: Optional[Path] = None) -> CheckResult:
    config_path = opencpn_config_path(config_path)
    if not config_path.exists():
        return CheckResult(
            "OpenCPN Charts",
            False,
            f"missing {config_path}; run noaa-navionics configure-opencpn after chart sync",
        )
    if chart_directory_configured(chart_dir, config_path):
        return CheckResult("OpenCPN Charts", True, f"{Path(chart_dir).expanduser()} listed in {config_path}")
    return CheckResult(
        "OpenCPN Charts",
        False,
        f"{Path(chart_dir).expanduser()} not listed in {config_path}; run noaa-navionics configure-opencpn",
    )


def check_opencpn_gpsd_config(
    *,
    host: str = "127.0.0.1",
    port: int = 2947,
    config_path: Optional[Path] = None,
) -> CheckResult:
    config_path = opencpn_config_path(config_path)
    if not config_path.exists():
        return CheckResult(
            "OpenCPN GPSD",
            False,
            f"missing {config_path}; run noaa-navionics configure-opencpn",
        )
    if gpsd_connection_configured(host=host, port=port, config_path=config_path):
        return CheckResult("OpenCPN GPSD", True, f"GPSD {host}:{port} listed in {config_path}")
    return CheckResult(
        "OpenCPN GPSD",
        False,
        f"GPSD {host}:{port} not listed in {config_path}; run noaa-navionics configure-opencpn",
    )


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


def check_chart_manifest(chart_dir: Path, *, max_age_days: int = 30) -> CheckResult:
    path = Path(chart_dir).expanduser()
    manifest_path = path / MANIFEST_NAME
    if not manifest_path.exists():
        return CheckResult("Manifest", False, f"missing {manifest_path}")
    try:
        manifest = read_manifest(path)
        created = _parse_manifest_time(str(manifest.get("created_at", "")))
    except Exception as exc:
        return CheckResult("Manifest", False, f"invalid {manifest_path}: {exc}")
    if created is None:
        return CheckResult("Manifest", False, f"manifest has no valid created_at: {manifest_path}")
    age_days = (datetime.now(timezone.utc) - created).total_seconds() / 86400
    if age_days < -0.01:
        return CheckResult("Manifest", False, "chart manifest timestamp is in the future")
    if age_days > max_age_days:
        return CheckResult("Manifest", False, f"chart manifest is {age_days:.1f} days old; max is {max_age_days}")
    package = manifest.get("package", {})
    label = package.get("label", "unknown package") if isinstance(package, dict) else "unknown package"
    return CheckResult("Manifest", True, f"{label}; updated {age_days:.1f} days ago")


def check_disk_space(chart_dir: Path) -> CheckResult:
    path = Path(chart_dir).expanduser()
    existing = path if path.exists() else path.parent
    if not existing.exists():
        existing = Path.home()
    usage = shutil.disk_usage(existing)
    free_gb = usage.free / (1024 ** 3)
    ok = free_gb >= 2.0
    return CheckResult("Disk", ok, f"{free_gb:.1f} GB free at {existing}")


def check_pi_throttling() -> CheckResult:
    vcgencmd = shutil.which("vcgencmd")
    if vcgencmd is None:
        return CheckResult("Pi Power", True, "vcgencmd not found; skipping Raspberry Pi throttling check")
    try:
        completed = subprocess.run(
            [vcgencmd, "get_throttled"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
    except Exception as exc:
        return CheckResult("Pi Power", False, f"vcgencmd get_throttled failed: {exc}")
    output = completed.stdout.strip() or completed.stderr.strip()
    if completed.returncode != 0:
        return CheckResult("Pi Power", False, f"vcgencmd get_throttled failed: {output}")
    value = _parse_throttled_value(output)
    if value is None:
        return CheckResult("Pi Power", False, f"unexpected throttling output: {output}")
    active = []
    historical = []
    for bit, label in _THROTTLE_BITS.items():
        if value & (1 << bit):
            if bit < 16:
                active.append(label)
            else:
                historical.append(label)
    if active:
        return CheckResult("Pi Power", False, "active throttling: " + ", ".join(active))
    if historical:
        return CheckResult("Pi Power", True, "healthy now; historical events: " + ", ".join(historical))
    return CheckResult("Pi Power", True, "no under-voltage or throttling reported")


def check_pi_temperature(*, warn_c: float = 70.0, fail_c: float = 80.0) -> CheckResult:
    temperature = _read_pi_temperature()
    if temperature is None:
        return CheckResult("Pi Thermal", True, "temperature sensor not found; skipping Raspberry Pi thermal check")
    if temperature >= fail_c:
        return CheckResult("Pi Thermal", False, f"{temperature:.1f} C; above {fail_c:.0f} C limit")
    if temperature >= warn_c:
        return CheckResult("Pi Thermal", True, f"{temperature:.1f} C; warm, check airflow and enclosure")
    return CheckResult("Pi Thermal", True, f"{temperature:.1f} C")


def check_gps_sample(sample: Path) -> CheckResult:
    path = Path(sample).expanduser()
    if not path.exists():
        return CheckResult("GPS", False, f"sample file not found: {path}")
    with path.open(encoding="ascii", errors="ignore") as handle:
        fix = first_fix(handle)
    if fix:
        return CheckResult("GPS", True, _fix_detail(fix))
    return CheckResult("GPS", False, f"no valid fix found in {path}")


def check_gps_device_path(device: str) -> CheckResult:
    if not device:
        return CheckResult("GPS Device", False, "no GPS device configured")
    path = Path(device).expanduser()
    if not path.exists():
        return CheckResult("GPS Device", False, f"{path} does not exist")
    try:
        resolved = path.resolve()
    except OSError:
        resolved = path
    if "/dev/serial/by-id/" in str(path):
        return CheckResult("GPS Device", True, f"{path} -> {resolved}")
    return CheckResult("GPS Device", True, f"{path} exists; prefer a stable /dev/serial/by-id/ path")


def check_gps_device(device: str, *, baud: int = 4800, seconds: float = 5.0) -> CheckResult:
    deadline = time.monotonic() + seconds
    try:
        with open_nmea_stream(device, baud=baud) as stream:
            for fix in iter_fixes(_deadline_lines(read_nmea_lines(stream), deadline)):
                return CheckResult("GPS", True, _fix_detail(fix))
    except Exception as exc:
        return CheckResult("GPS", False, f"{device}: {exc}")
    return CheckResult("GPS", False, f"no valid NMEA fix from {device} at {baud} baud within {seconds:.0f}s")


def check_gpsd(*, host: str = "127.0.0.1", port: int = 2947, seconds: float = 5.0) -> CheckResult:
    deadline = time.monotonic() + seconds
    try:
        for fix in iter_gpsd_fixes(host=host, port=port, timeout=seconds):
            if time.monotonic() > deadline:
                break
            return CheckResult("GPSD", True, _fix_detail(fix))
    except Exception as exc:
        return CheckResult("GPSD", False, f"gpsd {host}:{port}: {exc}")
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


def _parse_manifest_time(value: str) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


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
    if "=" not in output:
        return None
    value = output.split("=", 1)[1].strip()
    try:
        return int(value, 16 if value.lower().startswith("0x") else 10)
    except ValueError:
        return None


def _read_pi_temperature() -> Optional[float]:
    path = Path("/sys/class/thermal/thermal_zone0/temp")
    try:
        raw = path.read_text(encoding="ascii").strip()
    except OSError:
        return None
    try:
        return float(raw) / 1000
    except ValueError:
        return None
