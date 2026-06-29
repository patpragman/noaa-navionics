from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional
import importlib.util
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

from .gps import (
    GPSFix,
    gps_fix_has_quality_fields,
    gps_fix_quality_failure,
    iter_fixes,
    iter_gpsd_fixes,
    open_nmea_stream,
)
from .downloader import MANIFEST_NAME, count_enc_cells, package_for, read_manifest, sha256_file
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
    track_output: Optional[Path] = None,
) -> list[CheckResult]:
    results = [
        check_python(),
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
        ),
        check_opencpn_chart_config(chart_dir),
        check_disk_space(chart_dir),
        check_pi_throttling(),
        check_pi_temperature(),
    ]
    if track_output is not None and not _same_path(chart_dir, track_output):
        results.append(check_disk_space(track_output, name="Track Disk"))
    if gpsd:
        if gps_device and gpsd_host in {"127.0.0.1", "localhost", "::1"}:
            results.append(check_gps_device_path(gps_device))
            results.append(check_gpsd_startup_config(gps_device))
        results.append(check_opencpn_gpsd_config(host=gpsd_host, port=gpsd_port))
        results.append(check_chrony_gps_time_source(seconds=gps_seconds))
        results.append(check_gpsd(host=gpsd_host, port=gpsd_port, seconds=gps_seconds))
    elif gps_sample:
        results.append(check_gps_sample(gps_sample))
    elif gps_device:
        results.append(check_gps_device(gps_device, baud=gps_baud, seconds=gps_seconds))
    else:
        results.append(
            CheckResult(
                "GPS",
                False,
                "not checked; pass --gps-device /dev/serial/by-id/YOUR_GPS_DEVICE or --gps-sample file.nmea",
            )
        )
    return results


def check_python() -> CheckResult:
    version = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    ok = sys.version_info >= (3, 9)
    return CheckResult("Python", ok, f"running Python {version}")


def check_system_clock(now: Optional[datetime] = None, *, min_year: int = 2024) -> CheckResult:
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    if current.year < min_year:
        return CheckResult(
            "Clock",
            False,
            f"system clock is {current.isoformat()}; set time or enable time sync before relying on chart age checks",
        )
    return CheckResult("Clock", True, current.isoformat())


