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
Use an explicit plain `user@host` SSH target for deployment, verification, and dock tests; do not use scp-style `user@host:path` targets or append ports. If you override the SSH deploy directory, use a dedicated `noaa-navionics` directory. The deploy scripts reject broad paths such as `/`, `~`, `/home`, or unrelated directory names because deployment keeps that remote copy exact, using `rsync --delete` when available and a guarded tar-over-SSH bootstrap copy otherwise. Both copy paths skip local build/cache directories and downloaded chart artifacts, write into a sibling staging directory, and promote it after the transfer completes so a broken deploy attempt does not destroy the previous deployment.

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
It refuses a dirty local worktree by default so the Pi's recorded source revision matches the source you are verifying. Use `--allow-dirty` only for deliberate test deployments; those are recorded with a `-dirty` suffix. The deploy script checks for local `ssh` and remote `python3`, prefers `rsync` when it is available on both machines, and otherwise bootstraps the repo with local and remote `tar`. Both copy paths reject system or volatile remote directories such as `/tmp/noaa-navionics`, write into a validated sibling staging directory under a trusted deployment parent, and promote it only after the transfer succeeds. If a prior deploy was interrupted after the old tree moved to `.previous`, the next deploy restores that previous tree before creating a new staging copy, so a failed deploy does not empty or erase the last good deployment. The script writes the remote source revision through a synced temporary file and atomic replace only after the promoted repo path is a trusted directory, before the Pi installer records it for status reports. Remote install and provisioning commands run over SSH without allocating a pseudo-terminal so deployment works cleanly from non-interactive shells.

Deploy and run the full onboard provisioning sequence:

```bash
scripts/deploy_to_pi.sh pi@raspberrypi.local --provision --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Provisioning runs GPSD setup, chrony GPS time setup, chart sync, OpenCPN chart/GPSD registration, desktop graphical autologin setup, launcher GPS wait persistence, user service enablement, user linger for reboot persistence, and a final status report on the Pi.
The deploy, provisioning, and dock-test scripts validate retry counts, retry delays, GPS wait time, and reboot wait timeout before starting remote work.
When deployment is combined with provisioning, `--skip-autologin` is applied during both install and provisioning. `--skip-services` and `--skip-autologin` must be used together for deliberate headless or manual-test deployments, so the Pi is not left with only part of the unattended startup path enabled.
Use `--skip-gpsd` only when GPSD and the onboard config are already commissioned. If `--device` is supplied, the existing onboard config must name the same receiver. If unattended services or desktop autostart are still enabled, provisioning rejects missing config, placeholder GPS devices, mismatched requested devices, non-local GPSD hosts, volatile device names, nonexistent GPS paths, and disabled or inactive `gpsd.socket` or `gpsd.service` before it enables startup behavior. Skipping GPSD setup still leaves chrony GPS time setup enabled unless `--skip-gps-time` is also passed.
Use `--skip-gps-time` only when chrony already contains this project's uncommented GPSD `SHM 0` time-source block. If unattended services or desktop autostart are still enabled, provisioning rejects missing or commented-out GPS time configuration and disabled or inactive `chrony.service` before it enables startup behavior.
Use `--skip-sync` only when the configured chart directory already has a fresh, complete NOAA chart manifest. If unattended services or desktop autostart are still enabled, provisioning rejects missing or incomplete chart data before it enables startup behavior.
Use `--no-device-check` only for manual testing with both `--skip-services` and `--skip-autologin`; production provisioning requires the GPS receiver path to exist before it enables startup behavior.

Verify the Raspberry Pi after deployment:

```bash
scripts/verify_pi.sh pi@raspberrypi.local
```

The verify script runs checks on the Pi over SSH without allocating a pseudo-terminal, including architecture, installed commands, installed CLI/GUI command symlinks resolving into the private venv, trusted command/app-data/app-config/desktop-autostart/user-systemd parent directories, root-owned LightDM/GPSD/chrony config parent-directory integrity, Raspberry Pi power diagnostics, deployed source revision, chartplotter launcher content with synced current-boot launch-lock handling, persisted launcher GPS wait and OpenCPN restart policy, onboard app config, OpenCPN config and parent directory, source revision, launcher environment, desktop autostart, LightDM autologin, GPSD, chrony, helper launcher, and user systemd unit file ownership/mode integrity, desktop autostart fields plus hidden/disabled markers, graphical boot target, LightDM autologin for the deployed user with an installed X11 session, Tkinter readiness-warning support, installed and loaded user systemd unit commands, loaded fragment paths, install targets, loaded chart-refresh timer/timeout/retry/start-limit, track logger restart/start-limit, and boot-readiness restart/start-limit settings, user linger for reboot-persistent user services, successful execution of the enabled boot-readiness service, active GPX track logging with a recent valid timestamped current-boot trackpoint in a regular private GPX file owned by the deployed user in a private tracks directory, GPSD socket/service boot enablement and active state, GPSD client tools for manual checks, GPSD startup options, exactly one GPSD device matching the onboard config, chrony service state, uncommented GPSD time-source config, a usable chrony GPS source within the configured GPS wait, config, and `noaa-navionics status-report`. It also parses the generated JSON readiness artifact and requires it to be fresh, ready, populated with the full core readiness/service/loaded-setting/service-run checks, and stamped with the expected source revision check, config path, user-linger state, launcher settings matching the live launcher environment and expected restart policy, OpenCPN chart and GPSD settings matching the live OpenCPN config, desktop autostart and LightDM autologin settings matching the live desktop files, normalized config values, chart sync flags, GPX track-log directory, private directory mode, private latest file mode, and latest file path matching the live config, manifest path, manifest timestamp provenance, NOAA ZIP filename matching the onboard config, package URL, download URL, download path under chart storage, cache-reuse flag, positive download byte count, SHA-256, extraction path, and ENC cell count. In strict chartplotter-started mode, it also requires LightDM to be active, first checks that the existing status artifact was generated during the current boot, and queries the launcher's live X display to prove screen blanking and DPMS sleep are disabled. It expects a `-dirty` revision suffix only when verifying from a dirty local worktree. The status report step retries briefly so GPSD has time to produce its first fix after boot; add `--gps-seconds N` if the receiver needs a longer fix window and `--opencpn-restarts N --opencpn-restart-delay N` if you commissioned a non-default launcher restart policy.
It also writes a JSON status report on the Pi at `~/.cache/noaa-navionics/status.json`.

Run the dock acceptance test before relying on the Pi underway:

```bash
scripts/dock_test_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

