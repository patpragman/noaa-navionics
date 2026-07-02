from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
import xml.etree.ElementTree as ET
import json
import math
import os
import platform
import re
import socket
import stat
import subprocess
import sys
import tempfile
import time

from .config import (
    AppConfig,
    CHART_PACKAGES,
    CHART_PACKAGES_REQUIRING_VALUE,
    GPSD_LOCAL_HOSTS,
    GPS_BAUD_RATES,
    read_config,
)
from .downloader import MANIFEST_NAME, read_manifest
from .health import (
    CheckResult,
    check_opencpn_gpsd_config,
    run_preflight,
    _expected_manifest_package,
    _trusted_enc_cell_tree_count,
    _trusted_system_command,
)
from .opencpn import (
    enabled_gpsd_connections_from_values,
    normalize_gpsd_host,
    opencpn_config_path,
    read_chart_directories,
    read_data_connections,
)
from ._safeio import cleanup_private_temp_file
from . import __version__


DEFAULT_SOURCE_REVISION_PATH = Path("~/.local/share/noaa-navionics/source-revision")
DEFAULT_LAUNCHER_ENV_PATH = Path("~/.config/noaa-navionics/launcher.env")
DEFAULT_AUTOSTART_PATH = Path("~/.config/autostart/noaa-navionics-chartplotter.desktop")
DEFAULT_STATUS_DESKTOP_PATH = Path("~/Desktop/noaa-navionics-status.desktop")
DEFAULT_MOB_DESKTOP_PATH = Path("~/Desktop/noaa-navionics-mob.desktop")
DEFAULT_LIGHTDM_AUTOLOGIN_PATH = Path("/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf")
BOOT_ID_PATH = Path("/proc/sys/kernel/random/boot_id")
PROC_UPTIME_PATH = Path("/proc/uptime")
BOOT_ID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
STATUS_REPORT_MAX_AGE_SECONDS = 600.0
STATUS_REPORT_FUTURE_TOLERANCE_SECONDS = 30.0
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
        "ProtectSystem",
        "CapabilityBoundingSet",
        "RestrictAddressFamilies",
        "LockPersonality",
        "RestrictSUIDSGID",
        "MemoryDenyWriteExecute",
        "RestrictRealtime",
        "SystemCallArchitectures",
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
        "TimeoutStopUSec",
        "StartLimitIntervalUSec",
        "StartLimitBurst",
        "NoNewPrivileges",
        "PrivateTmp",
        "ProtectSystem",
        "CapabilityBoundingSet",
        "RestrictAddressFamilies",
        "LockPersonality",
        "RestrictSUIDSGID",
        "MemoryDenyWriteExecute",
        "RestrictRealtime",
        "SystemCallArchitectures",
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
        "ProtectSystem",
        "CapabilityBoundingSet",
        "RestrictAddressFamilies",
        "LockPersonality",
        "RestrictSUIDSGID",
        "MemoryDenyWriteExecute",
        "RestrictRealtime",
        "SystemCallArchitectures",
        "UMask",
    ],
}
USER_UNIT_INSTALL_TARGETS = {
    "noaa-navionics.timer": "timers.target",
    "noaa-navionics-track.service": "default.target",
    "noaa-navionics-preflight.service": "default.target",
}
LAUNCHER_ENV_KEYS = {
    "NOAA_NAVIONICS_GPS_SECONDS",
    "NOAA_NAVIONICS_WARNING_SECONDS",
    "NOAA_NAVIONICS_READINESS_ATTEMPTS",
    "NOAA_NAVIONICS_READINESS_RETRY_DELAY",
    "NOAA_NAVIONICS_START_ON_FAILED_READINESS",
    "NOAA_NAVIONICS_OPENCPN_RESTARTS",
    "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY",
}
LAUNCHER_ENV_INTEGER_LIMITS = {
    "NOAA_NAVIONICS_GPS_SECONDS": 600,
    "NOAA_NAVIONICS_WARNING_SECONDS": 600,
    "NOAA_NAVIONICS_READINESS_ATTEMPTS": 20,
    "NOAA_NAVIONICS_READINESS_RETRY_DELAY": 3600,
    "NOAA_NAVIONICS_OPENCPN_RESTARTS": 20,
    "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY": 3600,
}
CORE_READINESS_CHECKS = frozenset(
    {
        "Python",
        "Source Revision",
        "Clock",
        "Time Sync",
        "Tkinter",
        "OpenCPN",
        "Display Power",
        "Chart Package",
        "Charts",
        "Chart Update Debris",
        "Manifest",
        "OpenCPN Charts",
        "Disk",
        "Pi Power",
        "Pi Thermal",
    }
)
GPSD_READINESS_CHECKS = frozenset(
    {
        "OpenCPN GPSD",
        "GPSD Config",
        "Chrony Config",
        "GPSD",
        "GPS Time Source",
    }
)
SERIAL_READINESS_CHECKS = frozenset({"GPS Device", "GPS"})
CORE_SERVICE_CHECKS = frozenset(
    {
        "Chart Sync",
        "Chart Sync Settings",
        "Chart Sync Unit File",
        "Chart Timer",
        "Chart Timer Install",
        "Chart Timer Settings",
        "Chart Timer Unit File",
        "Track Log",
        "Track Logger",
        "Track Logger Install",
        "Track Logger Settings",
        "Track Logger Unit File",
        "Boot Readiness",
        "Boot Readiness Install",
        "Boot Readiness Settings",
        "Boot Readiness Unit File",
        "Boot Readiness Run",
        "Desktop Startup",
        "Launcher Settings",
        "User Linger",
    }
)
GPSD_SERVICE_CHECKS = frozenset({"GPSD Socket", "GPSD Service", "Chrony Service"})


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
    if gps_mode == "gpsd" and gps_sample is not None:
        checks.append(check_opencpn_gpsd_config(host=app_config.gpsd_host, port=app_config.gpsd_port))
    check_rows = [_check_result_dict(check) for check in checks]
    services = _service_summary()
    system_services = _system_service_summary()
    unit_files = _user_unit_file_summary()
    user = _user_summary()
    launcher_settings = _launcher_settings_summary()
    opencpn_config = _opencpn_config_summary()
    desktop = _desktop_summary()
    track_log = _track_log_summary(
        app_config.track_output,
        wait_seconds=_status_track_wait_seconds(gps_seconds),
    )
    service_checks = _service_readiness_checks(
        services,
        system_services,
        unit_files=unit_files,
        user=user,
        launcher_settings=launcher_settings,
        desktop=desktop,
        gps_mode=gps_mode,
    )
    service_checks.append(_track_log_readiness_check(track_log))
    generated_at = datetime.now(timezone.utc)
    gps_fix = _gps_fix_summary(checks, now=generated_at)
    return {
        "generated_at": generated_at.isoformat().replace("+00:00", "Z"),
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
        "user": user,
        "services": services,
        "system_services": system_services,
        "unit_files": unit_files,
        "launcher_settings": launcher_settings,
        "opencpn_config": opencpn_config,
        "desktop": desktop,
        "track_log": track_log,
        "gps_fix": gps_fix,
        "service_checks": [_check_result_dict(check) for check in service_checks],
        "checks": check_rows,
    }


def _status_track_wait_seconds(gps_seconds: float) -> float:
    try:
        seconds = float(gps_seconds)
    except (TypeError, ValueError):
        return 10.0
    if not math.isfinite(seconds) or seconds <= 0:
        return 10.0
    return min(max(seconds, 10.0), 60.0)


def _check_result_dict(check: CheckResult) -> dict[str, object]:
    row: dict[str, object] = {
        "name": check.name,
        "ok": check.ok,
        "detail": check.detail,
    }
    if check.data is not None:
        row["data"] = check.data
    return row


def status_report_is_ready(report: dict[str, object], *, now: Optional[datetime] = None) -> bool:
    return (
        report.get("ok") is True
        and not status_report_validation_failures(report, now=now)
        and _report_check_sections_all_ok(report)
    )


def status_report_validation_failures(
    report: dict[str, object],
    *,
    now: Optional[datetime] = None,
) -> list[CheckResult]:
    failures = _generated_at_validation_failures(report.get("generated_at"), now=now)
    if not isinstance(report.get("ok"), bool):
        failures.append(CheckResult("Status Report", False, "status report top-level ok is not boolean"))
    failures.extend(_host_validation_failures(report.get("host")))
    failures.extend(_app_validation_failures(report.get("app")))
    failures.extend(_runtime_readiness_validation_failures(report))
    config_failures = _config_validation_failures(report)
    failures.extend(config_failures)
    failures.extend(_user_validation_failures(report.get("user")))
    failures.extend(_unit_files_validation_failures(report.get("unit_files")))
    failures.extend(_service_summary_validation_failures(report))
    failures.extend(_clock_time_validation_failures(report))
    failures.extend(_pi_health_validation_failures(report))
    failures.extend(_command_evidence_validation_failures(report))
    failures.extend(_launcher_settings_validation_failures(report.get("launcher_settings")))
    failures.extend(_desktop_validation_failures(report))
    if not config_failures:
        failures.extend(_storage_validation_failures(report))
        failures.extend(_chart_readiness_validation_failures(report, now=now))
        failures.extend(_opencpn_readiness_validation_failures(report))
        failures.extend(_gps_readiness_validation_failures(report))
        failures.extend(_serial_gps_device_validation_failures(report))
        failures.extend(_gpsd_config_validation_failures(report))
        failures.extend(_chrony_gps_time_validation_failures(report))
        failures.extend(_opencpn_config_validation_failures(report))
        failures.extend(_gps_fix_validation_failures(report, now=now))
    failures.extend(_manifest_validation_failures(report.get("manifest")))
    failures.extend(_track_log_validation_failures(report.get("track_log"), now=now))
    for section_name in ("checks", "service_checks"):
        section = report.get(section_name)
        if not isinstance(section, list):
            failures.append(CheckResult("Status Report", False, f"status report missing {section_name} section"))
            continue
        if section_name == "checks":
            unnamed_detail = "status report has unnamed readiness check"
            duplicate_prefix = "status report has duplicate readiness check"
        else:
            unnamed_detail = "status report has unnamed service check"
            duplicate_prefix = "status report has duplicate service check"
        rows: dict[str, dict[str, object]] = {}
        for item in section:
            if not isinstance(item, dict):
                failures.append(CheckResult("Status Report", False, f"status report has malformed {section_name} row"))
                continue
            name = str(item.get("name", "")).strip()
            if not name:
                failures.append(CheckResult("Status Report", False, unnamed_detail))
                continue
            if not isinstance(item.get("ok"), bool):
                failures.append(CheckResult("Status Report", False, f"status report {name} ok is not boolean"))
                continue
            if name in rows:
                failures.append(CheckResult("Status Report", False, f"{duplicate_prefix}: {name}"))
                continue
            rows[name] = item
    missing_checks, missing_service_checks = missing_required_readiness_checks(report)
    failures.extend(
        CheckResult(name, False, "status report is missing this readiness check") for name in missing_checks
    )
    failures.extend(
        CheckResult(name, False, "status report is missing this service check") for name in missing_service_checks
    )
    return failures


def _gpsd_config_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    config = report.get("config")
    if not isinstance(config, dict) or str(config.get("gps_mode", "")).strip().lower() != "gpsd":
        return []
    checks = report.get("checks")
    if not isinstance(checks, list):
        return []
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    row = check_rows.get("GPSD Config")
    if not isinstance(row, dict) or row.get("ok") is not True:
        return []
    data = row.get("data")
    if not isinstance(data, dict):
        return [CheckResult("GPSD Config", False, "status report GPSD Config check has no structured data")]
    failures: list[CheckResult] = []
    path = str(data.get("path", "")).strip()
    if path != "/etc/default/gpsd":
        failures.append(CheckResult("GPSD Config", False, f"status report GPSD Config path {path or '<missing>'} is not /etc/default/gpsd"))
    if data.get("exists") is not True:
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config path does not exist"))
    if data.get("is_symlink") is not False:
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config path is a symlink"))
    if str(data.get("directory_symlink_component", "")).strip():
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config directory contains a symlink"))
    if data.get("is_regular") is not True:
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config path is not a regular file"))
    uid = data.get("uid")
    expected_uid = data.get("expected_uid")
    if isinstance(uid, bool) or not isinstance(uid, int) or uid != 0:
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config owner is not root"))
    if isinstance(expected_uid, bool) or not isinstance(expected_uid, int) or expected_uid != 0:
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config expected owner is not root"))
    mode = str(data.get("mode", "")).strip()
    try:
        parsed_mode = int(mode, 8)
    except ValueError:
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config mode is invalid"))
    else:
        if parsed_mode & 0o022:
            failures.append(CheckResult("GPSD Config", False, "status report GPSD Config is group/world writable"))
    expected_device = str(config.get("gps_device", "")).strip()
    if str(data.get("expected_device", "")).strip() != expected_device:
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config expected device does not match config"))
    devices = data.get("devices")
    if not isinstance(devices, list) or devices != [expected_device]:
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config devices do not match configured GPS device"))
    if str(data.get("start_daemon", "")).strip() != "true":
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config START_DAEMON is not true"))
    if str(data.get("usbauto", "")).strip() != "false":
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config USBAUTO is not false"))
    options = data.get("gpsd_options")
    if not isinstance(options, list) or "-n" not in options or data.get("immediate_polling") is not True:
        failures.append(CheckResult("GPSD Config", False, "status report GPSD Config does not enable immediate polling"))
    return failures


def _runtime_readiness_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    checks = report.get("checks")
    if not isinstance(checks, list):
        return []
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    failures: list[CheckResult] = []

    python_row = check_rows.get("Python")
    if isinstance(python_row, dict) and python_row.get("ok") is True:
        data = python_row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Python", False, "status report Python check has no structured data"))
        else:
            version_info = data.get("version_info")
            min_version = data.get("min_version")
            if (
                not isinstance(version_info, list)
                or len(version_info) < 2
                or any(isinstance(part, bool) or not isinstance(part, int) for part in version_info[:2])
            ):
                failures.append(CheckResult("Python", False, "status report Python version_info is invalid"))
            elif version_info[:2] < [3, 9]:
                failures.append(CheckResult("Python", False, "status report Python version is below 3.9"))
            if not isinstance(min_version, list) or min_version[:2] != [3, 9]:
                failures.append(CheckResult("Python", False, "status report Python minimum version is not recorded"))
            executable_value = data.get("executable", "")
            if not isinstance(executable_value, str):
                failures.append(CheckResult("Python", False, "status report Python executable path is not text"))
                executable = ""
            else:
                executable = executable_value.strip()
                control_failure = _status_control_character_failure(executable, "Python executable path")
                if control_failure:
                    failures.append(CheckResult("Python", False, control_failure))
            if not _status_absolute_path(executable):
                failures.append(CheckResult("Python", False, "status report Python executable path is not absolute"))

    tkinter_row = check_rows.get("Tkinter")
    if isinstance(tkinter_row, dict) and tkinter_row.get("ok") is True:
        data = tkinter_row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Tkinter", False, "status report Tkinter check has no structured data"))
        else:
            module_value = data.get("module", "")
            if not isinstance(module_value, str):
                failures.append(CheckResult("Tkinter", False, "status report Tkinter module is not text"))
                module = ""
            else:
                module = module_value.strip()
                control_failure = _status_control_character_failure(module, "Tkinter module")
                if control_failure:
                    failures.append(CheckResult("Tkinter", False, control_failure))
            if module != "tkinter":
                failures.append(CheckResult("Tkinter", False, "status report Tkinter module is not tkinter"))
            if data.get("available") is not True:
                failures.append(CheckResult("Tkinter", False, "status report Tkinter availability was not proven"))

    source_row = check_rows.get("Source Revision")
    if isinstance(source_row, dict) and source_row.get("ok") is True:
        data = source_row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Source Revision", False, "status report Source Revision check has no structured data"))
        elif data.get("is_raspberry_pi") is False and data.get("skipped") is True:
            pass
        else:
            revision_value = data.get("revision", "")
            if not isinstance(revision_value, str):
                failures.append(CheckResult("Source Revision", False, "status report Source Revision revision is not text"))
                revision = ""
            else:
                revision = revision_value.strip()
                control_failure = _status_control_character_failure(revision, "Source Revision revision")
                if control_failure:
                    failures.append(CheckResult("Source Revision", False, control_failure))
            app = report.get("app")
            expected_revision = app.get("source_revision", "") if isinstance(app, dict) else ""
            if not isinstance(expected_revision, str):
                expected_revision = ""
            expected_revision = expected_revision.strip()
            if revision.endswith("-dirty"):
                failures.append(CheckResult("Source Revision", False, "status report Source Revision records a dirty revision"))
            elif revision != expected_revision:
                failures.append(CheckResult("Source Revision", False, "status report Source Revision does not match app source revision"))
            path_value = data.get("path", "")
            if not isinstance(path_value, str):
                failures.append(CheckResult("Source Revision", False, "status report Source Revision path is not text"))
                path = ""
            else:
                path = path_value.strip()
                control_failure = _status_control_character_failure(path, "Source Revision path")
                if control_failure:
                    failures.append(CheckResult("Source Revision", False, control_failure))
            if not _status_absolute_path(path):
                failures.append(CheckResult("Source Revision", False, "status report Source Revision path is not absolute"))
            if data.get("exists") is not True:
                failures.append(CheckResult("Source Revision", False, "status report Source Revision path does not exist"))
            if data.get("is_symlink") is not False:
                failures.append(CheckResult("Source Revision", False, "status report Source Revision path is a symlink"))
            symlink_component_value = data.get("directory_symlink_component", "")
            if not isinstance(symlink_component_value, str):
                failures.append(
                    CheckResult("Source Revision", False, "status report Source Revision directory symlink component is not text")
                )
                symlink_component = ""
            else:
                symlink_component = symlink_component_value.strip()
                control_failure = _status_control_character_failure(
                    symlink_component,
                    "Source Revision directory symlink component",
                )
                if control_failure:
                    failures.append(CheckResult("Source Revision", False, control_failure))
            if symlink_component:
                failures.append(CheckResult("Source Revision", False, "status report Source Revision directory contains a symlink"))
            if data.get("is_regular") is not True:
                failures.append(CheckResult("Source Revision", False, "status report Source Revision path is not a regular file"))
            uid = data.get("uid")
            expected_uid = data.get("expected_uid")
            if (
                isinstance(uid, bool)
                or isinstance(expected_uid, bool)
                or not isinstance(uid, int)
                or not isinstance(expected_uid, int)
                or uid != expected_uid
            ):
                failures.append(CheckResult("Source Revision", False, "status report Source Revision owner is invalid"))
            mode_value = data.get("mode", "")
            if not isinstance(mode_value, str):
                failures.append(CheckResult("Source Revision", False, "status report Source Revision mode is not text"))
                mode = ""
            else:
                mode = mode_value.strip()
                control_failure = _status_control_character_failure(mode, "Source Revision mode")
                if control_failure:
                    failures.append(CheckResult("Source Revision", False, control_failure))
            try:
                parsed_mode = int(mode, 8)
            except ValueError:
                failures.append(CheckResult("Source Revision", False, "status report Source Revision mode is invalid"))
            else:
                if parsed_mode & 0o022:
                    failures.append(CheckResult("Source Revision", False, "status report Source Revision is group/world writable"))
    return failures


