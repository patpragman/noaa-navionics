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
Use an explicit plain `user@host` SSH target for deployment, verification, and dock tests; the scripts require a normal local username and DNS/IP-style hostname and reject scp-style `user@host:path` targets, ports, shell punctuation, whitespace, and quotes. If you override the SSH deploy directory, use a dedicated `noaa-navionics` directory. The deploy scripts reject broad paths such as `/`, `~`, `/home`, or unrelated directory names because deployment keeps that remote copy exact, using `rsync --delete` when available and a guarded tar-over-SSH bootstrap copy otherwise. Both copy paths skip local build/cache directories and downloaded chart artifacts, write into a sibling staging directory, and promote it after the transfer completes so a broken deploy attempt does not destroy the previous deployment.

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
Provisioning validates the GPSD, chrony GPS-time, and desktop autologin helper scripts through no-follow descriptors before startup and immediately before execution, then executes those helpers through the validated descriptors.
It refuses a dirty local worktree by default so the Pi's recorded source revision matches the source you are verifying. Use `--allow-dirty` only for deliberate test deployments; those are recorded with a `-dirty` suffix. The deploy script checks for trusted executable local deployment commands, checks remote `python3`, validates remote deploy command paths, ownership, permissions, and parent directories, prefers `rsync` when it is available on both machines, and otherwise bootstraps the repo with local and remote `tar`. It uses the validated absolute local and remote `rsync` or `tar` paths for the actual copy command, and uses the validated absolute remote `python3` path for deployment staging, source-revision, and promoted helper-execution checks. Both copy paths reject system or volatile remote directories such as `/tmp/noaa-navionics`, write into a validated private `0700` sibling staging directory under a trusted deployment parent, retighten that staging directory after transfer before promotion, and promote it only after the transfer succeeds. If a prior deploy was interrupted after the old tree moved to `.previous`, the next deploy restores that previous tree before creating a new staging copy, so a failed deploy does not empty or erase the last good deployment. The script writes the remote source revision through a synced temporary file and atomic replace only after the promoted repo path is a trusted directory, then reopens that promoted revision file through a no-follow descriptor before syncing it, before the Pi installer records it for status reports. After promotion, the remote install and provisioning helper scripts run from no-follow descriptors in the trusted promoted repo with that repo fixed as their working directory. Failed remote source-revision temp cleanup is no-follow and same-file validated before unlinking, leaving changed or unsafe temporary paths in place. Deployment sync helpers use no-follow directory opens; provisioning and startup sync helpers use no-follow opens for directories and regular files. Pi-facing SSH transports require root-owned executable local commands from trusted system directories for `ssh`, `git`, and any local `rsync` or `tar` copy path, execute the validated local command paths for Git, SSH, and copy operations, require pretrusted SSH host keys with `StrictHostKeyChecking=yes`, and use batch mode with connection timeouts and keepalives so missing SSH credentials, unknown or changed Pi host keys, offline Pis, and dead long-running links fail clearly instead of prompting or hanging; remote command trust probes use the fixed `/bin/sh` entrypoint, while longer remote operational helpers use `/bin/bash`, after pinning `PATH`.
Enroll and verify the Pi host key from the deployment computer before using the deploy, verify, dock-test, pre-trip, or post-trip wrappers, using the Pi desktop user rather than `root@`; an unknown or changed host key is treated as a failure.

```bash
scripts/enroll_pi_host_key.sh pi@raspberrypi.local --expected-sha256 SHA256:YOUR_TRUSTED_PI_HOST_KEY_FINGERPRINT
```

Get the expected SHA256 host-key fingerprint from the Pi console or another trusted channel, not from the same network scan you are trying to verify.
Host-key enrollment rejects custom `--known-hosts` paths with parent-directory components before scanning the network. Host-key enrollment temporary cleanup is no-follow and same-file validated before unlinking, leaving changed or unsafe scan/match/key temp paths in place.
Remote deployment directories must be dedicated `noaa-navionics` paths under regular, user-owned, non-writable, non-symlinked user storage, and parent-directory components such as `..` are rejected before any SSH deployment starts. Remote deployment cleanup refuses Python runtimes without symlink-attack-resistant `shutil.rmtree` before removing stale staging or previous deployment directories.

After installation and before provisioning, plug in the GPS and run this on the Pi:

```bash
noaa-navionics list-gps-devices
```

Use a reported `/dev/serial/by-id/...` path for `--device`. The command also shows volatile `/dev/ttyUSB*` or `/dev/ttyACM*` names and broken `/dev/serial/by-id/...` symlinks when present, but returns nonzero if those are the only candidates because they are not usable stable paths for unattended chartplotter startup.

Deploy and run the full onboard provisioning sequence:

```bash
scripts/deploy_to_pi.sh pi@raspberrypi.local --provision --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

Provisioning starts with a private `0077` umask, pins `PATH` to trusted system command directories, resolves sudo, systemctl, loginctl, and Python through trusted root-owned command checks, then runs GPSD setup, chrony GPS time setup, chart sync, OpenCPN chart/GPSD registration, desktop graphical autologin setup, launcher GPS wait persistence, user service enablement, user linger for reboot persistence, and a final status report on the Pi. The GPSD, chrony GPS-time, and desktop autologin helper scripts also start with a private `0077` umask and the same trusted system command path, resolve sudo, systemctl, and Python through trusted root-owned command checks before root file or service changes, write generated GPSD and chrony temp files through no-follow private descriptors, and desktop autologin writes the generated LightDM autologin temp file through a no-follow private descriptor. They revalidate root target paths before temporary-file creation and immediately before promotion, verify root-owned temporary config files through no-follow descriptors before and after copying content, then verify promoted root files through no-follow descriptors before syncing them.
Failed installer source-revision and root text temporary cleanup is also no-follow and same-file validated before unlinking, leaving changed or unsafe temporary paths in place.
Failed root temporary config cleanup is also no-follow and same-file validated before unlinking, leaving changed or unsafe temporary paths in place.
Failed root backup cleanup is also no-follow and same-file validated before unlinking, leaving changed or unsafe backup paths in place.
Generated local config temp cleanup is likewise no-follow and same-file validated before unlinking.
Python atomic-write temp cleanup for app config, OpenCPN config, status reports, and chart manifests is no-follow and same-file validated before unlinking.
GPSD app-config validation and promotion temp cleanup uses the same no-follow same-file validation.
The deploy, provisioning, and dock-test scripts validate retry counts, retry delays, GPS wait time, and reboot wait timeout before starting remote work.
When deployment is combined with provisioning, `--skip-autologin` is applied during both install and provisioning. `--skip-services` and `--skip-autologin` must be used together for deliberate headless or manual-test deployments, so the Pi is not left with only part of the unattended startup path enabled.
Use `--skip-gpsd` only when GPSD and the onboard config are already commissioned. If `--device` is supplied, the existing onboard config must name the same receiver. If unattended services or desktop autostart are still enabled, provisioning reads the existing onboard GPS config only after a no-follow descriptor confirms the opened file is still regular, user-owned, and not group/world-writable. It rejects missing, symlinked, non-regular, misowned, group/world-writable, placeholder, mismatched, non-local, volatile, or nonexistent GPS config, plus disabled or inactive `gpsd.socket` or `gpsd.service`, before it enables startup behavior. Skipping GPSD setup still leaves chrony GPS time setup enabled unless `--skip-gps-time` is also passed.
Use `--skip-gps-time` only when chrony already contains this project's uncommented GPSD `SHM 0` time-source block. If unattended services or desktop autostart are still enabled, provisioning rejects missing, symlinked, non-regular, misowned, group/world-writable, or commented-out GPS time configuration and disabled or inactive `chrony.service` before it enables startup behavior.
Use `--skip-sync` only when the configured chart directory already has a fresh, complete NOAA chart manifest on trusted writable chart storage. If unattended services or desktop autostart are still enabled, provisioning rejects missing, incomplete, symlinked chart-directory ancestors, misowned, or group/world-writable chart storage before it enables startup behavior.
Use `--no-device-check` only for manual testing with both `--skip-services` and `--skip-autologin`; production provisioning requires the GPS receiver path to exist before it enables startup behavior and rejects broken `/dev/serial/by-id/...` symlinks before writing GPSD config.

Verify the Raspberry Pi after deployment:

```bash
scripts/verify_pi.sh pi@raspberrypi.local
```

The verify script refuses a dirty local worktree by default, then runs checks on the Pi over batch-mode SSH with a connection timeout, keepalives, and no pseudo-terminal, uses the fixed remote `/bin/bash` entrypoint after pinning `PATH` before launching the remote verifier, resolves `python3`, `systemctl`, `loginctl`, and `chronyc` through trusted root-owned command checks before Python-backed helper checks, core service-state, loaded user-unit property, linger, and GPS-time-source checks, and checks architecture, installed root-owned command dependencies, installed CLI/GUI command symlinks resolving into the private venv, trusted command/app-data/app-config/desktop-autostart/user-systemd parent directories and path components, root-owned OpenCPN command integrity plus LightDM/GPSD/chrony config parent-directory path-component integrity, Raspberry Pi power diagnostics, deployed source revision, chartplotter launcher content with synced current-boot launch-lock handling and OpenCPN/pgrep/xset descriptor revalidation hooks, persisted launcher GPS wait and OpenCPN restart policy, onboard app config, OpenCPN config file and private parent directory, source revision, launcher environment, desktop autostart, LightDM autologin, GPSD, chrony, helper launcher, and user systemd unit file ownership/mode/path-component integrity, desktop autostart fields plus hidden/disabled markers, graphical boot target, LightDM autologin for the deployed user with an installed X11 session, Tkinter readiness-warning support, installed and loaded user systemd unit commands, loaded fragment paths, install targets, installed unit-file directives, private temp directories, read-only system filesystem protection, private file umasks, loaded chart-refresh timer/timeout/retry/start-limit, track logger restart/graceful-stop/start-limit, and boot-readiness restart/start-limit settings, user linger for reboot-persistent user services, successful execution of the enabled boot-readiness service, active GPX track logging with a recent valid timestamped current-boot trackpoint in a regular private GPX file owned by the deployed user in a private tracks directory, GPSD socket/service boot enablement and active state, GPSD client tools for manual checks, GPSD startup options, exactly one GPSD device matching the onboard config, chrony service state, uncommented GPSD time-source config, a usable chrony GPS source within the configured GPS wait, config, and `noaa-navionics status-report`. Loaded service command checks require the installed `%h/.local/bin/noaa-navionics` path, not just matching arguments. It also parses the generated JSON readiness artifact and requires it to be fresh, ready, populated with the full core readiness/service/unit-file/loaded-setting/service-run checks, and stamped with the expected source revision check, config path, user-linger state, launcher settings matching a no-follow descriptor read of the same inspected live private launcher environment and expected restart policy, status-reported user and system service summaries, user unit, OpenCPN config, desktop autostart, and LightDM autologin owner/mode matching live files, OpenCPN chart and GPSD settings matching the live OpenCPN config, desktop autostart and LightDM autologin settings matching the live desktop files, normalized config values, chart sync flags, GPX track-log directory, required track-log symlink-status fields, private directory mode, private latest file mode, and latest file path matching the live config, manifest path, required manifest/download/extract symlink-status fields, manifest timestamp provenance, NOAA ZIP filename matching the onboard config, package URL, download URL, download path under chart storage, cache-reuse flag, positive download byte count, SHA-256, extraction path, exact live regular non-symlink ENC cell count, no dirty `-dirty` source revision, and no non-Pi diagnostic skips for Pi-only checks in the status artifact. It parses that status artifact only through the no-follow descriptor it verified. It reads `/proc/uptime` through a no-follow descriptor and requires finite non-negative uptime before judging launcher logs or GPX tracks as current-boot evidence. In strict chartplotter-started mode, it also requires LightDM to be active, checks that the active launcher log and any rotated launcher log are trusted regular user files, parses the active launcher log only through the no-follow descriptor it verified, first checks that the existing status artifact was generated during the current boot, and queries the launcher's live X display to prove screen blanking and DPMS sleep are disabled. `--allow-dirty` only passes through the expected revision suffix for deliberate dirty test matching; it does not make dirty status artifacts production-ready. The status report step retries briefly so GPSD has time to produce its first fix after boot; add `--gps-seconds N` if the receiver needs a longer fix window and `--opencpn-restarts N --opencpn-restart-delay N` if you commissioned a non-default launcher restart policy.
Status reports read the Linux `boot_id` and `/proc/uptime` through no-follow descriptors and reject changed, symlinked, non-regular, malformed boot ID, or malformed uptime evidence before stamping the JSON or judging current-boot GPX tracks.
Strict chartplotter verification also requires source-revision and launcher-settings symlink-status fields in the generated JSON, so older or incomplete status artifacts cannot silently satisfy startup provenance checks.
Strict chartplotter verification requires GUI and service startup path symlink-status fields for OpenCPN config, desktop autostart, LightDM autologin, and installed user systemd units before trusting the generated JSON.
Status-report readiness checks also fail when launcher, desktop, LightDM, or user-unit symlink-status evidence is missing, so incomplete generated JSON cannot mark the Pi ready before verification parses it.
Pi verification also rejects generated status artifacts without top-level user service, loaded user-unit property, and GPSD/chrony system-service summaries.
Strict chartplotter verification cleans temporary startup-check captures through no-follow same-file validation, leaving changed or untrusted paths in place.
It also writes a JSON status report on the Pi at `~/.cache/noaa-navionics/status.json`.

Run the dock acceptance test before relying on the Pi underway:

```bash
scripts/dock_test_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

