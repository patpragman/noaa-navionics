from pathlib import Path
from datetime import datetime, timedelta, timezone
from contextlib import redirect_stderr, redirect_stdout
from http.client import IncompleteRead
from io import BytesIO, StringIO
from urllib.error import URLError
import ast
import copy
import json
import math
import re
import shutil
import stat
import sys
import signal
import tempfile
import threading
import textwrap
import time
import unittest
import zipfile
import os
from unittest.mock import patch

TEST_TMP_PARENT = Path(__file__).resolve().parents[1]

sys.path.insert(0, str(TEST_TMP_PARENT / "src"))

from noaa_navionics import health as health_module
from noaa_navionics import config as config_module
from noaa_navionics import downloader as downloader_module
from noaa_navionics import gps as gps_module
from noaa_navionics import cli as cli_module
from noaa_navionics import gui as gui_module
from noaa_navionics import opencpn as opencpn_module
from noaa_navionics import report as report_module
from noaa_navionics import status_gui as status_gui_module
from noaa_navionics.downloader import (
    DOWNLOAD_LOCK_NAME,
    MANIFEST_NAME,
    Package,
    download_package,
    extract_zip,
    package_for,
    read_manifest,
    search_catalog,
)
from noaa_navionics.config import AppConfig, default_config_text, package_kwargs, read_config, write_default_config
from noaa_navionics.cli import (
    _TrackLoggerStop,
    _gps_seconds_from_launcher_env,
    _log_rotating_tracks,
    _log_single_track,
    _raise_track_logger_stop,
    _trackable_fixes,
)
from noaa_navionics.gps import (
    GPSFix,
    GPXTrackLogger,
    _parse_time_today,
    daily_track_path,
    distance_meters,
    gps_fix_quality_failure,
    iter_fixes,
    iter_gpsd_fixes,
    parse_gpsd_sky,
    parse_gpsd_tpv,
    parse_nmea_sentence,
    read_nmea_lines,
)
from noaa_navionics.health import (
    CheckResult,
    check_chart_dir,
    check_chart_manifest,
    check_chart_update_debris,
    check_disk_space,
    check_chart_package,
    check_gps_device,
    check_gps_device_path,
    check_gpsd,
    check_gpsd_startup_config,
    check_gps_sample,
    check_display_power_tool,
    check_chrony_gps_time_config,
    check_chrony_gps_time_source,
    check_opencpn,
    check_opencpn_chart_config,
    check_opencpn_gpsd_config,
    check_pi_temperature,
    check_pi_throttling,
    check_python,
    check_source_revision,
    check_system_clock,
    check_tkinter,
    check_time_synchronization,
    _parse_vcgencmd_temperature,
    _parse_throttled_value,
    _read_trusted_config_lines,
    _sha256_trusted_file,
)
from noaa_navionics.opencpn import (
    chart_directory_configured,
    configure_chart_directory,
    configure_gpsd_connection,
    gpsd_connection_configured,
    read_data_connections,
    read_chart_directories,
)
from noaa_navionics.report import (
    build_status_report,
    format_status_text,
    status_report_is_ready,
    status_report_validation_failures,
    write_status_report,
    _install_wanted_by_targets,
    _key_value_file_summary,
    _launcher_settings_summary,
    _launcher_settings_check,
    _gps_fix_summary,
    _parse_proc_uptime_seconds,
    _read_trusted_gpx_track_file,
    _service_readiness_checks,
    _track_log_readiness_check,
    _track_log_summary,
    _user_unit_file_summary,
)


def trusted_unit_file(path: str, wanted_by: list[str], **overrides: object) -> dict[str, object]:
    unit_name = Path(path).name
    state: dict[str, object] = {
        "path": path,
        "exists": True,
        "is_symlink": False,
        "directory_is_symlink": False,
        "path_symlink_component": "",
        "uid": os.getuid(),
        "mode": "0600",
        "directory_uid": os.getuid(),
        "directory_mode": "0700",
        "wanted_by": wanted_by,
        "lines": trusted_unit_file_lines(unit_name),
    }
    state.update(overrides)
    return state


def trusted_user_services_summary(**overrides: object) -> dict[str, object]:
    state: dict[str, object] = {
        "available": True,
        "noaa-navionics.service": {
            "enabled": "static",
            "active": "inactive",
            "properties": {
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
                "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics.service",
                "ExecStartPre": "/home/pi/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300",
                "ExecStart": "/home/pi/.local/bin/noaa-navionics sync-charts --config /home/pi/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30",
            },
        },
        "noaa-navionics.timer": {
            "enabled": "enabled",
            "active": "active",
            "properties": {
                "Persistent": "yes",
                "RandomizedDelayUSec": "30min",
                "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics.timer",
                "TimersCalendar": "OnCalendar=weekly",
            },
        },
        "noaa-navionics-track.service": {
            "enabled": "enabled",
            "active": "active",
            "properties": {
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
                "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                "ExecStart": "/home/pi/.local/bin/noaa-navionics log-track --config /home/pi/.config/noaa-navionics/config.ini --rotate-daily",
            },
        },
        "noaa-navionics-preflight.service": {
            "enabled": "enabled",
            "active": "inactive",
            "properties": {
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
                "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                "Wants": "noaa-navionics-track.service",
                "After": "noaa-navionics-track.service",
                "ExecStart": "/home/pi/.local/bin/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env /home/pi/.config/noaa-navionics/launcher.env --output /home/pi/.cache/noaa-navionics/status.json",
                "Result": "success",
                "ExecMainStatus": "0",
                "ExecMainStartTimestampMonotonic": "123456",
            },
        },
    }
    state.update(overrides)
    return state


def trusted_system_services_summary(**overrides: object) -> dict[str, object]:
    state: dict[str, object] = {
        "available": True,
        "gpsd.socket": {"enabled": "enabled", "active": "active"},
        "gpsd.service": {"enabled": "enabled", "active": "active"},
        "chrony.service": {"enabled": "enabled", "active": "active"},
    }
    state.update(overrides)
    return state


def trusted_launcher_settings(**overrides: object) -> dict[str, object]:
    state: dict[str, object] = {
        "path": "/home/pi/.config/noaa-navionics/launcher.env",
        "exists": True,
        "is_symlink": False,
        "directory_is_symlink": False,
        "launcher_settings_symlink_component": "",
        "uid": os.getuid(),
        "mode": "0600",
        "directory_uid": os.getuid(),
        "directory_mode": "0700",
        "values": {
            "NOAA_NAVIONICS_GPS_SECONDS": "60",
            "NOAA_NAVIONICS_READINESS_ATTEMPTS": "3",
            "NOAA_NAVIONICS_READINESS_RETRY_DELAY": "10",
            "NOAA_NAVIONICS_WARNING_SECONDS": "8",
            "NOAA_NAVIONICS_OPENCPN_RESTARTS": "3",
            "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY": "5",
            "NOAA_NAVIONICS_START_ON_FAILED_READINESS": "no",
        },
    }
    state.update(overrides)
    return state


def trusted_desktop_summary(**overrides: object) -> dict[str, object]:
    state: dict[str, object] = {
        "autostart": {
            "path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop",
            "exists": True,
            "is_symlink": False,
            "directory_is_symlink": False,
            "path_symlink_component": "",
            "uid": os.getuid(),
            "mode": "0644",
            "directory_uid": os.getuid(),
            "directory_mode": "0700",
            "values": {
                "Type": "Application",
                "Name": "NOAA Navionics Chartplotter",
                "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
                "Terminal": "false",
                "X-GNOME-Autostart-enabled": "true",
            },
        },
        "lightdm_autologin": {
            "path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf",
            "exists": True,
            "is_symlink": False,
            "directory_is_symlink": False,
            "path_symlink_component": "",
            "uid": 0,
            "mode": "0644",
            "directory_uid": 0,
            "directory_mode": "0755",
            "sections": ["Seat:*"],
            "values": {
                "autologin-user": "pi",
                "autologin-user-timeout": "0",
                "autologin-session": "LXDE-pi",
            },
        },
        "graphical_target": "graphical.target",
        "lightdm_enabled": "enabled",
        "lightdm_active": "active",
    }
    state.update(overrides)
    return state


def fresh_status_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def complete_status_gui_report(
    *,
    ok: bool = True,
    gps_mode: str = "gpsd",
    generated_at=None,
) -> dict[str, object]:
    generated_at = generated_at or fresh_status_timestamp()
    checks = set(status_gui_module.CORE_READINESS_CHECKS)
    service_checks = set(status_gui_module.CORE_SERVICE_CHECKS)
    if gps_mode == "serial":
        checks.update(status_gui_module.SERIAL_READINESS_CHECKS)
        gps_source = "GPS"
    else:
        checks.update(status_gui_module.GPSD_READINESS_CHECKS)
        service_checks.update(status_gui_module.GPSD_SERVICE_CHECKS)
        gps_source = "GPSD"
    check_rows = [{"name": name, "ok": True, "detail": "ok"} for name in sorted(checks)]
    for row in check_rows:
        if row["name"] == "Python":
            row["detail"] = "running Python 3.11.2"
            row["data"] = {
                "version": "3.11.2",
                "version_info": [3, 11, 2],
                "min_version": [3, 9],
                "executable": "/home/pi/.local/share/noaa-navionics/venv/bin/python",
            }
        elif row["name"] == "Source Revision":
            row["detail"] = "fixture123"
            row["data"] = {
                "is_raspberry_pi": True,
                "path": "/home/pi/.local/share/noaa-navionics/source-revision",
                "exists": True,
                "is_symlink": False,
                "directory_symlink_component": "",
                "is_regular": True,
                "uid": os.getuid(),
                "expected_uid": os.getuid(),
                "mode": "0600",
                "revision": "fixture123",
            }
        elif row["name"] == "Clock":
            row["detail"] = generated_at
            row["data"] = {"timestamp": generated_at, "min_year": 2024}
        elif row["name"] == "Time Sync":
            row["detail"] = "system clock is synchronized (NTPSynchronized=yes)"
            row["data"] = {
                "is_raspberry_pi": True,
                "system_clock_synchronized": "yes",
                "ntp_synchronized": "yes",
            }
        elif row["name"] == "OpenCPN":
            row["detail"] = "trusted executable at /usr/bin/opencpn"
            row["data"] = {
                "command": "opencpn",
                "path": "/usr/bin/opencpn",
                "directory": "/usr/bin",
                "is_absolute": True,
                "is_symlink": False,
                "path_symlink_component": "",
                "trusted_system_directory": True,
                "is_regular": True,
                "executable": True,
                "uid": 0,
                "directory_uid": 0,
                "expected_uids": [0],
                "mode": "0755",
                "directory_mode": "0755",
            }
        elif row["name"] == "Display Power":
            row["detail"] = "trusted executable at /usr/bin/xset"
            row["data"] = {
                "command": "xset",
                "path": "/usr/bin/xset",
                "directory": "/usr/bin",
                "is_absolute": True,
                "is_symlink": False,
                "path_symlink_component": "",
                "trusted_system_directory": True,
                "is_regular": True,
                "executable": True,
                "uid": 0,
                "directory_uid": 0,
                "expected_uids": [0],
                "mode": "0755",
                "directory_mode": "0755",
            }
        elif row["name"] == "Tkinter":
            row["detail"] = "available"
            row["data"] = {
                "module": "tkinter",
                "available": True,
                "origin": "/usr/lib/python3.11/tkinter/__init__.py",
            }
        elif row["name"] == "Disk":
            row["detail"] = "12.5 GB free at /charts; minimum 2.0 GB"
            row["data"] = {
                "configured_path": "/charts",
                "checked_path": "/charts",
                "exists": True,
                "is_directory": True,
                "storage_symlink_component": "",
                "missing_removable_mount": False,
                "uid": 1000,
                "expected_uid": 1000,
                "mode": "0755",
                "min_free_gb": 2.0,
                "free_gb": 12.5,
                "writable": True,
            }
        elif row["name"] == "Chart Package":
            row["detail"] = "state AK"
            row["data"] = {
                "package": "state",
                "value": "AK",
                "complete_chart_set": True,
                "expected_filename": "AK_ENCs.zip",
                "expected_url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
            }
        elif row["name"] == "Charts":
            row["detail"] = "found extracted ENC cells under /charts"
            row["data"] = {
                "configured_path": "/charts",
                "exists": True,
                "storage_symlink_component": "",
                "enc_cell_samples": ["/charts/ENC_ROOT/US5AK00M/US5AK00M.000"],
                "zip_samples": [],
                "has_extracted_enc_cells": True,
                "has_unextracted_zips": False,
            }
        elif row["name"] == "Chart Update Debris":
            row["detail"] = "no interrupted chart updates found"
            row["data"] = {
                "configured_path": "/charts",
                "exists": True,
                "storage_symlink_component": "",
                "debris": [],
                "debris_count": 0,
                "clean": True,
            }
        elif row["name"] == "Manifest":
            row["detail"] = "Alaska; 1 ENC cells; updated 0.0 days ago"
            row["data"] = {
                "configured_path": "/charts",
                "path": "/charts/noaa-navionics-manifest.json",
                "created_at": generated_at,
                "created_at_source": "download",
                "max_age_days": 30,
                "age_days": 0.0,
                "package": "Alaska",
                "package_filename": "AK_ENCs.zip",
                "package_url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
                "expected_filename": "AK_ENCs.zip",
                "expected_url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
                "download_path": "/charts/AK_ENCs.zip",
                "download_url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
                "download_bytes": 123,
                "sha256": "abc123",
                "extract_path": "/charts/AK_ENCs",
                "enc_cell_count": 1,
                "actual_enc_cell_count": 1,
                "require_archive": True,
            }
        elif row["name"] == "OpenCPN Charts":
            row["detail"] = "/charts listed in /home/pi/.opencpn/opencpn.conf"
            row["data"] = {
                "config_path": "/home/pi/.opencpn/opencpn.conf",
                "chart_dir": "/charts",
                "config_exists": True,
                "chart_dir_exists": True,
                "configured": True,
                "chart_directories": ["/charts"],
            }
        elif row["name"] == "OpenCPN GPSD":
            row["detail"] = "GPSD 127.0.0.1:2947 listed in /home/pi/.opencpn/opencpn.conf"
            row["data"] = {
                "config_path": "/home/pi/.opencpn/opencpn.conf",
                "expected_host": "127.0.0.1",
                "expected_port": 2947,
                "config_exists": True,
                "configured": True,
                "enabled_gpsd_connections": [
                    {
                        "host": "127.0.0.1",
                        "port": 2947,
                        "raw": "1;2;127.0.0.1;2947;0;;4800;1;0;0;;0;;0;0;0;0;1;GPSd: 127.0.0.1 TCP port 2947;0;;0;0;",
                    }
                ],
                "unexpected_connections": [],
            }
        elif row["name"] == "GPS Device":
            row["detail"] = "/dev/serial/by-id/mock-gps -> /dev/ttyACM0"
            row["data"] = {
                "configured_path": "/dev/serial/by-id/mock-gps",
                "stable_path": True,
                "volatile_path": False,
                "is_by_id_path": True,
                "is_symlink": True,
                "exists": True,
                "is_directory": False,
                "resolved_path": "/dev/ttyACM0",
                "is_character_device": True,
            }
        elif row["name"] == "GPSD Config":
            row["detail"] = "/etc/default/gpsd uses /dev/serial/by-id/mock-gps with immediate polling"
            row["data"] = {
                "path": "/etc/default/gpsd",
                "expected_device": "/dev/serial/by-id/mock-gps",
                "exists": True,
                "is_symlink": False,
                "directory_symlink_component": "",
                "is_regular": True,
                "uid": 0,
                "expected_uid": 0,
                "mode": "0644",
                "values": {
                    "START_DAEMON": "true",
                    "USBAUTO": "false",
                    "GPSD_OPTIONS": "-n",
                    "DEVICES": "/dev/serial/by-id/mock-gps",
                },
                "devices": ["/dev/serial/by-id/mock-gps"],
                "gpsd_options": ["-n"],
                "start_daemon": "true",
                "usbauto": "false",
                "immediate_polling": True,
            }
        elif row["name"] == "Chrony Config":
            row["detail"] = "/etc/chrony/chrony.conf contains the NOAA Navionics GPSD SHM 0 time source"
            row["data"] = {
                "is_raspberry_pi": True,
                "path": "/etc/chrony/chrony.conf",
                "exists": True,
                "is_symlink": False,
                "directory_symlink_component": "",
                "is_regular": True,
                "uid": 0,
                "expected_uid": 0,
                "mode": "0644",
                "managed_refclock_present": True,
                "refclock_line": "refclock SHM 0 offset 0.5 delay 0.1 refid GPS",
            }
        elif row["name"] == "GPS Time Source":
            row["detail"] = "chrony GPS source: #+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms"
            row["data"] = {
                "is_raspberry_pi": True,
                "chronyc_path": "/usr/bin/chronyc",
                "chronyc_available": True,
                "returncode": 0,
                "gps_lines": ["#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms"],
                "usable_lines": ["#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms"],
                "selected_or_combined": True,
            }
        elif row["name"] in {"GPS", "GPSD"}:
            row["detail"] = "fix"
            row["data"] = {
                "timestamp": generated_at,
                "latitude": 61.2181,
                "longitude": -149.9003,
                "satellites": 8,
                "hdop": 0.9,
            }
        elif row["name"] == "Pi Power":
            row["detail"] = "no under-voltage or throttling reported"
            row["data"] = {
                "is_raspberry_pi": True,
                "vcgencmd_available": True,
                "throttled_output": "throttled=0x0",
                "throttled_value": 0,
                "reported_flags": [],
            }
        elif row["name"] == "Pi Thermal":
            row["detail"] = "42.5 C"
            row["data"] = {
                "is_raspberry_pi": True,
                "temperature_available": True,
                "temperature_c": 42.5,
                "warn_c": 70.0,
                "fail_c": 80.0,
            }
    return {
        "ok": ok,
        "generated_at": generated_at,
        "host": {"boot_id": "12345678-1234-4234-8234-123456789abc"},
        "app": {
            "version": "0.1.0",
            "source_revision": "fixture123",
            "source_revision_path": "/home/pi/.local/share/noaa-navionics/source-revision",
            "source_revision_exists": True,
            "source_revision_path_is_symlink": False,
            "source_revision_directory_is_symlink": False,
            "source_revision_symlink_component": "",
            "source_revision_uid": os.getuid(),
            "source_revision_mode": "0600",
            "source_revision_directory_uid": os.getuid(),
            "source_revision_directory_mode": "0700",
        },
        "user": {"name": "pi", "uid": os.getuid(), "linger": "yes"},
        "unit_files": {
            "directory": "/home/pi/.config/systemd/user",
            "noaa-navionics.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.service",
                [],
            ),
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        },
        "services": trusted_user_services_summary(),
        "system_services": trusted_system_services_summary(),
        "config_path": "/home/pi/.config/noaa-navionics/config.ini",
        "config": {
            "chart_package": "state",
            "chart_value": "AK",
            "chart_output": "/charts",
            "extract": True,
            "keep_zip": True,
            "force": True,
            "max_chart_age_days": 30,
            "min_free_gb": 2.0,
            "gps_mode": gps_mode,
            "gps_device": "/dev/serial/by-id/mock-gps",
            "gps_baud": 4800,
            "gpsd_host": "127.0.0.1",
            "gpsd_port": 2947,
            "track_output": "/charts",
            "track_retention_days": 90,
            "anchor_radius_meters": 50.0,
        },
        "launcher_settings": trusted_launcher_settings(),
        "opencpn_config": {
            "path": "/home/pi/.opencpn/opencpn.conf",
            "exists": True,
            "is_symlink": False,
            "directory_is_symlink": False,
            "config_symlink_component": "",
            "directory_uid": os.getuid(),
            "directory_mode": "0700",
            "uid": os.getuid(),
            "mode": "0600",
            "chart_directories": ["/charts"],
            "data_connections": [
                "1;2;127.0.0.1;2947;0;;4800;1;0;0;;0;;0;0;0;0;1;GPSd: 127.0.0.1 TCP port 2947;0;;0;0;"
            ],
        },
        "desktop": trusted_desktop_summary(),
        "manifest": {
            "path": "/charts/noaa-navionics-manifest.json",
            "exists": True,
            "is_symlink": False,
            "directory_is_symlink": False,
            "chart_storage_symlink_component": "",
            "manifest_symlink_component": "",
            "directory_uid": os.getuid(),
            "directory_mode": "0700",
            "uid": os.getuid(),
            "mode": "0600",
            "created_at": generated_at,
            "created_at_source": "download",
            "package": "Alaska",
            "package_filename": "AK_ENCs.zip",
            "url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
            "download_path": "/charts/AK_ENCs.zip",
            "download_path_exists": False,
            "download_path_is_symlink": False,
            "download_path_symlink_component": "",
            "download_url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
            "download_skipped": False,
            "download_bytes": 123,
            "sha256": "abc123",
            "extract_path": "/charts/AK_ENCs",
            "extract_path_is_symlink": False,
            "extract_path_symlink_component": "",
            "enc_cell_count": 1,
            "actual_enc_cell_count": 1,
        },
        "track_log": {
            "track_output": "/charts",
            "track_output_is_symlink": False,
            "track_storage_symlink_component": "",
            "tracks_dir": "/charts/tracks",
            "ok": True,
            "latest_path": "/charts/tracks/track-20260701.gpx",
            "latest_time": generated_at,
            "latest_latitude": 61.2181,
            "latest_longitude": -149.9003,
            "age_seconds": 0.0,
            "latest_satellites": 8,
            "latest_hdop": 0.9,
            "detail": "recent GPX trackpoint",
        },
        "gps_fix": {
            "source": gps_source,
            "ok": True,
            "detail": "fix",
            "timestamp": generated_at,
            "age_seconds": 0.0,
            "latitude": 61.2181,
            "longitude": -149.9003,
            "satellites": 8,
            "hdop": 0.9,
        },
        "checks": check_rows,
        "service_checks": [{"name": name, "ok": True, "detail": "ok"} for name in sorted(service_checks)],
    }


def verify_pi_string_set_assignment(source: str, name: str) -> set[str]:
    match = re.search(rf"^{re.escape(name)} = \{{(?P<body>.*?)^\}}", source, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError(f"missing verify_pi.py set assignment: {name}")
    return set(re.findall(r'"([^"]+)"', match.group("body")))


def shell_python_heredoc(source: str) -> str:
    match = re.search(r"<<'PY'\n(?P<body>.*?)\nPY\n", source, re.DOTALL)
    if not match:
        raise AssertionError("missing embedded Python heredoc")
    return match.group("body")


def shell_function_python_heredoc(source: str, function_name: str) -> str:
    match = re.search(
        rf"^{re.escape(function_name)}\(\) \{{.*?<<'PY'\n(?P<body>.*?)\nPY\n",
        source,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"missing embedded Python heredoc in {function_name}")
    return match.group("body")


def python_string_set_assignment(source: str, name: str) -> set[str]:
    tree = ast.parse(source)
    for statement in tree.body:
        if not isinstance(statement, ast.Assign):
            continue
        if not any(isinstance(target, ast.Name) and target.id == name for target in statement.targets):
            continue
        if not isinstance(statement.value, ast.Set):
            raise AssertionError(f"{name} is not assigned a string set")
        values = set()
        for element in statement.value.elts:
            if not isinstance(element, ast.Constant) or not isinstance(element.value, str):
                raise AssertionError(f"{name} contains a non-string value")
            values.add(element.value)
        return values
    raise AssertionError(f"missing Python set assignment: {name}")


def trusted_unit_file_lines(unit_name: str) -> list[str]:
    lines_by_unit = {
        "noaa-navionics.service": [
            "[Unit]",
            "StartLimitIntervalSec=6h",
            "StartLimitBurst=3",
            "[Service]",
            "Type=oneshot",
            "ExecStartPre=%h/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300",
            "ExecStart=%h/.local/bin/noaa-navionics sync-charts --config %h/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30",
            "TimeoutStartSec=2h",
            "Restart=on-failure",
            "RestartSec=30min",
        ],
        "noaa-navionics.timer": [
            "[Timer]",
            "OnCalendar=weekly",
            "Persistent=true",
            "RandomizedDelaySec=30min",
            "[Install]",
            "WantedBy=timers.target",
        ],
        "noaa-navionics-track.service": [
            "[Unit]",
            "StartLimitIntervalSec=10min",
            "StartLimitBurst=60",
            "[Service]",
            "Type=simple",
            "ExecStart=%h/.local/bin/noaa-navionics log-track --config %h/.config/noaa-navionics/config.ini --rotate-daily",
            "StandardOutput=null",
            "Restart=on-failure",
            "RestartSec=10",
            "TimeoutStopSec=30s",
            "[Install]",
            "WantedBy=default.target",
        ],
        "noaa-navionics-preflight.service": [
            "[Unit]",
            "Wants=noaa-navionics-track.service",
            "After=noaa-navionics-track.service",
            "StartLimitIntervalSec=30min",
            "StartLimitBurst=60",
            "[Service]",
            "Type=oneshot",
            "ExecStart=%h/.local/bin/noaa-navionics status-report --config %h/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env %h/.config/noaa-navionics/launcher.env --output %h/.cache/noaa-navionics/status.json",
            "TimeoutStartSec=0",
            "Restart=on-failure",
            "RestartSec=30",
            "[Install]",
            "WantedBy=default.target",
        ],
    }
    return list(lines_by_unit.get(unit_name, []))


class PackageForTests(unittest.TestCase):
    def test_state_package(self):
        package = package_for(state="ak")
        self.assertEqual(package.filename, "AK_ENCs.zip")
        self.assertEqual(package.url, "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip")

    def test_update_package(self):
        package = package_for(updates="10 days")
        self.assertEqual(package.filename, "TenDays_ENCs.zip")

    def test_cgd_package_is_zero_padded(self):
        package = package_for(cgd="7")
        self.assertEqual(package.filename, "07CGD_ENCs.zip")

    def test_rejects_unsupported_prepackaged_package_codes(self):
        with self.assertRaisesRegex(ValueError, "state must be one of"):
            package_for(state="ZZ")
        with self.assertRaisesRegex(ValueError, "Coast Guard district must be one of"):
            package_for(cgd="99")
        with self.assertRaisesRegex(ValueError, "region must be one of"):
            package_for(region="99")

    def test_requires_one_selector(self):
        with self.assertRaises(ValueError):
            package_for(state="AK", region="30")


class CatalogTests(unittest.TestCase):
    def test_search_catalog(self):
        xml = textwrap.dedent(
            """\
            <?xml version="1.0" encoding="UTF-8"?>
            <DS_Series xmlns="http://www.isotc211.org/2005/gmd"
                xmlns:gco="http://www.isotc211.org/2005/gco">
              <composedOf>
                <DS_DataSet>
                  <has>
                    <MD_Metadata>
                      <identificationInfo>
                        <MD_DataIdentification>
                          <citation>
                            <CI_Citation>
                              <title><gco:CharacterString>US5AK3CM</gco:CharacterString></title>
                              <alternateTitle><gco:CharacterString>Cook Inlet</gco:CharacterString></alternateTitle>
                              <edition><gco:CharacterString>12.0</gco:CharacterString></edition>
                            </CI_Citation>
                          </citation>
                          <descriptiveKeywords>
                            <MD_Keywords>
                              <keyword><gco:CharacterString>state: AK</gco:CharacterString></keyword>
                              <keyword><gco:CharacterString>region: 30</gco:CharacterString></keyword>
                              <keyword><gco:CharacterString>coast guard district: 17</gco:CharacterString></keyword>
                            </MD_Keywords>
                          </descriptiveKeywords>
                        </MD_DataIdentification>
                      </identificationInfo>
                      <distributionInfo>
                        <MD_Distribution>
                          <transferOptions>
                            <MD_DigitalTransferOptions>
                              <onLine>
                                <CI_OnlineResource>
                                  <linkage><URL>https://www.charts.noaa.gov/ENCs/US5AK3CM.zip</URL></linkage>
                                </CI_OnlineResource>
                              </onLine>
                            </MD_DigitalTransferOptions>
                          </transferOptions>
                        </MD_Distribution>
                      </distributionInfo>
                    </MD_Metadata>
                  </has>
                </DS_DataSet>
              </composedOf>
            </DS_Series>
            """
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "catalog.xml"
            path.write_text(xml, encoding="utf-8")
            matches = search_catalog(path, "cook", limit=5)
            self.assertEqual(len(matches), 1)
            self.assertEqual(matches[0].name, "US5AK3CM")
            self.assertEqual(matches[0].states, ("AK",))


class ConfigTests(unittest.TestCase):
    def test_write_and_read_default_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            written = write_default_config(path)
            self.assertEqual(written, path)
            config = read_config(path)
            self.assertEqual(config.chart_package, "state")
            self.assertEqual(config.chart_value, "AK")
            self.assertEqual(config.gps_mode, "gpsd")
            self.assertEqual(config.gps_device, "/dev/serial/by-id/YOUR_GPS_DEVICE")
            self.assertEqual(config.max_chart_age_days, 30)
            self.assertEqual(config.min_free_gb, 2.0)
            self.assertEqual(config.track_retention_days, 90)
            self.assertEqual(config.anchor_radius_meters, 50.0)
            self.assertTrue(config.extract)
            text = path.read_text(encoding="utf-8")
            self.assertIn("[anchor]\n", text)
            self.assertIn("radius_meters = 50\n", text)

    def test_write_default_config_creates_private_parent_and_file_with_permissive_umask(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            path = root / ".config" / "noaa-navionics" / "config.ini"
            original_umask = os.umask(0)
            try:
                write_default_config(path)
            finally:
                os.umask(original_umask)

            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_write_default_config_rejects_writable_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / ".config" / "noaa-navionics"
            parent.mkdir(parents=True)
            parent.chmod(0o777)
            try:
                with self.assertRaisesRegex(RuntimeError, "no group/other write bits"):
                    write_default_config(parent / "config.ini")
            finally:
                parent.chmod(0o700)

    def test_write_default_config_tightens_public_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / ".config" / "noaa-navionics"
            parent.mkdir(parents=True)
            parent.chmod(0o755)

            write_default_config(parent / "config.ini")

            self.assertEqual(parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual((parent / "config.ini").stat().st_mode & 0o777, 0o600)

    def test_write_default_config_rejects_parent_when_tightening_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / ".config" / "noaa-navionics"
            parent.mkdir(parents=True)
            parent.chmod(0o755)
            original_chmod = config_module.os.chmod

            def fake_chmod(path, mode):
                if Path(path) == parent and mode == 0o700:
                    return None
                return original_chmod(path, mode)

            config_module.os.chmod = fake_chmod
            try:
                with self.assertRaisesRegex(RuntimeError, "expected private 0700"):
                    write_default_config(parent / "config.ini")
            finally:
                config_module.os.chmod = original_chmod
                parent.chmod(0o700)

    def test_write_default_config_rejects_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-config"
            real_parent.mkdir()
            link_parent = root / ".config" / "noaa-navionics"
            link_parent.parent.mkdir()
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "symlink"):
                write_default_config(link_parent / "config.ini")

    def test_write_default_config_rejects_symlinked_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config_root = root / "real-config-root"
            real_config_root.mkdir()
            link_config_root = root / ".config"
            try:
                link_config_root.symlink_to(real_config_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config directory is a symlink"):
                write_default_config(link_config_root / "noaa-navionics" / "config.ini")

            self.assertFalse((real_config_root / "noaa-navionics" / "config.ini").exists())

    def test_write_default_config_rejects_symlinked_config_file_when_overwriting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config = root / "real-config.ini"
            write_default_config(real_config)
            link_config = root / "config.ini"
            try:
                link_config.symlink_to(real_config)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config is a symlink"):
                write_default_config(link_config, overwrite=True)

    def test_read_config_rejects_symlinked_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config = root / "real-config.ini"
            write_default_config(real_config)
            link_config = root / "config.ini"
            try:
                link_config.symlink_to(real_config)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config is a symlink"):
                read_config(link_config)

    def test_read_config_rejects_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-config"
            real_parent.mkdir()
            write_default_config(real_parent / "config.ini")
            link_parent = root / ".config" / "noaa-navionics"
            link_parent.parent.mkdir()
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config directory is a symlink"):
                read_config(link_parent / "config.ini")

    def test_read_config_rejects_symlinked_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config_root = root / "real-config-root"
            real_config_parent = real_config_root / "noaa-navionics"
            real_config_parent.mkdir(parents=True)
            write_default_config(real_config_parent / "config.ini")
            link_config_root = root / ".config"
            try:
                link_config_root.symlink_to(real_config_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config directory is a symlink"):
                read_config(link_config_root / "noaa-navionics" / "config.ini")

    def test_read_config_rejects_symlinked_parent_when_config_missing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-config"
            real_parent.mkdir()
            link_parent = root / ".config" / "noaa-navionics"
            link_parent.parent.mkdir()
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config directory is a symlink"):
                read_config(link_parent / "missing.ini")

    def test_read_config_rejects_nonregular_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.ini"
            config_path.mkdir()

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config is not a regular file"):
                read_config(config_path)

    def test_read_config_rejects_non_directory_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / "config-parent"
            parent.write_text("not a directory\n", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config parent is not a directory"):
                read_config(parent / "config.ini")

    def test_read_config_rejects_writable_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / "config-parent"
            parent.mkdir()
            config_path = parent / "config.ini"
            config_path.write_text(default_config_text(), encoding="utf-8")
            config_path.chmod(0o600)
            parent.chmod(0o777)
            try:
                with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config directory .* has permissions"):
                    read_config(config_path)
            finally:
                parent.chmod(0o700)

    def test_read_config_rejects_writable_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.ini"
            config_path.write_text(default_config_text(), encoding="utf-8")
            config_path.chmod(0o620)
            try:
                with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config .* has permissions"):
                    read_config(config_path)
            finally:
                config_path.chmod(0o600)

    def test_write_default_config_rejects_unsafe_existing_config_when_overwriting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.ini"
            config_path.write_text(default_config_text(), encoding="utf-8")
            config_path.chmod(0o620)
            try:
                with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config .* has permissions"):
                    write_default_config(config_path, overwrite=True)
            finally:
                config_path.chmod(0o600)

    def test_write_default_config_uses_unique_synced_temp_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            path = root / "config.ini"
            fixed_part = root / "config.ini.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")
            calls = []
            original_fsync = config_module.os.fsync
            config_module.os.fsync = lambda fd: calls.append(fd)
            try:
                write_default_config(path)
            finally:
                config_module.os.fsync = original_fsync

            self.assertEqual(fixed_part.read_text(encoding="utf-8"), "other writer\n")
            self.assertFalse(list(root.glob(".config.ini.*.part")))
            self.assertGreaterEqual(len(calls), 2)

    def test_write_default_config_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = config_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        config_module.os.open = fake_open
        try:
            config_module._fsync_directory(Path("/tmp"))
        finally:
            config_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], Path("/tmp"))
        self.assertTrue(calls[0][1] & getattr(os, "O_DIRECTORY", 0))
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_write_default_config_validates_promoted_file_with_no_follow_open(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            calls = []
            original_open = config_module.os.open

            def fake_open(open_path, flags, mode=0o777, *args, **kwargs):
                calls.append((Path(open_path), flags))
                return original_open(open_path, flags, mode, *args, **kwargs)

            config_module.os.open = fake_open
            try:
                write_default_config(path)
            finally:
                config_module.os.open = original_open

            promoted_opens = [(opened_path, flags) for opened_path, flags in calls if opened_path == path]
            self.assertTrue(promoted_opens)
            self.assertTrue(promoted_opens[-1][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_write_default_config_rejects_corrupt_promoted_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            original_replace = config_module.os.replace

            def corrupt_after_replace(source, target):
                original_replace(source, target)
                Path(target).write_text("not an ini file\n", encoding="utf-8")

            config_module.os.replace = corrupt_after_replace
            try:
                with self.assertRaisesRegex(RuntimeError, "could not parse promoted NOAA Navionics config"):
                    write_default_config(path)
            finally:
                config_module.os.replace = original_replace

    def test_custom_config_package_kwargs(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            path.write_text(
                "[charts]\n"
                "package = cgd\n"
                "value = 17\n"
                "output = /charts\n"
                "extract = true\n"
                "keep_zip = false\n"
                "force = false\n"
                "max_age_days = 14\n"
                "min_free_gb = 4.5\n"
                "\n"
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 9600\n"
                "gpsd_host = 192.168.1.10\n"
                "gpsd_port = 2947\n"
                "[tracking]\n"
                "retention_days = 14\n"
                "[anchor]\n"
                "radius_meters = 75.5\n",
                encoding="utf-8",
            )
            config = read_config(path)
            self.assertEqual(package_kwargs(config), {"cgd": "17"})
            self.assertEqual(config.gps_mode, "serial")
            self.assertEqual(config.gps_device, "/dev/serial/by-id/mock-gps")
            self.assertEqual(config.gps_baud, 9600)
            self.assertEqual(config.max_chart_age_days, 14)
            self.assertEqual(config.min_free_gb, 4.5)
            self.assertEqual(config.track_retention_days, 14)
            self.assertEqual(config.anchor_radius_meters, 75.5)
            self.assertFalse(config.keep_zip)
            self.assertFalse(config.force)

    def test_config_allows_run_media_storage_paths(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            path.write_text(
                "[charts]\n"
                "output = /run/media/pi/NOAA/charts\n"
                "\n"
                "[tracking]\n"
                "output = /run/media/pi/NOAA/tracks\n",
                encoding="utf-8",
            )

            config = read_config(path)

            self.assertEqual(config.chart_output, Path("/run/media/pi/NOAA/charts"))
            self.assertEqual(config.track_output, Path("/run/media/pi/NOAA/tracks"))

    def test_invalid_gps_mode_fails_config_read(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            path.write_text("[gps]\nmode = bluetooth\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "gps.mode"):
                read_config(path)

    def test_invalid_config_values_fail_fast(self):
        cases = [
            ("[charts]\npackage = potato\n", "charts.package"),
            ("[charts]\npackage = updates\nvalue = ten-days\n", "charts.package"),
            ("[charts]\npackage = catalog\n", "charts.package"),
            ("[charts]\npackage = state\nvalue =\n", "charts.value"),
            ("[charts]\noutput =\n", "charts.output"),
            ("[charts]\noutput = charts/noaa-enc\n", "charts.output"),
            ("[charts]\noutput = ~/charts/..\n", "charts.output"),
            ("[charts]\noutput = /\n", "charts.output"),
            ("[charts]\noutput = ~\n", "charts.output"),
            ("[charts]\noutput = ~/.config\n", "charts.output"),
            ("[charts]\noutput = /etc\n", "charts.output"),
            ("[charts]\noutput = /etc/noaa-navionics\n", "charts.output"),
            ("[charts]\noutput = /tmp/noaa-navionics\n", "charts.output"),
            ("[charts]\noutput = /mnt/../etc/noaa-navionics\n", "charts.output"),
            ("[charts]\noutput = /usr/local/noaa-navionics\n", "charts.output"),
            ("[charts]\npackage = state\nvalue = ZZ\n", "charts.value"),
            ("[charts]\npackage = cgd\nvalue = 99\n", "charts.value"),
            ("[charts]\npackage = region\nvalue = 99\n", "charts.value"),
            ("[charts]\nmax_age_days = 0\n", "charts.max_age_days"),
            ("[charts]\nmin_free_gb = 0\n", "charts.min_free_gb"),
            ("[charts]\nmin_free_gb = nan\n", "charts.min_free_gb"),
            ("[charts]\nextract = maybe\n", "charts.extract"),
            ("[anchor]\nradius_meters = 0\n", "anchor.radius_meters"),
            ("[anchor]\nradius_meters = nan\n", "anchor.radius_meters"),
            ("[gps]\nmode = serial\ndevice =\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice =\n", "gps.device"),
            ("[gps]\nmode = serial\ndevice = /dev/ttyACM0\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/ttyUSB0\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/ttyAMA0\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/serial/by-id/\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/serial/by-id/../ttyS0\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/serial/by-id/mock/extra\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/serial/by-id/$(id)\n", "gps.device"),
            ("[gps]\nbaud = 12345\n", "gps.baud"),
            ("[gps]\ngpsd_host = 127.0.0.1;bad\n", "gps.gpsd_host"),
            ("[gps]\nmode = gpsd\ngpsd_host = 192.168.1.10\n", "gps.gpsd_host"),
            ("[gps]\ngpsd_port = 70000\n", "gps.gpsd_port"),
            ("[tracking]\noutput =\n", "tracking.output"),
            ("[tracking]\noutput = tracks\n", "tracking.output"),
            ("[tracking]\noutput = ~/tracks/..\n", "tracking.output"),
            ("[tracking]\noutput = /\n", "tracking.output"),
            ("[tracking]\noutput = ~\n", "tracking.output"),
            ("[tracking]\noutput = ~/.cache\n", "tracking.output"),
            ("[tracking]\noutput = /var\n", "tracking.output"),
            ("[tracking]\noutput = /media/../var/tmp/noaa-navionics\n", "tracking.output"),
            ("[tracking]\noutput = /var/tmp/noaa-navionics\n", "tracking.output"),
            ("[tracking]\noutput = /run/noaa-navionics\n", "tracking.output"),
            ("[tracking]\nretention_days = -1\n", "tracking.retention_days"),
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            for index, (text, error) in enumerate(cases):
                with self.subTest(error=error):
                    path = root / f"config-{index}.ini"
                    path.write_text(text, encoding="utf-8")

                    with self.assertRaisesRegex(ValueError, error):
                        read_config(path)


class OpenCPNConfigTests(unittest.TestCase):
    def test_configure_chart_directory_creates_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / ".opencpn" / "opencpn.conf"
            charts = root / "charts" / "noaa-enc"
            charts.mkdir(parents=True)

            result = configure_chart_directory(charts, config_path=config)

            self.assertTrue(result.changed)
            self.assertEqual(result.key, "ChartDir1")
            self.assertTrue(config.exists())
            self.assertEqual(config.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            self.assertEqual(read_chart_directories(config), [charts.resolve()])
            self.assertTrue(chart_directory_configured(charts, config))

    def test_configure_chart_directory_rejects_missing_chart_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "missing-charts"

            with self.assertRaisesRegex(RuntimeError, "OpenCPN chart directory does not exist"):
                configure_chart_directory(charts, config_path=config)

            self.assertFalse(config.exists())

    def test_configure_chart_directory_rejects_non_directory_chart_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"
            charts.write_text("not a directory\n", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "OpenCPN chart directory is not a directory"):
                configure_chart_directory(charts, config_path=config)

            self.assertFalse(config.exists())

    def test_configure_chart_directory_rejects_symlinked_chart_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            real_charts = root / "real-charts"
            real_charts.mkdir()
            chart_link = root / "charts"
            try:
                chart_link.symlink_to(real_charts, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "OpenCPN chart directory path contains a symlink"):
                configure_chart_directory(chart_link, config_path=config)

            self.assertFalse(config.exists())

    def test_configure_chart_directory_rejects_writable_config_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / ".opencpn"
            parent.mkdir()
            parent.chmod(0o777)
            config = parent / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            try:
                with self.assertRaisesRegex(RuntimeError, "no group/other write bits"):
                    configure_chart_directory(charts, config_path=config)
            finally:
                parent.chmod(0o700)

    def test_configure_chart_directory_tightens_public_config_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / ".opencpn"
            parent.mkdir()
            parent.chmod(0o755)
            config = parent / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()

            configure_chart_directory(charts, config_path=config)

            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)

    def test_configure_chart_directory_rejects_config_parent_when_tightening_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / ".opencpn"
            parent.mkdir()
            parent.chmod(0o755)
            config = parent / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            original_chmod = opencpn_module.os.chmod

            def fake_chmod(path, mode):
                if Path(path) == parent and mode == 0o700:
                    return None
                return original_chmod(path, mode)

            opencpn_module.os.chmod = fake_chmod
            try:
                with self.assertRaisesRegex(RuntimeError, "expected private 0700"):
                    configure_chart_directory(charts, config_path=config)
            finally:
                opencpn_module.os.chmod = original_chmod
                parent.chmod(0o700)

    def test_configure_chart_directory_rejects_symlinked_config_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-opencpn"
            real_parent.mkdir()
            link_parent = root / ".opencpn"
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            charts = root / "charts"
            charts.mkdir()

            with self.assertRaisesRegex(RuntimeError, "symlink"):
                configure_chart_directory(charts, config_path=link_parent / "opencpn.conf")

    def test_configure_chart_directory_rejects_symlinked_config_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config_root = root / "real-config-root"
            real_config_root.mkdir()
            link_config_root = root / ".config"
            try:
                link_config_root.symlink_to(real_config_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            charts = root / "charts"
            charts.mkdir()

            with self.assertRaisesRegex(RuntimeError, "OpenCPN config directory is a symlink"):
                configure_chart_directory(
                    charts,
                    config_path=link_config_root / "opencpn" / "opencpn.conf",
                )

            self.assertFalse((real_config_root / "opencpn" / "opencpn.conf").exists())

    def test_read_chart_directories_rejects_symlinked_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_config = root / "real-opencpn.conf"
            configure_chart_directory(charts, config_path=real_config)
            link_config = root / "opencpn.conf"
            try:
                link_config.symlink_to(real_config)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "OpenCPN config path is a symlink"):
                read_chart_directories(link_config)

    def test_read_chart_directories_rejects_nonregular_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.mkdir()

            with self.assertRaisesRegex(RuntimeError, "OpenCPN config path is not a regular file"):
                read_chart_directories(config)

    def test_read_chart_directories_rejects_writable_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.write_text("[ChartDirectories]\n", encoding="utf-8")
            config.chmod(0o620)

            with self.assertRaisesRegex(RuntimeError, "OpenCPN config path .* has permissions"):
                read_chart_directories(config)

    def test_read_data_connections_rejects_writable_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.write_text(
                "[Settings/NMEADataSource]\n"
                "DataConnections=1;2;127.0.0.1;2947;0;;4800;1;0;0;;0;;0;0;0;0;1;GPSd;0;;0;0;\n",
                encoding="utf-8",
            )
            config.chmod(0o620)

            with self.assertRaisesRegex(RuntimeError, "OpenCPN config path .* has permissions"):
                read_data_connections(config)

    def test_configure_chart_directory_is_idempotent_and_backs_up_existing_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            config.write_text("[Settings]\nShowStatusBar=1\n\n[ChartDirectories]\nChartDir4=/old\n", encoding="utf-8")

            result = configure_chart_directory(charts, config_path=config)
            second = configure_chart_directory(charts, config_path=config)

            self.assertTrue(result.changed)
            self.assertIsNotNone(result.backup_path)
            assert result.backup_path is not None
            self.assertTrue(result.backup_path.exists())
            self.assertFalse(second.changed)
            text = config.read_text(encoding="utf-8")
            self.assertIn("[Settings]\nShowStatusBar=1\n", text)
            self.assertIn("ChartDir4=/old\n", text)
            self.assertIn(f"ChartDir5={charts.resolve()}\n", text)

    def test_opencpn_backup_uses_unique_name_within_same_second(self):
        class FrozenDateTime:
            @classmethod
            def now(cls, tz=None):
                return datetime(2026, 6, 29, 12, 0, 0, tzinfo=timezone.utc)

        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.write_text("original\n", encoding="utf-8")
            original_datetime = opencpn_module.datetime
            try:
                opencpn_module.datetime = FrozenDateTime
                first = opencpn_module._write_backup(config)
                config.write_text("second\n", encoding="utf-8")
                second = opencpn_module._write_backup(config)
            finally:
                opencpn_module.datetime = original_datetime

            self.assertNotEqual(first, second)
            self.assertEqual(first.read_text(encoding="utf-8"), "original\n")
            self.assertEqual(second.read_text(encoding="utf-8"), "second\n")
            self.assertEqual(first.name, "opencpn.conf.noaa-navionics.20260629T120000Z.bak")
            self.assertEqual(second.name, "opencpn.conf.noaa-navionics.20260629T120000Z.1.bak")

    def test_opencpn_backup_is_private_with_permissive_umask(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.write_text("original\n", encoding="utf-8")
            original_umask = os.umask(0)
            try:
                backup = opencpn_module._write_backup(config)
            finally:
                os.umask(original_umask)

            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            self.assertEqual(backup.read_text(encoding="utf-8"), "original\n")

    def test_opencpn_backup_uses_no_follow_private_open(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.write_text("original\n", encoding="utf-8")
            calls = []
            original_open = opencpn_module.os.open

            def capturing_open(path, flags, mode=0o777):
                calls.append((Path(path), flags, mode))
                return original_open(path, flags, mode)

            opencpn_module.os.open = capturing_open
            try:
                backup = opencpn_module._write_backup(config)
            finally:
                opencpn_module.os.open = original_open

            backup_calls = [call for call in calls if call[0] == backup]
            self.assertEqual(len(backup_calls), 1)
            self.assertTrue(backup_calls[0][1] & getattr(os, "O_NOFOLLOW", 0))
            self.assertEqual(backup_calls[0][2], 0o600)
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)

    def test_opencpn_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = opencpn_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        opencpn_module.os.open = fake_open
        try:
            opencpn_module._fsync_directory(Path("/tmp"))
        finally:
            opencpn_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_configure_chart_directory_writes_private_config_with_permissive_umask(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / ".opencpn" / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            original_umask = os.umask(0)
            try:
                configure_chart_directory(charts, config_path=config)
            finally:
                os.umask(original_umask)

            self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_configure_chart_directory_uses_unique_synced_temp_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            config.write_text("[Settings]\nShowStatusBar=1\n", encoding="utf-8")
            fixed_part = root / "opencpn.conf.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")
            calls = []
            original_fsync = opencpn_module.os.fsync
            opencpn_module.os.fsync = lambda fd: calls.append(fd)
            try:
                result = configure_chart_directory(charts, config_path=config)
            finally:
                opencpn_module.os.fsync = original_fsync

            self.assertTrue(result.changed)
            self.assertEqual(fixed_part.read_text(encoding="utf-8"), "other writer\n")
            self.assertFalse(list(root.glob(".opencpn.conf.*.part")))
            self.assertGreaterEqual(len(calls), 3)

    def test_configure_chart_directory_validates_promoted_file_with_no_follow_open(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            calls = []
            original_open = opencpn_module.os.open

            def fake_open(open_path, flags, mode=0o777, *args, **kwargs):
                calls.append((Path(open_path), flags))
                return original_open(open_path, flags, mode, *args, **kwargs)

            opencpn_module.os.open = fake_open
            try:
                configure_chart_directory(charts, config_path=config)
            finally:
                opencpn_module.os.open = original_open

            promoted_opens = [(opened_path, flags) for opened_path, flags in calls if opened_path == config]
            self.assertTrue(promoted_opens)
            self.assertTrue(promoted_opens[-1][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_configure_chart_directory_rejects_corrupt_promoted_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            original_replace = opencpn_module.os.replace

            def corrupt_after_replace(source, target):
                original_replace(source, target)
                Path(target).write_text("corrupt\n", encoding="utf-8")

            opencpn_module.os.replace = corrupt_after_replace
            try:
                with self.assertRaisesRegex(RuntimeError, "promoted OpenCPN config .* does not match"):
                    configure_chart_directory(charts, config_path=config)
            finally:
                opencpn_module.os.replace = original_replace

    def test_check_opencpn_chart_config_reports_missing_and_configured(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"

            missing = check_opencpn_chart_config(charts, config)
            self.assertFalse(missing.ok)

            charts.mkdir()
            configure_chart_directory(charts, config_path=config)
            configured = check_opencpn_chart_config(charts, config)
            self.assertTrue(configured.ok)
            data = configured.data or {}
            self.assertEqual(data["config_path"], str(config))
            self.assertEqual(data["chart_dir"], str(charts))
            self.assertTrue(data["config_exists"])
            self.assertTrue(data["chart_dir_exists"])
            self.assertTrue(data["configured"])
            self.assertEqual(data["chart_directories"], [str(charts)])

    def test_check_opencpn_chart_config_rejects_missing_configured_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "missing-charts"
            config.write_text(f"[ChartDirectories]\nChartDir1={charts}\n", encoding="utf-8")

            configured = check_opencpn_chart_config(charts, config)

            self.assertFalse(configured.ok)
            self.assertIn("chart directory does not exist", configured.detail)

    def test_configure_gpsd_connection_creates_nmea_data_source(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"

            result = configure_gpsd_connection(config_path=config, host="127.0.0.1", port=2947)

            self.assertTrue(result.changed)
            self.assertTrue(gpsd_connection_configured(config_path=config, host="localhost", port=2947))
            connections = read_data_connections(config)
            self.assertEqual(len(connections), 1)
            self.assertEqual(
                connections[0],
                "1;2;127.0.0.1;2947;0;;4800;1;0;0;;0;;0;0;0;0;1;"
                "GPSd: 127.0.0.1 TCP port 2947;0;;0;0;",
            )

    def test_configure_gpsd_connection_is_idempotent_and_preserves_existing_connections(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            existing = "1;0;192.0.2.10;10110;0;;4800;1;0;0;;0;;0;0;0;0;1;AIS;0;;0;0;"
            config.write_text(
                "[Settings/NMEADataSource]\n"
                f"DataConnections={existing}\n",
                encoding="utf-8",
            )

            first = configure_gpsd_connection(config_path=config, host="127.0.0.1", port=2947)
            second = configure_gpsd_connection(config_path=config, host="localhost", port=2947)

            self.assertTrue(first.changed)
            self.assertFalse(second.changed)
            connections = read_data_connections(config)
            self.assertEqual(connections[0], existing)
            self.assertEqual(len(connections), 2)

    def test_configure_gpsd_connection_removes_stale_enabled_gpsd_sources(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"

            configure_gpsd_connection(config_path=config, host="192.0.2.20", port=2947)
            result = configure_gpsd_connection(config_path=config, host="127.0.0.1", port=2947)

            self.assertTrue(result.changed)
            self.assertTrue(gpsd_connection_configured(config_path=config, host="localhost", port=2947))
            connections = read_data_connections(config)
            self.assertEqual(len(connections), 1)
            self.assertIn("127.0.0.1;2947", connections[0])
            self.assertNotIn("192.0.2.20", connections[0])

    def test_configure_gpsd_connection_uses_unique_synced_temp_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            fixed_part = root / "opencpn.conf.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")
            calls = []
            original_fsync = opencpn_module.os.fsync
            opencpn_module.os.fsync = lambda fd: calls.append(fd)
            try:
                result = configure_gpsd_connection(config_path=config)
            finally:
                opencpn_module.os.fsync = original_fsync

            self.assertTrue(result.changed)
            self.assertEqual(fixed_part.read_text(encoding="utf-8"), "other writer\n")
            self.assertFalse(list(root.glob(".opencpn.conf.*.part")))
            self.assertGreaterEqual(len(calls), 2)

    def test_process_state_from_stat_text(self):
        self.assertEqual(opencpn_module._process_state_from_stat_text("123 (opencpn) S 1 2 3"), "S")
        self.assertEqual(opencpn_module._process_state_from_stat_text("123 (opencpn) Z 1 2 3"), "Z")
        self.assertEqual(opencpn_module._process_state_from_stat_text("malformed"), "")

    def test_opencpn_running_from_proc_accepts_live_current_user_process(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            proc = Path(tmpdir)
            process = proc / "123"
            process.mkdir()
            (process / "stat").write_text("123 (opencpn) S 1 2 3\n", encoding="ascii")
            (process / "comm").write_text("opencpn\n", encoding="utf-8")

            self.assertTrue(opencpn_module._opencpn_running_from_proc(proc))

    def test_opencpn_running_from_proc_ignores_zombie_process(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            proc = Path(tmpdir)
            process = proc / "123"
            process.mkdir()
            (process / "stat").write_text("123 (opencpn) Z 1 2 3\n", encoding="ascii")
            (process / "comm").write_text("opencpn\n", encoding="utf-8")

            self.assertFalse(opencpn_module._opencpn_running_from_proc(proc))

    def test_opencpn_running_from_proc_rejects_symlinked_process_comm(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            proc = Path(tmpdir)
            process = proc / "123"
            process.mkdir()
            target = proc / "fake-comm"
            target.write_text("opencpn\n", encoding="utf-8")
            (process / "stat").write_text("123 (opencpn) S 1 2 3\n", encoding="ascii")
            try:
                (process / "comm").symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            self.assertFalse(opencpn_module._opencpn_running_from_proc(proc))

    def test_opencpn_running_from_proc_rejects_replaced_process_directory(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            proc = Path(tmpdir)
            process = proc / "123"
            replacement = proc / "replacement"
            process.mkdir()
            replacement.mkdir()
            (process / "stat").write_text("123 (old) S 1 2 3\n", encoding="ascii")
            (process / "comm").write_text("old\n", encoding="utf-8")
            (replacement / "stat").write_text("123 (opencpn) S 1 2 3\n", encoding="ascii")
            (replacement / "comm").write_text("opencpn\n", encoding="utf-8")
            original_open = opencpn_module.os.open

            def replacing_open(path, flags, mode=0o777, *, dir_fd=None):
                if dir_fd is None and Path(path) == process:
                    process.rename(proc / "old-process")
                    replacement.rename(process)
                if dir_fd is None:
                    return original_open(path, flags, mode)
                return original_open(path, flags, mode, dir_fd=dir_fd)

            try:
                opencpn_module.os.open = replacing_open
                self.assertFalse(opencpn_module._opencpn_running_from_proc(proc))
            finally:
                opencpn_module.os.open = original_open

    def test_check_opencpn_gpsd_config_reports_missing_and_configured(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"

            missing = check_opencpn_gpsd_config(config_path=config)
            self.assertFalse(missing.ok)

            configure_gpsd_connection(config_path=config)
            configured = check_opencpn_gpsd_config(config_path=config)
            self.assertTrue(configured.ok)
            data = configured.data or {}
            self.assertEqual(data["config_path"], str(config))
            self.assertEqual(data["expected_host"], "127.0.0.1")
            self.assertEqual(data["expected_port"], 2947)
            self.assertTrue(data["config_exists"])
            self.assertTrue(data["configured"])
            self.assertEqual(len(data["enabled_gpsd_connections"]), 1)
            self.assertEqual(data["enabled_gpsd_connections"][0]["host"], "127.0.0.1")
            self.assertEqual(data["enabled_gpsd_connections"][0]["port"], 2947)
            self.assertEqual(data["unexpected_connections"], [])

    def test_check_opencpn_gpsd_config_rejects_extra_enabled_gpsd_source(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            expected = opencpn_module._gpsd_connection_string("127.0.0.1", 2947)
            stale = opencpn_module._gpsd_connection_string("192.0.2.20", 2947)
            config.write_text(
                "[Settings/NMEADataSource]\n"
                f"DataConnections={expected}|{stale}\n",
                encoding="utf-8",
            )

            result = check_opencpn_gpsd_config(config_path=config, host="127.0.0.1", port=2947)

            self.assertFalse(result.ok)
            self.assertIn("unexpected enabled GPSD connection", result.detail)
            self.assertIn("192.0.2.20:2947", result.detail)

    def test_cli_configure_opencpn_skips_gpsd_for_serial_mode(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            opencpn_config = root / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            app_config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {charts}\n"
                "\n"
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )

            original = cli_module.opencpn_running
            try:
                cli_module.opencpn_running = lambda: False
                with redirect_stdout(StringIO()) as output:
                    code = cli_module.main(
                        [
                            "configure-opencpn",
                            "--config",
                            str(app_config),
                            "--opencpn-config",
                            str(opencpn_config),
                            "--dry-run",
                        ]
                    )
            finally:
                cli_module.opencpn_running = original

            self.assertEqual(code, 0)
            self.assertIn("GPSD skipped: gps.mode=serial", output.getvalue())
            self.assertNotIn("Added GPSD", output.getvalue())

    def test_cli_configure_opencpn_adds_gpsd_for_gpsd_mode(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            opencpn_config = root / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            app_config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {charts}\n"
                "\n"
                "[gps]\n"
                "mode = gpsd\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n",
                encoding="utf-8",
            )

            original = cli_module.opencpn_running
            try:
                cli_module.opencpn_running = lambda: False
                with redirect_stdout(StringIO()) as output:
                    code = cli_module.main(
                        [
                            "configure-opencpn",
                            "--config",
                            str(app_config),
                            "--opencpn-config",
                            str(opencpn_config),
                            "--dry-run",
                        ]
                    )
            finally:
                cli_module.opencpn_running = original

            self.assertEqual(code, 0)
            self.assertIn("Would add GPSD: 127.0.0.1:2947", output.getvalue())

    def test_cli_list_gps_devices_reports_stable_by_id_and_volatile_names(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            dev_root = Path(tmpdir)
            by_id = dev_root / "serial/by-id"
            by_id.mkdir(parents=True)
            volatile = dev_root / "ttyACM0"
            volatile.write_text("", encoding="ascii")
            (by_id / "usb-GPS_Receiver-if00").symlink_to("../../ttyACM0")

            stdout = StringIO()
            stderr = StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = cli_module.main(["list-gps-devices", "--dev-root", str(dev_root)])

            self.assertEqual(code, 0)
            self.assertEqual(stderr.getvalue(), "")
            output = stdout.getvalue()
            self.assertIn("PATH\tTYPE\tDETAIL", output)
            self.assertIn("/dev/serial/by-id/usb-GPS_Receiver-if00\tstable\tpoints to /dev/ttyACM0", output)
            self.assertIn(
                "/dev/ttyACM0\tvolatile\tnot safe for unattended provisioning",
                output,
            )

    def test_cli_list_gps_devices_warns_for_only_volatile_names(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            dev_root = Path(tmpdir)
            (dev_root / "ttyUSB0").write_text("", encoding="ascii")

            stdout = StringIO()
            stderr = StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = cli_module.main(["list-gps-devices", "--dev-root", str(dev_root)])

            self.assertEqual(code, 1)
            self.assertIn("/dev/ttyUSB0\tvolatile", stdout.getvalue())
            self.assertIn("Only volatile GPS device names were found", stderr.getvalue())

    def test_cli_list_gps_devices_reports_broken_by_id_without_success(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            dev_root = Path(tmpdir)
            by_id = dev_root / "serial/by-id"
            by_id.mkdir(parents=True)
            (by_id / "usb-GPS_Receiver-if00").symlink_to("../../ttyACM0")

            stdout = StringIO()
            stderr = StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = cli_module.main(["list-gps-devices", "--dev-root", str(dev_root)])

            self.assertEqual(code, 1)
            self.assertIn("PATH\tTYPE\tDETAIL", stdout.getvalue())
            self.assertIn(
                "/dev/serial/by-id/usb-GPS_Receiver-if00\tbroken\tbroken by-id symlink to /dev/ttyACM0",
                stdout.getvalue(),
            )
            self.assertIn("No usable stable GPS device paths were found", stderr.getvalue())

    def test_cli_list_gps_devices_warns_when_no_candidates_exist(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            stdout = StringIO()
            stderr = StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = cli_module.main(["list-gps-devices", "--dev-root", tmpdir])

            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("No GPS serial device candidates found", stderr.getvalue())

    def test_cli_log_track_uses_configured_output_and_gpsd_when_omitted(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            chart_output = root / "charts"
            track_output = root / "configured-tracks"
            app_config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {chart_output}\n"
                "\n"
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n"
                "retention_days = 14\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=1.0,
                longitude=2.0,
                satellites=8,
                hdop=1.2,
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
                gpsd_idle_timeout=None,
                serial_idle_timeout=None,
            ):
                calls.append(
                    (
                        device,
                        baud,
                        sample,
                        gpsd,
                        gpsd_host,
                        gpsd_port,
                        gpsd_connect_retry,
                        gpsd_idle_timeout,
                        serial_idle_timeout,
                    )
                )
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                stderr = StringIO()
                with redirect_stdout(StringIO()), redirect_stderr(stderr):
                    code = cli_module.main(["log-track", "--config", str(app_config), "--rotate-daily"])
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertEqual(
                calls,
                [("/dev/serial/by-id/mock-gps", 4800, None, True, "127.0.0.1", 2947, True, 300.0, None)],
            )
            expected_name = f"track-{fix.timestamp.strftime('%Y%m%d')}.gpx"
            self.assertTrue((track_output / "tracks" / expected_name).exists())
            self.assertIn("Live GPS stream ended unexpectedly", stderr.getvalue())

    def test_cli_mark_position_writes_mob_waypoint_to_configured_track_output(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            track_output = root / "configured-tracks"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.2181,
                longitude=-149.9003,
                satellites=9,
                hdop=0.9,
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
                gpsd_idle_timeout=None,
                serial_idle_timeout=None,
            ):
                calls.append((device, baud, sample, gpsd, gpsd_host, gpsd_port, deadline))
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                stdout = StringIO()
                with redirect_stdout(stdout):
                    code = cli_module.main(["mark-position", "--config", str(app_config), "--mob", "--seconds", "12"])
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][:6], ("/dev/serial/by-id/mock-gps", 4800, None, True, "127.0.0.1", 2947))
            self.assertIsNotNone(calls[0][6])
            mark_path = track_output / "tracks" / f"mob-{fix.timestamp.strftime('%Y%m%dT%H%M%SZ')}.gpx"
            self.assertTrue(mark_path.exists())
            text = mark_path.read_text(encoding="utf-8")
            self.assertIn('<wpt lat="61.21810000" lon="-149.90030000">', text)
            self.assertIn("<name>MOB</name>", text)
            self.assertIn("<desc>Man overboard position mark</desc>", text)
            self.assertIn("<sat>9</sat>", text)
            self.assertIn("<hdop>0.9</hdop>", text)
            self.assertEqual(stat.S_IMODE(mark_path.parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(mark_path.stat().st_mode), 0o600)
            self.assertIn(f"Marked position: {mark_path}", stdout.getvalue())

    def test_cli_anchor_watch_alarms_on_drift_from_explicit_anchor(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.0,
                longitude=-148.99,
                satellites=9,
                hdop=0.9,
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
                gpsd_idle_timeout=None,
                serial_idle_timeout=None,
            ):
                calls.append((device, baud, sample, gpsd, gpsd_host, gpsd_port, deadline))
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "anchor-watch",
                            "--config",
                            str(app_config),
                            "--anchor-lat",
                            "61.0",
                            "--anchor-lon",
                            "-149.0",
                            "--radius-meters",
                            "50",
                            "--seconds",
                            "12",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][:6], ("/dev/serial/by-id/mock-gps", 4800, None, True, "127.0.0.1", 2947))
            self.assertIsNotNone(calls[0][6])
            self.assertIn("Anchor distance:", stdout.getvalue())
            self.assertIn("ANCHOR ALARM", stderr.getvalue())

    def test_cli_anchor_watch_sets_anchor_from_first_fix_and_accepts_inside_radius(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=3)
            fixes = [
                GPSFix(
                    timestamp=now,
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                ),
                GPSFix(
                    timestamp=now + timedelta(seconds=1),
                    latitude=61.00001,
                    longitude=-149.00001,
                    satellites=9,
                    hdop=0.9,
                ),
            ]
            original = cli_module._read_fixes

            def fake_read_fixes(*args, **kwargs):
                return iter(fixes)

            try:
                cli_module._read_fixes = fake_read_fixes
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "anchor-watch",
                            "--config",
                            str(app_config),
                            "--radius-meters",
                            "50",
                            "--seconds",
                            "2",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            self.assertIn("Anchor set: 61.000000, -149.000000", stdout.getvalue())
            self.assertIn("Anchor distance:", stdout.getvalue())
            self.assertEqual(stderr.getvalue(), "")

    def test_cli_anchor_watch_rejects_run_without_post_anchor_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.0,
                longitude=-149.0,
                satellites=9,
                hdop=0.9,
            )
            original = cli_module._read_fixes

            try:
                cli_module._read_fixes = lambda *args, **kwargs: iter([fix])
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "anchor-watch",
                            "--config",
                            str(app_config),
                            "--radius-meters",
                            "50",
                            "--seconds",
                            "12",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertIn("Anchor set: 61.000000, -149.000000", stdout.getvalue())
            self.assertIn("need at least one drift check", stderr.getvalue())

    def test_cli_anchor_watch_rejects_timezone_less_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            naive_fix = GPSFix(
                timestamp=datetime(2026, 6, 30, 12, 0, 0),
                latitude=61.0,
                longitude=-148.99,
                satellites=9,
                hdop=0.9,
            )
            original = cli_module._read_fixes

            try:
                cli_module._read_fixes = lambda *args, **kwargs: iter([naive_fix])
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "anchor-watch",
                            "--config",
                            str(app_config),
                            "--anchor-lat",
                            "61.0",
                            "--anchor-lon",
                            "-149.0",
                            "--radius-meters",
                            "50",
                            "--seconds",
                            "12",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertNotIn("Anchor distance:", stdout.getvalue())
            self.assertIn("Skipping timezone-less anchor watch fix", stderr.getvalue())
            self.assertIn("No usable GPS fix was available for anchor watch.", stderr.getvalue())

    def test_cli_anchor_watch_averages_anchor_samples(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=3)
            fixes = [
                GPSFix(
                    timestamp=now,
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                ),
                GPSFix(
                    timestamp=now + timedelta(seconds=1),
                    latitude=61.00002,
                    longitude=-149.00002,
                    satellites=9,
                    hdop=0.9,
                ),
                GPSFix(
                    timestamp=now + timedelta(seconds=2),
                    latitude=61.00001,
                    longitude=-149.00001,
                    satellites=9,
                    hdop=0.9,
                ),
            ]
            original = cli_module._read_fixes

            try:
                cli_module._read_fixes = lambda *args, **kwargs: iter(fixes)
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "anchor-watch",
                            "--config",
                            str(app_config),
                            "--radius-meters",
                            "50",
                            "--anchor-samples",
                            "2",
                            "--seconds",
                            "12",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            self.assertIn("Anchor sample 1/2", stdout.getvalue())
            self.assertIn("Anchor set from 2 fixes: 61.000010, -149.000010", stdout.getvalue())
            self.assertIn("Anchor distance: 0.0 m", stdout.getvalue())
            self.assertEqual(stderr.getvalue(), "")

    def test_cli_anchor_watch_averages_anchor_samples_across_date_line(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=3)
            fixes = [
                GPSFix(timestamp=now, latitude=0.0, longitude=179.9, satellites=9, hdop=0.9),
                GPSFix(timestamp=now + timedelta(seconds=1), latitude=0.0, longitude=-179.9, satellites=9, hdop=0.9),
                GPSFix(timestamp=now + timedelta(seconds=2), latitude=0.0, longitude=179.95, satellites=9, hdop=0.9),
            ]
            original = cli_module._read_fixes

            try:
                cli_module._read_fixes = lambda *args, **kwargs: iter(fixes)
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "anchor-watch",
                            "--config",
                            str(app_config),
                            "--radius-meters",
                            "10000",
                            "--anchor-samples",
                            "2",
                            "--seconds",
                            "12",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            output = stdout.getvalue()
            self.assertIn("Anchor set from 2 fixes:", output)
            self.assertNotIn("Anchor set from 2 fixes: 0.000000, 0.000000", output)
            self.assertIn("Anchor distance: 5559.", output)
            self.assertEqual(stderr.getvalue(), "")

    def test_cli_anchor_watch_rejects_insufficient_anchor_samples(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=3)
            fixes = [
                GPSFix(
                    timestamp=now,
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                ),
                GPSFix(
                    timestamp=now + timedelta(seconds=1),
                    latitude=61.00002,
                    longitude=-149.00002,
                    satellites=9,
                    hdop=0.9,
                ),
            ]
            original = cli_module._read_fixes

            try:
                cli_module._read_fixes = lambda *args, **kwargs: iter(fixes)
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "anchor-watch",
                            "--config",
                            str(app_config),
                            "--radius-meters",
                            "50",
                            "--anchor-samples",
                            "3",
                            "--seconds",
                            "12",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertIn("Anchor sample 1/3", stdout.getvalue())
            self.assertIn("Anchor sample 2/3", stdout.getvalue())
            self.assertIn("need 3 anchor samples", stderr.getvalue())

    def test_cli_anchor_watch_uses_configured_radius_by_default(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "\n"
                "[anchor]\n"
                "radius_meters = 900\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.0,
                longitude=-148.99,
                satellites=9,
                hdop=0.9,
            )
            original = cli_module._read_fixes

            try:
                cli_module._read_fixes = lambda *args, **kwargs: iter([fix])
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "anchor-watch",
                            "--config",
                            str(app_config),
                            "--anchor-lat",
                            "61.0",
                            "--anchor-lon",
                            "-149.0",
                            "--seconds",
                            "12",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            self.assertIn("radius 900 m", stdout.getvalue())
            self.assertEqual(stderr.getvalue(), "")

    def test_cli_anchor_watch_interval_suppresses_non_alarm_updates_only(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=3)
            fixes = [
                GPSFix(
                    timestamp=now,
                    latitude=61.00001,
                    longitude=-149.00001,
                    satellites=9,
                    hdop=0.9,
                ),
                GPSFix(
                    timestamp=now + timedelta(seconds=1),
                    latitude=61.00002,
                    longitude=-149.00002,
                    satellites=9,
                    hdop=0.9,
                ),
                GPSFix(
                    timestamp=now + timedelta(seconds=2),
                    latitude=61.0,
                    longitude=-148.99,
                    satellites=9,
                    hdop=0.9,
                ),
            ]
            original = cli_module._read_fixes

            try:
                cli_module._read_fixes = lambda *args, **kwargs: iter(fixes)
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "anchor-watch",
                            "--config",
                            str(app_config),
                            "--anchor-lat",
                            "61.0",
                            "--anchor-lon",
                            "-149.0",
                            "--radius-meters",
                            "50",
                            "--interval-seconds",
                            "60",
                            "--seconds",
                            "12",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue().count("Anchor distance:"), 2)
            self.assertIn("ANCHOR ALARM", stderr.getvalue())

    def test_cli_anchor_watch_reports_stale_anchor_watch_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            stale = GPSFix(
                timestamp=datetime.now(timezone.utc) - timedelta(minutes=10),
                latitude=61.0,
                longitude=-149.0,
                satellites=9,
                hdop=0.9,
            )
            original = cli_module._read_fixes

            try:
                cli_module._read_fixes = lambda *args, **kwargs: iter([stale])
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "anchor-watch",
                            "--config",
                            str(app_config),
                            "--radius-meters",
                            "50",
                            "--seconds",
                            "12",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("Skipping stale anchor watch fix", stderr.getvalue())
            self.assertIn("No usable GPS fix was available for anchor watch.", stderr.getvalue())
            self.assertNotIn("track fix", stderr.getvalue())
            self.assertNotIn("GPX trackpoint", stderr.getvalue())

    def test_cli_log_track_timed_run_allows_finite_stream_after_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            track_output = root / "configured-tracks"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=1.0,
                longitude=2.0,
                satellites=8,
                hdop=1.2,
            )
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
                gpsd_idle_timeout=None,
                serial_idle_timeout=None,
            ):
                self.assertIsNotNone(deadline)
                self.assertTrue(gpsd_connect_retry)
                self.assertIsNone(gpsd_idle_timeout)
                self.assertIsNone(serial_idle_timeout)
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    code = cli_module.main(
                        ["log-track", "--config", str(app_config), "--rotate-daily", "--seconds", "0.1"]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            expected_name = f"track-{fix.timestamp.strftime('%Y%m%d')}.gpx"
            self.assertTrue((track_output / "tracks" / expected_name).exists())

    def test_cli_log_track_zero_gpsd_idle_timeout_disables_live_timeout(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            track_output = root / "tracks"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=1.0,
                longitude=2.0,
                satellites=8,
                hdop=1.2,
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
                gpsd_idle_timeout=None,
                serial_idle_timeout=None,
            ):
                calls.append((gpsd, gpsd_connect_retry, gpsd_idle_timeout, serial_idle_timeout))
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    code = cli_module.main(
                        [
                            "log-track",
                            "--config",
                            str(app_config),
                            "--rotate-daily",
                            "--gpsd-idle-timeout",
                            "0",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertEqual(calls, [(True, True, None, None)])

    def test_cli_log_track_zero_serial_idle_timeout_disables_live_timeout(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            track_output = root / "tracks"
            app_config.write_text(
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=1.0,
                longitude=2.0,
                satellites=8,
                hdop=1.2,
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
                gpsd_idle_timeout=None,
                serial_idle_timeout=None,
            ):
                calls.append((gpsd, gpsd_connect_retry, gpsd_idle_timeout, serial_idle_timeout))
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    code = cli_module.main(
                        [
                            "log-track",
                            "--config",
                            str(app_config),
                            "--rotate-daily",
                            "--serial-idle-timeout",
                            "0",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertEqual(calls, [(False, False, None, None)])

    def test_cli_log_track_explicit_device_and_output_override_config(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            configured_output = root / "configured-tracks"
            explicit_output = root / "explicit-tracks"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "\n"
                "[tracking]\n"
                f"output = {configured_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=1.0,
                longitude=2.0,
                satellites=8,
                hdop=1.2,
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
                gpsd_idle_timeout=None,
                serial_idle_timeout=None,
            ):
                calls.append((device, baud, sample, gpsd, gpsd_connect_retry, gpsd_idle_timeout, serial_idle_timeout))
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    code = cli_module.main(
                        [
                            "log-track",
                            "--config",
                            str(app_config),
                            "--device",
                            "/dev/serial/by-id/override-gps",
                            "--baud",
                            "9600",
                            "--output",
                            str(explicit_output),
                            "--rotate-daily",
                            "--seconds",
                            "0.1",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            self.assertEqual(calls, [("/dev/serial/by-id/override-gps", 9600, None, False, False, None, None)])
            self.assertFalse(configured_output.exists())
            expected_name = f"track-{fix.timestamp.strftime('%Y%m%d')}.gpx"
            self.assertTrue((explicit_output / "tracks" / expected_name).exists())

    def test_cli_log_track_rejects_volatile_explicit_serial_device(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "\n"
                "[tracking]\n"
                f"output = {root / 'tracks'}\n",
                encoding="utf-8",
            )

            stderr = StringIO()
            with redirect_stdout(StringIO()), redirect_stderr(stderr):
                code = cli_module.main(
                    [
                        "log-track",
                        "--config",
                        str(app_config),
                        "--device",
                        "/dev/ttyUSB0",
                        "--seconds",
                        "0.1",
                    ]
                )

            self.assertEqual(code, 2)
            self.assertIn("volatile USB name", stderr.getvalue())

    def test_cli_log_track_rejects_by_id_device_that_is_not_symlink(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "\n"
                "[tracking]\n"
                f"output = {root / 'tracks'}\n",
                encoding="utf-8",
            )
            original = cli_module._read_fixes

            def fail_if_opened(*args, **kwargs):
                raise AssertionError("non-symlink by-id device should be rejected before opening")

            try:
                cli_module._read_fixes = fail_if_opened
                stderr = StringIO()
                with (
                    patch("noaa_navionics.cli.Path.exists", return_value=True),
                    patch("noaa_navionics.cli.Path.is_symlink", return_value=False),
                    redirect_stdout(StringIO()),
                    redirect_stderr(stderr),
                ):
                    code = cli_module.main(
                        [
                            "log-track",
                            "--config",
                            str(app_config),
                            "--device",
                            "/dev/serial/by-id/mock-gps",
                            "--seconds",
                            "0.1",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 2)
            self.assertIn("udev by-id symlink", stderr.getvalue())

    def test_cli_gps_monitor_seconds_bounds_gpsd_wait(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=1.0,
                longitude=2.0,
                satellites=8,
                hdop=1.2,
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
            ):
                calls.append((device, baud, sample, gpsd, gpsd_host, gpsd_port, deadline, gpsd_connect_retry))
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    code = cli_module.main(["gps-monitor", "--config", str(app_config), "--once", "--seconds", "0.1"])
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][:6], ("/dev/serial/by-id/mock-gps", 4800, None, True, "127.0.0.1", 2947))
            self.assertIsNotNone(calls[0][6])
            self.assertTrue(calls[0][7])

    def test_cli_gps_monitor_rejects_position_only_fix(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n",
                encoding="utf-8",
            )
            position_only = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.2181,
                longitude=-149.9003,
            )
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
            ):
                return iter([position_only])

            try:
                cli_module._read_fixes = fake_read_fixes
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(["gps-monitor", "--config", str(app_config), "--once", "--seconds", "0.1"])
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("Skipping low-detail GPS monitor fix", stderr.getvalue())
            self.assertIn("cannot report a reliable live position", stderr.getvalue())

    def test_cli_gps_monitor_seconds_returns_nonzero_without_fix(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n",
                encoding="utf-8",
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
            ):
                calls.append((device, baud, sample, gpsd, deadline))
                return iter([])

            try:
                cli_module._read_fixes = fake_read_fixes
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    code = cli_module.main(["gps-monitor", "--config", str(app_config), "--once", "--seconds", "0.1"])
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][:4], ("/dev/serial/by-id/mock-gps", 4800, None, False))
            self.assertIsNotNone(calls[0][4])

    def test_cli_gps_monitor_rejects_volatile_explicit_serial_device(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n",
                encoding="utf-8",
            )

            stderr = StringIO()
            with redirect_stdout(StringIO()), redirect_stderr(stderr):
                code = cli_module.main(
                    [
                        "gps-monitor",
                        "--config",
                        str(app_config),
                        "--device",
                        "/dev/ttyACM0",
                        "--seconds",
                        "0.1",
                    ]
                )

            self.assertEqual(code, 2)
            self.assertIn("volatile USB name", stderr.getvalue())

    def test_cli_gps_monitor_rejects_by_id_device_that_is_not_symlink(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n",
                encoding="utf-8",
            )
            original = cli_module._read_fixes

            def fail_if_opened(*args, **kwargs):
                raise AssertionError("non-symlink by-id device should be rejected before opening")

            try:
                cli_module._read_fixes = fail_if_opened
                stderr = StringIO()
                with (
                    patch("noaa_navionics.cli.Path.exists", return_value=True),
                    patch("noaa_navionics.cli.Path.is_symlink", return_value=False),
                    redirect_stdout(StringIO()),
                    redirect_stderr(stderr),
                ):
                    code = cli_module.main(
                        [
                            "gps-monitor",
                            "--config",
                            str(app_config),
                            "--device",
                            "/dev/serial/by-id/mock-gps",
                            "--seconds",
                            "0.1",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 2)
            self.assertIn("udev by-id symlink", stderr.getvalue())

    def test_cli_log_track_seconds_fails_when_no_usable_fix_is_written(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            track_output = root / "tracks-out"
            app_config.write_text(
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            original = cli_module.open_nmea_stream

            def fake_open_nmea_stream(device, baud=4800):
                return BytesIO(b"")

            try:
                cli_module.open_nmea_stream = fake_open_nmea_stream
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "log-track",
                            "--config",
                            str(app_config),
                            "--seconds",
                            "0.01",
                        ]
                    )
            finally:
                cli_module.open_nmea_stream = original

            self.assertEqual(code, 1)
            self.assertIn("Saved 0 fixes", stdout.getvalue())
            self.assertIn("No usable GPS fixes", stderr.getvalue())
            self.assertFalse(track_output.exists())

    def test_read_fixes_retries_initial_gpsd_connection_for_live_logger(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        calls = []
        sleeps = []
        original_iter = cli_module.iter_gpsd_fixes
        original_sleep = cli_module.time.sleep

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            calls.append((host, port, timeout, max_duration))
            if len(calls) == 1:
                raise OSError("connection refused")
            return iter([fix])

        try:
            cli_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            cli_module.time.sleep = lambda seconds: sleeps.append(seconds)
            stderr = StringIO()
            with redirect_stderr(stderr):
                fixes = list(
                    cli_module._read_fixes(
                        "/dev/serial/by-id/mock-gps",
                        4800,
                        None,
                        gpsd=True,
                        gpsd_connect_retry=True,
                        gpsd_retry_delay=0.1,
                    )
                )
        finally:
            cli_module.iter_gpsd_fixes = original_iter
            cli_module.time.sleep = original_sleep

        self.assertEqual(fixes, [fix])
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [0.1])
        self.assertIn("GPSD unavailable at 127.0.0.1:2947", stderr.getvalue())

    def test_read_fixes_retries_initial_gpsd_connection_for_bounded_wait(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        calls = []
        sleeps = []
        original_iter = cli_module.iter_gpsd_fixes
        original_sleep = cli_module.time.sleep

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            calls.append((host, port, timeout, max_duration))
            if len(calls) == 1:
                raise OSError("connection refused")
            return iter([fix])

        try:
            cli_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            cli_module.time.sleep = lambda seconds: sleeps.append(seconds)
            stderr = StringIO()
            with redirect_stderr(stderr):
                fixes = list(
                    cli_module._read_fixes(
                        "/dev/serial/by-id/mock-gps",
                        4800,
                        None,
                        gpsd=True,
                        deadline=time.monotonic() + 1,
                        gpsd_connect_retry=True,
                        gpsd_retry_delay=0.1,
                    )
                )
        finally:
            cli_module.iter_gpsd_fixes = original_iter
            cli_module.time.sleep = original_sleep

        self.assertEqual(fixes, [fix])
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [0.1])
        self.assertIn("GPSD unavailable at 127.0.0.1:2947", stderr.getvalue())

    def test_read_fixes_retries_empty_gpsd_stream_before_first_fix(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        calls = []
        sleeps = []
        original_iter = cli_module.iter_gpsd_fixes
        original_sleep = cli_module.time.sleep

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            calls.append((host, port, timeout, max_duration))
            if len(calls) == 1:
                return iter(())
            return iter([fix])

        try:
            cli_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            cli_module.time.sleep = lambda seconds: sleeps.append(seconds)
            stderr = StringIO()
            with redirect_stderr(stderr):
                fixes = list(
                    cli_module._read_fixes(
                        "/dev/serial/by-id/mock-gps",
                        4800,
                        None,
                        gpsd=True,
                        gpsd_connect_retry=True,
                        gpsd_retry_delay=0.1,
                    )
                )
        finally:
            cli_module.iter_gpsd_fixes = original_iter
            cli_module.time.sleep = original_sleep

        self.assertEqual(fixes, [fix])
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [0.1])
        self.assertIn("ended before any fixes", stderr.getvalue())

    def test_read_fixes_does_not_retry_empty_gpsd_stream_for_bounded_run(self):
        calls = []
        sleeps = []
        original_iter = cli_module.iter_gpsd_fixes
        original_sleep = cli_module.time.sleep

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            calls.append((host, port, timeout, max_duration))
            return iter(())

        try:
            cli_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            cli_module.time.sleep = lambda seconds: sleeps.append(seconds)
            fixes = list(
                cli_module._read_fixes(
                    "/dev/serial/by-id/mock-gps",
                    4800,
                    None,
                    gpsd=True,
                    deadline=time.monotonic() + 1,
                    gpsd_connect_retry=True,
                    gpsd_retry_delay=0.1,
                )
            )
        finally:
            cli_module.iter_gpsd_fixes = original_iter
            cli_module.time.sleep = original_sleep

        self.assertEqual(fixes, [])
        self.assertEqual(len(calls), 1)
        self.assertEqual(sleeps, [])

    def test_read_fixes_does_not_retry_gpsd_failure_after_fix(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        calls = []
        sleeps = []
        original_iter = cli_module.iter_gpsd_fixes
        original_sleep = cli_module.time.sleep

        def failing_stream():
            yield fix
            raise OSError("gpsd stream reset")

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            calls.append((host, port, timeout, max_duration))
            return failing_stream()

        try:
            cli_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            cli_module.time.sleep = lambda seconds: sleeps.append(seconds)
            fixes = cli_module._read_fixes(
                "/dev/serial/by-id/mock-gps",
                4800,
                None,
                gpsd=True,
                gpsd_connect_retry=True,
                gpsd_retry_delay=0.1,
            )
            self.assertEqual(next(fixes), fix)
            with self.assertRaisesRegex(OSError, "gpsd stream reset"):
                next(fixes)
        finally:
            cli_module.iter_gpsd_fixes = original_iter
            cli_module.time.sleep = original_sleep

        self.assertEqual(len(calls), 1)
        self.assertEqual(sleeps, [])

    def test_read_fixes_passes_live_gpsd_idle_timeout(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        calls = []
        original_iter = cli_module.iter_gpsd_fixes

        def fake_iter_gpsd_fixes(**kwargs):
            calls.append(kwargs)
            return iter([fix])

        try:
            cli_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            fixes = list(
                cli_module._read_fixes(
                    "/dev/serial/by-id/mock-gps",
                    4800,
                    None,
                    gpsd=True,
                    gpsd_idle_timeout=300.0,
                )
            )
        finally:
            cli_module.iter_gpsd_fixes = original_iter

        self.assertEqual(fixes, [fix])
        self.assertEqual(calls[0]["idle_timeout"], 300.0)

    def test_read_fixes_passes_live_serial_idle_timeout(self):
        calls = []
        original_open = cli_module.open_nmea_stream
        original_read_lines = cli_module.read_nmea_lines

        class FakeStream:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

        def fake_open_nmea_stream(device, baud=4800):
            calls.append(("open", device, baud))
            return FakeStream()

        def fake_read_nmea_lines(stream, *, idle_timeout=None):
            calls.append(("read", idle_timeout))
            return iter(["$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"])

        try:
            cli_module.open_nmea_stream = fake_open_nmea_stream
            cli_module.read_nmea_lines = fake_read_nmea_lines
            fixes = list(
                cli_module._read_fixes(
                    "/dev/serial/by-id/mock-gps",
                    4800,
                    None,
                    serial_idle_timeout=300.0,
                )
            )
        finally:
            cli_module.open_nmea_stream = original_open
            cli_module.read_nmea_lines = original_read_lines

        self.assertEqual(calls, [("open", "/dev/serial/by-id/mock-gps", 4800), ("read", 300.0)])
        self.assertEqual(len(fixes), 1)
        self.assertAlmostEqual(fixes[0].latitude, 48.1173, places=4)


class GuiTests(unittest.TestCase):
    def test_gui_package_options_are_complete_onboard_chart_sources(self):
        self.assertEqual(set(gui_module.PACKAGE_KIND_OPTIONS), config_module.CHART_PACKAGES)
        self.assertNotIn("updates", gui_module.PACKAGE_KIND_OPTIONS)
        self.assertNotIn("catalog", gui_module.PACKAGE_KIND_OPTIONS)

    def test_status_gui_summarizes_readiness_rows(self):
        generated_at = fresh_status_timestamp()
        report = complete_status_gui_report(ok=False, gps_mode="serial", generated_at=generated_at)
        report["checks"].append({"name": "Extra GPS", "ok": False, "detail": "no fix"})

        rows = status_gui_module.status_rows(report)

        self.assertEqual(status_gui_module.status_headline(report), "NOT READY")
        self.assertEqual(rows[0], status_gui_module.StatusRow("Overall", False, f"generated {generated_at}"))
        self.assertIn(status_gui_module.StatusRow("Extra GPS", False, "no fix"), rows)
        self.assertEqual(status_gui_module.count_failures(rows), 2)
        self.assertEqual(status_gui_module.format_panel_summary(report), "2 reported readiness check(s) need attention.")

    def test_status_gui_renders_truthy_non_boolean_ok_values_as_failures(self):
        report = complete_status_gui_report()
        report["ok"] = "yes"
        for row in report["checks"]:
            if row["name"] == "Python":
                row["ok"] = "yes"
                break
        report["gps_fix"]["ok"] = "yes"

        rows = status_gui_module.status_rows(report)

        self.assertEqual(status_gui_module.status_headline(report), "NOT READY")
        self.assertIn(status_gui_module.StatusRow("Overall", False, f"generated {report['generated_at']}"), rows)
        self.assertIn(status_gui_module.StatusRow("Python", False, "running Python 3.11.2"), rows)
        self.assertTrue(
            any(row.name == "Status Report" and row.detail == "status report top-level ok is not boolean" for row in rows)
        )
        self.assertTrue(
            any(row.name == "Status Report" and row.detail == "status report Python ok is not boolean" for row in rows)
        )
        self.assertTrue(status_gui_module.format_gps_summary(report).startswith("GPSD FAIL"))

    def test_status_gui_reports_ready_when_all_rows_pass(self):
        report = complete_status_gui_report()

        self.assertEqual(status_gui_module.status_headline(report), "READY")
        self.assertEqual(status_gui_module.format_panel_summary(report), "All reported navigation readiness checks are passing.")

    def test_status_gui_rejects_incomplete_ready_report(self):
        report = {
            "ok": True,
            "generated_at": "2026-06-30T12:00:00Z",
            "checks": [{"name": "GPS", "ok": True, "detail": "fix"}],
            "service_checks": [{"name": "Track Log", "ok": True, "detail": "recent point"}],
        }

        rows = status_gui_module.status_rows(report)
        missing = [row for row in rows if "missing this" in row.detail]

        self.assertEqual(status_gui_module.status_headline(report), "NOT READY")
        self.assertTrue(missing)
        self.assertIn("reported readiness check(s) need attention", status_gui_module.format_panel_summary(report))

    def test_status_gui_formats_structured_gps_summary(self):
        report = {
            "gps_fix": {
                "source": "GPSD",
                "ok": True,
                "latitude": 61.2181,
                "longitude": -149.9003,
                "timestamp": "2026-06-30T12:34:56Z",
                "age_seconds": 5.4,
                "satellites": 9,
                "hdop": 0.9,
                "speed_knots": 4.2,
                "course_degrees": 181.5,
            },
        }

        self.assertEqual(
            status_gui_module.format_gps_summary(report),
            "GPSD OK | 61.218100, -149.900300 | 2026-06-30T12:34:56Z | age 5s | 9 sats | HDOP 0.9 | 4.2 kt | 181.5 deg",
        )
        self.assertEqual(status_gui_module.format_gps_summary({}), "GPS: not reported")

    def test_cli_status_gui_forwards_arguments(self):
        calls = []
        original = status_gui_module.main

        def fake_status_gui_main(argv=None):
            calls.append(list(argv or []))

        try:
            status_gui_module.main = fake_status_gui_main
            result = cli_module.main(
                [
                    "status-gui",
                    "--config",
                    "/tmp/config.ini",
                    "--output",
                    "/tmp/status.json",
                    "--gps-seconds",
                    "12",
                    "--action-gps-seconds",
                    "4",
                    "--refresh-seconds",
                    "0",
                    "--anchor-watch-seconds",
                    "15",
                    "--anchor-radius-meters",
                    "75",
                    "--anchor-samples",
                    "3",
                ]
            )
        finally:
            status_gui_module.main = original

        self.assertEqual(result, 0)
        self.assertEqual(
            calls,
            [
                [
                    "--config",
                    "/tmp/config.ini",
                    "--gps-seconds",
                    "12.0",
                    "--refresh-seconds",
                    "0.0",
                    "--action-gps-seconds",
                    "4.0",
                    "--anchor-watch-seconds",
                    "15.0",
                    "--anchor-radius-meters",
                    "75.0",
                    "--anchor-samples",
                    "3",
                    "--output",
                    "/tmp/status.json",
                ]
            ],
        )

    def test_status_gui_write_current_position_mark_uses_configured_track_output(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_output = root / "tracks-root"
            config_path = root / "config.ini"
            config_path.write_text(
                "[charts]\n"
                f"output = {root / 'charts'}\n"
                "\n"
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.2181,
                longitude=-149.9003,
                satellites=9,
                hdop=0.9,
            )
            original = status_gui_module.read_configured_gps_fix

            try:
                status_gui_module.read_configured_gps_fix = lambda app_config, **kwargs: fix
                path, returned_fix = status_gui_module.write_current_position_mark(config_path, mob=True)
            finally:
                status_gui_module.read_configured_gps_fix = original

            self.assertIs(returned_fix, fix)
            self.assertEqual(path, track_output / "tracks" / f"mob-{fix.timestamp.strftime('%Y%m%dT%H%M%SZ')}.gpx")
            text = path.read_text(encoding="utf-8")
            self.assertIn("<name>MOB</name>", text)
            self.assertIn("<desc>Man overboard position mark</desc>", text)

    def test_status_gui_position_mark_uses_action_gps_seconds(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_output = root / "tracks-root"
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.2181,
                longitude=-149.9003,
                satellites=9,
                hdop=0.9,
            )
            calls = []
            original = status_gui_module.read_configured_gps_fix

            def fake_read_configured_gps_fix(app_config, **kwargs):
                calls.append(kwargs)
                return fix

            try:
                status_gui_module.read_configured_gps_fix = fake_read_configured_gps_fix
                status_gui_module.write_current_position_mark(config_path, gps_seconds=4.0, mob=True)
            finally:
                status_gui_module.read_configured_gps_fix = original

            self.assertEqual(calls, [{"gps_seconds": 4.0}])

    def test_status_gui_position_mark_rejects_stale_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_output = root / "tracks-root"
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc) - timedelta(seconds=600),
                latitude=61.2181,
                longitude=-149.9003,
                satellites=9,
                hdop=0.9,
            )
            original = status_gui_module.read_configured_gps_fix

            try:
                status_gui_module.read_configured_gps_fix = lambda app_config, **kwargs: fix
                with self.assertRaisesRegex(ValueError, "fresh GPS fix"):
                    status_gui_module.write_current_position_mark(config_path, mob=True)
            finally:
                status_gui_module.read_configured_gps_fix = original

            self.assertFalse((track_output / "tracks").exists())

    def test_status_gui_position_mark_rejects_future_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_output = root / "tracks-root"
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc) + timedelta(seconds=1),
                latitude=61.2181,
                longitude=-149.9003,
                satellites=9,
                hdop=0.9,
            )
            original = status_gui_module.read_configured_gps_fix

            try:
                status_gui_module.read_configured_gps_fix = lambda app_config, **kwargs: fix
                with self.assertRaisesRegex(ValueError, "future"):
                    status_gui_module.write_current_position_mark(config_path, mob=True)
            finally:
                status_gui_module.read_configured_gps_fix = original

            self.assertFalse((track_output / "tracks").exists())

    def test_status_gui_position_mark_rejects_timezone_less_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_output = root / "tracks-root"
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime(2026, 6, 30, 12, 0, 0),
                latitude=61.2181,
                longitude=-149.9003,
                satellites=9,
                hdop=0.9,
            )
            original = status_gui_module.read_configured_gps_fix

            try:
                status_gui_module.read_configured_gps_fix = lambda app_config, **kwargs: fix
                with self.assertRaisesRegex(ValueError, "fix timestamp has no timezone"):
                    status_gui_module.write_current_position_mark(config_path, mob=True)
            finally:
                status_gui_module.read_configured_gps_fix = original

            self.assertFalse((track_output / "tracks").exists())

    def test_status_gui_anchor_check_uses_configured_gps_fixes(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=2)
            anchor_fix = GPSFix(
                timestamp=now,
                latitude=61.0,
                longitude=-149.0,
                satellites=9,
                hdop=0.9,
            )
            current_fix = GPSFix(
                timestamp=now + timedelta(seconds=1),
                latitude=61.0,
                longitude=-148.99,
                satellites=9,
                hdop=0.9,
            )
            calls = []
            original = status_gui_module.read_configured_gps_fixes

            def fake_read_configured_gps_fixes(app_config, *, count, gps_seconds=10.0, **kwargs):
                calls.append((app_config.gps_mode, count, gps_seconds, kwargs))
                return [anchor_fix, current_fix]

            try:
                status_gui_module.read_configured_gps_fixes = fake_read_configured_gps_fixes
                distance, radius, returned_anchor, returned_current = status_gui_module.check_anchor_drift(
                    config_path,
                    gps_seconds=12.0,
                    radius_meters=50.0,
                )
            finally:
                status_gui_module.read_configured_gps_fixes = original

            self.assertEqual(calls, [("gpsd", 2, 12.0, {})])
            self.assertEqual(radius, 50.0)
            self.assertIs(returned_anchor, anchor_fix)
            self.assertIs(returned_current, current_fix)
            self.assertGreater(distance, 500.0)
            self.assertIn("ANCHOR ALARM", status_gui_module.format_anchor_check(distance, radius))
            self.assertIn("Anchor OK", status_gui_module.format_anchor_check(1.0, radius))
            self.assertTrue(status_gui_module.anchor_alarm_active(distance, radius))
            self.assertFalse(status_gui_module.anchor_alarm_active(radius, radius))

    def test_status_gui_anchor_check_uses_action_gps_seconds(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=2)
            fixes = [
                GPSFix(timestamp=now, latitude=61.0, longitude=-149.0, satellites=9, hdop=0.9),
                GPSFix(
                    timestamp=now + timedelta(seconds=1),
                    latitude=61.0,
                    longitude=-148.99,
                    satellites=9,
                    hdop=0.9,
                ),
            ]
            calls = []
            original = status_gui_module.read_configured_gps_fixes

            def fake_read_configured_gps_fixes(app_config, *, count, gps_seconds=10.0, **kwargs):
                calls.append((count, gps_seconds, kwargs))
                return fixes

            try:
                status_gui_module.read_configured_gps_fixes = fake_read_configured_gps_fixes
                status_gui_module.check_anchor_drift(config_path, gps_seconds=4.0, radius_meters=50.0)
            finally:
                status_gui_module.read_configured_gps_fixes = original

            self.assertEqual(calls, [(2, 4.0, {})])

    def test_status_gui_anchor_watch_captures_average_anchor_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=2)
            fixes = [
                GPSFix(timestamp=now, latitude=61.0, longitude=-149.0, satellites=10, hdop=0.8),
                GPSFix(
                    timestamp=now + timedelta(seconds=1),
                    latitude=61.2,
                    longitude=-148.8,
                    satellites=8,
                    hdop=1.1,
                ),
            ]
            calls = []
            original = status_gui_module.read_configured_gps_fixes

            def fake_read_configured_gps_fixes(app_config, *, count, gps_seconds=10.0, **kwargs):
                calls.append((count, gps_seconds, kwargs))
                return fixes

            try:
                status_gui_module.read_configured_gps_fixes = fake_read_configured_gps_fixes
                anchor_fix = status_gui_module.capture_anchor_watch_fix(
                    config_path,
                    gps_seconds=4.0,
                    anchor_samples=2,
                )
            finally:
                status_gui_module.read_configured_gps_fixes = original

            self.assertEqual(calls, [(2, 4.0, {})])
            self.assertAlmostEqual(anchor_fix.latitude, 61.1)
            self.assertAlmostEqual(anchor_fix.longitude, -148.9)
            self.assertEqual(anchor_fix.satellites, 8)
            self.assertEqual(anchor_fix.hdop, 1.1)

    def test_status_gui_anchor_watch_averages_longitude_across_date_line(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=2)
            fixes = [
                GPSFix(timestamp=now, latitude=0.0, longitude=179.9, satellites=10, hdop=0.8),
                GPSFix(timestamp=now + timedelta(seconds=1), latitude=0.0, longitude=-179.9, satellites=8, hdop=1.1),
            ]
            original = status_gui_module.read_configured_gps_fixes

            try:
                status_gui_module.read_configured_gps_fixes = lambda app_config, **kwargs: fixes
                anchor_fix = status_gui_module.capture_anchor_watch_fix(
                    config_path,
                    gps_seconds=4.0,
                    anchor_samples=2,
                )
            finally:
                status_gui_module.read_configured_gps_fixes = original

            self.assertAlmostEqual(abs(anchor_fix.longitude), 180.0)
            self.assertNotAlmostEqual(anchor_fix.longitude, 0.0)
            self.assertEqual(anchor_fix.satellites, 8)
            self.assertEqual(anchor_fix.hdop, 1.1)

    def test_status_gui_anchor_watch_checks_current_fix_against_stored_anchor(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            anchor_fix = GPSFix(
                timestamp=datetime.now(timezone.utc) - timedelta(hours=6),
                latitude=61.0,
                longitude=-149.0,
                satellites=9,
                hdop=0.9,
            )
            current_fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.0,
                longitude=-148.99,
                satellites=9,
                hdop=0.9,
            )
            calls = []
            original = status_gui_module.read_configured_gps_fix

            def fake_read_configured_gps_fix(app_config, **kwargs):
                calls.append(kwargs)
                return current_fix

            try:
                status_gui_module.read_configured_gps_fix = fake_read_configured_gps_fix
                distance, radius, returned_anchor, returned_current = status_gui_module.check_anchor_watch_drift(
                    config_path,
                    anchor_fix,
                    gps_seconds=4.0,
                    radius_meters=50.0,
                )
            finally:
                status_gui_module.read_configured_gps_fix = original

            self.assertEqual(calls, [{"gps_seconds": 4.0}])
            self.assertEqual(radius, 50.0)
            self.assertIs(returned_anchor, anchor_fix)
            self.assertIs(returned_current, current_fix)
            self.assertGreater(distance, 500.0)

    def test_status_gui_anchor_watch_set_updates_button_state_after_storing_anchor(self):
        class FakeVar:
            def __init__(self):
                self.values = []

            def set(self, value):
                self.values.append(value)

        class FakeApp:
            def __init__(self):
                self.anchor_watch_fix = None
                self.anchor_watch_radius_meters = None
                self.anchor_watch_alarm_active = True
                self.anchor_watch_alarm_summary = "old alarm"
                self.anchor_watch_alarm_detail = "old detail"
                self.anchor_watch_status_summary = "old status"
                self.anchor_watch_status_detail = "old detail"
                self.anchor_radius = FakeVar()
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.busy_calls = []
                self.watch_scheduled = 0
                self.refresh_scheduled = 0

            def _set_busy(self, busy):
                self.busy_calls.append((busy, self.anchor_watch_fix))

            def _schedule_anchor_watch(self):
                self.watch_scheduled += 1

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

        app = FakeApp()
        anchor_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            satellites=9,
            hdop=0.9,
        )

        status_gui_module.StatusApp._show_anchor_watch_set(app, anchor_fix, 50.0)

        self.assertEqual(app.anchor_watch_fix, anchor_fix)
        self.assertEqual(app.anchor_watch_radius_meters, 50.0)
        self.assertEqual(app.busy_calls, [(False, anchor_fix)])
        self.assertFalse(app.anchor_watch_alarm_active)
        self.assertIsNone(app.anchor_watch_alarm_summary)
        self.assertIsNone(app.anchor_watch_alarm_detail)
        self.assertEqual(app.anchor_watch_status_summary, "Anchor watch armed; radius 50 m")
        self.assertIn("Anchor watch set:", app.anchor_watch_status_detail)
        self.assertEqual(app.watch_scheduled, 1)
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_status_refresh_preserves_active_anchor_alarm(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeTree:
            def get_children(self):
                return []

            def delete(self, item):
                raise AssertionError("no items should be deleted")

            def insert(self, *args, **kwargs):
                return None

        class FakeApp:
            def __init__(self):
                self.anchor_watch_alarm_active = True
                self.anchor_watch_alarm_summary = "Anchor watch: ANCHOR ALARM: 75.0 m from anchor; radius 50 m"
                self.anchor_watch_alarm_detail = "Anchor 61.000000, -149.000000 | Current 61.000000, -148.990000"
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.tree = FakeTree()
                self.output_path = Path("/tmp/status.json")
                self.busy_calls = []
                self.refresh_scheduled = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

        app = FakeApp()
        report = complete_status_gui_report()

        status_gui_module.StatusApp._show_report(app, report)

        self.assertEqual(app.headline.value, "NOT READY")
        self.assertEqual(app.summary.value, app.anchor_watch_alarm_summary)
        self.assertEqual(app.gps_summary.value, app.anchor_watch_alarm_detail)
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_status_refresh_preserves_active_anchor_watch_ok_status(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeTree:
            def get_children(self):
                return []

            def delete(self, item):
                raise AssertionError("no items should be deleted")

            def insert(self, *args, **kwargs):
                return None

        class FakeApp:
            def __init__(self):
                self.anchor_watch_fix = GPSFix(
                    timestamp=datetime.now(timezone.utc),
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                )
                self.anchor_watch_alarm_active = False
                self.anchor_watch_alarm_summary = None
                self.anchor_watch_alarm_detail = None
                self.anchor_watch_status_summary = "Anchor watch: Anchor OK: 3.0 m from anchor; radius 50 m"
                self.anchor_watch_status_detail = "Anchor 61.000000, -149.000000 | Current 61.000010, -149.000010"
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.tree = FakeTree()
                self.output_path = Path("/tmp/status.json")
                self.busy_calls = []
                self.refresh_scheduled = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

        app = FakeApp()
        report = complete_status_gui_report()

        status_gui_module.StatusApp._show_report(app, report)

        self.assertEqual(app.headline.value, "READY")
        self.assertEqual(app.summary.value, app.anchor_watch_status_summary)
        self.assertEqual(app.gps_summary.value, app.anchor_watch_status_detail)
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_status_refresh_does_not_hide_readiness_failure_for_anchor_watch_ok(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeTree:
            def get_children(self):
                return []

            def delete(self, item):
                raise AssertionError("no items should be deleted")

            def insert(self, *args, **kwargs):
                return None

        class FakeApp:
            def __init__(self):
                self.anchor_watch_fix = GPSFix(
                    timestamp=datetime.now(timezone.utc),
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                )
                self.anchor_watch_alarm_active = False
                self.anchor_watch_alarm_summary = None
                self.anchor_watch_alarm_detail = None
                self.anchor_watch_status_summary = "Anchor watch: Anchor OK: 3.0 m from anchor; radius 50 m"
                self.anchor_watch_status_detail = "Anchor 61.000000, -149.000000 | Current 61.000010, -149.000010"
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.tree = FakeTree()
                self.output_path = None
                self.busy_calls = []
                self.refresh_scheduled = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

        app = FakeApp()
        report = complete_status_gui_report(ok=False)
        for check in report["checks"]:
            if check["name"] == "GPSD":
                check["ok"] = False
                check["detail"] = "no fix"
                break
        report["gps_fix"] = {
            "source": "GPSD",
            "ok": False,
            "detail": "no fix",
        }

        status_gui_module.StatusApp._show_report(app, report)

        self.assertEqual(app.headline.value, "NOT READY")
        self.assertEqual(app.summary.value, "3 reported readiness check(s) need attention.")
        self.assertEqual(app.gps_summary.value, "GPSD FAIL | no fix")
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_status_refresh_does_not_hide_incomplete_report_for_anchor_watch_ok(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeTree:
            def get_children(self):
                return []

            def delete(self, item):
                raise AssertionError("no items should be deleted")

            def insert(self, *args, **kwargs):
                return None

        class FakeApp:
            def __init__(self):
                self.anchor_watch_fix = GPSFix(
                    timestamp=datetime.now(timezone.utc),
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                )
                self.anchor_watch_alarm_active = False
                self.anchor_watch_alarm_summary = None
                self.anchor_watch_alarm_detail = None
                self.anchor_watch_status_summary = "Anchor watch: Anchor OK: 3.0 m from anchor; radius 50 m"
                self.anchor_watch_status_detail = "Anchor 61.000000, -149.000000 | Current 61.000010, -149.000010"
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.tree = FakeTree()
                self.output_path = None
                self.busy_calls = []
                self.refresh_scheduled = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

        app = FakeApp()
        report = {
            "ok": True,
            "generated_at": "2026-06-30T12:00:00Z",
            "checks": [{"name": "GPSD", "ok": True, "detail": "fix"}],
            "service_checks": [{"name": "Track Log", "ok": True, "detail": "recent point"}],
        }

        status_gui_module.StatusApp._show_report(app, report)

        self.assertEqual(app.headline.value, "NOT READY")
        self.assertNotEqual(app.summary.value, app.anchor_watch_status_summary)
        self.assertIn("reported readiness check(s) need attention", app.summary.value)
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.refresh_scheduled, 1)

    def test_gui_status_report_uses_shared_readiness_validation(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.queue = gui_module.Queue()
                self.status = FakeVar()
                self.logs = []
                self.busy_calls = []
                self.after_calls = []

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _log(self, message):
                self.logs.append(message)

            def after(self, milliseconds, callback):
                self.after_calls.append((milliseconds, callback))

            def _poll_queue(self):
                raise AssertionError("scheduled callback should not run during this test")

        app = FakeApp()
        report = {
            "ok": True,
            "generated_at": "2026-06-30T12:00:00Z",
            "checks": [{"name": "GPSD", "ok": True, "detail": "fix"}],
            "service_checks": [{"name": "Track Log", "ok": True, "detail": "recent point"}],
        }
        app.queue.put(("status-report", (report, Path("/tmp/status.json"))))

        gui_module.DownloaderApp._poll_queue(app)

        self.assertEqual(app.status.value, "Status report needs attention")
        self.assertEqual(app.busy_calls, [False])
        self.assertTrue(any("Ready: no" in message for message in app.logs))
        self.assertTrue(any("status report is missing this readiness check" in message for message in app.logs))
        self.assertEqual(len(app.after_calls), 1)

    def test_gui_download_waits_for_unprocessed_worker_result(self):
        class FinishedWorker:
            def is_alive(self):
                return False

        class FakeApp:
            def __init__(self):
                self.worker = FinishedWorker()

            def _selected_package(self):
                raise AssertionError("download should wait until queued worker result is processed")

            def _set_busy(self, busy):
                raise AssertionError("download should not start a new worker")

        app = FakeApp()

        gui_module.DownloaderApp._start_download(app)

        self.assertIsInstance(app.worker, FinishedWorker)

    def test_gui_poll_queue_keeps_worker_during_progress_and_clears_on_done(self):
        class FinishedWorker:
            def is_alive(self):
                return False

        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeProgress:
            def __init__(self, app):
                self.app = app
                self.calls = []

            def configure(self, **kwargs):
                self.calls.append((kwargs, self.app.worker))

        class FakeResult:
            def __init__(self):
                self.skipped = False
                self.path = Path("/tmp/charts.zip")
                self.extracted_to = None

        class FakeApp:
            def __init__(self):
                self.queue = gui_module.Queue()
                self.queue.put(("progress", (5, 10)))
                self.queue.put(("done", FakeResult()))
                self.worker = FinishedWorker()
                self.progress = FakeProgress(self)
                self.status = FakeVar()
                self.logs = []
                self.busy_calls = []
                self.after_calls = []

            def _set_busy(self, busy):
                self.busy_calls.append((busy, self.worker))

            def _log(self, message):
                self.logs.append(message)

            def after(self, milliseconds, callback):
                self.after_calls.append((milliseconds, callback))

            def _poll_queue(self):
                raise AssertionError("scheduled callback should not run during this test")

        app = FakeApp()

        gui_module.DownloaderApp._poll_queue(app)

        self.assertEqual(app.progress.calls[0][0], {"mode": "determinate", "value": 50.0})
        self.assertIsInstance(app.progress.calls[0][1], FinishedWorker)
        self.assertEqual(app.busy_calls, [(False, None)])
        self.assertIsNone(app.worker)
        self.assertEqual(app.status.value, "Done")
        self.assertTrue(any("Downloaded: /tmp/charts.zip" in message for message in app.logs))
        self.assertEqual(len(app.after_calls), 1)

    def test_gui_close_cancels_poll_callback(self):
        class FakeApp:
            def __init__(self):
                self._closed = False
                self.poll_after_id = "poll-after"
                self.cancelled = []
                self.destroyed = False

            def after_cancel(self, after_id):
                self.cancelled.append(after_id)

            def destroy(self):
                self.destroyed = True

        app = FakeApp()

        gui_module.DownloaderApp.close(app)

        self.assertTrue(app._closed)
        self.assertEqual(app.cancelled, ["poll-after"])
        self.assertIsNone(app.poll_after_id)
        self.assertTrue(app.destroyed)

    def test_gui_poll_queue_does_not_reschedule_after_close(self):
        class FakeApp:
            def __init__(self):
                self._closed = True
                self.poll_after_id = "poll-after"
                self.queue = gui_module.Queue()

            def after(self, milliseconds, callback):
                raise AssertionError("closed GUI should not schedule queue polling")

        app = FakeApp()

        gui_module.DownloaderApp._poll_queue(app)

        self.assertIsNone(app.poll_after_id)

    def test_gui_actions_do_not_start_after_close(self):
        class FakeApp:
            def __init__(self):
                self._closed = True
                self.worker = None

            def _selected_package(self):
                raise AssertionError("closed GUI should not parse a package")

            def _set_busy(self, busy):
                raise AssertionError("closed GUI should not start work")

        app = FakeApp()

        gui_module.DownloaderApp._start_download(app)

        self.assertIsNone(app.worker)

    def test_status_gui_mark_does_not_hide_active_anchor_alarm(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.anchor_watch_alarm_active = True
                self.anchor_watch_alarm_summary = "Anchor watch: ANCHOR ALARM: 75.0 m from anchor; radius 50 m"
                self.anchor_watch_alarm_detail = "Anchor 61.000000, -149.000000 | Current 61.000000, -148.990000"
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.busy_calls = []
                self.refresh_scheduled = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

        app = FakeApp()

        status_gui_module.StatusApp._show_mark(app, Path("/tmp/mark.gpx"), ["61.0, -149.0"])

        self.assertEqual(app.headline.value, "NOT READY")
        self.assertEqual(app.summary.value, app.anchor_watch_alarm_summary)
        self.assertEqual(app.gps_summary.value, app.anchor_watch_alarm_detail)
        self.assertEqual(app.last_report.value, "61.0, -149.0")
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_anchor_check_does_not_hide_active_anchor_watch_alarm(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.anchor_watch_alarm_active = True
                self.anchor_watch_alarm_summary = "Anchor watch: ANCHOR ALARM: 75.0 m from anchor; radius 50 m"
                self.anchor_watch_alarm_detail = "Anchor 61.000000, -149.000000 | Current 61.000000, -148.990000"
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.busy_calls = []
                self.refresh_scheduled = 0
                self.bells = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

            def bell(self):
                self.bells += 1

        app = FakeApp()
        anchor_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            satellites=9,
            hdop=0.9,
        )
        current_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.00001,
            longitude=-149.00001,
            satellites=9,
            hdop=0.9,
        )

        status_gui_module.StatusApp._show_anchor(app, 2.0, 50.0, anchor_fix, current_fix)

        self.assertEqual(app.headline.value, "NOT READY")
        self.assertEqual(app.summary.value, app.anchor_watch_alarm_summary)
        self.assertEqual(app.gps_summary.value, app.anchor_watch_alarm_detail)
        self.assertIn("Current 61.000010", app.last_report.value)
        self.assertEqual(app.bells, 0)
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_anchor_check_ok_preserves_not_ready_readiness_headline(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.last_status_report_ready = False
                self.anchor_watch_alarm_active = False
                self.anchor_watch_alarm_summary = None
                self.anchor_watch_alarm_detail = None
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.busy_calls = []
                self.refresh_scheduled = 0
                self.bells = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

            def bell(self):
                self.bells += 1

        app = FakeApp()
        anchor_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            satellites=9,
            hdop=0.9,
        )
        current_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.00001,
            longitude=-149.00001,
            satellites=9,
            hdop=0.9,
        )

        status_gui_module.StatusApp._show_anchor(app, 2.0, 50.0, anchor_fix, current_fix)

        self.assertEqual(app.headline.value, "NOT READY")
        self.assertEqual(app.summary.value, "Anchor OK: 2.0 m from anchor; radius 50 m")
        self.assertIn("Current 61.000010", app.gps_summary.value)
        self.assertEqual(app.bells, 0)
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_anchor_watch_set_preserves_not_ready_readiness_headline(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.last_status_report_ready = False
                self.anchor_radius = FakeVar()
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.busy_calls = []
                self.watch_scheduled = 0
                self.refresh_scheduled = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_anchor_watch(self):
                self.watch_scheduled += 1

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

        app = FakeApp()
        anchor_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            satellites=9,
            hdop=0.9,
        )

        status_gui_module.StatusApp._show_anchor_watch_set(app, anchor_fix, 50.0)

        self.assertEqual(app.headline.value, "NOT READY")
        self.assertEqual(app.anchor_watch_fix, anchor_fix)
        self.assertEqual(app.anchor_watch_status_summary, "Anchor watch armed; radius 50 m")
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.watch_scheduled, 1)
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_anchor_watch_ok_preserves_not_ready_readiness_headline(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self, anchor_fix):
                self.last_status_report_ready = False
                self.anchor_watch_fix = anchor_fix
                self.anchor_watch_alarm_active = False
                self.anchor_watch_alarm_summary = None
                self.anchor_watch_alarm_detail = None
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.busy_calls = []
                self.watch_scheduled = 0
                self.refresh_scheduled = 0
                self.bells = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_anchor_watch(self):
                self.watch_scheduled += 1

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def bell(self):
                self.bells += 1

        anchor_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            satellites=9,
            hdop=0.9,
        )
        current_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.00001,
            longitude=-149.00001,
            satellites=9,
            hdop=0.9,
        )
        app = FakeApp(anchor_fix)

        status_gui_module.StatusApp._show_anchor_watch(app, 2.0, 50.0, anchor_fix, current_fix)

        self.assertEqual(app.headline.value, "NOT READY")
        self.assertEqual(app.summary.value, "Anchor watch: Anchor OK: 2.0 m from anchor; radius 50 m")
        self.assertFalse(app.anchor_watch_alarm_active)
        self.assertIsNone(app.anchor_watch_alarm_summary)
        self.assertEqual(app.bells, 0)
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.watch_scheduled, 1)
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_error_does_not_hide_active_anchor_watch_alarm(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.anchor_watch_alarm_active = True
                self.anchor_watch_alarm_summary = "Anchor watch: ANCHOR ALARM: 75.0 m from anchor; radius 50 m"
                self.anchor_watch_alarm_detail = "Anchor 61.000000, -149.000000 | Current 61.000000, -148.990000"
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.busy_calls = []
                self.watch_scheduled = 0
                self.refresh_scheduled = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_anchor_watch(self):
                self.watch_scheduled += 1

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

        app = FakeApp()

        status_gui_module.StatusApp._show_error(app, "temporary GPS read failed")

        self.assertEqual(app.headline.value, "NOT READY")
        self.assertEqual(app.summary.value, app.anchor_watch_alarm_summary)
        self.assertEqual(app.gps_summary.value, app.anchor_watch_alarm_detail)
        self.assertEqual(app.last_report.value, "Error: temporary GPS read failed")
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.watch_scheduled, 1)
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_stale_anchor_watch_result_does_not_restart_stopped_watch(self):
        class FakeVar:
            def __init__(self, value=None):
                self.value = value

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.anchor_watch_fix = None
                self.headline = FakeVar("READY")
                self.summary = FakeVar("Anchor watch stopped.")
                self.gps_summary = FakeVar("GPS unchanged")
                self.last_report = FakeVar("")
                self.busy_calls = []
                self.watch_scheduled = 0
                self.refresh_scheduled = 0
                self.bells = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_anchor_watch(self):
                self.watch_scheduled += 1

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def bell(self):
                self.bells += 1

        app = FakeApp()
        stopped_anchor_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            satellites=9,
            hdop=0.9,
        )
        current_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-148.99,
            satellites=9,
            hdop=0.9,
        )

        status_gui_module.StatusApp._show_anchor_watch(app, 700.0, 50.0, stopped_anchor_fix, current_fix)

        self.assertIsNone(app.anchor_watch_fix)
        self.assertEqual(app.headline.value, "READY")
        self.assertEqual(app.summary.value, "Anchor watch stopped.")
        self.assertEqual(app.gps_summary.value, "GPS unchanged")
        self.assertEqual(app.last_report.value, "Ignored stale anchor watch result; watch was stopped or reset.")
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.watch_scheduled, 0)
        self.assertEqual(app.refresh_scheduled, 1)
        self.assertEqual(app.bells, 0)

    def test_status_gui_stale_anchor_watch_error_does_not_replace_stopped_watch_status(self):
        class FakeVar:
            def __init__(self, value=None):
                self.value = value

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.anchor_watch_fix = None
                self.headline = FakeVar("READY")
                self.summary = FakeVar("Anchor watch stopped.")
                self.gps_summary = FakeVar("GPS unchanged")
                self.last_report = FakeVar("")
                self.busy_calls = []
                self.watch_scheduled = 0
                self.refresh_scheduled = 0

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _schedule_anchor_watch(self):
                self.watch_scheduled += 1

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

            def _show_error(self, message):
                raise AssertionError(f"stale anchor watch error should not be shown: {message}")

        app = FakeApp()
        stopped_anchor_fix = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            satellites=9,
            hdop=0.9,
        )

        status_gui_module.StatusApp._show_anchor_watch_error(app, stopped_anchor_fix, "GPSD timed out")

        self.assertIsNone(app.anchor_watch_fix)
        self.assertEqual(app.headline.value, "READY")
        self.assertEqual(app.summary.value, "Anchor watch stopped.")
        self.assertEqual(app.gps_summary.value, "GPS unchanged")
        self.assertEqual(app.last_report.value, "Ignored stale anchor watch error; watch was stopped or reset.")
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.watch_scheduled, 0)
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_start_watch_does_not_reset_active_watch(self):
        class FakeVar:
            def __init__(self, value=None):
                self.value = value

            def get(self):
                return self.value

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.anchor_watch_fix = GPSFix(
                    timestamp=datetime.now(timezone.utc),
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                )
                self.anchor_watch_alarm_active = False
                self.anchor_watch_alarm_summary = None
                self.anchor_watch_alarm_detail = None
                self.anchor_watch_status_summary = "Anchor watch: Anchor OK: 3.0 m from anchor; radius 50 m"
                self.anchor_watch_status_detail = "Anchor 61.000000, -149.000000 | Current 61.000010, -149.000010"
                self.anchor_radius = FakeVar("bad radius")
                self.anchor_samples = FakeVar("bad samples")
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.worker = None
                self.busy_calls = []

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

            def _show_anchor_watch_already_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_already_active(self)

            def _show_error(self, message):
                raise AssertionError(f"active watch should not parse new settings: {message}")

        app = FakeApp()

        status_gui_module.StatusApp.start_anchor_watch(app)

        self.assertIsNotNone(app.anchor_watch_fix)
        self.assertEqual(app.busy_calls, [False])
        self.assertEqual(app.summary.value, app.anchor_watch_status_summary)
        self.assertEqual(app.gps_summary.value, app.anchor_watch_status_detail)
        self.assertEqual(app.last_report.value, "Anchor watch is already active; stop it before starting a new watch.")
        self.assertIsNone(app.worker)

    def test_status_gui_disables_start_watch_while_anchor_watch_is_active(self):
        class FakeButton:
            def __init__(self):
                self.state = None

            def configure(self, *, state):
                self.state = state

        class FakeApp:
            def __init__(self):
                self.refresh_button = FakeButton()
                self.mark_button = FakeButton()
                self.mob_button = FakeButton()
                self.anchor_button = FakeButton()
                self.anchor_watch_button = FakeButton()
                self.stop_anchor_watch_button = FakeButton()
                self.anchor_radius_entry = FakeButton()
                self.anchor_samples_entry = FakeButton()
                self.anchor_watch_fix = GPSFix(
                    timestamp=datetime.now(timezone.utc),
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                )
                self.anchor_watch_radius_meters = 50.0

        app = FakeApp()

        status_gui_module.StatusApp._set_busy(app, False)

        self.assertEqual(app.anchor_watch_button.state, status_gui_module.tk.DISABLED)
        self.assertEqual(app.stop_anchor_watch_button.state, status_gui_module.tk.NORMAL)
        self.assertEqual(app.anchor_radius_entry.state, status_gui_module.tk.DISABLED)
        self.assertEqual(app.anchor_samples_entry.state, status_gui_module.tk.DISABLED)

    def test_status_gui_stop_watch_stays_available_while_anchor_watch_check_is_busy(self):
        class FakeButton:
            def __init__(self):
                self.state = None

            def configure(self, *, state):
                self.state = state

        class FakeApp:
            def __init__(self):
                self.refresh_button = FakeButton()
                self.mark_button = FakeButton()
                self.mob_button = FakeButton()
                self.anchor_button = FakeButton()
                self.anchor_watch_button = FakeButton()
                self.stop_anchor_watch_button = FakeButton()
                self.anchor_radius_entry = FakeButton()
                self.anchor_samples_entry = FakeButton()
                self.anchor_watch_fix = GPSFix(
                    timestamp=datetime.now(timezone.utc),
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                )

        app = FakeApp()

        status_gui_module.StatusApp._set_busy(app, True)

        self.assertEqual(app.refresh_button.state, status_gui_module.tk.DISABLED)
        self.assertEqual(app.mark_button.state, status_gui_module.tk.DISABLED)
        self.assertEqual(app.mob_button.state, status_gui_module.tk.DISABLED)
        self.assertEqual(app.anchor_button.state, status_gui_module.tk.DISABLED)
        self.assertEqual(app.anchor_watch_button.state, status_gui_module.tk.DISABLED)
        self.assertEqual(app.stop_anchor_watch_button.state, status_gui_module.tk.NORMAL)
        self.assertEqual(app.anchor_radius_entry.state, status_gui_module.tk.DISABLED)
        self.assertEqual(app.anchor_samples_entry.state, status_gui_module.tk.DISABLED)

    def test_status_gui_close_cancels_scheduled_callbacks(self):
        class FakeApp:
            def __init__(self):
                self._closed = False
                self.after_id = "refresh-after"
                self.poll_after_id = "poll-after"
                self.anchor_watch_after_id = "watch-after"
                self.anchor_watch_stop_confirm_after_id = "confirm-after"
                self.cancelled = []
                self.destroyed = False

            def after_cancel(self, after_id):
                self.cancelled.append(after_id)

            def destroy(self):
                self.destroyed = True

            def _cancel_after_callback(self, attr):
                return status_gui_module.StatusApp._cancel_after_callback(self, attr)

        app = FakeApp()

        status_gui_module.StatusApp.close(app)

        self.assertTrue(app._closed)
        self.assertEqual(
            app.cancelled,
            ["refresh-after", "poll-after", "watch-after", "confirm-after"],
        )
        self.assertIsNone(app.after_id)
        self.assertIsNone(app.poll_after_id)
        self.assertIsNone(app.anchor_watch_after_id)
        self.assertIsNone(app.anchor_watch_stop_confirm_after_id)
        self.assertTrue(app.destroyed)

    def test_status_gui_does_not_schedule_callbacks_after_close(self):
        class FakeApp:
            def __init__(self):
                self._closed = True
                self.after_id = "refresh-after"
                self.anchor_watch_after_id = "watch-after"
                self.refresh_seconds = 60.0
                self.anchor_watch_fix = GPSFix(
                    timestamp=datetime.now(timezone.utc),
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                )
                self.anchor_watch_seconds = 30.0
                self.cancelled = []

            def after_cancel(self, after_id):
                self.cancelled.append(after_id)

            def after(self, delay_ms, callback):
                raise AssertionError("closed status GUI should not schedule callbacks")

        app = FakeApp()

        status_gui_module.StatusApp._schedule_refresh(app)
        status_gui_module.StatusApp._schedule_anchor_watch(app)

        self.assertEqual(app.cancelled, [])
        self.assertEqual(app.after_id, "refresh-after")
        self.assertEqual(app.anchor_watch_after_id, "watch-after")

    def test_status_gui_refresh_cancels_pending_refresh_callback_before_starting_worker(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeThread:
            def __init__(self, *, target, daemon):
                self.target = target
                self.daemon = daemon
                self.started = False

            def start(self):
                self.started = True

        class FakeApp:
            def __init__(self):
                self._closed = False
                self.after_id = "refresh-after"
                self.worker = None
                self.summary = FakeVar()
                self.cancelled = []
                self.busy_calls = []
                self.started_threads = []

            def after_cancel(self, after_id):
                self.cancelled.append(after_id)

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _refresh_worker(self):
                return None

        app = FakeApp()
        original_thread = status_gui_module.Thread

        def fake_thread(*, target, daemon):
            thread = FakeThread(target=target, daemon=daemon)
            app.started_threads.append(thread)
            return thread

        try:
            status_gui_module.Thread = fake_thread
            status_gui_module.StatusApp.refresh_now(app)
        finally:
            status_gui_module.Thread = original_thread

        self.assertEqual(app.cancelled, ["refresh-after"])
        self.assertIsNone(app.after_id)
        self.assertEqual(app.busy_calls, [True])
        self.assertEqual(app.summary.value, "Refreshing status...")
        self.assertEqual(len(app.started_threads), 1)
        self.assertTrue(app.started_threads[0].started)

    def test_status_gui_refresh_waits_for_unprocessed_worker_result(self):
        class FakeVar:
            def __init__(self, value):
                self.value = value

            def set(self, value):
                self.value = value

        class FinishedWorker:
            def is_alive(self):
                return False

        class FakeApp:
            def __init__(self):
                self._closed = False
                self.after_id = None
                self.worker = FinishedWorker()
                self.summary = FakeVar("old summary")

            def _set_busy(self, busy):
                raise AssertionError("refresh should wait until queued worker result is processed")

            def _refresh_worker(self):
                raise AssertionError("refresh should not start a new worker")

        app = FakeApp()

        status_gui_module.StatusApp.refresh_now(app)

        self.assertIsInstance(app.worker, FinishedWorker)
        self.assertEqual(app.summary.value, "old summary")

    def test_status_gui_poll_queue_clears_worker_before_dispatching_result(self):
        class FinishedWorker:
            def is_alive(self):
                return False

        class FakeApp:
            def __init__(self):
                self._closed = False
                self.poll_after_id = "poll-after"
                self.queue = status_gui_module.Queue()
                self.queue.put(("error", "GPSD timed out"))
                self.worker = FinishedWorker()
                self.errors = []
                self.after_calls = []

            def _show_error(self, message):
                self.errors.append((message, self.worker))

            def after(self, delay_ms, callback):
                self.after_calls.append((delay_ms, callback.__name__))
                return "next-poll-after"

            def _poll_queue(self):
                return status_gui_module.StatusApp._poll_queue(self)

        app = FakeApp()

        status_gui_module.StatusApp._poll_queue(app)

        self.assertIsNone(app.worker)
        self.assertEqual(app.errors, [("GPSD timed out", None)])
        self.assertEqual(app.poll_after_id, "next-poll-after")
        self.assertEqual(app.after_calls, [(150, "_poll_queue")])

    def test_status_gui_anchor_watch_worker_queues_completion_when_watch_stopped_before_read(self):
        class FakeApp:
            def __init__(self):
                self.anchor_watch_fix = None
                self.queue = status_gui_module.Queue()

        app = FakeApp()

        status_gui_module.StatusApp._anchor_watch_worker(app, radius_meters=50.0)

        self.assertEqual(app.queue.get_nowait(), ("worker_done", None))

    def test_status_gui_poll_queue_clears_worker_for_noop_completion(self):
        class FinishedWorker:
            def is_alive(self):
                return False

        class FakeApp:
            def __init__(self):
                self._closed = False
                self.poll_after_id = "poll-after"
                self.queue = status_gui_module.Queue()
                self.queue.put(("worker_done", None))
                self.worker = FinishedWorker()
                self.after_calls = []

            def after(self, delay_ms, callback):
                self.after_calls.append((delay_ms, callback.__name__))
                return "next-poll-after"

            def _poll_queue(self):
                return status_gui_module.StatusApp._poll_queue(self)

        app = FakeApp()

        status_gui_module.StatusApp._poll_queue(app)

        self.assertIsNone(app.worker)
        self.assertEqual(app.poll_after_id, "next-poll-after")
        self.assertEqual(app.after_calls, [(150, "_poll_queue")])

    def test_status_gui_stop_watch_requires_second_press(self):
        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.anchor_watch_fix = GPSFix(
                    timestamp=datetime.now(timezone.utc),
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                )
                self.anchor_watch_after_id = "watch-after-id"
                self.anchor_watch_stop_confirm_after_id = None
                self.anchor_watch_alarm_active = True
                self.anchor_watch_alarm_summary = "Anchor watch: ANCHOR ALARM: 75.0 m from anchor; radius 50 m"
                self.anchor_watch_alarm_detail = "Anchor 61.000000, -149.000000 | Current 61.000000, -148.990000"
                self.headline = FakeVar()
                self.summary = FakeVar()
                self.gps_summary = FakeVar()
                self.last_report = FakeVar()
                self.after_calls = []
                self.cancelled = []

            def after(self, delay_ms, callback):
                self.after_calls.append((delay_ms, callback.__name__))
                return "confirm-after-id"

            def after_cancel(self, after_id):
                self.cancelled.append(after_id)

            def _show_anchor_watch_alarm_if_active(self):
                return status_gui_module.StatusApp._show_anchor_watch_alarm_if_active(self)

            def _show_anchor_watch_stop_confirmation(self):
                return status_gui_module.StatusApp._show_anchor_watch_stop_confirmation(self)

            def _expire_anchor_watch_stop_confirmation(self):
                return status_gui_module.StatusApp._expire_anchor_watch_stop_confirmation(self)

            def _cancel_anchor_watch_stop_confirmation(self):
                return status_gui_module.StatusApp._cancel_anchor_watch_stop_confirmation(self)

        app = FakeApp()

        status_gui_module.StatusApp.stop_anchor_watch(app)

        self.assertIsNotNone(app.anchor_watch_fix)
        self.assertEqual(app.anchor_watch_stop_confirm_after_id, "confirm-after-id")
        self.assertEqual(
            app.after_calls,
            [(int(status_gui_module.ANCHOR_WATCH_STOP_CONFIRM_SECONDS * 1000), "_expire_anchor_watch_stop_confirmation")],
        )
        self.assertEqual(app.cancelled, [])
        self.assertEqual(app.headline.value, "NOT READY")
        self.assertEqual(app.summary.value, app.anchor_watch_alarm_summary)
        self.assertEqual(app.gps_summary.value, app.anchor_watch_alarm_detail)
        self.assertIn("Press Stop Watch again", app.last_report.value)

    def test_status_gui_enables_start_watch_after_anchor_watch_stops(self):
        class FakeButton:
            def __init__(self):
                self.state = None

            def configure(self, *, state):
                self.state = state

        class FakeVar:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        class FakeApp:
            def __init__(self):
                self.refresh_button = FakeButton()
                self.mark_button = FakeButton()
                self.mob_button = FakeButton()
                self.anchor_button = FakeButton()
                self.anchor_watch_button = FakeButton()
                self.stop_anchor_watch_button = FakeButton()
                self.anchor_radius_entry = FakeButton()
                self.anchor_samples_entry = FakeButton()
                self.anchor_watch_fix = GPSFix(
                    timestamp=datetime.now(timezone.utc),
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                )
                self.anchor_watch_alarm_active = True
                self.anchor_watch_alarm_summary = "alarm"
                self.anchor_watch_alarm_detail = "detail"
                self.anchor_watch_status_summary = "status"
                self.anchor_watch_status_detail = "detail"
                self.anchor_watch_after_id = "after-id"
                self.anchor_watch_stop_confirm_after_id = "confirm-id"
                self.anchor_watch_radius_meters = 50.0
                self.summary = FakeVar()
                self.cancelled = []
                self.refresh_scheduled = 0

            def after_cancel(self, after_id):
                self.cancelled.append(after_id)

            def _cancel_anchor_watch_stop_confirmation(self):
                return status_gui_module.StatusApp._cancel_anchor_watch_stop_confirmation(self)

            def _set_busy(self, busy):
                status_gui_module.StatusApp._set_busy(self, busy)

            def _schedule_refresh(self):
                self.refresh_scheduled += 1

        app = FakeApp()

        status_gui_module.StatusApp.stop_anchor_watch(app)

        self.assertIsNone(app.anchor_watch_fix)
        self.assertIsNone(app.anchor_watch_radius_meters)
        self.assertFalse(app.anchor_watch_alarm_active)
        self.assertIsNone(app.anchor_watch_status_summary)
        self.assertIsNone(app.anchor_watch_status_detail)
        self.assertEqual(app.anchor_watch_button.state, status_gui_module.tk.NORMAL)
        self.assertEqual(app.stop_anchor_watch_button.state, status_gui_module.tk.DISABLED)
        self.assertIsNone(app.anchor_watch_stop_confirm_after_id)
        self.assertEqual(app.cancelled, ["confirm-id", "after-id"])
        self.assertEqual(app.refresh_scheduled, 1)

    def test_status_gui_anchor_watch_uses_stored_radius_after_field_edit(self):
        class FakeVar:
            def __init__(self, value):
                self.value = value

            def get(self):
                return self.value

            def set(self, value):
                self.value = value

        class FakeThread:
            def __init__(self, *, target, kwargs, daemon):
                self.target = target
                self.kwargs = kwargs
                self.daemon = daemon

            def start(self):
                return None

        class FakeApp:
            def __init__(self):
                self.anchor_watch_fix = GPSFix(
                    timestamp=datetime.now(timezone.utc),
                    latitude=61.0,
                    longitude=-149.0,
                    satellites=9,
                    hdop=0.9,
                )
                self.anchor_watch_radius_meters = 75.0
                self.anchor_watch_after_id = "after-id"
                self.anchor_radius = FakeVar("5")
                self.summary = FakeVar("")
                self.worker = None
                self.busy_calls = []
                self.watch_scheduled = 0
                self.started_threads = []

            def _set_busy(self, busy):
                self.busy_calls.append(busy)

            def _anchor_watch_worker(self, *, radius_meters):
                return None

        app = FakeApp()
        original_thread = status_gui_module.Thread

        def fake_thread(*, target, kwargs, daemon):
            thread = FakeThread(target=target, kwargs=kwargs, daemon=daemon)
            app.started_threads.append(thread)
            return thread

        try:
            status_gui_module.Thread = fake_thread
            status_gui_module.StatusApp._run_anchor_watch(app)
        finally:
            status_gui_module.Thread = original_thread

        self.assertIsNone(app.anchor_watch_after_id)
        self.assertEqual(app.busy_calls, [True])
        self.assertEqual(app.summary.value, "Checking anchor watch...")
        self.assertEqual(len(app.started_threads), 1)
        self.assertEqual(app.started_threads[0].kwargs, {"radius_meters": 75.0})

    def test_status_gui_anchor_check_rejects_stale_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            stale_anchor_fix = GPSFix(
                timestamp=datetime.now(timezone.utc) - timedelta(seconds=600),
                latitude=61.0,
                longitude=-149.0,
                satellites=9,
                hdop=0.9,
            )
            current_fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.0,
                longitude=-148.99,
                satellites=9,
                hdop=0.9,
            )
            original = status_gui_module.read_configured_gps_fixes

            try:
                status_gui_module.read_configured_gps_fixes = (
                    lambda app_config, **kwargs: [stale_anchor_fix, current_fix]
                )
                with self.assertRaisesRegex(ValueError, "anchor check requires fresh GPS fix 1"):
                    status_gui_module.check_anchor_drift(config_path)
            finally:
                status_gui_module.read_configured_gps_fixes = original

    def test_status_gui_anchor_check_rejects_future_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            anchor_fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.0,
                longitude=-149.0,
                satellites=9,
                hdop=0.9,
            )
            future_current_fix = GPSFix(
                timestamp=datetime.now(timezone.utc) + timedelta(seconds=1),
                latitude=61.0,
                longitude=-148.99,
                satellites=9,
                hdop=0.9,
            )
            original = status_gui_module.read_configured_gps_fixes

            try:
                status_gui_module.read_configured_gps_fixes = (
                    lambda app_config, **kwargs: [anchor_fix, future_current_fix]
                )
                with self.assertRaisesRegex(ValueError, "anchor check requires fresh GPS fix 2.*future"):
                    status_gui_module.check_anchor_drift(config_path)
            finally:
                status_gui_module.read_configured_gps_fixes = original

    def test_status_gui_anchor_check_rejects_timezone_less_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            timezone_less_anchor_fix = GPSFix(
                timestamp=datetime(2026, 6, 30, 12, 0, 0),
                latitude=61.0,
                longitude=-149.0,
                satellites=9,
                hdop=0.9,
            )
            current_fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=61.0,
                longitude=-148.99,
                satellites=9,
                hdop=0.9,
            )
            original = status_gui_module.read_configured_gps_fixes

            try:
                status_gui_module.read_configured_gps_fixes = (
                    lambda app_config, **kwargs: [timezone_less_anchor_fix, current_fix]
                )
                with self.assertRaisesRegex(ValueError, "fix timestamp has no timezone"):
                    status_gui_module.check_anchor_drift(config_path)
            finally:
                status_gui_module.read_configured_gps_fixes = original

    def test_status_gui_anchor_check_averages_anchor_samples(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=3)
            fixes = [
                GPSFix(timestamp=now, latitude=61.0, longitude=-149.0, satellites=9, hdop=0.8),
                GPSFix(
                    timestamp=now + timedelta(seconds=1),
                    latitude=61.00002,
                    longitude=-149.00002,
                    satellites=8,
                    hdop=1.1,
                ),
                GPSFix(
                    timestamp=now + timedelta(seconds=2),
                    latitude=61.00001,
                    longitude=-149.00001,
                    satellites=10,
                    hdop=0.9,
                ),
            ]
            calls = []
            original = status_gui_module.read_configured_gps_fixes

            def fake_read_configured_gps_fixes(app_config, *, count, gps_seconds=10.0, **kwargs):
                calls.append((app_config.gps_mode, count, gps_seconds, kwargs))
                return fixes

            try:
                status_gui_module.read_configured_gps_fixes = fake_read_configured_gps_fixes
                distance, radius, anchor_fix, current_fix = status_gui_module.check_anchor_drift(
                    config_path,
                    gps_seconds=12.0,
                    radius_meters=50.0,
                    anchor_samples=2,
                )
            finally:
                status_gui_module.read_configured_gps_fixes = original

            self.assertEqual(calls, [("gpsd", 3, 12.0, {})])
            self.assertEqual(radius, 50.0)
            self.assertAlmostEqual(anchor_fix.latitude, 61.00001)
            self.assertAlmostEqual(anchor_fix.longitude, -149.00001)
            self.assertEqual(anchor_fix.satellites, 8)
            self.assertEqual(anchor_fix.hdop, 1.1)
            self.assertIs(current_fix, fixes[-1])
            self.assertAlmostEqual(distance, 0.0, places=3)

    def test_status_gui_anchor_check_averages_longitude_across_date_line(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config_path = root / "config.ini"
            config_path.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            now = datetime.now(timezone.utc) - timedelta(seconds=3)
            fixes = [
                GPSFix(timestamp=now, latitude=0.0, longitude=179.9, satellites=9, hdop=0.8),
                GPSFix(timestamp=now + timedelta(seconds=1), latitude=0.0, longitude=-179.9, satellites=8, hdop=1.1),
                GPSFix(timestamp=now + timedelta(seconds=2), latitude=0.0, longitude=179.95, satellites=10, hdop=0.9),
            ]
            original = status_gui_module.read_configured_gps_fixes

            try:
                status_gui_module.read_configured_gps_fixes = lambda app_config, **kwargs: fixes
                distance, radius, anchor_fix, current_fix = status_gui_module.check_anchor_drift(
                    config_path,
                    gps_seconds=12.0,
                    radius_meters=10000.0,
                    anchor_samples=2,
                )
            finally:
                status_gui_module.read_configured_gps_fixes = original

            self.assertEqual(radius, 10000.0)
            self.assertAlmostEqual(abs(anchor_fix.longitude), 180.0)
            self.assertNotAlmostEqual(anchor_fix.longitude, 0.0)
            self.assertIs(current_fix, fixes[-1])
            self.assertLess(distance, radius)

    def test_status_gui_formats_anchor_fix_quality_detail(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 34, 56, tzinfo=timezone.utc),
            latitude=61.2181,
            longitude=-149.9003,
            satellites=8,
            hdop=1.1,
        )

        self.assertEqual(
            status_gui_module._format_anchor_fix_detail(fix),
            "61.218100, -149.900300; 2026-06-30T12:34:56Z; 8 sats; HDOP 1.1",
        )

    def test_status_gui_reads_configured_anchor_radius(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            config_path = Path(tmpdir) / "config.ini"
            config_path.write_text("[anchor]\nradius_meters = 82.5\n", encoding="utf-8")

            self.assertEqual(status_gui_module._configured_anchor_radius(config_path), 82.5)

    def test_gui_download_rejects_low_disk_before_download(self):
        package = package_for(state="AK")
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "charts" / "noaa"
            calls = []
            original_download = gui_module.download_package
            original_disk_check = gui_module.check_disk_space

            def fake_download_package(*args, **kwargs):
                calls.append((args, kwargs))
                raise AssertionError("download_package should not be called")

            try:
                gui_module.download_package = fake_download_package
                gui_module.check_disk_space = lambda *args, **kwargs: health_module.CheckResult(
                    "Disk",
                    False,
                    "0.1 GB free at /charts; minimum 2.0 GB",
                )

                with self.assertRaisesRegex(RuntimeError, "enough free space"):
                    gui_module.download_selected_package(
                        package,
                        output,
                        extract=True,
                        keep_zip=True,
                        force=True,
                    )
            finally:
                gui_module.download_package = original_download
                gui_module.check_disk_space = original_disk_check

            self.assertEqual(calls, [])

    def test_gui_download_rejects_missing_storage_before_creating_directory(self):
        package = package_for(state="AK")
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / "missing-storage" / "charts"
            calls = []
            original_download = gui_module.download_package

            def fake_download_package(*args, **kwargs):
                calls.append((args, kwargs))
                raise AssertionError("download_package should not be called")

            try:
                gui_module.download_package = fake_download_package

                with self.assertRaisesRegex(RuntimeError, "create or mount the configured storage path"):
                    gui_module.download_selected_package(
                        package,
                        output,
                        extract=True,
                        keep_zip=True,
                        force=True,
                    )
            finally:
                gui_module.download_package = original_download

            self.assertFalse(output.exists())
            self.assertEqual(calls, [])

    def test_configured_preflight_uses_onboard_config_values(self):
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="gpsd",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="192.0.2.10",
            gpsd_port=2948,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        calls = []
        original = gui_module.run_preflight

        def fake_run_preflight(**kwargs):
            calls.append(kwargs)
            return [health_module.CheckResult("Test", True, "ok")]

        try:
            gui_module.run_preflight = fake_run_preflight
            results = gui_module.run_configured_preflight(app_config)
        finally:
            gui_module.run_preflight = original

        self.assertEqual(results, [health_module.CheckResult("Test", True, "ok")])
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["chart_dir"], Path("/charts/noaa"))
        self.assertEqual(calls[0]["chart_package"], "state")
        self.assertEqual(calls[0]["chart_value"], "AK")
        self.assertEqual(calls[0]["gpsd"], True)
        self.assertEqual(calls[0]["gpsd_host"], "192.0.2.10")
        self.assertEqual(calls[0]["gpsd_port"], 2948)
        self.assertEqual(calls[0]["gps_device"], "/dev/serial/by-id/mock-gps")
        self.assertEqual(calls[0]["gps_baud"], 9600)
        self.assertEqual(calls[0]["gps_seconds"], 10.0)
        self.assertEqual(calls[0]["max_chart_age_days"], 12)
        self.assertEqual(calls[0]["min_free_gb"], 4.5)
        self.assertEqual(calls[0]["keep_zip"], True)
        self.assertEqual(calls[0]["track_output"], Path("/tracks/noaa"))

    def test_gui_gps_fix_reads_configured_gpsd_and_formats_position(self):
        timestamp = datetime.now(timezone.utc)
        timestamp_text = timestamp.isoformat().replace("+00:00", "Z")
        fix = GPSFix(
            timestamp=timestamp,
            latitude=61.2181,
            longitude=-149.9003,
            speed_knots=4.2,
            course_degrees=181.5,
            fix_quality=3,
            satellites=9,
            hdop=0.9,
        )
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="gpsd",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        calls = []
        original = gui_module.iter_gpsd_fixes

        def fake_iter_gpsd_fixes(**kwargs):
            calls.append(kwargs)
            return iter([fix])

        try:
            gui_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            result = gui_module.read_configured_gps_fix(app_config, gps_seconds=7.0)
        finally:
            gui_module.iter_gpsd_fixes = original

        self.assertIs(result, fix)
        self.assertEqual(calls[0]["host"], "127.0.0.1")
        self.assertEqual(calls[0]["port"], 2947)
        self.assertEqual(calls[0]["max_duration"], 7.0)
        lines = gui_module.format_gps_fix(result)
        self.assertIn("GPS fix: 61.218100, -149.900300", lines)
        self.assertIn(f"GPS time: {timestamp_text}", lines)
        self.assertIn("Satellites: 9", lines)
        self.assertIn("HDOP: 0.9", lines)
        self.assertIn("Speed: 4.2 kt", lines)
        self.assertIn("Course: 181.5 deg", lines)

    def test_gui_gps_fix_skips_stale_before_fresh_fix(self):
        stale = GPSFix(
            timestamp=datetime.now(timezone.utc) - timedelta(seconds=600),
            latitude=61.2181,
            longitude=-149.9003,
            satellites=9,
            hdop=0.9,
        )
        fresh = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.2182,
            longitude=-149.9004,
            satellites=9,
            hdop=0.9,
        )
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="gpsd",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        original = gui_module.iter_gpsd_fixes

        try:
            gui_module.iter_gpsd_fixes = lambda **kwargs: iter([stale, fresh])
            self.assertIs(gui_module.read_configured_gps_fix(app_config), fresh)
        finally:
            gui_module.iter_gpsd_fixes = original

    def test_gui_gps_fix_rejects_stale_timestamped_fix(self):
        fix = GPSFix(
            timestamp=datetime.now(timezone.utc) - timedelta(seconds=600),
            latitude=61.2181,
            longitude=-149.9003,
            satellites=9,
            hdop=0.9,
        )
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="gpsd",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        original = gui_module.iter_gpsd_fixes

        try:
            gui_module.iter_gpsd_fixes = lambda **kwargs: iter([fix])
            with self.assertRaisesRegex(RuntimeError, "stale"):
                gui_module.read_configured_gps_fix(app_config)
        finally:
            gui_module.iter_gpsd_fixes = original

    def test_gui_gps_fix_rejects_future_timestamped_fix(self):
        fix = GPSFix(
            timestamp=datetime.now(timezone.utc) + timedelta(seconds=1),
            latitude=61.2181,
            longitude=-149.9003,
            satellites=9,
            hdop=0.9,
        )
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="gpsd",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        original = gui_module.iter_gpsd_fixes

        try:
            gui_module.iter_gpsd_fixes = lambda **kwargs: iter([fix])
            with self.assertRaisesRegex(RuntimeError, "future"):
                gui_module.read_configured_gps_fix(app_config)
        finally:
            gui_module.iter_gpsd_fixes = original

    def test_gui_gps_fix_rejects_untimestamped_fix(self):
        fix = GPSFix(
            latitude=61.2181,
            longitude=-149.9003,
            satellites=9,
            hdop=0.9,
        )
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="gpsd",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        original = gui_module.iter_gpsd_fixes

        try:
            gui_module.iter_gpsd_fixes = lambda **kwargs: iter([fix])
            with self.assertRaisesRegex(RuntimeError, "no timestamp"):
                gui_module.read_configured_gps_fix(app_config)
        finally:
            gui_module.iter_gpsd_fixes = original

    def test_gui_gps_fix_rejects_volatile_serial_override(self):
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="serial",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        original = gui_module.open_nmea_stream

        def fake_open_nmea_stream(*args, **kwargs):
            raise AssertionError("open_nmea_stream should not be called")

        try:
            gui_module.open_nmea_stream = fake_open_nmea_stream
            with self.assertRaisesRegex(ValueError, "volatile"):
                gui_module.read_configured_gps_fix(
                    app_config,
                    gpsd_enabled=False,
                    gps_device="/dev/ttyUSB0",
                )
        finally:
            gui_module.open_nmea_stream = original

    def test_gui_gps_fix_rejects_broken_by_id_serial_before_opening(self):
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="serial",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        original = gui_module.open_nmea_stream

        def fake_open_nmea_stream(*args, **kwargs):
            raise AssertionError("open_nmea_stream should not be called")

        try:
            gui_module.open_nmea_stream = fake_open_nmea_stream
            with (
                patch("noaa_navionics.gui.Path.exists", return_value=False),
                patch("noaa_navionics.gui.Path.is_symlink", return_value=True),
                patch("noaa_navionics.gui.Path.resolve", return_value=Path("/dev/ttyACM0")),
            ):
                with self.assertRaisesRegex(ValueError, "broken by-id symlink"):
                    gui_module.read_configured_gps_fix(app_config, gpsd_enabled=False)
        finally:
            gui_module.open_nmea_stream = original

    def test_gui_gps_fix_rejects_by_id_serial_that_is_not_symlink(self):
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="serial",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        original = gui_module.open_nmea_stream

        def fake_open_nmea_stream(*args, **kwargs):
            raise AssertionError("open_nmea_stream should not be called")

        try:
            gui_module.open_nmea_stream = fake_open_nmea_stream
            with (
                patch("noaa_navionics.gui.Path.exists", return_value=True),
                patch("noaa_navionics.gui.Path.is_symlink", return_value=False),
            ):
                with self.assertRaisesRegex(ValueError, "udev by-id symlink"):
                    gui_module.read_configured_gps_fix(app_config, gpsd_enabled=False)
        finally:
            gui_module.open_nmea_stream = original

    def test_gui_gps_fix_rejects_by_id_serial_that_is_not_character_device(self):
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="serial",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        original = gui_module.open_nmea_stream

        def fake_open_nmea_stream(*args, **kwargs):
            raise AssertionError("open_nmea_stream should not be called")

        try:
            gui_module.open_nmea_stream = fake_open_nmea_stream
            with (
                patch("noaa_navionics.gui.Path.exists", return_value=True),
                patch("noaa_navionics.gui.Path.is_symlink", return_value=True),
                patch("noaa_navionics.gui.Path.is_char_device", return_value=False),
            ):
                with self.assertRaisesRegex(ValueError, "character device"):
                    gui_module.read_configured_gps_fix(app_config, gpsd_enabled=False)
        finally:
            gui_module.open_nmea_stream = original

    def test_gui_gps_fix_rejects_stable_alias_that_is_not_character_device(self):
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="serial",
            gps_device="/dev/gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        original = gui_module.open_nmea_stream

        def fake_open_nmea_stream(*args, **kwargs):
            raise AssertionError("open_nmea_stream should not be called")

        try:
            gui_module.open_nmea_stream = fake_open_nmea_stream
            with (
                patch("noaa_navionics.gui.Path.exists", return_value=True),
                patch("noaa_navionics.gui.Path.is_char_device", return_value=False),
            ):
                with self.assertRaisesRegex(ValueError, "character device"):
                    gui_module.read_configured_gps_fix(app_config, gpsd_enabled=False)
        finally:
            gui_module.open_nmea_stream = original

    def test_gui_gps_fix_rejects_fix_without_quality_fields(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 34, 56, tzinfo=timezone.utc),
            latitude=61.2181,
            longitude=-149.9003,
            fix_quality=3,
        )
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="gpsd",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="127.0.0.1",
            gpsd_port=2947,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
            anchor_radius_meters=75.0,
        )
        original = gui_module.iter_gpsd_fixes

        try:
            gui_module.iter_gpsd_fixes = lambda **kwargs: iter([fix])
            with self.assertRaisesRegex(RuntimeError, "without satellite or HDOP"):
                gui_module.read_configured_gps_fix(app_config)
        finally:
            gui_module.iter_gpsd_fixes = original

    def test_configured_gui_sync_rejects_incomplete_onboard_chart_packages(self):
        calls = []
        original = gui_module.download_package

        def fake_download_package(*args, **kwargs):
            calls.append((args, kwargs))
            raise AssertionError("download_package should not be called")

        try:
            gui_module.download_package = fake_download_package
            for package, value, expected in [
                ("updates", "ten-days", "not a complete chart set"),
                ("catalog", "", "metadata only"),
            ]:
                with self.subTest(package=package):
                    app_config = AppConfig(
                        chart_package=package,
                        chart_value=value,
                        chart_output=Path("/charts/noaa"),
                        extract=True,
                        keep_zip=True,
                        force=True,
                        max_chart_age_days=12,
                        min_free_gb=2.0,
                        gps_mode="gpsd",
                        gps_device="/dev/serial/by-id/mock-gps",
                        gps_baud=9600,
                        gpsd_host="127.0.0.1",
                        gpsd_port=2947,
                        track_output=Path("/tracks/noaa"),
                        track_retention_days=90,
                        anchor_radius_meters=50.0,
                    )

                    with self.assertRaisesRegex(ValueError, expected):
                        gui_module.sync_configured_charts(app_config)
        finally:
            gui_module.download_package = original

        self.assertEqual(calls, [])

    def test_configured_gui_sync_rejects_low_disk_before_download(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            app_config = AppConfig(
                chart_package="state",
                chart_value="AK",
                chart_output=Path(tmpdir) / "charts" / "noaa",
                extract=True,
                keep_zip=True,
                force=True,
                max_chart_age_days=12,
                min_free_gb=2.0,
                gps_mode="gpsd",
                gps_device="/dev/serial/by-id/mock-gps",
                gps_baud=9600,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                track_output=Path("/tracks/noaa"),
                track_retention_days=90,
                anchor_radius_meters=50.0,
            )
            calls = []
            original_download = gui_module.download_package
            original_disk_check = gui_module.check_disk_space

            def fake_download_package(*args, **kwargs):
                calls.append((args, kwargs))
                raise AssertionError("download_package should not be called")

            try:
                gui_module.download_package = fake_download_package
                gui_module.check_disk_space = lambda *args, **kwargs: health_module.CheckResult(
                    "Disk",
                    False,
                    "0.1 GB free at /charts; minimum 2.0 GB",
                )

                with self.assertRaisesRegex(RuntimeError, "enough free space"):
                    gui_module.sync_configured_charts(app_config)
            finally:
                gui_module.download_package = original_download
                gui_module.check_disk_space = original_disk_check

            self.assertEqual(calls, [])

    def test_configured_gui_sync_rejects_missing_storage_before_creating_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            chart_output = root / "missing-storage" / "charts"
            app_config = AppConfig(
                chart_package="state",
                chart_value="AK",
                chart_output=chart_output,
                extract=True,
                keep_zip=True,
                force=True,
                max_chart_age_days=12,
                min_free_gb=0.1,
                gps_mode="gpsd",
                gps_device="/dev/serial/by-id/mock-gps",
                gps_baud=9600,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                track_output=Path("/tracks/noaa"),
                track_retention_days=90,
                anchor_radius_meters=50.0,
            )
            calls = []
            original_download = gui_module.download_package

            def fake_download_package(*args, **kwargs):
                calls.append((args, kwargs))
                raise AssertionError("download_package should not be called")

            try:
                gui_module.download_package = fake_download_package

                with self.assertRaisesRegex(RuntimeError, "create or mount the configured storage path"):
                    gui_module.sync_configured_charts(app_config)
            finally:
                gui_module.download_package = original_download

            self.assertFalse(chart_output.exists())
            self.assertEqual(calls, [])


class CLIValidationTests(unittest.TestCase):
    def assert_parse_error(self, args):
        parser = cli_module.build_parser()
        with redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit) as raised:
                parser.parse_args(args)
        self.assertEqual(raised.exception.code, 2)

    def test_download_rejects_invalid_timing_values(self):
        self.assert_parse_error(["download", "--state", "AK", "--timeout", "0"])
        self.assert_parse_error(["download", "--state", "AK", "--timeout", "nan"])
        self.assert_parse_error(["download", "--state", "AK", "--retries", "0"])
        self.assert_parse_error(["download", "--state", "AK", "--retry-delay", "inf"])
        self.assert_parse_error(["download", "--state", "AK", "--retry-delay", "-1"])

    def test_sync_rejects_invalid_retry_values(self):
        self.assert_parse_error(["sync-charts", "--retries", "0"])
        self.assert_parse_error(["sync-charts", "--retry-delay", "-1"])

    def test_wait_network_rejects_invalid_values(self):
        self.assert_parse_error(["wait-network", "--host", ""])
        self.assert_parse_error(["wait-network", "--host", "bad host"])
        self.assert_parse_error(["wait-network", "--host", "bad;host"])
        self.assert_parse_error(["wait-network", "--host", "bad|host"])
        self.assert_parse_error(["wait-network", "--port", "0"])
        self.assert_parse_error(["wait-network", "--port", "65536"])
        self.assert_parse_error(["wait-network", "--seconds", "-1"])
        self.assert_parse_error(["wait-network", "--interval", "0"])
        self.assert_parse_error(["wait-network", "--timeout", "nan"])

    def test_wait_network_uses_immediate_probe_for_zero_second_budget(self):
        calls = []

        class FakeConnection:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, traceback):
                return False

        original = cli_module.socket.create_connection
        try:
            cli_module.socket.create_connection = lambda address, timeout: calls.append((address, timeout)) or FakeConnection()
            with redirect_stdout(StringIO()) as output:
                code = cli_module.main(
                    [
                        "wait-network",
                        "--host",
                        "example.invalid",
                        "--port",
                        "443",
                        "--seconds",
                        "0",
                        "--timeout",
                        "1",
                    ]
                )
        finally:
            cli_module.socket.create_connection = original

        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], ("example.invalid", 443))
        self.assertAlmostEqual(calls[0][1], 0.001)
        self.assertIn("Network reachable: example.invalid:443", output.getvalue())

    def test_wait_network_caps_tcp_probe_timeout_to_remaining_budget(self):
        calls = []

        class FakeConnection:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, traceback):
                return False

        original_connection = cli_module.socket.create_connection
        original_monotonic = cli_module.time.monotonic
        try:
            cli_module.socket.create_connection = lambda address, timeout: calls.append((address, timeout)) or FakeConnection()
            cli_module.time.monotonic = lambda: 100.0
            with redirect_stdout(StringIO()) as output:
                code = cli_module.main(
                    [
                        "wait-network",
                        "--host",
                        "example.invalid",
                        "--port",
                        "443",
                        "--seconds",
                        "2",
                        "--timeout",
                        "30",
                    ]
                )
        finally:
            cli_module.socket.create_connection = original_connection
            cli_module.time.monotonic = original_monotonic

        self.assertEqual(code, 0)
        self.assertEqual(calls, [(("example.invalid", 443), 2.0)])
        self.assertIn("Network reachable: example.invalid:443", output.getvalue())

    def test_sync_rejects_incomplete_onboard_chart_packages(self):
        cases = [
            ("updates", "ten-days"),
            ("catalog", ""),
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            for index, (package, value) in enumerate(cases):
                with self.subTest(package=package):
                    config = root / f"config-{index}.ini"
                    config.write_text(
                        "[charts]\n"
                        f"package = {package}\n"
                        f"value = {value}\n"
                        f"output = {root / 'charts'}\n",
                        encoding="utf-8",
                    )

                    stderr = StringIO()
                    with redirect_stderr(stderr):
                        code = cli_module.main(["sync-charts", "--config", str(config)])

                    self.assertEqual(code, 2)
                    self.assertIn("charts.package must be one of: state, cgd, region, chart, all", stderr.getvalue())

    def test_sync_rejects_low_disk_before_download(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config = root / "config.ini"
            config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {root / 'charts'}\n"
                "min_free_gb = 2.0\n",
                encoding="utf-8",
            )
            calls = []
            original_download = cli_module.download_package
            original_disk_check = cli_module.check_disk_space

            def fake_download_package(*args, **kwargs):
                calls.append((args, kwargs))
                raise AssertionError("download_package should not be called")

            try:
                cli_module.download_package = fake_download_package
                cli_module.check_disk_space = lambda *args, **kwargs: health_module.CheckResult(
                    "Disk",
                    False,
                    "0.1 GB free at chart storage; minimum 2.0 GB",
                )
                stderr = StringIO()
                with redirect_stderr(stderr):
                    code = cli_module.main(["sync-charts", "--config", str(config)])
            finally:
                cli_module.download_package = original_download
                cli_module.check_disk_space = original_disk_check

            self.assertEqual(code, 2)
            self.assertIn("enough free space", stderr.getvalue())
            self.assertEqual(calls, [])

    def test_sync_rejects_missing_chart_storage_before_creating_directory(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            chart_output = root / "missing-storage" / "charts"
            config = root / "config.ini"
            config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {chart_output}\n"
                "min_free_gb = 0.1\n",
                encoding="utf-8",
            )
            calls = []
            original_download = cli_module.download_package

            def fake_download_package(*args, **kwargs):
                calls.append((args, kwargs))
                raise AssertionError("download_package should not be called")

            try:
                cli_module.download_package = fake_download_package
                stderr = StringIO()
                with redirect_stderr(stderr):
                    code = cli_module.main(["sync-charts", "--config", str(config)])
            finally:
                cli_module.download_package = original_download

            self.assertEqual(code, 2)
            self.assertIn("create or mount the configured storage path", stderr.getvalue())
            self.assertFalse(chart_output.exists())
            self.assertEqual(calls, [])

    def test_preflight_explicit_default_chart_path_overrides_config(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config = root / "config.ini"
            configured_charts = root / "configured-charts"
            config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {configured_charts}\n"
                "\n"
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            calls = []
            original = cli_module.run_preflight

            def fake_run_preflight(**kwargs):
                calls.append(kwargs)
                return [health_module.CheckResult("Test", True, "ok")]

            try:
                cli_module.run_preflight = fake_run_preflight
                with redirect_stdout(StringIO()):
                    code = cli_module.main(
                        [
                            "preflight",
                            "--config",
                            str(config),
                            "--charts",
                            "~/charts/noaa-enc",
                        ]
                    )
            finally:
                cli_module.run_preflight = original

            self.assertEqual(code, 0)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0]["chart_dir"], Path("~/charts/noaa-enc").expanduser())
            self.assertNotEqual(calls[0]["chart_dir"], configured_charts)

    def test_gps_waits_reject_negative_seconds(self):
        self.assert_parse_error(["preflight", "--gps-seconds", "-1"])
        self.assert_parse_error(["status-report", "--gps-seconds", "-1"])
        self.assert_parse_error(["gps-monitor", "--seconds", "-1"])
        self.assert_parse_error(["status-gui", "--action-gps-seconds", "-1"])
        self.assert_parse_error(["status-gui", "--anchor-watch-seconds", "-1"])
        self.assert_parse_error(["status-gui", "--anchor-radius-meters", "0"])
        self.assert_parse_error(["status-gui", "--anchor-samples", "0"])

    def test_status_report_reads_gps_wait_from_trusted_launcher_environment(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            launcher_env = root / "launcher.env"
            launcher_env.write_text(
                "NOAA_NAVIONICS_GPS_SECONDS=37\n"
                "NOAA_NAVIONICS_OPENCPN_RESTARTS=3\n",
                encoding="ascii",
            )
            launcher_env.chmod(0o600)

            self.assertEqual(_gps_seconds_from_launcher_env(launcher_env), 37.0)

    def test_status_report_cli_uses_trusted_launcher_environment_gps_wait(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            launcher_env = root / "launcher.env"
            launcher_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=37\n", encoding="ascii")
            launcher_env.chmod(0o600)
            calls = []
            original_build = cli_module.build_status_report

            def fake_build_status_report(**kwargs):
                calls.append(kwargs)
                return complete_status_gui_report()

            try:
                cli_module.build_status_report = fake_build_status_report
                with redirect_stdout(StringIO()):
                    code = cli_module.main(
                        [
                            "status-report",
                            "--config",
                            str(root / "config.ini"),
                            "--gps-seconds-from-launcher-env",
                            str(launcher_env),
                            "--json",
                        ]
                    )
            finally:
                cli_module.build_status_report = original_build

            self.assertEqual(code, 0)
            self.assertEqual(calls[0]["gps_seconds"], 37.0)

    def test_status_report_rejects_symlinked_launcher_environment_for_gps_wait(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "target.env"
            target.write_text("NOAA_NAVIONICS_GPS_SECONDS=37\n", encoding="ascii")
            target.chmod(0o600)
            launcher_env = root / "launcher.env"
            try:
                launcher_env.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "launcher environment path is a symlink"):
                _gps_seconds_from_launcher_env(launcher_env)

    def test_status_report_rejects_writable_launcher_environment_parent_for_gps_wait(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / "launcher-parent"
            parent.mkdir()
            launcher_env = parent / "launcher.env"
            launcher_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=37\n", encoding="ascii")
            launcher_env.chmod(0o600)
            parent.chmod(0o777)
            try:
                with self.assertRaisesRegex(RuntimeError, "launcher environment directory .* has permissions"):
                    _gps_seconds_from_launcher_env(launcher_env)
            finally:
                parent.chmod(0o700)

    def test_status_report_rejects_unknown_launcher_environment_key_for_gps_wait(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            launcher_env = Path(tmpdir) / "launcher.env"
            launcher_env.write_text(
                "NOAA_NAVIONICS_GPS_SECONDS=37\n"
                "NOAA_NAVIONICS_EXTRA=1\n",
                encoding="ascii",
            )
            launcher_env.chmod(0o600)

            with self.assertRaisesRegex(ValueError, "unknown launcher environment key"):
                _gps_seconds_from_launcher_env(launcher_env)

    def test_track_logger_rejects_non_positive_duration(self):
        self.assert_parse_error(["log-track", "--seconds", "0"])
        self.assert_parse_error(["mark-position", "--seconds", "0"])
        self.assert_parse_error(["anchor-watch", "--seconds", "0"])
        self.assert_parse_error(["anchor-watch", "--anchor-samples", "0"])
        self.assert_parse_error(["anchor-watch", "--interval-seconds", "0"])
        self.assert_parse_error(["anchor-watch", "--radius-meters", "0"])
        self.assert_parse_error(["anchor-watch", "--anchor-lat", "91"])
        self.assert_parse_error(["anchor-watch", "--anchor-lon", "181"])

    def test_track_logger_rejects_negative_retention_days(self):
        self.assert_parse_error(["log-track", "--retention-days", "-1"])

    def test_live_serial_device_validation_rejects_broken_by_id_symlink(self):
        with (
            patch("noaa_navionics.cli.Path.exists", return_value=False),
            patch("noaa_navionics.cli.Path.is_symlink", return_value=True),
            patch("noaa_navionics.cli.Path.resolve", return_value=Path("/dev/ttyACM0")),
        ):
            with self.assertRaisesRegex(ValueError, "broken by-id symlink"):
                cli_module._validate_live_serial_device("/dev/serial/by-id/mock-gps")

    def test_live_serial_device_validation_rejects_by_id_that_is_not_character_device(self):
        with (
            patch("noaa_navionics.cli.Path.exists", return_value=True),
            patch("noaa_navionics.cli.Path.is_symlink", return_value=True),
            patch("noaa_navionics.cli.Path.is_char_device", return_value=False),
        ):
            with self.assertRaisesRegex(ValueError, "character device"):
                cli_module._validate_live_serial_device("/dev/serial/by-id/mock-gps")

    def test_live_serial_device_validation_rejects_stable_alias_that_is_not_character_device(self):
        with (
            patch("noaa_navionics.cli.Path.exists", return_value=True),
            patch("noaa_navionics.cli.Path.is_char_device", return_value=False),
        ):
            with self.assertRaisesRegex(ValueError, "character device"):
                cli_module._validate_live_serial_device("/dev/gps")


class ManifestTests(unittest.TestCase):
    VALID_CATALOG_XML = textwrap.dedent(
        """\
        <?xml version="1.0" encoding="UTF-8"?>
        <DS_Series xmlns="http://www.isotc211.org/2005/gmd"
            xmlns:gco="http://www.isotc211.org/2005/gco">
          <composedOf>
            <DS_DataSet>
              <has>
                <MD_Metadata>
                  <identificationInfo>
                    <MD_DataIdentification>
                      <citation>
                        <CI_Citation>
                          <title><gco:CharacterString>US5AK3CM</gco:CharacterString></title>
                          <alternateTitle><gco:CharacterString>Cook Inlet</gco:CharacterString></alternateTitle>
                        </CI_Citation>
                      </citation>
                    </MD_DataIdentification>
                  </identificationInfo>
                  <distributionInfo>
                    <MD_Distribution>
                      <transferOptions>
                        <MD_DigitalTransferOptions>
                          <onLine>
                            <CI_OnlineResource>
                              <linkage><URL>https://www.charts.noaa.gov/ENCs/US5AK3CM.zip</URL></linkage>
                            </CI_OnlineResource>
                          </onLine>
                        </MD_DigitalTransferOptions>
                      </transferOptions>
                    </MD_Distribution>
                  </distributionInfo>
                </MD_Metadata>
              </has>
            </DS_DataSet>
          </composedOf>
        </DS_Series>
        """
    )

    class FakeResponse:
        def __init__(self, payload, content_length: str = "5", url: str = ""):
            self.headers = {"Content-Length": content_length}
            self.payload = BytesIO(payload)
            self.url = url

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return None

        def read(self, size=-1):
            return self.payload.read(size)

        def geturl(self):
            return self.url

    def test_download_writes_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("Test package", source_zip.as_uri(), "AK_ENCs.zip")

            result = download_package(package, output, extract=True)

            self.assertTrue(result.sha256)
            self.assertTrue((output / MANIFEST_NAME).exists())
            manifest = read_manifest(output)
            self.assertEqual(manifest["package"]["label"], "Test package")
            self.assertEqual(manifest["package"]["url"], source_zip.as_uri())
            self.assertEqual(manifest["created_at_source"], "download")
            self.assertEqual(manifest["download"]["url"], source_zip.as_uri())
            self.assertEqual(manifest["download"]["sha256"], result.sha256)
            self.assertEqual(manifest["extract"]["enc_cell_count"], 1)
            check = check_chart_manifest(output)
            self.assertTrue(check.ok)
            data = check.data or {}
            self.assertEqual(data["configured_path"], str(output))
            self.assertEqual(data["path"], str(output / MANIFEST_NAME))
            self.assertEqual(data["created_at_source"], "download")
            self.assertEqual(data["package_filename"], "AK_ENCs.zip")
            self.assertEqual(data["package_url"], source_zip.as_uri())
            self.assertEqual(data["download_path"], str(output / "AK_ENCs.zip"))
            self.assertEqual(data["download_url"], source_zip.as_uri())
            self.assertEqual(data["download_bytes"], result.bytes_written)
            self.assertEqual(data["sha256"], result.sha256)
            self.assertEqual(data["enc_cell_count"], 1)
            self.assertEqual(data["actual_enc_cell_count"], 1)

    def test_download_tightens_chart_output_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            output.mkdir()
            os.chmod(output, 0o777)
            package = Package("Test package", source_zip.as_uri(), "AK_ENCs.zip")

            download_package(package, output, extract=True)

            self.assertEqual(output.stat().st_mode & 0o777, 0o700)

    def test_download_tightens_extracted_chart_tree(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            directory_info = zipfile.ZipInfo("US5AK3CM/")
            directory_info.external_attr = 0o777 << 16
            file_info = zipfile.ZipInfo("US5AK3CM/US5AK3CM.000")
            file_info.external_attr = 0o666 << 16
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr(directory_info, "")
                archive.writestr(file_info, "cell")
            output = root / "charts"
            package = Package("Test package", source_zip.as_uri(), "AK_ENCs.zip")

            download_package(package, output, extract=True)

            extracted = output / "AK_ENCs"
            cell_dir = extracted / "US5AK3CM"
            cell = cell_dir / "US5AK3CM.000"
            self.assertEqual(extracted.stat().st_mode & 0o777, 0o700)
            self.assertEqual(cell_dir.stat().st_mode & 0o777, 0o700)
            self.assertEqual(cell.stat().st_mode & 0o777, 0o600)

    def test_download_rejects_chart_output_directory_when_tightening_fails(self):
        original_chmod = downloader_module.os.chmod

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / "charts"
            output.mkdir()
            os.chmod(output, 0o777)
            package = Package("Test package", "file:///unused.zip", "AK_ENCs.zip")

            def no_op_chmod(path, mode):
                if Path(path) == output:
                    return None
                return original_chmod(path, mode)

            try:
                downloader_module.os.chmod = no_op_chmod
                with self.assertRaisesRegex(RuntimeError, "chart output directory .* permissions 0777"):
                    download_package(package, output)
            finally:
                downloader_module.os.chmod = original_chmod
                output.chmod(0o700)

    def test_fsync_tree_uses_no_follow_file_opens(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            tree = root / "chart-tree"
            tree.mkdir()
            regular = tree / "US5AK3CM.000"
            regular.write_text("cell", encoding="ascii")
            outside = root / "outside"
            outside.mkdir()
            outside_file = outside / "outside.000"
            outside_file.write_text("outside", encoding="ascii")
            symlink_file = tree / "linked.000"
            symlink_dir = tree / "linked-dir"
            try:
                symlink_file.symlink_to(outside_file)
                symlink_dir.symlink_to(outside, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            original_open = os.open
            opened: list[tuple[Path, int]] = []

            def recording_open(path, flags, *args, **kwargs):
                opened.append((Path(path), flags))
                return original_open(path, flags, *args, **kwargs)

            with patch("noaa_navionics.downloader.os.open", side_effect=recording_open):
                downloader_module._fsync_tree(tree)

            opened_by_path = {path: flags for path, flags in opened}
            self.assertIn(regular, opened_by_path)
            self.assertTrue(opened_by_path[regular] & getattr(os, "O_NOFOLLOW", 0))
            self.assertNotIn(symlink_file, opened_by_path)
            self.assertNotIn(symlink_dir, opened_by_path)
            self.assertNotIn(symlink_dir / outside_file.name, opened_by_path)

    def test_forced_download_rejects_bad_zip_before_replacing_archive(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            good_zip = root / "good.zip"
            with zipfile.ZipFile(good_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", good_zip.as_uri(), "AK_ENCs.zip")
            first = download_package(package, output, extract=True, keep_zip=True, force=True)
            archive_path = output / "AK_ENCs.zip"
            original_archive_bytes = archive_path.read_bytes()
            original_manifest = read_manifest(output)
            bad_zip = root / "bad.zip"
            bad_zip.write_bytes(b"not a zip")
            bad_package = Package("State AK", bad_zip.as_uri(), "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "downloaded ZIP is not a valid archive"):
                download_package(bad_package, output, extract=True, keep_zip=True, force=True)

            self.assertEqual(archive_path.read_bytes(), original_archive_bytes)
            self.assertEqual(read_manifest(output), original_manifest)
            self.assertTrue((output / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000").exists())
            self.assertFalse((output / "AK_ENCs.zip.part").exists())
            self.assertTrue(first.sha256)

    def test_forced_download_rejects_unsafe_zip_before_replacing_archive(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            good_zip = root / "good.zip"
            with zipfile.ZipFile(good_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", good_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)
            archive_path = output / "AK_ENCs.zip"
            original_archive_bytes = archive_path.read_bytes()
            original_manifest = read_manifest(output)
            unsafe_zip = root / "unsafe.zip"
            with zipfile.ZipFile(unsafe_zip, "w") as archive:
                archive.writestr("../evil.000", "bad")
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            unsafe_package = Package("State AK", unsafe_zip.as_uri(), "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "downloaded ZIP has unsafe member path"):
                download_package(unsafe_package, output, extract=True, keep_zip=True, force=True)

            self.assertEqual(archive_path.read_bytes(), original_archive_bytes)
            self.assertEqual(read_manifest(output), original_manifest)
            self.assertEqual((output / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000").read_text(encoding="ascii"), "cell")
            self.assertFalse((output / "AK_ENCs.zip.part").exists())
            self.assertFalse((root / "evil.000").exists())

    def test_forced_download_rejects_zip_without_enc_cells_before_replacing_archive(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            good_zip = root / "good.zip"
            with zipfile.ZipFile(good_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", good_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)
            archive_path = output / "AK_ENCs.zip"
            original_archive_bytes = archive_path.read_bytes()
            original_manifest = read_manifest(output)
            empty_zip = root / "empty.zip"
            with zipfile.ZipFile(empty_zip, "w") as archive:
                archive.writestr("README.txt", "not chart data")
            empty_package = Package("State AK", empty_zip.as_uri(), "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "downloaded ZIP contains no ENC"):
                download_package(empty_package, output, extract=True, keep_zip=True, force=True)

            self.assertEqual(archive_path.read_bytes(), original_archive_bytes)
            self.assertEqual(read_manifest(output), original_manifest)
            self.assertTrue((output / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000").exists())
            self.assertFalse((output / "AK_ENCs.zip.part").exists())

    def test_catalog_download_rejects_malformed_xml_before_promotion(self):
        original = downloader_module.urlopen
        payload = b"<html><body>marina login"

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(payload, content_length=str(len(payload)), url=request.full_url)

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = package_for(catalog=True)

                with self.assertRaisesRegex(RuntimeError, "downloaded catalog XML is not parseable"):
                    download_package(package, output, force=True)

                self.assertFalse((output / package.filename).exists())
                self.assertFalse((output / f"{package.filename}.part").exists())
                self.assertFalse((output / MANIFEST_NAME).exists())
        finally:
            downloader_module.urlopen = original

    def test_catalog_download_rejects_xml_without_enc_metadata_before_promotion(self):
        original = downloader_module.urlopen
        payload = b"<?xml version='1.0'?><status>maintenance</status>\n"

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(payload, content_length=str(len(payload)), url=request.full_url)

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = package_for(catalog=True)

                with self.assertRaisesRegex(RuntimeError, "no NOAA ENC chart metadata"):
                    download_package(package, output, force=True)

                self.assertFalse((output / package.filename).exists())
                self.assertFalse((output / f"{package.filename}.part").exists())
                self.assertFalse((output / MANIFEST_NAME).exists())
        finally:
            downloader_module.urlopen = original

    def test_catalog_download_accepts_noaa_enc_metadata(self):
        original = downloader_module.urlopen
        payload = self.VALID_CATALOG_XML.encode("utf-8")

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(payload, content_length=str(len(payload)), url=request.full_url)

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = package_for(catalog=True)

                result = download_package(package, output, force=True)

                self.assertEqual(result.path, output / package.filename)
                self.assertTrue(result.sha256)
                self.assertTrue((output / package.filename).exists())
                self.assertEqual(search_catalog(output / package.filename, "cook")[0].name, "US5AK3CM")
                manifest = read_manifest(output)
                self.assertEqual(manifest["package"]["filename"], package.filename)
        finally:
            downloader_module.urlopen = original

    def test_cached_catalog_reuse_rejects_xml_without_enc_metadata(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            package = package_for(catalog=True)
            catalog = output / package.filename
            catalog.write_text("<?xml version='1.0'?><status>maintenance</status>\n", encoding="utf-8")
            catalog.chmod(0o600)

            with self.assertRaisesRegex(RuntimeError, "no NOAA ENC chart metadata"):
                download_package(package, output, force=False)

            self.assertEqual(catalog.read_text(encoding="utf-8"), "<?xml version='1.0'?><status>maintenance</status>\n")
            self.assertFalse((output / MANIFEST_NAME).exists())

    def test_cached_catalog_reuse_accepts_noaa_enc_metadata_without_network(self):
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            raise AssertionError("urlopen should not be called for an existing valid catalog")

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = package_for(catalog=True)
                catalog = output / package.filename
                catalog.write_text(self.VALID_CATALOG_XML, encoding="utf-8")
                catalog.chmod(0o600)

                result = download_package(package, output, force=False)

                self.assertTrue(result.skipped)
                self.assertEqual(result.path, catalog)
                self.assertEqual(search_catalog(catalog, "cook")[0].name, "US5AK3CM")
                self.assertFalse((output / MANIFEST_NAME).exists())
        finally:
            downloader_module.urlopen = original

    def test_download_revalidates_archive_target_before_promotion(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            outside = root / "outside.zip"
            outside.write_text("outside\n", encoding="ascii")
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            original_validate = downloader_module._validate_downloaded_zip

            def swap_archive_target(path):
                original_validate(path)
                try:
                    (output / "AK_ENCs.zip").symlink_to(outside)
                except OSError as exc:
                    self.skipTest(f"symlinks unavailable: {exc}")

            with patch("noaa_navionics.downloader._validate_downloaded_zip", side_effect=swap_archive_target):
                with self.assertRaisesRegex(RuntimeError, "chart archive path is a symlink before promotion"):
                    download_package(package, output, extract=True, keep_zip=True, force=True)

            self.assertEqual(outside.read_text(encoding="ascii"), "outside\n")
            self.assertTrue((output / "AK_ENCs.zip").is_symlink())
            self.assertFalse((output / "AK_ENCs.zip.part").exists())
            self.assertFalse((output / MANIFEST_NAME).exists())

    def test_download_manifest_records_final_response_url(self):
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            self.assertEqual(request.full_url, "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip")
            return self.FakeResponse(
                b"chart",
                url="https://downloads.charts.noaa.gov/cache/AK_ENCs.zip",
            )

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("State AK", "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", "AK_ENCs.zip")

                result = download_package(package, output)

                manifest = read_manifest(output)
                self.assertEqual(result.url, "https://downloads.charts.noaa.gov/cache/AK_ENCs.zip")
                self.assertEqual(manifest["package"]["url"], package.url)
                self.assertEqual(manifest["download"]["url"], result.url)
        finally:
            downloader_module.urlopen = original

    def test_download_rejects_http_redirect_before_writing_archive(self):
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(
                b"chart",
                url="http://downloads.charts.noaa.gov/cache/AK_ENCs.zip",
            )

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("State AK", "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", "AK_ENCs.zip")

                with self.assertRaisesRegex(RuntimeError, "non-HTTPS redirect"):
                    download_package(package, output)

                self.assertFalse((output / "AK_ENCs.zip").exists())
                self.assertFalse((output / MANIFEST_NAME).exists())
        finally:
            downloader_module.urlopen = original

    def test_download_rejects_non_noaa_redirect_before_writing_archive(self):
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(
                b"chart",
                url="https://example.invalid/cache/AK_ENCs.zip",
            )

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("State AK", "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", "AK_ENCs.zip")

                with self.assertRaisesRegex(RuntimeError, "non-NOAA host"):
                    download_package(package, output)

                self.assertFalse((output / "AK_ENCs.zip").exists())
                self.assertFalse((output / MANIFEST_NAME).exists())
        finally:
            downloader_module.urlopen = original

    def test_download_rejects_redirect_to_wrong_filename_before_writing_archive(self):
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(
                b"chart",
                url="https://downloads.charts.noaa.gov/cache/CA_ENCs.zip",
            )

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("State AK", "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", "AK_ENCs.zip")

                with self.assertRaisesRegex(RuntimeError, "does not match package filename"):
                    download_package(package, output)

                self.assertFalse((output / "AK_ENCs.zip").exists())
                self.assertFalse((output / MANIFEST_NAME).exists())
        finally:
            downloader_module.urlopen = original

    def test_existing_zip_extract_respects_no_keep_zip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            existing = output / "AK_ENCs.zip"
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)

            result = download_package(package, output, extract=True, keep_zip=False)

            self.assertTrue(result.skipped)
            self.assertFalse(existing.exists())
            self.assertTrue((output / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000").exists())
            manifest = read_manifest(output)
            self.assertEqual(manifest["download"]["bytes"], result.bytes_written)
            self.assertEqual(manifest["created_at_source"], "previous-manifest")
            self.assertEqual(manifest["extract"]["enc_cell_count"], 1)

    def test_existing_zip_no_keep_zip_rejects_symlink_swapped_before_removal(self):
        original_extract_zip = downloader_module.extract_zip
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            archive_path = output / "AK_ENCs.zip"
            target = root / "target.zip"
            target.write_text("do not remove\n", encoding="utf-8")
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)

            def replacing_extract(zip_path, destination):
                extracted_to = original_extract_zip(zip_path, destination)
                archive_path.unlink()
                try:
                    archive_path.symlink_to(target)
                except OSError as exc:
                    self.skipTest(f"symlinks unavailable: {exc}")
                return extracted_to

            try:
                downloader_module.extract_zip = replacing_extract
                with self.assertRaisesRegex(RuntimeError, "chart archive path is a symlink before removal"):
                    download_package(package, output, extract=True, keep_zip=False)
            finally:
                downloader_module.extract_zip = original_extract_zip

            self.assertTrue(archive_path.is_symlink())
            self.assertEqual(target.read_text(encoding="utf-8"), "do not remove\n")

    def test_existing_zip_no_keep_zip_rejects_replaced_archive_before_removal(self):
        original_extract_zip = downloader_module.extract_zip
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            archive_path = output / "AK_ENCs.zip"
            replacement = root / "replacement.zip"
            replacement.write_text("do not remove\n", encoding="utf-8")
            replacement.chmod(0o600)
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)

            def replacing_extract(zip_path, destination):
                extracted_to = original_extract_zip(zip_path, destination)
                os.replace(replacement, archive_path)
                return extracted_to

            try:
                downloader_module.extract_zip = replacing_extract
                with self.assertRaisesRegex(RuntimeError, "chart archive path changed before cleanup"):
                    download_package(package, output, extract=True, keep_zip=False)
            finally:
                downloader_module.extract_zip = original_extract_zip

            self.assertEqual(archive_path.read_text(encoding="utf-8"), "do not remove\n")

    def test_existing_zip_without_previous_manifest_fails_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            existing = output / "AK_ENCs.zip"
            with zipfile.ZipFile(existing, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            package = Package("State AK", "https://example.invalid/AK_ENCs.zip", "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "prior verified manifest"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs").exists())
            self.assertFalse((output / MANIFEST_NAME).exists())

    def test_existing_zip_symlink_fails_before_reading_cache(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / "charts"
            output.mkdir()
            real_archive = root / "real.zip"
            with zipfile.ZipFile(real_archive, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            archive_link = output / "AK_ENCs.zip"
            try:
                archive_link.symlink_to(real_archive)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            package = Package("State AK", real_archive.as_uri(), "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "chart archive path is a symlink"):
                download_package(package, output, extract=True)

            self.assertTrue(archive_link.is_symlink())
            self.assertFalse((output / "AK_ENCs").exists())

    def test_existing_zip_nonregular_path_fails_before_reading_cache(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            existing = output / "AK_ENCs.zip"
            existing.mkdir()
            package = Package("State AK", "https://example.invalid/AK_ENCs.zip", "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "chart download path is not a regular file"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs").exists())

    def test_existing_zip_writable_file_fails_before_reading_cache(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            existing = output / "AK_ENCs.zip"
            with zipfile.ZipFile(existing, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            existing.chmod(0o622)
            package = Package("State AK", "https://example.invalid/AK_ENCs.zip", "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "chart download path .* has permissions 0622"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs").exists())

    def test_hash_existing_download_path_rejects_writable_zip_before_hashing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            existing = Path(tmpdir) / "AK_ENCs.zip"
            with zipfile.ZipFile(existing, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            existing.chmod(0o622)

            with self.assertRaisesRegex(RuntimeError, "chart download path .* has permissions 0622"):
                downloader_module._hash_existing_download_path(existing)

    def test_download_rejects_symlinked_output_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_storage = root / "real-storage"
            real_storage.mkdir()
            storage_link = root / "storage-link"
            try:
                storage_link.symlink_to(real_storage, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            output = storage_link / "charts"
            package = Package("State AK", "https://example.invalid/AK_ENCs.zip", "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "chart output path contains a symlink"):
                download_package(package, output)

            self.assertFalse((real_storage / "charts").exists())

    def test_existing_zip_mismatched_previous_manifest_fails_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            first_zip = root / "first.zip"
            with zipfile.ZipFile(first_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", first_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)
            existing = output / "AK_ENCs.zip"
            with zipfile.ZipFile(existing, "w") as archive:
                archive.writestr("US5AK4CM/US5AK4CM.000", "different cell")

            with self.assertRaisesRegex(RuntimeError, "prior verified manifest"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs" / "US5AK4CM").exists())

    def test_existing_zip_mismatched_previous_manifest_download_url_fails_before_extracting(self):
        original = downloader_module.urlopen

        def zip_payload():
            buffer = BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            return buffer.getvalue()

        payload = zip_payload()

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(payload, content_length=str(len(payload)), url=request.full_url)

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("State AK", "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", "AK_ENCs.zip")
                download_package(package, output, extract=False, keep_zip=True, force=True)
                manifest = read_manifest(output)
                manifest["download"]["url"] = "https://downloads.charts.noaa.gov/cache/CA_ENCs.zip"
                (output / MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")

                with self.assertRaisesRegex(RuntimeError, "prior verified manifest"):
                    download_package(package, output, extract=True)

                self.assertFalse((output / "AK_ENCs" / "US5AK3CM").exists())
        finally:
            downloader_module.urlopen = original

    def test_existing_zip_unverified_previous_manifest_fails_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)
            manifest = read_manifest(output)
            manifest["created_at_source"] = "unverified-cache"
            (output / MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "prior verified manifest"):
                download_package(package, output, extract=True)

            self.assertEqual(read_manifest(output)["created_at_source"], "unverified-cache")

    def test_existing_zip_symlinked_previous_manifest_fails_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=False, keep_zip=True, force=True)
            real_manifest = root / "real-manifest.json"
            real_manifest.write_text((output / MANIFEST_NAME).read_text(encoding="utf-8"), encoding="utf-8")
            (output / MANIFEST_NAME).unlink()
            try:
                (output / MANIFEST_NAME).symlink_to(real_manifest)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "previous chart manifest path is a symlink"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs").exists())

    def test_existing_zip_writable_previous_manifest_fails_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=False, keep_zip=True, force=True)
            (output / MANIFEST_NAME).chmod(0o622)

            with self.assertRaisesRegex(RuntimeError, "previous chart manifest path .* has permissions 0622"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs").exists())

    def test_existing_zip_preserves_previous_manifest_timestamp(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            first = download_package(package, output, extract=True, force=True)
            old_created_at = "2000-01-01T00:00:00Z"
            manifest = read_manifest(output)
            manifest["created_at"] = old_created_at
            (output / MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")

            second = download_package(package, output, extract=True, force=False)

            self.assertTrue(second.skipped)
            self.assertEqual(second.sha256, first.sha256)
            updated_manifest = read_manifest(output)
            self.assertEqual(updated_manifest["created_at"], old_created_at)
            self.assertEqual(updated_manifest["created_at_source"], "previous-manifest")
            check = check_chart_manifest(output, max_age_days=1)
            self.assertFalse(check.ok)
            self.assertIn("days old", check.detail)

    def test_existing_zip_preserves_previous_manifest_download_url(self):
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(
                b"chart",
                url="https://downloads.charts.noaa.gov/cache/AK_ENCs.zip",
            )

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("State AK", "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", "AK_ENCs.zip")
                first = download_package(package, output, force=True)

                second = download_package(package, output, force=False)

                self.assertTrue(second.skipped)
                self.assertEqual(read_manifest(output)["download"]["url"], first.url)
        finally:
            downloader_module.urlopen = original

    def test_write_manifest_does_not_reuse_fixed_part_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            fixed_part = output / "noaa-navionics-manifest.json.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")
            package = Package("Test package", "file:///AK_ENCs.zip", "AK_ENCs.zip")
            result = downloader_module.DownloadResult(output / "AK_ENCs.zip", package.url, 0, sha256="abc")

            downloader_module.write_manifest(output, package, result)

            self.assertEqual(fixed_part.read_text(encoding="utf-8"), "other writer\n")
            self.assertEqual(read_manifest(output)["package"]["filename"], "AK_ENCs.zip")
            self.assertFalse(list(output.glob(".noaa-navionics-manifest.json.*.part")))

    def test_write_manifest_rejects_symlinked_output_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_storage = root / "real-storage"
            real_storage.mkdir()
            storage_link = root / "storage-link"
            try:
                storage_link.symlink_to(real_storage, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            output = storage_link / "charts"
            package = Package("Test package", "file:///AK_ENCs.zip", "AK_ENCs.zip")
            result = downloader_module.DownloadResult(output / "AK_ENCs.zip", package.url, 0, sha256="abc")

            with self.assertRaisesRegex(RuntimeError, "chart output path contains a symlink"):
                downloader_module.write_manifest(output, package, result)

            self.assertFalse((real_storage / "charts").exists())

    def test_write_manifest_rejects_symlinked_manifest_target(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / "charts"
            output.mkdir()
            target = root / "target-manifest.json"
            target.write_text("do not replace\n", encoding="utf-8")
            manifest = output / MANIFEST_NAME
            try:
                manifest.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            package = Package("Test package", "file:///AK_ENCs.zip", "AK_ENCs.zip")
            result = downloader_module.DownloadResult(output / "AK_ENCs.zip", package.url, 0, sha256="abc")

            with self.assertRaisesRegex(RuntimeError, "refusing to replace symlinked chart manifest path"):
                downloader_module.write_manifest(output, package, result)

            self.assertTrue(manifest.is_symlink())
            self.assertEqual(target.read_text(encoding="utf-8"), "do not replace\n")

    def test_write_manifest_rejects_nonregular_manifest_target(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            (output / MANIFEST_NAME).mkdir()
            package = Package("Test package", "file:///AK_ENCs.zip", "AK_ENCs.zip")
            result = downloader_module.DownloadResult(output / "AK_ENCs.zip", package.url, 0, sha256="abc")

            with self.assertRaisesRegex(RuntimeError, "refusing to replace non-regular chart manifest path"):
                downloader_module.write_manifest(output, package, result)

    def test_write_manifest_rejects_writable_manifest_target(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            manifest = output / MANIFEST_NAME
            manifest.write_text("do not replace\n", encoding="utf-8")
            manifest.chmod(0o622)
            package = Package("Test package", "file:///AK_ENCs.zip", "AK_ENCs.zip")
            result = downloader_module.DownloadResult(output / "AK_ENCs.zip", package.url, 0, sha256="abc")

            try:
                with self.assertRaisesRegex(
                    RuntimeError, "refusing to replace chart manifest path .* with permissions 0622"
                ):
                    downloader_module.write_manifest(output, package, result)
            finally:
                manifest.chmod(0o600)

            self.assertEqual(manifest.read_text(encoding="utf-8"), "do not replace\n")

    def test_write_manifest_revalidates_manifest_target_before_promotion(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / "charts"
            output.mkdir()
            outside = root / "outside-manifest.json"
            outside.write_text("outside\n", encoding="utf-8")
            package = Package("Test package", "file:///AK_ENCs.zip", "AK_ENCs.zip")
            result = downloader_module.DownloadResult(output / "AK_ENCs.zip", package.url, 0, sha256="abc")
            original_prepare = downloader_module._prepare_output_dir
            calls = 0

            def swapping_prepare(path):
                nonlocal calls
                calls += 1
                original_prepare(path)
                if calls == 2:
                    try:
                        (output / MANIFEST_NAME).symlink_to(outside)
                    except OSError as exc:
                        self.skipTest(f"symlinks unavailable: {exc}")

            with patch("noaa_navionics.downloader._prepare_output_dir", side_effect=swapping_prepare):
                with self.assertRaisesRegex(RuntimeError, "refusing to replace symlinked chart manifest path"):
                    downloader_module.write_manifest(output, package, result)

            self.assertEqual(outside.read_text(encoding="utf-8"), "outside\n")
            self.assertTrue((output / MANIFEST_NAME).is_symlink())
            self.assertFalse(list(output.glob(".noaa-navionics-manifest.json.*.part")))

    def test_write_manifest_syncs_file_and_directory(self):
        calls = []
        original_fsync = downloader_module.os.fsync
        downloader_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("Test package", "file:///AK_ENCs.zip", "AK_ENCs.zip")
                result = downloader_module.DownloadResult(output / "AK_ENCs.zip", package.url, 0, sha256="abc")

                downloader_module.write_manifest(output, package, result)
        finally:
            downloader_module.os.fsync = original_fsync

        self.assertGreaterEqual(len(calls), 2)

    def test_chart_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = downloader_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        downloader_module.os.open = fake_open
        try:
            downloader_module._fsync_directory(Path("/tmp"))
        finally:
            downloader_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], Path("/tmp"))
        self.assertTrue(calls[0][1] & getattr(os, "O_DIRECTORY", 0))
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_download_rejects_existing_partial_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            partial = output / "AK_ENCs.zip.part"
            partial.write_bytes(b"interrupted")
            package = package_for(state="AK")

            with self.assertRaisesRegex(RuntimeError, "partial download already exists"):
                download_package(package, output, force=True)

            self.assertEqual(partial.read_bytes(), b"interrupted")

    def test_download_rejects_existing_partial_symlink(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            partial = output / "AK_ENCs.zip.part"
            try:
                partial.symlink_to(output / "missing-part-target")
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            package = package_for(state="AK")

            with self.assertRaisesRegex(RuntimeError, "partial download already exists"):
                download_package(package, output, force=True)

            self.assertTrue(partial.is_symlink())

    def test_download_creates_private_archive_with_permissive_umask(self):
        original = downloader_module.urlopen
        old_umask = os.umask(0)

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(b"chart")

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("Private archive test", "https://example.invalid/chart.zip", "chart.zip")

                result = download_package(package, output)

                self.assertEqual(result.path.stat().st_mode & 0o777, 0o600)
        finally:
            os.umask(old_umask)
            downloader_module.urlopen = original

    def test_download_retries_transient_network_failure(self):
        calls = {"count": 0}
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            calls["count"] += 1
            if calls["count"] == 1:
                raise URLError("temporary outage")
            return self.FakeResponse(b"chart")

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                package = Package("Retry test", "https://example.invalid/chart.zip", "chart.zip")
                result = download_package(package, Path(tmpdir), retries=2, retry_delay=0)
                self.assertEqual(result.path.read_bytes(), b"chart")
                self.assertFalse(result.skipped)
        finally:
            downloader_module.urlopen = original

        self.assertEqual(calls["count"], 2)

    def test_download_retries_incomplete_response(self):
        calls = {"count": 0}
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            calls["count"] += 1
            if calls["count"] == 1:
                return self.FakeResponse(b"cha")
            return self.FakeResponse(b"chart")

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                package = Package("Retry test", "https://example.invalid/chart.zip", "chart.zip")
                result = download_package(package, Path(tmpdir), retries=2, retry_delay=0)
                self.assertEqual(result.path.read_bytes(), b"chart")
                self.assertEqual(result.bytes_written, 5)
        finally:
            downloader_module.urlopen = original

        self.assertEqual(calls["count"], 2)

    def test_download_retries_read_level_incomplete_response_and_cleans_partial(self):
        calls = {"count": 0}
        original = downloader_module.urlopen

        class BrokenReadResponse:
            headers = {"Content-Length": "5"}

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def read(self, size=-1):
                raise IncompleteRead(b"cha", 5)

        def fake_urlopen(request, timeout=60):
            calls["count"] += 1
            if calls["count"] == 1:
                return BrokenReadResponse()
            return self.FakeResponse(b"chart")

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                package = Package("Retry test", "https://example.invalid/chart.zip", "chart.zip")
                result = download_package(package, root, retries=2, retry_delay=0)
                self.assertEqual(result.path.read_bytes(), b"chart")
                self.assertFalse((root / "chart.zip.part").exists())
        finally:
            downloader_module.urlopen = original

        self.assertEqual(calls["count"], 2)

    def test_download_cleanup_rejects_symlinked_interrupted_partial(self):
        original = downloader_module.urlopen

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "do-not-remove"
            target.write_text("keep\n", encoding="ascii")

            class ReplacingReadResponse:
                headers = {"Content-Length": "5"}

                def __enter__(self):
                    return self

                def __exit__(self, exc_type, exc, tb):
                    return None

                def read(self, size=-1):
                    partial = root / "chart.zip.part"
                    partial.unlink()
                    partial.symlink_to(target)
                    raise IncompleteRead(b"cha", 5)

            def fake_urlopen(request, timeout=60):
                return ReplacingReadResponse()

            try:
                downloader_module.urlopen = fake_urlopen
                package = Package("Retry test", "https://example.invalid/chart.zip", "chart.zip")
                with self.assertRaisesRegex(RuntimeError, "partial download path is a symlink before cleanup"):
                    download_package(package, root, retries=2, retry_delay=0)
            finally:
                downloader_module.urlopen = original

            self.assertTrue((root / "chart.zip.part").is_symlink())
            self.assertEqual(target.read_text(encoding="ascii"), "keep\n")

    def test_download_cleanup_rejects_replaced_interrupted_partial(self):
        original = downloader_module.urlopen

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)

            class ReplacingReadResponse:
                headers = {"Content-Length": "5"}

                def __enter__(self):
                    return self

                def __exit__(self, exc_type, exc, tb):
                    return None

                def read(self, size=-1):
                    partial = root / "chart.zip.part"
                    replacement = root / "replacement.part"
                    replacement.write_text("new owner\n", encoding="ascii")
                    replacement.chmod(0o600)
                    os.replace(replacement, partial)
                    raise IncompleteRead(b"cha", 5)

            def fake_urlopen(request, timeout=60):
                return ReplacingReadResponse()

            try:
                downloader_module.urlopen = fake_urlopen
                package = Package("Retry test", "https://example.invalid/chart.zip", "chart.zip")
                with self.assertRaisesRegex(RuntimeError, "partial download path changed before cleanup"):
                    download_package(package, root, retries=2, retry_delay=0)
            finally:
                downloader_module.urlopen = original

            self.assertEqual((root / "chart.zip.part").read_text(encoding="ascii"), "new owner\n")

    def test_download_cleanup_rejects_writable_interrupted_partial(self):
        original = downloader_module.urlopen

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)

            class WritablePartialReadResponse:
                headers = {"Content-Length": "5"}

                def __enter__(self):
                    return self

                def __exit__(self, exc_type, exc, tb):
                    return None

                def read(self, size=-1):
                    os.chmod(root / "chart.zip.part", 0o622)
                    raise IncompleteRead(b"cha", 5)

            def fake_urlopen(request, timeout=60):
                return WritablePartialReadResponse()

            try:
                downloader_module.urlopen = fake_urlopen
                package = Package("Retry test", "https://example.invalid/chart.zip", "chart.zip")
                with self.assertRaisesRegex(RuntimeError, "partial download path .* has permissions 0622"):
                    download_package(package, root, retries=2, retry_delay=0)
            finally:
                downloader_module.urlopen = original

            partial = root / "chart.zip.part"
            try:
                self.assertTrue(partial.exists())
                self.assertEqual(partial.stat().st_mode & 0o777, 0o622)
            finally:
                if partial.exists() and not partial.is_symlink():
                    os.chmod(partial, 0o600)

    def test_download_lock_blocks_concurrent_chart_update(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("busy\n", encoding="ascii")
            os.chmod(lock, 0o600)
            package = Package("Locked test", "https://example.invalid/chart.zip", "chart.zip")

            with self.assertRaisesRegex(RuntimeError, "already in progress"):
                download_package(package, root)

            self.assertTrue(lock.exists())

    def test_download_lock_rejects_public_active_lock_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("busy\n", encoding="ascii")
            os.chmod(lock, 0o644)
            package = Package("Locked test", "https://example.invalid/chart.zip", "chart.zip")

            with self.assertRaisesRegex(RuntimeError, "chart update lock path has permissions 0644"):
                download_package(package, root)

            self.assertTrue(lock.exists())
            self.assertEqual(lock.read_text(encoding="ascii"), "busy\n")

    def test_download_lock_rejects_symlinked_lock_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "lock-target"
            target.write_text("stale\n", encoding="ascii")
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(target, (old_time, old_time))
            lock = root / DOWNLOAD_LOCK_NAME
            try:
                lock.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            package = Package("Locked test", "https://example.invalid/chart.zip", "chart.zip")

            with self.assertRaisesRegex(RuntimeError, "chart update lock path is a symlink"):
                download_package(package, root)

            self.assertTrue(lock.is_symlink())
            self.assertEqual(target.read_text(encoding="ascii"), "stale\n")

    def test_stale_download_lock_is_replaced(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / "chart.zip").write_bytes(b"existing")
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("stale\n", encoding="ascii")
            os.chmod(lock, 0o600)
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            package = Package("Stale lock test", "https://example.invalid/chart.zip", "chart.zip")

            result = download_package(package, root)

            self.assertTrue(result.skipped)
            self.assertFalse(lock.exists())

    def test_stale_download_lock_cleanup_leaves_replaced_lock_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / "chart.zip").write_bytes(b"existing")
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("stale\n", encoding="ascii")
            os.chmod(lock, 0o600)
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            package = Package("Stale lock test", "https://example.invalid/chart.zip", "chart.zip")
            original_lock_is_stale = downloader_module._lock_is_stale
            calls = 0

            def replacing_lock_is_stale(lock_path, *, stale_seconds=downloader_module.DOWNLOAD_LOCK_STALE_SECONDS):
                nonlocal calls
                calls += 1
                if calls == 1:
                    replacement = lock_path.with_name("replacement-download.lock")
                    replacement.write_text("new owner\n", encoding="ascii")
                    os.chmod(replacement, 0o600)
                    os.replace(replacement, lock_path)
                    return True
                return False

            try:
                downloader_module._lock_is_stale = replacing_lock_is_stale
                with redirect_stderr(StringIO()) as stderr:
                    with self.assertRaisesRegex(RuntimeError, "chart update already in progress"):
                        download_package(package, root)
            finally:
                downloader_module._lock_is_stale = original_lock_is_stale

            self.assertEqual(calls, 2)
            self.assertEqual(lock.read_text(encoding="ascii"), "new owner\n")
            self.assertIn("chart update lock cleanup changed before cleanup", stderr.getvalue())

    def test_stale_download_lock_cleanup_rejects_writable_lock_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / "chart.zip").write_bytes(b"existing")
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("stale\n", encoding="ascii")
            os.chmod(lock, 0o620)
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            package = Package("Stale lock test", "https://example.invalid/chart.zip", "chart.zip")

            with self.assertRaisesRegex(RuntimeError, "chart update lock path has permissions"):
                download_package(package, root)

            self.assertTrue(lock.exists())
            self.assertEqual(lock.read_text(encoding="ascii"), "stale\n")

    def test_stale_download_lock_cleanup_rejects_public_lock_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / "chart.zip").write_bytes(b"existing")
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("stale\n", encoding="ascii")
            os.chmod(lock, 0o644)
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            package = Package("Stale lock test", "https://example.invalid/chart.zip", "chart.zip")

            with self.assertRaisesRegex(RuntimeError, "chart update lock path has permissions 0644"):
                download_package(package, root)

            self.assertTrue(lock.exists())
            self.assertEqual(lock.read_text(encoding="ascii"), "stale\n")

    def test_old_download_lock_with_live_owner_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lock = root / DOWNLOAD_LOCK_NAME
            current_boot_id = "12345678-1234-4234-8234-123456789abc"
            lock.write_text(f"pid=1234 boot_id={current_boot_id} created_at=old\n", encoding="ascii")
            os.chmod(lock, 0o600)
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            original_boot_id = downloader_module._current_boot_id
            original_pid_is_running = downloader_module._pid_is_running
            try:
                downloader_module._current_boot_id = lambda: current_boot_id
                downloader_module._pid_is_running = lambda pid: pid == 1234

                stale = downloader_module._lock_is_stale(lock)
            finally:
                downloader_module._current_boot_id = original_boot_id
                downloader_module._pid_is_running = original_pid_is_running

            self.assertFalse(stale)
            self.assertEqual(lock.read_text(encoding="ascii"), f"pid=1234 boot_id={current_boot_id} created_at=old\n")

    def test_old_download_lock_from_previous_boot_is_stale_even_if_pid_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            lock = Path(tmpdir) / DOWNLOAD_LOCK_NAME
            current_boot_id = "12345678-1234-4234-8234-123456789abc"
            previous_boot_id = "abcdefab-cdef-4abc-8def-abcdefabcdef"
            lock.write_text(f"pid=1234 boot_id={previous_boot_id} created_at=old\n", encoding="ascii")
            os.chmod(lock, 0o600)
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            original_boot_id = downloader_module._current_boot_id
            original_pid_is_running = downloader_module._pid_is_running
            try:
                downloader_module._current_boot_id = lambda: current_boot_id
                downloader_module._pid_is_running = lambda pid: True

                stale = downloader_module._lock_is_stale(lock)
            finally:
                downloader_module._current_boot_id = original_boot_id
                downloader_module._pid_is_running = original_pid_is_running

            self.assertTrue(stale)

    def test_old_download_lock_with_malformed_current_boot_id_keeps_live_owner(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            lock = Path(tmpdir) / DOWNLOAD_LOCK_NAME
            owner_boot_id = "12345678-1234-4234-8234-123456789abc"
            lock.write_text(f"pid=1234 boot_id={owner_boot_id} created_at=old\n", encoding="ascii")
            os.chmod(lock, 0o600)
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            original_boot_id = downloader_module._current_boot_id
            original_pid_is_running = downloader_module._pid_is_running
            try:
                downloader_module._current_boot_id = lambda: "unknown"
                downloader_module._pid_is_running = lambda pid: pid == 1234

                stale = downloader_module._lock_is_stale(lock)
            finally:
                downloader_module._current_boot_id = original_boot_id
                downloader_module._pid_is_running = original_pid_is_running

            self.assertFalse(stale)

    def test_old_download_lock_with_malformed_owner_boot_id_keeps_live_owner(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            lock = Path(tmpdir) / DOWNLOAD_LOCK_NAME
            current_boot_id = "12345678-1234-4234-8234-123456789abc"
            lock.write_text("pid=1234 boot_id=not-a-boot-id created_at=old\n", encoding="ascii")
            os.chmod(lock, 0o600)
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            original_boot_id = downloader_module._current_boot_id
            original_pid_is_running = downloader_module._pid_is_running
            try:
                downloader_module._current_boot_id = lambda: current_boot_id
                downloader_module._pid_is_running = lambda pid: pid == 1234

                stale = downloader_module._lock_is_stale(lock)
            finally:
                downloader_module._current_boot_id = original_boot_id
                downloader_module._pid_is_running = original_pid_is_running

            self.assertFalse(stale)

    def test_download_lock_current_boot_id_reads_no_follow_descriptor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            boot_id = Path(tmpdir) / "boot_id"
            boot_id.write_text("12345678-1234-4234-8234-123456789abc\n", encoding="ascii")
            original_boot_id_path = downloader_module.BOOT_ID_PATH
            downloader_module.BOOT_ID_PATH = boot_id
            try:
                self.assertEqual(downloader_module._current_boot_id(), "12345678-1234-4234-8234-123456789abc")
            finally:
                downloader_module.BOOT_ID_PATH = original_boot_id_path

    def test_download_lock_current_boot_id_rejects_symlinked_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_boot_id = root / "real_boot_id"
            real_boot_id.write_text("12345678-1234-4234-8234-123456789abc\n", encoding="ascii")
            boot_id = root / "boot_id"
            try:
                boot_id.symlink_to(real_boot_id)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "current boot ID path is a symlink"):
                downloader_module._read_current_boot_id_text(boot_id)

    def test_download_lock_current_boot_id_rejects_replaced_path_before_reading(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            boot_id = root / "boot_id"
            boot_id.write_text("12345678-1234-4234-8234-123456789abc\n", encoding="ascii")
            replacement = root / "replacement_boot_id"
            replacement.write_text("abcdefab-cdef-4abc-8def-abcdefabcdef\n", encoding="ascii")
            original_open = downloader_module.os.open

            def replacing_open(path, flags, mode=0o777, *, dir_fd=None):
                if Path(path) == boot_id:
                    os.replace(replacement, boot_id)
                if dir_fd is None:
                    return original_open(path, flags, mode)
                return original_open(path, flags, mode, dir_fd=dir_fd)

            try:
                downloader_module.os.open = replacing_open
                with self.assertRaisesRegex(RuntimeError, "current boot ID path changed before it could be read"):
                    downloader_module._read_current_boot_id_text(boot_id)
            finally:
                downloader_module.os.open = original_open

    def test_download_lock_cleanup_preserves_replaced_lock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lock = root / DOWNLOAD_LOCK_NAME

            with downloader_module._chart_update_lock(root):
                lock.write_text("new owner\n", encoding="ascii")

            self.assertEqual(lock.read_text(encoding="ascii"), "new owner\n")

    def test_download_lock_cleanup_preserves_replaced_lock_with_same_text(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lock = root / DOWNLOAD_LOCK_NAME

            with redirect_stderr(StringIO()) as stderr:
                with downloader_module._chart_update_lock(root):
                    lock_text = lock.read_text(encoding="ascii")
                    replacement = root / "replacement-download.lock"
                    replacement.write_text(lock_text, encoding="ascii")
                    os.chmod(replacement, 0o600)
                    os.replace(replacement, lock)

            self.assertEqual(lock.read_text(encoding="ascii"), lock_text)
            self.assertIn("chart update lock cleanup changed before cleanup", stderr.getvalue())

    def test_download_lock_syncs_create_and_cleanup(self):
        calls = []
        original_fsync = downloader_module.os.fsync
        downloader_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                lock = root / DOWNLOAD_LOCK_NAME

                with downloader_module._chart_update_lock(root):
                    self.assertTrue(lock.exists())
                    self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
                self.assertFalse(lock.exists())
        finally:
            downloader_module.os.fsync = original_fsync

        self.assertGreaterEqual(len(calls), 3)

    def test_download_lock_cleans_up_failed_lock_setup(self):
        original_fchmod = downloader_module.os.fchmod
        def failing_fchmod(fd, mode):
            raise OSError("chmod failed")

        downloader_module.os.fchmod = failing_fchmod
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                lock = root / DOWNLOAD_LOCK_NAME

                with self.assertRaisesRegex(OSError, "chmod failed"):
                    with downloader_module._chart_update_lock(root):
                        pass

                self.assertFalse(lock.exists())
        finally:
            downloader_module.os.fchmod = original_fchmod

    def test_stale_manifest_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            manifest = root / MANIFEST_NAME
            manifest.write_text(
                '{"created_at":"2000-01-01T00:00:00Z","package":{"label":"Old"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )
            result = check_chart_manifest(root, max_age_days=1)
            self.assertFalse(result.ok)
            self.assertIn("days old", result.detail)

    def test_manifest_rejects_timezone_less_created_at(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            manifest = root / MANIFEST_NAME
            manifest.write_text(
                '{"created_at":"2026-07-01T12:00:00","package":{"label":"Test"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, max_age_days=1)

            self.assertFalse(result.ok)
            self.assertIn("manifest has no valid created_at", result.detail)

    def test_manifest_symlink_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_manifest = root / "real-manifest.json"
            real_manifest.write_text(
                '{"created_at":"2000-01-01T00:00:00Z","package":{"label":"Old"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )
            manifest = root / MANIFEST_NAME
            try:
                manifest.symlink_to(real_manifest)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_manifest(root, max_age_days=1)

            self.assertFalse(result.ok)
            self.assertIn("manifest path is a symlink", result.detail)

    def test_manifest_rejects_symlinked_chart_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_charts = root / "real-charts"
            real_charts.mkdir()
            chart_link = root / "charts"
            try:
                chart_link.symlink_to(real_charts, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_manifest(chart_link)

            self.assertFalse(result.ok)
            self.assertIn("chart directory is a symlink", result.detail)

    def test_manifest_rejects_symlinked_chart_directory_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_storage = root / "real-storage"
            charts = real_storage / "charts"
            charts.mkdir(parents=True)
            storage_link = root / "storage-link"
            try:
                storage_link.symlink_to(real_storage, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_manifest(storage_link / "charts")

            self.assertFalse(result.ok)
            self.assertIn("chart directory path contains a symlink", result.detail)
            self.assertIn("storage-link", result.detail)

    def test_manifest_nonregular_path_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / MANIFEST_NAME).mkdir()

            result = check_chart_manifest(root, max_age_days=1)

            self.assertFalse(result.ok)
            self.assertIn("manifest path is not a regular file", result.detail)

    def test_manifest_writable_file_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            manifest = root / MANIFEST_NAME
            manifest.write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"path":"","url":"file:///test.zip","bytes":1,"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            manifest.chmod(0o666)

            result = check_chart_manifest(root, max_age_days=1)

            self.assertFalse(result.ok)
            self.assertIn("manifest path", result.detail)
            self.assertIn("has permissions 0666", result.detail)

    def test_manifest_writable_directory_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            manifest = root / MANIFEST_NAME
            manifest.write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"path":"","url":"file:///test.zip","bytes":1,"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            manifest.chmod(0o600)
            root.chmod(0o777)
            try:
                result = check_chart_manifest(root, max_age_days=1)
            finally:
                root.chmod(0o700)

            self.assertFalse(result.ok)
            self.assertIn("manifest directory", result.detail)
            self.assertIn("has permissions 0777", result.detail)

    def test_read_manifest_rejects_symlinked_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_manifest = root / "real-manifest.json"
            real_manifest.write_text('{"created_at":"2026-01-01T00:00:00Z"}\n', encoding="utf-8")
            manifest = root / MANIFEST_NAME
            try:
                manifest.symlink_to(real_manifest)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "manifest path is a symlink"):
                read_manifest(root)

    def test_read_manifest_rejects_symlinked_manifest_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_dir = root / "real"
            real_dir.mkdir()
            (real_dir / MANIFEST_NAME).write_text('{"created_at":"2026-01-01T00:00:00Z"}\n', encoding="utf-8")
            link_dir = root / "link"
            try:
                link_dir.symlink_to(real_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "manifest directory contains a symlink"):
                read_manifest(link_dir)

    def test_read_manifest_rejects_non_directory_manifest_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            not_directory = root / "charts"
            not_directory.write_text("not a directory", encoding="ascii")

            with self.assertRaisesRegex(RuntimeError, "manifest parent is not a directory"):
                read_manifest(not_directory)

    def test_read_manifest_rejects_writable_manifest_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            manifest = root / MANIFEST_NAME
            manifest.write_text('{"created_at":"2026-01-01T00:00:00Z"}\n', encoding="utf-8")
            manifest.chmod(0o600)
            root.chmod(0o777)
            try:
                with self.assertRaisesRegex(RuntimeError, "manifest directory .* has permissions 0777"):
                    read_manifest(root)
            finally:
                root.chmod(0o700)

    def test_read_manifest_rejects_writable_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            manifest = root / MANIFEST_NAME
            manifest.write_text('{"created_at":"2026-01-01T00:00:00Z"}\n', encoding="utf-8")
            manifest.chmod(0o622)

            with self.assertRaisesRegex(RuntimeError, "manifest path .* has permissions 0622"):
                read_manifest(root)

    def test_read_manifest_rejects_replaced_manifest_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            manifest = root / MANIFEST_NAME
            manifest.write_text('{"created_at":"2026-01-01T00:00:00Z"}\n', encoding="utf-8")
            expected_stat = manifest.stat()
            replacement = root / "replacement-manifest.json"
            replacement.write_text('{"created_at":"2026-02-01T00:00:00Z"}\n', encoding="utf-8")
            replacement.replace(manifest)

            with self.assertRaisesRegex(RuntimeError, "manifest path changed before it could be read"):
                read_manifest(root, expected_stat=expected_stat)

    def test_manifest_without_extracted_cells_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            old_cell = root / "old" / "US5AK3CM.000"
            old_cell.parent.mkdir()
            old_cell.write_text("old", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                '"extract":{"path":"","enc_cell_count":0}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("does not record an extracted chart path", result.detail)

    def test_manifest_with_missing_extract_path_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            missing = root / "AK_ENCs"
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{missing}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("extract path does not exist", result.detail)

    def test_manifest_extract_symlink_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_extract = root / "real-AK-ENCs"
            cell = real_extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            extract_link = root / "AK_ENCs"
            try:
                extract_link.symlink_to(real_extract, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract_link}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("manifest extract path is a symlink", result.detail)

    def test_manifest_extract_path_under_symlinked_parent_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-extract-parent"
            real_extract = real_parent / "AK_ENCs"
            cell = real_extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            link_parent = root / "extract-link"
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            extract = link_parent / "AK_ENCs"
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("manifest extract path contains a symlink", result.detail)
            self.assertIn("extract-link", result.detail)

    def test_manifest_with_missing_recorded_cells_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":2}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("manifest recorded 2 ENC cells but found 1", result.detail)

    def test_manifest_with_extra_unrecorded_cells_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            extra_cell = extract / "US5AK4CM" / "US5AK4CM.000"
            cell.parent.mkdir(parents=True)
            extra_cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            extra_cell.write_text("extra", encoding="ascii")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("manifest recorded 1 ENC cells but found 2", result.detail)

    def test_manifest_writable_enc_cell_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            cell.chmod(0o666)
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("manifest extract file", result.detail)
            self.assertIn("has permissions 0666", result.detail)

    def test_manifest_writable_extract_directory_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            cell.parent.chmod(0o777)
            try:
                (root / MANIFEST_NAME).write_text(
                    '{"created_at":"' + now + '",'
                    '"package":{"label":"Test"},'
                    '"download":{"sha256":"abc"},'
                    f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                    encoding="utf-8",
                )

                result = check_chart_manifest(root)
            finally:
                cell.parent.chmod(0o700)

            self.assertFalse(result.ok)
            self.assertIn("manifest extract directory", result.detail)
            self.assertIn("has permissions 0777", result.detail)

    def test_manifest_extract_path_outside_chart_dir_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            outside = root / "outside" / "AK_ENCs"
            cell = outside / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            charts.mkdir()
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (charts / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{outside}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(charts)

            self.assertFalse(result.ok)
            self.assertIn("outside chart directory", result.detail)

    def test_manifest_package_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="CA")

            self.assertFalse(result.ok)
            self.assertIn("does not match configured CA_ENCs.zip", result.detail)

    def test_manifest_package_url_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip","url":"https://example.invalid/AK_ENCs.zip"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest package URL", result.detail)
            self.assertIn("https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", result.detail)

    def test_manifest_download_url_redirect_with_matching_filename_passes(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://downloads.charts.noaa.gov/cache/AK_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertTrue(result.ok)

    def test_manifest_download_url_non_noaa_redirect_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://example.invalid/cache/AK_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest download URL", result.detail)
            self.assertIn("non-NOAA host", result.detail)

    def test_count_enc_cells_ignores_symlinked_cells(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "outside.000"
            target.write_text("not a trusted chart cell", encoding="ascii")
            cell = root / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            try:
                cell.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            self.assertEqual(downloader_module.count_enc_cells(root / "AK_ENCs"), 0)

    def test_manifest_symlinked_enc_cell_does_not_satisfy_count(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            target = root / "outside.000"
            target.write_text("not a trusted chart cell", encoding="ascii")
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            try:
                cell.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest extract path contains a symlink", result.detail)

    def test_manifest_download_url_mismatched_filename_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://example.invalid/CA_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest download URL", result.detail)
            self.assertIn("does not match package filename", result.detail)
            self.assertIn("non-HTTPS", result.detail)

    def test_manifest_download_url_http_redirect_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"http://downloads.charts.noaa.gov/cache/AK_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest download URL", result.detail)
            self.assertIn("does not match package filename", result.detail)
            self.assertIn("non-HTTPS", result.detail)

    def test_manifest_missing_download_url_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("does not record a download URL", result.detail)

    def test_manifest_fails_when_other_extracted_enc_directory_remains(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            current_cell = extract / "US5AK3CM" / "US5AK3CM.000"
            current_cell.parent.mkdir(parents=True)
            current_cell.write_text("cell", encoding="ascii")
            stale_cell = root / "CA_ENCs" / "US5CA99M" / "US5CA99M.000"
            stale_cell.parent.mkdir(parents=True)
            stale_cell.write_text("old", encoding="ascii")
            (root / "tracks").mkdir()
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("unexpected ENC chart directories", result.detail)
            self.assertIn("CA_ENCs", result.detail)

    def test_manifest_archive_sha_mismatch_fails_when_zip_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"corrupt")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":7,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("SHA-256", result.detail)

    def test_manifest_archive_size_mismatch_fails_when_zip_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            digest = downloader_module.sha256_file(archive)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":99,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("downloaded bytes", result.detail)

    def test_manifest_archive_requires_positive_size_when_zip_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            digest = downloader_module.sha256_file(archive)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":0,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("positive download byte count", result.detail)

    def test_manifest_archive_requires_positive_size_when_zip_not_retained(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":0,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("positive download byte count", result.detail)

    def test_manifest_archive_requires_sha256_when_zip_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":{archive.stat().st_size},"sha256":""}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("download SHA-256", result.detail)

    def test_manifest_archive_requires_sha256_when_zip_not_retained(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":""}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("download SHA-256", result.detail)

    def test_manifest_archive_required_fails_when_zip_missing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("retained download path is missing", result.detail)

    def test_manifest_archive_required_fails_without_download_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip","bytes":5,"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("does not record a retained download path", result.detail)

    def test_manifest_archive_path_outside_chart_dir_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            outside = root / "outside.zip"
            outside.write_bytes(b"chart")
            digest = downloader_module.sha256_file(outside)
            extract = charts / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (charts / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{outside}","bytes":5,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(charts, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("download path is outside chart directory", result.detail)

    def test_manifest_archive_symlink_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_archive = root / "real-AK-ENCs.zip"
            real_archive.write_bytes(b"chart")
            archive_link = root / "AK_ENCs.zip"
            try:
                archive_link.symlink_to(real_archive)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            digest = downloader_module.sha256_file(real_archive)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive_link}","bytes":5,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest download path is a symlink", result.detail)

    def test_manifest_archive_nonregular_path_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.mkdir()
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("manifest download path is not a regular file", result.detail)

    def test_manifest_archive_writable_file_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            digest = downloader_module.sha256_file(archive)
            archive.chmod(0o622)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("manifest download path", result.detail)
            self.assertIn("has permissions 0622", result.detail)

    def test_manifest_archive_rejects_retained_file_that_is_not_zip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"not a zip")
            digest = downloader_module.sha256_file(archive)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":{archive.stat().st_size},"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("retained chart archive is not a valid ZIP", result.detail)

    def test_manifest_archive_rejects_retained_zip_without_enc_cells(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            with zipfile.ZipFile(archive, "w") as zip_handle:
                zip_handle.writestr("README.txt", "not chart data")
            digest = downloader_module.sha256_file(archive)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":{archive.stat().st_size},"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("retained chart archive contains no ENC .000 cells", result.detail)

    def test_manifest_archive_rejects_retained_zip_with_unsafe_member(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            with zipfile.ZipFile(archive, "w") as zip_handle:
                zip_handle.writestr("../evil.000", "bad")
                zip_handle.writestr("US5AK3CM/US5AK3CM.000", "cell")
            digest = downloader_module.sha256_file(archive)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":{archive.stat().st_size},"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("retained chart archive has unsafe member path", result.detail)

    def test_sha256_trusted_file_rejects_writable_archive_before_hashing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            archive = Path(tmpdir) / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            archive.chmod(0o622)

            with self.assertRaisesRegex(RuntimeError, "has permissions 0622"):
                _sha256_trusted_file(archive, label="manifest download path", expected_uid=os.getuid())

    def test_sha256_file_rejects_symlinked_archive_before_hashing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_archive = root / "real-AK-ENCs.zip"
            real_archive.write_bytes(b"chart")
            archive = root / "AK_ENCs.zip"
            try:
                archive.symlink_to(real_archive)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "chart archive path is a symlink"):
                downloader_module.sha256_file(archive)

    def test_sha256_file_rejects_writable_archive_before_hashing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            archive = Path(tmpdir) / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            archive.chmod(0o622)

            try:
                with self.assertRaisesRegex(RuntimeError, "chart download path .* has permissions 0622"):
                    downloader_module.sha256_file(archive)
            finally:
                archive.chmod(0o600)

    def test_sha256_file_rejects_archive_under_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-parent"
            real_parent.mkdir()
            archive = real_parent / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            link_parent = root / "link-parent"
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "chart download path contains a symlink"):
                downloader_module.sha256_file(link_parent / "AK_ENCs.zip")

    def test_manifest_archive_path_under_symlinked_parent_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-archive-parent"
            real_parent.mkdir()
            archive = real_parent / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            digest = downloader_module.sha256_file(archive)
            link_parent = root / "archive-link"
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            archive_path = link_parent / "AK_ENCs.zip"
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive_path}","bytes":5,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest download path contains a symlink", result.detail)
            self.assertIn("archive-link", result.detail)

    def test_chart_package_rejects_update_bundle_as_primary_charts(self):
        result = check_chart_package("updates", "ten-days")
        self.assertFalse(result.ok)
        self.assertIn("not a complete chart set", result.detail)

    def test_chart_package_accepts_state_bundle(self):
        result = check_chart_package("state", "AK")
        self.assertTrue(result.ok)
        self.assertEqual(
            result.data,
            {
                "package": "state",
                "value": "AK",
                "complete_chart_set": True,
                "expected_filename": "AK_ENCs.zip",
                "expected_url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
            },
        )

    def test_chart_package_rejects_unsupported_state_bundle(self):
        result = check_chart_package("state", "ZZ")
        self.assertFalse(result.ok)
        self.assertIn("not a supported NOAA ENC package", result.detail)

    def test_chart_update_debris_fails_for_interrupted_sync_paths(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / ".AK_ENCs.previous").mkdir()
            (root / ".CA_ENCs.abcd.extracting").mkdir()
            (root / "AK_ENCs.zip.part").write_text("partial zip\n", encoding="ascii")
            (root / ".noaa-navionics-manifest.json.abcd.part").write_text("partial manifest\n", encoding="ascii")

            result = check_chart_update_debris(root)

            self.assertFalse(result.ok)
            self.assertIn(".AK_ENCs.previous", result.detail)
            self.assertIn(".CA_ENCs.abcd.extracting", result.detail)
            self.assertIn("AK_ENCs.zip.part", result.detail)
            self.assertIn(".noaa-navionics-manifest.json.abcd.part", result.detail)

    def test_chart_update_debris_rejects_symlinked_chart_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_charts = root / "real-charts"
            real_charts.mkdir()
            chart_link = root / "charts"
            try:
                chart_link.symlink_to(real_charts, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_update_debris(chart_link)

            self.assertFalse(result.ok)
            self.assertIn("chart directory is a symlink", result.detail)

    def test_chart_update_debris_rejects_symlinked_chart_directory_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_storage = root / "real-storage"
            charts = real_storage / "charts"
            charts.mkdir(parents=True)
            storage_link = root / "storage-link"
            try:
                storage_link.symlink_to(real_storage, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_update_debris(storage_link / "charts")

            self.assertFalse(result.ok)
            self.assertIn("chart directory path contains a symlink", result.detail)
            self.assertIn("storage-link", result.detail)

    def test_chart_update_debris_ignores_download_lock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / DOWNLOAD_LOCK_NAME).write_text("locked\n", encoding="ascii")

            result = check_chart_update_debris(root)

            self.assertTrue(result.ok)
            data = result.data or {}
            self.assertEqual(data["configured_path"], str(root))
            self.assertTrue(data["clean"])
            self.assertEqual(data["debris_count"], 0)
            self.assertEqual(data["debris"], [])

    def test_chart_update_debris_allows_retained_manifest_archive(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_update_debris(root)

            self.assertTrue(result.ok)
            data = result.data or {}
            self.assertEqual(data["configured_path"], str(root))
            self.assertTrue(data["clean"])
            self.assertEqual(data["debris_count"], 0)
            self.assertEqual(data["debris"], [])

    def test_chart_update_debris_fails_for_unexpected_top_level_zip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            extra = root / "CA_ENCs.zip"
            archive.write_bytes(b"chart")
            extra.write_bytes(b"stale chart")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_update_debris(root)

            self.assertFalse(result.ok)
            self.assertIn("CA_ENCs.zip", result.detail)
            self.assertNotIn("AK_ENCs.zip", result.detail)

    def test_extract_zip_replaces_existing_directory_after_success(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            destination = root / "AK_ENCs"
            old_cell = destination / "OLD" / "OLD.000"
            old_cell.parent.mkdir(parents=True)
            old_cell.write_text("old", encoding="ascii")

            extracted = extract_zip(archive, destination)

            self.assertEqual(extracted, destination)
            self.assertFalse(old_cell.exists())
            self.assertEqual((destination / "US5AK3CM" / "US5AK3CM.000").read_text(encoding="ascii"), "new")
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))
            self.assertFalse((root / ".AK_ENCs.previous").exists())

    def test_extract_zip_rejects_crc_failure_before_staging(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "cell")
            archive_bytes = archive.read_bytes()
            self.assertIn(b"cell", archive_bytes)
            archive.write_bytes(archive_bytes.replace(b"cell", b"bell", 1))
            destination = root / "AK_ENCs"

            with self.assertRaisesRegex(RuntimeError, "chart ZIP has a failed CRC member"):
                extract_zip(archive, destination)

            self.assertFalse(destination.exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_symlinked_destination(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            real_destination = root / "real-charts"
            real_destination.mkdir()
            destination = root / "AK_ENCs"
            try:
                destination.symlink_to(real_destination, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "chart extraction destination is a symlink"):
                extract_zip(archive, destination)

            self.assertTrue(destination.is_symlink())
            self.assertFalse((real_destination / "US5AK3CM").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_revalidates_destination_before_promotion(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            destination = root / "AK_ENCs"
            real_destination = root / "real-charts"
            real_destination.mkdir()
            original_fsync_tree = downloader_module._fsync_tree

            def swap_destination(path):
                original_fsync_tree(path)
                try:
                    destination.symlink_to(real_destination, target_is_directory=True)
                except OSError as exc:
                    self.skipTest(f"symlinks unavailable: {exc}")

            with patch("noaa_navionics.downloader._fsync_tree", side_effect=swap_destination):
                with self.assertRaisesRegex(RuntimeError, "chart extraction destination is a symlink before promotion"):
                    extract_zip(archive, destination)

            self.assertTrue(destination.is_symlink())
            self.assertFalse((real_destination / "US5AK3CM").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_symlinked_destination_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            real_parent = root / "real-parent"
            real_parent.mkdir()
            link_parent = root / "link-parent"
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            destination = link_parent / "AK_ENCs"

            with self.assertRaisesRegex(RuntimeError, "chart output path contains a symlink"):
                extract_zip(archive, destination)

            self.assertFalse((real_parent / "AK_ENCs").exists())
            self.assertFalse(list(real_parent.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_non_directory_destination(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            destination = root / "AK_ENCs"
            destination.write_text("not a directory\n", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "chart extraction destination is not a directory"):
                extract_zip(archive, destination)

            self.assertEqual(destination.read_text(encoding="utf-8"), "not a directory\n")
            self.assertFalse((root / ".AK_ENCs.previous").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_symlinked_previous_debris_without_promoting_it(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            target = root / "previous-target"
            target.mkdir()
            previous = root / ".AK_ENCs.previous"
            try:
                previous.symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "previous chart extraction path is a symlink before cleanup"):
                extract_zip(archive, root / "AK_ENCs")

            self.assertTrue(previous.is_symlink())
            self.assertTrue(target.is_dir())
            self.assertFalse((root / "AK_ENCs").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_previous_debris_with_symlinked_child(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            previous = root / ".AK_ENCs.previous"
            previous.mkdir()
            target = root / "previous-child-target"
            target.mkdir()
            try:
                (previous / "child-link").symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "previous chart extraction path is a symlink before cleanup"):
                extract_zip(archive, root / "AK_ENCs")

            self.assertTrue((previous / "child-link").is_symlink())
            self.assertTrue(target.is_dir())
            self.assertFalse((root / "AK_ENCs").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_replaced_previous_debris_before_cleanup(self):
        original_validate = downloader_module._validate_removable_chart_tree
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                archive = root / "charts.zip"
                with zipfile.ZipFile(archive, "w") as zip_file:
                    zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
                previous = root / ".AK_ENCs.previous"
                previous.mkdir()
                (previous / "old.000").write_text("old", encoding="ascii")

                def replacing_validate(path, *, label):
                    result = original_validate(path, label=label)
                    if Path(path) == previous:
                        swapped = root / ".AK_ENCs.previous-swapped"
                        previous.rename(swapped)
                        previous.mkdir()
                        (previous / "replacement.000").write_text("replacement", encoding="ascii")
                    return result

                downloader_module._validate_removable_chart_tree = replacing_validate
                with self.assertRaisesRegex(RuntimeError, "previous chart extraction changed before cleanup"):
                    extract_zip(archive, root / "AK_ENCs")

                self.assertTrue(previous.is_dir())
                self.assertEqual((previous / "replacement.000").read_text(encoding="ascii"), "replacement")
                self.assertFalse((root / "AK_ENCs").exists())
                self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))
        finally:
            downloader_module._validate_removable_chart_tree = original_validate

    def test_remove_path_rejects_replaced_regular_file_before_unlink(self):
        original_validate = downloader_module._validate_removable_chart_tree
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                target = root / "stale.zip"
                target.write_text("old", encoding="ascii")
                target.chmod(0o600)
                replacement = root / "replacement.zip"
                replacement.write_text("replacement", encoding="ascii")
                replacement.chmod(0o600)

                def replacing_validate(path, *, label):
                    result = original_validate(path, label=label)
                    os.replace(replacement, path)
                    return result

                downloader_module._validate_removable_chart_tree = replacing_validate
                with self.assertRaisesRegex(RuntimeError, "chart update path changed before cleanup"):
                    downloader_module._remove_path(target)

                self.assertTrue(target.exists())
                self.assertEqual(target.read_text(encoding="ascii"), "replacement")
        finally:
            downloader_module._validate_removable_chart_tree = original_validate

    def test_extract_zip_cleanup_requires_symlink_safe_rmtree(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            previous = root / ".AK_ENCs.previous"
            previous.mkdir()
            (previous / "old.000").write_text("old", encoding="ascii")
            original = getattr(downloader_module.shutil.rmtree, "avoids_symlink_attacks", None)
            try:
                downloader_module.shutil.rmtree.avoids_symlink_attacks = False
                with self.assertRaisesRegex(RuntimeError, "shutil.rmtree is not symlink-attack resistant"):
                    extract_zip(archive, root / "AK_ENCs")
            finally:
                if original is None:
                    try:
                        del downloader_module.shutil.rmtree.avoids_symlink_attacks
                    except AttributeError:
                        pass
                else:
                    downloader_module.shutil.rmtree.avoids_symlink_attacks = original

            self.assertTrue(previous.is_dir())
            self.assertEqual((previous / "old.000").read_text(encoding="ascii"), "old")
            self.assertFalse((root / "AK_ENCs").exists())

    def test_extract_zip_failed_staging_cleanup_requires_symlink_safe_rmtree(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "empty-charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("README.txt", "no chart cells")
            destination = root / "AK_ENCs"
            original = getattr(downloader_module.shutil.rmtree, "avoids_symlink_attacks", None)
            try:
                downloader_module.shutil.rmtree.avoids_symlink_attacks = False
                with self.assertRaisesRegex(RuntimeError, "shutil.rmtree is not symlink-attack resistant"):
                    extract_zip(archive, destination)
            finally:
                if original is None:
                    try:
                        del downloader_module.shutil.rmtree.avoids_symlink_attacks
                    except AttributeError:
                        pass
                else:
                    downloader_module.shutil.rmtree.avoids_symlink_attacks = original

            self.assertFalse(destination.exists())
            leftovers = list(root.glob(".AK_ENCs.*.extracting"))
            self.assertEqual(len(leftovers), 1)
            self.assertEqual((leftovers[0] / "README.txt").read_text(encoding="ascii"), "no chart cells")

    def test_extract_zip_syncs_extracted_tree_and_parent_directory(self):
        calls = []
        original_fsync = downloader_module.os.fsync
        downloader_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                archive = root / "charts.zip"
                with zipfile.ZipFile(archive, "w") as zip_file:
                    zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")

                extract_zip(archive, root / "AK_ENCs")
        finally:
            downloader_module.os.fsync = original_fsync

        self.assertGreaterEqual(len(calls), 3)

    def test_extract_zip_failure_preserves_existing_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "bad.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("../evil.000", "bad")
            destination = root / "AK_ENCs"
            old_cell = destination / "US5AK3CM" / "US5AK3CM.000"
            old_cell.parent.mkdir(parents=True)
            old_cell.write_text("old", encoding="ascii")

            with self.assertRaises(RuntimeError):
                extract_zip(archive, destination)

            self.assertEqual(old_cell.read_text(encoding="ascii"), "old")
            self.assertFalse((root / "evil.000").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_without_enc_cells_preserves_existing_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "empty-charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("README.txt", "no chart cells")
            destination = root / "AK_ENCs"
            old_cell = destination / "US5AK3CM" / "US5AK3CM.000"
            old_cell.parent.mkdir(parents=True)
            old_cell.write_text("old", encoding="ascii")

            with self.assertRaisesRegex(RuntimeError, "no ENC"):
                extract_zip(archive, destination)

            self.assertEqual(old_cell.read_text(encoding="ascii"), "old")
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))


class StatusReportTests(unittest.TestCase):
    def test_boot_id_rejects_malformed_values(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            boot_id = Path(tmpdir) / "boot_id"
            original_boot_id_path = report_module.BOOT_ID_PATH
            report_module.BOOT_ID_PATH = boot_id
            try:
                boot_id.write_text("not-a-boot-id\n", encoding="ascii")
                self.assertEqual(report_module._boot_id(), "unknown")

                boot_id.write_text("12345678-1234-4234-8234-123456789abc\n", encoding="ascii")
                self.assertEqual(report_module._boot_id(), "12345678-1234-4234-8234-123456789abc")
            finally:
                report_module.BOOT_ID_PATH = original_boot_id_path

    def test_boot_id_rejects_symlinked_path(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            real_boot_id = root / "real_boot_id"
            real_boot_id.write_text("12345678-1234-4234-8234-123456789abc\n", encoding="ascii")
            boot_id = root / "boot_id"
            try:
                boot_id.symlink_to(real_boot_id)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            original_boot_id_path = report_module.BOOT_ID_PATH
            report_module.BOOT_ID_PATH = boot_id
            try:
                self.assertEqual(report_module._boot_id(), "unknown")
            finally:
                report_module.BOOT_ID_PATH = original_boot_id_path

    def test_boot_id_rejects_replaced_path_before_reading(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            boot_id = root / "boot_id"
            boot_id.write_text("12345678-1234-4234-8234-123456789abc\n", encoding="ascii")
            replacement = root / "replacement_boot_id"
            replacement.write_text("abcdefab-cdef-4abc-8def-abcdefabcdef\n", encoding="ascii")
            original_open = report_module.os.open

            def replacing_open(path, flags, mode=0o777, *, dir_fd=None):
                if Path(path) == boot_id:
                    os.replace(replacement, boot_id)
                if dir_fd is None:
                    return original_open(path, flags, mode)
                return original_open(path, flags, mode, dir_fd=dir_fd)

            try:
                report_module.os.open = replacing_open
                with self.assertRaisesRegex(RuntimeError, "boot ID path changed before it could be read"):
                    report_module._read_boot_id_text(boot_id)
            finally:
                report_module.os.open = original_open

    def test_parse_proc_uptime_seconds_requires_finite_non_negative_value(self):
        self.assertEqual(_parse_proc_uptime_seconds("123.45 678.90\n"), 123.45)
        for value in ("nan 0\n", "inf 0\n", "-1 0\n", "not-a-number 0\n", "\n"):
            with self.subTest(value=value):
                with self.assertRaises((ValueError, IndexError)):
                    _parse_proc_uptime_seconds(value)

    def test_current_boot_epoch_reads_proc_uptime_with_no_follow_descriptor(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            uptime = Path(tmpdir) / "uptime"
            uptime.write_text("12.5 100.0\n", encoding="ascii")
            original_uptime_path = report_module.PROC_UPTIME_PATH
            original_time = report_module.time.time
            report_module.PROC_UPTIME_PATH = uptime
            report_module.time.time = lambda: 100.0
            try:
                self.assertEqual(report_module._current_boot_epoch(), 87.5)
            finally:
                report_module.PROC_UPTIME_PATH = original_uptime_path
                report_module.time.time = original_time

    def test_proc_uptime_reader_rejects_symlinked_path(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            real_uptime = root / "real_uptime"
            real_uptime.write_text("12.5 100.0\n", encoding="ascii")
            uptime = root / "uptime"
            try:
                uptime.symlink_to(real_uptime)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "proc uptime path is a symlink"):
                report_module._read_proc_uptime_text(uptime)

    def test_proc_uptime_reader_rejects_replaced_path_before_reading(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            uptime = root / "uptime"
            uptime.write_text("12.5 100.0\n", encoding="ascii")
            replacement = root / "replacement_uptime"
            replacement.write_text("99.0 100.0\n", encoding="ascii")
            original_open = report_module.os.open

            def replacing_open(path, flags, mode=0o777, *, dir_fd=None):
                if Path(path) == uptime:
                    os.replace(replacement, uptime)
                if dir_fd is None:
                    return original_open(path, flags, mode)
                return original_open(path, flags, mode, dir_fd=dir_fd)

            try:
                report_module.os.open = replacing_open
                with self.assertRaisesRegex(RuntimeError, "proc uptime path changed before it could be read"):
                    report_module._read_proc_uptime_text(uptime)
            finally:
                report_module.os.open = original_open

    def test_status_report_queries_user_service_hardening_properties(self):
        for unit in (
            "noaa-navionics.service",
            "noaa-navionics-track.service",
            "noaa-navionics-preflight.service",
        ):
            with self.subTest(unit=unit):
                self.assertIn("UMask", report_module.USER_UNIT_PROPERTIES[unit])
                self.assertIn("ProtectSystem", report_module.USER_UNIT_PROPERTIES[unit])
                self.assertIn("LockPersonality", report_module.USER_UNIT_PROPERTIES[unit])
                self.assertIn("RestrictSUIDSGID", report_module.USER_UNIT_PROPERTIES[unit])
                self.assertIn("MemoryDenyWriteExecute", report_module.USER_UNIT_PROPERTIES[unit])
                self.assertIn("RestrictRealtime", report_module.USER_UNIT_PROPERTIES[unit])
                self.assertIn("SystemCallArchitectures", report_module.USER_UNIT_PROPERTIES[unit])

    def test_service_summary_rejects_user_owned_systemctl_on_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "systemctl"
            fake.write_text("#!/bin/sh\necho active\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                summary = report_module._service_summary()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(summary["available"])
        self.assertIn("Systemctl command directory is not a trusted system directory", str(summary["detail"]))

    def test_user_summary_rejects_user_owned_loginctl_on_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "loginctl"
            fake.write_text("#!/bin/sh\necho Linger=yes\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_user = os.environ.get("USER")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                os.environ["USER"] = "pi"
                health_module._is_raspberry_pi = lambda: True
                summary = report_module._user_summary()
            finally:
                os.environ["PATH"] = original_path
                if original_user is None:
                    os.environ.pop("USER", None)
                else:
                    os.environ["USER"] = original_user
                health_module._is_raspberry_pi = original_is_pi

        self.assertIn("Loginctl command directory is not a trusted system directory", str(summary["error"]))

    def test_build_and_write_status_report(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            cell = charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            archive = charts / "AK_ENCs.zip"
            archive.write_bytes(b"x" * 123)
            archive.chmod(0o640)
            manifest = charts / MANIFEST_NAME
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            manifest.write_text(
                '{"created_at":"' + now + '",'
                '"created_at_source":"download",'
                '"package":{"label":"Test","filename":"AK_ENCs.zip","url":"file:///test.zip"},'
                f'"download":{{"path":"{archive}","url":"file:///test.zip",'
                '"bytes":123,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{cell.parent}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            sample = root / "sample.nmea"
            gps_sample_time = (datetime.now(timezone.utc) - timedelta(seconds=5)).strftime("%H%M%S")
            sample.write_text(
                f"$GPGGA,{gps_sample_time},4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,\n",
                encoding="ascii",
            )
            track_time = datetime.now(timezone.utc)
            with GPXTrackLogger(charts / "tracks" / "track-20260629.gpx") as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=track_time, satellites=8, hdop=1.2))
            config = root / "config.ini"
            config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {charts}\n"
                "max_age_days = 30\n"
                "min_free_gb = 3.5\n"
                "\n"
                "[gps]\n"
                "mode = gpsd\n"
                "\n"
                "[tracking]\n"
                f"output = {charts}\n"
                "\n"
                "[anchor]\n"
                "radius_meters = 65\n",
                encoding="utf-8",
            )

            revision = root / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            boot_id = root / "boot_id"
            boot_id.write_text("12345678-1234-4234-8234-123456789abc\n", encoding="ascii")
            launcher_env = root / "launcher.env"
            launcher_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=10\n", encoding="ascii")
            launcher_env.chmod(0o600)
            opencpn_config = root / "opencpn.conf"
            configure_chart_directory(charts, config_path=opencpn_config)
            configure_gpsd_connection(config_path=opencpn_config)
            autostart = root / "noaa-navionics-chartplotter.desktop"
            autostart.write_text(
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=NOAA Navionics Chartplotter\n"
                "Exec=sh -lc \"$HOME/.local/bin/noaa-navionics-start-chartplotter\"\n"
                "Terminal=false\n"
                "X-GNOME-Autostart-enabled=true\n",
                encoding="utf-8",
            )
            autostart.chmod(0o644)
            lightdm_autologin = root / "50-noaa-navionics-autologin.conf"
            lightdm_autologin.write_text(
                "[Seat:*]\n"
                f"autologin-user={os.environ.get('USER', '')}\n"
                "autologin-user-timeout=0\n"
                "autologin-session=missing-test-session\n",
                encoding="utf-8",
            )
            lightdm_autologin.chmod(0o644)
            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            original_boot_id_path = report_module.BOOT_ID_PATH
            original_launcher_env_path = report_module.DEFAULT_LAUNCHER_ENV_PATH
            original_opencpn_config_path = opencpn_module.DEFAULT_OPENCPN_CONFIG_PATH
            original_flatpak_opencpn_config_path = opencpn_module.FLATPAK_OPENCPN_CONFIG_PATH
            original_autostart_path = report_module.DEFAULT_AUTOSTART_PATH
            original_lightdm_autologin_path = report_module.DEFAULT_LIGHTDM_AUTOLOGIN_PATH
            original_systemctl_system = report_module._systemctl_system
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(revision)
            report_module.BOOT_ID_PATH = boot_id
            report_module.DEFAULT_LAUNCHER_ENV_PATH = launcher_env
            report_module.DEFAULT_AUTOSTART_PATH = autostart
            report_module.DEFAULT_LIGHTDM_AUTOLOGIN_PATH = lightdm_autologin
            report_module._systemctl_system = lambda args: {
                ("get-default",): "graphical.target",
                ("is-enabled", "lightdm.service"): "enabled",
                ("is-active", "lightdm.service"): "inactive",
            }.get(tuple(args), "unknown")
            opencpn_module.DEFAULT_OPENCPN_CONFIG_PATH = opencpn_config
            opencpn_module.FLATPAK_OPENCPN_CONFIG_PATH = root / "missing-flatpak-opencpn.conf"
            try:
                report = build_status_report(config_path=config, gps_sample=sample)
            finally:
                report_module.BOOT_ID_PATH = original_boot_id_path
                report_module.DEFAULT_LAUNCHER_ENV_PATH = original_launcher_env_path
                report_module.DEFAULT_AUTOSTART_PATH = original_autostart_path
                report_module.DEFAULT_LIGHTDM_AUTOLOGIN_PATH = original_lightdm_autologin_path
                report_module._systemctl_system = original_systemctl_system
                opencpn_module.DEFAULT_OPENCPN_CONFIG_PATH = original_opencpn_config_path
                opencpn_module.FLATPAK_OPENCPN_CONFIG_PATH = original_flatpak_opencpn_config_path
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path
            self.assertIn("checks", report)
            self.assertIn("services", report)
            self.assertIn("system_services", report)
            self.assertIn("unit_files", report)
            self.assertIn("user", report)
            self.assertIn("launcher_settings", report)
            self.assertIn("opencpn_config", report)
            self.assertIn("desktop", report)
            self.assertIn("track_log", report)
            self.assertIn("gps_fix", report)
            self.assertIn("service_checks", report)
            self.assertEqual(report["app"]["source_revision"], "abc123")
            self.assertEqual(report["app"]["source_revision_path"], str(revision))
            self.assertEqual(report["app"]["source_revision_path_is_symlink"], False)
            self.assertEqual(report["app"]["source_revision_directory_is_symlink"], False)
            self.assertEqual(report["app"]["source_revision_symlink_component"], "")
            self.assertEqual(report["app"]["source_revision_directory_uid"], os.getuid())
            self.assertEqual(
                report["app"]["source_revision_directory_mode"],
                f"{revision.parent.stat().st_mode & 0o777:04o}",
            )
            self.assertEqual(report["config"]["extract"], True)
            self.assertEqual(report["config"]["keep_zip"], True)
            self.assertEqual(report["config"]["force"], True)
            self.assertEqual(report["config"]["min_free_gb"], 3.5)
            self.assertEqual(report["config"]["anchor_radius_meters"], 65.0)
            gps_check = next(check for check in report["checks"] if check["name"] == "GPS")
            self.assertEqual(gps_check["data"]["latitude"], 48.1173)
            self.assertEqual(gps_check["data"]["longitude"], 11.516666666666667)
            self.assertEqual(gps_check["data"]["satellites"], 8)
            self.assertEqual(gps_check["data"]["hdop"], 0.9)
            self.assertEqual(gps_check["data"]["altitude_m"], 545.4)
            self.assertEqual(report["gps_fix"]["source"], "GPS")
            self.assertEqual(report["gps_fix"]["latitude"], 48.1173)
            self.assertEqual(report["gps_fix"]["longitude"], 11.516666666666667)
            self.assertEqual(report["gps_fix"]["satellites"], 8)
            self.assertEqual(report["gps_fix"]["hdop"], 0.9)
            self.assertIsInstance(report["gps_fix"]["age_seconds"], float)
            self.assertGreaterEqual(report["gps_fix"]["age_seconds"], 0.0)
            self.assertEqual(report["host"]["boot_id"], "12345678-1234-4234-8234-123456789abc")
            self.assertEqual(report["launcher_settings"]["path"], str(launcher_env))
            self.assertEqual(report["launcher_settings"]["is_symlink"], False)
            self.assertEqual(report["launcher_settings"]["directory_is_symlink"], False)
            self.assertEqual(report["launcher_settings"]["launcher_settings_symlink_component"], "")
            self.assertEqual(report["launcher_settings"]["mode"], "0600")
            self.assertEqual(report["launcher_settings"]["values"]["NOAA_NAVIONICS_GPS_SECONDS"], "10")
            self.assertEqual(report["opencpn_config"]["path"], str(opencpn_config))
            self.assertEqual(report["opencpn_config"]["exists"], True)
            self.assertEqual(report["opencpn_config"]["is_symlink"], False)
            self.assertEqual(report["opencpn_config"]["directory_is_symlink"], False)
            self.assertEqual(report["opencpn_config"]["config_symlink_component"], "")
            self.assertEqual(report["opencpn_config"]["uid"], os.getuid())
            self.assertEqual(report["opencpn_config"]["mode"], "0600")
            self.assertEqual(report["opencpn_config"]["chart_directories"], [str(charts.resolve())])
            self.assertTrue(report["opencpn_config"]["data_connections"])
            self.assertEqual(report["desktop"]["autostart"]["path"], str(autostart))
            self.assertEqual(report["desktop"]["autostart"]["is_symlink"], False)
            self.assertEqual(report["desktop"]["autostart"]["directory_is_symlink"], False)
            self.assertEqual(report["desktop"]["autostart"]["path_symlink_component"], "")
            self.assertEqual(report["desktop"]["autostart"]["uid"], os.getuid())
            self.assertEqual(report["desktop"]["autostart"]["mode"], "0644")
            self.assertEqual(report["desktop"]["autostart"]["values"]["Exec"], 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"')
            self.assertEqual(report["desktop"]["lightdm_autologin"]["path"], str(lightdm_autologin))
            self.assertEqual(report["desktop"]["lightdm_autologin"]["is_symlink"], False)
            self.assertEqual(report["desktop"]["lightdm_autologin"]["directory_is_symlink"], False)
            self.assertEqual(report["desktop"]["lightdm_autologin"]["path_symlink_component"], "")
            self.assertEqual(report["desktop"]["lightdm_autologin"]["uid"], os.getuid())
            self.assertEqual(report["desktop"]["lightdm_autologin"]["mode"], "0644")
            self.assertEqual(report["desktop"]["lightdm_autologin"]["values"]["autologin-user-timeout"], "0")
            self.assertEqual(report["desktop"]["graphical_target"], "graphical.target")
            self.assertEqual(report["desktop"]["lightdm_enabled"], "enabled")
            self.assertEqual(report["track_log"]["track_output"], str(charts))
            self.assertEqual(report["track_log"]["track_output_is_symlink"], False)
            self.assertEqual(report["track_log"]["tracks_dir"], str(charts / "tracks"))
            self.assertEqual(report["manifest"]["path"], str(manifest))
            self.assertEqual(report["manifest"]["exists"], True)
            self.assertEqual(report["manifest"]["is_symlink"], False)
            self.assertEqual(report["manifest"]["directory_is_symlink"], False)
            self.assertEqual(report["manifest"]["chart_storage_symlink_component"], "")
            self.assertEqual(report["manifest"]["manifest_symlink_component"], "")
            self.assertEqual(report["manifest"]["directory_uid"], os.getuid())
            self.assertEqual(report["manifest"]["directory_mode"], f"{manifest.parent.stat().st_mode & 0o777:04o}")
            self.assertEqual(report["manifest"]["uid"], os.getuid())
            self.assertEqual(report["manifest"]["mode"], "0644")
            self.assertEqual(report["manifest"]["created_at"], now)
            self.assertEqual(report["manifest"]["created_at_source"], "download")
            self.assertEqual(report["manifest"]["package"], "Test")
            self.assertEqual(report["manifest"]["package_filename"], "AK_ENCs.zip")
            self.assertEqual(report["manifest"]["url"], "file:///test.zip")
            self.assertEqual(report["manifest"]["download_path"], str(charts / "AK_ENCs.zip"))
            self.assertEqual(report["manifest"]["download_path_exists"], True)
            self.assertEqual(report["manifest"]["download_path_is_symlink"], False)
            self.assertEqual(report["manifest"]["download_path_symlink_component"], "")
            self.assertEqual(report["manifest"]["download_path_uid"], os.getuid())
            self.assertEqual(report["manifest"]["download_path_mode"], "0640")
            self.assertEqual(report["manifest"]["download_url"], "file:///test.zip")
            self.assertEqual(report["manifest"]["download_skipped"], False)
            self.assertEqual(report["manifest"]["download_bytes"], 123)
            self.assertEqual(report["manifest"]["sha256"], "abc")
            self.assertEqual(report["manifest"]["extract_path"], str(cell.parent))
            self.assertEqual(report["manifest"]["extract_path_is_symlink"], False)
            self.assertEqual(report["manifest"]["extract_path_symlink_component"], "")
            self.assertEqual(report["manifest"]["enc_cell_count"], 1)
            self.assertEqual(report["manifest"]["actual_enc_cell_count"], 1)
            self.assertFalse(report["ok"])
            text = format_status_text(report)
            self.assertIn("Ready: no", text)
            self.assertIn("Anchor radius: 65.0 m", text)
            self.assertIn("GPS fix: GPS ok; 48.117300, 11.516667; ", text)
            self.assertIn("; age ", text)
            self.assertIn("Boot ID: 12345678-1234-4234-8234-123456789abc", text)
            self.assertIn("revision abc123", text)
            self.assertIn("source_revision_path_is_symlink=False", text)
            self.assertIn("source_revision_directory_is_symlink=False", text)
            self.assertIn("source_revision_symlink_component=", text)
            self.assertIn("actual_enc_cell_count: 1", text)
            self.assertIn("OpenCPN Config:", text)
            self.assertIn(f"path={opencpn_config}", text)
            self.assertIn("is_symlink=False", text)
            self.assertIn("directory_is_symlink=False", text)
            self.assertIn("config_symlink_component=", text)
            self.assertIn(f"uid={os.getuid()} mode=0600", text)
            self.assertIn("Desktop Startup:", text)
            self.assertIn(f"autostart={autostart}", text)
            self.assertIn("is_symlink=False", text)
            self.assertIn("path_symlink_component=", text)
            self.assertIn(f"uid={os.getuid()} mode=0644", text)
            self.assertIn("created_at_source: download", text)
            self.assertIn("is_symlink: False", text)
            self.assertIn("directory_is_symlink: False", text)
            self.assertIn("chart_storage_symlink_component: ", text)
            self.assertIn("manifest_symlink_component: ", text)
            self.assertIn(f"uid: {os.getuid()}", text)
            self.assertIn("mode: 0644", text)
            self.assertIn("package_filename: AK_ENCs.zip", text)
            self.assertIn("url: file:///test.zip", text)
            self.assertIn("download_path_exists: True", text)
            self.assertIn("download_path_is_symlink: False", text)
            self.assertIn("download_path_symlink_component: ", text)
            self.assertIn(f"download_path_uid: {os.getuid()}", text)
            self.assertIn("download_path_mode: 0640", text)
            self.assertIn("download_url: file:///test.zip", text)
            self.assertIn("download_skipped: False", text)
            self.assertIn("download_bytes: 123", text)
            self.assertIn(f"extract_path: {cell.parent}", text)
            self.assertIn("extract_path_is_symlink: False", text)
            self.assertIn("extract_path_symlink_component: ", text)
            self.assertIn("Service Checks:", text)
            self.assertIn("System Services:", text)
            self.assertIn("User:", text)
            self.assertIn("User Unit Files:", text)
            self.assertIn("Launcher Settings:", text)
            self.assertIn("is_symlink=False", text)
            self.assertIn("launcher_settings_symlink_component=", text)
            self.assertIn("Track Log:", text)
            self.assertIn(f"track_output={charts}", text)
            self.assertIn("track_output_is_symlink=False", text)
            self.assertIn("track_storage_symlink_component=", text)
            output = root / "status.json"
            write_status_report(report, output)
            self.assertTrue(output.exists())
            self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_gps_fix_summary_preserves_future_timestamp_age(self):
        now = datetime(2026, 6, 30, 12, 0, 0, tzinfo=timezone.utc)
        future = now + timedelta(seconds=45)
        check = CheckResult(
            "GPSD",
            True,
            "future test fix",
            {
                "timestamp": future.isoformat().replace("+00:00", "Z"),
                "latitude": 61.0,
                "longitude": -149.0,
                "satellites": 8,
                "hdop": 1.2,
            },
        )

        summary = _gps_fix_summary([check], now=now)

        self.assertEqual(summary["source"], "GPSD")
        self.assertEqual(summary["age_seconds"], -45.0)

    def test_gps_fix_summary_rejects_timezone_less_current_time(self):
        check = CheckResult(
            "GPSD",
            True,
            "fix",
            {
                "timestamp": "2026-07-01T12:00:00Z",
                "latitude": 61.0,
                "longitude": -149.0,
                "satellites": 8,
                "hdop": 1.2,
            },
        )

        with self.assertRaisesRegex(ValueError, "current time must include a timezone"):
            _gps_fix_summary([check], now=datetime(2026, 7, 1, 12, 0, 0))

    def test_status_text_rejects_incomplete_ready_report(self):
        report = {
            "ok": True,
            "generated_at": fresh_status_timestamp(),
            "host": {"boot_id": "12345678-1234-4234-8234-123456789abc"},
            "checks": [{"name": "GPS", "ok": True, "detail": "fix"}],
            "service_checks": [{"name": "Track Log", "ok": True, "detail": "recent point"}],
        }

        text = format_status_text(report)
        failures = status_report_validation_failures(report)

        self.assertFalse(status_report_is_ready(report))
        self.assertTrue(failures)
        self.assertIn("Ready: no", text)
        self.assertIn("status report is missing this readiness check", text)

    def test_status_text_rejects_malformed_ready_report(self):
        report = {
            "ok": True,
            "generated_at": fresh_status_timestamp(),
            "host": {"boot_id": "12345678-1234-4234-8234-123456789abc"},
            "checks": [{"name": "GPSD", "ok": True, "detail": "fix"}, "bad-row"],
            "service_checks": [{"name": name, "ok": True, "detail": "ok"} for name in sorted(report_module.CORE_SERVICE_CHECKS | report_module.GPSD_SERVICE_CHECKS)],
        }

        text = format_status_text(report)

        self.assertFalse(status_report_is_ready(report))
        self.assertIn("Ready: no", text)
        self.assertIn("status report has malformed checks row", text)

    def test_status_report_ready_rejects_unnamed_or_duplicate_rows(self):
        cases = [
            ("checks", {"ok": True, "detail": "missing name"}, "status report has unnamed readiness check"),
            (
                "checks",
                {"name": "Python", "ok": True, "detail": "duplicate"},
                "status report has duplicate readiness check: Python",
            ),
            ("service_checks", {"ok": True, "detail": "missing name"}, "status report has unnamed service check"),
            (
                "service_checks",
                {"name": "Track Log", "ok": True, "detail": "duplicate"},
                "status report has duplicate service check: Track Log",
            ),
        ]
        for section, row, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report()
                report[section].append(row)

                failures = status_report_validation_failures(report)

                self.assertFalse(status_report_is_ready(report))
                self.assertTrue(any(expected in failure.detail for failure in failures))

    def test_status_report_ready_requires_boolean_ok(self):
        missing = object()
        cases = [
            ("missing", missing),
            ("string", "yes"),
            ("integer", 1),
            ("none", None),
        ]
        for label, value in cases:
            with self.subTest(label=label):
                report = complete_status_gui_report()
                if value is missing:
                    del report["ok"]
                else:
                    report["ok"] = value

                failures = status_report_validation_failures(report)

                self.assertFalse(status_report_is_ready(report))
                self.assertTrue(
                    any("status report top-level ok is not boolean" in failure.detail for failure in failures)
                )

        report = complete_status_gui_report(ok=False)
        failures = status_report_validation_failures(report)

        self.assertFalse(status_report_is_ready(report))
        self.assertFalse(any("status report top-level ok is not boolean" in failure.detail for failure in failures))

    def test_status_report_ready_requires_boolean_row_ok_values(self):
        cases = [
            ("checks", "Python", "status report Python ok is not boolean"),
            ("service_checks", "Track Log", "status report Track Log ok is not boolean"),
        ]
        for section, name, expected in cases:
            with self.subTest(section=section, name=name):
                report = complete_status_gui_report()
                for row in report[section]:
                    if row["name"] == name:
                        row["ok"] = "yes"
                        break

                failures = status_report_validation_failures(report)
                text = format_status_text(report)

                self.assertFalse(status_report_is_ready(report))
                self.assertTrue(any(expected in failure.detail for failure in failures))
                self.assertIn(f"FAIL {name}", text)

    def test_status_report_validation_does_not_trust_truthy_row_ok_for_structured_evidence(self):
        cases = [
            (
                "Python",
                "status report Python ok is not boolean",
                "status report Python check has no structured data",
            ),
            (
                "GPSD",
                "status report GPSD ok is not boolean",
                "status report GPSD check has no structured fix data",
            ),
            (
                "GPSD Config",
                "status report GPSD Config ok is not boolean",
                "status report GPSD Config check has no structured data",
            ),
        ]
        for name, expected, unexpected in cases:
            with self.subTest(name=name):
                report = complete_status_gui_report()
                for row in report["checks"]:
                    if row["name"] == name:
                        row["ok"] = "yes"
                        row.pop("data", None)
                        break

                failures = status_report_validation_failures(report)
                details = [failure.detail for failure in failures]

                self.assertIn(expected, details)
                self.assertNotIn(unexpected, details)

    def test_status_report_ready_requires_fresh_generated_at(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        report = complete_status_gui_report(
            generated_at=now.isoformat().replace("+00:00", "Z"),
        )

        self.assertTrue(status_report_is_ready(report, now=now))
        self.assertFalse(status_report_validation_failures(report, now=now))

        report["generated_at"] = (now - timedelta(seconds=601)).isoformat().replace("+00:00", "Z")
        failures = status_report_validation_failures(report, now=now)
        self.assertFalse(status_report_is_ready(report, now=now))
        self.assertEqual(failures[0].name, "Status Report")
        self.assertIn("stale", failures[0].detail)

    def test_status_report_ready_rejects_future_generated_at(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        report = complete_status_gui_report(
            generated_at=(now + timedelta(seconds=31)).isoformat().replace("+00:00", "Z"),
        )

        failures = status_report_validation_failures(report, now=now)

        self.assertFalse(status_report_is_ready(report, now=now))
        self.assertEqual(failures[0].name, "Status Report")
        self.assertIn("future", failures[0].detail)

    def test_status_report_ready_rejects_malformed_generated_at(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        cases = [
            ({}, "missing generated_at"),
            ({"generated_at": "2026-07-01T12:00:00"}, "must include a timezone"),
            ({"generated_at": "not a timestamp"}, "invalid generated_at"),
        ]
        for updates, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "generated_at" not in updates:
                    report.pop("generated_at", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertEqual(failures[0].name, "Status Report")
                self.assertIn(expected, failures[0].detail)

    def test_status_report_ready_rejects_timezone_less_current_time(self):
        generated_at = "2026-07-01T12:00:00Z"
        report = complete_status_gui_report(generated_at=generated_at)

        failures = status_report_validation_failures(report, now=datetime(2026, 7, 1, 12, 0, 0))

        self.assertFalse(status_report_is_ready(report, now=datetime(2026, 7, 1, 12, 0, 0)))
        self.assertEqual(failures[0].name, "Status Report")
        self.assertIn("current time must include a timezone", failures[0].detail)
        self.assertTrue(
            any(
                failure.name == "Manifest" and "current time must include a timezone" in failure.detail
                for failure in failures
            )
        )
        self.assertTrue(
            any(
                failure.name == "GPS Fix" and "current time must include a timezone" in failure.detail
                for failure in failures
            )
        )

    def test_status_report_ready_requires_structured_runtime_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")

        def python_data(**overrides):
            data = {
                "version": "3.11.2",
                "version_info": [3, 11, 2],
                "min_version": [3, 9],
                "executable": "/home/pi/.local/share/noaa-navionics/venv/bin/python",
            }
            data.update(overrides)
            return data

        def source_revision_data(**overrides):
            data = {
                "is_raspberry_pi": True,
                "path": "/home/pi/.local/share/noaa-navionics/source-revision",
                "exists": True,
                "is_symlink": False,
                "directory_symlink_component": "",
                "is_regular": True,
                "uid": os.getuid(),
                "expected_uid": os.getuid(),
                "mode": "0600",
                "revision": "fixture123",
            }
            data.update(overrides)
            return data

        cases = [
            ("Python", None, "Python check has no structured data"),
            ("Python", python_data(version_info=["3", 11, 2]), "Python version_info is invalid"),
            ("Python", python_data(version_info=[3, 8, 18]), "Python version is below 3.9"),
            ("Python", python_data(min_version=[3, 8]), "Python minimum version is not recorded"),
            ("Python", python_data(executable="python3"), "Python executable path is not absolute"),
            ("Tkinter", None, "Tkinter check has no structured data"),
            ("Tkinter", {"module": "tk", "available": True, "origin": ""}, "Tkinter module is not tkinter"),
            ("Tkinter", {"module": "tkinter", "available": False, "origin": ""}, "Tkinter availability was not proven"),
            ("Source Revision", None, "Source Revision check has no structured data"),
            ("Source Revision", source_revision_data(revision="fixture123-dirty"), "Source Revision records a dirty revision"),
            ("Source Revision", source_revision_data(revision="stale"), "Source Revision does not match app source revision"),
            ("Source Revision", source_revision_data(path="source-revision"), "Source Revision path is not absolute"),
            ("Source Revision", source_revision_data(exists=False), "Source Revision path does not exist"),
            ("Source Revision", source_revision_data(is_symlink=True), "Source Revision path is a symlink"),
            ("Source Revision", source_revision_data(directory_symlink_component="/home-link"), "Source Revision directory contains a symlink"),
            ("Source Revision", source_revision_data(is_regular=False), "Source Revision path is not a regular file"),
            ("Source Revision", source_revision_data(uid=1001), "Source Revision owner is invalid"),
            ("Source Revision", source_revision_data(mode="0666"), "Source Revision is group/world writable"),
        ]
        for row_name, data, expected in cases:
            with self.subTest(row_name=row_name, expected=expected):
                report = complete_status_gui_report(generated_at=generated_at)
                row = next(check for check in report["checks"] if check["name"] == row_name)
                if data is None:
                    row.pop("data", None)
                else:
                    row["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(any(failure.name == row_name and expected in failure.detail for failure in failures))

        non_pi_report = complete_status_gui_report(generated_at=generated_at)
        source_revision = next(check for check in non_pi_report["checks"] if check["name"] == "Source Revision")
        source_revision["detail"] = "not a Raspberry Pi; skipping deployed source revision check"
        source_revision["data"] = {"is_raspberry_pi": False, "skipped": True}

        self.assertTrue(status_report_is_ready(non_pi_report, now=now))
        self.assertFalse(status_report_validation_failures(non_pi_report, now=now))

    def test_status_report_ready_requires_structured_clock_and_time_sync_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")
        cases = [
            ("Clock", None, "Clock check has no structured data", "Clock"),
            (
                "Clock",
                {"timestamp": "1970-01-01T00:00:00Z", "min_year": 2024},
                "timestamp year 1970 is before 2024",
                "Clock",
            ),
            (
                "Clock",
                {"timestamp": (now - timedelta(seconds=301)).isoformat().replace("+00:00", "Z"), "min_year": 2024},
                "differs from generated_at by 301s",
                "Clock",
            ),
            ("Time Sync", None, "Time Sync check has no structured data", "Time Sync"),
            (
                "Time Sync",
                {
                    "is_raspberry_pi": True,
                    "system_clock_synchronized": "no",
                    "ntp_synchronized": "yes",
                },
                "SystemClockSynchronized=yes",
                "Time Sync",
            ),
        ]
        for row_name, data, expected, failure_name in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(generated_at=generated_at)
                row = next(check for check in report["checks"] if check["name"] == row_name)
                if data is None:
                    row.pop("data", None)
                else:
                    row["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == failure_name and expected in failure.detail for failure in failures)
                )

        non_pi_report = complete_status_gui_report(generated_at=generated_at)
        time_sync = next(check for check in non_pi_report["checks"] if check["name"] == "Time Sync")
        time_sync["detail"] = "not a Raspberry Pi; skipping time synchronization check"
        time_sync["data"] = {"is_raspberry_pi": False, "skipped": True}

        self.assertTrue(status_report_is_ready(non_pi_report, now=now))
        self.assertFalse(status_report_validation_failures(non_pi_report, now=now))

    def test_status_report_ready_requires_structured_pi_health_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")
        cases = [
            ("Pi Power", None, "Pi Power check has no structured data", "Pi Power"),
            (
                "Pi Power",
                {
                    "is_raspberry_pi": True,
                    "vcgencmd_available": True,
                    "throttled_output": "throttled=0x1",
                    "throttled_value": 1,
                    "reported_flags": ["under-voltage"],
                },
                "reported throttling flags: under-voltage",
                "Pi Power",
            ),
            (
                "Pi Power",
                {
                    "is_raspberry_pi": True,
                    "vcgencmd_available": True,
                    "throttled_output": "throttled=0x0",
                    "reported_flags": [],
                },
                "missing throttled value",
                "Pi Power",
            ),
            ("Pi Thermal", None, "Pi Thermal check has no structured data", "Pi Thermal"),
            (
                "Pi Thermal",
                {
                    "is_raspberry_pi": True,
                    "temperature_available": True,
                    "temperature_c": "42.5",
                    "warn_c": 70.0,
                    "fail_c": 80.0,
                },
                "missing finite temperature",
                "Pi Thermal",
            ),
            (
                "Pi Thermal",
                {
                    "is_raspberry_pi": True,
                    "temperature_available": True,
                    "temperature_c": 81.0,
                    "warn_c": 70.0,
                    "fail_c": 80.0,
                },
                "temperature 81.0 C is above 80 C limit",
                "Pi Thermal",
            ),
        ]
        for row_name, data, expected, failure_name in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(generated_at=generated_at)
                row = next(check for check in report["checks"] if check["name"] == row_name)
                if data is None:
                    row.pop("data", None)
                else:
                    row["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == failure_name and expected in failure.detail for failure in failures)
                )

        non_pi_report = complete_status_gui_report(generated_at=generated_at)
        for row_name in ("Pi Power", "Pi Thermal"):
            row = next(check for check in non_pi_report["checks"] if check["name"] == row_name)
            row["detail"] = "not a Raspberry Pi; skipping Pi health check"
            row["data"] = {"is_raspberry_pi": False, "skipped": True}

        self.assertTrue(status_report_is_ready(non_pi_report, now=now))
        self.assertFalse(status_report_validation_failures(non_pi_report, now=now))

    def test_status_report_ready_requires_structured_storage_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")

        def storage_data(**overrides):
            data = {
                "configured_path": "/charts",
                "checked_path": "/charts",
                "exists": True,
                "is_directory": True,
                "storage_symlink_component": "",
                "missing_removable_mount": False,
                "uid": 1000,
                "expected_uid": 1000,
                "mode": "0755",
                "min_free_gb": 2.0,
                "free_gb": 12.5,
                "writable": True,
            }
            data.update(overrides)
            return data

        cases = [
            (None, "Disk check has no structured data"),
            (storage_data(free_gb=1.0), "free space 1.0 GB is below 2.0 GB"),
            (storage_data(mode="0777"), "storage is group/world writable"),
            (storage_data(writable=False), "storage is not writable"),
            (storage_data(storage_symlink_component="/storage-link"), "storage path contains a symlink"),
            (storage_data(missing_removable_mount=True), "removable storage is not mounted"),
            (storage_data(uid=1001), "storage owner is invalid"),
            (storage_data(configured_path="relative/charts"), "configured path is not absolute"),
        ]
        for data, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(generated_at=generated_at)
                disk = next(check for check in report["checks"] if check["name"] == "Disk")
                if data is None:
                    disk.pop("data", None)
                else:
                    disk["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(any(failure.name == "Disk" and expected in failure.detail for failure in failures))

        track_report = complete_status_gui_report(generated_at=generated_at)
        track_report["config"]["track_output"] = "/tracks"
        track_report["track_log"]["track_output"] = "/tracks"
        track_report["track_log"]["tracks_dir"] = "/tracks/tracks"
        track_report["track_log"]["latest_path"] = "/tracks/tracks/track-20260701.gpx"
        track_report["checks"].append({"name": "Track Disk", "ok": True, "detail": "12.5 GB free"})

        failures = status_report_validation_failures(track_report, now=now)

        self.assertFalse(status_report_is_ready(track_report, now=now))
        self.assertTrue(
            any(
                failure.name == "Track Disk" and "Track Disk check has no structured data" in failure.detail
                for failure in failures
            )
        )

        track_disk = next(check for check in track_report["checks"] if check["name"] == "Track Disk")
        track_disk["detail"] = "12.5 GB free at /tracks; minimum 2.0 GB"
        track_disk["data"] = storage_data(configured_path="/tracks", checked_path="/tracks")

        self.assertTrue(status_report_is_ready(track_report, now=now))
        self.assertFalse(status_report_validation_failures(track_report, now=now))

    def test_status_report_ready_requires_structured_chart_readiness_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")

        def chart_package_data(**overrides):
            data = {
                "package": "state",
                "value": "AK",
                "complete_chart_set": True,
                "expected_filename": "AK_ENCs.zip",
                "expected_url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
            }
            data.update(overrides)
            return data

        def charts_data(**overrides):
            data = {
                "configured_path": "/charts",
                "exists": True,
                "storage_symlink_component": "",
                "enc_cell_samples": ["/charts/ENC_ROOT/US5AK00M/US5AK00M.000"],
                "zip_samples": [],
                "has_extracted_enc_cells": True,
                "has_unextracted_zips": False,
            }
            data.update(overrides)
            return data

        def debris_data(**overrides):
            data = {
                "configured_path": "/charts",
                "exists": True,
                "storage_symlink_component": "",
                "debris": [],
                "debris_count": 0,
                "clean": True,
            }
            data.update(overrides)
            return data

        def manifest_data(**overrides):
            data = {
                "configured_path": "/charts",
                "path": "/charts/noaa-navionics-manifest.json",
                "created_at": generated_at,
                "created_at_source": "download",
                "max_age_days": 30,
                "age_days": 0.0,
                "package": "Alaska",
                "package_filename": "AK_ENCs.zip",
                "package_url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
                "expected_filename": "AK_ENCs.zip",
                "expected_url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
                "download_path": "/charts/AK_ENCs.zip",
                "download_url": "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",
                "download_bytes": 123,
                "sha256": "abc123",
                "extract_path": "/charts/AK_ENCs",
                "enc_cell_count": 1,
                "actual_enc_cell_count": 1,
                "require_archive": True,
            }
            data.update(overrides)
            return data

        cases = [
            ("Chart Package", None, "Chart Package check has no structured data"),
            ("Chart Package", chart_package_data(package="all"), "does not match configured package"),
            ("Chart Package", chart_package_data(value="WA"), "does not match configured value"),
            ("Chart Package", chart_package_data(complete_chart_set=False), "is not a complete NOAA ENC package"),
            ("Chart Package", chart_package_data(expected_filename="US5WA.zip"), "filename does not match NOAA package"),
            ("Chart Package", chart_package_data(expected_url="https://example.invalid/AK_ENCs.zip"), "URL does not match NOAA package"),
            ("Charts", None, "Charts check has no structured data"),
            ("Charts", charts_data(configured_path="relative/charts"), "Charts path is not absolute"),
            ("Charts", charts_data(configured_path="/other-charts"), "Charts path does not match configured chart output"),
            ("Charts", charts_data(exists=False), "Charts path does not exist"),
            ("Charts", charts_data(storage_symlink_component="/media/link"), "Charts path contains a symlink"),
            ("Charts", charts_data(has_extracted_enc_cells=False), "found no extracted ENC cells"),
            ("Charts", charts_data(enc_cell_samples=[]), "has no ENC cell sample paths"),
            ("Charts", charts_data(enc_cell_samples=["relative.000"]), "ENC cell sample path is not absolute"),
            ("Chart Update Debris", None, "Chart Update Debris check has no structured data"),
            ("Chart Update Debris", debris_data(configured_path="relative/charts"), "Chart Update Debris path is not absolute"),
            ("Chart Update Debris", debris_data(configured_path="/other-charts"), "Chart Update Debris path does not match configured chart output"),
            ("Chart Update Debris", debris_data(storage_symlink_component="/media/link"), "Chart Update Debris path contains a symlink"),
            ("Chart Update Debris", debris_data(debris_count=1), "found stale update debris"),
            ("Chart Update Debris", debris_data(debris=["/charts/update.part"]), "debris list is not empty"),
            ("Chart Update Debris", debris_data(clean=False), "did not prove a clean chart directory"),
            ("Manifest", None, "Manifest check has no structured data"),
            ("Manifest", manifest_data(configured_path="relative/charts"), "Manifest configured path is not absolute"),
            ("Manifest", manifest_data(configured_path="/other-charts"), "Manifest configured path does not match chart output"),
            ("Manifest", manifest_data(path="noaa-navionics-manifest.json"), "Manifest path is not absolute"),
            ("Manifest", manifest_data(path="/other/noaa-navionics-manifest.json"), "Manifest path does not match manifest summary"),
            ("Manifest", manifest_data(created_at_source="unverified-cache"), "Manifest created_at_source is not verified"),
            ("Manifest", manifest_data(created_at="2026-07-01T12:00:00"), "Manifest created_at timestamp is invalid"),
            ("Manifest", manifest_data(expected_filename="WA_ENCs.zip"), "Manifest expected filename does not match NOAA package"),
            ("Manifest", manifest_data(expected_url="https://example.invalid/AK_ENCs.zip"), "Manifest expected URL does not match NOAA package"),
            ("Manifest", manifest_data(package_filename="WA_ENCs.zip"), "Manifest package filename does not match manifest summary"),
            ("Manifest", manifest_data(package_url="https://example.invalid/AK_ENCs.zip"), "Manifest package URL does not match manifest summary"),
            ("Manifest", manifest_data(max_age_days=0), "Manifest max_age_days is not positive"),
            ("Manifest", manifest_data(max_age_days=7), "Manifest max_age_days does not match config"),
            ("Manifest", manifest_data(age_days=-1.0), "Manifest age_days is invalid"),
            ("Manifest", manifest_data(download_path="AK_ENCs.zip"), "Manifest download path is not absolute"),
            ("Manifest", manifest_data(download_bytes=0), "Manifest download byte count is not positive"),
            ("Manifest", manifest_data(extract_path="AK_ENCs"), "Manifest extract path is not absolute"),
            ("Manifest", manifest_data(enc_cell_count=0), "Manifest has no ENC cells"),
            ("Manifest", manifest_data(actual_enc_cell_count=2), "Manifest actual ENC cell count does not match recorded count"),
        ]
        for row_name, data, expected in cases:
            with self.subTest(row_name=row_name, expected=expected):
                report = complete_status_gui_report(generated_at=generated_at)
                row = next(check for check in report["checks"] if check["name"] == row_name)
                if data is None:
                    row.pop("data", None)
                else:
                    row["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == row_name and expected in failure.detail for failure in failures)
                )

        stale_created_at = (now - timedelta(days=31)).isoformat().replace("+00:00", "Z")
        stale_report = complete_status_gui_report(generated_at=generated_at)
        stale_report["manifest"]["created_at"] = stale_created_at
        manifest_row = next(check for check in stale_report["checks"] if check["name"] == "Manifest")
        manifest_row["data"] = manifest_data(created_at=stale_created_at, age_days=31.0)

        failures = status_report_validation_failures(stale_report, now=now)

        self.assertFalse(status_report_is_ready(stale_report, now=now))
        self.assertTrue(any(failure.name == "Manifest" and "Manifest is 31.0 days old" in failure.detail for failure in failures))

    def test_status_report_ready_requires_structured_opencpn_readiness_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")

        def opencpn_charts_data(**overrides):
            data = {
                "config_path": "/home/pi/.opencpn/opencpn.conf",
                "chart_dir": "/charts",
                "config_exists": True,
                "chart_dir_exists": True,
                "configured": True,
                "chart_directories": ["/charts"],
            }
            data.update(overrides)
            return data

        def opencpn_gpsd_data(**overrides):
            data = {
                "config_path": "/home/pi/.opencpn/opencpn.conf",
                "expected_host": "127.0.0.1",
                "expected_port": 2947,
                "config_exists": True,
                "configured": True,
                "enabled_gpsd_connections": [
                    {
                        "host": "127.0.0.1",
                        "port": 2947,
                        "raw": "1;2;127.0.0.1;2947;0;;4800;1;0;0;;0;;0;0;0;0;1;GPSd: 127.0.0.1 TCP port 2947;0;;0;0;",
                    }
                ],
                "unexpected_connections": [],
            }
            data.update(overrides)
            return data

        cases = [
            ("OpenCPN Charts", None, "OpenCPN Charts check has no structured data"),
            ("OpenCPN Charts", opencpn_charts_data(chart_dir="relative/charts"), "chart directory is not absolute"),
            ("OpenCPN Charts", opencpn_charts_data(chart_dir="/other-charts"), "chart directory does not match configured chart output"),
            ("OpenCPN Charts", opencpn_charts_data(config_path="relative/opencpn.conf"), "config path is not absolute"),
            ("OpenCPN Charts", opencpn_charts_data(config_exists=False), "config does not exist"),
            ("OpenCPN Charts", opencpn_charts_data(chart_dir_exists=False), "chart directory does not exist"),
            ("OpenCPN Charts", opencpn_charts_data(configured=False), "did not prove configured chart directory"),
            ("OpenCPN Charts", opencpn_charts_data(chart_directories=[]), "has no parsed chart directories"),
            ("OpenCPN Charts", opencpn_charts_data(chart_directories=["/other-charts"]), "parsed directories do not include configured chart output"),
            ("OpenCPN GPSD", None, "OpenCPN GPSD check has no structured data"),
            ("OpenCPN GPSD", opencpn_gpsd_data(config_path="relative/opencpn.conf"), "config path is not absolute"),
            ("OpenCPN GPSD", opencpn_gpsd_data(config_exists=False), "config does not exist"),
            ("OpenCPN GPSD", opencpn_gpsd_data(expected_host="192.0.2.10"), "host does not match configured GPSD host"),
            ("OpenCPN GPSD", opencpn_gpsd_data(expected_port=2948), "port does not match configured GPSD port"),
            ("OpenCPN GPSD", opencpn_gpsd_data(configured=False), "did not prove configured endpoint"),
            ("OpenCPN GPSD", opencpn_gpsd_data(enabled_gpsd_connections=[]), "has no parsed enabled GPSD connections"),
            (
                "OpenCPN GPSD",
                opencpn_gpsd_data(enabled_gpsd_connections=[{"host": "192.0.2.10", "port": 2947, "raw": "stale"}]),
                "parsed connections do not include configured endpoint",
            ),
            ("OpenCPN GPSD", opencpn_gpsd_data(unexpected_connections="not-list"), "unexpected connection list was not parsed"),
            (
                "OpenCPN GPSD",
                opencpn_gpsd_data(unexpected_connections=[{"host": "192.0.2.10", "port": 2947, "raw": "stale"}]),
                "found unexpected enabled GPSD connections",
            ),
        ]
        for row_name, data, expected in cases:
            with self.subTest(row_name=row_name, expected=expected):
                report = complete_status_gui_report(generated_at=generated_at)
                row = next(check for check in report["checks"] if check["name"] == row_name)
                if data is None:
                    row.pop("data", None)
                else:
                    row["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == row_name and expected in failure.detail for failure in failures)
                )

        serial_report = complete_status_gui_report(gps_mode="serial", generated_at=generated_at)
        serial_report["checks"].append({"name": "OpenCPN GPSD", "ok": True, "detail": "legacy row"})

        self.assertTrue(status_report_is_ready(serial_report, now=now))
        self.assertFalse(status_report_validation_failures(serial_report, now=now))

    def test_status_report_ready_requires_structured_serial_gps_device_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")

        def device_data(**overrides):
            data = {
                "configured_path": "/dev/serial/by-id/mock-gps",
                "stable_path": True,
                "volatile_path": False,
                "is_by_id_path": True,
                "is_symlink": True,
                "exists": True,
                "is_directory": False,
                "resolved_path": "/dev/ttyACM0",
                "is_character_device": True,
            }
            data.update(overrides)
            return data

        cases = [
            (None, "GPS Device check has no structured data"),
            (device_data(configured_path="/dev/ttyACM0"), "path /dev/ttyACM0 does not match configured"),
            (device_data(configured_path="/dev/serial/by-id/mock/extra"), "path is not stable"),
            (device_data(stable_path=False), "missing stable path evidence"),
            (device_data(volatile_path=True), "path is volatile"),
            (device_data(exists=False), "path does not exist"),
            (device_data(is_directory=True), "path is a directory"),
            (device_data(is_symlink=False), "by-id path is not a symlink"),
            (device_data(is_character_device=False), "is not a character device"),
            (device_data(resolved_path="ttyACM0"), "resolved path is not absolute"),
        ]
        for data, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(gps_mode="serial", generated_at=generated_at)
                row = next(check for check in report["checks"] if check["name"] == "GPS Device")
                if data is None:
                    row.pop("data", None)
                else:
                    row["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == "GPS Device" and expected in failure.detail for failure in failures)
                )

        gpsd_report = complete_status_gui_report(generated_at=generated_at)
        gpsd_report["checks"].append({"name": "GPS Device", "ok": True, "detail": "legacy row"})

        self.assertTrue(status_report_is_ready(gpsd_report, now=now))
        self.assertFalse(status_report_validation_failures(gpsd_report, now=now))

    def test_status_report_ready_requires_structured_gpsd_config_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")

        def gpsd_config_data(**overrides):
            data = {
                "path": "/etc/default/gpsd",
                "expected_device": "/dev/serial/by-id/mock-gps",
                "exists": True,
                "is_symlink": False,
                "directory_symlink_component": "",
                "is_regular": True,
                "uid": 0,
                "expected_uid": 0,
                "mode": "0644",
                "values": {
                    "START_DAEMON": "true",
                    "USBAUTO": "false",
                    "GPSD_OPTIONS": "-n",
                    "DEVICES": "/dev/serial/by-id/mock-gps",
                },
                "devices": ["/dev/serial/by-id/mock-gps"],
                "gpsd_options": ["-n"],
                "start_daemon": "true",
                "usbauto": "false",
                "immediate_polling": True,
            }
            data.update(overrides)
            return data

        cases = [
            (None, "GPSD Config check has no structured data"),
            (gpsd_config_data(path="/tmp/gpsd"), "path /tmp/gpsd is not /etc/default/gpsd"),
            (gpsd_config_data(exists=False), "path does not exist"),
            (gpsd_config_data(is_symlink=True), "path is a symlink"),
            (gpsd_config_data(directory_symlink_component="/etc-link"), "directory contains a symlink"),
            (gpsd_config_data(is_regular=False), "path is not a regular file"),
            (gpsd_config_data(uid=1000), "owner is not root"),
            (gpsd_config_data(expected_uid=1000), "expected owner is not root"),
            (gpsd_config_data(mode="0666"), "is group/world writable"),
            (gpsd_config_data(expected_device="/dev/serial/by-id/other-gps"), "expected device does not match config"),
            (gpsd_config_data(devices=[]), "devices do not match configured GPS device"),
            (gpsd_config_data(start_daemon="false"), "START_DAEMON is not true"),
            (gpsd_config_data(usbauto="true"), "USBAUTO is not false"),
            (gpsd_config_data(gpsd_options=[], immediate_polling=False), "does not enable immediate polling"),
        ]
        for data, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(generated_at=generated_at)
                row = next(check for check in report["checks"] if check["name"] == "GPSD Config")
                if data is None:
                    row.pop("data", None)
                else:
                    row["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == "GPSD Config" and expected in failure.detail for failure in failures)
                )

        serial_report = complete_status_gui_report(gps_mode="serial", generated_at=generated_at)
        serial_report["checks"].append({"name": "GPSD Config", "ok": True, "detail": "legacy row"})

        self.assertTrue(status_report_is_ready(serial_report, now=now))
        self.assertFalse(status_report_validation_failures(serial_report, now=now))

    def test_status_report_ready_requires_structured_chrony_gps_time_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")

        def chrony_config_data(**overrides):
            data = {
                "is_raspberry_pi": True,
                "path": "/etc/chrony/chrony.conf",
                "exists": True,
                "is_symlink": False,
                "directory_symlink_component": "",
                "is_regular": True,
                "uid": 0,
                "expected_uid": 0,
                "mode": "0644",
                "managed_refclock_present": True,
                "refclock_line": "refclock SHM 0 offset 0.5 delay 0.1 refid GPS",
            }
            data.update(overrides)
            return data

        def gps_time_source_data(**overrides):
            data = {
                "is_raspberry_pi": True,
                "chronyc_path": "/usr/bin/chronyc",
                "chronyc_available": True,
                "returncode": 0,
                "gps_lines": ["#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms"],
                "usable_lines": ["#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms"],
                "selected_or_combined": True,
            }
            data.update(overrides)
            return data

        cases = [
            ("Chrony Config", None, "Chrony Config check has no structured data"),
            ("Chrony Config", chrony_config_data(path="/tmp/chrony.conf"), "path /tmp/chrony.conf is not /etc/chrony/chrony.conf"),
            ("Chrony Config", chrony_config_data(exists=False), "path does not exist"),
            ("Chrony Config", chrony_config_data(is_symlink=True), "path is a symlink"),
            ("Chrony Config", chrony_config_data(directory_symlink_component="/etc-link"), "directory contains a symlink"),
            ("Chrony Config", chrony_config_data(is_regular=False), "path is not a regular file"),
            ("Chrony Config", chrony_config_data(uid=1000), "owner is not root"),
            ("Chrony Config", chrony_config_data(expected_uid=1000), "expected owner is not root"),
            ("Chrony Config", chrony_config_data(mode="0666"), "is group/world writable"),
            ("Chrony Config", chrony_config_data(managed_refclock_present=False), "missing managed GPSD SHM refclock"),
            ("Chrony Config", chrony_config_data(refclock_line="refclock PPS /dev/pps0 refid PPS"), "refclock line is not the managed GPSD SHM source"),
            ("GPS Time Source", None, "GPS Time Source check has no structured data"),
            ("GPS Time Source", gps_time_source_data(is_raspberry_pi=None), "did not identify a Raspberry Pi check"),
            ("GPS Time Source", gps_time_source_data(chronyc_available=False), "did not validate chronyc availability"),
            ("GPS Time Source", gps_time_source_data(gps_lines=[]), "has no GPS refclock lines"),
            ("GPS Time Source", gps_time_source_data(usable_lines=[]), "has no selected or combined GPS refclock"),
            ("GPS Time Source", gps_time_source_data(selected_or_combined=False), "did not prove selected or combined GPS time"),
        ]
        for row_name, data, expected in cases:
            with self.subTest(row_name=row_name, expected=expected):
                report = complete_status_gui_report(generated_at=generated_at)
                row = next(check for check in report["checks"] if check["name"] == row_name)
                if data is None:
                    row.pop("data", None)
                else:
                    row["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == row_name and expected in failure.detail for failure in failures)
                )

        serial_report = complete_status_gui_report(gps_mode="serial", generated_at=generated_at)
        serial_report["checks"].extend(
            [
                {"name": "Chrony Config", "ok": True, "detail": "legacy row"},
                {"name": "GPS Time Source", "ok": True, "detail": "legacy row"},
            ]
        )

        self.assertTrue(status_report_is_ready(serial_report, now=now))
        self.assertFalse(status_report_validation_failures(serial_report, now=now))

    def test_status_report_ready_requires_structured_command_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")

        def command_data(command="opencpn", path="/usr/bin/opencpn", **overrides):
            data = {
                "command": command,
                "path": path,
                "directory": "/usr/bin",
                "is_absolute": True,
                "is_symlink": False,
                "path_symlink_component": "",
                "trusted_system_directory": True,
                "is_regular": True,
                "executable": True,
                "uid": 0,
                "directory_uid": 0,
                "expected_uids": [0],
                "mode": "0755",
                "directory_mode": "0755",
            }
            data.update(overrides)
            return data

        cases = [
            ("OpenCPN", None, "OpenCPN check has no structured command data"),
            ("OpenCPN", command_data(command="other"), "command other is not opencpn"),
            ("OpenCPN", command_data(path="opencpn", is_absolute=False), "command path is not absolute"),
            ("OpenCPN", command_data(is_symlink=True), "command is a symlink"),
            ("OpenCPN", command_data(path_symlink_component="/usr-link"), "command path contains a symlink"),
            ("OpenCPN", command_data(trusted_system_directory=False), "command is not in a trusted system directory"),
            ("OpenCPN", command_data(is_regular=False), "command is not a regular file"),
            ("OpenCPN", command_data(executable=False), "command is not executable"),
            ("OpenCPN", command_data(uid=1000), "command owner is not root"),
            ("OpenCPN", command_data(directory_uid=1000), "command directory owner is not root"),
            ("OpenCPN", command_data(mode="0777"), "command is group/world writable"),
            ("OpenCPN", command_data(directory_mode="0777"), "command directory is group/world writable"),
            (
                "Display Power",
                command_data(command="other", path="/usr/bin/xset"),
                "command other is not xset",
            ),
        ]
        for row_name, data, expected in cases:
            with self.subTest(row=row_name, expected=expected):
                report = complete_status_gui_report(generated_at=generated_at)
                row = next(check for check in report["checks"] if check["name"] == row_name)
                if data is None:
                    row.pop("data", None)
                else:
                    row["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(any(failure.name == row_name and expected in failure.detail for failure in failures))

    def test_status_report_ready_rejects_missing_or_malformed_host_boot_id(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        cases = [
            ({}, "missing host section"),
            ({"host": {}}, "missing valid host boot_id"),
            ({"host": {"boot_id": "unknown"}}, "missing valid host boot_id"),
            ({"host": {"boot_id": "not-a-boot-id"}}, "not a Linux boot_id value"),
        ]
        for updates, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "host" not in updates:
                    report.pop("host", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertEqual(failures[0].name, "Status Report")
                self.assertIn(expected, failures[0].detail)

    def test_status_report_ready_requires_valid_app_source_revision_summary(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        valid_app = complete_status_gui_report(
            generated_at=now.isoformat().replace("+00:00", "Z"),
        )["app"]
        cases = [
            ({}, "missing app section"),
            ({"app": {**valid_app, "source_revision": ""}}, "missing deployed source_revision"),
            ({"app": {**valid_app, "source_revision": "unknown"}}, "missing deployed source_revision"),
            ({"app": {**valid_app, "source_revision": "fixture123-dirty"}}, "dirty deployed source_revision"),
            ({"app": {**valid_app, "source_revision_path": ""}}, "missing source_revision_path"),
            ({"app": {**valid_app, "source_revision_path_is_symlink": True}}, "path is a symlink"),
            (
                {"app": {key: value for key, value in valid_app.items() if key != "source_revision_path_is_symlink"}},
                "path is a symlink or missing symlink status",
            ),
            (
                {"app": {**valid_app, "source_revision_directory_is_symlink": True}},
                "directory is a symlink",
            ),
            (
                {"app": {key: value for key, value in valid_app.items() if key != "source_revision_symlink_component"}},
                "missing source_revision_symlink_component",
            ),
            (
                {"app": {**valid_app, "source_revision_symlink_component": "/home/pi/.local/share"}},
                "path contains a symlink",
            ),
            (
                {"app": {**valid_app, "source_revision_error": "source revision path is not a regular file"}},
                "source revision error",
            ),
        ]
        for updates, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "app" not in updates:
                    report.pop("app", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == "Status Report" and expected in failure.detail for failure in failures)
                )

    def test_status_report_ready_requires_valid_config_summary(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        valid_report = complete_status_gui_report(
            generated_at=now.isoformat().replace("+00:00", "Z"),
        )
        valid_config = valid_report["config"]
        valid_track_log = valid_report["track_log"]
        valid_manifest = valid_report["manifest"]
        cases = [
            ({}, "missing config_path"),
            ({"config": None}, "missing config section"),
            ({"config": {**valid_config, "chart_package": "bad"}}, "chart_package is invalid"),
            ({"config": {**valid_config, "chart_value": ""}}, "chart_value is required"),
            ({"config": {**valid_config, "chart_output": "relative/charts"}}, "chart_output is not absolute"),
            ({"config": {**valid_config, "track_output": "relative/tracks"}}, "track_output is not absolute"),
            ({"config": {**valid_config, "extract": "yes"}}, "extract is not boolean"),
            ({"config": {**valid_config, "max_chart_age_days": 0}}, "max_chart_age_days is not positive"),
            ({"config": {**valid_config, "min_free_gb": 0.0}}, "min_free_gb is not positive"),
            ({"config": {**valid_config, "gps_mode": "network"}}, "gps_mode is invalid"),
            ({"config": {**valid_config, "gps_device": ""}}, "gps_device is empty"),
            ({"config": {**valid_config, "gps_baud": 1234}}, "gps_baud is invalid"),
            ({"config": {**valid_config, "gpsd_host": "192.0.2.10"}}, "gpsd_host is not local"),
            ({"config": {**valid_config, "gpsd_port": 0}}, "gpsd_port is invalid"),
            (
                {"config": {**valid_config, "track_retention_days": -1}},
                "track_retention_days is negative or invalid",
            ),
            ({"config": {**valid_config, "anchor_radius_meters": 0.0}}, "anchor_radius_meters is not positive"),
            (
                {
                    "config": {**valid_config, "chart_output": "/other-charts"},
                    "manifest": valid_manifest,
                },
                "manifest path /charts/noaa-navionics-manifest.json does not match configured",
            ),
            (
                {
                    "config": {**valid_config, "track_output": "/other-tracks"},
                    "track_log": valid_track_log,
                },
                "track_output /charts does not match configured /other-tracks",
            ),
        ]
        for updates, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "config_path" not in updates and "config" not in updates:
                    report.pop("config_path", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(any(failure.name == "Config" and expected in failure.detail for failure in failures))

    def test_status_report_ready_requires_valid_user_and_unit_file_summaries(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        valid_report = complete_status_gui_report(
            generated_at=now.isoformat().replace("+00:00", "Z"),
        )
        valid_user = valid_report["user"]
        valid_unit_files = valid_report["unit_files"]
        timer_without_install_target = {
            **valid_unit_files["noaa-navionics.timer"],
            "wanted_by": [],
        }
        service_without_restart = {
            **valid_unit_files["noaa-navionics.service"],
            "lines": [
                line
                for line in valid_unit_files["noaa-navionics.service"]["lines"]
                if line != "Restart=on-failure"
            ],
        }
        cases = [
            ({}, "missing user section", "User Linger"),
            ({"user": {**valid_user, "name": ""}}, "user name is empty", "User Linger"),
            ({"user": {**valid_user, "uid": "pi"}}, "user uid is invalid", "User Linger"),
            ({"user": {**valid_user, "linger": "no"}}, "linger=no", "User Linger"),
            ({"unit_files": None}, "missing unit_files section", "Unit Files"),
            (
                {"unit_files": {key: value for key, value in valid_unit_files.items() if key != "noaa-navionics.service"}},
                "noaa-navionics.service missing from unit file summary",
                "Chart Sync Unit File",
            ),
            (
                {
                    "unit_files": {
                        **valid_unit_files,
                        "noaa-navionics.service": {
                            **valid_unit_files["noaa-navionics.service"],
                            "is_symlink": True,
                        },
                    }
                },
                "unit file path is a symlink",
                "Chart Sync Unit File",
            ),
            (
                {
                    "unit_files": {
                        **valid_unit_files,
                        "noaa-navionics.service": {
                            key: value
                            for key, value in valid_unit_files["noaa-navionics.service"].items()
                            if key != "path_symlink_component"
                        },
                    }
                },
                "missing path_symlink_component",
                "Chart Sync Unit File",
            ),
            (
                {
                    "unit_files": {
                        **valid_unit_files,
                        "noaa-navionics.service": {
                            **valid_unit_files["noaa-navionics.service"],
                            "mode": "0666",
                        },
                    }
                },
                "mode=0666",
                "Chart Sync Unit File",
            ),
            (
                {
                    "unit_files": {
                        **valid_unit_files,
                        "noaa-navionics.service": service_without_restart,
                    }
                },
                "missing unit file lines",
                "Chart Sync Unit File",
            ),
            (
                {
                    "unit_files": {
                        **valid_unit_files,
                        "noaa-navionics.timer": timer_without_install_target,
                    }
                },
                "WantedBy=<missing> expected timers.target",
                "Chart Timer Install",
            ),
        ]
        for updates, expected, failure_name in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "user" not in updates and "unit_files" not in updates:
                    report.pop("user", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == failure_name and expected in failure.detail for failure in failures)
                )

    def test_status_report_ready_requires_valid_service_summaries(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        valid_report = complete_status_gui_report(
            generated_at=now.isoformat().replace("+00:00", "Z"),
        )
        valid_services = valid_report["services"]
        valid_system_services = valid_report["system_services"]
        services_without_properties = {
            unit: {key: value for key, value in state.items() if key != "properties"}
            if isinstance(state, dict)
            else state
            for unit, state in valid_services.items()
        }
        inactive_track_logger = copy.deepcopy(valid_services)
        inactive_track_logger["noaa-navionics-track.service"]["active"] = "inactive"
        weak_track_logger_settings = copy.deepcopy(valid_services)
        weak_track_logger_settings["noaa-navionics-track.service"]["properties"]["ProtectSystem"] = "no"
        inactive_gpsd_socket = copy.deepcopy(valid_system_services)
        inactive_gpsd_socket["gpsd.socket"]["active"] = "inactive"
        cases = [
            ({}, "missing services section", "Status Report"),
            ({"system_services": None}, "missing system_services section", "Status Report"),
            (
                {"services": services_without_properties},
                "systemd user service properties were not loaded",
                "Status Report",
            ),
            (
                {"services": inactive_track_logger},
                "noaa-navionics-track.service enabled=enabled active=inactive",
                "Track Logger",
            ),
            (
                {"services": weak_track_logger_settings},
                "ProtectSystem=no expected full",
                "Track Logger Settings",
            ),
            (
                {"system_services": inactive_gpsd_socket},
                "gpsd.socket enabled=enabled active=inactive",
                "GPSD Socket",
            ),
        ]
        for updates, expected, failure_name in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "services" not in updates and "system_services" not in updates:
                    report.pop("services", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == failure_name and expected in failure.detail for failure in failures)
                )

        serial_report = complete_status_gui_report(
            gps_mode="serial",
            generated_at=now.isoformat().replace("+00:00", "Z"),
        )
        serial_report["system_services"] = inactive_gpsd_socket

        self.assertTrue(status_report_is_ready(serial_report, now=now))
        self.assertFalse(status_report_validation_failures(serial_report, now=now))

    def test_status_report_ready_requires_valid_launcher_settings_summary(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        valid_launcher_settings = complete_status_gui_report(
            generated_at=now.isoformat().replace("+00:00", "Z"),
        )["launcher_settings"]
        valid_values = valid_launcher_settings["values"]
        cases = [
            ({}, "missing launcher_settings section"),
            ({"launcher_settings": {**valid_launcher_settings, "path": ""}}, "path is empty"),
            (
                {"launcher_settings": {**valid_launcher_settings, "path": "launcher.env"}},
                "path is not absolute",
            ),
            (
                {"launcher_settings": {**valid_launcher_settings, "exists": False}},
                "file does not exist",
            ),
            (
                {"launcher_settings": {**valid_launcher_settings, "is_symlink": True}},
                "path is a symlink",
            ),
            (
                {"launcher_settings": {**valid_launcher_settings, "directory_is_symlink": True}},
                "directory is a symlink",
            ),
            (
                {
                    "launcher_settings": {
                        key: value
                        for key, value in valid_launcher_settings.items()
                        if key != "launcher_settings_symlink_component"
                    }
                },
                "missing launcher_settings_symlink_component",
            ),
            (
                {
                    "launcher_settings": {
                        **valid_launcher_settings,
                        "launcher_settings_symlink_component": "/home/pi/.config",
                    }
                },
                "path contains a symlink",
            ),
            (
                {
                    "launcher_settings": {
                        **valid_launcher_settings,
                        "error": "launcher environment is not a regular file",
                    }
                },
                "launcher settings error",
            ),
            (
                {"launcher_settings": {**valid_launcher_settings, "values": None}},
                "values were not parsed",
            ),
            (
                {
                    "launcher_settings": {
                        **valid_launcher_settings,
                        "values": {**valid_values, "NOAA_NAVIONICS_EXTRA": "1"},
                    }
                },
                "unknown launcher settings key",
            ),
            (
                {
                    "launcher_settings": {
                        **valid_launcher_settings,
                        "malformed_lines": ["2: NOAA_NAVIONICS_GPS_SECONDS 60"],
                    }
                },
                "malformed launcher settings line",
            ),
            (
                {
                    "launcher_settings": {
                        **valid_launcher_settings,
                        "values": {key: value for key, value in valid_values.items() if key != "NOAA_NAVIONICS_GPS_SECONDS"},
                    }
                },
                "NOAA_NAVIONICS_GPS_SECONDS=<missing>",
            ),
            (
                {
                    "launcher_settings": {
                        **valid_launcher_settings,
                        "values": {**valid_values, "NOAA_NAVIONICS_READINESS_ATTEMPTS": "0"},
                    }
                },
                "NOAA_NAVIONICS_READINESS_ATTEMPTS=0 expected positive integer",
            ),
            (
                {
                    "launcher_settings": {
                        **valid_launcher_settings,
                        "values": {**valid_values, "NOAA_NAVIONICS_OPENCPN_RESTARTS": "-1"},
                    }
                },
                "NOAA_NAVIONICS_OPENCPN_RESTARTS=-1 expected non-negative integer",
            ),
            (
                {
                    "launcher_settings": {
                        **valid_launcher_settings,
                        "values": {**valid_values, "NOAA_NAVIONICS_START_ON_FAILED_READINESS": "yes"},
                    }
                },
                "START_ON_FAILED_READINESS",
            ),
            (
                {
                    "launcher_settings": {
                        **valid_launcher_settings,
                        "values": {key: value for key, value in valid_values.items() if key != "NOAA_NAVIONICS_START_ON_FAILED_READINESS"},
                    }
                },
                "NOAA_NAVIONICS_START_ON_FAILED_READINESS=<missing>",
            ),
        ]
        for updates, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "launcher_settings" not in updates:
                    report.pop("launcher_settings", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == "Launcher Settings" and expected in failure.detail for failure in failures)
                )

    def test_status_report_ready_requires_valid_opencpn_config_summary(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        valid_opencpn_config = complete_status_gui_report(
            generated_at=now.isoformat().replace("+00:00", "Z"),
        )["opencpn_config"]
        stale_connection = (
            "1;2;192.0.2.20;2947;0;;4800;1;0;0;;0;;0;0;0;0;1;"
            "GPSd: 192.0.2.20 TCP port 2947;0;;0;0;"
        )
        cases = [
            ({}, "missing opencpn_config section"),
            ({"opencpn_config": {**valid_opencpn_config, "path": ""}}, "path is empty"),
            (
                {"opencpn_config": {**valid_opencpn_config, "path": "opencpn.conf"}},
                "path is not absolute",
            ),
            (
                {"opencpn_config": {**valid_opencpn_config, "exists": False}},
                "does not exist",
            ),
            (
                {"opencpn_config": {**valid_opencpn_config, "is_symlink": True}},
                "config is a symlink",
            ),
            (
                {"opencpn_config": {**valid_opencpn_config, "directory_is_symlink": True}},
                "directory is a symlink",
            ),
            (
                {
                    "opencpn_config": {
                        key: value for key, value in valid_opencpn_config.items() if key != "config_symlink_component"
                    }
                },
                "missing config_symlink_component",
            ),
            (
                {"opencpn_config": {**valid_opencpn_config, "config_symlink_component": "/home/pi/.opencpn"}},
                "path contains a symlink",
            ),
            (
                {"opencpn_config": {**valid_opencpn_config, "error": "OpenCPN config path is not a regular file"}},
                "OpenCPN config error",
            ),
            (
                {"opencpn_config": {**valid_opencpn_config, "chart_directories": None}},
                "chart directories were not parsed",
            ),
            (
                {"opencpn_config": {**valid_opencpn_config, "data_connections": None}},
                "data connections were not parsed",
            ),
            (
                {"opencpn_config": {**valid_opencpn_config, "chart_directories": ["/other-charts"]}},
                "does not list configured chart output /charts",
            ),
            (
                {"opencpn_config": {**valid_opencpn_config, "data_connections": []}},
                "does not contain enabled GPSD connection 127.0.0.1:2947",
            ),
            (
                {
                    "opencpn_config": {
                        **valid_opencpn_config,
                        "data_connections": [*valid_opencpn_config["data_connections"], stale_connection],
                    }
                },
                "unexpected enabled GPSD connections: 192.0.2.20:2947",
            ),
        ]
        for updates, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "opencpn_config" not in updates:
                    report.pop("opencpn_config", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == "OpenCPN Config" and expected in failure.detail for failure in failures)
                )

    def test_status_report_ready_requires_valid_desktop_summary(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        valid_desktop = complete_status_gui_report(
            generated_at=now.isoformat().replace("+00:00", "Z"),
        )["desktop"]
        valid_autostart = valid_desktop["autostart"]
        valid_lightdm = valid_desktop["lightdm_autologin"]
        cases = [
            ({}, "missing desktop section"),
            ({"desktop": {key: value for key, value in valid_desktop.items() if key != "autostart"}}, "missing desktop autostart section"),
            (
                {"desktop": {**valid_desktop, "autostart": {**valid_autostart, "path": ""}}},
                "desktop autostart path is empty",
            ),
            (
                {"desktop": {**valid_desktop, "autostart": {**valid_autostart, "exists": False}}},
                "desktop autostart does not exist",
            ),
            (
                {"desktop": {**valid_desktop, "autostart": {**valid_autostart, "is_symlink": True}}},
                "desktop autostart path is a symlink",
            ),
            (
                {"desktop": {**valid_desktop, "autostart": {**valid_autostart, "directory_is_symlink": True}}},
                "desktop autostart directory is a symlink",
            ),
            (
                {
                    "desktop": {
                        **valid_desktop,
                        "autostart": {
                            key: value for key, value in valid_autostart.items() if key != "path_symlink_component"
                        },
                    }
                },
                "desktop autostart missing path_symlink_component",
            ),
            (
                {"desktop": {**valid_desktop, "autostart": {**valid_autostart, "path_symlink_component": "/home/pi"}}},
                "desktop autostart path contains a symlink",
            ),
            (
                {"desktop": {**valid_desktop, "autostart": {**valid_autostart, "mode": "0666"}}},
                "desktop autostart has permissions 0666",
            ),
            (
                {
                    "desktop": {
                        **valid_desktop,
                        "autostart": {
                            **valid_autostart,
                            "values": {**valid_autostart["values"], "Hidden": "true"},
                        },
                    }
                },
                "desktop autostart Hidden=true",
            ),
            (
                {
                    "desktop": {
                        **valid_desktop,
                        "autostart": {
                            **valid_autostart,
                            "values": {**valid_autostart["values"], "Exec": "/tmp/start-chartplotter"},
                        },
                    }
                },
                "desktop autostart Exec=/tmp/start-chartplotter",
            ),
            (
                {"desktop": {**valid_desktop, "graphical_target": "multi-user.target"}},
                "graphical target is multi-user.target",
            ),
            (
                {"desktop": {**valid_desktop, "lightdm_enabled": "disabled"}},
                "LightDM enabled state is disabled",
            ),
            (
                {
                    "desktop": {
                        **valid_desktop,
                        "lightdm_autologin": {key: value for key, value in valid_lightdm.items() if key != "sections"},
                    }
                },
                "LightDM autologin sections were not parsed",
            ),
            (
                {"desktop": {**valid_desktop, "lightdm_autologin": {**valid_lightdm, "sections": []}}},
                "LightDM autologin config missing [Seat:*] section",
            ),
            (
                {
                    "desktop": {
                        **valid_desktop,
                        "lightdm_autologin": {**valid_lightdm, "values": None},
                    }
                },
                "LightDM autologin values were not parsed",
            ),
            (
                {
                    "desktop": {
                        **valid_desktop,
                        "lightdm_autologin": {
                            **valid_lightdm,
                            "values": {**valid_lightdm["values"], "autologin-user": "other"},
                        },
                    }
                },
                "LightDM autologin-user=other expected pi",
            ),
            (
                {
                    "desktop": {
                        **valid_desktop,
                        "lightdm_autologin": {
                            **valid_lightdm,
                            "values": {**valid_lightdm["values"], "autologin-user-timeout": "5"},
                        },
                    }
                },
                "LightDM autologin-user-timeout=5 expected 0",
            ),
            (
                {
                    "desktop": {
                        **valid_desktop,
                        "lightdm_autologin": {
                            **valid_lightdm,
                            "values": {**valid_lightdm["values"], "autologin-session": "../bad"},
                        },
                    }
                },
                "LightDM autologin-session is unsafe",
            ),
        ]
        for updates, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "desktop" not in updates:
                    report.pop("desktop", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == "Desktop Startup" and expected in failure.detail for failure in failures)
                )

    def test_status_report_ready_requires_valid_manifest_summary(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        valid_manifest = complete_status_gui_report(
            generated_at=now.isoformat().replace("+00:00", "Z"),
        )["manifest"]
        cases = [
            ({}, "missing manifest section"),
            ({"manifest": {**valid_manifest, "exists": False}}, "does not exist"),
            ({"manifest": {**valid_manifest, "is_symlink": True}}, "path is a symlink"),
            ({"manifest": {**valid_manifest, "directory_is_symlink": True}}, "directory is a symlink"),
            (
                {"manifest": {key: value for key, value in valid_manifest.items() if key != "chart_storage_symlink_component"}},
                "missing chart_storage_symlink_component",
            ),
            (
                {"manifest": {**valid_manifest, "chart_storage_symlink_component": "/charts"}},
                "path contains a symlink",
            ),
            (
                {"manifest": {key: value for key, value in valid_manifest.items() if key != "manifest_symlink_component"}},
                "missing manifest_symlink_component",
            ),
            ({"manifest": {**valid_manifest, "error": "manifest path is not a regular file"}}, "manifest error"),
            ({"manifest": {**valid_manifest, "created_at_source": "manual"}}, "created_at_source manual is not verified"),
            (
                {"manifest": {**valid_manifest, "download_path_is_symlink": True}},
                "download path is a symlink",
            ),
            (
                {"manifest": {key: value for key, value in valid_manifest.items() if key != "download_path_symlink_component"}},
                "missing download_path_symlink_component",
            ),
            (
                {"manifest": {**valid_manifest, "extract_path_is_symlink": True}},
                "extract path is a symlink",
            ),
            (
                {"manifest": {key: value for key, value in valid_manifest.items() if key != "extract_path_symlink_component"}},
                "missing extract_path_symlink_component",
            ),
            (
                {"manifest": {**valid_manifest, "download_path_error": "manifest download path is not a regular file"}},
                "download path error",
            ),
            ({"manifest": {**valid_manifest, "download_bytes": 0}}, "download byte count is not positive"),
            ({"manifest": {**valid_manifest, "enc_cell_count": 0}}, "has no ENC cells"),
            ({"manifest": {**valid_manifest, "actual_enc_cell_count": 0}}, "actual ENC cell count is not positive"),
            (
                {"manifest": {**valid_manifest, "actual_enc_cell_count": 2}},
                "actual_enc_cell_count does not match enc_cell_count",
            ),
        ]
        for updates, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "manifest" not in updates:
                    report.pop("manifest", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(
                    any(failure.name == "Chart Manifest" and expected in failure.detail for failure in failures)
                )

    def test_status_report_ready_requires_valid_gps_fix_summary(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        cases = [
            ({}, "missing gps_fix section"),
            ({"gps_fix": {"ok": "yes", "detail": "truthy"}}, "ok is not boolean"),
            ({"gps_fix": {"ok": False, "detail": "no fix"}}, "not ok"),
            ({"gps_fix": {"ok": True, "source": "GPS"}}, "source GPS is not GPSD"),
            ({"gps_fix": {"ok": True, "source": "GPSD", "latitude": 0.0, "longitude": 0.0, "timestamp": now.isoformat().replace("+00:00", "Z"), "age_seconds": 0.0, "satellites": 8, "hdop": 0.9}}, "coordinates are invalid"),
            ({"gps_fix": {"ok": True, "source": "GPSD", "latitude": 61.0, "longitude": -149.0, "timestamp": "2026-07-01T12:00:00", "age_seconds": 0.0, "satellites": 8, "hdop": 0.9}}, "has no valid timestamp"),
            ({"gps_fix": {"ok": True, "source": "GPSD", "latitude": 61.0, "longitude": -149.0, "timestamp": (now - timedelta(seconds=601)).isoformat().replace("+00:00", "Z"), "age_seconds": 601.0, "satellites": 8, "hdop": 0.9}}, "timestamp is stale"),
            ({"gps_fix": {"ok": True, "source": "GPSD", "latitude": 61.0, "longitude": -149.0, "timestamp": (now - timedelta(seconds=120)).isoformat().replace("+00:00", "Z"), "age_seconds": 1.0, "satellites": 8, "hdop": 0.9}}, "inconsistent with timestamp age"),
            ({"gps_fix": {"ok": True, "source": "GPSD", "latitude": 61.0, "longitude": -149.0, "timestamp": (now - timedelta(seconds=120)).isoformat().replace("+00:00", "Z"), "age_seconds": 300.0, "satellites": 8, "hdop": 0.9}}, "inconsistent with timestamp age"),
            ({"gps_fix": {"ok": True, "source": "GPSD", "latitude": 61.0, "longitude": -149.0, "timestamp": now.isoformat().replace("+00:00", "Z"), "age_seconds": 0.0}}, "no satellite or HDOP quality fields"),
            ({"gps_fix": {"ok": True, "source": "GPSD", "latitude": 61.0, "longitude": -149.0, "timestamp": now.isoformat().replace("+00:00", "Z"), "age_seconds": 0.0, "satellites": 3, "hdop": 0.9}}, "satellites is weak"),
            ({"gps_fix": {"ok": True, "source": "GPSD", "latitude": 61.0, "longitude": -149.0, "timestamp": now.isoformat().replace("+00:00", "Z"), "age_seconds": 0.0, "satellites": 8, "hdop": 6.0}}, "hdop is weak"),
        ]
        for updates, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "gps_fix" not in updates:
                    report.pop("gps_fix", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(any(failure.name == "GPS Fix" and expected in failure.detail for failure in failures))

    def test_status_report_ready_requires_structured_gps_readiness_evidence(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        generated_at = now.isoformat().replace("+00:00", "Z")

        def fix_data(**overrides):
            data = {
                "timestamp": generated_at,
                "latitude": 61.2181,
                "longitude": -149.9003,
                "satellites": 8,
                "hdop": 0.9,
            }
            data.update(overrides)
            return data

        cases = [
            ("gpsd", "GPSD", None, "GPSD check has no structured fix data"),
            ("gpsd", "GPSD", fix_data(latitude="north"), "fix has non-numeric coordinates"),
            ("gpsd", "GPSD", fix_data(latitude=0.0, longitude=0.0), "fix coordinates are invalid 0,0"),
            ("gpsd", "GPSD", fix_data(timestamp="not-a-time"), "fix has no valid timestamp"),
            ("gpsd", "GPSD", fix_data(timestamp="2026-07-01T12:00:00"), "fix has no valid timestamp"),
            ("gpsd", "GPSD", fix_data(satellites=None, hdop=None), "fix has no satellite or HDOP quality fields"),
            ("gpsd", "GPSD", fix_data(satellites=3), "fix satellites is weak or invalid"),
            ("gpsd", "GPSD", fix_data(hdop=6.0), "fix HDOP is weak or invalid"),
            ("gpsd", "GPSD", fix_data(latitude=61.5), "latitude does not match gps_fix"),
            ("gpsd", "GPSD", fix_data(longitude=-149.5), "longitude does not match gps_fix"),
            ("gpsd", "GPSD", fix_data(timestamp=(now - timedelta(seconds=1)).isoformat().replace("+00:00", "Z")), "timestamp does not match gps_fix"),
            ("gpsd", "GPSD", fix_data(satellites=9), "satellites do not match gps_fix"),
            ("gpsd", "GPSD", fix_data(hdop=1.1), "HDOP does not match gps_fix"),
            ("serial", "GPS", None, "GPS check has no structured fix data"),
            ("serial", "GPS", fix_data(latitude=61.5), "latitude does not match gps_fix"),
        ]
        for gps_mode, row_name, data, expected in cases:
            with self.subTest(gps_mode=gps_mode, row_name=row_name, expected=expected):
                report = complete_status_gui_report(gps_mode=gps_mode, generated_at=generated_at)
                row = next(check for check in report["checks"] if check["name"] == row_name)
                if data is None:
                    row.pop("data", None)
                else:
                    row["data"] = data

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(any(failure.name == row_name and expected in failure.detail for failure in failures))

        report = complete_status_gui_report(generated_at=generated_at)
        report["checks"].append({"name": "GPS", "ok": True, "detail": "legacy serial row"})

        self.assertTrue(status_report_is_ready(report, now=now))
        self.assertFalse(status_report_validation_failures(report, now=now))

    def test_status_report_ready_requires_valid_track_log_summary(self):
        now = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
        valid_track_log = {
            "track_output": "/charts",
            "track_output_is_symlink": False,
            "track_storage_symlink_component": "",
            "tracks_dir": "/charts/tracks",
            "ok": True,
            "latest_path": "/charts/tracks/track-20260701.gpx",
            "latest_time": now.isoformat().replace("+00:00", "Z"),
            "latest_latitude": 61.0,
            "latest_longitude": -149.0,
            "age_seconds": 0.0,
            "latest_satellites": 8,
            "latest_hdop": 0.9,
        }
        cases = [
            ({}, "missing track_log section"),
            ({"track_log": {**valid_track_log, "ok": "yes"}}, "ok is not boolean"),
            ({"track_log": {**valid_track_log, "ok": False, "detail": "no track"}}, "is not ok"),
            ({"track_log": {**valid_track_log, "track_output_is_symlink": True}}, "track_output is a symlink"),
            ({"track_log": {key: value for key, value in valid_track_log.items() if key != "track_storage_symlink_component"}}, "missing track_storage_symlink_component"),
            ({"track_log": {**valid_track_log, "track_storage_symlink_component": "/charts"}}, "storage path contains a symlink"),
            ({"track_log": {**valid_track_log, "latest_path": ""}}, "has no latest_path"),
            ({"track_log": {key: value for key, value in valid_track_log.items() if key != "latest_time"}}, "has no valid latest_time"),
            ({"track_log": {**valid_track_log, "latest_time": "2026-07-01T12:00:00"}}, "has no valid latest_time"),
            ({"track_log": {**valid_track_log, "latest_time": (now + timedelta(seconds=31)).isoformat().replace("+00:00", "Z")}}, "latest_time is in the future"),
            ({"track_log": {**valid_track_log, "latest_time": (now - timedelta(seconds=601)).isoformat().replace("+00:00", "Z"), "age_seconds": 601.0}}, "latest_time is stale"),
            ({"track_log": {**valid_track_log, "latest_latitude": 0.0, "latest_longitude": 0.0}}, "coordinates are invalid"),
            ({"track_log": {**valid_track_log, "age_seconds": -1.0}}, "age_seconds is negative"),
            ({"track_log": {**valid_track_log, "age_seconds": 601.0}}, "age_seconds is stale"),
            ({"track_log": {**valid_track_log, "latest_time": (now - timedelta(seconds=120)).isoformat().replace("+00:00", "Z"), "age_seconds": 1.0}}, "inconsistent with latest_time age"),
            ({"track_log": {**valid_track_log, "latest_time": (now - timedelta(seconds=120)).isoformat().replace("+00:00", "Z"), "age_seconds": 300.0}}, "inconsistent with latest_time age"),
            ({"track_log": {key: value for key, value in valid_track_log.items() if key not in {"latest_satellites", "latest_hdop"}}}, "no latest satellite or HDOP quality fields"),
            ({"track_log": {**valid_track_log, "latest_satellites": 3}}, "latest_satellites is weak"),
            ({"track_log": {**valid_track_log, "latest_hdop": 6.0}}, "latest_hdop is weak"),
        ]
        for updates, expected in cases:
            with self.subTest(expected=expected):
                report = complete_status_gui_report(
                    generated_at=now.isoformat().replace("+00:00", "Z"),
                )
                report.update(updates)
                if "track_log" not in updates:
                    report.pop("track_log", None)

                failures = status_report_validation_failures(report, now=now)

                self.assertFalse(status_report_is_ready(report, now=now))
                self.assertTrue(any(failure.name == "Track Log" and expected in failure.detail for failure in failures))

    def test_verify_pi_required_status_checks_match_shared_gpsd_readiness(self):
        source = Path("scripts/verify_pi.sh").read_text(encoding="utf-8")

        self.assertEqual(
            verify_pi_string_set_assignment(source, "required_checks"),
            set(report_module.CORE_READINESS_CHECKS) | set(report_module.GPSD_READINESS_CHECKS),
        )
        self.assertEqual(
            verify_pi_string_set_assignment(source, "required_service_checks"),
            set(report_module.CORE_SERVICE_CHECKS) | set(report_module.GPSD_SERVICE_CHECKS),
        )

    def test_recovery_verifier_required_status_checks_match_shared_readiness(self):
        source = shell_python_heredoc(Path("scripts/verify_pi_recovery_exports.sh").read_text(encoding="utf-8"))

        self.assertEqual(
            python_string_set_assignment(source, "CORE_READINESS_CHECKS"),
            set(report_module.CORE_READINESS_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "GPSD_READINESS_CHECKS"),
            set(report_module.GPSD_READINESS_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "SERIAL_READINESS_CHECKS"),
            set(report_module.SERIAL_READINESS_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "PI_ONLY_READINESS_CHECKS"),
            {"Source Revision", "Time Sync", "Pi Power", "Pi Thermal", "Chrony Config", "GPS Time Source"},
        )
        self.assertEqual(
            python_string_set_assignment(source, "CORE_SERVICE_CHECKS"),
            set(report_module.CORE_SERVICE_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "GPSD_SERVICE_CHECKS"),
            set(report_module.GPSD_SERVICE_CHECKS),
        )

    def test_post_trip_required_status_checks_match_shared_readiness(self):
        source = shell_function_python_heredoc(
            Path("scripts/post_trip_collect_pi.sh").read_text(encoding="utf-8"),
            "verify_status_snapshot_json",
        )

        self.assertEqual(
            python_string_set_assignment(source, "CORE_READINESS_CHECKS"),
            set(report_module.CORE_READINESS_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "GPSD_READINESS_CHECKS"),
            set(report_module.GPSD_READINESS_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "SERIAL_READINESS_CHECKS"),
            set(report_module.SERIAL_READINESS_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "PI_ONLY_READINESS_CHECKS"),
            {"Source Revision", "Time Sync", "Pi Power", "Pi Thermal", "Chrony Config", "GPS Time Source"},
        )
        self.assertEqual(
            python_string_set_assignment(source, "CORE_SERVICE_CHECKS"),
            set(report_module.CORE_SERVICE_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "GPSD_SERVICE_CHECKS"),
            set(report_module.GPSD_SERVICE_CHECKS),
        )

    def test_pre_trip_required_status_checks_match_shared_readiness(self):
        source = shell_function_python_heredoc(
            Path("scripts/pre_trip_prepare_pi.sh").read_text(encoding="utf-8"),
            "save_pre_departure_status_snapshot",
        )

        self.assertEqual(
            python_string_set_assignment(source, "CORE_READINESS_CHECKS"),
            set(report_module.CORE_READINESS_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "GPSD_READINESS_CHECKS"),
            set(report_module.GPSD_READINESS_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "SERIAL_READINESS_CHECKS"),
            set(report_module.SERIAL_READINESS_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "PI_ONLY_READINESS_CHECKS"),
            {"Source Revision", "Time Sync", "Pi Power", "Pi Thermal", "Chrony Config", "GPS Time Source"},
        )
        self.assertEqual(
            python_string_set_assignment(source, "CORE_SERVICE_CHECKS"),
            set(report_module.CORE_SERVICE_CHECKS),
        )
        self.assertEqual(
            python_string_set_assignment(source, "GPSD_SERVICE_CHECKS"),
            set(report_module.GPSD_SERVICE_CHECKS),
        )

    def test_verify_pi_validates_status_report_service_summaries(self):
        source = Path("scripts/verify_pi.sh").read_text(encoding="utf-8")

        for expected in [
            "def require_status_unit",
            'services = report.get("services")',
            'system_services = report.get("system_services")',
            'status report has no {summary_name} section',
            'status report {unit} loaded properties missing',
            '"noaa-navionics-track.service"',
            '"gpsd.socket"',
            '"chrony.service"',
        ]:
            with self.subTest(expected=expected):
                self.assertIn(expected, source)

    def test_verify_pi_rejects_timezone_less_live_timestamps(self):
        source = Path("scripts/verify_pi.sh").read_text(encoding="utf-8")

        for expected in [
            "def parse_timezone_aware_timestamp",
            "timestamp must include a timezone",
            'parse_timezone_aware_timestamp(generated_at, "status report generated_at")',
            'parse_timezone_aware_timestamp(gps_timestamp, "status report gps_fix")',
            'parse_timezone_aware_timestamp(timestamp_text, "launcher startup")',
            "def parse_gpx_trackpoint_timestamp",
            "has a timezone-less GPX trackpoint timestamp",
            "parse_gpx_trackpoint_timestamp(timestamp_text)",
        ]:
            with self.subTest(expected=expected):
                self.assertIn(expected, source)

    def test_status_snapshot_validators_require_usable_timezone_offsets(self):
        for script in (
            "scripts/pre_trip_prepare_pi.sh",
            "scripts/verify_pi_recovery_exports.sh",
            "scripts/post_trip_collect_pi.sh",
        ):
            with self.subTest(script=script):
                source = Path(script).read_text(encoding="utf-8")
                self.assertIn(
                    "parsed_generated_at.tzinfo is None or parsed_generated_at.utcoffset() is None",
                    source,
                )

    def test_status_snapshot_validators_reject_non_pi_diagnostic_skips(self):
        for script in (
            "scripts/pre_trip_prepare_pi.sh",
            "scripts/verify_pi_recovery_exports.sh",
            "scripts/post_trip_collect_pi.sh",
        ):
            with self.subTest(script=script):
                source = Path(script).read_text(encoding="utf-8")
                self.assertIn("PI_ONLY_READINESS_CHECKS", source)
                self.assertIn('get("is_raspberry_pi") is False', source)
                self.assertIn('get("skipped") is True', source)
                self.assertIn("records non-Pi diagnostic skip(s)", source)

    def test_status_snapshot_validators_reject_non_boolean_row_ok_values(self):
        for script in (
            "scripts/pre_trip_prepare_pi.sh",
            "scripts/verify_pi_recovery_exports.sh",
            "scripts/post_trip_collect_pi.sh",
        ):
            with self.subTest(script=script):
                source = Path(script).read_text(encoding="utf-8")
                self.assertIn('not isinstance(row.get("ok"), bool)', source)
                self.assertIn("readiness check {name} ok is not boolean", source)
                self.assertIn("service check {name} ok is not boolean", source)

    def test_status_snapshot_validators_reject_non_boolean_summary_ok_values(self):
        expectations = {
            "scripts/pre_trip_prepare_pi.sh": (
                "pre-departure status snapshot JSON gps_fix ok is not boolean",
                "pre-departure status snapshot JSON track_log ok is not boolean",
                "pre-departure status snapshot JSON gps_fix is not ok",
                "pre-departure status snapshot JSON track_log is not ok",
            ),
            "scripts/verify_pi_recovery_exports.sh": (
                "pre-departure status snapshot JSON gps_fix ok is not boolean",
                "pre-departure status snapshot JSON track_log ok is not boolean",
                "pre-departure status snapshot JSON gps_fix is not ok",
                "pre-departure status snapshot JSON track_log is not ok",
            ),
            "scripts/post_trip_collect_pi.sh": (
                "status snapshot JSON gps_fix ok is not boolean",
                "status snapshot JSON track_log ok is not boolean",
                "status snapshot JSON gps_fix is not ok",
                "status snapshot JSON track_log is not ok",
            ),
        }
        for script, expected_messages in expectations.items():
            with self.subTest(script=script):
                source = Path(script).read_text(encoding="utf-8")
                for expected in expected_messages:
                    with self.subTest(expected=expected):
                        self.assertIn(expected, source)

    def test_status_snapshot_validators_require_structured_gps_and_track_summaries(self):
        expectations = {
            "scripts/pre_trip_prepare_pi.sh": (
                "pre-departure status snapshot JSON gps_fix has non-numeric coordinates",
                "pre-departure status snapshot JSON {field} timestamp must include a timezone",
                "pre-departure status snapshot JSON {label} has no satellite or HDOP quality fields",
                "pre-departure status snapshot JSON {expected_name} latitude does not match gps_fix",
                "pre-departure status snapshot JSON {expected_name} timestamp does not match gps_fix",
                "pre-departure status snapshot JSON {expected_name} HDOP does not match gps_fix",
                "pre-departure status snapshot JSON config chart_output is not absolute",
                "pre-departure status snapshot JSON missing config track_output",
                "pre-departure status snapshot JSON config track_output is not absolute",
                "pre-departure status snapshot JSON Charts path does not match config chart_output",
                "pre-departure status snapshot JSON Chart Update Debris found stale update debris",
                "pre-departure status snapshot JSON OpenCPN Charts parsed directories do not include configured chart output",
                "pre-departure status snapshot JSON Manifest row has no top-level manifest summary",
                "pre-departure status snapshot JSON Manifest path does not match manifest summary",
                "pre-departure status snapshot JSON Manifest created_at_source is not verified",
                "pre-departure status snapshot JSON Manifest actual ENC cell count does not match manifest summary",
                "pre-departure status snapshot JSON track_log missing latest_path",
                "pre-departure status snapshot JSON track_log track_output is a symlink or missing symlink status",
                "pre-departure status snapshot JSON track_log track_output does not match config track_output",
                "pre-departure status snapshot JSON track_log tracks_dir does not match config track_output",
                "pre-departure status snapshot JSON {field} age_seconds is inconsistent with timestamp age",
            ),
            "scripts/verify_pi_recovery_exports.sh": (
                "pre-departure status snapshot JSON gps_fix has non-numeric coordinates",
                "pre-departure status snapshot JSON {field} timestamp must include a timezone",
                "pre-departure status snapshot JSON {label} has no satellite or HDOP quality fields",
                "pre-departure status snapshot JSON {expected_name} latitude does not match gps_fix",
                "pre-departure status snapshot JSON {expected_name} timestamp does not match gps_fix",
                "pre-departure status snapshot JSON {expected_name} HDOP does not match gps_fix",
                "pre-departure status snapshot JSON config chart_output is not absolute",
                "pre-departure status snapshot JSON missing config track_output",
                "pre-departure status snapshot JSON config track_output is not absolute",
                "pre-departure status snapshot JSON Charts path does not match config chart_output",
                "pre-departure status snapshot JSON Chart Update Debris found stale update debris",
                "pre-departure status snapshot JSON OpenCPN Charts parsed directories do not include configured chart output",
                "pre-departure status snapshot JSON Manifest row has no top-level manifest summary",
                "pre-departure status snapshot JSON Manifest path does not match manifest summary",
                "pre-departure status snapshot JSON Manifest created_at_source is not verified",
                "pre-departure status snapshot JSON Manifest actual ENC cell count does not match manifest summary",
                "pre-departure status snapshot JSON track_log missing latest_path",
                "pre-departure status snapshot JSON track_log track_output is a symlink or missing symlink status",
                "pre-departure status snapshot JSON track_log track_output does not match config track_output",
                "pre-departure status snapshot JSON track_log tracks_dir does not match config track_output",
                "pre-departure status snapshot JSON {field} age_seconds is inconsistent with timestamp age",
            ),
            "scripts/post_trip_collect_pi.sh": (
                "status snapshot JSON gps_fix has non-numeric coordinates",
                "status snapshot JSON {field} timestamp must include a timezone",
                "status snapshot JSON {label} has no satellite or HDOP quality fields",
                "status snapshot JSON {expected_name} latitude does not match gps_fix",
                "status snapshot JSON {expected_name} timestamp does not match gps_fix",
                "status snapshot JSON {expected_name} HDOP does not match gps_fix",
                "status snapshot JSON config chart_output is not absolute",
                "status snapshot JSON missing config track_output",
                "status snapshot JSON config track_output is not absolute",
                "status snapshot JSON Charts path does not match config chart_output",
                "status snapshot JSON Chart Update Debris found stale update debris",
                "status snapshot JSON OpenCPN Charts parsed directories do not include configured chart output",
                "status snapshot JSON Manifest row has no top-level manifest summary",
                "status snapshot JSON Manifest path does not match manifest summary",
                "status snapshot JSON Manifest created_at_source is not verified",
                "status snapshot JSON Manifest actual ENC cell count does not match manifest summary",
                "status snapshot JSON track_log missing latest_path",
                "status snapshot JSON track_log track_output is a symlink or missing symlink status",
                "status snapshot JSON track_log track_output does not match config track_output",
                "status snapshot JSON track_log tracks_dir does not match config track_output",
                "status snapshot JSON {field} age_seconds is inconsistent with timestamp age",
            ),
        }
        for script, expected_messages in expectations.items():
            with self.subTest(script=script):
                source = Path(script).read_text(encoding="utf-8")
                for expected in expected_messages:
                    with self.subTest(expected=expected):
                        self.assertIn(expected, source)

    def test_status_snapshot_validators_reject_source_revision_row_mismatches(self):
        for script in (
            "scripts/pre_trip_prepare_pi.sh",
            "scripts/verify_pi_recovery_exports.sh",
            "scripts/post_trip_collect_pi.sh",
        ):
            with self.subTest(script=script):
                source = Path(script).read_text(encoding="utf-8")
                self.assertIn("Source Revision row missing revision", source)
                self.assertIn("Source Revision row records a dirty revision", source)
                self.assertIn("Source Revision row does not match deployed source_revision", source)

        verify_source = shell_function_python_heredoc(
            Path("scripts/verify_pi.sh").read_text(encoding="utf-8"),
            "check_status_report_json",
        )
        for expected in (
            "status report Source Revision row missing structured data",
            "status report Source Revision row missing revision",
            "status report Source Revision row records a dirty revision",
            "status report Source Revision row does not match deployed source revision",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, verify_source)

    def test_verify_pi_rejects_malformed_or_duplicate_status_rows(self):
        verify_source = shell_function_python_heredoc(
            Path("scripts/verify_pi.sh").read_text(encoding="utf-8"),
            "check_status_report_json",
        )

        for expected in (
            "status report has malformed checks row",
            "status report has unnamed readiness check",
            "status report {name} ok is not boolean",
            "status report has duplicate readiness check",
            "status report has malformed service_checks row",
            "status report has unnamed service check",
            "status report has duplicate service check",
            "missing_checks = sorted(required_checks - set(check_rows))",
            "missing_service_checks = sorted(required_service_checks - set(service_rows))",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, verify_source)

    def test_status_report_with_gps_sample_still_checks_opencpn_gpsd_config(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            cell = charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            archive = charts / "AK_ENCs.zip"
            archive.write_bytes(b"x")
            manifest = charts / MANIFEST_NAME
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            manifest.write_text(
                '{"created_at":"' + now + '",'
                '"created_at_source":"download",'
                '"package":{"label":"Test","filename":"AK_ENCs.zip","url":"file:///test.zip"},'
                f'"download":{{"path":"{archive}","url":"file:///test.zip","bytes":1,"sha256":"abc","skipped":false}},'
                f'"extract":{{"path":"{cell.parent}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            sample = root / "sample.nmea"
            gps_sample_time = (datetime.now(timezone.utc) - timedelta(seconds=5)).strftime("%H%M%S")
            sample.write_text(
                f"$GPGGA,{gps_sample_time},4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,\n",
                encoding="ascii",
            )
            with GPXTrackLogger(charts / "tracks" / "track-20260629.gpx") as logger:
                logger.append(
                    GPSFix(
                        latitude=61.2181,
                        longitude=-149.9003,
                        timestamp=datetime.now(timezone.utc),
                        satellites=8,
                        hdop=1.2,
                    )
                )
            config = root / "config.ini"
            config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {charts}\n"
                "min_free_gb = 0.1\n"
                "\n"
                "[gps]\n"
                "mode = gpsd\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n"
                "\n"
                "[tracking]\n"
                f"output = {charts}\n",
                encoding="utf-8",
            )
            opencpn_config = root / "opencpn.conf"
            configure_chart_directory(charts, config_path=opencpn_config)
            original_opencpn_config_path = opencpn_module.DEFAULT_OPENCPN_CONFIG_PATH
            original_flatpak_opencpn_config_path = opencpn_module.FLATPAK_OPENCPN_CONFIG_PATH
            opencpn_module.DEFAULT_OPENCPN_CONFIG_PATH = opencpn_config
            opencpn_module.FLATPAK_OPENCPN_CONFIG_PATH = root / "missing-flatpak-opencpn.conf"
            try:
                report = build_status_report(config_path=config, gps_sample=sample)
            finally:
                opencpn_module.DEFAULT_OPENCPN_CONFIG_PATH = original_opencpn_config_path
                opencpn_module.FLATPAK_OPENCPN_CONFIG_PATH = original_flatpak_opencpn_config_path

            opencpn_gpsd_check = next(check for check in report["checks"] if check["name"] == "OpenCPN GPSD")
            self.assertFalse(opencpn_gpsd_check["ok"])
            self.assertIn("not listed", opencpn_gpsd_check["detail"])
            self.assertFalse(report["ok"])

    def test_app_summary_rejects_symlinked_source_revision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_revision = root / "real-source-revision"
            real_revision.write_text("unexpected\n", encoding="utf-8")
            link_revision = root / "source-revision"
            try:
                link_revision.symlink_to(real_revision)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(link_revision)
            try:
                summary = report_module._app_summary()
            finally:
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_path"], str(link_revision))
            self.assertEqual(summary["source_revision_path_is_symlink"], True)
            self.assertEqual(summary["source_revision_directory_is_symlink"], False)
            self.assertEqual(summary["source_revision_symlink_component"], "")
            self.assertIn("source revision path is a symlink", summary["source_revision_error"])

    def test_app_summary_rejects_symlinked_source_revision_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_dir = root / "real-source"
            real_dir.mkdir()
            real_revision = real_dir / "source-revision"
            real_revision.write_text("unexpected\n", encoding="utf-8")
            link_dir = root / "source-link"
            try:
                link_dir.symlink_to(real_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_revision = link_dir / "source-revision"

            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(link_revision)
            try:
                summary = report_module._app_summary()
            finally:
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_path"], str(link_revision))
            self.assertEqual(summary["source_revision_path_is_symlink"], False)
            self.assertEqual(summary["source_revision_directory_is_symlink"], True)
            self.assertEqual(summary["source_revision_symlink_component"], str(link_dir))
            self.assertIn("source revision directory is a symlink", summary["source_revision_error"])

    def test_app_summary_rejects_symlinked_source_revision_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_root = root / "real-install"
            real_dir = real_root / "noaa-navionics"
            real_dir.mkdir(parents=True)
            real_revision = real_dir / "source-revision"
            real_revision.write_text("unexpected\n", encoding="utf-8")
            link_root = root / "install-link"
            try:
                link_root.symlink_to(real_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_revision = link_root / "noaa-navionics" / "source-revision"

            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(link_revision)
            try:
                summary = report_module._app_summary()
            finally:
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_path"], str(link_revision))
            self.assertEqual(summary["source_revision_path_is_symlink"], False)
            self.assertEqual(summary["source_revision_directory_is_symlink"], False)
            self.assertEqual(summary["source_revision_symlink_component"], str(link_root))
            self.assertIn("source revision directory is a symlink", summary["source_revision_error"])

    def test_app_summary_rejects_nonregular_source_revision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.mkdir()

            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(revision)
            try:
                summary = report_module._app_summary()
            finally:
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_exists"], True)
            self.assertIn("source revision path is not a regular file", summary["source_revision_error"])

    def test_app_summary_rejects_writable_source_revision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o620)

            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(revision)
            try:
                summary = report_module._app_summary()
            finally:
                revision.chmod(0o600)
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_mode"], "0620")
            self.assertIn("source revision path", summary["source_revision_error"])
            self.assertIn("has permissions 0620", summary["source_revision_error"])

    def test_app_summary_rejects_writable_source_revision_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / "source-root"
            parent.mkdir()
            revision = parent / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o600)
            parent.chmod(0o777)
            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(revision)
            try:
                summary = report_module._app_summary()
            finally:
                parent.chmod(0o700)
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_directory_uid"], os.getuid())
            self.assertEqual(summary["source_revision_directory_mode"], "0777")
            self.assertIn("source revision directory", summary["source_revision_error"])
            self.assertIn("has permissions 0777", summary["source_revision_error"])

    def test_source_revision_reader_rejects_writable_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o622)
            try:
                with self.assertRaisesRegex(RuntimeError, "source revision path .* has permissions 0622"):
                    report_module._source_revision(revision)
            finally:
                revision.chmod(0o600)

    def test_source_revision_reader_rejects_replaced_file_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            revision = root / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o600)
            expected_stat = revision.stat()
            replacement = root / "replacement-source-revision"
            replacement.write_text("unexpected\n", encoding="utf-8")
            replacement.chmod(0o600)
            replacement.replace(revision)

            with self.assertRaisesRegex(RuntimeError, "changed before it could be read"):
                report_module._read_source_revision_text(revision, expected_stat=expected_stat)

    def test_launcher_settings_summary_rejects_symlinked_environment(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_env = root / "real-launcher.env"
            real_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=10\n", encoding="ascii")
            link_env = root / "launcher.env"
            try:
                link_env.symlink_to(real_env)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = _launcher_settings_summary(link_env)

            self.assertEqual(summary["path"], str(link_env))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], True)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["launcher_settings_symlink_component"], "")
            self.assertIn("launcher environment path is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_launcher_settings_summary_rejects_symlinked_environment_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config = root / "real-config"
            real_config.mkdir()
            real_env = real_config / "launcher.env"
            real_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=10\n", encoding="ascii")
            link_config = root / "linked-config"
            try:
                link_config.symlink_to(real_config, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_env = link_config / "launcher.env"

            summary = _launcher_settings_summary(link_env)

            self.assertEqual(summary["path"], str(link_env))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], True)
            self.assertEqual(summary["launcher_settings_symlink_component"], str(link_config))
            self.assertIn("launcher environment directory is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_launcher_settings_summary_rejects_symlinked_environment_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_home = root / "real-home"
            real_config = real_home / ".config" / "noaa-navionics"
            real_config.mkdir(parents=True)
            real_env = real_config / "launcher.env"
            real_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=10\n", encoding="ascii")
            link_home = root / "home-link"
            try:
                link_home.symlink_to(real_home, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_env = link_home / ".config" / "noaa-navionics" / "launcher.env"

            summary = _launcher_settings_summary(link_env)

            self.assertEqual(summary["path"], str(link_env))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["launcher_settings_symlink_component"], str(link_home))
            self.assertIn("launcher environment directory is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_launcher_settings_summary_records_malformed_environment_lines(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            launcher_env = Path(tmpdir) / "launcher.env"
            launcher_env.write_text(
                "NOAA_NAVIONICS_GPS_SECONDS=60\n"
                "# comment\n"
                "not-a-setting\n",
                encoding="ascii",
            )
            launcher_env.chmod(0o600)

            summary = _launcher_settings_summary(launcher_env)

            self.assertEqual(summary["values"]["NOAA_NAVIONICS_GPS_SECONDS"], "60")
            self.assertEqual(summary["malformed_lines"], ["3: not-a-setting"])

    def test_launcher_settings_summary_rejects_nonregular_environment(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            launcher_env = Path(tmpdir) / "launcher.env"
            launcher_env.mkdir()

            summary = _launcher_settings_summary(launcher_env)
            check = _launcher_settings_check(summary)

            self.assertEqual(summary["path"], str(launcher_env))
            self.assertEqual(summary["exists"], True)
            self.assertIn("not a regular file", summary["error"])
            self.assertFalse(check.ok)
            self.assertIn("not a regular file", check.detail)

    def test_launcher_settings_summary_records_owner_and_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            launcher_env = Path(tmpdir) / "launcher.env"
            launcher_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=60\n", encoding="ascii")
            launcher_env.chmod(0o600)

            summary = _launcher_settings_summary(launcher_env)

            self.assertEqual(summary["directory_uid"], os.getuid())
            self.assertEqual(summary["directory_mode"], f"{launcher_env.parent.stat().st_mode & 0o777:04o}")
            self.assertEqual(summary["uid"], os.getuid())
            self.assertEqual(summary["mode"], "0600")
            self.assertEqual(summary["values"]["NOAA_NAVIONICS_GPS_SECONDS"], "60")

    def test_launcher_settings_summary_records_public_environment_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / "launcher-parent"
            parent.mkdir()
            launcher_env = parent / "launcher.env"
            launcher_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=60\n", encoding="ascii")
            launcher_env.chmod(0o600)
            parent.chmod(0o777)
            try:
                summary = _launcher_settings_summary(launcher_env)
                check = _launcher_settings_check(summary)
            finally:
                parent.chmod(0o700)

            self.assertEqual(summary["directory_uid"], os.getuid())
            self.assertEqual(summary["directory_mode"], "0777")
            self.assertFalse(check.ok)
            self.assertIn("launcher environment directory", check.detail)
            self.assertIn("expected no group/other write bits", check.detail)

    def test_launcher_settings_summary_rejects_public_environment_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            launcher_env = Path(tmpdir) / "launcher.env"
            launcher_env.write_text("NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes\n", encoding="ascii")
            launcher_env.chmod(0o644)

            summary = _launcher_settings_summary(launcher_env)
            check = _launcher_settings_check(summary)

            self.assertEqual(summary["uid"], os.getuid())
            self.assertEqual(summary["mode"], "0644")
            self.assertIn("expected private 0600", summary["error"])
            self.assertNotIn("values", summary)
            self.assertFalse(check.ok)
            self.assertIn("expected private 0600", check.detail)

    def test_launcher_settings_reader_rejects_replaced_environment_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            launcher_env = root / "launcher.env"
            launcher_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=60\n", encoding="ascii")
            launcher_env.chmod(0o600)
            expected_stat = launcher_env.stat()
            replacement = root / "replacement-launcher.env"
            replacement.write_text("NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes\n", encoding="ascii")
            replacement.chmod(0o600)
            replacement.replace(launcher_env)

            with self.assertRaisesRegex(RuntimeError, "launcher environment changed before it could be read"):
                report_module._read_launcher_settings_lines(launcher_env, expected_stat=expected_stat)

    def test_launcher_settings_check_fails_symlinked_environment_ancestor(self):
        check = _launcher_settings_check(trusted_launcher_settings(launcher_settings_symlink_component="/home/pi"))

        self.assertFalse(check.ok)
        self.assertIn("launcher environment directory is a symlink: /home/pi", check.detail)

    def test_launcher_settings_check_fails_misowned_environment(self):
        check = _launcher_settings_check(trusted_launcher_settings(uid=os.getuid() + 1))

        self.assertFalse(check.ok)
        self.assertIn("owned by uid", check.detail)

    def test_launcher_settings_check_fails_unknown_environment_keys(self):
        check = _launcher_settings_check(
            trusted_launcher_settings(
                values={
                    "NOAA_NAVIONICS_GPS_SECONDS": "60",
                    "NOAA_NAVIONICS_UNEXPECTED": "1",
                },
            )
        )

        self.assertFalse(check.ok)
        self.assertIn("unknown launcher environment key(s): NOAA_NAVIONICS_UNEXPECTED", check.detail)

    def test_launcher_settings_check_fails_malformed_environment_lines(self):
        check = _launcher_settings_check(trusted_launcher_settings(malformed_lines=["2: not-a-setting"]))

        self.assertFalse(check.ok)
        self.assertIn("malformed launcher environment line 2: not-a-setting", check.detail)

    def test_key_value_file_summary_rejects_symlinked_startup_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_file = root / "real.desktop"
            real_file.write_text("[Desktop Entry]\nName=Unexpected\n", encoding="utf-8")
            link_file = root / "noaa-navionics-chartplotter.desktop"
            try:
                link_file.symlink_to(real_file)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = _key_value_file_summary(link_file, comment_prefixes=("#",))

            self.assertEqual(summary["path"], str(link_file))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], True)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["path_symlink_component"], "")
            self.assertIn("key-value file path is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_key_value_file_summary_rejects_symlinked_startup_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_dir = root / "real-autostart"
            real_dir.mkdir()
            real_file = real_dir / "noaa-navionics-chartplotter.desktop"
            real_file.write_text("[Desktop Entry]\nName=Unexpected\n", encoding="utf-8")
            link_dir = root / "autostart"
            try:
                link_dir.symlink_to(real_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_file = link_dir / "noaa-navionics-chartplotter.desktop"

            summary = _key_value_file_summary(link_file, comment_prefixes=("#",))

            self.assertEqual(summary["path"], str(link_file))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], True)
            self.assertEqual(summary["path_symlink_component"], str(link_dir))
            self.assertIn("key-value file directory is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_key_value_file_summary_rejects_symlinked_startup_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_home = root / "real-home"
            real_autostart = real_home / ".config" / "autostart"
            real_autostart.mkdir(parents=True)
            real_file = real_autostart / "noaa-navionics-chartplotter.desktop"
            real_file.write_text("[Desktop Entry]\nName=Unexpected\n", encoding="utf-8")
            link_home = root / "home-link"
            try:
                link_home.symlink_to(real_home, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_file = link_home / ".config" / "autostart" / "noaa-navionics-chartplotter.desktop"

            summary = _key_value_file_summary(link_file, comment_prefixes=("#",))

            self.assertEqual(summary["path"], str(link_file))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["path_symlink_component"], str(link_home))
            self.assertIn("key-value file directory is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_key_value_file_summary_rejects_nonregular_startup_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "noaa-navionics-chartplotter.desktop"
            path.mkdir()

            summary = _key_value_file_summary(path, comment_prefixes=("#",))

            self.assertEqual(summary["path"], str(path))
            self.assertEqual(summary["exists"], True)
            self.assertIn("key-value file path is not a regular file", summary["error"])
            self.assertNotIn("values", summary)

    def test_key_value_file_summary_records_owner_and_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "noaa-navionics-chartplotter.desktop"
            path.write_text("[Desktop Entry]\nName=NOAA Navionics Chartplotter\n", encoding="utf-8")
            path.chmod(0o640)

            summary = _key_value_file_summary(path, comment_prefixes=("#",))

            self.assertEqual(summary["uid"], os.getuid())
            self.assertEqual(summary["mode"], "0640")
            self.assertEqual(summary["values"]["Name"], "NOAA Navionics Chartplotter")

    def test_key_value_file_summary_rejects_writable_startup_file_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "noaa-navionics-chartplotter.desktop"
            path.write_text("[Desktop Entry]\nName=Unexpected\n", encoding="utf-8")
            path.chmod(0o622)

            summary = _key_value_file_summary(path, comment_prefixes=("#",))

            self.assertIn("has permissions 0622", summary["error"])
            self.assertIn("expected no group/other write bits", summary["error"])
            self.assertNotIn("values", summary)

    def test_key_value_file_reader_rejects_replaced_startup_file_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            path = root / "noaa-navionics-chartplotter.desktop"
            path.write_text("[Desktop Entry]\nName=NOAA Navionics Chartplotter\n", encoding="utf-8")
            path.chmod(0o640)
            expected_stat = path.stat()
            replacement = root / "replacement.desktop"
            replacement.write_text("[Desktop Entry]\nName=Unexpected\nHidden=true\n", encoding="utf-8")
            replacement.chmod(0o640)
            replacement.replace(path)

            with self.assertRaisesRegex(RuntimeError, "key-value file path changed before it could be read"):
                report_module._read_key_value_file_lines(path, expected_stat=expected_stat)

    def test_opencpn_config_summary_rejects_symlinked_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_config = root / "real-opencpn.conf"
            configure_chart_directory(charts, config_path=real_config)
            link_config = root / "opencpn.conf"
            try:
                link_config.symlink_to(real_config)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = report_module._opencpn_config_summary(link_config)

            self.assertEqual(summary["path"], str(link_config))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], True)
            self.assertIn("OpenCPN config path is a symlink", summary["error"])
            self.assertNotIn("chart_directories", summary)
            self.assertNotIn("data_connections", summary)

    def test_opencpn_config_summary_rejects_symlinked_config_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_config_dir = root / "real-opencpn"
            real_config_dir.mkdir()
            real_config = real_config_dir / "opencpn.conf"
            configure_chart_directory(charts, config_path=real_config)
            link_config_dir = root / "opencpn-link"
            try:
                link_config_dir.symlink_to(real_config_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            config = link_config_dir / "opencpn.conf"

            summary = report_module._opencpn_config_summary(config)

            self.assertEqual(summary["path"], str(config))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], True)
            self.assertEqual(summary["config_symlink_component"], str(link_config_dir))
            self.assertIn("OpenCPN config directory is a symlink", summary["error"])
            self.assertNotIn("chart_directories", summary)
            self.assertNotIn("data_connections", summary)

    def test_opencpn_config_summary_rejects_symlinked_config_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_config_root = root / "real-config-root"
            real_config_dir = real_config_root / "opencpn"
            real_config_dir.mkdir(parents=True)
            real_config = real_config_dir / "opencpn.conf"
            configure_chart_directory(charts, config_path=real_config)
            link_config_root = root / "config-link"
            try:
                link_config_root.symlink_to(real_config_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            config = link_config_root / "opencpn" / "opencpn.conf"

            summary = report_module._opencpn_config_summary(config)

            self.assertEqual(summary["path"], str(config))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["config_symlink_component"], str(link_config_root))
            self.assertIn("OpenCPN config directory is a symlink", summary["error"])
            self.assertNotIn("chart_directories", summary)
            self.assertNotIn("data_connections", summary)

    def test_opencpn_config_summary_rejects_nonregular_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.mkdir()

            summary = report_module._opencpn_config_summary(config)

            self.assertEqual(summary["path"], str(config))
            self.assertEqual(summary["exists"], True)
            self.assertIn("OpenCPN config path is not a regular file", summary["error"])
            self.assertNotIn("chart_directories", summary)
            self.assertNotIn("data_connections", summary)

    def test_opencpn_config_summary_records_owner_and_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            config = root / "opencpn.conf"
            configure_chart_directory(charts, config_path=config)
            config.chmod(0o640)

            summary = report_module._opencpn_config_summary(config)

            self.assertEqual(summary["uid"], os.getuid())
            self.assertEqual(summary["mode"], "0640")
            self.assertEqual(summary["directory_uid"], os.getuid())
            self.assertEqual(summary["directory_mode"], "0700")
            self.assertEqual(summary["chart_directories"], [str(charts.resolve())])

    def test_opencpn_config_summary_records_public_directory_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config_dir = root / "opencpn"
            config_dir.mkdir()
            config = config_dir / "opencpn.conf"
            config.write_text("[ChartDirectories]\n", encoding="utf-8")
            config.chmod(0o600)
            config_dir.chmod(0o755)
            try:
                summary = report_module._opencpn_config_summary(config)
            finally:
                config_dir.chmod(0o700)

            self.assertEqual(summary["directory_uid"], os.getuid())
            self.assertEqual(summary["directory_mode"], "0755")

    def test_manifest_summary_rejects_symlinked_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_manifest = root / "real-manifest.json"
            real_manifest.write_text(
                '{"created_at":"2000-01-01T00:00:00Z","package":{"label":"Old"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )
            manifest = charts / MANIFEST_NAME
            try:
                manifest.symlink_to(real_manifest)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["path"], str(manifest))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], True)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertIn("manifest path is a symlink", summary["error"])
            self.assertNotIn("created_at", summary)

    def test_manifest_summary_rejects_symlinked_manifest_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_charts = root / "real-charts"
            real_charts.mkdir()
            (real_charts / MANIFEST_NAME).write_text(
                '{"created_at":"2000-01-01T00:00:00Z","package":{"label":"Old"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )
            link_charts = root / "charts-link"
            try:
                link_charts.symlink_to(real_charts, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = report_module._manifest_summary(link_charts)

            self.assertEqual(summary["path"], str(link_charts / MANIFEST_NAME))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], True)
            self.assertEqual(summary["chart_storage_symlink_component"], str(link_charts))
            self.assertEqual(summary["manifest_symlink_component"], str(link_charts))
            self.assertIn("manifest directory is a symlink", summary["error"])
            self.assertNotIn("created_at", summary)

    def test_manifest_summary_rejects_symlinked_manifest_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_root = root / "real-root"
            real_charts = real_root / "charts"
            real_charts.mkdir(parents=True)
            (real_charts / MANIFEST_NAME).write_text(
                '{"created_at":"2000-01-01T00:00:00Z","package":{"label":"Old"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )
            link_root = root / "root-link"
            try:
                link_root.symlink_to(real_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            charts = link_root / "charts"

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["path"], str(charts / MANIFEST_NAME))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["chart_storage_symlink_component"], str(link_root))
            self.assertEqual(summary["manifest_symlink_component"], str(link_root))
            self.assertIn("manifest directory is a symlink", summary["error"])
            self.assertNotIn("created_at", summary)

    def test_manifest_summary_rejects_nonregular_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            charts = Path(tmpdir) / "charts"
            charts.mkdir()
            manifest = charts / MANIFEST_NAME
            manifest.mkdir()

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["path"], str(manifest))
            self.assertEqual(summary["exists"], True)
            self.assertIn("manifest path is not a regular file", summary["error"])
            self.assertNotIn("created_at", summary)

    def test_manifest_summary_records_owner_and_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            charts = Path(tmpdir) / "charts"
            charts.mkdir()
            extract = charts / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            manifest = charts / MANIFEST_NAME
            manifest.write_text(
                '{"created_at":"2000-01-01T00:00:00Z",'
                '"package":{"label":"Test","filename":"AK_ENCs.zip","url":"file:///test.zip"},'
                '"download":{"path":"","url":"file:///test.zip","bytes":1,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            manifest.chmod(0o640)

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["uid"], os.getuid())
            self.assertEqual(summary["mode"], "0640")
            self.assertEqual(summary["directory_uid"], os.getuid())
            self.assertEqual(summary["directory_mode"], f"{charts.stat().st_mode & 0o777:04o}")
            self.assertEqual(summary["package_filename"], "AK_ENCs.zip")

    def test_manifest_summary_rejects_writable_manifest_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            charts = Path(tmpdir) / "charts"
            charts.mkdir()
            extract = charts / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            manifest = charts / MANIFEST_NAME
            manifest.write_text(
                '{"created_at":"2000-01-01T00:00:00Z",'
                '"package":{"label":"Test","filename":"AK_ENCs.zip","url":"file:///test.zip"},'
                '"download":{"path":"","url":"file:///test.zip","bytes":1,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            manifest.chmod(0o600)
            charts.chmod(0o777)
            try:
                summary = report_module._manifest_summary(charts)
            finally:
                charts.chmod(0o700)

            self.assertEqual(summary["directory_uid"], os.getuid())
            self.assertEqual(summary["directory_mode"], "0777")
            self.assertIn("manifest directory", summary["error"])
            self.assertIn("has permissions 0777", summary["error"])
            self.assertNotIn("created_at", summary)

    def test_manifest_summary_marks_writable_extract_tree(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            charts = Path(tmpdir) / "charts"
            charts.mkdir()
            extract = charts / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            cell.chmod(0o666)
            manifest = charts / MANIFEST_NAME
            manifest.write_text(
                '{"created_at":"2000-01-01T00:00:00Z",'
                '"package":{"label":"Test","filename":"AK_ENCs.zip","url":"file:///test.zip"},'
                '"download":{"path":"","url":"file:///test.zip","bytes":1,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["actual_enc_cell_count"], 0)
            self.assertIn("manifest extract file", summary["extract_path_error"])
            self.assertIn("has permissions 0666", summary["extract_path_error"])

    def test_manifest_summary_marks_symlinked_recorded_paths(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_archive = root / "real-AK-ENCs.zip"
            real_archive.write_bytes(b"chart")
            archive_link = charts / "AK_ENCs.zip"
            real_extract = root / "real-AK-ENCs"
            cell = real_extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            extract_link = charts / "AK_ENCs"
            try:
                archive_link.symlink_to(real_archive)
                extract_link.symlink_to(real_extract, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (charts / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"created_at_source":"download",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive_link}","url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",'
                '"bytes":5,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{extract_link}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["download_path"], str(archive_link))
            self.assertEqual(summary["download_path_is_symlink"], True)
            self.assertEqual(summary["download_path_symlink_component"], str(archive_link))
            self.assertEqual(summary["extract_path"], str(extract_link))
            self.assertEqual(summary["extract_path_is_symlink"], True)
            self.assertEqual(summary["extract_path_symlink_component"], str(extract_link))

    def test_manifest_summary_marks_nonregular_download_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            archive = charts / "AK_ENCs.zip"
            archive.mkdir()
            extract = charts / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (charts / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"created_at_source":"download",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",'
                '"bytes":5,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["download_path"], str(archive))
            self.assertEqual(summary["download_path_exists"], True)
            self.assertIn("manifest download path is not a regular file", summary["download_path_error"])
            self.assertNotIn("download_path_uid", summary)
            self.assertNotIn("download_path_mode", summary)

    def test_manifest_summary_marks_recorded_path_symlink_ancestors(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_artifact_root = root / "real-artifacts"
            real_artifact_root.mkdir()
            archive = real_artifact_root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            extract = real_artifact_root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            artifact_link = root / "artifact-link"
            try:
                artifact_link.symlink_to(real_artifact_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            archive_path = artifact_link / "AK_ENCs.zip"
            extract_path = artifact_link / "AK_ENCs"
            (charts / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"created_at_source":"download",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive_path}","url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",'
                '"bytes":5,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{extract_path}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["download_path"], str(archive_path))
            self.assertEqual(summary["download_path_is_symlink"], False)
            self.assertEqual(summary["download_path_symlink_component"], str(artifact_link))
            self.assertEqual(summary["extract_path"], str(extract_path))
            self.assertEqual(summary["extract_path_is_symlink"], False)
            self.assertEqual(summary["extract_path_symlink_component"], str(artifact_link))

    def test_track_log_summary_accepts_recent_valid_trackpoint(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertTrue(summary["ok"])
            self.assertEqual(summary["latest_path"], str(track_path))
            self.assertEqual(summary["latest_time"], timestamp.isoformat().replace("+00:00", "Z"))
            self.assertEqual(summary["tracks_mode"], "0700")
            self.assertEqual(summary["latest_mode"], "0600")
            self.assertAlmostEqual(summary["latest_latitude"], 61.2181)
            self.assertAlmostEqual(summary["latest_longitude"], -149.9003)
            self.assertEqual(summary["latest_satellites"], 8)
            self.assertEqual(summary["latest_hdop"], 1.2)
            self.assertTrue(check.ok)
            self.assertIn("61.218100", check.detail)
            self.assertIn("8 satellites", check.detail)

    def test_track_log_summary_rejects_future_trackpoint(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(
                    GPSFix(
                        latitude=61.2181,
                        longitude=-149.9003,
                        timestamp=timestamp + timedelta(seconds=60),
                        satellites=8,
                        hdop=1.2,
                    )
                )

            summary = _track_log_summary(
                root,
                now=timestamp,
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("timestamp is in the future", check.detail)

    def test_track_log_summary_rejects_timezone_less_trackpoint(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            track_path = tracks / "track-20260629.gpx"
            track_path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="61.2181" lon="-149.9003">'
                f"<time>{timestamp.replace(tzinfo=None).isoformat()}</time>"
                "<sat>8</sat><hdop>1.2</hdop>"
                "</trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            track_path.chmod(0o600)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("timezone-less GPX trackpoint timestamp", check.detail)

    def test_track_log_summary_rejects_timezone_less_current_time(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            with self.assertRaisesRegex(ValueError, "current time must include a timezone"):
                _track_log_summary(Path(tmpdir), now=datetime(2026, 7, 1, 12, 0, 0), boot_epoch=None)

    def test_track_log_summary_rejects_missing_trackpoint_quality(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            track_path = tracks / "track-20260629.gpx"
            track_path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="61.2181" lon="-149.9003">'
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
                "</trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            track_path.chmod(0o600)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("missing satellite or HDOP quality fields", check.detail)

    def test_track_log_summary_rejects_negative_hdop(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            track_path = tracks / "track-20260629.gpx"
            track_path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="61.2181" lon="-149.9003">'
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
                "<hdop>-0.1</hdop>"
                "</trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            track_path.chmod(0o600)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("negative HDOP", check.detail)

    def test_track_log_summary_rejects_public_tracks_directory(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))
            track_path.parent.chmod(0o755)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("permissions are 0755", check.detail)

    def test_track_log_summary_rejects_symlinked_track_output(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            real_output = root / "real-tracks"
            track_path = real_output / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))
            link_output = root / "track-link"
            try:
                link_output.symlink_to(real_output, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = _track_log_summary(
                link_output,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertEqual(summary["track_output"], str(link_output))
            self.assertEqual(summary["track_output_is_symlink"], True)
            self.assertEqual(summary["track_storage_symlink_component"], str(link_output))
            self.assertFalse(check.ok)
            self.assertIn("expected real GPX track storage", check.detail)

    def test_track_log_summary_rejects_symlinked_track_output_ancestor(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            real_root = root / "real-storage"
            real_output = real_root / "noaa-tracks"
            track_path = real_output / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))
            link_root = root / "link-storage"
            try:
                link_root.symlink_to(real_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = _track_log_summary(
                link_root / "noaa-tracks",
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertEqual(summary["track_output"], str(link_root / "noaa-tracks"))
            self.assertEqual(summary["track_output_is_symlink"], False)
            self.assertEqual(summary["track_storage_symlink_component"], str(link_root))
            self.assertFalse(check.ok)
            self.assertIn("expected real GPX track storage", check.detail)

    def test_track_log_summary_rejects_public_track_file(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))
            track_path.chmod(0o644)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("permissions are 0644", check.detail)

    def test_read_trusted_gpx_track_file_rejects_writable_track_file_before_parsing(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            track_path = tracks / "track-20260629.gpx"
            track_path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="61.2181" lon="-149.9003">'
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
                "<sat>8</sat></trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            track_path.chmod(0o622)

            with self.assertRaisesRegex(RuntimeError, "permissions are 0622"):
                _read_trusted_gpx_track_file(track_path, expected_owner=os.getuid())

    def test_read_trusted_gpx_track_file_rejects_replaced_file_before_parsing(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            track_path = tracks / "track-20260629.gpx"
            track_path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="61.2181" lon="-149.9003">'
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
                "<sat>8</sat></trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            track_path.chmod(0o600)
            expected_stat = track_path.stat()
            replacement = tracks / "replacement.gpx"
            replacement.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="60.0" lon="-150.0">'
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
                "<sat>8</sat></trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            replacement.chmod(0o600)
            replacement.replace(track_path)

            with self.assertRaisesRegex(RuntimeError, "changed before it could be read"):
                _read_trusted_gpx_track_file(track_path, expected_owner=os.getuid(), expected_stat=expected_stat)

    def test_track_log_summary_waits_for_delayed_trackpoint(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"

            def write_later():
                time.sleep(0.05)
                with GPXTrackLogger(track_path) as logger:
                    logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))

            writer = threading.Thread(target=write_later)
            writer.start()
            try:
                summary = _track_log_summary(
                    root,
                    now=timestamp + timedelta(seconds=5),
                    boot_epoch=timestamp.timestamp() - 10,
                    wait_seconds=1.0,
                    poll_seconds=0.01,
                )
            finally:
                writer.join()

            self.assertTrue(summary["ok"])
            self.assertEqual(summary["latest_path"], str(track_path))

    def test_track_log_summary_rejects_stale_trackpoint(self):
        timestamp = datetime.now(timezone.utc) - timedelta(seconds=700)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))

            summary = _track_log_summary(root, now=timestamp + timedelta(seconds=700), boot_epoch=None)
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("stale", check.detail)

    def test_track_log_summary_rejects_non_finite_trackpoint_coordinates(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            track_path = tracks / "track-20260629.gpx"
            track_path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="NaN" lon="-149.9003">'
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
                "</trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            track_path.chmod(0o600)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("non-finite coordinates", check.detail)

    def test_track_log_summary_rejects_symlinked_track_file(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            real_track = root / "real.gpx"
            with GPXTrackLogger(real_track) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))
            symlink_track = tracks / "track-20260629.gpx"
            try:
                symlink_track.symlink_to(real_track)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = _track_log_summary(root, now=timestamp + timedelta(seconds=5), boot_epoch=None)
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("symlink", check.detail)

    def test_write_status_report_does_not_reuse_fixed_part_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / "status.json"
            fixed_part = root / "status.json.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")

            write_status_report({"ok": True}, output)

            self.assertEqual(fixed_part.read_text(encoding="utf-8"), "other writer\n")
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["ok"], True)
            self.assertFalse(list(root.glob(".status.json.*.part")))

    def test_write_status_report_tightens_public_output_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            root.chmod(0o755)
            output = root / "status.json"

            write_status_report({"ok": True}, output)

            self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_write_status_report_rejects_output_directory_when_tightening_fails(self):
        original_chmod = report_module.os.chmod

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            root.chmod(0o755)
            output = root / "status.json"

            def no_op_chmod(path, mode):
                if Path(path) == root:
                    return None
                return original_chmod(path, mode)

            try:
                report_module.os.chmod = no_op_chmod
                with self.assertRaisesRegex(RuntimeError, "status report directory .* permissions 0755"):
                    write_status_report({"ok": True}, output)
            finally:
                report_module.os.chmod = original_chmod
                root.chmod(0o700)

    def test_write_status_report_tightens_public_home_cache_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            cache_parent = root / ".cache"
            cache_parent.mkdir()
            cache_parent.chmod(0o755)
            old_home = os.environ.get("HOME")
            os.environ["HOME"] = str(root)
            try:
                output = Path("~/.cache/noaa-navionics/status.json")
                write_status_report({"ok": True}, output)
            finally:
                if old_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = old_home

            status_dir = cache_parent / "noaa-navionics"
            status_file = status_dir / "status.json"
            self.assertEqual(stat.S_IMODE(cache_parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(status_dir.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(status_file.stat().st_mode), 0o600)

    def test_write_status_report_rejects_home_cache_parent_when_tightening_fails(self):
        original_chmod = report_module.os.chmod
        old_home = os.environ.get("HOME")

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            cache_parent = root / ".cache"
            cache_parent.mkdir()
            cache_parent.chmod(0o755)

            def no_op_chmod(path, mode):
                if Path(path) == cache_parent:
                    return None
                return original_chmod(path, mode)

            os.environ["HOME"] = str(root)
            try:
                report_module.os.chmod = no_op_chmod
                output = Path("~/.cache/noaa-navionics/status.json")
                with self.assertRaisesRegex(
                    RuntimeError,
                    "status report cache parent directory .* permissions 0755",
                ):
                    write_status_report({"ok": True}, output)
            finally:
                report_module.os.chmod = original_chmod
                cache_parent.chmod(0o700)
                if old_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = old_home

    def test_write_status_report_rejects_symlinked_output_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_cache = root / "real-cache"
            real_cache.mkdir()
            cache_link = root / ".cache"
            try:
                cache_link.symlink_to(real_cache, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            output = cache_link / "noaa-navionics" / "status.json"

            with self.assertRaisesRegex(RuntimeError, "status report parent directory .* is a symlink"):
                write_status_report({"ok": True}, output)

            self.assertFalse((real_cache / "noaa-navionics").exists())

    def test_write_status_report_rejects_symlinked_output_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_home = root / "real-home"
            real_home.mkdir()
            home_link = root / "home-link"
            try:
                home_link.symlink_to(real_home, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            output = home_link / ".cache" / "noaa-navionics" / "status.json"

            with self.assertRaisesRegex(RuntimeError, "status report parent path contains a symlink"):
                write_status_report({"ok": True}, output)

            self.assertFalse((real_home / ".cache").exists())

    def test_write_status_report_syncs_file_and_directory(self):
        calls = []
        original_fsync = report_module.os.fsync
        report_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir) / "status.json"
                write_status_report({"ok": True}, output)
        finally:
            report_module.os.fsync = original_fsync

        self.assertGreaterEqual(len(calls), 2)

    def test_write_status_report_validates_promoted_file_with_no_follow_open(self):
        calls = []
        original_open = report_module.os.open

        def recording_open(path, flags, *args, **kwargs):
            calls.append((Path(path), flags))
            return original_open(path, flags, *args, **kwargs)

        report_module.os.open = recording_open
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir) / "status.json"
                write_status_report({"ok": True}, output)
        finally:
            report_module.os.open = original_open

        status_opens = [(path, flags) for path, flags in calls if path.name == "status.json"]
        self.assertTrue(status_opens)
        self.assertTrue(any(flags & getattr(os, "O_NOFOLLOW", 0) for _, flags in status_opens))

    def test_write_status_report_rejects_corrupt_promoted_file(self):
        original_replace = report_module.os.replace

        def corrupting_replace(src, dst):
            original_replace(src, dst)
            Path(dst).write_text("not json\n", encoding="utf-8")
            Path(dst).chmod(0o600)

        report_module.os.replace = corrupting_replace
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir) / "status.json"
                with self.assertRaisesRegex(RuntimeError, "status report is not valid JSON"):
                    write_status_report({"ok": True}, output)
        finally:
            report_module.os.replace = original_replace

    def test_write_status_report_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = report_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        report_module.os.open = fake_open
        try:
            report_module._fsync_directory(Path("/tmp"))
        finally:
            report_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], Path("/tmp"))
        self.assertTrue(calls[0][1] & getattr(os, "O_DIRECTORY", 0))
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_install_wanted_by_targets_parse_only_install_section(self):
        targets = _install_wanted_by_targets(
            [
                "[Unit]",
                "WantedBy=wrong.target",
                "[Install]",
                "WantedBy=default.target timers.target",
                ";WantedBy=commented.target",
            ]
        )

        self.assertEqual(targets, ["default.target", "timers.target"])

    def test_install_wanted_by_targets_ignore_missing_install_section(self):
        targets = _install_wanted_by_targets(
            [
                "[Service]",
                "WantedBy=default.target",
            ]
        )

        self.assertEqual(targets, [])

    def test_user_unit_file_summary_rejects_symlinked_unit_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            unit_dir = root / ".config/systemd/user"
            unit_dir.mkdir(parents=True)
            real_unit = root / "real.timer"
            real_unit.write_text("[Install]\nWantedBy=timers.target\n", encoding="utf-8")
            unit_link = unit_dir / "noaa-navionics.timer"
            try:
                unit_link.symlink_to(real_unit)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with patch.dict(os.environ, {"HOME": str(root)}):
                summary = _user_unit_file_summary()

            state = summary["noaa-navionics.timer"]
            self.assertEqual(state["path"], str(unit_link))
            self.assertEqual(state["exists"], True)
            self.assertEqual(state["is_symlink"], True)
            self.assertEqual(state["directory_is_symlink"], False)
            self.assertEqual(state["path_symlink_component"], "")
            self.assertIn("user unit file path is a symlink", state["error"])
            self.assertNotIn("wanted_by", state)

    def test_user_unit_file_summary_rejects_symlinked_unit_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_unit_dir = root / "real-systemd-user"
            real_unit_dir.mkdir()
            real_unit = real_unit_dir / "noaa-navionics.timer"
            real_unit.write_text("[Install]\nWantedBy=timers.target\n", encoding="utf-8")
            config_dir = root / ".config/systemd"
            config_dir.mkdir(parents=True)
            unit_dir = config_dir / "user"
            try:
                unit_dir.symlink_to(real_unit_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with patch.dict(os.environ, {"HOME": str(root)}):
                summary = _user_unit_file_summary()

            state = summary["noaa-navionics.timer"]
            self.assertEqual(state["path"], str(unit_dir / "noaa-navionics.timer"))
            self.assertEqual(state["exists"], True)
            self.assertEqual(state["is_symlink"], False)
            self.assertEqual(state["directory_is_symlink"], True)
            self.assertEqual(state["path_symlink_component"], str(unit_dir))
            self.assertIn("user unit file directory is a symlink", state["error"])
            self.assertNotIn("wanted_by", state)

    def test_user_unit_file_summary_rejects_symlinked_unit_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_home = root / "real-home"
            unit_dir = real_home / ".config/systemd/user"
            unit_dir.mkdir(parents=True)
            real_unit = unit_dir / "noaa-navionics.timer"
            real_unit.write_text("[Install]\nWantedBy=timers.target\n", encoding="utf-8")
            link_home = root / "home-link"
            try:
                link_home.symlink_to(real_home, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with patch.dict(os.environ, {"HOME": str(link_home)}):
                summary = _user_unit_file_summary()

            state = summary["noaa-navionics.timer"]
            self.assertEqual(state["path"], str(link_home / ".config/systemd/user/noaa-navionics.timer"))
            self.assertEqual(state["exists"], True)
            self.assertEqual(state["is_symlink"], False)
            self.assertEqual(state["directory_is_symlink"], False)
            self.assertEqual(state["path_symlink_component"], str(link_home))
            self.assertIn("user unit file directory is a symlink", state["error"])
            self.assertNotIn("wanted_by", state)

    def test_user_unit_file_summary_records_owner_and_permissions(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            unit_dir = root / ".config/systemd/user"
            unit_dir.mkdir(parents=True)
            os.chmod(unit_dir, 0o700)
            unit_file = unit_dir / "noaa-navionics.timer"
            unit_file.write_text("[Install]\nWantedBy=timers.target\n", encoding="utf-8")
            os.chmod(unit_file, 0o600)

            with patch.dict(os.environ, {"HOME": str(root)}):
                summary = _user_unit_file_summary()

            state = summary["noaa-navionics.timer"]
            self.assertEqual(state["uid"], os.getuid())
            self.assertEqual(state["mode"], "0600")
            self.assertEqual(state["directory_uid"], os.getuid())
            self.assertEqual(state["directory_mode"], "0700")
            self.assertEqual(state["wanted_by"], ["timers.target"])
            self.assertIn("WantedBy=timers.target", state["lines"])

    def test_user_unit_file_summary_rejects_writable_unit_file_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            unit_dir = root / ".config/systemd/user"
            unit_dir.mkdir(parents=True)
            os.chmod(unit_dir, 0o700)
            unit_file = unit_dir / "noaa-navionics.timer"
            unit_file.write_text("[Install]\nWantedBy=timers.target\n", encoding="utf-8")
            os.chmod(unit_file, 0o622)

            with patch.dict(os.environ, {"HOME": str(root)}):
                summary = _user_unit_file_summary()

            state = summary["noaa-navionics.timer"]
            self.assertIn("has permissions 0622", state["error"])
            self.assertIn("expected no group/other write bits", state["error"])
            self.assertNotIn("wanted_by", state)

    def test_user_unit_file_reader_rejects_replaced_unit_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            unit_file = root / "noaa-navionics-track.service"
            unit_file.write_text("[Install]\nWantedBy=default.target\n", encoding="utf-8")
            unit_file.chmod(0o600)
            expected_stat = unit_file.stat()
            replacement = root / "replacement.service"
            replacement.write_text("[Install]\nWantedBy=unexpected.target\n", encoding="utf-8")
            replacement.chmod(0o600)
            replacement.replace(unit_file)

            with self.assertRaisesRegex(RuntimeError, "user unit file path changed before it could be read"):
                report_module._read_user_unit_file_lines(unit_file, expected_stat=expected_stat)

    def test_service_readiness_checks_accept_expected_onboard_units(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")

        self.assertTrue(all(check.ok for check in checks))
        self.assertIn("Chart Sync", [check.name for check in checks])

    def test_service_readiness_checks_accept_expected_loaded_unit_properties(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "inactive",
                "properties": {
                    "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics.service",
                    "ExecStartPre": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300 ; }",
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics sync-charts --config /home/pi/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30 ; }",
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
            },
            "noaa-navionics.timer": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics.timer",
                    "TimersCalendar": "{ OnCalendar=weekly ; NextElapseUSecRealtime=Mon 2026-07-06 00:00:00 UTC }",
                    "Persistent": "yes",
                    "RandomizedDelayUSec": "30min",
                },
            },
            "noaa-navionics-track.service": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics log-track --config /home/pi/.config/noaa-navionics/config.ini --rotate-daily ; }",
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
            },
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                    "Wants": "noaa-navionics-track.service",
                    "After": "noaa-navionics-track.service basic.target",
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env /home/pi/.config/noaa-navionics/launcher.env --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Type": "oneshot",
                    "Environment": "",
                    "EnvironmentFiles": "",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "123456789",
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
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.service",
                [],
            ),
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        settings_checks = [check for check in checks if check.name.endswith("Settings")]
        run_check = next(check for check in checks if check.name == "Boot Readiness Run")

        self.assertEqual(len(settings_checks), 4)
        self.assertTrue(all(check.ok for check in settings_checks))
        self.assertTrue(run_check.ok)

    def test_service_readiness_checks_fail_stale_loaded_unit_fragment_path(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "inactive",
                "properties": {
                    "FragmentPath": "/tmp/noaa-navionics.service",
                    "ExecStartPre": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300 ; }",
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics sync-charts --config /home/pi/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30 ; }",
                    "Type": "oneshot",
                    "TimeoutStartUSec": "2h",
                    "Restart": "on-failure",
                    "RestartUSec": "30min",
                    "StartLimitIntervalUSec": "6h",
                    "StartLimitBurst": "3",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.service",
                [],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        chart_settings = next(check for check in checks if check.name == "Chart Sync Settings")

        self.assertFalse(chart_settings.ok)
        self.assertIn("FragmentPath=/tmp/noaa-navionics.service", chart_settings.detail)
        self.assertIn("expected /home/pi/.config/systemd/user/noaa-navionics.service", chart_settings.detail)

    def test_service_readiness_checks_accept_unit_file_install_targets(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        install_checks = [check for check in checks if check.name.endswith("Install")]

        self.assertEqual(len(install_checks), 3)
        self.assertTrue(all(check.ok for check in install_checks))

    def test_service_readiness_checks_fail_public_unit_file_permissions(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
                mode="0666",
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("mode=0666", timer_install.detail)
        self.assertIn("expected no group/other write bits", timer_install.detail)

    def test_service_readiness_checks_fail_public_unit_directory_permissions(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
                directory_mode="0777",
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("directory_mode=0777", timer_install.detail)
        self.assertIn("expected no group/other write bits", timer_install.detail)

    def test_service_readiness_checks_fail_misowned_unit_file(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unexpected_uid = os.getuid() + 1
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
                uid=unexpected_uid,
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn(f"uid={unexpected_uid}", timer_install.detail)
        self.assertIn(f"expected {os.getuid()}", timer_install.detail)

    def test_service_readiness_checks_fail_symlinked_unit_file_install_target(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": {
                "path": "/home/pi/.config/systemd/user/noaa-navionics.timer",
                "exists": True,
                "is_symlink": True,
            },
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("unit file path is a symlink", timer_install.detail)

    def test_service_readiness_checks_fail_symlinked_unit_file_directory(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
                directory_is_symlink=True,
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("unit file directory is a symlink", timer_install.detail)

    def test_service_readiness_checks_fail_symlinked_unit_file_ancestor(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
                path_symlink_component="/home/pi",
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("unit file path contains a symlink: /home/pi", timer_install.detail)

    def test_service_readiness_checks_fail_missing_unit_file_symlink_status(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_state = trusted_unit_file("/home/pi/.config/systemd/user/noaa-navionics.timer", ["timers.target"])
        unit_state.pop("path_symlink_component")
        unit_files = {
            "noaa-navionics.timer": unit_state,
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("missing path_symlink_component", timer_install.detail)

    def test_launcher_settings_check_accepts_fail_closed_settings(self):
        check = _launcher_settings_check(
            trusted_launcher_settings(
                values={
                    "NOAA_NAVIONICS_GPS_SECONDS": "30",
                    "NOAA_NAVIONICS_READINESS_ATTEMPTS": "3",
                    "NOAA_NAVIONICS_READINESS_RETRY_DELAY": "10",
                    "NOAA_NAVIONICS_WARNING_SECONDS": "8",
                    "NOAA_NAVIONICS_OPENCPN_RESTARTS": "3",
                    "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY": "5",
                    "NOAA_NAVIONICS_START_ON_FAILED_READINESS": "no",
                },
            )
        )

        self.assertTrue(check.ok)
        self.assertIn("fail-closed", check.detail)

    def test_launcher_settings_check_fails_public_environment(self):
        check = _launcher_settings_check(
            trusted_launcher_settings(mode="0644", values={"NOAA_NAVIONICS_GPS_SECONDS": "30"})
        )

        self.assertFalse(check.ok)
        self.assertIn("expected private 0600", check.detail)

    def test_launcher_settings_check_fails_public_environment_directory(self):
        check = _launcher_settings_check(
            trusted_launcher_settings(directory_mode="0775", values={"NOAA_NAVIONICS_GPS_SECONDS": "30"})
        )

        self.assertFalse(check.ok)
        self.assertIn("launcher environment directory", check.detail)
        self.assertIn("expected no group/other write bits", check.detail)

    def test_launcher_settings_check_fails_symlinked_environment(self):
        check = _launcher_settings_check(
            trusted_launcher_settings(is_symlink=True, values={"NOAA_NAVIONICS_GPS_SECONDS": "30"})
        )

        self.assertFalse(check.ok)
        self.assertIn("launcher environment path is a symlink", check.detail)

    def test_launcher_settings_check_fails_symlinked_environment_directory(self):
        check = _launcher_settings_check(
            trusted_launcher_settings(directory_is_symlink=True, values={"NOAA_NAVIONICS_GPS_SECONDS": "30"})
        )

        self.assertFalse(check.ok)
        self.assertIn("launcher environment directory is a symlink", check.detail)

    def test_launcher_settings_check_fails_missing_symlink_status(self):
        missing_path_status = trusted_launcher_settings()
        missing_path_status.pop("is_symlink")
        path_check = _launcher_settings_check(missing_path_status)

        missing_component = trusted_launcher_settings()
        missing_component.pop("launcher_settings_symlink_component")
        component_check = _launcher_settings_check(missing_component)

        self.assertFalse(path_check.ok)
        self.assertIn("missing symlink status", path_check.detail)
        self.assertFalse(component_check.ok)
        self.assertIn("missing launcher_settings_symlink_component", component_check.detail)

    def test_launcher_settings_check_fails_fail_open_override(self):
        check = _launcher_settings_check(
            trusted_launcher_settings(
                values={
                    "NOAA_NAVIONICS_GPS_SECONDS": "30",
                    "NOAA_NAVIONICS_START_ON_FAILED_READINESS": "yes",
                },
            )
        )

        self.assertFalse(check.ok)
        self.assertIn("START_ON_FAILED_READINESS is enabled", check.detail)

    def test_launcher_settings_check_fails_invalid_optional_timing_values(self):
        check = _launcher_settings_check(
            trusted_launcher_settings(
                values={
                    "NOAA_NAVIONICS_GPS_SECONDS": "30",
                    "NOAA_NAVIONICS_WARNING_SECONDS": "soon",
                    "NOAA_NAVIONICS_OPENCPN_RESTARTS": "-1",
                    "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY": "soon",
                },
            )
        )

        self.assertFalse(check.ok)
        self.assertIn("NOAA_NAVIONICS_WARNING_SECONDS=soon expected non-negative integer", check.detail)
        self.assertIn("NOAA_NAVIONICS_OPENCPN_RESTARTS=-1 expected non-negative integer", check.detail)
        self.assertIn("NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=soon expected non-negative integer", check.detail)

    def test_launcher_settings_check_fails_missing_gps_wait(self):
        check = _launcher_settings_check(trusted_launcher_settings(values={}))

        self.assertFalse(check.ok)
        self.assertIn("NOAA_NAVIONICS_GPS_SECONDS=<missing>", check.detail)

    def test_service_readiness_checks_include_launcher_settings(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            launcher_settings=trusted_launcher_settings(
                values={
                    "NOAA_NAVIONICS_GPS_SECONDS": "10",
                    "NOAA_NAVIONICS_START_ON_FAILED_READINESS": "yes",
                },
            ),
            gps_mode="gpsd",
        )
        launcher_check = next(check for check in checks if check.name == "Launcher Settings")

        self.assertFalse(launcher_check.ok)
        self.assertIn("START_ON_FAILED_READINESS is enabled", launcher_check.detail)

    def test_service_readiness_checks_include_user_linger(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            user={"name": "pi", "uid": 1000, "linger": "no"},
            gps_mode="gpsd",
        )
        linger_check = next(check for check in checks if check.name == "User Linger")

        self.assertFalse(linger_check.ok)
        self.assertIn("linger=no", linger_check.detail)

    def test_service_readiness_checks_include_desktop_startup(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {"path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop", "exists": False},
                "lightdm_autologin": {"path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf", "exists": False},
                "graphical_target": "multi-user.target",
                "lightdm_enabled": "disabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart missing", desktop_check.detail)
        self.assertIn("systemd default target is multi-user.target", desktop_check.detail)
        self.assertIn("lightdm.service is disabled", desktop_check.detail)

    def test_service_readiness_checks_fail_missing_desktop_symlink_status(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {
                    "path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": False,
                    "values": {
                        "Type": "Application",
                        "Name": "NOAA Navionics Chartplotter",
                        "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
                        "Terminal": "false",
                        "X-GNOME-Autostart-enabled": "true",
                    },
                },
                "lightdm_autologin": {
                    "path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": False,
                    "sections": ["Seat:*"],
                    "values": {
                        "autologin-user": "pi",
                        "autologin-user-timeout": "0",
                        "autologin-session": "LXDE-pi",
                    },
                },
                "graphical_target": "graphical.target",
                "lightdm_enabled": "enabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart missing path_symlink_component", desktop_check.detail)
        self.assertIn("LightDM autologin config missing path_symlink_component", desktop_check.detail)

    def test_service_readiness_checks_fail_symlinked_desktop_startup_files(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {
                    "path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop",
                    "exists": True,
                    "is_symlink": True,
                },
                "lightdm_autologin": {
                    "path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf",
                    "exists": True,
                    "is_symlink": True,
                },
                "graphical_target": "graphical.target",
                "lightdm_enabled": "enabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart path is a symlink", desktop_check.detail)
        self.assertIn("LightDM autologin config path is a symlink", desktop_check.detail)

    def test_service_readiness_checks_fail_symlinked_desktop_startup_directories(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {
                    "path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": True,
                    "values": {
                        "Type": "Application",
                        "Name": "NOAA Navionics Chartplotter",
                        "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
                        "Terminal": "false",
                        "X-GNOME-Autostart-enabled": "true",
                    },
                },
                "lightdm_autologin": {
                    "path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": True,
                    "sections": ["Seat:*"],
                    "values": {
                        "autologin-user": "pi",
                        "autologin-user-timeout": "0",
                        "autologin-session": "LXDE-pi",
                    },
                },
                "graphical_target": "graphical.target",
                "lightdm_enabled": "enabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart directory is a symlink", desktop_check.detail)
        self.assertIn("LightDM autologin config directory is a symlink", desktop_check.detail)

    def test_service_readiness_checks_fail_symlinked_desktop_startup_ancestors(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {
                    "path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": False,
                    "path_symlink_component": "/home/pi",
                    "values": {
                        "Type": "Application",
                        "Name": "NOAA Navionics Chartplotter",
                        "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
                        "Terminal": "false",
                        "X-GNOME-Autostart-enabled": "true",
                    },
                },
                "lightdm_autologin": {
                    "path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": False,
                    "path_symlink_component": "/etc/lightdm",
                    "sections": ["Seat:*"],
                    "values": {
                        "autologin-user": "pi",
                        "autologin-user-timeout": "0",
                        "autologin-session": "LXDE-pi",
                    },
                },
                "graphical_target": "graphical.target",
                "lightdm_enabled": "enabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart path contains a symlink: /home/pi", desktop_check.detail)
        self.assertIn("LightDM autologin config path contains a symlink: /etc/lightdm", desktop_check.detail)

    def test_service_readiness_checks_fail_unsafe_desktop_startup_files(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {
                    "path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": False,
                    "uid": os.getuid() + 1,
                    "mode": "0666",
                    "values": {
                        "Type": "Application",
                        "Name": "NOAA Navionics Chartplotter",
                        "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
                        "Terminal": "false",
                        "X-GNOME-Autostart-enabled": "true",
                    },
                },
                "lightdm_autologin": {
                    "path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": False,
                    "uid": os.getuid() + 1,
                    "mode": "0666",
                    "sections": ["Seat:*"],
                    "values": {
                        "autologin-user": "pi",
                        "autologin-user-timeout": "0",
                        "autologin-session": "LXDE-pi",
                    },
                },
                "graphical_target": "graphical.target",
                "lightdm_enabled": "enabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart is owned by uid", desktop_check.detail)
        self.assertIn("desktop autostart has permissions 0666", desktop_check.detail)
        self.assertIn("LightDM autologin config is owned by uid", desktop_check.detail)
        self.assertIn("LightDM autologin config has permissions 0666", desktop_check.detail)

    def test_service_readiness_checks_fail_stale_unit_file_install_target(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["default.target"],
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("WantedBy=default.target", timer_install.detail)
        self.assertIn("expected timers.target", timer_install.detail)

    def test_service_readiness_checks_fail_stale_installed_unit_file_settings(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        stale_lines = [
            line
            for line in trusted_unit_file_lines("noaa-navionics-track.service")
            if line != "RestartSec=10"
        ]
        unit_files = {
            "noaa-navionics.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.service",
                [],
            ),
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
                lines=stale_lines,
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        track_file = next(check for check in checks if check.name == "Track Logger Unit File")

        self.assertFalse(track_file.ok)
        self.assertIn("RestartSec=10", track_file.detail)

    def test_service_readiness_checks_fail_missing_loaded_unit_hardening(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "inactive",
                "properties": {
                    "ExecStartPre": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300 ; }",
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics sync-charts --config /home/pi/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30 ; }",
                    "Type": "oneshot",
                    "TimeoutStartUSec": "2h",
                    "Restart": "on-failure",
                    "RestartUSec": "30min",
                    "StartLimitIntervalUSec": "6h",
                    "StartLimitBurst": "3",
                    "NoNewPrivileges": "no",
                    "PrivateTmp": "no",
                },
            },
            "noaa-navionics.timer": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "TimersCalendar": "{ OnCalendar=weekly ; NextElapseUSecRealtime=Mon 2026-07-06 00:00:00 UTC }",
                    "Persistent": "yes",
                    "RandomizedDelayUSec": "30min",
                },
            },
            "noaa-navionics-track.service": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics log-track --config /home/pi/.config/noaa-navionics/config.ini --rotate-daily ; }",
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
            },
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env /home/pi/.config/noaa-navionics/launcher.env --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Type": "oneshot",
                    "Environment": "",
                    "EnvironmentFiles": "",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        chart_settings = next(check for check in checks if check.name == "Chart Sync Settings")

        self.assertFalse(chart_settings.ok)
        self.assertIn("NoNewPrivileges=no", chart_settings.detail)
        self.assertIn("PrivateTmp=no", chart_settings.detail)

    def test_service_readiness_checks_fail_stale_loaded_track_settings(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "Type": "oneshot",
                    "StandardOutput": "journal",
                    "Restart": "no",
                    "RestartUSec": "100ms",
                    "StartLimitIntervalUSec": "10min",
                    "StartLimitBurst": "60",
                },
            },
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        track_settings = next(check for check in checks if check.name == "Track Logger Settings")

        self.assertFalse(track_settings.ok)
        self.assertIn("Type=oneshot", track_settings.detail)
        self.assertIn("StandardOutput=journal", track_settings.detail)
        self.assertIn("Restart=no", track_settings.detail)

    def test_service_readiness_checks_fail_stale_loaded_boot_readiness_restart(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "Type": "simple",
                    "TimeoutStartUSec": "90s",
                    "Restart": "no",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "5min",
                    "StartLimitBurst": "5",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        boot_settings = next(check for check in checks if check.name == "Boot Readiness Settings")

        self.assertFalse(boot_settings.ok)
        self.assertIn("Type=simple", boot_settings.detail)
        self.assertIn("TimeoutStartUSec=90s", boot_settings.detail)
        self.assertIn("Restart=no", boot_settings.detail)

    def test_service_readiness_checks_fail_stale_boot_readiness_systemd_environment_file(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env /home/pi/.config/noaa-navionics/launcher.env --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Type": "oneshot",
                    "Environment": "NOAA_NAVIONICS_GPS_SECONDS=2",
                    "EnvironmentFiles": "/home/pi/.config/noaa-navionics/launcher.env",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        boot_settings = next(check for check in checks if check.name == "Boot Readiness Settings")

        self.assertFalse(boot_settings.ok)
        self.assertIn("Environment=NOAA_NAVIONICS_GPS_SECONDS=2", boot_settings.detail)
        self.assertIn("EnvironmentFiles=/home/pi/.config/noaa-navionics/launcher.env expected", boot_settings.detail)

    def test_service_readiness_checks_fail_missing_boot_readiness_track_ordering(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env /home/pi/.config/noaa-navionics/launcher.env --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Type": "oneshot",
                    "Environment": "",
                    "EnvironmentFiles": "",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        boot_settings = next(check for check in checks if check.name == "Boot Readiness Settings")

        self.assertFalse(boot_settings.ok)
        self.assertIn("Wants=<missing> missing noaa-navionics-track.service", boot_settings.detail)
        self.assertIn("After=<missing> missing noaa-navionics-track.service", boot_settings.detail)

    def test_service_readiness_checks_fail_boot_readiness_never_ran(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "Type": "oneshot",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "0",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        run_check = next(check for check in checks if check.name == "Boot Readiness Run")

        self.assertFalse(run_check.ok)
        self.assertIn("ExecMainStartTimestampMonotonic=0", run_check.detail)

    def test_service_readiness_checks_fail_boot_readiness_exit_status(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "Type": "oneshot",
                    "Result": "exit-code",
                    "ExecMainStatus": "1",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        run_check = next(check for check in checks if check.name == "Boot Readiness Run")

        self.assertFalse(run_check.ok)
        self.assertIn("Result=exit-code", run_check.detail)
        self.assertIn("ExecMainStatus=1", run_check.detail)

    def test_service_readiness_checks_accept_boot_readiness_running_self_report(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "activating",
                "properties": {
                    "Type": "oneshot",
                    "Result": "",
                    "ExecMainStatus": "",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        run_check = next(check for check in checks if check.name == "Boot Readiness Run")

        self.assertTrue(run_check.ok)
        self.assertIn("active=activating", run_check.detail)
        self.assertIn("ExecMainStartTimestampMonotonic=123456789", run_check.detail)

    def test_service_readiness_checks_fail_loaded_command_missing_args(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ argv[]=/home/pi/.local/bin/noaa-navionics sync-charts ; }",
                    "Type": "oneshot",
                    "TimeoutStartUSec": "2h",
                    "Restart": "on-failure",
                    "RestartUSec": "30min",
                    "StartLimitIntervalUSec": "6h",
                    "StartLimitBurst": "3",
                },
            },
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        chart_settings = next(check for check in checks if check.name == "Chart Sync Settings")

        self.assertFalse(chart_settings.ok)
        self.assertIn("ExecStartPre=<missing>", chart_settings.detail)
        self.assertIn("missing noaa-navionics wait-network", chart_settings.detail)
        self.assertIn("missing --config", chart_settings.detail)
        self.assertIn("missing --retries 5", chart_settings.detail)

    def test_service_readiness_checks_fail_loaded_command_wrong_path(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "inactive",
                "properties": {
                    "ExecStartPre": "{ path=/tmp/noaa-navionics ; argv[]=/tmp/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300 ; }",
                    "ExecStart": "{ path=/tmp/noaa-navionics ; argv[]=/tmp/noaa-navionics sync-charts --config /home/pi/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30 ; }",
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
            },
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "ExecStart": "{ path=/tmp/noaa-navionics ; argv[]=/tmp/noaa-navionics log-track --config /home/pi/.config/noaa-navionics/config.ini --rotate-daily ; }",
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
            },
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ path=/tmp/noaa-navionics ; argv[]=/tmp/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds-from-launcher-env /home/pi/.config/noaa-navionics/launcher.env --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Wants": "noaa-navionics-track.service",
                    "After": "noaa-navionics-track.service",
                    "Type": "oneshot",
                    "Environment": "",
                    "EnvironmentFiles": "",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "123456789",
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
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        chart_settings = next(check for check in checks if check.name == "Chart Sync Settings")
        track_settings = next(check for check in checks if check.name == "Track Logger Settings")
        boot_settings = next(check for check in checks if check.name == "Boot Readiness Settings")

        self.assertFalse(chart_settings.ok)
        self.assertIn("missing .local/bin/noaa-navionics", chart_settings.detail)
        self.assertFalse(track_settings.ok)
        self.assertIn("missing .local/bin/noaa-navionics", track_settings.detail)
        self.assertFalse(boot_settings.ok)
        self.assertIn("missing .local/bin/noaa-navionics", boot_settings.detail)

    def test_service_readiness_checks_fail_disabled_chart_timer(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "disabled", "active": "inactive"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        timer_check = next(check for check in checks if check.name == "Chart Timer")

        self.assertFalse(timer_check.ok)
        self.assertIn("disabled", timer_check.detail)

    def test_service_readiness_checks_allow_failed_chart_sync_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "failed"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        sync_check = next(check for check in checks if check.name == "Chart Sync")

        self.assertTrue(sync_check.ok)
        self.assertIn("manifest freshness", sync_check.detail)

    def test_service_readiness_checks_fail_disabled_chart_sync_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "disabled", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        sync_check = next(check for check in checks if check.name == "Chart Sync")

        self.assertFalse(sync_check.ok)
        self.assertIn("disabled", sync_check.detail)

    def test_service_readiness_checks_fail_missing_chart_sync_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "not-found", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        sync_check = next(check for check in checks if check.name == "Chart Sync")

        self.assertFalse(sync_check.ok)
        self.assertIn("not-found", sync_check.detail)

    def test_service_readiness_checks_fail_chart_sync_query_error(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "error: Failed to connect to bus",
            },
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        sync_check = next(check for check in checks if check.name == "Chart Sync")

        self.assertFalse(sync_check.ok)
        self.assertIn("Failed to connect", sync_check.detail)

    def test_service_readiness_checks_fail_missing_unit_query_result(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "not-found", "active": "unknown"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        timer_check = next(check for check in checks if check.name == "Chart Timer")

        self.assertFalse(timer_check.ok)
        self.assertIn("not-found", timer_check.detail)

    def test_service_readiness_checks_fail_failed_boot_readiness_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "failed"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        boot_check = next(check for check in checks if check.name == "Boot Readiness")

        self.assertFalse(boot_check.ok)
        self.assertIn("failed", boot_check.detail)

    def test_service_readiness_checks_fail_inactive_track_logger(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "inactive"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        track_check = next(check for check in checks if check.name == "Track Logger")

        self.assertFalse(track_check.ok)
        self.assertIn("inactive", track_check.detail)

    def test_service_readiness_checks_fail_disabled_gpsd_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "disabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        gpsd_check = next(check for check in checks if check.name == "GPSD Service")

        self.assertFalse(gpsd_check.ok)
        self.assertIn("disabled", gpsd_check.detail)

    def test_service_readiness_checks_fail_disabled_gpsd_socket(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "disabled", "active": "inactive"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        gpsd_socket_check = next(check for check in checks if check.name == "GPSD Socket")

        self.assertFalse(gpsd_socket_check.ok)
        self.assertIn("disabled", gpsd_socket_check.detail)

    def test_service_readiness_checks_fail_disabled_chrony_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "disabled", "active": "inactive"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        chrony_check = next(check for check in checks if check.name == "Chrony Service")

        self.assertFalse(chrony_check.ok)
        self.assertIn("disabled", chrony_check.detail)


class GpsTests(unittest.TestCase):
    def _trusted_gps_device_patch(self):
        return patch(
            "noaa_navionics.health.check_gps_device_path",
            return_value=health_module.CheckResult(
                "GPS Device",
                True,
                "/dev/serial/by-id/mock-gps -> /dev/ttyACM0",
            ),
        )

    def _fake_stat_result(self, mode: int, *, inode: int = 100, device: int = 200) -> os.stat_result:
        return os.stat_result((mode, inode, device, 1, os.getuid(), os.getgid(), 0, 0, 0, 0))

    def test_distance_meters_uses_haversine_distance(self):
        self.assertAlmostEqual(distance_meters(0.0, 0.0, 0.0, 1.0), 111195.1, delta=1.0)
        self.assertAlmostEqual(distance_meters(61.0, -149.0, 61.0, -149.0), 0.0, delta=0.001)

    def test_distance_meters_rejects_invalid_coordinates(self):
        for coordinates in (
            (91.0, 0.0, 0.0, 0.0),
            (0.0, 181.0, 0.0, 0.0),
            (0.0, 0.0, float("nan"), 0.0),
            (0.0, 0.0, 0.0, "bad"),
        ):
            with self.subTest(coordinates=coordinates):
                with self.assertRaisesRegex(ValueError, "coordinates must be finite"):
                    distance_meters(*coordinates)

    def test_open_nmea_stream_closes_fd_when_termios_setup_fails(self):
        closed_fds = []
        char_stat = self._fake_stat_result(stat.S_IFCHR | 0o600)
        original_stat = gps_module.os.stat
        original_open = gps_module.os.open
        original_fstat = gps_module.os.fstat
        original_close = gps_module.os.close
        original_tcgetattr = gps_module.termios.tcgetattr

        try:
            gps_module.os.stat = lambda path: char_stat
            gps_module.os.open = lambda path, flags: 123
            gps_module.os.fstat = lambda fd: char_stat
            gps_module.os.close = lambda fd: closed_fds.append(fd)
            gps_module.termios.tcgetattr = lambda fd: (_ for _ in ()).throw(OSError("termios failed"))

            with self.assertRaisesRegex(OSError, "termios failed"):
                gps_module.open_nmea_stream("/dev/serial/by-id/mock-gps")
        finally:
            gps_module.os.stat = original_stat
            gps_module.os.open = original_open
            gps_module.os.fstat = original_fstat
            gps_module.os.close = original_close
            gps_module.termios.tcgetattr = original_tcgetattr

        self.assertEqual(closed_fds, [123])

    def test_open_nmea_stream_closes_fd_when_fdopen_fails(self):
        closed_fds = []
        char_stat = self._fake_stat_result(stat.S_IFCHR | 0o600)
        original_stat = gps_module.os.stat
        original_open = gps_module.os.open
        original_fstat = gps_module.os.fstat
        original_close = gps_module.os.close
        original_fdopen = gps_module.os.fdopen
        original_tcgetattr = gps_module.termios.tcgetattr
        original_tcsetattr = gps_module.termios.tcsetattr

        try:
            gps_module.os.stat = lambda path: char_stat
            gps_module.os.open = lambda path, flags: 456
            gps_module.os.fstat = lambda fd: char_stat
            gps_module.os.close = lambda fd: closed_fds.append(fd)
            gps_module.os.fdopen = lambda fd, mode, buffering=0: (_ for _ in ()).throw(OSError("fdopen failed"))
            gps_module.termios.tcgetattr = lambda fd: [0, 0, 0, 0, 0, 0, [0] * 64]
            gps_module.termios.tcsetattr = lambda fd, when, attrs: None

            with self.assertRaisesRegex(OSError, "fdopen failed"):
                gps_module.open_nmea_stream("/dev/serial/by-id/mock-gps")
        finally:
            gps_module.os.stat = original_stat
            gps_module.os.open = original_open
            gps_module.os.fstat = original_fstat
            gps_module.os.close = original_close
            gps_module.os.fdopen = original_fdopen
            gps_module.termios.tcgetattr = original_tcgetattr
            gps_module.termios.tcsetattr = original_tcsetattr

        self.assertEqual(closed_fds, [456])

    def test_open_nmea_stream_rejects_non_character_device_before_opening(self):
        regular_stat = self._fake_stat_result(stat.S_IFREG | 0o600)
        original_stat = gps_module.os.stat
        original_open = gps_module.os.open

        def unexpected_open(path, flags):
            raise AssertionError("open_nmea_stream should reject non-character device before opening")

        try:
            gps_module.os.stat = lambda path: regular_stat
            gps_module.os.open = unexpected_open
            with self.assertRaisesRegex(OSError, "GPS serial device is not a character device"):
                gps_module.open_nmea_stream("/dev/serial/by-id/mock-gps")
        finally:
            gps_module.os.stat = original_stat
            gps_module.os.open = original_open

    def test_open_nmea_stream_rejects_replaced_device_before_termios(self):
        closed_fds = []
        before_stat = self._fake_stat_result(stat.S_IFCHR | 0o600, inode=100)
        after_stat = self._fake_stat_result(stat.S_IFCHR | 0o600, inode=101)
        original_stat = gps_module.os.stat
        original_open = gps_module.os.open
        original_fstat = gps_module.os.fstat
        original_close = gps_module.os.close
        original_tcgetattr = gps_module.termios.tcgetattr

        def unexpected_tcgetattr(fd):
            raise AssertionError("open_nmea_stream should reject replaced device before termios setup")

        try:
            gps_module.os.stat = lambda path: before_stat
            gps_module.os.open = lambda path, flags: 789
            gps_module.os.fstat = lambda fd: after_stat
            gps_module.os.close = lambda fd: closed_fds.append(fd)
            gps_module.termios.tcgetattr = unexpected_tcgetattr
            with self.assertRaisesRegex(RuntimeError, "GPS serial device changed before it could be opened"):
                gps_module.open_nmea_stream("/dev/serial/by-id/mock-gps")
        finally:
            gps_module.os.stat = original_stat
            gps_module.os.open = original_open
            gps_module.os.fstat = original_fstat
            gps_module.os.close = original_close
            gps_module.termios.tcgetattr = original_tcgetattr

        self.assertEqual(closed_fds, [789])

    def test_parse_gga_sentence(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47"
        fix = parse_nmea_sentence(sentence)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertAlmostEqual(fix.latitude, 48.1173, places=4)
        self.assertAlmostEqual(fix.longitude, 11.5166667, places=4)
        self.assertEqual(fix.satellites, 8)
        self.assertEqual(fix.altitude_m, 545.4)

    def test_parse_nmea_rejects_bad_checksum(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*46"

        with self.assertRaisesRegex(ValueError, "NMEA checksum failed"):
            parse_nmea_sentence(sentence)
        self.assertEqual(list(iter_fixes([sentence])), [])

    def test_parse_nmea_rejects_malformed_checksum_suffix(self):
        for sentence in (
            "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*4Z",
            "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47TRAILING",
        ):
            with self.subTest(sentence=sentence):
                with self.assertRaisesRegex(ValueError, "NMEA checksum failed"):
                    parse_nmea_sentence(sentence)
                self.assertEqual(list(iter_fixes([sentence])), [])

    def test_iter_fixes_rejects_gga_without_fix_quality(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,,08,0.9,545.4,M,46.9,M,,"
        fix = parse_nmea_sentence(sentence)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertIsNone(fix.fix_quality)
        self.assertFalse(fix.valid)
        self.assertEqual(list(iter_fixes([sentence])), [])

    def test_iter_fixes_rejects_gga_with_malformed_fix_quality(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,bad,08,0.9,545.4,M,46.9,M,,"
        fix = parse_nmea_sentence(sentence)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertIsNone(fix.fix_quality)
        self.assertFalse(fix.valid)
        self.assertEqual(list(iter_fixes([sentence])), [])

    def test_parse_nmea_ignores_non_finite_optional_numbers(self):
        gga = "$GPGGA,123519,4807.038,N,01131.000,E,1,NaN,Infinity,-Infinity,M,46.9,M,,"
        rmc = "$GPRMC,123519,A,4807.038,N,01131.000,E,NaN,Infinity,230394,003.1,W"

        gga_fix = parse_nmea_sentence(gga)
        rmc_fix = parse_nmea_sentence(rmc)

        self.assertIsNotNone(gga_fix)
        self.assertIsNotNone(rmc_fix)
        assert gga_fix is not None
        assert rmc_fix is not None
        self.assertIsNone(gga_fix.satellites)
        self.assertIsNone(gga_fix.hdop)
        self.assertIsNone(gga_fix.altitude_m)
        self.assertIsNone(rmc_fix.speed_knots)
        self.assertIsNone(rmc_fix.course_degrees)

    def test_parse_nmea_drops_impossible_optional_quality_and_motion(self):
        gga = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,-0.1,545.4,M,46.9,M,,"
        rmc = "$GPRMC,123519,A,4807.038,N,01131.000,E,-1.0,361.0,230394,003.1,W"

        gga_fix = parse_nmea_sentence(gga)
        rmc_fix = parse_nmea_sentence(rmc)

        self.assertIsNotNone(gga_fix)
        self.assertIsNotNone(rmc_fix)
        assert gga_fix is not None
        assert rmc_fix is not None
        self.assertIsNone(gga_fix.hdop)
        self.assertIsNone(rmc_fix.speed_knots)
        self.assertIsNone(rmc_fix.course_degrees)

    def test_gga_time_without_date_uses_nearest_utc_day(self):
        before_midnight = _parse_time_today("000010", now=datetime(2026, 6, 29, 23, 59, 50, tzinfo=timezone.utc))
        after_midnight = _parse_time_today("235950", now=datetime(2026, 6, 30, 0, 0, 10, tzinfo=timezone.utc))

        self.assertEqual(before_midnight, datetime(2026, 6, 30, 0, 0, 10, tzinfo=timezone.utc))
        self.assertEqual(after_midnight, datetime(2026, 6, 29, 23, 59, 50, tzinfo=timezone.utc))

    def test_gga_time_without_date_rejects_timezone_less_current_time(self):
        with self.assertRaisesRegex(ValueError, "GGA current time must include a timezone"):
            _parse_time_today("123519", now=datetime(2026, 6, 29, 12, 0, 0))

    def test_gga_fractional_time_rounds_across_midnight(self):
        rounded = _parse_time_today("235959.9999999", now=datetime(2026, 6, 29, 23, 59, 59, tzinfo=timezone.utc))

        self.assertEqual(rounded, datetime(2026, 6, 30, 0, 0, 0, tzinfo=timezone.utc))

    def test_parse_gga_malformed_time_is_untimestamped(self):
        for time_value in ("badtime", "NaN000", "-123519"):
            with self.subTest(time_value=time_value):
                fix = parse_nmea_sentence(
                    f"$GPGGA,{time_value},4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
                )

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertIsNone(fix.timestamp)
                self.assertTrue(fix.valid)

    def test_parse_gga_rejects_impossible_time_fields(self):
        for time_value in ("240000", "236000", "235960", "126000"):
            with self.subTest(time_value=time_value):
                fix = parse_nmea_sentence(
                    f"$GPGGA,{time_value},4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
                )

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertIsNone(fix.timestamp)
                self.assertTrue(fix.valid)

    def test_parse_rmc_sentence(self):
        sentence = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A"
        fix = parse_nmea_sentence(sentence)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.timestamp.year, 1994)
        self.assertEqual(fix.speed_knots, 22.4)
        self.assertEqual(fix.course_degrees, 84.4)

    def test_parse_rmc_accepts_navigation_mode_fix(self):
        for mode in ("A", "D", "F", "P", "R"):
            with self.subTest(mode=mode):
                sentence = f"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,290626,,,{mode}"
                fix = parse_nmea_sentence(sentence)

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertTrue(fix.valid)

    def test_parse_rmc_rejects_non_navigation_mode_fix(self):
        for mode in ("E", "M", "N", "S", "X"):
            with self.subTest(mode=mode):
                sentence = f"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,290626,,,{mode}"

                self.assertIsNone(parse_nmea_sentence(sentence))
                self.assertEqual(list(iter_fixes([sentence])), [])

    def test_parse_rmc_fractional_time_rounds_across_date(self):
        sentence = "$GPRMC,235959.9999999,A,4807.038,N,01131.000,E,0.0,0.0,290626,003.1,W"
        fix = parse_nmea_sentence(sentence)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.timestamp, datetime(2026, 6, 30, 0, 0, 0, tzinfo=timezone.utc))

    def test_parse_rmc_malformed_timestamp_is_untimestamped(self):
        for time_value, date_value in (
            ("badtime", "230394"),
            ("123519", "badate"),
            ("123519", "310226"),
            ("NaN000", "230394"),
            ("-123519", "230394"),
        ):
            with self.subTest(time_value=time_value, date_value=date_value):
                fix = parse_nmea_sentence(
                    f"$GPRMC,{time_value},A,4807.038,N,01131.000,E,022.4,084.4,{date_value},003.1,W"
                )

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertIsNone(fix.timestamp)
                self.assertTrue(fix.valid)

    def test_parse_rmc_rejects_impossible_time_fields(self):
        for time_value in ("240000", "236000", "235960", "126000"):
            with self.subTest(time_value=time_value):
                fix = parse_nmea_sentence(
                    f"$GPRMC,{time_value},A,4807.038,N,01131.000,E,022.4,084.4,290626,003.1,W"
                )

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertIsNone(fix.timestamp)
                self.assertTrue(fix.valid)

    def test_parse_nmea_rejects_bad_coordinate_hemispheres(self):
        gga = parse_nmea_sentence("$GPGGA,123519,4807.038,X,01131.000,E,1,08,0.9,545.4,M,46.9,M,,")
        rmc = parse_nmea_sentence("$GPRMC,123519,A,4807.038,N,01131.000,X,022.4,084.4,230394,003.1,W")

        self.assertIsNone(gga)
        self.assertIsNone(rmc)
        self.assertEqual(
            list(
                iter_fixes(
                    [
                        "$GPGGA,123519,4807.038,X,01131.000,E,1,08,0.9,545.4,M,46.9,M,,",
                        "$GPRMC,123519,A,4807.038,N,01131.000,X,022.4,084.4,230394,003.1,W",
                    ]
                )
            ),
            [],
        )

    def test_parse_nmea_rejects_malformed_coordinate_numbers(self):
        bad_minutes = "$GPGGA,123519,4867.000,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
        bad_number = "$GPRMC,123519,A,48XX.038,N,01131.000,E,022.4,084.4,230394,003.1,W"

        self.assertIsNone(parse_nmea_sentence(bad_minutes))
        self.assertIsNone(parse_nmea_sentence(bad_number))
        self.assertEqual(list(iter_fixes([bad_minutes, bad_number])), [])

    def test_parse_nmea_rejects_impossible_coordinate_values(self):
        bad_latitude = "$GPGGA,123519,9100.000,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
        bad_longitude = "$GPRMC,123519,A,4807.038,N,18100.000,W,022.4,084.4,230394,003.1,W"
        negative_degrees = "$GPGGA,123519,-100.000,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
        non_finite = "$GPRMC,123519,A,48NaN,N,01131.000,E,022.4,084.4,230394,003.1,W"

        self.assertIsNone(parse_nmea_sentence(bad_latitude))
        self.assertIsNone(parse_nmea_sentence(bad_longitude))
        self.assertIsNone(parse_nmea_sentence(negative_degrees))
        self.assertIsNone(parse_nmea_sentence(non_finite))
        self.assertEqual(list(iter_fixes([bad_latitude, bad_longitude, negative_degrees, non_finite])), [])

    def test_iter_fixes_merges_gga_and_rmc(self):
        fixes = list(
            iter_fixes(
                [
                    "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47",
                    "$GPRMC,123520,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*60",
                ]
            )
        )
        self.assertGreaterEqual(len(fixes), 1)
        self.assertEqual(fixes[-1].satellites, 8)
        self.assertEqual(fixes[-1].speed_knots, 22.4)

    def test_gpx_logger_writes_trackpoint(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47"
        fix = parse_nmea_sentence(sentence)
        assert fix is not None
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)
            text = path.read_text(encoding="utf-8")
            self.assertIn("<trkpt lat=\"48.11730000\" lon=\"11.51666667\">", text)
            self.assertIn("<ele>545.40</ele>", text)
            self.assertIn("<sat>8</sat>", text)
            self.assertIn("<hdop>0.9</hdop>", text)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_gpx_logger_skips_invalid_direct_fix(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=math.nan,
            longitude=-149.0,
            satellites=8,
            hdop=1.2,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)

            text = path.read_text(encoding="utf-8")
            self.assertNotIn("<trkpt", text)
            self.assertNotIn("nan", text)

    def test_gpx_logger_skips_untimestamped_direct_fix(self):
        fix = GPSFix(latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)

            text = path.read_text(encoding="utf-8")
            self.assertNotIn("<trkpt", text)

    def test_gpx_logger_skips_timezone_less_direct_fix(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, 0),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)

            text = path.read_text(encoding="utf-8")
            self.assertNotIn("<trkpt", text)

    def test_gpx_logger_syncs_track_file_and_directory_to_disk(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        calls = []
        original_fsync = gps_module.os.fsync
        gps_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                path = Path(tmpdir) / "track.gpx"
                with GPXTrackLogger(path, fsync_interval_seconds=0) as logger:
                    logger.append(fix)
        finally:
            gps_module.os.fsync = original_fsync

        self.assertGreaterEqual(len(calls), 5)

    def test_gpx_logger_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = gps_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        gps_module.os.open = fake_open
        try:
            gps_module._fsync_directory(Path("/tmp"))
        finally:
            gps_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_gpx_logger_skips_missing_quality_fields(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)

            text = path.read_text(encoding="utf-8")
            self.assertNotIn("<trkpt", text)

    def test_gpx_logger_tightens_public_track_parent(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            parent = Path(tmpdir) / "tracks"
            parent.mkdir()
            parent.chmod(0o755)
            path = parent / "track.gpx"

            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)

            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_gpx_logger_rejects_track_parent_when_tightening_fails(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        original_chmod = gps_module.os.chmod

        with tempfile.TemporaryDirectory() as tmpdir:
            parent = Path(tmpdir) / "tracks"
            parent.mkdir()
            parent.chmod(0o755)
            path = parent / "track.gpx"

            def no_op_chmod(path_arg, mode):
                if Path(path_arg) == parent:
                    return None
                return original_chmod(path_arg, mode)

            try:
                gps_module.os.chmod = no_op_chmod
                with self.assertRaisesRegex(RuntimeError, "has permissions 0755, expected private 0700"):
                    with GPXTrackLogger(path, name="Test") as logger:
                        logger.append(fix)
            finally:
                gps_module.os.chmod = original_chmod
                parent.chmod(0o700)

            self.assertFalse(path.exists())

    def test_gpx_logger_rejects_misowned_track_parent(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            parent = Path(tmpdir) / "tracks"
            parent.mkdir()
            path = parent / "track.gpx"
            other_uid = os.getuid() + 1

            with patch.object(gps_module.os, "getuid", return_value=other_uid):
                with self.assertRaisesRegex(RuntimeError, "is owned by uid"):
                    with GPXTrackLogger(path, name="Test") as logger:
                        logger.append(fix)

            self.assertFalse(path.exists())

    def test_gpx_logger_rejects_symlinked_track_parent(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "target"
            target.mkdir()
            link_parent = root / "track-parent"
            try:
                link_parent.symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "expected real GPX track storage"):
                with GPXTrackLogger(link_parent / "track.gpx") as logger:
                    logger.append(fix)

            self.assertFalse((target / "track.gpx").exists())

    def test_gpx_logger_rejects_symlinked_track_file(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "target.gpx"
            link = root / "track.gpx"
            target.write_text("existing\n", encoding="utf-8")
            try:
                link.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "expected a new regular GPX track file"):
                with GPXTrackLogger(link, name="Test") as logger:
                    logger.append(fix)

            self.assertEqual(target.read_text(encoding="utf-8"), "existing\n")

    def test_gpx_logger_does_not_overwrite_existing_file(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            path.write_text("existing", encoding="utf-8")

            with self.assertRaises(FileExistsError):
                with GPXTrackLogger(path) as logger:
                    logger.append(fix)

            self.assertEqual(path.read_text(encoding="utf-8"), "existing")

    def test_gpx_position_mark_writes_private_waypoint_file(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 34, 56, tzinfo=timezone.utc),
            latitude=61.2181,
            longitude=-149.9003,
            altitude_m=12.3,
            satellites=9,
            hdop=0.9,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "tracks" / "mark.gpx"
            written = gps_module.write_gpx_position_mark(
                path,
                fix,
                name="MOB & Crew",
                description="Port <rail>",
            )

            self.assertEqual(written, path)
            text = path.read_text(encoding="utf-8")
            self.assertIn('<wpt lat="61.21810000" lon="-149.90030000">', text)
            self.assertIn("<ele>12.30</ele>", text)
            self.assertIn("<time>2026-06-30T12:34:56Z</time>", text)
            self.assertIn("<name>MOB &amp; Crew</name>", text)
            self.assertIn("<desc>Port &lt;rail&gt;</desc>", text)
            self.assertIn("<sat>9</sat>", text)
            self.assertIn("<hdop>0.9</hdop>", text)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_gpx_position_mark_rejects_missing_quality_fields(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 34, 56, tzinfo=timezone.utc),
            latitude=61.2181,
            longitude=-149.9003,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "tracks" / "mark.gpx"

            with self.assertRaisesRegex(ValueError, "satellite or HDOP"):
                gps_module.write_gpx_position_mark(path, fix)

            self.assertFalse(path.exists())

    def test_gpx_position_mark_rejects_timezone_less_fix(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 34, 56),
            latitude=61.2181,
            longitude=-149.9003,
            satellites=9,
            hdop=0.9,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "tracks" / "mark.gpx"

            with self.assertRaisesRegex(ValueError, "timestamp has no timezone"):
                gps_module.write_gpx_position_mark(path, fix)

            self.assertFalse(path.exists())

    def test_gpx_position_mark_rejects_symlinked_target_file(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 34, 56, tzinfo=timezone.utc),
            latitude=61.2181,
            longitude=-149.9003,
            satellites=9,
            hdop=0.9,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "target.gpx"
            target.write_text("existing\n", encoding="utf-8")
            link = root / "tracks" / "mark.gpx"
            link.parent.mkdir()
            try:
                link.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "expected a new regular GPX position mark file"):
                gps_module.write_gpx_position_mark(link, fix)

            self.assertEqual(target.read_text(encoding="utf-8"), "existing\n")

    def test_gpx_position_mark_failed_cleanup_leaves_replaced_path(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 34, 56, tzinfo=timezone.utc),
            latitude=61.2181,
            longitude=-149.9003,
            satellites=9,
            hdop=0.9,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "tracks" / "mark.gpx"
            original_writer = gps_module._write_gpx_position_mark

            def replace_path_then_fail(handle, fix_arg, *, name, description):
                handle.write("partial waypoint\n")
                handle.flush()
                path.unlink()
                path.write_text("replacement\n", encoding="utf-8")
                path.chmod(0o600)
                raise RuntimeError("simulated mark write failure")

            try:
                gps_module._write_gpx_position_mark = replace_path_then_fail
                with redirect_stderr(StringIO()) as stderr:
                    with self.assertRaisesRegex(RuntimeError, "simulated mark write failure"):
                        gps_module.write_gpx_position_mark(path, fix)
            finally:
                gps_module._write_gpx_position_mark = original_writer

            self.assertEqual(path.read_text(encoding="utf-8"), "replacement\n")
            self.assertIn("GPX position mark cleanup changed before cleanup", stderr.getvalue())

    def test_gpx_position_mark_does_not_overwrite_existing_file(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 34, 56, tzinfo=timezone.utc),
            latitude=61.2181,
            longitude=-149.9003,
            satellites=9,
            hdop=0.9,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "tracks" / "mark.gpx"
            path.parent.mkdir()
            path.write_text("existing\n", encoding="utf-8")

            with self.assertRaises(FileExistsError):
                gps_module.write_gpx_position_mark(path, fix)

            self.assertEqual(path.read_text(encoding="utf-8"), "existing\n")

    def test_gpx_position_mark_available_uses_suffix_for_existing_timestamp_mark(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 34, 56, tzinfo=timezone.utc),
            latitude=61.2181,
            longitude=-149.9003,
            satellites=9,
            hdop=0.9,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            first = root / "tracks" / "mark-20260630T123456Z.gpx"
            first.parent.mkdir()
            first.write_text("existing\n", encoding="utf-8")

            written = gps_module.write_available_gpx_position_mark(first, fix)

            self.assertEqual(written, root / "tracks" / "mark-20260630T123456Z-1.gpx")
            self.assertEqual(first.read_text(encoding="utf-8"), "existing\n")
            self.assertTrue(written.exists())
            self.assertEqual(stat.S_IMODE(written.stat().st_mode), 0o600)

    def test_gpx_position_mark_available_retries_after_create_race(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 34, 56, tzinfo=timezone.utc),
            latitude=61.2181,
            longitude=-149.9003,
            satellites=9,
            hdop=0.9,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "tracks" / "mark-20260630T123456Z.gpx"
            original = gps_module.write_gpx_position_mark
            calls = []

            def racing_write(candidate, fix_arg, *, name="Position mark", description=""):
                calls.append(Path(candidate))
                if len(calls) == 1:
                    raise FileExistsError(str(candidate))
                return original(candidate, fix_arg, name=name, description=description)

            try:
                gps_module.write_gpx_position_mark = racing_write
                written = gps_module.write_available_gpx_position_mark(path, fix)
            finally:
                gps_module.write_gpx_position_mark = original

            self.assertEqual(calls, [path, path.with_name("mark-20260630T123456Z-1.gpx")])
            self.assertEqual(written, path.with_name("mark-20260630T123456Z-1.gpx"))
            self.assertTrue(written.exists())

    def test_gpx_position_mark_path_uses_utc_timestamp(self):
        timestamp = datetime(2026, 6, 30, 12, 34, 56, tzinfo=timezone.utc)
        self.assertEqual(
            gps_module.gpx_position_mark_path(Path("/tracks"), timestamp, prefix="MOB!"),
            Path("/tracks/tracks/MOB-20260630T123456Z.gpx"),
        )

    def test_gpx_position_mark_path_rejects_timezone_less_timestamp(self):
        with self.assertRaisesRegex(ValueError, "timestamp must include a timezone"):
            gps_module.gpx_position_mark_path(Path("/tracks"), datetime(2026, 6, 30, 12, 34, 56))

    def test_daily_track_path_uses_utc_date(self):
        timestamp = datetime(2026, 6, 29, 23, 30, tzinfo=timezone.utc)
        self.assertEqual(daily_track_path(Path("/tracks"), timestamp), Path("/tracks/tracks/track-20260629.gpx"))

    def test_daily_track_path_rejects_timezone_less_timestamp(self):
        with self.assertRaisesRegex(ValueError, "daily track timestamp must include a timezone"):
            daily_track_path(Path("/tracks"), datetime(2026, 6, 29, 23, 30))

    def test_log_rotating_tracks_writes_one_file_per_utc_day(self):
        fixes = [
            GPSFix(timestamp=datetime(2026, 6, 29, 23, 59, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2),
            GPSFix(timestamp=datetime(2026, 6, 30, 0, 1, tzinfo=timezone.utc), latitude=3.0, longitude=4.0, satellites=8, hdop=1.2),
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            with redirect_stdout(StringIO()):
                count, outputs = _log_rotating_tracks(iter(fixes), Path(tmpdir), deadline=None, sample=True)
            self.assertEqual(count, 2)
            self.assertEqual([path.name for path in outputs], ["track-20260629.gpx", "track-20260630.gpx"])
            self.assertEqual((Path(tmpdir) / "tracks").stat().st_mode & 0o777, 0o700)
            self.assertIn('lat="1.00000000"', outputs[0].read_text(encoding="utf-8"))
            self.assertIn('lat="3.00000000"', outputs[1].read_text(encoding="utf-8"))

    def test_prepare_private_tracks_dir_rejects_directory_when_tightening_fails(self):
        original_chmod = cli_module.os.chmod

        with tempfile.TemporaryDirectory() as tmpdir:
            tracks = Path(tmpdir) / "tracks"
            tracks.mkdir()
            tracks.chmod(0o755)

            def no_op_chmod(path_arg, mode):
                if Path(path_arg) == tracks:
                    return None
                return original_chmod(path_arg, mode)

            try:
                cli_module.os.chmod = no_op_chmod
                with self.assertRaisesRegex(RuntimeError, "has permissions 0755, expected private 0700"):
                    cli_module._prepare_private_tracks_dir(tracks)
            finally:
                cli_module.os.chmod = original_chmod
                tracks.chmod(0o700)

    def test_log_rotating_tracks_rejects_symlinked_tracks_directory(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "target"
            target.mkdir()
            try:
                (root / "tracks").symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "symlink"):
                with redirect_stdout(StringIO()):
                    _log_rotating_tracks(iter([fix]), root, deadline=None, sample=True)

    def test_log_rotating_tracks_rejects_symlinked_base_directory(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "target"
            target.mkdir()
            link_base = root / "track-storage"
            try:
                link_base.symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "expected a private tracks directory"):
                with redirect_stdout(StringIO()):
                    _log_rotating_tracks(iter([fix]), link_base, deadline=None, sample=True)

            self.assertFalse((target / "tracks").exists())

    def test_log_single_track_closes_gpx_on_stop_signal_exception(self):
        def fixes():
            yield GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
            raise _TrackLoggerStop("SIGTERM")

        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "track.gpx"
            with redirect_stdout(StringIO()):
                with self.assertRaises(_TrackLoggerStop):
                    _log_single_track(fixes(), output, deadline=None, sample=False)

            text = output.read_text(encoding="utf-8")
            self.assertIn('lat="1.00000000"', text)
            self.assertTrue(text.endswith("</gpx>\n"))

    def test_log_single_track_does_not_create_file_without_fixes(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "track.gpx"
            with redirect_stdout(StringIO()):
                count = _log_single_track(iter([]), output, deadline=None, sample=True)

            self.assertEqual(count, 0)
            self.assertFalse(output.exists())

    def test_log_single_track_does_not_create_file_for_only_weak_fixes(self):
        weak = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=3,
            hdop=1.2,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "track.gpx"
            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                count = _log_single_track(_trackable_fixes(iter([weak])), output, deadline=None, sample=True)

            self.assertEqual(count, 0)
            self.assertFalse(output.exists())

    def test_log_single_track_does_not_create_file_for_null_island_fix(self):
        invalid = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=0.0,
            longitude=0.0,
            satellites=8,
            hdop=1.2,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "track.gpx"
            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                count = _log_single_track(_trackable_fixes(iter([invalid])), output, deadline=None, sample=True)

            self.assertEqual(count, 0)
            self.assertFalse(output.exists())

    def test_log_single_track_does_not_create_file_for_missing_coordinates(self):
        invalid = GPSFix(
            timestamp=datetime.now(timezone.utc),
            satellites=8,
            hdop=1.2,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "track.gpx"
            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                count = _log_single_track(_trackable_fixes(iter([invalid])), output, deadline=None, sample=True)
            self.assertEqual(count, 0)
            self.assertFalse(output.exists())

    def test_trackable_fixes_skip_reported_weak_quality(self):
        now = datetime.now(timezone.utc)
        weak = GPSFix(
            timestamp=now,
            latitude=1.0,
            longitude=2.0,
            satellites=3,
            hdop=1.2,
        )
        good = GPSFix(
            timestamp=now,
            latitude=3.0,
            longitude=4.0,
            satellites=5,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([weak, good])))

        self.assertEqual(fixes, [good])
        self.assertIn("Skipping weak track fix", stderr.getvalue())

    def test_trackable_fixes_skip_untimestamped_quality_fix(self):
        now = datetime.now(timezone.utc)
        untimestamped = GPSFix(
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        timestamped = GPSFix(
            timestamp=now,
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([untimestamped, timestamped])))

        self.assertEqual(fixes, [timestamped])
        self.assertIn("Skipping untimestamped track fix", stderr.getvalue())

    def test_trackable_fixes_skip_timezone_less_fix(self):
        naive = GPSFix(
            timestamp=datetime(2026, 6, 30, 12, 0, 0),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        aware = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([naive, aware])))

        self.assertEqual(fixes, [aware])
        self.assertIn("Skipping timezone-less track fix", stderr.getvalue())
        self.assertIn("fix timestamp has no timezone", stderr.getvalue())

    def test_trackable_fixes_skip_stale_timestamped_fix(self):
        stale = GPSFix(
            timestamp=datetime.now(timezone.utc) - timedelta(minutes=10),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        fresh = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([stale, fresh])))

        self.assertEqual(fixes, [fresh])
        self.assertIn("Skipping stale track fix", stderr.getvalue())
        self.assertIn("stale", stderr.getvalue())

    def test_trackable_fixes_skip_future_timestamped_fix(self):
        future = GPSFix(
            timestamp=datetime.now(timezone.utc) + timedelta(minutes=10),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        fresh = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([future, fresh])))

        self.assertEqual(fixes, [fresh])
        self.assertIn("Skipping stale track fix", stderr.getvalue())
        self.assertIn("future", stderr.getvalue())

    def test_trackable_fixes_skip_slightly_future_timestamped_fix(self):
        now = datetime.now(timezone.utc)
        future = GPSFix(
            timestamp=now + timedelta(seconds=1),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        fresh = GPSFix(
            timestamp=now,
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([future, fresh])))

        self.assertEqual(fixes, [fresh])
        self.assertIn("Skipping stale track fix", stderr.getvalue())
        self.assertIn("future", stderr.getvalue())

    def test_trackable_fixes_skip_position_only_fix(self):
        position_only = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=1.0,
            longitude=2.0,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([position_only])))

        self.assertEqual(fixes, [])
        self.assertIn("Skipping low-detail track fix", stderr.getvalue())
        self.assertIn("missing satellite or HDOP quality fields", stderr.getvalue())

    def test_trackable_fixes_skip_position_only_before_quality_fix(self):
        now = datetime.now(timezone.utc) - timedelta(seconds=2)
        first = GPSFix(
            timestamp=now,
            latitude=1.0,
            longitude=2.0,
        )
        second = GPSFix(
            timestamp=now + timedelta(seconds=1),
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()):
            fixes = list(_trackable_fixes(iter([first, second])))

        self.assertEqual(fixes, [second])

    def test_trackable_fixes_skip_position_only_before_weak_quality(self):
        now = datetime.now(timezone.utc) - timedelta(seconds=2)
        position_only = GPSFix(
            timestamp=now,
            latitude=1.0,
            longitude=2.0,
        )
        weak = GPSFix(
            timestamp=now + timedelta(seconds=1),
            latitude=3.0,
            longitude=4.0,
            satellites=3,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()):
            fixes = list(_trackable_fixes(iter([position_only, weak])))

        self.assertEqual(fixes, [])

    def test_trackable_fixes_drop_untimestamped_position_only_fix(self):
        untimestamped = GPSFix(latitude=1.0, longitude=2.0)
        timestamped = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()):
            fixes = list(_trackable_fixes(iter([untimestamped, timestamped])))

        self.assertEqual(fixes, [timestamped])

    def test_trackable_fixes_skip_position_only_before_untimestamped_fix(self):
        timestamped = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=1.0,
            longitude=2.0,
        )
        untimestamped = GPSFix(latitude=3.0, longitude=4.0)

        with redirect_stderr(StringIO()):
            fixes = list(_trackable_fixes(iter([timestamped, untimestamped])))

        self.assertEqual(fixes, [])

    def test_shared_gps_quality_rejects_high_hdop(self):
        fix = GPSFix(latitude=1.0, longitude=2.0, satellites=8, hdop=9.9)

        self.assertIn("HDOP", gps_fix_quality_failure(fix))

    def test_shared_gps_quality_rejects_negative_hdop(self):
        fix = GPSFix(latitude=1.0, longitude=2.0, satellites=8, hdop=-0.1)

        self.assertIn("negative HDOP", gps_fix_quality_failure(fix))

    def test_shared_gps_quality_rejects_null_island_fix(self):
        fix = GPSFix(latitude=0.0, longitude=0.0, satellites=8, hdop=1.2)

        self.assertIn("0.000000, 0.000000", gps_fix_quality_failure(fix))

    def test_shared_gps_quality_rejects_out_of_range_coordinates(self):
        latitude = GPSFix(latitude=91.0, longitude=-149.0, satellites=8, hdop=1.2)
        longitude = GPSFix(latitude=61.0, longitude=-181.0, satellites=8, hdop=1.2)

        self.assertIn("latitude 91.000000 outside -90..90", gps_fix_quality_failure(latitude))
        self.assertIn("longitude -181.000000 outside -180..180", gps_fix_quality_failure(longitude))

    def test_shared_gps_quality_rejects_missing_coordinates(self):
        fix = GPSFix(satellites=8, hdop=1.2)

        self.assertIn("missing coordinates", gps_fix_quality_failure(fix))

    def test_shared_gps_quality_rejects_non_finite_coordinates(self):
        fix = GPSFix(latitude=math.nan, longitude=-149.0, satellites=8, hdop=1.2)

        self.assertIn("non-finite coordinates", gps_fix_quality_failure(fix))

    def test_track_signal_handler_raises_stop_exception(self):
        with self.assertRaisesRegex(_TrackLoggerStop, "SIGTERM"):
            _raise_track_logger_stop(signal.SIGTERM, None)

    def test_log_rotating_tracks_does_not_overwrite_existing_daily_file(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            existing = Path(tmpdir) / "tracks" / "track-20260629.gpx"
            existing.parent.mkdir()
            existing.write_text("old", encoding="utf-8")
            with redirect_stdout(StringIO()):
                count, outputs = _log_rotating_tracks(iter([fix]), Path(tmpdir), deadline=None, sample=True)
            self.assertEqual(count, 1)
            self.assertEqual(outputs[0].name, "track-20260629-1.gpx")
            self.assertEqual(existing.read_text(encoding="utf-8"), "old")

    def test_log_rotating_tracks_prunes_old_daily_files(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            tracks = Path(tmpdir) / "tracks"
            tracks.mkdir()
            old = tracks / "track-20260401.gpx"
            keep = tracks / "track-20260620.gpx"
            unrelated = tracks / "notes.gpx"
            old.write_text("old", encoding="utf-8")
            old.chmod(0o600)
            keep.write_text("keep", encoding="utf-8")
            unrelated.write_text("notes", encoding="utf-8")

            with redirect_stdout(StringIO()):
                _log_rotating_tracks(iter([fix]), Path(tmpdir), deadline=None, sample=True, retention_days=30)

            self.assertFalse(old.exists())
            self.assertTrue(keep.exists())
            self.assertTrue(unrelated.exists())
            self.assertTrue((tracks / "track-20260630.gpx").exists())

    def test_pruned_track_log_directory_is_synced(self):
        calls = []
        original_fsync = cli_module.os.fsync
        cli_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                tracks = Path(tmpdir) / "tracks"
                tracks.mkdir()
                tracks.chmod(0o700)
                old = tracks / "track-20260401.gpx"
                old.write_text("old", encoding="utf-8")
                old.chmod(0o600)

                removed = cli_module._prune_old_track_logs(
                    Path(tmpdir),
                    retention_days=30,
                    now=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc),
                )
        finally:
            cli_module.os.fsync = original_fsync

        self.assertEqual([path.name for path in removed], ["track-20260401.gpx"])
        self.assertGreaterEqual(len(calls), 1)

    def test_prune_old_track_logs_rejects_timezone_less_current_time(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tracks = Path(tmpdir) / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)

            with self.assertRaisesRegex(ValueError, "current time must include a timezone"):
                cli_module._prune_old_track_logs(
                    Path(tmpdir),
                    retention_days=30,
                    now=datetime(2026, 6, 30, 12, 0),
                )

    def test_gpx_track_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = cli_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        cli_module.os.open = fake_open
        try:
            cli_module._fsync_directory(Path("/tmp"))
        finally:
            cli_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], Path("/tmp"))
        self.assertTrue(calls[0][1] & getattr(os, "O_DIRECTORY", 0))
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_prune_old_track_logs_rejects_symlinked_old_track(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tracks = Path(tmpdir) / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            target = Path(tmpdir) / "target.gpx"
            target.write_text("existing\n", encoding="utf-8")
            old_link = tracks / "track-20260401.gpx"
            try:
                old_link.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "refusing to prune GPX track logs"):
                cli_module._prune_old_track_logs(
                    Path(tmpdir),
                    retention_days=30,
                    now=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc),
                )

            self.assertTrue(old_link.is_symlink())
            self.assertEqual(target.read_text(encoding="utf-8"), "existing\n")

    def test_prune_old_track_logs_rejects_nonregular_old_track(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tracks = Path(tmpdir) / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            old_dir = tracks / "track-20260401.gpx"
            old_dir.mkdir()

            with self.assertRaisesRegex(RuntimeError, "not a regular GPX track file"):
                cli_module._prune_old_track_logs(
                    Path(tmpdir),
                    retention_days=30,
                    now=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc),
                )

            self.assertTrue(old_dir.is_dir())

    def test_prune_old_track_logs_rejects_public_old_track(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tracks = Path(tmpdir) / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            old = tracks / "track-20260401.gpx"
            old.write_text("old", encoding="utf-8")
            old.chmod(0o644)

            with self.assertRaisesRegex(RuntimeError, "expected private 0600"):
                cli_module._prune_old_track_logs(
                    Path(tmpdir),
                    retention_days=30,
                    now=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc),
                )

            self.assertTrue(old.exists())
            self.assertEqual(old.read_text(encoding="utf-8"), "old")

    def test_prune_old_track_logs_uses_no_follow_descriptor_before_unlink(self):
        open_calls = []
        unlink_calls = []
        stat_calls = []
        original_open = cli_module.os.open
        original_stat = cli_module.os.stat
        original_unlink = cli_module.os.unlink

        def recording_open(path, flags, mode=0o777, *, dir_fd=None):
            open_calls.append((path, flags, dir_fd))
            if dir_fd is None:
                return original_open(path, flags, mode)
            return original_open(path, flags, mode, dir_fd=dir_fd)

        def recording_stat(path, *args, dir_fd=None, follow_symlinks=True, **kwargs):
            stat_calls.append((path, dir_fd, follow_symlinks))
            if dir_fd is None:
                return original_stat(path, *args, follow_symlinks=follow_symlinks, **kwargs)
            return original_stat(path, *args, dir_fd=dir_fd, follow_symlinks=follow_symlinks, **kwargs)

        def recording_unlink(path, *, dir_fd=None):
            unlink_calls.append((path, dir_fd))
            return original_unlink(path, dir_fd=dir_fd)

        cli_module.os.open = recording_open
        cli_module.os.stat = recording_stat
        cli_module.os.unlink = recording_unlink
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                tracks = Path(tmpdir) / "tracks"
                tracks.mkdir()
                tracks.chmod(0o700)
                old = tracks / "track-20260401.gpx"
                old.write_text("old", encoding="utf-8")
                old.chmod(0o600)

                removed = cli_module._prune_old_track_logs(
                    Path(tmpdir),
                    retention_days=30,
                    now=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc),
                )
        finally:
            cli_module.os.open = original_open
            cli_module.os.stat = original_stat
            cli_module.os.unlink = original_unlink

        self.assertEqual([path.name for path in removed], ["track-20260401.gpx"])
        track_open = [call for call in open_calls if call[0] == "track-20260401.gpx"]
        self.assertEqual(len(track_open), 1)
        self.assertTrue(track_open[0][1] & getattr(os, "O_NOFOLLOW", 0))
        self.assertIsNotNone(track_open[0][2])
        track_stat = [call for call in stat_calls if call[0] == "track-20260401.gpx"]
        self.assertEqual(track_stat, [("track-20260401.gpx", track_open[0][2], False)])
        track_unlink = [call for call in unlink_calls if call[0] == "track-20260401.gpx"]
        self.assertEqual(track_unlink, [("track-20260401.gpx", track_open[0][2])])

    def test_prune_old_track_logs_rejects_replaced_track_before_unlink(self):
        original_validate = cli_module._validate_prunable_track_log
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                tracks = Path(tmpdir) / "tracks"
                tracks.mkdir()
                tracks.chmod(0o700)
                old = tracks / "track-20260401.gpx"
                old.write_text("old", encoding="utf-8")
                old.chmod(0o600)
                replacement = tracks / "replacement.gpx"
                replacement.write_text("replacement", encoding="utf-8")
                replacement.chmod(0o600)

                def replacing_validate(path, *, tracks_fd):
                    result = original_validate(path, tracks_fd=tracks_fd)
                    os.replace(replacement, path)
                    return result

                cli_module._validate_prunable_track_log = replacing_validate
                with self.assertRaisesRegex(RuntimeError, "changed before GPX pruning"):
                    cli_module._prune_old_track_logs(
                        Path(tmpdir),
                        retention_days=30,
                        now=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc),
                    )
                self.assertTrue(old.exists())
                self.assertEqual(old.read_text(encoding="utf-8"), "replacement")
        finally:
            cli_module._validate_prunable_track_log = original_validate

    def test_parse_gpsd_tpv(self):
        payload = (
            '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
            '"lat":61.2181,"lon":-149.9003,"speed":2.0,"track":180.5,"alt":12.3}'
        )
        fix = parse_gpsd_tpv(payload)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertAlmostEqual(fix.latitude, 61.2181)
        self.assertAlmostEqual(fix.longitude, -149.9003)
        self.assertAlmostEqual(fix.speed_knots, 3.887688984)
        self.assertEqual(fix.course_degrees, 180.5)

    def test_parse_gpsd_tpv_rejects_non_finite_position(self):
        payload = '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z","lat":NaN,"lon":-149.9003}'

        self.assertIsNone(parse_gpsd_tpv(payload))

    def test_parse_gpsd_tpv_rejects_out_of_range_position(self):
        bad_latitude = '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z","lat":91.0,"lon":-149.9003}'
        bad_longitude = '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z","lat":61.2181,"lon":-181.0}'

        self.assertIsNone(parse_gpsd_tpv(bad_latitude))
        self.assertIsNone(parse_gpsd_tpv(bad_longitude))

    def test_parse_gpsd_tpv_rejects_malformed_fix_mode(self):
        base = '"class":"TPV","time":"2026-06-28T12:34:56.000Z","lat":61.2181,"lon":-149.9003'

        self.assertIsNone(parse_gpsd_tpv("{" + base + ',"mode":NaN}'))
        self.assertIsNone(parse_gpsd_tpv("{" + base + ',"mode":2.5}'))
        self.assertIsNone(parse_gpsd_tpv("{" + base + ',"mode":"bad"}'))

    def test_parse_gpsd_tpv_ignores_malformed_or_timezone_less_time(self):
        for time_value in ('"bad-time"', '"2026-06-28T12:34:56.000"', "12345", "true"):
            with self.subTest(time_value=time_value):
                payload = (
                    '{"class":"TPV","mode":3,"time":'
                    + time_value
                    + ',"lat":61.2181,"lon":-149.9003,"speed":2.0}'
                )
                fix = parse_gpsd_tpv(payload)

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertIsNone(fix.timestamp)
                self.assertAlmostEqual(fix.latitude, 61.2181)
                self.assertAlmostEqual(fix.speed_knots, 3.887688984)

    def test_parse_gpsd_tpv_drops_non_finite_optional_numbers(self):
        payload = (
            '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
            '"lat":61.2181,"lon":-149.9003,"speed":NaN,"track":Infinity,"alt":-Infinity}'
        )
        fix = parse_gpsd_tpv(payload)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertIsNone(fix.speed_knots)
        self.assertIsNone(fix.course_degrees)
        self.assertIsNone(fix.altitude_m)

    def test_parse_gpsd_tpv_drops_impossible_optional_motion(self):
        payload = (
            '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
            '"lat":61.2181,"lon":-149.9003,"speed":-0.1,"track":361.0,"alt":-12.3}'
        )
        fix = parse_gpsd_tpv(payload)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertIsNone(fix.speed_knots)
        self.assertIsNone(fix.course_degrees)
        self.assertEqual(fix.altitude_m, -12.3)

    def test_parse_gpsd_sky_uses_usat_and_hdop(self):
        payload = '{"class":"SKY","uSat":7,"nSat":11,"hdop":1.4}'
        fix = parse_gpsd_sky(payload)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 7)
        self.assertEqual(fix.hdop, 1.4)

    def test_parse_gpsd_sky_drops_non_finite_hdop(self):
        payload = '{"class":"SKY","uSat":7,"hdop":NaN}'
        fix = parse_gpsd_sky(payload)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 7)
        self.assertIsNone(fix.hdop)

    def test_parse_gpsd_sky_drops_negative_hdop(self):
        payload = '{"class":"SKY","uSat":7,"hdop":-0.1}'
        fix = parse_gpsd_sky(payload)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 7)
        self.assertIsNone(fix.hdop)

    def test_parse_gpsd_sky_ignores_malformed_usat(self):
        payload = '{"class":"SKY","uSat":NaN,"satellites":[{"used":true},{"used":false},{"used":true}]}'
        fix = parse_gpsd_sky(payload)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 2)

    def test_parse_gpsd_sky_counts_used_satellites(self):
        payload = (
            '{"class":"SKY","hdop":2.1,"satellites":['
            '{"PRN":1,"used":true},{"PRN":2,"used":false},{"PRN":3,"used":true}]}'
        )
        fix = parse_gpsd_sky(payload)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 2)
        self.assertEqual(fix.hdop, 2.1)

    def test_parse_nmea_gsa_quality(self):
        fix = parse_nmea_sentence("$GPGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5")

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.fix_quality, 3)
        self.assertEqual(fix.satellites, 4)
        self.assertEqual(fix.hdop, 0.9)

    def test_iter_fixes_merges_gsa_quality_into_rmc_position(self):
        fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
        fix_date = datetime.now(timezone.utc).strftime("%d%m%y")
        fixes = list(
            iter_fixes(
                [
                    f"$GPRMC,{fix_time},A,4807.038,N,01131.000,E,022.4,084.4,{fix_date},,,A",
                    "$GPGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5",
                ]
            )
        )

        self.assertEqual(len(fixes), 2)
        self.assertIsNone(fixes[0].satellites)
        self.assertEqual(fixes[1].satellites, 4)
        self.assertEqual(fixes[1].hdop, 0.9)
        self.assertAlmostEqual(fixes[1].latitude, 48.1173, places=4)

    def test_iter_fixes_rejects_stale_gsa_quality_for_rmc_position(self):
        fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
        fix_date = datetime.now(timezone.utc).strftime("%d%m%y")
        original_monotonic = gps_module.time.monotonic
        times = iter([0.0, 10.0])
        gps_module.time.monotonic = lambda: next(times)
        try:
            fixes = list(
                iter_fixes(
                    [
                        "$GPGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5",
                        f"$GPRMC,{fix_time},A,4807.038,N,01131.000,E,022.4,084.4,{fix_date},,,A",
                    ]
                )
            )
        finally:
            gps_module.time.monotonic = original_monotonic

        self.assertEqual(fixes, [])

    def test_iter_fixes_accepts_fresh_gsa_after_stale_quality_gap(self):
        fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
        fix_date = datetime.now(timezone.utc).strftime("%d%m%y")
        original_monotonic = gps_module.time.monotonic
        times = iter([0.0, 10.0, 10.1])
        gps_module.time.monotonic = lambda: next(times)
        try:
            fixes = list(
                iter_fixes(
                    [
                        "$GPGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5",
                        f"$GPRMC,{fix_time},A,4807.038,N,01131.000,E,022.4,084.4,{fix_date},,,A",
                        "$GPGSA,A,3,04,05,09,12,15,,,,,,,,1.8,0.8,1.5",
                    ]
                )
            )
        finally:
            gps_module.time.monotonic = original_monotonic

        self.assertEqual(len(fixes), 1)
        self.assertEqual(fixes[0].satellites, 5)
        self.assertEqual(fixes[0].hdop, 0.8)
        self.assertAlmostEqual(fixes[0].latitude, 48.1173, places=4)

    def test_iter_gpsd_fixes_merges_sky_quality_into_tpv(self):
        original = gps_module.socket.create_connection

        class FakeSocket:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return StringIO(
                    '{"class":"SKY","uSat":5,"hdop":1.8}\n'
                    '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
                    '"lat":61.2181,"lon":-149.9003}\n'
                )

            def settimeout(self, timeout):
                self.timeout = timeout

        try:
            gps_module.socket.create_connection = lambda address, timeout=10.0: FakeSocket()
            fix = next(iter_gpsd_fixes(timeout=1))
        finally:
            gps_module.socket.create_connection = original

        self.assertEqual(fix.satellites, 5)
        self.assertEqual(fix.hdop, 1.8)
        self.assertAlmostEqual(fix.latitude, 61.2181)

    def test_iter_gpsd_fixes_rejects_overlong_message(self):
        original = gps_module.socket.create_connection

        class FakeSocket:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return StringIO("x" * 18)

            def settimeout(self, timeout):
                self.timeout = timeout

        try:
            gps_module.socket.create_connection = lambda address, timeout=10.0: FakeSocket()
            with self.assertRaisesRegex(ValueError, "GPSD message exceeded 16 bytes"):
                list(iter_gpsd_fixes(timeout=1, max_message_bytes=16))
        finally:
            gps_module.socket.create_connection = original

    def test_iter_gpsd_fixes_accepts_bounded_message(self):
        original = gps_module.socket.create_connection
        payload = '{"class":"TPV","mode":3,"lat":61.2,"lon":-149.9}\n'

        class FakeSocket:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return StringIO(payload)

            def settimeout(self, timeout):
                self.timeout = timeout

        try:
            gps_module.socket.create_connection = lambda address, timeout=10.0: FakeSocket()
            fixes = list(iter_gpsd_fixes(timeout=1, max_message_bytes=len(payload)))
        finally:
            gps_module.socket.create_connection = original

        self.assertEqual(len(fixes), 1)
        self.assertAlmostEqual(fixes[0].latitude, 61.2)

    def test_iter_gpsd_fixes_ignores_stale_sky_quality(self):
        original_socket = gps_module.socket.create_connection
        original_monotonic = gps_module.time.monotonic

        class FakeSocket:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return StringIO(
                    '{"class":"SKY","uSat":3,"hdop":9.9}\n'
                    '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
                    '"lat":61.2181,"lon":-149.9003}\n'
                )

            def settimeout(self, timeout):
                self.timeout = timeout

        clock_values = iter([100.0, 121.0])
        try:
            gps_module.socket.create_connection = lambda address, timeout=10.0: FakeSocket()
            gps_module.time.monotonic = lambda: next(clock_values)
            fix = next(iter_gpsd_fixes(timeout=1, sky_max_age_seconds=10.0))
        finally:
            gps_module.socket.create_connection = original_socket
            gps_module.time.monotonic = original_monotonic

        self.assertIsNone(fix.satellites)
        self.assertIsNone(fix.hdop)
        self.assertAlmostEqual(fix.latitude, 61.2181)

    def test_iter_gpsd_fixes_clears_read_timeout_for_unbounded_stream(self):
        original_socket = gps_module.socket.create_connection

        class FakeSocket:
            def __init__(self):
                self.timeouts = []
                self.request = b""

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return StringIO(
                    '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
                    '"lat":61.2181,"lon":-149.9003}\n'
                )

            def settimeout(self, timeout):
                self.timeouts.append(timeout)

        fake_socket = FakeSocket()
        calls = []

        def fake_create_connection(address, timeout=10.0):
            calls.append((address, timeout))
            return fake_socket

        try:
            gps_module.socket.create_connection = fake_create_connection
            fix = next(iter_gpsd_fixes(host="127.0.0.1", port=2947, timeout=7, max_duration=None))
        finally:
            gps_module.socket.create_connection = original_socket

        self.assertEqual(calls, [(("127.0.0.1", 2947), 7)])
        self.assertEqual(fake_socket.timeouts, [None])
        self.assertAlmostEqual(fix.latitude, 61.2181)

    def test_iter_gpsd_fixes_sets_idle_timeout_for_unbounded_stream(self):
        original_socket = gps_module.socket.create_connection

        class FakeSocket:
            def __init__(self):
                self.timeouts = []

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return StringIO(
                    '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
                    '"lat":61.2181,"lon":-149.9003}\n'
                )

            def settimeout(self, timeout):
                self.timeouts.append(timeout)

        fake_socket = FakeSocket()

        try:
            gps_module.socket.create_connection = lambda address, timeout=10.0: fake_socket
            fix = next(iter_gpsd_fixes(timeout=1, idle_timeout=300.0))
        finally:
            gps_module.socket.create_connection = original_socket

        self.assertEqual(fake_socket.timeouts, [300.0])
        self.assertAlmostEqual(fix.latitude, 61.2181)

    def test_iter_gpsd_fixes_raises_on_idle_timeout(self):
        original_socket = gps_module.socket.create_connection

        class IdleHandle:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def readline(self, size=-1):
                raise TimeoutError("idle")

        class FakeSocket:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return IdleHandle()

            def settimeout(self, timeout):
                self.timeout = timeout

        try:
            gps_module.socket.create_connection = lambda address, timeout=10.0: FakeSocket()
            with self.assertRaisesRegex(TimeoutError, "no GPSD messages within 300s"):
                list(iter_gpsd_fixes(timeout=1, idle_timeout=300.0))
        finally:
            gps_module.socket.create_connection = original_socket

    def test_read_nmea_lines_raises_on_idle_timeout(self):
        original_monotonic = gps_module.time.monotonic

        class IdleStream:
            def read(self, size=-1):
                return b""

        clock_values = iter([100.0, 401.0])
        try:
            gps_module.time.monotonic = lambda: next(clock_values)
            with self.assertRaisesRegex(TimeoutError, "no NMEA bytes within 300s"):
                next(read_nmea_lines(IdleStream(), idle_timeout=300.0))
        finally:
            gps_module.time.monotonic = original_monotonic

    def test_read_nmea_lines_rejects_overlong_unterminated_fragment(self):
        class LongFragmentStream:
            def read(self, size=-1):
                return b"A"

        with self.assertRaisesRegex(ValueError, "NMEA sentence exceeded 4 bytes without a line ending"):
            next(read_nmea_lines(LongFragmentStream(), max_line_bytes=4))

    def test_cli_deadline_nmea_reader_rejects_overlong_unterminated_fragment(self):
        original_limit = cli_module.NMEA_MAX_LINE_BYTES
        original_monotonic = cli_module.time.monotonic

        class LongFragmentStream:
            def read(self, size=-1):
                return b"A"

        try:
            cli_module.NMEA_MAX_LINE_BYTES = 4
            cli_module.time.monotonic = lambda: 0.0
            with self.assertRaisesRegex(ValueError, "NMEA sentence exceeded 4 bytes without a line ending"):
                next(cli_module._read_nmea_lines_until(LongFragmentStream(), deadline=10.0))
        finally:
            cli_module.NMEA_MAX_LINE_BYTES = original_limit
            cli_module.time.monotonic = original_monotonic

    def test_iter_gpsd_fixes_stops_after_max_duration_without_fixes(self):
        original_socket = gps_module.socket.create_connection
        original_monotonic = gps_module.time.monotonic

        class FakeHandle:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def readline(self, size=-1):
                return '{"class":"TPV","mode":1}\n'

        class FakeSocket:
            def __init__(self):
                self.timeouts = []

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return FakeHandle()

            def settimeout(self, timeout):
                self.timeouts.append(timeout)

        fake_socket = FakeSocket()

        def fake_monotonic():
            fake_monotonic.value += 0.06
            return fake_monotonic.value

        fake_monotonic.value = -0.06

        try:
            gps_module.socket.create_connection = lambda address, timeout=10.0: fake_socket
            gps_module.time.monotonic = fake_monotonic
            fixes = list(iter_gpsd_fixes(timeout=1, max_duration=0.1))
        finally:
            gps_module.socket.create_connection = original_socket
            gps_module.time.monotonic = original_monotonic

        self.assertEqual(fixes, [])
        self.assertTrue(fake_socket.timeouts)
        self.assertLessEqual(max(fake_socket.timeouts), 0.1)

    def test_check_gps_sample(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentence, encoding="ascii")
            result = check_gps_sample(path)
            self.assertTrue(result.ok)
            self.assertIn("48.117300", result.detail)
            self.assertEqual(result.data["satellites"], 8)
            self.assertEqual(result.data["hdop"], 0.9)
            self.assertEqual(result.data["altitude_m"], 545.4)

    def test_check_gps_sample_rejects_weak_fix_quality(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,03,0.9,545.4,M,46.9,M,,\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentence, encoding="ascii")
            result = check_gps_sample(path)
            self.assertFalse(result.ok)
            self.assertIn("weak GPS fix", result.detail)

    def test_check_gps_sample_rejects_missing_quality_fields(self):
        sentence = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,290626,,,A\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentence, encoding="ascii")
            result = check_gps_sample(path)
            self.assertFalse(result.ok)
            self.assertIn("missing satellite or HDOP quality fields", result.detail)

    def test_check_gps_sample_accepts_rmc_with_gsa_quality(self):
        fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
        fix_date = datetime.now(timezone.utc).strftime("%d%m%y")
        sentences = (
            f"$GPRMC,{fix_time},A,4807.038,N,01131.000,E,022.4,084.4,{fix_date},,,A\n"
            "$GPGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5\n"
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentences, encoding="ascii")
            result = check_gps_sample(path)
            self.assertTrue(result.ok)
            self.assertIn("4 satellites", result.detail)
            self.assertIn("HDOP 0.9", result.detail)

    def test_check_gps_sample_rejects_null_island_fix(self):
        sentence = "$GPGGA,123519,0000.000,N,00000.000,E,1,08,0.9,545.4,M,46.9,M,,\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentence, encoding="ascii")
            result = check_gps_sample(path)
            self.assertFalse(result.ok)
            self.assertIn("0.000000, 0.000000", result.detail)

    def test_check_gps_sample_rejects_symlinked_sample(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "real-sample.nmea"
            target.write_text(sentence, encoding="ascii")
            sample = root / "sample.nmea"
            try:
                sample.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_gps_sample(sample)

            self.assertFalse(result.ok)
            self.assertIn("GPS sample path is a symlink", result.detail)

    def test_check_gps_sample_rejects_writable_sample(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            sample = Path(tmpdir) / "sample.nmea"
            sample.write_text(sentence, encoding="ascii")
            sample.chmod(0o666)

            result = check_gps_sample(sample)

            self.assertFalse(result.ok)
            self.assertIn("has permissions 0666", result.detail)

    def test_check_gps_sample_rejects_replaced_sample_before_parsing(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n"
        original_open = health_module.os.open
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                sample = root / "sample.nmea"
                sample.write_text(sentence, encoding="ascii")
                replacement = root / "replacement.nmea"
                replacement.write_text(sentence, encoding="ascii")
                replaced = False

                def replacing_open(path, flags, *args, **kwargs):
                    nonlocal replaced
                    if Path(path) == sample and not replaced:
                        replacement.replace(sample)
                        replaced = True
                    return original_open(path, flags, *args, **kwargs)

                health_module.os.open = replacing_open
                result = check_gps_sample(sample)
        finally:
            health_module.os.open = original_open

        self.assertFalse(result.ok)
        self.assertIn("GPS sample path changed before it could be read", result.detail)

    def test_cli_sample_reader_rejects_symlinked_sample(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "real-sample.nmea"
            target.write_text(sentence, encoding="ascii")
            sample = root / "sample.nmea"
            try:
                sample.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "GPS sample path is a symlink"):
                list(cli_module._read_fixes("", 4800, str(sample)))

    def test_check_gps_device_uses_configured_baud(self):
        captured = {}
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            captured["device"] = device
            captured["baud"] = baud
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertTrue(result.ok)
        self.assertEqual(captured, {"device": "/dev/serial/by-id/mock-gps", "baud": 9600})

    def test_check_gps_device_rejects_volatile_path_before_opening(self):
        original = health_module.open_nmea_stream

        def unexpected_open_nmea_stream(device, baud=4800):
            raise AssertionError("check_gps_device should reject volatile GPS device path before opening it")

        try:
            health_module.open_nmea_stream = unexpected_open_nmea_stream
            with tempfile.TemporaryDirectory() as tmpdir:
                device = Path(tmpdir) / "ttyACM0"
                device.write_text("", encoding="ascii")
                result = check_gps_device(str(device), baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("not checked because", result.detail)
        self.assertIn("not stable", result.detail)

    def test_check_gps_device_rejects_low_satellite_count(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},4807.038,N,01131.000,E,1,03,0.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("navigation-quality", result.detail)
        self.assertIn("weak GPS fix", result.detail)

    def test_check_gps_device_rejects_high_hdop(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},4807.038,N,01131.000,E,1,08,9.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("HDOP", result.detail)

    def test_check_gps_device_rejects_missing_quality_fields(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            fix_date = datetime.now(timezone.utc).strftime("%d%m%y")
            return BytesIO(
                f"$GPRMC,{fix_time},A,4807.038,N,01131.000,E,022.4,084.4,{fix_date},,,A\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("missing satellite or HDOP quality fields", result.detail)

    def test_check_gps_device_accepts_rmc_with_gsa_quality(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            fix_date = datetime.now(timezone.utc).strftime("%d%m%y")
            return BytesIO(
                (
                    f"$GPRMC,{fix_time},A,4807.038,N,01131.000,E,022.4,084.4,{fix_date},,,A\n"
                    "$GPGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5\n"
                ).encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertTrue(result.ok)
        self.assertIn("4 satellites", result.detail)
        self.assertIn("HDOP 0.9", result.detail)
        self.assertIn("speed 22.4 kt", result.detail)
        self.assertIn("course 84.4 deg", result.detail)
        self.assertEqual(result.data["speed_knots"], 22.4)
        self.assertEqual(result.data["course_degrees"], 84.4)

    def test_check_gps_device_rejects_overlong_unterminated_nmea_fragment(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            return BytesIO(b"A" * (health_module.NMEA_MAX_LINE_BYTES + 1))

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("NMEA sentence exceeded", result.detail)

    def test_check_gps_device_rejects_null_island_fix(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},0000.000,N,00000.000,E,1,08,0.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("0.000000, 0.000000", result.detail)

    def test_check_gps_device_rejects_out_of_range_coordinates(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},9100.000,N,18100.000,E,1,08,0.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("no fresh navigation-quality NMEA fix", result.detail)

    def test_check_gps_device_rejects_stale_timestamped_fix(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            return BytesIO(b"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W\n")

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("stale", result.detail)

    def test_check_gps_device_rejects_untimestamped_fix(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            return BytesIO(b"$GPGGA,,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,\n")

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("no timestamp", result.detail)

    def test_check_gpsd_rejects_stale_timestamped_fix(self):
        original = health_module.iter_gpsd_fixes
        stale = GPSFix(
            timestamp=datetime(2000, 1, 1, tzinfo=timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([stale])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("stale", result.detail)

    def test_check_gpsd_rejects_future_timestamped_fix(self):
        original = health_module.iter_gpsd_fixes
        future = GPSFix(
            timestamp=datetime.now(timezone.utc) + timedelta(seconds=60),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
            satellites=8,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([future])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("future", result.detail)

    def test_check_gpsd_rejects_untimestamped_fix(self):
        original = health_module.iter_gpsd_fixes
        untimestamped = GPSFix(
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
            satellites=8,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([untimestamped])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("no timestamp", result.detail)

    def test_check_gpsd_rejects_timezone_less_fix(self):
        original = health_module.iter_gpsd_fixes
        timezone_less = GPSFix(
            timestamp=datetime.now().replace(microsecond=0),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
            satellites=8,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([timezone_less])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("fix timestamp has no timezone", result.detail)

    def test_check_gpsd_rejects_weak_fix_quality_when_reported(self):
        original = health_module.iter_gpsd_fixes
        weak = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
            satellites=3,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([weak])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("weak GPS fix", result.detail)

    def test_check_gpsd_rejects_null_island_fix(self):
        original = health_module.iter_gpsd_fixes
        invalid = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=0.0,
            longitude=0.0,
            fix_quality=3,
            satellites=8,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([invalid])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("0.000000, 0.000000", result.detail)

    def test_check_gpsd_rejects_out_of_range_coordinates(self):
        original = health_module.iter_gpsd_fixes
        invalid = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=181.0,
            fix_quality=3,
            satellites=8,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([invalid])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("longitude 181.000000 outside -180..180", result.detail)

    def test_check_gpsd_waits_for_quality_after_initial_position(self):
        original = health_module.iter_gpsd_fixes
        position_only = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )
        weak = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
            satellites=3,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([position_only, weak])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("weak GPS fix", result.detail)

    def test_check_gpsd_accepts_later_quality_fix(self):
        original = health_module.iter_gpsd_fixes
        timestamp = datetime.now(timezone.utc).replace(microsecond=0)
        position_only = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )
        good = GPSFix(
            timestamp=timestamp,
            latitude=61.1,
            longitude=-149.1,
            speed_knots=4.2,
            course_degrees=181.5,
            fix_quality=3,
            satellites=6,
            hdop=1.2,
            altitude_m=12.3,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([position_only, good])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertTrue(result.ok)
        self.assertIn("6 satellites", result.detail)
        self.assertIn("61.100000", result.detail)
        self.assertIn(f"time {timestamp.isoformat().replace('+00:00', 'Z')}", result.detail)
        self.assertIn("speed 4.2 kt", result.detail)
        self.assertIn("course 181.5 deg", result.detail)
        self.assertIn("altitude 12.3 m", result.detail)
        self.assertEqual(result.data["timestamp"], timestamp.isoformat().replace("+00:00", "Z"))
        self.assertEqual(result.data["latitude"], 61.1)
        self.assertEqual(result.data["longitude"], -149.1)
        self.assertEqual(result.data["speed_knots"], 4.2)
        self.assertEqual(result.data["course_degrees"], 181.5)
        self.assertEqual(result.data["altitude_m"], 12.3)

    def test_check_gpsd_rejects_position_only_fix_before_stream_error(self):
        original = health_module.iter_gpsd_fixes
        position_only = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )

        def fixes(**kwargs):
            yield position_only
            raise RuntimeError("stream ended")

        try:
            health_module.iter_gpsd_fixes = fixes
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("stream ended", result.detail)
        self.assertIn("missing satellite or HDOP quality fields", result.detail)

    def test_check_gpsd_rejects_position_only_fix_without_quality_fields(self):
        original = health_module.iter_gpsd_fixes
        fresh = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([fresh])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("missing satellite or HDOP quality fields", result.detail)

    def test_check_gpsd_bounds_gpsd_iterator_by_wait_seconds(self):
        original = health_module.iter_gpsd_fixes
        calls = []

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            calls.append((host, port, timeout, max_duration))
            return iter([])

        try:
            health_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            result = check_gpsd(host="127.0.0.1", port=2947, seconds=7)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0:2], ("127.0.0.1", 2947))
        self.assertGreater(calls[0][2], 0)
        self.assertLessEqual(calls[0][2], 7)
        self.assertGreater(calls[0][3], 0)
        self.assertLessEqual(calls[0][3], 7)
        self.assertFalse(result.ok)

    def test_check_gpsd_retries_initial_connection_until_bounded_wait(self):
        original_iter = health_module.iter_gpsd_fixes
        original_sleep = health_module.time.sleep
        timestamp = datetime.now(timezone.utc).replace(microsecond=0)
        fix = GPSFix(
            timestamp=timestamp,
            latitude=61.1,
            longitude=-149.1,
            fix_quality=3,
            satellites=8,
            hdop=1.2,
        )
        calls = []
        sleeps = []

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            calls.append((host, port, timeout, max_duration))
            if len(calls) == 1:
                raise OSError("connection refused")
            return iter([fix])

        try:
            health_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            health_module.time.sleep = lambda seconds: sleeps.append(seconds)
            result = check_gpsd(host="127.0.0.1", port=2947, seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original_iter
            health_module.time.sleep = original_sleep

        self.assertTrue(result.ok)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][0:2], ("127.0.0.1", 2947))
        self.assertEqual(calls[1][0:2], ("127.0.0.1", 2947))
        self.assertEqual(len(sleeps), 1)
        self.assertGreater(sleeps[0], 0.0)
        self.assertLessEqual(sleeps[0], 1.0)
        self.assertIn("8 satellites", result.detail)

    def test_check_gpsd_reports_last_connection_error_after_bounded_wait(self):
        original_iter = health_module.iter_gpsd_fixes
        original_monotonic = health_module.time.monotonic
        original_sleep = health_module.time.sleep
        times = iter([0.0, 0.0, 1.1])
        sleeps = []

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            raise OSError("connection refused")

        try:
            health_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            health_module.time.monotonic = lambda: next(times)
            health_module.time.sleep = lambda seconds: sleeps.append(seconds)
            result = check_gpsd(host="127.0.0.1", port=2947, seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original_iter
            health_module.time.monotonic = original_monotonic
            health_module.time.sleep = original_sleep

        self.assertFalse(result.ok)
        self.assertEqual(sleeps, [])
        self.assertIn("last GPSD connection error: connection refused", result.detail)

    def test_check_gps_device_path_reports_missing_device(self):
        result = check_gps_device_path("/dev/serial/by-id/no-such-gps")
        self.assertFalse(result.ok)
        self.assertIn("does not exist", result.detail)
        self.assertIsNotNone(result.data)
        self.assertEqual(result.data.get("configured_path"), "/dev/serial/by-id/no-such-gps")
        self.assertEqual(result.data.get("stable_path"), True)
        self.assertEqual(result.data.get("exists"), False)

    def test_check_gps_device_path_reports_broken_by_id_symlink(self):
        with (
            patch("noaa_navionics.health.Path.exists", return_value=False),
            patch("noaa_navionics.health.Path.is_symlink", return_value=True),
            patch("noaa_navionics.health.Path.resolve", return_value=Path("/dev/ttyACM0")),
        ):
            result = check_gps_device_path("/dev/serial/by-id/usb-gps")

            self.assertFalse(result.ok)
            self.assertIn("broken by-id symlink", result.detail)
            self.assertIn("/dev/ttyACM0", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("is_symlink"), True)
            self.assertEqual(result.data.get("exists"), False)
            self.assertEqual(result.data.get("resolved_path"), "/dev/ttyACM0")

    def test_check_gps_device_path_accepts_stable_symlink(self):
        with (
            patch("noaa_navionics.health.Path.exists", return_value=True),
            patch("noaa_navionics.health.Path.is_dir", return_value=False),
            patch("noaa_navionics.health.Path.is_symlink", return_value=True),
            patch("noaa_navionics.health.Path.is_char_device", return_value=True),
            patch("noaa_navionics.health.Path.resolve", return_value=Path("/dev/ttyACM0")),
        ):
            stable = "/dev/serial/by-id/usb-gps"
            result = check_gps_device_path(str(stable))

            self.assertTrue(result.ok)
            self.assertIn("usb-gps", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("configured_path"), stable)
            self.assertEqual(result.data.get("stable_path"), True)
            self.assertEqual(result.data.get("is_by_id_path"), True)
            self.assertEqual(result.data.get("is_symlink"), True)
            self.assertEqual(result.data.get("is_character_device"), True)
            self.assertEqual(result.data.get("resolved_path"), "/dev/ttyACM0")

    def test_check_gps_device_path_rejects_by_id_character_node_without_symlink(self):
        with (
            patch("noaa_navionics.health.Path.exists", return_value=True),
            patch("noaa_navionics.health.Path.is_dir", return_value=False),
            patch("noaa_navionics.health.Path.is_symlink", return_value=False),
            patch("noaa_navionics.health.Path.is_char_device", return_value=True),
            patch("noaa_navionics.health.Path.resolve", return_value=Path("/dev/ttyACM0")),
        ):
            result = check_gps_device_path("/dev/serial/by-id/usb-gps")

            self.assertFalse(result.ok)
            self.assertIn("udev by-id symlink", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("is_symlink"), False)

    def test_check_gps_device_path_rejects_non_character_stable_path(self):
        with (
            patch("noaa_navionics.health.Path.exists", return_value=True),
            patch("noaa_navionics.health.Path.is_dir", return_value=False),
            patch("noaa_navionics.health.Path.is_symlink", return_value=True),
            patch("noaa_navionics.health.Path.is_char_device", return_value=False),
            patch("noaa_navionics.health.Path.resolve", return_value=Path("/tmp/not-a-device")),
        ):
            result = check_gps_device_path("/dev/serial/by-id/usb-gps")

            self.assertFalse(result.ok)
            self.assertIn("character device", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("is_character_device"), False)

    def test_check_gps_device_path_rejects_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = check_gps_device_path(tmpdir)

            self.assertFalse(result.ok)
            self.assertIn("directory", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("is_directory"), True)

    def test_stable_gps_device_path_rejects_bare_by_id_directory(self):
        self.assertFalse(health_module._stable_gps_device_path("/dev/serial/by-id/"))

    def test_stable_gps_device_path_rejects_nested_by_id_path(self):
        self.assertFalse(health_module._stable_gps_device_path("/dev/serial/by-id/mock/extra"))
        self.assertFalse(health_module._stable_gps_device_path("/dev/serial/by-id/../ttyS0"))

    def test_stable_gps_device_path_rejects_shell_metacharacters(self):
        self.assertFalse(health_module._stable_gps_device_path("/dev/serial/by-id/$(id)"))
        self.assertFalse(config_module._stable_gps_device_path("/dev/serial/by-id/$(id)"))

    def test_check_gps_device_path_rejects_unsafe_by_id_name_before_existence(self):
        result = check_gps_device_path("/dev/serial/by-id/$(id)")

        self.assertFalse(result.ok)
        self.assertIn("safe /dev/serial/by-id", result.detail)
        self.assertIsNotNone(result.data)
        self.assertEqual(result.data.get("stable_path"), False)

    def test_check_gps_device_path_rejects_volatile_usb_name(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            device = Path(tmpdir) / "ttyUSB0"
            device.write_text("", encoding="ascii")

            result = check_gps_device_path(str(device))

            self.assertFalse(result.ok)
            self.assertIn("not stable", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("volatile_path"), True)

    def test_check_gps_device_path_rejects_unrecognized_existing_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            device = Path(tmpdir) / "ttyS0"
            device.write_text("", encoding="ascii")

            result = check_gps_device_path(str(device))

            self.assertFalse(result.ok)
            self.assertIn("recognized stable", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("stable_path"), False)

    def test_check_gpsd_startup_config_accepts_expected_device(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/mock-gps"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertTrue(result.ok)
            self.assertIn("immediate polling", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("path"), str(config))
            self.assertEqual(result.data.get("expected_device"), "/dev/serial/by-id/mock-gps")
            self.assertEqual(result.data.get("devices"), ["/dev/serial/by-id/mock-gps"])
            self.assertEqual(result.data.get("gpsd_options"), ["-n"])
            self.assertEqual(result.data.get("start_daemon"), "true")
            self.assertEqual(result.data.get("usbauto"), "false")
            self.assertEqual(result.data.get("immediate_polling"), True)

    def test_check_gpsd_startup_config_rejects_symlinked_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config = root / "gpsd.real"
            real_config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/mock-gps"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )
            config = root / "gpsd"
            try:
                config.symlink_to(real_config)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("GPSD config path is a symlink", result.detail)
            self.assertIn(str(config), result.detail)

    def test_check_gpsd_startup_config_rejects_symlinked_config_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_root = root / "real-root"
            config_dir = real_root / "default"
            config_dir.mkdir(parents=True)
            config = config_dir / "gpsd"
            config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/mock-gps"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )
            link_root = root / "link-root"
            try:
                link_root.symlink_to(real_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_gpsd_startup_config(
                "/dev/serial/by-id/mock-gps",
                config_path=link_root / "default" / "gpsd",
            )

            self.assertFalse(result.ok)
            self.assertIn("GPSD config directory is a symlink", result.detail)
            self.assertIn(str(link_root), result.detail)

    def test_check_gpsd_startup_config_rejects_nonregular_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.mkdir()

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("GPSD config path is not a regular file", result.detail)

    def test_check_gpsd_startup_config_rejects_writable_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/mock-gps"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )
            config.chmod(0o666)

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("GPSD config", result.detail)
            self.assertIn("has permissions 0666", result.detail)

    def test_check_gpsd_startup_config_rejects_replaced_config_before_parsing(self):
        original_open = health_module.os.open
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                config = root / "gpsd"
                config.write_text(
                    'START_DAEMON="true"\n'
                    'USBAUTO="false"\n'
                    'DEVICES="/dev/serial/by-id/mock-gps"\n'
                    'GPSD_OPTIONS="-n"\n',
                    encoding="utf-8",
                )
                replacement = root / "gpsd.replacement"
                replacement.write_text(
                    'START_DAEMON="true"\n'
                    'USBAUTO="false"\n'
                    'DEVICES="/dev/serial/by-id/mock-gps"\n'
                    'GPSD_OPTIONS="-n"\n',
                    encoding="utf-8",
                )
                replaced = False

                def replacing_open(path, flags, *args, **kwargs):
                    nonlocal replaced
                    if Path(path) == config and not replaced:
                        replacement.replace(config)
                        replaced = True
                    return original_open(path, flags, *args, **kwargs)

                health_module.os.open = replacing_open
                result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)
        finally:
            health_module.os.open = original_open

        self.assertFalse(result.ok)
        self.assertIn("GPSD config changed before it could be read", result.detail)

    def test_check_gpsd_startup_config_rejects_unsafe_expected_device(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/$(id)"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )

            result = check_gpsd_startup_config("/dev/serial/by-id/$(id)", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("safe stable path", result.detail)

    def test_check_gpsd_startup_config_rejects_mismatch_and_missing_polling(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.write_text(
                'START_DAEMON="false"\n'
                'USBAUTO="true"\n'
                'DEVICES="/dev/serial/by-id/other-gps"\n'
                'GPSD_OPTIONS=""\n',
                encoding="utf-8",
            )

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("START_DAEMON", result.detail)
            self.assertIn("USBAUTO", result.detail)
            self.assertIn("does not include -n", result.detail)
            self.assertIn("/dev/serial/by-id/mock-gps", result.detail)

    def test_check_gpsd_startup_config_rejects_extra_devices(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/mock-gps /dev/serial/by-id/old-gps"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("must contain exactly", result.detail)
            self.assertIn("/dev/serial/by-id/old-gps", result.detail)

    def test_chart_check_requires_extracted_cells(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / "AK_ENCs.zip").write_bytes(b"not a real zip")
            zip_result = check_chart_dir(root)
            self.assertFalse(zip_result.ok)
            cell = root / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("", encoding="ascii")
            extracted_result = check_chart_dir(root)
            self.assertTrue(extracted_result.ok)
            data = extracted_result.data or {}
            self.assertEqual(data["configured_path"], str(root))
            self.assertTrue(data["has_extracted_enc_cells"])
            self.assertEqual(data["enc_cell_samples"], [str(cell)])

    def test_chart_check_ignores_symlinked_enc_cells(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "outside.000"
            target.write_text("not a trusted chart cell", encoding="ascii")
            charts = root / "charts"
            cell = charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            try:
                cell.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_dir(charts)

            self.assertFalse(result.ok)
            self.assertIn("no ENC .000 cells", result.detail)

    def test_chart_check_rejects_symlinked_chart_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_charts = root / "real-charts"
            cell = real_charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("", encoding="ascii")
            chart_link = root / "charts"
            try:
                chart_link.symlink_to(real_charts, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_dir(chart_link)

            self.assertFalse(result.ok)
            self.assertIn("chart directory is a symlink", result.detail)

    def test_chart_check_rejects_symlinked_chart_directory_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_storage = root / "real-storage"
            charts = real_storage / "charts"
            cell = charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("", encoding="ascii")
            storage_link = root / "storage-link"
            try:
                storage_link.symlink_to(real_storage, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_dir(storage_link / "charts")

            self.assertFalse(result.ok)
            self.assertIn("chart directory path contains a symlink", result.detail)
            self.assertIn("storage-link", result.detail)

    def test_disk_check_requires_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "charts"
            path.write_text("not a directory", encoding="ascii")
            result = check_disk_space(path)
            self.assertFalse(result.ok)
            self.assertIn("not a directory", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("configured_path"), str(path))
            self.assertEqual(result.data.get("is_directory"), False)

    def test_disk_check_rejects_symlinked_storage_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "real-charts"
            target.mkdir()
            link = root / "charts"
            link.symlink_to(target, target_is_directory=True)

            result = check_disk_space(link)

            self.assertFalse(result.ok)
            self.assertIn("is a symlink", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("storage_symlink_component"), str(link))

    def test_disk_check_rejects_storage_under_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target_parent = root / "real-storage"
            charts = target_parent / "charts"
            charts.mkdir(parents=True)
            link_parent = root / "storage-link"
            try:
                link_parent.symlink_to(target_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_disk_space(link_parent / "charts")

            self.assertFalse(result.ok)
            self.assertIn("storage-link", result.detail)
            self.assertIn("is a symlink", result.detail)

    def test_disk_check_rejects_missing_parent_storage(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "missing-mount" / "charts"
            result = check_disk_space(path)
            self.assertFalse(result.ok)
            self.assertIn("does not exist", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("exists"), False)
            self.assertEqual(result.data.get("checked_path"), str(path.parent))

    def test_disk_check_reports_unwritable_directory(self):
        original = health_module._directory_writable
        try:
            health_module._directory_writable = lambda path: False
            with tempfile.TemporaryDirectory() as tmpdir:
                result = check_disk_space(Path(tmpdir))
            self.assertFalse(result.ok)
            self.assertIn("not writable", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("writable"), False)
        finally:
            health_module._directory_writable = original

    def test_disk_check_rejects_public_storage_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            os.chmod(charts, 0o777)
            try:
                result = check_disk_space(charts)
            finally:
                os.chmod(charts, 0o700)

            self.assertFalse(result.ok)
            self.assertIn("expected no group/other write bits", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("mode"), "0777")

    def test_disk_check_uses_configured_free_space_floor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            usage = shutil.disk_usage(tmpdir)
            min_free_gb = (usage.free / (1024 ** 3)) + 1.0

            result = check_disk_space(Path(tmpdir), min_free_gb=min_free_gb)

            self.assertFalse(result.ok)
            self.assertIn("minimum", result.detail)
            self.assertIsNotNone(result.data)
            self.assertLess(result.data.get("free_gb"), result.data.get("min_free_gb"))

    def test_disk_check_rejects_unmounted_removable_storage_path(self):
        original_roots = health_module.REMOVABLE_STORAGE_ROOTS
        original_ismount = health_module.os.path.ismount
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                removable_root = Path(tmpdir) / "mnt"
                charts = removable_root / "usb" / "charts"
                charts.mkdir(parents=True)
                health_module.REMOVABLE_STORAGE_ROOTS = (removable_root,)
                health_module.os.path.ismount = lambda path: False

                result = check_disk_space(charts)

            self.assertFalse(result.ok)
            self.assertIn("no mounted storage device", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("missing_removable_mount"), True)
        finally:
            health_module.REMOVABLE_STORAGE_ROOTS = original_roots
            health_module.os.path.ismount = original_ismount

    def test_disk_check_accepts_mounted_removable_storage_parent(self):
        original_roots = health_module.REMOVABLE_STORAGE_ROOTS
        original_ismount = health_module.os.path.ismount
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                removable_root = Path(tmpdir) / "mnt"
                mount_point = removable_root / "usb"
                charts = mount_point / "charts"
                charts.mkdir(parents=True)
                health_module.REMOVABLE_STORAGE_ROOTS = (removable_root,)
                health_module.os.path.ismount = lambda path: Path(path) == mount_point

                result = check_disk_space(charts)

            self.assertTrue(result.ok)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("configured_path"), str(charts))
            self.assertEqual(result.data.get("storage_symlink_component"), "")
            self.assertEqual(result.data.get("missing_removable_mount"), False)
            self.assertEqual(result.data.get("writable"), True)
        finally:
            health_module.REMOVABLE_STORAGE_ROOTS = original_roots
            health_module.os.path.ismount = original_ismount

    def test_preflight_checks_separate_track_storage(self):
        original = health_module._directory_writable
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                chart_dir = root / "charts"
                extract = chart_dir / "AK_ENCs"
                cell = extract / "US5AK3CM" / "US5AK3CM.000"
                cell.parent.mkdir(parents=True)
                cell.write_text("cell", encoding="ascii")
                now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
                (chart_dir / MANIFEST_NAME).write_text(
                    '{"created_at":"' + now + '",'
                    '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                    '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                    '"download":{"path":"","url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip","bytes":0,"sha256":""},'
                    f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                    encoding="utf-8",
                )
                sample = root / "sample.nmea"
                sample.write_text(
                    "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n",
                    encoding="ascii",
                )
                track_parent = root / "track-storage"
                track_parent.mkdir()
                track_output = track_parent / "tracks"
                health_module._directory_writable = lambda path: Path(path) != track_parent

                results = health_module.run_preflight(
                    chart_dir=chart_dir,
                    chart_package="state",
                    chart_value="AK",
                    gps_sample=sample,
                    track_output=track_output,
                )

            track_check = next(check for check in results if check.name == "Track Disk")
            self.assertFalse(track_check.ok)
            self.assertIn("not writable", track_check.detail)
        finally:
            health_module._directory_writable = original

    def test_preflight_rejects_missing_separate_track_storage_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            chart_dir = root / "charts"
            extract = chart_dir / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (chart_dir / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"path":"","url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip","bytes":0,"sha256":""},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            sample = root / "sample.nmea"
            sample.write_text(
                "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n",
                encoding="ascii",
            )
            track_output = root / "missing-mount" / "tracks"

            results = health_module.run_preflight(
                chart_dir=chart_dir,
                chart_package="state",
                chart_value="AK",
                gps_sample=sample,
                track_output=track_output,
            )

        track_check = next(check for check in results if check.name == "Track Disk")
        self.assertFalse(track_check.ok)
        self.assertIn("does not exist", track_check.detail)

    def test_preflight_rejects_volatile_direct_serial_device_before_opening(self):
        original_open = health_module.open_nmea_stream

        def unexpected_open_nmea_stream(device, baud=4800):
            raise AssertionError("preflight should reject volatile GPS device path before opening it")

        try:
            health_module.open_nmea_stream = unexpected_open_nmea_stream
            with tempfile.TemporaryDirectory() as tmpdir:
                device = Path(tmpdir) / "ttyUSB0"
                device.write_text("", encoding="ascii")

                results = health_module.run_preflight(
                    chart_dir=Path(tmpdir) / "charts",
                    gps_device=str(device),
                    gps_seconds=0,
                )
        finally:
            health_module.open_nmea_stream = original_open

        device_check = next(check for check in results if check.name == "GPS Device")
        gps_check = next(check for check in results if check.name == "GPS")
        self.assertFalse(device_check.ok)
        self.assertIn("not stable", device_check.detail)
        self.assertFalse(gps_check.ok)
        self.assertIn("not checked because", gps_check.detail)
        self.assertIn("noaa-navionics list-gps-devices", gps_check.detail)

    def test_preflight_missing_gps_points_to_device_discovery(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            results = health_module.run_preflight(
                chart_dir=Path(tmpdir) / "charts",
                gps_seconds=0,
            )

        gps_check = next(check for check in results if check.name == "GPS")
        self.assertFalse(gps_check.ok)
        self.assertIn("--gps-device /dev/serial/by-id/YOUR_GPS_DEVICE", gps_check.detail)
        self.assertIn("noaa-navionics list-gps-devices", gps_check.detail)


class PiHealthTests(unittest.TestCase):
    def test_raspberry_pi_model_reader_accepts_model_text(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            model = Path(tmpdir) / "model"
            model.write_bytes(b"Raspberry Pi 4 Model B Rev 1.5\x00")

            self.assertEqual(
                health_module._read_raspberry_pi_model_text(model),
                "Raspberry Pi 4 Model B Rev 1.5",
            )

    def test_raspberry_pi_model_reader_rejects_empty_model(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            model = Path(tmpdir) / "model"
            model.write_bytes(b"\x00")

            with self.assertRaisesRegex(RuntimeError, "Raspberry Pi model path is empty"):
                health_module._read_raspberry_pi_model_text(model)

    def test_raspberry_pi_model_reader_rejects_symlinked_model(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            real_model = root / "real-model"
            real_model.write_text("Raspberry Pi 4\n", encoding="ascii")
            model = root / "model"
            try:
                model.symlink_to(real_model)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "Raspberry Pi model path is a symlink"):
                health_module._read_raspberry_pi_model_text(model)

    def test_raspberry_pi_model_reader_rejects_replaced_model_before_reading(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            model = root / "model"
            model.write_text("Raspberry Pi 4\n", encoding="ascii")
            replacement = root / "replacement-model"
            replacement.write_text("Raspberry Pi 5\n", encoding="ascii")
            original_open = health_module.os.open

            def replacing_open(path, flags, mode=0o777, *, dir_fd=None):
                if Path(path) == model:
                    os.replace(replacement, model)
                if dir_fd is None:
                    return original_open(path, flags, mode)
                return original_open(path, flags, mode, dir_fd=dir_fd)

            try:
                health_module.os.open = replacing_open
                with self.assertRaisesRegex(RuntimeError, "Raspberry Pi model path changed before it could be read"):
                    health_module._read_raspberry_pi_model_text(model)
            finally:
                health_module.os.open = original_open

    def test_check_python_records_structured_runtime(self):
        result = check_python()

        self.assertTrue(result.ok)
        data = result.data or {}
        self.assertEqual(data["version_info"][:2], [sys.version_info.major, sys.version_info.minor])
        self.assertEqual(data["min_version"], [3, 9])
        self.assertTrue(Path(str(data["executable"])).is_absolute())

    def test_check_tkinter_records_structured_availability(self):
        result = check_tkinter()

        data = result.data or {}
        self.assertEqual(data["module"], "tkinter")
        self.assertEqual(data["available"], result.ok)
        if result.ok:
            self.assertEqual(result.detail, "available")

    def test_check_source_revision_skips_non_pi(self):
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._is_raspberry_pi = lambda: False
            result = check_source_revision()
        finally:
            health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("skipping", result.detail)
        self.assertEqual(result.data, {"is_raspberry_pi": False, "skipped": True})

    def test_check_source_revision_accepts_recorded_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertEqual(result.detail, "abc123")
            data = result.data or {}
            self.assertTrue(data["is_raspberry_pi"])
            self.assertEqual(data["path"], str(revision))
            self.assertTrue(data["exists"])
            self.assertFalse(data["is_symlink"])
            self.assertEqual(data["directory_symlink_component"], "")
            self.assertTrue(data["is_regular"])
            self.assertEqual(data["uid"], os.getuid())
            self.assertEqual(data["expected_uid"], os.getuid())
            self.assertEqual(data["revision"], "abc123")

    def test_check_source_revision_rejects_dirty_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123-dirty\n", encoding="utf-8")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("dirty deployed source revision", result.detail)
            data = result.data or {}
            self.assertEqual(data["revision"], "abc123-dirty")

    def test_check_source_revision_rejects_missing_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "missing"
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("cannot read deployed source revision", result.detail)

    def test_check_source_revision_rejects_symlinked_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_revision = root / "real-source-revision"
            real_revision.write_text("abc123\n", encoding="utf-8")
            revision = root / "source-revision"
            try:
                revision.symlink_to(real_revision)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("deployed source revision path is a symlink", result.detail)

    def test_check_source_revision_rejects_symlinked_revision_directory_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_dir = root / "real-source"
            real_dir.mkdir()
            real_revision = real_dir / "source-revision"
            real_revision.write_text("abc123\n", encoding="utf-8")
            link_dir = root / "source-link"
            try:
                link_dir.symlink_to(real_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            revision = link_dir / "source-revision"
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("deployed source revision directory is a symlink", result.detail)

    def test_check_source_revision_rejects_symlinked_revision_ancestor_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_root = root / "real-install"
            real_dir = real_root / "noaa-navionics"
            real_dir.mkdir(parents=True)
            real_revision = real_dir / "source-revision"
            real_revision.write_text("abc123\n", encoding="utf-8")
            link_root = root / "install-link"
            try:
                link_root.symlink_to(real_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            revision = link_root / "noaa-navionics" / "source-revision"
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("deployed source revision directory is a symlink", result.detail)
            self.assertIn(str(link_root), result.detail)

    def test_check_source_revision_rejects_nonregular_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.mkdir()
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("not a regular file", result.detail)

    def test_check_source_revision_rejects_writable_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o620)
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                revision.chmod(0o600)
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("has permissions 0620", result.detail)

    def test_check_source_revision_rejects_writable_revision_directory_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / "source-root"
            parent.mkdir()
            revision = parent / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o600)
            parent.chmod(0o777)
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                parent.chmod(0o700)
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("deployed source revision directory", result.detail)
            self.assertIn("has permissions 0777", result.detail)

    def test_health_source_revision_reader_rejects_writable_revision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o622)
            try:
                with self.assertRaisesRegex(RuntimeError, "source revision path has permissions 0622"):
                    health_module._read_source_revision_text(revision)
            finally:
                revision.chmod(0o600)

    def test_health_source_revision_reader_rejects_replaced_revision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            revision = root / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o600)
            expected_stat = revision.stat()
            replacement = root / "replacement-source-revision"
            replacement.write_text("unexpected\n", encoding="utf-8")
            replacement.chmod(0o600)
            replacement.replace(revision)

            with self.assertRaisesRegex(RuntimeError, "changed before it could be read"):
                health_module._read_source_revision_text(revision, expected_stat=expected_stat)

    def test_check_source_revision_rejects_unknown_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("unknown\n", encoding="utf-8")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("not recorded", result.detail)

    def test_check_system_clock_rejects_epoch_like_time(self):
        result = check_system_clock(datetime(1970, 1, 1, tzinfo=timezone.utc))
        self.assertFalse(result.ok)
        self.assertIn("system clock", result.detail)
        self.assertEqual(result.data, {"timestamp": "1970-01-01T00:00:00+00:00", "min_year": 2024})

    def test_check_system_clock_rejects_timezone_less_current_time(self):
        result = check_system_clock(datetime(2026, 6, 29, 12, 0, 0))

        self.assertFalse(result.ok)
        self.assertIn("must include a timezone", result.detail)
        self.assertEqual(result.data, {"timestamp": None, "min_year": 2024})

    def test_check_system_clock_accepts_modern_time(self):
        result = check_system_clock(datetime(2026, 6, 29, tzinfo=timezone.utc))
        self.assertTrue(result.ok)
        self.assertEqual(result.data, {"timestamp": "2026-06-29T00:00:00+00:00", "min_year": 2024})

    def test_check_time_synchronization_skips_non_pi(self):
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._is_raspberry_pi = lambda: False
            result = check_time_synchronization()
        finally:
            health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("skipping", result.detail)
        self.assertEqual(result.data, {"is_raspberry_pi": False, "skipped": True})

    def test_check_time_synchronization_accepts_synced_pi_clock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "timedatectl"
            fake.write_text("#!/bin/sh\necho SystemClockSynchronized=yes\n", encoding="ascii")
            fake.chmod(0o755)
            original_is_pi = health_module._is_raspberry_pi
            original_trusted_command = health_module._trusted_system_command
            try:
                health_module._is_raspberry_pi = lambda: True
                health_module._trusted_system_command = lambda command, label: (fake, "") if command == "timedatectl" else original_trusted_command(command, label)
                result = check_time_synchronization()
            finally:
                health_module._is_raspberry_pi = original_is_pi
                health_module._trusted_system_command = original_trusted_command

            self.assertTrue(result.ok)
            self.assertIn("synchronized", result.detail)
            self.assertEqual(
                result.data,
                {
                    "is_raspberry_pi": True,
                    "system_clock_synchronized": "yes",
                    "ntp_synchronized": "",
                },
            )

    def test_check_time_synchronization_rejects_ntp_yes_without_system_clock_sync(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "timedatectl"
            fake.write_text(
                "#!/bin/sh\n"
                "echo SystemClockSynchronized=no\n"
                "echo NTPSynchronized=yes\n",
                encoding="ascii",
            )
            fake.chmod(0o755)
            original_is_pi = health_module._is_raspberry_pi
            original_trusted_command = health_module._trusted_system_command
            try:
                health_module._is_raspberry_pi = lambda: True
                health_module._trusted_system_command = lambda command, label: (fake, "") if command == "timedatectl" else original_trusted_command(command, label)
                result = check_time_synchronization()
            finally:
                health_module._is_raspberry_pi = original_is_pi
                health_module._trusted_system_command = original_trusted_command

            self.assertFalse(result.ok)
            self.assertIn("SystemClockSynchronized=no", result.detail)
            self.assertIn("NTPSynchronized=yes", result.detail)
            self.assertEqual(
                result.data,
                {
                    "is_raspberry_pi": True,
                    "system_clock_synchronized": "no",
                    "ntp_synchronized": "yes",
                },
            )

    def test_check_time_synchronization_accepts_system_clock_yes_over_ntp_no(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "timedatectl"
            fake.write_text(
                "#!/bin/sh\n"
                "echo SystemClockSynchronized=yes\n"
                "echo NTPSynchronized=no\n",
                encoding="ascii",
            )
            fake.chmod(0o755)
            original_is_pi = health_module._is_raspberry_pi
            original_trusted_command = health_module._trusted_system_command
            try:
                health_module._is_raspberry_pi = lambda: True
                health_module._trusted_system_command = lambda command, label: (fake, "") if command == "timedatectl" else original_trusted_command(command, label)
                result = check_time_synchronization()
            finally:
                health_module._is_raspberry_pi = original_is_pi
                health_module._trusted_system_command = original_trusted_command

            self.assertTrue(result.ok)
            self.assertIn("synchronized", result.detail)
            self.assertEqual(
                result.data,
                {
                    "is_raspberry_pi": True,
                    "system_clock_synchronized": "yes",
                    "ntp_synchronized": "no",
                },
            )

    def test_check_time_synchronization_rejects_unsynced_pi_clock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "timedatectl"
            fake.write_text("#!/bin/sh\necho SystemClockSynchronized=no\n", encoding="ascii")
            fake.chmod(0o755)
            original_is_pi = health_module._is_raspberry_pi
            original_trusted_command = health_module._trusted_system_command
            try:
                health_module._is_raspberry_pi = lambda: True
                health_module._trusted_system_command = lambda command, label: (fake, "") if command == "timedatectl" else original_trusted_command(command, label)
                result = check_time_synchronization()
            finally:
                health_module._is_raspberry_pi = original_is_pi
                health_module._trusted_system_command = original_trusted_command

            self.assertFalse(result.ok)
            self.assertIn("not synchronized", result.detail)
            self.assertEqual(
                result.data,
                {
                    "is_raspberry_pi": True,
                    "system_clock_synchronized": "no",
                    "ntp_synchronized": "",
                },
            )

    def test_check_time_synchronization_reports_missing_timedatectl_on_pi(self):
        original_path = os.environ.get("PATH", "")
        original_is_pi = health_module._is_raspberry_pi
        try:
            os.environ["PATH"] = "/nonexistent"
            health_module._is_raspberry_pi = lambda: True
            result = check_time_synchronization()
        finally:
            os.environ["PATH"] = original_path
            health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("timedatectl", result.detail)

    def test_check_time_synchronization_rejects_user_owned_timedatectl_on_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "timedatectl"
            fake.write_text("#!/bin/sh\necho SystemClockSynchronized=yes\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_time_synchronization()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("Time sync command directory is not a trusted system directory", result.detail)

    def test_check_chrony_gps_time_config_skips_non_pi(self):
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._is_raspberry_pi = lambda: False
            result = check_chrony_gps_time_config()
        finally:
            health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("skipping", result.detail)

    def test_check_chrony_gps_time_config_accepts_managed_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.write_text("refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_config(config)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertIn("GPSD SHM 0", result.detail)
            self.assertIsNotNone(result.data)
            data = result.data or {}
            self.assertEqual(data["path"], str(config))
            self.assertTrue(data["managed_refclock_present"])
            self.assertEqual(data["refclock_line"], "refclock SHM 0 offset 0.5 delay 0.1 refid GPS")

    def test_check_chrony_gps_time_config_rejects_commented_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.write_text("# refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_config(config)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("uncommented NOAA Navionics GPSD SHM 0", result.detail)

    def test_check_chrony_gps_time_config_rejects_nonregular_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.mkdir()
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_config(config)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("Chrony config is not a regular file", result.detail)

    def test_check_chrony_gps_time_config_rejects_writable_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.write_text("refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
            config.chmod(0o666)
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_config(config)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("has permissions 0666", result.detail)

    def test_check_chrony_gps_time_config_rejects_replaced_config_before_parsing(self):
        original_open = health_module.os.open
        original_is_pi = health_module._is_raspberry_pi
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                config = root / "chrony.conf"
                config.write_text("refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
                replacement = root / "chrony.replacement"
                replacement.write_text("refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
                replaced = False

                def replacing_open(path, flags, *args, **kwargs):
                    nonlocal replaced
                    if Path(path) == config and not replaced:
                        replacement.replace(config)
                        replaced = True
                    return original_open(path, flags, *args, **kwargs)

                health_module.os.open = replacing_open
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_config(config)
        finally:
            health_module.os.open = original_open
            health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("Chrony config changed before it could be read", result.detail)

    def test_read_trusted_config_lines_rejects_writable_config_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.write_text("refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
            config.chmod(0o666)

            with self.assertRaisesRegex(RuntimeError, "has permissions 0666"):
                _read_trusted_config_lines(config, label="Chrony config", expected_uid=os.getuid())

    def test_read_trusted_config_lines_rejects_replaced_config_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.write_text("refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
            expected_stat = config.stat()
            replacement = Path(tmpdir) / "chrony.replacement"
            replacement.write_text("refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
            replacement.replace(config)

            with self.assertRaisesRegex(RuntimeError, "Chrony config changed before it could be read"):
                _read_trusted_config_lines(
                    config,
                    label="Chrony config",
                    expected_uid=os.getuid(),
                    expected_stat=expected_stat,
                )

    def test_check_chrony_gps_time_source_skips_non_pi(self):
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._is_raspberry_pi = lambda: False
            result = check_chrony_gps_time_source()
        finally:
            health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("skipping", result.detail)
        self.assertEqual(result.data, {"is_raspberry_pi": False, "skipped": True})

    def test_check_chrony_gps_time_source_accepts_usable_gps_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "chronyc"
            fake.write_text("#!/bin/sh\necho '#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms'\n", encoding="ascii")
            fake.chmod(0o755)
            original_is_pi = health_module._is_raspberry_pi
            original_trusted_command = health_module._trusted_system_command
            try:
                health_module._is_raspberry_pi = lambda: True
                health_module._trusted_system_command = lambda command, label: (fake, "") if command == "chronyc" else original_trusted_command(command, label)
                result = check_chrony_gps_time_source(seconds=0)
            finally:
                health_module._is_raspberry_pi = original_is_pi
                health_module._trusted_system_command = original_trusted_command

            self.assertTrue(result.ok)
            self.assertIn("GPS", result.detail)
            self.assertIsNotNone(result.data)
            data = result.data or {}
            self.assertTrue(data["chronyc_available"])
            self.assertEqual(data["gps_lines"], ["#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms"])
            self.assertEqual(data["usable_lines"], ["#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms"])
            self.assertTrue(data["selected_or_combined"])

    def test_check_chrony_gps_time_source_rejects_unusable_gps_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "chronyc"
            fake.write_text("#!/bin/sh\necho '#? GPS 0 4 0 - +0ns[ +0ns] +/- 0ns'\n", encoding="ascii")
            fake.chmod(0o755)
            original_is_pi = health_module._is_raspberry_pi
            original_trusted_command = health_module._trusted_system_command
            try:
                health_module._is_raspberry_pi = lambda: True
                health_module._trusted_system_command = lambda command, label: (fake, "") if command == "chronyc" else original_trusted_command(command, label)
                result = check_chrony_gps_time_source()
            finally:
                health_module._is_raspberry_pi = original_is_pi
                health_module._trusted_system_command = original_trusted_command

            self.assertFalse(result.ok)
            self.assertIn("not usable", result.detail)

    def test_check_chrony_gps_time_source_rejects_excluded_gps_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "chronyc"
            fake.write_text("#!/bin/sh\necho '#- GPS 0 4 377 8 +12us[ +20us] +/- 100ms'\n", encoding="ascii")
            fake.chmod(0o755)
            original_is_pi = health_module._is_raspberry_pi
            original_trusted_command = health_module._trusted_system_command
            try:
                health_module._is_raspberry_pi = lambda: True
                health_module._trusted_system_command = lambda command, label: (fake, "") if command == "chronyc" else original_trusted_command(command, label)
                result = check_chrony_gps_time_source(seconds=0)
            finally:
                health_module._is_raspberry_pi = original_is_pi
                health_module._trusted_system_command = original_trusted_command

            self.assertFalse(result.ok)
            self.assertIn("not usable", result.detail)

    def test_check_chrony_gps_time_source_waits_for_later_usable_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            counter = root / "count"
            fake = bin_dir / "chronyc"
            fake.write_text(
                "#!/bin/sh\n"
                f"count_file='{counter}'\n"
                'if [ -f "$count_file" ]; then\n'
                '  IFS= read -r count <"$count_file"\n'
                "else\n"
                "  count=0\n"
                "fi\n"
                'count=$((count + 1))\n'
                'echo "$count" >"$count_file"\n'
                'if [ "$count" -lt 2 ]; then\n'
                "  echo '#? GPS 0 4 0 - +0ns[ +0ns] +/- 0ns'\n"
                "else\n"
                "  echo '#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms'\n"
                "fi\n",
                encoding="ascii",
            )
            fake.chmod(0o755)
            original_is_pi = health_module._is_raspberry_pi
            original_trusted_command = health_module._trusted_system_command
            try:
                health_module._is_raspberry_pi = lambda: True
                health_module._trusted_system_command = lambda command, label: (fake, "") if command == "chronyc" else original_trusted_command(command, label)
                result = check_chrony_gps_time_source(seconds=1, poll_interval=0.01)
            finally:
                health_module._is_raspberry_pi = original_is_pi
                health_module._trusted_system_command = original_trusted_command

            self.assertTrue(result.ok)
            self.assertEqual(counter.read_text(encoding="ascii").strip(), "2")

    def test_check_chrony_gps_time_source_reports_missing_gps_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "chronyc"
            fake.write_text("#!/bin/sh\necho '^* 192.0.2.1 2 6 377 10 +1ms[ +1ms] +/- 20ms'\n", encoding="ascii")
            fake.chmod(0o755)
            original_is_pi = health_module._is_raspberry_pi
            original_trusted_command = health_module._trusted_system_command
            try:
                health_module._is_raspberry_pi = lambda: True
                health_module._trusted_system_command = lambda command, label: (fake, "") if command == "chronyc" else original_trusted_command(command, label)
                result = check_chrony_gps_time_source(seconds=0)
            finally:
                health_module._is_raspberry_pi = original_is_pi
                health_module._trusted_system_command = original_trusted_command

            self.assertFalse(result.ok)
            self.assertIn("GPS refclock", result.detail)

    def test_check_chrony_gps_time_source_rejects_user_owned_chronyc_on_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "chronyc"
            fake.write_text("#!/bin/sh\necho '#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms'\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_source(seconds=0)
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("Chrony command directory is not a trusted system directory", result.detail)

    def test_check_display_power_tool_reports_missing_xset(self):
        original_path = os.environ.get("PATH", "")
        try:
            os.environ["PATH"] = "/nonexistent"
            result = check_display_power_tool()
        finally:
            os.environ["PATH"] = original_path
        self.assertFalse(result.ok)
        self.assertIn("x11-xserver-utils", result.detail)

    def test_check_display_power_tool_accepts_trusted_local_command_off_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "xset"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: False
                result = check_display_power_tool()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("trusted executable", result.detail)
        self.assertIsNotNone(result.data)
        self.assertEqual(result.data.get("command"), "xset")
        self.assertEqual(result.data.get("path"), str(fake))
        self.assertEqual(result.data.get("directory"), str(bin_dir))
        self.assertEqual(result.data.get("is_symlink"), False)
        self.assertEqual(result.data.get("is_regular"), True)
        self.assertEqual(result.data.get("executable"), True)

    def test_check_display_power_tool_rejects_user_owned_xset_on_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "xset"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_display_power_tool()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("Display Power command directory is not a trusted system directory", result.detail)

    def test_check_opencpn_accepts_trusted_local_command(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "opencpn"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: False
                result = check_opencpn()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertIn("trusted executable", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("command"), "opencpn")
            self.assertEqual(result.data.get("path"), str(fake))
            self.assertEqual(result.data.get("directory"), str(bin_dir))
            self.assertEqual(result.data.get("is_symlink"), False)
            self.assertEqual(result.data.get("is_regular"), True)
            self.assertEqual(result.data.get("executable"), True)

    def test_check_opencpn_rejects_symlinked_command(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            bin_dir = root / "bin"
            bin_dir.mkdir(mode=0o700)
            real = root / "real-opencpn"
            real.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            real.chmod(0o755)
            fake = bin_dir / "opencpn"
            try:
                fake.symlink_to(real)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: False
                result = check_opencpn()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("symlink", result.detail)

    def test_check_opencpn_rejects_writable_command(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "opencpn"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            fake.chmod(0o775)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: False
                result = check_opencpn()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("expected no group/other write bits", result.detail)

    def test_check_opencpn_requires_root_owner_on_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "opencpn"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_opencpn()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("expected root", result.detail)

    def test_check_opencpn_requires_root_parent_on_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "opencpn"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_opencpn()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("OpenCPN command directory is owned by uid", result.detail)
            self.assertIn("expected root", result.detail)

    def test_check_opencpn_rejects_untrusted_directory_on_pi(self):
        fake = Path("/opt/opencpn/bin/opencpn")

        class FakeStat:
            def __init__(self, mode: int, uid: int = 0):
                self.st_mode = mode
                self.st_uid = uid

        def fake_stat(path: Path, *args: object, **kwargs: object) -> FakeStat:
            if path == fake:
                return FakeStat(stat.S_IFREG | 0o755)
            if path == fake.parent:
                return FakeStat(stat.S_IFDIR | 0o755)
            raise FileNotFoundError(path)

        def fake_is_file(path: Path) -> bool:
            return path == fake

        def fake_is_symlink(path: Path) -> bool:
            return False

        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._is_raspberry_pi = lambda: True
            with patch.object(health_module.shutil, "which", return_value=str(fake)):
                with patch.object(Path, "is_file", fake_is_file):
                    with patch.object(Path, "is_symlink", fake_is_symlink):
                        with patch.object(Path, "stat", fake_stat):
                            with patch.object(os, "access", return_value=True):
                                result = check_opencpn()
        finally:
            health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("OpenCPN command directory is not a trusted system directory", result.detail)

    def test_parse_throttled_value(self):
        self.assertEqual(_parse_throttled_value("throttled=0x50000"), 0x50000)
        self.assertEqual(_parse_throttled_value("throttled=3"), 3)
        self.assertIsNone(_parse_throttled_value("not-throttled"))
        self.assertIsNone(_parse_throttled_value("other=0x0"))
        self.assertIsNone(_parse_throttled_value("throttled=0x0 warning"))
        self.assertIsNone(_parse_throttled_value("warning\nthrottled=0x0"))

    def test_check_pi_throttling_reports_active_under_voltage(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "vcgencmd"
            fake.write_text("#!/bin/sh\necho throttled=0x1\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            try:
                os.environ["PATH"] = str(bin_dir)
                result = check_pi_throttling()
            finally:
                os.environ["PATH"] = original_path
            self.assertFalse(result.ok)
            self.assertIn("under-voltage", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("throttled_value"), 1)
            self.assertEqual(result.data.get("reported_flags"), ["under-voltage"])

    def test_check_pi_throttling_rejects_historical_events(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "vcgencmd"
            fake.write_text("#!/bin/sh\necho throttled=0x50000\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            try:
                os.environ["PATH"] = str(bin_dir)
                result = check_pi_throttling()
            finally:
                os.environ["PATH"] = original_path
            self.assertFalse(result.ok)
            self.assertIn("under-voltage occurred", result.detail)
            self.assertIn("throttling occurred", result.detail)
            self.assertIsNotNone(result.data)
            self.assertEqual(result.data.get("throttled_value"), 0x50000)
            self.assertIn("under-voltage occurred", result.data.get("reported_flags", []))
            self.assertIn("throttling occurred", result.data.get("reported_flags", []))

    def test_check_pi_throttling_reports_missing_command_on_pi(self):
        original_path = os.environ.get("PATH", "")
        original_is_pi = health_module._is_raspberry_pi
        try:
            os.environ["PATH"] = "/nonexistent"
            health_module._is_raspberry_pi = lambda: True
            result = check_pi_throttling()
        finally:
            os.environ["PATH"] = original_path
            health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("vcgencmd", result.detail)
        self.assertIsNotNone(result.data)
        self.assertEqual(result.data.get("is_raspberry_pi"), True)
        self.assertEqual(result.data.get("vcgencmd_available"), False)

    def test_check_pi_throttling_rejects_user_owned_vcgencmd_on_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "vcgencmd"
            fake.write_text("#!/bin/sh\necho throttled=0x0\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_pi_throttling()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("Pi power command directory is not a trusted system directory", result.detail)
        self.assertIsNotNone(result.data)
        self.assertEqual(result.data.get("is_raspberry_pi"), True)
        self.assertEqual(result.data.get("vcgencmd_available"), False)

    def test_check_pi_temperature_reports_normal_temperature(self):
        original_reader = health_module._read_pi_temperature
        try:
            health_module._read_pi_temperature = lambda: 42.5
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader

        self.assertTrue(result.ok)
        self.assertIn("42.5 C", result.detail)
        self.assertIsNotNone(result.data)
        self.assertEqual(result.data.get("temperature_c"), 42.5)
        self.assertEqual(result.data.get("warn_c"), 70.0)
        self.assertEqual(result.data.get("fail_c"), 80.0)

    def test_check_pi_temperature_warns_when_warm(self):
        original_reader = health_module._read_pi_temperature
        try:
            health_module._read_pi_temperature = lambda: 72.0
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader

        self.assertTrue(result.ok)
        self.assertIn("warm", result.detail)
        self.assertIsNotNone(result.data)
        self.assertEqual(result.data.get("temperature_c"), 72.0)

    def test_check_pi_temperature_fails_above_limit(self):
        original_reader = health_module._read_pi_temperature
        try:
            health_module._read_pi_temperature = lambda: 81.0
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader

        self.assertFalse(result.ok)
        self.assertIn("above 80 C limit", result.detail)
        self.assertIsNotNone(result.data)
        self.assertEqual(result.data.get("temperature_c"), 81.0)

    def test_check_pi_temperature_rejects_non_finite_temperature(self):
        original_reader = health_module._read_pi_temperature
        try:
            health_module._read_pi_temperature = lambda: math.nan
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader

        self.assertFalse(result.ok)
        self.assertIn("non-finite", result.detail)
        self.assertIsNotNone(result.data)
        self.assertTrue(math.isnan(result.data.get("temperature_c")))

    def test_check_pi_temperature_reports_missing_sensor_on_pi(self):
        original_reader = health_module._read_pi_temperature
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._read_pi_temperature = lambda: None
            health_module._is_raspberry_pi = lambda: True
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader
            health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("temperature sensor unavailable", result.detail)
        self.assertIsNotNone(result.data)
        self.assertEqual(result.data.get("is_raspberry_pi"), True)
        self.assertEqual(result.data.get("temperature_available"), False)

    def test_check_pi_temperature_skips_missing_sensor_off_pi(self):
        original_reader = health_module._read_pi_temperature
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._read_pi_temperature = lambda: None
            health_module._is_raspberry_pi = lambda: False
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader
            health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("skipping", result.detail)
        self.assertIsNotNone(result.data)
        self.assertEqual(result.data.get("is_raspberry_pi"), False)
        self.assertEqual(result.data.get("temperature_available"), False)
        self.assertEqual(result.data.get("skipped"), True)

    def test_parse_vcgencmd_temperature(self):
        self.assertEqual(_parse_vcgencmd_temperature("temp=42.5'C"), 42.5)
        self.assertEqual(_parse_vcgencmd_temperature("temp=47'C"), 47.0)
        self.assertIsNone(_parse_vcgencmd_temperature("temperature unavailable"))
        self.assertIsNone(_parse_vcgencmd_temperature("temp=42.5"))
        self.assertIsNone(_parse_vcgencmd_temperature("warning temp=42.5'C"))
        self.assertIsNone(_parse_vcgencmd_temperature("temp=42.5'C warning"))

    def test_read_sysfs_pi_temperature(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            temp_file = Path(tmpdir) / "temp"
            temp_file.write_text("42500\n", encoding="ascii")

            self.assertEqual(health_module._read_sysfs_pi_temperature(temp_file), 42.5)

    def test_read_sysfs_pi_temperature_rejects_symlinked_sensor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_temp = root / "real-temp"
            temp_link = root / "temp"
            real_temp.write_text("42500\n", encoding="ascii")
            temp_link.symlink_to(real_temp)

            self.assertIsNone(health_module._read_sysfs_pi_temperature(temp_link))

    def test_read_sysfs_pi_temperature_rejects_replaced_sensor_before_reading(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            temp_file = root / "temp"
            replacement = root / "replacement"
            temp_file.write_text("42500\n", encoding="ascii")
            replacement.write_text("90000\n", encoding="ascii")
            real_os_stat = health_module.os.stat
            swapped = False

            with patch.object(health_module.os, "stat", wraps=health_module.os.stat) as stat_mock:
                def stat_with_replacement(path, *args, **kwargs):
                    nonlocal swapped
                    result = real_os_stat(path, *args, **kwargs)
                    if Path(path) == temp_file and kwargs.get("follow_symlinks") is False and not swapped:
                        swapped = True
                        temp_file.replace(root / "old-temp")
                        replacement.replace(temp_file)
                    return result

                stat_mock.side_effect = stat_with_replacement
                self.assertIsNone(health_module._read_sysfs_pi_temperature(temp_file))

            self.assertEqual(temp_file.read_text(encoding="ascii"), "90000\n")

    def test_read_sysfs_pi_temperature_rejects_non_finite_values(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            temp_file = Path(tmpdir) / "temp"

            temp_file.write_text("nan\n", encoding="ascii")
            self.assertIsNone(health_module._read_sysfs_pi_temperature(temp_file))

            temp_file.write_text("inf\n", encoding="ascii")
            self.assertIsNone(health_module._read_sysfs_pi_temperature(temp_file))

    def test_read_pi_temperature_falls_back_to_vcgencmd(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "vcgencmd"
            fake.write_text(
                "#!/bin/sh\n"
                "test \"$1\" = measure_temp || exit 2\n"
                "echo \"temp=43.7'C\"\n",
                encoding="ascii",
            )
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_sysfs_reader = health_module._read_sysfs_pi_temperature
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._read_sysfs_pi_temperature = lambda path: None
                self.assertEqual(health_module._read_pi_temperature(), 43.7)
            finally:
                os.environ["PATH"] = original_path
                health_module._read_sysfs_pi_temperature = original_sysfs_reader


if __name__ == "__main__":
    unittest.main()
