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
The Raspberry Pi installer installs OpenCPN and GPSD on the Pi, and only adds the Bookworm backports apt source when the Pi OS codename is Bookworm.

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
On the Raspberry Pi it can also load the onboard config, sync the configured chart package, write the JSON status report, and register the configured chart/GPSD connection with OpenCPN.

## CLI Examples

Download Alaska ENCs and extract them:

```bash
noaa-navionics download --state AK --output ~/charts/noaa-enc --extract
```

For unreliable marina or hotspot networks, `download` and `sync-charts` accept `--retries` and `--retry-delay`.

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

Deployment refuses a dirty local worktree by default so the Pi's recorded source revision is trustworthy. Use `--allow-dirty` only for deliberate test deployments; those are recorded with a `-dirty` suffix.

Deploy and run the onboard provisioning sequence:

```bash
scripts/deploy_to_pi.sh pi@raspberrypi.local --provision --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Provisioning runs the first chart sync with retry settings suited to unreliable marina Wi-Fi. Use `--sync-retries` and `--sync-retry-delay` with `deploy_to_pi.sh` if the initial commissioning download needs a longer retry window.

Verify the Raspberry Pi after deployment:

```bash
scripts/verify_pi.sh pi@raspberrypi.local
```

Verification also checks that the chartplotter launcher, desktop autostart entry, GPSD startup options, and deployed source revision match the repo you are verifying from, including a `-dirty` suffix for deliberate dirty test deployments. The final status report retries briefly while GPSD gets its first fix.

Run the full dock acceptance test, including a reboot and post-reboot verification:

```bash
scripts/dock_test_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

On the Pi, configure GPSD with the GPS device:

```bash
scripts/configure_gpsd.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Use a `/dev/serial/by-id/` path when possible; verification checks that the configured GPSD device still exists.

On the Pi, `status-report` writes a JSON readiness artifact:

```bash
noaa-navionics status-report --output ~/.cache/noaa-navionics/status.json
```

The installed boot-time readiness service writes the same status report after login and retries briefly while the GPS gets its first fix. The report checks the NOAA Navionics user units, flags a failed chart sync service, and checks GPSD service state in addition to recording raw service diagnostics.
Deploy/install records the source revision so status reports show which code is running on the Pi.

Start the Pi chartplotter launcher:

```bash
noaa-navionics-start-chartplotter
```

Launcher output is appended to `~/.cache/noaa-navionics/chartplotter.log`.
The launcher rotates that log once it exceeds 1 MB so repeated unattended boots do not grow the cache indefinitely.

Create the onboard config:

```bash
noaa-navionics init-config
```

Download the configured chart package:

```bash
noaa-navionics sync-charts
```

Register the configured chart directory and GPSD connection with OpenCPN:

```bash
noaa-navionics configure-opencpn
```

`sync-charts` writes `noaa-navionics-manifest.json` with SHA-256, source URL, extraction path, ENC cell count, and sync time. `preflight` checks that the manifest is current and that the recorded extraction still contains at least the recorded ENC cell count before the boat leaves the dock.
Preflight also checks for a sane system clock because chart freshness and GPX timestamps depend on UTC time.

Preflight check:

```bash
noaa-navionics preflight
```

Live GPS check. GPSD readiness rejects stale timestamped fixes:

```bash
noaa-navionics gps-monitor --gpsd --once
```

For direct serial checks, `preflight --gps-device` accepts `--gps-baud`; `status-report` uses the baud from `~/.config/noaa-navionics/config.ini`.

Track logging:

```bash
noaa-navionics log-track
```

The systemd track logger writes daily GPX files and prunes rotated track logs older than `[tracking] retention_days` from the onboard config. The default is 90 days; set it to `0` to keep all rotated track logs.

## Raspberry Pi Automation

A user-level systemd timer is included in `systemd/`.
The Pi provisioning script enables user lingering so the timer and track logger can run after reboot without an interactive login.
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
