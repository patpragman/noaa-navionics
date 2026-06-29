# NOAA Navionics

NOAA Navionics is a small Python tool for downloading NOAA Electronic Navigational Charts (ENCs) for offline use on a laptop, Raspberry Pi, or other compute box. It uses only the Python standard library and NOAA's public S-57 ENC ZIP files.

This project is not affiliated with Garmin/Navionics and does not use proprietary Navionics data. The name here means a local, Navionics-like chart downloader backed by official NOAA data.

## What It Downloads

NOAA publishes ENCs in S-57 format through the Office of Coast Survey chart downloader:

- Full bundle: `All_ENCs.zip`
- Update bundles: `OneDay_ENCs.zip`, `TwoDays_ENCs.zip`, `OneWeek_ENCs.zip`, `TenDays_ENCs.zip`
- State bundles such as `AK_ENCs.zip`
- Coast Guard district bundles such as `17CGD_ENCs.zip`
- Region bundles such as `30Region_ENCs.zip`
- Individual chart ZIPs listed in `ENCProdCat_19115.xml`

State, Coast Guard district, and region selectors are validated against NOAA's current prepackaged ENC bundles so typos fail before a dock sync starts.

NOAA's downloader page says ENCs are available in S-57 format and points scripts to the XML product catalog. NOAA requests this citation for use of the data:

> Office of Coast Survey. (2001). NOAA Electronic Navigational Charts (ENC) [Dataset]. National Oceanic and Atmospheric Administration. Accessed [date]. https://doi.org/10.25923/jyyk-j845

## Install

On Raspberry Pi OS or Debian:

```bash
sudo apt update
sudo apt install python3 python3-venv python3-tk
scripts/install_raspberry_pi.sh
```

For headless use, `python3-tk` is optional.
For chartplotter use, use Raspberry Pi OS with Desktop/LightDM so OpenCPN can launch on the attached display after power-up.
The Raspberry Pi installer installs OpenCPN, GPSD, chrony, LightDM, and X11 display-power utilities on the Pi with noninteractive apt calls, ensures Raspberry Pi power diagnostic utilities are available for `vcgencmd`, and only adds the Bookworm backports apt source when the Pi OS codename is Bookworm. Provisioning configures graphical autologin only after GPSD, charts, and the onboard config are commissioned.
Run install, deployment, GPS setup, provisioning, verification, and dock tests as the normal Pi desktop user, not `root`; the scripts use `sudo` only for the specific system changes they need.
The optional SSH deploy directory must be a dedicated `noaa-navionics` directory because deployment uses `rsync --delete` to keep the Pi copy exact.

## Tkinter GUI

Run:

```bash
python3 -m noaa_navionics.gui
```

or, after installing:

```bash
noaa-navionics-gui
```

The GUI lets you choose a bundle type, output directory, ZIP extraction, and overwrite behavior.
On the Raspberry Pi it can also load the onboard config, run preflight with the configured chart, GPSD, baud, chart-age, and track-storage values, sync the configured chart package with the same complete-chart guard as the CLI, write the JSON status report, and register the configured chart/GPSD connection with OpenCPN.

## CLI Examples

Download Alaska ENCs and extract them:

```bash
noaa-navionics download --state AK --output ~/charts/noaa-enc --extract
```

For unreliable marina or hotspot networks, `download` and `sync-charts` accept `--retries` and `--retry-delay`.
Retries must be at least `1`; retry delays must be `0` seconds or greater.

Download the 10-day update bundle:

```bash
noaa-navionics download --updates ten-days --output ~/charts/noaa-enc
```

Update bundles are useful for manual maintenance but are not complete chart sets. For the onboard Pi config, use a complete package such as `state`, `cgd`, `region`, `chart`, or `all`.

Download Coast Guard District 17:

```bash
noaa-navionics download --cgd 17 --output ~/charts/noaa-enc --extract
```

Find individual charts in NOAA's product catalog:

```bash
noaa-navionics search-catalog "Cook Inlet" --limit 10
```

Download one individual ENC:

