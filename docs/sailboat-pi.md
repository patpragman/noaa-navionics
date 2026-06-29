# Sailboat Raspberry Pi Setup

This project is the chart-data, GPS-check, and operations wrapper for a Raspberry Pi chartplotter. Use OpenCPN for the actual chart display and route/navigation UI. OpenCPN is mature ENC chartplotter software; this Python project stays dependency-light and handles NOAA chart downloads, GPS health checks, and GPX track logging.

## Hardware Assumptions

- Raspberry Pi 4 with 4 GB RAM or newer
- 32 GB or larger SD card, preferably high-endurance
- Reliable 5 V power supply from the boat DC system
- USB or UART GPS that emits NMEA 0183
- Daylight-readable display
- Keyboard/mouse or touchscreen available for maintenance
- Raspberry Pi OS with Desktop/LightDM for unattended OpenCPN startup

## Install Packages

Fast path from a cloned repo:

```bash
scripts/install_raspberry_pi.sh
```

Deploy from another computer over SSH:

```bash
scripts/deploy_to_pi.sh pi@raspberrypi.local
```

The deploy script copies this repo to the Raspberry Pi and runs the installer on the Pi. It does not install or enable services on the computer you run it from.
It refuses a dirty local worktree by default so the Pi's recorded source revision matches the source you are verifying. Use `--allow-dirty` only for deliberate test deployments; those are recorded with a `-dirty` suffix.

Deploy and run the full onboard provisioning sequence:

```bash
scripts/deploy_to_pi.sh pi@raspberrypi.local --provision --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Provisioning runs GPSD setup, chart sync, OpenCPN chart/GPSD registration, desktop graphical autologin setup, user service enablement, user linger for reboot persistence, and a final status report on the Pi.
The deploy, provisioning, and dock-test scripts validate retry counts, retry delays, GPS wait time, and reboot wait timeout before starting remote work.

Verify the Raspberry Pi after deployment:

```bash
scripts/verify_pi.sh pi@raspberrypi.local
```

The verify script runs checks on the Pi over SSH, including architecture, installed commands, deployed source revision, chartplotter launcher content, desktop autostart fields, graphical boot target, LightDM autologin for the deployed user, installed user systemd unit contents, GPSD boot enablement and startup options, GPSD device matching the onboard config, config, and `noaa-navionics status-report`. It also parses the generated JSON readiness artifact and requires it to be fresh, ready, populated with readiness checks, and stamped with the expected source revision. It expects a `-dirty` revision suffix only when verifying from a dirty local worktree. The status report step retries briefly so GPSD has time to produce its first fix after boot; add `--gps-seconds N` if the receiver needs a longer fix window.
It also writes a JSON status report on the Pi at `~/.cache/noaa-navionics/status.json`.

Run the dock acceptance test before relying on the Pi underway:

```bash
scripts/dock_test_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

The dock test deploys and provisions the Pi, verifies readiness, reboots it, waits for SSH to return, and verifies readiness again. After reboot, it uses the stricter verify mode that waits briefly for desktop autostart, requires a fresh chartplotter launcher log from the current boot, and requires a running `opencpn` process, proving the desktop autostart path actually launched OpenCPN. Use `--skip-deploy` to test an already-provisioned Pi.
For deliberate test deployments from a dirty worktree, pass `--allow-dirty` to the dock test as well.

Manual install:

```bash
sudo apt update
sudo apt install python3 python3-venv python3-tk opencpn gpsd gpsd-clients x11-xserver-utils
scripts/install_raspberry_pi.sh --skip-apt
```

On Raspberry Pi OS Bookworm, the installer adds `bookworm-backports` automatically when that source is not already configured. It does not add that Bookworm source on other OS releases.

The installer creates a private virtual environment at `~/.local/share/noaa-navionics/venv`, symlinks commands into `~/.local/bin`, installs the chartplotter autostart entry, and configures LightDM graphical autologin for the installing user. It syncs the installed command symlinks, launchers, source revision file, desktop autostart entry, and user systemd unit files to disk. The Python code uses only the standard library. `opencpn` renders NOAA ENCs, and `gpsd` shares one GPS feed between OpenCPN and this tool. The track logger is enabled for future boots during install, but provisioning starts it only after GPSD has been configured. Use `--skip-autologin` only for deliberate headless or development deployments.

## Onboard Config

All services read one config file:

```bash
noaa-navionics init-config
nano ~/.config/noaa-navionics/config.ini
```

`init-config` writes through a unique temporary file, syncs to disk, and atomically replaces `config.ini`.

Default config:

```ini
[charts]
package = state
value = AK
output = ~/charts/noaa-enc
extract = yes
keep_zip = yes
force = yes
max_age_days = 30

[gps]
mode = gpsd
device = /dev/serial/by-id/YOUR_GPS_DEVICE
baud = 4800
gpsd_host = 127.0.0.1
gpsd_port = 2947

[tracking]
output = ~/charts/noaa-enc
# Keep this many days of rotated GPX track logs; 0 disables pruning.
retention_days = 90
```

