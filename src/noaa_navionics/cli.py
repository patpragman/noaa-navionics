from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional
import argparse
import json
import math
import os
import signal
import socket
import stat
import time
import sys

from .config import (
    DEFAULT_CONFIG_PATH,
    _stable_gps_device_path,
    _volatile_usb_device_path,
    package_kwargs,
    read_config,
    write_default_config,
)
from .downloader import (
    BASE_URL,
    CATALOG_NAME,
    download_package,
    ensure_catalog,
    package_for,
    search_catalog,
)
from .gps import (
    GPXTrackLogger,
    NMEA_MAX_LINE_BYTES,
    daily_track_path,
    default_track_path,
    first_symlink_ancestor,
    gps_fix_has_quality_fields,
    gps_fix_quality_failure,
    iter_fixes,
    iter_gpsd_fixes,
    open_nmea_stream,
    read_nmea_lines,
)
from .health import check_chart_package, check_disk_space, open_trusted_gps_sample, run_preflight
from .opencpn import configure_chart_directory, configure_gpsd_connection, opencpn_running
from .report import (
    DEFAULT_LAUNCHER_ENV_PATH,
    LAUNCHER_ENV_KEYS,
    _read_launcher_settings_lines,
    build_status_report,
    format_status_text,
    write_status_report,
)


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def _non_negative_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be 0 or greater")
    return parsed


def _positive_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a number") from exc
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than 0")
    return parsed