```bash
noaa-navionics download --chart US5AK3CM --output ~/charts/noaa-enc --extract
```

## Sailboat Raspberry Pi Use

For a production-style Raspberry Pi chartplotter setup, use this project with OpenCPN and GPSD:

- OpenCPN renders and navigates with NOAA ENC charts.
- GPSD shares one GPS peripheral between OpenCPN and this tool.
- `noaa-navionics` downloads NOAA charts, checks readiness, monitors GPS, and logs GPX tracks.

See [docs/sailboat-pi.md](docs/sailboat-pi.md).

Deploy to a Raspberry Pi over SSH:

```bash
scripts/deploy_to_pi.sh pi@raspberrypi.local
```

Deployment refuses a dirty local worktree by default so the Pi's recorded source revision is trustworthy. Use `--allow-dirty` only for deliberate test deployments; those are recorded with a `-dirty` suffix. The deploy script writes the remote source revision through a synced temporary file and atomic replace before the Pi installer records it for status reports.

Deploy and run the onboard provisioning sequence:

```bash
scripts/deploy_to_pi.sh pi@raspberrypi.local --provision --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Provisioning runs the first chart sync with retry settings suited to unreliable marina Wi-Fi. Use `--sync-retries` and `--sync-retry-delay` with `deploy_to_pi.sh` or `dock_test_pi.sh` if the initial commissioning download needs a longer retry window. Use `--gps-seconds N` if the attached GPS receiver needs more time for a cold-start fix during commissioning.
The deploy, provisioning, and dock-test scripts reject invalid retry, delay, GPS wait, and reboot timeout values before starting remote work.
Provisioning persists the chosen GPS wait in `~/.config/noaa-navionics/launcher.env` so the boot readiness service and desktop chartplotter launcher use the same cold-start window after reboot.
Provisioning also configures chrony to use GPSD's message-based `SHM 0` time source so a Pi without an RTC can synchronize its clock from the GPS when network time is unavailable. Readiness requires chrony to report the GPS refclock as selected or combined, not merely present.
Onboard config chart and track output paths must be absolute or start with `~`, and they cannot be broad system or home directories such as `/`, `~`, `/home`, `/etc`, `/var`, `~/.config`, or `~/.cache`.
For production provisioning, use the default onboard config at `~/.config/noaa-navionics/config.ini`; custom `--config` paths are rejected unless both services and desktop autostart are deliberately skipped for manual testing.
When `deploy_to_pi.sh --provision` is run with `--skip-autologin`, that choice is applied to both installation and provisioning. `--skip-services` requires `--skip-autologin` so the Pi is not left with desktop chartplotter autostart enabled but no readiness or track-logging services.
Use `--skip-gpsd` only when the onboard config already names a commissioned local GPSD receiver; provisioning rejects missing, placeholder, remote, volatile, or nonexistent GPS config before enabling unattended startup.
Use `--skip-gps-time` only when chrony already contains this project's GPSD `SHM 0` time-source block; provisioning rejects missing GPS time configuration before enabling unattended startup.
Use `--skip-sync` only when the onboard config already points at a fresh, complete NOAA chart manifest; provisioning rejects missing or incomplete chart data before enabling unattended startup.
Use `--no-device-check` only for manual testing with both `--skip-services` and `--skip-autologin`; production provisioning requires the GPS receiver path to exist before unattended startup is enabled.

Verify the Raspberry Pi after deployment:

```bash
scripts/verify_pi.sh pi@raspberrypi.local
```

Use `--gps-seconds N` here too if the GPS receiver needs a longer fix window.
Verification also checks that the chartplotter launcher contains the readiness gate and OpenCPN ENC parsing command, that the persisted launcher GPS wait matches the verification wait, that the desktop autostart entry is enabled and not marked hidden/disabled, that LightDM autologin and the graphical boot target are configured for the deployed user, that Raspberry Pi power diagnostics are available, that the installed and loaded user systemd units contain the expected commands and loaded chart-refresh timer/timeout/retry/start-limit, track logger restart/start-limit, and boot-readiness restart/start-limit settings, that the GPX track logger is enabled, active, and writing a recent timestamped current-boot trackpoint, and that GPSD and chrony are enabled and active. It also checks GPSD startup options, GPSD device path, chrony GPSD time-source config, a usable chrony GPS source within the configured GPS wait, deployed source revision, configured free-space threshold, and generated JSON readiness artifact match the repo you are verifying from, including the artifact's embedded source revision check, config path, normalized config values and chart sync flags, manifest path, manifest timestamp provenance, NOAA ZIP filename matching the onboard config, package URL, download URL, download path under chart storage, cache-reuse flag, positive download byte count, SHA-256, extraction path, ENC cell count, full core readiness/service/loaded-setting check names, and a `-dirty` suffix for deliberate dirty test deployments. In strict chartplotter-started mode, verification first checks that the existing status artifact was generated during the current boot. The final status report retries briefly while GPSD gets its first fix.

Run the full dock acceptance test, including a reboot and post-reboot verification:

```bash
scripts/dock_test_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

