from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from .config import AppConfig, read_config
from .downloader import MANIFEST_NAME, read_manifest
from .health import CheckResult, run_preflight
from .opencpn import opencpn_config_path, read_chart_directories, read_data_connections
from . import __version__


DEFAULT_SOURCE_REVISION_PATH = Path("~/.local/share/noaa-navionics/source-revision")
DEFAULT_LAUNCHER_ENV_PATH = Path("~/.config/noaa-navionics/launcher.env")
DEFAULT_AUTOSTART_PATH = Path("~/.config/autostart/noaa-navionics-chartplotter.desktop")
DEFAULT_LIGHTDM_AUTOLOGIN_PATH = Path("/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf")
BOOT_ID_PATH = Path("/proc/sys/kernel/random/boot_id")
USER_UNIT_PROPERTIES = {
    "noaa-navionics.service": [
        "FragmentPath",
        "ExecStartPre",
        "ExecStart",
        "Type",
        "TimeoutStartUSec",
        "Restart",
        "RestartUSec",
        "StartLimitIntervalUSec",
        "StartLimitBurst",
        "NoNewPrivileges",
        "PrivateTmp",
        "UMask",
    ],
    "noaa-navionics.timer": [
        "FragmentPath",
        "TimersCalendar",
        "Persistent",
        "RandomizedDelayUSec",
    ],
    "noaa-navionics-track.service": [
        "FragmentPath",
        "ExecStart",
        "Type",
        "StandardOutput",
        "Restart",
        "RestartUSec",
        "StartLimitIntervalUSec",
        "StartLimitBurst",
        "NoNewPrivileges",
        "PrivateTmp",
        "UMask",
    ],
    "noaa-navionics-preflight.service": [
        "FragmentPath",
        "Wants",
        "After",
        "ExecStart",
        "Type",
        "Environment",
        "EnvironmentFiles",
        "Result",
        "ExecMainStatus",
        "ExecMainStartTimestampMonotonic",
        "TimeoutStartUSec",
        "Restart",
        "RestartUSec",
        "StartLimitIntervalUSec",
        "StartLimitBurst",
        "NoNewPrivileges",
        "PrivateTmp",
    ],
}
USER_UNIT_INSTALL_TARGETS = {
    "noaa-navionics.timer": "timers.target",
    "noaa-navionics-track.service": "default.target",
    "noaa-navionics-preflight.service": "default.target",
}


def build_status_report(
    *,
    config_path: Path,
    gps_sample: Optional[Path] = None,
    gps_seconds: float = 5.0,
) -> dict[str, object]:
    app_config = read_config(config_path)
    gps_mode = app_config.gps_mode
    checks = run_preflight(
        chart_dir=app_config.chart_output,
        chart_package=app_config.chart_package,
        chart_value=app_config.chart_value,
        gpsd=gps_mode == "gpsd" and gps_sample is None,
        gpsd_host=app_config.gpsd_host,
        gpsd_port=app_config.gpsd_port,
        gps_device=app_config.gps_device if gps_sample is None else None,
        gps_baud=app_config.gps_baud,
        gps_sample=gps_sample,
        gps_seconds=gps_seconds,
        max_chart_age_days=app_config.max_chart_age_days,
        min_free_gb=app_config.min_free_gb,
        keep_zip=app_config.keep_zip,
        track_output=app_config.track_output,
    )
    check_rows = [asdict(check) for check in checks]
    services = _service_summary()
    system_services = _system_service_summary()
    unit_files = _user_unit_file_summary()
    launcher_settings = _launcher_settings_summary()
    opencpn_config = _opencpn_config_summary()
    desktop = _desktop_summary()
    track_log = _track_log_summary(
        app_config.track_output,
        wait_seconds=min(max(float(gps_seconds), 10.0), 60.0),
    )
    service_checks = _service_readiness_checks(
        services,
        system_services,
        unit_files=unit_files,
        launcher_settings=launcher_settings,
        desktop=desktop,
        gps_mode=gps_mode,
    )
    service_checks.append(_track_log_readiness_check(track_log))
    return {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "ok": all(check.ok for check in checks) and all(check.ok for check in service_checks),
        "host": {
            "name": socket.gethostname(),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": sys.version.split()[0],
            "boot_id": _boot_id(),
        },
        "app": _app_summary(),
        "config_path": str(Path(config_path).expanduser()),
        "config": _config_summary(app_config),
        "manifest": _manifest_summary(app_config.chart_output),
        "services": services,
        "system_services": system_services,
        "unit_files": unit_files,
        "launcher_settings": launcher_settings,
        "opencpn_config": opencpn_config,
        "desktop": desktop,
        "track_log": track_log,
        "service_checks": [asdict(check) for check in service_checks],
        "checks": check_rows,
    }


def write_status_report(report: dict[str, object], output: Path) -> Path:
    target = Path(output).expanduser()
    _prepare_private_status_parent(target.parent)
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
            os.chmod(tmp_path, 0o600)
            handle.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
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
    return target


def _prepare_private_status_parent(path: Path) -> None:
    path = Path(path).expanduser()
    if path.is_symlink():
        raise RuntimeError(f"status report directory {path} is a symlink")
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    stat_result = path.stat()
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"status report directory {path} is owned by uid {stat_result.st_uid}, "
            f"expected {os.getuid()}"
        )
    os.chmod(path, 0o700)
    _fsync_directory(path)
    _fsync_directory(path.parent)


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


