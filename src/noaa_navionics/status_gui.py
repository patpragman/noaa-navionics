from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from queue import Empty, Queue
from threading import Thread
from typing import Optional
import argparse
import math
import tkinter as tk
from tkinter import ttk

from .config import DEFAULT_CONFIG_PATH, read_config
from .gps import GPSFix, distance_meters, gpx_position_mark_path, write_gpx_position_mark
from .gui import format_gps_fix, read_configured_gps_fix, read_configured_gps_fixes
from .report import build_status_report, write_status_report


DEFAULT_STATUS_REPORT = Path("~/.cache/noaa-navionics/status.json").expanduser()


@dataclass(frozen=True)
class StatusRow:
    name: str
    ok: bool
    detail: str


def status_headline(report: dict[str, object]) -> str:
    return "READY" if bool(report.get("ok")) else "NOT READY"


def status_rows(report: dict[str, object]) -> list[StatusRow]:
    rows = [
        StatusRow(
            "Overall",
            bool(report.get("ok")),
            f"generated {report.get('generated_at', 'unknown time')}",
        )
    ]
    for section_name in ("checks", "service_checks"):
        section = report.get(section_name)
        if not isinstance(section, list):
            continue
        for item in section:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name", "Check"))
            detail = str(item.get("detail", ""))
            rows.append(StatusRow(name, bool(item.get("ok")), detail))
    return rows


def count_failures(rows: list[StatusRow]) -> int:
    return sum(1 for row in rows if not row.ok)


def format_panel_summary(report: dict[str, object]) -> str:
    rows = status_rows(report)
    failures = count_failures(rows)
    if failures == 0:
        return "All reported navigation readiness checks are passing."
    return f"{failures} reported readiness check(s) need attention."


def format_gps_summary(report: dict[str, object]) -> str:
    gps_fix = report.get("gps_fix")
    if not isinstance(gps_fix, dict) or not gps_fix.get("source"):
        return "GPS: not reported"
    source = str(gps_fix.get("source", "GPS"))
    state = "OK" if gps_fix.get("ok") else "FAIL"
    pieces = [f"{source} {state}"]
    latitude = gps_fix.get("latitude")
    longitude = gps_fix.get("longitude")
    if isinstance(latitude, (int, float)) and isinstance(longitude, (int, float)):
        pieces.append(f"{latitude:.6f}, {longitude:.6f}")
    timestamp = gps_fix.get("timestamp")
    if timestamp:
        pieces.append(str(timestamp))
    age_seconds = gps_fix.get("age_seconds")
    if isinstance(age_seconds, (int, float)) and not isinstance(age_seconds, bool):
        pieces.append(f"age {age_seconds:.0f}s")
    satellites = gps_fix.get("satellites")
    if satellites is not None:
        pieces.append(f"{satellites} sats")
    hdop = gps_fix.get("hdop")
    if hdop is not None:
        pieces.append(f"HDOP {hdop}")
    speed = gps_fix.get("speed_knots")
    if isinstance(speed, (int, float)):
        pieces.append(f"{speed:.1f} kt")
    course = gps_fix.get("course_degrees")
    if isinstance(course, (int, float)):
        pieces.append(f"{course:.1f} deg")
    if len(pieces) == 1:
        detail = str(gps_fix.get("detail", "")).strip()
        if detail:
            pieces.append(detail)
    return " | ".join(pieces)


def available_position_mark_path(path: Path) -> Path:
    target = Path(path).expanduser()
    if not target.exists():
        return target
    stem = target.stem
    suffix = target.suffix
    for index in range(1, 1000):
        candidate = target.with_name(f"{stem}-{index}{suffix}")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"could not find available position mark filename near {target}")


def write_current_position_mark(
    config_path: Path,
    *,
    gps_seconds: float = 10.0,
    mob: bool = False,
) -> tuple[Path, GPSFix]:
    app_config = read_config(config_path)
    fix = read_configured_gps_fix(app_config, gps_seconds=gps_seconds)
    path = available_position_mark_path(
        gpx_position_mark_path(app_config.track_output, fix.timestamp, prefix="mob" if mob else "mark")
    )
    name = "MOB" if mob else "Position mark"
    description = "Man overboard position mark" if mob else ""
    return write_gpx_position_mark(path, fix, name=name, description=description), fix


