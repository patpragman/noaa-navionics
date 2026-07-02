from __future__ import annotations

from configparser import ConfigParser, Error as ConfigParserError
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
import os
import stat
import tempfile

from ._safeio import cleanup_private_temp_file


DEFAULT_CONFIG_PATH = Path("~/.config/noaa-navionics/config.ini")
CHART_PACKAGES = {"state", "cgd", "region", "chart", "all"}
CHART_PACKAGES_REQUIRING_VALUE = {"state", "cgd", "region", "chart"}
GPS_BAUD_RATES = {4800, 9600, 19200, 38400, 57600, 115200}
GPSD_LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}
STABLE_GPS_DEVICE_PATHS = {"/dev/serial0", "/dev/serial1", "/dev/gps"}
GPS_UDEV_SAFE_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:+@-")
UNSAFE_STORAGE_NAMES = {
    "",
    ".cache",
    ".config",
    ".local",
    "boot",
    "dev",
    "etc",
    "home",
    "media",
    "mnt",
    "opt",
    "proc",
    "root",
    "run",
    "sys",
    "tmp",
    "usr",
    "var",
}
FORBIDDEN_STORAGE_ROOTS = (
    Path("/boot"),
    Path("/dev"),
    Path("/etc"),
    Path("/opt"),
    Path("/proc"),
    Path("/root"),
    Path("/run"),
    Path("/sys"),
    Path("/tmp"),
    Path("/usr"),
    Path("/var"),
)
ALLOWED_STORAGE_ROOTS = (Path("/media"), Path("/mnt"), Path("/run/media"))


@dataclass(frozen=True)
class AppConfig:
    chart_package: str
    chart_value: str
    chart_output: Path
    extract: bool
    keep_zip: bool
    force: bool
    max_chart_age_days: int
    min_free_gb: float
    gps_mode: str
    gps_device: str
    gps_baud: int
    gpsd_host: str
    gpsd_port: int
    track_output: Path
    track_retention_days: int
    anchor_radius_meters: float


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
        min_free_gb=2.0,
        gps_mode="gpsd",
        gps_device="/dev/serial/by-id/YOUR_GPS_DEVICE",
        gps_baud=4800,
        gpsd_host="127.0.0.1",
        gpsd_port=2947,
        track_output=chart_output,
        track_retention_days=90,
        anchor_radius_meters=50.0,
    )


def config_path(path: Optional[Path] = None) -> Path:
    return (path or DEFAULT_CONFIG_PATH).expanduser()


