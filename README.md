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
sudo apt install python3 python3-tk
python3 -m pip install --user .
```

For headless use, `python3-tk` is optional.

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

## CLI Examples

Download Alaska ENCs and extract them:

```bash
noaa-navionics download --state AK --output ~/charts/noaa-enc --extract
```

Download the 10-day update bundle:

```bash
noaa-navionics download --updates ten-days --output ~/charts/noaa-enc
```

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

Create the onboard config:

```bash
noaa-navionics init-config
```

Download the configured chart package:

```bash
noaa-navionics sync-charts
```

`sync-charts` writes `noaa-navionics-manifest.json` with SHA-256, source URL, extraction path, and sync time. `preflight` checks that manifest before the boat leaves the dock.

Preflight check:

```bash
noaa-navionics preflight
```

Live GPS check:

```bash
noaa-navionics gps-monitor --gpsd --once
```

Track logging:

```bash
noaa-navionics log-track
```

## Raspberry Pi Automation

A user-level systemd timer is included in `systemd/`.

```bash
mkdir -p ~/.config/systemd/user
cp systemd/noaa-navionics.service systemd/noaa-navionics.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now noaa-navionics.timer
```

Edit `~/.config/noaa-navionics/config.ini` if you want a bundle other than Alaska.

## Navigation Safety

This tool downloads and extracts chart data, checks GPS/chart readiness, and can log GPX tracks. OpenCPN should be used for ENC rendering and navigation workflows. This project is not certified navigation equipment and does not replace official navigation practices.