def _chart_readiness_validation_failures(
    report: dict[str, object],
    *,
    now: Optional[datetime] = None,
) -> list[CheckResult]:
    config = report.get("config")
    checks = report.get("checks")
    if not isinstance(config, dict) or not isinstance(checks, list):
        return []
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    failures: list[CheckResult] = []

    package_row = check_rows.get("Chart Package")
    if isinstance(package_row, dict) and package_row.get("ok") is True:
        data = package_row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Chart Package", False, "status report Chart Package check has no structured data"))
        else:
            expected_package = str(config.get("chart_package", "")).strip().lower()
            expected_value = str(config.get("chart_value", "")).strip()
            if str(data.get("package", "")).strip().lower() != expected_package:
                failures.append(CheckResult("Chart Package", False, "status report Chart Package does not match configured package"))
            if str(data.get("value", "")).strip() != expected_value:
                failures.append(CheckResult("Chart Package", False, "status report Chart Package does not match configured value"))
            if expected_package and data.get("complete_chart_set") is not True:
                failures.append(CheckResult("Chart Package", False, "status report Chart Package is not a complete NOAA ENC package"))
            expected_filename, expected_url = _expected_manifest_package(expected_package, expected_value)
            if expected_filename and str(data.get("expected_filename", "")).strip() != expected_filename:
                failures.append(CheckResult("Chart Package", False, "status report Chart Package filename does not match NOAA package"))
            if expected_url and str(data.get("expected_url", "")).strip() != expected_url:
                failures.append(CheckResult("Chart Package", False, "status report Chart Package URL does not match NOAA package"))

    charts_row = check_rows.get("Charts")
    if isinstance(charts_row, dict) and charts_row.get("ok") is True:
        data = charts_row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Charts", False, "status report Charts check has no structured data"))
        else:
            expected_path = str(config.get("chart_output", "")).strip()
            configured_path_text = str(data.get("configured_path", ""))
            configured_path_failure = _status_control_character_failure(configured_path_text, "Charts path")
            if configured_path_failure:
                failures.append(CheckResult("Charts", False, configured_path_failure))
            configured_path = configured_path_text.strip()
            if not _status_absolute_path(configured_path):
                failures.append(CheckResult("Charts", False, "status report Charts path is not absolute"))
            if configured_path != expected_path:
                failures.append(CheckResult("Charts", False, "status report Charts path does not match configured chart output"))
            if data.get("exists") is not True:
                failures.append(CheckResult("Charts", False, "status report Charts path does not exist"))
            if str(data.get("storage_symlink_component", "")).strip():
                failures.append(CheckResult("Charts", False, "status report Charts path contains a symlink"))
            enc_cell_samples = data.get("enc_cell_samples")
            if data.get("has_extracted_enc_cells") is not True:
                failures.append(CheckResult("Charts", False, "status report Charts found no extracted ENC cells"))
            if data.get("has_unextracted_zips") is not False:
                failures.append(CheckResult("Charts", False, "status report Charts found unextracted ZIP chart artifacts"))
            zip_samples = data.get("zip_samples")
            if not isinstance(zip_samples, list) or zip_samples:
                failures.append(CheckResult("Charts", False, "status report Charts ZIP sample list is not empty"))
            if not isinstance(enc_cell_samples, list) or not enc_cell_samples:
                failures.append(CheckResult("Charts", False, "status report Charts has no ENC cell sample paths"))
            elif any(_status_text_has_control_char(str(sample)) for sample in enc_cell_samples):
                failures.append(CheckResult("Charts", False, "status report Charts ENC cell sample path contains control characters"))
            elif any(not _status_absolute_path(str(sample)) for sample in enc_cell_samples):
                failures.append(CheckResult("Charts", False, "status report Charts ENC cell sample path is not absolute"))
            elif any(not _status_path_under(str(sample), expected_path) for sample in enc_cell_samples):
                failures.append(CheckResult("Charts", False, "status report Charts ENC cell sample path is outside chart output"))

    debris_row = check_rows.get("Chart Update Debris")
    if isinstance(debris_row, dict) and debris_row.get("ok") is True:
        data = debris_row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Chart Update Debris", False, "status report Chart Update Debris check has no structured data"))
        else:
            expected_path = str(config.get("chart_output", "")).strip()
            configured_path_text = str(data.get("configured_path", ""))
            configured_path_failure = _status_control_character_failure(configured_path_text, "Chart Update Debris path")
            if configured_path_failure:
                failures.append(CheckResult("Chart Update Debris", False, configured_path_failure))
            configured_path = configured_path_text.strip()
            if not _status_absolute_path(configured_path):
                failures.append(CheckResult("Chart Update Debris", False, "status report Chart Update Debris path is not absolute"))
            if configured_path != expected_path:
                failures.append(CheckResult("Chart Update Debris", False, "status report Chart Update Debris path does not match configured chart output"))
            if str(data.get("storage_symlink_component", "")).strip():
                failures.append(CheckResult("Chart Update Debris", False, "status report Chart Update Debris path contains a symlink"))
            debris_count = data.get("debris_count")
            if isinstance(debris_count, bool) or not isinstance(debris_count, int) or debris_count != 0:
                failures.append(CheckResult("Chart Update Debris", False, "status report Chart Update Debris found stale update debris"))
            debris = data.get("debris")
            if not isinstance(debris, list) or debris:
                failures.append(CheckResult("Chart Update Debris", False, "status report Chart Update Debris debris list is not empty"))
            if data.get("clean") is not True:
                failures.append(CheckResult("Chart Update Debris", False, "status report Chart Update Debris did not prove a clean chart directory"))

    manifest_row = check_rows.get("Manifest")
    if isinstance(manifest_row, dict) and manifest_row.get("ok") is True:
        data = manifest_row.get("data")
        manifest = report.get("manifest")
        if not isinstance(data, dict):
            failures.append(CheckResult("Manifest", False, "status report Manifest check has no structured data"))
        elif not isinstance(manifest, dict):
            failures.append(CheckResult("Manifest", False, "status report Manifest check has no top-level manifest summary"))
        else:
            expected_path = str(config.get("chart_output", "")).strip()
            configured_path_text = str(data.get("configured_path", ""))
            configured_path_failure = _status_control_character_failure(configured_path_text, "Manifest configured path")
            if configured_path_failure:
                failures.append(CheckResult("Manifest", False, configured_path_failure))
            configured_path = configured_path_text.strip()
            if not _status_absolute_path(configured_path):
                failures.append(CheckResult("Manifest", False, "status report Manifest configured path is not absolute"))
            if configured_path != expected_path:
                failures.append(CheckResult("Manifest", False, "status report Manifest configured path does not match chart output"))
            manifest_path_text = str(data.get("path", ""))
            manifest_path_failure = _status_control_character_failure(manifest_path_text, "Manifest path")
            if manifest_path_failure:
                failures.append(CheckResult("Manifest", False, manifest_path_failure))
            manifest_path = manifest_path_text.strip()
            if not _status_absolute_path(manifest_path):
                failures.append(CheckResult("Manifest", False, "status report Manifest path is not absolute"))
            if manifest_path != str(manifest.get("path", "")).strip():
                failures.append(CheckResult("Manifest", False, "status report Manifest path does not match manifest summary"))
            for row_field, summary_field, detail in (
                ("created_at", "created_at", "created_at does not match manifest summary"),
                ("created_at_source", "created_at_source", "created_at_source does not match manifest summary"),
                ("package", "package", "package label does not match manifest summary"),
                ("package_filename", "package_filename", "package filename does not match manifest summary"),
                ("package_url", "url", "package URL does not match manifest summary"),
                ("download_path", "download_path", "download path does not match manifest summary"),
                ("download_url", "download_url", "download URL does not match manifest summary"),
                ("sha256", "sha256", "SHA-256 does not match manifest summary"),
                ("extract_path", "extract_path", "extract path does not match manifest summary"),
            ):
                if str(data.get(row_field, "")).strip() != str(manifest.get(summary_field, "")).strip():
                    failures.append(CheckResult("Manifest", False, f"status report Manifest {detail}"))
            created_at_source = str(data.get("created_at_source", "")).strip()
            if created_at_source not in {"download", "previous-manifest"}:
                failures.append(CheckResult("Manifest", False, "status report Manifest created_at_source is not verified"))
            expected_package = str(config.get("chart_package", "")).strip().lower()
            expected_value = str(config.get("chart_value", "")).strip()
            expected_filename, expected_url = _expected_manifest_package(expected_package, expected_value)
            if expected_filename and str(data.get("expected_filename", "")).strip() != expected_filename:
                failures.append(CheckResult("Manifest", False, "status report Manifest expected filename does not match NOAA package"))
            if expected_url and str(data.get("expected_url", "")).strip() != expected_url:
                failures.append(CheckResult("Manifest", False, "status report Manifest expected URL does not match NOAA package"))
            if expected_filename and str(data.get("package_filename", "")).strip() != expected_filename:
                failures.append(CheckResult("Manifest", False, "status report Manifest package filename does not match NOAA package"))
            if expected_url and str(data.get("package_url", "")).strip() != expected_url:
                failures.append(CheckResult("Manifest", False, "status report Manifest package URL does not match NOAA package"))
            max_age_days = _positive_status_int(data.get("max_age_days"))
            if max_age_days is None:
                failures.append(CheckResult("Manifest", False, "status report Manifest max_age_days is not positive"))
            configured_max_age_days = _positive_status_int(config.get("max_chart_age_days"))
            if max_age_days is not None and configured_max_age_days is not None and max_age_days != configured_max_age_days:
                failures.append(CheckResult("Manifest", False, "status report Manifest max_age_days does not match config"))
            created_at = _parse_gps_fix_timestamp(data.get("created_at"))
            if created_at is None:
                failures.append(CheckResult("Manifest", False, "status report Manifest created_at timestamp is invalid"))
            elif max_age_days is not None:
                try:
                    current = _current_utc(now, label="status report Manifest")
                except ValueError as exc:
                    failures.append(CheckResult("Manifest", False, str(exc)))
                else:
                    age_days = (current - created_at).total_seconds() / 86400
                    if age_days < -0.01:
                        failures.append(CheckResult("Manifest", False, "status report Manifest created_at timestamp is in the future"))
                    elif age_days > max_age_days:
                        failures.append(CheckResult("Manifest", False, f"status report Manifest is {age_days:.1f} days old; max is {max_age_days}"))
            reported_age_days = _finite_gps_fix_float(data.get("age_days"))
            if reported_age_days is None or reported_age_days < 0:
                failures.append(CheckResult("Manifest", False, "status report Manifest age_days is invalid"))
            download_path_text = str(data.get("download_path", ""))
            extract_path_text = str(data.get("extract_path", ""))
            download_path_failure = _status_control_character_failure(download_path_text, "Manifest download path")
            if download_path_failure:
                failures.append(CheckResult("Manifest", False, download_path_failure))
            extract_path_failure = _status_control_character_failure(extract_path_text, "Manifest extract path")
            if extract_path_failure:
                failures.append(CheckResult("Manifest", False, extract_path_failure))
            download_path = download_path_text.strip()
            extract_path = extract_path_text.strip()
            if not _status_absolute_path(download_path):
                failures.append(CheckResult("Manifest", False, "status report Manifest download path is not absolute"))
            elif not _status_path_under(download_path, expected_path):
                failures.append(CheckResult("Manifest", False, "status report Manifest download path is outside chart output"))
            if not _status_absolute_path(extract_path):
                failures.append(CheckResult("Manifest", False, "status report Manifest extract path is not absolute"))
            elif not _status_path_under(extract_path, expected_path):
                failures.append(CheckResult("Manifest", False, "status report Manifest extract path is outside chart output"))
            download_bytes = _positive_status_int(data.get("download_bytes"))
            summary_download_bytes = _positive_status_int(manifest.get("download_bytes"))
            if download_bytes is None:
                failures.append(CheckResult("Manifest", False, "status report Manifest download byte count is not positive"))
            elif summary_download_bytes is not None and download_bytes != summary_download_bytes:
                failures.append(CheckResult("Manifest", False, "status report Manifest download byte count does not match manifest summary"))
            enc_cell_count = _positive_status_int(data.get("enc_cell_count"))
            actual_enc_cell_count = _positive_status_int(data.get("actual_enc_cell_count"))
            summary_enc_cell_count = _positive_status_int(manifest.get("enc_cell_count"))
            summary_actual_enc_cell_count = _positive_status_int(manifest.get("actual_enc_cell_count"))
            if enc_cell_count is None:
                failures.append(CheckResult("Manifest", False, "status report Manifest has no ENC cells"))
            if actual_enc_cell_count is None:
                failures.append(CheckResult("Manifest", False, "status report Manifest actual ENC cell count is not positive"))
            if enc_cell_count is not None and actual_enc_cell_count is not None and enc_cell_count != actual_enc_cell_count:
                failures.append(CheckResult("Manifest", False, "status report Manifest actual ENC cell count does not match recorded count"))
            if enc_cell_count is not None and summary_enc_cell_count is not None and enc_cell_count != summary_enc_cell_count:
                failures.append(CheckResult("Manifest", False, "status report Manifest ENC cell count does not match manifest summary"))
            if (
                actual_enc_cell_count is not None
                and summary_actual_enc_cell_count is not None
                and actual_enc_cell_count != summary_actual_enc_cell_count
            ):
                failures.append(CheckResult("Manifest", False, "status report Manifest actual ENC cell count does not match manifest summary"))
    return failures


def _opencpn_readiness_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    config = report.get("config")
    checks = report.get("checks")
    if not isinstance(config, dict) or not isinstance(checks, list):
        return []
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    failures: list[CheckResult] = []

    charts_row = check_rows.get("OpenCPN Charts")
    if isinstance(charts_row, dict) and charts_row.get("ok") is True:
        data = charts_row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("OpenCPN Charts", False, "status report OpenCPN Charts check has no structured data"))
        else:
            chart_dir_text = str(data.get("chart_dir", ""))
            chart_dir_failure = _status_control_character_failure(chart_dir_text, "OpenCPN Charts chart directory")
            if chart_dir_failure:
                failures.append(CheckResult("OpenCPN Charts", False, chart_dir_failure))
            chart_dir = chart_dir_text.strip()
            expected_chart_output = str(config.get("chart_output", "")).strip()
            if not _status_absolute_path(chart_dir):
                failures.append(CheckResult("OpenCPN Charts", False, "status report OpenCPN Charts chart directory is not absolute"))
            if chart_dir != expected_chart_output:
                failures.append(CheckResult("OpenCPN Charts", False, "status report OpenCPN Charts chart directory does not match configured chart output"))
            config_path_text = str(data.get("config_path", ""))
            config_path_failure = _status_control_character_failure(config_path_text, "OpenCPN Charts config path")
            if config_path_failure:
                failures.append(CheckResult("OpenCPN Charts", False, config_path_failure))
            config_path = config_path_text.strip()
            if not _status_absolute_path(config_path):
                failures.append(CheckResult("OpenCPN Charts", False, "status report OpenCPN Charts config path is not absolute"))
            if data.get("config_exists") is not True:
                failures.append(CheckResult("OpenCPN Charts", False, "status report OpenCPN Charts config does not exist"))
            if data.get("chart_dir_exists") is not True:
                failures.append(CheckResult("OpenCPN Charts", False, "status report OpenCPN Charts chart directory does not exist"))
            if data.get("configured") is not True:
                failures.append(CheckResult("OpenCPN Charts", False, "status report OpenCPN Charts did not prove configured chart directory"))
            chart_directories = data.get("chart_directories")
            if not isinstance(chart_directories, list) or not chart_directories:
                failures.append(CheckResult("OpenCPN Charts", False, "status report OpenCPN Charts has no parsed chart directories"))
            elif any(_status_text_has_control_char(str(directory)) for directory in chart_directories):
                failures.append(CheckResult("OpenCPN Charts", False, "status report OpenCPN Charts parsed directories contain control characters"))
            elif not any(str(directory).strip() == expected_chart_output for directory in chart_directories):
                failures.append(CheckResult("OpenCPN Charts", False, "status report OpenCPN Charts parsed directories do not include configured chart output"))

    gps_mode = str(config.get("gps_mode", "")).strip().lower()
    if gps_mode == "gpsd":
        gpsd_row = check_rows.get("OpenCPN GPSD")
        if isinstance(gpsd_row, dict) and gpsd_row.get("ok") is True:
            data = gpsd_row.get("data")
            if not isinstance(data, dict):
                failures.append(CheckResult("OpenCPN GPSD", False, "status report OpenCPN GPSD check has no structured data"))
            else:
                config_path_text = str(data.get("config_path", ""))
                config_path_failure = _status_control_character_failure(config_path_text, "OpenCPN GPSD config path")
                if config_path_failure:
                    failures.append(CheckResult("OpenCPN GPSD", False, config_path_failure))
                config_path = config_path_text.strip()
                if not _status_absolute_path(config_path):
                    failures.append(CheckResult("OpenCPN GPSD", False, "status report OpenCPN GPSD config path is not absolute"))
                if data.get("config_exists") is not True:
                    failures.append(CheckResult("OpenCPN GPSD", False, "status report OpenCPN GPSD config does not exist"))
                expected_host = normalize_gpsd_host(str(config.get("gpsd_host", "")).strip())
                expected_port = config.get("gpsd_port")
                if str(data.get("expected_host", "")).strip() != expected_host:
                    failures.append(CheckResult("OpenCPN GPSD", False, "status report OpenCPN GPSD host does not match configured GPSD host"))
                if data.get("expected_port") != expected_port:
                    failures.append(CheckResult("OpenCPN GPSD", False, "status report OpenCPN GPSD port does not match configured GPSD port"))
                if data.get("configured") is not True:
                    failures.append(CheckResult("OpenCPN GPSD", False, "status report OpenCPN GPSD did not prove configured endpoint"))
                connections = data.get("enabled_gpsd_connections")
                if not isinstance(connections, list) or not connections:
                    failures.append(CheckResult("OpenCPN GPSD", False, "status report OpenCPN GPSD has no parsed enabled GPSD connections"))
                else:
                    matching = [
                        connection
                        for connection in connections
                        if isinstance(connection, dict)
                        and str(connection.get("host", "")).strip() == expected_host
                        and connection.get("port") == expected_port
                    ]
                    if not matching:
                        failures.append(CheckResult("OpenCPN GPSD", False, "status report OpenCPN GPSD parsed connections do not include configured endpoint"))
                unexpected = data.get("unexpected_connections")
                if not isinstance(unexpected, list):
                    failures.append(CheckResult("OpenCPN GPSD", False, "status report OpenCPN GPSD unexpected connection list was not parsed"))
                elif unexpected:
                    failures.append(CheckResult("OpenCPN GPSD", False, "status report OpenCPN GPSD found unexpected enabled GPSD connections"))
    return failures


def _gps_readiness_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    config = report.get("config")
    checks = report.get("checks")
    gps_fix = report.get("gps_fix")
    if not isinstance(config, dict) or not isinstance(checks, list):
        return []
    gps_mode = str(config.get("gps_mode", "")).strip().lower()
    expected_name = "GPS" if gps_mode == "serial" else "GPSD"
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    row = check_rows.get(expected_name)
    if not isinstance(row, dict) or row.get("ok") is not True:
        return []
    data = row.get("data")
    if not isinstance(data, dict):
        return [CheckResult(expected_name, False, f"status report {expected_name} check has no structured fix data")]

    failures: list[CheckResult] = []
    latitude = _finite_gps_fix_float(data.get("latitude"))
    longitude = _finite_gps_fix_float(data.get("longitude"))
    if latitude is None or longitude is None:
        failures.append(CheckResult(expected_name, False, f"status report {expected_name} fix has non-numeric coordinates"))
    elif not (-90.0 <= latitude <= 90.0):
        failures.append(CheckResult(expected_name, False, f"status report {expected_name} fix latitude is outside -90..90"))
    elif not (-180.0 <= longitude <= 180.0):
        failures.append(CheckResult(expected_name, False, f"status report {expected_name} fix longitude is outside -180..180"))
    elif abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        failures.append(CheckResult(expected_name, False, f"status report {expected_name} fix coordinates are invalid 0,0"))
    timestamp = _parse_gps_fix_timestamp(data.get("timestamp"))
    if timestamp is None:
        failures.append(CheckResult(expected_name, False, f"status report {expected_name} fix has no valid timestamp"))
    satellites = data.get("satellites")
    hdop = data.get("hdop")
    if satellites is None and hdop is None:
        failures.append(CheckResult(expected_name, False, f"status report {expected_name} fix has no satellite or HDOP quality fields"))
    if satellites is not None and (isinstance(satellites, bool) or not isinstance(satellites, int) or satellites < 4):
        failures.append(CheckResult(expected_name, False, f"status report {expected_name} fix satellites is weak or invalid"))
    parsed_hdop = _finite_gps_fix_float(hdop)
    if hdop is not None and (parsed_hdop is None or parsed_hdop < 0.0 or parsed_hdop > 5.0):
        failures.append(CheckResult(expected_name, False, f"status report {expected_name} fix HDOP is weak or invalid"))

    if isinstance(gps_fix, dict) and gps_fix.get("ok") is True:
        if str(gps_fix.get("source", "")).strip() != expected_name:
            failures.append(CheckResult(expected_name, False, f"status report {expected_name} row does not match gps_fix source"))
        summary_latitude = _finite_gps_fix_float(gps_fix.get("latitude"))
        summary_longitude = _finite_gps_fix_float(gps_fix.get("longitude"))
        if latitude is not None and summary_latitude is not None and abs(latitude - summary_latitude) > 1e-7:
            failures.append(CheckResult(expected_name, False, f"status report {expected_name} latitude does not match gps_fix"))
        if longitude is not None and summary_longitude is not None and abs(longitude - summary_longitude) > 1e-7:
            failures.append(CheckResult(expected_name, False, f"status report {expected_name} longitude does not match gps_fix"))
        summary_timestamp = _parse_gps_fix_timestamp(gps_fix.get("timestamp"))
        if timestamp is not None and summary_timestamp is not None and timestamp != summary_timestamp:
            failures.append(CheckResult(expected_name, False, f"status report {expected_name} timestamp does not match gps_fix"))
        if satellites is not None and gps_fix.get("satellites") is not None and satellites != gps_fix.get("satellites"):
            failures.append(CheckResult(expected_name, False, f"status report {expected_name} satellites do not match gps_fix"))
        if hdop is not None and gps_fix.get("hdop") is not None:
            summary_hdop = _finite_gps_fix_float(gps_fix.get("hdop"))
            if parsed_hdop is not None and summary_hdop is not None and abs(parsed_hdop - summary_hdop) > 1e-9:
                failures.append(CheckResult(expected_name, False, f"status report {expected_name} HDOP does not match gps_fix"))
    return failures


def _chrony_gps_time_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    config = report.get("config")
    if not isinstance(config, dict) or str(config.get("gps_mode", "")).strip().lower() != "gpsd":
        return []
    checks = report.get("checks")
    if not isinstance(checks, list):
        return []
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    failures: list[CheckResult] = []

    config_row = check_rows.get("Chrony Config")
    if isinstance(config_row, dict) and config_row.get("ok") is True:
        data = config_row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Chrony Config", False, "status report Chrony Config check has no structured data"))
        elif data.get("is_raspberry_pi") is False and data.get("skipped") is True:
            pass
        else:
            path = str(data.get("path", "")).strip()
            if path != "/etc/chrony/chrony.conf":
                failures.append(CheckResult("Chrony Config", False, f"status report Chrony Config path {path or '<missing>'} is not /etc/chrony/chrony.conf"))
            if data.get("exists") is not True:
                failures.append(CheckResult("Chrony Config", False, "status report Chrony Config path does not exist"))
            if data.get("is_symlink") is not False:
                failures.append(CheckResult("Chrony Config", False, "status report Chrony Config path is a symlink"))
            if str(data.get("directory_symlink_component", "")).strip():
                failures.append(CheckResult("Chrony Config", False, "status report Chrony Config directory contains a symlink"))
            if data.get("is_regular") is not True:
                failures.append(CheckResult("Chrony Config", False, "status report Chrony Config path is not a regular file"))
            uid = data.get("uid")
            expected_uid = data.get("expected_uid")
            if isinstance(uid, bool) or not isinstance(uid, int) or uid != 0:
                failures.append(CheckResult("Chrony Config", False, "status report Chrony Config owner is not root"))
            if isinstance(expected_uid, bool) or not isinstance(expected_uid, int) or expected_uid != 0:
                failures.append(CheckResult("Chrony Config", False, "status report Chrony Config expected owner is not root"))
            mode = str(data.get("mode", "")).strip()
            try:
                parsed_mode = int(mode, 8)
            except ValueError:
                failures.append(CheckResult("Chrony Config", False, "status report Chrony Config mode is invalid"))
            else:
                if parsed_mode & 0o022:
                    failures.append(CheckResult("Chrony Config", False, "status report Chrony Config is group/world writable"))
            if data.get("managed_refclock_present") is not True:
                failures.append(CheckResult("Chrony Config", False, "status report Chrony Config is missing managed GPSD SHM refclock"))
            if str(data.get("refclock_line", "")).strip() != "refclock SHM 0 offset 0.5 delay 0.1 refid GPS":
                failures.append(CheckResult("Chrony Config", False, "status report Chrony Config refclock line is not the managed GPSD SHM source"))

    source_row = check_rows.get("GPS Time Source")
    if isinstance(source_row, dict) and source_row.get("ok") is True:
        data = source_row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("GPS Time Source", False, "status report GPS Time Source check has no structured data"))
        elif data.get("is_raspberry_pi") is False and data.get("skipped") is True:
            pass
        else:
            if data.get("is_raspberry_pi") is not True:
                failures.append(CheckResult("GPS Time Source", False, "status report GPS Time Source did not identify a Raspberry Pi check"))
            if data.get("chronyc_available") is not True:
                failures.append(CheckResult("GPS Time Source", False, "status report GPS Time Source did not validate chronyc availability"))
            gps_lines = data.get("gps_lines")
            if not isinstance(gps_lines, list) or not gps_lines:
                failures.append(CheckResult("GPS Time Source", False, "status report GPS Time Source has no GPS refclock lines"))
            usable_lines = data.get("usable_lines")
            if not isinstance(usable_lines, list) or not usable_lines:
                failures.append(CheckResult("GPS Time Source", False, "status report GPS Time Source has no selected or combined GPS refclock"))
            if data.get("selected_or_combined") is not True:
                failures.append(CheckResult("GPS Time Source", False, "status report GPS Time Source did not prove selected or combined GPS time"))
    return failures


def _command_evidence_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    checks = report.get("checks")
    if not isinstance(checks, list):
        return []
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    expected_commands = {
        "OpenCPN": "opencpn",
        "Display Power": "xset",
    }
    failures: list[CheckResult] = []
    for name, expected_command in expected_commands.items():
        row = check_rows.get(name)
        if not isinstance(row, dict) or row.get("ok") is not True:
            continue
        data = row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult(name, False, f"status report {name} check has no structured command data"))
            continue
        command = str(data.get("command", "")).strip()
        if command != expected_command:
            failures.append(
                CheckResult(
                    name,
                    False,
                    f"status report {name} command {command or '<missing>'} is not {expected_command}",
                )
            )
        path = str(data.get("path", "")).strip()
        directory = str(data.get("directory", "")).strip()
        if not _status_absolute_path(path) or data.get("is_absolute") is not True:
            failures.append(CheckResult(name, False, f"status report {name} command path is not absolute"))
        if not _status_absolute_path(directory):
            failures.append(CheckResult(name, False, f"status report {name} command directory is not absolute"))
        if data.get("is_symlink") is not False:
            failures.append(CheckResult(name, False, f"status report {name} command is a symlink"))
        if str(data.get("path_symlink_component", "")).strip():
            failures.append(CheckResult(name, False, f"status report {name} command path contains a symlink"))
        if data.get("trusted_system_directory") is not True:
            failures.append(CheckResult(name, False, f"status report {name} command is not in a trusted system directory"))
        if data.get("is_regular") is not True:
            failures.append(CheckResult(name, False, f"status report {name} command is not a regular file"))
        if data.get("executable") is not True:
            failures.append(CheckResult(name, False, f"status report {name} command is not executable"))
        for field, detail in (("uid", "command owner"), ("directory_uid", "command directory owner")):
            value = data.get(field)
            if isinstance(value, bool) or not isinstance(value, int) or value != 0:
                failures.append(CheckResult(name, False, f"status report {name} {detail} is not root"))
        for field, detail in (("mode", "command"), ("directory_mode", "command directory")):
            mode = str(data.get(field, "")).strip()
            try:
                parsed_mode = int(mode, 8)
            except ValueError:
                failures.append(CheckResult(name, False, f"status report {name} {detail} mode is invalid"))
            else:
                if parsed_mode & 0o022:
                    failures.append(CheckResult(name, False, f"status report {name} {detail} is group/world writable"))
    return failures


def _serial_gps_device_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    config = report.get("config")
    if not isinstance(config, dict) or str(config.get("gps_mode", "")).strip().lower() != "serial":
        return []
    checks = report.get("checks")
    if not isinstance(checks, list):
        return []
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    row = check_rows.get("GPS Device")
    if not isinstance(row, dict) or row.get("ok") is not True:
        return []
    data = row.get("data")
    if not isinstance(data, dict):
        return [CheckResult("GPS Device", False, "status report GPS Device check has no structured data")]
    failures: list[CheckResult] = []
    configured_path_text = str(data.get("configured_path", ""))
    configured_path_failure = _status_control_character_failure(configured_path_text, "GPS Device path")
    if configured_path_failure:
        failures.append(CheckResult("GPS Device", False, configured_path_failure))
    configured_path = configured_path_text.strip()
    expected_path = str(config.get("gps_device", "")).strip()
    if not _status_absolute_path(configured_path):
        failures.append(CheckResult("GPS Device", False, "status report GPS Device path is not absolute"))
    if configured_path != expected_path:
        failures.append(
            CheckResult(
                "GPS Device",
                False,
                f"status report GPS Device path {configured_path or '<missing>'} does not match configured {expected_path or '<missing>'}",
            )
        )
    if not _stable_status_gps_device_path(configured_path):
        failures.append(CheckResult("GPS Device", False, "status report GPS Device path is not stable"))
    if data.get("stable_path") is not True:
        failures.append(CheckResult("GPS Device", False, "status report GPS Device missing stable path evidence"))
    if data.get("volatile_path") is True:
        failures.append(CheckResult("GPS Device", False, "status report GPS Device path is volatile"))
    if data.get("exists") is not True:
        failures.append(CheckResult("GPS Device", False, "status report GPS Device path does not exist"))
    if data.get("is_directory") is True:
        failures.append(CheckResult("GPS Device", False, "status report GPS Device path is a directory"))
    if configured_path.startswith(("/dev/serial/by-id/", "/dev/serial/by-path/")) and data.get("is_symlink") is not True:
        failures.append(CheckResult("GPS Device", False, "status report GPS Device udev path is not a symlink"))
    if data.get("is_character_device") is not True:
        failures.append(CheckResult("GPS Device", False, "status report GPS Device is not a character device"))
    resolved_path_text = str(data.get("resolved_path", ""))
    resolved_path_failure = _status_control_character_failure(resolved_path_text, "GPS Device resolved path")
    if resolved_path_failure:
        failures.append(CheckResult("GPS Device", False, resolved_path_failure))
    resolved_path = resolved_path_text.strip()
    if not _status_absolute_path(resolved_path):
        failures.append(CheckResult("GPS Device", False, "status report GPS Device resolved path is not absolute"))
    return failures


def _stable_status_gps_device_path(path: str) -> bool:
    for prefix in ("/dev/serial/by-id/", "/dev/serial/by-path/"):
        if path.startswith(prefix):
            suffix = path[len(prefix) :]
            return bool(suffix) and "/" not in suffix and suffix not in {".", ".."} and all(
                char in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:+@-" for char in suffix
            )
    return path in {"/dev/serial0", "/dev/serial1", "/dev/gps"}