def _non_negative_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a number") from exc
    if not math.isfinite(parsed) or parsed < 0:
        raise argparse.ArgumentTypeError("must be 0 or greater")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="noaa-navionics",
        description="Download NOAA ENC chart ZIPs using only the Python standard library.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    download = subparsers.add_parser("download", help="download a NOAA ENC ZIP or catalog")
    _add_selector_args(download)
    download.add_argument("--output", "-o", default="~/charts/noaa-enc", help="download directory")
    download.add_argument("--extract", action="store_true", help="extract ZIP after download")
    download.add_argument("--no-keep-zip", action="store_true", help="remove ZIP after successful extraction")
    download.add_argument("--force", action="store_true", help="overwrite an existing local file")
    download.add_argument("--timeout", type=_positive_float, default=60.0, help="network timeout in seconds")
    download.add_argument("--retries", type=_positive_int, default=1, help="download attempts before failing")
    download.add_argument("--retry-delay", type=_non_negative_float, default=2.0, help="seconds between retryable failures")
    download.add_argument("--base-url", default=BASE_URL, help=argparse.SUPPRESS)

    sync = subparsers.add_parser("sync-charts", help="download the chart package from the config file")
    sync.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    sync.add_argument("--force", action="store_true", help="override config and force redownload")
    sync.add_argument("--retries", type=_positive_int, default=3, help="download attempts before failing")
    sync.add_argument("--retry-delay", type=_non_negative_float, default=10.0, help="seconds between retryable failures")

    wait_network = subparsers.add_parser("wait-network", help="wait for bounded TCP connectivity")
    wait_network.add_argument("--host", default="www.charts.noaa.gov", help="host to probe")
    wait_network.add_argument("--port", type=_positive_int, default=443, help="TCP port to probe")
    wait_network.add_argument("--seconds", type=_non_negative_float, default=300.0, help="maximum seconds to wait")
    wait_network.add_argument("--interval", type=_positive_float, default=5.0, help="seconds between probes")
    wait_network.add_argument("--timeout", type=_positive_float, default=5.0, help="per-probe TCP timeout")

    catalog = subparsers.add_parser("catalog", help="download NOAA's XML product catalog")
    catalog.add_argument("--output", "-o", default="~/charts/noaa-enc", help="download directory")
    catalog.add_argument("--force", action="store_true", help="overwrite an existing catalog")

    search = subparsers.add_parser("search-catalog", help="search NOAA's XML product catalog")
    search.add_argument("query", help="chart name, state code, region, district, or title text")
    search.add_argument("--catalog", help=f"path to {CATALOG_NAME}; downloads it if omitted")
    search.add_argument("--output", "-o", default="~/charts/noaa-enc", help="catalog cache directory")
    search.add_argument("--limit", type=int, default=20)
    search.add_argument("--force-catalog", action="store_true", help="refresh catalog before searching")

    list_packages = subparsers.add_parser("list-packages", help="print common package selectors")
    list_packages.add_argument("--base-url", default=BASE_URL, help=argparse.SUPPRESS)

    gui = subparsers.add_parser("gui", help="launch the Tkinter GUI")

    init_config = subparsers.add_parser("init-config", help="write a default onboard config file")
    init_config.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    init_config.add_argument("--force", action="store_true", help="overwrite an existing config")

    opencpn_config = subparsers.add_parser("configure-opencpn", help="configure OpenCPN charts and GPSD")
    opencpn_config.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="NOAA Navionics config file path")
    opencpn_config.add_argument("--charts", help="chart directory to add; defaults to [charts].output")
    opencpn_config.add_argument("--opencpn-config", help="OpenCPN config path; defaults to ~/.opencpn/opencpn.conf")
    opencpn_config.add_argument("--dry-run", action="store_true", help="print intended change without writing")
    opencpn_config.add_argument("--no-backup", action="store_true", help="do not back up an existing OpenCPN config")
    opencpn_config.add_argument("--no-gpsd", action="store_true", help="only configure charts, not the GPSD connection")
    opencpn_config.add_argument(
        "--allow-running",
        action="store_true",
        help="allow editing OpenCPN config while OpenCPN appears to be running",
    )

    preflight = subparsers.add_parser("preflight", help="check Pi navigation readiness")
    preflight.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    preflight.add_argument("--charts", help="chart directory; defaults to [charts].output")
    preflight.add_argument("--gpsd", action="store_true", help="check GPSD at localhost:2947")
    preflight.add_argument("--gps-device", help="NMEA serial device, e.g. /dev/serial/by-id/YOUR_GPS_DEVICE")
    preflight.add_argument("--gps-baud", type=int, help="NMEA serial baud rate")
    preflight.add_argument("--gps-sample", help="NMEA sample file for testing")
    preflight.add_argument("--gps-seconds", type=_non_negative_float, default=5.0, help="seconds to wait for a GPS fix")

    status = subparsers.add_parser("status-report", help="write an onboard readiness status report")
    status.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    status.add_argument("--gps-sample", help="NMEA sample file for testing")
    status.add_argument("--gps-seconds", type=_non_negative_float, default=5.0, help="seconds to wait for a GPS fix")
    status.add_argument(
        "--gps-seconds-from-launcher-env",
        nargs="?",
        const=str(DEFAULT_LAUNCHER_ENV_PATH),
        help="read GPS wait seconds from the trusted chartplotter launcher environment",
    )
    status.add_argument("--output", help="write JSON report to this file")
    status.add_argument("--json", action="store_true", help="print JSON instead of text")

    gps = subparsers.add_parser("gps-monitor", help="print live GPS fixes from an NMEA device")
    gps.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    gps.add_argument("--device", help="NMEA serial device")
    gps.add_argument("--baud", type=int, help="serial baud rate")
    gps.add_argument("--gpsd", action="store_true", help="read GPSD at localhost:2947")
    gps.add_argument("--sample", help="read NMEA from a text file instead of a serial device")
    gps.add_argument("--once", action="store_true", help="exit after the first valid fix")
    gps.add_argument("--seconds", type=_positive_float, help="stop after this many seconds if no fix is read")

    track = subparsers.add_parser("log-track", help="record GPS fixes to a GPX track")
    track.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    track.add_argument("--device", help="NMEA serial device")
    track.add_argument("--baud", type=int, help="serial baud rate")
    track.add_argument("--gpsd", action="store_true", help="read GPSD at localhost:2947")
    track.add_argument("--output", "-o", help="base output directory; defaults to [tracking].output")
    track.add_argument("--file", help="explicit GPX output file")
    track.add_argument("--sample", help="read NMEA from a text file instead of a serial device")
    track.add_argument("--seconds", type=_positive_float, help="stop after this many seconds")
    track.add_argument(
        "--gpsd-idle-timeout",
        type=_non_negative_float,
        default=300.0,
        help="restart live GPSD logging after this many quiet seconds; 0 disables",
    )
    track.add_argument(
        "--serial-idle-timeout",
        type=_non_negative_float,
        default=300.0,
        help="restart live serial logging after this many quiet seconds; 0 disables",
    )
    track.add_argument("--rotate-daily", action="store_true", help="write one GPX file per UTC day")
    track.add_argument(
        "--retention-days",
        type=_non_negative_int,
        help="days of rotated GPX track logs to keep; defaults to [tracking].retention_days",
    )

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "download":
            package = package_for(
                state=args.state,
                cgd=args.cgd,
                region=args.region,
                updates=args.updates,
                chart=args.chart,
                all_charts=args.all,
                catalog=args.catalog,
                base_url=args.base_url,
            )

            def progress(done: int, total: Optional[int]) -> None:
                if total:
                    pct = done / total * 100
                    print(f"\r{done:,} / {total:,} bytes ({pct:5.1f}%)", end="", flush=True)
                else:
                    print(f"\r{done:,} bytes", end="", flush=True)

            result = download_package(
                package,
                Path(args.output),
                extract=args.extract,
                keep_zip=not args.no_keep_zip,
                force=args.force,
                timeout=args.timeout,
                retries=args.retries,
                retry_delay=args.retry_delay,
                progress=progress,
            )
            print()
            if result.skipped:
                print(f"Already exists: {result.path}")
            else:
                print(f"Downloaded: {result.path}")
            if result.extracted_to:
                print(f"Extracted to: {result.extracted_to}")
            return 0

        if args.command == "catalog":
            path = ensure_catalog(Path(args.output), force=args.force)
            print(path)
            return 0

        if args.command == "sync-charts":
            app_config = read_config(Path(args.config))
            package_check = check_chart_package(app_config.chart_package, app_config.chart_value)
            if not package_check.ok:
                raise ValueError(f"sync-charts requires a complete onboard chart package: {package_check.detail}")
            disk_check = check_disk_space(app_config.chart_output, min_free_gb=app_config.min_free_gb)
            if not disk_check.ok:
                raise RuntimeError(f"sync-charts requires writable chart storage with enough free space: {disk_check.detail}")
            app_config.chart_output.mkdir(parents=True, exist_ok=True)
            disk_check = check_disk_space(app_config.chart_output, min_free_gb=app_config.min_free_gb)
            if not disk_check.ok:
                raise RuntimeError(f"sync-charts requires writable chart storage with enough free space: {disk_check.detail}")
            package = package_for(**package_kwargs(app_config))
            result = download_package(
                package,
                app_config.chart_output,
                extract=app_config.extract,
                keep_zip=app_config.keep_zip,
                force=args.force or app_config.force,
                retries=args.retries,
                retry_delay=args.retry_delay,
            )
            print(f"Downloaded: {result.path}" if not result.skipped else f"Already exists: {result.path}")
            if result.extracted_to:
                print(f"Extracted to: {result.extracted_to}")
            return 0

        if args.command == "wait-network":
            _wait_for_network(args.host, args.port, args.seconds, interval=args.interval, timeout=args.timeout)
            print(f"Network reachable: {args.host}:{args.port}")
            return 0

        if args.command == "search-catalog":
            catalog_path = Path(args.catalog).expanduser() if args.catalog else ensure_catalog(
                Path(args.output), force=args.force_catalog
            )
            matches = search_catalog(catalog_path, args.query, limit=args.limit)
            for entry in matches:
                print(f"{entry.name}\t{entry.title}\t{entry.url}")
            if not matches:
                print("No matches found.", file=sys.stderr)
                return 1
            return 0

        if args.command == "list-packages":
            rows = [
                ("--state AK", "Alaska bundle", "AK_ENCs.zip"),
                ("--all", "All NOAA ENCs", "All_ENCs.zip"),
                ("--updates one-day", "Charts updated in last day", "OneDay_ENCs.zip"),
                ("--updates two-days", "Charts updated in last two days", "TwoDays_ENCs.zip"),
                ("--updates one-week", "Charts updated in last week", "OneWeek_ENCs.zip"),
                ("--updates ten-days", "Charts updated in last ten days", "TenDays_ENCs.zip"),
                ("--cgd 17", "Coast Guard District 17", "17CGD_ENCs.zip"),
                ("--region 30", "NOAA chart region 30", "30Region_ENCs.zip"),
                ("--chart US5AK3CM", "Individual ENC cell", "US5AK3CM.zip"),
                ("--catalog", "NOAA XML product catalog", CATALOG_NAME),
            ]
            for selector, label, filename in rows:
                print(f"{selector:20} {label:35} {args.base_url}{filename}")
            return 0

        if args.command == "gui":
            from .gui import main as gui_main

            gui_main()
            return 0

        if args.command == "init-config":
            path = write_default_config(Path(args.config), overwrite=args.force)
            print(path)
            return 0

        if args.command == "configure-opencpn":
            if opencpn_running() and not args.allow_running:
                raise RuntimeError("OpenCPN appears to be running; close it before editing its config")
            app_config = read_config(Path(args.config))
            chart_dir = Path(args.charts).expanduser() if args.charts else app_config.chart_output
            result = configure_chart_directory(
                chart_dir,
                config_path=Path(args.opencpn_config).expanduser() if args.opencpn_config else None,
                backup=not args.no_backup,
                dry_run=args.dry_run,
            )
            action = "Would add" if args.dry_run and result.changed else "Added" if result.changed else "Already present"
            print(f"{action}: {result.key}={result.chart_dir}")
            print(f"OpenCPN config: {result.config_path}")
            if result.backup_path:
                print(f"Backup: {result.backup_path}")
            if not args.no_gpsd and app_config.gps_mode == "gpsd":
                gpsd_result = configure_gpsd_connection(
                    host=app_config.gpsd_host,
                    port=app_config.gpsd_port,
                    config_path=Path(args.opencpn_config).expanduser() if args.opencpn_config else None,
                    backup=not args.no_backup and not result.changed,
                    dry_run=args.dry_run,
                )
                gpsd_action = (
                    "Would add GPSD"
                    if args.dry_run and gpsd_result.changed
                    else "Added GPSD"
                    if gpsd_result.changed
                    else "GPSD already present"
                )
                print(f"{gpsd_action}: {gpsd_result.host}:{gpsd_result.port}")
                if gpsd_result.backup_path and gpsd_result.backup_path != result.backup_path:
                    print(f"Backup: {gpsd_result.backup_path}")
            elif not args.no_gpsd:
                print(f"GPSD skipped: gps.mode={app_config.gps_mode}")
            print("Start OpenCPN with ENC processing: opencpn -parse_all_enc")
            return 0

        if args.command == "preflight":
            app_config = read_config(Path(args.config))
            gps_mode = app_config.gps_mode
            chart_dir = Path(args.charts).expanduser() if args.charts else app_config.chart_output
            results = run_preflight(
                chart_dir=chart_dir,
                chart_package=app_config.chart_package,
                chart_value=app_config.chart_value,
                gpsd=args.gpsd or (gps_mode == "gpsd" and not args.gps_device and not args.gps_sample),
                gpsd_host=app_config.gpsd_host,
                gpsd_port=app_config.gpsd_port,
                gps_device=args.gps_device or app_config.gps_device,
                gps_baud=args.gps_baud or app_config.gps_baud,
                gps_sample=Path(args.gps_sample) if args.gps_sample else None,
                gps_seconds=args.gps_seconds,
                max_chart_age_days=app_config.max_chart_age_days,
                min_free_gb=app_config.min_free_gb,
                keep_zip=app_config.keep_zip,
                track_output=app_config.track_output,
            )
            for result in results:
                mark = "OK" if result.ok else "FAIL"
                print(f"{mark:4} {result.name:10} {result.detail}")
            return 0 if all(result.ok for result in results) else 1

        if args.command == "status-report":
            gps_seconds = args.gps_seconds
            if args.gps_seconds_from_launcher_env:
                gps_seconds = _gps_seconds_from_launcher_env(Path(args.gps_seconds_from_launcher_env))
            report = build_status_report(
                config_path=Path(args.config),
                gps_sample=Path(args.gps_sample) if args.gps_sample else None,
                gps_seconds=gps_seconds,
            )
            if args.output:
                write_status_report(report, Path(args.output))
            if args.json:
                print(json.dumps(report, indent=2, sort_keys=True))
            else:
                print(format_status_text(report))
            return 0 if report["ok"] else 1

        if args.command == "gps-monitor":
            app_config = read_config(Path(args.config))
            use_gpsd = args.gpsd or (app_config.gps_mode == "gpsd" and not args.sample and args.device is None)
            device = args.device or app_config.gps_device
            if not use_gpsd and not args.sample:
                _validate_live_serial_device(device)
            count = 0
            deadline = time.monotonic() + args.seconds if args.seconds else None
            for fix in _read_fixes(
                device,
                args.baud or app_config.gps_baud,
                args.sample,
                gpsd=use_gpsd,
                gpsd_host=app_config.gpsd_host,
                gpsd_port=app_config.gpsd_port,
                deadline=deadline,
            ):
                print(_format_fix(fix))
                count += 1
                if args.once or count >= 1 and args.sample:
                    return 0
            return 1

        if args.command == "log-track":
            app_config = read_config(Path(args.config))
            use_gpsd = args.gpsd or (app_config.gps_mode == "gpsd" and not args.sample and args.device is None)
            device = args.device or app_config.gps_device
            if not use_gpsd and not args.sample:
                _validate_live_serial_device(device)
            base_output = Path(args.output).expanduser() if args.output else app_config.track_output
            deadline = time.monotonic() + args.seconds if args.seconds else None
            fixes = _read_fixes(
                device,
                args.baud or app_config.gps_baud,
                args.sample,
                gpsd=use_gpsd,
                gpsd_host=app_config.gpsd_host,
                gpsd_port=app_config.gpsd_port,
                deadline=deadline,
                gpsd_connect_retry=use_gpsd and deadline is None and not args.sample,
                gpsd_idle_timeout=args.gpsd_idle_timeout
                if use_gpsd and deadline is None and not args.sample and args.gpsd_idle_timeout
                else None,
                serial_idle_timeout=args.serial_idle_timeout
                if not use_gpsd and deadline is None and not args.sample and args.serial_idle_timeout
                else None,
            )
            fixes = _trackable_fixes(fixes)
            previous_handlers = _install_track_stop_handlers()
            try:
                if args.rotate_daily and not args.file:
                    retention_days = args.retention_days
                    if retention_days is None:
                        retention_days = app_config.track_retention_days
                    count, outputs = _log_rotating_tracks(
                        fixes,
                        base_output,
                        deadline=deadline,
                        sample=bool(args.sample),
                        retention_days=retention_days,
                    )
                    print(f"Saved {count} fixes to {', '.join(str(path) for path in outputs)}")
                else:
                    output = (
                        Path(args.file).expanduser()
                        if args.file
                        else _available_track_path(default_track_path(base_output))
                    )
                    count = _log_single_track(fixes, output, deadline=deadline, sample=bool(args.sample))
                    print(f"Saved {count} fixes to {output}")
                if count == 0:
                    print("No usable GPS fixes were written to the GPX track.", file=sys.stderr)
                    return 1
                if deadline is None and not args.sample:
                    print(
                        "Live GPS stream ended unexpectedly; restart the track logger to resume GPX logging.",
                        file=sys.stderr,
                    )
                    return 1
            except _TrackLoggerStop as exc:
                print(f"Stopped track logger: {exc}")
            finally:
                _restore_signal_handlers(previous_handlers)
            return 0

    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    parser.print_help()
    return 2