The dock test preflights noninteractive sudo reboot access before deploying or provisioning, pins remote reboot probes and sudo calls to trusted system command directories, validates the remote absolute `reboot` and `sudo` command paths as root-owned, executable, non-group/world-writable commands in trusted system directories, deploys and provisions the Pi, verifies readiness, revalidates those same reboot and sudo command paths immediately before requesting reboot, waits for SSH to return, validates the remote absolute `python3` command path before every boot-ID read including after SSH returns from reboot, reads and validates the Pi pre- and post-reboot boot IDs through no-follow descriptors as Linux `boot_id` values on the Pi before comparing them, requires the boot ID to change, passes that observed post-reboot boot ID into strict verification, and verifies readiness again. It passes the requested GPS device into verification so the onboard config and GPSD daemon must still point at the intended receiver; the rebooted dock acceptance path requires `--device` even with `--skip-deploy`. If the SSH user cannot reboot without a password prompt, the test fails clearly instead of waiting on an interactive sudo prompt. After reboot, it uses the stricter verify mode that waits through the configured launcher readiness budget for desktop autostart, requires LightDM to be active, requires the existing readiness status report and chartplotter launcher log to be fresh for the current boot, reads the current boot ID through a no-follow descriptor before comparing status-report or launcher-lock boot evidence, verifies the active and rotated launcher logs are regular trusted user files before parsing startup markers, parses the active launcher log only through the no-follow descriptor it verified, rejects launcher logs that started OpenCPN after failed readiness, requires the private user-owned chartplotter launcher lock directory and reads regular private PID/boot-ID files through no-follow descriptors before proving they are stamped with the current boot ID and owned by a live launcher process, parses live launcher and OpenCPN process state, parentage, command lines, executable links, and environments through same-user no-follow `/proc` descriptors, rejects live `NOAA_NAVIONICS_*` launcher process environment overrides so production behavior comes from the private commissioned launcher file, queries that launcher's live X display with a trusted `XAUTHORITY` file when present to prove screen blanking and DPMS sleep are disabled, and requires a launcher-supervised `opencpn` child process owned by the deployed user to be running on that same live X display from a trusted root-owned executable with `-parse_all_enc` and remain running with that trusted executable and display environment through a short stability check, proving the desktop autostart path actually launched OpenCPN after passing readiness under launcher supervision. Use `--skip-deploy` to test an already-provisioned Pi, but still pass the expected `--device` for full acceptance.
`--no-reboot` is only a pre-reboot smoke check; it skips the power-cycle and chartplotter-autostart proof required before relying on the Pi underway.
`--skip-autologin` is rejected for the dock acceptance test because that test must prove the production desktop startup path; use direct deploy/provision commands with both `--skip-autologin` and `--skip-services` only for weaker manual or headless testing.
For deliberate test deployments from a dirty worktree, pass `--allow-dirty` to the dock test as well.

Run the normal pre-trip dock workflow against an already commissioned Pi:

```bash
scripts/pre_trip_prepare_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

The pre-trip wrapper validates each local helper script through a no-follow same-file descriptor as a current-user-owned executable with no group/other write bits before startup and immediately before each helper execution, executes each helper through the validated no-follow descriptor, validates the trusted root-owned local `python3` command path before creating, syncing, writing, parsing, and cleaning up the private recovery-output capture, refreshes NOAA charts on the Pi with a post-refresh status report, rejects broad/system local output directories, parent-directory components, or symlinked local output path components, tightens the local recovery export directory to user-owned private `0700`, requires the parsed recovery directory to be an immediate private child of that output directory, exports a local recovery bundle with a private checksum manifest, verifies archive structure and checksums, then runs the live no-deploy pre-departure check. After a successful pre-departure check with recovery export enabled, it saves a private `0600` `pre-departure-status.json` readiness snapshot plus a private `0600` `pre-departure-status.sha256` sidecar in the local recovery directory, and rejects stale, far-future, thin, failed, unstructured, non-Pi-skipped, or GPS-context-mismatched readiness snapshots at capture time. It does not install, enable, reboot, shut down, or download charts on the local computer.

Before leaving the dock on an already commissioned Pi, run the no-deploy, no-reboot pre-departure check:

```bash
scripts/pre_departure_check_pi.sh pi@raspberrypi.local --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

It reuses strict live verification for the current boot and requires the chartplotter startup path, exact GPS receiver, chart readiness, GPSD, chrony GPS time, and GPX track logging to pass. The pre-departure wrapper validates the SSH target, rejects root and loopback/local-host targets, validates its local verification helper through a no-follow same-file descriptor as a current-user-owned executable with no group/other write bits before startup and immediately before execution, executes that helper through the validated no-follow descriptor, and validates the trusted root-owned local `python3` command path before helper validation. It is quicker operational evidence for the running Pi, not a replacement for rebooted dock acceptance after commissioning or system changes.

Run a lightweight read-only status snapshot on an already commissioned Pi:

```bash
scripts/check_pi_status.sh pi@raspberrypi.local
```

The status helper validates the Pi's trusted root-owned `python3`, validates the installed private venv command path through a no-follow descriptor immediately before execution, executes that installed command through the validated no-follow descriptor, validates the onboard config file, and validates the private launcher environment before using its commissioned GPS wait, rejects symlinked command-tree or config path components, then prints the text report, or JSON with `--json`, over batch-mode SSH. By default it reads the commissioned GPS wait from the private launcher environment through the same status-report parser used by boot readiness; pass `--gps-seconds N` only for a one-off override. Its GPSD readiness check retries initial connection refusals inside the configured GPS wait. It does not deploy, reboot, download charts, or write the Pi status artifact; use it for a quick maintenance or underway health check, not as a replacement for dock acceptance.
Status JSON includes a top-level `gps_fix` object plus matching structured `data` on the GPS/GPSD readiness row, so support bundles and verification can inspect live fix time, signed age, position, satellite/HDOP quality, speed, course, and altitude without parsing prose.

Refresh the Pi's NOAA charts while you still have dock Wi-Fi:

```bash
scripts/refresh_pi_charts.sh pi@raspberrypi.local --retries 5 --retry-delay 30 --status
```

The refresh helper validates the SSH target, the Pi's trusted root-owned `python3`, and the installed private venv command path through a no-follow descriptor immediately before each app execution, executes each app call through the validated no-follow descriptor, rejects symlinked command-tree or config path components, waits for NOAA TCP connectivity from the Pi, then runs `sync-charts` with the onboard config. Add `--force` only for a deliberate redownload. Add `--status` to run a read-only status report after the refreshed chart sync succeeds; it validates the private launcher environment before post-refresh status uses the commissioned GPS wait unless `--gps-seconds N` is supplied. No chart data is downloaded on the local computer.

Collect a diagnostic support bundle from the Pi before changing anything:

```bash
scripts/collect_pi_support_bundle.sh pi@raspberrypi.local
```

