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
For chartplotter use, use Raspberry Pi OS with Desktop/LightDM and an installed X11 session so OpenCPN can launch on the attached display after power-up.
The Raspberry Pi installer starts with a private `0077` umask, installs rsync, OpenCPN, GPSD, GPSD client tools, chrony, LightDM, X11 display-power utilities, process lookup tools from `procps`, and local Python build tooling on the Pi with noninteractive apt calls, rejects symlinked, misowned, or group/world-writable user install paths, replaces its guarded private virtual environment before installing this repo with pip index access disabled and without build isolation or PEP 517 so it does not unexpectedly fetch Python packages from PyPI, syncs the venv tree before atomically replacing command links, helper launchers, and user systemd unit files, ensures a trusted root-owned `vcgencmd` is available for Raspberry Pi power diagnostics, and only adds the Bookworm backports apt source as a synced drop-in when the Pi OS codename is Bookworm after validating the root-owned apt source path and ancestors. Installer package setup resolves sudo, apt-get, and Python through trusted root-owned command checks before running package changes or installer Python helpers. Installer sync helpers use no-follow opens for directories and regular files. Installer revalidates user directories after creating or tightening them before placing temporary files there, then revalidates helper, unit, and command-link targets immediately before promotion. Installer venv cleanup refuses Python runtimes without symlink-attack-resistant `shutil.rmtree` before removing the previous private virtual environment, and venv tree sync skips symlinked directories and files instead of following them while flushing the install to disk. Verification requires the installed CLI and GUI command symlinks to resolve into that private venv, requires helper launchers to be trusted user-owned executables, and rejects writable or misowned parent directories for installed commands, app data, app config, desktop autostart, and user systemd units. It accepts the GPSD client tools as `gpsd-clients` or `gpsd-tools` depending on the OS package split and verifies a trusted root-owned `cgps` is available for manual GPS checks. Provisioning and the GPSD, chrony GPS-time, and desktop autologin helpers also start with a private `0077` umask and pin `PATH` to trusted system command directories before running setup commands; provisioning resolves sudo, systemctl, loginctl, and Python through trusted root-owned command checks before enabling services, linger, or Python-backed provisioning helpers, the helpers resolve sudo, systemctl, and Python through trusted root-owned command checks before root file or service changes, the chartplotter launcher resolves Python to a trusted executable path before running descriptor-safe helper snippets, and provisioning configures graphical autologin only after GPSD, charts, and the onboard config are commissioned.
Run install, deployment, GPS setup, provisioning, verification, and dock tests as the normal Pi desktop user, not `root`; SSH targets must use plain `user@host` with a normal local username and DNS/IP-style hostname, without scp-style paths, ports, shell punctuation, whitespace, or quotes, and the scripts use `sudo` only for the specific system changes they need.
The optional SSH deploy directory must be a dedicated `noaa-navionics` directory under a regular, user-owned, non-writable, non-symlinked path, and parent-directory components such as `..` are rejected because deployment keeps the Pi copy exact. It uses `rsync --delete` when available and falls back to a guarded tar-over-SSH bootstrap copy for a fresh Pi that does not have `rsync` installed yet.

## Tkinter GUI

Run:

```bash
python3 -m noaa_navionics.gui
```

or, after installing:

```bash
noaa-navionics-gui
```

The GUI lets you choose a complete onboard chart bundle type, output directory, ZIP extraction, and overwrite behavior; manual GUI downloads check writable chart storage and free space before creating the output directory or starting a NOAA download.
On the Raspberry Pi it can also load the onboard config, run preflight with the configured chart, GPSD, baud, chart-age, and track-storage values, sync the configured chart package with the same complete-chart guard as the CLI, write the JSON status report, and register the configured chart/GPSD connection with OpenCPN.

## CLI Examples

Download Alaska ENCs and extract them:

```bash
noaa-navionics download --state AK --output ~/charts/noaa-enc --extract
```

For unreliable marina or hotspot networks, `download` and `sync-charts` accept `--retries` and `--retry-delay`.
Retries must be at least `1`; retry delays must be `0` seconds or greater.
Chart archive, extraction, and manifest promotion revalidate output paths immediately before replacement, so a swapped symlink or unsafe target does not become the live offline chart set.

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

Deployment refuses a dirty local worktree by default so the Pi's recorded source revision is trustworthy. Use `--allow-dirty` only for deliberate test deployments; those are recorded with a `-dirty` suffix. Direct installs run on a dirty Pi worktree also record the same `-dirty` suffix unless a deploy-provided `.source-revision` is present. The deploy script checks for trusted executable local deployment commands, checks remote `python3`, validates remote deploy command paths, ownership, permissions, and parent directories, prefers `rsync` when it is available on both machines, and otherwise bootstraps the repo with local and remote `tar`. It uses the validated absolute local and remote `rsync` or `tar` paths for the actual copy command, and uses the validated absolute remote `python3` path for deployment staging and source-revision helpers. Both copy paths skip local build/cache directories and downloaded chart artifacts, reject system or volatile remote directories such as `/tmp/noaa-navionics`, write into a validated sibling staging directory under a trusted deployment parent, and promote it only after the transfer succeeds. If a prior deploy was interrupted after the old tree moved to `.previous`, the next deploy restores that previous tree before creating a new staging copy, so a failed deploy does not empty or erase the last good deployment. The script writes the remote source revision through a synced temporary file and atomic replace only after the promoted repo path is a trusted directory, then reopens that promoted revision file through a no-follow descriptor before syncing it, before the Pi installer records it for status reports. Deployment sync helpers use no-follow directory opens; provisioning and startup sync helpers use no-follow opens for directories and regular files. Deploy, verify, and dock-test SSH transports require root-owned executable local commands from trusted system directories for `ssh`, `git`, and any local `rsync` or `tar` copy path, execute the validated local command paths for Git, SSH, and copy operations, and use batch mode with connection timeouts and keepalives so missing SSH credentials, offline Pis, or dead long-running links fail clearly instead of opening password prompts or hanging silently; remote install and provisioning commands also run without allocating a pseudo-terminal so deployment works cleanly from non-interactive shells.
Remote deployment cleanup refuses Python runtimes without symlink-attack-resistant `shutil.rmtree` before removing stale staging or previous deployment directories.