def _add_selector_args(parser: argparse.ArgumentParser) -> None:
    selectors = parser.add_mutually_exclusive_group(required=True)
    selectors.add_argument("--state", help="NOAA state/territory bundle, e.g. AK")
    selectors.add_argument("--cgd", help="Coast Guard district bundle, e.g. 17")
    selectors.add_argument("--region", help="NOAA region bundle, e.g. 30")
    selectors.add_argument("--updates", help="one-day, two-days, one-week, or ten-days")
    selectors.add_argument("--chart", help="individual ENC cell name, e.g. US5AK3CM")
    selectors.add_argument("--all", action="store_true", help="download all NOAA ENCs")
    selectors.add_argument("--catalog", action="store_true", help="download NOAA XML product catalog")


def _gps_seconds_from_launcher_env(path: Path) -> float:
    launcher_env = path.expanduser()
    symlink_component = first_symlink_ancestor(launcher_env.parent)
    if launcher_env.is_symlink():
        raise RuntimeError(f"launcher environment path is a symlink: {launcher_env}")
    if symlink_component is not None:
        raise RuntimeError(f"launcher environment directory is a symlink: {symlink_component}")
    _reject_unsafe_launcher_env_parent(launcher_env.parent)
    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(_read_launcher_settings_lines(launcher_env), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"malformed launcher environment line {line_number}: {line}")
        key, value = line.split("=", 1)
        key = key.strip()
        if key not in LAUNCHER_ENV_KEYS:
            raise ValueError(f"unknown launcher environment key: {key}")
        values[key] = value.strip()
    raw_seconds = values.get("NOAA_NAVIONICS_GPS_SECONDS", "")
    if not raw_seconds.isdigit() or int(raw_seconds) <= 0:
        raise ValueError(f"NOAA_NAVIONICS_GPS_SECONDS={raw_seconds or '<missing>'} expected positive integer")
    return float(int(raw_seconds))