The dock test preflights noninteractive sudo reboot access before deploying or provisioning, deploys and provisions the Pi, verifies readiness, requests reboot with `sudo -n reboot`, waits for SSH to return, requires the Pi boot ID to change, passes that observed post-reboot boot ID into strict verification, and verifies readiness again. It passes the requested GPS device into verification so the onboard config and GPSD daemon must still point at the intended receiver; the rebooted dock acceptance path requires `--device` even with `--skip-deploy`. If the SSH user cannot reboot without a password prompt, the test fails clearly instead of waiting on an interactive sudo prompt. After reboot, it uses the stricter verify mode that waits through the configured launcher readiness budget for desktop autostart, requires LightDM to be active, requires the existing readiness status report and chartplotter launcher log to be fresh for the current boot, rejects launcher logs that started OpenCPN after failed readiness, requires the chartplotter launcher lock to be stamped with the current boot ID and owned by a live launcher process, and requires an `opencpn` process owned by the deployed user to be running with `-parse_all_enc` and remain running through a short stability check, proving the desktop autostart path actually launched or preserved OpenCPN after passing readiness under launcher supervision. Use `--skip-deploy` to test an already-provisioned Pi, but still pass the expected `--device` for full acceptance.
`--no-reboot` is only a pre-reboot smoke check; it skips the power-cycle and chartplotter-autostart proof required before relying on the Pi underway.
`--skip-autologin` is rejected for the dock acceptance test because that test must prove the production desktop startup path; use direct deploy/provision commands with both `--skip-autologin` and `--skip-services` only for weaker manual or headless testing.
For deliberate test deployments from a dirty worktree, pass `--allow-dirty` to the dock test as well.

Manual install:

```bash
sudo apt update
sudo apt install python3 python3-venv python3-tk rsync opencpn gpsd gpsd-clients chrony lightdm x11-xserver-utils python3-setuptools procps
sudo apt install raspi-utils || sudo apt install libraspberrypi-bin
scripts/install_raspberry_pi.sh --skip-apt
```