Deploy and run the onboard provisioning sequence:

```bash
scripts/deploy_to_pi.sh pi@raspberrypi.local --provision --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Provisioning runs the first chart sync with retry settings suited to unreliable marina Wi-Fi. Use `--sync-retries` and `--sync-retry-delay` with `deploy_to_pi.sh` or `dock_test_pi.sh` if the initial commissioning download needs a longer retry window. The unattended Pi default waits 60 seconds for a GPS fix at startup; use `--gps-seconds N` if the attached GPS receiver needs a different cold-start window during commissioning. Use `--opencpn-restarts N` and `--opencpn-restart-delay N` to tune how many times the desktop launcher restarts OpenCPN after nonzero exits.
The deploy, provisioning, and dock-test scripts reject invalid retry, delay, GPS wait, OpenCPN restart, and reboot timeout values before starting remote work.
Provisioning persists the chosen GPS wait, the explicit fail-closed startup policy, readiness retry defaults, warning duration, and OpenCPN restart policy in the private `0600` file `~/.config/noaa-navionics/launcher.env` through a synced temporary file and atomic replacement so the boot readiness service and desktop chartplotter launcher use the same commissioned startup policy after reboot. The boot readiness service does not use systemd `EnvironmentFile`; it passes that launcher environment path to `status-report`, which reads the GPS wait through the same no-follow, private-file validation used by status reports.
Provisioning requires the installed private `~/.local/bin/noaa-navionics` symlink to resolve into `~/.local/share/noaa-navionics/venv/bin/noaa-navionics` before it runs chart sync, OpenCPN configuration, service setup, or status reporting.
Provisioning also configures chrony to use GPSD's message-based `SHM 0` time source so a Pi without an RTC can synchronize its clock from the GPS when network time is unavailable. Readiness requires chrony to report the GPS refclock as selected or combined, not merely present.
Before reporting success, provisioning now verifies the chart refresh timer and GPX track logger are enabled and active, and that the boot-readiness service's latest run completed successfully.
Onboard config reads use a no-follow descriptor and reject symlinked path components, non-regular files, writable files, or files owned by the wrong user before trusting chart, GPS, or track settings. Chart and track output paths must be absolute or start with `~`, and they cannot be broad system, volatile, or home directories such as `/`, `~`, `/home`, `/etc`, `/etc/noaa-navionics`, `/tmp/noaa-navionics`, `/var`, `~/.config`, or `~/.cache`. Use a dedicated real directory under the Pi user's home or mounted storage under `/mnt`, `/media`, or `/run/media`; readiness rejects symlinked storage paths, and GPX logging rejects symlinked track-output parent components and symlinked GPX output files before writing track files.
For production provisioning, use the default onboard config at `~/.config/noaa-navionics/config.ini`; custom `--config` paths are rejected unless both services and desktop autostart are deliberately skipped for manual testing.
When `deploy_to_pi.sh --provision` is run with `--skip-autologin`, that choice is applied to both installation and provisioning. `--skip-services` and `--skip-autologin` must be used together for manual or headless testing, so the Pi is not left with only part of the unattended startup path enabled.
Use `--skip-gpsd` only when the onboard config already names a commissioned local GPSD receiver; if `--device` is supplied, that existing config must name the same receiver. Production provisioning reads the existing onboard GPS config only after a no-follow descriptor confirms the opened file is still regular, user-owned, and not group/world-writable. It rejects missing, symlinked, non-regular, misowned, group/world-writable, placeholder, mismatched, remote, volatile, or nonexistent GPS config and disabled or inactive `gpsd.socket` or `gpsd.service` before enabling unattended startup. This does not skip chrony GPS time setup; add `--skip-gps-time` only when that is already commissioned too.
Use `--skip-gps-time` only when chrony already contains this project's uncommented GPSD `SHM 0` time-source block; production provisioning rejects missing, symlinked, non-regular, misowned, group/world-writable, or commented-out GPS time configuration and disabled or inactive `chrony.service` before enabling unattended startup.
Use `--skip-sync` only when the onboard config already points at a fresh, complete NOAA chart manifest on trusted writable chart storage; provisioning rejects missing, incomplete, symlinked, misowned, or group/world-writable chart storage before enabling unattended startup.
Use `--no-device-check` only for manual testing with both `--skip-services` and `--skip-autologin`; production provisioning requires the GPS receiver path to exist before unattended startup is enabled.

Verify the Raspberry Pi after deployment:

```bash
scripts/verify_pi.sh pi@raspberrypi.local
```

Use `--gps-seconds N` here too if the GPS receiver needs a longer fix window. Use `--opencpn-restarts N` and `--opencpn-restart-delay N` here when verifying a non-default launcher restart policy.
Verification refuses a dirty local worktree by default, then runs over batch-mode SSH with a connection timeout, keepalives, and no pseudo-terminal, so it works cleanly from non-interactive deployment shells and fails clearly on dead links. It pins its remote command path to trusted system directories before launching the remote verifier and before checking system services, loaded user-unit properties, and readiness evidence. It also checks that the installed CLI and GUI command symlinks resolve into the private venv, that the command, app data, app config, desktop autostart, and user systemd parent directories are owned by the deployed user and not group/world-writable, that the root-owned OpenCPN command plus LightDM, GPSD, and chrony config parent-directory path components are not symlinks or group/world-writable, that the chartplotter launcher contains the readiness gate, synced current-boot launch-lock handling, trusted OpenCPN binary resolver, and OpenCPN ENC parsing command, that the persisted launcher GPS wait and OpenCPN restart policy match the verification values, that the onboard app config, OpenCPN config file, source revision, launcher environment, desktop autostart, LightDM autologin, GPSD, chrony, helper launchers, and user systemd unit files are regular trusted paths with the expected owner, no symlinked path components, and no group/other write bits, that the OpenCPN config parent directory is private `0700`, that the desktop autostart entry is enabled and not marked hidden/disabled, that LightDM autologin, the selected installed X11 session, Tkinter readiness-warning support, and the graphical boot target are configured for the deployed user, that Raspberry Pi power diagnostics and a readable Pi thermal sensor or `vcgencmd measure_temp` output are available, that the installed and loaded user systemd units execute the installed `%h/.local/bin/noaa-navionics` command with the expected arguments, loaded fragment paths, install targets, installed unit-file directives, private temp directories, read-only system filesystem protection, private file umasks, and loaded chart-refresh timer/timeout/retry/start-limit, track logger restart/start-limit, and boot-readiness restart/start-limit settings, that user linger is enabled for reboot-persistent user services, that the enabled boot-readiness service has actually run successfully, that the GPX track logger is enabled, active, and writing a recent valid timestamped current-boot trackpoint to a regular private GPX file owned by the deployed user in a private tracks directory, and that GPSD socket/service, GPSD client tools, and chrony are available and active. It also checks GPSD startup options, GPSD device path, uncommented chrony GPSD time-source config, a usable chrony GPS source within the configured GPS wait, deployed source revision, configured free-space threshold, and generated JSON readiness artifact match the repo you are verifying from, parsing that status artifact only through the no-follow descriptor it verified, including the artifact's embedded source revision check, config path, user-linger state, launcher settings matching a no-follow descriptor read of the same inspected live private launcher environment and expected restart policy, status-reported user unit, OpenCPN config, desktop autostart, and LightDM autologin owner/mode matching the live files and unit directory, OpenCPN chart and GPSD settings matching the live OpenCPN config, desktop autostart and LightDM autologin settings matching the live desktop files, normalized config values and chart sync flags, GPX track-log directory, private directory mode, private latest file mode, and file path matching the live config, manifest path, manifest timestamp provenance, NOAA ZIP filename matching the onboard config, package URL, download URL, download path under chart storage, cache-reuse flag, positive download byte count, SHA-256, extraction path, exact live regular non-symlink ENC cell count, full core readiness/service/unit-file/loaded-setting/service-run check names, and a `-dirty` suffix only when `--allow-dirty` is passed for a deliberate dirty test deployment. In strict chartplotter-started mode, verification also requires LightDM to be active, checks that the active launcher log and any rotated launcher log are trusted regular user files, parses the active launcher log only through the no-follow descriptor it verified, and first checks that the existing status artifact was generated during the current boot. The final status report retries briefly while GPSD gets its first fix.

Run a no-deploy, no-reboot pre-departure check on an already commissioned Pi:

```bash
scripts/pre_departure_check_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

