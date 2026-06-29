from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import BinaryIO, Iterable, Iterator, Optional, TextIO
import json
import math
import os
import socket
import termios
import time
from xml.sax.saxutils import escape


BAUD_RATES = {
    4800: termios.B4800,
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
}


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
        return self.latitude is not None and self.longitude is not None and self.fix_quality is not None and self.fix_quality != 0

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
    return None


def checksum_ok(sentence: str) -> bool:
    body, supplied = sentence.strip()[1:].split("*", 1)
    value = 0
    for char in body:
        value ^= ord(char)
    return f"{value:02X}" == supplied[:2].upper()


def iter_fixes(lines: Iterable[str]) -> Iterator[GPSFix]:
    latest: Optional[GPSFix] = None
    for line in lines:
        try:
            fix = parse_nmea_sentence(line)
        except ValueError:
            continue
        if fix is None:
            continue
        latest = merge_fixes(latest, fix)
        if latest and latest.valid:
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
    fd = os.open(device, os.O_RDONLY | os.O_NOCTTY)
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


def read_nmea_lines(stream: BinaryIO) -> Iterator[str]:
    buffer = b""
    while True:
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
    timestamp = None
    if data.get("time"):
        timestamp = _parse_iso_time(data["time"])
    speed_mps = _finite_float_or_none(data.get("speed"))
    track = _finite_float_or_none(data.get("track"))
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
    hdop = _finite_float_or_none(data.get("hdop"))
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
    sky_max_age_seconds: float = 10.0,
) -> Iterator[GPSFix]:
    latest_sky: Optional[GPSFix] = None
    latest_sky_monotonic: Optional[float] = None
    deadline = time.monotonic() + max_duration if max_duration is not None else None
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.sendall(b'?WATCH={"enable":true,"json":true};\n')
        with sock.makefile("r", encoding="utf-8", errors="ignore") as handle:
            while True:
                if deadline is not None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    sock.settimeout(max(0.001, remaining))
                try:
                    line = handle.readline()
                except TimeoutError:
                    break
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
    if fix.satellites is not None and fix.satellites < min_satellites:
        return f"weak GPS fix: {fix.satellites} satellites; need at least {min_satellites}"
    if fix.hdop is not None and fix.hdop > max_hdop:
        return f"weak GPS fix: HDOP {fix.hdop}; max is {max_hdop:g}"
    return ""


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
        parent.mkdir(parents=True, exist_ok=True)
        self.file = self.path.open("x", encoding="utf-8")
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
        if gps_fix_quality_failure(fix):
            return
        self.file.write(f'    <trkpt lat="{fix.latitude:.8f}" lon="{fix.longitude:.8f}">\n')
        if fix.altitude_m is not None:
            self.file.write(f"      <ele>{fix.altitude_m:.2f}</ele>\n")
        if fix.timestamp:
            self.file.write(f"      <time>{fix.timestamp.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')}</time>\n")
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


def default_track_path(base_dir: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return Path(base_dir).expanduser() / "tracks" / f"track-{stamp}.gpx"


def daily_track_path(base_dir: Path, timestamp: Optional[datetime] = None) -> Path:
    current = timestamp or datetime.now(timezone.utc)
    stamp = current.astimezone(timezone.utc).strftime("%Y%m%d")
    return Path(base_dir).expanduser() / "tracks" / f"track-{stamp}.gpx"


def _parse_rmc(fields: list[str], raw: str) -> Optional[GPSFix]:
    if len(fields) < 10 or fields[2] != "A":
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
        speed_knots=_float_or_none(fields[7]),
        course_degrees=_float_or_none(fields[8]),
        fix_quality=1,
        source_sentence=raw,
    )


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
        hdop=_float_or_none(fields[8]),
        altitude_m=_float_or_none(fields[9]),
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
    if minutes < 0.0 or minutes >= 60.0:
        return None
    decimal = degrees + minutes / 60
    if hemisphere in ("S", "W"):
        decimal = -decimal
    return decimal


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
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
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
        return datetime.fromisoformat(normalized).astimezone(timezone.utc)
    except ValueError:
        return None


def _time_parts(value: str) -> Optional[tuple[int, int, int, int, int]]:
    if len(value) < 6:
        return None
    try:
        hour = int(value[0:2])
        minute = int(value[2:4])
        seconds = float(value[4:])
    except ValueError:
        return None
    if hour < 0 or minute < 0 or seconds < 0.0 or not math.isfinite(seconds):
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


_HALF_DAY = timedelta(hours=12)
_ONE_DAY = timedelta(days=1)
