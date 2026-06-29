# Sailboat Raspberry Pi Setup

This project is the chart-data, GPS-check, and operations wrapper for a Raspberry Pi chartplotter. Use OpenCPN for the actual chart display and route/navigation UI. OpenCPN is mature ENC chartplotter software; this Python project stays dependency-light and handles NOAA chart downloads, GPS health checks, and GPX track logging.

## Hardware Assumptions

- Raspberry Pi 4 with 4 GB RAM or newer
- 32 GB or larger SD card, preferably high-endurance
- Reliable 5 V power supply from the boat DC system
- USB or UART GPS that emits NMEA 0183
- Daylight-readable display
- Keyboard/mouse or touchscreen available for maintenance
- Raspberry Pi OS with Desktop/LightDM and an installed X11 session for unattended OpenCPN startup

Run the install, deploy, GPS setup, provisioning, verification, and dock-test scripts as the Pi desktop user, not `root`. The scripts reject root-owned workflows so user services, charts, GPX tracks, and LightDM autologin are tied to the real helm account.
Use an explicit plain `user@host` SSH target for deployment, verification, and dock tests; do not use scp-style `user@host:path` targets or append ports. If you override the SSH deploy directory, use a dedicated `noaa-navionics` directory. The deploy scripts reject broad paths such as `/`, `~`, `/home`, or unrelated directory names because deployment keeps that remote copy exact, using `rsync --delete` when available and a guarded tar-over-SSH bootstrap copy otherwise. Both copy paths write into a sibling staging directory and promote it after the transfer completes so a broken deploy attempt does not destroy the previous deployment.

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
It refuses a dirty local worktree by default so the Pi's recorded source revision matches the source you are verifying. Use `--allow-dirty` only for deliberate test deployments; those are recorded with a `-dirty` suffix. The deploy script checks for local `ssh` and remote `python3`, prefers `rsync` when it is available on both machines, and otherwise bootstraps the repo with local and remote `tar`. Both copy paths write into a validated sibling staging directory and promote it only after the transfer succeeds, so an interrupted deploy does not empty the previous deployment. The script writes the remote source revision through a synced temporary file and atomic replace before the Pi installer records it for status reports.

Deploy and run the full onboard provisioning sequence:

```bash
scripts/deploy_to_pi.sh pi@raspberrypi.local --provision --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Provisioning runs GPSD setup, chrony GPS time setup, chart sync, OpenCPN chart/GPSD registration, desktop graphical autologin setup, launcher GPS wait persistence, user service enablement, user linger for reboot persistence, and a final status report on the Pi.
The deploy, provisioning, and dock-test scripts validate retry counts, retry delays, GPS wait time, and reboot wait timeout before starting remote work.
When deployment is combined with provisioning, `--skip-autologin` is applied during both install and provisioning. `--skip-services` requires `--skip-autologin` so deliberate headless or manual-test deployments do not leave desktop chartplotter autostart enabled without the readiness and track-logging services.
Use `--skip-gpsd` only when GPSD and the onboard config are already commissioned. If unattended services or desktop autostart are still enabled, provisioning rejects missing config, placeholder GPS devices, non-local GPSD hosts, volatile device names, nonexistent GPS paths, and disabled or inactive `gpsd.service` before it enables startup behavior.
Use `--skip-gps-time` only when chrony already contains this project's uncommented GPSD `SHM 0` time-source block. If unattended services or desktop autostart are still enabled, provisioning rejects missing or commented-out GPS time configuration and disabled or inactive `chrony.service` before it enables startup behavior.
Use `--skip-sync` only when the configured chart directory already has a fresh, complete NOAA chart manifest. If unattended services or desktop autostart are still enabled, provisioning rejects missing or incomplete chart data before it enables startup behavior.
Use `--no-device-check` only for manual testing with both `--skip-services` and `--skip-autologin`; production provisioning requires the GPS receiver path to exist before it enables startup behavior.

Verify the Raspberry Pi after deployment:

```bash
scripts/verify_pi.sh pi@raspberrypi.local
```

The verify script runs checks on the Pi over SSH, including architecture, installed commands, Raspberry Pi power diagnostics, deployed source revision, chartplotter launcher content, persisted launcher GPS wait, desktop autostart fields plus hidden/disabled markers, graphical boot target, LightDM autologin for the deployed user with an installed X11 session, installed and loaded user systemd unit commands and loaded chart-refresh timer/timeout/retry/start-limit, track logger restart/start-limit, and boot-readiness restart/start-limit settings, successful execution of the enabled boot-readiness service, active GPX track logging with a recent timestamped current-boot trackpoint, GPSD boot enablement and active state, GPSD startup options, exactly one GPSD device matching the onboard config, chrony service state, GPSD time-source config, a usable chrony GPS source within the configured GPS wait, config, and `noaa-navionics status-report`. It also parses the generated JSON readiness artifact and requires it to be fresh, ready, populated with the full core readiness/service/loaded-setting checks, and stamped with the expected source revision check, config path, normalized config values, chart sync flags, manifest path, manifest timestamp provenance, NOAA ZIP filename matching the onboard config, package URL, download URL, download path under chart storage, cache-reuse flag, positive download byte count, SHA-256, extraction path, and ENC cell count. In strict chartplotter-started mode, it first checks that the existing status artifact was generated during the current boot. It expects a `-dirty` revision suffix only when verifying from a dirty local worktree. The status report step retries briefly so GPSD has time to produce its first fix after boot; add `--gps-seconds N` if the receiver needs a longer fix window.
It also writes a JSON status report on the Pi at `~/.cache/noaa-navionics/status.json`.

Run the dock acceptance test before relying on the Pi underway:

```bash
scripts/dock_test_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