def _storage_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    checks = report.get("checks")
    if not isinstance(checks, list):
        return []
    failures: list[CheckResult] = []
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    for name in ("Disk", "Track Disk"):
        row = check_rows.get(name)
        if not isinstance(row, dict) or row.get("ok") is not True:
            continue
        data = row.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult(name, False, f"status report {name} check has no structured data"))
            continue
        configured_path_text = str(data.get("configured_path", ""))
        checked_path_text = str(data.get("checked_path", ""))
        configured_path_failure = _status_control_character_failure(configured_path_text, f"{name} configured path")
        if configured_path_failure:
            failures.append(CheckResult(name, False, configured_path_failure))
        checked_path_failure = _status_control_character_failure(checked_path_text, f"{name} checked path")
        if checked_path_failure:
            failures.append(CheckResult(name, False, checked_path_failure))
        configured_path = configured_path_text.strip()
        checked_path = checked_path_text.strip()
        if not _status_absolute_path(configured_path):
            failures.append(CheckResult(name, False, f"status report {name} configured path is not absolute"))
        if not _status_absolute_path(checked_path):
            failures.append(CheckResult(name, False, f"status report {name} checked path is not absolute"))
        if data.get("exists") is not True:
            failures.append(CheckResult(name, False, f"status report {name} checked path does not exist"))
        if data.get("is_directory") is not True:
            failures.append(CheckResult(name, False, f"status report {name} checked path is not a directory"))
        symlink_component = str(data.get("storage_symlink_component", "")).strip()
        if symlink_component:
            failures.append(CheckResult(name, False, f"status report {name} storage path contains a symlink"))
        if data.get("missing_removable_mount") is True:
            failures.append(CheckResult(name, False, f"status report {name} removable storage is not mounted"))
        uid = data.get("uid")
        expected_uid = data.get("expected_uid")
        if (
            isinstance(uid, bool)
            or isinstance(expected_uid, bool)
            or not isinstance(uid, int)
            or not isinstance(expected_uid, int)
            or uid != expected_uid
        ):
            failures.append(CheckResult(name, False, f"status report {name} storage owner is invalid"))
        mode = str(data.get("mode", "")).strip()
        try:
            parsed_mode = int(mode, 8)
        except ValueError:
            failures.append(CheckResult(name, False, f"status report {name} storage mode is invalid"))
        else:
            if parsed_mode & 0o022:
                failures.append(CheckResult(name, False, f"status report {name} storage is group/world writable"))
        min_free_gb = _positive_status_float(data.get("min_free_gb"))
        free_gb = _finite_gps_fix_float(data.get("free_gb"))
        if min_free_gb is None:
            failures.append(CheckResult(name, False, f"status report {name} missing minimum free-space threshold"))
        if free_gb is None or free_gb < 0.0:
            failures.append(CheckResult(name, False, f"status report {name} missing finite free-space measurement"))
        elif min_free_gb is not None and free_gb < min_free_gb:
            failures.append(
                CheckResult(
                    name,
                    False,
                    f"status report {name} free space {free_gb:.1f} GB is below {min_free_gb:.1f} GB",
                )
            )
        total_inodes = data.get("total_inodes")
        free_inodes = data.get("free_inodes")
        if isinstance(total_inodes, bool) or not isinstance(total_inodes, int) or total_inodes < 0:
            failures.append(CheckResult(name, False, f"status report {name} missing inode capacity measurement"))
        if isinstance(free_inodes, bool) or not isinstance(free_inodes, int) or free_inodes < 0:
            failures.append(CheckResult(name, False, f"status report {name} missing free inode measurement"))
        elif isinstance(total_inodes, int) and total_inodes > 0 and free_inodes <= 0:
            failures.append(CheckResult(name, False, f"status report {name} has no free inodes"))
        if data.get("writable") is not True:
            failures.append(CheckResult(name, False, f"status report {name} storage is not writable"))
    return failures


def _pi_health_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    checks = report.get("checks")
    if not isinstance(checks, list):
        return []
    failures: list[CheckResult] = []
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    power = check_rows.get("Pi Power")
    if isinstance(power, dict):
        data = power.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Pi Power", False, "status report Pi Power check has no structured data"))
        elif data.get("is_raspberry_pi") is False and data.get("skipped") is True:
            pass
        elif data.get("is_raspberry_pi") is not True:
            failures.append(CheckResult("Pi Power", False, "status report Pi Power missing Raspberry Pi evidence"))
        else:
            throttled_value = data.get("throttled_value")
            if isinstance(throttled_value, bool) or not isinstance(throttled_value, int):
                failures.append(CheckResult("Pi Power", False, "status report Pi Power missing throttled value"))
            reported_flags = data.get("reported_flags")
            if not isinstance(reported_flags, list) or any(not isinstance(flag, str) for flag in reported_flags):
                failures.append(CheckResult("Pi Power", False, "status report Pi Power missing throttling flag list"))
            elif reported_flags:
                failures.append(
                    CheckResult(
                        "Pi Power",
                        False,
                        "status report Pi Power reported throttling flags: " + ", ".join(reported_flags),
                    )
                )

    thermal = check_rows.get("Pi Thermal")
    if isinstance(thermal, dict):
        data = thermal.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Pi Thermal", False, "status report Pi Thermal check has no structured data"))
        elif data.get("is_raspberry_pi") is False and data.get("skipped") is True:
            pass
        elif data.get("is_raspberry_pi") is not True:
            failures.append(CheckResult("Pi Thermal", False, "status report Pi Thermal missing Raspberry Pi evidence"))
        else:
            temperature = data.get("temperature_c")
            if isinstance(temperature, bool) or not isinstance(temperature, (int, float)) or not math.isfinite(temperature):
                failures.append(CheckResult("Pi Thermal", False, "status report Pi Thermal missing finite temperature"))
            else:
                fail_c = data.get("fail_c", 80.0)
                try:
                    parsed_fail_c = float(fail_c)
                except (TypeError, ValueError):
                    parsed_fail_c = 80.0
                if temperature >= parsed_fail_c:
                    failures.append(
                        CheckResult(
                            "Pi Thermal",
                            False,
                            f"status report Pi Thermal temperature {temperature:.1f} C is above {parsed_fail_c:.0f} C limit",
                        )
                    )
    return failures


def _clock_time_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    checks = report.get("checks")
    if not isinstance(checks, list):
        return []
    failures: list[CheckResult] = []
    check_rows = {str(check.get("name", "")): check for check in checks if isinstance(check, dict)}
    clock = check_rows.get("Clock")
    if isinstance(clock, dict):
        data = clock.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Clock", False, "status report Clock check has no structured data"))
        else:
            timestamp = data.get("timestamp")
            try:
                parsed_clock = datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
            except ValueError:
                failures.append(CheckResult("Clock", False, f"status report Clock timestamp is invalid: {timestamp}"))
            else:
                if parsed_clock.tzinfo is None or parsed_clock.utcoffset() is None:
                    failures.append(CheckResult("Clock", False, "status report Clock timestamp must include a timezone"))
                else:
                    min_year = data.get("min_year", 2024)
                    try:
                        parsed_min_year = int(min_year)
                    except (TypeError, ValueError):
                        parsed_min_year = 2024
                    parsed_clock_utc = parsed_clock.astimezone(timezone.utc)
                    if parsed_clock_utc.year < parsed_min_year:
                        failures.append(
                            CheckResult(
                                "Clock",
                                False,
                                f"status report Clock timestamp year {parsed_clock_utc.year} is before {parsed_min_year}",
                            )
                        )
                    generated_at = report.get("generated_at")
                    if isinstance(generated_at, str):
                        try:
                            generated = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
                        except ValueError:
                            generated = None
                        if generated is not None and generated.tzinfo is not None and generated.utcoffset() is not None:
                            drift = abs(
                                (
                                    generated.astimezone(timezone.utc) - parsed_clock_utc
                                ).total_seconds()
                            )
                            if drift > 300.0:
                                failures.append(
                                    CheckResult(
                                        "Clock",
                                        False,
                                        f"status report Clock timestamp differs from generated_at by {drift:.0f}s",
                                    )
                                )
    time_sync = check_rows.get("Time Sync")
    if isinstance(time_sync, dict):
        data = time_sync.get("data")
        if not isinstance(data, dict):
            failures.append(CheckResult("Time Sync", False, "status report Time Sync check has no structured data"))
        elif data.get("is_raspberry_pi") is False and data.get("skipped") is True:
            pass
        elif data.get("is_raspberry_pi") is not True:
            failures.append(CheckResult("Time Sync", False, "status report Time Sync missing Raspberry Pi evidence"))
        elif str(data.get("system_clock_synchronized", "")).strip().lower() != "yes":
            failures.append(
                CheckResult(
                    "Time Sync",
                    False,
                    "status report Time Sync did not report SystemClockSynchronized=yes",
                )
            )
    return failures


def _service_summary_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    failures: list[CheckResult] = []
    services = report.get("services")
    system_services = report.get("system_services")
    if not isinstance(services, dict):
        failures.append(CheckResult("Status Report", False, "status report missing services section"))
    if not isinstance(system_services, dict):
        failures.append(CheckResult("Status Report", False, "status report missing system_services section"))
    if failures:
        return failures
    if not _summary_has_loaded_properties(services):
        failures.append(
            CheckResult(
                "Status Report",
                False,
                "status report systemd user service properties were not loaded",
            )
        )
    config = report.get("config")
    gps_mode = "gpsd"
    if isinstance(config, dict):
        configured_mode = str(config.get("gps_mode", "")).strip()
        if configured_mode in {"gpsd", "serial"}:
            gps_mode = configured_mode
    unit_files = report.get("unit_files")
    derived_checks = _service_readiness_checks(
        services,
        system_services,
        unit_files=unit_files if isinstance(unit_files, dict) else None,
        gps_mode=gps_mode,
    )
    failures.extend(
        CheckResult(check.name, False, f"status report service summary invalid: {check.detail}")
        for check in derived_checks
        if not check.ok
    )
    return failures


def _generated_at_validation_failures(
    generated_at: object,
    *,
    now: Optional[datetime] = None,
) -> list[CheckResult]:
    if not isinstance(generated_at, str) or not generated_at.strip():
        return [CheckResult("Status Report", False, "status report missing generated_at timestamp")]
    try:
        parsed = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
    except ValueError:
        return [CheckResult("Status Report", False, f"status report has invalid generated_at timestamp: {generated_at}")]
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return [CheckResult("Status Report", False, "status report generated_at timestamp must include a timezone")]
    try:
        current = _current_utc(now, label="status report")
    except ValueError as exc:
        return [CheckResult("Status Report", False, str(exc))]
    age_seconds = (current - parsed.astimezone(timezone.utc)).total_seconds()
    if age_seconds < -STATUS_REPORT_FUTURE_TOLERANCE_SECONDS:
        return [
            CheckResult(
                "Status Report",
                False,
                f"status report generated_at timestamp is in the future by {-age_seconds:.0f}s",
            )
        ]
    if age_seconds > STATUS_REPORT_MAX_AGE_SECONDS:
        return [
            CheckResult(
                "Status Report",
                False,
                f"status report generated_at timestamp is stale ({age_seconds:.0f}s old)",
            )
        ]
    return []


def _host_validation_failures(host: object) -> list[CheckResult]:
    if not isinstance(host, dict):
        return [CheckResult("Status Report", False, "status report missing host section")]
    boot_id_value = host.get("boot_id", "")
    if not isinstance(boot_id_value, str):
        return [CheckResult("Status Report", False, "status report missing valid host boot_id")]
    boot_id = boot_id_value.strip()
    if not boot_id or boot_id == "unknown":
        return [CheckResult("Status Report", False, "status report missing valid host boot_id")]
    control_failure = _status_control_character_failure(boot_id, "host boot_id")
    if control_failure:
        return [CheckResult("Status Report", False, control_failure)]
    if not BOOT_ID_RE.fullmatch(boot_id):
        return [CheckResult("Status Report", False, f"status report host boot_id is not a Linux boot_id value: {boot_id}")]
    return []


def _app_validation_failures(app: object) -> list[CheckResult]:
    if not isinstance(app, dict):
        return [CheckResult("Status Report", False, "status report missing app section")]
    source_revision = app.get("source_revision")
    if not isinstance(source_revision, str):
        return [CheckResult("Status Report", False, "status report missing deployed source_revision")]
    source_revision_text = source_revision.strip()
    if not source_revision_text or source_revision_text == "unknown":
        return [CheckResult("Status Report", False, "status report missing deployed source_revision")]
    control_failure = _status_control_character_failure(source_revision_text, "source_revision")
    if control_failure:
        return [CheckResult("Status Report", False, control_failure)]
    if source_revision_text.endswith("-dirty"):
        return [
            CheckResult(
                "Status Report",
                False,
                "status report dirty deployed source_revision is not production-ready",
            )
        ]
    source_revision_path = app.get("source_revision_path", "")
    if not isinstance(source_revision_path, str) or not source_revision_path.strip():
        return [CheckResult("Status Report", False, "status report missing source_revision_path")]
    control_failure = _status_control_character_failure(source_revision_path.strip(), "source_revision_path")
    if control_failure:
        return [CheckResult("Status Report", False, control_failure)]
    if app.get("source_revision_path_is_symlink") is not False:
        return [
            CheckResult(
                "Status Report",
                False,
                "status report source revision path is a symlink or missing symlink status",
            )
        ]
    if app.get("source_revision_directory_is_symlink") is not False:
        return [
            CheckResult(
                "Status Report",
                False,
                "status report source revision directory is a symlink or missing symlink status",
            )
        ]
    if "source_revision_symlink_component" not in app:
        return [
            CheckResult(
                "Status Report",
                False,
                "status report source revision missing source_revision_symlink_component",
            )
        ]
    source_revision_symlink_component = app.get("source_revision_symlink_component", "")
    if not isinstance(source_revision_symlink_component, str):
        return [
            CheckResult(
                "Status Report",
                False,
                "status report source revision missing source_revision_symlink_component",
            )
        ]
    control_failure = _status_control_character_failure(
        source_revision_symlink_component.strip(),
        "source_revision_symlink_component",
    )
    if control_failure:
        return [CheckResult("Status Report", False, control_failure)]
    if source_revision_symlink_component.strip():
        return [CheckResult("Status Report", False, "status report source revision path contains a symlink")]
    source_revision_error_value = app.get("source_revision_error", "")
    if not isinstance(source_revision_error_value, str):
        return [CheckResult("Status Report", False, "status report source_revision_error is not text")]
    source_revision_error = source_revision_error_value.strip()
    control_failure = _status_control_character_failure(source_revision_error, "source_revision_error")
    if control_failure:
        return [CheckResult("Status Report", False, control_failure)]
    if source_revision_error:
        return [
            CheckResult(
                "Status Report",
                False,
                f"status report source revision error: {source_revision_error}",
            )
        ]
    return []


def _config_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    config_path = report.get("config_path")
    if not isinstance(config_path, str) or not config_path.strip():
        return [CheckResult("Config", False, "status report missing config_path")]
    config_path_failure = _status_control_character_failure(config_path, "config_path")
    if config_path_failure:
        return [CheckResult("Config", False, config_path_failure)]
    config_path_text = config_path.strip()
    if not _status_absolute_path(config_path_text):
        return [CheckResult("Config", False, f"status report config_path is not absolute: {config_path}")]
    config = report.get("config")
    if not isinstance(config, dict):
        return [CheckResult("Config", False, "status report missing config section")]
    chart_package_text = str(config.get("chart_package", ""))
    control_failure = _status_control_character_failure(chart_package_text, "config chart_package")
    if control_failure:
        return [CheckResult("Config", False, control_failure)]
    chart_package = chart_package_text.strip().lower()
    if chart_package not in CHART_PACKAGES:
        return [CheckResult("Config", False, f"status report config chart_package is invalid: {chart_package or '<missing>'}")]
    chart_value_text = str(config.get("chart_value", ""))
    control_failure = _status_control_character_failure(chart_value_text, "config chart_value")
    if control_failure:
        return [CheckResult("Config", False, control_failure)]
    chart_value = chart_value_text.strip()
    if chart_package in CHART_PACKAGES_REQUIRING_VALUE and not chart_value:
        return [CheckResult("Config", False, f"status report config chart_value is required for {chart_package}")]
    chart_output_text = str(config.get("chart_output", ""))
    track_output_text = str(config.get("track_output", ""))
    control_failure = _status_control_character_failure(chart_output_text, "config chart_output")
    if control_failure:
        return [CheckResult("Config", False, control_failure)]
    control_failure = _status_control_character_failure(track_output_text, "config track_output")
    if control_failure:
        return [CheckResult("Config", False, control_failure)]
    chart_output = chart_output_text.strip()
    track_output = track_output_text.strip()
    if not _status_absolute_path(chart_output):
        return [CheckResult("Config", False, f"status report config chart_output is not absolute: {chart_output or '<missing>'}")]
    if not _status_absolute_path(track_output):
        return [CheckResult("Config", False, f"status report config track_output is not absolute: {track_output or '<missing>'}")]
    for field in ("extract", "keep_zip", "force"):
        if not isinstance(config.get(field), bool):
            return [CheckResult("Config", False, f"status report config {field} is not boolean")]
    max_chart_age_days = _positive_status_int(config.get("max_chart_age_days"))
    if max_chart_age_days is None:
        return [CheckResult("Config", False, "status report config max_chart_age_days is not positive")]
    min_free_gb = _positive_status_float(config.get("min_free_gb"))
    if min_free_gb is None:
        return [CheckResult("Config", False, "status report config min_free_gb is not positive")]
    gps_mode_text = str(config.get("gps_mode", ""))
    control_failure = _status_control_character_failure(gps_mode_text, "config gps_mode")
    if control_failure:
        return [CheckResult("Config", False, control_failure)]
    gps_mode = gps_mode_text.strip().lower()
    if gps_mode not in {"gpsd", "serial"}:
        return [CheckResult("Config", False, f"status report config gps_mode is invalid: {gps_mode or '<missing>'}")]
    gps_device_text = str(config.get("gps_device", ""))
    control_failure = _status_control_character_failure(gps_device_text, "config gps_device")
    if control_failure:
        return [CheckResult("Config", False, control_failure)]
    gps_device = gps_device_text.strip()
    if not gps_device:
        return [CheckResult("Config", False, "status report config gps_device is empty")]
    if not _stable_status_gps_device_path(gps_device):
        if gps_device.startswith("/dev/ttyUSB") or gps_device.startswith("/dev/ttyACM"):
            return [
                CheckResult(
                    "Config",
                    False,
                    f"status report config gps_device is volatile; use /dev/serial/by-id/... or /dev/serial/by-path/... instead: {gps_device}",
                )
            ]
        return [
            CheckResult(
                "Config",
                False,
                "status report config gps_device must be /dev/serial/by-id/..., /dev/serial/by-path/..., /dev/serial0, /dev/serial1, or /dev/gps",
            )
        ]
    gps_baud = config.get("gps_baud")
    if isinstance(gps_baud, bool) or not isinstance(gps_baud, int) or gps_baud not in GPS_BAUD_RATES:
        return [CheckResult("Config", False, f"status report config gps_baud is invalid: {gps_baud!r}")]
    gpsd_host_text = str(config.get("gpsd_host", ""))
    control_failure = _status_control_character_failure(gpsd_host_text, "config gpsd_host")
    if control_failure:
        return [CheckResult("Config", False, control_failure)]
    gpsd_host = gpsd_host_text.strip()
    if not gpsd_host:
        return [CheckResult("Config", False, "status report config gpsd_host is empty")]
    if gps_mode == "gpsd" and gpsd_host.lower() not in GPSD_LOCAL_HOSTS:
        return [CheckResult("Config", False, f"status report config gpsd_host is not local: {gpsd_host}")]
    gpsd_port = config.get("gpsd_port")
    if isinstance(gpsd_port, bool) or not isinstance(gpsd_port, int) or not (1 <= gpsd_port <= 65535):
        return [CheckResult("Config", False, f"status report config gpsd_port is invalid: {gpsd_port!r}")]
    track_retention_days = _nonnegative_status_int(config.get("track_retention_days"))
    if track_retention_days is None:
        return [CheckResult("Config", False, "status report config track_retention_days is negative or invalid")]
    anchor_radius_meters = _positive_status_float(config.get("anchor_radius_meters"))
    if anchor_radius_meters is None:
        return [CheckResult("Config", False, "status report config anchor_radius_meters is not positive")]
    manifest = report.get("manifest")
    if isinstance(manifest, dict):
        manifest_path = str(manifest.get("path", "")).strip()
        expected_manifest_path = str(Path(chart_output) / MANIFEST_NAME)
        if manifest_path and manifest_path != expected_manifest_path:
            return [
                CheckResult(
                    "Config",
                    False,
                    f"status report manifest path {manifest_path} does not match configured {expected_manifest_path}",
                )
            ]
    track_log = report.get("track_log")
    if isinstance(track_log, dict):
        actual_track_output = str(track_log.get("track_output", "")).strip()
        expected_tracks_dir = str(Path(track_output) / "tracks")
        actual_tracks_dir = str(track_log.get("tracks_dir", "")).strip()
        if actual_track_output and actual_track_output != track_output:
            return [
                CheckResult(
                    "Config",
                    False,
                    f"status report track_log track_output {actual_track_output} does not match configured {track_output}",
                )
            ]
        if actual_tracks_dir and actual_tracks_dir != expected_tracks_dir:
            return [
                CheckResult(
                    "Config",
                    False,
                    f"status report track_log tracks_dir {actual_tracks_dir} does not match configured {expected_tracks_dir}",
                )
            ]
    return []


def _status_control_character_failure(text: str, label: str) -> str:
    if _status_text_has_control_char(text):
        return f"status report {label} contains control characters"
    return ""


def _status_required_text_field(
    summary: dict[str, object],
    field: str,
    missing_detail: str,
    label: str,
    check_name: str,
) -> tuple[str, Optional[CheckResult]]:
    value = summary.get(field, "")
    if not isinstance(value, str) or not value.strip():
        return "", CheckResult(check_name, False, missing_detail)
    text = value.strip()
    control_failure = _status_control_character_failure(text, label)
    if control_failure:
        return "", CheckResult(check_name, False, control_failure)
    return text, None


def _status_text_has_control_char(text: str) -> bool:
    return any(ord(char) < 32 or ord(char) == 127 for char in text)


def _user_validation_failures(user: object) -> list[CheckResult]:
    if not isinstance(user, dict):
        return [CheckResult("User Linger", False, "status report missing user section")]
    name_value = user.get("name", "")
    if not isinstance(name_value, str):
        return [CheckResult("User Linger", False, "status report user name is empty")]
    name = name_value.strip()
    if not name:
        return [CheckResult("User Linger", False, "status report user name is empty")]
    control_failure = _status_control_character_failure(name, "user name")
    if control_failure:
        return [CheckResult("User Linger", False, control_failure)]
    uid = user.get("uid")
    if isinstance(uid, bool) or not isinstance(uid, int) or uid < 0:
        return [CheckResult("User Linger", False, f"status report user uid is invalid: {uid!r}")]
    check = _user_linger_check(user)
    if not check.ok:
        return [CheckResult(check.name, False, f"status report user summary invalid: {check.detail}")]
    return []