On Raspberry Pi OS Bookworm, the installer adds `bookworm-backports` as a synced apt source drop-in when that source is not already configured, after rejecting symlinked, misowned, or group/world-writable apt source paths. It does not add that Bookworm source on other OS releases.

The installer rejects symlinked, misowned, or group/world-writable user install paths, replaces its private virtual environment at `~/.local/share/noaa-navionics/venv` on each run, symlinks commands into `~/.local/bin`, uses noninteractive apt calls for unattended SSH deployment, ensures rsync remains available for future deployments, ensures LightDM, X11 display-power tools, and `procps` process lookup tools are installed for graphical startup checks, and ensures `vcgencmd` is available for Raspberry Pi power checks. The venv cleanup is guarded so only the dedicated `noaa-navionics/venv` directory can be removed; this prevents stale installed Python files from surviving repeated deploys. It installs the local repo with pip build isolation and PEP 517 disabled because the application has no runtime Python dependencies and the legacy setup metadata can be installed with the Pi's apt-provided setuptools. It records a deploy-provided `.source-revision` when present; otherwise direct installs from a dirty Git worktree are marked with a `-dirty` suffix in status reports. It then syncs the venv tree to disk before replacing command links, helper launchers, and user systemd unit files through synced temporary files. Pi verification requires those CLI and GUI symlinks to resolve into the private venv, requires helper launchers to be trusted user-owned executables, and rejects writable or misowned parent directories for commands, app data, app config, desktop autostart, and user systemd units. It installs GPSD client tools as `gpsd-clients` first, falls back to `gpsd-tools` when needed, and verifies `cgps` is present for manual GPS checks. It tries `raspi-utils` first and falls back to `libraspberrypi-bin` for older Raspberry Pi OS images. It syncs the installed command symlinks, launchers, source revision file, and user systemd unit files to disk. The Python code uses only the standard library. `opencpn` renders NOAA ENCs, `gpsd` shares one GPS feed between OpenCPN and this tool, and `chrony` can discipline the Pi clock from GPSD when network time is unavailable. The installer leaves chart refresh, track logging, desktop autostart, and LightDM autologin disabled; provisioning installs or enables them only after the onboard config, charts, and GPSD have been configured. Use `--skip-autologin` only together with `--skip-services` for deliberate headless or development deployments.

## Onboard Config

All services read one config file:

```bash
noaa-navionics init-config
nano ~/.config/noaa-navionics/config.ini
```

`init-config` creates the config directory with private `0700` permissions when needed, refuses symlinked, misowned, or group/world-writable config directories, then writes through a unique private `0600` temporary file, syncs to disk, and atomically replaces `config.ini`.

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

Config validation fails fast on unsafe values: `charts.package` must be one of `state`, `cgd`, `region`, `chart`, or `all`; packages other than `all` need `charts.value`; state, Coast Guard district, and region package values must match a NOAA prepackaged ENC bundle; chart and track output paths cannot be blank, must be absolute or start with `~`, and cannot be broad system, volatile, or home directories such as `/`, `~`, `/home`, `/etc`, `/etc/noaa-navionics`, `/tmp/noaa-navionics`, `/var`, `~/.config`, or `~/.cache`; use a dedicated real directory under the Pi user's home or mounted storage under `/mnt`, `/media`, or `/run/media`; readiness rejects symlinked storage paths; `charts.max_age_days` must be at least `1`; `charts.min_free_gb` must be at least `0.1`; GPSD hosts cannot be blank or contain spaces, semicolons, or pipes, and `gpsd` mode requires a local host of `127.0.0.1`, `localhost`, or `::1`; GPSD ports must be `1` through `65535`; serial baud must be one of `4800`, `9600`, `19200`, `38400`, `57600`, or `115200`; `gpsd` and serial modes both require `gps.device` to be a stable path such as one `/dev/serial/by-id/...` symlink name, `/dev/serial0`, `/dev/serial1`, or `/dev/gps`; and track retention must be `0` or greater.
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