The dock test deploys and provisions the Pi, verifies readiness, requests reboot with noninteractive `sudo -n reboot`, waits for SSH to return, requires the Pi boot ID to change, and verifies readiness again. If the SSH user cannot reboot without a password prompt, the test fails clearly instead of waiting on an interactive sudo prompt. After reboot, it uses the stricter verify mode that waits briefly for desktop autostart, requires the existing readiness status report and chartplotter launcher log to be fresh for the current boot, and requires an `opencpn` process owned by the deployed user to remain running through a short stability check, proving the desktop autostart path actually launched or preserved OpenCPN. Use `--skip-deploy` to test an already-provisioned Pi.
`--no-reboot` is only a pre-reboot smoke check; it skips the power-cycle and chartplotter-autostart proof required before relying on the Pi underway.
`--skip-autologin` is rejected for the rebooted dock acceptance test because that test must prove chartplotter autostart after a power cycle.
For deliberate test deployments from a dirty worktree, pass `--allow-dirty` to the dock test as well.

Manual install:

```bash
sudo apt update
sudo apt install python3 python3-venv python3-tk rsync opencpn gpsd gpsd-clients chrony lightdm x11-xserver-utils python3-setuptools
sudo apt install raspi-utils || sudo apt install libraspberrypi-bin
scripts/install_raspberry_pi.sh --skip-apt
```

On Raspberry Pi OS Bookworm, the installer adds `bookworm-backports` automatically when that source is not already configured. It does not add that Bookworm source on other OS releases.

The installer replaces its private virtual environment at `~/.local/share/noaa-navionics/venv` on each run, symlinks commands into `~/.local/bin`, uses noninteractive apt calls for unattended SSH deployment, ensures rsync remains available for future deployments, ensures LightDM and X11 display-power tools are installed for graphical startup, and ensures `vcgencmd` is available for Raspberry Pi power checks. The venv cleanup is guarded so only the dedicated `noaa-navionics/venv` directory can be removed; this prevents stale installed Python files from surviving repeated deploys. It installs the local repo with pip build isolation and PEP 517 disabled because the application has no runtime Python dependencies and the legacy setup metadata can be installed with the Pi's apt-provided setuptools. It then syncs the venv tree to disk before replacing command links. It tries `raspi-utils` first and falls back to `libraspberrypi-bin` for older Raspberry Pi OS images. It syncs the installed command symlinks, launchers, source revision file, and user systemd unit files to disk. The Python code uses only the standard library. `opencpn` renders NOAA ENCs, `gpsd` shares one GPS feed between OpenCPN and this tool, and `chrony` can discipline the Pi clock from GPSD when network time is unavailable. The installer leaves chart refresh, track logging, desktop autostart, and LightDM autologin disabled; provisioning installs or enables them only after the onboard config, charts, and GPSD have been configured. Use `--skip-autologin` only for deliberate headless or development deployments.

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
# Use an absolute path or a path starting with ~ for unattended systemd services.
output = ~/charts/noaa-enc
extract = yes
keep_zip = yes
force = yes
max_age_days = 30
min_free_gb = 2.0