def _unit_files_validation_failures(unit_files: object) -> list[CheckResult]:
    if not isinstance(unit_files, dict):
        return [CheckResult("Unit Files", False, "status report missing unit_files section")]
    checks = [
        _unit_file_contains_check(
            unit_files,
            "noaa-navionics.service",
            "Chart Sync Unit File",
            [
                "Type=oneshot",
                "ExecStartPre=%h/.local/share/noaa-navionics/venv/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300",
                "ExecStart=%h/.local/share/noaa-navionics/venv/bin/noaa-navionics sync-charts --config %h/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30",
                "TimeoutStartSec=2h",
                "Restart=on-failure",
                "RestartSec=30min",
                "StartLimitIntervalSec=6h",
                "StartLimitBurst=3",
            ],
        ),
        _unit_file_contains_check(
            unit_files,
            "noaa-navionics.timer",
            "Chart Timer Unit File",
            [
                "OnCalendar=weekly",
                "Persistent=true",
                "RandomizedDelaySec=30min",
            ],
        ),
        _unit_file_contains_check(
            unit_files,
            "noaa-navionics-track.service",
            "Track Logger Unit File",
            [
                "Type=simple",
                "ExecStart=%h/.local/share/noaa-navionics/venv/bin/noaa-navionics log-track --config %h/.config/noaa-navionics/config.ini --rotate-daily",
                "StandardOutput=null",
                "Restart=on-failure",
                "RestartSec=10",
                "TimeoutStopSec=30s",
                "StartLimitIntervalSec=10min",
                "StartLimitBurst=60",
            ],
        ),
        _unit_file_contains_check(
            unit_files,
            "noaa-navionics-preflight.service",
            "Boot Readiness Unit File",
            [
                "Wants=noaa-navionics-track.service",
                "After=noaa-navionics-track.service",
                "Type=oneshot",
                "ExecStart=%h/.local/share/noaa-navionics/venv/bin/noaa-navionics status-report --config %h/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env %h/.config/noaa-navionics/launcher.env --output %h/.cache/noaa-navionics/status.json",
                "TimeoutStartSec=15min",
                "Restart=on-failure",
                "RestartSec=30",
                "StartLimitIntervalSec=30min",
                "StartLimitBurst=60",
            ],
        ),
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
    return [
        CheckResult(check.name, False, f"status report unit file summary invalid: {check.detail}")
        for check in checks
        if not check.ok
    ]


def _launcher_settings_validation_failures(launcher_settings: object) -> list[CheckResult]:
    if not isinstance(launcher_settings, dict):
        return [CheckResult("Launcher Settings", False, "status report missing launcher_settings section")]
    path, failure = _status_required_text_field(
        launcher_settings,
        "path",
        "status report launcher settings path is empty",
        "launcher settings path",
        "Launcher Settings",
    )
    if failure:
        return [failure]
    if not _status_absolute_path(path):
        return [CheckResult("Launcher Settings", False, f"status report launcher settings path is not absolute: {path}")]
    if launcher_settings.get("exists") is not True:
        return [CheckResult("Launcher Settings", False, f"status report launcher settings file does not exist: {path}")]
    if launcher_settings.get("is_symlink") is not False:
        return [
            CheckResult(
                "Launcher Settings",
                False,
                "status report launcher settings path is a symlink or missing symlink status",
            )
        ]
    if launcher_settings.get("directory_is_symlink") is not False:
        return [
            CheckResult(
                "Launcher Settings",
                False,
                "status report launcher settings directory is a symlink or missing symlink status",
            )
        ]
    if "launcher_settings_symlink_component" not in launcher_settings:
        return [
            CheckResult(
                "Launcher Settings",
                False,
                "status report launcher settings missing launcher_settings_symlink_component",
            )
        ]
    symlink_component = launcher_settings.get("launcher_settings_symlink_component", "")
    if not isinstance(symlink_component, str):
        return [CheckResult("Launcher Settings", False, "status report launcher settings symlink component is not text")]
    symlink_component_text = symlink_component.strip()
    control_failure = _status_control_character_failure(
        symlink_component_text,
        "launcher settings symlink component",
    )
    if control_failure:
        return [CheckResult("Launcher Settings", False, control_failure)]
    if symlink_component_text:
        return [CheckResult("Launcher Settings", False, "status report launcher settings path contains a symlink")]
    error_value = launcher_settings.get("error", "")
    if not isinstance(error_value, str):
        return [CheckResult("Launcher Settings", False, "status report launcher settings error is not text")]
    error = error_value.strip()
    control_failure = _status_control_character_failure(error, "launcher settings error")
    if control_failure:
        return [CheckResult("Launcher Settings", False, control_failure)]
    if error:
        return [CheckResult("Launcher Settings", False, f"status report launcher settings error: {error}")]
    values = launcher_settings.get("values")
    if not isinstance(values, dict):
        return [CheckResult("Launcher Settings", False, "status report launcher settings values were not parsed")]

    failures = []
    malformed_lines = launcher_settings.get("malformed_lines", [])
    if isinstance(malformed_lines, list):
        failures.extend(f"malformed launcher settings line {line}" for line in malformed_lines)
    else:
        failures.append("malformed launcher settings lines were not parsed")
    if any(not isinstance(key, str) for key in values):
        failures.append("launcher settings keys are not text")
    unknown_keys = sorted(key for key in values if isinstance(key, str) and key not in LAUNCHER_ENV_KEYS)
    if unknown_keys:
        failures.append("unknown launcher settings key(s): " + ", ".join(unknown_keys))

    def required_positive_integer(key: str) -> None:
        raw_value = values.get(key, "")
        if not isinstance(raw_value, str):
            failures.append(f"{key}=<non-text> expected positive integer")
            return
        value = raw_value.strip()
        control_failure = _status_control_character_failure(value, key)
        if control_failure:
            failures.append(control_failure)
            return
        if not value.isdigit() or int(value) <= 0:
            failures.append(f"{key}={value or '<missing>'} expected positive integer")
            return
        maximum = LAUNCHER_ENV_INTEGER_LIMITS[key]
        if int(value) > maximum:
            failures.append(f"{key}={value} expected at most {maximum}")

    def required_nonnegative_integer(key: str) -> None:
        raw_value = values.get(key, "")
        if not isinstance(raw_value, str):
            failures.append(f"{key}=<non-text> expected non-negative integer")
            return
        value = raw_value.strip()
        control_failure = _status_control_character_failure(value, key)
        if control_failure:
            failures.append(control_failure)
            return
        if not value.isdigit() or int(value) < 0:
            failures.append(f"{key}={value or '<missing>'} expected non-negative integer")
            return
        maximum = LAUNCHER_ENV_INTEGER_LIMITS[key]
        if int(value) > maximum:
            failures.append(f"{key}={value} expected at most {maximum}")

    required_positive_integer("NOAA_NAVIONICS_GPS_SECONDS")
    required_positive_integer("NOAA_NAVIONICS_READINESS_ATTEMPTS")
    required_nonnegative_integer("NOAA_NAVIONICS_READINESS_RETRY_DELAY")
    required_nonnegative_integer("NOAA_NAVIONICS_WARNING_SECONDS")
    required_nonnegative_integer("NOAA_NAVIONICS_OPENCPN_RESTARTS")
    required_nonnegative_integer("NOAA_NAVIONICS_OPENCPN_RESTART_DELAY")
    fail_open_value = values.get("NOAA_NAVIONICS_START_ON_FAILED_READINESS", "")
    if not isinstance(fail_open_value, str):
        failures.append("NOAA_NAVIONICS_START_ON_FAILED_READINESS=<non-text> expected explicit no")
        fail_open = ""
    else:
        fail_open = fail_open_value.strip().lower()
        control_failure = _status_control_character_failure(fail_open, "NOAA_NAVIONICS_START_ON_FAILED_READINESS")
        if control_failure:
            failures.append(control_failure)
    if fail_open in {"1", "yes", "true", "on"}:
        failures.append("status report launcher settings enable NOAA_NAVIONICS_START_ON_FAILED_READINESS")
    elif fail_open not in {"0", "no", "false", "off"}:
        failures.append(
            f"NOAA_NAVIONICS_START_ON_FAILED_READINESS={fail_open or '<missing>'} expected explicit no"
        )
    if failures:
        return [CheckResult("Launcher Settings", False, f"status report launcher settings invalid: {'; '.join(failures)}")]
    return []


def _opencpn_config_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    opencpn_config = report.get("opencpn_config")
    if not isinstance(opencpn_config, dict):
        return [CheckResult("OpenCPN Config", False, "status report missing opencpn_config section")]
    path, failure = _status_required_text_field(
        opencpn_config,
        "path",
        "status report OpenCPN config path is empty",
        "OpenCPN config path",
        "OpenCPN Config",
    )
    if failure:
        return [failure]
    if not _status_absolute_path(path):
        return [CheckResult("OpenCPN Config", False, f"status report OpenCPN config path is not absolute: {path}")]
    if opencpn_config.get("exists") is not True:
        return [CheckResult("OpenCPN Config", False, f"status report OpenCPN config does not exist: {path}")]
    if opencpn_config.get("is_symlink") is not False:
        return [
            CheckResult(
                "OpenCPN Config",
                False,
                "status report OpenCPN config is a symlink or missing symlink status",
            )
        ]
    if opencpn_config.get("directory_is_symlink") is not False:
        return [
            CheckResult(
                "OpenCPN Config",
                False,
                "status report OpenCPN config directory is a symlink or missing symlink status",
            )
        ]
    if "config_symlink_component" not in opencpn_config:
        return [CheckResult("OpenCPN Config", False, "status report OpenCPN config missing config_symlink_component")]
    config_symlink_component = opencpn_config.get("config_symlink_component", "")
    if not isinstance(config_symlink_component, str):
        return [CheckResult("OpenCPN Config", False, "status report OpenCPN config config_symlink_component is not text")]
    config_symlink_component_text = config_symlink_component.strip()
    control_failure = _status_control_character_failure(
        config_symlink_component_text,
        "OpenCPN config config_symlink_component",
    )
    if control_failure:
        return [CheckResult("OpenCPN Config", False, control_failure)]
    if config_symlink_component_text:
        return [CheckResult("OpenCPN Config", False, "status report OpenCPN config path contains a symlink")]
    error_value = opencpn_config.get("error", "")
    if not isinstance(error_value, str):
        return [CheckResult("OpenCPN Config", False, "status report OpenCPN config error is not text")]
    error = error_value.strip()
    control_failure = _status_control_character_failure(error, "OpenCPN config error")
    if control_failure:
        return [CheckResult("OpenCPN Config", False, control_failure)]
    if error:
        return [CheckResult("OpenCPN Config", False, f"status report OpenCPN config error: {error}")]

    chart_directories = opencpn_config.get("chart_directories")
    data_connections = opencpn_config.get("data_connections")
    if not isinstance(chart_directories, list) or any(not isinstance(value, str) for value in chart_directories):
        return [CheckResult("OpenCPN Config", False, "status report OpenCPN chart directories were not parsed")]
    if any(_status_text_has_control_char(value) for value in chart_directories):
        return [CheckResult("OpenCPN Config", False, "status report OpenCPN chart directories contain control characters")]
    if not isinstance(data_connections, list) or any(not isinstance(value, str) for value in data_connections):
        return [CheckResult("OpenCPN Config", False, "status report OpenCPN data connections were not parsed")]

    config = report.get("config")
    if not isinstance(config, dict):
        return []
    chart_output = str(config.get("chart_output", "")).strip()
    if chart_output:
        normalized_chart_output = str(Path(chart_output).expanduser().resolve(strict=False))
        normalized_chart_directories = [
            str(Path(value).expanduser().resolve(strict=False)) for value in chart_directories
        ]
        if normalized_chart_output not in normalized_chart_directories:
            return [
                CheckResult(
                    "OpenCPN Config",
                    False,
                    f"status report OpenCPN config does not list configured chart output {normalized_chart_output}",
                )
            ]
    gps_mode = str(config.get("gps_mode", "")).strip().lower()
    if gps_mode == "gpsd":
        expected_host = normalize_gpsd_host(str(config.get("gpsd_host", "")).strip())
        expected_port = config.get("gpsd_port")
        enabled_gpsd = enabled_gpsd_connections_from_values(data_connections)
        expected_connection = any(
            connection.host == expected_host and connection.port == expected_port for connection in enabled_gpsd
        )
        if not expected_connection:
            return [
                CheckResult(
                    "OpenCPN Config",
                    False,
                    f"status report OpenCPN config does not contain enabled GPSD connection "
                    f"{expected_host}:{expected_port}",
                )
            ]
        unexpected = [
            connection
            for connection in enabled_gpsd
            if connection.host != expected_host or connection.port != expected_port
        ]
        if unexpected:
            endpoints = ", ".join(
                f"{connection.host}:{connection.port if connection.port is not None else '<invalid-port>'}"
                for connection in unexpected
            )
            return [
                CheckResult(
                    "OpenCPN Config",
                    False,
                    f"status report OpenCPN config contains unexpected enabled GPSD connections: {endpoints}",
                )
            ]
    return []


def _desktop_validation_failures(report: dict[str, object]) -> list[CheckResult]:
    desktop = report.get("desktop")
    if not isinstance(desktop, dict):
        return [CheckResult("Desktop Startup", False, "status report missing desktop section")]
    failures = []

    def required_text(summary: dict[str, object], field: str, missing_detail: str, label: str) -> str:
        value, failure = _status_required_text_field(summary, field, missing_detail, label, "Desktop Startup")
        if failure:
            failures.append(failure.detail)
        return value

    def optional_text(summary: dict[str, object], field: str, not_text_detail: str, label: str) -> str:
        value = summary.get(field, "")
        if not isinstance(value, str):
            failures.append(not_text_detail)
            return ""
        text = value.strip()
        control_failure = _status_control_character_failure(text, label)
        if control_failure:
            failures.append(control_failure)
            return ""
        return text

    autostart = desktop.get("autostart")
    if not isinstance(autostart, dict):
        failures.append("status report missing desktop autostart section")
    else:
        path = required_text(
            autostart,
            "path",
            "status report desktop autostart path is empty",
            "desktop autostart path",
        )
        if path and not _status_absolute_path(path):
            failures.append(f"status report desktop autostart path is not absolute: {path}")
        if autostart.get("exists") is not True:
            failures.append(f"status report desktop autostart does not exist: {path or '<missing>'}")
        if autostart.get("is_symlink") is not False:
            failures.append("status report desktop autostart path is a symlink or missing symlink status")
        if autostart.get("directory_is_symlink") is not False:
            failures.append("status report desktop autostart directory is a symlink or missing symlink status")
        if "path_symlink_component" not in autostart:
            failures.append("status report desktop autostart missing path_symlink_component")
        else:
            symlink_component = optional_text(
                autostart,
                "path_symlink_component",
                "status report desktop autostart path_symlink_component is not text",
                "desktop autostart path_symlink_component",
            )
            if symlink_component:
                failures.append("status report desktop autostart path contains a symlink")
        error = optional_text(
            autostart,
            "error",
            "status report desktop autostart error is not text",
            "desktop autostart error",
        )
        if error:
            failures.append(f"status report desktop autostart error: {error}")
        failures.extend(
            _key_value_file_integrity_failures(
                autostart,
                label="desktop autostart",
                expected_uid=os.getuid(),
            )
        )
        values = autostart.get("values")
        if not isinstance(values, dict):
            failures.append("status report desktop autostart values were not parsed")
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
            if str(values.get("Hidden", "")).strip().lower() == "true":
                failures.append("desktop autostart Hidden=true disables chartplotter startup")

    status_launcher = desktop.get("status_launcher")
    if not isinstance(status_launcher, dict):
        failures.append("status report missing status GUI desktop launcher section")
    else:
        path = required_text(
            status_launcher,
            "path",
            "status report status GUI desktop launcher path is empty",
            "status GUI desktop launcher path",
        )
        if path and not _status_absolute_path(path):
            failures.append(f"status report status GUI desktop launcher path is not absolute: {path}")
        if status_launcher.get("exists") is not True:
            failures.append(f"status report status GUI desktop launcher does not exist: {path or '<missing>'}")
        if status_launcher.get("is_symlink") is not False:
            failures.append("status report status GUI desktop launcher path is a symlink or missing symlink status")
        if status_launcher.get("directory_is_symlink") is not False:
            failures.append("status report status GUI desktop launcher directory is a symlink or missing symlink status")
        if "path_symlink_component" not in status_launcher:
            failures.append("status report status GUI desktop launcher missing path_symlink_component")
        else:
            symlink_component = optional_text(
                status_launcher,
                "path_symlink_component",
                "status report status GUI desktop launcher path_symlink_component is not text",
                "status GUI desktop launcher path_symlink_component",
            )
            if symlink_component:
                failures.append("status report status GUI desktop launcher path contains a symlink")
        error = optional_text(
            status_launcher,
            "error",
            "status report status GUI desktop launcher error is not text",
            "status GUI desktop launcher error",
        )
        if error:
            failures.append(f"status report status GUI desktop launcher error: {error}")
        failures.extend(
            _key_value_file_integrity_failures(
                status_launcher,
                label="status GUI desktop launcher",
                expected_uid=os.getuid(),
            )
        )
        failures.extend(_user_executable_mode_failures(status_launcher, label="status GUI desktop launcher"))
        values = status_launcher.get("values")
        if not isinstance(values, dict):
            failures.append("status report status GUI desktop launcher values were not parsed")
        else:
            expected_values = {
                "Type": "Application",
                "Name": "NOAA Navionics Status",
                "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-status-gui"',
                "Terminal": "false",
            }
            for key, expected in expected_values.items():
                actual = str(values.get(key, "")).strip()
                if actual != expected:
                    failures.append(f"status GUI desktop launcher {key}={actual or '<missing>'} expected {expected}")
            if str(values.get("Hidden", "")).strip().lower() == "true":
                failures.append("status GUI desktop launcher Hidden=true hides the readiness panel")
            if str(values.get("X-GNOME-Autostart-enabled", "")).strip().lower() == "true":
                failures.append("status GUI desktop launcher must not be configured for autostart")

    graphical_target = str(desktop.get("graphical_target", "")).strip()
    if graphical_target != "graphical.target":
        failures.append(f"status report graphical target is {graphical_target or '<missing>'}")
    lightdm_enabled = str(desktop.get("lightdm_enabled", "")).strip()
    if lightdm_enabled != "enabled":
        failures.append(f"status report LightDM enabled state is {lightdm_enabled or '<missing>'}")

    lightdm = desktop.get("lightdm_autologin")
    if not isinstance(lightdm, dict):
        failures.append("status report missing LightDM autologin section")
    else:
        path = required_text(
            lightdm,
            "path",
            "status report LightDM autologin config path is empty",
            "LightDM autologin config path",
        )
        if path and not _status_absolute_path(path):
            failures.append(f"status report LightDM autologin config path is not absolute: {path}")
        if lightdm.get("exists") is not True:
            failures.append(f"status report LightDM autologin config does not exist: {path or '<missing>'}")
        if lightdm.get("is_symlink") is not False:
            failures.append("status report LightDM autologin config path is a symlink or missing symlink status")
        if lightdm.get("directory_is_symlink") is not False:
            failures.append("status report LightDM autologin config directory is a symlink or missing symlink status")
        if "path_symlink_component" not in lightdm:
            failures.append("status report LightDM autologin config missing path_symlink_component")
        else:
            symlink_component = optional_text(
                lightdm,
                "path_symlink_component",
                "status report LightDM autologin config path_symlink_component is not text",
                "LightDM autologin config path_symlink_component",
            )
            if symlink_component:
                failures.append("status report LightDM autologin config path contains a symlink")
        error = optional_text(
            lightdm,
            "error",
            "status report LightDM autologin config error is not text",
            "LightDM autologin config error",
        )
        if error:
            failures.append(f"status report LightDM autologin config error: {error}")
        failures.extend(
            _key_value_file_integrity_failures(
                lightdm,
                label="LightDM autologin config",
                expected_uid=0,
            )
        )
        sections = lightdm.get("sections")
        if not isinstance(sections, list):
            failures.append("status report LightDM autologin sections were not parsed")
        elif "Seat:*" not in {str(section) for section in sections}:
            failures.append("LightDM autologin config missing [Seat:*] section")
        values = lightdm.get("values")
        if not isinstance(values, dict):
            failures.append("status report LightDM autologin values were not parsed")
        else:
            user = report.get("user")
            expected_user = str(user.get("name", "")).strip() if isinstance(user, dict) else ""
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
    mob_launcher = desktop.get("mob_launcher")
    if not isinstance(mob_launcher, dict):
        failures.append("status report missing MOB desktop launcher section")
    else:
        path = required_text(
            mob_launcher,
            "path",
            "status report MOB desktop launcher path is empty",
            "MOB desktop launcher path",
        )
        if path and not _status_absolute_path(path):
            failures.append(f"status report MOB desktop launcher path is not absolute: {path}")
        if mob_launcher.get("exists") is not True:
            failures.append(f"status report MOB desktop launcher does not exist: {path or '<missing>'}")
        if mob_launcher.get("is_symlink") is not False:
            failures.append("status report MOB desktop launcher path is a symlink or missing symlink status")
        if mob_launcher.get("directory_is_symlink") is not False:
            failures.append("status report MOB desktop launcher directory is a symlink or missing symlink status")
        if "path_symlink_component" not in mob_launcher:
            failures.append("status report MOB desktop launcher missing path_symlink_component")
        else:
            symlink_component = optional_text(
                mob_launcher,
                "path_symlink_component",
                "status report MOB desktop launcher path_symlink_component is not text",
                "MOB desktop launcher path_symlink_component",
            )
            if symlink_component:
                failures.append("status report MOB desktop launcher path contains a symlink")
        error = optional_text(
            mob_launcher,
            "error",
            "status report MOB desktop launcher error is not text",
            "MOB desktop launcher error",
        )
        if error:
            failures.append(f"status report MOB desktop launcher error: {error}")
        failures.extend(
            _key_value_file_integrity_failures(
                mob_launcher,
                label="MOB desktop launcher",
                expected_uid=os.getuid(),
            )
        )
        failures.extend(_user_executable_mode_failures(mob_launcher, label="MOB desktop launcher"))
        values = mob_launcher.get("values")
        if not isinstance(values, dict):
            failures.append("status report MOB desktop launcher values were not parsed")
        else:
            expected_values = {
                "Type": "Application",
                "Name": "NOAA Navionics MOB",
                "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics mob; printf \'\\nPress Enter to close...\'; read _"',
                "Terminal": "true",
            }
            for key, expected in expected_values.items():
                actual = str(values.get(key, "")).strip()
                if actual != expected:
                    failures.append(f"MOB desktop launcher {key}={actual or '<missing>'} expected {expected}")
            if str(values.get("Hidden", "")).strip().lower() == "true":
                failures.append("MOB desktop launcher Hidden=true hides the emergency launcher")
            if str(values.get("X-GNOME-Autostart-enabled", "")).strip().lower() == "true":
                failures.append("MOB desktop launcher must not be configured for autostart")
    if failures:
        return [
            CheckResult(
                "Desktop Startup",
                False,
                "status report desktop summary invalid: " + "; ".join(failures),
            )
        ]
    return []


def _manifest_validation_failures(manifest: object) -> list[CheckResult]:
    if not isinstance(manifest, dict):
        return [CheckResult("Chart Manifest", False, "status report missing manifest section")]
    path, failure = _status_required_text_field(
        manifest,
        "path",
        "status report manifest path is empty",
        "manifest path",
        "Chart Manifest",
    )
    if failure:
        return [failure]
    if manifest.get("exists") is not True:
        return [CheckResult("Chart Manifest", False, "status report manifest does not exist")]
    if manifest.get("is_symlink") is not False:
        return [
            CheckResult(
                "Chart Manifest",
                False,
                "status report manifest path is a symlink or missing symlink status",
            )
        ]
    if manifest.get("directory_is_symlink") is not False:
        return [
            CheckResult(
                "Chart Manifest",
                False,
                "status report manifest directory is a symlink or missing symlink status",
            )
        ]
    for field, detail in (
        ("chart_storage_symlink_component", "status report manifest missing chart_storage_symlink_component"),
        ("manifest_symlink_component", "status report manifest missing manifest_symlink_component"),
    ):
        if field not in manifest:
            return [CheckResult("Chart Manifest", False, detail)]
        value = manifest.get(field, "")
        if not isinstance(value, str):
            return [CheckResult("Chart Manifest", False, f"status report manifest {field} is not text")]
        value_text = value.strip()
        control_failure = _status_control_character_failure(value_text, f"manifest {field}")
        if control_failure:
            return [CheckResult("Chart Manifest", False, control_failure)]
        if value_text:
            return [CheckResult("Chart Manifest", False, "status report manifest path contains a symlink")]
    manifest_error_value = manifest.get("error", "")
    if not isinstance(manifest_error_value, str):
        return [CheckResult("Chart Manifest", False, "status report manifest error is not text")]
    manifest_error = manifest_error_value.strip()
    control_failure = _status_control_character_failure(manifest_error, "manifest error")
    if control_failure:
        return [CheckResult("Chart Manifest", False, control_failure)]
    if manifest_error:
        return [CheckResult("Chart Manifest", False, f"status report manifest error: {manifest_error}")]
    required_text_fields = {
        "created_at": "manifest created_at",
        "created_at_source": "manifest created_at_source",
        "package": "manifest package",
        "package_filename": "manifest package_filename",
        "url": "manifest url",
        "download_path": "manifest download path",
        "download_url": "manifest download_url",
        "sha256": "manifest sha256",
        "extract_path": "manifest extract path",
    }
    required_text: dict[str, str] = {}
    for field, label in required_text_fields.items():
        value, failure = _status_required_text_field(
            manifest,
            field,
            f"status report manifest missing {field}",
            label,
            "Chart Manifest",
        )
        if failure:
            return [failure]
        required_text[field] = value
    download_path_text = required_text["download_path"]
    extract_path_text = required_text["extract_path"]
    if not _status_absolute_path(path):
        return [CheckResult("Chart Manifest", False, "status report manifest path is not absolute")]
    if not _status_absolute_path(download_path_text):
        return [CheckResult("Chart Manifest", False, "status report manifest download path is not absolute")]
    if not _status_absolute_path(extract_path_text):
        return [CheckResult("Chart Manifest", False, "status report manifest extract path is not absolute")]
    created_at_source = required_text["created_at_source"]
    if created_at_source not in {"download", "previous-manifest"}:
        return [
            CheckResult(
                "Chart Manifest",
                False,
                f"status report manifest created_at_source {created_at_source} is not verified",
            )
        ]
    if manifest.get("download_path_is_symlink") is not False:
        return [
            CheckResult(
                "Chart Manifest",
                False,
                "status report manifest download path is a symlink or missing symlink status",
            )
        ]
    if "download_path_symlink_component" not in manifest:
        return [CheckResult("Chart Manifest", False, "status report manifest missing download_path_symlink_component")]
    download_path_symlink_component = manifest.get("download_path_symlink_component", "")
    if not isinstance(download_path_symlink_component, str):
        return [CheckResult("Chart Manifest", False, "status report manifest download_path_symlink_component is not text")]
    download_path_symlink_component_text = download_path_symlink_component.strip()
    control_failure = _status_control_character_failure(
        download_path_symlink_component_text,
        "manifest download_path_symlink_component",
    )
    if control_failure:
        return [CheckResult("Chart Manifest", False, control_failure)]
    if download_path_symlink_component_text:
        return [CheckResult("Chart Manifest", False, "status report manifest download path contains a symlink")]
    if manifest.get("extract_path_is_symlink") is not False:
        return [
            CheckResult(
                "Chart Manifest",
                False,
                "status report manifest extract path is a symlink or missing symlink status",
            )
        ]
    if "extract_path_symlink_component" not in manifest:
        return [CheckResult("Chart Manifest", False, "status report manifest missing extract_path_symlink_component")]
    extract_path_symlink_component = manifest.get("extract_path_symlink_component", "")
    if not isinstance(extract_path_symlink_component, str):
        return [CheckResult("Chart Manifest", False, "status report manifest extract_path_symlink_component is not text")]
    extract_path_symlink_component_text = extract_path_symlink_component.strip()
    control_failure = _status_control_character_failure(
        extract_path_symlink_component_text,
        "manifest extract_path_symlink_component",
    )
    if control_failure:
        return [CheckResult("Chart Manifest", False, control_failure)]
    if extract_path_symlink_component_text:
        return [CheckResult("Chart Manifest", False, "status report manifest extract path contains a symlink")]
    download_path_error_value = manifest.get("download_path_error", "")
    if not isinstance(download_path_error_value, str):
        return [CheckResult("Chart Manifest", False, "status report manifest download_path_error is not text")]
    download_path_error = download_path_error_value.strip()
    control_failure = _status_control_character_failure(download_path_error, "manifest download_path_error")
    if control_failure:
        return [CheckResult("Chart Manifest", False, control_failure)]
    if download_path_error:
        return [CheckResult("Chart Manifest", False, f"status report manifest download path error: {download_path_error}")]
    extract_path_error_value = manifest.get("extract_path_error", "")
    if not isinstance(extract_path_error_value, str):
        return [CheckResult("Chart Manifest", False, "status report manifest extract_path_error is not text")]
    extract_path_error = extract_path_error_value.strip()
    control_failure = _status_control_character_failure(extract_path_error, "manifest extract_path_error")
    if control_failure:
        return [CheckResult("Chart Manifest", False, control_failure)]
    if extract_path_error:
        return [CheckResult("Chart Manifest", False, f"status report manifest extract path error: {extract_path_error}")]
    download_bytes = _positive_status_int(manifest.get("download_bytes"))
    enc_cell_count = _positive_status_int(manifest.get("enc_cell_count"))
    actual_enc_cell_count = _positive_status_int(manifest.get("actual_enc_cell_count"))
    if download_bytes is None:
        return [CheckResult("Chart Manifest", False, "status report manifest download byte count is not positive")]
    if enc_cell_count is None:
        return [CheckResult("Chart Manifest", False, "status report manifest has no ENC cells")]
    if actual_enc_cell_count is None:
        return [CheckResult("Chart Manifest", False, "status report manifest actual ENC cell count is not positive")]
    if actual_enc_cell_count != enc_cell_count:
        return [
            CheckResult(
                "Chart Manifest",
                False,
                "status report manifest actual_enc_cell_count does not match enc_cell_count",
            )
        ]
    return []


def _gps_fix_validation_failures(
    report: dict[str, object],
    *,
    now: Optional[datetime] = None,
) -> list[CheckResult]:
    gps_fix = report.get("gps_fix")
    if not isinstance(gps_fix, dict):
        return [CheckResult("GPS Fix", False, "status report missing gps_fix section")]
    if not isinstance(gps_fix.get("ok"), bool):
        return [CheckResult("GPS Fix", False, "status report gps_fix ok is not boolean")]
    if gps_fix.get("ok") is not True:
        detail_value = gps_fix.get("detail", "<missing detail>")
        if not isinstance(detail_value, str):
            return [CheckResult("GPS Fix", False, "status report gps_fix detail is not text")]
        detail = detail_value.strip() or "<missing detail>"
        control_failure = _status_control_character_failure(detail, "gps_fix detail")
        if control_failure:
            return [CheckResult("GPS Fix", False, control_failure)]
        return [CheckResult("GPS Fix", False, f"status report gps_fix is not ok: {detail}")]
    source, failure = _status_required_text_field(
        gps_fix,
        "source",
        "status report gps_fix source is missing",
        "gps_fix source",
        "GPS Fix",
    )
    if failure:
        return [failure]
    config = report.get("config")
    gps_mode = str(config.get("gps_mode", "")).strip().lower() if isinstance(config, dict) else ""
    expected_source = "GPS" if gps_mode == "serial" else "GPSD"
    if source != expected_source:
        return [CheckResult("GPS Fix", False, f"status report gps_fix source {source or '<missing>'} is not {expected_source}")]
    latitude = _finite_gps_fix_float(gps_fix.get("latitude"))
    longitude = _finite_gps_fix_float(gps_fix.get("longitude"))
    if latitude is None or longitude is None:
        return [CheckResult("GPS Fix", False, "status report gps_fix has non-numeric coordinates")]
    if not (-90.0 <= latitude <= 90.0):
        return [CheckResult("GPS Fix", False, f"status report gps_fix latitude is outside -90..90: {latitude}")]
    if not (-180.0 <= longitude <= 180.0):
        return [CheckResult("GPS Fix", False, f"status report gps_fix longitude is outside -180..180: {longitude}")]
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        return [CheckResult("GPS Fix", False, "status report gps_fix coordinates are invalid 0,0")]
    timestamp = _parse_gps_fix_timestamp(gps_fix.get("timestamp"))
    if timestamp is None:
        return [CheckResult("GPS Fix", False, "status report gps_fix has no valid timestamp")]
    try:
        current = _current_utc(now, label="status report gps_fix")
    except ValueError as exc:
        return [CheckResult("GPS Fix", False, str(exc))]
    age_seconds = (current - timestamp).total_seconds()
    if age_seconds < -STATUS_REPORT_FUTURE_TOLERANCE_SECONDS:
        return [CheckResult("GPS Fix", False, f"status report gps_fix timestamp is in the future by {-age_seconds:.0f}s")]
    if age_seconds > STATUS_REPORT_MAX_AGE_SECONDS:
        return [CheckResult("GPS Fix", False, f"status report gps_fix timestamp is stale ({age_seconds:.0f}s old)")]
    reported_age_seconds = _finite_gps_fix_float(gps_fix.get("age_seconds"))
    if reported_age_seconds is None:
        return [CheckResult("GPS Fix", False, "status report gps_fix age_seconds is not numeric")]
    if reported_age_seconds < 0.0:
        return [CheckResult("GPS Fix", False, f"status report gps_fix age_seconds is negative: {reported_age_seconds:g}")]
    if reported_age_seconds > STATUS_REPORT_MAX_AGE_SECONDS:
        return [CheckResult("GPS Fix", False, f"status report gps_fix age_seconds is stale: {reported_age_seconds:g}s")]
    if abs(reported_age_seconds - age_seconds) > STATUS_REPORT_FUTURE_TOLERANCE_SECONDS:
        return [
            CheckResult(
                "GPS Fix",
                False,
                f"status report gps_fix age_seconds {reported_age_seconds:g} is inconsistent with timestamp age {age_seconds:g}",
            )
        ]
    satellites = gps_fix.get("satellites")
    hdop = gps_fix.get("hdop")
    if satellites is None and hdop is None:
        return [CheckResult("GPS Fix", False, "status report gps_fix has no satellite or HDOP quality fields")]
    if satellites is not None and (isinstance(satellites, bool) or not isinstance(satellites, int) or satellites < 4):
        return [CheckResult("GPS Fix", False, f"status report gps_fix satellites is weak or invalid: {satellites!r}")]
    parsed_hdop = _finite_gps_fix_float(hdop)
    if hdop is not None and (parsed_hdop is None or parsed_hdop < 0.0 or parsed_hdop > 5.0):
        return [CheckResult("GPS Fix", False, f"status report gps_fix hdop is weak or invalid: {hdop!r}")]
    return []


def _track_log_validation_failures(track_log: object, *, now: Optional[datetime] = None) -> list[CheckResult]:
    if not isinstance(track_log, dict):
        return [CheckResult("Track Log", False, "status report missing track_log section")]
    track_output, failure = _status_required_text_field(
        track_log,
        "track_output",
        "status report track_log track_output is not absolute",
        "track_log track_output",
        "Track Log",
    )
    if failure:
        return [failure]
    tracks_dir, failure = _status_required_text_field(
        track_log,
        "tracks_dir",
        "status report track_log tracks_dir is not absolute",
        "track_log tracks_dir",
        "Track Log",
    )
    if failure:
        return [failure]
    latest_path_value = track_log.get("latest_path", "")
    if not isinstance(latest_path_value, str):
        return [CheckResult("Track Log", False, "status report track_log has no latest_path")]
    latest_path = latest_path_value.strip()
    control_failure = _status_control_character_failure(latest_path, "track_log latest_path")
    if control_failure:
        return [CheckResult("Track Log", False, control_failure)]
    if not _status_absolute_path(track_output):
        return [CheckResult("Track Log", False, "status report track_log track_output is not absolute")]
    if not _status_absolute_path(tracks_dir):
        return [CheckResult("Track Log", False, "status report track_log tracks_dir is not absolute")]
    if _normalize_status_path(tracks_dir) != _normalize_status_path(str(Path(track_output) / "tracks")):
        return [CheckResult("Track Log", False, "status report track_log tracks_dir does not match track_output")]
    if track_log.get("track_output_is_symlink") is not False:
        return [CheckResult("Track Log", False, "status report track_log track_output is a symlink or missing symlink status")]
    if "track_storage_symlink_component" not in track_log:
        return [CheckResult("Track Log", False, "status report track_log missing track_storage_symlink_component")]
    track_storage_symlink_component = track_log.get("track_storage_symlink_component", "")
    if not isinstance(track_storage_symlink_component, str):
        return [CheckResult("Track Log", False, "status report track_log track_storage_symlink_component is not text")]
    track_storage_symlink_component_text = track_storage_symlink_component.strip()
    control_failure = _status_control_character_failure(
        track_storage_symlink_component_text,
        "track_log track_storage_symlink_component",
    )
    if control_failure:
        return [CheckResult("Track Log", False, control_failure)]
    if track_storage_symlink_component_text:
        return [CheckResult("Track Log", False, "status report track_log storage path contains a symlink")]
    if not isinstance(track_log.get("ok"), bool):
        return [CheckResult("Track Log", False, "status report track_log ok is not boolean")]
    if track_log.get("ok") is not True:
        detail_value = track_log.get("detail", "<missing detail>")
        if not isinstance(detail_value, str):
            return [CheckResult("Track Log", False, "status report track_log detail is not text")]
        detail = detail_value.strip() or "<missing detail>"
        control_failure = _status_control_character_failure(detail, "track_log detail")
        if control_failure:
            return [CheckResult("Track Log", False, control_failure)]
        return [CheckResult("Track Log", False, f"status report track_log is not ok: {detail}")]
    if not latest_path:
        return [CheckResult("Track Log", False, "status report track_log has no latest_path")]
    if not _status_absolute_path(latest_path):
        return [CheckResult("Track Log", False, "status report track_log latest_path is not absolute")]
    if not _status_path_under(latest_path, tracks_dir):
        return [CheckResult("Track Log", False, "status report track_log latest_path is not under tracks_dir")]
    latest_name = Path(latest_path).name
    if not latest_name.startswith("track-") or Path(latest_name).suffix.lower() != ".gpx":
        return [CheckResult("Track Log", False, "status report track_log latest_path is not a track-*.gpx file")]
    tracks_mode = _status_mode_value(track_log.get("tracks_mode"))
    if tracks_mode is None:
        return [CheckResult("Track Log", False, "status report track_log tracks_mode is missing or invalid")]
    if tracks_mode & 0o077:
        return [CheckResult("Track Log", False, f"status report track_log tracks_mode {tracks_mode:04o} is not private")]
    latest_mode = _status_mode_value(track_log.get("latest_mode"))
    if latest_mode is None:
        return [CheckResult("Track Log", False, "status report track_log latest_mode is missing or invalid")]
    if latest_mode & 0o077:
        return [CheckResult("Track Log", False, f"status report track_log latest_mode {latest_mode:04o} is not private")]
    latitude = _finite_gps_fix_float(track_log.get("latest_latitude"))
    longitude = _finite_gps_fix_float(track_log.get("latest_longitude"))
    age_seconds = _finite_gps_fix_float(track_log.get("age_seconds"))
    if latitude is None or longitude is None:
        return [CheckResult("Track Log", False, "status report track_log has non-numeric latest coordinates")]
    if age_seconds is None:
        return [CheckResult("Track Log", False, "status report track_log age_seconds is not numeric")]
    latest_time = _parse_gps_fix_timestamp(track_log.get("latest_time"))
    if latest_time is None:
        return [CheckResult("Track Log", False, "status report track_log has no valid latest_time")]
    try:
        current = _current_utc(now, label="status report track_log")
    except ValueError as exc:
        return [CheckResult("Track Log", False, str(exc))]
    timestamp_age_seconds = (current - latest_time).total_seconds()
    if timestamp_age_seconds < -STATUS_REPORT_FUTURE_TOLERANCE_SECONDS:
        return [
            CheckResult(
                "Track Log",
                False,
                f"status report track_log latest_time is in the future by {-timestamp_age_seconds:.0f}s",
            )
        ]
    if timestamp_age_seconds > STATUS_REPORT_MAX_AGE_SECONDS:
        return [
            CheckResult(
                "Track Log",
                False,
                f"status report track_log latest_time is stale ({timestamp_age_seconds:.0f}s old)",
            )
        ]
    if not (-90.0 <= latitude <= 90.0):
        return [CheckResult("Track Log", False, f"status report track_log latest_latitude is outside -90..90: {latitude}")]
    if not (-180.0 <= longitude <= 180.0):
        return [CheckResult("Track Log", False, f"status report track_log latest_longitude is outside -180..180: {longitude}")]
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        return [CheckResult("Track Log", False, "status report track_log latest coordinates are invalid 0,0")]
    if age_seconds < 0.0:
        return [CheckResult("Track Log", False, f"status report track_log age_seconds is negative: {age_seconds:g}")]
    if age_seconds > STATUS_REPORT_MAX_AGE_SECONDS:
        return [CheckResult("Track Log", False, f"status report track_log age_seconds is stale: {age_seconds:g}s")]
    if abs(age_seconds - timestamp_age_seconds) > STATUS_REPORT_FUTURE_TOLERANCE_SECONDS:
        return [
            CheckResult(
                "Track Log",
                False,
                f"status report track_log age_seconds {age_seconds:g} is inconsistent with latest_time age {timestamp_age_seconds:g}",
            )
        ]
    satellites = track_log.get("latest_satellites")
    hdop = track_log.get("latest_hdop")
    if satellites is None and hdop is None:
        return [CheckResult("Track Log", False, "status report track_log has no latest satellite or HDOP quality fields")]
    if satellites is not None and (isinstance(satellites, bool) or not isinstance(satellites, int) or satellites < 4):
        return [CheckResult("Track Log", False, f"status report track_log latest_satellites is weak or invalid: {satellites!r}")]
    parsed_hdop = _finite_gps_fix_float(hdop)
    if hdop is not None and (parsed_hdop is None or parsed_hdop < 0.0 or parsed_hdop > 5.0):
        return [CheckResult("Track Log", False, f"status report track_log latest_hdop is weak or invalid: {hdop!r}")]
    return []


def _positive_status_int(value: object) -> Optional[int]:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return None
    return value


def _nonnegative_status_int(value: object) -> Optional[int]:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _positive_status_float(value: object) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0.0:
        return None
    return parsed


def _status_absolute_path(value: str) -> bool:
    return bool(value) and not _status_text_has_control_char(value) and Path(value).expanduser().is_absolute()


def _normalize_status_path(value: str) -> str:
    return os.path.normpath(value)


def _status_path_under(child: str, parent: str) -> bool:
    if not _status_absolute_path(child) or not _status_absolute_path(parent):
        return False
    normalized_child = _normalize_status_path(child)
    normalized_parent = _normalize_status_path(parent)
    if normalized_child == normalized_parent:
        return False
    try:
        return os.path.commonpath([normalized_child, normalized_parent]) == normalized_parent
    except ValueError:
        return False


def _status_mode_value(value: object) -> Optional[int]:
    text = str(value).strip()
    if not text:
        return None
    try:
        parsed = int(text, 8)
    except ValueError:
        return None
    if parsed < 0 or parsed > 0o7777:
        return None
    return parsed


def _finite_gps_fix_float(value: object) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    parsed = float(value)
    if not math.isfinite(parsed):
        return None
    return parsed


def missing_required_readiness_checks(report: dict[str, object]) -> tuple[list[str], list[str]]:
    checks = report.get("checks")
    service_checks = report.get("service_checks")
    if not isinstance(checks, list) or not isinstance(service_checks, list):
        return [], []
    check_names = {str(check.get("name", "")) for check in checks if isinstance(check, dict)}
    service_check_names = {str(check.get("name", "")) for check in service_checks if isinstance(check, dict)}
    required_checks = set(CORE_READINESS_CHECKS)
    required_service_checks = set(CORE_SERVICE_CHECKS)
    gps_mode = ""
    config = report.get("config")
    if isinstance(config, dict):
        gps_mode = str(config.get("gps_mode", "")).strip().lower()
    if gps_mode == "serial":
        required_checks.update(SERIAL_READINESS_CHECKS)
    else:
        required_checks.update(GPSD_READINESS_CHECKS)
        required_service_checks.update(GPSD_SERVICE_CHECKS)
    track_log = report.get("track_log")
    if isinstance(track_log, dict):
        track_output = str(track_log.get("track_output", "")).strip()
        chart_output = ""
        if isinstance(config, dict):
            chart_output = str(config.get("chart_output", "")).strip()
        if track_output and chart_output and track_output != chart_output:
            required_checks.add("Track Disk")
    return sorted(required_checks - check_names), sorted(required_service_checks - service_check_names)


def _report_check_sections_all_ok(report: dict[str, object]) -> bool:
    for section_name in ("checks", "service_checks"):
        section = report.get(section_name)
        if not isinstance(section, list):
            return False
        for item in section:
            if not isinstance(item, dict) or item.get("ok") is not True:
                return False
    return True


def _gps_fix_summary(checks: list[CheckResult], *, now: Optional[datetime] = None) -> dict[str, object]:
    for check in checks:
        if check.name not in {"GPS", "GPSD"}:
            continue
        summary: dict[str, object] = {
            "source": check.name,
            "ok": check.ok,
            "detail": check.detail,
        }
        if check.data is not None:
            summary.update(check.data)
            timestamp = _parse_gps_fix_timestamp(check.data.get("timestamp"))
            if timestamp is not None:
                current = _current_utc(now, label="GPS fix summary")
                summary["age_seconds"] = (current - timestamp).total_seconds()
        return summary
    return {
        "source": "",
        "ok": False,
        "detail": "GPS fix check was not run",
    }


def _parse_gps_fix_timestamp(value: object) -> Optional[datetime]:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        timestamp = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if timestamp.tzinfo is None or timestamp.utcoffset() is None:
        return None
    return timestamp.astimezone(timezone.utc)


def _current_utc(now: Optional[datetime], *, label: str) -> datetime:
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None or current.utcoffset() is None:
        raise ValueError(f"{label} current time must include a timezone")
    return current.astimezone(timezone.utc)


def write_status_report(report: dict[str, object], output: Path) -> Path:
    target = Path(output).expanduser()
    _prepare_private_status_parent(target.parent)
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
            handle.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
            tmp_stat = os.fstat(handle.fileno())
        _validate_status_temp_for_promotion(tmp_path, expected_stat=tmp_stat)
        os.replace(tmp_path, target)
        _validate_written_status_report(target)
        _fsync_directory(target.parent)
    finally:
        if tmp_path is not None:
            cleanup_private_temp_file(tmp_path, label="status report temp", expected_stat=tmp_stat)
    return target


def _validate_status_temp_for_promotion(path: Path, *, expected_stat: Optional[os.stat_result]) -> None:
    if expected_stat is None:
        raise RuntimeError(f"status report temp was not opened safely before promotion: {path}")
    try:
        current = path.lstat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect status report temp before promotion {path}: {exc}") from exc
    if stat.S_ISLNK(current.st_mode):
        raise RuntimeError(f"status report temp is a symlink before promotion: {path}")
    if not stat.S_ISREG(current.st_mode):
        raise RuntimeError(f"status report temp is not a regular file before promotion: {path}")
    if current.st_uid != os.getuid():
        raise RuntimeError(f"status report temp {path} is owned by uid {current.st_uid}, expected {os.getuid()}")
    mode = stat.S_IMODE(current.st_mode)
    if mode != 0o600:
        raise RuntimeError(f"status report temp {path} has permissions {mode:04o}, expected private 0600")
    if not os.path.samestat(current, expected_stat):
        raise RuntimeError(f"status report temp changed before promotion; leaving it in place: {path}")

    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(opened, expected_stat):
            raise RuntimeError(f"status report temp changed while being opened for promotion: {path}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"status report temp is not regular when opened for promotion: {path}")
        opened_mode = stat.S_IMODE(opened.st_mode)
        if opened.st_uid != os.getuid() or opened_mode != 0o600:
            raise RuntimeError(f"status report temp {path} is not private current-user storage before promotion")
        os.fsync(fd)
    finally:
        os.close(fd)


def _validate_written_status_report(path: Path) -> None:
    target = Path(path).expanduser()
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(target, follow_symlinks=False)
        fd = os.open(target, flags)
    except OSError as exc:
        raise RuntimeError(f"could not open status report for validation: {target}: {exc}") from exc
    try:
        opened = os.fstat(fd)
        if before.st_dev != opened.st_dev or before.st_ino != opened.st_ino:
            raise RuntimeError(f"status report changed while being opened: {target}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"status report must be a regular file: {target}")
        if opened.st_uid != os.getuid():
            raise RuntimeError(f"status report {target} is owned by uid {opened.st_uid}, expected {os.getuid()}")
        mode = stat.S_IMODE(opened.st_mode)
        if mode != 0o600:
            raise RuntimeError(f"status report {target} has permissions {mode:04o}, expected private 0600")
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            try:
                payload = json.load(handle)
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"status report is not valid JSON: {target}: {exc}") from exc
    finally:
        if fd >= 0:
            os.close(fd)
    if not isinstance(payload, dict):
        raise RuntimeError(f"status report JSON must be an object: {target}")


def _prepare_private_status_parent(path: Path) -> None:
    path = Path(path).expanduser()
    if path.is_symlink():
        raise RuntimeError(f"status report directory {path} is a symlink")
    if path.parent.is_symlink():
        raise RuntimeError(f"status report parent directory {path.parent} is a symlink")
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        raise RuntimeError(f"status report parent path contains a symlink: {symlink_component}")
    _prepare_home_status_cache_parent(path)
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    stat_result = path.stat()
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"status report directory {path} is owned by uid {stat_result.st_uid}, "
            f"expected {os.getuid()}"
        )
    os.chmod(path, 0o700)
    if path.is_symlink():
        raise RuntimeError(f"status report directory {path} became a symlink after permission tightening")
    stat_result = path.stat()
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"status report directory {path} is owned by uid {stat_result.st_uid}, "
            f"expected {os.getuid()}"
        )
    mode = stat_result.st_mode & 0o777
    if mode & 0o077:
        raise RuntimeError(f"status report directory {path} has permissions {mode:04o}, expected private 0700")
    _fsync_directory(path)
    _fsync_directory(path.parent)