The support bundle helper rejects broad/system local output directories, parent-directory components, or symlinked local output path components, normalizes the local output root, tightens the local output directory to user-owned private `0700`, creates the Pi-side temporary collection directory only under a private user-owned support cache with `mktemp -d`, cleans that temporary directory only through symlink-attack-resistant Python `shutil.rmtree`, reads configured storage metadata and copies selected Pi files through no-follow descriptor revalidation, cleans temporary copy-error captures and Pi-side copy temp files through no-follow same-file validation, validates the Pi's trusted root-owned `python3` command path before running Pi-side cleanup, copy, metadata, and archive helper snippets, archives the Pi-side bundle through that validated Python helper after rejecting symlinked or non-regular bundle entries and revalidating opened file descriptors, validates the installed `noaa-navionics` private venv command and executes it through a validated no-follow descriptor before running GPS discovery plus quick and commissioned read-only live status reports, records system command-integrity evidence for the host-identity, service, journal, chrony, mount, timedate, package, disk, Pi-health, storage-listing and serial-listing commands used by diagnostics, and writes a local private `0600` `.tgz` containing Pi-side NOAA Navionics config, saved status reports, fresh read-only status-report JSON captures using both a short diagnostic GPS wait and the commissioned launcher GPS wait, configured chart manifests and storage listings, launcher logs, installed user units, selected OpenCPN/GPSD/chrony/LightDM config files when readable, OS release and package-version evidence, recent relevant journal output, service state, loaded user and system unit properties, raw serial device listings, `noaa-navionics list-gps-devices` stable/volatile GPS classification, disk space, and Pi health command output. It promotes the local bundle from a descriptor-validated private partial file without overwriting an existing final archive, then validates the final local support bundle through a no-follow descriptor, requires a regular `README.txt` and at least one diagnostic file plus the core command-evidence files, and rejects duplicate or unsupported archive members before reporting success. It is read-only diagnostic evidence; it does not deploy, reboot, start services, download charts, or copy NOAA chart archives, extracted ENC cells, or GPX track contents.

Export GPX track logs after a trip:

```bash
scripts/export_pi_tracks.sh pi@raspberrypi.local
```

The track export helper validates the SSH target, validates the Pi's trusted root-owned `python3` command path before running the read-only export payload, rejects broad/system local output directories, parent-directory components, or symlinked local output path components, normalizes the local output root, tightens the local output directory to user-owned private `0700`, reads the Pi's onboard config, writes a local private `0600` `.tgz` containing only regular private `.gpx` files from the configured track directory plus an export manifest, promotes it from a descriptor-validated private partial file without overwriting an existing final archive, and validates the final local archive through a no-follow descriptor, requiring README plus a positive manifest count and manifest track names that match the regular GPX data files while rejecting duplicate or unsupported archive members before reporting success. Use `--days N` to export only recent track files. It does not deploy, reboot, start services, download charts, or copy NOAA chart archives or extracted ENC cells.

Mark the current GPS position while underway:

```bash
noaa-navionics mark-position --mob
```

The position-mark command reads one fresh quality-checked GPSD or serial fix from the onboard config and writes a private GPX waypoint file under the configured track output's `tracks/` directory, so track exports include the mark. It creates waypoint files with private exclusive no-follow opens, and default Mark/MOB filenames advance to a suffixed name if the same timestamped mark already exists or appears during creation, so Mark/MOB will not follow symlinked targets or overwrite an existing waypoint. Failed waypoint cleanup is no-follow and same-file validated before unlinking, leaving replaced paths in place. Use `--name` and `--description` for routine marks, or `--mob` for a MOB-named waypoint. Mark, MOB, and Anchor Check reject timezone-less, stale, or future-dated GPS fixes and broken, fake, or non-device stable serial paths rather than writing or judging positions from bad GPS evidence.

Watch anchor drift from the current position or an explicit anchor point:

```bash
noaa-navionics anchor-watch
```

The anchor watch reads quality-checked GPSD or serial fixes from the onboard config, uses the first accepted fix as the anchor unless `--anchor-lat` and `--anchor-lon` are provided, prints distance updates, and exits non-zero with an audible terminal bell when drift exceeds `[anchor].radius_meters`. Use `--anchor-samples N` to average multiple quality fixes before setting the anchor; longitude averaging is date-line-safe so samples around `+180/-180` do not create a false anchor near Greenwich. Use `--radius-meters N` for a one-off radius override and `--interval-seconds N` to reduce normal update noise while still printing alarms immediately. A finite anchor-watch run succeeds only after at least one post-anchor drift fix has been checked, and skipped timezone-less, stale, future-dated, weak, or incomplete fixes are reported as anchor-watch GPS evidence rather than GPX track-log evidence. Status reports and Pi verification include the configured anchor radius. It does not change charts, OpenCPN config, or services.

Collect post-trip artifacts after returning to the dock:

```bash
scripts/post_trip_collect_pi.sh pi@raspberrypi.local
```

The post-trip helper validates each local helper script through a no-follow same-file descriptor as a current-user-owned executable with no group/other write bits before startup and immediately before each helper execution, executes each post-trip helper through the validated no-follow descriptor, validates the trusted root-owned local `python3` command path before helper validation and status snapshot creation, rejects broad/system local output directories, parent-directory components, or symlinked local output path components, normalizes the local export root, tightens the local export directory and trip folder to user-owned private `0700`, saves a local private `0600` JSON status snapshot through an exclusive no-follow file create, executes the status helper through the validated no-follow descriptor while writing that snapshot, fsyncs that status snapshot file and its private trip directory before reporting it saved, validates the saved status snapshot as a same-file no-follow private file before preserving it, validates successful snapshots as descriptor-opened readiness JSON with a fresh timezone-stamped `generated_at`, a valid Linux boot ID, a clean deployed source revision without a dirty `-dirty` suffix, a valid GPSD or serial config, track-log output context, the full required readiness/service check names, all rows passing, structured data on every required readiness row, and no non-Pi diagnostic skips for Pi-only checks, exports GPX tracks, collects a diagnostic support bundle, validates the returned track/support archives as private no-follow readable gzip tar files inside the trip folder, requires a regular archive `README.txt`, requires the track archive manifest `track_count` and track names to match regular `tracks/*.gpx` data files and the support archive to contain the core command-evidence files, rejects duplicate normalized archive members, backslash member names, and symlink, hardlink, device, or FIFO members, writes and verifies a private `0600` `SHA256SUMS.txt` for the collected status and archive artifacts, can optionally dry-run or request a clean shutdown with `--shutdown-dry-run` or `--shutdown-confirm`, and rejects a real shutdown-only run when all artifact collection steps are skipped. It continues exporting tracks/support even when the status snapshot reports unhealthy state, then exits non-zero after collection so the saved artifacts can be inspected.

Export OpenCPN user navigation data before SD-card swaps or maintenance:

```bash
scripts/export_pi_opencpn_data.sh pi@raspberrypi.local
```

The OpenCPN export helper validates the Pi's trusted root-owned `python3` command path before running the read-only export payload, rejects broad/system local output directories, parent-directory components, or symlinked local output path components, normalizes the local output root, tightens the local output directory to user-owned private `0700`, writes a local private `0600` `.tgz` containing trusted regular OpenCPN config, `navobj.xml` route/waypoint data, and GPX/XML layer files when present, promotes it from a descriptor-validated private partial file without overwriting an existing final archive, and validates the final local archive through a no-follow descriptor, requiring README plus a positive manifest count and manifest file names that match the regular data files while rejecting duplicate or unsupported archive members before reporting success. It does not deploy, reboot, start services, download charts, or copy NOAA chart archives or extracted ENC cells.

Export commissioning settings before reimaging or replacing storage:

```bash
scripts/export_pi_settings.sh pi@raspberrypi.local
```

The settings export helper validates the Pi's trusted root-owned `python3` command path before running the read-only export payload, rejects broad/system local output directories, parent-directory components, or symlinked local output path components, normalizes the local output root, tightens the local output directory to user-owned private `0700`, writes a local private `0600` `.tgz` containing trusted NOAA Navionics config, launcher policy, source revision, user service/autostart files, production `/etc/chrony/chrony.conf` when readable, and readable GPSD/legacy chrony-drop-in/LightDM settings, promotes it from a descriptor-validated private partial file without overwriting an existing final archive, and validates the final local archive through a no-follow descriptor, requiring README plus a positive manifest count and manifest file names that match the regular data files while rejecting duplicate or unsupported archive members before reporting success. It does not deploy, reboot, start services, download charts, or copy logs, GPX tracks, NOAA chart archives, or extracted ENC cells.

Export a full recovery set before a trip or maintenance window:

```bash
scripts/export_pi_recovery_bundle.sh pi@raspberrypi.local --track-days 30
```

The recovery export helper validates each local export helper script through a no-follow same-file descriptor as a current-user-owned executable with no group/other write bits before startup and immediately before each helper execution, executes each export helper through the validated no-follow descriptor, validates the trusted root-owned local `python3` command path before helper validation, rejects broad/system local output directories, parent-directory components, or symlinked local output path components, normalizes the local output root, tightens the local output directory and timestamped recovery folder to user-owned private `0700`, runs the read-only settings, OpenCPN user-data, GPX track, and support-bundle exports into that directory, writes a private `0600` `SHA256SUMS.txt` for the four recovery archives, and verifies the completed local recovery set before reporting success. The recovery verifier validates the trusted root-owned local `python3` command path before running its verifier engine, rejects recovery directory paths with parent-directory components, requires the timestamped recovery directory to be user-owned private `0700` storage, requires each archive and the checksum manifest to be user-owned private `0600` files opened through no-follow descriptor revalidation, verifies each archive's SHA-256 digest against the manifest, requires settings/OpenCPN manifest file names and GPX manifest track names to match the regular data files, requires the diagnostic support bundle to contain the core command-evidence files, and only then reports the recovery set as verified. It does not deploy, reboot, start services, download charts, or copy NOAA chart archives or extracted ENC cells.
Re-run verification later before relying on a copied or archived recovery directory for SD-card recovery:

```bash
scripts/verify_pi_recovery_exports.sh pi-recovery-exports/noaa-navionics-pi-recovery-pi_raspberrypi_local-YYYYMMDDTHHMMSSZ
```