[gps]
mode = gpsd
device = /dev/serial/by-id/YOUR_GPS_DEVICE
baud = 4800
gpsd_host = 127.0.0.1
gpsd_port = 2947

[tracking]
# Use an absolute path or a path starting with ~ for unattended systemd services.
output = ~/charts/noaa-enc
# Keep this many days of rotated GPX track logs; 0 disables pruning.
retention_days = 90
```

Config validation fails fast on unsafe values: `charts.package` must be one of `state`, `cgd`, `region`, `chart`, or `all`; packages other than `all` need `charts.value`; state, Coast Guard district, and region package values must match a NOAA prepackaged ENC bundle; chart and track output paths cannot be blank, must be absolute or start with `~`, and cannot be broad system or home directories such as `/`, `~`, `/home`, `/etc`, `/var`, `~/.config`, or `~/.cache`; `charts.max_age_days` must be at least `1`; `charts.min_free_gb` must be at least `0.1`; GPSD hosts cannot be blank or contain spaces, semicolons, or pipes, and `gpsd` mode requires a local host of `127.0.0.1`, `localhost`, or `::1`; GPSD ports must be `1` through `65535`; serial baud must be one of `4800`, `9600`, `19200`, `38400`, `57600`, or `115200`; `gpsd` and serial modes both require `gps.device` to be a stable path such as one `/dev/serial/by-id/...` symlink name, `/dev/serial0`, `/dev/serial1`, or `/dev/gps`; and track retention must be `0` or greater.
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
Config validation, GPSD setup, and readiness checks fail volatile USB names such as `/dev/ttyUSB0` or `/dev/ttyACM0`, reject nested or shell-unsafe by-id paths, require the configured path to be a character device when device checks are enabled, and reject unrecognized device paths; use one `/dev/serial/by-id/...` symlink name for USB GPS receivers, `/dev/serial0` or `/dev/serial1` for Raspberry Pi UART GPS hardware, or `/dev/gps` for a managed stable alias.

Configure chrony to use GPSD as a local time source:

```bash
scripts/configure_gps_time.sh
```

This writes only `/etc/chrony/chrony.conf` outside dry-run mode, backs it up, adds a managed `refclock SHM 0 offset 0.5 delay 0.1 refid GPS` block for GPSD's message-based time source, syncs the replacement file, restarts chrony, and restarts GPSD so GPSD can reconnect after chrony restarts. This is intended to keep chart-age checks and GPX timestamps sane when the Pi is away from network time. Readiness requires chrony to report the GPS refclock as selected or combined, not merely present or excluded. For sub-second timing, use GPS/PPS hardware and tune chrony for PPS separately.

Restart and verify:

```bash
sudo systemctl enable --now gpsd
sudo systemctl restart gpsd
cgps
noaa-navionics gps-monitor --gpsd --once
```

`noaa-navionics configure-opencpn`, below, configures OpenCPN to use the GPSD network source from the onboard config.
If you intentionally use serial mode instead of GPSD, set `[gps] baud` in `~/.config/noaa-navionics/config.ini` and use `noaa-navionics preflight --gps-device /dev/serial/by-id/YOUR_GPS_DEVICE --gps-baud 9600` when checking that device directly. Direct serial readiness also rejects stale, future-dated, and untimestamped NMEA fixes.
Readiness rejects non-finite coordinates, coordinates outside valid latitude/longitude bounds, and invalid `0,0` coordinates. When the receiver reports satellite count or HDOP, readiness also requires at least four satellites and HDOP no higher than 5. GPSD readiness merges recent SKY satellite/HDOP reports with TPV position fixes before applying that gate, and it still exits inside the configured GPS wait if GPSD only streams non-fix status messages.
Fractional NMEA timestamps are normalized across second, minute, and UTC day rollovers before readiness checks and GPX logging.

## One-Step Provisioning

After `scripts/install_raspberry_pi.sh` has run on the Pi, commission the onboard setup with:

```bash
scripts/provision_sailboat_pi.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