This is a live Pi check for the current startup state before leaving the dock. It requires strict chartplotter-started verification, exact GPS receiver matching, chart readiness, GPSD, chrony GPS time, and GPX track logging, but it does not replace the rebooted dock acceptance test for new or changed installations.

Refresh the Pi's NOAA charts while you still have dock Wi-Fi:

```bash
scripts/refresh_pi_charts.sh pi@raspberrypi.local --retries 5 --retry-delay 30
```

The refresh helper validates the SSH target, waits for NOAA TCP connectivity from the Pi, then runs `sync-charts` on the Pi's installed `~/.local/bin/noaa-navionics` with the onboard config. Add `--force` only for a deliberate redownload. No chart data is downloaded on the local computer.

Collect a diagnostic support bundle from the Pi before changing anything:

```bash
scripts/collect_pi_support_bundle.sh pi@raspberrypi.local
```

The support bundle is a local `.tgz` containing Pi-side NOAA Navionics config, status reports, configured chart manifests and storage listings, launcher logs, installed user units, selected OpenCPN/GPSD/chrony/LightDM config files when readable, recent relevant journal output, service state, device listings, disk space, and Pi health command output. It is read-only diagnostic evidence; it does not deploy, reboot, start services, download charts, or copy NOAA chart archives, extracted ENC cells, or GPX track contents.

Shut the Pi down cleanly before cutting boat power:

```bash
scripts/shutdown_pi_safely.sh pi@raspberrypi.local --confirm
```

The shutdown helper validates the SSH target, trusted remote `sync`, `sudo`, and `systemctl` command paths, flushes filesystem buffers, and requests `systemctl poweroff` through noninteractive sudo. Use `--dry-run` to prove that path without powering off.

Run the full dock acceptance test, including a reboot and post-reboot verification:

```bash
scripts/dock_test_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

For deliberate test deployments from a dirty worktree, pass `--allow-dirty` to the dock test as well.
The dock test preflights noninteractive sudo reboot access before deploying or provisioning, pins remote reboot probes and sudo calls to trusted system command directories, validates the remote absolute `reboot` and `sudo` command paths as root-owned, executable, non-group/world-writable commands in trusted system directories, then later requests reboot with those same validated paths and fails clearly if the SSH user cannot reboot without a password prompt. It also passes the requested GPS device into verification so the onboard config and GPSD daemon must still point at the intended receiver; the rebooted dock acceptance path requires `--device` even with `--skip-deploy`. After the reboot, the dock test validates the remote absolute `python3` command path before reading boot IDs, reads and validates the Pi pre- and post-reboot boot IDs as Linux `boot_id` values on the Pi before comparing them, requires the boot ID to change, passes that observed post-reboot boot ID into strict verification, then uses the stricter verify mode that waits through the configured launcher readiness budget for desktop autostart, requires LightDM to be active, requires the existing readiness status report and chartplotter launcher log to be fresh for the current boot, verifies the active and rotated launcher logs are regular trusted user files before parsing startup markers, parses the active launcher log only through the no-follow descriptor it verified, rejects launcher logs that started OpenCPN after failed readiness, requires the private user-owned chartplotter launcher lock directory and reads regular private PID/boot-ID files through no-follow descriptors before proving they are stamped with the current boot ID and owned by a live launcher process, parses live launcher and OpenCPN process state, parentage, command lines, executable links, and environments as explicit `/proc` data, rejects live `NOAA_NAVIONICS_*` launcher process environment overrides so production behavior comes from the private commissioned launcher file, queries that launcher's live X display with a trusted `XAUTHORITY` file when present to prove screen blanking and DPMS sleep are disabled, and requires a launcher-supervised `opencpn` child process owned by the deployed user to be running on that same live X display from a trusted root-owned executable with `-parse_all_enc` and remain running with that trusted executable and display environment through a short stability check.
`--no-reboot` is only a pre-reboot smoke check; it deliberately skips the power-cycle and chartplotter-autostart proof required before relying on the Pi underway.
`--skip-autologin` is rejected for the dock acceptance test because that test must prove the production desktop startup path; use direct deploy/provision commands with both `--skip-autologin` and `--skip-services` only for weaker manual or headless testing.

On the Pi, configure GPSD with the GPS device:

```bash
scripts/configure_gpsd.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Use a single `/dev/serial/by-id/...` symlink name when possible; deploy, dock-test, direct verification, config validation, GPSD setup, and readiness checks fail volatile USB names such as `/dev/ttyUSB0` or `/dev/ttyACM0`, reject nested or shell-unsafe by-id paths, require the configured path to be a character device when device checks are enabled, require `/dev/serial/by-id/...` paths to be actual udev symlinks, and reject unrecognized device paths that are not one of the documented stable aliases.
The installer creates or tightens app-owned user directories such as `~/.local/bin`, `~/.local/share/noaa-navionics`, `~/.config/noaa-navionics`, and `~/.config/systemd/user` to private `0700` permissions before installing files. It syncs installed command symlinks, launchers, source revision, and user systemd unit files to disk, and replaces command symlinks, helper launchers, and user systemd unit files through synced temporary files. Installer revalidates user directories after creating or tightening them before placing temporary files there. Installer venv cleanup refuses Python runtimes without symlink-attack-resistant `shutil.rmtree` before removing the previous private virtual environment. Provisioning does the same directory hardening for launcher environment, user systemd, and desktop autostart paths before replacing refreshed user systemd unit files and the desktop autostart entry through synced temporary files and enabling or reloading startup behavior. Provisioning revalidates user directories after creating or tightening them before placing temporary files there, revalidates launcher environment and user-file targets immediately before promotion, then verifies the promoted launcher environment and promoted user service/autostart files through no-follow descriptors before enabling startup services. Status reports and Pi verification parse user systemd unit install targets only after a no-follow descriptor read confirms the opened unit file is still the inspected file, regular, user-owned, and not group/world-writable. Pi verification rejects those startup and runtime config files or their key parent directories if they are symlinks, owned by the wrong account, or group/world-writable. The GPSD setup script reads any existing onboard app config through a no-follow descriptor, validates the final NOAA Navionics app config, config directory, and `/etc/default/gpsd` target path before writing, rejects symlinked GPSD config path components, creates a synced root-owned private `0600` backup of `/etc/default/gpsd`, replaces it through a synced temporary file, reloads systemd, enables and restarts both `gpsd.socket` and `gpsd.service`, then updates the onboard `config.ini` through a synced private `0600` atomic replacement. GPSD setup resolves sudo, systemctl, and Python through trusted root-owned command checks before changing GPSD service state. GPS time setup reads existing chrony config, and readiness and production skip checks read GPSD and chrony config files, only after a no-follow descriptor confirms the opened file is still regular, owned by the expected account, and not group/world-writable. Readiness also rejects symlinked, non-regular, writable, or misowned GPSD config files or path components before trusting the configured startup device. `scripts/configure_gps_time.sh` writes only the production chrony config path `/etc/chrony/chrony.conf` unless it is in dry-run mode, rejects symlinked, non-regular, writable, or misowned chrony config paths, refuses damaged managed block markers, creates a synced root-owned private `0600` backup of that file, replaces it through a synced temporary file, adds a managed GPSD `SHM 0` refclock block, restarts chrony, then restarts the GPSD socket and service so the daemons reconnect in the right order. GPS time setup resolves sudo, systemctl, and Python through trusted root-owned command checks before changing chrony or GPSD service state. Readiness also rejects unsafe chrony config paths or a missing/commented GPSD SHM refclock before trusting GPS-disciplined time. Desktop autologin rejects symlinked LightDM autologin path components or writable LightDM autologin paths, then writes the LightDM drop-in through the same synced temporary-file replacement before enabling graphical boot. Desktop autologin setup resolves sudo, systemctl, and Python through trusted root-owned command checks before changing graphical target or LightDM service state. GPSD setup, GPS time setup, and desktop autologin revalidate root target paths before temporary-file creation and immediately before promotion, verify their root-owned temporary config files through no-follow descriptors before and after copying content, then verify promoted root files against their source through no-follow descriptors before syncing them.

Readiness compares GPSD and chrony config no-follow descriptors against the inspected file before parsing startup or GPS time settings.

On the Pi, `status-report` writes a JSON readiness artifact:

```bash
noaa-navionics status-report --output ~/.cache/noaa-navionics/status.json
```

