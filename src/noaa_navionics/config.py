from __future__ import annotations

from configparser import ConfigParser
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
import os
import tempfile


DEFAULT_CONFIG_PATH = Path("~/.config/noaa-navionics/config.ini")
CHART_PACKAGES = {"state", "cgd", "region", "chart", "all"}
CHART_PACKAGES_REQUIRING_VALUE = {"state", "cgd", "region", "chart"}
GPS_BAUD_RATES = {4800, 9600, 19200, 38400, 57600, 115200}
GPSD_LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}
STABLE_GPS_DEVICE_PATHS = {"/dev/serial0", "/dev/serial1", "/dev/gps"}


@dataclass(frozen=True)
class AppConfig:
    chart_package: str
    chart_value: str
    chart_output: Path
    extract: bool
    keep_zip: bool
    force: bool
    max_chart_age_days: int
    gps_mode: str
    gps_device: str
    gps_baud: int
    gpsd_host: str
    gpsd_port: int
    track_output: Path
    track_retention_days: int


def default_config() -> AppConfig:
    chart_output = Path("~/charts/noaa-enc").expanduser()
    return AppConfig(
        chart_package="state",
        chart_value="AK",
        chart_output=chart_output,
        extract=True,
        keep_zip=True,
        force=True,
        max_chart_age_days=30,
        gps_mode="gpsd",
        gps_device="/dev/serial/by-id/YOUR_GPS_DEVICE",
        gps_baud=4800,
        gpsd_host="127.0.0.1",
        gpsd_port=2947,
        track_output=chart_output,
        track_retention_days=90,
    )


def config_path(path: Optional[Path] = None) -> Path:
    return (path or DEFAULT_CONFIG_PATH).expanduser()


def read_config(path: Optional[Path] = None) -> AppConfig:
    defaults = default_config()
    cfg_path = config_path(path)
    parser = ConfigParser()
    if cfg_path.exists():
        parser.read(cfg_path)

    charts = parser["charts"] if parser.has_section("charts") else {}
    gps = parser["gps"] if parser.has_section("gps") else {}
    tracking = parser["tracking"] if parser.has_section("tracking") else {}

    chart_package = charts.get("package", defaults.chart_package).strip().lower()
    if chart_package not in CHART_PACKAGES:
        raise ValueError("charts.package must be one of: state, cgd, region, chart, all")
    chart_value = charts.get("value", defaults.chart_value).strip()
    if chart_package in CHART_PACKAGES_REQUIRING_VALUE and not chart_value:
        raise ValueError(f"charts.value is required when charts.package is {chart_package}")
    chart_output_text = _get_required_text(charts, "output", str(defaults.chart_output), label="charts.output")
    chart_output = Path(chart_output_text).expanduser()
    _require_absolute_path(chart_output, label="charts.output")
    max_chart_age_days = _get_int(
        charts,
        "max_age_days",
        defaults.max_chart_age_days,
        label="charts.max_age_days",
        minimum=1,
    )
    gps_mode = gps.get("mode", defaults.gps_mode).strip().lower()
    if gps_mode not in {"gpsd", "serial"}:
        raise ValueError("gps.mode must be either gpsd or serial")
    gps_baud = _get_int(gps, "baud", defaults.gps_baud, label="gps.baud")
    if gps_baud not in GPS_BAUD_RATES:
        raise ValueError(f"gps.baud must be one of: {', '.join(str(rate) for rate in sorted(GPS_BAUD_RATES))}")
    gps_device = gps.get("device", defaults.gps_device).strip()
    if gps_mode in {"gpsd", "serial"} and not gps_device:
        raise ValueError(f"gps.device is required when gps.mode is {gps_mode}")
    if gps_device and not _stable_gps_device_path(gps_device):
        if _volatile_usb_device_path(gps_device):
            raise ValueError("gps.device uses a volatile USB name; use /dev/serial/by-id/... instead")
        raise ValueError("gps.device must be /dev/serial/by-id/..., /dev/serial0, /dev/serial1, or /dev/gps")
    gpsd_host = _get_required_text(gps, "gpsd_host", defaults.gpsd_host, label="gps.gpsd_host")
    if any(separator in gpsd_host for separator in (";", "|")) or any(char.isspace() for char in gpsd_host):
        raise ValueError("gps.gpsd_host must be a hostname or IP address without spaces, semicolons, or pipes")
    if gps_mode == "gpsd" and gpsd_host.lower() not in GPSD_LOCAL_HOSTS:
        raise ValueError("gps.gpsd_host must be local for onboard gpsd mode: 127.0.0.1, localhost, or ::1")
    gpsd_port = _get_int(gps, "gpsd_port", defaults.gpsd_port, label="gps.gpsd_port", minimum=1, maximum=65535)
    track_output_text = _get_required_text(tracking, "output", str(chart_output), label="tracking.output")
    track_output = Path(track_output_text).expanduser()
    _require_absolute_path(track_output, label="tracking.output")
    track_retention_days = _get_int(
        tracking,
        "retention_days",
        defaults.track_retention_days,
        label="tracking.retention_days",
        minimum=0,
    )
    return AppConfig(
        chart_package=chart_package,
        chart_value=chart_value,
        chart_output=chart_output,
        extract=_get_bool(charts, "extract", defaults.extract, label="charts.extract"),
        keep_zip=_get_bool(charts, "keep_zip", defaults.keep_zip, label="charts.keep_zip"),
        force=_get_bool(charts, "force", defaults.force, label="charts.force"),
        max_chart_age_days=max_chart_age_days,
        gps_mode=gps_mode,
        gps_device=gps_device,
        gps_baud=gps_baud,
        gpsd_host=gpsd_host,
        gpsd_port=gpsd_port,
        track_output=track_output,
        track_retention_days=track_retention_days,
    )