This runs the same sequence expected before departure: initializes config if needed, configures GPSD, configures chrony to use GPSD time, downloads the configured NOAA chart package, registers charts and GPSD in OpenCPN, syncs refreshed user systemd unit files, reloads the user manager, enables user linger, clears stale failed states for the track logger and boot readiness service, enables the user timer and track/readiness services, restarts the track logger so refreshed service settings are active, starts the boot readiness service, writes `~/.cache/noaa-navionics/status.json`, and then installs desktop autostart and configures graphical autologin. The boot readiness service has a broad retry budget so a slow GPSD, chrony, or receiver startup after power-on does not permanently suppress the readiness report.
The initial chart download uses retry defaults for unreliable marina Wi-Fi. Add `--sync-retries N --sync-retry-delay N` when commissioning from a slower hotspot or remote dock network. Add `--gps-seconds N` to `deploy_to_pi.sh --provision` or `dock_test_pi.sh` when the GPS receiver needs a longer cold-start fix window; provisioning stores that value in `~/.config/noaa-navionics/launcher.env` for boot readiness and desktop autostart, and GPSD checks stay bounded by that window even when GPSD is connected but not producing usable fixes.
For production provisioning, use `~/.config/noaa-navionics/config.ini`. A custom `--config` path is rejected unless both `--skip-services` and `--skip-autologin` are passed for manual testing, because the installed user services and desktop launcher use the default onboard config after reboot.

## Startup

The installer copies a launcher to `~/.local/bin/noaa-navionics-start-chartplotter`. Provisioning installs a desktop autostart entry for it, sets the Pi to boot to `graphical.target`, enables `lightdm.service`, and writes `/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf` for the deployed user after confirming the account exists with an owned local home directory and an installed X11 session is available. The launcher reads `NOAA_NAVIONICS_GPS_SECONDS` and optional `NOAA_NAVIONICS_WARNING_SECONDS` from `~/.config/noaa-navionics/launcher.env` or its environment, writes `~/.cache/noaa-navionics/status.json`, appends startup output and OpenCPN's exit status to `~/.cache/noaa-navionics/chartplotter.log`, rotates that log after 1 MB, uses a cache-directory launch lock, clears stale locks whose live PID is not actually the chartplotter launcher, leaves an existing OpenCPN process in place instead of starting a duplicate, asks X11 desktop sessions to disable screen blanking and DPMS sleep, shows a Tkinter warning with failed checks if readiness fails, and then starts OpenCPN.

Manual launch:

```bash
noaa-navionics-start-chartplotter
```

Maintenance GUI:

```bash
noaa-navionics-gui
```

The GUI can load `~/.config/noaa-navionics/config.ini`, choose complete onboard chart packages, sync the configured chart package with the same complete-chart guard as the CLI, write `~/.cache/noaa-navionics/status.json`, run preflight checks with the configured chart, GPSD, baud, chart-age, and track-storage values, and register the configured chart/GPSD connection with OpenCPN. Close OpenCPN before using the GUI's OpenCPN configuration button.

## Charts

Download Alaska charts:

```bash
noaa-navionics sync-charts
```