Status reports include the current Linux boot ID only when it has the expected Linux `boot_id` UUID shape, OpenCPN command integrity, launcher environment path integrity and settings, parsed OpenCPN chart/GPSD config path integrity and state, desktop autostart and LightDM autologin path-component integrity and state, manifest-recorded and live regular non-symlink ENC cell counts from a user-owned non-writable extracted chart tree, and a launcher-settings readiness check that rejects symlinked launcher environment paths or launcher environment path components, fail-open chartplotter startup overrides, malformed or unknown launcher environment entries, or malformed OpenCPN restart values. Status reports and Pi verification reject symlinked, writable, misowned, or untrusted-directory OpenCPN commands before trusting chart display startup. OpenCPN chart and GPSD config reads use a no-follow descriptor and reject symlinked path components, non-regular files, writable files, or files owned by the wrong user before trusting chart or GPSD settings. OpenCPN backup and directory sync use no-follow opens while provisioning updates chart/GPSD settings. Status report directory sync uses no-follow directory opens after atomic replacement. Status reports and Pi verification parse desktop autostart and LightDM autologin files only after a no-follow descriptor read confirms the opened file is still the inspected file, regular, and not group/world-writable. Pi verification reads the live LightDM autologin session and chrony GPSD refclock config through no-follow descriptors before trusting graphical startup or GPS-disciplined time. Pi verification also parses the onboard app config through a no-follow descriptor read, runs GPSD device comparisons through that same trusted config read path, ensures recent GPX trackpoint verification uses that same trusted config read path, compares desktop autostart, LightDM autologin, and manifest files through no-follow descriptor reads, validates the extracted chart tree, and hashes retained-download archives through the same no-follow descriptor it verified. Status reports and Pi verification also reject symlinked, non-regular, writable, or misowned desktop autostart, LightDM autologin, and manifest files, plus symlinked retained-download or extract path components before trusting startup state or chart freshness. They are written through a private `0700` cache directory with a unique private `0600` temporary file and atomic replace, so overlapping launcher and readiness-service writes cannot corrupt or publicly expose the JSON artifact.
Status reports and Pi verification compare desktop autostart, LightDM autologin, and manifest files through same-file no-follow descriptor reads before trusting startup or chart freshness.
The status JSON writer rejects symlinked cache parent components, tightens a user-owned `~/.cache` parent and the private report directory to `0700`, revalidates both after permission tightening before writing JSON, syncs the file and replacement directory entry to disk, and strict Pi verification rejects symlinked, misowned, or public cache parents, public cache directories, or public status files.
Readiness and Pi verification require a well-formed `vcgencmd get_throttled` value and fail on any current or historical under-voltage, frequency capping, throttling, or soft thermal limiting reported since boot. Readiness also requires a readable thermal sensor or well-formed finite `vcgencmd measure_temp` value before trusting the enclosure temperature margin.
The installed boot-time readiness service writes the same status report after login, starts after and wants the GPX track logger, reads the persisted GPS wait setting, disables systemd's start timeout so that configured cold-start GPS waits control each run, and keeps retrying through a generous start-limit window if GPSD, chrony, the receiver, or GPX logging come up slowly after power-on. The report checks the NOAA Navionics user unit path-component integrity, verifies the unit files and user unit directory are owned by the deployed user and not group/world-writable, verifies their loaded fragment paths, installed `%h/.local/bin/noaa-navionics` command paths, restart/timer/start-limit/private-umask/read-only-system settings when systemd reports them, verifies the user unit-file `[Install]` targets that make the timer, track logger, and boot-readiness service persist after reboot, verifies user linger is enabled, waits briefly for the track logger after GPS readiness, verifies it has written a recent valid current-boot GPX point to a regular file owned by the deployed user after parsing finite non-negative `/proc/uptime`, verifies the desktop autostart and LightDM autologin files that start the chartplotter after power-up, fails readiness on disabled, missing, failed, or unqueryable required units, verifies `/etc/default/gpsd` for exactly the configured local GPS device and immediate polling, verifies chrony's managed GPSD SHM refclock config, and checks GPSD socket, GPSD service, and chrony service state in addition to recording raw service diagnostics. The weekly chart-refresh timer uses a 30-minute randomized delay for catch-up runs after boot and runs a bounded TCP connectivity check to NOAA before spending chart-download retries. A failed weekly chart-refresh unit is reported but does not by itself fail readiness; the chart manifest age and contents decide whether the onboard charts are usable. A missing or disabled chart-refresh service still fails readiness because the Pi would no longer refresh charts automatically.
Deploy/install records the source revision through synced private `0600` atomic file writes so status reports show which code is running on the Pi and whether the recorded revision path contains an unexpected symlink component. Status reports and Pi readiness read that revision through a no-follow descriptor after confirming the source revision directory is user-owned and not group/world-writable, and the opened file is still the inspected file, regular, user-owned, and not group/world-writable. On Raspberry Pi targets, readiness fails if that deployed source revision directory is misowned or group/world-writable, or if the deployed source revision is missing, symlinked, non-regular, misowned, group/world-writable, recorded through a symlinked path component, or recorded as `unknown`.
The strict dock-test verifier checks the pre-existing report's boot ID before it regenerates the report, proving the post-reboot launcher or readiness service already wrote a current-boot artifact.

Start the Pi chartplotter launcher:

```bash
noaa-navionics-start-chartplotter
```