Config validation fails fast on unsafe values: `charts.package` must be one of `state`, `cgd`, `region`, `updates`, `chart`, `all`, or `catalog`; packages other than `all` and `catalog` need `charts.value`; chart and track output paths cannot be blank; `charts.max_age_days` must be at least `1`; GPSD hosts cannot be blank or contain spaces, semicolons, or pipes; GPSD ports must be `1` through `65535`; serial baud must be one of `4800`, `9600`, `19200`, `38400`, `57600`, or `115200`; serial mode requires `gps.device`; and track retention must be `0` or greater.
`gps.mode` must be `gpsd` or `serial`. Use `gpsd` for onboard production so OpenCPN and this tool can share the receiver.

## GPSD Setup

For a USB GPS, check the device name:

```bash
ls -l /dev/serial/by-id/
```

Configure GPSD with the stable device path:

```bash
scripts/configure_gpsd.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

The script requires an absolute `/dev/...` path without whitespace or quotes, backs up `/etc/default/gpsd`, writes and syncs the GPSD config, restarts GPSD, and updates `~/.config/noaa-navionics/config.ini` through a synced atomic replacement.
GPSD setup and readiness checks fail volatile USB names such as `/dev/ttyUSB0` or `/dev/ttyACM0`; use `/dev/serial/by-id/...` for USB GPS receivers or a stable Raspberry Pi serial alias for UART GPS hardware.

Restart and verify:

```bash
sudo systemctl enable --now gpsd
sudo systemctl restart gpsd
cgps
noaa-navionics gps-monitor --gpsd --once
```

`noaa-navionics configure-opencpn`, below, configures OpenCPN to use the GPSD network source from the onboard config.
If you intentionally use serial mode instead of GPSD, set `[gps] baud` in `~/.config/noaa-navionics/config.ini` and use `noaa-navionics preflight --gps-device /dev/serial/by-id/YOUR_GPS_DEVICE --gps-baud 9600` when checking that device directly. Direct serial readiness also rejects stale or future-dated timestamped NMEA fixes.
Fractional NMEA timestamps are normalized across second, minute, and UTC day rollovers before readiness checks and GPX logging.

## One-Step Provisioning

After `scripts/install_raspberry_pi.sh` has run on the Pi, commission the onboard setup with:

```bash
scripts/provision_sailboat_pi.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

This runs the same sequence expected before departure: initializes config if needed, configures GPSD, downloads the configured NOAA chart package, registers charts and GPSD in OpenCPN, configures graphical autologin, syncs refreshed user systemd unit files, enables user linger, enables the user timer and track/readiness services, and writes `~/.cache/noaa-navionics/status.json`.
The initial chart download uses retry defaults for unreliable marina Wi-Fi. Add `--sync-retries N --sync-retry-delay N` when commissioning from a slower hotspot or remote dock network. Add `--gps-seconds N` to `deploy_to_pi.sh --provision` or `dock_test_pi.sh` when the GPS receiver needs a longer cold-start fix window.

## Startup

The installer copies a launcher to `~/.local/bin/noaa-navionics-start-chartplotter`, installs a desktop autostart entry for it, sets the Pi to boot to `graphical.target`, enables `lightdm.service`, and writes `/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf` for the deployed user. The launcher writes `~/.cache/noaa-navionics/status.json`, appends startup output to `~/.cache/noaa-navionics/chartplotter.log`, rotates that log after 1 MB, asks X11 desktop sessions to disable screen blanking and DPMS sleep, warns if readiness fails, and then starts OpenCPN.

Manual launch:

```bash
noaa-navionics-start-chartplotter
```

Maintenance GUI:

```bash
noaa-navionics-gui
```

The GUI can load `~/.config/noaa-navionics/config.ini`, sync the configured chart package, write `~/.cache/noaa-navionics/status.json`, run preflight checks, and register the configured chart/GPSD connection with OpenCPN. Close OpenCPN before using the GUI's OpenCPN configuration button.

## Charts

Download Alaska charts:

```bash
noaa-navionics sync-charts
```

Each sync writes `noaa-navionics-manifest.json` next to the chart data. The manifest records the NOAA package URL and ZIP filename, download size, SHA-256, extraction path, ENC cell count, and UTC sync time. ZIP extraction refuses packages with no ENC `.000` cells before replacing the previous chart directory. Completed ZIP downloads, extracted chart trees, manifest JSON, and the affected directory entries are synced before atomic replacement; manifest writes use unique temporary files. Syncs hold `.noaa-navionics-download.lock` in the chart directory so a timer run and a manual run cannot update the same chart set at the same time; stale locks older than six hours are replaced. Preflight requires this manifest, fails if it is older than `max_age_days`, verifies that the recorded NOAA ZIP matches the configured chart package, verifies that the recorded extraction path is still under the configured chart directory, and verifies that the extraction still contains at least the recorded number of ENC cells. If the kept ZIP is still present, preflight also verifies its recorded path, size, and SHA-256.
The installed chart refresh service runs `sync-charts` with retries, a two-hour systemd start timeout, and delayed service-level retry attempts so large NOAA bundles are not killed or abandoned during slow marina Wi-Fi downloads.