def _reject_unsafe_launcher_env_parent(path: Path) -> None:
    parent = Path(path).expanduser()
    if not parent.exists():
        return
    if not parent.is_dir():
        raise RuntimeError(f"launcher environment parent is not a directory: {parent}")
    try:
        parent_stat = parent.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect launcher environment directory {parent}: {exc}") from exc
    if parent_stat.st_uid != os.getuid():
        raise RuntimeError(
            f"launcher environment directory {parent} is owned by uid {parent_stat.st_uid}, "
            f"expected {os.getuid()}"
        )
    parent_mode = stat.S_IMODE(parent_stat.st_mode)
    if parent_mode & 0o022:
        raise RuntimeError(
            f"launcher environment directory {parent} has permissions {parent_mode:04o}, "
            "expected no group/other write bits"
        )


def _read_fixes(
    device: str,
    baud: int,
    sample: Optional[str],
    *,
    gpsd: bool = False,
    gpsd_host: str = "127.0.0.1",
    gpsd_port: int = 2947,
    deadline: Optional[float] = None,
    gpsd_connect_retry: bool = False,
    gpsd_retry_delay: float = 5.0,
    gpsd_idle_timeout: Optional[float] = None,
    serial_idle_timeout: Optional[float] = None,
):
    if gpsd:
        timeout = 10.0
        max_duration = None
        if deadline is not None:
            timeout = max(0.1, deadline - time.monotonic())
            max_duration = timeout
        yielded_fix = False
        while True:
            try:
                gpsd_kwargs = {
                    "host": gpsd_host,
                    "port": gpsd_port,
                    "timeout": timeout,
                    "max_duration": max_duration,
                }
                if gpsd_idle_timeout is not None:
                    gpsd_kwargs["idle_timeout"] = gpsd_idle_timeout
                for fix in iter_gpsd_fixes(**gpsd_kwargs):
                    if deadline is not None and time.monotonic() > deadline:
                        break
                    yielded_fix = True
                    yield fix
                if gpsd_connect_retry and deadline is None and not yielded_fix:
                    print(
                        f"GPSD stream at {gpsd_host}:{gpsd_port} ended before any fixes; "
                        f"retrying in {gpsd_retry_delay:g}s",
                        file=sys.stderr,
                    )
                    time.sleep(max(0.1, gpsd_retry_delay))
                    continue
                return
            except OSError as exc:
                if not gpsd_connect_retry or deadline is not None or yielded_fix:
                    raise
                print(
                    f"GPSD unavailable at {gpsd_host}:{gpsd_port}: {exc}; "
                    f"retrying in {gpsd_retry_delay:g}s",
                    file=sys.stderr,
                )
                time.sleep(max(0.1, gpsd_retry_delay))
        return
    if sample:
        with open_trusted_gps_sample(Path(sample)) as handle:
            yield from iter_fixes(handle)
        return
    _validate_live_serial_device(device)
    with open_nmea_stream(device, baud=baud) as stream:
        lines = (
            _read_nmea_lines_until(stream, deadline)
            if deadline is not None
            else read_nmea_lines(stream, idle_timeout=serial_idle_timeout)
        )
        yield from iter_fixes(lines)