Each sync writes `noaa-navionics-manifest.json` next to the chart data. The manifest records the NOAA package URL, actual download URL, ZIP filename, download size, SHA-256, extraction path, ENC cell count, and chart freshness time. Onboard config rejects updates-only and catalog-only packages because they are not complete chart sources. Configured syncs require `[charts] min_free_gb` free space on writable chart storage before starting a NOAA download. Keep the production default `[charts] force = yes` so scheduled refreshes download a current NOAA bundle instead of reusing an old cache. If you set `force = no`, reusing a ZIP preserves the previous matching manifest timestamp; a cached ZIP with no prior verified manifest is marked unverified and fails preflight until you force a fresh download. ZIP extraction refuses packages with no ENC `.000` cells before replacing the previous chart directory. Completed ZIP downloads, extracted chart trees, manifest JSON, and the affected directory entries are synced before atomic replacement; manifest writes use unique temporary files. If `[charts] keep_zip = no`, the ZIP is removed after extraction even when it was already cached. Syncs hold `.noaa-navionics-download.lock` in the chart directory so a timer run and a manual run cannot update the same chart set at the same time; stale lock cleanup records PID and boot ID so an old lock is not removed while its owner is still running on the current boot. Preflight requires this manifest, fails if it is older than `max_age_days`, fails if stale chart-update staging, previous directories, or partial `.part` files remain from an interrupted sync, verifies that the recorded NOAA ZIP filename, package URL, and actual download URL match the configured chart package, verifies that the recorded extraction path is still under the configured chart directory, verifies that the extraction still contains at least the recorded number of ENC cells, and fails if another top-level ENC chart directory remains beside the manifest extract. Storage configured under `/mnt`, `/media`, or `/run/media` must have an actual mounted device on that path or one of its parents, so an unplugged USB drive does not accidentally pass readiness against the Pi's SD card. If the kept ZIP is still present, preflight also requires a positive recorded byte count and SHA-256, then verifies its recorded path, size, and SHA-256.
The installed chart refresh service runs `sync-charts` with retries, a two-hour systemd start timeout, delayed service-level retry attempts, basic user-service hardening, and a 30-minute randomized timer delay so missed weekly refreshes do not always run immediately at boot beside chartplotter startup.
If a weekly chart refresh fails while the boat is offline, the status report records the failed service state but does not fail readiness on that alone; manifest age, package match, extraction path, and ENC cell checks decide whether the installed charts are still usable.
Preflight requires a plausible system clock, and on Raspberry Pi targets it also requires `timedatectl` to report the system clock synchronized before relying on chart age or GPX timestamps. Provisioning configures chrony to use GPSD's `SHM 0` message-based time source, which is sufficient for chart age and GPX timestamps. For sub-second timekeeping, add GPS/PPS hardware and tune chrony for PPS separately.

For another cruising area, use `--state`, `--cgd`, `--region`, or individual `--chart` downloads. Use the catalog search to identify specific cells:

```bash
noaa-navionics search-catalog "Cook Inlet"
```

Do not use a NOAA `updates` bundle as the primary onboard chart package. Update bundles only contain recently changed cells, so onboard config rejects them and preflight treats them as incomplete for navigation readiness.

Register the chart directory and GPSD connection in OpenCPN:

```bash
noaa-navionics configure-opencpn
```

This backs up `~/.opencpn/opencpn.conf` if it already exists, adds the configured chart directory under `[ChartDirectories]`, adds a GPSD network connection under `[Settings/NMEADataSource]` only when `[gps] mode = gpsd`, and leaves OpenCPN closed. Backups and replacement config files are synced to disk, backup names are made unique when multiple writes happen in the same second, and replacement writes use unique temporary files. Preflight requires OpenCPN's configured chart directory to exist so stale paths or missing chart storage do not pass readiness. The chartplotter launcher starts OpenCPN with `-parse_all_enc` so OpenCPN processes available S-57 ENC charts on start.

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

The status report includes readiness checks, NOAA Navionics user unit checks, loaded user unit setting checks when systemd reports them, GPSD startup config checks for local receivers, and GPSD/chrony service state checks.
The boot readiness service reads `~/.config/noaa-navionics/launcher.env` so it uses the same GPS fix wait as the chartplotter launcher.
It is written through a unique temporary file and atomic replace, so overlapping launcher and readiness-service writes cannot corrupt the JSON artifact.
The status JSON is synced to disk along with the replacement directory entry.
It also records the current Linux boot ID and installed source revision through synced atomic file writes so you can confirm the Pi is running the expected deployment. On Raspberry Pi targets, readiness fails if that deployed source revision is missing or recorded as `unknown`.

