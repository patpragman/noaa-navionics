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

from .config import AppConfig, read_config
from .downloader import MANIFEST_NAME, read_manifest
from .health import CheckResult, run_preflight
from . import __version__


DEFAULT_SOURCE_REVISION_PATH = Path("~/.local/share/noaa-navionics/source-revision")


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
    )
    check_rows = [asdict(check) for check in checks]
    services = _service_summary()
    system_services = _system_service_summary()
    service_checks = _service_readiness_checks(
        services,
        system_services,
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
        },
        "app": _app_summary(),
        "config_path": str(Path(config_path).expanduser()),
        "config": _config_summary(app_config),
        "manifest": _manifest_summary(app_config.chart_output),
        "services": services,
        "system_services": system_services,
        "service_checks": [asdict(check) for check in service_checks],
        "checks": check_rows,
    }


def write_status_report(report: dict[str, object], output: Path) -> Path:
    target = Path(output).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".part")
    tmp.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(target)
    return target


def format_status_text(report: dict[str, object]) -> str:
    lines = [
        f"Generated: {report.get('generated_at', '')}",
        f"Host: {report.get('host', {}).get('name', '')}",
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
        for key in ("created_at", "package", "sha256", "enc_cell_count"):
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
    return "\n".join(lines)


def _config_summary(app_config: AppConfig) -> dict[str, object]:
    return {
        "chart_package": app_config.chart_package,
        "chart_value": app_config.chart_value,
        "chart_output": str(app_config.chart_output),
        "max_chart_age_days": app_config.max_chart_age_days,
        "gps_mode": app_config.gps_mode,
        "gps_device": app_config.gps_device,
        "gps_baud": app_config.gps_baud,
        "gpsd_host": app_config.gpsd_host,
        "gpsd_port": app_config.gpsd_port,
        "track_output": str(app_config.track_output),
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
        "package": package.get("label", "") if isinstance(package, dict) else "",
        "url": package.get("url", "") if isinstance(package, dict) else "",
        "sha256": download.get("sha256", "") if isinstance(download, dict) else "",
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
        }
    return summary


def _system_service_summary() -> dict[str, object]:
    if shutil.which("systemctl") is None:
        return {"available": False, "detail": "systemctl not found"}
    units = ["gpsd.service"]
    summary: dict[str, object] = {"available": True}
    for unit in units:
        summary[unit] = {
            "enabled": _systemctl_system(["is-enabled", unit]),
            "active": _systemctl_system(["is-active", unit]),
        }
    return summary


def _service_readiness_checks(
    services: dict[str, object],
    system_services: dict[str, object],
    *,
    gps_mode: str,
) -> list[CheckResult]:
    checks = [
        _unit_not_failed_check(
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
    if gps_mode == "gpsd":
        checks.append(
            _unit_check(
                system_services,
                "gpsd.service",
                "GPSD Service",
                require_enabled=False,
                require_active=True,
            )
        )
    return checks


def _unit_not_failed_check(summary: dict[str, object], unit: str, name: str) -> CheckResult:
    if summary.get("available") is False:
        return CheckResult(name, False, str(summary.get("detail", "systemctl not available")))
    state = summary.get(unit)
    if not isinstance(state, dict):
        return CheckResult(name, False, f"{unit} missing from status report")
    enabled = str(state.get("enabled", ""))
    active = str(state.get("active", ""))
    ok = active != "failed"
    detail = f"{unit} enabled={enabled} active={active}"
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
    enabled_ok = not require_enabled or enabled in {"enabled", "static", "generated"}
    active_ok = not require_active or active in {"active", "activating"}
    ok = enabled_ok and active_ok
    detail = f"{unit} enabled={enabled} active={active}"
    return CheckResult(name, ok, detail)


def _systemctl_user(args: list[str]) -> str:
    return _systemctl(["systemctl", "--user", *args])


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