def _validate_live_serial_device(device: str) -> None:
    if not device:
        raise ValueError("GPS serial device is required")
    if _volatile_usb_device_path(device):
        raise ValueError("GPS serial device uses a volatile USB name; use /dev/serial/by-id/... instead")
    if not _stable_gps_device_path(device):
        raise ValueError(
            "GPS serial device must be /dev/serial/by-id/..., /dev/serial0, /dev/serial1, or /dev/gps"
        )
    path = Path(device).expanduser()
    path_text = str(path)
    if path_text.startswith("/dev/serial/by-id/") and path.exists() and not path.is_symlink():
        raise ValueError(f"GPS serial device {path} is not a udev by-id symlink")


def _read_nmea_lines_until(stream, deadline: float):
    buffer = b""
    while time.monotonic() <= deadline:
        chunk = stream.read(1)
        if not chunk:
            time.sleep(0.05)
            continue
        buffer += chunk
        if len(buffer) > NMEA_MAX_LINE_BYTES:
            raise ValueError(f"NMEA sentence exceeded {NMEA_MAX_LINE_BYTES} bytes without a line ending")
        if chunk in (b"\n", b"\r"):
            line = buffer.decode("ascii", errors="ignore").strip()
            buffer = b""
            if line:
                yield line


def _wait_for_network(
    host: str,
    port: int,
    seconds: float,
    *,
    interval: float = 5.0,
    timeout: float = 5.0,
) -> None:
    deadline = time.monotonic() + seconds
    last_error = ""
    while True:
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return
        except OSError as exc:
            last_error = str(exc)
        if time.monotonic() >= deadline:
            detail = f": {last_error}" if last_error else ""
            raise RuntimeError(f"network not reachable at {host}:{port} within {seconds:g}s{detail}")
        time.sleep(min(interval, max(0.1, deadline - time.monotonic())))