For deliberate test deployments from a dirty worktree, pass `--allow-dirty` to the dock test as well.
The dock test requests reboot with noninteractive `sudo -n reboot` and fails clearly if the SSH user cannot reboot without a password prompt. After the reboot, the dock test requires the Pi boot ID to change, then uses the stricter verify mode that waits briefly for desktop autostart, requires the existing readiness status report and chartplotter launcher log to be fresh for the current boot, and requires an `opencpn` process owned by the deployed user to remain running through a short stability check.
`--no-reboot` is only a pre-reboot smoke check; it deliberately skips the power-cycle and chartplotter-autostart proof required before relying on the Pi underway.
`--skip-autologin` is rejected for the rebooted dock acceptance test because that test must prove chartplotter autostart after a power cycle.

On the Pi, configure GPSD with the GPS device:

```bash
scripts/configure_gpsd.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Use a single `/dev/serial/by-id/...` symlink name when possible; config validation, GPSD setup, and verification fail volatile USB names such as `/dev/ttyUSB0` or `/dev/ttyACM0`, reject nested by-id paths, require the configured path to be a character device when device checks are enabled, and reject unrecognized device paths that are not one of the documented stable aliases.
The installer syncs installed command symlinks, launchers, source revision, and user systemd unit files to disk. Provisioning syncs the desktop autostart entry after commissioning succeeds. The GPSD setup script syncs `/etc/default/gpsd` and its backup to disk, then updates the onboard `config.ini` through a synced atomic replacement. `scripts/configure_gps_time.sh` backs up and syncs `/etc/chrony/chrony.conf`, adds a managed GPSD `SHM 0` refclock block, restarts chrony, then restarts GPSD so the daemons reconnect in the right order.

On the Pi, `status-report` writes a JSON readiness artifact:

```bash
noaa-navionics status-report --output ~/.cache/noaa-navionics/status.json
```

Status reports include the current Linux boot ID and are written through a unique temporary file and atomic replace, so overlapping launcher and readiness-service writes cannot corrupt the JSON artifact.
The status JSON is synced to disk along with the replacement directory entry.
The installed boot-time readiness service writes the same status report after login, reads the persisted GPS wait setting, disables systemd's start timeout so that configured cold-start GPS waits control each run, and keeps retrying through a generous start-limit window if GPSD, chrony, or the receiver come up slowly after power-on. The report checks the NOAA Navionics user units, verifies their loaded restart/timer/start-limit settings when systemd reports them, fails readiness on failed or unqueryable required units, verifies `/etc/default/gpsd` for exactly the configured local GPS device and immediate polling, and checks GPSD and chrony service state in addition to recording raw service diagnostics. The weekly chart-refresh timer uses a 30-minute randomized delay for catch-up runs after boot. A failed weekly chart-refresh unit is reported but does not by itself fail readiness; the chart manifest age and contents decide whether the onboard charts are usable.
Deploy/install records the source revision through synced atomic file writes so status reports show which code is running on the Pi. On Raspberry Pi targets, readiness fails if that deployed source revision is missing or recorded as `unknown`.
The strict dock-test verifier checks the pre-existing report's boot ID before it regenerates the report, proving the post-reboot launcher or readiness service already wrote a current-boot artifact.

Start the Pi chartplotter launcher:

```bash
noaa-navionics-start-chartplotter
```

Launcher output is appended to `~/.cache/noaa-navionics/chartplotter.log`, including OpenCPN's exit status if the chartplotter process stops.
The launcher rotates that log once it exceeds 1 MB so repeated unattended boots do not grow the cache indefinitely.
It reads `NOAA_NAVIONICS_GPS_SECONDS` and optional `NOAA_NAVIONICS_WARNING_SECONDS` from `~/.config/noaa-navionics/launcher.env` or the process environment before writing its startup readiness report.
If OpenCPN is already running for the same user, a repeated launcher invocation leaves the existing chartplotter instance in place instead of starting a second one.
The launcher also uses a cache-directory lock so overlapping desktop startup attempts cannot race each other before OpenCPN is visible; if an old lock points at an unrelated reused PID, it clears the stale lock and continues startup.
When an X desktop session is present, the launcher also asks the display server to disable screen blanking and DPMS sleep before starting OpenCPN.
Preflight and Pi verification require `xset` from `x11-xserver-utils` so this display-awake step is available.
If readiness fails in a desktop session, the launcher shows a Tkinter warning listing failed checks and the status report path before starting OpenCPN anyway.
If those display power commands fail during chartplotter autostart, or if the current-boot launcher log shows OpenCPN already exited, the strict Pi startup verifier fails the dock test.
The provisioning script configures LightDM autologin so the desktop autostart entry can launch the chartplotter after boot. Use `--skip-autologin` only for deliberate headless or development deployments.

Create the onboard config:

```bash
noaa-navionics init-config
```

Initial config writes use a unique temporary file, sync to disk, and atomically replace `config.ini`.

Download the configured chart package:

```bash
noaa-navionics sync-charts
```

Register the configured chart directory and GPSD connection with OpenCPN:

```bash
noaa-navionics configure-opencpn
```

`configure-opencpn` adds the GPSD network connection only when `[gps] mode = gpsd`; in serial mode it configures charts and skips GPSD. Existing OpenCPN config backups and replacement config files are synced to disk, and replacement writes use unique temporary files. Preflight requires OpenCPN's configured chart directory to exist so stale chart paths or missing storage do not pass readiness.
For onboard `gpsd` mode, `gpsd_host` must be local (`127.0.0.1`, `localhost`, or `::1`) and `gps.device` must name the attached receiver through a stable path such as one `/dev/serial/by-id/...` symlink name, `/dev/serial0`, `/dev/serial1`, or `/dev/gps`, so OpenCPN, readiness checks, and the installed GPSD service all use the Pi's GPS peripheral.

`sync-charts` writes `noaa-navionics-manifest.json` with SHA-256, source package URL, actual download URL, NOAA ZIP filename, extraction path, ENC cell count, and chart freshness time. Onboard config rejects updates-only and catalog-only packages because they are not complete chart sources, and it rejects broad chart or track storage paths before any sync or GPX logging starts. The production default is `force = yes` so scheduled refreshes download a current NOAA bundle instead of reusing an old cache. If you set `force = no`, reusing a ZIP preserves the previous matching manifest timestamp; a cached ZIP with no prior verified manifest is marked unverified and fails preflight until you force a fresh download. Chart extraction refuses ZIPs with no ENC `.000` cells before replacing the previous extraction. Completed ZIP downloads, extracted chart trees, manifest JSON, and the affected directory entries are synced before atomic replacement; manifest writes use unique temporary files. If ZIP retention is disabled, the ZIP is removed after extraction even when the ZIP was already cached. Syncs take a chart-directory lock so a timer run and a manual run cannot update the same chart set at the same time. `preflight` checks that the manifest is current, that no stale chart-update staging, previous directories, or partial `.part` files remain from an interrupted sync, that the recorded NOAA ZIP filename, source package URL, and actual download URL match the configured chart package, that the recorded extraction is still under the configured chart directory, that it still contains at least the recorded ENC cell count, and that no other top-level ENC chart directories remain beside the manifest extract before the boat leaves the dock. It also requires at least `[charts] min_free_gb` free space on writable chart storage and separate track storage. When the kept ZIP is still present, preflight also requires a positive recorded byte count and SHA-256, then verifies its recorded path, size, and SHA-256.
Preflight also checks for a sane system clock because chart freshness and GPX timestamps depend on UTC time. On a Raspberry Pi, preflight also requires `timedatectl` to report the system clock synchronized before relying on chart age and GPX timestamps.

Preflight check:

```bash
noaa-navionics preflight
```

Live GPS check. GPSD readiness rejects stale, future-dated, and untimestamped fixes:

```bash
noaa-navionics gps-monitor --gpsd --once
```

For direct serial checks, `preflight --gps-device` accepts `--gps-baud`; `status-report` uses the baud from `~/.config/noaa-navionics/config.ini`. Direct serial readiness rejects stale, future-dated, and untimestamped NMEA fixes too.
GPS readiness rejects non-finite coordinates, coordinates outside valid latitude/longitude bounds, and invalid `0,0` coordinates. When a receiver reports quality fields, it also rejects weak fixes with fewer than four satellites or HDOP above 5. GPSD readiness merges recent SKY satellite/HDOP reports with TPV position fixes before applying that gate.
NMEA fractional timestamps are normalized across second, minute, and UTC day rollovers before freshness checks and GPX logging.

Track logging:

```bash
noaa-navionics log-track
```

The systemd track logger writes daily GPX files using `[gps]` and `[tracking] output` from the onboard config, and prunes rotated track logs older than `[tracking] retention_days`. Manual `--device`, `--baud`, `--gpsd`, and `--output` flags override the config for direct troubleshooting. GPX files are created exclusively so existing tracks are not silently overwritten, the new file entry is synced after creation, points are periodically synced to disk to reduce data loss after abrupt power loss, and SIGTERM/SIGINT shutdown closes the current GPX file before exit. The track logger skips invalid coordinates and weak satellite/HDOP fixes instead of writing them to GPX, and single-file logging does not create an output file until the first accepted fix. The installed service drops per-fix stdout so normal GPS logging does not fill the systemd journal, while stderr warnings and failures still go to the service log. If `[tracking] output` is on separate storage from the charts, preflight also checks that track destination has an existing writable parent and enough free space. The default retention is 90 days; set it to `0` to keep all rotated track logs.
The track logger service uses a generous start-limit window so delayed GPSD or GPS hardware at boot does not permanently suppress GPX logging.

## Raspberry Pi Automation

A user-level systemd timer is included in `systemd/`.
The installer copies the chart refresh timer and track logger unit files but leaves them disabled. The Pi provisioning script enables user lingering, reloads refreshed unit files, clears stale failed states for the track logger and boot readiness service, starts the chart refresh timer, restarts the track logger after GPSD setup, and starts the boot readiness service immediately so updated service settings are applied only after the onboard config, charts, and GPSD are commissioned. The timer, readiness service, and track logger can then run after reboot without an interactive login.
The provisioning script also configures the Pi to boot to `graphical.target` and autologin through LightDM as the deployed user, so the desktop autostart entry can bring up OpenCPN after a power cycle.
The included chart sync service retries transient network failures, allows up to two hours for slow NOAA downloads, and asks systemd for delayed retry attempts if the whole run still fails.

```bash
mkdir -p ~/.config/systemd/user
cp systemd/noaa-navionics.service systemd/noaa-navionics.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now noaa-navionics.timer
```

Edit `~/.config/noaa-navionics/config.ini` if you want a bundle other than Alaska.

## Development Checks

Run the source and script checks without installing anything locally:

```bash
scripts/check.sh
```

## Navigation Safety

This tool downloads and extracts chart data, checks GPS/chart readiness, and can log GPX tracks. OpenCPN should be used for ENC rendering and navigation workflows. This project is not certified navigation equipment and does not replace official navigation practices.
