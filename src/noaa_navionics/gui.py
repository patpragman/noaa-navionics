from __future__ import annotations

from pathlib import Path
from queue import Empty, Queue
from threading import Thread
from typing import Optional
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from .config import DEFAULT_CONFIG_PATH, AppConfig, package_kwargs, read_config
from .downloader import download_package, package_for
from .health import check_chart_package, check_disk_space, run_preflight
from .opencpn import configure_chart_directory, configure_gpsd_connection, opencpn_running
from .report import build_status_report, format_status_text, write_status_report


DEFAULT_STATUS_REPORT = Path("~/.cache/noaa-navionics/status.json").expanduser()
PACKAGE_KIND_OPTIONS = ("state", "cgd", "region", "chart", "all")
PACKAGE_KINDS = set(PACKAGE_KIND_OPTIONS)
DEFAULT_MIN_FREE_GB = 2.0


def run_configured_preflight(
    app_config: AppConfig,
    *,
    gpsd_enabled: Optional[bool] = None,
    gps_device: Optional[str] = None,
    gps_seconds: float = 10.0,
):
    use_gpsd = app_config.gps_mode == "gpsd" if gpsd_enabled is None else gpsd_enabled
    serial_device = None if use_gpsd else (gps_device or app_config.gps_device)
    return run_preflight(
        chart_dir=app_config.chart_output,
        chart_package=app_config.chart_package,
        chart_value=app_config.chart_value,
        gpsd=use_gpsd,
        gpsd_host=app_config.gpsd_host,
        gpsd_port=app_config.gpsd_port,
        gps_device=app_config.gps_device if use_gpsd else serial_device,
        gps_baud=app_config.gps_baud,
        gps_seconds=gps_seconds,
        max_chart_age_days=app_config.max_chart_age_days,
        min_free_gb=app_config.min_free_gb,
        keep_zip=app_config.keep_zip,
        track_output=app_config.track_output,
    )


def sync_configured_charts(app_config: AppConfig, *, progress=None, retries: int = 3, retry_delay: float = 10.0):
    package_check = check_chart_package(app_config.chart_package, app_config.chart_value)
    if not package_check.ok:
        raise ValueError(f"sync requires a complete onboard chart package: {package_check.detail}")
    disk_check = check_disk_space(app_config.chart_output, min_free_gb=app_config.min_free_gb)
    if not disk_check.ok:
        raise RuntimeError(f"sync requires writable chart storage with enough free space: {disk_check.detail}")
    app_config.chart_output.mkdir(parents=True, exist_ok=True)
    disk_check = check_disk_space(app_config.chart_output, min_free_gb=app_config.min_free_gb)
    if not disk_check.ok:
        raise RuntimeError(f"sync requires writable chart storage with enough free space: {disk_check.detail}")
    package = package_for(**package_kwargs(app_config))
    return download_package(
        package,
        app_config.chart_output,
        extract=app_config.extract,
        keep_zip=app_config.keep_zip,
        force=app_config.force,
        retries=retries,
        retry_delay=retry_delay,
        progress=progress,
    )


def download_selected_package(
    package,
    output: Path,
    *,
    extract: bool,
    keep_zip: bool,
    force: bool,
    progress=None,
    min_free_gb: float = DEFAULT_MIN_FREE_GB,
):
    output = Path(output).expanduser()
    disk_check = check_disk_space(output, min_free_gb=min_free_gb)
    if not disk_check.ok:
        raise RuntimeError(f"download requires writable chart storage with enough free space: {disk_check.detail}")
    output.mkdir(parents=True, exist_ok=True)
    disk_check = check_disk_space(output, min_free_gb=min_free_gb)
    if not disk_check.ok:
        raise RuntimeError(f"download requires writable chart storage with enough free space: {disk_check.detail}")
    return download_package(
        package,
        output,
        extract=extract,
        keep_zip=keep_zip,
        force=force,
        progress=progress,
    )


class DownloaderApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("NOAA Navionics")
        self.geometry("720x520")
        self.minsize(640, 440)
        self.queue: Queue = Queue()
        self.worker: Optional[Thread] = None
        self.action_buttons: list[ttk.Button] = []

        self.kind = tk.StringVar(value="state")
        self.value = tk.StringVar(value="AK")
        self.output = tk.StringVar(value=str(Path("~/charts/noaa-enc").expanduser()))
        self.config_path = tk.StringVar(value=str(DEFAULT_CONFIG_PATH.expanduser()))
        self.status_report = tk.StringVar(value=str(DEFAULT_STATUS_REPORT))
        self.extract = tk.BooleanVar(value=True)
        self.keep_zip = tk.BooleanVar(value=True)
        self.force = tk.BooleanVar(value=False)
        self.status = tk.StringVar(value="Ready")
        self.gps_device = tk.StringVar(value="/dev/serial/by-id/YOUR_GPS_DEVICE")
        self.use_gpsd = tk.BooleanVar(value=True)

        self._build()
        self.after(150, self._poll_queue)

    def _build(self) -> None:
        root = ttk.Frame(self, padding=16)
        root.pack(fill=tk.BOTH, expand=True)
        root.columnconfigure(1, weight=1)
        root.rowconfigure(8, weight=1)

        ttk.Label(root, text="Package").grid(row=0, column=0, sticky=tk.W, pady=(0, 8))
        kind = ttk.Combobox(
            root,
            textvariable=self.kind,
            values=PACKAGE_KIND_OPTIONS,
            state="readonly",
            width=14,
        )
        kind.grid(row=0, column=1, sticky=tk.W, pady=(0, 8))
        kind.bind("<<ComboboxSelected>>", self._kind_changed)

        ttk.Label(root, text="Value").grid(row=1, column=0, sticky=tk.W, pady=(0, 8))
        value_row = ttk.Frame(root)
        value_row.grid(row=1, column=1, sticky=tk.EW, pady=(0, 8))
        value_row.columnconfigure(0, weight=1)
        self.value_entry = ttk.Entry(value_row, textvariable=self.value)
        self.value_entry.grid(row=0, column=0, sticky=tk.EW)
        self.hint = ttk.Label(value_row, text="Example: AK")
        self.hint.grid(row=0, column=1, sticky=tk.W, padx=(10, 0))

        ttk.Label(root, text="Output").grid(row=2, column=0, sticky=tk.W, pady=(0, 8))
        output_row = ttk.Frame(root)
        output_row.grid(row=2, column=1, sticky=tk.EW, pady=(0, 8))
        output_row.columnconfigure(0, weight=1)
        ttk.Entry(output_row, textvariable=self.output).grid(row=0, column=0, sticky=tk.EW)
        ttk.Button(output_row, text="Browse", command=self._browse).grid(row=0, column=1, padx=(10, 0))

        options = ttk.Frame(root)
        options.grid(row=3, column=1, sticky=tk.W, pady=(4, 12))
        ttk.Checkbutton(options, text="Extract ZIP", variable=self.extract).grid(row=0, column=0, sticky=tk.W)
        ttk.Checkbutton(options, text="Keep ZIP", variable=self.keep_zip).grid(row=0, column=1, sticky=tk.W, padx=(16, 0))
        ttk.Checkbutton(options, text="Overwrite", variable=self.force).grid(row=0, column=2, sticky=tk.W, padx=(16, 0))

        ttk.Label(root, text="Config").grid(row=4, column=0, sticky=tk.W, pady=(0, 8))
        config_row = ttk.Frame(root)
        config_row.grid(row=4, column=1, sticky=tk.EW, pady=(0, 8))
        config_row.columnconfigure(0, weight=1)
        ttk.Entry(config_row, textvariable=self.config_path).grid(row=0, column=0, sticky=tk.EW)
        self.load_config_button = ttk.Button(config_row, text="Load", command=self._load_config)
        self.load_config_button.grid(row=0, column=1, padx=(10, 0))

        gps_row = ttk.Frame(root)
        gps_row.grid(row=5, column=1, sticky=tk.EW, pady=(0, 12))
        gps_row.columnconfigure(1, weight=1)
        ttk.Label(gps_row, text="GPS").grid(row=0, column=0, sticky=tk.W)
        ttk.Entry(gps_row, textvariable=self.gps_device, width=18).grid(row=0, column=1, sticky=tk.W, padx=(10, 0))
        ttk.Checkbutton(gps_row, text="GPSD", variable=self.use_gpsd).grid(row=0, column=2, sticky=tk.W, padx=(10, 0))
        self.preflight_button = ttk.Button(gps_row, text="Preflight", command=self._start_preflight)
        self.preflight_button.grid(row=0, column=3, padx=(10, 0))

        action_row = ttk.Frame(root)
        action_row.grid(row=6, column=1, sticky=tk.EW, pady=(0, 12))
        self.download_button = ttk.Button(action_row, text="Download", command=self._start_download)
        self.download_button.pack(side=tk.LEFT)
        self.sync_config_button = ttk.Button(action_row, text="Sync", command=self._start_config_sync)
        self.sync_config_button.pack(side=tk.LEFT, padx=(10, 0))
        self.status_report_button = ttk.Button(action_row, text="Status", command=self._start_status_report)
        self.status_report_button.pack(side=tk.LEFT, padx=(10, 0))
        self.opencpn_button = ttk.Button(action_row, text="OpenCPN", command=self._start_opencpn_config)
        self.opencpn_button.pack(side=tk.LEFT, padx=(10, 0))
        ttk.Button(action_row, text="Quit", command=self.destroy).pack(side=tk.LEFT, padx=(10, 0))
        self.action_buttons.extend(
            [
                self.load_config_button,
                self.preflight_button,
                self.download_button,
                self.sync_config_button,
                self.status_report_button,
                self.opencpn_button,
            ]
        )

        self.progress = ttk.Progressbar(root, mode="determinate", maximum=100)
        self.progress.grid(row=7, column=0, columnspan=2, sticky=tk.EW, pady=(0, 8))

        log_frame = ttk.LabelFrame(root, text="Log")
        log_frame.grid(row=8, column=0, columnspan=2, sticky=tk.NSEW)
        log_frame.rowconfigure(0, weight=1)
        log_frame.columnconfigure(0, weight=1)
        self.log = tk.Text(log_frame, height=12, wrap=tk.WORD)
        self.log.grid(row=0, column=0, sticky=tk.NSEW)
        scroll = ttk.Scrollbar(log_frame, orient=tk.VERTICAL, command=self.log.yview)
        scroll.grid(row=0, column=1, sticky=tk.NS)
        self.log.configure(yscrollcommand=scroll.set)

        ttk.Label(root, textvariable=self.status).grid(row=9, column=0, columnspan=2, sticky=tk.W, pady=(8, 0))
        self._kind_changed()

    def _browse(self) -> None:
        selected = filedialog.askdirectory(initialdir=self.output.get() or str(Path.home()))
        if selected:
            self.output.set(selected)

    def _kind_changed(self, event: Optional[object] = None) -> None:
        hints = {
            "state": ("AK", "Example: AK"),
            "cgd": ("17", "Example: 17"),
            "region": ("30", "Example: 30"),
            "chart": ("US5AK3CM", "Example: US5AK3CM"),
            "all": ("", "No value needed"),
        }
        current = self.kind.get()
        default, hint = hints[current]
        if current == "all":
            self.value_entry.configure(state=tk.DISABLED)
            self.value.set("")
        else:
            self.value_entry.configure(state=tk.NORMAL)
            if not self.value.get():
                self.value.set(default)
        self.hint.configure(text=hint)

    def _start_download(self) -> None:
        if self.worker and self.worker.is_alive():
            return

        try:
            package = self._selected_package()
        except Exception as exc:
            messagebox.showerror("Invalid selection", str(exc))
            return

        self.progress.configure(mode="determinate", value=0)
        self._set_busy(True)
        self.status.set(f"Downloading {package.filename}")
        self._log(f"Downloading {package.url}")

        self.worker = Thread(target=self._download_worker, args=(package,), daemon=True)
        self.worker.start()

    def _start_preflight(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        self._set_busy(True)
        self.status.set("Running preflight")
        self._log("Running preflight checks")
        self.worker = Thread(target=self._preflight_worker, daemon=True)
        self.worker.start()

    def _load_config(self) -> None:
        try:
            app_config = read_config(self._config_path())
            if app_config.chart_package not in PACKAGE_KINDS:
                raise ValueError("charts.package must be one of: state, cgd, region, chart, all")
        except Exception as exc:
            messagebox.showerror("Config failed", str(exc))
            return
        self.kind.set(app_config.chart_package)
        self.value.set(app_config.chart_value)
        self.output.set(str(app_config.chart_output))
        self.extract.set(app_config.extract)
        self.keep_zip.set(app_config.keep_zip)
        self.force.set(app_config.force)
        self.gps_device.set(app_config.gps_device)
        self.use_gpsd.set(app_config.gps_mode == "gpsd")
        self._kind_changed()
        self._log(f"Loaded config: {self._config_path()}")
        self.status.set("Config loaded")

    def _start_config_sync(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        self._set_busy(True)
        self.progress.configure(mode="determinate", value=0)
        self.status.set("Syncing configured charts")
        self._log(f"Syncing config: {self._config_path()}")
        self.worker = Thread(target=self._config_sync_worker, daemon=True)
        self.worker.start()

    def _start_status_report(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        self._set_busy(True)
        self.status.set("Writing status report")
        self._log("Writing status report")
        self.worker = Thread(target=self._status_report_worker, daemon=True)
        self.worker.start()

    def _start_opencpn_config(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        self._set_busy(True)
        self.status.set("Configuring OpenCPN")
        self._log("Configuring OpenCPN")
        self.worker = Thread(target=self._opencpn_config_worker, daemon=True)
        self.worker.start()

    def _selected_package(self):
        kind = self.kind.get()
        value = self.value.get().strip()
        return package_for(
            state=value if kind == "state" else None,
            cgd=value if kind == "cgd" else None,
            region=value if kind == "region" else None,
            chart=value if kind == "chart" else None,
            all_charts=kind == "all",
        )

    def _download_worker(self, package) -> None:
        try:
            def progress(done: int, total: Optional[int]) -> None:
                self.queue.put(("progress", (done, total)))

            result = download_selected_package(
                package,
                Path(self.output.get()),
                extract=self.extract.get(),
                keep_zip=self.keep_zip.get(),
                force=self.force.get(),
                progress=progress,
            )
            self.queue.put(("done", result))
        except Exception as exc:
            self.queue.put(("error", exc))

    def _config_sync_worker(self) -> None:
        try:
            app_config = read_config(self._config_path())

            def progress(done: int, total: Optional[int]) -> None:
                self.queue.put(("progress", (done, total)))

            result = sync_configured_charts(app_config, progress=progress)
            self.queue.put(("done", result))
        except Exception as exc:
            self.queue.put(("error", exc))

    def _preflight_worker(self) -> None:
        try:
            app_config = read_config(self._config_path())
            results = run_configured_preflight(
                app_config,
                gpsd_enabled=self.use_gpsd.get(),
                gps_device=self.gps_device.get().strip() or None,
            )
            self.queue.put(("preflight", results))
        except Exception as exc:
            self.queue.put(("error", exc))

    def _status_report_worker(self) -> None:
        try:
            output = Path(self.status_report.get()).expanduser()
            report = build_status_report(config_path=self._config_path(), gps_seconds=10.0)
            write_status_report(report, output)
            self.queue.put(("status-report", (report, output)))
        except Exception as exc:
            self.queue.put(("error", exc))

    def _opencpn_config_worker(self) -> None:
        try:
            if opencpn_running():
                raise RuntimeError("OpenCPN appears to be running; close it before editing its config")
            app_config = read_config(self._config_path())
            chart_result = configure_chart_directory(app_config.chart_output)
            lines = [
                f"OpenCPN config: {chart_result.config_path}",
                f"Charts: {'added' if chart_result.changed else 'already present'} {chart_result.chart_dir}",
            ]
            gpsd_result = None
            if app_config.gps_mode == "gpsd":
                gpsd_result = configure_gpsd_connection(host=app_config.gpsd_host, port=app_config.gpsd_port)
                lines.append(
                    f"GPSD: {'added' if gpsd_result.changed else 'already present'} {gpsd_result.host}:{gpsd_result.port}"
                )
            else:
                lines.append(f"GPSD: skipped (gps.mode={app_config.gps_mode})")
            if chart_result.backup_path:
                lines.append(f"Backup: {chart_result.backup_path}")
            if gpsd_result and gpsd_result.backup_path and gpsd_result.backup_path != chart_result.backup_path:
                lines.append(f"Backup: {gpsd_result.backup_path}")
            self.queue.put(("log-lines", ("OpenCPN configured", lines)))
        except Exception as exc:
            self.queue.put(("error", exc))

    def _poll_queue(self) -> None:
        try:
            while True:
                kind, payload = self.queue.get_nowait()
                if kind == "progress":
                    done, total = payload
                    if total:
                        self.progress.configure(mode="determinate", value=done / total * 100)
                        self.status.set(f"{done:,} / {total:,} bytes")
                    else:
                        self.progress.configure(mode="indeterminate")
                        self.status.set(f"{done:,} bytes")
                elif kind == "done":
                    self._set_busy(False)
                    self.progress.configure(mode="determinate", value=100)
                    result = payload
                    if result.skipped:
                        self._log(f"Already exists: {result.path}")
                    else:
                        self._log(f"Downloaded: {result.path}")
                    if result.extracted_to:
                        self._log(f"Extracted to: {result.extracted_to}")
                    self.status.set("Done")
                elif kind == "preflight":
                    self._set_busy(False)
                    ok = True
                    for result in payload:
                        ok = ok and result.ok
                        mark = "OK" if result.ok else "FAIL"
                        self._log(f"{mark:4} {result.name:10} {result.detail}")
                    self.status.set("Preflight passed" if ok else "Preflight needs attention")
                elif kind == "status-report":
                    self._set_busy(False)
                    report, output = payload
                    self._log(format_status_text(report))
                    self._log(f"Status report: {output}")
                    self.status.set("Status report passed" if report.get("ok") else "Status report needs attention")
                elif kind == "log-lines":
                    self._set_busy(False)
                    status, lines = payload
                    for line in lines:
                        self._log(line)
                    self.status.set(status)
                elif kind == "error":
                    self._set_busy(False)
                    self.status.set("Error")
                    self._log(f"Error: {payload}")
                    messagebox.showerror("Operation failed", str(payload))
        except Empty:
            pass
        self.after(150, self._poll_queue)

    def _config_path(self) -> Path:
        return Path(self.config_path.get()).expanduser()

    def _set_busy(self, busy: bool) -> None:
        state = tk.DISABLED if busy else tk.NORMAL
        for button in self.action_buttons:
            button.configure(state=state)

    def _log(self, message: str) -> None:
        self.log.insert(tk.END, message + "\n")
        self.log.see(tk.END)


def main() -> None:
    app = DownloaderApp()
    app.mainloop()


if __name__ == "__main__":
    main()
