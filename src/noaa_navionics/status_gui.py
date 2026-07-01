from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from queue import Empty, Queue
from threading import Thread
from typing import Optional
import argparse
import math
import tkinter as tk
from tkinter import ttk

from .config import DEFAULT_CONFIG_PATH, read_config
from .gps import GPSFix, distance_meters, gpx_position_mark_path, mean_longitude_degrees, write_available_gpx_position_mark
from .gui import format_gps_fix, read_configured_gps_fix, read_configured_gps_fixes
from .report import (
    CORE_READINESS_CHECKS,
    CORE_SERVICE_CHECKS,
    GPSD_READINESS_CHECKS,
    GPSD_SERVICE_CHECKS,
    SERIAL_READINESS_CHECKS,
    build_status_report,
    status_report_is_ready,
    status_report_validation_failures,
    write_status_report,
)


DEFAULT_STATUS_REPORT = Path("~/.cache/noaa-navionics/status.json").expanduser()
ANCHOR_WATCH_STOP_CONFIRM_SECONDS = 8.0


@dataclass(frozen=True)
class StatusRow:
    name: str
    ok: bool
    detail: str


def status_headline(report: dict[str, object]) -> str:
    return "READY" if status_report_is_ready(report) and count_failures(status_rows(report)) == 0 else "NOT READY"


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
    for failure in status_report_validation_failures(report):
        rows.append(StatusRow(failure.name, False, failure.detail))
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


def write_current_position_mark(
    config_path: Path,
    *,
    gps_seconds: float = 10.0,
    mob: bool = False,
    max_fix_age_seconds: float = 300.0,
    future_tolerance_seconds: float = 0.0,
) -> tuple[Path, GPSFix]:
    app_config = read_config(config_path)
    fix = read_configured_gps_fix(app_config, gps_seconds=gps_seconds)
    freshness_failure = _position_mark_freshness_failure(
        fix,
        max_fix_age_seconds=max_fix_age_seconds,
        future_tolerance_seconds=future_tolerance_seconds,
    )
    if freshness_failure:
        raise ValueError(f"position mark requires a fresh GPS fix: {freshness_failure}")
    path = gpx_position_mark_path(app_config.track_output, fix.timestamp, prefix="mob" if mob else "mark")
    name = "MOB" if mob else "Position mark"
    description = "Man overboard position mark" if mob else ""
    return write_available_gpx_position_mark(path, fix, name=name, description=description), fix


def _position_mark_freshness_failure(
    fix: GPSFix,
    *,
    max_fix_age_seconds: float,
    future_tolerance_seconds: float,
) -> str:
    return _gps_fix_freshness_failure(
        fix,
        max_fix_age_seconds=max_fix_age_seconds,
        future_tolerance_seconds=future_tolerance_seconds,
    )


def _gps_fix_freshness_failure(
    fix: GPSFix,
    *,
    max_fix_age_seconds: float,
    future_tolerance_seconds: float,
) -> str:
    if fix.timestamp is None:
        return "fix has no timestamp"
    timestamp = fix.timestamp
    if timestamp.tzinfo is None:
        timestamp = timestamp.replace(tzinfo=timezone.utc)
    age_seconds = (datetime.now(timezone.utc) - timestamp.astimezone(timezone.utc)).total_seconds()
    if age_seconds > max_fix_age_seconds:
        return f"fix timestamp is stale ({age_seconds:.0f}s old)"
    if age_seconds < -future_tolerance_seconds:
        return f"fix timestamp is in the future by {-age_seconds:.0f}s"
    return ""