def read_config(path: Optional[Path] = None) -> AppConfig:
    defaults = default_config()
    cfg_path = config_path(path)
    parser = ConfigParser()
    expected_config_stat = _reject_unsafe_config_path(cfg_path)
    if expected_config_stat is not None:
        _read_existing_config(parser, cfg_path, expected_stat=expected_config_stat)

    charts = parser["charts"] if parser.has_section("charts") else {}
    gps = parser["gps"] if parser.has_section("gps") else {}
    tracking = parser["tracking"] if parser.has_section("tracking") else {}
    anchor = parser["anchor"] if parser.has_section("anchor") else {}

    chart_package = _reject_control_characters(
        charts.get("package", defaults.chart_package).strip().lower(),
        label="charts.package",
    )
    if chart_package not in CHART_PACKAGES:
        raise ValueError("charts.package must be one of: state, cgd, region, chart, all")
    chart_value = _reject_control_characters(charts.get("value", defaults.chart_value).strip(), label="charts.value")
    if chart_package in CHART_PACKAGES_REQUIRING_VALUE and not chart_value:
        raise ValueError(f"charts.value is required when charts.package is {chart_package}")
    _validate_chart_package_value(chart_package, chart_value)
    chart_output_text = _get_required_text(charts, "output", str(defaults.chart_output), label="charts.output")
    chart_output = Path(chart_output_text).expanduser()
    _require_absolute_path(chart_output, label="charts.output")
    _require_safe_storage_path(chart_output, label="charts.output")
    max_chart_age_days = _get_int(
        charts,
        "max_age_days",
        defaults.max_chart_age_days,
        label="charts.max_age_days",
        minimum=1,
    )
    min_free_gb = _get_float(
        charts,
        "min_free_gb",
        defaults.min_free_gb,
        label="charts.min_free_gb",
        minimum=0.1,
    )
    gps_mode = _reject_control_characters(gps.get("mode", defaults.gps_mode).strip().lower(), label="gps.mode")
    if gps_mode not in {"gpsd", "serial"}:
        raise ValueError("gps.mode must be either gpsd or serial")
    gps_baud = _get_int(gps, "baud", defaults.gps_baud, label="gps.baud")
    if gps_baud not in GPS_BAUD_RATES:
        raise ValueError(f"gps.baud must be one of: {', '.join(str(rate) for rate in sorted(GPS_BAUD_RATES))}")
    gps_device = _reject_control_characters(gps.get("device", defaults.gps_device).strip(), label="gps.device")
    if gps_mode in {"gpsd", "serial"} and not gps_device:
        raise ValueError(f"gps.device is required when gps.mode is {gps_mode}")
    if gps_device and not _stable_gps_device_path(gps_device):
        if _volatile_usb_device_path(gps_device):
            raise ValueError("gps.device uses a volatile USB name; use /dev/serial/by-id/... or /dev/serial/by-path/... instead")
        raise ValueError("gps.device must be /dev/serial/by-id/..., /dev/serial/by-path/..., /dev/serial0, /dev/serial1, or /dev/gps")
    gpsd_host = _get_required_text(gps, "gpsd_host", defaults.gpsd_host, label="gps.gpsd_host")
    if any(separator in gpsd_host for separator in (";", "|")) or any(char.isspace() for char in gpsd_host):
        raise ValueError("gps.gpsd_host must be a hostname or IP address without spaces, semicolons, or pipes")
    if gps_mode == "gpsd" and gpsd_host.lower() not in GPSD_LOCAL_HOSTS:
        raise ValueError("gps.gpsd_host must be local for onboard gpsd mode: 127.0.0.1, localhost, or ::1")
    gpsd_port = _get_int(gps, "gpsd_port", defaults.gpsd_port, label="gps.gpsd_port", minimum=1, maximum=65535)
    track_output_text = _get_required_text(tracking, "output", str(chart_output), label="tracking.output")
    track_output = Path(track_output_text).expanduser()
    _require_absolute_path(track_output, label="tracking.output")
    _require_safe_storage_path(track_output, label="tracking.output")
    track_retention_days = _get_int(
        tracking,
        "retention_days",
        defaults.track_retention_days,
        label="tracking.retention_days",
        minimum=0,
    )
    anchor_radius_meters = _get_float(
        anchor,
        "radius_meters",
        defaults.anchor_radius_meters,
        label="anchor.radius_meters",
        minimum=1.0,
    )
    return AppConfig(
        chart_package=chart_package,
        chart_value=chart_value,
        chart_output=chart_output,
        extract=_get_bool(charts, "extract", defaults.extract, label="charts.extract"),
        keep_zip=_get_bool(charts, "keep_zip", defaults.keep_zip, label="charts.keep_zip"),
        force=_get_bool(charts, "force", defaults.force, label="charts.force"),
        max_chart_age_days=max_chart_age_days,
        min_free_gb=min_free_gb,
        gps_mode=gps_mode,
        gps_device=gps_device,
        gps_baud=gps_baud,
        gpsd_host=gpsd_host,
        gpsd_port=gpsd_port,
        track_output=track_output,
        track_retention_days=track_retention_days,
        anchor_radius_meters=anchor_radius_meters,
    )


def write_default_config(path: Optional[Path] = None, *, overwrite: bool = False) -> Path:
    target = config_path(path)
    _reject_unsafe_config_path(target)
    if target.exists() and not overwrite:
        raise FileExistsError(f"config already exists: {target}")
    _prepare_config_parent(target)
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
        f"min_free_gb = {defaults.min_free_gb:.1f}\n"
        "\n"
        "[gps]\n"
        "# mode can be gpsd or serial. Use gpsd for onboard production so OpenCPN can share the GPS.\n"
        f"mode = {defaults.gps_mode}\n"
        "# Use /dev/serial/by-id/... or /dev/serial/by-path/... for USB GPS, or a documented stable alias.\n"
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
        "\n"
        "[anchor]\n"
        "# Default alarm radius used by anchor-watch and the status GUI Anchor Check.\n"
        f"radius_meters = {defaults.anchor_radius_meters:g}\n"
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