The verifier checks the local `.tgz` files with the validated local Python command for the expected export set, readable tar contents, safe and unique normalized member paths, regular README files, positive settings/OpenCPN manifest counts and file names that match the regular data files, GPX manifest counts and track names that match the regular `tracks/*.gpx` data files, and support bundle core command-evidence files. When optional `pre-departure-status.json` and `pre-departure-status.sha256` files are present, the verifier also requires them to be private `0600` files, checks the sidecar digest, and requires the JSON to report `ok=true` with a valid GPSD or serial config, track-log output context, the full required readiness/service check names, all rows passing, structured data on every required readiness row, no non-Pi diagnostic skips for Pi-only checks, a timezone-stamped non-future `generated_at`, a valid Linux boot ID, and a clean deployed source revision without a dirty `-dirty` suffix. It does not contact the Pi.
After reimaging a Pi, copy the verified recovery directory onto the Pi and restore user-owned navigation data as the Pi desktop user:

```bash
scripts/restore_pi_recovery_user_data.sh /path/to/noaa-navionics-pi-recovery-... --apply
```

The restore helper is dry-run by default and requires `--apply` before writing. It validates the trusted root-owned local `python3` command path before running its restore engine, then restores NOAA Navionics `config.ini` and launcher policy, whitelisted OpenCPN user config/routes/waypoints/layers, and GPX tracks into the restored configured track directory after rejecting copied recovery directory paths with parent-directory components, requiring the copied recovery directory to be user-owned private `0700` storage, requiring each archive and `SHA256SUMS.txt` to be user-owned private `0600` files, verifying each archive's SHA-256 digest before loading restore contents, reading each restore archive through a no-follow descriptor, requiring regular README archive files and regular manifest files when manifests are required, requiring settings/OpenCPN manifest file names and the GPX manifest count and track names to match regular data files, enforcing unique normalized member paths, validating the diagnostic support archive's core command-evidence files without loading its contents into memory, and rejecting parent-directory traversal, unsafe chart storage, unsafe GPS settings, or broad mounted-storage roots in the recovered config paths. Restore-created directories and overwrite backup directories are revalidated as user-owned private `0700` paths before recovered files are written or backed up. Overwrite backups read the existing target through a no-follow descriptor, reject writable or misowned source files, write an exclusive private backup, re-open the promoted backup before replacement continues, and immediately before restore promotion verify that the target is still the backed-up file or still absent. Each promoted restored file is reopened through a no-follow descriptor, verified as the same regular private `0600` file, and compared with the recovery archive bytes before restore reports success. Failed restore temp cleanup is no-follow and same-file validated before unlinking, leaving changed or unsafe restore temp paths in place. It does not restore root-owned GPSD, chrony, LightDM, service unit, chart, or NOAA ENC files; re-run provisioning and then `scripts/verify_pi.sh` or `scripts/dock_test_pi.sh` on the Pi before relying on it.

Shut the Pi down cleanly before cutting boat power:

```bash
scripts/shutdown_pi_safely.sh pi@raspberrypi.local --confirm
```

The shutdown helper validates the SSH target, rejects loopback/local-host targets, validates trusted remote `sync`, `sudo`, and `systemctl` command paths and parent directories, revalidates `sync` immediately before flushing filesystems, verifies noninteractive sudo can run the exact `systemctl poweroff` command, and revalidates `sudo` and `systemctl` immediately before the dry-run report or real poweroff request. It then flushes filesystem buffers, requests `systemctl poweroff` through noninteractive sudo, and waits up to the configured timeout for SSH to stop responding before reporting shutdown confirmation. Use `--dry-run` to prove that path without powering off.

Manual install:

```bash
sudo apt update
sudo apt install python3 python3-venv python3-tk rsync opencpn gpsd gpsd-clients chrony lightdm x11-xserver-utils python3-setuptools procps
sudo apt install raspi-utils || sudo apt install libraspberrypi-bin
scripts/install_raspberry_pi.sh --skip-apt
```

On Raspberry Pi OS Bookworm, the installer adds `bookworm-backports` as a synced apt source drop-in when that source is not already configured, after rejecting symlinked, misowned, or group/world-writable apt source paths and ancestors. It does not add that Bookworm source on other OS releases.

SSH deployment requires the remote `noaa-navionics` directory to be under a regular, user-owned, non-writable, non-symlinked path before staging or recording the deployed source revision.

The installer starts with a private `0077` umask, rejects symlinked, misowned, or group/world-writable user install paths, tightens app-owned user directories such as `~/.local/bin`, `~/.local/share/noaa-navionics`, `~/.config/noaa-navionics`, and `~/.config/systemd/user` to private `0700` permissions, replaces its private virtual environment at `~/.local/share/noaa-navionics/venv` on each run, symlinks commands into `~/.local/bin`, uses noninteractive apt calls for unattended SSH deployment, resolves sudo, apt-get, and Python through trusted root-owned command checks before package changes or installer Python helpers, ensures rsync remains available for future deployments, ensures LightDM, X11 display-power tools, and `procps` process lookup tools are installed for graphical startup checks, and ensures a trusted root-owned `vcgencmd` is available for Raspberry Pi power checks. The venv cleanup is guarded so only the dedicated `noaa-navionics/venv` directory can be removed, and venv cleanup refuses Python runtimes without symlink-attack-resistant `shutil.rmtree` before removing the previous private virtual environment; this prevents stale installed Python files from surviving repeated deploys without taking a weaker recursive deletion path. It installs the local repo with pip index access, pip version checks, build isolation, and PEP 517 disabled because the application has no runtime Python dependencies and the legacy setup metadata can be installed with the Pi's apt-provided setuptools. It records a deploy-provided `.source-revision` when present; otherwise direct installs from a dirty Git worktree are marked with a `-dirty` suffix in status reports. Installer sync helpers use no-follow opens for directories and regular files. Installer revalidates user directories after creating or tightening them before placing temporary files there, then revalidates helper, unit, and command-link targets immediately before promotion. venv tree sync skips symlinked directories and files instead of following them while flushing the install to disk before replacing command links, helper launchers, and user systemd unit files through synced temporary files. Before reporting success, the installer verifies that the CLI and GUI command symlinks resolve into the private venv, reopens promoted helper launchers and user systemd unit files through no-follow descriptors and compares them with the repo sources, and verifies that helper launchers are trusted user-owned executables. Pi verification repeats those checks and rejects writable or misowned parent directories for commands, app data, app config, desktop autostart, and user systemd units. It installs GPSD client tools as `gpsd-clients` first, falls back to `gpsd-tools` when needed, and verifies a trusted root-owned `cgps` is present for manual GPS checks. It tries `raspi-utils` first and falls back to `libraspberrypi-bin` for older Raspberry Pi OS images. It syncs the installed command symlinks, launchers, source revision file, and user systemd unit files to disk. The Python code uses only the standard library. `opencpn` renders NOAA ENCs, `gpsd` shares one GPS feed between OpenCPN and this tool, and `chrony` can discipline the Pi clock from GPSD when network time is unavailable. The installer leaves chart refresh, track logging, desktop autostart, and LightDM autologin disabled; provisioning installs or enables them only after the onboard config, charts, and GPSD have been configured. Use `--skip-autologin` only together with `--skip-services` for deliberate headless or development deployments.
Failed installer user-file and command-link temporary-path cleanup is no-follow and same-file validated before unlinking, leaving changed or untrusted paths in place.

## Onboard Config

All services read one config file:

```bash
noaa-navionics init-config
nano ~/.config/noaa-navionics/config.ini
```

Config reads use a no-follow descriptor and refuse symlinked, non-regular, misowned, or group/world-writable config files, misowned or group/world-writable config directories, plus symlinked config path components, before trusting chart, GPS, or track settings. `init-config` writes refuse the same unsafe paths, creates or tightens the config directory to private `0700` permissions, revalidates ownership, symlink state, and mode after permission tightening, refuses misowned or group/world-writable config directories, then writes through a unique private `0600` temporary file, syncs to disk, and atomically replaces `config.ini`. After replacement, the promoted config is reopened through a no-follow descriptor, verified as the same regular private file, parsed as INI, and checked for the required onboard sections. Config directory sync uses no-follow directory opens after promoted config validation.

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

Config validation fails fast on unsafe values: `charts.package` must be one of `state`, `cgd`, `region`, `chart`, or `all`; packages other than `all` need `charts.value`; state, Coast Guard district, and region package values must match a NOAA prepackaged ENC bundle; chart and track output paths cannot be blank, must be absolute or start with `~`, cannot contain parent-directory components such as `..`, and cannot be broad system, volatile, or home directories such as `/`, `~`, `/home`, `/etc`, `/etc/noaa-navionics`, `/tmp/noaa-navionics`, `/var`, `~/.config`, or `~/.cache`; use a dedicated real directory under the Pi user's home or mounted storage under `/mnt`, `/media`, or `/run/media`; readiness rejects symlinked storage paths; the GPX logger also refuses symlinked track-output parent components and symlinked GPX output files before creating track directories or files; `charts.max_age_days` must be at least `1`; `charts.min_free_gb` must be at least `0.1`; GPSD hosts cannot be blank or contain spaces, semicolons, or pipes, and `gpsd` mode requires a local host of `127.0.0.1`, `localhost`, or `::1`; GPSD ports must be `1` through `65535`; serial baud must be one of `4800`, `9600`, `19200`, `38400`, `57600`, or `115200`; `gpsd` and serial modes both require `gps.device` to be a stable path such as one `/dev/serial/by-id/...` symlink name, `/dev/serial0`, `/dev/serial1`, or `/dev/gps`; and track retention must be `0` or greater.
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