def _prepare_home_status_cache_parent(path: Path) -> None:
    path = Path(path).expanduser()
    home_cache_report_dir = Path.home() / ".cache" / "noaa-navionics"
    if path != home_cache_report_dir:
        return
    cache_parent = path.parent
    cache_parent.mkdir(mode=0o700, exist_ok=True)
    stat_result = cache_parent.stat()
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"status report cache parent directory {cache_parent} is owned by uid "
            f"{stat_result.st_uid}, expected {os.getuid()}"
        )
    mode = stat_result.st_mode & 0o777
    if mode & 0o077:
        os.chmod(cache_parent, 0o700)
    if cache_parent.is_symlink():
        raise RuntimeError(
            f"status report cache parent directory {cache_parent} became a symlink after permission tightening"
        )
    stat_result = cache_parent.stat()
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"status report cache parent directory {cache_parent} is owned by uid "
            f"{stat_result.st_uid}, expected {os.getuid()}"
        )
    mode = stat_result.st_mode & 0o777
    if mode & 0o077:
        raise RuntimeError(
            f"status report cache parent directory {cache_parent} has permissions {mode:04o}, expected private 0700"
        )
    _fsync_directory(cache_parent)
    _fsync_directory(cache_parent.parent)


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


def format_status_text(report: dict[str, object]) -> str:
    lines = [
        f"Generated: {report.get('generated_at', '')}",
        f"Host: {report.get('host', {}).get('name', '')}",
        f"Boot ID: {report.get('host', {}).get('boot_id', '')}",
        f"App: {report.get('app', {}).get('version', '')} "
        f"revision {report.get('app', {}).get('source_revision', '')} "
        f"source_revision_path_is_symlink="
        f"{report.get('app', {}).get('source_revision_path_is_symlink', '')} "
        f"source_revision_directory_is_symlink="
        f"{report.get('app', {}).get('source_revision_directory_is_symlink', '')} "
        f"source_revision_symlink_component="
        f"{report.get('app', {}).get('source_revision_symlink_component', '')}",
        f"Config: {report.get('config_path', '')}",
        f"Anchor radius: {report.get('config', {}).get('anchor_radius_meters', '')} m",
        f"Ready: {'yes' if status_report_is_ready(report) else 'no'}",
    ]
    gps_fix = report.get("gps_fix", {})
    if isinstance(gps_fix, dict) and gps_fix.get("source"):
        lines.append(f"GPS fix: {_format_gps_fix_summary(gps_fix)}")
    lines.extend(["", "Checks:"])
    for check in report.get("checks", []):
        if not isinstance(check, dict):
            continue
        mark = "OK" if check.get("ok") is True else "FAIL"
        lines.append(f"{mark:4} {check.get('name', ''):10} {check.get('detail', '')}")
    for check in status_report_validation_failures(report):
        lines.append(f"FAIL {check.name:10} {check.detail}")
    service_checks = report.get("service_checks", [])
    if isinstance(service_checks, list) and service_checks:
        lines.extend(["", "Service Checks:"])
        for check in service_checks:
            if not isinstance(check, dict):
                continue
            mark = "OK" if check.get("ok") is True else "FAIL"
            lines.append(f"{mark:4} {check.get('name', ''):18} {check.get('detail', '')}")
    manifest = report.get("manifest", {})
    if isinstance(manifest, dict) and manifest:
        lines.extend(["", "Manifest:"])
        for key in (
            "created_at",
            "created_at_source",
            "is_symlink",
            "directory_is_symlink",
            "chart_storage_symlink_component",
            "manifest_symlink_component",
            "uid",
            "mode",
            "package",
            "package_filename",
            "url",
            "download_path",
            "download_path_exists",
            "download_path_is_symlink",
            "download_path_symlink_component",
            "download_path_uid",
            "download_path_mode",
            "download_path_error",
            "download_url",
            "download_skipped",
            "download_bytes",
            "sha256",
            "extract_path",
            "extract_path_is_symlink",
            "extract_path_symlink_component",
            "enc_cell_count",
            "actual_enc_cell_count",
        ):
            if key in manifest:
                lines.append(f"{key}: {manifest[key]}")
    user = report.get("user", {})
    if isinstance(user, dict) and user:
        lines.extend(["", "User:"])
        lines.append(
            f"name={user.get('name', '')} uid={user.get('uid', '')} linger={user.get('linger', '')}".rstrip()
        )
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
                lines.append(
                    f"{name}: exists={state.get('exists', '')} "
                    f"is_symlink={state.get('is_symlink', '')} "
                    f"directory_is_symlink={state.get('directory_is_symlink', '')} "
                    f"path_symlink_component={state.get('path_symlink_component', '')} "
                    f"uid={state.get('uid', '')} mode={state.get('mode', '')} "
                    f"directory_uid={state.get('directory_uid', '')} "
                    f"directory_mode={state.get('directory_mode', '')} "
                    f"wanted_by={wanted_by_text}"
                )
    launcher_settings = report.get("launcher_settings", {})
    if isinstance(launcher_settings, dict) and launcher_settings:
        lines.extend(["", "Launcher Settings:"])
        values = launcher_settings.get("values", {})
        if isinstance(values, dict):
            value_text = " ".join(f"{key}={value}" for key, value in sorted(values.items()))
        else:
            value_text = ""
        symlink_text = (
            f"is_symlink={launcher_settings.get('is_symlink', '')} "
            f"directory_is_symlink={launcher_settings.get('directory_is_symlink', '')} "
            f"launcher_settings_symlink_component={launcher_settings.get('launcher_settings_symlink_component', '')}"
        )
        lines.append(
            f"path={launcher_settings.get('path', '')} "
            f"exists={launcher_settings.get('exists', '')} {symlink_text} {value_text}".rstrip()
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
            f"path={opencpn_config.get('path', '')} "
            f"exists={opencpn_config.get('exists', '')} "
            f"is_symlink={opencpn_config.get('is_symlink', '')} "
            f"directory_is_symlink={opencpn_config.get('directory_is_symlink', '')} "
            f"config_symlink_component={opencpn_config.get('config_symlink_component', '')} "
            f"uid={opencpn_config.get('uid', '')} mode={opencpn_config.get('mode', '')} "
            f"chart_directories={chart_dir_text} data_connections={connection_count}".rstrip()
        )
    desktop = report.get("desktop", {})
    if isinstance(desktop, dict) and desktop:
        lines.extend(["", "Desktop Startup:"])
        autostart = desktop.get("autostart", {})
        status_launcher = desktop.get("status_launcher", {})
        mob_launcher = desktop.get("mob_launcher", {})
        lightdm = desktop.get("lightdm_autologin", {})
        if isinstance(autostart, dict):
            lines.append(
                f"autostart={autostart.get('path', '')} "
                f"exists={autostart.get('exists', '')} "
                f"is_symlink={autostart.get('is_symlink', '')} "
                f"directory_is_symlink={autostart.get('directory_is_symlink', '')} "
                f"path_symlink_component={autostart.get('path_symlink_component', '')} "
                f"uid={autostart.get('uid', '')} mode={autostart.get('mode', '')}".rstrip()
            )
        if isinstance(status_launcher, dict):
            lines.append(
                f"status_launcher={status_launcher.get('path', '')} "
                f"exists={status_launcher.get('exists', '')} "
                f"is_symlink={status_launcher.get('is_symlink', '')} "
                f"directory_is_symlink={status_launcher.get('directory_is_symlink', '')} "
                f"path_symlink_component={status_launcher.get('path_symlink_component', '')} "
                f"uid={status_launcher.get('uid', '')} mode={status_launcher.get('mode', '')}".rstrip()
            )
        if isinstance(mob_launcher, dict):
            lines.append(
                f"mob_launcher={mob_launcher.get('path', '')} "
                f"exists={mob_launcher.get('exists', '')} "
                f"is_symlink={mob_launcher.get('is_symlink', '')} "
                f"directory_is_symlink={mob_launcher.get('directory_is_symlink', '')} "
                f"path_symlink_component={mob_launcher.get('path_symlink_component', '')} "
                f"uid={mob_launcher.get('uid', '')} mode={mob_launcher.get('mode', '')}".rstrip()
            )
        if isinstance(lightdm, dict):
            lines.append(
                f"lightdm_autologin={lightdm.get('path', '')} "
                f"exists={lightdm.get('exists', '')} "
                f"is_symlink={lightdm.get('is_symlink', '')} "
                f"directory_is_symlink={lightdm.get('directory_is_symlink', '')} "
                f"path_symlink_component={lightdm.get('path_symlink_component', '')} "
                f"uid={lightdm.get('uid', '')} mode={lightdm.get('mode', '')}".rstrip()
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
        quality = ""
        if "latest_satellites" in track_log:
            quality += f" satellites={track_log.get('latest_satellites')}"
        if "latest_hdop" in track_log:
            quality += f" hdop={track_log.get('latest_hdop')}"
        lines.append(
            f"track_output={track_log.get('track_output', '')} "
            f"tracks_dir={track_log.get('tracks_dir', '')} ok={track_log.get('ok', '')} "
            f"track_output_is_symlink={track_log.get('track_output_is_symlink', '')} "
            f"track_storage_symlink_component={track_log.get('track_storage_symlink_component', '')} "
            f"dir_mode={track_log.get('tracks_mode', '')} latest={latest}{coordinates}{quality} "
            f"mode={track_log.get('latest_mode', '')} "
            f"detail={track_log.get('detail', '')}".rstrip()
        )
    return "\n".join(lines)


def _format_gps_fix_summary(gps_fix: dict[str, object]) -> str:
    source = gps_fix.get("source", "")
    ok = "ok" if gps_fix.get("ok") is True else "fail"
    pieces = [f"{source} {ok}"]
    latitude = gps_fix.get("latitude")
    longitude = gps_fix.get("longitude")
    if isinstance(latitude, (int, float)) and isinstance(longitude, (int, float)):
        pieces.append(f"{latitude:.6f}, {longitude:.6f}")
    timestamp = gps_fix.get("timestamp")
    if timestamp:
        pieces.append(f"time {timestamp}")
    age_seconds = gps_fix.get("age_seconds")
    if isinstance(age_seconds, (int, float)) and not isinstance(age_seconds, bool):
        pieces.append(f"age {age_seconds:.0f}s")
    satellites = gps_fix.get("satellites")
    if satellites is not None:
        pieces.append(f"{satellites} satellites")
    hdop = gps_fix.get("hdop")
    if hdop is not None:
        pieces.append(f"HDOP {hdop}")
    speed = gps_fix.get("speed_knots")
    if isinstance(speed, (int, float)):
        pieces.append(f"speed {speed:.1f} kt")
    course = gps_fix.get("course_degrees")
    if isinstance(course, (int, float)):
        pieces.append(f"course {course:.1f} deg")
    detail = gps_fix.get("detail")
    if len(pieces) == 1 and detail:
        pieces.append(str(detail))
    return "; ".join(pieces)


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
        "anchor_radius_meters": app_config.anchor_radius_meters,
    }


