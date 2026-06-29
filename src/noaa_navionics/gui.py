from __future__ import annotations

from pathlib import Path
from queue import Empty, Queue
from threading import Thread
from typing import Optional
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from .downloader import download_package, package_for
from .health import run_preflight


class DownloaderApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("NOAA Navionics")
        self.geometry("720x520")
        self.minsize(640, 440)
        self.queue: Queue = Queue()
        self.worker: Optional[Thread] = None

        self.kind = tk.StringVar(value="state")
        self.value = tk.StringVar(value="AK")
        self.output = tk.StringVar(value=str(Path("~/charts/noaa-enc").expanduser()))
        self.extract = tk.BooleanVar(value=True)
        self.keep_zip = tk.BooleanVar(value=True)
        self.force = tk.BooleanVar(value=False)
        self.status = tk.StringVar(value="Ready")
        self.gps_device = tk.StringVar(value="/dev/ttyUSB0")
        self.use_gpsd = tk.BooleanVar(value=True)

        self._build()
        self.after(150, self._poll_queue)

    def _build(self) -> None:
        root = ttk.Frame(self, padding=16)
        root.pack(fill=tk.BOTH, expand=True)
        root.columnconfigure(1, weight=1)
        root.rowconfigure(7, weight=1)

        ttk.Label(root, text="Package").grid(row=0, column=0, sticky=tk.W, pady=(0, 8))
        kind = ttk.Combobox(
            root,
            textvariable=self.kind,
            values=("state", "updates", "cgd", "region", "chart", "all", "catalog"),
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

        gps_row = ttk.Frame(root)
        gps_row.grid(row=4, column=1, sticky=tk.EW, pady=(0, 12))
        gps_row.columnconfigure(1, weight=1)
        ttk.Label(gps_row, text="GPS").grid(row=0, column=0, sticky=tk.W)
        ttk.Entry(gps_row, textvariable=self.gps_device, width=18).grid(row=0, column=1, sticky=tk.W, padx=(10, 0))
        ttk.Checkbutton(gps_row, text="GPSD", variable=self.use_gpsd).grid(row=0, column=2, sticky=tk.W, padx=(10, 0))
        ttk.Button(gps_row, text="Preflight", command=self._start_preflight).grid(row=0, column=3, padx=(10, 0))

        action_row = ttk.Frame(root)
        action_row.grid(row=5, column=1, sticky=tk.EW, pady=(0, 12))
        self.download_button = ttk.Button(action_row, text="Download", command=self._start_download)
        self.download_button.pack(side=tk.LEFT)
        ttk.Button(action_row, text="Quit", command=self.destroy).pack(side=tk.LEFT, padx=(10, 0))

        self.progress = ttk.Progressbar(root, mode="determinate", maximum=100)
        self.progress.grid(row=6, column=0, columnspan=2, sticky=tk.EW, pady=(0, 8))

        log_frame = ttk.LabelFrame(root, text="Log")
        log_frame.grid(row=7, column=0, columnspan=2, sticky=tk.NSEW)
        log_frame.rowconfigure(0, weight=1)
        log_frame.columnconfigure(0, weight=1)
        self.log = tk.Text(log_frame, height=12, wrap=tk.WORD)
        self.log.grid(row=0, column=0, sticky=tk.NSEW)
        scroll = ttk.Scrollbar(log_frame, orient=tk.VERTICAL, command=self.log.yview)
        scroll.grid(row=0, column=1, sticky=tk.NS)
        self.log.configure(yscrollcommand=scroll.set)

        ttk.Label(root, textvariable=self.status).grid(row=8, column=0, columnspan=2, sticky=tk.W, pady=(8, 0))
        self._kind_changed()

    def _browse(self) -> None:
        selected = filedialog.askdirectory(initialdir=self.output.get() or str(Path.home()))
        if selected:
            self.output.set(selected)

    def _kind_changed(self, event: Optional[object] = None) -> None:
        hints = {
            "state": ("AK", "Example: AK"),
            "updates": ("ten-days", "one-day, two-days, one-week, ten-days"),
            "cgd": ("17", "Example: 17"),
            "region": ("30", "Example: 30"),
            "chart": ("US5AK3CM", "Example: US5AK3CM"),
            "all": ("", "No value needed"),
            "catalog": ("", "No value needed"),
        }
        current = self.kind.get()
        default, hint = hints[current]
        if current in {"all", "catalog"}:
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

        self.progress.configure(value=0)
        self.download_button.configure(state=tk.DISABLED)
        self.status.set(f"Downloading {package.filename}")
        self._log(f"Downloading {package.url}")

        self.worker = Thread(target=self._download_worker, args=(package,), daemon=True)
        self.worker.start()

    def _start_preflight(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        self.download_button.configure(state=tk.DISABLED)
        self.status.set("Running preflight")
        self._log("Running preflight checks")
        self.worker = Thread(target=self._preflight_worker, daemon=True)
        self.worker.start()

    def _selected_package(self):
        kind = self.kind.get()
        value = self.value.get().strip()
        return package_for(
            state=value if kind == "state" else None,
            updates=value if kind == "updates" else None,
            cgd=value if kind == "cgd" else None,
            region=value if kind == "region" else None,
            chart=value if kind == "chart" else None,
            all_charts=kind == "all",
            catalog=kind == "catalog",
        )

    def _download_worker(self, package) -> None:
        try:
            def progress(done: int, total: Optional[int]) -> None:
                self.queue.put(("progress", (done, total)))

            result = download_package(
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

    def _preflight_worker(self) -> None:
        try:
            results = run_preflight(
                chart_dir=Path(self.output.get()),
                gpsd=self.use_gpsd.get(),
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                gps_device=None if self.use_gpsd.get() else self.gps_device.get().strip() or None,
                gps_seconds=5.0,
            )
            self.queue.put(("preflight", results))
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
                    self.download_button.configure(state=tk.NORMAL)
                    self.progress.configure(value=100)
                    result = payload
                    if result.skipped:
                        self._log(f"Already exists: {result.path}")
                    else:
                        self._log(f"Downloaded: {result.path}")
                    if result.extracted_to:
                        self._log(f"Extracted to: {result.extracted_to}")
                    self.status.set("Done")
                elif kind == "preflight":
                    self.download_button.configure(state=tk.NORMAL)
                    ok = True
                    for result in payload:
                        ok = ok and result.ok
                        mark = "OK" if result.ok else "FAIL"
                        self._log(f"{mark:4} {result.name:10} {result.detail}")
                    self.status.set("Preflight passed" if ok else "Preflight needs attention")
                elif kind == "error":
                    self.download_button.configure(state=tk.NORMAL)
                    self.status.set("Error")
                    self._log(f"Error: {payload}")
                    messagebox.showerror("Download failed", str(payload))
        except Empty:
            pass
        self.after(150, self._poll_queue)

    def _log(self, message: str) -> None:
        self.log.insert(tk.END, message + "\n")
        self.log.see(tk.END)


def main() -> None:
    app = DownloaderApp()
    app.mainloop()


if __name__ == "__main__":
    main()