The script requires an absolute `/dev/...` path without whitespace or quotes, reads any existing onboard app config through a no-follow descriptor, validates the onboard app config, config directory, and `/etc/default/gpsd` target path before touching GPSD, rejects parent-directory components and symlinked GPSD config path components, writes the generated GPSD temp file through a no-follow private descriptor, creates a synced root-owned private `0600` backup of `/etc/default/gpsd`, replaces the GPSD config through a synced temporary file, reloads systemd, enables and restarts both `gpsd.socket` and `gpsd.service`, and updates `~/.config/noaa-navionics/config.ini` through a synced private `0600` atomic replacement. GPSD setup resolves sudo, systemctl, and Python through trusted root-owned command checks before changing GPSD service state. Promoted root config files are verified against their source through regular no-follow file descriptors before syncing. Readiness also rejects symlinked, non-regular, writable, or misowned GPSD config files or path components before trusting the configured startup device.
Deploy, dock-test, direct verification, config validation, GPSD setup, and readiness checks fail volatile USB names such as `/dev/ttyUSB0` or `/dev/ttyACM0`, reject nested or shell-unsafe by-id paths, require the configured path to be a character device when device checks are enabled, require `/dev/serial/by-id/...` paths to be actual udev symlinks, and reject unrecognized device paths; use one `/dev/serial/by-id/...` symlink name for USB GPS receivers, `/dev/serial0` or `/dev/serial1` for Raspberry Pi UART GPS hardware, or `/dev/gps` for a managed stable alias. GPSD setup validates the final NOAA Navionics app config before writing `/etc/default/gpsd`, so unsafe chart or track storage settings fail before system GPSD files are changed.

Configure chrony to use GPSD as a local time source:

```bash
scripts/configure_gps_time.sh
```

This writes only `/etc/chrony/chrony.conf` outside dry-run mode, rejects parent-directory components plus symlinked, non-regular, writable, or misowned chrony config paths, writes the generated chrony temp file through a no-follow private descriptor, creates a synced root-owned private `0600` backup, refuses damaged managed block markers, adds a managed `refclock SHM 0 offset 0.5 delay 0.1 refid GPS` block for GPSD's message-based time source, replaces the config through a synced temporary file, verifies the promoted config against its source through regular no-follow file descriptors before syncing, restarts chrony, and restarts GPSD so GPSD can reconnect after chrony restarts. GPS time setup resolves sudo, systemctl, and Python through trusted root-owned command checks before changing chrony or GPSD service state. This is intended to keep chart-age checks and GPX timestamps sane when the Pi is away from network time. Pi readiness requires trusted `timedatectl` output with `SystemClockSynchronized=yes`; `NTPSynchronized=yes` alone is not enough. GPS time setup reads existing chrony config, and readiness and production skip checks read GPSD and chrony config files, only after a no-follow descriptor confirms the opened file is still regular, owned by the expected account, and not group/world-writable. Readiness compares GPSD and chrony config no-follow descriptors against the inspected file before parsing startup or GPS time settings. Readiness requires the managed chrony GPSD SHM refclock config and requires chrony to report the GPS refclock as selected or combined, not merely present or excluded. For sub-second timing, use GPS/PPS hardware and tune chrony for PPS separately.

Restart and verify:

```bash
sudo systemctl enable --now gpsd.socket gpsd.service
sudo systemctl restart gpsd.socket gpsd.service
cgps
noaa-navionics gps-monitor --gpsd --once --seconds 30
```

`noaa-navionics configure-opencpn`, below, configures OpenCPN to use the GPSD network source from the onboard config and removes stale enabled OpenCPN GPSD endpoints while preserving unrelated data connections such as AIS. The readiness path rejects extra enabled OpenCPN GPSD endpoints so a stale GPSD source cannot remain active beside the commissioned local receiver.
Use `gps-monitor --seconds N` during dock diagnostics so the command exits non-zero instead of waiting forever when GPSD is starting slowly, refusing connections, or connected but no fix arrives.
`gps-monitor --once` exits successfully only after a fresh timestamped GPS fix with satellite or HDOP quality data, so a position-only fix does not make dock diagnostics look healthy. Bounded live GPSD commands retry initial GPSD connection failures inside their wait window, but still fail on stream errors after a fix has been accepted.
If you intentionally use serial mode instead of GPSD, set `[gps] baud` in `~/.config/noaa-navionics/config.ini` and use `noaa-navionics preflight --gps-device /dev/serial/by-id/YOUR_GPS_DEVICE --gps-baud 9600` when checking that device directly. Manual `gps-monitor --device` and `log-track --device` direct serial runs also reject stable paths that are broken, exist but are not actual udev symlinks when using `/dev/serial/by-id/...`, or do not resolve to a character device, and the low-level NMEA opener requires the opened path to remain the same character device through immediate descriptor revalidation before termios setup. Direct serial readiness also rejects stale, future-dated, and untimestamped NMEA fixes.
Readiness rejects missing fix-quality, missing coordinates, non-finite, out-of-range, malformed numeric/hemisphere NMEA, explicit RMC simulator/manual/estimated/no-fix mode flags, and invalid `0,0` coordinates. NMEA and GPSD parsing reject malformed or non-finite required fix fields and ignore malformed, non-finite, negative, or out-of-range optional speed, course, satellite-count, or HDOP values while retaining valid negative altitude. GPSD and direct NMEA readiness require satellite-count or HDOP quality fields, then reject weak fixes with fewer than four satellites, negative HDOP, or HDOP above 5. Direct NMEA readiness accepts GGA position/quality fixes and RMC position fixes merged only with recent GSA satellite/HDOP quality. GPSD readiness merges recent SKY satellite/HDOP reports with TPV position fixes before applying that gate, and it still exits inside the configured GPS wait if GPSD only streams non-fix status messages.
GPX track directory permission tightening is revalidated before track files are created.
NMEA readers and GPSD streams reject overlong messages before buffering can grow without bound. Diagnostic NMEA sample files are read only through same-file no-follow descriptor checks before GPS readiness or manual sample logging trusts them. NMEA parsing rejects bad, malformed, or trailing-garbage checksum suffixes when a sentence includes a checksum. Fractional NMEA timestamps are normalized across second, minute, and UTC day rollovers before readiness checks and GPX logging. Malformed or non-finite NMEA timestamps and malformed or timezone-less GPSD timestamps are treated as missing timestamps, so readiness still rejects those fixes when freshness is required.

## One-Step Provisioning

After `scripts/install_raspberry_pi.sh` has run on the Pi, commission the onboard setup with:

```bash
scripts/provision_sailboat_pi.sh --device /dev/serial/by-id/YOUR_GPS_DEVICE
```

This runs the same sequence expected before departure: initializes config if needed, configures GPSD, configures chrony to use GPSD time, downloads the configured NOAA chart package, registers charts and GPSD in OpenCPN, rejects symlinked, misowned, or group/world-writable launcher environment, user systemd, and desktop autostart paths, tightens those user directories to private `0700` permissions, replaces refreshed user systemd unit files through synced temporary files, reloads the user manager, confirms systemd loaded the installed user-unit fragments and hardening settings before enabling unattended startup, enables user linger, clears stale failed states for the chart refresh, track logger, and boot readiness services, enables the user timer and track/readiness services, restarts the track logger and boot readiness service so refreshed service settings are active, confirms the chart timer and track logger are enabled and active, confirms boot readiness completed successfully, installs desktop autostart through a synced temporary file, configures graphical autologin, and then tightens the user-owned `~/.cache` parent before writing the private `0600` status report `~/.cache/noaa-navionics/status.json` after those desktop startup files exist. Provisioning revalidates user directories after creating or tightening them before placing temporary files there, revalidates launcher environment and user-file targets immediately before promotion, then verifies the promoted launcher environment and promoted user service/autostart files through no-follow descriptors before enabling startup services. Status reports and Pi verification parse user systemd unit install targets only after a no-follow descriptor read confirms the opened unit file is still the inspected file, regular, user-owned, and not group/world-writable. Pi verification rejects launcher environment, autostart, LightDM autologin, user unit, app config, OpenCPN config, GPSD, chrony, or source-revision files that are symlinks, owned by the wrong account, or group/world-writable, verifies the status artifact's user unit, OpenCPN config, desktop autostart, and LightDM autologin owner/mode fields match the live files and unit directory, and verifies the loaded chart-refresh, track-logging, and boot-readiness services keep a private `0077` umask, `ProtectSystem=full`, `LockPersonality`, `RestrictSUIDSGID`, `MemoryDenyWriteExecute`, `RestrictRealtime`, and `SystemCallArchitectures=native`. The boot readiness service wants and starts after the GPX track logger, verifies linger remains enabled for reboot-persistent user services, and has a broad retry budget so a slow GPSD, chrony, receiver, or first GPX write after power-on does not permanently suppress the readiness report.
Failed provisioning temporary paths are cleaned through no-follow same-file validation, leaving changed or untrusted paths in place.
Provisioning requires the installed private `~/.local/bin/noaa-navionics` symlink to resolve into `~/.local/share/noaa-navionics/venv/bin/noaa-navionics` before it runs chart sync, OpenCPN configuration, service setup, or status reporting.
The initial chart download uses retry defaults for unreliable marina Wi-Fi. Add `--sync-retries N --sync-retry-delay N` when commissioning from a slower hotspot or remote dock network. The chart-refresh `wait-network` preflight caps each TCP probe to the remaining overall `--seconds` budget, so a slow DNS/TCP attempt cannot stretch an unattended boot wait beyond the configured limit. The unattended Pi default waits 60 seconds for a GPS fix at startup; add `--gps-seconds N` to `deploy_to_pi.sh --provision` or `dock_test_pi.sh` when the GPS receiver needs a different cold-start window. Add `--opencpn-restarts N --opencpn-restart-delay N` when the chartplotter needs a different supervised restart policy after nonzero OpenCPN exits. Provisioning stores the GPS wait, explicit fail-closed startup policy, readiness retry defaults, warning duration, and OpenCPN restart policy in the private `0600` file `~/.config/noaa-navionics/launcher.env` through a synced temporary file and atomic replacement for boot readiness and desktop autostart, and GPSD checks stay bounded by the GPS wait even when GPSD is connected but not producing usable fixes. The boot readiness service does not use systemd `EnvironmentFile`; it passes that launcher environment path to `status-report`, which reads `NOAA_NAVIONICS_GPS_SECONDS` through the same no-follow, private-file parser used by readiness reports and fails malformed or unknown launcher keys before waiting on GPS.
For production provisioning, use `~/.config/noaa-navionics/config.ini`. A custom `--config` path is rejected unless both `--skip-services` and `--skip-autologin` are passed for manual testing, because the installed user services and desktop launcher use the default onboard config after reboot.