def _trackable_fixes(
    fixes,
    *,
    max_fix_age_seconds: float = 300.0,
    future_tolerance_seconds: float = 30.0,
):
    last_skip_detail = ""
    for fix in fixes:
        quality_detail = gps_fix_quality_failure(fix)
        if quality_detail:
            if quality_detail != last_skip_detail:
                print(f"Skipping weak track fix: {quality_detail}", file=sys.stderr)
                last_skip_detail = quality_detail
            continue
        if fix.timestamp is None:
            detail = "fix has no timestamp; cannot write reliable GPX trackpoint"
            if detail != last_skip_detail:
                print(f"Skipping untimestamped track fix: {detail}", file=sys.stderr)
                last_skip_detail = detail
            continue
        freshness_detail = _track_fix_freshness_failure(
            fix,
            max_fix_age_seconds=max_fix_age_seconds,
            future_tolerance_seconds=future_tolerance_seconds,
        )
        if freshness_detail:
            if freshness_detail != last_skip_detail:
                print(f"Skipping stale track fix: {freshness_detail}", file=sys.stderr)
                last_skip_detail = freshness_detail
            continue
        if not gps_fix_has_quality_fields(fix):
            detail = "fix missing satellite or HDOP quality fields; cannot write reliable GPX trackpoint"
            if detail != last_skip_detail:
                print(f"Skipping low-detail track fix: {detail}", file=sys.stderr)
                last_skip_detail = detail
            continue
        last_skip_detail = ""
        yield fix