The script requires an absolute `/dev/...` path without whitespace or quotes, validates the onboard app config, config directory, and `/etc/default/gpsd` target path before touching GPSD, creates a synced root-owned private `0600` backup of `/etc/default/gpsd`, replaces the GPSD config through a synced temporary file, reloads systemd, enables and restarts both `gpsd.socket` and `gpsd.service`, and updates `~/.config/noaa-navionics/config.ini` through a synced private `0600` atomic replacement.
Deploy, dock-test, direct verification, config validation, GPSD setup, and readiness checks fail volatile USB names such as `/dev/ttyUSB0` or `/dev/ttyACM0`, reject nested or shell-unsafe by-id paths, require the configured path to be a character device when device checks are enabled, and reject unrecognized device paths; use one `/dev/serial/by-id/...` symlink name for USB GPS receivers, `/dev/serial0` or `/dev/serial1` for Raspberry Pi UART GPS hardware, or `/dev/gps` for a managed stable alias. GPSD setup validates the final NOAA Navionics app config before writing `/etc/default/gpsd`, so unsafe chart or track storage settings fail before system GPSD files are changed.

Configure chrony to use GPSD as a local time source:

```bash
scripts/configure_gps_time.sh
```

This writes only `/etc/chrony/chrony.conf` outside dry-run mode, rejects symlinked or writable chrony config paths, creates a synced root-owned private `0600` backup, refuses damaged managed block markers, adds a managed `refclock SHM 0 offset 0.5 delay 0.1 refid GPS` block for GPSD's message-based time source, replaces the config through a synced temporary file, restarts chrony, and restarts GPSD so GPSD can reconnect after chrony restarts. This is intended to keep chart-age checks and GPX timestamps sane when the Pi is away from network time. Readiness requires chrony to report the GPS refclock as selected or combined, not merely present or excluded. For sub-second timing, use GPS/PPS hardware and tune chrony for PPS separately.

Restart and verify:

```bash
sudo systemctl enable --now gpsd.socket gpsd.service
sudo systemctl restart gpsd.socket gpsd.service
cgps
noaa-navionics gps-monitor --gpsd --once --seconds 30
```

`noaa-navionics configure-opencpn`, below, configures OpenCPN to use the GPSD network source from the onboard config.
Use `gps-monitor --seconds N` during dock diagnostics so the command exits non-zero instead of waiting forever when GPSD is connected but no fix arrives.
If you intentionally use serial mode instead of GPSD, set `[gps] baud` in `~/.config/noaa-navionics/config.ini` and use `noaa-navionics preflight --gps-device /dev/serial/by-id/YOUR_GPS_DEVICE --gps-baud 9600` when checking that device directly. Direct serial readiness also rejects stale, future-dated, and untimestamped NMEA fixes.
Readiness rejects missing fix-quality, missing coordinates, non-finite, out-of-range, malformed numeric/hemisphere NMEA, and invalid `0,0` coordinates. NMEA and GPSD parsing reject malformed or non-finite required fix fields and ignore malformed or non-finite optional speed, course, altitude, satellite-count, or HDOP values. When the receiver reports satellite count or HDOP, readiness also requires at least four satellites and HDOP no higher than 5. GPSD readiness merges recent SKY satellite/HDOP reports with TPV position fixes before applying that gate, and it still exits inside the configured GPS wait if GPSD only streams non-fix status messages.
Fractional NMEA timestamps are normalized across second, minute, and UTC day rollovers before readiness checks and GPX logging. Malformed or non-finite NMEA timestamps and malformed GPSD timestamps are treated as missing timestamps, so readiness still rejects those fixes when freshness is required.

## One-Step Provisioning

After `scripts/install_raspberry_pi.sh` has run on the Pi, commission the onboard setup with:

```bash
scripts/provision_sailboat_pi.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

This runs the same sequence expected before departure: initializes config if needed, configures GPSD, configures chrony to use GPSD time, downloads the configured NOAA chart package, registers charts and GPSD in OpenCPN, rejects symlinked, misowned, or group/world-writable launcher environment, user systemd, and desktop autostart paths before replacing refreshed user systemd unit files through synced temporary files, reloads the user manager, enables user linger, clears stale failed states for the chart refresh, track logger, and boot readiness services, enables the user timer and track/readiness services, restarts the track logger and boot readiness service so refreshed service settings are active, installs desktop autostart through a synced temporary file, configures graphical autologin, and then writes the private `0600` status report `~/.cache/noaa-navionics/status.json` after those desktop startup files exist. Pi verification rejects launcher environment, autostart, LightDM autologin, user unit, app config, OpenCPN config, GPSD, chrony, or source-revision files that are symlinks, owned by the wrong account, or group/world-writable. The boot readiness service wants and starts after the GPX track logger, verifies linger remains enabled for reboot-persistent user services, and has a broad retry budget so a slow GPSD, chrony, receiver, or first GPX write after power-on does not permanently suppress the readiness report.
The initial chart download uses retry defaults for unreliable marina Wi-Fi. Add `--sync-retries N --sync-retry-delay N` when commissioning from a slower hotspot or remote dock network. The unattended Pi default waits 60 seconds for a GPS fix at startup; add `--gps-seconds N` to `deploy_to_pi.sh --provision` or `dock_test_pi.sh` when the GPS receiver needs a different cold-start window. Add `--opencpn-restarts N --opencpn-restart-delay N` when the chartplotter needs a different supervised restart policy after nonzero OpenCPN exits. Provisioning stores those launcher values in `~/.config/noaa-navionics/launcher.env` through a synced temporary file and atomic replacement for boot readiness and desktop autostart, and GPSD checks stay bounded by the GPS wait even when GPSD is connected but not producing usable fixes.
For production provisioning, use `~/.config/noaa-navionics/config.ini`. A custom `--config` path is rejected unless both `--skip-services` and `--skip-autologin` are passed for manual testing, because the installed user services and desktop launcher use the default onboard config after reboot.

## Startup

The installer copies a launcher to `~/.local/bin/noaa-navionics-start-chartplotter`. Provisioning installs a desktop autostart entry for it, sets the Pi to boot to `graphical.target`, enables `lightdm.service`, and rejects root-owned autologin setup, symlinked paths, or writable LightDM autologin paths before replacing `/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf` through a synced temporary file for the deployed user after confirming the account exists with an owned local home directory and an installed X11 session is available. The launcher reads `NOAA_NAVIONICS_GPS_SECONDS`, optional `NOAA_NAVIONICS_WARNING_SECONDS`, optional `NOAA_NAVIONICS_READINESS_ATTEMPTS`, optional `NOAA_NAVIONICS_READINESS_RETRY_DELAY`, optional `NOAA_NAVIONICS_OPENCPN_RESTARTS`, optional `NOAA_NAVIONICS_OPENCPN_RESTART_DELAY`, and optional `NOAA_NAVIONICS_START_ON_FAILED_READINESS` from `~/.config/noaa-navionics/launcher.env` only after rejecting symlinked, misowned, or group/world-writable launcher environment files, then applies process environment overrides, keeps `~/.cache/noaa-navionics` private at `0700`, writes private `0600` status and launcher-log files, appends startup output and OpenCPN's exit status to `~/.cache/noaa-navionics/chartplotter.log`, rotates and syncs that log after 1 MB, keeps a synced private cache-directory launch lock stamped with the current Linux boot ID for the supervised OpenCPN session, rejects symlinked lock paths before reading or cleaning them, clears and syncs stale locks from previous boots or whose live PID is not actually the chartplotter launcher, leaves an existing live non-zombie OpenCPN process in place instead of starting a duplicate, asks X11 desktop sessions to disable screen blanking and DPMS sleep, retries failed startup readiness reports before launching OpenCPN, and restarts OpenCPN after a nonzero exit status up to 3 times by default. A clean status `0`, such as a deliberate manual close, is not restarted; set `NOAA_NAVIONICS_OPENCPN_RESTARTS=0` for no crash-restart attempts. After the final failed readiness attempt, it shows a Tkinter warning with failed checks when a desktop is available and does not start OpenCPN automatically; in the default fail-closed mode the warning button only dismisses the dialog. Set `NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes` only for deliberate manual fallback behavior where OpenCPN should launch despite failed readiness; production Pi verification rejects that override when proving the boat-ready startup path.

Manual launch:

```bash
noaa-navionics-start-chartplotter
```

Maintenance GUI:

```bash
noaa-navionics-gui
```

The GUI can load `~/.config/noaa-navionics/config.ini`, choose complete onboard chart packages, sync the configured chart package with the same complete-chart guard as the CLI, write `~/.cache/noaa-navionics/status.json`, run preflight checks with the configured chart, GPSD, baud, chart-age, and track-storage values, and register the configured chart/GPSD connection with OpenCPN. The OpenCPN config writer creates the config directory with private permissions when needed, refuses symlinked, misowned, or group/world-writable config directories, and forces private `0600` backup and replacement config files. Close OpenCPN before using the GUI's OpenCPN configuration button.

## Charts

Download Alaska charts:

```bash
noaa-navionics sync-charts
```

Each sync writes `noaa-navionics-manifest.json` next to the chart data. The manifest records the NOAA package URL, actual download URL, ZIP filename, download size, SHA-256, extraction path, ENC cell count, and chart freshness time. Onboard config rejects updates-only and catalog-only packages because they are not complete chart sources, and rejects broad, volatile, or system chart and track storage paths before any sync or GPX logging starts. Configured syncs require `[charts] min_free_gb` free space on writable chart storage before creating the chart output directory or starting a NOAA download. Keep the production default `[charts] force = yes` so scheduled refreshes download a current NOAA bundle instead of reusing an old cache. If you set `force = no`, an existing ZIP is reused for chart extraction only when it matches the previous verified manifest for the same NOAA package, preserving that manifest's timestamp and download URL; a cached ZIP with no prior verified manifest or a mismatched size/SHA-256 fails before extraction until you force a fresh download. ZIP extraction refuses packages with no ENC `.000` cells before replacing the previous chart directory. Completed ZIP downloads, extracted chart trees, manifest JSON, and the affected directory entries are synced before atomic replacement; manifest writes use unique temporary files. If a previous interrupted download left a fixed `.part` file beside the target ZIP, the next sync refuses to overwrite it and tells you to remove interrupted chart update debris first. If `[charts] keep_zip = no`, the ZIP is removed after extraction even when it was already cached. Syncs hold a synced `.noaa-navionics-download.lock` in the chart directory so a timer run and a manual run cannot update the same chart set at the same time; stale lock cleanup records PID and boot ID so an old lock is not removed while its owner is still running on the current boot. Preflight defaults to `[charts].output`, and `--charts PATH` explicitly checks another mounted chart directory. Preflight requires this manifest, fails if it is older than `max_age_days`, fails if stale chart-update staging, previous directories, partial `.part` files, or unexpected top-level ZIP files remain from an interrupted or manual sync, verifies that the recorded NOAA ZIP filename, package URL, and actual download URL still identify the configured chart package filename without an HTTPS downgrade, verifies that the recorded download path stays under chart storage and records a positive byte count and SHA-256 even when the ZIP is not retained, verifies that the recorded extraction path is still under the selected chart directory, verifies that the extraction still contains at least the recorded number of ENC cells, and fails if another top-level ENC chart directory remains beside the manifest extract. Storage configured under `/mnt`, `/media`, or `/run/media` must have an actual mounted device on that path or one of its parents, so an unplugged USB drive does not accidentally pass readiness against the Pi's SD card. If `[charts] keep_zip = yes`, preflight also requires the recorded retained ZIP to still exist, then verifies its recorded path, size, and SHA-256; that retained archive is the only top-level ZIP preflight allows.
The installed chart refresh service runs `sync-charts` with retries, a two-hour systemd start timeout, delayed service-level retry attempts, basic user-service hardening, and a 30-minute randomized timer delay so missed weekly refreshes do not always run immediately at boot beside chartplotter startup.
If a weekly chart refresh fails while the boat is offline, the status report records the failed service state but does not fail readiness on that alone; manifest age, package match, extraction path, and ENC cell checks decide whether the installed charts are still usable. A missing or disabled chart-refresh service still fails readiness because the Pi would no longer refresh charts automatically.
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

The status report includes readiness checks, NOAA Navionics user unit checks, parsed user unit-file `[Install]` targets, loaded user unit fragment-path and setting checks when systemd reports them, a recent valid current-boot GPX trackpoint check with a brief post-GPS wait for the logger to flush, launcher environment path integrity and settings with fail-closed startup and OpenCPN restart-setting checks, parsed OpenCPN chart/GPSD config state, desktop autostart and LightDM autologin state, GPSD startup config checks for local receivers, and GPSD socket/service plus chrony service state checks.
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
- `pgrep` available from `procps` so launcher and verifier process checks work
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
- Raspberry Pi thermal sensor or `vcgencmd measure_temp` readable, and temperature below the hard limit
- Fresh valid GPSD fix, or a fresh valid direct NMEA fix when intentionally using serial mode
- Chart refresh timer, including its bounded NOAA TCP connectivity check, track logger, boot readiness service, GPSD socket/service, and chrony service are in the expected state
- During the dock test after reboot, the status report and chartplotter launcher ran during the current boot, the launcher lock is owned by a live launcher process, and OpenCPN is running

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

The generated GPX files are stored under `~/charts/noaa-enc/tracks/` by default. The systemd service reads `[gps]` and `[tracking] output` from the onboard config and writes one file per UTC day, such as `track-20260629.gpx`; manual `--device`, `--baud`, `--gpsd`, and `--output` flags override the config for direct troubleshooting. If the service restarts on the same day it uses a numeric suffix instead of overwriting the earlier file. Daily rotated GPX files live in a private `0700` tracks directory and are created exclusively with private `0600` permissions, so an explicit existing output file fails instead of being truncated. The new file entry is synced after creation, service-created track files also use a private `0077` umask, and track files are flushed at every point and periodically synced to disk to reduce data loss after abrupt power loss. The logger skips invalid coordinates, untimestamped fixes, stale or future-dated timestamps, and weak satellite/HDOP fixes instead of writing them to GPX; single-file logging does not create the output file until the first accepted timestamped fix. A bounded diagnostic run such as `log-track --seconds 30` exits non-zero if no usable fix is written before the timeout. An untimed live GPSD logger waits and retries if GPSD is not accepting connections yet at boot, then keeps the connected stream unbounded through temporary GPSD quiet periods. After a successful connection, it exits non-zero if the GPS stream ends unexpectedly, so the installed `Restart=on-failure` service restarts instead of silently stopping after a transient GPSD or device interruption. The installed service drops per-fix stdout so normal GPS logging does not fill the systemd journal, while stderr warnings and failures still go to the service log. When systemd stops the logger during reboot or shutdown, SIGTERM handling closes the current GPX file before exit. If `[tracking] output` points somewhere other than the chart directory, preflight checks that separate destination has an existing writable parent and enough free space. By default, rotated track logs older than 90 days are pruned; set `[tracking] retention_days = 0` to disable pruning.
The track logger service uses a generous start-limit window so delayed GPSD or GPS hardware at boot does not permanently suppress GPX logging.

Systemd user service:

```bash
scripts/install_raspberry_pi.sh --skip-apt
systemctl --user daemon-reload
systemctl --user enable --now noaa-navionics-track.service
```

The service reads `~/.config/noaa-navionics/config.ini`.

## Chart Updates

Install the weekly chart refresh timer:

```bash
scripts/install_raspberry_pi.sh --skip-apt
systemctl --user daemon-reload
systemctl --user enable --now noaa-navionics.timer
```

Edit `~/.config/noaa-navionics/config.ini` if your cruising region is not Alaska.

## Boot-Time Readiness Report

Install a user service that writes the same readiness report at login:

```bash
scripts/install_raspberry_pi.sh --skip-apt
systemctl --user daemon-reload
systemctl --user enable noaa-navionics-preflight.service
```

The service writes `~/.cache/noaa-navionics/status.json`, disables systemd's start timeout so persisted cold-start GPS waits can finish, fails readiness on disabled, missing, failed, or unqueryable NOAA Navionics units, and retries briefly if GPSD is not producing a valid fix yet.

## Operational Notes

- Do not run the Python serial reader and OpenCPN against `/dev/ttyUSB0` at the same time. Use GPSD for shared production use.
- Keep paper charts or an independent backup navigation device on board.
- NOAA ENCs are official data, but this project is not certified navigation equipment.
- Test the full setup at the dock with the GPS outdoors before using it underway.
- Keep the Pi clock synchronized when online; GPS timestamps are UTC.
