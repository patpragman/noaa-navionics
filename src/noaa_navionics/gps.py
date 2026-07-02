from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import BinaryIO, Callable, Iterable, Iterator, Optional, TextIO
import json
import math
import os
import socket
import stat
import termios
import time
from xml.sax.saxutils import escape

from ._safeio import cleanup_private_temp_file


BAUD_RATES = {
    4800: termios.B4800,
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
}
NMEA_MAX_LINE_BYTES = 4096
GPSD_MAX_MESSAGE_BYTES = 65536
NMEA_CHECKSUM_HEX = frozenset("0123456789ABCDEFabcdef")
EARTH_RADIUS_METERS = 6371008.8


@dataclass(frozen=True)
class GPSFix:
    timestamp: Optional[datetime] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    speed_knots: Optional[float] = None
    course_degrees: Optional[float] = None
    fix_quality: Optional[int] = None
    satellites: Optional[int] = None
    hdop: Optional[float] = None
    altitude_m: Optional[float] = None
    source_sentence: str = ""

    @property
    def valid(self) -> bool:
        return (
            self.latitude is not None
            and self.longitude is not None
            and _coordinate_in_range(self.latitude, latitude=True)
            and _coordinate_in_range(self.longitude, latitude=False)
            and not (self.latitude == 0.0 and self.longitude == 0.0)
            and self.fix_quality is not None
            and self.fix_quality != 0
        )

    @property
    def speed_mph(self) -> Optional[float]:
        if self.speed_knots is None:
            return None
        return self.speed_knots * 1.150779448


def parse_nmea_sentence(sentence: str) -> Optional[GPSFix]:
    raw = sentence.strip()
    if not raw:
        return None
    if not raw.startswith("$"):
        raise ValueError("NMEA sentence must start with '$'")
    if "*" in raw and not checksum_ok(raw):
        raise ValueError("NMEA checksum failed")

    body = raw[1:].split("*", 1)[0]
    fields = body.split(",")
    sentence_type = fields[0][-3:]
    if sentence_type == "RMC":
        return _parse_rmc(fields, raw)
    if sentence_type == "GGA":
        return _parse_gga(fields, raw)
    if sentence_type == "GSA":
        return _parse_gsa(fields, raw)
    return None


def checksum_ok(sentence: str) -> bool:
    body, supplied = sentence.strip()[1:].split("*", 1)
    if len(supplied) != 2 or any(char not in NMEA_CHECKSUM_HEX for char in supplied):
        return False
    value = 0
    for char in body:
        value ^= ord(char)
    return f"{value:02X}" == supplied.upper()


def iter_fixes(
    lines: Iterable[str],
    *,
    max_quality_merge_age_seconds: float = 5.0,
    invalid_fix_callback: Optional[Callable[[GPSFix], None]] = None,
) -> Iterator[GPSFix]:
    latest: Optional[GPSFix] = None
    latest_position_monotonic: Optional[float] = None
    latest_quality_monotonic: Optional[float] = None
    for line in lines:
        try:
            fix = parse_nmea_sentence(line)
        except ValueError:
            continue
        if fix is None:
            continue
        received_monotonic = time.monotonic()
        if fix.latitude is not None and fix.longitude is not None:
            latest_position_monotonic = received_monotonic
        if gps_fix_has_quality_fields(fix):
            latest_quality_monotonic = received_monotonic
        latest = merge_fixes(latest, fix)
        if latest and not latest.valid and invalid_fix_callback is not None:
            invalid_fix_callback(latest)
        if latest and latest.valid:
            if (
                gps_fix_has_quality_fields(latest)
                and latest_position_monotonic is not None
                and latest_quality_monotonic is not None
                and abs(latest_position_monotonic - latest_quality_monotonic) > max_quality_merge_age_seconds
            ):
                continue
            yield latest