def format_status_text(report: dict[str, object]) -> str:
    lines = [
        f"Generated: {report.get('generated_at', '')}",
        f"Host: {report.get('host', {}).get('name', '')}",
        f"Boot ID: {report.get('host', {}).get('boot_id', '')}",
        f"App: {report.get('app', {}).get('version', '')} revision {report.get('app', {}).get('source_revision', '')}",
        f"Config: {report.get('config_path', '')}",
        f"Ready: {'yes' if report.get('ok') else 'no'}",
        "",
        "Checks:",
    ]
    for check in report.get("checks", []):
        if not isinstance(check, dict):
            continue
        mark = "OK" if check.get("ok") else "FAIL"
        lines.append(f"{mark:4} {check.get('name', ''):10} {check.get('detail', '')}")
    service_checks = report.get("service_checks", [])
    if isinstance(service_checks, list) and service_checks:
        lines.extend(["", "Service Checks:"])
        for check in service_checks:
            if not isinstance(check, dict):
                continue
            mark = "OK" if check.get("ok") else "FAIL"
            lines.append(f"{mark:4} {check.get('name', ''):18} {check.get('detail', '')}")
    manifest = report.get("manifest", {})
    if isinstance(manifest, dict) and manifest:
        lines.extend(["", "Manifest:"])
        for key in (
            "created_at",
            "created_at_source",
            "package",
            "package_filename",
            "url",
            "download_path",
            "download_url",
            "download_skipped",
            "download_bytes",
            "sha256",
            "extract_path",
            "enc_cell_count",
        ):
            if key in manifest:
                lines.append(f"{key}: {manifest[key]}")
    services = report.get("services", {})
    if isinstance(services, dict) and services:
        lines.extend(["", "Services:"])
        for name, state in services.items():
            if isinstance(state, dict):
                lines.append(f"{name}: enabled={state.get('enabled', '')} active={state.get('active', '')}")
    system_services = report.get("system_services", {})
    if isinstance(system_services, dict) and system_services:
        lines.extend(["", "System Services:"])
        for name, state in system_services.items():
            if isinstance(state, dict):
                lines.append(f"{name}: enabled={state.get('enabled', '')} active={state.get('active', '')}")
    unit_files = report.get("unit_files", {})
    if isinstance(unit_files, dict) and unit_files:
        lines.extend(["", "User Unit Files:"])
        for name, state in unit_files.items():
            if isinstance(state, dict):
                wanted_by = state.get("wanted_by", [])
                if isinstance(wanted_by, list):
                    wanted_by_text = ",".join(str(value) for value in wanted_by)
                else:
                    wanted_by_text = str(wanted_by)
                lines.append(f"{name}: exists={state.get('exists', '')} wanted_by={wanted_by_text}")
    launcher_settings = report.get("launcher_settings", {})
    if isinstance(launcher_settings, dict) and launcher_settings:
        lines.extend(["", "Launcher Settings:"])
        values = launcher_settings.get("values", {})
        if isinstance(values, dict):
            value_text = " ".join(f"{key}={value}" for key, value in sorted(values.items()))
        else:
            value_text = ""
        lines.append(
            f"path={launcher_settings.get('path', '')} exists={launcher_settings.get('exists', '')} {value_text}".rstrip()
        )
    opencpn_config = report.get("opencpn_config", {})
    if isinstance(opencpn_config, dict) and opencpn_config:
        lines.extend(["", "OpenCPN Config:"])
        chart_dirs = opencpn_config.get("chart_directories", [])
        if isinstance(chart_dirs, list):
            chart_dir_text = ",".join(str(value) for value in chart_dirs)
        else:
            chart_dir_text = ""
        data_connections = opencpn_config.get("data_connections", [])
        if isinstance(data_connections, list):
            connection_count = len(data_connections)
        else:
            connection_count = 0
        lines.append(
            f"path={opencpn_config.get('path', '')} exists={opencpn_config.get('exists', '')} "
            f"chart_directories={chart_dir_text} data_connections={connection_count}".rstrip()
        )
    desktop = report.get("desktop", {})
    if isinstance(desktop, dict) and desktop:
        lines.extend(["", "Desktop Startup:"])
        autostart = desktop.get("autostart", {})
        lightdm = desktop.get("lightdm_autologin", {})
        if isinstance(autostart, dict):
            lines.append(
                f"autostart={autostart.get('path', '')} exists={autostart.get('exists', '')}"
            )
        if isinstance(lightdm, dict):
            lines.append(
                f"lightdm_autologin={lightdm.get('path', '')} exists={lightdm.get('exists', '')}"
            )
        lines.append(
            f"graphical_target={desktop.get('graphical_target', '')} "
            f"lightdm_enabled={desktop.get('lightdm_enabled', '')}"
        )
    track_log = report.get("track_log", {})
    if isinstance(track_log, dict) and track_log:
        lines.extend(["", "Track Log:"])
        latest = track_log.get("latest_path", "")
        coordinates = ""
        if "latest_latitude" in track_log and "latest_longitude" in track_log:
            coordinates = f" {track_log.get('latest_latitude')},{track_log.get('latest_longitude')}"
        lines.append(
            f"tracks_dir={track_log.get('tracks_dir', '')} ok={track_log.get('ok', '')} "
            f"dir_mode={track_log.get('tracks_mode', '')} latest={latest}{coordinates} "
            f"mode={track_log.get('latest_mode', '')} "
            f"detail={track_log.get('detail', '')}".rstrip()
        )
    return "\n".join(lines)


def _config_summary(app_config: AppConfig) -> dict[str, object]:
    return {
        "chart_package": app_config.chart_package,
        "chart_value": app_config.chart_value,
        "chart_output": str(app_config.chart_output),
        "extract": app_config.extract,
        "keep_zip": app_config.keep_zip,
        "force": app_config.force,
        "max_chart_age_days": app_config.max_chart_age_days,
        "min_free_gb": app_config.min_free_gb,
        "gps_mode": app_config.gps_mode,
        "gps_device": app_config.gps_device,
        "gps_baud": app_config.gps_baud,
        "gpsd_host": app_config.gpsd_host,
        "gpsd_port": app_config.gpsd_port,
        "track_output": str(app_config.track_output),
        "track_retention_days": app_config.track_retention_days,
    }


def _app_summary() -> dict[str, object]:
    return {
        "version": __version__,
        "source_revision": _source_revision(),
        "source_revision_path": str(_source_revision_path()),
    }