Launcher startup sets a private `0077` umask, rejects symlinked cache path components before creating `~/.cache/noaa-navionics`, tightens the user-owned `~/.cache` parent and `~/.cache/noaa-navionics` to `0700`, revalidates both cache directories after creation or tightening before creating runtime files, rejects misowned cache directories, rejects symlinked, non-regular, or misowned launcher logs, and appends output to the private `0600` file `~/.cache/noaa-navionics/chartplotter.log` only after opening it through a no-follow descriptor, including OpenCPN's exit status if the chartplotter process stops.
The launcher rotates that log once it exceeds 1 MB, rejects symlinked or non-regular rotated-log targets, and syncs the rotated file and directory entry so repeated unattended boots do not grow the cache indefinitely.
It reads `NOAA_NAVIONICS_GPS_SECONDS`, optional `NOAA_NAVIONICS_WARNING_SECONDS`, optional `NOAA_NAVIONICS_READINESS_ATTEMPTS`, optional `NOAA_NAVIONICS_READINESS_RETRY_DELAY`, optional `NOAA_NAVIONICS_OPENCPN_RESTARTS`, optional `NOAA_NAVIONICS_OPENCPN_RESTART_DELAY`, and optional `NOAA_NAVIONICS_START_ON_FAILED_READINESS` from `~/.config/noaa-navionics/launcher.env` through a no-follow descriptor only after rejecting a missing launcher environment, symlinked launcher environment files or path components, misowned or group/world-writable launcher environment directories, misowned launcher environment files, launcher environment files that are not private `0600`, malformed launcher environment lines, and unknown launcher environment keys; ambient `NOAA_NAVIONICS_*` process environment variables are ignored so unattended boots use the commissioned private file. Production provisioning writes all startup policy keys explicitly, including `NOAA_NAVIONICS_START_ON_FAILED_READINESS=no`, so dock evidence does not depend on implicit launcher defaults. Missing or invalid launcher timing and fail-open values stop launcher startup instead of falling back to defaults. Boot readiness also reads `NOAA_NAVIONICS_GPS_SECONDS` through the `status-report --gps-seconds-from-launcher-env` trusted parser instead of allowing systemd to ingest `launcher.env` directly. Status reports parse launcher settings only after checking the launcher environment directory ownership and permissions, then using a no-follow descriptor read that confirms the file is still the inspected file, regular, user-owned, and private `0600`. Production Pi verification reads that private launcher environment through a no-follow descriptor before comparing persisted timing and restart policy, sizing strict startup waits, and rejecting fail-open startup. The readiness report fails if the persisted launcher environment directory is owned by the wrong account or group/world-writable, or if the launcher environment is missing, not regular, owned by the wrong account, group/world-writable, malformed, or contains unknown keys, so typos and unsafe startup policy files do not silently pass dock verification.
If OpenCPN is already running for the same user, a repeated launcher invocation leaves the existing chartplotter instance in place instead of starting a second one; the launcher resolves `pgrep` to a trusted executable path for that duplicate check, and defunct zombie processes do not count as running.
The launcher also keeps a synced cache-directory lock for the supervised OpenCPN session so overlapping desktop startup attempts cannot race each other while OpenCPN is still starting or running; it writes and reads lock PID and boot-ID files through no-follow descriptor opens, requires existing launcher lock directories to be private `0700` and PID/boot-ID files to be private `0600` before trusting them, parses live `/proc` state and NUL-delimited process arguments rather than substring-matching lock owners, rejects symlinked lock paths before reading or cleaning them, leaves a lock untouched if it is swapped for a symlink before release cleanup, and if an old lock points at an unrelated reused PID, it refuses symlinked, misowned, non-private lock metadata, or group/world-writable stale lock debris before removing the stale lock and continuing startup.
Before launching OpenCPN, the launcher pins command lookup to trusted system directories on Raspberry Pi hardware, resolves the command to an absolute executable path, rejects symlinked, non-regular, non-executable, group/world-writable, or unexpectedly owned binaries and command directories, requires a root-owned OpenCPN executable and executable directory on Raspberry Pi hardware, and logs the resolved path used for startup. Pi verification independently requires the deployed OpenCPN command and command directory to be root-owned trusted paths.
If OpenCPN exits with a nonzero status, the launcher restarts it up to `NOAA_NAVIONICS_OPENCPN_RESTARTS` times, defaulting to 3 attempts with a 5 second delay. A clean exit status `0`, such as a deliberate manual close, is not restarted. If the launcher receives `TERM` or `INT`, it forwards shutdown to the supervised OpenCPN child and waits for it before releasing the launch lock, so a stopped desktop session does not leave an unsupervised chartplotter process behind. Put `NOAA_NAVIONICS_OPENCPN_RESTARTS=0` in the launcher environment file for the previous no-restart behavior.
When an X desktop session is present, the launcher also resolves `xset` to a trusted executable path and asks the display server to disable screen blanking and DPMS sleep before starting OpenCPN.
Preflight and Pi verification require a trusted root-owned `xset` from `x11-xserver-utils` so this display-awake step is available. Strict chartplotter verification also requires trusted root-owned `python3`, `systemctl`, `loginctl`, `pgrep`, `vcgencmd`, `chronyc`, `gpsd`, and `cgps` commands so Python-backed helper checks, service-state, linger, duplicate-process, power, time, and GPS checks do not depend on untrusted command paths or a minimal base image.
If readiness fails, the launcher retries the startup readiness report before launching OpenCPN. After the final failed attempt it shows a Tkinter warning listing failed checks and the status report path when a desktop is available, reading failed-check details only from a no-follow descriptor-confirmed private status file, then does not start OpenCPN automatically; in the default fail-closed mode the warning button only dismisses the dialog. Put `NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes` in the private launcher environment file only for deliberate manual fallback behavior where OpenCPN should launch despite failed readiness; production Pi verification rejects that override when proving the boat-ready startup path.
If those display power commands fail during chartplotter autostart, if the live post-boot X display still reports screen blanking or DPMS sleep enabled, or if the current-boot launcher log shows OpenCPN already exited, the strict Pi startup verifier fails the dock test.
The provisioning script configures LightDM autologin so the desktop autostart entry can launch the chartplotter after boot. Autologin setup rejects root-owned runs, rejects root autologin, requires the selected account to exist with an owned local home directory, and writes an installed X11 session into the LightDM config so display blanking controls work. Use `--skip-autologin` only together with `--skip-services` for deliberate headless or development deployments.

Create the onboard config:

```bash
noaa-navionics init-config
```

Initial config reads and writes refuse symlinked, non-regular, misowned, or group/world-writable config files, misowned or group/world-writable config directories, plus symlinked config path components. Writes create or tighten the config directory to private `0700` permissions, revalidate ownership, symlink state, and mode after permission tightening, refuse misowned or group/world-writable config directories, then use a unique private `0600` temporary file, sync to disk, and atomically replace `config.ini`. Config directory sync uses no-follow directory opens after atomic replacement.

Download the configured chart package:

```bash
noaa-navionics sync-charts
```

Register the configured chart directory and GPSD connection with OpenCPN:

```bash
noaa-navionics configure-opencpn
```

`configure-opencpn` adds the GPSD network connection only when `[gps] mode = gpsd`; in serial mode it configures charts and skips GPSD. When GPSD mode is enabled, it removes stale enabled OpenCPN GPSD endpoints while preserving unrelated data connections such as AIS. It refuses to register missing, non-directory, or symlinked chart directories, creates or tightens the OpenCPN config directory to private `0700` permissions when writing, revalidates ownership, symlink state, and mode after permission tightening, and refuses to read or write through symlinked, non-regular, misowned, or group/world-writable OpenCPN config files, symlinked path components, or misowned config directories. Existing OpenCPN config backups and replacement config files are synced to disk, backup names are made unique when multiple writes happen in the same second, and backup and replacement writes force private `0600` files through unique temporary paths. Preflight requires OpenCPN's configured chart directory to exist so stale chart paths or missing storage do not pass readiness.
For onboard `gpsd` mode, `gpsd_host` must be local (`127.0.0.1`, `localhost`, or `::1`) and `gps.device` must name the attached receiver through a stable path such as one `/dev/serial/by-id/...` symlink name, `/dev/serial0`, `/dev/serial1`, or `/dev/gps`, so OpenCPN, readiness checks, and the installed GPSD service all use the Pi's GPS peripheral. The readiness path rejects extra enabled OpenCPN GPSD endpoints so a stale GPSD source cannot remain active beside the commissioned local receiver.

