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

```bash
sudo apt update
sudo sh -c 'echo deb https://deb.debian.org/debian bookworm-backports main >> /etc/apt/sources.list'
sudo apt update
sudo apt install python3 python3-tk opencpn gpsd gpsd-clients
python3 -m pip install --user .
```

The Python code uses only the standard library. `opencpn` renders NOAA ENCs, and `gpsd` shares one GPS feed between OpenCPN and this tool.

## GPSD Setup

For a USB GPS, check the device name:

```bash
ls -l /dev/serial/by-id/
```

Edit `/etc/default/gpsd`:

```text
START_DAEMON="true"
USBAUTO="true"
DEVICES="/dev/serial/by-id/YOUR_GPS_DEVICE"
GPSD_OPTIONS="-n"
```

Restart and verify:

```bash
sudo systemctl enable --now gpsd
sudo systemctl restart gpsd
cgps
noaa-navionics gps-monitor --gpsd --once
```

Configure OpenCPN to use the GPSD network source at `localhost:2947`.

## Charts

Download Alaska charts:

```bash
noaa-navionics download --state AK --output ~/charts/noaa-enc --extract
```

For another cruising area, use `--state`, `--cgd`, `--region`, or individual `--chart` downloads. Use the catalog search to identify specific cells:

```bash
noaa-navionics search-catalog "Cook Inlet"
```

In OpenCPN, add the extracted chart directory under `~/charts/noaa-enc` to the chart directories list, then force a chart database rebuild.

## Pre-Departure Check

Run this before relying on the Pi:

```bash
noaa-navionics preflight --charts ~/charts/noaa-enc --gpsd
```

Expected checks:

- Python 3.9+
- Tkinter available for the GUI
- OpenCPN installed
- Extracted ENC chart cells present
- At least 2 GB free disk space
- Valid GPSD fix

If any check fails, treat the Pi as not ready.

## Track Logging

Manual:

```bash
noaa-navionics log-track --gpsd --output ~/charts/noaa-enc
```

The generated GPX files are stored under `~/charts/noaa-enc/tracks/`.

Systemd user service:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/noaa-navionics-track.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now noaa-navionics-track.service
```

## Chart Updates

Install the weekly chart refresh timer:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/noaa-navionics.service systemd/noaa-navionics.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now noaa-navionics.timer
```

Edit the service file if your cruising region is not Alaska.

## Operational Notes

- Do not run the Python serial reader and OpenCPN against `/dev/ttyUSB0` at the same time. Use GPSD for shared production use.
- Keep paper charts or an independent backup navigation device on board.
- NOAA ENCs are official data, but this project is not certified navigation equipment.
- Test the full setup at the dock with the GPS outdoors before using it underway.
- Keep the Pi clock synchronized when online; GPS timestamps are UTC.