def _source_revision() -> str:
    path = _source_revision_path()
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError:
        return "unknown"
    return value or "unknown"


def _source_revision_path() -> Path:
    override = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
    return Path(override).expanduser() if override else DEFAULT_SOURCE_REVISION_PATH.expanduser()


def _boot_id() -> str:
    try:
        value = BOOT_ID_PATH.read_text(encoding="ascii").strip()
    except OSError:
        return "unknown"
    return value or "unknown"


def _current_boot_epoch() -> Optional[float]:
    try:
        uptime_seconds = float(Path("/proc/uptime").read_text(encoding="ascii").split()[0])
    except (OSError, ValueError, IndexError):
        return None
    return time.time() - uptime_seconds


def _track_log_summary(
    track_output: Path,
    *,
    max_age_seconds: float = 600.0,
    now: Optional[datetime] = None,
    boot_epoch: Optional[float] = None,
    expected_uid: Optional[int] = None,
    wait_seconds: float = 0.0,
    poll_seconds: float = 1.0,
) -> dict[str, object]:
    deadline = time.monotonic() + max(0.0, wait_seconds)
    poll_interval = max(0.1, poll_seconds)
    while True:
        summary = _track_log_summary_once(
            track_output,
            max_age_seconds=max_age_seconds,
            now=now,
            boot_epoch=boot_epoch,
            expected_uid=expected_uid,
        )
        if summary.get("ok") is True or time.monotonic() >= deadline:
            return summary
        time.sleep(min(poll_interval, max(0.0, deadline - time.monotonic())))


def _track_log_summary_once(
    track_output: Path,
    *,
    max_age_seconds: float = 600.0,
    now: Optional[datetime] = None,
    boot_epoch: Optional[float] = None,
    expected_uid: Optional[int] = None,
) -> dict[str, object]:
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    current = current.astimezone(timezone.utc)
    expected_owner = os.getuid() if expected_uid is None else expected_uid
    boot_time = _current_boot_epoch() if boot_epoch is None else boot_epoch
    tracks_dir = Path(track_output).expanduser() / "tracks"
    summary: dict[str, object] = {
        "tracks_dir": str(tracks_dir),
        "exists": tracks_dir.exists(),
        "ok": False,
        "max_age_seconds": max_age_seconds,
    }
    if not tracks_dir.exists():
        summary["detail"] = f"{tracks_dir} does not exist"
        return summary
    if tracks_dir.is_symlink():
        summary["detail"] = f"{tracks_dir} is a symlink, expected a private GPX tracks directory"
        return summary
    try:
        tracks_stat = tracks_dir.stat()
    except OSError as exc:
        summary["detail"] = f"could not inspect GPX tracks directory {tracks_dir}: {exc}"
        return summary
    if not tracks_dir.is_dir():
        summary["detail"] = f"{tracks_dir} is not a directory"
        return summary
    if tracks_stat.st_uid != expected_owner:
        summary["detail"] = f"{tracks_dir} is owned by uid {tracks_stat.st_uid}, expected {expected_owner}"
        return summary
    tracks_mode = tracks_stat.st_mode & 0o777
    summary["tracks_mode"] = f"{tracks_mode:04o}"
    if tracks_mode & 0o077:
        summary["detail"] = f"{tracks_dir} permissions are {tracks_mode:04o}, expected private 0700"
        return summary
    try:
        resolved_tracks_dir = tracks_dir.resolve(strict=True)
    except OSError as exc:
        summary["detail"] = f"could not resolve GPX tracks directory {tracks_dir}: {exc}"
        return summary
    candidates = []
    last_detail = ""
    for path in tracks_dir.glob("track-*.gpx"):
        if path.is_symlink():
            last_detail = f"{path} is a symlink, expected a regular GPX track file"
            continue
        if not path.is_file():
            last_detail = f"{path} is not a regular GPX track file"
            continue
        try:
            stat = path.stat()
            path.resolve(strict=True).relative_to(resolved_tracks_dir)
        except OSError as exc:
            last_detail = f"could not inspect {path}: {exc}"
            continue
        except ValueError:
            last_detail = f"{path} resolves outside GPX tracks directory"
            continue
        if stat.st_uid != expected_owner:
            last_detail = f"{path} is owned by uid {stat.st_uid}, expected {expected_owner}"
            continue
        mode = stat.st_mode & 0o777
        if mode & 0o077:
            last_detail = f"{path} permissions are {mode:04o}, expected private 0600"
            continue
        candidates.append((stat.st_mtime, path, stat))
    candidates.sort(reverse=True)
    for _mtime, path, stat in candidates:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            last_detail = f"could not read {path}: {exc}"
            continue
        if boot_time is not None and stat.st_mtime + 5 < boot_time:
            last_detail = f"{path} is older than current boot"
            continue
        trackpoints = re.findall(r"<trkpt\b.*?</trkpt>", text, flags=re.DOTALL)
        if not trackpoints:
            last_detail = f"{path} is current-boot but has no GPX trackpoint yet"
            continue
        newest_time = None
        newest_position = None
        for trackpoint in trackpoints:
            position, position_error = _gpx_trackpoint_position(trackpoint)
            if position is None:
                last_detail = f"{path} {position_error}"
                continue
            match = re.search(r"<time>([^<]+)</time>", trackpoint)
            if not match:
                last_detail = f"{path} has GPX trackpoints but no timestamped trackpoint yet"
                continue
            timestamp_text = match.group(1).strip()
            try:
                track_time = datetime.fromisoformat(timestamp_text.replace("Z", "+00:00")).astimezone(timezone.utc)
            except ValueError:
                last_detail = f"{path} has an invalid GPX trackpoint timestamp: {timestamp_text}"
                continue
            if newest_time is None or track_time > newest_time:
                newest_time = track_time
                newest_position = position
        if newest_time is None or newest_position is None:
            last_detail = last_detail or f"{path} has GPX trackpoints but no valid timestamped position yet"
            continue
        track_epoch = newest_time.timestamp()
        if boot_time is not None and track_epoch + 5 < boot_time:
            last_detail = f"{path} newest GPX trackpoint is older than current boot"
            continue
        age = current.timestamp() - track_epoch
        if age < -30:
            last_detail = f"{path} newest GPX trackpoint timestamp is in the future by {-age:.0f}s"
            continue
        if age > max_age_seconds:
            last_detail = f"{path} newest GPX trackpoint is stale: {age:.0f}s old"
            continue
        latitude, longitude = newest_position
        summary.update(
            {
                "ok": True,
                "latest_path": str(path),
                "latest_time": newest_time.isoformat().replace("+00:00", "Z"),
                "latest_latitude": latitude,
                "latest_longitude": longitude,
                "age_seconds": age,
                "latest_mode": f"{stat.st_mode & 0o777:04o}",
                "detail": f"{path} {latitude:.6f},{longitude:.6f}",
            }
        )
        return summary
    summary["detail"] = last_detail or f"no current-boot GPX trackpoint found under {tracks_dir}"
    return summary