Expected checks:

- Python 3.9+
- System clock has a sane modern UTC date
- Raspberry Pi clock is synchronized before chart-age and GPX timestamp checks are trusted
- Tkinter available for the GUI
- OpenCPN installed
- `xset` available so the launcher can disable X11 display blanking and DPMS sleep
- `vcgencmd` available on Raspberry Pi so under-voltage and throttling can be checked
- Chartplotter startup log has no display-awake command failures or OpenCPN exit marker after the current boot
- Desktop autostart installed for the chartplotter launcher and not marked hidden or disabled
- Configured chart package is a complete chart source, not an updates-only bundle
- Extracted ENC chart cells present
- Current chart manifest present, matching the configured chart package, and tied to an existing extraction with the recorded ENC cell count
- OpenCPN configured with the chart directory
- OpenCPN configured with the GPSD network connection
- Chrony enabled, active, configured to use GPSD time, and reporting a usable GPS refclock source
- Graphical boot and LightDM autologin configured with an installed X11 session for unattended startup
- Configured local GPS device path exists when GPSD is using a local receiver
- At least `[charts] min_free_gb` free disk space on writable chart storage, and on separate track storage when `[tracking] output` uses a different path; `/mnt`, `/media`, and `/run/media` storage paths must actually be mounted
- No active Raspberry Pi under-voltage or throttling
- Raspberry Pi temperature below the hard limit
- Fresh valid GPSD fix, or a fresh valid direct NMEA fix when intentionally using serial mode
- Chart refresh timer, track logger, boot readiness service, GPSD service, and chrony service are in the expected state
- During the dock test after reboot, the status report and chartplotter launcher ran during the current boot and OpenCPN is running

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

The generated GPX files are stored under `~/charts/noaa-enc/tracks/` by default. The systemd service reads `[gps]` and `[tracking] output` from the onboard config and writes one file per UTC day, such as `track-20260629.gpx`; manual `--device`, `--baud`, `--gpsd`, and `--output` flags override the config for direct troubleshooting. If the service restarts on the same day it uses a numeric suffix instead of overwriting the earlier file. GPX files are created exclusively, so an explicit existing output file fails instead of being truncated. The new file entry is synced after creation, and track files are flushed at every point and periodically synced to disk to reduce data loss after abrupt power loss. The logger skips invalid coordinates and weak satellite/HDOP fixes instead of writing them to GPX; single-file logging does not create the output file until the first accepted fix. A bounded diagnostic run such as `log-track --seconds 30` exits non-zero if no usable fix is written before the timeout. An untimed live run exits non-zero if the GPS stream ends unexpectedly, so the installed `Restart=on-failure` service restarts instead of silently stopping after a transient GPSD or device interruption. The installed service drops per-fix stdout so normal GPS logging does not fill the systemd journal, while stderr warnings and failures still go to the service log. When systemd stops the logger during reboot or shutdown, SIGTERM handling closes the current GPX file before exit. If `[tracking] output` points somewhere other than the chart directory, preflight checks that separate destination has an existing writable parent and enough free space. By default, rotated track logs older than 90 days are pruned; set `[tracking] retention_days = 0` to disable pruning.
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

The service writes `~/.cache/noaa-navionics/status.json`, disables systemd's start timeout so persisted cold-start GPS waits can finish, fails readiness on failed or unqueryable NOAA Navionics units, and retries briefly if GPSD is not producing a valid fix yet.

## Operational Notes

- Do not run the Python serial reader and OpenCPN against `/dev/ttyUSB0` at the same time. Use GPSD for shared production use.
- Keep paper charts or an independent backup navigation device on board.
- NOAA ENCs are official data, but this project is not certified navigation equipment.
- Test the full setup at the dock with the GPS outdoors before using it underway.
- Keep the Pi clock synchronized when online; GPS timestamps are UTC.