## Startup

The installer copies a launcher to `~/.local/bin/noaa-navionics-start-chartplotter`. Provisioning installs a desktop autostart entry for it, sets the Pi to boot to `graphical.target`, enables `lightdm.service`, and rejects root-owned autologin setup, symlinked LightDM autologin path components, or writable LightDM autologin paths before replacing `/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf` through a synced temporary file for the deployed user after confirming the account exists with an owned local home directory and an installed X11 session is available. Desktop autologin setup resolves sudo, systemctl, and Python through trusted root-owned command checks before changing graphical target or LightDM service state. The launcher starts with a private `0077` umask, reads the Raspberry Pi model through a no-follow same-file descriptor before applying Pi-only trusted-command rules, pins command lookup to trusted system directories on Raspberry Pi hardware, resolves Python to a trusted executable path before running descriptor-safe helper snippets, reads `NOAA_NAVIONICS_GPS_SECONDS`, optional `NOAA_NAVIONICS_WARNING_SECONDS`, optional `NOAA_NAVIONICS_READINESS_ATTEMPTS`, optional `NOAA_NAVIONICS_READINESS_RETRY_DELAY`, optional `NOAA_NAVIONICS_OPENCPN_RESTARTS`, optional `NOAA_NAVIONICS_OPENCPN_RESTART_DELAY`, and optional `NOAA_NAVIONICS_START_ON_FAILED_READINESS` from `~/.config/noaa-navionics/launcher.env` through a no-follow descriptor only after rejecting a missing launcher environment, symlinked launcher environment files or path components, misowned or group/world-writable launcher environment directories, misowned launcher environment files, launcher environment files that are not private `0600`, malformed launcher environment lines, and unknown launcher environment keys, ignores ambient `NOAA_NAVIONICS_*` process environment variables so unattended boots use the commissioned private file, and production provisioning writes all startup policy keys explicitly, including `NOAA_NAVIONICS_START_ON_FAILED_READINESS=no`, so dock evidence does not depend on implicit launcher defaults. The launcher rejects missing or invalid launcher timing and fail-open values instead of falling back to defaults. It records launcher settings in status reports only after checking the launcher environment directory ownership and permissions, then using a no-follow descriptor read that confirms the file is still the inspected file, regular, user-owned, and private `0600`, makes boot readiness read GPS wait through `status-report --gps-seconds-from-launcher-env` instead of systemd `EnvironmentFile`, rejects symlinked cache path components, tightens the user-owned `~/.cache` parent to `0700`, keeps `~/.cache/noaa-navionics` private at `0700`, rejects misowned cache directories, writes private `0600` status and launcher-log files, rejects symlinked, non-regular, or misowned launcher logs before appending startup output and OpenCPN's exit status to `~/.cache/noaa-navionics/chartplotter.log` through a no-follow descriptor, rotates and syncs that log after 1 MB only after rejecting symlinked or non-regular rotated-log targets, keeps a synced private cache-directory launch lock stamped with the current Linux boot ID read through a no-follow descriptor for the supervised OpenCPN session, promotes lock PID and boot-ID files through exclusive private temporary files and atomic replacement, then reads them back through no-follow descriptors, requires existing launcher lock directories to be private `0700` and PID/boot-ID files to be private `0600` before trusting them, opens same-user `/proc` process directories and reads state plus NUL-delimited process arguments through no-follow descriptors rather than substring-matching lock owners, rejects symlinked lock paths before reading or cleaning them, leaves the lock untouched if it is swapped for a symlink or no longer belongs to the releasing launcher before release cleanup, refuses symlinked, misowned, non-private lock metadata, or group/world-writable stale lock debris before removing stale locks from previous boots or whose live PID is not actually the chartplotter launcher, rejects non-root OpenCPN executables or executable directories on Raspberry Pi hardware before startup, revalidates the resolved OpenCPN executable through no-follow same-file descriptors immediately before each launch or restart, resolves and revalidates `pgrep` through no-follow same-file descriptors before duplicate OpenCPN checks, leaves an existing live non-zombie OpenCPN process in place instead of starting a duplicate, resolves and revalidates `xset` through no-follow same-file descriptors before asking X11 desktop sessions to disable screen blanking and DPMS sleep, retries failed startup readiness reports before launching OpenCPN, and restarts OpenCPN after a nonzero exit status up to 3 times by default. Production Pi verification reads that private launcher environment through a no-follow descriptor before comparing persisted timing and restart policy, sizing strict startup waits, and rejecting fail-open startup. The readiness report also fails if the persisted launcher environment directory is owned by the wrong account or group/world-writable, or if the launcher environment is missing, not regular, owned by the wrong account, group/world-writable, malformed, or contains unknown keys, so typos and unsafe startup policy files do not silently pass dock verification. A clean status `0`, such as a deliberate manual close, is not restarted; if the launcher receives `TERM` or `INT`, it forwards shutdown to the supervised OpenCPN child, escalates to `KILL` if that child ignores the bounded shutdown wait, and releases the launch lock, so a stopped desktop session does not leave an unsupervised chartplotter process behind. Put `NOAA_NAVIONICS_OPENCPN_RESTARTS=0` in the launcher environment file for no crash-restart attempts. After the final failed readiness attempt, it shows a Tkinter warning with failed checks when a desktop is available, reading failed-check details only from a no-follow descriptor-confirmed private status file, and does not start OpenCPN automatically; in the default fail-closed mode the warning button only dismisses the dialog. Put `NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes` in the private launcher environment file only for deliberate manual fallback behavior where OpenCPN should launch despite failed readiness; production Pi verification rejects that override when proving the boat-ready startup path.

The launcher also revalidates both cache directories after creation or tightening before creating runtime files.
Launcher log pipe cleanup is no-follow and same-file validated before unlinking, leaving changed or untrusted FIFO paths in place.
The launcher log stream uses a no-follow descriptor-backed Python helper, and log rotation verifies the rotated inode before syncing it.

Manual launch:

```bash
noaa-navionics-start-chartplotter
```

Maintenance GUI:

```bash
noaa-navionics-gui
```

The GUI can load `~/.config/noaa-navionics/config.ini`, choose complete onboard chart packages, check writable chart storage and free space before creating a manual-download output directory, read one fresh timestamped quality-checked GPSD or serial GPS fix, sync the configured chart package with the same complete-chart guard as the CLI, write `~/.cache/noaa-navionics/status.json`, run preflight checks with the configured chart, GPSD, baud, chart-age, and track-storage values, and register the configured chart/GPSD connection with OpenCPN. The OpenCPN config writer creates or tightens the config directory to private `0700` permissions when writing, refuses symlinked, non-regular, misowned, or group/world-writable OpenCPN config files, symlinked path components, or misowned config directories, and forces private `0600` backup and replacement config files. Before writing, it refuses to edit while OpenCPN appears to be running, checking same-user `/proc` process directories, `stat`, and `comm` through no-follow descriptors and ignoring replaced or symlinked process evidence. After replacement, the promoted OpenCPN config is reopened through a no-follow descriptor, verified as the same regular private file, and compared with the expected content before the writer reports success. Close OpenCPN before using the GUI's OpenCPN configuration button.

Helm-readiness panel:

```bash
noaa-navionics-status-gui
```

The status GUI refreshes the same readiness report used by boot checks, writes `~/.cache/noaa-navionics/status.json` by default, and shows a large READY/NOT READY headline, a dedicated live GPS fix summary, plus individual chart, GPS, service, and track-log check rows for quick inspection at the Pi display. The status GUI marks incomplete or stale status JSON as NOT READY and adds visible missing-check rows instead of treating a partial report as passing. Shared readiness validation rejects missing, malformed, timezone-less, stale, or far-future `generated_at` timestamps; missing, unknown, or malformed host `boot_id` evidence; missing, unknown, dirty, symlinked, or error-marked deployed source-revision evidence; missing, invalid, or cross-section-mismatched onboard config evidence; missing, disabled, symlinked, unsafe, stale, or malformed user service and unit-file evidence; missing, disabled, symlinked, hidden, wrong-user, or malformed desktop autostart and LightDM evidence; missing, symlinked, error-marked, fail-open, or timing-invalid launcher policy evidence; missing, symlinked, error-marked, chart-missing, GPSD-missing, or stale-endpoint OpenCPN config evidence; missing, incomplete, symlinked, error-marked, or ENC-empty chart manifest evidence; missing, failed, stale, source-mismatched, coordinate-invalid, or low-quality top-level `gps_fix` evidence; and missing, failed, symlinked, stale, coordinate-invalid, or low-quality top-level `track_log` evidence before a report can read as ready. Action successes such as Anchor Check or anchor-watch OK do not change the headline back to READY unless the last full readiness report was also READY. Use its Mark or MOB buttons to write a private GPX waypoint from a fresh quality-checked GPS fix into the configured track export area, and use Anchor Check for a bounded fresh-fix drift check with an optional date-line-safe averaged anchor sample count; serial-mode button actions reject broken, fake, or non-device stable GPS paths before opening the GPS receiver. `--action-gps-seconds N` bounds those button-triggered GPS waits separately from automatic refreshes. Start Watch captures a fresh anchor fix, refuses to reset an active watch, freezes the selected watch radius, rechecks drift at `--anchor-watch-seconds N`, and Stop Watch requires a second press within 8 seconds before it cancels repeated anchor checks; Stop Watch stays available during long GPS/readiness actions so a watch can still be cancelled while a check is running. The panel ignores stale anchor-watch results and errors after the watch is stopped or reset, shows anchor/current GPS quality, keeps active anchor-watch alarms visible over action feedback or transient errors, rings the display bell when the drift check or anchor watch exceeds the radius, and cancels scheduled refresh, queue-poll, stop-confirmation, and anchor-watch callbacks when the window is closed.
READY reports also require structured Python, Tkinter, and Source Revision evidence, including Python 3.9+ runtime metadata, Tkinter availability for desktop warnings, and deployed source revision data matching the top-level app summary unless the report explicitly records a non-Pi diagnostic skip. READY reports also require structured Clock and Time Sync evidence, including a fresh timezone-aware clock timestamp and Raspberry Pi `SystemClockSynchronized=yes` unless the report explicitly records a non-Pi diagnostic skip. READY reports also require structured Pi Power and Pi Thermal evidence, including Raspberry Pi throttle flags and a finite temperature reading so under-voltage, throttling, and over-temperature conditions cannot be hidden in prose rows. READY reports also require structured Disk and Track Disk storage evidence, including absolute inspected paths, owner and mode, mount status, writability, and measured free space. READY reports also require structured Chart Package, Charts, Chart Update Debris, and Manifest evidence proving the configured NOAA ENC package is a complete chart set, the configured chart output has extracted ENC cells, no interrupted chart-update debris or unextracted ZIP-only state remains, and the manifest row matches the top-level manifest package, download, extract, checksum, ENC count, and configured max-age summary. READY reports also require structured OpenCPN Charts evidence proving the configured chart output is present in the parsed OpenCPN config. READY reports also require structured GPS or GPSD row evidence matching the top-level `gps_fix` coordinates, timestamp, and quality fields so the visible GPS row cannot diverge from the machine-validated fix summary. Serial-mode READY reports also require structured GPS Device evidence proving the configured path is stable, non-volatile, present, and a character device, with `/dev/serial/by-id/*` paths verified as udev symlinks. GPSD-mode READY reports also require structured OpenCPN GPSD evidence proving the configured GPSD endpoint is the enabled OpenCPN GPSD source and no stale enabled GPSD endpoints remain. GPSD-mode READY reports also require structured GPSD Config evidence proving `/etc/default/gpsd` is root-owned, non-writable, points only at the configured GPS device, disables USB auto-discovery, and enables `-n` immediate polling. GPSD-mode READY reports also require structured Chrony Config and GPS Time Source evidence proving `/etc/chrony/chrony.conf` is root-owned, non-writable, contains the managed GPSD SHM refclock, and that chrony has selected or combined a GPS refclock source. READY reports also require structured OpenCPN and Display Power command evidence, including absolute root-owned non-symlinked executable paths in trusted system directories with non-writable command and directory modes.