def _gpx_trackpoint_position(trackpoint: str) -> tuple[Optional[tuple[float, float]], str]:
    tag_match = re.search(r"<trkpt\b([^>]*)>", trackpoint)
    if not tag_match:
        return None, "GPX trackpoint has no opening trkpt tag"
    attrs = tag_match.group(1)
    lat_match = re.search(r'\blat="([^"]+)"', attrs)
    lon_match = re.search(r'\blon="([^"]+)"', attrs)
    if not lat_match or not lon_match:
        return None, "GPX trackpoint is missing latitude or longitude"
    try:
        latitude = float(lat_match.group(1))
        longitude = float(lon_match.group(1))
    except ValueError:
        return None, f"GPX trackpoint has non-numeric coordinates: {lat_match.group(1)}, {lon_match.group(1)}"
    if not (-90.0 <= latitude <= 90.0):
        return None, f"GPX trackpoint latitude is outside -90..90: {latitude}"
    if not (-180.0 <= longitude <= 180.0):
        return None, f"GPX trackpoint longitude is outside -180..180: {longitude}"
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        return None, "GPX trackpoint has invalid 0,0 coordinates"
    return (latitude, longitude), ""


def _track_log_readiness_check(track_log: dict[str, object]) -> CheckResult:
    if track_log.get("ok") is True:
        return CheckResult("Track Log", True, str(track_log.get("detail", "recent GPX trackpoint found")))
    return CheckResult("Track Log", False, str(track_log.get("detail", "no recent GPX trackpoint found")))


def _manifest_summary(chart_output: Path) -> dict[str, object]:
    manifest_path = Path(chart_output).expanduser() / MANIFEST_NAME
    if not manifest_path.exists():
        return {"path": str(manifest_path), "exists": False}
    try:
        manifest = read_manifest(chart_output)
    except Exception as exc:
        return {"path": str(manifest_path), "exists": True, "error": str(exc)}
    package = manifest.get("package", {})
    download = manifest.get("download", {})
    extract = manifest.get("extract", {})
    return {
        "path": str(manifest_path),
        "exists": True,
        "created_at": manifest.get("created_at", ""),
        "created_at_source": manifest.get("created_at_source", ""),
        "package": package.get("label", "") if isinstance(package, dict) else "",
        "package_filename": package.get("filename", "") if isinstance(package, dict) else "",
        "url": package.get("url", "") if isinstance(package, dict) else "",
        "download_path": download.get("path", "") if isinstance(download, dict) else "",
        "download_url": download.get("url", "") if isinstance(download, dict) else "",
        "download_skipped": download.get("skipped", False) if isinstance(download, dict) else False,
        "download_bytes": download.get("bytes", 0) if isinstance(download, dict) else 0,
        "sha256": download.get("sha256", "") if isinstance(download, dict) else "",
        "extract_path": extract.get("path", "") if isinstance(extract, dict) else "",
        "enc_cell_count": extract.get("enc_cell_count", 0) if isinstance(extract, dict) else 0,
    }


def _service_summary() -> dict[str, object]:
    if shutil.which("systemctl") is None:
        return {"available": False, "detail": "systemctl not found"}
    units = [
        "noaa-navionics.service",
        "noaa-navionics.timer",
        "noaa-navionics-track.service",
        "noaa-navionics-preflight.service",
    ]
    summary: dict[str, object] = {"available": True}
    for unit in units:
        summary[unit] = {
            "enabled": _systemctl_user(["is-enabled", unit]),
            "active": _systemctl_user(["is-active", unit]),
            "properties": _systemctl_user_show(unit, USER_UNIT_PROPERTIES.get(unit, [])),
        }
    return summary


def _system_service_summary() -> dict[str, object]:
    if shutil.which("systemctl") is None:
        return {"available": False, "detail": "systemctl not found"}
    units = ["gpsd.socket", "gpsd.service", "chrony.service"]
    summary: dict[str, object] = {"available": True}
    for unit in units:
        summary[unit] = {
            "enabled": _systemctl_system(["is-enabled", unit]),
            "active": _systemctl_system(["is-active", unit]),
        }
    return summary


def _user_unit_file_summary() -> dict[str, object]:
    unit_dir = Path.home() / ".config/systemd/user"
    summary: dict[str, object] = {"directory": str(unit_dir)}
    for unit in USER_UNIT_PROPERTIES:
        path = unit_dir / unit
        state: dict[str, object] = {"path": str(path), "exists": path.is_file()}
        if path.is_file():
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except OSError as exc:
                state["error"] = str(exc)
            else:
                state["wanted_by"] = _install_wanted_by_targets(lines)
        summary[unit] = state
    return summary