def check_anchor_drift(
    config_path: Path,
    *,
    gps_seconds: float = 10.0,
    radius_meters: float = 50.0,
) -> tuple[float, float, GPSFix, GPSFix]:
    if not math.isfinite(radius_meters) or radius_meters <= 0:
        raise ValueError("anchor radius must be greater than 0")
    app_config = read_config(config_path)
    anchor_fix, current_fix = read_configured_gps_fixes(app_config, count=2, gps_seconds=gps_seconds)
    distance = distance_meters(anchor_fix.latitude, anchor_fix.longitude, current_fix.latitude, current_fix.longitude)
    return distance, radius_meters, anchor_fix, current_fix


def format_anchor_check(distance: float, radius_meters: float) -> str:
    if distance > radius_meters:
        return f"ANCHOR ALARM: {distance:.1f} m from anchor; radius {radius_meters:g} m"
    return f"Anchor OK: {distance:.1f} m from anchor; radius {radius_meters:g} m"


def anchor_alarm_active(distance: float, radius_meters: float) -> bool:
    return distance > radius_meters


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


class StatusApp(tk.Tk):
    def __init__(
        self,
        *,
        config_path: Path = DEFAULT_CONFIG_PATH,
        output_path: Optional[Path] = DEFAULT_STATUS_REPORT,
        gps_seconds: float = 10.0,
        refresh_seconds: float = 60.0,
        anchor_radius_meters: Optional[float] = None,
    ) -> None:
        super().__init__()
        self.title("NOAA Navionics Status")
        self.geometry("780x560")
        self.minsize(680, 460)

        self.config_path = Path(config_path).expanduser()
        self.output_path = Path(output_path).expanduser() if output_path is not None else None
        self.gps_seconds = gps_seconds
        self.refresh_seconds = refresh_seconds
        if anchor_radius_meters is None:
            anchor_radius_meters = _configured_anchor_radius(self.config_path)
        self.anchor_radius = tk.StringVar(value=f"{anchor_radius_meters:g}")
        self.queue: Queue = Queue()
        self.worker: Optional[Thread] = None
        self.after_id: Optional[str] = None

        self.headline = tk.StringVar(value="Checking...")
        self.summary = tk.StringVar(value="Waiting for the first status refresh.")
        self.gps_summary = tk.StringVar(value="GPS: waiting for status refresh.")
        self.last_report = tk.StringVar(value="")
        self._build()
        self.after(100, self.refresh_now)
        self.after(150, self._poll_queue)

    def _build(self) -> None:
        root = ttk.Frame(self, padding=16)
        root.pack(fill=tk.BOTH, expand=True)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(3, weight=1)

        ttk.Label(root, textvariable=self.headline, font=("TkDefaultFont", 22, "bold")).grid(
            row=0, column=0, sticky=tk.W
        )
        ttk.Label(root, textvariable=self.summary).grid(row=1, column=0, sticky=tk.W, pady=(4, 12))
        ttk.Label(root, textvariable=self.gps_summary).grid(row=2, column=0, sticky=tk.W, pady=(0, 12))

        self.tree = ttk.Treeview(root, columns=("status", "detail"), show="headings", height=12)
        self.tree.heading("status", text="Status")
        self.tree.heading("detail", text="Detail")
        self.tree.column("status", width=90, stretch=False)
        self.tree.column("detail", width=520)
        self.tree.grid(row=3, column=0, sticky=tk.NSEW)
        scroll = ttk.Scrollbar(root, orient=tk.VERTICAL, command=self.tree.yview)
        scroll.grid(row=3, column=1, sticky=tk.NS)
        self.tree.configure(yscrollcommand=scroll.set)

        self.tree.tag_configure("ok", foreground="#0a6f2a")
        self.tree.tag_configure("fail", foreground="#b00020")

        buttons = ttk.Frame(root)
        buttons.grid(row=4, column=0, sticky=tk.EW, pady=(12, 0))
        self.refresh_button = ttk.Button(buttons, text="Refresh", command=self.refresh_now)
        self.refresh_button.pack(side=tk.LEFT)
        self.mark_button = ttk.Button(buttons, text="Mark", command=lambda: self.mark_position(mob=False))
        self.mark_button.pack(side=tk.LEFT, padx=(10, 0))
        self.mob_button = ttk.Button(buttons, text="MOB", command=lambda: self.mark_position(mob=True))
        self.mob_button.pack(side=tk.LEFT, padx=(10, 0))
        ttk.Label(buttons, text="Radius m").pack(side=tk.LEFT, padx=(16, 0))
        self.anchor_radius_entry = ttk.Entry(buttons, textvariable=self.anchor_radius, width=7)
        self.anchor_radius_entry.pack(side=tk.LEFT, padx=(6, 0))
        self.anchor_button = ttk.Button(buttons, text="Anchor Check", command=self.anchor_check)
        self.anchor_button.pack(side=tk.LEFT, padx=(10, 0))
        ttk.Button(buttons, text="Quit", command=self.destroy).pack(side=tk.LEFT, padx=(10, 0))
        ttk.Label(root, textvariable=self.last_report).grid(row=5, column=0, sticky=tk.W, pady=(8, 0))

    def refresh_now(self) -> None:
        if self.worker is not None and self.worker.is_alive():
            return
        self._set_busy(True)
        self.summary.set("Refreshing status...")
        self.worker = Thread(target=self._refresh_worker, daemon=True)
        self.worker.start()

    def mark_position(self, *, mob: bool = False) -> None:
        if self.worker is not None and self.worker.is_alive():
            return
        self._set_busy(True)
        self.summary.set("Recording current GPS position...")
        self.worker = Thread(target=self._mark_worker, kwargs={"mob": mob}, daemon=True)
        self.worker.start()

    def anchor_check(self) -> None:
        if self.worker is not None and self.worker.is_alive():
            return
        try:
            radius_meters = _positive_float(self.anchor_radius.get())
        except argparse.ArgumentTypeError as exc:
            self._show_error(f"Anchor radius {exc}")
            return
        self._set_busy(True)
        self.summary.set("Checking anchor distance...")
        self.worker = Thread(target=self._anchor_worker, kwargs={"radius_meters": radius_meters}, daemon=True)
        self.worker.start()

    def _refresh_worker(self) -> None:
        try:
            report = build_status_report(config_path=self.config_path, gps_seconds=self.gps_seconds)
            if self.output_path is not None:
                write_status_report(report, self.output_path)
            self.queue.put(("report", report))
        except Exception as exc:  # pragma: no cover - UI path
            self.queue.put(("error", str(exc)))

    def _mark_worker(self, *, mob: bool) -> None:
        try:
            path, fix = write_current_position_mark(self.config_path, gps_seconds=self.gps_seconds, mob=mob)
            self.queue.put(("mark", (path, format_gps_fix(fix))))
        except Exception as exc:  # pragma: no cover - UI path
            self.queue.put(("error", str(exc)))

    def _anchor_worker(self, *, radius_meters: float) -> None:
        try:
            distance, radius, anchor_fix, current_fix = check_anchor_drift(
                self.config_path,
                gps_seconds=self.gps_seconds,
                radius_meters=radius_meters,
            )
            self.queue.put(("anchor", (distance, radius, anchor_fix, current_fix)))
        except Exception as exc:  # pragma: no cover - UI path
            self.queue.put(("error", str(exc)))

    def _poll_queue(self) -> None:
        try:
            while True:
                kind, payload = self.queue.get_nowait()
                if kind == "report":
                    self._show_report(payload)
                elif kind == "mark":
                    path, lines = payload
                    self._show_mark(path, lines)
                elif kind == "anchor":
                    distance, radius, anchor_fix, current_fix = payload
                    self._show_anchor(distance, radius, anchor_fix, current_fix)
                elif kind == "error":
                    self._show_error(str(payload))
        except Empty:
            pass
        self.after(150, self._poll_queue)

    def _show_report(self, report: dict[str, object]) -> None:
        self._set_busy(False)
        rows = status_rows(report)
        self.headline.set(status_headline(report))
        self.summary.set(format_panel_summary(report))
        self.gps_summary.set(format_gps_summary(report))
        for item in self.tree.get_children():
            self.tree.delete(item)
        for row in rows:
            marker = "OK" if row.ok else "FAIL"
            self.tree.insert(
                "",
                tk.END,
                values=(marker, f"{row.name}: {row.detail}"),
                tags=("ok" if row.ok else "fail",),
            )
        if self.output_path is not None:
            self.last_report.set(f"Status report: {self.output_path}")
        else:
            self.last_report.set("Status report was not written to disk.")
        self._schedule_refresh()

    def _show_mark(self, path: Path, lines: list[str]) -> None:
        self._set_busy(False)
        self.summary.set(f"Saved position mark: {path}")
        self.last_report.set(" | ".join(lines))
        self._schedule_refresh()

    def _show_anchor(self, distance: float, radius_meters: float, anchor_fix: GPSFix, current_fix: GPSFix) -> None:
        self._set_busy(False)
        summary = format_anchor_check(distance, radius_meters)
        alarm = anchor_alarm_active(distance, radius_meters)
        self.headline.set("NOT READY" if alarm else "READY")
        self.summary.set(summary)
        self.gps_summary.set(f"Anchor {_fix_coordinates(anchor_fix)} | Current {_fix_coordinates(current_fix)}")
        self.last_report.set(f"Anchor {_fix_coordinates(anchor_fix)} | Current {_fix_coordinates(current_fix)}")
        if alarm:
            self.bell()
        self._schedule_refresh()

    def _show_error(self, message: str) -> None:
        self._set_busy(False)
        self.headline.set("NOT READY")
        self.summary.set(message)
        self.gps_summary.set("GPS: unavailable")
        self._schedule_refresh()

    def _set_busy(self, busy: bool) -> None:
        state = tk.DISABLED if busy else tk.NORMAL
        self.refresh_button.configure(state=state)
        self.mark_button.configure(state=state)
        self.mob_button.configure(state=state)
        self.anchor_button.configure(state=state)
        self.anchor_radius_entry.configure(state=state)

    def _schedule_refresh(self) -> None:
        if self.after_id is not None:
            self.after_cancel(self.after_id)
            self.after_id = None
        if self.refresh_seconds > 0:
            self.after_id = self.after(int(self.refresh_seconds * 1000), self.refresh_now)