def check_anchor_drift(
    config_path: Path,
    *,
    gps_seconds: float = 10.0,
    radius_meters: float = 50.0,
    anchor_samples: int = 1,
    max_fix_age_seconds: float = 300.0,
    future_tolerance_seconds: float = 0.0,
) -> tuple[float, float, GPSFix, GPSFix]:
    if not math.isfinite(radius_meters) or radius_meters <= 0:
        raise ValueError("anchor radius must be greater than 0")
    if anchor_samples < 1:
        raise ValueError("anchor samples must be at least 1")
    app_config = read_config(config_path)
    fixes = read_configured_gps_fixes(app_config, count=anchor_samples + 1, gps_seconds=gps_seconds)
    for index, fix in enumerate(fixes, start=1):
        freshness_failure = _gps_fix_freshness_failure(
            fix,
            max_fix_age_seconds=max_fix_age_seconds,
            future_tolerance_seconds=future_tolerance_seconds,
        )
        if freshness_failure:
            raise ValueError(f"anchor check requires fresh GPS fix {index}: {freshness_failure}")
    anchor_fixes = fixes[:anchor_samples]
    current_fix = fixes[-1]
    anchor_fix = _average_anchor_fix(anchor_fixes)
    distance = distance_meters(anchor_fix.latitude, anchor_fix.longitude, current_fix.latitude, current_fix.longitude)
    return distance, radius_meters, anchor_fix, current_fix


def capture_anchor_watch_fix(
    config_path: Path,
    *,
    gps_seconds: float = 10.0,
    anchor_samples: int = 1,
    max_fix_age_seconds: float = 300.0,
    future_tolerance_seconds: float = 0.0,
) -> GPSFix:
    if anchor_samples < 1:
        raise ValueError("anchor samples must be at least 1")
    app_config = read_config(config_path)
    fixes = read_configured_gps_fixes(app_config, count=anchor_samples, gps_seconds=gps_seconds)
    for index, fix in enumerate(fixes, start=1):
        freshness_failure = _gps_fix_freshness_failure(
            fix,
            max_fix_age_seconds=max_fix_age_seconds,
            future_tolerance_seconds=future_tolerance_seconds,
        )
        if freshness_failure:
            raise ValueError(f"anchor watch requires fresh GPS fix {index}: {freshness_failure}")
    return _average_anchor_fix(fixes)


def check_anchor_watch_drift(
    config_path: Path,
    anchor_fix: GPSFix,
    *,
    gps_seconds: float = 10.0,
    radius_meters: float = 50.0,
    max_fix_age_seconds: float = 300.0,
    future_tolerance_seconds: float = 0.0,
) -> tuple[float, float, GPSFix, GPSFix]:
    if not math.isfinite(radius_meters) or radius_meters <= 0:
        raise ValueError("anchor radius must be greater than 0")
    if anchor_fix.latitude is None or anchor_fix.longitude is None:
        raise ValueError("anchor watch fix must include coordinates")
    app_config = read_config(config_path)
    current_fix = read_configured_gps_fix(app_config, gps_seconds=gps_seconds)
    freshness_failure = _gps_fix_freshness_failure(
        current_fix,
        max_fix_age_seconds=max_fix_age_seconds,
        future_tolerance_seconds=future_tolerance_seconds,
    )
    if freshness_failure:
        raise ValueError(f"anchor watch requires fresh current GPS fix: {freshness_failure}")
    distance = distance_meters(anchor_fix.latitude, anchor_fix.longitude, current_fix.latitude, current_fix.longitude)
    return distance, radius_meters, anchor_fix, current_fix