def _launcher_settings_summary(path: Optional[Path] = None) -> dict[str, object]:
    launcher_env = Path(path or DEFAULT_LAUNCHER_ENV_PATH).expanduser()
    summary: dict[str, object] = {"path": str(launcher_env), "exists": launcher_env.is_file()}
    if not launcher_env.exists():
        return summary
    try:
        lines = launcher_env.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        summary["error"] = str(exc)
        return summary
    values: dict[str, str] = {}
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    summary["values"] = values
    return summary


def _opencpn_config_summary(path: Optional[Path] = None) -> dict[str, object]:
    config_path = opencpn_config_path(path)
    summary: dict[str, object] = {"path": str(config_path), "exists": config_path.is_file()}
    if not config_path.exists():
        return summary
    try:
        summary["chart_directories"] = [str(chart_dir) for chart_dir in read_chart_directories(config_path)]
        summary["data_connections"] = read_data_connections(config_path)
    except OSError as exc:
        summary["error"] = str(exc)
    return summary


def _desktop_summary(
    *,
    autostart_path: Optional[Path] = None,
    lightdm_autologin_path: Optional[Path] = None,
) -> dict[str, object]:
    autostart = _key_value_file_summary(
        Path(autostart_path or DEFAULT_AUTOSTART_PATH).expanduser(),
        comment_prefixes=("#",),
    )
    lightdm_autologin = _key_value_file_summary(
        Path(lightdm_autologin_path or DEFAULT_LIGHTDM_AUTOLOGIN_PATH),
        comment_prefixes=("#", ";"),
    )
    return {
        "autostart": autostart,
        "lightdm_autologin": lightdm_autologin,
        "graphical_target": _systemctl_system(["get-default"]),
        "lightdm_enabled": _systemctl_system(["is-enabled", "lightdm.service"]),
        "lightdm_active": _systemctl_system(["is-active", "lightdm.service"]),
    }


def _key_value_file_summary(path: Path, *, comment_prefixes: tuple[str, ...]) -> dict[str, object]:
    summary: dict[str, object] = {"path": str(path), "exists": path.is_file()}
    if not path.exists():
        return summary
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        summary["error"] = str(exc)
        return summary
    values: dict[str, str] = {}
    sections: list[str] = []
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith(comment_prefixes):
            continue
        if line.startswith("[") and line.endswith("]"):
            sections.append(line[1:-1].strip())
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    summary["sections"] = sections
    summary["values"] = values
    return summary


def _install_wanted_by_targets(lines: list[str]) -> list[str]:
    targets: list[str] = []
    section = ""
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if section != "Install" or not line.startswith("WantedBy="):
            continue
        targets.extend(target for target in line.split("=", 1)[1].split() if target)
    return targets


def _service_readiness_checks(
    services: dict[str, object],
    system_services: dict[str, object],
    *,
    unit_files: Optional[dict[str, object]] = None,
    launcher_settings: Optional[dict[str, object]] = None,
    desktop: Optional[dict[str, object]] = None,
    gps_mode: str,
) -> list[CheckResult]:
    checks = [
        _chart_sync_check(
            services,
            "noaa-navionics.service",
            "Chart Sync",
        ),
        _unit_check(
            services,
            "noaa-navionics.timer",
            "Chart Timer",
            require_enabled=True,
            require_active=True,
        ),
        _unit_check(
            services,
            "noaa-navionics-track.service",
            "Track Logger",
            require_enabled=True,
            require_active=True,
        ),
        _unit_check(
            services,
            "noaa-navionics-preflight.service",
            "Boot Readiness",
            require_enabled=True,
            require_active=False,
        ),
    ]
    if _summary_has_loaded_properties(services):
        checks.extend(
            [
                _unit_properties_check(
                    services,
                    "noaa-navionics.service",
                    "Chart Sync Settings",
                    exact=_with_loaded_fragment_path(
                        {
                            "Type": "oneshot",
                            "TimeoutStartUSec": "2h",
                            "Restart": "on-failure",
                            "RestartUSec": "30min",
                            "StartLimitIntervalUSec": "6h",
                            "StartLimitBurst": "3",
                            "NoNewPrivileges": "yes",
                            "PrivateTmp": "yes",
                        },
                        unit_files,
                        "noaa-navionics.service",
                    ),
                    contains={
                        "ExecStartPre": [
                            "noaa-navionics wait-network",
                            "--host",
                            "www.charts.noaa.gov",
                            "--port 443",
                            "--seconds 300",
                        ],
                        "ExecStart": [
                            "noaa-navionics sync-charts",
                            "--config",
                            "noaa-navionics/config.ini",
                            "--retries 5",
                            "--retry-delay 30",
                        ],
                    },
                ),
                _unit_properties_check(
                    services,
                    "noaa-navionics.timer",
                    "Chart Timer Settings",
                    exact=_with_loaded_fragment_path(
                        {"Persistent": "yes", "RandomizedDelayUSec": "30min"},
                        unit_files,
                        "noaa-navionics.timer",
                    ),
                    contains={"TimersCalendar": "OnCalendar=weekly"},
                ),
                _unit_properties_check(
                    services,
                    "noaa-navionics-track.service",
                    "Track Logger Settings",
                    exact=_with_loaded_fragment_path(
                        {
                            "Type": "simple",
                            "StandardOutput": "null",
                            "Restart": "on-failure",
                            "RestartUSec": "10s",
                            "StartLimitIntervalUSec": "10min",
                            "StartLimitBurst": "60",
                            "NoNewPrivileges": "yes",
                            "PrivateTmp": "yes",
                            "UMask": "0077",
                        },
                        unit_files,
                        "noaa-navionics-track.service",
                    ),
                    contains={
                        "ExecStart": [
                            "noaa-navionics log-track",
                            "--config",
                            "noaa-navionics/config.ini",
                            "--rotate-daily",
                        ],
                    },
                ),
                _unit_properties_check(
                    services,
                    "noaa-navionics-preflight.service",
                    "Boot Readiness Settings",
                    exact=_with_loaded_fragment_path(
                        {
                            "Type": "oneshot",
                            "TimeoutStartUSec": "infinity",
                            "Restart": "on-failure",
                            "RestartUSec": "30s",
                            "StartLimitIntervalUSec": "30min",
                            "StartLimitBurst": "60",
                            "NoNewPrivileges": "yes",
                            "PrivateTmp": "yes",
                        },
                        unit_files,
                        "noaa-navionics-preflight.service",
                    ),
                    contains={
                        "Wants": "noaa-navionics-track.service",
                        "After": "noaa-navionics-track.service",
                        "ExecStart": [
                            "noaa-navionics status-report",
                            "--config",
                            "noaa-navionics/config.ini",
                            "--gps-seconds",
                            "--output",
                            "noaa-navionics/status.json",
                        ],
                        "Environment": "NOAA_NAVIONICS_GPS_SECONDS=60",
                        "EnvironmentFiles": "noaa-navionics/launcher.env",
                    },
                ),
                _preflight_execution_check(
                    services,
                    "noaa-navionics-preflight.service",
                    "Boot Readiness Run",
                ),
            ]
        )
    if unit_files is not None:
        checks.extend(
            [
                _unit_file_install_target_check(
                    unit_files,
                    "noaa-navionics.timer",
                    "Chart Timer Install",
                    "timers.target",
                ),
                _unit_file_install_target_check(
                    unit_files,
                    "noaa-navionics-track.service",
                    "Track Logger Install",
                    "default.target",
                ),
                _unit_file_install_target_check(
                    unit_files,
                    "noaa-navionics-preflight.service",
                    "Boot Readiness Install",
                    "default.target",
                ),
            ]
        )
    if launcher_settings is not None:
        checks.append(_launcher_settings_check(launcher_settings))
    if desktop is not None:
        checks.append(_desktop_startup_check(desktop))
    if gps_mode == "gpsd":
        checks.append(
            _unit_check(
                system_services,
                "gpsd.socket",
                "GPSD Socket",
                require_enabled=True,
                require_active=True,
            )
        )
        checks.append(
            _unit_check(
                system_services,
                "gpsd.service",
                "GPSD Service",
                require_enabled=True,
                require_active=True,
            )
        )
        checks.append(
            _unit_check(
                system_services,
                "chrony.service",
                "Chrony Service",
                require_enabled=True,
                require_active=True,
            )
        )
    return checks