def merge_fixes(previous: Optional[GPSFix], update: GPSFix) -> GPSFix:
    if previous is None:
        return update
    return GPSFix(
        timestamp=update.timestamp or previous.timestamp,
        latitude=update.latitude if update.latitude is not None else previous.latitude,
        longitude=update.longitude if update.longitude is not None else previous.longitude,
        speed_knots=update.speed_knots if update.speed_knots is not None else previous.speed_knots,
        course_degrees=update.course_degrees if update.course_degrees is not None else previous.course_degrees,
        fix_quality=update.fix_quality if update.fix_quality is not None else previous.fix_quality,
        satellites=update.satellites if update.satellites is not None else previous.satellites,
        hdop=update.hdop if update.hdop is not None else previous.hdop,
        altitude_m=update.altitude_m if update.altitude_m is not None else previous.altitude_m,
        source_sentence=update.source_sentence or previous.source_sentence,
    )


def open_nmea_stream(device: str, baud: int = 4800) -> BinaryIO:
    if baud not in BAUD_RATES:
        raise ValueError(f"unsupported baud rate {baud}; choose one of {sorted(BAUD_RATES)}")
    fd = _open_nmea_device_fd(device)
    try:
        attrs = termios.tcgetattr(fd)
        attrs[0] = attrs[0] & ~(termios.IGNBRK | termios.BRKINT | termios.PARMRK | termios.ISTRIP | termios.INLCR | termios.IGNCR | termios.ICRNL | termios.IXON)
        attrs[1] = attrs[1] & ~termios.OPOST
        attrs[2] = attrs[2] | termios.CLOCAL | termios.CREAD
        attrs[2] = attrs[2] & ~(termios.PARENB | termios.PARODD | termios.CSTOPB | termios.CSIZE)
        attrs[2] = attrs[2] | termios.CS8
        attrs[3] = attrs[3] & ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG | termios.IEXTEN)
        attrs[4] = BAUD_RATES[baud]
        attrs[5] = BAUD_RATES[baud]
        attrs[6][termios.VMIN] = 0
        attrs[6][termios.VTIME] = 10
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        return os.fdopen(fd, "rb", buffering=0)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        raise


def _open_nmea_device_fd(device: str) -> int:
    target = Path(device)
    try:
        before = os.stat(target)
    except OSError:
        raise
    if not stat.S_ISCHR(before.st_mode):
        raise OSError(f"GPS serial device is not a character device: {target}")
    fd = os.open(target, os.O_RDONLY | os.O_NOCTTY | getattr(os, "O_CLOEXEC", 0))
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(before, opened):
            raise RuntimeError(f"GPS serial device changed before it could be opened: {target}")
        if not stat.S_ISCHR(opened.st_mode):
            raise RuntimeError(f"GPS serial device is not a character device after opening: {target}")
        return fd
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        raise


def read_nmea_lines(
    stream: BinaryIO,
    *,
    idle_timeout: Optional[float] = None,
    max_line_bytes: int = NMEA_MAX_LINE_BYTES,
) -> Iterator[str]:
    buffer = b""
    last_data_monotonic = time.monotonic()
    while True:
        chunk = stream.read(1)
        if not chunk:
            if idle_timeout is not None and time.monotonic() - last_data_monotonic >= idle_timeout:
                raise TimeoutError(f"no NMEA bytes within {idle_timeout:g}s")
            time.sleep(0.05)
            continue
        last_data_monotonic = time.monotonic()
        buffer += chunk
        if len(buffer) > max_line_bytes:
            raise ValueError(f"NMEA sentence exceeded {max_line_bytes} bytes without a line ending")
        if chunk in (b"\n", b"\r"):
            line = buffer.decode("ascii", errors="ignore").strip()
            buffer = b""
            if line:
                yield line


