from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
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
from .health import CheckResult, check_opencpn_gpsd_config, run_preflight, _trusted_enc_cell_tree_count, _trusted_system_command
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
        wait_seconds=min(max(float(gps_seconds), 10.0), 60.0),
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
        bool(report.get("ok"))
        and not status_report_validation_failures(report, now=now)
        and _report_check_sections_all_ok(report)
    )


def status_report_validation_failures(
    report: dict[str, object],
    *,
    now: Optional[datetime] = None,
) -> list[CheckResult]:
    failures = _generated_at_validation_failures(report.get("generated_at"), now=now)
    failures.extend(_host_validation_failures(report.get("host")))
    failures.extend(_app_validation_failures(report.get("app")))
    failures.extend(_config_validation_failures(report))
    failures.extend(_user_validation_failures(report.get("user")))
    failures.extend(_unit_files_validation_failures(report.get("unit_files")))
    failures.extend(_launcher_settings_validation_failures(report.get("launcher_settings")))
    failures.extend(_opencpn_config_validation_failures(report))
    failures.extend(_desktop_validation_failures(report))
    failures.extend(_manifest_validation_failures(report.get("manifest")))
    failures.extend(_gps_fix_validation_failures(report, now=now))
    failures.extend(_track_log_validation_failures(report.get("track_log")))
    for section_name in ("checks", "service_checks"):
        section = report.get(section_name)
        if not isinstance(section, list):
            failures.append(CheckResult("Status Report", False, f"status report missing {section_name} section"))
            continue
        if any(not isinstance(item, dict) for item in section):
            failures.append(CheckResult("Status Report", False, f"status report has malformed {section_name} row"))
    missing_checks, missing_service_checks = missing_required_readiness_checks(report)
    failures.extend(
        CheckResult(name, False, "status report is missing this readiness check") for name in missing_checks
    )
    failures.extend(
        CheckResult(name, False, "status report is missing this service check") for name in missing_service_checks
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
    if parsed.tzinfo is None:
        return [CheckResult("Status Report", False, "status report generated_at timestamp must include a timezone")]
    current = now or datetime.now(timezone.utc)
    age_seconds = (current.astimezone(timezone.utc) - parsed.astimezone(timezone.utc)).total_seconds()
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
    boot_id = str(host.get("boot_id", "")).strip()
    if not boot_id or boot_id == "unknown":
        return [CheckResult("Status Report", False, "status report missing valid host boot_id")]
    if not BOOT_ID_RE.fullmatch(boot_id):
        return [CheckResult("Status Report", False, f"status report host boot_id is not a Linux boot_id value: {boot_id}")]
    return []


def _app_validation_failures(app: object) -> list[CheckResult]:
    if not isinstance(app, dict):
        return [CheckResult("Status Report", False, "status report missing app section")]
    source_revision = app.get("source_revision")
    if not isinstance(source_revision, str) or not source_revision.strip() or source_revision.strip() == "unknown":
        return [CheckResult("Status Report", False, "status report missing deployed source_revision")]
    if not str(app.get("source_revision_path", "")).strip():
        return [CheckResult("Status Report", False, "status report missing source_revision_path")]
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
    if str(app.get("source_revision_symlink_component", "")).strip():
        return [CheckResult("Status Report", False, "status report source revision path contains a symlink")]
    source_revision_error = str(app.get("source_revision_error", "")).strip()
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
    config = report.get("config")
    if not isinstance(config, dict):
        return [CheckResult("Config", False, "status report missing config section")]
    chart_package = str(config.get("chart_package", "")).strip().lower()
    if chart_package not in CHART_PACKAGES:
        return [CheckResult("Config", False, f"status report config chart_package is invalid: {chart_package or '<missing>'}")]
    chart_value = str(config.get("chart_value", "")).strip()
    if chart_package in CHART_PACKAGES_REQUIRING_VALUE and not chart_value:
        return [CheckResult("Config", False, f"status report config chart_value is required for {chart_package}")]
    chart_output = str(config.get("chart_output", "")).strip()
    track_output = str(config.get("track_output", "")).strip()
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
    gps_mode = str(config.get("gps_mode", "")).strip().lower()
    if gps_mode not in {"gpsd", "serial"}:
        return [CheckResult("Config", False, f"status report config gps_mode is invalid: {gps_mode or '<missing>'}")]
    gps_device = str(config.get("gps_device", "")).strip()
    if not gps_device:
        return [CheckResult("Config", False, "status report config gps_device is empty")]
    gps_baud = config.get("gps_baud")
    if isinstance(gps_baud, bool) or not isinstance(gps_baud, int) or gps_baud not in GPS_BAUD_RATES:
        return [CheckResult("Config", False, f"status report config gps_baud is invalid: {gps_baud!r}")]
    gpsd_host = str(config.get("gpsd_host", "")).strip()
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


def _user_validation_failures(user: object) -> list[CheckResult]:
    if not isinstance(user, dict):
        return [CheckResult("User Linger", False, "status report missing user section")]
    name = str(user.get("name", "")).strip()
    if not name:
        return [CheckResult("User Linger", False, "status report user name is empty")]
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
                "ExecStartPre=%h/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300",
                "ExecStart=%h/.local/bin/noaa-navionics sync-charts --config %h/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30",
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
                "ExecStart=%h/.local/bin/noaa-navionics log-track --config %h/.config/noaa-navionics/config.ini --rotate-daily",
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
                "ExecStart=%h/.local/bin/noaa-navionics status-report --config %h/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env %h/.config/noaa-navionics/launcher.env --output %h/.cache/noaa-navionics/status.json",
                "TimeoutStartSec=0",
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
    path = str(launcher_settings.get("path", "")).strip()
    if not path:
        return [CheckResult("Launcher Settings", False, "status report launcher settings path is empty")]
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
    if str(launcher_settings.get("launcher_settings_symlink_component", "")).strip():
        return [CheckResult("Launcher Settings", False, "status report launcher settings path contains a symlink")]
    error = str(launcher_settings.get("error", "")).strip()
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
    unknown_keys = sorted(str(key) for key in values if str(key) not in LAUNCHER_ENV_KEYS)
    if unknown_keys:
        failures.append("unknown launcher settings key(s): " + ", ".join(unknown_keys))

    def required_positive_integer(key: str) -> None:
        value = str(values.get(key, "")).strip()
        if not value.isdigit() or int(value) <= 0:
            failures.append(f"{key}={value or '<missing>'} expected positive integer")

    def required_nonnegative_integer(key: str) -> None:
        value = str(values.get(key, "")).strip()
        if not value.isdigit() or int(value) < 0:
            failures.append(f"{key}={value or '<missing>'} expected non-negative integer")

    required_positive_integer("NOAA_NAVIONICS_GPS_SECONDS")
    required_positive_integer("NOAA_NAVIONICS_READINESS_ATTEMPTS")
    required_nonnegative_integer("NOAA_NAVIONICS_READINESS_RETRY_DELAY")
    required_nonnegative_integer("NOAA_NAVIONICS_WARNING_SECONDS")
    required_nonnegative_integer("NOAA_NAVIONICS_OPENCPN_RESTARTS")
    required_nonnegative_integer("NOAA_NAVIONICS_OPENCPN_RESTART_DELAY")
    fail_open = str(values.get("NOAA_NAVIONICS_START_ON_FAILED_READINESS", "")).strip().lower()
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
    path = str(opencpn_config.get("path", "")).strip()
    if not path:
        return [CheckResult("OpenCPN Config", False, "status report OpenCPN config path is empty")]
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
    if str(opencpn_config.get("config_symlink_component", "")).strip():
        return [CheckResult("OpenCPN Config", False, "status report OpenCPN config path contains a symlink")]
    error = str(opencpn_config.get("error", "")).strip()
    if error:
        return [CheckResult("OpenCPN Config", False, f"status report OpenCPN config error: {error}")]

    chart_directories = opencpn_config.get("chart_directories")
    data_connections = opencpn_config.get("data_connections")
    if not isinstance(chart_directories, list) or any(not isinstance(value, str) for value in chart_directories):
        return [CheckResult("OpenCPN Config", False, "status report OpenCPN chart directories were not parsed")]
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
    autostart = desktop.get("autostart")
    if not isinstance(autostart, dict):
        failures.append("status report missing desktop autostart section")
    else:
        path = str(autostart.get("path", "")).strip()
        if not path:
            failures.append("status report desktop autostart path is empty")
        elif not _status_absolute_path(path):
            failures.append(f"status report desktop autostart path is not absolute: {path}")
        if autostart.get("exists") is not True:
            failures.append(f"status report desktop autostart does not exist: {path or '<missing>'}")
        if autostart.get("is_symlink") is not False:
            failures.append("status report desktop autostart path is a symlink or missing symlink status")
        if autostart.get("directory_is_symlink") is not False:
            failures.append("status report desktop autostart directory is a symlink or missing symlink status")
        if "path_symlink_component" not in autostart:
            failures.append("status report desktop autostart missing path_symlink_component")
        elif str(autostart.get("path_symlink_component", "")).strip():
            failures.append("status report desktop autostart path contains a symlink")
        error = str(autostart.get("error", "")).strip()
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
        path = str(lightdm.get("path", "")).strip()
        if not path:
            failures.append("status report LightDM autologin config path is empty")
        elif not _status_absolute_path(path):
            failures.append(f"status report LightDM autologin config path is not absolute: {path}")
        if lightdm.get("exists") is not True:
            failures.append(f"status report LightDM autologin config does not exist: {path or '<missing>'}")
        if lightdm.get("is_symlink") is not False:
            failures.append("status report LightDM autologin config path is a symlink or missing symlink status")
        if lightdm.get("directory_is_symlink") is not False:
            failures.append("status report LightDM autologin config directory is a symlink or missing symlink status")
        if "path_symlink_component" not in lightdm:
            failures.append("status report LightDM autologin config missing path_symlink_component")
        elif str(lightdm.get("path_symlink_component", "")).strip():
            failures.append("status report LightDM autologin config path contains a symlink")
        error = str(lightdm.get("error", "")).strip()
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
    if not str(manifest.get("path", "")).strip():
        return [CheckResult("Chart Manifest", False, "status report manifest path is empty")]
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
        if str(manifest.get(field, "")).strip():
            return [CheckResult("Chart Manifest", False, "status report manifest path contains a symlink")]
    manifest_error = str(manifest.get("error", "")).strip()
    if manifest_error:
        return [CheckResult("Chart Manifest", False, f"status report manifest error: {manifest_error}")]
    required_text_fields = (
        "created_at",
        "created_at_source",
        "package",
        "package_filename",
        "url",
        "download_path",
        "download_url",
        "sha256",
        "extract_path",
    )
    for field in required_text_fields:
        if not str(manifest.get(field, "")).strip():
            return [CheckResult("Chart Manifest", False, f"status report manifest missing {field}")]
    created_at_source = str(manifest.get("created_at_source", "")).strip()
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
    if str(manifest.get("download_path_symlink_component", "")).strip():
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
    if str(manifest.get("extract_path_symlink_component", "")).strip():
        return [CheckResult("Chart Manifest", False, "status report manifest extract path contains a symlink")]
    download_path_error = str(manifest.get("download_path_error", "")).strip()
    if download_path_error:
        return [CheckResult("Chart Manifest", False, f"status report manifest download path error: {download_path_error}")]
    extract_path_error = str(manifest.get("extract_path_error", "")).strip()
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
    if gps_fix.get("ok") is not True:
        return [CheckResult("GPS Fix", False, f"status report gps_fix is not ok: {gps_fix.get('detail', '<missing detail>')}")]
    source = str(gps_fix.get("source", "")).strip()
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
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
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


def _track_log_validation_failures(track_log: object) -> list[CheckResult]:
    if not isinstance(track_log, dict):
        return [CheckResult("Track Log", False, "status report missing track_log section")]
    if track_log.get("track_output_is_symlink") is not False:
        return [CheckResult("Track Log", False, "status report track_log track_output is a symlink or missing symlink status")]
    if "track_storage_symlink_component" not in track_log:
        return [CheckResult("Track Log", False, "status report track_log missing track_storage_symlink_component")]
    if str(track_log.get("track_storage_symlink_component", "")).strip():
        return [CheckResult("Track Log", False, "status report track_log storage path contains a symlink")]
    if track_log.get("ok") is not True:
        return [CheckResult("Track Log", False, f"status report track_log is not ok: {track_log.get('detail', '<missing detail>')}")]
    if not str(track_log.get("latest_path", "")).strip():
        return [CheckResult("Track Log", False, "status report track_log has no latest_path")]
    latitude = _finite_gps_fix_float(track_log.get("latest_latitude"))
    longitude = _finite_gps_fix_float(track_log.get("latest_longitude"))
    age_seconds = _finite_gps_fix_float(track_log.get("age_seconds"))
    if latitude is None or longitude is None:
        return [CheckResult("Track Log", False, "status report track_log has non-numeric latest coordinates")]
    if age_seconds is None:
        return [CheckResult("Track Log", False, "status report track_log age_seconds is not numeric")]
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
    return bool(value) and Path(value).expanduser().is_absolute()


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
                current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
                summary["age_seconds"] = (current - timestamp).total_seconds()
        return summary
    return {
        "source": "",
        "ok": False,
        "detail": "GPS fix check was not run",
    }


def _parse_gps_fix_timestamp(value: object) -> Optional[datetime]:
    if not isinstance(value, str) or not value:
        return None
    try:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if timestamp.tzinfo is None:
        timestamp = timestamp.replace(tzinfo=timezone.utc)
    return timestamp.astimezone(timezone.utc)


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
        _validate_written_status_report(target)
        _fsync_directory(target.parent)
    finally:
        if tmp_path is not None:
            cleanup_private_temp_file(tmp_path, label="status report temp")
    return target


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
        mark = "OK" if check.get("ok") else "FAIL"
        lines.append(f"{mark:4} {check.get('name', ''):10} {check.get('detail', '')}")
    for check in status_report_validation_failures(report):
        lines.append(f"FAIL {check.name:10} {check.detail}")
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
    ok = "ok" if gps_fix.get("ok") else "fail"
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
    for _mtime, path, stat_result in candidates:
        try:
            read_stat, text = _read_trusted_gpx_track_file(
                path,
                expected_owner=expected_owner,
                expected_stat=stat_result,
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
            position, position_error = _gpx_trackpoint_position(trackpoint)
            if position is None:
                last_detail = f"{path} {position_error}"
                continue
            quality, quality_error = _gpx_trackpoint_quality(trackpoint)
            if quality is None:
                last_detail = f"{path} {quality_error}"
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
        summary.update(
            latest_fields
        )
        return summary
    summary["detail"] = last_detail or f"no current-boot GPX trackpoint found under {tracks_dir}"
    return summary


def _read_trusted_gpx_track_file(
    path: Path,
    *,
    expected_owner: int,
    expected_stat: Optional[os.stat_result] = None,
) -> tuple[os.stat_result, str]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        if path.is_symlink():
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
    if not math.isfinite(latitude) or not math.isfinite(longitude):
        return None, f"GPX trackpoint has non-finite coordinates: {lat_match.group(1)}, {lon_match.group(1)}"
    if not (-90.0 <= latitude <= 90.0):
        return None, f"GPX trackpoint latitude is outside -90..90: {latitude}"
    if not (-180.0 <= longitude <= 180.0):
        return None, f"GPX trackpoint longitude is outside -180..180: {longitude}"
    if abs(latitude) < 1e-12 and abs(longitude) < 1e-12:
        return None, "GPX trackpoint has invalid 0,0 coordinates"
    return (latitude, longitude), ""


def _gpx_trackpoint_quality(trackpoint: str) -> tuple[Optional[dict[str, object]], str]:
    sat_match = re.search(r"<sat>([^<]+)</sat>", trackpoint)
    hdop_match = re.search(r"<hdop>([^<]+)</hdop>", trackpoint)
    if not sat_match and not hdop_match:
        return None, "GPX trackpoint is missing satellite or HDOP quality fields"
    quality: dict[str, object] = {"satellites": None, "hdop": None}
    if sat_match:
        sat_text = sat_match.group(1).strip()
        try:
            satellites = int(sat_text)
        except ValueError:
            return None, f"GPX trackpoint has non-numeric satellite count: {sat_text}"
        if satellites < 4:
            return None, f"GPX trackpoint has weak satellite count: {satellites}"
        quality["satellites"] = satellites
    if hdop_match:
        hdop_text = hdop_match.group(1).strip()
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
                            ".local/bin/noaa-navionics",
                            "noaa-navionics wait-network",
                            "--host",
                            "www.charts.noaa.gov",
                            "--port 443",
                            "--seconds 300",
                        ],
                        "ExecStart": [
                            ".local/bin/noaa-navionics",
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
                            ".local/bin/noaa-navionics",
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
                            "TimeoutStartUSec": "infinity",
                            "Restart": "on-failure",
                            "RestartUSec": "30s",
                            "StartLimitIntervalUSec": "30min",
                            "StartLimitBurst": "60",
                            "NoNewPrivileges": "yes",
                            "PrivateTmp": "yes",
                            "ProtectSystem": "full",
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
                            ".local/bin/noaa-navionics",
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
                        "ExecStartPre=%h/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300",
                        "ExecStart=%h/.local/bin/noaa-navionics sync-charts --config %h/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30",
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
                        "ExecStart=%h/.local/bin/noaa-navionics log-track --config %h/.config/noaa-navionics/config.ini --rotate-daily",
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
                        "ExecStart=%h/.local/bin/noaa-navionics status-report --config %h/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env %h/.config/noaa-navionics/launcher.env --output %h/.cache/noaa-navionics/status.json",
                        "TimeoutStartSec=0",
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
    name = str(summary.get("name", "")).strip()
    error = str(summary.get("error", "")).strip()
    if error:
        return CheckResult("User Linger", False, f"{name or '<unknown>'}: {error}")
    linger = str(summary.get("linger", "")).strip()
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
    attempts = str(values.get("NOAA_NAVIONICS_READINESS_ATTEMPTS", "")).strip()
    if attempts and (not attempts.isdigit() or int(attempts) <= 0):
        failures.append(f"NOAA_NAVIONICS_READINESS_ATTEMPTS={attempts} expected positive integer")
    retry_delay = str(values.get("NOAA_NAVIONICS_READINESS_RETRY_DELAY", "")).strip()
    if retry_delay and (not retry_delay.isdigit() or int(retry_delay) < 0):
        failures.append(f"NOAA_NAVIONICS_READINESS_RETRY_DELAY={retry_delay} expected non-negative integer")
    warning_seconds = str(values.get("NOAA_NAVIONICS_WARNING_SECONDS", "")).strip()
    if warning_seconds and (not warning_seconds.isdigit() or int(warning_seconds) < 0):
        failures.append(f"NOAA_NAVIONICS_WARNING_SECONDS={warning_seconds} expected non-negative integer")
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

    if failures:
        return CheckResult("Desktop Startup", False, "; ".join(failures))
    active = str(summary.get("lightdm_active", "")).strip() or "<unknown>"
    return CheckResult("Desktop Startup", True, f"desktop autostart and LightDM autologin are configured; lightdm active={active}")


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