## Charts

Download Alaska charts:

```bash
noaa-navionics sync-charts
```

Each sync writes `noaa-navionics-manifest.json` next to the chart data. The manifest records the NOAA package URL, actual download URL, ZIP filename, download size, SHA-256, extraction path, ENC cell count, and chart freshness time. Onboard config rejects updates-only and catalog-only packages because they are not complete chart sources, and rejects broad, volatile, or system chart and track storage paths before any sync or GPX logging starts. Configured syncs require `[charts] min_free_gb` free space on writable chart storage before creating the chart output directory or starting a NOAA download. Direct chart downloads, extraction, and manifest writes reject symlinked chart output path components before creating storage, locks, archives, extracted trees, or manifests, then make the chart output directory private `0700` to the installing user. Chart archive, extraction, and manifest promotion revalidate output paths immediately before replacement, extraction cleanup revalidates stale chart debris as the same file or directory immediately before removal, and extracted ENC directories/files are tightened to private `0700`/`0600` before promotion, so a swapped symlink, unsafe target, replaced cleanup target, or permissive ZIP member mode does not become the live offline chart set. Keep the production default `[charts] force = yes` so scheduled refreshes download a current NOAA bundle instead of reusing an old cache. If you set `force = no`, an existing ZIP is reused for chart extraction only when it is a regular user-owned file with no group/other write bits and matches the trusted previous manifest for the same NOAA package and a compatible actual download URL, preserving that manifest's timestamp and download URL; cache-reuse hashes are computed from the same no-follow descriptor that sync validated. A cached ZIP with no trusted previous manifest, unsafe ownership or permissions, mismatched source metadata, or a mismatched size/SHA-256 fails before extraction until you force a fresh download. ZIP extraction checks member paths and CRCs before creating extraction staging, tightens extracted ENC directories/files to private `0700`/`0600`, revalidates stale chart debris as the same file or directory immediately before cleanup, and refuses packages with no ENC `.000` cells, an existing non-directory extraction target, unsafe `.previous` extraction debris, replaced cleanup targets, or a Python runtime without symlink-attack-resistant `shutil.rmtree` before replacing the previous chart directory. Completed ZIP downloads are created through exclusive no-follow private `0600` partial files; downloaded ZIPs must open cleanly, contain only safe member paths, pass CRC checks, and contain ENC `.000` cells before they can replace a retained archive. Catalog downloads and cached catalog reuse are parsed as XML and must contain NOAA ENC chart metadata before replacing or trusting the product catalog. Completed ZIPs, extracted chart trees, manifest JSON, and the affected directory entries are synced before atomic replacement; Chart tree sync uses no-follow opens for directories and regular files. Manifest writes use unique temporary files. Manifest fallback ZIP hashes use the same trusted no-follow archive hash path. If a previous interrupted download left a fixed `.part` file beside the target ZIP, the next sync refuses to overwrite it and tells you to remove interrupted chart update debris first. Failed download cleanup revalidates interrupted `.part` files as regular, user-owned, non-group/world-writable files and same-file validates them before removing them, leaving unsafe or replaced debris in place for preflight to catch. If `[charts] keep_zip = no`, the ZIP is revalidated as a regular trusted archive and same-file validated immediately before removal after extraction, even when it was already cached. Syncs hold a synced private `0600` no-follow `.noaa-navionics-download.lock` in the chart directory so a timer run and a manual run cannot update the same chart set at the same time; symlinked lock paths are rejected, stale lock reads use a no-follow descriptor, stale and release lock cleanup is same-file validated before unlinking, stale lock cleanup refuses misowned or non-private lock files, and stale lock cleanup records PID and a Linux `boot_id` value after reading the current boot ID through a no-follow descriptor, using a boot mismatch only when both lock and current boot IDs have the valid Linux `boot_id` UUID shape so an old lock is not removed while its owner is still running on the current boot. Preflight defaults to `[charts].output`, and `--charts PATH` explicitly checks another mounted chart directory. Preflight requires chart storage to be owned by the deployed user with no group/other write bits, requires this manifest, fails if it is older than `max_age_days`, fails if stale chart-update staging, previous directories, partial `.part` files, or unexpected top-level ZIP files remain from an interrupted or manual sync, verifies that the recorded NOAA ZIP filename, package URL, and actual download URL still identify the configured chart package filename without an HTTPS downgrade or non-NOAA redirect, verifies that the recorded download path stays under chart storage and records a positive byte count and SHA-256 even when the ZIP is not retained, verifies that the recorded extraction path is still under the selected chart directory, verifies that its live chart tree is user-owned with no group/other write bits and contains exactly the manifest-recorded regular non-symlink ENC cell count with no missing or extra cells, and fails if another top-level ENC chart directory remains beside the manifest extract. Storage configured under `/mnt`, `/media`, or `/run/media` must have an actual mounted device on that path or one of its parents, so an unplugged USB drive does not accidentally pass readiness against the Pi's SD card. If `[charts] keep_zip = yes`, preflight also requires the recorded retained ZIP to still exist under chart storage, then verifies its recorded path, regular-file status, owner, permissions, size, SHA-256, ZIP member paths, CRCs, and ENC cell presence; retained ZIP hashes and archive checks are computed from no-follow descriptors that readiness verified. That retained archive is the only top-level ZIP preflight allows.
Chart output directory permission tightening is revalidated before creating locks, archives, extracted trees, or manifests.
Manifest writes refuse existing symlinked or non-regular manifest targets before replacing metadata. Manifest reads reject symlinked manifest files or parent path components, unsafe manifest directory ownership or permissions, and unsafe manifest file ownership or permissions before trusting cached or readiness metadata.
NOAA download redirects that downgrade to HTTP, leave NOAA hosts, or change filenames fail before archive replacement.
The installed chart refresh service runs `sync-charts` with retries, a two-hour systemd start timeout, delayed service-level retry attempts, `NoNewPrivileges`, a private temporary directory, `ProtectSystem=full`, `LockPersonality`, `RestrictSUIDSGID`, `MemoryDenyWriteExecute`, `RestrictRealtime`, `SystemCallArchitectures=native`, a private `0077` umask, and a 30-minute randomized timer delay so missed weekly refreshes do not always run immediately at boot beside chartplotter startup.
If a weekly chart refresh fails while the boat is offline, the status report records the failed service state but does not fail readiness on that alone; manifest age, package match, extraction path, and ENC cell checks decide whether the installed charts are still usable. A missing or disabled chart-refresh service still fails readiness because the Pi would no longer refresh charts automatically.
Preflight requires a plausible system clock. Raspberry Pi hardware detection reads `/proc/device-tree/model` only through a no-follow same-file descriptor before deciding whether Pi-only clock, power, thermal, and command-owner checks apply. On Raspberry Pi targets it also requires `timedatectl` to report the system clock synchronized before relying on chart age or GPX timestamps. Provisioning configures chrony to use GPSD's `SHM 0` message-based time source, which is sufficient for chart age and GPX timestamps. For sub-second timekeeping, add GPS/PPS hardware and tune chrony for PPS separately.

For another cruising area, use `--state`, `--cgd`, `--region`, or individual `--chart` downloads. Use the catalog search to identify specific cells:

```bash
noaa-navionics search-catalog "Cook Inlet"
```

Do not use a NOAA `updates` bundle as the primary onboard chart package. Update bundles only contain recently changed cells, so onboard config rejects them and preflight treats them as incomplete for navigation readiness.

Register the chart directory and GPSD connection in OpenCPN:

```bash
noaa-navionics configure-opencpn
```

This backs up `~/.opencpn/opencpn.conf` if it already exists, adds the configured chart directory under `[ChartDirectories]`, adds a GPSD network connection under `[Settings/NMEADataSource]` only when `[gps] mode = gpsd`, and leaves OpenCPN closed. It refuses to register missing, non-directory, or symlinked chart directories. Backups and replacement config files are synced to disk, backup names are made unique when multiple writes happen in the same second, and replacement writes use unique temporary files. Preflight requires OpenCPN's configured chart directory to exist so stale paths or missing chart storage do not pass readiness. The chartplotter launcher starts OpenCPN with `-parse_all_enc` so OpenCPN processes available S-57 ENC charts on start.

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