def _app_summary() -> dict[str, object]:
    source_revision_path = _source_revision_path()
    source_revision_is_symlink = source_revision_path.is_symlink()
    source_revision_symlink_component = _first_symlink_ancestor(source_revision_path.parent)
    source_revision_directory_is_symlink = source_revision_path.parent.is_symlink()
    summary: dict[str, object] = {
        "version": __version__,
        "source_revision": "unknown",
        "source_revision_path": str(source_revision_path),
        "source_revision_exists": source_revision_path.exists(),
        "source_revision_path_is_symlink": source_revision_is_symlink,
        "source_revision_directory_is_symlink": source_revision_directory_is_symlink,
        "source_revision_symlink_component": (
            str(source_revision_symlink_component) if source_revision_symlink_component is not None else ""
        ),
    }
    source_revision_stat: Optional[os.stat_result] = None
    if source_revision_is_symlink:
        summary["source_revision_error"] = f"source revision path is a symlink: {source_revision_path}"
        return summary
    if source_revision_symlink_component is not None:
        summary["source_revision_error"] = (
            f"source revision directory is a symlink: {source_revision_symlink_component}"
        )
        return summary
    if source_revision_path.parent.exists():
        if not source_revision_path.parent.is_dir():
            summary["source_revision_error"] = (
                f"source revision parent is not a directory: {source_revision_path.parent}"
            )
            return summary
        try:
            source_revision_directory_stat = source_revision_path.parent.stat()
        except OSError as exc:
            summary["source_revision_error"] = (
                f"could not inspect source revision directory {source_revision_path.parent}: {exc}"
            )
            return summary
        source_revision_directory_mode = source_revision_directory_stat.st_mode & 0o777
        summary["source_revision_directory_uid"] = source_revision_directory_stat.st_uid
        summary["source_revision_directory_mode"] = f"{source_revision_directory_mode:04o}"
        if source_revision_directory_stat.st_uid != os.getuid():
            summary["source_revision_error"] = (
                f"source revision directory {source_revision_path.parent} is owned by uid "
                f"{source_revision_directory_stat.st_uid}, expected {os.getuid()}"
            )
            return summary
        if source_revision_directory_mode & 0o022:
            summary["source_revision_error"] = (
                f"source revision directory {source_revision_path.parent} has permissions "
                f"{source_revision_directory_mode:04o}, expected no group/other write bits"
            )
            return summary
    if source_revision_path.exists():
        if not source_revision_path.is_file():
            summary["source_revision_error"] = f"source revision path is not a regular file: {source_revision_path}"
            return summary
        try:
            source_revision_stat = source_revision_path.stat()
        except OSError as exc:
            summary["source_revision_error"] = f"could not inspect source revision path {source_revision_path}: {exc}"
            return summary
        source_revision_mode = source_revision_stat.st_mode & 0o777
        summary["source_revision_uid"] = source_revision_stat.st_uid
        summary["source_revision_mode"] = f"{source_revision_mode:04o}"
        if source_revision_stat.st_uid != os.getuid():
            summary["source_revision_error"] = (
                f"source revision path {source_revision_path} is owned by uid "
                f"{source_revision_stat.st_uid}, expected {os.getuid()}"
            )
            return summary
        if source_revision_mode & 0o022:
            summary["source_revision_error"] = (
                f"source revision path {source_revision_path} has permissions "
                f"{source_revision_mode:04o}, expected no group/other write bits"
            )
            return summary
    try:
        summary["source_revision"] = _source_revision(
            source_revision_path,
            expected_stat=source_revision_stat,
        )
    except RuntimeError as exc:
        summary["source_revision_error"] = str(exc)
    return summary


def _source_revision(path: Optional[Path] = None, *, expected_stat: Optional[os.stat_result] = None) -> str:
    revision_path = path or _source_revision_path()
    try:
        value = _read_source_revision_text(revision_path, expected_stat=expected_stat)
    except OSError:
        return "unknown"
    return value or "unknown"


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
                f"source revision path {path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"source revision path {path} has permissions {mode:04o}, expected no group/other write bits"
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


def _boot_id() -> str:
    try:
        value = _read_boot_id_text(BOOT_ID_PATH)
    except (OSError, RuntimeError):
        return "unknown"
    if BOOT_ID_RE.fullmatch(value):
        return value
    return "unknown"


