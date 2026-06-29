# Sailboat Raspberry Pi Setup

This project is the chart-data, GPS-check, and operations wrapper for a Raspberry Pi chartplotter. Use OpenCPN for the actual chart display and route/navigation UI. OpenCPN is mature ENC chartplotter software; this Python project stays dependency-light and handles NOAA chart downloads, GPS health checks, and GPX track logging.

## Hardware Assumptions

- Raspberry Pi 4 with 4 GB RAM or newer
- 32 GB or larger SD card, preferably high-endurance
- Reliable 5 V power supply from the boat DC system
- USB or UART GPS that emits NMEA 0183
- Daylight-readable display
- Keyboard/mouse or touchscreen available for maintenance

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

Deploy and run the full onboard provisioning sequence:

```bash
scripts/deploy_to_pi.sh pi@raspberrypi.local --provision --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Provisioning runs GPSD setup, chart sync, OpenCPN chart/GPSD registration, user service enablement, user linger for reboot persistence, and a final status report on the Pi.

Verify the Raspberry Pi after deployment:

```bash
scripts/verify_pi.sh pi@raspberrypi.local
```

The verify script runs checks on the Pi over SSH, including architecture, installed commands, user units, config, and `noaa-navionics preflight`.
It also writes a JSON status report on the Pi at `~/.cache/noaa-navionics/status.json`.

Run the dock acceptance test before relying on the Pi underway:

```bash
scripts/dock_test_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

The dock test deploys and provisions the Pi, verifies readiness, reboots it, waits for SSH to return, and verifies readiness again. Use `--skip-deploy` to test an already-provisioned Pi.

Manual install:

```bash
sudo apt update
sudo sh -c 'echo deb https://deb.debian.org/debian bookworm-backports main >> /etc/apt/sources.list'
sudo apt update
sudo apt install python3 python3-venv python3-tk opencpn gpsd gpsd-clients
scripts/install_raspberry_pi.sh --skip-apt
```

The installer creates a private virtual environment at `~/.local/share/noaa-navionics/venv` and symlinks commands into `~/.local/bin`. The Python code uses only the standard library. `opencpn` renders NOAA ENCs, and `gpsd` shares one GPS feed between OpenCPN and this tool.

## Onboard Config

All services read one config file:

```bash
noaa-navionics init-config
nano ~/.config/noaa-navionics/config.ini
```

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
device = /dev/ttyUSB0
baud = 4800
gpsd_host = 127.0.0.1
gpsd_port = 2947

[tracking]
output = ~/charts/noaa-enc
```

## GPSD Setup

For a USB GPS, check the device name:

```bash
ls -l /dev/serial/by-id/
```

Configure GPSD with the stable device path:

```bash
scripts/configure_gpsd.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

The script backs up `/etc/default/gpsd`, writes the GPSD config, restarts GPSD, and updates `~/.config/noaa-navionics/config.ini`.

Restart and verify:

```bash
sudo systemctl enable --now gpsd
sudo systemctl restart gpsd
cgps
noaa-navionics gps-monitor --gpsd --once
```

`noaa-navionics configure-opencpn`, below, configures OpenCPN to use the GPSD network source from the onboard config.

## One-Step Provisioning

After `scripts/install_raspberry_pi.sh` has run on the Pi, commission the onboard setup with:

```bash
scripts/provision_sailboat_pi.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

This runs the same sequence expected before departure: initializes config if needed, configures GPSD, downloads the configured NOAA chart package, registers charts and GPSD in OpenCPN, enables user linger, enables the user timer and track/preflight services, and writes `~/.cache/noaa-navionics/status.json`.

## Startup

The installer copies a launcher to `~/.local/bin/noaa-navionics-start-chartplotter` and installs a desktop autostart entry for it. The launcher writes `~/.cache/noaa-navionics/status.json`, warns if readiness fails, and then starts OpenCPN.

Manual launch:

```bash
noaa-navionics-start-chartplotter
```

## Charts

Download Alaska charts:

```bash
noaa-navionics sync-charts
```

Each sync writes `noaa-navionics-manifest.json` next to the chart data. The manifest records the NOAA package URL, download size, SHA-256, extraction path, ENC cell count, and UTC sync time. Preflight requires this manifest and fails if it is older than `max_age_days`.

For another cruising area, use `--state`, `--cgd`, `--region`, or individual `--chart` downloads. Use the catalog search to identify specific cells:

```bash
noaa-navionics search-catalog "Cook Inlet"
```

Register the chart directory and GPSD connection in OpenCPN:

```bash
noaa-navionics configure-opencpn
```

This backs up `~/.opencpn/opencpn.conf` if it already exists, adds the configured chart directory under `[ChartDirectories]`, adds a GPSD network connection under `[Settings/NMEADataSource]`, and leaves OpenCPN closed. The chartplotter launcher starts OpenCPN with `-parse_all_enc` so OpenCPN processes available S-57 ENC charts on start.

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

Expected checks:

- Python 3.9+
- Tkinter available for the GUI
- OpenCPN installed
- Extracted ENC chart cells present
- Current chart manifest present
- OpenCPN configured with the chart directory
- OpenCPN configured with the GPSD network connection
- At least 2 GB free disk space
- No active Raspberry Pi under-voltage or throttling
- Raspberry Pi temperature below the hard limit
- Valid GPSD fix

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

The generated GPX files are stored under `~/charts/noaa-enc/tracks/`.

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

## Boot-Time Preflight

Install a user service that runs the same readiness check at login:

```bash
cp systemd/noaa-navionics-preflight.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable noaa-navionics-preflight.service
```

## Operational Notes

- Do not run the Python serial reader and OpenCPN against `/dev/ttyUSB0` at the same time. Use GPSD for shared production use.
- Keep paper charts or an independent backup navigation device on board.
- NOAA ENCs are official data, but this project is not certified navigation equipment.
- Test the full setup at the dock with the GPS outdoors before using it underway.
- Keep the Pi clock synchronized when online; GPS timestamps are UTC.