The status report includes readiness checks, NOAA Navionics user unit path-component integrity checks, user unit-file and unit-directory owner/mode checks, parsed user unit-file `[Install]` targets, loaded user unit fragment-path and setting checks when systemd reports them, including installed `%h/.local/bin/noaa-navionics` command paths, private temp, read-only system filesystem, and private umask settings, a recent valid current-boot GPX trackpoint check with satellite or HDOP quality metadata after parsing finite non-negative `/proc/uptime` and a brief post-GPS wait for the logger to flush, manifest-recorded and live regular non-symlink ENC cell counts from a user-owned non-writable extracted chart tree, OpenCPN command integrity, launcher environment path-component integrity and settings with fail-closed startup, known-key, malformed-line, and OpenCPN restart-setting checks, parsed OpenCPN chart/GPSD config path integrity and state, desktop autostart and LightDM autologin path-component integrity and state, GPSD startup config checks for local receivers, chrony GPSD SHM refclock config, and GPSD socket/service plus chrony service state checks. Sample-based status reports substitute only the live GPS fix read; when the onboard config is in `gpsd` mode they still verify OpenCPN's GPSD connection. Status reports and Pi verification reject symlinked, writable, misowned, or untrusted-directory OpenCPN commands before trusting chart display startup. Pi verification compares status-reported launcher settings only after a no-follow descriptor read confirms the live launcher environment is still regular, user-owned, and private `0600`. OpenCPN chart and GPSD config reads use a no-follow descriptor and reject symlinked path components, non-regular files, writable files, or files owned by the wrong user before trusting chart or GPSD settings. OpenCPN backup and directory sync use no-follow opens while provisioning updates chart/GPSD settings. Status report directory sync uses no-follow directory opens after atomic replacement, and the promoted JSON is reopened through a no-follow descriptor, checked as private `0600`, and parsed before the writer reports success. Status reports and Pi verification parse desktop autostart and LightDM autologin files only after a no-follow descriptor read confirms the opened file is still the inspected file, regular, and not group/world-writable. Pi verification reads the live LightDM autologin session and chrony GPSD refclock config through no-follow descriptors before trusting graphical startup or GPS-disciplined time. Pi verification also parses the onboard app config through a no-follow descriptor read, runs GPSD device comparisons through that same trusted config read path, ensures recent GPX trackpoint verification uses that same trusted config read path, compares desktop autostart, LightDM autologin, and manifest files through no-follow descriptor reads, validates the extracted chart tree, and hashes retained-download archives through the same no-follow descriptor it verified. Status reports and Pi verification also reject symlinked, non-regular, writable, or misowned desktop autostart, LightDM autologin, and manifest files, plus symlinked retained-download or extract path components before trusting startup state or chart freshness.
Status reports and Pi verification compare desktop autostart, LightDM autologin, and manifest files through same-file no-follow descriptor reads before trusting startup or chart freshness.
The boot readiness service reads `~/.config/noaa-navionics/launcher.env` so it uses the same GPS fix wait as the chartplotter launcher.
It is written through a unique temporary file and atomic replace, then reopened and parsed through a no-follow descriptor, so overlapping launcher and readiness-service writes cannot corrupt the JSON artifact.
The status JSON writer rejects symlinked cache parent components, tightens a user-owned `~/.cache` parent and the private report directory to `0700`, revalidates both after permission tightening before writing JSON, syncs the file and replacement directory entry to disk, and strict verification rejects symlinked, misowned, or public cache parents, public cache directories, or public status files.
Readiness and Pi verification require a well-formed `vcgencmd get_throttled` value and fail on any current or historical under-voltage, frequency capping, throttling, or soft thermal limiting reported since boot. Readiness also requires a readable thermal sensor through a no-follow same-file descriptor or a well-formed finite `vcgencmd measure_temp` value before trusting the enclosure temperature margin.
It also records the current Linux boot ID only when it has the expected Linux `boot_id` UUID shape, and records the installed source revision through synced private `0600` atomic file writes so you can confirm the Pi is running the expected deployment and that the recorded revision path contains no symlinked component. Status reports and Pi readiness read that revision through a no-follow descriptor after confirming the source revision directory is user-owned and not group/world-writable, and the opened file is still the inspected file, regular, user-owned, and not group/world-writable. On Raspberry Pi targets, readiness fails if that deployed source revision directory is misowned or group/world-writable, or if the deployed source revision is missing, symlinked, non-regular, misowned, group/world-writable, recorded through a symlinked path component, recorded as `unknown`, or recorded with a dirty `-dirty` suffix.

Expected checks:

- Python 3.9+
- System clock has a sane modern UTC date
- Raspberry Pi clock is synchronized before chart-age and GPX timestamp checks are trusted
- Tkinter available for the GUI
- OpenCPN installed as a trusted non-writable command, root-owned on Raspberry Pi
- trusted root-owned `xset` available so the launcher can disable X11 display blanking and DPMS sleep and the verifier can prove it stayed disabled
- trusted root-owned `pgrep` available from `procps` so launcher and verifier process checks work
- trusted root-owned `vcgencmd`, `chronyc`, `gpsd`, and `cgps` available so power, time, and GPS checks use trusted command paths
- Chartplotter startup log has no display-awake command failures or OpenCPN exit marker after the current boot
- Desktop autostart installed for the chartplotter launcher and not marked hidden or disabled
- Configured chart package is a complete chart source, not an updates-only bundle
- Extracted ENC chart cells present
- Current chart manifest present, matching the configured chart package, and tied to an existing extraction with exactly the recorded ENC cell count
- OpenCPN configured with the chart directory
- OpenCPN configured with the GPSD network connection
- Chrony enabled, active, configured to use GPSD time, and reporting a usable GPS refclock source
- Graphical boot and LightDM autologin configured with an installed X11 session for unattended startup
- Configured local GPS device path exists when GPSD is using a local receiver
- At least `[charts] min_free_gb` free disk space on writable chart storage, and on separate track storage when `[tracking] output` uses a different path; `/mnt`, `/media`, and `/run/media` storage paths must actually be mounted
- No current or since-boot Raspberry Pi under-voltage or throttling
- Raspberry Pi thermal sensor or `vcgencmd measure_temp` readable, and temperature below the hard limit
- Fresh navigation-quality GPSD or direct NMEA fix with satellite or HDOP quality fields
- Chart refresh timer, including its bounded NOAA TCP connectivity check, track logger, boot readiness service, GPSD socket/service, and chrony service are in the expected state
- During the dock test after reboot, the status report and chartplotter launcher ran during the current boot, the private user-owned launcher lock is owned by a live launcher process, and launcher-supervised OpenCPN is running

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

The generated GPX files are stored under `~/charts/noaa-enc/tracks/` by default. The systemd service reads `[gps]` and `[tracking] output` from the onboard config and writes one file per UTC day, such as `track-20260629.gpx`; manual `--device`, `--baud`, `--gpsd`, and `--output` flags override the config for direct troubleshooting. If the service restarts on the same day it uses a numeric suffix instead of overwriting the earlier file.

Daily rotated GPX files live in a private user-owned `0700` tracks directory and are created exclusively with private `0600` no-follow opens, so explicit existing output files or symlinked GPX output files fail instead of being truncated. The new file entry is synced after creation, GPX directory sync uses no-follow directory opens, service-created track files also use a private `0077` umask, and track files are flushed at every point and periodically synced to disk to reduce data loss after abrupt power loss. Retention pruning validates old GPX entries through no-follow descriptors, revalidates the directory entry as the same file immediately before unlinking, and refuses replaced, symlinked, non-regular, misowned, or non-private old GPX entries instead of deleting them.

The logger skips invalid coordinates, missing satellite/HDOP quality fields, untimestamped fixes, timezone-less timestamps, stale or future-dated timestamps, and weak satellite/HDOP fixes instead of writing them to GPX; accepted trackpoints record GPX `<sat>` and/or `<hdop>` quality fields, and single-file logging does not create the output file until the first accepted timestamped quality fix. A bounded diagnostic run such as `log-track --seconds 30` retries initial GPSD connection refusals inside the timeout and exits non-zero if no usable fix is written before the timeout. An untimed live GPSD logger waits and retries if GPSD is not accepting connections yet at boot or if the first connected GPSD stream ends before any fix arrives, then keeps the connected stream through temporary GPSD quiet periods, but exits non-zero after 300 quiet seconds by default so systemd can restart a silent receiver path. Use `--gpsd-idle-timeout 0` or `--serial-idle-timeout 0` only for manual troubleshooting where idle recovery should be disabled. Live serial logging uses the same 300-second quiet limit for an open receiver that stops sending NMEA bytes. After a successful connection, it exits non-zero if the GPS stream ends unexpectedly, so the installed `Restart=on-failure` service restarts instead of silently stopping after a transient GPSD or device interruption.

The installed service drops per-fix stdout so normal GPS logging does not fill the systemd journal, while stderr warnings and failures still go to the service log. When systemd stops the logger during reboot or shutdown, SIGTERM handling closes the current GPX file before exit. If `[tracking] output` points somewhere other than the chart directory, preflight checks that separate destination has an existing writable parent and enough free space. Status reports and Pi verification read candidate GPX track files only after a no-follow descriptor confirms the opened file is still the inspected file, regular, user-owned, and private `0600`; status reports and Pi verification reject symlinked GPX storage path components, missing GPX satellite/HDOP quality fields, non-finite GPX trackpoint coordinates, timezone-less or future-dated GPX trackpoint timestamps, and negative GPX HDOP before accepting recent trackpoints. By default, rotated track logs older than 90 days are pruned; set `[tracking] retention_days = 0` to disable pruning.
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

The service writes `~/.cache/noaa-navionics/status.json`, disables systemd's start timeout so persisted cold-start GPS waits can finish, fails readiness on disabled, missing, failed, or unqueryable NOAA Navionics units, retries initial GPSD connection refusals inside that wait, and retries briefly if GPSD is not producing a valid fix yet.

## Operational Notes

- Do not run the Python serial reader and OpenCPN against `/dev/ttyUSB0` at the same time. Use GPSD for shared production use.
- Keep paper charts or an independent backup navigation device on board.
- NOAA ENCs are official data, but this project is not certified navigation equipment.
- Test the full setup at the dock with the GPS outdoors before using it underway.
- Keep the Pi clock synchronized when online; GPS timestamps are UTC.