def _read_boot_id_text(path: Path) -> str:
    target = Path(path)
    try:
        before = os.stat(target, follow_symlinks=False)
    except OSError:
        if target.is_symlink():
            raise RuntimeError(f"boot ID path is a symlink: {target}")
        raise
    if not stat.S_ISREG(before.st_mode):
        raise RuntimeError(f"boot ID path is not a regular file: {target}")
    try:
        fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        if target.is_symlink():
            raise RuntimeError(f"boot ID path is a symlink: {target}")
        raise
    try:
        opened = os.fstat(fd)
        if before.st_dev != opened.st_dev or before.st_ino != opened.st_ino:
            raise RuntimeError(f"boot ID path changed before it could be read: {target}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"boot ID path is not a regular file when opened: {target}")
        with os.fdopen(fd, encoding="ascii") as handle:
            fd = -1
            return handle.read().strip()
    finally:
        if fd >= 0:
            os.close(fd)


def _current_boot_epoch() -> Optional[float]:
    try:
        uptime_seconds = _parse_proc_uptime_seconds(_read_proc_uptime_text(PROC_UPTIME_PATH))
    except (OSError, RuntimeError, ValueError, IndexError):
        return None
    return time.time() - uptime_seconds


def _read_proc_uptime_text(path: Path) -> str:
    target = Path(path)
    try:
        before = os.stat(target, follow_symlinks=False)
    except OSError:
        if target.is_symlink():
            raise RuntimeError(f"proc uptime path is a symlink: {target}")
        raise
    if stat.S_ISLNK(before.st_mode):
        raise RuntimeError(f"proc uptime path is a symlink: {target}")
    if not stat.S_ISREG(before.st_mode):
        raise RuntimeError(f"proc uptime path is not a regular file: {target}")
    try:
        fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        if target.is_symlink():
            raise RuntimeError(f"proc uptime path is a symlink: {target}")
        raise
    try:
        opened = os.fstat(fd)
        if before.st_dev != opened.st_dev or before.st_ino != opened.st_ino:
            raise RuntimeError(f"proc uptime path changed before it could be read: {target}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"proc uptime path is not a regular file when opened: {target}")
        with os.fdopen(fd, encoding="ascii") as handle:
            fd = -1
            return handle.read().strip()
    finally:
        if fd >= 0:
            os.close(fd)


def _parse_proc_uptime_seconds(value: str) -> float:
    uptime_seconds = float(value.split()[0])
    if not math.isfinite(uptime_seconds) or uptime_seconds < 0:
        raise ValueError("uptime must be finite and non-negative")
    return uptime_seconds


def _finite_non_negative_seconds(value: object, label: str) -> float:
    seconds = _finite_seconds(value, label)
    if seconds < 0.0:
        raise ValueError(f"{label} must be finite and non-negative")
    return seconds


def _finite_positive_seconds(value: object, label: str) -> float:
    seconds = _finite_seconds(value, label)
    if seconds <= 0.0:
        raise ValueError(f"{label} must be finite and greater than 0")
    return seconds


def _finite_seconds(value: object, label: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{label} must be finite")
    try:
        seconds = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} must be finite") from exc
    if not math.isfinite(seconds):
        raise ValueError(f"{label} must be finite")
    return seconds


def _finite_optional_epoch(value: Optional[object], label: str) -> Optional[float]:
    if value is None:
        return None
    epoch = _finite_seconds(value, label)
    if epoch < 0.0:
        raise ValueError(f"{label} must be finite and non-negative")
    return epoch


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
    max_age_seconds = _finite_non_negative_seconds(max_age_seconds, "max_age_seconds")
    wait_seconds = _finite_non_negative_seconds(wait_seconds, "wait_seconds")
    poll_seconds = _finite_positive_seconds(poll_seconds, "poll_seconds")
    boot_epoch = _finite_optional_epoch(boot_epoch, "boot_epoch")
    deadline = time.monotonic() + wait_seconds
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
    max_age_seconds = _finite_non_negative_seconds(max_age_seconds, "max_age_seconds")
    boot_epoch = _finite_optional_epoch(boot_epoch, "boot_epoch")
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None or current.utcoffset() is None:
        raise ValueError("track log summary current time must include a timezone")
    current = current.astimezone(timezone.utc)
    expected_owner = os.getuid() if expected_uid is None else expected_uid
    boot_time = _current_boot_epoch() if boot_epoch is None else boot_epoch
    track_output_path = Path(track_output).expanduser()
    tracks_dir = track_output_path / "tracks"
    symlink_component = _first_symlink_ancestor(tracks_dir)
    summary: dict[str, object] = {
        "track_output": str(track_output_path),
        "track_output_is_symlink": track_output_path.is_symlink(),
        "track_storage_symlink_component": str(symlink_component) if symlink_component is not None else "",
        "tracks_dir": str(tracks_dir),
        "exists": tracks_dir.exists(),
        "ok": False,
        "max_age_seconds": max_age_seconds,
    }
    if symlink_component is not None:
        summary["detail"] = f"{symlink_component} is a symlink, expected real GPX track storage"
        return summary
    try:
        tracks_fd, tracks_stat = _open_trusted_tracks_dir(tracks_dir, expected_owner=expected_owner)
    except RuntimeError as exc:
        summary["detail"] = str(exc)
        return summary
    try:
        tracks_mode = tracks_stat.st_mode & 0o777
        summary["tracks_mode"] = f"{tracks_mode:04o}"
        candidates = []
        last_detail = ""
        for name in os.listdir(tracks_fd):
            if not name.startswith("track-") or not name.endswith(".gpx"):
                continue
            path = tracks_dir / name
            try:
                candidate_stat = os.stat(name, dir_fd=tracks_fd, follow_symlinks=False)
            except OSError as exc:
                last_detail = f"could not inspect {path}: {exc}"
                continue
            if stat.S_ISLNK(candidate_stat.st_mode):
                last_detail = f"{path} is a symlink, expected a regular GPX track file"
                continue
            if not stat.S_ISREG(candidate_stat.st_mode):
                last_detail = f"{path} is not a regular GPX track file"
                continue
            if candidate_stat.st_uid != expected_owner:
                last_detail = f"{path} is owned by uid {candidate_stat.st_uid}, expected {expected_owner}"
                continue
            mode = candidate_stat.st_mode & 0o777
            if mode & 0o077:
                last_detail = f"{path} permissions are {mode:04o}, expected private 0600"
                continue
            candidates.append((candidate_stat.st_mtime, path, candidate_stat))
        candidates.sort(reverse=True)
        for _mtime, path, stat_result in candidates:
            try:
                read_stat, text = _read_trusted_gpx_track_file(
                    path,
                    expected_owner=expected_owner,
                    expected_stat=stat_result,
                    directory_fd=tracks_fd,
                )
            except Exception as exc:
                last_detail = str(exc)
                continue
            stat_result = read_stat
            if boot_time is not None and stat_result.st_mtime + 5 < boot_time:
                last_detail = f"{path} is older than current boot"
                continue
            trackpoints = re.findall(r"<trkpt\b.*?</trkpt>", text, flags=re.DOTALL)
            if not trackpoints:
                last_detail = f"{path} is current-boot but has no GPX trackpoint yet"
                continue
            newest_time = None
            newest_position = None
            newest_quality = None
            for trackpoint in trackpoints:
                element, element_error = _gpx_trackpoint_element(trackpoint)
                if element is None:
                    last_detail = f"{path} {element_error}"
                    continue
                position, position_error = _gpx_trackpoint_position(element)
                if position is None:
                    last_detail = f"{path} {position_error}"
                    continue
                quality, quality_error = _gpx_trackpoint_quality(element)
                if quality is None:
                    last_detail = f"{path} {quality_error}"
                    continue
                timestamp_text = _gpx_child_text(element, "time")
                if timestamp_text is None:
                    last_detail = f"{path} has GPX trackpoints but no timestamped trackpoint yet"
                    continue
                track_time, timestamp_error = _parse_gpx_trackpoint_timestamp(timestamp_text)
                if track_time is None:
                    last_detail = f"{path} {timestamp_error}"
                    continue
                if newest_time is None or track_time > newest_time:
                    newest_time = track_time
                    newest_position = position
                    newest_quality = quality
            if newest_time is None or newest_position is None or newest_quality is None:
                last_detail = last_detail or f"{path} has GPX trackpoints but no valid timestamped quality position yet"
                continue
            track_epoch = newest_time.timestamp()
            if boot_time is not None and track_epoch + 5 < boot_time:
                last_detail = f"{path} newest GPX trackpoint is older than current boot"
                continue
            age = current.timestamp() - track_epoch
            if age < 0.0:
                last_detail = f"{path} newest GPX trackpoint timestamp is in the future by {-age:.0f}s"
                continue
            if age > max_age_seconds:
                last_detail = f"{path} newest GPX trackpoint is stale: {age:.0f}s old"
                continue
            latitude, longitude = newest_position
            quality_detail = _format_trackpoint_quality(newest_quality)
            detail = f"{path} {latitude:.6f},{longitude:.6f}"
            if quality_detail:
                detail = f"{detail} {quality_detail}"
            latest_fields: dict[str, object] = {
                "ok": True,
                "latest_path": str(path),
                "latest_time": newest_time.isoformat().replace("+00:00", "Z"),
                "latest_latitude": latitude,
                "latest_longitude": longitude,
                "age_seconds": age,
                "latest_mode": f"{stat_result.st_mode & 0o777:04o}",
                "detail": detail,
            }
            if newest_quality.get("satellites") is not None:
                latest_fields["latest_satellites"] = newest_quality["satellites"]
            if newest_quality.get("hdop") is not None:
                latest_fields["latest_hdop"] = newest_quality["hdop"]
            summary.update(latest_fields)
            return summary
        summary["detail"] = last_detail or f"no current-boot GPX trackpoint found under {tracks_dir}"
        return summary
    finally:
        os.close(tracks_fd)


def _open_trusted_tracks_dir(path: Path, *, expected_owner: int) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        raise RuntimeError(f"{path} does not exist") from None
    except OSError as exc:
        raise RuntimeError(f"could not inspect GPX tracks directory {path}: {exc}") from exc
    if stat.S_ISLNK(before.st_mode):
        raise RuntimeError(f"{path} is a symlink, expected a private GPX tracks directory")
    if not stat.S_ISDIR(before.st_mode):
        raise RuntimeError(f"{path} is not a directory")
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        raise RuntimeError(f"GPX tracks directory disappeared before it could be read: {path}") from None
    except OSError as exc:
        if path.is_symlink():
            raise RuntimeError(f"{path} is a symlink, expected a private GPX tracks directory") from exc
        raise RuntimeError(f"could not open GPX tracks directory {path}: {exc}") from exc
    try:
        opened = os.fstat(fd)
        if not os.path.samestat(opened, before):
            raise RuntimeError(f"GPX tracks directory changed before it could be read: {path}")
        if not stat.S_ISDIR(opened.st_mode):
            raise RuntimeError(f"{path} is not a directory")
        if opened.st_uid != expected_owner:
            raise RuntimeError(f"{path} is owned by uid {opened.st_uid}, expected {expected_owner}")
        mode = opened.st_mode & 0o777
        if mode & 0o077:
            raise RuntimeError(f"{path} permissions are {mode:04o}, expected private 0700")
        return fd, opened
    except Exception:
        os.close(fd)
        raise


def _parse_gpx_trackpoint_timestamp(value: str) -> tuple[Optional[datetime], str]:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None, f"has an invalid GPX trackpoint timestamp: {value}"
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None, "has a timezone-less GPX trackpoint timestamp"
    return parsed.astimezone(timezone.utc), ""


def _read_trusted_gpx_track_file(
    path: Path,
    *,
    expected_owner: int,
    expected_stat: Optional[os.stat_result] = None,
    directory_fd: Optional[int] = None,
) -> tuple[os.stat_result, str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        if directory_fd is None:
            fd = os.open(path, flags)
        else:
            fd = os.open(path.name, flags, dir_fd=directory_fd)
    except OSError:
        if directory_fd is None and path.is_symlink():
            raise RuntimeError(f"{path} is a symlink, expected a regular GPX track file")
        raise
    try:
        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"{path} is not a regular GPX track file")
        if expected_stat is not None and (stat_result.st_dev, stat_result.st_ino) != (
            expected_stat.st_dev,
            expected_stat.st_ino,
        ):
            raise RuntimeError(f"{path} changed before it could be read")
        if stat_result.st_uid != expected_owner:
            raise RuntimeError(f"{path} is owned by uid {stat_result.st_uid}, expected {expected_owner}")
        mode = stat_result.st_mode & 0o777
        if mode & 0o077:
            raise RuntimeError(f"{path} permissions are {mode:04o}, expected private 0600")
        with os.fdopen(fd, encoding="utf-8", errors="replace") as handle:
            fd = -1
            return stat_result, handle.read()
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


def _gpx_trackpoint_element(trackpoint: str) -> tuple[Optional[ET.Element], str]:
    try:
        element = ET.fromstring(trackpoint)
    except ET.ParseError as exc:
        return None, f"GPX trackpoint is malformed XML: {exc}"
    if _gpx_local_name(element.tag) != "trkpt":
        return None, "GPX trackpoint has no opening trkpt tag"
    return element, ""


def _gpx_local_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def _gpx_child_text(element: ET.Element, child_name: str) -> Optional[str]:
    for child in element:
        if _gpx_local_name(child.tag) == child_name and child.text is not None:
            return child.text.strip()
    return None


def _gpx_trackpoint_position(element: ET.Element) -> tuple[Optional[tuple[float, float]], str]:
    latitude_text = element.get("lat")
    longitude_text = element.get("lon")
    if latitude_text is None or longitude_text is None:
        return None, "GPX trackpoint is missing latitude or longitude"
    try:
        latitude = float(latitude_text)
        longitude = float(longitude_text)
    except ValueError:
        return None, f"GPX trackpoint has non-numeric coordinates: {latitude_text}, {longitude_text}"
    if not math.isfinite(latitude) or not math.isfinite(longitude):
        return None, f"GPX trackpoint has non-finite coordinates: {latitude_text}, {longitude_text}"
    if not (-90.0 <= latitude <= 90.0):
        return None, f"GPX trackpoint latitude is outside -90..90: {latitude}"
    if not (-180.0 <= longitude <= 180.0):
        return None, f"GPX trackpoint longitude is outside -180..180: {longitude}"
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        return None, "GPX trackpoint has invalid 0,0 coordinates"
    return (latitude, longitude), ""


def _gpx_trackpoint_quality(element: ET.Element) -> tuple[Optional[dict[str, object]], str]:
    sat_text = _gpx_child_text(element, "sat")
    hdop_text = _gpx_child_text(element, "hdop")
    if sat_text is None and hdop_text is None:
        return None, "GPX trackpoint is missing satellite or HDOP quality fields"
    quality: dict[str, object] = {"satellites": None, "hdop": None}
    if sat_text is not None:
        try:
            satellites = int(sat_text)
        except ValueError:
            return None, f"GPX trackpoint has non-numeric satellite count: {sat_text}"
        if satellites < 4:
            return None, f"GPX trackpoint has weak satellite count: {satellites}"
        quality["satellites"] = satellites
    if hdop_text is not None:
        try:
            hdop = float(hdop_text)
        except ValueError:
            return None, f"GPX trackpoint has non-numeric HDOP: {hdop_text}"
        if not math.isfinite(hdop):
            return None, f"GPX trackpoint has non-finite HDOP: {hdop_text}"
        if hdop < 0.0:
            return None, f"GPX trackpoint has invalid negative HDOP: {hdop:g}"
        if hdop > 5.0:
            return None, f"GPX trackpoint has weak HDOP: {hdop:g}"
        quality["hdop"] = hdop
    return quality, ""


def _format_trackpoint_quality(quality: dict[str, object]) -> str:
    pieces = []
    if quality.get("satellites") is not None:
        pieces.append(f"{quality['satellites']} satellites")
    if quality.get("hdop") is not None:
        pieces.append(f"HDOP {quality['hdop']:g}")
    return "; ".join(pieces)


def _track_log_readiness_check(track_log: dict[str, object]) -> CheckResult:
    if track_log.get("ok") is True:
        return CheckResult("Track Log", True, str(track_log.get("detail", "recent GPX trackpoint found")))
    return CheckResult("Track Log", False, str(track_log.get("detail", "no recent GPX trackpoint found")))


def _manifest_summary(chart_output: Path) -> dict[str, object]:
    chart_storage_path = Path(chart_output).expanduser()
    manifest_path = chart_storage_path / MANIFEST_NAME
    chart_storage_symlink_component = _first_symlink_ancestor(chart_storage_path)
    summary: dict[str, object] = {
        "path": str(manifest_path),
        "exists": manifest_path.exists(),
        "is_symlink": manifest_path.is_symlink(),
        "directory_is_symlink": manifest_path.parent.is_symlink(),
        "chart_storage_symlink_component": (
            str(chart_storage_symlink_component) if chart_storage_symlink_component is not None else ""
        ),
        "manifest_symlink_component": (
            str(chart_storage_symlink_component) if chart_storage_symlink_component is not None else ""
        ),
    }
    if manifest_path.is_symlink():
        summary["error"] = f"manifest path is a symlink: {manifest_path}"
        return summary
    if chart_storage_symlink_component is not None:
        summary["error"] = f"manifest directory is a symlink: {chart_storage_symlink_component}"
        return summary
    if manifest_path.parent.exists():
        if not manifest_path.parent.is_dir():
            summary["error"] = f"manifest parent is not a directory: {manifest_path.parent}"
            return summary
        try:
            directory_stat = manifest_path.parent.stat()
        except OSError as exc:
            summary["error"] = f"could not inspect manifest directory {manifest_path.parent}: {exc}"
            return summary
        directory_mode = directory_stat.st_mode & 0o777
        summary["directory_uid"] = directory_stat.st_uid
        summary["directory_mode"] = f"{directory_mode:04o}"
        if directory_stat.st_uid != os.getuid():
            summary["error"] = (
                f"manifest directory {manifest_path.parent} is owned by uid "
                f"{directory_stat.st_uid}, expected {os.getuid()}"
            )
            return summary
        if directory_mode & 0o022:
            summary["error"] = (
                f"manifest directory {manifest_path.parent} has permissions "
                f"{directory_mode:04o}, expected no group/other write bits"
            )
            return summary
    if not manifest_path.exists():
        return summary
    if not manifest_path.is_file():
        summary["error"] = f"manifest path is not a regular file: {manifest_path}"
        return summary
    try:
        stat_result = manifest_path.stat()
    except OSError as exc:
        summary["error"] = str(exc)
        return summary
    summary["uid"] = stat_result.st_uid
    summary["mode"] = f"{stat_result.st_mode & 0o777:04o}"
    try:
        manifest = read_manifest(chart_output, expected_stat=stat_result)
    except Exception as exc:
        summary["error"] = str(exc)
        return summary
    package = manifest.get("package", {})
    download = manifest.get("download", {})
    extract = manifest.get("extract", {})
    download_path = str(download.get("path", "")).strip() if isinstance(download, dict) else ""
    extract_path = str(extract.get("path", "")).strip() if isinstance(extract, dict) else ""
    download_path_obj = Path(download_path).expanduser() if download_path else None
    extract_path_obj = Path(extract_path).expanduser() if extract_path else None
    download_path_symlink_component = (
        _first_symlink_ancestor(download_path_obj) if download_path_obj is not None else None
    )
    extract_path_symlink_component = (
        _first_symlink_ancestor(extract_path_obj) if extract_path_obj is not None else None
    )
    actual_enc_cell_count = 0
    extract_path_error = ""
    if (
        extract_path_obj is not None
        and extract_path_obj.exists()
        and extract_path_obj.is_dir()
        and not extract_path_obj.is_symlink()
        and extract_path_symlink_component is None
    ):
        actual_enc_cell_count, extract_path_error = _trusted_enc_cell_tree_count(extract_path_obj)
    summary.update(
        {
            "created_at": manifest.get("created_at", ""),
            "created_at_source": manifest.get("created_at_source", ""),
            "package": package.get("label", "") if isinstance(package, dict) else "",
            "package_filename": package.get("filename", "") if isinstance(package, dict) else "",
            "url": package.get("url", "") if isinstance(package, dict) else "",
            "download_path": download_path,
            "download_path_exists": download_path_obj.exists() if download_path_obj is not None else False,
            "download_path_is_symlink": download_path_obj.is_symlink() if download_path_obj is not None else False,
            "download_path_symlink_component": (
                str(download_path_symlink_component) if download_path_symlink_component is not None else ""
            ),
            "download_url": download.get("url", "") if isinstance(download, dict) else "",
            "download_skipped": download.get("skipped", False) if isinstance(download, dict) else False,
            "download_bytes": download.get("bytes", 0) if isinstance(download, dict) else 0,
            "sha256": download.get("sha256", "") if isinstance(download, dict) else "",
            "extract_path": extract_path,
            "extract_path_is_symlink": extract_path_obj.is_symlink() if extract_path_obj is not None else False,
            "extract_path_symlink_component": (
                str(extract_path_symlink_component) if extract_path_symlink_component is not None else ""
            ),
            "enc_cell_count": extract.get("enc_cell_count", 0) if isinstance(extract, dict) else 0,
            "actual_enc_cell_count": actual_enc_cell_count,
        }
    )
    if extract_path_error:
        summary["extract_path_error"] = extract_path_error
    if (
        download_path_obj is not None
        and download_path_obj.exists()
        and not download_path_obj.is_symlink()
        and download_path_symlink_component is None
    ):
        if not download_path_obj.is_file():
            summary["download_path_error"] = f"manifest download path is not a regular file: {download_path_obj}"
        else:
            try:
                download_stat = download_path_obj.stat()
            except OSError as exc:
                summary["download_path_error"] = str(exc)
            else:
                summary["download_path_uid"] = download_stat.st_uid
                summary["download_path_mode"] = f"{download_stat.st_mode & 0o777:04o}"
    return summary


def _service_summary() -> dict[str, object]:
    _, error = _trusted_system_command("systemctl", "Systemctl command")
    if error:
        return {"available": False, "detail": error}
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
    _, error = _trusted_system_command("systemctl", "Systemctl command")
    if error:
        return {"available": False, "detail": error}
    units = ["gpsd.socket", "gpsd.service", "chrony.service"]
    summary: dict[str, object] = {"available": True}
    for unit in units:
        summary[unit] = {
            "enabled": _systemctl_system(["is-enabled", unit]),
            "active": _systemctl_system(["is-active", unit]),
        }
    return summary


def _user_summary() -> dict[str, object]:
    name = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    summary: dict[str, object] = {"name": name, "uid": os.getuid()}
    if not name:
        summary["error"] = "USER is not set"
        return summary
    loginctl, error = _trusted_system_command("loginctl", "Loginctl command")
    if error:
        summary["error"] = error
        return summary
    assert loginctl is not None
    try:
        completed = subprocess.run(
            [str(loginctl), "show-user", name, "-p", "Linger"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
    except Exception as exc:
        summary["error"] = str(exc)
        return summary
    output = completed.stdout.strip() or completed.stderr.strip()
    if completed.returncode != 0:
        summary["error"] = output or f"exit {completed.returncode}"
        return summary
    for line in completed.stdout.splitlines():
        if line.startswith("Linger="):
            summary["linger"] = line.split("=", 1)[1].strip()
            break
    if "linger" not in summary:
        summary["error"] = output or "loginctl did not report Linger"
    return summary


def _user_unit_file_summary() -> dict[str, object]:
    unit_dir = Path.home() / ".config/systemd/user"
    summary: dict[str, object] = {"directory": str(unit_dir)}
    for unit in USER_UNIT_PROPERTIES:
        path = unit_dir / unit
        symlink_component = _first_symlink_ancestor(path.parent)
        state: dict[str, object] = {
            "path": str(path),
            "exists": path.is_file(),
            "is_symlink": path.is_symlink(),
            "directory_is_symlink": path.parent.is_symlink(),
            "path_symlink_component": str(symlink_component) if symlink_component is not None else "",
        }
        try:
            directory_stat = path.parent.stat()
        except OSError as exc:
            state["directory_error"] = str(exc)
        else:
            state["directory_uid"] = directory_stat.st_uid
            state["directory_mode"] = f"{directory_stat.st_mode & 0o777:04o}"
        if path.is_symlink():
            state["error"] = f"user unit file path is a symlink: {path}"
            summary[unit] = state
            continue
        if symlink_component is not None:
            state["error"] = f"user unit file directory is a symlink: {symlink_component}"
            summary[unit] = state
            continue
        if path.is_file():
            try:
                expected_stat = path.stat()
            except OSError as exc:
                state["error"] = f"could not inspect user unit file path {path}: {exc}"
                summary[unit] = state
                continue
            try:
                stat_result, lines = _read_user_unit_file_lines(path, expected_stat=expected_stat)
                state["uid"] = stat_result.st_uid
                state["mode"] = f"{stat_result.st_mode & 0o777:04o}"
            except Exception as exc:
                state["error"] = str(exc)
            else:
                state["wanted_by"] = _install_wanted_by_targets(lines)
                state["lines"] = lines
        summary[unit] = state
    return summary


def _read_user_unit_file_lines(
    path: Path,
    *,
    expected_stat: Optional[os.stat_result] = None,
) -> tuple[os.stat_result, list[str]]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        if path.is_symlink():
            raise RuntimeError(f"user unit file path is a symlink: {path}")
        raise
    try:
        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"user unit file path is not a regular file: {path}")
        if expected_stat is not None and (stat_result.st_dev, stat_result.st_ino) != (
            expected_stat.st_dev,
            expected_stat.st_ino,
        ):
            raise RuntimeError(f"user unit file path changed before it could be read: {path}")
        if stat_result.st_uid != os.getuid():
            raise RuntimeError(
                f"user unit file path {path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"user unit file path {path} has permissions {mode:04o}, expected no group/other write bits"
            )
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            return stat_result, handle.read().splitlines()
    finally:
        if fd >= 0:
            os.close(fd)


def _launcher_settings_summary(path: Optional[Path] = None) -> dict[str, object]:
    launcher_env = Path(path or DEFAULT_LAUNCHER_ENV_PATH).expanduser()
    symlink_component = _first_symlink_ancestor(launcher_env.parent)
    summary: dict[str, object] = {
        "path": str(launcher_env),
        "exists": launcher_env.exists(),
        "is_symlink": launcher_env.is_symlink(),
        "directory_is_symlink": launcher_env.parent.is_symlink(),
        "launcher_settings_symlink_component": str(symlink_component) if symlink_component is not None else "",
    }
    if launcher_env.is_symlink():
        summary["error"] = f"launcher environment path is a symlink: {launcher_env}"
        return summary
    if symlink_component is not None:
        summary["error"] = f"launcher environment directory is a symlink: {symlink_component}"
        return summary
    if launcher_env.parent.exists():
        if not launcher_env.parent.is_dir():
            summary["error"] = f"launcher environment parent is not a directory: {launcher_env.parent}"
            return summary
        try:
            parent_stat = launcher_env.parent.stat()
            summary["directory_uid"] = parent_stat.st_uid
            summary["directory_mode"] = f"{parent_stat.st_mode & 0o777:04o}"
        except OSError as exc:
            summary["error"] = f"could not inspect launcher environment directory {launcher_env.parent}: {exc}"
            return summary
    if not launcher_env.exists():
        return summary
    if not launcher_env.is_file():
        summary["error"] = f"launcher environment is not a regular file: {launcher_env}"
        return summary
    try:
        stat_result = launcher_env.stat()
        summary["uid"] = stat_result.st_uid
        summary["mode"] = f"{stat_result.st_mode & 0o777:04o}"
    except OSError as exc:
        summary["error"] = str(exc)
        return summary
    try:
        lines = _read_launcher_settings_lines(launcher_env, expected_stat=stat_result)
    except Exception as exc:
        summary["error"] = str(exc)
        return summary
    values: dict[str, str] = {}
    malformed_lines = []
    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            if line and not line.startswith("#") and "=" not in line:
                malformed_lines.append(f"{line_number}: {line}")
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    summary["values"] = values
    if malformed_lines:
        summary["malformed_lines"] = malformed_lines
    return summary


def _read_launcher_settings_lines(path: Path, *, expected_stat: Optional[os.stat_result] = None) -> list[str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        if path.is_symlink():
            raise RuntimeError(f"launcher environment path is a symlink: {path}")
        raise
    try:
        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"launcher environment is not a regular file: {path}")
        if expected_stat is not None and (stat_result.st_dev, stat_result.st_ino) != (
            expected_stat.st_dev,
            expected_stat.st_ino,
        ):
            raise RuntimeError(f"launcher environment changed before it could be read: {path}")
        if stat_result.st_uid != os.getuid():
            raise RuntimeError(
                f"launcher environment is owned by uid {stat_result.st_uid}, expected {os.getuid()}: {path}"
            )
        mode = stat_result.st_mode & 0o777
        if mode != 0o600:
            raise RuntimeError(f"launcher environment has permissions {mode:04o}, expected private 0600: {path}")
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            return handle.read().splitlines()
    finally:
        if fd >= 0:
            os.close(fd)


def _opencpn_config_summary(path: Optional[Path] = None) -> dict[str, object]:
    config_path = opencpn_config_path(path)
    symlink_component = _first_symlink_ancestor(config_path.parent)
    summary: dict[str, object] = {
        "path": str(config_path),
        "exists": config_path.exists(),
        "is_symlink": config_path.is_symlink(),
        "directory_is_symlink": config_path.parent.is_symlink(),
        "config_symlink_component": str(symlink_component) if symlink_component is not None else "",
    }
    if config_path.is_symlink():
        summary["error"] = f"OpenCPN config path is a symlink: {config_path}"
        return summary
    if symlink_component is not None:
        summary["error"] = f"OpenCPN config directory is a symlink: {symlink_component}"
        return summary
    if config_path.parent.exists():
        try:
            directory_stat = config_path.parent.stat()
        except OSError as exc:
            summary["error"] = f"could not inspect OpenCPN config directory {config_path.parent}: {exc}"
            return summary
        summary["directory_uid"] = directory_stat.st_uid
        summary["directory_mode"] = f"{directory_stat.st_mode & 0o777:04o}"
    if not config_path.exists():
        return summary
    if not config_path.is_file():
        summary["error"] = f"OpenCPN config path is not a regular file: {config_path}"
        return summary
    try:
        stat_result = config_path.stat()
    except OSError as exc:
        summary["error"] = str(exc)
        return summary
    summary["uid"] = stat_result.st_uid
    summary["mode"] = f"{stat_result.st_mode & 0o777:04o}"
    try:
        summary["chart_directories"] = [str(chart_dir) for chart_dir in read_chart_directories(config_path)]
        summary["data_connections"] = read_data_connections(config_path)
    except Exception as exc:
        summary["error"] = str(exc)
    return summary


def _desktop_summary(
    *,
    autostart_path: Optional[Path] = None,
    status_desktop_path: Optional[Path] = None,
    mob_desktop_path: Optional[Path] = None,
    lightdm_autologin_path: Optional[Path] = None,
) -> dict[str, object]:
    autostart = _key_value_file_summary(
        Path(autostart_path or DEFAULT_AUTOSTART_PATH).expanduser(),
        comment_prefixes=("#",),
    )
    status_launcher = _key_value_file_summary(
        Path(status_desktop_path or DEFAULT_STATUS_DESKTOP_PATH).expanduser(),
        comment_prefixes=("#",),
    )
    mob_launcher = _key_value_file_summary(
        Path(mob_desktop_path or DEFAULT_MOB_DESKTOP_PATH).expanduser(),
        comment_prefixes=("#",),
    )
    lightdm_autologin = _key_value_file_summary(
        Path(lightdm_autologin_path or DEFAULT_LIGHTDM_AUTOLOGIN_PATH),
        comment_prefixes=("#", ";"),
    )
    return {
        "autostart": autostart,
        "status_launcher": status_launcher,
        "mob_launcher": mob_launcher,
        "lightdm_autologin": lightdm_autologin,
        "graphical_target": _systemctl_system(["get-default"]),
        "lightdm_enabled": _systemctl_system(["is-enabled", "lightdm.service"]),
        "lightdm_active": _systemctl_system(["is-active", "lightdm.service"]),
    }


def _read_key_value_file_lines(
    path: Path,
    *,
    expected_stat: Optional[os.stat_result] = None,
) -> tuple[os.stat_result, list[str]]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        if path.is_symlink():
            raise RuntimeError(f"key-value file path is a symlink: {path}")
        raise
    try:
        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"key-value file path is not a regular file: {path}")
        if expected_stat is not None and (stat_result.st_dev, stat_result.st_ino) != (
            expected_stat.st_dev,
            expected_stat.st_ino,
        ):
            raise RuntimeError(f"key-value file path changed before it could be read: {path}")
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"key-value file path {path} has permissions {mode:04o}, "
                "expected no group/other write bits"
            )
        with os.fdopen(fd, encoding="utf-8") as handle:
            fd = -1
            return stat_result, handle.read().splitlines()
    finally:
        if fd >= 0:
            os.close(fd)


def _key_value_file_summary(path: Path, *, comment_prefixes: tuple[str, ...]) -> dict[str, object]:
    symlink_component = _first_symlink_ancestor(path.parent)
    summary: dict[str, object] = {
        "path": str(path),
        "exists": path.exists(),
        "is_symlink": path.is_symlink(),
        "directory_is_symlink": path.parent.is_symlink(),
        "path_symlink_component": str(symlink_component) if symlink_component is not None else "",
    }
    if path.is_symlink():
        summary["error"] = f"key-value file path is a symlink: {path}"
        return summary
    if symlink_component is not None:
        summary["error"] = f"key-value file directory is a symlink: {symlink_component}"
        return summary
    if not path.exists():
        return summary
    if not path.is_file():
        summary["error"] = f"key-value file path is not a regular file: {path}"
        return summary
    try:
        expected_stat = path.stat()
    except OSError as exc:
        summary["error"] = f"could not inspect key-value file path {path}: {exc}"
        return summary
    try:
        stat_result, lines = _read_key_value_file_lines(path, expected_stat=expected_stat)
    except Exception as exc:
        summary["error"] = str(exc)
        return summary
    summary["uid"] = stat_result.st_uid
    summary["mode"] = f"{stat_result.st_mode & 0o777:04o}"
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
    user: Optional[dict[str, object]] = None,
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
                            "ProtectSystem": "full",
                            "CapabilityBoundingSet": "",
                            "RestrictAddressFamilies": "AF_UNIX AF_INET AF_INET6",
                            "LockPersonality": "yes",
                            "RestrictSUIDSGID": "yes",
                            "MemoryDenyWriteExecute": "yes",
                            "RestrictRealtime": "yes",
                            "SystemCallArchitectures": "native",
                            "UMask": "0077",
                        },
                        unit_files,
                        "noaa-navionics.service",
                    ),
                    contains={
                        "ExecStartPre": [
                            ".local/share/noaa-navionics/venv/bin/noaa-navionics",
                            "noaa-navionics wait-network",
                            "--host",
                            "www.charts.noaa.gov",
                            "--port 443",
                            "--seconds 300",
                        ],
                        "ExecStart": [
                            ".local/share/noaa-navionics/venv/bin/noaa-navionics",
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
                            "TimeoutStopUSec": "30s",
                            "StartLimitIntervalUSec": "10min",
                            "StartLimitBurst": "60",
                            "NoNewPrivileges": "yes",
                            "PrivateTmp": "yes",
                            "ProtectSystem": "full",
                            "CapabilityBoundingSet": "",
                            "RestrictAddressFamilies": "AF_UNIX AF_INET AF_INET6",
                            "LockPersonality": "yes",
                            "RestrictSUIDSGID": "yes",
                            "MemoryDenyWriteExecute": "yes",
                            "RestrictRealtime": "yes",
                            "SystemCallArchitectures": "native",
                            "UMask": "0077",
                        },
                        unit_files,
                        "noaa-navionics-track.service",
                    ),
                    contains={
                        "ExecStart": [
                            ".local/share/noaa-navionics/venv/bin/noaa-navionics",
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
                            "Environment": "",
                            "EnvironmentFiles": "",
                            "TimeoutStartUSec": "15min",
                            "Restart": "on-failure",
                            "RestartUSec": "30s",
                            "StartLimitIntervalUSec": "30min",
                            "StartLimitBurst": "60",
                            "NoNewPrivileges": "yes",
                            "PrivateTmp": "yes",
                            "ProtectSystem": "full",
                            "CapabilityBoundingSet": "",
                            "RestrictAddressFamilies": "AF_UNIX AF_INET AF_INET6",
                            "LockPersonality": "yes",
                            "RestrictSUIDSGID": "yes",
                            "MemoryDenyWriteExecute": "yes",
                            "RestrictRealtime": "yes",
                            "SystemCallArchitectures": "native",
                            "UMask": "0077",
                        },
                        unit_files,
                        "noaa-navionics-preflight.service",
                    ),
                    contains={
                        "Wants": "noaa-navionics-track.service",
                        "After": "noaa-navionics-track.service",
                        "ExecStart": [
                            ".local/share/noaa-navionics/venv/bin/noaa-navionics",
                            "noaa-navionics status-report",
                            "--config",
                            "noaa-navionics/config.ini",
                            "--gps-seconds-from-launcher-env",
                            "noaa-navionics/launcher.env",
                            "--output",
                            "noaa-navionics/status.json",
                        ],
                    },
                ),
                _preflight_execution_check(
                    services,
                    "noaa-navionics-preflight.service",
                    "Boot Readiness Run",
                ),
            ]
        )
    if user is not None:
        checks.append(_user_linger_check(user))
    if unit_files is not None:
        checks.extend(
            [
                _unit_file_contains_check(
                    unit_files,
                    "noaa-navionics.service",
                    "Chart Sync Unit File",
                    [
                        "Type=oneshot",
                        "ExecStartPre=%h/.local/share/noaa-navionics/venv/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300",
                        "ExecStart=%h/.local/share/noaa-navionics/venv/bin/noaa-navionics sync-charts --config %h/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30",
                        "TimeoutStartSec=2h",
                        "Restart=on-failure",
                        "RestartSec=30min",
                        "StartLimitIntervalSec=6h",
                        "StartLimitBurst=3",
                    ],
                ),
                _unit_file_contains_check(
                    unit_files,
                    "noaa-navionics.timer",
                    "Chart Timer Unit File",
                    [
                        "OnCalendar=weekly",
                        "Persistent=true",
                        "RandomizedDelaySec=30min",
                    ],
                ),
                _unit_file_contains_check(
                    unit_files,
                    "noaa-navionics-track.service",
                    "Track Logger Unit File",
                    [
                        "Type=simple",
                        "ExecStart=%h/.local/share/noaa-navionics/venv/bin/noaa-navionics log-track --config %h/.config/noaa-navionics/config.ini --rotate-daily",
                        "StandardOutput=null",
                        "Restart=on-failure",
                        "RestartSec=10",
                        "TimeoutStopSec=30s",
                        "StartLimitIntervalSec=10min",
                        "StartLimitBurst=60",
                    ],
                ),
                _unit_file_contains_check(
                    unit_files,
                    "noaa-navionics-preflight.service",
                    "Boot Readiness Unit File",
                    [
                        "Wants=noaa-navionics-track.service",
                        "After=noaa-navionics-track.service",
                        "Type=oneshot",
                        "ExecStart=%h/.local/share/noaa-navionics/venv/bin/noaa-navionics status-report --config %h/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env %h/.config/noaa-navionics/launcher.env --output %h/.cache/noaa-navionics/status.json",
                        "TimeoutStartSec=15min",
                        "Restart=on-failure",
                        "RestartSec=30",
                        "StartLimitIntervalSec=30min",
                        "StartLimitBurst=60",
                    ],
                ),
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


def _user_linger_check(summary: dict[str, object]) -> CheckResult:
    name_value = summary.get("name", "")
    if not isinstance(name_value, str):
        return CheckResult("User Linger", False, "user name is not text")
    name = name_value.strip()
    control_failure = _status_control_character_failure(name, "user name")
    if control_failure:
        return CheckResult("User Linger", False, control_failure.removeprefix("status report "))
    error_value = summary.get("error", "")
    if not isinstance(error_value, str):
        return CheckResult("User Linger", False, "user error is not text")
    error = error_value.strip()
    control_failure = _status_control_character_failure(error, "user error")
    if control_failure:
        return CheckResult("User Linger", False, control_failure.removeprefix("status report "))
    if error:
        return CheckResult("User Linger", False, f"{name or '<unknown>'}: {error}")
    linger_value = summary.get("linger", "")
    if not isinstance(linger_value, str):
        return CheckResult("User Linger", False, "user linger is not text")
    linger = linger_value.strip()
    control_failure = _status_control_character_failure(linger, "user linger")
    if control_failure:
        return CheckResult("User Linger", False, control_failure.removeprefix("status report "))
    if linger != "yes":
        return CheckResult("User Linger", False, f"{name or '<unknown>'} linger={linger or '<missing>'}, expected yes")
    return CheckResult("User Linger", True, f"{name} has linger enabled for reboot-persistent user services")


def _launcher_settings_check(summary: dict[str, object]) -> CheckResult:
    path = str(summary.get("path", DEFAULT_LAUNCHER_ENV_PATH.expanduser()))
    if summary.get("exists") is not True:
        return CheckResult("Launcher Settings", False, f"launcher environment is missing: {path}")
    if summary.get("is_symlink") is not False:
        return CheckResult(
            "Launcher Settings",
            False,
            f"launcher environment path is a symlink or missing symlink status: {path}",
        )
    if summary.get("directory_is_symlink") is not False:
        directory = str(Path(path).parent)
        return CheckResult(
            "Launcher Settings",
            False,
            f"launcher environment directory is a symlink or missing symlink status: {directory}",
        )
    if "launcher_settings_symlink_component" not in summary:
        return CheckResult(
            "Launcher Settings",
            False,
            f"launcher environment missing launcher_settings_symlink_component: {path}",
        )
    symlink_component = str(summary.get("launcher_settings_symlink_component", "")).strip()
    if symlink_component:
        return CheckResult(
            "Launcher Settings",
            False,
            f"launcher environment directory is a symlink: {symlink_component}",
        )
    error = str(summary.get("error", ""))
    if error:
        return CheckResult("Launcher Settings", False, f"launcher environment unreadable at {path}: {error}")
    directory_uid = summary.get("directory_uid")
    if directory_uid is not None:
        try:
            parsed_directory_uid = int(directory_uid)
        except (TypeError, ValueError):
            return CheckResult(
                "Launcher Settings",
                False,
                f"launcher environment directory owner was not parsed: {Path(path).parent}",
            )
        if parsed_directory_uid != os.getuid():
            return CheckResult(
                "Launcher Settings",
                False,
                f"launcher environment directory {Path(path).parent} is owned by uid "
                f"{parsed_directory_uid}, expected {os.getuid()}",
            )
    directory_mode = str(summary.get("directory_mode", "")).strip()
    if directory_mode:
        try:
            parsed_directory_mode = int(directory_mode, 8)
        except ValueError:
            return CheckResult(
                "Launcher Settings",
                False,
                f"launcher environment directory mode was not parsed: {Path(path).parent}",
            )
        if parsed_directory_mode & 0o022:
            return CheckResult(
                "Launcher Settings",
                False,
                f"launcher environment directory {Path(path).parent} has permissions {directory_mode}, "
                "expected no group/other write bits",
            )
    uid = summary.get("uid")
    if uid is not None:
        try:
            parsed_uid = int(uid)
        except (TypeError, ValueError):
            return CheckResult("Launcher Settings", False, f"launcher environment owner was not parsed: {path}")
        if parsed_uid != os.getuid():
            return CheckResult(
                "Launcher Settings",
                False,
                f"launcher environment is owned by uid {parsed_uid}, expected {os.getuid()}: {path}",
            )
    mode = str(summary.get("mode", "")).strip()
    if mode and mode != "0600":
        return CheckResult(
            "Launcher Settings",
            False,
            f"launcher environment has permissions {mode}, expected private 0600: {path}",
        )
    values = summary.get("values", {})
    if not isinstance(values, dict):
        return CheckResult("Launcher Settings", False, f"launcher environment values were not parsed: {path}")

    failures = []
    malformed_lines = summary.get("malformed_lines", [])
    if isinstance(malformed_lines, list):
        failures.extend(f"malformed launcher environment line {line}" for line in malformed_lines)
    else:
        failures.append("malformed launcher environment lines were not parsed")
    unknown_keys = sorted(str(key) for key in values if str(key) not in LAUNCHER_ENV_KEYS)
    if unknown_keys:
        failures.append("unknown launcher environment key(s): " + ", ".join(unknown_keys))
    gps_seconds = str(values.get("NOAA_NAVIONICS_GPS_SECONDS", "")).strip()
    if not gps_seconds.isdigit() or int(gps_seconds) <= 0:
        failures.append(f"NOAA_NAVIONICS_GPS_SECONDS={gps_seconds or '<missing>'} expected positive integer")
    elif int(gps_seconds) > LAUNCHER_ENV_INTEGER_LIMITS["NOAA_NAVIONICS_GPS_SECONDS"]:
        failures.append(
            f"NOAA_NAVIONICS_GPS_SECONDS={gps_seconds} expected at most "
            f"{LAUNCHER_ENV_INTEGER_LIMITS['NOAA_NAVIONICS_GPS_SECONDS']}"
        )
    attempts = str(values.get("NOAA_NAVIONICS_READINESS_ATTEMPTS", "")).strip()
    if attempts and (not attempts.isdigit() or int(attempts) <= 0):
        failures.append(f"NOAA_NAVIONICS_READINESS_ATTEMPTS={attempts} expected positive integer")
    elif attempts and int(attempts) > LAUNCHER_ENV_INTEGER_LIMITS["NOAA_NAVIONICS_READINESS_ATTEMPTS"]:
        failures.append(
            f"NOAA_NAVIONICS_READINESS_ATTEMPTS={attempts} expected at most "
            f"{LAUNCHER_ENV_INTEGER_LIMITS['NOAA_NAVIONICS_READINESS_ATTEMPTS']}"
        )
    retry_delay = str(values.get("NOAA_NAVIONICS_READINESS_RETRY_DELAY", "")).strip()
    if retry_delay and (not retry_delay.isdigit() or int(retry_delay) < 0):
        failures.append(f"NOAA_NAVIONICS_READINESS_RETRY_DELAY={retry_delay} expected non-negative integer")
    elif retry_delay and int(retry_delay) > LAUNCHER_ENV_INTEGER_LIMITS["NOAA_NAVIONICS_READINESS_RETRY_DELAY"]:
        failures.append(
            f"NOAA_NAVIONICS_READINESS_RETRY_DELAY={retry_delay} expected at most "
            f"{LAUNCHER_ENV_INTEGER_LIMITS['NOAA_NAVIONICS_READINESS_RETRY_DELAY']}"
        )
    warning_seconds = str(values.get("NOAA_NAVIONICS_WARNING_SECONDS", "")).strip()
    if warning_seconds and (not warning_seconds.isdigit() or int(warning_seconds) < 0):
        failures.append(f"NOAA_NAVIONICS_WARNING_SECONDS={warning_seconds} expected non-negative integer")
    elif warning_seconds and int(warning_seconds) > LAUNCHER_ENV_INTEGER_LIMITS["NOAA_NAVIONICS_WARNING_SECONDS"]:
        failures.append(
            f"NOAA_NAVIONICS_WARNING_SECONDS={warning_seconds} expected at most "
            f"{LAUNCHER_ENV_INTEGER_LIMITS['NOAA_NAVIONICS_WARNING_SECONDS']}"
        )
    opencpn_restarts = str(values.get("NOAA_NAVIONICS_OPENCPN_RESTARTS", "")).strip()
    if opencpn_restarts and (not opencpn_restarts.isdigit() or int(opencpn_restarts) < 0):
        failures.append(f"NOAA_NAVIONICS_OPENCPN_RESTARTS={opencpn_restarts} expected non-negative integer")
    elif opencpn_restarts and int(opencpn_restarts) > LAUNCHER_ENV_INTEGER_LIMITS["NOAA_NAVIONICS_OPENCPN_RESTARTS"]:
        failures.append(
            f"NOAA_NAVIONICS_OPENCPN_RESTARTS={opencpn_restarts} expected at most "
            f"{LAUNCHER_ENV_INTEGER_LIMITS['NOAA_NAVIONICS_OPENCPN_RESTARTS']}"
        )
    opencpn_restart_delay = str(values.get("NOAA_NAVIONICS_OPENCPN_RESTART_DELAY", "")).strip()
    if opencpn_restart_delay and (not opencpn_restart_delay.isdigit() or int(opencpn_restart_delay) < 0):
        failures.append(
            f"NOAA_NAVIONICS_OPENCPN_RESTART_DELAY={opencpn_restart_delay} expected non-negative integer"
        )
    elif opencpn_restart_delay and int(opencpn_restart_delay) > LAUNCHER_ENV_INTEGER_LIMITS[
        "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY"
    ]:
        failures.append(
            f"NOAA_NAVIONICS_OPENCPN_RESTART_DELAY={opencpn_restart_delay} expected at most "
            f"{LAUNCHER_ENV_INTEGER_LIMITS['NOAA_NAVIONICS_OPENCPN_RESTART_DELAY']}"
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
        if autostart.get("is_symlink") is not False:
            failures.append(f"desktop autostart path is a symlink or missing symlink status: {path}")
        if autostart.get("directory_is_symlink") is not False:
            failures.append(
                f"desktop autostart directory is a symlink or missing symlink status: {Path(path).parent}"
            )
        if "path_symlink_component" not in autostart:
            failures.append(f"desktop autostart missing path_symlink_component: {path}")
        autostart_symlink_component = str(autostart.get("path_symlink_component", "")).strip()
        if autostart_symlink_component:
            failures.append(f"desktop autostart path contains a symlink: {autostart_symlink_component}")
        if str(autostart.get("error", "")):
            failures.append(f"desktop autostart unreadable at {path}: {autostart.get('error')}")
        failures.extend(
            _key_value_file_integrity_failures(
                autostart,
                label="desktop autostart",
                expected_uid=os.getuid(),
            )
        )
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

    status_launcher = summary.get("status_launcher")
    if not isinstance(status_launcher, dict):
        failures.append("status GUI desktop launcher summary missing")
    else:
        path = str(status_launcher.get("path", DEFAULT_STATUS_DESKTOP_PATH.expanduser()))
        if status_launcher.get("exists") is not True:
            failures.append(f"status GUI desktop launcher missing at {path}")
        if status_launcher.get("is_symlink") is not False:
            failures.append(f"status GUI desktop launcher path is a symlink or missing symlink status: {path}")
        if status_launcher.get("directory_is_symlink") is not False:
            failures.append(
                f"status GUI desktop launcher directory is a symlink or missing symlink status: {Path(path).parent}"
            )
        if "path_symlink_component" not in status_launcher:
            failures.append(f"status GUI desktop launcher missing path_symlink_component: {path}")
        status_symlink_component = str(status_launcher.get("path_symlink_component", "")).strip()
        if status_symlink_component:
            failures.append(f"status GUI desktop launcher path contains a symlink: {status_symlink_component}")
        if str(status_launcher.get("error", "")):
            failures.append(f"status GUI desktop launcher unreadable at {path}: {status_launcher.get('error')}")
        failures.extend(
            _key_value_file_integrity_failures(
                status_launcher,
                label="status GUI desktop launcher",
                expected_uid=os.getuid(),
            )
        )
        failures.extend(_user_executable_mode_failures(status_launcher, label="status GUI desktop launcher"))
        values = status_launcher.get("values")
        if not isinstance(values, dict):
            failures.append(f"status GUI desktop launcher values were not parsed at {path}")
        else:
            expected_values = {
                "Type": "Application",
                "Name": "NOAA Navionics Status",
                "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-status-gui"',
                "Terminal": "false",
            }
            for key, expected in expected_values.items():
                actual = str(values.get(key, "")).strip()
                if actual != expected:
                    failures.append(f"status GUI desktop launcher {key}={actual or '<missing>'} expected {expected}")
            hidden = str(values.get("Hidden", "")).strip().lower()
            if hidden == "true":
                failures.append("status GUI desktop launcher Hidden=true hides the readiness panel")
            autostart_enabled = str(values.get("X-GNOME-Autostart-enabled", "")).strip().lower()
            if autostart_enabled == "true":
                failures.append("status GUI desktop launcher must not be configured for autostart")

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
        if lightdm.get("is_symlink") is not False:
            failures.append(
                f"LightDM autologin config path is a symlink or missing symlink status: {path}"
            )
        if lightdm.get("directory_is_symlink") is not False:
            failures.append(
                f"LightDM autologin config directory is a symlink or missing symlink status: {Path(path).parent}"
            )
        if "path_symlink_component" not in lightdm:
            failures.append(f"LightDM autologin config missing path_symlink_component: {path}")
        lightdm_symlink_component = str(lightdm.get("path_symlink_component", "")).strip()
        if lightdm_symlink_component:
            failures.append(f"LightDM autologin config path contains a symlink: {lightdm_symlink_component}")
        if str(lightdm.get("error", "")):
            failures.append(f"LightDM autologin config unreadable at {path}: {lightdm.get('error')}")
        failures.extend(
            _key_value_file_integrity_failures(
                lightdm,
                label="LightDM autologin config",
                expected_uid=0,
            )
        )
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

    mob_launcher = summary.get("mob_launcher")
    if not isinstance(mob_launcher, dict):
        failures.append("MOB desktop launcher summary missing")
    else:
        path = str(mob_launcher.get("path", DEFAULT_MOB_DESKTOP_PATH.expanduser()))
        if mob_launcher.get("exists") is not True:
            failures.append(f"MOB desktop launcher missing at {path}")
        if mob_launcher.get("is_symlink") is not False:
            failures.append(f"MOB desktop launcher path is a symlink or missing symlink status: {path}")
        if mob_launcher.get("directory_is_symlink") is not False:
            failures.append(
                f"MOB desktop launcher directory is a symlink or missing symlink status: {Path(path).parent}"
            )
        if "path_symlink_component" not in mob_launcher:
            failures.append(f"MOB desktop launcher missing path_symlink_component: {path}")
        mob_symlink_component = str(mob_launcher.get("path_symlink_component", "")).strip()
        if mob_symlink_component:
            failures.append(f"MOB desktop launcher path contains a symlink: {mob_symlink_component}")
        if str(mob_launcher.get("error", "")):
            failures.append(f"MOB desktop launcher unreadable at {path}: {mob_launcher.get('error')}")
        failures.extend(
            _key_value_file_integrity_failures(
                mob_launcher,
                label="MOB desktop launcher",
                expected_uid=os.getuid(),
            )
        )
        failures.extend(_user_executable_mode_failures(mob_launcher, label="MOB desktop launcher"))
        values = mob_launcher.get("values")
        if not isinstance(values, dict):
            failures.append(f"MOB desktop launcher values were not parsed at {path}")
        else:
            expected_values = {
                "Type": "Application",
                "Name": "NOAA Navionics MOB",
                "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics mob; printf \'\\nPress Enter to close...\'; read _"',
                "Terminal": "true",
            }
            for key, expected in expected_values.items():
                actual = str(values.get(key, "")).strip()
                if actual != expected:
                    failures.append(f"MOB desktop launcher {key}={actual or '<missing>'} expected {expected}")
            hidden = str(values.get("Hidden", "")).strip().lower()
            if hidden == "true":
                failures.append("MOB desktop launcher Hidden=true hides the emergency launcher")
            autostart_enabled = str(values.get("X-GNOME-Autostart-enabled", "")).strip().lower()
            if autostart_enabled == "true":
                failures.append("MOB desktop launcher must not be configured for autostart")

    if failures:
        return CheckResult("Desktop Startup", False, "; ".join(failures))
    active = str(summary.get("lightdm_active", "")).strip() or "<unknown>"
    return CheckResult(
        "Desktop Startup",
        True,
        f"desktop autostart, status GUI launcher, MOB launcher, and LightDM autologin are configured; lightdm active={active}",
    )


def _key_value_file_integrity_failures(
    summary: dict[str, object],
    *,
    label: str,
    expected_uid: int,
) -> list[str]:
    failures = []
    path = str(summary.get("path", "<unknown>"))
    uid = summary.get("uid")
    if uid is not None:
        try:
            parsed_uid = int(uid)
        except (TypeError, ValueError):
            failures.append(f"{label} owner was not parsed at {path}")
        else:
            if parsed_uid != expected_uid:
                failures.append(f"{label} is owned by uid {parsed_uid}, expected {expected_uid}: {path}")
    mode = str(summary.get("mode", "")).strip()
    if mode:
        try:
            parsed_mode = int(mode, 8)
        except ValueError:
            failures.append(f"{label} permissions were not parsed at {path}: {mode}")
        else:
            if parsed_mode & 0o022:
                failures.append(f"{label} has permissions {mode}, expected no group/other write bits: {path}")
    return failures


def _user_executable_mode_failures(summary: dict[str, object], *, label: str) -> list[str]:
    path = str(summary.get("path", "<unknown>"))
    mode = str(summary.get("mode", "")).strip()
    if not mode:
        return [f"{label} permissions were not parsed at {path}"]
    try:
        parsed_mode = int(mode, 8)
    except ValueError:
        return [f"{label} permissions were not parsed at {path}: {mode}"]
    if not parsed_mode & stat.S_IXUSR:
        return [f"{label} has permissions {mode}, expected user executable bit: {path}"]
    return []


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
    common_error = _unit_file_common_error(state, unit, path)
    if common_error:
        return CheckResult(name, False, common_error)
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


def _unit_file_contains_check(
    summary: dict[str, object],
    unit: str,
    name: str,
    expected_lines: list[str],
) -> CheckResult:
    state = summary.get(unit)
    if not isinstance(state, dict):
        return CheckResult(name, False, f"{unit} missing from unit file summary")
    path = str(state.get("path", unit))
    common_error = _unit_file_common_error(state, unit, path)
    if common_error:
        return CheckResult(name, False, common_error)
    lines = state.get("lines")
    if not isinstance(lines, list):
        return CheckResult(name, False, f"{unit} has no parsed unit file lines at {path}")
    stripped_lines = {str(line).strip() for line in lines}
    missing = [line for line in expected_lines if line not in stripped_lines]
    if missing:
        return CheckResult(name, False, f"{unit} missing unit file lines: {', '.join(missing)}")
    return CheckResult(name, True, f"{unit} contains expected service settings")


def _unit_file_common_error(state: dict[str, object], unit: str, path: str) -> str:
    if state.get("exists") is not True:
        return f"{unit} unit file is missing at {path}"
    if state.get("is_symlink") is not False:
        return f"{unit} unit file path is a symlink or missing symlink status: {path}"
    if state.get("directory_is_symlink") is not False:
        return f"{unit} unit file directory is a symlink or missing symlink status: {Path(path).parent}"
    if "path_symlink_component" not in state:
        return f"{unit} unit file missing path_symlink_component: {path}"
    symlink_component = str(state.get("path_symlink_component", "")).strip()
    if symlink_component:
        return f"{unit} unit file path contains a symlink: {symlink_component}"
    directory_error = str(state.get("directory_error", "")).strip()
    if directory_error:
        return f"{unit} unit file directory unreadable at {Path(path).parent}: {directory_error}"
    error = str(state.get("error", ""))
    if error:
        return f"{unit} unit file unreadable at {path}: {error}"
    owner_check = _owned_by_current_user(state, "uid")
    if owner_check:
        return f"{unit} unit file {owner_check}: {path}"
    directory_owner_check = _owned_by_current_user(state, "directory_uid")
    if directory_owner_check:
        return f"{unit} unit file directory {directory_owner_check}: {Path(path).parent}"
    mode_check = _not_group_or_other_writable(state, "mode")
    if mode_check:
        return f"{unit} unit file {mode_check}: {path}"
    directory_mode_check = _not_group_or_other_writable(state, "directory_mode")
    if directory_mode_check:
        return f"{unit} unit file directory {directory_mode_check}: {Path(path).parent}"
    return ""


def _owned_by_current_user(summary: dict[str, object], key: str) -> str:
    value = summary.get(key)
    if value is None or value == "":
        return f"{key}=<missing>, expected {os.getuid()}"
    try:
        uid = int(str(value))
    except ValueError:
        return f"{key}={value}, expected {os.getuid()}"
    if uid != os.getuid():
        return f"{key}={uid}, expected {os.getuid()}"
    return ""


def _not_group_or_other_writable(summary: dict[str, object], key: str) -> str:
    value = str(summary.get(key, "")).strip()
    if not value:
        return f"{key}=<missing>, expected no group/other write bits"
    try:
        mode = int(value, 8)
    except ValueError:
        return f"{key}={value}, expected octal permissions"
    if mode & 0o022:
        return f"{key}={mode:04o}, expected no group/other write bits"
    return ""


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
    if error is not None and not isinstance(error, str):
        return CheckResult(name, False, f"{unit} loaded properties error is not text")
    if isinstance(error, str) and _status_text_has_control_char(error):
        return CheckResult(name, False, f"{unit} loaded properties error contains control characters")
    if isinstance(error, str) and error:
        return CheckResult(name, False, f"{unit} loaded properties unavailable: {error}")

    failures = []
    for key, expected in (exact or {}).items():
        actual, failure = _unit_property_text(properties, unit, key, name)
        if failure:
            return failure
        if actual != expected:
            failures.append(f"{key}={actual or '<missing>'} expected {expected}")
    for key, expected_value in (contains or {}).items():
        actual, failure = _unit_property_text(properties, unit, key, name)
        if failure:
            return failure
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
    if error is not None and not isinstance(error, str):
        return CheckResult(name, False, f"{unit} loaded properties error is not text")
    if isinstance(error, str) and _status_text_has_control_char(error):
        return CheckResult(name, False, f"{unit} loaded properties error contains control characters")
    if isinstance(error, str) and error:
        return CheckResult(name, False, f"{unit} loaded properties unavailable: {error}")
    active, failure = _unit_state_text(state, unit, "active", name)
    if failure:
        return failure
    result, failure = _unit_property_text(properties, unit, "Result", name)
    if failure:
        return failure
    status, failure = _unit_property_text(properties, unit, "ExecMainStatus", name)
    if failure:
        return failure
    started, failure = _unit_property_text(properties, unit, "ExecMainStartTimestampMonotonic", name)
    if failure:
        return failure
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
    enabled, failure = _unit_state_text(state, unit, "enabled", name)
    if failure:
        return failure
    active, failure = _unit_state_text(state, unit, "active", name)
    if failure:
        return failure
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
    enabled, failure = _unit_state_text(state, unit, "enabled", name)
    if failure:
        return failure
    active, failure = _unit_state_text(state, unit, "active", name)
    if failure:
        return failure
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
    enabled, failure = _unit_state_text(state, unit, "enabled", name)
    if failure:
        return failure
    active, failure = _unit_state_text(state, unit, "active", name)
    if failure:
        return failure
    if _unit_query_failed(enabled) or _unit_query_failed(active):
        return CheckResult(name, False, f"{unit} enabled={enabled} active={active}")
    if active == "failed":
        return CheckResult(name, False, f"{unit} enabled={enabled} active={active}")
    enabled_ok = not require_enabled or enabled in {"enabled", "static", "generated"}
    active_ok = not require_active or active in {"active", "activating"}
    ok = enabled_ok and active_ok
    detail = f"{unit} enabled={enabled} active={active}"
    return CheckResult(name, ok, detail)


def _unit_state_text(
    state: dict[str, object],
    unit: str,
    field: str,
    name: str,
) -> tuple[str, Optional[CheckResult]]:
    value = state.get(field, "")
    if not isinstance(value, str):
        return "", CheckResult(name, False, f"{unit} {field} is not text")
    text = value.strip()
    if _status_text_has_control_char(text):
        return "", CheckResult(name, False, f"{unit} {field} contains control characters")
    return text, None


def _unit_property_text(
    properties: dict[str, object],
    unit: str,
    key: str,
    name: str,
) -> tuple[str, Optional[CheckResult]]:
    value = properties.get(key, "")
    if not isinstance(value, str):
        return "", CheckResult(name, False, f"{unit} {key} is not text")
    if _status_text_has_control_char(value):
        return "", CheckResult(name, False, f"{unit} {key} contains control characters")
    return value, None


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
    systemctl, error = _trusted_system_command("systemctl", "Systemctl command")
    if error:
        return {"error": error}
    assert systemctl is not None
    property_args = []
    for prop in properties:
        property_args.extend(["-p", prop])
    try:
        completed = subprocess.run(
            [str(systemctl), "--user", "show", unit, *property_args],
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
    if command and command[0] == "systemctl":
        systemctl, error = _trusted_system_command("systemctl", "Systemctl command")
        if error:
            return f"error: {error}"
        assert systemctl is not None
        command = [str(systemctl), *command[1:]]
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