def _launcher_settings_check(summary: dict[str, object]) -> CheckResult:
    path = str(summary.get("path", DEFAULT_LAUNCHER_ENV_PATH.expanduser()))
    if summary.get("exists") is not True:
        return CheckResult("Launcher Settings", False, f"launcher environment is missing: {path}")
    error = str(summary.get("error", ""))
    if error:
        return CheckResult("Launcher Settings", False, f"launcher environment unreadable at {path}: {error}")
    values = summary.get("values", {})
    if not isinstance(values, dict):
        return CheckResult("Launcher Settings", False, f"launcher environment values were not parsed: {path}")

    failures = []
    gps_seconds = str(values.get("NOAA_NAVIONICS_GPS_SECONDS", "")).strip()
    if not gps_seconds.isdigit() or int(gps_seconds) <= 0:
        failures.append(f"NOAA_NAVIONICS_GPS_SECONDS={gps_seconds or '<missing>'} expected positive integer")
    attempts = str(values.get("NOAA_NAVIONICS_READINESS_ATTEMPTS", "")).strip()
    if attempts and (not attempts.isdigit() or int(attempts) <= 0):
        failures.append(f"NOAA_NAVIONICS_READINESS_ATTEMPTS={attempts} expected positive integer")
    retry_delay = str(values.get("NOAA_NAVIONICS_READINESS_RETRY_DELAY", "")).strip()
    if retry_delay and (not retry_delay.isdigit() or int(retry_delay) < 0):
        failures.append(f"NOAA_NAVIONICS_READINESS_RETRY_DELAY={retry_delay} expected non-negative integer")
    opencpn_restarts = str(values.get("NOAA_NAVIONICS_OPENCPN_RESTARTS", "")).strip()
    if opencpn_restarts and (not opencpn_restarts.isdigit() or int(opencpn_restarts) < 0):
        failures.append(f"NOAA_NAVIONICS_OPENCPN_RESTARTS={opencpn_restarts} expected non-negative integer")
    opencpn_restart_delay = str(values.get("NOAA_NAVIONICS_OPENCPN_RESTART_DELAY", "")).strip()
    if opencpn_restart_delay and (not opencpn_restart_delay.isdigit() or int(opencpn_restart_delay) < 0):
        failures.append(
            f"NOAA_NAVIONICS_OPENCPN_RESTART_DELAY={opencpn_restart_delay} expected non-negative integer"
        )
    fail_open = str(values.get("NOAA_NAVIONICS_START_ON_FAILED_READINESS", "")).strip().lower()
    if fail_open in {"1", "yes", "true", "on"}:
        failures.append("NOAA_NAVIONICS_START_ON_FAILED_READINESS is enabled")
    elif fail_open and fail_open not in {"0", "no", "false", "off"}:
        failures.append(f"NOAA_NAVIONICS_START_ON_FAILED_READINESS={fail_open} expected yes/no")
    if failures:
        return CheckResult("Launcher Settings", False, f"{path}: " + "; ".join(failures))
    return CheckResult("Launcher Settings", True, f"{path} keeps chartplotter startup fail-closed")