`sync-charts` writes `noaa-navionics-manifest.json` with SHA-256, source package URL, actual download URL, NOAA ZIP filename, extraction path, ENC cell count, and chart freshness time. Onboard config rejects updates-only and catalog-only packages because they are not complete chart sources, and it rejects broad, volatile, or system chart and track storage paths before any sync or GPX logging starts. Configured syncs also require `[charts] min_free_gb` free space on writable chart storage before creating the chart output directory or starting a NOAA download. Direct chart downloads, extraction, and manifest writes reject symlinked chart output path components before creating storage, locks, archives, extracted trees, or manifests, then make the chart output directory private `0700` to the installing user. The production default is `force = yes` so scheduled refreshes download a current NOAA bundle instead of reusing an old cache. If you set `force = no`, an existing ZIP is reused for chart extraction only when it is a regular user-owned file with no group/other write bits and matches the trusted previous manifest for the same NOAA package and a compatible actual download URL, preserving that manifest's timestamp and download URL; cache-reuse hashes are computed from the same no-follow descriptor that sync validated. A cached ZIP with no trusted previous manifest, unsafe ownership or permissions, mismatched source metadata, or a mismatched size/SHA-256 fails before extraction until you force a fresh download. Chart extraction checks ZIP member paths and CRCs before creating extraction staging, and refuses ZIPs with no ENC `.000` cells, an existing non-directory extraction target, unsafe `.previous` extraction debris, or a Python runtime without symlink-attack-resistant `shutil.rmtree` before replacing the previous extraction. Completed ZIP downloads are created through exclusive no-follow private `0600` partial files; downloaded ZIPs must open cleanly, contain only safe member paths, pass CRC checks, and contain ENC `.000` cells before they can replace a retained archive. Completed ZIPs, extracted chart trees, manifest JSON, and the affected directory entries are synced before atomic replacement; Chart tree sync uses no-follow opens for directories and regular files. Manifest writes use unique temporary files. Manifest fallback ZIP hashes use the same trusted no-follow archive hash path. If a previous interrupted download left a fixed `.part` file beside the target ZIP, the next sync refuses to overwrite it and tells you to remove interrupted chart update debris first. Failed download cleanup revalidates interrupted `.part` files as regular, user-owned, non-group/world-writable files before removing them, leaving unsafe debris in place for preflight to catch. If ZIP retention is disabled, the ZIP is revalidated as a regular trusted archive immediately before removal after extraction, even when the ZIP was already cached. Syncs take a synced private `0600` no-follow chart-directory lock so a timer run and a manual run cannot update the same chart set at the same time; symlinked lock paths are rejected, stale lock reads use a no-follow descriptor, stale lock cleanup refuses misowned or non-private lock files, and stale lock cleanup records PID and a Linux `boot_id` value, using a boot mismatch only when both lock and current boot IDs have the valid Linux `boot_id` UUID shape so an old lock is not removed while its owner is still running on the current boot. `preflight` checks that chart storage is owned by the deployed user with no group/other write bits, that the manifest is current, that no stale chart-update staging, previous directories, partial `.part` files, or unexpected top-level ZIP files remain from an interrupted or manual sync, that the recorded NOAA ZIP filename, source package URL, and actual download URL still identify the configured chart package filename without an HTTPS downgrade, that the recorded download path stays under chart storage and records a positive byte count and SHA-256 even when the ZIP is not retained, that the recorded extraction is still under the configured chart directory, that its live chart tree is user-owned with no group/other write bits and contains exactly the manifest-recorded regular non-symlink ENC cell count with no missing or extra cells, and that no other top-level ENC chart directories remain beside the manifest extract before the boat leaves the dock. It also requires at least `[charts] min_free_gb` free space on writable chart storage and separate track storage. Storage configured under `/mnt`, `/media`, or `/run/media` must have an actual mounted device on that path or one of its parents, so an unplugged USB drive does not accidentally pass readiness against the Pi's SD card. When `[charts] keep_zip = yes`, preflight requires the recorded retained ZIP to still exist under chart storage, then verifies its recorded path, regular-file status, owner, permissions, size, and SHA-256; retained ZIP hashes are computed from the same no-follow descriptor that readiness verified. That retained archive is the only top-level ZIP preflight allows.
Chart output directory permission tightening is revalidated before creating locks, archives, extracted trees, or manifests.
Manifest writes refuse existing symlinked or non-regular manifest targets before replacing metadata. Manifest reads reject symlinked manifest files or parent path components, unsafe manifest directory ownership or permissions, and unsafe manifest file ownership or permissions before trusting cached or readiness metadata.
NOAA download redirects that downgrade to HTTP or change filenames fail before archive replacement.
Preflight also checks for a sane system clock because chart freshness and GPX timestamps depend on UTC time. On a Raspberry Pi, preflight also requires `timedatectl` to report the system clock synchronized before relying on chart age and GPX timestamps.

Preflight check. By default this uses `[charts].output`; pass `--charts PATH` to check a different mounted chart directory explicitly:

```bash
noaa-navionics preflight
```

Live GPS check. Add `--seconds N` during dock diagnostics so the command exits non-zero instead of waiting forever when GPSD is connected but no fix arrives. GPSD readiness checks are bounded by the configured wait time and reject stale, future-dated, and untimestamped fixes:

```bash
noaa-navionics gps-monitor --gpsd --once --seconds 30
```