def _track_fix_freshness_failure(
    fix,
    *,
    max_fix_age_seconds: float = 300.0,
    future_tolerance_seconds: float = 30.0,
) -> str:
    if fix.timestamp is None:
        return "fix has no timestamp; cannot write reliable GPX trackpoint"
    age_seconds = (datetime.now(timezone.utc) - fix.timestamp.astimezone(timezone.utc)).total_seconds()
    if age_seconds > max_fix_age_seconds:
        return f"fix timestamp is stale ({age_seconds:.0f}s old)"
    if age_seconds < -future_tolerance_seconds:
        return f"fix timestamp is in the future by {-age_seconds:.0f}s"
    return ""


class _TrackLoggerStop(Exception):
    pass


def _install_track_stop_handlers():
    previous = {}
    for sig in (signal.SIGINT, signal.SIGTERM):
        previous[sig] = signal.getsignal(sig)
        signal.signal(sig, _raise_track_logger_stop)
    return previous


def _restore_signal_handlers(previous) -> None:
    for sig, handler in previous.items():
        signal.signal(sig, handler)


def _raise_track_logger_stop(signum, frame) -> None:
    try:
        name = signal.Signals(signum).name
    except ValueError:
        name = str(signum)
    raise _TrackLoggerStop(name)


def _log_single_track(fixes, output: Path, *, deadline: Optional[float], sample: bool) -> int:
    count = 0
    logger: Optional[GPXTrackLogger] = None
    try:
        for fix in fixes:
            if logger is None:
                logger = GPXTrackLogger(output)
                logger.__enter__()
            logger.append(fix)
            count += 1
            print(_format_fix(fix))
            if deadline and time.monotonic() >= deadline:
                break
            if sample:
                continue
    finally:
        if logger is not None:
            logger.__exit__(None, None, None)
    return count


def _log_rotating_tracks(
    fixes,
    base_output: Path,
    *,
    deadline: Optional[float],
    sample: bool,
    retention_days: int = 0,
) -> tuple[int, list[Path]]:
    count = 0
    current_day: Optional[str] = None
    current_path: Optional[Path] = None
    logger: Optional[GPXTrackLogger] = None
    outputs: list[Path] = []
    try:
        for fix in fixes:
            day = _track_day(fix)
            if day != current_day:
                if logger is not None:
                    logger.__exit__(None, None, None)
                current_day = day
                current_path = _available_track_path(daily_track_path(base_output, fix.timestamp))
                _prepare_private_tracks_dir(current_path.parent)
                outputs.append(current_path)
                logger = GPXTrackLogger(current_path)
                logger.__enter__()
                _prune_old_track_logs(base_output, retention_days=retention_days, now=fix.timestamp)
            assert logger is not None
            logger.append(fix)
            count += 1
            print(_format_fix(fix))
            if deadline and time.monotonic() >= deadline:
                break
            if sample:
                continue
    finally:
        if logger is not None:
            logger.__exit__(None, None, None)
    return count, outputs


def _prepare_private_tracks_dir(tracks_dir: Path) -> None:
    path = Path(tracks_dir).expanduser()
    symlink_component = first_symlink_ancestor(path)
    if symlink_component is not None:
        raise RuntimeError(f"{symlink_component} is a symlink, expected a private tracks directory")
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    symlink_component = first_symlink_ancestor(path)
    if symlink_component is not None:
        raise RuntimeError(f"{symlink_component} is a symlink, expected a private tracks directory")
    stat_result = path.stat()
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(f"{path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}")
    os.chmod(path, 0o700)
    _fsync_directory(path)
    _fsync_directory(path.parent)


