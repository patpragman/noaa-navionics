from __future__ import annotations

from configparser import ConfigParser
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


DEFAULT_CONFIG_PATH = Path("~/.config/noaa-navionics/config.ini")


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
        gps_device="/dev/ttyUSB0",
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

    chart_output = Path(charts.get("output", str(defaults.chart_output))).expanduser()
    gps_mode = gps.get("mode", defaults.gps_mode).strip().lower()
    if gps_mode not in {"gpsd", "serial"}:
        raise ValueError("gps.mode must be either gpsd or serial")
    return AppConfig(
        chart_package=charts.get("package", defaults.chart_package).strip().lower(),
        chart_value=charts.get("value", defaults.chart_value).strip(),
        chart_output=chart_output,
        extract=_get_bool(charts, "extract", defaults.extract),
        keep_zip=_get_bool(charts, "keep_zip", defaults.keep_zip),
        force=_get_bool(charts, "force", defaults.force),
        max_chart_age_days=int(charts.get("max_age_days", str(defaults.max_chart_age_days))),
        gps_mode=gps_mode,
        gps_device=gps.get("device", defaults.gps_device).strip(),
        gps_baud=int(gps.get("baud", str(defaults.gps_baud))),
        gpsd_host=gps.get("gpsd_host", defaults.gpsd_host).strip(),
        gpsd_port=int(gps.get("gpsd_port", str(defaults.gpsd_port))),
        track_output=Path(tracking.get("output", str(chart_output))).expanduser(),
        track_retention_days=int(tracking.get("retention_days", str(defaults.track_retention_days))),
    )


def write_default_config(path: Optional[Path] = None, *, overwrite: bool = False) -> Path:
    target = config_path(path)
    if target.exists() and not overwrite:
        raise FileExistsError(f"config already exists: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(default_config_text(), encoding="utf-8")
    return target


def default_config_text() -> str:
    defaults = default_config()
    return (
        "[charts]\n"
        "# package can be: state, cgd, region, updates, chart, all, catalog\n"
        f"package = {defaults.chart_package}\n"
        f"value = {defaults.chart_value}\n"
        f"output = {defaults.chart_output}\n"
        "extract = yes\n"
        "keep_zip = yes\n"
        "force = yes\n"
        f"max_age_days = {defaults.max_chart_age_days}\n"
        "\n"
        "[gps]\n"
        "# mode can be gpsd or serial. Use gpsd for onboard production so OpenCPN can share the GPS.\n"
        f"mode = {defaults.gps_mode}\n"
        f"device = {defaults.gps_device}\n"
        f"baud = {defaults.gps_baud}\n"
        f"gpsd_host = {defaults.gpsd_host}\n"
        f"gpsd_port = {defaults.gpsd_port}\n"
        "\n"
        "[tracking]\n"
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
    if package == "updates":
        return {"updates": value}
    if package == "chart":
        return {"chart": value}
    if package == "all":
        return {"all_charts": True}
    if package == "catalog":
        return {"catalog": True}
    raise ValueError("charts.package must be one of: state, cgd, region, updates, chart, all, catalog")


def _get_bool(section: object, key: str, default: bool) -> bool:
    if not hasattr(section, "get"):
        return default
    value = section.get(key)
    if value is None:
        return default
    return str(value).strip().lower() in {"1", "yes", "true", "on"}