def _validate_chart_package_value(package: str, value: str) -> None:
    from .downloader import package_for

    try:
        if package == "state":
            package_for(state=value)
        elif package == "cgd":
            package_for(cgd=value)
        elif package == "region":
            package_for(region=value)
        elif package == "chart":
            package_for(chart=value)
        elif package == "all":
            package_for(all_charts=True)
    except ValueError as exc:
        raise ValueError(f"charts.value {exc}") from exc


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
        _validate_config_temp_for_promotion(tmp_path, expected_stat=tmp_stat)
        os.replace(tmp_path, target)
        _validate_written_config(target)
        _fsync_directory(target.parent)
    finally:
        if tmp_path is not None:
            cleanup_private_temp_file(tmp_path, label="NOAA Navionics config temp", expected_stat=tmp_stat)


def _validate_config_temp_for_promotion(path: Path, *, expected_stat: Optional[os.stat_result]) -> None:
    if expected_stat is None:
        raise RuntimeError(f"NOAA Navionics config temp was not opened safely before promotion: {path}")
    try:
        current = path.lstat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect NOAA Navionics config temp before promotion {path}: {exc}") from exc
    if stat.S_ISLNK(current.st_mode):
        raise RuntimeError(f"NOAA Navionics config temp is a symlink before promotion: {path}")
    if not stat.S_ISREG(current.st_mode):
        raise RuntimeError(f"NOAA Navionics config temp is not a regular file before promotion: {path}")
    if current.st_uid != os.getuid():
        raise RuntimeError(
            f"NOAA Navionics config temp {path} is owned by uid {current.st_uid}, expected {os.getuid()}"
        )
    mode = stat.S_IMODE(current.st_mode)
    if mode != 0o600:
        raise RuntimeError(f"NOAA Navionics config temp {path} has permissions {mode:04o}, expected private 0600")
    if not os.path.samestat(current, expected_stat):
        raise RuntimeError(f"NOAA Navionics config temp changed before promotion; leaving it in place: {path}")

    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(opened, expected_stat):
            raise RuntimeError(f"NOAA Navionics config temp changed while being opened for promotion: {path}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"NOAA Navionics config temp is not regular when opened for promotion: {path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened.st_uid != os.getuid() or opened_mode != 0o600:
            raise RuntimeError(
                f"NOAA Navionics config temp {path} is not private current-user storage before promotion"
            )
        os.fsync(fd)
    finally:
        os.close(fd)


def _validate_written_config(path: Path) -> None:
    _reject_unsafe_config_path(path)
    try:
        expected = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        raise RuntimeError(f"could not inspect promoted NOAA Navionics config {path}: {exc}") from exc
    if not stat.S_ISREG(expected.st_mode):
        raise RuntimeError(f"promoted NOAA Navionics config is not a regular file: {path}")
    if expected.st_uid != os.getuid():
        raise RuntimeError(
            f"promoted NOAA Navionics config {path} is owned by uid {expected.st_uid}, expected {os.getuid()}"
        )
    mode = expected.st_mode & 0o777
    if mode != 0o600:
        raise RuntimeError(f"promoted NOAA Navionics config {path} has permissions {mode:04o}, expected 0600")

    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        if path.is_symlink():
            raise RuntimeError(f"promoted NOAA Navionics config is a symlink: {path}") from exc
        raise RuntimeError(f"could not open promoted NOAA Navionics config {path}: {exc}") from exc
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
            raise RuntimeError(f"promoted NOAA Navionics config changed while validating: {path}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"promoted NOAA Navionics config is not a regular file when opened: {path}")
        if opened.st_uid != os.getuid():
            raise RuntimeError(
                f"promoted NOAA Navionics config {path} is owned by uid {opened.st_uid}, expected {os.getuid()}"
            )
        opened_mode = opened.st_mode & 0o777
        if opened_mode != 0o600:
            raise RuntimeError(
                f"promoted NOAA Navionics config {path} has permissions {opened_mode:04o}, expected 0600"
            )
        parser = ConfigParser()
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            try:
                parser.read_file(handle, source=str(path))
            except ConfigParserError as exc:
                raise RuntimeError(f"could not parse promoted NOAA Navionics config {path}: {exc}") from exc
        for section in ("charts", "gps", "tracking", "anchor"):
            if not parser.has_section(section):
                raise RuntimeError(f"promoted NOAA Navionics config {path} is missing [{section}]")
    finally:
        if fd >= 0:
            os.close(fd)


def _prepare_config_parent(target: Path) -> None:
    parent = target.parent
    symlink_component = _first_symlink_ancestor(parent)
    if symlink_component is not None:
        raise RuntimeError(f"NOAA Navionics config directory is a symlink: {symlink_component}")
    parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    symlink_component = _first_symlink_ancestor(parent)
    if symlink_component is not None:
        raise RuntimeError(f"NOAA Navionics config directory is a symlink: {symlink_component}")
    if not parent.is_dir():
        raise RuntimeError(f"NOAA Navionics config parent is not a directory: {parent}")
    try:
        parent_stat = parent.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect NOAA Navionics config directory {parent}: {exc}") from exc
    if parent_stat.st_uid != os.getuid():
        raise RuntimeError(
            f"NOAA Navionics config directory {parent} is owned by uid {parent_stat.st_uid}, expected {os.getuid()}"
        )
    parent_mode = parent_stat.st_mode & 0o777
    if parent_mode & 0o022:
        raise RuntimeError(
            f"NOAA Navionics config directory {parent} has permissions {parent_mode:04o}, "
            "expected no group/other write bits"
        )
    if parent_mode & 0o077:
        try:
            os.chmod(parent, 0o700)
        except OSError as exc:
            raise RuntimeError(f"could not make NOAA Navionics config directory private: {parent}: {exc}") from exc
    symlink_component = _first_symlink_ancestor(parent)
    if symlink_component is not None:
        raise RuntimeError(
            f"NOAA Navionics config directory became a symlink after permission tightening: {symlink_component}"
        )
    try:
        parent_stat = parent.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect NOAA Navionics config directory {parent}: {exc}") from exc
    if parent_stat.st_uid != os.getuid():
        raise RuntimeError(
            f"NOAA Navionics config directory {parent} is owned by uid {parent_stat.st_uid}, expected {os.getuid()}"
        )
    parent_mode = parent_stat.st_mode & 0o777
    if parent_mode & 0o077:
        raise RuntimeError(
            f"NOAA Navionics config directory {parent} has permissions {parent_mode:04o}, "
            "expected private 0700"
        )


def _reject_unsafe_config_path(path: Path) -> Optional[os.stat_result]:
    path = Path(path).expanduser()
    if path.is_symlink():
        raise RuntimeError(f"NOAA Navionics config is a symlink: {path}")
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        raise RuntimeError(f"NOAA Navionics config directory is a symlink: {symlink_component}")
    if path.parent.exists():
        if not path.parent.is_dir():
            raise RuntimeError(f"NOAA Navionics config parent is not a directory: {path.parent}")
        try:
            parent_stat = path.parent.stat()
        except OSError as exc:
            raise RuntimeError(f"could not inspect NOAA Navionics config directory {path.parent}: {exc}") from exc
        if parent_stat.st_uid != os.getuid():
            raise RuntimeError(
                f"NOAA Navionics config directory {path.parent} is owned by uid "
                f"{parent_stat.st_uid}, expected {os.getuid()}"
            )
        parent_mode = parent_stat.st_mode & 0o777
        if parent_mode & 0o022:
            raise RuntimeError(
                f"NOAA Navionics config directory {path.parent} has permissions {parent_mode:04o}, "
                "expected no group/other write bits"
            )
    if not path.exists():
        return None
    if not path.is_file():
        raise RuntimeError(f"NOAA Navionics config is not a regular file: {path}")
    try:
        path_stat = path.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect NOAA Navionics config {path}: {exc}") from exc
    if path_stat.st_uid != os.getuid():
        raise RuntimeError(
            f"NOAA Navionics config {path} is owned by uid {path_stat.st_uid}, expected {os.getuid()}"
        )
    mode = path_stat.st_mode & 0o777
    if mode & 0o022:
        raise RuntimeError(
            f"NOAA Navionics config {path} has permissions {mode:04o}, expected no group/other write bits"
        )
    return path_stat


def _read_existing_config(
    parser: ConfigParser,
    path: Path,
    *,
    expected_stat: Optional[os.stat_result] = None,
) -> None:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        if expected_stat is not None:
            raise RuntimeError(f"NOAA Navionics config disappeared while being opened: {path}") from None
        return
    except OSError as exc:
        if path.is_symlink():
            raise RuntimeError(f"NOAA Navionics config is a symlink: {path}") from exc
        raise RuntimeError(f"could not open NOAA Navionics config {path}: {exc}") from exc

    try:
        opened = os.fstat(fd)
        if expected_stat is not None and not os.path.samestat(opened, expected_stat):
            raise RuntimeError(f"NOAA Navionics config changed while being opened: {path}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"NOAA Navionics config is not a regular file when opened: {path}")
        if opened.st_uid != os.getuid():
            raise RuntimeError(
                f"NOAA Navionics config {path} is owned by uid {opened.st_uid}, expected {os.getuid()}"
            )
        mode = opened.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"NOAA Navionics config {path} has permissions {mode:04o}, expected no group/other write bits"
            )
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            parser.read_file(handle, source=str(path))
    finally:
        if fd >= 0:
            os.close(fd)


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
    field = label or key
    if not hasattr(section, "get"):
        value = default
    else:
        raw = section.get(key)
        value = default if raw is None else str(raw)
    text = value.strip()
    if not text:
        raise ValueError(f"{field} must not be empty")
    _reject_control_characters(text, label=field)
    return text


def _reject_control_characters(text: str, *, label: str) -> str:
    if any(ord(char) < 32 or ord(char) == 127 for char in text):
        raise ValueError(f"{label} must not contain control characters")
    return text


def _require_absolute_path(path: Path, *, label: str) -> None:
    if not path.is_absolute():
        raise ValueError(f"{label} must be an absolute path or start with ~")


def _require_safe_storage_path(path: Path, *, label: str) -> None:
    expanded = Path(path).expanduser()
    if ".." in expanded.parts:
        raise ValueError(f"{label} must not contain parent-directory components")
    home = Path.home()
    unsafe_paths = {Path("/"), home}
    unsafe_paths.update(Path("/") / name for name in UNSAFE_STORAGE_NAMES if name and not name.startswith("."))
    unsafe_paths.update(home / name for name in (".cache", ".config", ".local"))
    if expanded in unsafe_paths or expanded.name in UNSAFE_STORAGE_NAMES:
        raise ValueError(
            f"{label} must be a dedicated storage directory, not a broad system or home directory"
        )
    resolved = expanded.resolve(strict=False)
    for root in FORBIDDEN_STORAGE_ROOTS:
        if _path_is_relative_to(resolved, root) and not any(
            _path_is_relative_to(resolved, allowed) for allowed in ALLOWED_STORAGE_ROOTS
        ):
            raise ValueError(f"{label} must not be under volatile or system directory {root}")


def _stable_gps_device_path(path: str) -> bool:
    for prefix in ("/dev/serial/by-id/", "/dev/serial/by-path/"):
        if path.startswith(prefix):
            suffix = path[len(prefix) :]
            return bool(suffix) and "/" not in suffix and suffix not in {".", ".."} and _safe_gps_udev_suffix(suffix)
    return path in STABLE_GPS_DEVICE_PATHS


def _safe_gps_udev_suffix(suffix: str) -> bool:
    return bool(suffix) and all(char in GPS_UDEV_SAFE_CHARS for char in suffix)


def _volatile_usb_device_path(path: str) -> bool:
    name = Path(path).name
    return name.startswith("ttyUSB") or name.startswith("ttyACM")


def _path_is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


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


def _get_float(
    section: object,
    key: str,
    default: float,
    *,
    label: Optional[str] = None,
    minimum: Optional[float] = None,
    maximum: Optional[float] = None,
) -> float:
    field = label or key
    if not hasattr(section, "get"):
        value = default
    else:
        raw = section.get(key)
        value = default if raw is None else _parse_float(field, raw)
    if minimum is not None and value < minimum:
        raise ValueError(f"{field} must be at least {minimum:g}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{field} must be at most {maximum:g}")
    return value


def _parse_float(key: str, value: object) -> float:
    try:
        parsed = float(str(value).strip())
    except ValueError as exc:
        raise ValueError(f"{key} must be a number") from exc
    if parsed != parsed or parsed in {float("inf"), float("-inf")}:
        raise ValueError(f"{key} must be a finite number")
    return parsed
