from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional
import argparse
import json
import math
import signal
import time
import sys

from .config import DEFAULT_CONFIG_PATH, package_kwargs, read_config, write_default_config
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
    daily_track_path,
    default_track_path,
    gps_fix_quality_failure,
    iter_fixes,
    iter_gpsd_fixes,
    open_nmea_stream,
    read_nmea_lines,
)
from .health import run_preflight
from .opencpn import configure_chart_directory, configure_gpsd_connection, opencpn_running
from .report import build_status_report, format_status_text, write_status_report


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
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
    preflight.add_argument("--charts", default="~/charts/noaa-enc", help="chart directory")
    preflight.add_argument("--gpsd", action="store_true", help="check GPSD at localhost:2947")
    preflight.add_argument("--gps-device", help="NMEA serial device, e.g. /dev/serial/by-id/YOUR_GPS_DEVICE")
    preflight.add_argument("--gps-baud", type=int, help="NMEA serial baud rate")
    preflight.add_argument("--gps-sample", help="NMEA sample file for testing")
    preflight.add_argument("--gps-seconds", type=_non_negative_float, default=5.0, help="seconds to wait for a GPS fix")

    status = subparsers.add_parser("status-report", help="write an onboard readiness status report")
    status.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    status.add_argument("--gps-sample", help="NMEA sample file for testing")
    status.add_argument("--gps-seconds", type=_non_negative_float, default=5.0, help="seconds to wait for a GPS fix")
    status.add_argument("--output", help="write JSON report to this file")
    status.add_argument("--json", action="store_true", help="print JSON instead of text")

    gps = subparsers.add_parser("gps-monitor", help="print live GPS fixes from an NMEA device")
    gps.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    gps.add_argument("--device", default="/dev/ttyUSB0", help="NMEA serial device")
    gps.add_argument("--baud", type=int, default=4800, help="serial baud rate")
    gps.add_argument("--gpsd", action="store_true", help="read GPSD at localhost:2947")
    gps.add_argument("--sample", help="read NMEA from a text file instead of a serial device")
    gps.add_argument("--once", action="store_true", help="exit after the first valid fix")

    track = subparsers.add_parser("log-track", help="record GPS fixes to a GPX track")
    track.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    track.add_argument("--device", default="/dev/ttyUSB0", help="NMEA serial device")
    track.add_argument("--baud", type=int, default=4800, help="serial baud rate")
    track.add_argument("--gpsd", action="store_true", help="read GPSD at localhost:2947")
    track.add_argument("--output", "-o", default="~/charts/noaa-enc", help="base output directory")
    track.add_argument("--file", help="explicit GPX output file")
    track.add_argument("--sample", help="read NMEA from a text file instead of a serial device")
    track.add_argument("--seconds", type=_positive_float, help="stop after this many seconds")
    track.add_argument("--rotate-daily", action="store_true", help="write one GPX file per UTC day")
    track.add_argument(
        "--retention-days",
        type=int,
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
            results = run_preflight(
                chart_dir=Path(args.charts) if args.charts != "~/charts/noaa-enc" else app_config.chart_output,
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
                track_output=app_config.track_output,
            )
            for result in results:
                mark = "OK" if result.ok else "FAIL"
                print(f"{mark:4} {result.name:10} {result.detail}")
            return 0 if all(result.ok for result in results) else 1

        if args.command == "status-report":
            report = build_status_report(
                config_path=Path(args.config),
                gps_sample=Path(args.gps_sample) if args.gps_sample else None,
                gps_seconds=args.gps_seconds,
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
            use_gpsd = args.gpsd or (
                app_config.gps_mode == "gpsd" and not args.sample and args.device == "/dev/ttyUSB0"
            )
            count = 0
            for fix in _read_fixes(
                args.device if args.device != "/dev/ttyUSB0" else app_config.gps_device,
                args.baud if args.baud != 4800 else app_config.gps_baud,
                args.sample,
                gpsd=use_gpsd,
                gpsd_host=app_config.gpsd_host,
                gpsd_port=app_config.gpsd_port,
            ):
                print(_format_fix(fix))
                count += 1
                if args.once or count >= 1 and args.sample:
                    return 0
            return 1

        if args.command == "log-track":
            app_config = read_config(Path(args.config))
            use_gpsd = args.gpsd or (
                app_config.gps_mode == "gpsd" and not args.sample and args.device == "/dev/ttyUSB0"
            )
            base_output = Path(args.output) if args.output != "~/charts/noaa-enc" else app_config.track_output
            deadline = time.monotonic() + args.seconds if args.seconds else None
            fixes = _read_fixes(
                args.device if args.device != "/dev/ttyUSB0" else app_config.gps_device,
                args.baud if args.baud != 4800 else app_config.gps_baud,
                args.sample,
                gpsd=use_gpsd,
                gpsd_host=app_config.gpsd_host,
                gpsd_port=app_config.gpsd_port,
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


def _read_fixes(
    device: str,
    baud: int,
    sample: Optional[str],
    *,
    gpsd: bool = False,
    gpsd_host: str = "127.0.0.1",
    gpsd_port: int = 2947,
):
    if gpsd:
        yield from iter_gpsd_fixes(host=gpsd_host, port=gpsd_port)
        return
    if sample:
        with Path(sample).expanduser().open(encoding="ascii", errors="ignore") as handle:
            yield from iter_fixes(handle)
        return
    with open_nmea_stream(device, baud=baud) as stream:
        yield from iter_fixes(read_nmea_lines(stream))


def _trackable_fixes(fixes):
    last_skip_detail = ""
    for fix in fixes:
        quality_detail = gps_fix_quality_failure(fix)
        if quality_detail:
            if quality_detail != last_skip_detail:
                print(f"Skipping weak track fix: {quality_detail}", file=sys.stderr)
                last_skip_detail = quality_detail
            continue
        last_skip_detail = ""
        yield fix


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


def _prune_old_track_logs(base_output: Path, *, retention_days: int, now: Optional[datetime] = None) -> list[Path]:
    if retention_days <= 0:
        return []
    tracks_dir = Path(base_output).expanduser() / "tracks"
    if not tracks_dir.exists():
        return []
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc).date()
    cutoff = current - timedelta(days=retention_days)
    removed: list[Path] = []
    for path in tracks_dir.glob("track-*.gpx"):
        track_date = _track_date_from_name(path)
        if track_date is None or track_date >= cutoff:
            continue
        try:
            path.unlink()
        except OSError:
            continue
        removed.append(path)
    return removed


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