def _desktop_startup_check(summary: dict[str, object]) -> CheckResult:
    failures = []
    autostart = summary.get("autostart")
    if not isinstance(autostart, dict):
        failures.append("desktop autostart summary missing")
    else:
        path = str(autostart.get("path", DEFAULT_AUTOSTART_PATH.expanduser()))
        if autostart.get("exists") is not True:
            failures.append(f"desktop autostart missing at {path}")
        if str(autostart.get("error", "")):
            failures.append(f"desktop autostart unreadable at {path}: {autostart.get('error')}")
        values = autostart.get("values")
        if not isinstance(values, dict):
            failures.append(f"desktop autostart values were not parsed at {path}")
        else:
            expected_values = {
                "Type": "Application",
                "Name": "NOAA Navionics Chartplotter",
                "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
                "Terminal": "false",
                "X-GNOME-Autostart-enabled": "true",
            }
            for key, expected in expected_values.items():
                actual = str(values.get(key, "")).strip()
                if actual != expected:
                    failures.append(f"desktop autostart {key}={actual or '<missing>'} expected {expected}")
            hidden = str(values.get("Hidden", "")).strip().lower()
            if hidden == "true":
                failures.append("desktop autostart Hidden=true disables chartplotter startup")

    graphical_target = str(summary.get("graphical_target", "")).strip()
    if graphical_target != "graphical.target":
        failures.append(f"systemd default target is {graphical_target or '<missing>'}, expected graphical.target")
    lightdm_enabled = str(summary.get("lightdm_enabled", "")).strip()
    if lightdm_enabled != "enabled":
        failures.append(f"lightdm.service is {lightdm_enabled or '<missing>'}, expected enabled")

    lightdm = summary.get("lightdm_autologin")
    if not isinstance(lightdm, dict):
        failures.append("LightDM autologin summary missing")
    else:
        path = str(lightdm.get("path", DEFAULT_LIGHTDM_AUTOLOGIN_PATH))
        if lightdm.get("exists") is not True:
            failures.append(f"LightDM autologin config missing at {path}")
        if str(lightdm.get("error", "")):
            failures.append(f"LightDM autologin config unreadable at {path}: {lightdm.get('error')}")
        sections = {str(section) for section in lightdm.get("sections", [])} if isinstance(lightdm.get("sections"), list) else set()
        if "Seat:*" not in sections:
            failures.append("LightDM autologin config missing [Seat:*] section")
        values = lightdm.get("values")
        if not isinstance(values, dict):
            failures.append(f"LightDM autologin values were not parsed at {path}")
        else:
            expected_user = os.environ.get("USER", "")
            actual_user = str(values.get("autologin-user", "")).strip()
            if expected_user and actual_user != expected_user:
                failures.append(f"LightDM autologin-user={actual_user or '<missing>'} expected {expected_user}")
            timeout = str(values.get("autologin-user-timeout", "")).strip()
            if timeout != "0":
                failures.append(f"LightDM autologin-user-timeout={timeout or '<missing>'} expected 0")
            session = str(values.get("autologin-session", "")).strip()
            if not session:
                failures.append("LightDM autologin-session is missing")
            elif not _safe_xsession_name(session):
                failures.append(f"LightDM autologin-session is unsafe: {session}")
            elif not (Path("/usr/share/xsessions") / f"{session}.desktop").is_file():
                failures.append(f"LightDM autologin-session is not installed: {session}")

    if failures:
        return CheckResult("Desktop Startup", False, "; ".join(failures))
    active = str(summary.get("lightdm_active", "")).strip() or "<unknown>"
    return CheckResult("Desktop Startup", True, f"desktop autostart and LightDM autologin are configured; lightdm active={active}")


def _safe_xsession_name(value: str) -> bool:
    return bool(value) and all(char.isalnum() or char in "._+-" for char in value)


def _unit_file_install_target_check(
    summary: dict[str, object],
    unit: str,
    name: str,
    expected_target: str,
) -> CheckResult:
    state = summary.get(unit)
    if not isinstance(state, dict):
        return CheckResult(name, False, f"{unit} missing from unit file summary")
    path = str(state.get("path", unit))
    if state.get("exists") is not True:
        return CheckResult(name, False, f"{unit} unit file is missing at {path}")
    error = str(state.get("error", ""))
    if error:
        return CheckResult(name, False, f"{unit} unit file unreadable at {path}: {error}")
    wanted_by = state.get("wanted_by")
    if not isinstance(wanted_by, list):
        return CheckResult(name, False, f"{unit} has no parsed WantedBy target at {path}")
    if expected_target not in {str(value) for value in wanted_by}:
        return CheckResult(
            name,
            False,
            f"{unit} WantedBy={','.join(str(value) for value in wanted_by) or '<missing>'} expected {expected_target}",
        )
    return CheckResult(name, True, f"{unit} installs into {expected_target}")


def _summary_has_loaded_properties(summary: dict[str, object]) -> bool:
    return any(
        isinstance(state, dict) and isinstance(state.get("properties"), dict)
        for state in summary.values()
    )


def _with_loaded_fragment_path(
    exact: dict[str, str],
    unit_files: Optional[dict[str, object]],
    unit: str,
) -> dict[str, str]:
    expected = dict(exact)
    if unit_files is None:
        return expected
    state = unit_files.get(unit)
    if not isinstance(state, dict):
        return expected
    path = str(state.get("path", "")).strip()
    if path:
        expected["FragmentPath"] = path
    return expected


def _unit_properties_check(
    summary: dict[str, object],
    unit: str,
    name: str,
    *,
    exact: Optional[dict[str, str]] = None,
    contains: Optional[dict[str, str | list[str]]] = None,
) -> CheckResult:
    if summary.get("available") is False:
        return CheckResult(name, False, str(summary.get("detail", "systemctl not available")))
    state = summary.get(unit)
    if not isinstance(state, dict):
        return CheckResult(name, False, f"{unit} missing from status report")
    properties = state.get("properties")
    if not isinstance(properties, dict):
        return CheckResult(name, False, f"{unit} loaded properties missing from status report")
    error = properties.get("error")
    if error:
        return CheckResult(name, False, f"{unit} loaded properties unavailable: {error}")

    failures = []
    for key, expected in (exact or {}).items():
        actual = str(properties.get(key, ""))
        if actual != expected:
            failures.append(f"{key}={actual or '<missing>'} expected {expected}")
    for key, expected_value in (contains or {}).items():
        actual = str(properties.get(key, ""))
        expected_values = [expected_value] if isinstance(expected_value, str) else expected_value
        for expected in expected_values:
            if expected not in actual:
                failures.append(f"{key}={actual or '<missing>'} missing {expected}")
    if failures:
        return CheckResult(name, False, f"{unit}: " + "; ".join(failures))
    return CheckResult(name, True, f"{unit} loaded settings match expected values")