For another cruising area, use `--state`, `--cgd`, `--region`, or individual `--chart` downloads. Use the catalog search to identify specific cells:

```bash
noaa-navionics search-catalog "Cook Inlet"
```

Do not use a NOAA `updates` bundle as the primary onboard chart package. Update bundles only contain recently changed cells, so preflight treats them as incomplete for navigation readiness.

Register the chart directory and GPSD connection in OpenCPN:

```bash
noaa-navionics configure-opencpn
```

This backs up `~/.opencpn/opencpn.conf` if it already exists, adds the configured chart directory under `[ChartDirectories]`, adds a GPSD network connection under `[Settings/NMEADataSource]` only when `[gps] mode = gpsd`, and leaves OpenCPN closed. Backups and replacement config files are synced to disk, and replacement writes use unique temporary files. The chartplotter launcher starts OpenCPN with `-parse_all_enc` so OpenCPN processes available S-57 ENC charts on start.

## Pre-Departure Check

Run this before relying on the Pi:

```bash
noaa-navionics preflight --charts ~/charts/noaa-enc --gpsd
```

or, using the onboard config:

```bash
noaa-navionics preflight
```

Save a status report for troubleshooting:

```bash
noaa-navionics status-report --output ~/.cache/noaa-navionics/status.json
```

The status report includes readiness checks, NOAA Navionics user unit checks, and GPSD service state checks.
It is written through a unique temporary file and atomic replace, so overlapping launcher and readiness-service writes cannot corrupt the JSON artifact.
The status JSON is synced to disk along with the replacement directory entry.
It also records the installed source revision so you can confirm the Pi is running the expected deployment.

Expected checks:

- Python 3.9+
- System clock has a sane modern UTC date
- Tkinter available for the GUI
- OpenCPN installed
- `xset` available so the launcher can disable X11 display blanking and DPMS sleep
- Chartplotter startup log has no display-awake command failures after the current boot
- Configured chart package is a complete chart source, not an updates-only bundle
- Extracted ENC chart cells present
- Current chart manifest present, matching the configured chart package, and tied to an existing extraction with the recorded ENC cell count
- OpenCPN configured with the chart directory
- OpenCPN configured with the GPSD network connection
- Graphical boot and LightDM autologin configured for unattended startup
- Configured local GPS device path exists when GPSD is using a local receiver
- At least 2 GB free disk space on writable chart storage, and on separate track storage when `[tracking] output` uses a different path
- No active Raspberry Pi under-voltage or throttling
- Raspberry Pi temperature below the hard limit
- Fresh valid GPSD fix, or a fresh valid direct NMEA fix when intentionally using serial mode
- Chart refresh timer, track logger, boot readiness service, and GPSD service are in the expected state
- During the dock test after reboot, the chartplotter launcher ran during the current boot and OpenCPN is running

If any check fails, treat the Pi as not ready.

## Track Logging

Manual:

```bash
noaa-navionics log-track --gpsd --output ~/charts/noaa-enc
```

or, using the onboard config:

```bash
noaa-navionics log-track
```

The generated GPX files are stored under `~/charts/noaa-enc/tracks/` by default. The systemd service writes one file per UTC day, such as `track-20260629.gpx`; if the service restarts on the same day it uses a numeric suffix instead of overwriting the earlier file. GPX files are created exclusively, so an explicit existing output file fails instead of being truncated. Track files are flushed at every point and periodically synced to disk to reduce data loss after abrupt power loss. When systemd stops the logger during reboot or shutdown, SIGTERM handling closes the current GPX file before exit. If `[tracking] output` points somewhere other than the chart directory, preflight checks that separate destination for free space and writability. By default, rotated track logs older than 90 days are pruned; set `[tracking] retention_days = 0` to disable pruning.
The track logger service uses a generous start-limit window so delayed GPSD or GPS hardware at boot does not permanently suppress GPX logging.

Systemd user service:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/noaa-navionics-track.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now noaa-navionics-track.service
```

The service reads `~/.config/noaa-navionics/config.ini`.

## Chart Updates

Install the weekly chart refresh timer:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/noaa-navionics.service systemd/noaa-navionics.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now noaa-navionics.timer
```

Edit `~/.config/noaa-navionics/config.ini` if your cruising region is not Alaska.

## Boot-Time Readiness Report

Install a user service that writes the same readiness report at login:

```bash
cp systemd/noaa-navionics-preflight.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable noaa-navionics-preflight.service
```

The service writes `~/.cache/noaa-navionics/status.json`, fails readiness on failed or unqueryable NOAA Navionics units, and retries briefly if GPSD is not producing a valid fix yet.

## Operational Notes

- Do not run the Python serial reader and OpenCPN against `/dev/ttyUSB0` at the same time. Use GPSD for shared production use.
- Keep paper charts or an independent backup navigation device on board.
- NOAA ENCs are official data, but this project is not certified navigation equipment.
- Test the full setup at the dock with the GPS outdoors before using it underway.
- Keep the Pi clock synchronized when online; GPS timestamps are UTC.