def parse_gpsd_tpv(payload: str) -> Optional[GPSFix]:
    data = json.loads(payload)
    if data.get("class") != "TPV":
        return None
    mode = _non_negative_int_or_none(data.get("mode", 0))
    if mode is None or mode < 2 or "lat" not in data or "lon" not in data:
        return None
    latitude = _finite_float_or_none(data.get("lat"))
    longitude = _finite_float_or_none(data.get("lon"))
    if latitude is None or longitude is None:
        return None
    if not _coordinate_in_range(latitude, latitude=True) or not _coordinate_in_range(longitude, latitude=False):
        return None
    timestamp = None
    time_value = data.get("time")
    if isinstance(time_value, str) and time_value:
        timestamp = _parse_iso_time(time_value)
    speed_mps = _non_negative_float_or_none(data.get("speed"))
    track = _course_degrees_or_none(data.get("track"))
    altitude = _finite_float_or_none(data.get("alt"))
    return GPSFix(
        timestamp=timestamp,
        latitude=latitude,
        longitude=longitude,
        speed_knots=speed_mps * 1.943844492 if speed_mps is not None else None,
        course_degrees=track,
        fix_quality=mode,
        altitude_m=altitude,
        source_sentence=payload.strip(),
    )


def parse_gpsd_sky(payload: str) -> Optional[GPSFix]:
    data = json.loads(payload)
    if data.get("class") != "SKY":
        return None
    satellites = _gpsd_used_satellites(data)
    hdop = _non_negative_float_or_none(data.get("hdop"))
    return GPSFix(
        satellites=satellites,
        hdop=hdop,
        source_sentence=payload.strip(),
    )


def iter_gpsd_fixes(
    host: str = "127.0.0.1",
    port: int = 2947,
    timeout: float = 10.0,
    *,
    max_duration: Optional[float] = None,
    idle_timeout: Optional[float] = None,
    sky_max_age_seconds: float = 10.0,
    max_message_bytes: int = GPSD_MAX_MESSAGE_BYTES,
    invalid_fix_callback: Optional[Callable[[GPSFix], None]] = None,
) -> Iterator[GPSFix]:
    latest_sky: Optional[GPSFix] = None
    latest_sky_monotonic: Optional[float] = None
    deadline = time.monotonic() + max_duration if max_duration is not None else None
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.sendall(b'?WATCH={"enable":true,"json":true};\n')
        if deadline is None:
            sock.settimeout(idle_timeout)
        with sock.makefile("r", encoding="utf-8", errors="ignore") as handle:
            while True:
                if deadline is not None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    read_timeout = max(0.001, remaining)
                    if idle_timeout is not None:
                        read_timeout = min(read_timeout, idle_timeout)
                    sock.settimeout(read_timeout)
                try:
                    line = handle.readline(max_message_bytes + 1)
                except TimeoutError as exc:
                    if deadline is None and idle_timeout is not None:
                        raise TimeoutError(f"no GPSD messages within {idle_timeout:g}s") from exc
                    break
                if len(line) > max_message_bytes:
                    raise ValueError(f"GPSD message exceeded {max_message_bytes} bytes")
                if not line:
                    break
                try:
                    sky = parse_gpsd_sky(line)
                    if sky is not None:
                        latest_sky = sky
                        latest_sky_monotonic = time.monotonic()
                        continue
                    fix = parse_gpsd_tpv(line)
                except (json.JSONDecodeError, ValueError, TypeError):
                    continue
                if fix and not fix.valid and invalid_fix_callback is not None:
                    invalid_fix_callback(fix)
                if fix and fix.valid:
                    if (
                        latest_sky is not None
                        and latest_sky_monotonic is not None
                        and time.monotonic() - latest_sky_monotonic <= sky_max_age_seconds
                    ):
                        yield merge_fixes(latest_sky, fix)
                    else:
                        yield fix


def _finite_float_or_none(value: object) -> Optional[float]:
    if value is None:
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def _non_negative_float_or_none(value: object) -> Optional[float]:
    parsed = _finite_float_or_none(value)
    if parsed is None or parsed < 0.0:
        return None
    return parsed


def _course_degrees_or_none(value: object) -> Optional[float]:
    parsed = _finite_float_or_none(value)
    if parsed is None or parsed < 0.0 or parsed > 360.0:
        return None
    return parsed


def _non_negative_int_or_none(value: object) -> Optional[int]:
    parsed = _finite_float_or_none(value)
    if parsed is None or parsed < 0 or not parsed.is_integer():
        return None
    return int(parsed)