For direct serial checks, `preflight --gps-device` accepts `--gps-baud`; `status-report` uses the baud from `~/.config/noaa-navionics/config.ini`. A sample-based `status-report --gps-sample` substitutes the live fix read but still checks OpenCPN's GPSD connection when the onboard config is in `gpsd` mode. Manual `gps-monitor --device` and `log-track --device` direct serial runs also reject `/dev/serial/by-id/...` paths that exist but are not actual udev symlinks. Direct serial readiness rejects stale, future-dated, and untimestamped NMEA fixes too.
GPS readiness rejects missing fix-quality, missing coordinates, non-finite, out-of-range, malformed numeric/hemisphere NMEA, explicit RMC simulator/manual/estimated/no-fix mode flags, and invalid `0,0` coordinates. NMEA and GPSD parsing reject malformed or non-finite required fix fields and ignore malformed, non-finite, negative, or out-of-range optional speed, course, satellite-count, or HDOP values while retaining valid negative altitude. GPSD and direct NMEA readiness require satellite-count or HDOP quality fields and reject weak fixes with fewer than four satellites, negative HDOP, or HDOP above 5. Direct NMEA readiness accepts GGA position/quality fixes and RMC position fixes merged with GSA satellite/HDOP quality. GPSD readiness merges recent SKY satellite/HDOP reports with TPV position fixes before applying that gate, and it still exits inside the wait window if GPSD only streams non-fix status messages.
NMEA readers and GPSD streams reject overlong messages before buffering can grow without bound. Diagnostic NMEA sample files are read only through same-file no-follow descriptor checks before GPS readiness or manual sample logging trusts them. NMEA parsing rejects bad, malformed, or trailing-garbage checksum suffixes when a sentence includes a checksum. NMEA fractional timestamps are normalized across second, minute, and UTC day rollovers before freshness checks and GPX logging. Malformed or non-finite NMEA timestamps and malformed GPSD timestamps are treated as missing timestamps, so readiness still rejects those fixes when freshness is required.

Track logging:

```bash
noaa-navionics log-track
```

The systemd track logger writes daily GPX files using `[gps]` and `[tracking] output` from the onboard config, and prunes rotated track logs older than `[tracking] retention_days`. Manual `--device`, `--baud`, `--gpsd`, and `--output` flags override the config for direct troubleshooting, but direct serial `--device` still requires stable GPS paths and refuses existing by-id paths that are not actual udev symlinks.

Daily rotated GPX files live in a private user-owned `0700` tracks directory and are created exclusively with private `0600` no-follow opens so existing tracks or symlinked GPX output files are not silently overwritten, the new file entry is synced after creation, GPX directory sync uses no-follow directory opens, service-created track files also use a private `0077` umask, points are periodically synced to disk to reduce data loss after abrupt power loss, and SIGTERM/SIGINT shutdown closes the current GPX file before exit. GPX track directory permission tightening is revalidated before track files are created. Retention pruning validates old GPX entries through no-follow descriptors and refuses symlinked, non-regular, misowned, or non-private old GPX entries instead of deleting them.

The track logger skips invalid coordinates, missing satellite/HDOP quality fields, untimestamped fixes, stale or future-dated timestamps, and weak satellite/HDOP fixes instead of writing them to GPX; accepted trackpoints record GPX `<sat>` and/or `<hdop>` quality fields, and single-file logging does not create the output file until the first accepted timestamped quality fix. A bounded diagnostic run such as `log-track --seconds 30` exits non-zero if no usable fix is written before the timeout. An untimed live GPSD logger waits and retries if GPSD is not accepting connections yet at boot or if the first connected GPSD stream ends before any fix arrives, then keeps the connected stream through temporary GPSD quiet periods, but exits non-zero after 300 quiet seconds by default so systemd can restart a silent receiver path. Use `--gpsd-idle-timeout 0` or `--serial-idle-timeout 0` only for manual troubleshooting where idle recovery should be disabled. Live serial logging uses the same 300-second quiet limit for an open receiver that stops sending NMEA bytes. After a successful connection, it exits non-zero if the GPS stream ends unexpectedly, so the installed `Restart=on-failure` service restarts instead of silently stopping after a transient GPSD or device interruption.

The installed service drops per-fix stdout so normal GPS logging does not fill the systemd journal, while stderr warnings and failures still go to the service log. If `[tracking] output` is on separate storage from the charts, preflight also checks that track destination has an existing writable parent and enough free space. Status reports and Pi verification read candidate GPX track files only after a no-follow descriptor confirms the opened file is still the inspected file, regular, user-owned, and private `0600`; status reports and Pi verification reject symlinked GPX storage path components, missing GPX satellite/HDOP quality fields, non-finite GPX trackpoint coordinates, and negative GPX HDOP before accepting recent trackpoints. The default retention is 90 days; set it to `0` to keep all rotated track logs.
The track logger service uses a generous start-limit window so delayed GPSD or GPS hardware at boot does not permanently suppress GPX logging.

## Raspberry Pi Automation

A user-level systemd timer is included in `systemd/`.
The installer copies the chart refresh timer and track logger unit files but leaves them disabled. The Pi provisioning script reloads refreshed unit files, confirms systemd loaded the installed user-unit fragments and hardening settings before enabling unattended startup, enables user lingering, clears stale failed states for the chart refresh, track logger, and boot readiness services, starts the chart refresh timer, and restarts the track logger and boot readiness service after GPSD setup so updated service settings are applied only after the onboard config, charts, and GPSD are commissioned. The timer, readiness service, and track logger can then run after reboot without an interactive login.
The provisioning script also configures the Pi to boot to `graphical.target` and autologin through LightDM as the deployed user, so the desktop autostart entry can bring up OpenCPN after a power cycle.
The included chart sync service retries transient network failures, allows up to two hours for slow NOAA downloads, runs with `NoNewPrivileges`, a private temporary directory, `ProtectSystem=full`, `LockPersonality`, `RestrictSUIDSGID`, `MemoryDenyWriteExecute`, `RestrictRealtime`, and a private `0077` umask, and asks systemd for delayed retry attempts if the whole run still fails.

```bash
scripts/install_raspberry_pi.sh --skip-apt
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
