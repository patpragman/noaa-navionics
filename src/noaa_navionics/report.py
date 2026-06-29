from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import tempfile

from .config import AppConfig, read_config
from .downloader import MANIFEST_NAME, read_manifest
from .health import CheckResult, run_preflight
from . import __version__


DEFAULT_SOURCE_REVISION_PATH = Path("~/.local/share/noaa-navionics/source-revision")
DEFAULT_LAUNCHER_ENV_PATH = Path("~/.config/noaa-navionics/launcher.env")
BOOT_ID_PATH = Path("/proc/sys/kernel/random/boot_id")
USER_UNIT_PROPERTIES = {
    "noaa-navionics.service": [
        "ExecStart",
        "Type",
        "TimeoutStartUSec",
        "Restart",
        "RestartUSec",
        "StartLimitIntervalUSec",
        "StartLimitBurst",
        "NoNewPrivileges",
        "PrivateTmp",
    ],
    "noaa-navionics.timer": [
        "TimersCalendar",
        "Persistent",
        "RandomizedDelayUSec",
    ],
    "noaa-navionics-track.service": [
        "ExecStart",
        "Type",
        "StandardOutput",
        "Restart",
        "RestartUSec",
        "StartLimitIntervalUSec",
        "StartLimitBurst",
        "NoNewPrivileges",
        "PrivateTmp",
    ],
    "noaa-navionics-preflight.service": [
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
    service_checks = _service_readiness_checks(
        services,
        system_services,
        unit_files=unit_files,
        launcher_settings=launcher_settings,
        gps_mode=gps_mode,
    )
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
        "service_checks": [asdict(check) for check in service_checks],
        "checks": check_rows,
    }


def write_status_report(report: dict[str, object], output: Path) -> Path:
    target = Path(output).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
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
    for unit in USER_UNIT_INSTALL_TARGETS:
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
                    exact={
                        "Type": "oneshot",
                        "TimeoutStartUSec": "2h",
                        "Restart": "on-failure",
                        "RestartUSec": "30min",
                        "StartLimitIntervalUSec": "6h",
                        "StartLimitBurst": "3",
                        "NoNewPrivileges": "yes",
                        "PrivateTmp": "yes",
                    },
                    contains={
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
                    exact={"Persistent": "yes", "RandomizedDelayUSec": "30min"},
                    contains={"TimersCalendar": "OnCalendar=weekly"},
                ),
                _unit_properties_check(
                    services,
                    "noaa-navionics-track.service",
                    "Track Logger Settings",
                    exact={
                        "Type": "simple",
                        "StandardOutput": "null",
                        "Restart": "on-failure",
                        "RestartUSec": "10s",
                        "StartLimitIntervalUSec": "10min",
                        "StartLimitBurst": "60",
                        "NoNewPrivileges": "yes",
                        "PrivateTmp": "yes",
                    },
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
                    exact={
                        "Type": "oneshot",
                        "TimeoutStartUSec": "infinity",
                        "Restart": "on-failure",
                        "RestartUSec": "30s",
                        "StartLimitIntervalUSec": "30min",
                        "StartLimitBurst": "60",
                        "NoNewPrivileges": "yes",
                        "PrivateTmp": "yes",
                    },
                    contains={
                        "ExecStart": [
                            "noaa-navionics status-report",
                            "--config",
                            "noaa-navionics/config.ini",
                            "--gps-seconds",
                            "--output",
                            "noaa-navionics/status.json",
                        ],
                        "Environment": "NOAA_NAVIONICS_GPS_SECONDS=10",
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
    fail_open = str(values.get("NOAA_NAVIONICS_START_ON_FAILED_READINESS", "")).strip().lower()
    if fail_open in {"1", "yes", "true", "on"}:
        failures.append("NOAA_NAVIONICS_START_ON_FAILED_READINESS is enabled")
    elif fail_open and fail_open not in {"0", "no", "false", "off"}:
        failures.append(f"NOAA_NAVIONICS_START_ON_FAILED_READINESS={fail_open} expected yes/no")
    if failures:
        return CheckResult("Launcher Settings", False, f"{path}: " + "; ".join(failures))
    return CheckResult("Launcher Settings", True, f"{path} keeps chartplotter startup fail-closed")


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