def _gpsd_used_satellites(data: dict[str, object]) -> Optional[int]:
    usat = data.get("uSat")
    if usat is not None:
        parsed_usat = _non_negative_int_or_none(usat)
        if parsed_usat is not None:
            return parsed_usat
    satellites = data.get("satellites")
    if not isinstance(satellites, list):
        return None
    used = 0
    saw_used = False
    for satellite in satellites:
        if not isinstance(satellite, dict):
            continue
        if "used" not in satellite:
            continue
        saw_used = True
        if satellite.get("used") is True:
            used += 1
    return used if saw_used else None


def gps_fix_quality_failure(
    fix: GPSFix,
    *,
    min_satellites: int = 4,
    max_hdop: float = 5.0,
) -> str:
    latitude = fix.latitude
    longitude = fix.longitude
    if latitude is None or longitude is None:
        return "invalid GPS fix: missing coordinates"
    if not math.isfinite(latitude) or not math.isfinite(longitude):
        return f"invalid GPS fix: non-finite coordinates {latitude:.6f}, {longitude:.6f}"
    if latitude < -90.0 or latitude > 90.0:
        return f"invalid GPS fix: latitude {latitude:.6f} outside -90..90"
    if longitude < -180.0 or longitude > 180.0:
        return f"invalid GPS fix: longitude {longitude:.6f} outside -180..180"
    if latitude == 0.0 and longitude == 0.0:
        return "invalid GPS fix: 0.000000, 0.000000 coordinates"
    if fix.satellites is not None:
        if isinstance(fix.satellites, bool) or not isinstance(fix.satellites, int):
            return f"invalid GPS fix: satellite count is not an integer: {fix.satellites!r}"
        if fix.satellites < min_satellites:
            return f"weak GPS fix: {fix.satellites} satellites; need at least {min_satellites}"
    if fix.hdop is not None:
        if isinstance(fix.hdop, bool) or not isinstance(fix.hdop, (int, float)):
            return f"invalid GPS fix: HDOP is not numeric: {fix.hdop!r}"
        hdop = float(fix.hdop)
        if not math.isfinite(hdop):
            return f"invalid GPS fix: non-finite HDOP {fix.hdop!r}"
        if hdop < 0.0:
            return f"invalid GPS fix: negative HDOP {hdop:g}"
        if hdop > max_hdop:
            return f"weak GPS fix: HDOP {hdop}; max is {max_hdop:g}"
    return ""


def distance_meters(
    latitude1: object,
    longitude1: object,
    latitude2: object,
    longitude2: object,
) -> float:
    lat1 = _finite_float_or_none(latitude1)
    lon1 = _finite_float_or_none(longitude1)
    lat2 = _finite_float_or_none(latitude2)
    lon2 = _finite_float_or_none(longitude2)
    if (
        lat1 is None
        or lon1 is None
        or lat2 is None
        or lon2 is None
        or not _coordinate_in_range(lat1, latitude=True)
        or not _coordinate_in_range(lat2, latitude=True)
        or not _coordinate_in_range(lon1, latitude=False)
        or not _coordinate_in_range(lon2, latitude=False)
    ):
        raise ValueError("coordinates must be finite latitude/longitude values in range")

    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)
    haversine = (
        math.sin(delta_phi / 2.0) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2.0) ** 2
    )
    return 2.0 * EARTH_RADIUS_METERS * math.asin(min(1.0, math.sqrt(haversine)))


def mean_longitude_degrees(longitudes: Iterable[object]) -> float:
    values: list[float] = []
    for longitude in longitudes:
        parsed = _finite_float_or_none(longitude)
        if parsed is None or not _coordinate_in_range(parsed, latitude=False):
            raise ValueError("longitudes must be finite values in range")
        values.append(parsed)
    if not values:
        raise ValueError("at least one longitude is required")
    sin_sum = sum(math.sin(math.radians(value)) for value in values)
    cos_sum = sum(math.cos(math.radians(value)) for value in values)
    if abs(sin_sum) < 1e-12 and abs(cos_sum) < 1e-12:
        return sum(values) / len(values)
    mean = math.degrees(math.atan2(sin_sum, cos_sum))
    return ((mean + 180.0) % 360.0) - 180.0


