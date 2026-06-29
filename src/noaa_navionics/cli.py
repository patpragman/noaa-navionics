from __future__ import annotations

from pathlib import Path
from typing import Optional
import argparse
import json
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
from .gps import GPXTrackLogger, default_track_path, iter_fixes, iter_gpsd_fixes, open_nmea_stream, read_nmea_lines
from .health import run_preflight
from .opencpn import configure_chart_directory, opencpn_running
from .report import build_status_report, format_status_text, write_status_report


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
    download.add_argument("--timeout", type=float, default=60, help="network timeout in seconds")
    download.add_argument("--base-url", default=BASE_URL, help=argparse.SUPPRESS)

    sync = subparsers.add_parser("sync-charts", help="download the chart package from the config file")
    sync.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    sync.add_argument("--force", action="store_true", help="override config and force redownload")

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

    opencpn_config = subparsers.add_parser("configure-opencpn", help="add the configured chart directory to OpenCPN")
    opencpn_config.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="NOAA Navionics config file path")
    opencpn_config.add_argument("--charts", help="chart directory to add; defaults to [charts].output")
    opencpn_config.add_argument("--opencpn-config", help="OpenCPN config path; defaults to ~/.opencpn/opencpn.conf")
    opencpn_config.add_argument("--dry-run", action="store_true", help="print intended change without writing")
    opencpn_config.add_argument("--no-backup", action="store_true", help="do not back up an existing OpenCPN config")
    opencpn_config.add_argument(
        "--allow-running",
        action="store_true",
        help="allow editing OpenCPN config while OpenCPN appears to be running",
    )

    preflight = subparsers.add_parser("preflight", help="check Pi navigation readiness")
    preflight.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    preflight.add_argument("--charts", default="~/charts/noaa-enc", help="chart directory")
    preflight.add_argument("--gpsd", action="store_true", help="check GPSD at localhost:2947")
    preflight.add_argument("--gps-device", help="NMEA serial device, e.g. /dev/ttyUSB0")
    preflight.add_argument("--gps-sample", help="NMEA sample file for testing")
    preflight.add_argument("--gps-seconds", type=float, default=5.0, help="seconds to wait for a GPS fix")

    status = subparsers.add_parser("status-report", help="write an onboard readiness status report")
    status.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    status.add_argument("--gps-sample", help="NMEA sample file for testing")
    status.add_argument("--gps-seconds", type=float, default=5.0, help="seconds to wait for a GPS fix")
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
    track.add_argument("--seconds", type=float, help="stop after this many seconds")

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
            print("Start OpenCPN with ENC processing: opencpn -parse_all_enc")
            return 0

        if args.command == "preflight":
            app_config = read_config(Path(args.config))
            gps_mode = app_config.gps_mode
            results = run_preflight(
                chart_dir=Path(args.charts) if args.charts != "~/charts/noaa-enc" else app_config.chart_output,
                gpsd=args.gpsd or (gps_mode == "gpsd" and not args.gps_device and not args.gps_sample),
                gpsd_host=app_config.gpsd_host,
                gpsd_port=app_config.gpsd_port,
                gps_device=args.gps_device or (app_config.gps_device if gps_mode == "serial" else None),
                gps_sample=Path(args.gps_sample) if args.gps_sample else None,
                gps_seconds=args.gps_seconds,
                max_chart_age_days=app_config.max_chart_age_days,
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
            output = Path(args.file).expanduser() if args.file else default_track_path(base_output)
            deadline = time.monotonic() + args.seconds if args.seconds else None
            with GPXTrackLogger(output) as logger:
                count = 0
                for fix in _read_fixes(
                    args.device if args.device != "/dev/ttyUSB0" else app_config.gps_device,
                    args.baud if args.baud != 4800 else app_config.gps_baud,
                    args.sample,
                    gpsd=use_gpsd,
                    gpsd_host=app_config.gpsd_host,
                    gpsd_port=app_config.gpsd_port,
                ):
                    logger.append(fix)
                    count += 1
                    print(_format_fix(fix))
                    if deadline and time.monotonic() >= deadline:
                        break
                    if args.sample:
                        continue
            print(f"Saved {count} fixes to {output}")
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


def _format_fix(fix) -> str:
    timestamp = fix.timestamp.isoformat() if fix.timestamp else "no-time"
    speed = f"{fix.speed_knots:.1f} kt" if fix.speed_knots is not None else "speed n/a"
    course = f"{fix.course_degrees:.0f} deg" if fix.course_degrees is not None else "course n/a"
    sats = f"{fix.satellites} sats" if fix.satellites is not None else "sats n/a"
    hdop = f"HDOP {fix.hdop}" if fix.hdop is not None else "HDOP n/a"
    return f"{timestamp}  {fix.latitude:.6f}, {fix.longitude:.6f}  {speed}  {course}  {sats}  {hdop}"


if __name__ == "__main__":
    raise SystemExit(main())