def _average_anchor_fix(fixes: list[GPSFix]) -> GPSFix:
    if len(fixes) == 1:
        return fixes[0]
    latitudes = [fix.latitude for fix in fixes if fix.latitude is not None]
    longitudes = [fix.longitude for fix in fixes if fix.longitude is not None]
    if len(latitudes) != len(fixes) or len(longitudes) != len(fixes):
        raise ValueError("anchor samples must include coordinates")
    satellites = [fix.satellites for fix in fixes if fix.satellites is not None]
    hdops = [fix.hdop for fix in fixes if fix.hdop is not None]
    return GPSFix(
        timestamp=fixes[-1].timestamp,
        latitude=sum(latitudes) / len(latitudes),
        longitude=mean_longitude_degrees(longitudes),
        satellites=min(satellites) if satellites else None,
        hdop=max(hdops) if hdops else None,
    )


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


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
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
        action_gps_seconds: Optional[float] = None,
        refresh_seconds: float = 60.0,
        anchor_watch_seconds: float = 30.0,
        anchor_radius_meters: Optional[float] = None,
        anchor_samples: int = 1,
    ) -> None:
        super().__init__()
        self.title("NOAA Navionics Status")
        self.geometry("780x560")
        self.minsize(680, 460)

        self.config_path = Path(config_path).expanduser()
        self.output_path = Path(output_path).expanduser() if output_path is not None else None
        self.gps_seconds = gps_seconds
        self.action_gps_seconds = gps_seconds if action_gps_seconds is None else action_gps_seconds
        self.refresh_seconds = refresh_seconds
        self.anchor_watch_seconds = anchor_watch_seconds
        self.anchor_watch_fix: Optional[GPSFix] = None
        self.anchor_watch_radius_meters: Optional[float] = None
        self.anchor_watch_after_id: Optional[str] = None
        self.anchor_watch_stop_confirm_after_id: Optional[str] = None
        self.anchor_watch_alarm_active = False
        self.anchor_watch_alarm_summary: Optional[str] = None
        self.anchor_watch_alarm_detail: Optional[str] = None
        self.anchor_watch_status_summary: Optional[str] = None
        self.anchor_watch_status_detail: Optional[str] = None
        self.last_status_report_ready = False
        if anchor_radius_meters is None:
            anchor_radius_meters = _configured_anchor_radius(self.config_path)
        self.anchor_radius = tk.StringVar(value=f"{anchor_radius_meters:g}")
        self.anchor_samples = tk.StringVar(value=str(anchor_samples))
        self.queue: Queue = Queue()
        self.worker: Optional[Thread] = None
        self.after_id: Optional[str] = None
        self.poll_after_id: Optional[str] = None
        self._closed = False

        self.headline = tk.StringVar(value="Checking...")
        self.summary = tk.StringVar(value="Waiting for the first status refresh.")
        self.gps_summary = tk.StringVar(value="GPS: waiting for status refresh.")
        self.last_report = tk.StringVar(value="")
        self._build()
        self.protocol("WM_DELETE_WINDOW", self.close)
        self._set_busy(False)
        self.after_id = self.after(100, self.refresh_now)
        self.poll_after_id = self.after(150, self._poll_queue)

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
        ttk.Label(buttons, text="Samples").pack(side=tk.LEFT, padx=(10, 0))
        self.anchor_samples_entry = ttk.Entry(buttons, textvariable=self.anchor_samples, width=4)
        self.anchor_samples_entry.pack(side=tk.LEFT, padx=(6, 0))
        self.anchor_button = ttk.Button(buttons, text="Anchor Check", command=self.anchor_check)
        self.anchor_button.pack(side=tk.LEFT, padx=(10, 0))
        self.anchor_watch_button = ttk.Button(buttons, text="Start Watch", command=self.start_anchor_watch)
        self.anchor_watch_button.pack(side=tk.LEFT, padx=(10, 0))
        self.stop_anchor_watch_button = ttk.Button(buttons, text="Stop Watch", command=self.stop_anchor_watch)
        self.stop_anchor_watch_button.pack(side=tk.LEFT, padx=(10, 0))
        ttk.Button(buttons, text="Quit", command=self.close).pack(side=tk.LEFT, padx=(10, 0))
        ttk.Label(root, textvariable=self.last_report).grid(row=5, column=0, sticky=tk.W, pady=(8, 0))

    def close(self) -> None:
        self._closed = True
        self._cancel_after_callback("after_id")
        self._cancel_after_callback("poll_after_id")
        self._cancel_after_callback("anchor_watch_after_id")
        self._cancel_after_callback("anchor_watch_stop_confirm_after_id")
        self.destroy()

    def refresh_now(self) -> None:
        self.after_id = None
        if getattr(self, "_closed", False):
            return
        if self.worker is not None and self.worker.is_alive():
            return
        self._set_busy(True)
        self.summary.set("Refreshing status...")
        self.worker = Thread(target=self._refresh_worker, daemon=True)
        self.worker.start()

    def mark_position(self, *, mob: bool = False) -> None:
        if getattr(self, "_closed", False):
            return
        if self.worker is not None and self.worker.is_alive():
            return
        self._set_busy(True)
        self.summary.set("Recording current GPS position...")
        self.worker = Thread(target=self._mark_worker, kwargs={"mob": mob}, daemon=True)
        self.worker.start()

    def anchor_check(self) -> None:
        if getattr(self, "_closed", False):
            return
        if self.worker is not None and self.worker.is_alive():
            return
        try:
            radius_meters = _positive_float(self.anchor_radius.get())
        except argparse.ArgumentTypeError as exc:
            self._show_error(f"Anchor radius {exc}")
            return
        try:
            anchor_samples = _positive_int(self.anchor_samples.get())
        except argparse.ArgumentTypeError as exc:
            self._show_error(f"Anchor samples {exc}")
            return
        self._set_busy(True)
        self.summary.set("Checking anchor distance...")
        self.worker = Thread(
            target=self._anchor_worker,
            kwargs={"radius_meters": radius_meters, "anchor_samples": anchor_samples},
            daemon=True,
        )
        self.worker.start()

    def start_anchor_watch(self) -> None:
        if getattr(self, "_closed", False):
            return
        if self.worker is not None and self.worker.is_alive():
            return
        if self.anchor_watch_fix is not None:
            self._show_anchor_watch_already_active()
            return
        try:
            radius_meters = _positive_float(self.anchor_radius.get())
        except argparse.ArgumentTypeError as exc:
            self._show_error(f"Anchor radius {exc}")
            return
        try:
            anchor_samples = _positive_int(self.anchor_samples.get())
        except argparse.ArgumentTypeError as exc:
            self._show_error(f"Anchor samples {exc}")
            return
        self._set_busy(True)
        self.summary.set("Setting anchor watch...")
        self.worker = Thread(
            target=self._set_anchor_watch_worker,
            kwargs={"radius_meters": radius_meters, "anchor_samples": anchor_samples},
            daemon=True,
        )
        self.worker.start()

    def stop_anchor_watch(self) -> None:
        if getattr(self, "_closed", False):
            return
        if self.anchor_watch_fix is None:
            self._cancel_anchor_watch_stop_confirmation()
            self._set_busy(False)
            return
        if self.anchor_watch_stop_confirm_after_id is None:
            self._show_anchor_watch_stop_confirmation()
            return
        self._cancel_anchor_watch_stop_confirmation()
        self.anchor_watch_fix = None
        self.anchor_watch_radius_meters = None
        self.anchor_watch_alarm_active = False
        self.anchor_watch_alarm_summary = None
        self.anchor_watch_alarm_detail = None
        self.anchor_watch_status_summary = None
        self.anchor_watch_status_detail = None
        if self.anchor_watch_after_id is not None:
            self.after_cancel(self.anchor_watch_after_id)
            self.anchor_watch_after_id = None
        self.summary.set("Anchor watch stopped.")
        self._set_busy(False)
        self._schedule_refresh()

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
            path, fix = write_current_position_mark(self.config_path, gps_seconds=self.action_gps_seconds, mob=mob)
            self.queue.put(("mark", (path, format_gps_fix(fix))))
        except Exception as exc:  # pragma: no cover - UI path
            self.queue.put(("error", str(exc)))

    def _anchor_worker(self, *, radius_meters: float, anchor_samples: int) -> None:
        try:
            distance, radius, anchor_fix, current_fix = check_anchor_drift(
                self.config_path,
                gps_seconds=self.action_gps_seconds,
                radius_meters=radius_meters,
                anchor_samples=anchor_samples,
            )
            self.queue.put(("anchor", (distance, radius, anchor_fix, current_fix)))
        except Exception as exc:  # pragma: no cover - UI path
            self.queue.put(("error", str(exc)))

    def _set_anchor_watch_worker(self, *, radius_meters: float, anchor_samples: int) -> None:
        try:
            anchor_fix = capture_anchor_watch_fix(
                self.config_path,
                gps_seconds=self.action_gps_seconds,
                anchor_samples=anchor_samples,
            )
            self.queue.put(("anchor_watch_set", (anchor_fix, radius_meters)))
        except Exception as exc:  # pragma: no cover - UI path
            self.queue.put(("error", str(exc)))

    def _anchor_watch_worker(self, *, radius_meters: float) -> None:
        anchor_watch_fix = self.anchor_watch_fix
        try:
            if anchor_watch_fix is None:
                return
            distance, radius, anchor_fix, current_fix = check_anchor_watch_drift(
                self.config_path,
                anchor_watch_fix,
                gps_seconds=self.action_gps_seconds,
                radius_meters=radius_meters,
            )
            self.queue.put(("anchor_watch", (distance, radius, anchor_fix, current_fix)))
        except Exception as exc:  # pragma: no cover - UI path
            self.queue.put(("anchor_watch_error", (anchor_watch_fix, str(exc))))

    def _poll_queue(self) -> None:
        self.poll_after_id = None
        if getattr(self, "_closed", False):
            return
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
                elif kind == "anchor_watch_set":
                    anchor_fix, radius = payload
                    self._show_anchor_watch_set(anchor_fix, radius)
                elif kind == "anchor_watch":
                    distance, radius, anchor_fix, current_fix = payload
                    self._show_anchor_watch(distance, radius, anchor_fix, current_fix)
                elif kind == "anchor_watch_error":
                    anchor_fix, message = payload
                    self._show_anchor_watch_error(anchor_fix, str(message))
                elif kind == "error":
                    self._show_error(str(payload))
        except Empty:
            pass
        if not getattr(self, "_closed", False):
            self.poll_after_id = self.after(150, self._poll_queue)

    def _show_report(self, report: dict[str, object]) -> None:
        self._set_busy(False)
        rows = status_rows(report)
        headline = status_headline(report)
        self.last_status_report_ready = headline == "READY"
        self.headline.set(headline)
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
        alarm_visible = self._show_anchor_watch_alarm_if_active()
        if (
            not alarm_visible
            and status_report_is_ready(report)
            and self.anchor_watch_fix is not None
            and self.anchor_watch_status_summary is not None
        ):
            self.summary.set(self.anchor_watch_status_summary)
            if self.anchor_watch_status_detail is not None:
                self.gps_summary.set(self.anchor_watch_status_detail)
        self._schedule_refresh()

    def _show_mark(self, path: Path, lines: list[str]) -> None:
        self._set_busy(False)
        self.summary.set(f"Saved position mark: {path}")
        self.last_report.set(" | ".join(lines))
        self._show_anchor_watch_alarm_if_active()
        self._schedule_refresh()

    def _show_anchor(self, distance: float, radius_meters: float, anchor_fix: GPSFix, current_fix: GPSFix) -> None:
        self._set_busy(False)
        summary = format_anchor_check(distance, radius_meters)
        alarm = anchor_alarm_active(distance, radius_meters)
        self.headline.set(StatusApp._action_headline(self, alarm=alarm))
        self.summary.set(summary)
        details = f"Anchor {_format_anchor_fix_detail(anchor_fix)} | Current {_format_anchor_fix_detail(current_fix)}"
        self.gps_summary.set(details)
        self.last_report.set(details)
        if alarm:
            self.bell()
        self._show_anchor_watch_alarm_if_active()
        self._schedule_refresh()

    def _show_anchor_watch_set(self, anchor_fix: GPSFix, radius_meters: float) -> None:
        self.anchor_watch_fix = anchor_fix
        self.anchor_watch_radius_meters = radius_meters
        self.anchor_watch_alarm_active = False
        self.anchor_watch_alarm_summary = None
        self.anchor_watch_alarm_detail = None
        self._set_busy(False)
        self.anchor_radius.set(f"{radius_meters:g}")
        self.headline.set(StatusApp._action_headline(self))
        details = f"Anchor watch set: {_format_anchor_fix_detail(anchor_fix)}"
        watch_summary = f"Anchor watch armed; radius {radius_meters:g} m"
        self.anchor_watch_status_summary = watch_summary
        self.anchor_watch_status_detail = details
        self.summary.set(watch_summary)
        self.gps_summary.set(details)
        self.last_report.set(details)
        self._schedule_anchor_watch()
        self._schedule_refresh()

    def _show_anchor_watch(self, distance: float, radius_meters: float, anchor_fix: GPSFix, current_fix: GPSFix) -> None:
        if self.anchor_watch_fix is not anchor_fix:
            self._set_busy(False)
            self.last_report.set("Ignored stale anchor watch result; watch was stopped or reset.")
            self._schedule_refresh()
            return
        self._set_busy(False)
        summary = format_anchor_check(distance, radius_meters)
        alarm = anchor_alarm_active(distance, radius_meters)
        self.headline.set(StatusApp._action_headline(self, alarm=alarm))
        watch_summary = f"Anchor watch: {summary}"
        self.summary.set(watch_summary)
        details = f"Anchor {_format_anchor_fix_detail(anchor_fix)} | Current {_format_anchor_fix_detail(current_fix)}"
        self.gps_summary.set(details)
        self.last_report.set(details)
        self.anchor_watch_status_summary = watch_summary
        self.anchor_watch_status_detail = details
        self.anchor_watch_alarm_active = alarm
        self.anchor_watch_alarm_summary = watch_summary if alarm else None
        self.anchor_watch_alarm_detail = details if alarm else None
        if alarm:
            self.bell()
        self._schedule_anchor_watch()
        self._schedule_refresh()

    def _show_anchor_watch_error(self, anchor_fix: Optional[GPSFix], message: str) -> None:
        if anchor_fix is not None and self.anchor_watch_fix is not anchor_fix:
            self._set_busy(False)
            self.last_report.set("Ignored stale anchor watch error; watch was stopped or reset.")
            self._schedule_refresh()
            return
        self._show_error(message)

    def _show_anchor_watch_already_active(self) -> None:
        self._set_busy(False)
        self.last_report.set("Anchor watch is already active; stop it before starting a new watch.")
        if self._show_anchor_watch_alarm_if_active():
            return
        if self.anchor_watch_status_summary is not None:
            self.summary.set(self.anchor_watch_status_summary)
            if self.anchor_watch_status_detail is not None:
                self.gps_summary.set(self.anchor_watch_status_detail)

    def _show_error(self, message: str) -> None:
        self._set_busy(False)
        self.last_report.set(f"Error: {message}")
        alarm_visible = self._show_anchor_watch_alarm_if_active()
        if alarm_visible:
            self._schedule_anchor_watch()
            self._schedule_refresh()
            return
        self.headline.set("NOT READY")
        self.summary.set(message)
        self.gps_summary.set("GPS: unavailable")
        self._schedule_anchor_watch()
        self._schedule_refresh()

    def _show_anchor_watch_alarm_if_active(self) -> bool:
        if not self.anchor_watch_alarm_active or self.anchor_watch_alarm_summary is None:
            return False
        self.headline.set("NOT READY")
        self.summary.set(self.anchor_watch_alarm_summary)
        if self.anchor_watch_alarm_detail is not None:
            self.gps_summary.set(self.anchor_watch_alarm_detail)
        return True

    def _action_headline(self, *, alarm: bool = False) -> str:
        if alarm or not getattr(self, "last_status_report_ready", False):
            return "NOT READY"
        return "READY"

    def _show_anchor_watch_stop_confirmation(self) -> None:
        seconds = ANCHOR_WATCH_STOP_CONFIRM_SECONDS
        message = f"Press Stop Watch again within {seconds:g}s to stop anchor watch."
        self.anchor_watch_stop_confirm_after_id = self.after(
            int(seconds * 1000),
            self._expire_anchor_watch_stop_confirmation,
        )
        if not self._show_anchor_watch_alarm_if_active():
            self.summary.set(message)
        self.last_report.set(message)

    def _expire_anchor_watch_stop_confirmation(self) -> None:
        self.anchor_watch_stop_confirm_after_id = None
        if self.anchor_watch_fix is None:
            return
        self.last_report.set("Anchor watch stop confirmation expired.")
        if self._show_anchor_watch_alarm_if_active():
            return
        if self.anchor_watch_status_summary is not None:
            self.summary.set(self.anchor_watch_status_summary)
            if self.anchor_watch_status_detail is not None:
                self.gps_summary.set(self.anchor_watch_status_detail)

    def _cancel_anchor_watch_stop_confirmation(self) -> None:
        StatusApp._cancel_after_callback(self, "anchor_watch_stop_confirm_after_id")

    def _cancel_after_callback(self, attr: str) -> None:
        after_id = getattr(self, attr, None)
        if after_id is None:
            return
        try:
            self.after_cancel(after_id)
        except tk.TclError:
            pass
        setattr(self, attr, None)

    def _set_busy(self, busy: bool) -> None:
        state = tk.DISABLED if busy else tk.NORMAL
        self.refresh_button.configure(state=state)
        self.mark_button.configure(state=state)
        self.mob_button.configure(state=state)
        self.anchor_button.configure(state=state)
        self.anchor_watch_button.configure(
            state=tk.DISABLED if busy or self.anchor_watch_fix is not None else tk.NORMAL
        )
        self.stop_anchor_watch_button.configure(
            state=tk.DISABLED if self.anchor_watch_fix is None else tk.NORMAL
        )
        settings_state = tk.DISABLED if busy or self.anchor_watch_fix is not None else tk.NORMAL
        self.anchor_radius_entry.configure(state=settings_state)
        self.anchor_samples_entry.configure(state=settings_state)

    def _schedule_refresh(self) -> None:
        if getattr(self, "_closed", False):
            return
        if self.after_id is not None:
            self.after_cancel(self.after_id)
            self.after_id = None
        if self.refresh_seconds > 0:
            self.after_id = self.after(int(self.refresh_seconds * 1000), self.refresh_now)

    def _schedule_anchor_watch(self) -> None:
        if getattr(self, "_closed", False):
            return
        if self.anchor_watch_after_id is not None:
            self.after_cancel(self.anchor_watch_after_id)
            self.anchor_watch_after_id = None
        if self.anchor_watch_fix is None or self.anchor_watch_seconds <= 0:
            return
        self.anchor_watch_after_id = self.after(int(self.anchor_watch_seconds * 1000), self._run_anchor_watch)

    def _run_anchor_watch(self) -> None:
        self.anchor_watch_after_id = None
        if getattr(self, "_closed", False):
            return
        if self.anchor_watch_fix is None:
            return
        if self.worker is not None and self.worker.is_alive():
            self._schedule_anchor_watch()
            return
        radius_meters = self.anchor_watch_radius_meters
        if radius_meters is None:
            try:
                radius_meters = _positive_float(self.anchor_radius.get())
            except argparse.ArgumentTypeError as exc:
                self._show_error(f"Anchor radius {exc}")
                return
        self._set_busy(True)
        self.summary.set("Checking anchor watch...")
        self.worker = Thread(target=self._anchor_watch_worker, kwargs={"radius_meters": radius_meters}, daemon=True)
        self.worker.start()