def _fix_coordinates(fix: GPSFix) -> str:
    return f"{fix.latitude:.6f}, {fix.longitude:.6f}"


def _configured_anchor_radius(config_path: Path) -> float:
    try:
        return read_config(config_path).anchor_radius_meters
    except Exception:
        return 50.0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Show a Tkinter NOAA Navionics readiness panel.")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="config file path")
    parser.add_argument(
        "--output",
        default=str(DEFAULT_STATUS_REPORT),
        help="write the refreshed JSON status report to this path",
    )
    parser.add_argument("--no-output", action="store_true", help="do not write a JSON status report")
    parser.add_argument("--gps-seconds", type=_non_negative_float, default=10.0, help="seconds to wait for a GPS fix")
    parser.add_argument(
        "--refresh-seconds",
        type=_non_negative_float,
        default=60.0,
        help="seconds between automatic refreshes; 0 disables",
    )
    parser.add_argument(
        "--anchor-radius-meters",
        type=_positive_float,
        help="anchor drift radius used by the Anchor Check button",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> None:
    args = build_parser().parse_args(argv)
    output_path = None if args.no_output else Path(args.output)
    app = StatusApp(
        config_path=Path(args.config),
        output_path=output_path,
        gps_seconds=args.gps_seconds,
        refresh_seconds=args.refresh_seconds,
        anchor_radius_meters=args.anchor_radius_meters,
    )
    app.mainloop()


if __name__ == "__main__":  # pragma: no cover
    main()