def write_default_config(path: Optional[Path] = None, *, overwrite: bool = False) -> Path:
    target = config_path(path)
    if target.exists() and not overwrite:
        raise FileExistsError(f"config already exists: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    _write_text_atomic(target, default_config_text())
    return target


def default_config_text() -> str:
    defaults = default_config()
    return (
        "[charts]\n"
        "# package can be: state, cgd, region, chart, all\n"
        f"package = {defaults.chart_package}\n"
        f"value = {defaults.chart_value}\n"
        "# Use an absolute path or a path starting with ~ for unattended systemd services.\n"
        f"output = {defaults.chart_output}\n"
        "extract = yes\n"
        "keep_zip = yes\n"
        "force = yes\n"
        f"max_age_days = {defaults.max_chart_age_days}\n"
        "\n"
        "[gps]\n"
        "# mode can be gpsd or serial. Use gpsd for onboard production so OpenCPN can share the GPS.\n"
        f"mode = {defaults.gps_mode}\n"
        "# Use /dev/serial/by-id/... for USB GPS, or a documented stable alias.\n"
        f"device = {defaults.gps_device}\n"
        f"baud = {defaults.gps_baud}\n"
        f"gpsd_host = {defaults.gpsd_host}\n"
        f"gpsd_port = {defaults.gpsd_port}\n"
        "\n"
        "[tracking]\n"
        "# Use an absolute path or a path starting with ~ for unattended systemd services.\n"
        f"output = {defaults.track_output}\n"
        "# Keep this many days of rotated GPX track logs; 0 disables pruning.\n"
        f"retention_days = {defaults.track_retention_days}\n"
    )


def package_kwargs(app_config: AppConfig) -> dict[str, object]:
    package = app_config.chart_package
    value = app_config.chart_value
    if package == "state":
        return {"state": value}
    if package == "cgd":
        return {"cgd": value}
    if package == "region":
        return {"region": value}
    if package == "chart":
        return {"chart": value}
    if package == "all":
        return {"all_charts": True}
    raise ValueError("charts.package must be one of: state, cgd, region, chart, all")


def _write_text_atomic(target: Path, text: str) -> None:
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
            os.fsync(handle.fileno())
        os.replace(tmp_path, target)
        _fsync_directory(target.parent)
    finally:
        if tmp_path is not None:
            try:
                tmp_path.unlink()
            except FileNotFoundError:
                pass


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


def _get_bool(section: object, key: str, default: bool, *, label: Optional[str] = None) -> bool:
    if not hasattr(section, "get"):
        return default
    value = section.get(key)
    if value is None:
        return default
    normalized = str(value).strip().lower()
    if normalized in {"1", "yes", "true", "on"}:
        return True
    if normalized in {"0", "no", "false", "off"}:
        return False
    raise ValueError(f"{label or key} must be a boolean value")


def _get_required_text(section: object, key: str, default: str, *, label: Optional[str] = None) -> str:
    if not hasattr(section, "get"):
        value = default
    else:
        raw = section.get(key)
        value = default if raw is None else str(raw)
    text = value.strip()
    if not text:
        raise ValueError(f"{label or key} must not be empty")
    return text


def _require_absolute_path(path: Path, *, label: str) -> None:
    if not path.is_absolute():
        raise ValueError(f"{label} must be an absolute path or start with ~")


def _stable_gps_device_path(path: str) -> bool:
    by_id_prefix = "/dev/serial/by-id/"
    if path.startswith(by_id_prefix):
        suffix = path[len(by_id_prefix) :]
        return bool(suffix) and "/" not in suffix and suffix not in {".", ".."}
    return path in STABLE_GPS_DEVICE_PATHS


def _volatile_usb_device_path(path: str) -> bool:
    name = Path(path).name
    return name.startswith("ttyUSB") or name.startswith("ttyACM")


def _get_int(
    section: object,
    key: str,
    default: int,
    *,
    label: Optional[str] = None,
    minimum: Optional[int] = None,
    maximum: Optional[int] = None,
) -> int:
    field = label or key
    if not hasattr(section, "get"):
        value = default
    else:
        raw = section.get(key)
        value = default if raw is None else _parse_int(field, raw)
    if minimum is not None and value < minimum:
        raise ValueError(f"{field} must be at least {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{field} must be at most {maximum}")
    return value


def _parse_int(key: str, value: object) -> int:
    try:
        return int(str(value).strip())
    except ValueError as exc:
        raise ValueError(f"{key} must be an integer") from exc
