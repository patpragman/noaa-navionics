from __future__ import annotations

from pathlib import Path
from typing import Optional
import argparse
import time
import sys

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

    preflight = subparsers.add_parser("preflight", help="check Pi navigation readiness")
    preflight.add_argument("--charts", default="~/charts/noaa-enc", help="chart directory")
    preflight.add_argument("--gpsd", action="store_true", help="check GPSD at localhost:2947")
    preflight.add_argument("--gps-device", help="NMEA serial device, e.g. /dev/ttyUSB0")
    preflight.add_argument("--gps-sample", help="NMEA sample file for testing")
    preflight.add_argument("--gps-seconds", type=float, default=5.0, help="seconds to wait for a GPS fix")

    gps = subparsers.add_parser("gps-monitor", help="print live GPS fixes from an NMEA device")
    gps.add_argument("--device", default="/dev/ttyUSB0", help="NMEA serial device")
    gps.add_argument("--baud", type=int, default=4800, help="serial baud rate")
    gps.add_argument("--gpsd", action="store_true", help="read GPSD at localhost:2947")
    gps.add_argument("--sample", help="read NMEA from a text file instead of a serial device")
    gps.add_argument("--once", action="store_true", help="exit after the first valid fix")

    track = subparsers.add_parser("log-track", help="record GPS fixes to a GPX track")
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

        if args.command == "preflight":
            results = run_preflight(
                chart_dir=Path(args.charts),
                gpsd=args.gpsd,
                gps_device=args.gps_device,
                gps_sample=Path(args.gps_sample) if args.gps_sample else None,
                gps_seconds=args.gps_seconds,
            )
            for result in results:
                mark = "OK" if result.ok else "FAIL"
                print(f"{mark:4} {result.name:10} {result.detail}")
            return 0 if all(result.ok for result in results) else 1

        if args.command == "gps-monitor":
            count = 0
            for fix in _read_fixes(args.device, args.baud, args.sample, gpsd=args.gpsd):
                print(_format_fix(fix))
                count += 1
                if args.once or count >= 1 and args.sample:
                    return 0
            return 1

        if args.command == "log-track":
            output = Path(args.file).expanduser() if args.file else default_track_path(Path(args.output))
            deadline = time.monotonic() + args.seconds if args.seconds else None
            with GPXTrackLogger(output) as logger:
                count = 0
                for fix in _read_fixes(args.device, args.baud, args.sample, gpsd=args.gpsd):
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


def _read_fixes(device: str, baud: int, sample: Optional[str], *, gpsd: bool = False):
    if gpsd:
        yield from iter_gpsd_fixes()
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