def _preflight_execution_check(summary: dict[str, object], unit: str, name: str) -> CheckResult:
    if summary.get("available") is False:
        return CheckResult(name, False, str(summary.get("detail", "systemctl not available")))
    state = summary.get(unit)
    if not isinstance(state, dict):
        return CheckResult(name, False, f"{unit} missing from status report")
    properties = state.get("properties")
    if not isinstance(properties, dict):
        return CheckResult(name, False, f"{unit} loaded properties missing from status report")
    error = properties.get("error")
    if error:
        return CheckResult(name, False, f"{unit} loaded properties unavailable: {error}")
    active = str(state.get("active", "")).strip()
    result = str(properties.get("Result", "")).strip()
    status = str(properties.get("ExecMainStatus", "")).strip()
    started = str(properties.get("ExecMainStartTimestampMonotonic", "")).strip()
    detail = f"{unit} active={active or '<missing>'} Result={result or '<missing>'} ExecMainStatus={status or '<missing>'}"
    if active in {"active", "activating"} and started.isdigit() and int(started) > 0:
        return CheckResult(name, True, detail + f" ExecMainStartTimestampMonotonic={started}")
    if result != "success":
        return CheckResult(name, False, detail)
    if status != "0":
        return CheckResult(name, False, detail)
    if not started.isdigit() or int(started) <= 0:
        return CheckResult(name, False, detail + f" ExecMainStartTimestampMonotonic={started or '<missing>'}")
    return CheckResult(name, True, detail)


def _chart_sync_check(summary: dict[str, object], unit: str, name: str) -> CheckResult:
    if summary.get("available") is False:
        return CheckResult(name, False, str(summary.get("detail", "systemctl not available")))
    state = summary.get(unit)
    if not isinstance(state, dict):
        return CheckResult(name, False, f"{unit} missing from status report")
    enabled = str(state.get("enabled", ""))
    active = str(state.get("active", ""))
    detail = f"{unit} enabled={enabled} active={active}"
    active_text = active.strip().lower()
    enabled_text = enabled.strip().lower()
    if _unit_query_failed(enabled) or enabled_text not in {"static", "generated"}:
        return CheckResult(name, False, detail)
    if active_text != "failed" and _unit_query_failed(active):
        return CheckResult(name, False, detail)
    if active_text == "failed":
        detail += "; last chart refresh failed, but chart manifest freshness decides navigation readiness"
    return CheckResult(name, True, detail)


def _unit_not_failed_check(summary: dict[str, object], unit: str, name: str) -> CheckResult:
    if summary.get("available") is False:
        return CheckResult(name, False, str(summary.get("detail", "systemctl not available")))
    state = summary.get(unit)
    if not isinstance(state, dict):
        return CheckResult(name, False, f"{unit} missing from status report")
    enabled = str(state.get("enabled", ""))
    active = str(state.get("active", ""))
    detail = f"{unit} enabled={enabled} active={active}"
    ok = active != "failed" and not _unit_query_failed(enabled) and not _unit_query_failed(active)
    return CheckResult(name, ok, detail)


def _unit_check(
    summary: dict[str, object],
    unit: str,
    name: str,
    *,
    require_enabled: bool,
    require_active: bool,
) -> CheckResult:
    if summary.get("available") is False:
        return CheckResult(name, False, str(summary.get("detail", "systemctl not available")))
    state = summary.get(unit)
    if not isinstance(state, dict):
        return CheckResult(name, False, f"{unit} missing from status report")
    enabled = str(state.get("enabled", ""))
    active = str(state.get("active", ""))
    if _unit_query_failed(enabled) or _unit_query_failed(active):
        return CheckResult(name, False, f"{unit} enabled={enabled} active={active}")
    if active == "failed":
        return CheckResult(name, False, f"{unit} enabled={enabled} active={active}")
    enabled_ok = not require_enabled or enabled in {"enabled", "static", "generated"}
    active_ok = not require_active or active in {"active", "activating"}
    ok = enabled_ok and active_ok
    detail = f"{unit} enabled={enabled} active={active}"
    return CheckResult(name, ok, detail)


def _unit_query_failed(value: str) -> bool:
    text = value.strip().lower()
    if not text:
        return True
    return (
        text.startswith("error:")
        or text.startswith("failed")
        or text.startswith("exit ")
        or text in {"not-found", "unknown"}
    )


def _systemctl_user(args: list[str]) -> str:
    return _systemctl(["systemctl", "--user", *args])


def _systemctl_user_show(unit: str, properties: list[str]) -> dict[str, str]:
    if not properties:
        return {}
    property_args = []
    for prop in properties:
        property_args.extend(["-p", prop])
    try:
        completed = subprocess.run(
            ["systemctl", "--user", "show", unit, *property_args],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
    except Exception as exc:
        return {"error": str(exc)}
    output = completed.stdout.strip() or completed.stderr.strip()
    if completed.returncode != 0:
        return {"error": output or f"exit {completed.returncode}"}
    parsed: dict[str, str] = {}
    for line in completed.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            parsed[key.strip()] = value.strip()
    return parsed


def _systemctl_system(args: list[str]) -> str:
    return _systemctl(["systemctl", *args])


def _systemctl(command: list[str]) -> str:
    try:
        completed = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
    except Exception as exc:
        return f"error: {exc}"
    value = completed.stdout.strip() or completed.stderr.strip()
    return value or f"exit {completed.returncode}"