def check_time_synchronization() -> CheckResult:
    if not _is_raspberry_pi():
        return CheckResult("Time Sync", True, "not a Raspberry Pi; skipping time synchronization check")
    timedatectl = shutil.which("timedatectl")
    if timedatectl is None:
        return CheckResult("Time Sync", False, "timedatectl not found; cannot verify Raspberry Pi clock sync")
    try:
        completed = subprocess.run(
            [timedatectl, "show", "-p", "SystemClockSynchronized", "-p", "NTPSynchronized"],
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
        return CheckResult("Time Sync", False, f"timedatectl failed: {output}")
    values = {}
    for line in completed.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().lower()
    synchronized = values.get("SystemClockSynchronized") or values.get("NTPSynchronized")
    if synchronized == "yes":
        return CheckResult("Time Sync", True, "system clock is synchronized")
    if synchronized == "no":
        return CheckResult(
            "Time Sync",
            False,
            "system clock is not synchronized; connect network time or configure GPS time before relying on chart age and GPX timestamps",
        )
    return CheckResult("Time Sync", False, f"could not determine clock synchronization from timedatectl: {output}")


def check_tkinter() -> CheckResult:
    ok = importlib.util.find_spec("tkinter") is not None
    return CheckResult("Tkinter", ok, "available" if ok else "missing; install python3-tk")


def check_opencpn() -> CheckResult:
    path = shutil.which("opencpn")
    return CheckResult("OpenCPN", path is not None, path or "missing; install opencpn for chart display")


def check_display_power_tool() -> CheckResult:
    path = shutil.which("xset")
    return CheckResult(
        "Display Power",
        path is not None,
        path or "missing; install x11-xserver-utils so the launcher can disable display blanking",
    )


def check_chrony_gps_time_source(*, seconds: float = 5.0, poll_interval: float = 1.0) -> CheckResult:
    if not _is_raspberry_pi():
        return CheckResult("GPS Time Source", True, "not a Raspberry Pi; skipping chrony GPS source check")
    chronyc = shutil.which("chronyc")
    if chronyc is None:
        return CheckResult("GPS Time Source", False, "chronyc not found; install chrony")
    deadline = time.monotonic() + max(0.0, seconds)
    result = _check_chrony_gps_time_source_once(chronyc)
    while not result.ok and time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        time.sleep(min(max(0.01, poll_interval), remaining))
        result = _check_chrony_gps_time_source_once(chronyc)
    if not result.ok and seconds > 0:
        return CheckResult(result.name, False, f"{result.detail} within {seconds:.0f}s")
    return result


def _check_chrony_gps_time_source_once(chronyc: str) -> CheckResult:
    try:
        completed = subprocess.run(
            [chronyc, "sources", "-n"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
    except Exception as exc:
        return CheckResult("GPS Time Source", False, f"chronyc sources failed: {exc}")
    output = completed.stdout.strip() or completed.stderr.strip()
    if completed.returncode != 0:
        return CheckResult("GPS Time Source", False, f"chronyc sources failed: {output}")
    gps_lines = [
        line.strip()
        for line in completed.stdout.splitlines()
        if line.startswith("#") and "GPS" in line.upper()
    ]
    usable = [line for line in gps_lines if len(line) > 1 and line[1] in "*+-"]
    if usable:
        return CheckResult("GPS Time Source", True, "chrony GPS source: " + usable[0])
    if gps_lines:
        return CheckResult("GPS Time Source", False, "chrony GPS source is not usable yet: " + gps_lines[0])
    return CheckResult("GPS Time Source", False, "chrony does not report a GPS refclock source")


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
    chart_path = Path(chart_dir).expanduser()
    if not config_path.exists():
        return CheckResult(
            "OpenCPN Charts",
            False,
            f"missing {config_path}; run noaa-navionics configure-opencpn after chart sync",
        )
    if not chart_path.exists():
        return CheckResult("OpenCPN Charts", False, f"chart directory does not exist: {chart_path}")
    if chart_directory_configured(chart_dir, config_path):
        return CheckResult("OpenCPN Charts", True, f"{chart_path} listed in {config_path}")
    return CheckResult(
        "OpenCPN Charts",
        False,
        f"{chart_path} not listed in {config_path}; run noaa-navionics configure-opencpn",
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


def check_chart_update_debris(chart_dir: Path) -> CheckResult:
    path = Path(chart_dir).expanduser()
    if not path.exists():
        return CheckResult("Chart Update Debris", True, f"not checked; {path} does not exist")
    try:
        debris = sorted(
            child
            for child in path.iterdir()
            if child.name.startswith(".") and (child.name.endswith(".extracting") or child.name.endswith(".previous"))
        )
    except OSError as exc:
        return CheckResult("Chart Update Debris", False, f"cannot inspect chart directory: {exc}")
    if debris:
        names = ", ".join(child.name for child in debris[:5])
        suffix = "" if len(debris) <= 5 else f", and {len(debris) - 5} more"
        return CheckResult(
            "Chart Update Debris",
            False,
            f"remove stale chart update debris before departure: {names}{suffix}",
        )
    return CheckResult("Chart Update Debris", True, "no interrupted chart updates found")


def check_chart_manifest(
    chart_dir: Path,
    *,
    max_age_days: int = 30,
    expected_package: str = "",
    expected_value: str = "",
) -> CheckResult:
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
    extract = manifest.get("extract", {})
    if not isinstance(extract, dict):
        return CheckResult("Manifest", False, "manifest has no extract section")
    extract_path_text = str(extract.get("path", "")).strip()
    if not extract_path_text:
        return CheckResult("Manifest", False, "manifest does not record an extracted chart path")
    extract_path = Path(extract_path_text).expanduser()
    if not extract_path.exists():
        return CheckResult("Manifest", False, f"manifest extract path does not exist: {extract_path}")
    try:
        extract_path.resolve().relative_to(path.resolve())
    except ValueError:
        return CheckResult("Manifest", False, f"manifest extract path is outside chart directory: {extract_path}")
    try:
        manifest_cell_count = int(extract.get("enc_cell_count", 0))
    except (TypeError, ValueError):
        return CheckResult("Manifest", False, "manifest has invalid ENC cell count")
    if manifest_cell_count <= 0:
        return CheckResult("Manifest", False, "manifest reports no extracted ENC cells")
    actual_cell_count = count_enc_cells(extract_path)
    if actual_cell_count <= 0:
        return CheckResult("Manifest", False, f"no ENC cells found at manifest extract path: {extract_path}")
    if actual_cell_count < manifest_cell_count:
        return CheckResult(
            "Manifest",
            False,
            f"manifest recorded {manifest_cell_count} ENC cells but only {actual_cell_count} remain at {extract_path}",
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
    archive_check = _check_manifest_archive(path, manifest)
    if archive_check is not None:
        return archive_check
    download_url_check = _check_manifest_download_url(manifest)
    if download_url_check is not None:
        return download_url_check
    return CheckResult("Manifest", True, f"{label}; {actual_cell_count} ENC cells; updated {age_days:.1f} days ago")


def _check_manifest_download_url(manifest: dict[str, object]) -> Optional[CheckResult]:
    package = manifest.get("package", {})
    download = manifest.get("download", {})
    if not isinstance(package, dict) or not isinstance(download, dict):
        return CheckResult("Manifest", False, "manifest has no package or download section")
    package_url = str(package.get("url", "")).strip()
    download_url = str(download.get("url", "")).strip()
    if not download_url:
        return CheckResult("Manifest", False, "manifest does not record a download URL")
    if package_url and download_url != package_url:
        return CheckResult(
            "Manifest",
            False,
            f"manifest download URL {download_url} does not match package URL {package_url}",
        )
    return None


def _check_manifest_archive(chart_dir: Path, manifest: dict[str, object]) -> Optional[CheckResult]:
    download = manifest.get("download", {})
    if not isinstance(download, dict):
        return CheckResult("Manifest", False, "manifest has no download section")
    archive_path_text = str(download.get("path", "")).strip()
    if not archive_path_text:
        return None
    archive_path = Path(archive_path_text).expanduser()
    try:
        archive_path.resolve().relative_to(chart_dir.resolve())
    except ValueError:
        return CheckResult("Manifest", False, f"manifest download path is outside chart directory: {archive_path}")
    if not archive_path.exists():
        return None
    try:
        expected_bytes = int(download.get("bytes", 0))
    except (TypeError, ValueError):
        return CheckResult("Manifest", False, "manifest has invalid download byte count")
    actual_bytes = archive_path.stat().st_size
    if expected_bytes <= 0:
        return CheckResult("Manifest", False, "manifest does not record a positive download byte count")
    if actual_bytes != expected_bytes:
        return CheckResult(
            "Manifest",
            False,
            f"manifest recorded {expected_bytes} downloaded bytes but {archive_path} has {actual_bytes}",
        )
    expected_sha256 = str(download.get("sha256", "")).strip().lower()
    if not expected_sha256:
        return CheckResult("Manifest", False, "manifest does not record a download SHA-256")
    actual_sha256 = sha256_file(archive_path)
    if actual_sha256.lower() != expected_sha256:
        return CheckResult("Manifest", False, f"manifest SHA-256 does not match {archive_path}")
    return None


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


def check_disk_space(chart_dir: Path, *, name: str = "Disk") -> CheckResult:
    path = Path(chart_dir).expanduser()
    existing = path if path.exists() else path.parent
    if not existing.exists():
        return CheckResult(name, False, f"{existing} does not exist; create or mount the configured storage path")
    if not existing.is_dir():
        return CheckResult(name, False, f"{existing} is not a directory")
    usage = shutil.disk_usage(existing)
    free_gb = usage.free / (1024 ** 3)
    writable = _directory_writable(existing)
    ok = free_gb >= 2.0 and writable
    detail = f"{free_gb:.1f} GB free at {existing}"
    if not writable:
        detail += "; not writable"
    return CheckResult(name, ok, detail)


def check_pi_throttling() -> CheckResult:
    vcgencmd = shutil.which("vcgencmd")
    if vcgencmd is None:
        if _is_raspberry_pi():
            return CheckResult(
                "Pi Power",
                False,
                "vcgencmd not found on Raspberry Pi; install the Raspberry Pi firmware utilities",
            )
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


def _is_raspberry_pi() -> bool:
    model_path = Path("/proc/device-tree/model")
    try:
        return "Raspberry Pi" in model_path.read_text(encoding="ascii", errors="ignore")
    except OSError:
        return False


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
    quality_detail = ""
    with path.open(encoding="ascii", errors="ignore") as handle:
        for fix in iter_fixes(handle):
            quality_detail = gps_fix_quality_failure(fix)
            if quality_detail:
                continue
            return CheckResult("GPS", True, _fix_detail(fix))
    suffix = f"; {quality_detail}" if quality_detail else ""
    return CheckResult("GPS", False, f"no valid fix found in {path}{suffix}")


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
    path_text = str(path)
    if _volatile_usb_device_path(path_text):
        return CheckResult(
            "GPS Device",
            False,
            f"{path} exists but is not stable; use /dev/serial/by-id/ or a Raspberry Pi serial alias",
        )
    if _stable_gps_device_path(path_text):
        return CheckResult("GPS Device", True, f"{path} -> {resolved}")
    return CheckResult(
        "GPS Device",
        False,
        f"{path} exists but is not a recognized stable GPS path; use /dev/serial/by-id/, /dev/serial0, /dev/serial1, or /dev/gps",
    )


def check_gpsd_startup_config(device: str, config_path: Path = Path("/etc/default/gpsd")) -> CheckResult:
    expected_device = str(device).strip()
    if not expected_device:
        return CheckResult("GPSD Config", False, "no expected GPSD device configured")
    path = Path(config_path).expanduser()
    try:
        values = _read_gpsd_default_config(path)
    except OSError as exc:
        return CheckResult("GPSD Config", False, f"cannot read {path}: {exc}")
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
    return CheckResult("GPSD Config", True, f"{path} uses {expected_device} with immediate polling")


def _read_gpsd_default_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open(encoding="utf-8") as handle:
        for raw_line in handle:
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


def _split_shell_words(value: str) -> list[str]:
    try:
        return shlex.split(value)
    except ValueError:
        return []


def _stable_gps_device_path(path: str) -> bool:
    return "/dev/serial/by-id/" in path or path in {"/dev/serial0", "/dev/serial1", "/dev/gps"}


def _volatile_usb_device_path(path: str) -> bool:
    name = Path(path).name
    return name.startswith("ttyUSB") or name.startswith("ttyACM")


def check_gps_device(
    device: str,
    *,
    baud: int = 4800,
    seconds: float = 5.0,
    max_fix_age_seconds: float = 300.0,
) -> CheckResult:
    deadline = time.monotonic() + seconds
    stale_detail = ""
    quality_detail = ""
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
                return CheckResult("GPS", True, _fix_detail(fix))
    except Exception as exc:
        return CheckResult("GPS", False, f"{device}: {exc}")
    fix_detail = stale_detail or (f"; {quality_detail}" if quality_detail else "")
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
    pending_without_quality: Optional[GPSFix] = None
    try:
        for fix in iter_gpsd_fixes(host=host, port=port, timeout=seconds):
            if time.monotonic() > deadline:
                break
            freshness_detail = _fix_freshness_failure(fix, max_fix_age_seconds=max_fix_age_seconds)
            if freshness_detail:
                stale_detail = f"; {freshness_detail}"
                continue
            quality_detail = gps_fix_quality_failure(fix)
            if quality_detail:
                pending_without_quality = None
                continue
            if not gps_fix_has_quality_fields(fix):
                pending_without_quality = fix
                continue
            return CheckResult("GPSD", True, _fix_detail(fix))
    except Exception as exc:
        if pending_without_quality is not None:
            return CheckResult("GPSD", True, _fix_detail(pending_without_quality))
        return CheckResult("GPSD", False, f"gpsd {host}:{port}: {exc}")
    if pending_without_quality is not None:
        return CheckResult("GPSD", True, _fix_detail(pending_without_quality))
    fix_detail = stale_detail or (f"; {quality_detail}" if quality_detail else "")
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
        if chunk in (b"\n", b"\r"):
            line = buffer.decode("ascii", errors="ignore").strip()
            buffer = b""
            if line:
                yield line


def _limited_find(root: Path, *, suffix: str, limit: int) -> list[Path]:
    found: list[Path] = []
    for path in root.rglob(f"*{suffix}"):
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
    if fix.satellites is not None:
        pieces.append(f"{fix.satellites} satellites")
    if fix.hdop is not None:
        pieces.append(f"HDOP {fix.hdop}")
    return "; ".join(pieces)


def _fix_freshness_failure(fix: GPSFix, *, max_fix_age_seconds: float) -> str:
    if fix.timestamp is None:
        return "fix has no timestamp; cannot verify freshness"
    age_seconds = (datetime.now(timezone.utc) - fix.timestamp.astimezone(timezone.utc)).total_seconds()
    if age_seconds > max_fix_age_seconds:
        return f"last timestamped fix was stale ({age_seconds:.0f}s old)"
    if age_seconds < -30:
        return "fix timestamp is in the future"
    return ""


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