def _fix_coordinates(fix: GPSFix) -> str:
    return f"{fix.latitude:.6f}, {fix.longitude:.6f}"


def _format_anchor_fix_detail(fix: GPSFix) -> str:
    pieces = [_fix_coordinates(fix)]
    if fix.timestamp is not None:
        pieces.append(fix.timestamp.isoformat().replace("+00:00", "Z"))
    if fix.satellites is not None:
        pieces.append(f"{fix.satellites} sats")
    if fix.hdop is not None:
        pieces.append(f"HDOP {fix.hdop:g}")
    return "; ".join(pieces)


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
        "--action-gps-seconds",
        type=_non_negative_float,
        help="seconds to wait for Mark, MOB, and Anchor Check GPS fixes; defaults to --gps-seconds",
    )
    parser.add_argument(
        "--refresh-seconds",
        type=_non_negative_float,
        default=60.0,
        help="seconds between automatic refreshes; 0 disables",
    )
    parser.add_argument(
        "--anchor-watch-seconds",
        type=_non_negative_float,
        default=30.0,
        help="seconds between automatic anchor-watch checks; 0 disables repeated checks",
    )
    parser.add_argument(
        "--anchor-radius-meters",
        type=_positive_float,
        help="anchor drift radius used by the Anchor Check button",
    )
    parser.add_argument(
        "--anchor-samples",
        type=_positive_int,
        default=1,
        help="quality GPS fixes to average for the Anchor Check button",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> None:
    args = build_parser().parse_args(argv)
    output_path = None if args.no_output else Path(args.output)
    app = StatusApp(
        config_path=Path(args.config),
        output_path=output_path,
        gps_seconds=args.gps_seconds,
        action_gps_seconds=args.action_gps_seconds,
        refresh_seconds=args.refresh_seconds,
        anchor_watch_seconds=args.anchor_watch_seconds,
        anchor_radius_meters=args.anchor_radius_meters,
        anchor_samples=args.anchor_samples,
    )
    app.mainloop()


if __name__ == "__main__":  # pragma: no cover
    main()