def gps_fix_has_quality_fields(fix: GPSFix) -> bool:
    return fix.satellites is not None or fix.hdop is not None


class GPXTrackLogger:
    def __init__(
        self,
        path: Path,
        name: str = "NOAA Navionics Track",
        *,
        fsync_interval_seconds: float = 30.0,
    ) -> None:
        self.path = Path(path).expanduser()
        self.name = name
        self.fsync_interval_seconds = fsync_interval_seconds
        self.file: Optional[TextIO] = None
        self._last_fsync_monotonic: Optional[float] = None

    def __enter__(self) -> "GPXTrackLogger":
        parent = self.path.parent
        _prepare_private_gpx_parent(parent)
        if self.path.is_symlink():
            raise RuntimeError(f"{self.path} is a symlink, expected a new regular GPX track file")
        fd = os.open(
            self.path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        try:
            self.file = os.fdopen(fd, "w", encoding="utf-8")
        except Exception:
            os.close(fd)
            raise
        self.file.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        self.file.write('<gpx version="1.1" creator="noaa-navionics" xmlns="http://www.topografix.com/GPX/1/1">\n')
        self.file.write(f"  <trk><name>{escape(self.name)}</name><trkseg>\n")
        self.file.flush()
        self._sync_to_disk(force=True)
        _fsync_directory(parent)
        _fsync_directory(parent.parent)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if not self.file:
            return
        self.file.write("  </trkseg></trk>\n</gpx>\n")
        self.file.flush()
        self._sync_to_disk(force=True)
        self.file.close()
        self.file = None

    def append(self, fix: GPSFix) -> None:
        if not self.file:
            raise RuntimeError("GPXTrackLogger must be opened with a context manager")
        if fix.latitude is None or fix.longitude is None:
            return
        if fix.timestamp is None:
            return
        if fix.timestamp.tzinfo is None or fix.timestamp.utcoffset() is None:
            return
        if gps_fix_quality_failure(fix):
            return
        if not gps_fix_has_quality_fields(fix):
            return
        self.file.write(f'    <trkpt lat="{fix.latitude:.8f}" lon="{fix.longitude:.8f}">\n')
        if fix.altitude_m is not None:
            self.file.write(f"      <ele>{fix.altitude_m:.2f}</ele>\n")
        self.file.write(f"      <time>{fix.timestamp.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')}</time>\n")
        if fix.satellites is not None:
            self.file.write(f"      <sat>{fix.satellites}</sat>\n")
        if fix.hdop is not None:
            self.file.write(f"      <hdop>{fix.hdop:g}</hdop>\n")
        self.file.write("    </trkpt>\n")
        self.file.flush()
        self._sync_to_disk()

    def _sync_to_disk(self, *, force: bool = False) -> None:
        if not self.file:
            return
        interval = self.fsync_interval_seconds
        if interval < 0 and not force:
            return
        current = time.monotonic()
        if not force and self._last_fsync_monotonic is not None:
            if current - self._last_fsync_monotonic < interval:
                return
        os.fsync(self.file.fileno())
        self._last_fsync_monotonic = current


def gpx_position_mark_path(base_dir: Path, timestamp: Optional[datetime] = None, *, prefix: str = "mark") -> Path:
    current = _current_utc(timestamp, message="position mark timestamp must include a timezone")
    stamp = current.strftime("%Y%m%dT%H%M%SZ")
    safe_prefix = "".join(char if char.isalnum() or char in ("-", "_") else "-" for char in prefix).strip("-_")
    if not safe_prefix:
        safe_prefix = "mark"
    return Path(base_dir).expanduser() / "tracks" / f"{safe_prefix}-{stamp}.gpx"


def write_gpx_position_mark(
    path: Path,
    fix: GPSFix,
    *,
    name: str = "Position mark",
    description: str = "",
    symbol: str = "",
) -> Path:
    target = Path(path).expanduser()
    if fix.latitude is None or fix.longitude is None:
        raise ValueError("position mark requires GPS coordinates")
    if fix.timestamp is None:
        raise ValueError("position mark requires a timestamped GPS fix")
    if fix.timestamp.tzinfo is None or fix.timestamp.utcoffset() is None:
        raise ValueError("position mark fix timestamp has no timezone")
    quality_failure = gps_fix_quality_failure(fix)
    if quality_failure:
        raise ValueError(quality_failure)
    if not gps_fix_has_quality_fields(fix):
        raise ValueError("position mark requires satellite or HDOP quality data")
    _prepare_private_gpx_parent(target.parent)
    if target.is_symlink():
        raise RuntimeError(f"{target} is a symlink, expected a new regular GPX position mark file")
    fd = os.open(
        target,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    created = True
    created_stat = os.fstat(fd)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            created = False
            _write_gpx_position_mark(handle, fix, name=name, description=description, symbol=symbol)
            handle.flush()
            os.fsync(handle.fileno())
        _fsync_directory(target.parent)
        _fsync_directory(target.parent.parent)
    except Exception:
        if created:
            os.close(fd)
        cleanup_private_temp_file(target, label="GPX position mark cleanup", expected_stat=created_stat)
        raise
    return target


def write_available_gpx_position_mark(
    path: Path,
    fix: GPSFix,
    *,
    name: str = "Position mark",
    description: str = "",
    symbol: str = "",
    attempts: int = 1000,
) -> Path:
    target = Path(path).expanduser()
    stem = target.stem
    suffix = target.suffix
    for index in range(attempts):
        candidate = target if index == 0 else target.with_name(f"{stem}-{index}{suffix}")
        if candidate.exists():
            continue
        try:
            return write_gpx_position_mark(candidate, fix, name=name, description=description, symbol=symbol)
        except FileExistsError:
            continue
    raise RuntimeError(f"could not find available GPX position mark filename near {target}")


def _write_gpx_position_mark(handle: TextIO, fix: GPSFix, *, name: str, description: str, symbol: str) -> None:
    handle.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    handle.write('<gpx version="1.1" creator="noaa-navionics" xmlns="http://www.topografix.com/GPX/1/1">\n')
    handle.write(f'  <wpt lat="{fix.latitude:.8f}" lon="{fix.longitude:.8f}">\n')
    if fix.altitude_m is not None:
        handle.write(f"    <ele>{fix.altitude_m:.2f}</ele>\n")
    handle.write(f"    <time>{fix.timestamp.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')}</time>\n")
    handle.write(f"    <name>{escape(name)}</name>\n")
    if description:
        handle.write(f"    <desc>{escape(description)}</desc>\n")
    if symbol:
        handle.write(f"    <sym>{escape(symbol)}</sym>\n")
    if fix.satellites is not None:
        handle.write(f"    <sat>{fix.satellites}</sat>\n")
    if fix.hdop is not None:
        handle.write(f"    <hdop>{fix.hdop:g}</hdop>\n")
    handle.write("  </wpt>\n")
    handle.write("</gpx>\n")


def _prepare_private_gpx_parent(parent: Path) -> None:
    symlink_component = first_symlink_ancestor(parent)
    if symlink_component is not None:
        raise RuntimeError(f"{symlink_component} is a symlink, expected real GPX track storage")
    parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    symlink_component = first_symlink_ancestor(parent)
    if symlink_component is not None:
        raise RuntimeError(f"{symlink_component} is a symlink, expected real GPX track storage")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(parent, flags)
    except OSError as exc:
        raise RuntimeError(f"{parent} could not be opened safely for GPX track storage: {exc}") from exc
    try:
        parent_stat = os.fstat(fd)
        if not stat.S_ISDIR(parent_stat.st_mode):
            raise RuntimeError(f"{parent} is not a directory")
        if parent_stat.st_uid != os.getuid():
            raise RuntimeError(f"{parent} is owned by uid {parent_stat.st_uid}, expected {os.getuid()}")
        os.fchmod(fd, 0o700)
        parent_stat = os.fstat(fd)
        if not stat.S_ISDIR(parent_stat.st_mode):
            raise RuntimeError(f"{parent} changed away from a directory after permission tightening")
        if parent_stat.st_uid != os.getuid():
            raise RuntimeError(f"{parent} is owned by uid {parent_stat.st_uid}, expected {os.getuid()}")
        parent_mode = parent_stat.st_mode & 0o777
        if parent_mode & 0o077:
            raise RuntimeError(f"{parent} has permissions {parent_mode:04o}, expected private 0700")
    finally:
        os.close(fd)
    symlink_component = first_symlink_ancestor(parent)
    if symlink_component is not None:
        raise RuntimeError(f"{symlink_component} became a symlink after permission tightening")


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


def first_symlink_ancestor(path: Path) -> Optional[Path]:
    current = Path(path).expanduser()
    candidates = [current, *current.parents]
    for candidate in candidates:
        if candidate.is_symlink():
            return candidate
    return None


def default_track_path(base_dir: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return Path(base_dir).expanduser() / "tracks" / f"track-{stamp}.gpx"


def daily_track_path(base_dir: Path, timestamp: Optional[datetime] = None) -> Path:
    current = _current_utc(timestamp, message="daily track timestamp must include a timezone")
    stamp = current.strftime("%Y%m%d")
    return Path(base_dir).expanduser() / "tracks" / f"track-{stamp}.gpx"


def _parse_rmc(fields: list[str], raw: str) -> Optional[GPSFix]:
    if len(fields) < 10 or fields[2] != "A":
        return None
    if not _rmc_mode_has_fix(fields):
        return None
    lat = _parse_lat_lon(fields[3], fields[4], latitude=True)
    lon = _parse_lat_lon(fields[5], fields[6], latitude=False)
    if lat is None or lon is None:
        return None
    timestamp = _parse_rmc_timestamp(fields[1], fields[9])
    return GPSFix(
        timestamp=timestamp,
        latitude=lat,
        longitude=lon,
        speed_knots=_non_negative_float_or_none(fields[7]),
        course_degrees=_course_degrees_or_none(fields[8]),
        fix_quality=1,
        source_sentence=raw,
    )


def _rmc_mode_has_fix(fields: list[str]) -> bool:
    if len(fields) <= 12 or fields[12] == "":
        return True
    return fields[12] in {"A", "D", "F", "P", "R"}


def _parse_gga(fields: list[str], raw: str) -> Optional[GPSFix]:
    if len(fields) < 10:
        return None
    lat = _parse_lat_lon(fields[2], fields[3], latitude=True)
    lon = _parse_lat_lon(fields[4], fields[5], latitude=False)
    if lat is None or lon is None:
        return None
    quality = _int_or_none(fields[6])
    return GPSFix(
        timestamp=_parse_time_today(fields[1]),
        latitude=lat,
        longitude=lon,
        fix_quality=quality,
        satellites=_int_or_none(fields[7]),
        hdop=_non_negative_float_or_none(fields[8]),
        altitude_m=_float_or_none(fields[9]),
        source_sentence=raw,
    )


def _parse_gsa(fields: list[str], raw: str) -> Optional[GPSFix]:
    if len(fields) < 3:
        return None
    fix_type = _int_or_none(fields[2])
    if fix_type is None:
        return None
    if fix_type == 1:
        fix_quality = 0
    elif fix_type in {2, 3}:
        fix_quality = fix_type
    else:
        return None
    satellite_fields = fields[3:15]
    satellites = sum(1 for value in satellite_fields if _positive_int_or_none(value) is not None)
    return GPSFix(
        fix_quality=fix_quality,
        satellites=satellites if satellites > 0 else None,
        hdop=_non_negative_float_or_none(fields[16]) if len(fields) > 16 else None,
        source_sentence=raw,
    )


def _parse_lat_lon(value: str, hemisphere: str, *, latitude: bool) -> Optional[float]:
    if not value or not hemisphere:
        return None
    if latitude:
        if hemisphere not in ("N", "S"):
            return None
        split_at = 2
    else:
        if hemisphere not in ("E", "W"):
            return None
        split_at = 3
    try:
        degrees = float(value[:split_at])
        minutes = float(value[split_at:])
    except ValueError:
        return None
    if not math.isfinite(degrees) or not math.isfinite(minutes):
        return None
    if degrees < 0.0:
        return None
    if minutes < 0.0 or minutes >= 60.0:
        return None
    decimal = degrees + minutes / 60
    if not _coordinate_in_range(decimal, latitude=latitude):
        return None
    if hemisphere in ("S", "W"):
        decimal = -decimal
    return decimal


def _coordinate_in_range(value: float, *, latitude: bool) -> bool:
    if not math.isfinite(value):
        return False
    limit = 90.0 if latitude else 180.0
    return -limit <= value <= limit


def _parse_rmc_timestamp(time_value: str, date_value: str) -> Optional[datetime]:
    if not time_value or not date_value or len(date_value) != 6:
        return None
    parsed_time = _time_parts(time_value)
    if parsed_time is None:
        return None
    try:
        day = int(date_value[0:2])
        month = int(date_value[2:4])
        year_value = int(date_value[4:6])
    except ValueError:
        return None
    year = 1900 + year_value if year_value >= 80 else 2000 + year_value
    hour, minute, second, microsecond, day_carry = parsed_time
    try:
        base = datetime(year, month, day, hour, minute, second, microsecond, tzinfo=timezone.utc)
    except ValueError:
        return None
    if day_carry:
        base += timedelta(days=day_carry)
    return base


def _parse_time_today(value: str, *, now: Optional[datetime] = None) -> Optional[datetime]:
    parsed_time = _time_parts(value)
    if parsed_time is None:
        return None
    now = _current_utc(now, message="GGA current time must include a timezone")
    hour, minute, second, microsecond, day_carry = parsed_time
    candidate = datetime(now.year, now.month, now.day, hour, minute, second, microsecond, tzinfo=timezone.utc)
    if day_carry:
        candidate += timedelta(days=day_carry)
    if candidate - now > _HALF_DAY:
        return candidate - _ONE_DAY
    if now - candidate > _HALF_DAY:
        return candidate + _ONE_DAY
    return candidate


def _parse_iso_time(value: str) -> Optional[datetime]:
    try:
        normalized = value.replace("Z", "+00:00")
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed.astimezone(timezone.utc)


def _current_utc(value: Optional[datetime], *, message: str) -> datetime:
    current = value or datetime.now(timezone.utc)
    if current.tzinfo is None or current.utcoffset() is None:
        raise ValueError(message)
    return current.astimezone(timezone.utc)


def _time_parts(value: str) -> Optional[tuple[int, int, int, int, int]]:
    if len(value) < 6:
        return None
    try:
        hour = int(value[0:2])
        minute = int(value[2:4])
        seconds = float(value[4:])
    except ValueError:
        return None
    if (
        hour < 0
        or hour > 23
        or minute < 0
        or minute > 59
        or seconds < 0.0
        or seconds >= 60.0
        or not math.isfinite(seconds)
    ):
        return None
    whole_seconds = int(seconds)
    microsecond = int(round((seconds - whole_seconds) * 1_000_000))
    if microsecond >= 1_000_000:
        whole_seconds += 1
        microsecond -= 1_000_000
    if whole_seconds >= 60:
        minute += whole_seconds // 60
        whole_seconds %= 60
    if minute >= 60:
        hour += minute // 60
        minute %= 60
    day_carry = 0
    if hour >= 24:
        day_carry = hour // 24
        hour %= 24
    return hour, minute, whole_seconds, microsecond, day_carry


def _float_or_none(value: str) -> Optional[float]:
    if value == "":
        return None
    return _finite_float_or_none(value)


def _int_or_none(value: str) -> Optional[int]:
    if value == "":
        return None
    return _non_negative_int_or_none(value)


def _positive_int_or_none(value: str) -> Optional[int]:
    parsed = _int_or_none(value)
    if parsed is None or parsed <= 0:
        return None
    return parsed


_HALF_DAY = timedelta(hours=12)
_ONE_DAY = timedelta(days=1)