def _prune_old_track_logs(base_output: Path, *, retention_days: int, now: Optional[datetime] = None) -> list[Path]:
    if retention_days <= 0:
        return []
    tracks_dir = Path(base_output).expanduser() / "tracks"
    symlink_component = first_symlink_ancestor(tracks_dir)
    if symlink_component is not None:
        raise RuntimeError(f"{symlink_component} is a symlink, refusing to prune GPX track logs")
    if not tracks_dir.exists():
        return []
    tracks_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        tracks_fd = os.open(tracks_dir, tracks_flags)
    except OSError as exc:
        raise RuntimeError(f"{tracks_dir} could not be opened safely for GPX pruning: {exc}") from exc
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc).date()
    cutoff = current - timedelta(days=retention_days)
    removed: list[Path] = []
    try:
        tracks_stat = os.fstat(tracks_fd)
        if not stat.S_ISDIR(tracks_stat.st_mode):
            raise RuntimeError(f"{tracks_dir} is not a directory, refusing to prune GPX track logs")
        if tracks_stat.st_uid != os.getuid():
            raise RuntimeError(f"{tracks_dir} is owned by uid {tracks_stat.st_uid}, expected {os.getuid()}")
        if stat.S_IMODE(tracks_stat.st_mode) & 0o077:
            raise RuntimeError(f"{tracks_dir} has permissions {stat.S_IMODE(tracks_stat.st_mode):03o}, expected private 0700")
        for path in tracks_dir.glob("track-*.gpx"):
            track_date = _track_date_from_name(path)
            if track_date is None or track_date >= cutoff:
                continue
            _validate_prunable_track_log(path, tracks_fd=tracks_fd)
            try:
                os.unlink(path.name, dir_fd=tracks_fd)
            except OSError:
                continue
            removed.append(path)
    finally:
        os.close(tracks_fd)
    if removed:
        _fsync_directory(tracks_dir)
    return removed


def _validate_prunable_track_log(path: Path, *, tracks_fd: int) -> None:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path.name, flags, dir_fd=tracks_fd)
    except OSError as exc:
        if path.is_symlink():
            raise RuntimeError(f"{path} is a symlink, refusing to prune GPX track logs") from exc
        raise RuntimeError(f"{path} could not be opened safely for GPX pruning: {exc}") from exc
    try:
        path_stat = os.fstat(fd)
        if not stat.S_ISREG(path_stat.st_mode):
            raise RuntimeError(f"{path} is not a regular GPX track file, refusing to prune")
        if path_stat.st_uid != os.getuid():
            raise RuntimeError(f"{path} is owned by uid {path_stat.st_uid}, expected {os.getuid()}")
        mode = stat.S_IMODE(path_stat.st_mode)
        if mode != 0o600:
            raise RuntimeError(f"{path} has permissions {mode:03o}, expected private 0600")
    finally:
        os.close(fd)


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


def _track_date_from_name(path: Path):
    pieces = path.stem.split("-")
    if len(pieces) < 2 or len(pieces[1]) != 8:
        return None
    try:
        return datetime.strptime(pieces[1], "%Y%m%d").date()
    except ValueError:
        return None


def _track_day(fix) -> str:
    timestamp = fix.timestamp or datetime.now(timezone.utc)
    return timestamp.astimezone(timezone.utc).strftime("%Y%m%d")


def _available_track_path(path: Path) -> Path:
    if not path.exists():
        return path
    stem = path.stem
    suffix = path.suffix
    for index in range(1, 1000):
        candidate = path.with_name(f"{stem}-{index}{suffix}")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"could not find available track filename near {path}")


def _format_fix(fix) -> str:
    timestamp = fix.timestamp.isoformat() if fix.timestamp else "no-time"
    speed = f"{fix.speed_knots:.1f} kt" if fix.speed_knots is not None else "speed n/a"
    course = f"{fix.course_degrees:.0f} deg" if fix.course_degrees is not None else "course n/a"
    sats = f"{fix.satellites} sats" if fix.satellites is not None else "sats n/a"
    hdop = f"HDOP {fix.hdop}" if fix.hdop is not None else "HDOP n/a"
    return f"{timestamp}  {fix.latitude:.6f}, {fix.longitude:.6f}  {speed}  {course}  {sats}  {hdop}"


if __name__ == "__main__":
    raise SystemExit(main())
