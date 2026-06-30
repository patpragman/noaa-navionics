from pathlib import Path
from datetime import datetime, timedelta, timezone
from contextlib import redirect_stderr, redirect_stdout
from http.client import IncompleteRead
from io import BytesIO, StringIO
from urllib.error import URLError
import json
import math
import shutil
import stat
import sys
import signal
import tempfile
import threading
import textwrap
import time
import unittest
import zipfile
import os
from unittest.mock import patch

TEST_TMP_PARENT = Path(__file__).resolve().parents[1]

sys.path.insert(0, str(TEST_TMP_PARENT / "src"))

from noaa_navionics import health as health_module
from noaa_navionics import config as config_module
from noaa_navionics import downloader as downloader_module
from noaa_navionics import gps as gps_module
from noaa_navionics import cli as cli_module
from noaa_navionics import gui as gui_module
from noaa_navionics import opencpn as opencpn_module
from noaa_navionics import report as report_module
from noaa_navionics.downloader import (
    DOWNLOAD_LOCK_NAME,
    MANIFEST_NAME,
    Package,
    download_package,
    extract_zip,
    package_for,
    read_manifest,
    search_catalog,
)
from noaa_navionics.config import AppConfig, default_config_text, package_kwargs, read_config, write_default_config
from noaa_navionics.cli import (
    _TrackLoggerStop,
    _log_rotating_tracks,
    _log_single_track,
    _raise_track_logger_stop,
    _trackable_fixes,
)
from noaa_navionics.gps import (
    GPSFix,
    GPXTrackLogger,
    _parse_time_today,
    daily_track_path,
    gps_fix_quality_failure,
    iter_fixes,
    iter_gpsd_fixes,
    parse_gpsd_sky,
    parse_gpsd_tpv,
    parse_nmea_sentence,
)
from noaa_navionics.health import (
    check_chart_dir,
    check_chart_manifest,
    check_chart_update_debris,
    check_disk_space,
    check_chart_package,
    check_gps_device,
    check_gps_device_path,
    check_gpsd,
    check_gpsd_startup_config,
    check_gps_sample,
    check_display_power_tool,
    check_chrony_gps_time_config,
    check_chrony_gps_time_source,
    check_opencpn,
    check_opencpn_chart_config,
    check_opencpn_gpsd_config,
    check_pi_temperature,
    check_pi_throttling,
    check_source_revision,
    check_system_clock,
    check_time_synchronization,
    _parse_vcgencmd_temperature,
    _parse_throttled_value,
    _read_trusted_config_lines,
    _sha256_trusted_file,
)
from noaa_navionics.opencpn import (
    chart_directory_configured,
    configure_chart_directory,
    configure_gpsd_connection,
    gpsd_connection_configured,
    read_data_connections,
    read_chart_directories,
)
from noaa_navionics.report import (
    build_status_report,
    format_status_text,
    write_status_report,
    _install_wanted_by_targets,
    _key_value_file_summary,
    _launcher_settings_summary,
    _launcher_settings_check,
    _read_trusted_gpx_track_file,
    _service_readiness_checks,
    _track_log_readiness_check,
    _track_log_summary,
    _user_unit_file_summary,
)


def trusted_unit_file(path: str, wanted_by: list[str], **overrides: object) -> dict[str, object]:
    state: dict[str, object] = {
        "path": path,
        "exists": True,
        "is_symlink": False,
        "directory_is_symlink": False,
        "path_symlink_component": "",
        "uid": os.getuid(),
        "mode": "0600",
        "directory_uid": os.getuid(),
        "directory_mode": "0700",
        "wanted_by": wanted_by,
    }
    state.update(overrides)
    return state


class PackageForTests(unittest.TestCase):
    def test_state_package(self):
        package = package_for(state="ak")
        self.assertEqual(package.filename, "AK_ENCs.zip")
        self.assertEqual(package.url, "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip")

    def test_update_package(self):
        package = package_for(updates="10 days")
        self.assertEqual(package.filename, "TenDays_ENCs.zip")

    def test_cgd_package_is_zero_padded(self):
        package = package_for(cgd="7")
        self.assertEqual(package.filename, "07CGD_ENCs.zip")

    def test_rejects_unsupported_prepackaged_package_codes(self):
        with self.assertRaisesRegex(ValueError, "state must be one of"):
            package_for(state="ZZ")
        with self.assertRaisesRegex(ValueError, "Coast Guard district must be one of"):
            package_for(cgd="99")
        with self.assertRaisesRegex(ValueError, "region must be one of"):
            package_for(region="99")

    def test_requires_one_selector(self):
        with self.assertRaises(ValueError):
            package_for(state="AK", region="30")


class CatalogTests(unittest.TestCase):
    def test_search_catalog(self):
        xml = textwrap.dedent(
            """\
            <?xml version="1.0" encoding="UTF-8"?>
            <DS_Series xmlns="http://www.isotc211.org/2005/gmd"
                xmlns:gco="http://www.isotc211.org/2005/gco">
              <composedOf>
                <DS_DataSet>
                  <has>
                    <MD_Metadata>
                      <identificationInfo>
                        <MD_DataIdentification>
                          <citation>
                            <CI_Citation>
                              <title><gco:CharacterString>US5AK3CM</gco:CharacterString></title>
                              <alternateTitle><gco:CharacterString>Cook Inlet</gco:CharacterString></alternateTitle>
                              <edition><gco:CharacterString>12.0</gco:CharacterString></edition>
                            </CI_Citation>
                          </citation>
                          <descriptiveKeywords>
                            <MD_Keywords>
                              <keyword><gco:CharacterString>state: AK</gco:CharacterString></keyword>
                              <keyword><gco:CharacterString>region: 30</gco:CharacterString></keyword>
                              <keyword><gco:CharacterString>coast guard district: 17</gco:CharacterString></keyword>
                            </MD_Keywords>
                          </descriptiveKeywords>
                        </MD_DataIdentification>
                      </identificationInfo>
                      <distributionInfo>
                        <MD_Distribution>
                          <transferOptions>
                            <MD_DigitalTransferOptions>
                              <onLine>
                                <CI_OnlineResource>
                                  <linkage><URL>https://www.charts.noaa.gov/ENCs/US5AK3CM.zip</URL></linkage>
                                </CI_OnlineResource>
                              </onLine>
                            </MD_DigitalTransferOptions>
                          </transferOptions>
                        </MD_Distribution>
                      </distributionInfo>
                    </MD_Metadata>
                  </has>
                </DS_DataSet>
              </composedOf>
            </DS_Series>
            """
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "catalog.xml"
            path.write_text(xml, encoding="utf-8")
            matches = search_catalog(path, "cook", limit=5)
            self.assertEqual(len(matches), 1)
            self.assertEqual(matches[0].name, "US5AK3CM")
            self.assertEqual(matches[0].states, ("AK",))


class ConfigTests(unittest.TestCase):
    def test_write_and_read_default_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            written = write_default_config(path)
            self.assertEqual(written, path)
            config = read_config(path)
            self.assertEqual(config.chart_package, "state")
            self.assertEqual(config.chart_value, "AK")
            self.assertEqual(config.gps_mode, "gpsd")
            self.assertEqual(config.gps_device, "/dev/serial/by-id/YOUR_GPS_DEVICE")
            self.assertEqual(config.max_chart_age_days, 30)
            self.assertEqual(config.min_free_gb, 2.0)
            self.assertEqual(config.track_retention_days, 90)
            self.assertTrue(config.extract)

    def test_write_default_config_creates_private_parent_and_file_with_permissive_umask(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            path = root / ".config" / "noaa-navionics" / "config.ini"
            original_umask = os.umask(0)
            try:
                write_default_config(path)
            finally:
                os.umask(original_umask)

            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_write_default_config_rejects_writable_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / ".config" / "noaa-navionics"
            parent.mkdir(parents=True)
            parent.chmod(0o777)
            try:
                with self.assertRaisesRegex(RuntimeError, "no group/other write bits"):
                    write_default_config(parent / "config.ini")
            finally:
                parent.chmod(0o700)

    def test_write_default_config_rejects_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-config"
            real_parent.mkdir()
            link_parent = root / ".config" / "noaa-navionics"
            link_parent.parent.mkdir()
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "symlink"):
                write_default_config(link_parent / "config.ini")

    def test_write_default_config_rejects_symlinked_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config_root = root / "real-config-root"
            real_config_root.mkdir()
            link_config_root = root / ".config"
            try:
                link_config_root.symlink_to(real_config_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config directory is a symlink"):
                write_default_config(link_config_root / "noaa-navionics" / "config.ini")

            self.assertFalse((real_config_root / "noaa-navionics" / "config.ini").exists())

    def test_write_default_config_rejects_symlinked_config_file_when_overwriting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config = root / "real-config.ini"
            write_default_config(real_config)
            link_config = root / "config.ini"
            try:
                link_config.symlink_to(real_config)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config is a symlink"):
                write_default_config(link_config, overwrite=True)

    def test_read_config_rejects_symlinked_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config = root / "real-config.ini"
            write_default_config(real_config)
            link_config = root / "config.ini"
            try:
                link_config.symlink_to(real_config)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config is a symlink"):
                read_config(link_config)

    def test_read_config_rejects_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-config"
            real_parent.mkdir()
            write_default_config(real_parent / "config.ini")
            link_parent = root / ".config" / "noaa-navionics"
            link_parent.parent.mkdir()
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config directory is a symlink"):
                read_config(link_parent / "config.ini")

    def test_read_config_rejects_symlinked_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config_root = root / "real-config-root"
            real_config_parent = real_config_root / "noaa-navionics"
            real_config_parent.mkdir(parents=True)
            write_default_config(real_config_parent / "config.ini")
            link_config_root = root / ".config"
            try:
                link_config_root.symlink_to(real_config_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config directory is a symlink"):
                read_config(link_config_root / "noaa-navionics" / "config.ini")

    def test_read_config_rejects_symlinked_parent_when_config_missing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-config"
            real_parent.mkdir()
            link_parent = root / ".config" / "noaa-navionics"
            link_parent.parent.mkdir()
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config directory is a symlink"):
                read_config(link_parent / "missing.ini")

    def test_read_config_rejects_nonregular_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.ini"
            config_path.mkdir()

            with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config is not a regular file"):
                read_config(config_path)

    def test_read_config_rejects_writable_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.ini"
            config_path.write_text(default_config_text(), encoding="utf-8")
            config_path.chmod(0o620)
            try:
                with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config .* has permissions"):
                    read_config(config_path)
            finally:
                config_path.chmod(0o600)

    def test_write_default_config_rejects_unsafe_existing_config_when_overwriting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.ini"
            config_path.write_text(default_config_text(), encoding="utf-8")
            config_path.chmod(0o620)
            try:
                with self.assertRaisesRegex(RuntimeError, "NOAA Navionics config .* has permissions"):
                    write_default_config(config_path, overwrite=True)
            finally:
                config_path.chmod(0o600)

    def test_write_default_config_uses_unique_synced_temp_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            path = root / "config.ini"
            fixed_part = root / "config.ini.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")
            calls = []
            original_fsync = config_module.os.fsync
            config_module.os.fsync = lambda fd: calls.append(fd)
            try:
                write_default_config(path)
            finally:
                config_module.os.fsync = original_fsync

            self.assertEqual(fixed_part.read_text(encoding="utf-8"), "other writer\n")
            self.assertFalse(list(root.glob(".config.ini.*.part")))
            self.assertGreaterEqual(len(calls), 2)

    def test_write_default_config_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = config_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        config_module.os.open = fake_open
        try:
            config_module._fsync_directory(Path("/tmp"))
        finally:
            config_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], Path("/tmp"))
        self.assertTrue(calls[0][1] & getattr(os, "O_DIRECTORY", 0))
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_custom_config_package_kwargs(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            path.write_text(
                "[charts]\n"
                "package = cgd\n"
                "value = 17\n"
                "output = /charts\n"
                "extract = true\n"
                "keep_zip = false\n"
                "force = false\n"
                "max_age_days = 14\n"
                "min_free_gb = 4.5\n"
                "\n"
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 9600\n"
                "gpsd_host = 192.168.1.10\n"
                "gpsd_port = 2947\n"
                "[tracking]\n"
                "retention_days = 14\n",
                encoding="utf-8",
            )
            config = read_config(path)
            self.assertEqual(package_kwargs(config), {"cgd": "17"})
            self.assertEqual(config.gps_mode, "serial")
            self.assertEqual(config.gps_device, "/dev/serial/by-id/mock-gps")
            self.assertEqual(config.gps_baud, 9600)
            self.assertEqual(config.max_chart_age_days, 14)
            self.assertEqual(config.min_free_gb, 4.5)
            self.assertEqual(config.track_retention_days, 14)
            self.assertFalse(config.keep_zip)
            self.assertFalse(config.force)

    def test_config_allows_run_media_storage_paths(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            path.write_text(
                "[charts]\n"
                "output = /run/media/pi/NOAA/charts\n"
                "\n"
                "[tracking]\n"
                "output = /run/media/pi/NOAA/tracks\n",
                encoding="utf-8",
            )

            config = read_config(path)

            self.assertEqual(config.chart_output, Path("/run/media/pi/NOAA/charts"))
            self.assertEqual(config.track_output, Path("/run/media/pi/NOAA/tracks"))

    def test_invalid_gps_mode_fails_config_read(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            path.write_text("[gps]\nmode = bluetooth\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "gps.mode"):
                read_config(path)

    def test_invalid_config_values_fail_fast(self):
        cases = [
            ("[charts]\npackage = potato\n", "charts.package"),
            ("[charts]\npackage = updates\nvalue = ten-days\n", "charts.package"),
            ("[charts]\npackage = catalog\n", "charts.package"),
            ("[charts]\npackage = state\nvalue =\n", "charts.value"),
            ("[charts]\noutput =\n", "charts.output"),
            ("[charts]\noutput = charts/noaa-enc\n", "charts.output"),
            ("[charts]\noutput = /\n", "charts.output"),
            ("[charts]\noutput = ~\n", "charts.output"),
            ("[charts]\noutput = ~/.config\n", "charts.output"),
            ("[charts]\noutput = /etc\n", "charts.output"),
            ("[charts]\noutput = /etc/noaa-navionics\n", "charts.output"),
            ("[charts]\noutput = /tmp/noaa-navionics\n", "charts.output"),
            ("[charts]\noutput = /usr/local/noaa-navionics\n", "charts.output"),
            ("[charts]\npackage = state\nvalue = ZZ\n", "charts.value"),
            ("[charts]\npackage = cgd\nvalue = 99\n", "charts.value"),
            ("[charts]\npackage = region\nvalue = 99\n", "charts.value"),
            ("[charts]\nmax_age_days = 0\n", "charts.max_age_days"),
            ("[charts]\nmin_free_gb = 0\n", "charts.min_free_gb"),
            ("[charts]\nmin_free_gb = nan\n", "charts.min_free_gb"),
            ("[charts]\nextract = maybe\n", "charts.extract"),
            ("[gps]\nmode = serial\ndevice =\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice =\n", "gps.device"),
            ("[gps]\nmode = serial\ndevice = /dev/ttyACM0\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/ttyUSB0\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/ttyAMA0\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/serial/by-id/\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/serial/by-id/../ttyS0\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/serial/by-id/mock/extra\n", "gps.device"),
            ("[gps]\nmode = gpsd\ndevice = /dev/serial/by-id/$(id)\n", "gps.device"),
            ("[gps]\nbaud = 12345\n", "gps.baud"),
            ("[gps]\ngpsd_host = 127.0.0.1;bad\n", "gps.gpsd_host"),
            ("[gps]\nmode = gpsd\ngpsd_host = 192.168.1.10\n", "gps.gpsd_host"),
            ("[gps]\ngpsd_port = 70000\n", "gps.gpsd_port"),
            ("[tracking]\noutput =\n", "tracking.output"),
            ("[tracking]\noutput = tracks\n", "tracking.output"),
            ("[tracking]\noutput = /\n", "tracking.output"),
            ("[tracking]\noutput = ~\n", "tracking.output"),
            ("[tracking]\noutput = ~/.cache\n", "tracking.output"),
            ("[tracking]\noutput = /var\n", "tracking.output"),
            ("[tracking]\noutput = /var/tmp/noaa-navionics\n", "tracking.output"),
            ("[tracking]\noutput = /run/noaa-navionics\n", "tracking.output"),
            ("[tracking]\nretention_days = -1\n", "tracking.retention_days"),
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            for index, (text, error) in enumerate(cases):
                with self.subTest(error=error):
                    path = root / f"config-{index}.ini"
                    path.write_text(text, encoding="utf-8")

                    with self.assertRaisesRegex(ValueError, error):
                        read_config(path)


class OpenCPNConfigTests(unittest.TestCase):
    def test_configure_chart_directory_creates_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / ".opencpn" / "opencpn.conf"
            charts = root / "charts" / "noaa-enc"
            charts.mkdir(parents=True)

            result = configure_chart_directory(charts, config_path=config)

            self.assertTrue(result.changed)
            self.assertEqual(result.key, "ChartDir1")
            self.assertTrue(config.exists())
            self.assertEqual(config.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            self.assertEqual(read_chart_directories(config), [charts.resolve()])
            self.assertTrue(chart_directory_configured(charts, config))

    def test_configure_chart_directory_rejects_missing_chart_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "missing-charts"

            with self.assertRaisesRegex(RuntimeError, "OpenCPN chart directory does not exist"):
                configure_chart_directory(charts, config_path=config)

            self.assertFalse(config.exists())

    def test_configure_chart_directory_rejects_non_directory_chart_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"
            charts.write_text("not a directory\n", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "OpenCPN chart directory is not a directory"):
                configure_chart_directory(charts, config_path=config)

            self.assertFalse(config.exists())

    def test_configure_chart_directory_rejects_symlinked_chart_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            real_charts = root / "real-charts"
            real_charts.mkdir()
            chart_link = root / "charts"
            try:
                chart_link.symlink_to(real_charts, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "OpenCPN chart directory path contains a symlink"):
                configure_chart_directory(chart_link, config_path=config)

            self.assertFalse(config.exists())

    def test_configure_chart_directory_rejects_writable_config_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / ".opencpn"
            parent.mkdir()
            parent.chmod(0o777)
            config = parent / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            try:
                with self.assertRaisesRegex(RuntimeError, "no group/other write bits"):
                    configure_chart_directory(charts, config_path=config)
            finally:
                parent.chmod(0o700)

    def test_configure_chart_directory_tightens_public_config_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            parent = root / ".opencpn"
            parent.mkdir()
            parent.chmod(0o755)
            config = parent / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()

            configure_chart_directory(charts, config_path=config)

            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)

    def test_configure_chart_directory_rejects_symlinked_config_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-opencpn"
            real_parent.mkdir()
            link_parent = root / ".opencpn"
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            charts = root / "charts"
            charts.mkdir()

            with self.assertRaisesRegex(RuntimeError, "symlink"):
                configure_chart_directory(charts, config_path=link_parent / "opencpn.conf")

    def test_configure_chart_directory_rejects_symlinked_config_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config_root = root / "real-config-root"
            real_config_root.mkdir()
            link_config_root = root / ".config"
            try:
                link_config_root.symlink_to(real_config_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            charts = root / "charts"
            charts.mkdir()

            with self.assertRaisesRegex(RuntimeError, "OpenCPN config directory is a symlink"):
                configure_chart_directory(
                    charts,
                    config_path=link_config_root / "opencpn" / "opencpn.conf",
                )

            self.assertFalse((real_config_root / "opencpn" / "opencpn.conf").exists())

    def test_read_chart_directories_rejects_symlinked_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_config = root / "real-opencpn.conf"
            configure_chart_directory(charts, config_path=real_config)
            link_config = root / "opencpn.conf"
            try:
                link_config.symlink_to(real_config)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "OpenCPN config path is a symlink"):
                read_chart_directories(link_config)

    def test_read_chart_directories_rejects_nonregular_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.mkdir()

            with self.assertRaisesRegex(RuntimeError, "OpenCPN config path is not a regular file"):
                read_chart_directories(config)

    def test_read_chart_directories_rejects_writable_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.write_text("[ChartDirectories]\n", encoding="utf-8")
            config.chmod(0o620)

            with self.assertRaisesRegex(RuntimeError, "OpenCPN config path .* has permissions"):
                read_chart_directories(config)

    def test_read_data_connections_rejects_writable_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.write_text(
                "[Settings/NMEADataSource]\n"
                "DataConnections=1;2;127.0.0.1;2947;0;;4800;1;0;0;;0;;0;0;0;0;1;GPSd;0;;0;0;\n",
                encoding="utf-8",
            )
            config.chmod(0o620)

            with self.assertRaisesRegex(RuntimeError, "OpenCPN config path .* has permissions"):
                read_data_connections(config)

    def test_configure_chart_directory_is_idempotent_and_backs_up_existing_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            config.write_text("[Settings]\nShowStatusBar=1\n\n[ChartDirectories]\nChartDir4=/old\n", encoding="utf-8")

            result = configure_chart_directory(charts, config_path=config)
            second = configure_chart_directory(charts, config_path=config)

            self.assertTrue(result.changed)
            self.assertIsNotNone(result.backup_path)
            assert result.backup_path is not None
            self.assertTrue(result.backup_path.exists())
            self.assertFalse(second.changed)
            text = config.read_text(encoding="utf-8")
            self.assertIn("[Settings]\nShowStatusBar=1\n", text)
            self.assertIn("ChartDir4=/old\n", text)
            self.assertIn(f"ChartDir5={charts.resolve()}\n", text)

    def test_opencpn_backup_uses_unique_name_within_same_second(self):
        class FrozenDateTime:
            @classmethod
            def now(cls, tz=None):
                return datetime(2026, 6, 29, 12, 0, 0, tzinfo=timezone.utc)

        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.write_text("original\n", encoding="utf-8")
            original_datetime = opencpn_module.datetime
            try:
                opencpn_module.datetime = FrozenDateTime
                first = opencpn_module._write_backup(config)
                config.write_text("second\n", encoding="utf-8")
                second = opencpn_module._write_backup(config)
            finally:
                opencpn_module.datetime = original_datetime

            self.assertNotEqual(first, second)
            self.assertEqual(first.read_text(encoding="utf-8"), "original\n")
            self.assertEqual(second.read_text(encoding="utf-8"), "second\n")
            self.assertEqual(first.name, "opencpn.conf.noaa-navionics.20260629T120000Z.bak")
            self.assertEqual(second.name, "opencpn.conf.noaa-navionics.20260629T120000Z.1.bak")

    def test_opencpn_backup_is_private_with_permissive_umask(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.write_text("original\n", encoding="utf-8")
            original_umask = os.umask(0)
            try:
                backup = opencpn_module._write_backup(config)
            finally:
                os.umask(original_umask)

            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            self.assertEqual(backup.read_text(encoding="utf-8"), "original\n")

    def test_opencpn_backup_uses_no_follow_private_open(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.write_text("original\n", encoding="utf-8")
            calls = []
            original_open = opencpn_module.os.open

            def capturing_open(path, flags, mode=0o777):
                calls.append((Path(path), flags, mode))
                return original_open(path, flags, mode)

            opencpn_module.os.open = capturing_open
            try:
                backup = opencpn_module._write_backup(config)
            finally:
                opencpn_module.os.open = original_open

            backup_calls = [call for call in calls if call[0] == backup]
            self.assertEqual(len(backup_calls), 1)
            self.assertTrue(backup_calls[0][1] & getattr(os, "O_NOFOLLOW", 0))
            self.assertEqual(backup_calls[0][2], 0o600)
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)

    def test_opencpn_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = opencpn_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        opencpn_module.os.open = fake_open
        try:
            opencpn_module._fsync_directory(Path("/tmp"))
        finally:
            opencpn_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_configure_chart_directory_writes_private_config_with_permissive_umask(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / ".opencpn" / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            original_umask = os.umask(0)
            try:
                configure_chart_directory(charts, config_path=config)
            finally:
                os.umask(original_umask)

            self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_configure_chart_directory_uses_unique_synced_temp_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            config.write_text("[Settings]\nShowStatusBar=1\n", encoding="utf-8")
            fixed_part = root / "opencpn.conf.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")
            calls = []
            original_fsync = opencpn_module.os.fsync
            opencpn_module.os.fsync = lambda fd: calls.append(fd)
            try:
                result = configure_chart_directory(charts, config_path=config)
            finally:
                opencpn_module.os.fsync = original_fsync

            self.assertTrue(result.changed)
            self.assertEqual(fixed_part.read_text(encoding="utf-8"), "other writer\n")
            self.assertFalse(list(root.glob(".opencpn.conf.*.part")))
            self.assertGreaterEqual(len(calls), 3)

    def test_check_opencpn_chart_config_reports_missing_and_configured(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"

            missing = check_opencpn_chart_config(charts, config)
            self.assertFalse(missing.ok)

            charts.mkdir()
            configure_chart_directory(charts, config_path=config)
            configured = check_opencpn_chart_config(charts, config)
            self.assertTrue(configured.ok)

    def test_check_opencpn_chart_config_rejects_missing_configured_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "missing-charts"
            config.write_text(f"[ChartDirectories]\nChartDir1={charts}\n", encoding="utf-8")

            configured = check_opencpn_chart_config(charts, config)

            self.assertFalse(configured.ok)
            self.assertIn("chart directory does not exist", configured.detail)

    def test_configure_gpsd_connection_creates_nmea_data_source(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"

            result = configure_gpsd_connection(config_path=config, host="127.0.0.1", port=2947)

            self.assertTrue(result.changed)
            self.assertTrue(gpsd_connection_configured(config_path=config, host="localhost", port=2947))
            connections = read_data_connections(config)
            self.assertEqual(len(connections), 1)
            self.assertEqual(
                connections[0],
                "1;2;127.0.0.1;2947;0;;4800;1;0;0;;0;;0;0;0;0;1;"
                "GPSd: 127.0.0.1 TCP port 2947;0;;0;0;",
            )

    def test_configure_gpsd_connection_is_idempotent_and_preserves_existing_connections(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            existing = "1;0;192.0.2.10;10110;0;;4800;1;0;0;;0;;0;0;0;0;1;AIS;0;;0;0;"
            config.write_text(
                "[Settings/NMEADataSource]\n"
                f"DataConnections={existing}\n",
                encoding="utf-8",
            )

            first = configure_gpsd_connection(config_path=config, host="127.0.0.1", port=2947)
            second = configure_gpsd_connection(config_path=config, host="localhost", port=2947)

            self.assertTrue(first.changed)
            self.assertFalse(second.changed)
            connections = read_data_connections(config)
            self.assertEqual(connections[0], existing)
            self.assertEqual(len(connections), 2)

    def test_configure_gpsd_connection_removes_stale_enabled_gpsd_sources(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"

            configure_gpsd_connection(config_path=config, host="192.0.2.20", port=2947)
            result = configure_gpsd_connection(config_path=config, host="127.0.0.1", port=2947)

            self.assertTrue(result.changed)
            self.assertTrue(gpsd_connection_configured(config_path=config, host="localhost", port=2947))
            connections = read_data_connections(config)
            self.assertEqual(len(connections), 1)
            self.assertIn("127.0.0.1;2947", connections[0])
            self.assertNotIn("192.0.2.20", connections[0])

    def test_configure_gpsd_connection_uses_unique_synced_temp_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            fixed_part = root / "opencpn.conf.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")
            calls = []
            original_fsync = opencpn_module.os.fsync
            opencpn_module.os.fsync = lambda fd: calls.append(fd)
            try:
                result = configure_gpsd_connection(config_path=config)
            finally:
                opencpn_module.os.fsync = original_fsync

            self.assertTrue(result.changed)
            self.assertEqual(fixed_part.read_text(encoding="utf-8"), "other writer\n")
            self.assertFalse(list(root.glob(".opencpn.conf.*.part")))
            self.assertGreaterEqual(len(calls), 2)

    def test_process_state_from_stat_text(self):
        self.assertEqual(opencpn_module._process_state_from_stat_text("123 (opencpn) S 1 2 3"), "S")
        self.assertEqual(opencpn_module._process_state_from_stat_text("123 (opencpn) Z 1 2 3"), "Z")
        self.assertEqual(opencpn_module._process_state_from_stat_text("malformed"), "")

    def test_check_opencpn_gpsd_config_reports_missing_and_configured(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"

            missing = check_opencpn_gpsd_config(config_path=config)
            self.assertFalse(missing.ok)

            configure_gpsd_connection(config_path=config)
            configured = check_opencpn_gpsd_config(config_path=config)
            self.assertTrue(configured.ok)

    def test_check_opencpn_gpsd_config_rejects_extra_enabled_gpsd_source(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            expected = opencpn_module._gpsd_connection_string("127.0.0.1", 2947)
            stale = opencpn_module._gpsd_connection_string("192.0.2.20", 2947)
            config.write_text(
                "[Settings/NMEADataSource]\n"
                f"DataConnections={expected}|{stale}\n",
                encoding="utf-8",
            )

            result = check_opencpn_gpsd_config(config_path=config, host="127.0.0.1", port=2947)

            self.assertFalse(result.ok)
            self.assertIn("unexpected enabled GPSD connection", result.detail)
            self.assertIn("192.0.2.20:2947", result.detail)

    def test_cli_configure_opencpn_skips_gpsd_for_serial_mode(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            opencpn_config = root / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            app_config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {charts}\n"
                "\n"
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )

            original = cli_module.opencpn_running
            try:
                cli_module.opencpn_running = lambda: False
                with redirect_stdout(StringIO()) as output:
                    code = cli_module.main(
                        [
                            "configure-opencpn",
                            "--config",
                            str(app_config),
                            "--opencpn-config",
                            str(opencpn_config),
                            "--dry-run",
                        ]
                    )
            finally:
                cli_module.opencpn_running = original

            self.assertEqual(code, 0)
            self.assertIn("GPSD skipped: gps.mode=serial", output.getvalue())
            self.assertNotIn("Added GPSD", output.getvalue())

    def test_cli_configure_opencpn_adds_gpsd_for_gpsd_mode(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            opencpn_config = root / "opencpn.conf"
            charts = root / "charts"
            charts.mkdir()
            app_config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {charts}\n"
                "\n"
                "[gps]\n"
                "mode = gpsd\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n",
                encoding="utf-8",
            )

            original = cli_module.opencpn_running
            try:
                cli_module.opencpn_running = lambda: False
                with redirect_stdout(StringIO()) as output:
                    code = cli_module.main(
                        [
                            "configure-opencpn",
                            "--config",
                            str(app_config),
                            "--opencpn-config",
                            str(opencpn_config),
                            "--dry-run",
                        ]
                    )
            finally:
                cli_module.opencpn_running = original

            self.assertEqual(code, 0)
            self.assertIn("Would add GPSD: 127.0.0.1:2947", output.getvalue())

    def test_cli_log_track_uses_configured_output_and_gpsd_when_omitted(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            chart_output = root / "charts"
            track_output = root / "configured-tracks"
            app_config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {chart_output}\n"
                "\n"
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n"
                "retention_days = 14\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=1.0,
                longitude=2.0,
                satellites=8,
                hdop=1.2,
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
            ):
                calls.append((device, baud, sample, gpsd, gpsd_host, gpsd_port, gpsd_connect_retry))
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                stderr = StringIO()
                with redirect_stdout(StringIO()), redirect_stderr(stderr):
                    code = cli_module.main(["log-track", "--config", str(app_config), "--rotate-daily"])
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertEqual(calls, [("/dev/serial/by-id/mock-gps", 4800, None, True, "127.0.0.1", 2947, True)])
            expected_name = f"track-{fix.timestamp.strftime('%Y%m%d')}.gpx"
            self.assertTrue((track_output / "tracks" / expected_name).exists())
            self.assertIn("Live GPS stream ended unexpectedly", stderr.getvalue())

    def test_cli_log_track_timed_run_allows_finite_stream_after_fix(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            track_output = root / "configured-tracks"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=1.0,
                longitude=2.0,
                satellites=8,
                hdop=1.2,
            )
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
            ):
                self.assertIsNotNone(deadline)
                self.assertFalse(gpsd_connect_retry)
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    code = cli_module.main(
                        ["log-track", "--config", str(app_config), "--rotate-daily", "--seconds", "0.1"]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            expected_name = f"track-{fix.timestamp.strftime('%Y%m%d')}.gpx"
            self.assertTrue((track_output / "tracks" / expected_name).exists())

    def test_cli_log_track_explicit_device_and_output_override_config(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            configured_output = root / "configured-tracks"
            explicit_output = root / "explicit-tracks"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "\n"
                "[tracking]\n"
                f"output = {configured_output}\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime.now(timezone.utc),
                latitude=1.0,
                longitude=2.0,
                satellites=8,
                hdop=1.2,
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
            ):
                calls.append((device, baud, sample, gpsd, gpsd_connect_retry))
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    code = cli_module.main(
                        [
                            "log-track",
                            "--config",
                            str(app_config),
                            "--device",
                            "/dev/serial/by-id/override-gps",
                            "--baud",
                            "9600",
                            "--output",
                            str(explicit_output),
                            "--rotate-daily",
                            "--seconds",
                            "0.1",
                        ]
                    )
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            self.assertEqual(calls, [("/dev/serial/by-id/override-gps", 9600, None, False, False)])
            self.assertFalse(configured_output.exists())
            expected_name = f"track-{fix.timestamp.strftime('%Y%m%d')}.gpx"
            self.assertTrue((explicit_output / "tracks" / expected_name).exists())

    def test_cli_log_track_rejects_volatile_explicit_serial_device(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "\n"
                "[tracking]\n"
                f"output = {root / 'tracks'}\n",
                encoding="utf-8",
            )

            stderr = StringIO()
            with redirect_stdout(StringIO()), redirect_stderr(stderr):
                code = cli_module.main(
                    [
                        "log-track",
                        "--config",
                        str(app_config),
                        "--device",
                        "/dev/ttyUSB0",
                        "--seconds",
                        "0.1",
                    ]
                )

            self.assertEqual(code, 2)
            self.assertIn("volatile USB name", stderr.getvalue())

    def test_cli_gps_monitor_seconds_bounds_gpsd_wait(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "gpsd_host = 127.0.0.1\n"
                "gpsd_port = 2947\n",
                encoding="utf-8",
            )
            fix = GPSFix(
                timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
                latitude=1.0,
                longitude=2.0,
                satellites=8,
                hdop=1.2,
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
            ):
                calls.append((device, baud, sample, gpsd, gpsd_host, gpsd_port, deadline, gpsd_connect_retry))
                return iter([fix])

            try:
                cli_module._read_fixes = fake_read_fixes
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    code = cli_module.main(["gps-monitor", "--config", str(app_config), "--once", "--seconds", "0.1"])
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 0)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][:6], ("/dev/serial/by-id/mock-gps", 4800, None, True, "127.0.0.1", 2947))
            self.assertIsNotNone(calls[0][6])
            self.assertFalse(calls[0][7])

    def test_cli_gps_monitor_seconds_returns_nonzero_without_fix(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n",
                encoding="utf-8",
            )
            calls = []
            original = cli_module._read_fixes

            def fake_read_fixes(
                device,
                baud,
                sample,
                *,
                gpsd=False,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                deadline=None,
                gpsd_connect_retry=False,
            ):
                calls.append((device, baud, sample, gpsd, deadline))
                return iter([])

            try:
                cli_module._read_fixes = fake_read_fixes
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    code = cli_module.main(["gps-monitor", "--config", str(app_config), "--once", "--seconds", "0.1"])
            finally:
                cli_module._read_fixes = original

            self.assertEqual(code, 1)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][:4], ("/dev/serial/by-id/mock-gps", 4800, None, False))
            self.assertIsNotNone(calls[0][4])

    def test_cli_gps_monitor_rejects_volatile_explicit_serial_device(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            app_config.write_text(
                "[gps]\n"
                "mode = gpsd\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n",
                encoding="utf-8",
            )

            stderr = StringIO()
            with redirect_stdout(StringIO()), redirect_stderr(stderr):
                code = cli_module.main(
                    [
                        "gps-monitor",
                        "--config",
                        str(app_config),
                        "--device",
                        "/dev/ttyACM0",
                        "--seconds",
                        "0.1",
                    ]
                )

            self.assertEqual(code, 2)
            self.assertIn("volatile USB name", stderr.getvalue())

    def test_cli_log_track_seconds_fails_when_no_usable_fix_is_written(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            track_output = root / "tracks-out"
            app_config.write_text(
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n"
                "baud = 4800\n"
                "\n"
                "[tracking]\n"
                f"output = {track_output}\n",
                encoding="utf-8",
            )
            original = cli_module.open_nmea_stream

            def fake_open_nmea_stream(device, baud=4800):
                return BytesIO(b"")

            try:
                cli_module.open_nmea_stream = fake_open_nmea_stream
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    code = cli_module.main(
                        [
                            "log-track",
                            "--config",
                            str(app_config),
                            "--seconds",
                            "0.01",
                        ]
                    )
            finally:
                cli_module.open_nmea_stream = original

            self.assertEqual(code, 1)
            self.assertIn("Saved 0 fixes", stdout.getvalue())
            self.assertIn("No usable GPS fixes", stderr.getvalue())
            self.assertFalse(track_output.exists())

    def test_read_fixes_retries_initial_gpsd_connection_for_live_logger(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        calls = []
        sleeps = []
        original_iter = cli_module.iter_gpsd_fixes
        original_sleep = cli_module.time.sleep

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            calls.append((host, port, timeout, max_duration))
            if len(calls) == 1:
                raise OSError("connection refused")
            return iter([fix])

        try:
            cli_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            cli_module.time.sleep = lambda seconds: sleeps.append(seconds)
            stderr = StringIO()
            with redirect_stderr(stderr):
                fixes = list(
                    cli_module._read_fixes(
                        "/dev/serial/by-id/mock-gps",
                        4800,
                        None,
                        gpsd=True,
                        gpsd_connect_retry=True,
                        gpsd_retry_delay=0.1,
                    )
                )
        finally:
            cli_module.iter_gpsd_fixes = original_iter
            cli_module.time.sleep = original_sleep

        self.assertEqual(fixes, [fix])
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [0.1])
        self.assertIn("GPSD unavailable at 127.0.0.1:2947", stderr.getvalue())

    def test_read_fixes_does_not_retry_gpsd_failure_after_fix(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        calls = []
        sleeps = []
        original_iter = cli_module.iter_gpsd_fixes
        original_sleep = cli_module.time.sleep

        def failing_stream():
            yield fix
            raise OSError("gpsd stream reset")

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            calls.append((host, port, timeout, max_duration))
            return failing_stream()

        try:
            cli_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            cli_module.time.sleep = lambda seconds: sleeps.append(seconds)
            fixes = cli_module._read_fixes(
                "/dev/serial/by-id/mock-gps",
                4800,
                None,
                gpsd=True,
                gpsd_connect_retry=True,
                gpsd_retry_delay=0.1,
            )
            self.assertEqual(next(fixes), fix)
            with self.assertRaisesRegex(OSError, "gpsd stream reset"):
                next(fixes)
        finally:
            cli_module.iter_gpsd_fixes = original_iter
            cli_module.time.sleep = original_sleep

        self.assertEqual(len(calls), 1)
        self.assertEqual(sleeps, [])


class GuiTests(unittest.TestCase):
    def test_gui_package_options_are_complete_onboard_chart_sources(self):
        self.assertEqual(set(gui_module.PACKAGE_KIND_OPTIONS), config_module.CHART_PACKAGES)
        self.assertNotIn("updates", gui_module.PACKAGE_KIND_OPTIONS)
        self.assertNotIn("catalog", gui_module.PACKAGE_KIND_OPTIONS)

    def test_configured_preflight_uses_onboard_config_values(self):
        app_config = AppConfig(
            chart_package="state",
            chart_value="AK",
            chart_output=Path("/charts/noaa"),
            extract=True,
            keep_zip=True,
            force=True,
            max_chart_age_days=12,
            min_free_gb=4.5,
            gps_mode="gpsd",
            gps_device="/dev/serial/by-id/mock-gps",
            gps_baud=9600,
            gpsd_host="192.0.2.10",
            gpsd_port=2948,
            track_output=Path("/tracks/noaa"),
            track_retention_days=30,
        )
        calls = []
        original = gui_module.run_preflight

        def fake_run_preflight(**kwargs):
            calls.append(kwargs)
            return [health_module.CheckResult("Test", True, "ok")]

        try:
            gui_module.run_preflight = fake_run_preflight
            results = gui_module.run_configured_preflight(app_config)
        finally:
            gui_module.run_preflight = original

        self.assertEqual(results, [health_module.CheckResult("Test", True, "ok")])
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["chart_dir"], Path("/charts/noaa"))
        self.assertEqual(calls[0]["chart_package"], "state")
        self.assertEqual(calls[0]["chart_value"], "AK")
        self.assertEqual(calls[0]["gpsd"], True)
        self.assertEqual(calls[0]["gpsd_host"], "192.0.2.10")
        self.assertEqual(calls[0]["gpsd_port"], 2948)
        self.assertEqual(calls[0]["gps_device"], "/dev/serial/by-id/mock-gps")
        self.assertEqual(calls[0]["gps_baud"], 9600)
        self.assertEqual(calls[0]["gps_seconds"], 10.0)
        self.assertEqual(calls[0]["max_chart_age_days"], 12)
        self.assertEqual(calls[0]["min_free_gb"], 4.5)
        self.assertEqual(calls[0]["keep_zip"], True)
        self.assertEqual(calls[0]["track_output"], Path("/tracks/noaa"))

    def test_configured_gui_sync_rejects_incomplete_onboard_chart_packages(self):
        calls = []
        original = gui_module.download_package

        def fake_download_package(*args, **kwargs):
            calls.append((args, kwargs))
            raise AssertionError("download_package should not be called")

        try:
            gui_module.download_package = fake_download_package
            for package, value, expected in [
                ("updates", "ten-days", "not a complete chart set"),
                ("catalog", "", "metadata only"),
            ]:
                with self.subTest(package=package):
                    app_config = AppConfig(
                        chart_package=package,
                        chart_value=value,
                        chart_output=Path("/charts/noaa"),
                        extract=True,
                        keep_zip=True,
                        force=True,
                        max_chart_age_days=12,
                        min_free_gb=2.0,
                        gps_mode="gpsd",
                        gps_device="/dev/serial/by-id/mock-gps",
                        gps_baud=9600,
                        gpsd_host="127.0.0.1",
                        gpsd_port=2947,
                        track_output=Path("/tracks/noaa"),
                        track_retention_days=90,
                    )

                    with self.assertRaisesRegex(ValueError, expected):
                        gui_module.sync_configured_charts(app_config)
        finally:
            gui_module.download_package = original

        self.assertEqual(calls, [])

    def test_configured_gui_sync_rejects_low_disk_before_download(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            app_config = AppConfig(
                chart_package="state",
                chart_value="AK",
                chart_output=Path(tmpdir) / "charts" / "noaa",
                extract=True,
                keep_zip=True,
                force=True,
                max_chart_age_days=12,
                min_free_gb=2.0,
                gps_mode="gpsd",
                gps_device="/dev/serial/by-id/mock-gps",
                gps_baud=9600,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                track_output=Path("/tracks/noaa"),
                track_retention_days=90,
            )
            calls = []
            original_download = gui_module.download_package
            original_disk_check = gui_module.check_disk_space

            def fake_download_package(*args, **kwargs):
                calls.append((args, kwargs))
                raise AssertionError("download_package should not be called")

            try:
                gui_module.download_package = fake_download_package
                gui_module.check_disk_space = lambda *args, **kwargs: health_module.CheckResult(
                    "Disk",
                    False,
                    "0.1 GB free at /charts; minimum 2.0 GB",
                )

                with self.assertRaisesRegex(RuntimeError, "enough free space"):
                    gui_module.sync_configured_charts(app_config)
            finally:
                gui_module.download_package = original_download
                gui_module.check_disk_space = original_disk_check

            self.assertEqual(calls, [])

    def test_configured_gui_sync_rejects_missing_storage_before_creating_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            chart_output = root / "missing-storage" / "charts"
            app_config = AppConfig(
                chart_package="state",
                chart_value="AK",
                chart_output=chart_output,
                extract=True,
                keep_zip=True,
                force=True,
                max_chart_age_days=12,
                min_free_gb=0.1,
                gps_mode="gpsd",
                gps_device="/dev/serial/by-id/mock-gps",
                gps_baud=9600,
                gpsd_host="127.0.0.1",
                gpsd_port=2947,
                track_output=Path("/tracks/noaa"),
                track_retention_days=90,
            )
            calls = []
            original_download = gui_module.download_package

            def fake_download_package(*args, **kwargs):
                calls.append((args, kwargs))
                raise AssertionError("download_package should not be called")

            try:
                gui_module.download_package = fake_download_package

                with self.assertRaisesRegex(RuntimeError, "create or mount the configured storage path"):
                    gui_module.sync_configured_charts(app_config)
            finally:
                gui_module.download_package = original_download

            self.assertFalse(chart_output.exists())
            self.assertEqual(calls, [])


class CLIValidationTests(unittest.TestCase):
    def assert_parse_error(self, args):
        parser = cli_module.build_parser()
        with redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit) as raised:
                parser.parse_args(args)
        self.assertEqual(raised.exception.code, 2)

    def test_download_rejects_invalid_timing_values(self):
        self.assert_parse_error(["download", "--state", "AK", "--timeout", "0"])
        self.assert_parse_error(["download", "--state", "AK", "--timeout", "nan"])
        self.assert_parse_error(["download", "--state", "AK", "--retries", "0"])
        self.assert_parse_error(["download", "--state", "AK", "--retry-delay", "inf"])
        self.assert_parse_error(["download", "--state", "AK", "--retry-delay", "-1"])

    def test_sync_rejects_invalid_retry_values(self):
        self.assert_parse_error(["sync-charts", "--retries", "0"])
        self.assert_parse_error(["sync-charts", "--retry-delay", "-1"])

    def test_wait_network_rejects_invalid_values(self):
        self.assert_parse_error(["wait-network", "--port", "0"])
        self.assert_parse_error(["wait-network", "--seconds", "-1"])
        self.assert_parse_error(["wait-network", "--interval", "0"])
        self.assert_parse_error(["wait-network", "--timeout", "nan"])

    def test_wait_network_uses_bounded_tcp_probe(self):
        calls = []

        class FakeConnection:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, traceback):
                return False

        original = cli_module.socket.create_connection
        try:
            cli_module.socket.create_connection = lambda address, timeout: calls.append((address, timeout)) or FakeConnection()
            with redirect_stdout(StringIO()) as output:
                code = cli_module.main(
                    [
                        "wait-network",
                        "--host",
                        "example.invalid",
                        "--port",
                        "443",
                        "--seconds",
                        "0",
                        "--timeout",
                        "1",
                    ]
                )
        finally:
            cli_module.socket.create_connection = original

        self.assertEqual(code, 0)
        self.assertEqual(calls, [(("example.invalid", 443), 1.0)])
        self.assertIn("Network reachable: example.invalid:443", output.getvalue())

    def test_sync_rejects_incomplete_onboard_chart_packages(self):
        cases = [
            ("updates", "ten-days"),
            ("catalog", ""),
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            for index, (package, value) in enumerate(cases):
                with self.subTest(package=package):
                    config = root / f"config-{index}.ini"
                    config.write_text(
                        "[charts]\n"
                        f"package = {package}\n"
                        f"value = {value}\n"
                        f"output = {root / 'charts'}\n",
                        encoding="utf-8",
                    )

                    stderr = StringIO()
                    with redirect_stderr(stderr):
                        code = cli_module.main(["sync-charts", "--config", str(config)])

                    self.assertEqual(code, 2)
                    self.assertIn("charts.package must be one of: state, cgd, region, chart, all", stderr.getvalue())

    def test_sync_rejects_low_disk_before_download(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config = root / "config.ini"
            config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {root / 'charts'}\n"
                "min_free_gb = 2.0\n",
                encoding="utf-8",
            )
            calls = []
            original_download = cli_module.download_package
            original_disk_check = cli_module.check_disk_space

            def fake_download_package(*args, **kwargs):
                calls.append((args, kwargs))
                raise AssertionError("download_package should not be called")

            try:
                cli_module.download_package = fake_download_package
                cli_module.check_disk_space = lambda *args, **kwargs: health_module.CheckResult(
                    "Disk",
                    False,
                    "0.1 GB free at chart storage; minimum 2.0 GB",
                )
                stderr = StringIO()
                with redirect_stderr(stderr):
                    code = cli_module.main(["sync-charts", "--config", str(config)])
            finally:
                cli_module.download_package = original_download
                cli_module.check_disk_space = original_disk_check

            self.assertEqual(code, 2)
            self.assertIn("enough free space", stderr.getvalue())
            self.assertEqual(calls, [])

    def test_sync_rejects_missing_chart_storage_before_creating_directory(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            chart_output = root / "missing-storage" / "charts"
            config = root / "config.ini"
            config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {chart_output}\n"
                "min_free_gb = 0.1\n",
                encoding="utf-8",
            )
            calls = []
            original_download = cli_module.download_package

            def fake_download_package(*args, **kwargs):
                calls.append((args, kwargs))
                raise AssertionError("download_package should not be called")

            try:
                cli_module.download_package = fake_download_package
                stderr = StringIO()
                with redirect_stderr(stderr):
                    code = cli_module.main(["sync-charts", "--config", str(config)])
            finally:
                cli_module.download_package = original_download

            self.assertEqual(code, 2)
            self.assertIn("create or mount the configured storage path", stderr.getvalue())
            self.assertFalse(chart_output.exists())
            self.assertEqual(calls, [])

    def test_preflight_explicit_default_chart_path_overrides_config(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            config = root / "config.ini"
            configured_charts = root / "configured-charts"
            config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {configured_charts}\n"
                "\n"
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/serial/by-id/mock-gps\n",
                encoding="utf-8",
            )
            calls = []
            original = cli_module.run_preflight

            def fake_run_preflight(**kwargs):
                calls.append(kwargs)
                return [health_module.CheckResult("Test", True, "ok")]

            try:
                cli_module.run_preflight = fake_run_preflight
                with redirect_stdout(StringIO()):
                    code = cli_module.main(
                        [
                            "preflight",
                            "--config",
                            str(config),
                            "--charts",
                            "~/charts/noaa-enc",
                        ]
                    )
            finally:
                cli_module.run_preflight = original

            self.assertEqual(code, 0)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0]["chart_dir"], Path("~/charts/noaa-enc").expanduser())
            self.assertNotEqual(calls[0]["chart_dir"], configured_charts)

    def test_gps_waits_reject_negative_seconds(self):
        self.assert_parse_error(["preflight", "--gps-seconds", "-1"])
        self.assert_parse_error(["status-report", "--gps-seconds", "-1"])
        self.assert_parse_error(["gps-monitor", "--seconds", "-1"])

    def test_track_logger_rejects_non_positive_duration(self):
        self.assert_parse_error(["log-track", "--seconds", "0"])

    def test_track_logger_rejects_negative_retention_days(self):
        self.assert_parse_error(["log-track", "--retention-days", "-1"])


class ManifestTests(unittest.TestCase):
    class FakeResponse:
        def __init__(self, payload, content_length: str = "5", url: str = ""):
            self.headers = {"Content-Length": content_length}
            self.payload = BytesIO(payload)
            self.url = url

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return None

        def read(self, size=-1):
            return self.payload.read(size)

        def geturl(self):
            return self.url

    def test_download_writes_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("Test package", source_zip.as_uri(), "AK_ENCs.zip")

            result = download_package(package, output, extract=True)

            self.assertTrue(result.sha256)
            self.assertTrue((output / MANIFEST_NAME).exists())
            manifest = read_manifest(output)
            self.assertEqual(manifest["package"]["label"], "Test package")
            self.assertEqual(manifest["package"]["url"], source_zip.as_uri())
            self.assertEqual(manifest["created_at_source"], "download")
            self.assertEqual(manifest["download"]["url"], source_zip.as_uri())
            self.assertEqual(manifest["download"]["sha256"], result.sha256)
            self.assertEqual(manifest["extract"]["enc_cell_count"], 1)
            self.assertTrue(check_chart_manifest(output).ok)

    def test_download_tightens_chart_output_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            output.mkdir()
            os.chmod(output, 0o777)
            package = Package("Test package", source_zip.as_uri(), "AK_ENCs.zip")

            download_package(package, output, extract=True)

            self.assertEqual(output.stat().st_mode & 0o777, 0o700)

    def test_forced_download_rejects_bad_zip_before_replacing_archive(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            good_zip = root / "good.zip"
            with zipfile.ZipFile(good_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", good_zip.as_uri(), "AK_ENCs.zip")
            first = download_package(package, output, extract=True, keep_zip=True, force=True)
            archive_path = output / "AK_ENCs.zip"
            original_archive_bytes = archive_path.read_bytes()
            original_manifest = read_manifest(output)
            bad_zip = root / "bad.zip"
            bad_zip.write_bytes(b"not a zip")
            bad_package = Package("State AK", bad_zip.as_uri(), "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "downloaded ZIP is not a valid archive"):
                download_package(bad_package, output, extract=True, keep_zip=True, force=True)

            self.assertEqual(archive_path.read_bytes(), original_archive_bytes)
            self.assertEqual(read_manifest(output), original_manifest)
            self.assertTrue((output / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000").exists())
            self.assertFalse((output / "AK_ENCs.zip.part").exists())
            self.assertTrue(first.sha256)

    def test_forced_download_rejects_unsafe_zip_before_replacing_archive(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            good_zip = root / "good.zip"
            with zipfile.ZipFile(good_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", good_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)
            archive_path = output / "AK_ENCs.zip"
            original_archive_bytes = archive_path.read_bytes()
            original_manifest = read_manifest(output)
            unsafe_zip = root / "unsafe.zip"
            with zipfile.ZipFile(unsafe_zip, "w") as archive:
                archive.writestr("../evil.000", "bad")
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            unsafe_package = Package("State AK", unsafe_zip.as_uri(), "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "downloaded ZIP has unsafe member path"):
                download_package(unsafe_package, output, extract=True, keep_zip=True, force=True)

            self.assertEqual(archive_path.read_bytes(), original_archive_bytes)
            self.assertEqual(read_manifest(output), original_manifest)
            self.assertEqual((output / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000").read_text(encoding="ascii"), "cell")
            self.assertFalse((output / "AK_ENCs.zip.part").exists())
            self.assertFalse((root / "evil.000").exists())

    def test_forced_download_rejects_zip_without_enc_cells_before_replacing_archive(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            good_zip = root / "good.zip"
            with zipfile.ZipFile(good_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", good_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)
            archive_path = output / "AK_ENCs.zip"
            original_archive_bytes = archive_path.read_bytes()
            original_manifest = read_manifest(output)
            empty_zip = root / "empty.zip"
            with zipfile.ZipFile(empty_zip, "w") as archive:
                archive.writestr("README.txt", "not chart data")
            empty_package = Package("State AK", empty_zip.as_uri(), "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "downloaded ZIP contains no ENC"):
                download_package(empty_package, output, extract=True, keep_zip=True, force=True)

            self.assertEqual(archive_path.read_bytes(), original_archive_bytes)
            self.assertEqual(read_manifest(output), original_manifest)
            self.assertTrue((output / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000").exists())
            self.assertFalse((output / "AK_ENCs.zip.part").exists())

    def test_download_manifest_records_final_response_url(self):
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            self.assertEqual(request.full_url, "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip")
            return self.FakeResponse(
                b"chart",
                url="https://downloads.charts.noaa.gov/cache/AK_ENCs.zip",
            )

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("State AK", "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", "AK_ENCs.zip")

                result = download_package(package, output)

                manifest = read_manifest(output)
                self.assertEqual(result.url, "https://downloads.charts.noaa.gov/cache/AK_ENCs.zip")
                self.assertEqual(manifest["package"]["url"], package.url)
                self.assertEqual(manifest["download"]["url"], result.url)
        finally:
            downloader_module.urlopen = original

    def test_download_rejects_http_redirect_before_writing_archive(self):
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(
                b"chart",
                url="http://downloads.charts.noaa.gov/cache/AK_ENCs.zip",
            )

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("State AK", "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", "AK_ENCs.zip")

                with self.assertRaisesRegex(RuntimeError, "non-HTTPS redirect"):
                    download_package(package, output)

                self.assertFalse((output / "AK_ENCs.zip").exists())
                self.assertFalse((output / MANIFEST_NAME).exists())
        finally:
            downloader_module.urlopen = original

    def test_download_rejects_redirect_to_wrong_filename_before_writing_archive(self):
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(
                b"chart",
                url="https://downloads.charts.noaa.gov/cache/CA_ENCs.zip",
            )

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("State AK", "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", "AK_ENCs.zip")

                with self.assertRaisesRegex(RuntimeError, "does not match package filename"):
                    download_package(package, output)

                self.assertFalse((output / "AK_ENCs.zip").exists())
                self.assertFalse((output / MANIFEST_NAME).exists())
        finally:
            downloader_module.urlopen = original

    def test_existing_zip_extract_respects_no_keep_zip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            existing = output / "AK_ENCs.zip"
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)

            result = download_package(package, output, extract=True, keep_zip=False)

            self.assertTrue(result.skipped)
            self.assertFalse(existing.exists())
            self.assertTrue((output / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000").exists())
            manifest = read_manifest(output)
            self.assertEqual(manifest["download"]["bytes"], result.bytes_written)
            self.assertEqual(manifest["created_at_source"], "previous-manifest")
            self.assertEqual(manifest["extract"]["enc_cell_count"], 1)

    def test_existing_zip_no_keep_zip_rejects_symlink_swapped_before_removal(self):
        original_extract_zip = downloader_module.extract_zip
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            archive_path = output / "AK_ENCs.zip"
            target = root / "target.zip"
            target.write_text("do not remove\n", encoding="utf-8")
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)

            def replacing_extract(zip_path, destination):
                extracted_to = original_extract_zip(zip_path, destination)
                archive_path.unlink()
                try:
                    archive_path.symlink_to(target)
                except OSError as exc:
                    self.skipTest(f"symlinks unavailable: {exc}")
                return extracted_to

            try:
                downloader_module.extract_zip = replacing_extract
                with self.assertRaisesRegex(RuntimeError, "chart archive path is a symlink before removal"):
                    download_package(package, output, extract=True, keep_zip=False)
            finally:
                downloader_module.extract_zip = original_extract_zip

            self.assertTrue(archive_path.is_symlink())
            self.assertEqual(target.read_text(encoding="utf-8"), "do not remove\n")

    def test_existing_zip_without_previous_manifest_fails_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            existing = output / "AK_ENCs.zip"
            with zipfile.ZipFile(existing, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            package = Package("State AK", "https://example.invalid/AK_ENCs.zip", "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "prior verified manifest"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs").exists())
            self.assertFalse((output / MANIFEST_NAME).exists())

    def test_existing_zip_symlink_fails_before_reading_cache(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / "charts"
            output.mkdir()
            real_archive = root / "real.zip"
            with zipfile.ZipFile(real_archive, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            archive_link = output / "AK_ENCs.zip"
            try:
                archive_link.symlink_to(real_archive)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            package = Package("State AK", real_archive.as_uri(), "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "chart archive path is a symlink"):
                download_package(package, output, extract=True)

            self.assertTrue(archive_link.is_symlink())
            self.assertFalse((output / "AK_ENCs").exists())

    def test_existing_zip_nonregular_path_fails_before_reading_cache(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            existing = output / "AK_ENCs.zip"
            existing.mkdir()
            package = Package("State AK", "https://example.invalid/AK_ENCs.zip", "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "chart download path is not a regular file"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs").exists())

    def test_existing_zip_writable_file_fails_before_reading_cache(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            existing = output / "AK_ENCs.zip"
            with zipfile.ZipFile(existing, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            existing.chmod(0o622)
            package = Package("State AK", "https://example.invalid/AK_ENCs.zip", "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "chart download path .* has permissions 0622"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs").exists())

    def test_hash_existing_download_path_rejects_writable_zip_before_hashing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            existing = Path(tmpdir) / "AK_ENCs.zip"
            with zipfile.ZipFile(existing, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            existing.chmod(0o622)

            with self.assertRaisesRegex(RuntimeError, "chart download path .* has permissions 0622"):
                downloader_module._hash_existing_download_path(existing)

    def test_download_rejects_symlinked_output_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_storage = root / "real-storage"
            real_storage.mkdir()
            storage_link = root / "storage-link"
            try:
                storage_link.symlink_to(real_storage, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            output = storage_link / "charts"
            package = Package("State AK", "https://example.invalid/AK_ENCs.zip", "AK_ENCs.zip")

            with self.assertRaisesRegex(RuntimeError, "chart output path contains a symlink"):
                download_package(package, output)

            self.assertFalse((real_storage / "charts").exists())

    def test_existing_zip_mismatched_previous_manifest_fails_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            first_zip = root / "first.zip"
            with zipfile.ZipFile(first_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", first_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)
            existing = output / "AK_ENCs.zip"
            with zipfile.ZipFile(existing, "w") as archive:
                archive.writestr("US5AK4CM/US5AK4CM.000", "different cell")

            with self.assertRaisesRegex(RuntimeError, "prior verified manifest"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs" / "US5AK4CM").exists())

    def test_existing_zip_unverified_previous_manifest_fails_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=True, keep_zip=True, force=True)
            manifest = read_manifest(output)
            manifest["created_at_source"] = "unverified-cache"
            (output / MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "prior verified manifest"):
                download_package(package, output, extract=True)

            self.assertEqual(read_manifest(output)["created_at_source"], "unverified-cache")

    def test_existing_zip_symlinked_previous_manifest_fails_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=False, keep_zip=True, force=True)
            real_manifest = root / "real-manifest.json"
            real_manifest.write_text((output / MANIFEST_NAME).read_text(encoding="utf-8"), encoding="utf-8")
            (output / MANIFEST_NAME).unlink()
            try:
                (output / MANIFEST_NAME).symlink_to(real_manifest)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "previous chart manifest path is a symlink"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs").exists())

    def test_existing_zip_writable_previous_manifest_fails_before_extracting(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            download_package(package, output, extract=False, keep_zip=True, force=True)
            (output / MANIFEST_NAME).chmod(0o622)

            with self.assertRaisesRegex(RuntimeError, "previous chart manifest path .* has permissions 0622"):
                download_package(package, output, extract=True)

            self.assertFalse((output / "AK_ENCs").exists())

    def test_existing_zip_preserves_previous_manifest_timestamp(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source_zip = root / "source.zip"
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            output = root / "charts"
            package = Package("State AK", source_zip.as_uri(), "AK_ENCs.zip")
            first = download_package(package, output, extract=True, force=True)
            old_created_at = "2000-01-01T00:00:00Z"
            manifest = read_manifest(output)
            manifest["created_at"] = old_created_at
            (output / MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")

            second = download_package(package, output, extract=True, force=False)

            self.assertTrue(second.skipped)
            self.assertEqual(second.sha256, first.sha256)
            updated_manifest = read_manifest(output)
            self.assertEqual(updated_manifest["created_at"], old_created_at)
            self.assertEqual(updated_manifest["created_at_source"], "previous-manifest")
            check = check_chart_manifest(output, max_age_days=1)
            self.assertFalse(check.ok)
            self.assertIn("days old", check.detail)

    def test_existing_zip_preserves_previous_manifest_download_url(self):
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(
                b"chart",
                url="https://downloads.charts.noaa.gov/cache/AK_ENCs.zip",
            )

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("State AK", "https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", "AK_ENCs.zip")
                first = download_package(package, output, force=True)

                second = download_package(package, output, force=False)

                self.assertTrue(second.skipped)
                self.assertEqual(read_manifest(output)["download"]["url"], first.url)
        finally:
            downloader_module.urlopen = original

    def test_write_manifest_does_not_reuse_fixed_part_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            fixed_part = output / "noaa-navionics-manifest.json.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")
            package = Package("Test package", "file:///AK_ENCs.zip", "AK_ENCs.zip")
            result = downloader_module.DownloadResult(output / "AK_ENCs.zip", package.url, 0, sha256="abc")

            downloader_module.write_manifest(output, package, result)

            self.assertEqual(fixed_part.read_text(encoding="utf-8"), "other writer\n")
            self.assertEqual(read_manifest(output)["package"]["filename"], "AK_ENCs.zip")
            self.assertFalse(list(output.glob(".noaa-navionics-manifest.json.*.part")))

    def test_write_manifest_rejects_symlinked_output_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_storage = root / "real-storage"
            real_storage.mkdir()
            storage_link = root / "storage-link"
            try:
                storage_link.symlink_to(real_storage, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            output = storage_link / "charts"
            package = Package("Test package", "file:///AK_ENCs.zip", "AK_ENCs.zip")
            result = downloader_module.DownloadResult(output / "AK_ENCs.zip", package.url, 0, sha256="abc")

            with self.assertRaisesRegex(RuntimeError, "chart output path contains a symlink"):
                downloader_module.write_manifest(output, package, result)

            self.assertFalse((real_storage / "charts").exists())

    def test_write_manifest_syncs_file_and_directory(self):
        calls = []
        original_fsync = downloader_module.os.fsync
        downloader_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("Test package", "file:///AK_ENCs.zip", "AK_ENCs.zip")
                result = downloader_module.DownloadResult(output / "AK_ENCs.zip", package.url, 0, sha256="abc")

                downloader_module.write_manifest(output, package, result)
        finally:
            downloader_module.os.fsync = original_fsync

        self.assertGreaterEqual(len(calls), 2)

    def test_chart_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = downloader_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        downloader_module.os.open = fake_open
        try:
            downloader_module._fsync_directory(Path("/tmp"))
        finally:
            downloader_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], Path("/tmp"))
        self.assertTrue(calls[0][1] & getattr(os, "O_DIRECTORY", 0))
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_download_rejects_existing_partial_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            partial = output / "AK_ENCs.zip.part"
            partial.write_bytes(b"interrupted")
            package = package_for(state="AK")

            with self.assertRaisesRegex(RuntimeError, "partial download already exists"):
                download_package(package, output, force=True)

            self.assertEqual(partial.read_bytes(), b"interrupted")

    def test_download_rejects_existing_partial_symlink(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            partial = output / "AK_ENCs.zip.part"
            try:
                partial.symlink_to(output / "missing-part-target")
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            package = package_for(state="AK")

            with self.assertRaisesRegex(RuntimeError, "partial download already exists"):
                download_package(package, output, force=True)

            self.assertTrue(partial.is_symlink())

    def test_download_creates_private_archive_with_permissive_umask(self):
        original = downloader_module.urlopen
        old_umask = os.umask(0)

        def fake_urlopen(request, timeout=60):
            return self.FakeResponse(b"chart")

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir)
                package = Package("Private archive test", "https://example.invalid/chart.zip", "chart.zip")

                result = download_package(package, output)

                self.assertEqual(result.path.stat().st_mode & 0o777, 0o600)
        finally:
            os.umask(old_umask)
            downloader_module.urlopen = original

    def test_download_retries_transient_network_failure(self):
        calls = {"count": 0}
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            calls["count"] += 1
            if calls["count"] == 1:
                raise URLError("temporary outage")
            return self.FakeResponse(b"chart")

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                package = Package("Retry test", "https://example.invalid/chart.zip", "chart.zip")
                result = download_package(package, Path(tmpdir), retries=2, retry_delay=0)
                self.assertEqual(result.path.read_bytes(), b"chart")
                self.assertFalse(result.skipped)
        finally:
            downloader_module.urlopen = original

        self.assertEqual(calls["count"], 2)

    def test_download_retries_incomplete_response(self):
        calls = {"count": 0}
        original = downloader_module.urlopen

        def fake_urlopen(request, timeout=60):
            calls["count"] += 1
            if calls["count"] == 1:
                return self.FakeResponse(b"cha")
            return self.FakeResponse(b"chart")

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                package = Package("Retry test", "https://example.invalid/chart.zip", "chart.zip")
                result = download_package(package, Path(tmpdir), retries=2, retry_delay=0)
                self.assertEqual(result.path.read_bytes(), b"chart")
                self.assertEqual(result.bytes_written, 5)
        finally:
            downloader_module.urlopen = original

        self.assertEqual(calls["count"], 2)

    def test_download_retries_read_level_incomplete_response_and_cleans_partial(self):
        calls = {"count": 0}
        original = downloader_module.urlopen

        class BrokenReadResponse:
            headers = {"Content-Length": "5"}

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def read(self, size=-1):
                raise IncompleteRead(b"cha", 5)

        def fake_urlopen(request, timeout=60):
            calls["count"] += 1
            if calls["count"] == 1:
                return BrokenReadResponse()
            return self.FakeResponse(b"chart")

        try:
            downloader_module.urlopen = fake_urlopen
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                package = Package("Retry test", "https://example.invalid/chart.zip", "chart.zip")
                result = download_package(package, root, retries=2, retry_delay=0)
                self.assertEqual(result.path.read_bytes(), b"chart")
                self.assertFalse((root / "chart.zip.part").exists())
        finally:
            downloader_module.urlopen = original

        self.assertEqual(calls["count"], 2)

    def test_download_lock_blocks_concurrent_chart_update(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("busy\n", encoding="ascii")
            package = Package("Locked test", "https://example.invalid/chart.zip", "chart.zip")

            with self.assertRaisesRegex(RuntimeError, "already in progress"):
                download_package(package, root)

            self.assertTrue(lock.exists())

    def test_download_lock_rejects_symlinked_lock_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "lock-target"
            target.write_text("stale\n", encoding="ascii")
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(target, (old_time, old_time))
            lock = root / DOWNLOAD_LOCK_NAME
            try:
                lock.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            package = Package("Locked test", "https://example.invalid/chart.zip", "chart.zip")

            with self.assertRaisesRegex(RuntimeError, "chart update lock path is a symlink"):
                download_package(package, root)

            self.assertTrue(lock.is_symlink())
            self.assertEqual(target.read_text(encoding="ascii"), "stale\n")

    def test_stale_download_lock_is_replaced(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / "chart.zip").write_bytes(b"existing")
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("stale\n", encoding="ascii")
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            package = Package("Stale lock test", "https://example.invalid/chart.zip", "chart.zip")

            result = download_package(package, root)

            self.assertTrue(result.skipped)
            self.assertFalse(lock.exists())

    def test_stale_download_lock_cleanup_rejects_writable_lock_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / "chart.zip").write_bytes(b"existing")
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("stale\n", encoding="ascii")
            os.chmod(lock, 0o620)
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            package = Package("Stale lock test", "https://example.invalid/chart.zip", "chart.zip")

            with self.assertRaisesRegex(RuntimeError, "chart update lock path has permissions"):
                download_package(package, root)

            self.assertTrue(lock.exists())
            self.assertEqual(lock.read_text(encoding="ascii"), "stale\n")

    def test_old_download_lock_with_live_owner_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("pid=1234 boot_id=current-boot created_at=old\n", encoding="ascii")
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            original_boot_id = downloader_module._current_boot_id
            original_pid_is_running = downloader_module._pid_is_running
            try:
                downloader_module._current_boot_id = lambda: "current-boot"
                downloader_module._pid_is_running = lambda pid: pid == 1234

                stale = downloader_module._lock_is_stale(lock)
            finally:
                downloader_module._current_boot_id = original_boot_id
                downloader_module._pid_is_running = original_pid_is_running

            self.assertFalse(stale)
            self.assertEqual(lock.read_text(encoding="ascii"), "pid=1234 boot_id=current-boot created_at=old\n")

    def test_old_download_lock_from_previous_boot_is_stale_even_if_pid_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            lock = Path(tmpdir) / DOWNLOAD_LOCK_NAME
            lock.write_text("pid=1234 boot_id=previous-boot created_at=old\n", encoding="ascii")
            old_time = time.time() - downloader_module.DOWNLOAD_LOCK_STALE_SECONDS - 60
            os.utime(lock, (old_time, old_time))
            original_boot_id = downloader_module._current_boot_id
            original_pid_is_running = downloader_module._pid_is_running
            try:
                downloader_module._current_boot_id = lambda: "current-boot"
                downloader_module._pid_is_running = lambda pid: True

                stale = downloader_module._lock_is_stale(lock)
            finally:
                downloader_module._current_boot_id = original_boot_id
                downloader_module._pid_is_running = original_pid_is_running

            self.assertTrue(stale)

    def test_download_lock_cleanup_preserves_replaced_lock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lock = root / DOWNLOAD_LOCK_NAME

            with downloader_module._chart_update_lock(root):
                lock.write_text("new owner\n", encoding="ascii")

            self.assertEqual(lock.read_text(encoding="ascii"), "new owner\n")

    def test_download_lock_syncs_create_and_cleanup(self):
        calls = []
        original_fsync = downloader_module.os.fsync
        downloader_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                lock = root / DOWNLOAD_LOCK_NAME

                with downloader_module._chart_update_lock(root):
                    self.assertTrue(lock.exists())
                    self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
                self.assertFalse(lock.exists())
        finally:
            downloader_module.os.fsync = original_fsync

        self.assertGreaterEqual(len(calls), 3)

    def test_download_lock_cleans_up_failed_lock_setup(self):
        original_fchmod = downloader_module.os.fchmod
        def failing_fchmod(fd, mode):
            raise OSError("chmod failed")

        downloader_module.os.fchmod = failing_fchmod
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                lock = root / DOWNLOAD_LOCK_NAME

                with self.assertRaisesRegex(OSError, "chmod failed"):
                    with downloader_module._chart_update_lock(root):
                        pass

                self.assertFalse(lock.exists())
        finally:
            downloader_module.os.fchmod = original_fchmod

    def test_stale_manifest_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            manifest = root / MANIFEST_NAME
            manifest.write_text(
                '{"created_at":"2000-01-01T00:00:00Z","package":{"label":"Old"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )
            result = check_chart_manifest(root, max_age_days=1)
            self.assertFalse(result.ok)
            self.assertIn("days old", result.detail)

    def test_manifest_symlink_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_manifest = root / "real-manifest.json"
            real_manifest.write_text(
                '{"created_at":"2000-01-01T00:00:00Z","package":{"label":"Old"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )
            manifest = root / MANIFEST_NAME
            try:
                manifest.symlink_to(real_manifest)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_manifest(root, max_age_days=1)

            self.assertFalse(result.ok)
            self.assertIn("manifest path is a symlink", result.detail)

    def test_manifest_nonregular_path_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / MANIFEST_NAME).mkdir()

            result = check_chart_manifest(root, max_age_days=1)

            self.assertFalse(result.ok)
            self.assertIn("manifest path is not a regular file", result.detail)

    def test_manifest_writable_file_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            manifest = root / MANIFEST_NAME
            manifest.write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"path":"","url":"file:///test.zip","bytes":1,"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            manifest.chmod(0o666)

            result = check_chart_manifest(root, max_age_days=1)

            self.assertFalse(result.ok)
            self.assertIn("manifest path", result.detail)
            self.assertIn("has permissions 0666", result.detail)

    def test_read_manifest_rejects_symlinked_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_manifest = root / "real-manifest.json"
            real_manifest.write_text('{"created_at":"2026-01-01T00:00:00Z"}\n', encoding="utf-8")
            manifest = root / MANIFEST_NAME
            try:
                manifest.symlink_to(real_manifest)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "manifest path is a symlink"):
                read_manifest(root)

    def test_read_manifest_rejects_symlinked_manifest_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_dir = root / "real"
            real_dir.mkdir()
            (real_dir / MANIFEST_NAME).write_text('{"created_at":"2026-01-01T00:00:00Z"}\n', encoding="utf-8")
            link_dir = root / "link"
            try:
                link_dir.symlink_to(real_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "manifest directory contains a symlink"):
                read_manifest(link_dir)

    def test_read_manifest_rejects_writable_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            manifest = root / MANIFEST_NAME
            manifest.write_text('{"created_at":"2026-01-01T00:00:00Z"}\n', encoding="utf-8")
            manifest.chmod(0o622)

            with self.assertRaisesRegex(RuntimeError, "manifest path .* has permissions 0622"):
                read_manifest(root)

    def test_manifest_without_extracted_cells_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            old_cell = root / "old" / "US5AK3CM.000"
            old_cell.parent.mkdir()
            old_cell.write_text("old", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                '"extract":{"path":"","enc_cell_count":0}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("does not record an extracted chart path", result.detail)

    def test_manifest_with_missing_extract_path_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            missing = root / "AK_ENCs"
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{missing}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("extract path does not exist", result.detail)

    def test_manifest_extract_symlink_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_extract = root / "real-AK-ENCs"
            cell = real_extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            extract_link = root / "AK_ENCs"
            try:
                extract_link.symlink_to(real_extract, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract_link}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("manifest extract path is a symlink", result.detail)

    def test_manifest_extract_path_under_symlinked_parent_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-extract-parent"
            real_extract = real_parent / "AK_ENCs"
            cell = real_extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            link_parent = root / "extract-link"
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            extract = link_parent / "AK_ENCs"
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("manifest extract path contains a symlink", result.detail)
            self.assertIn("extract-link", result.detail)

    def test_manifest_with_missing_recorded_cells_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":2}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("manifest recorded 2 ENC cells but found 1", result.detail)

    def test_manifest_with_extra_unrecorded_cells_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            extra_cell = extract / "US5AK4CM" / "US5AK4CM.000"
            cell.parent.mkdir(parents=True)
            extra_cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            extra_cell.write_text("extra", encoding="ascii")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root)

            self.assertFalse(result.ok)
            self.assertIn("manifest recorded 1 ENC cells but found 2", result.detail)

    def test_manifest_extract_path_outside_chart_dir_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            outside = root / "outside" / "AK_ENCs"
            cell = outside / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            charts.mkdir()
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (charts / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{outside}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(charts)

            self.assertFalse(result.ok)
            self.assertIn("outside chart directory", result.detail)

    def test_manifest_package_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="CA")

            self.assertFalse(result.ok)
            self.assertIn("does not match configured CA_ENCs.zip", result.detail)

    def test_manifest_package_url_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip","url":"https://example.invalid/AK_ENCs.zip"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest package URL", result.detail)
            self.assertIn("https://www.charts.noaa.gov/ENCs/AK_ENCs.zip", result.detail)

    def test_manifest_download_url_redirect_with_matching_filename_passes(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://downloads.charts.noaa.gov/cache/AK_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertTrue(result.ok)

    def test_count_enc_cells_ignores_symlinked_cells(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "outside.000"
            target.write_text("not a trusted chart cell", encoding="ascii")
            cell = root / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            try:
                cell.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            self.assertEqual(downloader_module.count_enc_cells(root / "AK_ENCs"), 0)

    def test_manifest_symlinked_enc_cell_does_not_satisfy_count(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            target = root / "outside.000"
            target.write_text("not a trusted chart cell", encoding="ascii")
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            try:
                cell.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("no ENC cells found", result.detail)

    def test_manifest_download_url_mismatched_filename_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://example.invalid/CA_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest download URL", result.detail)
            self.assertIn("does not match package filename", result.detail)
            self.assertIn("non-HTTPS", result.detail)

    def test_manifest_download_url_http_redirect_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"http://downloads.charts.noaa.gov/cache/AK_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest download URL", result.detail)
            self.assertIn("does not match package filename", result.detail)
            self.assertIn("non-HTTPS", result.detail)

    def test_manifest_missing_download_url_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("does not record a download URL", result.detail)

    def test_manifest_fails_when_other_extracted_enc_directory_remains(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            current_cell = extract / "US5AK3CM" / "US5AK3CM.000"
            current_cell.parent.mkdir(parents=True)
            current_cell.write_text("cell", encoding="ascii")
            stale_cell = root / "CA_ENCs" / "US5CA99M" / "US5CA99M.000"
            stale_cell.parent.mkdir(parents=True)
            stale_cell.write_text("old", encoding="ascii")
            (root / "tracks").mkdir()
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip","sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("unexpected ENC chart directories", result.detail)
            self.assertIn("CA_ENCs", result.detail)

    def test_manifest_archive_sha_mismatch_fails_when_zip_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"corrupt")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":7,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("SHA-256", result.detail)

    def test_manifest_archive_size_mismatch_fails_when_zip_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            digest = downloader_module.sha256_file(archive)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":99,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("downloaded bytes", result.detail)

    def test_manifest_archive_requires_positive_size_when_zip_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            digest = downloader_module.sha256_file(archive)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":0,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("positive download byte count", result.detail)

    def test_manifest_archive_requires_positive_size_when_zip_not_retained(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":0,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("positive download byte count", result.detail)

    def test_manifest_archive_requires_sha256_when_zip_exists(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":{archive.stat().st_size},"sha256":""}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("download SHA-256", result.detail)

    def test_manifest_archive_requires_sha256_when_zip_not_retained(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":""}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("download SHA-256", result.detail)

    def test_manifest_archive_required_fails_when_zip_missing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("retained download path is missing", result.detail)

    def test_manifest_archive_required_fails_without_download_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip","bytes":5,"sha256":"abc"},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("does not record a retained download path", result.detail)

    def test_manifest_archive_path_outside_chart_dir_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            outside = root / "outside.zip"
            outside.write_bytes(b"chart")
            digest = downloader_module.sha256_file(outside)
            extract = charts / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (charts / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{outside}","bytes":5,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(charts, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("download path is outside chart directory", result.detail)

    def test_manifest_archive_symlink_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_archive = root / "real-AK-ENCs.zip"
            real_archive.write_bytes(b"chart")
            archive_link = root / "AK_ENCs.zip"
            try:
                archive_link.symlink_to(real_archive)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            digest = downloader_module.sha256_file(real_archive)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive_link}","bytes":5,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest download path is a symlink", result.detail)

    def test_manifest_archive_nonregular_path_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.mkdir()
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("manifest download path is not a regular file", result.detail)

    def test_manifest_archive_writable_file_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            archive.chmod(0o622)
            digest = downloader_module.sha256_file(archive)
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK", require_archive=True)

            self.assertFalse(result.ok)
            self.assertIn("manifest download path", result.detail)
            self.assertIn("has permissions 0622", result.detail)

    def test_sha256_trusted_file_rejects_writable_archive_before_hashing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            archive = Path(tmpdir) / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            archive.chmod(0o622)

            with self.assertRaisesRegex(RuntimeError, "has permissions 0622"):
                _sha256_trusted_file(archive, label="manifest download path", expected_uid=os.getuid())

    def test_manifest_archive_path_under_symlinked_parent_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_parent = root / "real-archive-parent"
            real_parent.mkdir()
            archive = real_parent / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            digest = downloader_module.sha256_file(archive)
            link_parent = root / "archive-link"
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            archive_path = link_parent / "AK_ENCs.zip"
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive_path}","bytes":5,"sha256":"{digest}"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_manifest(root, expected_package="state", expected_value="AK")

            self.assertFalse(result.ok)
            self.assertIn("manifest download path contains a symlink", result.detail)
            self.assertIn("archive-link", result.detail)

    def test_chart_package_rejects_update_bundle_as_primary_charts(self):
        result = check_chart_package("updates", "ten-days")
        self.assertFalse(result.ok)
        self.assertIn("not a complete chart set", result.detail)

    def test_chart_package_accepts_state_bundle(self):
        result = check_chart_package("state", "AK")
        self.assertTrue(result.ok)

    def test_chart_package_rejects_unsupported_state_bundle(self):
        result = check_chart_package("state", "ZZ")
        self.assertFalse(result.ok)
        self.assertIn("not a supported NOAA ENC package", result.detail)

    def test_chart_update_debris_fails_for_interrupted_sync_paths(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / ".AK_ENCs.previous").mkdir()
            (root / ".CA_ENCs.abcd.extracting").mkdir()
            (root / "AK_ENCs.zip.part").write_text("partial zip\n", encoding="ascii")
            (root / ".noaa-navionics-manifest.json.abcd.part").write_text("partial manifest\n", encoding="ascii")

            result = check_chart_update_debris(root)

            self.assertFalse(result.ok)
            self.assertIn(".AK_ENCs.previous", result.detail)
            self.assertIn(".CA_ENCs.abcd.extracting", result.detail)
            self.assertIn("AK_ENCs.zip.part", result.detail)
            self.assertIn(".noaa-navionics-manifest.json.abcd.part", result.detail)

    def test_chart_update_debris_ignores_download_lock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / DOWNLOAD_LOCK_NAME).write_text("locked\n", encoding="ascii")

            result = check_chart_update_debris(root)

            self.assertTrue(result.ok)

    def test_chart_update_debris_allows_retained_manifest_archive(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_update_debris(root)

            self.assertTrue(result.ok)

    def test_chart_update_debris_fails_for_unexpected_top_level_zip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "AK_ENCs.zip"
            extra = root / "CA_ENCs.zip"
            archive.write_bytes(b"chart")
            extra.write_bytes(b"stale chart")
            extract = root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (root / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","bytes":5,"sha256":"abc"}},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            result = check_chart_update_debris(root)

            self.assertFalse(result.ok)
            self.assertIn("CA_ENCs.zip", result.detail)
            self.assertNotIn("AK_ENCs.zip", result.detail)

    def test_extract_zip_replaces_existing_directory_after_success(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            destination = root / "AK_ENCs"
            old_cell = destination / "OLD" / "OLD.000"
            old_cell.parent.mkdir(parents=True)
            old_cell.write_text("old", encoding="ascii")

            extracted = extract_zip(archive, destination)

            self.assertEqual(extracted, destination)
            self.assertFalse(old_cell.exists())
            self.assertEqual((destination / "US5AK3CM" / "US5AK3CM.000").read_text(encoding="ascii"), "new")
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))
            self.assertFalse((root / ".AK_ENCs.previous").exists())

    def test_extract_zip_rejects_crc_failure_before_staging(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "cell")
            archive_bytes = archive.read_bytes()
            self.assertIn(b"cell", archive_bytes)
            archive.write_bytes(archive_bytes.replace(b"cell", b"bell", 1))
            destination = root / "AK_ENCs"

            with self.assertRaisesRegex(RuntimeError, "chart ZIP has a failed CRC member"):
                extract_zip(archive, destination)

            self.assertFalse(destination.exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_symlinked_destination(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            real_destination = root / "real-charts"
            real_destination.mkdir()
            destination = root / "AK_ENCs"
            try:
                destination.symlink_to(real_destination, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "chart extraction destination is a symlink"):
                extract_zip(archive, destination)

            self.assertTrue(destination.is_symlink())
            self.assertFalse((real_destination / "US5AK3CM").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_symlinked_destination_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            real_parent = root / "real-parent"
            real_parent.mkdir()
            link_parent = root / "link-parent"
            try:
                link_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            destination = link_parent / "AK_ENCs"

            with self.assertRaisesRegex(RuntimeError, "chart output path contains a symlink"):
                extract_zip(archive, destination)

            self.assertFalse((real_parent / "AK_ENCs").exists())
            self.assertFalse(list(real_parent.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_non_directory_destination(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            destination = root / "AK_ENCs"
            destination.write_text("not a directory\n", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "chart extraction destination is not a directory"):
                extract_zip(archive, destination)

            self.assertEqual(destination.read_text(encoding="utf-8"), "not a directory\n")
            self.assertFalse((root / ".AK_ENCs.previous").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_symlinked_previous_debris_without_promoting_it(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            target = root / "previous-target"
            target.mkdir()
            previous = root / ".AK_ENCs.previous"
            try:
                previous.symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "previous chart extraction path is a symlink before cleanup"):
                extract_zip(archive, root / "AK_ENCs")

            self.assertTrue(previous.is_symlink())
            self.assertTrue(target.is_dir())
            self.assertFalse((root / "AK_ENCs").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_rejects_previous_debris_with_symlinked_child(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            previous = root / ".AK_ENCs.previous"
            previous.mkdir()
            target = root / "previous-child-target"
            target.mkdir()
            try:
                (previous / "child-link").symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "previous chart extraction path is a symlink before cleanup"):
                extract_zip(archive, root / "AK_ENCs")

            self.assertTrue((previous / "child-link").is_symlink())
            self.assertTrue(target.is_dir())
            self.assertFalse((root / "AK_ENCs").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_cleanup_requires_symlink_safe_rmtree(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")
            previous = root / ".AK_ENCs.previous"
            previous.mkdir()
            (previous / "old.000").write_text("old", encoding="ascii")
            original = getattr(downloader_module.shutil.rmtree, "avoids_symlink_attacks", None)
            try:
                downloader_module.shutil.rmtree.avoids_symlink_attacks = False
                with self.assertRaisesRegex(RuntimeError, "shutil.rmtree is not symlink-attack resistant"):
                    extract_zip(archive, root / "AK_ENCs")
            finally:
                if original is None:
                    try:
                        del downloader_module.shutil.rmtree.avoids_symlink_attacks
                    except AttributeError:
                        pass
                else:
                    downloader_module.shutil.rmtree.avoids_symlink_attacks = original

            self.assertTrue(previous.is_dir())
            self.assertEqual((previous / "old.000").read_text(encoding="ascii"), "old")
            self.assertFalse((root / "AK_ENCs").exists())

    def test_extract_zip_failed_staging_cleanup_requires_symlink_safe_rmtree(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "empty-charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("README.txt", "no chart cells")
            destination = root / "AK_ENCs"
            original = getattr(downloader_module.shutil.rmtree, "avoids_symlink_attacks", None)
            try:
                downloader_module.shutil.rmtree.avoids_symlink_attacks = False
                with self.assertRaisesRegex(RuntimeError, "shutil.rmtree is not symlink-attack resistant"):
                    extract_zip(archive, destination)
            finally:
                if original is None:
                    try:
                        del downloader_module.shutil.rmtree.avoids_symlink_attacks
                    except AttributeError:
                        pass
                else:
                    downloader_module.shutil.rmtree.avoids_symlink_attacks = original

            self.assertFalse(destination.exists())
            leftovers = list(root.glob(".AK_ENCs.*.extracting"))
            self.assertEqual(len(leftovers), 1)
            self.assertEqual((leftovers[0] / "README.txt").read_text(encoding="ascii"), "no chart cells")

    def test_extract_zip_syncs_extracted_tree_and_parent_directory(self):
        calls = []
        original_fsync = downloader_module.os.fsync
        downloader_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                archive = root / "charts.zip"
                with zipfile.ZipFile(archive, "w") as zip_file:
                    zip_file.writestr("US5AK3CM/US5AK3CM.000", "new")

                extract_zip(archive, root / "AK_ENCs")
        finally:
            downloader_module.os.fsync = original_fsync

        self.assertGreaterEqual(len(calls), 3)

    def test_extract_zip_failure_preserves_existing_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "bad.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("../evil.000", "bad")
            destination = root / "AK_ENCs"
            old_cell = destination / "US5AK3CM" / "US5AK3CM.000"
            old_cell.parent.mkdir(parents=True)
            old_cell.write_text("old", encoding="ascii")

            with self.assertRaises(RuntimeError):
                extract_zip(archive, destination)

            self.assertEqual(old_cell.read_text(encoding="ascii"), "old")
            self.assertFalse((root / "evil.000").exists())
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))

    def test_extract_zip_without_enc_cells_preserves_existing_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            archive = root / "empty-charts.zip"
            with zipfile.ZipFile(archive, "w") as zip_file:
                zip_file.writestr("README.txt", "no chart cells")
            destination = root / "AK_ENCs"
            old_cell = destination / "US5AK3CM" / "US5AK3CM.000"
            old_cell.parent.mkdir(parents=True)
            old_cell.write_text("old", encoding="ascii")

            with self.assertRaisesRegex(RuntimeError, "no ENC"):
                extract_zip(archive, destination)

            self.assertEqual(old_cell.read_text(encoding="ascii"), "old")
            self.assertFalse(list(root.glob(".AK_ENCs.*.extracting")))


class StatusReportTests(unittest.TestCase):
    def test_status_report_queries_track_logger_umask(self):
        for unit in (
            "noaa-navionics.service",
            "noaa-navionics-track.service",
            "noaa-navionics-preflight.service",
        ):
            with self.subTest(unit=unit):
                self.assertIn("UMask", report_module.USER_UNIT_PROPERTIES[unit])
                self.assertIn("ProtectSystem", report_module.USER_UNIT_PROPERTIES[unit])

    def test_build_and_write_status_report(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            cell = charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            archive = charts / "AK_ENCs.zip"
            archive.write_bytes(b"x" * 123)
            archive.chmod(0o640)
            manifest = charts / MANIFEST_NAME
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            manifest.write_text(
                '{"created_at":"' + now + '",'
                '"created_at_source":"download",'
                '"package":{"label":"Test","filename":"AK_ENCs.zip","url":"file:///test.zip"},'
                f'"download":{{"path":"{archive}","url":"file:///test.zip",'
                '"bytes":123,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{cell.parent}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            sample = root / "sample.nmea"
            sample.write_text(
                "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n",
                encoding="ascii",
            )
            track_time = datetime.now(timezone.utc)
            with GPXTrackLogger(charts / "tracks" / "track-20260629.gpx") as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=track_time, satellites=8, hdop=1.2))
            config = root / "config.ini"
            config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {charts}\n"
                "max_age_days = 30\n"
                "min_free_gb = 3.5\n"
                "\n"
                "[gps]\n"
                "mode = gpsd\n"
                "\n"
                "[tracking]\n"
                f"output = {charts}\n",
                encoding="utf-8",
            )

            revision = root / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            boot_id = root / "boot_id"
            boot_id.write_text("boot-abc\n", encoding="ascii")
            launcher_env = root / "launcher.env"
            launcher_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=10\n", encoding="ascii")
            launcher_env.chmod(0o600)
            opencpn_config = root / "opencpn.conf"
            configure_chart_directory(charts, config_path=opencpn_config)
            configure_gpsd_connection(config_path=opencpn_config)
            autostart = root / "noaa-navionics-chartplotter.desktop"
            autostart.write_text(
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=NOAA Navionics Chartplotter\n"
                "Exec=sh -lc \"$HOME/.local/bin/noaa-navionics-start-chartplotter\"\n"
                "Terminal=false\n"
                "X-GNOME-Autostart-enabled=true\n",
                encoding="utf-8",
            )
            autostart.chmod(0o644)
            lightdm_autologin = root / "50-noaa-navionics-autologin.conf"
            lightdm_autologin.write_text(
                "[Seat:*]\n"
                f"autologin-user={os.environ.get('USER', '')}\n"
                "autologin-user-timeout=0\n"
                "autologin-session=missing-test-session\n",
                encoding="utf-8",
            )
            lightdm_autologin.chmod(0o644)
            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            original_boot_id_path = report_module.BOOT_ID_PATH
            original_launcher_env_path = report_module.DEFAULT_LAUNCHER_ENV_PATH
            original_opencpn_config_path = opencpn_module.DEFAULT_OPENCPN_CONFIG_PATH
            original_flatpak_opencpn_config_path = opencpn_module.FLATPAK_OPENCPN_CONFIG_PATH
            original_autostart_path = report_module.DEFAULT_AUTOSTART_PATH
            original_lightdm_autologin_path = report_module.DEFAULT_LIGHTDM_AUTOLOGIN_PATH
            original_systemctl_system = report_module._systemctl_system
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(revision)
            report_module.BOOT_ID_PATH = boot_id
            report_module.DEFAULT_LAUNCHER_ENV_PATH = launcher_env
            report_module.DEFAULT_AUTOSTART_PATH = autostart
            report_module.DEFAULT_LIGHTDM_AUTOLOGIN_PATH = lightdm_autologin
            report_module._systemctl_system = lambda args: {
                ("get-default",): "graphical.target",
                ("is-enabled", "lightdm.service"): "enabled",
                ("is-active", "lightdm.service"): "inactive",
            }.get(tuple(args), "unknown")
            opencpn_module.DEFAULT_OPENCPN_CONFIG_PATH = opencpn_config
            opencpn_module.FLATPAK_OPENCPN_CONFIG_PATH = root / "missing-flatpak-opencpn.conf"
            try:
                report = build_status_report(config_path=config, gps_sample=sample)
            finally:
                report_module.BOOT_ID_PATH = original_boot_id_path
                report_module.DEFAULT_LAUNCHER_ENV_PATH = original_launcher_env_path
                report_module.DEFAULT_AUTOSTART_PATH = original_autostart_path
                report_module.DEFAULT_LIGHTDM_AUTOLOGIN_PATH = original_lightdm_autologin_path
                report_module._systemctl_system = original_systemctl_system
                opencpn_module.DEFAULT_OPENCPN_CONFIG_PATH = original_opencpn_config_path
                opencpn_module.FLATPAK_OPENCPN_CONFIG_PATH = original_flatpak_opencpn_config_path
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path
            self.assertIn("checks", report)
            self.assertIn("services", report)
            self.assertIn("system_services", report)
            self.assertIn("unit_files", report)
            self.assertIn("user", report)
            self.assertIn("launcher_settings", report)
            self.assertIn("opencpn_config", report)
            self.assertIn("desktop", report)
            self.assertIn("track_log", report)
            self.assertIn("service_checks", report)
            self.assertEqual(report["app"]["source_revision"], "abc123")
            self.assertEqual(report["app"]["source_revision_path"], str(revision))
            self.assertEqual(report["app"]["source_revision_path_is_symlink"], False)
            self.assertEqual(report["app"]["source_revision_directory_is_symlink"], False)
            self.assertEqual(report["app"]["source_revision_symlink_component"], "")
            self.assertEqual(report["config"]["extract"], True)
            self.assertEqual(report["config"]["keep_zip"], True)
            self.assertEqual(report["config"]["force"], True)
            self.assertEqual(report["config"]["min_free_gb"], 3.5)
            self.assertEqual(report["host"]["boot_id"], "boot-abc")
            self.assertEqual(report["launcher_settings"]["path"], str(launcher_env))
            self.assertEqual(report["launcher_settings"]["is_symlink"], False)
            self.assertEqual(report["launcher_settings"]["directory_is_symlink"], False)
            self.assertEqual(report["launcher_settings"]["launcher_settings_symlink_component"], "")
            self.assertEqual(report["launcher_settings"]["mode"], "0600")
            self.assertEqual(report["launcher_settings"]["values"]["NOAA_NAVIONICS_GPS_SECONDS"], "10")
            self.assertEqual(report["opencpn_config"]["path"], str(opencpn_config))
            self.assertEqual(report["opencpn_config"]["exists"], True)
            self.assertEqual(report["opencpn_config"]["is_symlink"], False)
            self.assertEqual(report["opencpn_config"]["directory_is_symlink"], False)
            self.assertEqual(report["opencpn_config"]["config_symlink_component"], "")
            self.assertEqual(report["opencpn_config"]["uid"], os.getuid())
            self.assertEqual(report["opencpn_config"]["mode"], "0600")
            self.assertEqual(report["opencpn_config"]["chart_directories"], [str(charts.resolve())])
            self.assertTrue(report["opencpn_config"]["data_connections"])
            self.assertEqual(report["desktop"]["autostart"]["path"], str(autostart))
            self.assertEqual(report["desktop"]["autostart"]["is_symlink"], False)
            self.assertEqual(report["desktop"]["autostart"]["directory_is_symlink"], False)
            self.assertEqual(report["desktop"]["autostart"]["path_symlink_component"], "")
            self.assertEqual(report["desktop"]["autostart"]["uid"], os.getuid())
            self.assertEqual(report["desktop"]["autostart"]["mode"], "0644")
            self.assertEqual(report["desktop"]["autostart"]["values"]["Exec"], 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"')
            self.assertEqual(report["desktop"]["lightdm_autologin"]["path"], str(lightdm_autologin))
            self.assertEqual(report["desktop"]["lightdm_autologin"]["is_symlink"], False)
            self.assertEqual(report["desktop"]["lightdm_autologin"]["directory_is_symlink"], False)
            self.assertEqual(report["desktop"]["lightdm_autologin"]["path_symlink_component"], "")
            self.assertEqual(report["desktop"]["lightdm_autologin"]["uid"], os.getuid())
            self.assertEqual(report["desktop"]["lightdm_autologin"]["mode"], "0644")
            self.assertEqual(report["desktop"]["lightdm_autologin"]["values"]["autologin-user-timeout"], "0")
            self.assertEqual(report["desktop"]["graphical_target"], "graphical.target")
            self.assertEqual(report["desktop"]["lightdm_enabled"], "enabled")
            self.assertEqual(report["track_log"]["track_output"], str(charts))
            self.assertEqual(report["track_log"]["track_output_is_symlink"], False)
            self.assertEqual(report["track_log"]["tracks_dir"], str(charts / "tracks"))
            self.assertEqual(report["manifest"]["path"], str(manifest))
            self.assertEqual(report["manifest"]["exists"], True)
            self.assertEqual(report["manifest"]["is_symlink"], False)
            self.assertEqual(report["manifest"]["directory_is_symlink"], False)
            self.assertEqual(report["manifest"]["manifest_symlink_component"], "")
            self.assertEqual(report["manifest"]["uid"], os.getuid())
            self.assertEqual(report["manifest"]["mode"], "0644")
            self.assertEqual(report["manifest"]["created_at"], now)
            self.assertEqual(report["manifest"]["created_at_source"], "download")
            self.assertEqual(report["manifest"]["package"], "Test")
            self.assertEqual(report["manifest"]["package_filename"], "AK_ENCs.zip")
            self.assertEqual(report["manifest"]["url"], "file:///test.zip")
            self.assertEqual(report["manifest"]["download_path"], str(charts / "AK_ENCs.zip"))
            self.assertEqual(report["manifest"]["download_path_exists"], True)
            self.assertEqual(report["manifest"]["download_path_is_symlink"], False)
            self.assertEqual(report["manifest"]["download_path_symlink_component"], "")
            self.assertEqual(report["manifest"]["download_path_uid"], os.getuid())
            self.assertEqual(report["manifest"]["download_path_mode"], "0640")
            self.assertEqual(report["manifest"]["download_url"], "file:///test.zip")
            self.assertEqual(report["manifest"]["download_skipped"], False)
            self.assertEqual(report["manifest"]["download_bytes"], 123)
            self.assertEqual(report["manifest"]["sha256"], "abc")
            self.assertEqual(report["manifest"]["extract_path"], str(cell.parent))
            self.assertEqual(report["manifest"]["extract_path_is_symlink"], False)
            self.assertEqual(report["manifest"]["extract_path_symlink_component"], "")
            self.assertEqual(report["manifest"]["enc_cell_count"], 1)
            self.assertEqual(report["manifest"]["actual_enc_cell_count"], 1)
            self.assertFalse(report["ok"])
            text = format_status_text(report)
            self.assertIn("Ready: no", text)
            self.assertIn("Boot ID: boot-abc", text)
            self.assertIn("revision abc123", text)
            self.assertIn("source_revision_path_is_symlink=False", text)
            self.assertIn("source_revision_directory_is_symlink=False", text)
            self.assertIn("source_revision_symlink_component=", text)
            self.assertIn("actual_enc_cell_count: 1", text)
            self.assertIn("OpenCPN Config:", text)
            self.assertIn(f"path={opencpn_config}", text)
            self.assertIn("is_symlink=False", text)
            self.assertIn("directory_is_symlink=False", text)
            self.assertIn("config_symlink_component=", text)
            self.assertIn(f"uid={os.getuid()} mode=0600", text)
            self.assertIn("Desktop Startup:", text)
            self.assertIn(f"autostart={autostart}", text)
            self.assertIn("is_symlink=False", text)
            self.assertIn("path_symlink_component=", text)
            self.assertIn(f"uid={os.getuid()} mode=0644", text)
            self.assertIn("created_at_source: download", text)
            self.assertIn("is_symlink: False", text)
            self.assertIn("directory_is_symlink: False", text)
            self.assertIn("manifest_symlink_component: ", text)
            self.assertIn(f"uid: {os.getuid()}", text)
            self.assertIn("mode: 0644", text)
            self.assertIn("package_filename: AK_ENCs.zip", text)
            self.assertIn("url: file:///test.zip", text)
            self.assertIn("download_path_exists: True", text)
            self.assertIn("download_path_is_symlink: False", text)
            self.assertIn("download_path_symlink_component: ", text)
            self.assertIn(f"download_path_uid: {os.getuid()}", text)
            self.assertIn("download_path_mode: 0640", text)
            self.assertIn("download_url: file:///test.zip", text)
            self.assertIn("download_skipped: False", text)
            self.assertIn("download_bytes: 123", text)
            self.assertIn(f"extract_path: {cell.parent}", text)
            self.assertIn("extract_path_is_symlink: False", text)
            self.assertIn("extract_path_symlink_component: ", text)
            self.assertIn("Service Checks:", text)
            self.assertIn("System Services:", text)
            self.assertIn("User:", text)
            self.assertIn("User Unit Files:", text)
            self.assertIn("Launcher Settings:", text)
            self.assertIn("is_symlink=False", text)
            self.assertIn("launcher_settings_symlink_component=", text)
            self.assertIn("Track Log:", text)
            self.assertIn(f"track_output={charts}", text)
            self.assertIn("track_output_is_symlink=False", text)
            self.assertIn("track_storage_symlink_component=", text)
            output = root / "status.json"
            write_status_report(report, output)
            self.assertTrue(output.exists())
            self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_app_summary_rejects_symlinked_source_revision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_revision = root / "real-source-revision"
            real_revision.write_text("unexpected\n", encoding="utf-8")
            link_revision = root / "source-revision"
            try:
                link_revision.symlink_to(real_revision)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(link_revision)
            try:
                summary = report_module._app_summary()
            finally:
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_path"], str(link_revision))
            self.assertEqual(summary["source_revision_path_is_symlink"], True)
            self.assertEqual(summary["source_revision_directory_is_symlink"], False)
            self.assertEqual(summary["source_revision_symlink_component"], "")
            self.assertIn("source revision path is a symlink", summary["source_revision_error"])

    def test_app_summary_rejects_symlinked_source_revision_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_dir = root / "real-source"
            real_dir.mkdir()
            real_revision = real_dir / "source-revision"
            real_revision.write_text("unexpected\n", encoding="utf-8")
            link_dir = root / "source-link"
            try:
                link_dir.symlink_to(real_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_revision = link_dir / "source-revision"

            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(link_revision)
            try:
                summary = report_module._app_summary()
            finally:
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_path"], str(link_revision))
            self.assertEqual(summary["source_revision_path_is_symlink"], False)
            self.assertEqual(summary["source_revision_directory_is_symlink"], True)
            self.assertEqual(summary["source_revision_symlink_component"], str(link_dir))
            self.assertIn("source revision directory is a symlink", summary["source_revision_error"])

    def test_app_summary_rejects_symlinked_source_revision_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_root = root / "real-install"
            real_dir = real_root / "noaa-navionics"
            real_dir.mkdir(parents=True)
            real_revision = real_dir / "source-revision"
            real_revision.write_text("unexpected\n", encoding="utf-8")
            link_root = root / "install-link"
            try:
                link_root.symlink_to(real_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_revision = link_root / "noaa-navionics" / "source-revision"

            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(link_revision)
            try:
                summary = report_module._app_summary()
            finally:
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_path"], str(link_revision))
            self.assertEqual(summary["source_revision_path_is_symlink"], False)
            self.assertEqual(summary["source_revision_directory_is_symlink"], False)
            self.assertEqual(summary["source_revision_symlink_component"], str(link_root))
            self.assertIn("source revision directory is a symlink", summary["source_revision_error"])

    def test_app_summary_rejects_nonregular_source_revision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.mkdir()

            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(revision)
            try:
                summary = report_module._app_summary()
            finally:
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_exists"], True)
            self.assertIn("source revision path is not a regular file", summary["source_revision_error"])

    def test_app_summary_rejects_writable_source_revision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o620)

            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(revision)
            try:
                summary = report_module._app_summary()
            finally:
                revision.chmod(0o600)
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path

            self.assertEqual(summary["source_revision"], "unknown")
            self.assertEqual(summary["source_revision_mode"], "0620")
            self.assertIn("source revision path", summary["source_revision_error"])
            self.assertIn("has permissions 0620", summary["source_revision_error"])

    def test_source_revision_reader_rejects_writable_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o622)
            try:
                with self.assertRaisesRegex(RuntimeError, "source revision path .* has permissions 0622"):
                    report_module._source_revision(revision)
            finally:
                revision.chmod(0o600)

    def test_launcher_settings_summary_rejects_symlinked_environment(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_env = root / "real-launcher.env"
            real_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=10\n", encoding="ascii")
            link_env = root / "launcher.env"
            try:
                link_env.symlink_to(real_env)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = _launcher_settings_summary(link_env)

            self.assertEqual(summary["path"], str(link_env))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], True)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["launcher_settings_symlink_component"], "")
            self.assertIn("launcher environment path is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_launcher_settings_summary_rejects_symlinked_environment_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config = root / "real-config"
            real_config.mkdir()
            real_env = real_config / "launcher.env"
            real_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=10\n", encoding="ascii")
            link_config = root / "linked-config"
            try:
                link_config.symlink_to(real_config, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_env = link_config / "launcher.env"

            summary = _launcher_settings_summary(link_env)

            self.assertEqual(summary["path"], str(link_env))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], True)
            self.assertEqual(summary["launcher_settings_symlink_component"], str(link_config))
            self.assertIn("launcher environment directory is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_launcher_settings_summary_rejects_symlinked_environment_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_home = root / "real-home"
            real_config = real_home / ".config" / "noaa-navionics"
            real_config.mkdir(parents=True)
            real_env = real_config / "launcher.env"
            real_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=10\n", encoding="ascii")
            link_home = root / "home-link"
            try:
                link_home.symlink_to(real_home, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_env = link_home / ".config" / "noaa-navionics" / "launcher.env"

            summary = _launcher_settings_summary(link_env)

            self.assertEqual(summary["path"], str(link_env))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["launcher_settings_symlink_component"], str(link_home))
            self.assertIn("launcher environment directory is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_launcher_settings_summary_records_malformed_environment_lines(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            launcher_env = Path(tmpdir) / "launcher.env"
            launcher_env.write_text(
                "NOAA_NAVIONICS_GPS_SECONDS=60\n"
                "# comment\n"
                "not-a-setting\n",
                encoding="ascii",
            )
            launcher_env.chmod(0o600)

            summary = _launcher_settings_summary(launcher_env)

            self.assertEqual(summary["values"]["NOAA_NAVIONICS_GPS_SECONDS"], "60")
            self.assertEqual(summary["malformed_lines"], ["3: not-a-setting"])

    def test_launcher_settings_summary_rejects_nonregular_environment(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            launcher_env = Path(tmpdir) / "launcher.env"
            launcher_env.mkdir()

            summary = _launcher_settings_summary(launcher_env)
            check = _launcher_settings_check(summary)

            self.assertEqual(summary["path"], str(launcher_env))
            self.assertEqual(summary["exists"], True)
            self.assertIn("not a regular file", summary["error"])
            self.assertFalse(check.ok)
            self.assertIn("not a regular file", check.detail)

    def test_launcher_settings_summary_records_owner_and_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            launcher_env = Path(tmpdir) / "launcher.env"
            launcher_env.write_text("NOAA_NAVIONICS_GPS_SECONDS=60\n", encoding="ascii")
            launcher_env.chmod(0o600)

            summary = _launcher_settings_summary(launcher_env)

            self.assertEqual(summary["uid"], os.getuid())
            self.assertEqual(summary["mode"], "0600")
            self.assertEqual(summary["values"]["NOAA_NAVIONICS_GPS_SECONDS"], "60")

    def test_launcher_settings_summary_rejects_public_environment_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            launcher_env = Path(tmpdir) / "launcher.env"
            launcher_env.write_text("NOAA_NAVIONICS_START_ON_FAILED_READINESS=yes\n", encoding="ascii")
            launcher_env.chmod(0o644)

            summary = _launcher_settings_summary(launcher_env)
            check = _launcher_settings_check(summary)

            self.assertEqual(summary["uid"], os.getuid())
            self.assertEqual(summary["mode"], "0644")
            self.assertIn("expected private 0600", summary["error"])
            self.assertNotIn("values", summary)
            self.assertFalse(check.ok)
            self.assertIn("expected private 0600", check.detail)

    def test_launcher_settings_check_fails_symlinked_environment_ancestor(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "is_symlink": False,
                "directory_is_symlink": False,
                "launcher_settings_symlink_component": "/home/pi",
                "values": {"NOAA_NAVIONICS_GPS_SECONDS": "60"},
            }
        )

        self.assertFalse(check.ok)
        self.assertIn("launcher environment directory is a symlink: /home/pi", check.detail)

    def test_launcher_settings_check_fails_misowned_environment(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "is_symlink": False,
                "uid": os.getuid() + 1,
                "mode": "0600",
                "values": {"NOAA_NAVIONICS_GPS_SECONDS": "60"},
            }
        )

        self.assertFalse(check.ok)
        self.assertIn("owned by uid", check.detail)

    def test_launcher_settings_check_fails_unknown_environment_keys(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "is_symlink": False,
                "mode": "0600",
                "values": {
                    "NOAA_NAVIONICS_GPS_SECONDS": "60",
                    "NOAA_NAVIONICS_UNEXPECTED": "1",
                },
            }
        )

        self.assertFalse(check.ok)
        self.assertIn("unknown launcher environment key(s): NOAA_NAVIONICS_UNEXPECTED", check.detail)

    def test_launcher_settings_check_fails_malformed_environment_lines(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "is_symlink": False,
                "mode": "0600",
                "values": {"NOAA_NAVIONICS_GPS_SECONDS": "60"},
                "malformed_lines": ["2: not-a-setting"],
            }
        )

        self.assertFalse(check.ok)
        self.assertIn("malformed launcher environment line 2: not-a-setting", check.detail)

    def test_key_value_file_summary_rejects_symlinked_startup_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_file = root / "real.desktop"
            real_file.write_text("[Desktop Entry]\nName=Unexpected\n", encoding="utf-8")
            link_file = root / "noaa-navionics-chartplotter.desktop"
            try:
                link_file.symlink_to(real_file)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = _key_value_file_summary(link_file, comment_prefixes=("#",))

            self.assertEqual(summary["path"], str(link_file))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], True)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["path_symlink_component"], "")
            self.assertIn("key-value file path is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_key_value_file_summary_rejects_symlinked_startup_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_dir = root / "real-autostart"
            real_dir.mkdir()
            real_file = real_dir / "noaa-navionics-chartplotter.desktop"
            real_file.write_text("[Desktop Entry]\nName=Unexpected\n", encoding="utf-8")
            link_dir = root / "autostart"
            try:
                link_dir.symlink_to(real_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_file = link_dir / "noaa-navionics-chartplotter.desktop"

            summary = _key_value_file_summary(link_file, comment_prefixes=("#",))

            self.assertEqual(summary["path"], str(link_file))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], True)
            self.assertEqual(summary["path_symlink_component"], str(link_dir))
            self.assertIn("key-value file directory is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_key_value_file_summary_rejects_symlinked_startup_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_home = root / "real-home"
            real_autostart = real_home / ".config" / "autostart"
            real_autostart.mkdir(parents=True)
            real_file = real_autostart / "noaa-navionics-chartplotter.desktop"
            real_file.write_text("[Desktop Entry]\nName=Unexpected\n", encoding="utf-8")
            link_home = root / "home-link"
            try:
                link_home.symlink_to(real_home, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            link_file = link_home / ".config" / "autostart" / "noaa-navionics-chartplotter.desktop"

            summary = _key_value_file_summary(link_file, comment_prefixes=("#",))

            self.assertEqual(summary["path"], str(link_file))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["path_symlink_component"], str(link_home))
            self.assertIn("key-value file directory is a symlink", summary["error"])
            self.assertNotIn("values", summary)

    def test_key_value_file_summary_rejects_nonregular_startup_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "noaa-navionics-chartplotter.desktop"
            path.mkdir()

            summary = _key_value_file_summary(path, comment_prefixes=("#",))

            self.assertEqual(summary["path"], str(path))
            self.assertEqual(summary["exists"], True)
            self.assertIn("key-value file path is not a regular file", summary["error"])
            self.assertNotIn("values", summary)

    def test_key_value_file_summary_records_owner_and_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "noaa-navionics-chartplotter.desktop"
            path.write_text("[Desktop Entry]\nName=NOAA Navionics Chartplotter\n", encoding="utf-8")
            path.chmod(0o640)

            summary = _key_value_file_summary(path, comment_prefixes=("#",))

            self.assertEqual(summary["uid"], os.getuid())
            self.assertEqual(summary["mode"], "0640")
            self.assertEqual(summary["values"]["Name"], "NOAA Navionics Chartplotter")

    def test_key_value_file_summary_rejects_writable_startup_file_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "noaa-navionics-chartplotter.desktop"
            path.write_text("[Desktop Entry]\nName=Unexpected\n", encoding="utf-8")
            path.chmod(0o622)

            summary = _key_value_file_summary(path, comment_prefixes=("#",))

            self.assertIn("has permissions 0622", summary["error"])
            self.assertIn("expected no group/other write bits", summary["error"])
            self.assertNotIn("values", summary)

    def test_opencpn_config_summary_rejects_symlinked_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_config = root / "real-opencpn.conf"
            configure_chart_directory(charts, config_path=real_config)
            link_config = root / "opencpn.conf"
            try:
                link_config.symlink_to(real_config)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = report_module._opencpn_config_summary(link_config)

            self.assertEqual(summary["path"], str(link_config))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], True)
            self.assertIn("OpenCPN config path is a symlink", summary["error"])
            self.assertNotIn("chart_directories", summary)
            self.assertNotIn("data_connections", summary)

    def test_opencpn_config_summary_rejects_symlinked_config_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_config_dir = root / "real-opencpn"
            real_config_dir.mkdir()
            real_config = real_config_dir / "opencpn.conf"
            configure_chart_directory(charts, config_path=real_config)
            link_config_dir = root / "opencpn-link"
            try:
                link_config_dir.symlink_to(real_config_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            config = link_config_dir / "opencpn.conf"

            summary = report_module._opencpn_config_summary(config)

            self.assertEqual(summary["path"], str(config))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], True)
            self.assertEqual(summary["config_symlink_component"], str(link_config_dir))
            self.assertIn("OpenCPN config directory is a symlink", summary["error"])
            self.assertNotIn("chart_directories", summary)
            self.assertNotIn("data_connections", summary)

    def test_opencpn_config_summary_rejects_symlinked_config_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_config_root = root / "real-config-root"
            real_config_dir = real_config_root / "opencpn"
            real_config_dir.mkdir(parents=True)
            real_config = real_config_dir / "opencpn.conf"
            configure_chart_directory(charts, config_path=real_config)
            link_config_root = root / "config-link"
            try:
                link_config_root.symlink_to(real_config_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            config = link_config_root / "opencpn" / "opencpn.conf"

            summary = report_module._opencpn_config_summary(config)

            self.assertEqual(summary["path"], str(config))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["config_symlink_component"], str(link_config_root))
            self.assertIn("OpenCPN config directory is a symlink", summary["error"])
            self.assertNotIn("chart_directories", summary)
            self.assertNotIn("data_connections", summary)

    def test_opencpn_config_summary_rejects_nonregular_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"
            config.mkdir()

            summary = report_module._opencpn_config_summary(config)

            self.assertEqual(summary["path"], str(config))
            self.assertEqual(summary["exists"], True)
            self.assertIn("OpenCPN config path is not a regular file", summary["error"])
            self.assertNotIn("chart_directories", summary)
            self.assertNotIn("data_connections", summary)

    def test_opencpn_config_summary_records_owner_and_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            config = root / "opencpn.conf"
            configure_chart_directory(charts, config_path=config)
            config.chmod(0o640)

            summary = report_module._opencpn_config_summary(config)

            self.assertEqual(summary["uid"], os.getuid())
            self.assertEqual(summary["mode"], "0640")
            self.assertEqual(summary["directory_uid"], os.getuid())
            self.assertEqual(summary["directory_mode"], "0700")
            self.assertEqual(summary["chart_directories"], [str(charts.resolve())])

    def test_opencpn_config_summary_records_public_directory_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config_dir = root / "opencpn"
            config_dir.mkdir()
            config = config_dir / "opencpn.conf"
            config.write_text("[ChartDirectories]\n", encoding="utf-8")
            config.chmod(0o600)
            config_dir.chmod(0o755)
            try:
                summary = report_module._opencpn_config_summary(config)
            finally:
                config_dir.chmod(0o700)

            self.assertEqual(summary["directory_uid"], os.getuid())
            self.assertEqual(summary["directory_mode"], "0755")

    def test_manifest_summary_rejects_symlinked_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_manifest = root / "real-manifest.json"
            real_manifest.write_text(
                '{"created_at":"2000-01-01T00:00:00Z","package":{"label":"Old"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )
            manifest = charts / MANIFEST_NAME
            try:
                manifest.symlink_to(real_manifest)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["path"], str(manifest))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], True)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertIn("manifest path is a symlink", summary["error"])
            self.assertNotIn("created_at", summary)

    def test_manifest_summary_rejects_symlinked_manifest_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_charts = root / "real-charts"
            real_charts.mkdir()
            (real_charts / MANIFEST_NAME).write_text(
                '{"created_at":"2000-01-01T00:00:00Z","package":{"label":"Old"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )
            link_charts = root / "charts-link"
            try:
                link_charts.symlink_to(real_charts, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = report_module._manifest_summary(link_charts)

            self.assertEqual(summary["path"], str(link_charts / MANIFEST_NAME))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], True)
            self.assertEqual(summary["manifest_symlink_component"], str(link_charts))
            self.assertIn("manifest directory is a symlink", summary["error"])
            self.assertNotIn("created_at", summary)

    def test_manifest_summary_rejects_symlinked_manifest_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_root = root / "real-root"
            real_charts = real_root / "charts"
            real_charts.mkdir(parents=True)
            (real_charts / MANIFEST_NAME).write_text(
                '{"created_at":"2000-01-01T00:00:00Z","package":{"label":"Old"},"download":{},"extract":{}}\n',
                encoding="utf-8",
            )
            link_root = root / "root-link"
            try:
                link_root.symlink_to(real_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            charts = link_root / "charts"

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["path"], str(charts / MANIFEST_NAME))
            self.assertEqual(summary["exists"], True)
            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["directory_is_symlink"], False)
            self.assertEqual(summary["manifest_symlink_component"], str(link_root))
            self.assertIn("manifest directory is a symlink", summary["error"])
            self.assertNotIn("created_at", summary)

    def test_manifest_summary_rejects_nonregular_manifest(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            charts = Path(tmpdir) / "charts"
            charts.mkdir()
            manifest = charts / MANIFEST_NAME
            manifest.mkdir()

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["path"], str(manifest))
            self.assertEqual(summary["exists"], True)
            self.assertIn("manifest path is not a regular file", summary["error"])
            self.assertNotIn("created_at", summary)

    def test_manifest_summary_records_owner_and_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            charts = Path(tmpdir) / "charts"
            charts.mkdir()
            extract = charts / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            manifest = charts / MANIFEST_NAME
            manifest.write_text(
                '{"created_at":"2000-01-01T00:00:00Z",'
                '"package":{"label":"Test","filename":"AK_ENCs.zip","url":"file:///test.zip"},'
                '"download":{"path":"","url":"file:///test.zip","bytes":1,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            manifest.chmod(0o640)

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["uid"], os.getuid())
            self.assertEqual(summary["mode"], "0640")
            self.assertEqual(summary["package_filename"], "AK_ENCs.zip")

    def test_manifest_summary_marks_symlinked_recorded_paths(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_archive = root / "real-AK-ENCs.zip"
            real_archive.write_bytes(b"chart")
            archive_link = charts / "AK_ENCs.zip"
            real_extract = root / "real-AK-ENCs"
            cell = real_extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            extract_link = charts / "AK_ENCs"
            try:
                archive_link.symlink_to(real_archive)
                extract_link.symlink_to(real_extract, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (charts / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"created_at_source":"download",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive_link}","url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",'
                '"bytes":5,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{extract_link}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["download_path"], str(archive_link))
            self.assertEqual(summary["download_path_is_symlink"], True)
            self.assertEqual(summary["download_path_symlink_component"], str(archive_link))
            self.assertEqual(summary["extract_path"], str(extract_link))
            self.assertEqual(summary["extract_path_is_symlink"], True)
            self.assertEqual(summary["extract_path_symlink_component"], str(extract_link))

    def test_manifest_summary_marks_nonregular_download_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            archive = charts / "AK_ENCs.zip"
            archive.mkdir()
            extract = charts / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (charts / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"created_at_source":"download",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive}","url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",'
                '"bytes":5,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["download_path"], str(archive))
            self.assertEqual(summary["download_path_exists"], True)
            self.assertIn("manifest download path is not a regular file", summary["download_path_error"])
            self.assertNotIn("download_path_uid", summary)
            self.assertNotIn("download_path_mode", summary)

    def test_manifest_summary_marks_recorded_path_symlink_ancestors(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            real_artifact_root = root / "real-artifacts"
            real_artifact_root.mkdir()
            archive = real_artifact_root / "AK_ENCs.zip"
            archive.write_bytes(b"chart")
            extract = real_artifact_root / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            artifact_link = root / "artifact-link"
            try:
                artifact_link.symlink_to(real_artifact_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            archive_path = artifact_link / "AK_ENCs.zip"
            extract_path = artifact_link / "AK_ENCs"
            (charts / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"created_at_source":"download",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                f'"download":{{"path":"{archive_path}","url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip",'
                '"bytes":5,"sha256":"abc","skipped":false},'
                f'"extract":{{"path":"{extract_path}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )

            summary = report_module._manifest_summary(charts)

            self.assertEqual(summary["is_symlink"], False)
            self.assertEqual(summary["download_path"], str(archive_path))
            self.assertEqual(summary["download_path_is_symlink"], False)
            self.assertEqual(summary["download_path_symlink_component"], str(artifact_link))
            self.assertEqual(summary["extract_path"], str(extract_path))
            self.assertEqual(summary["extract_path_is_symlink"], False)
            self.assertEqual(summary["extract_path_symlink_component"], str(artifact_link))

    def test_track_log_summary_accepts_recent_valid_trackpoint(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertTrue(summary["ok"])
            self.assertEqual(summary["latest_path"], str(track_path))
            self.assertEqual(summary["tracks_mode"], "0700")
            self.assertEqual(summary["latest_mode"], "0600")
            self.assertAlmostEqual(summary["latest_latitude"], 61.2181)
            self.assertAlmostEqual(summary["latest_longitude"], -149.9003)
            self.assertEqual(summary["latest_satellites"], 8)
            self.assertEqual(summary["latest_hdop"], 1.2)
            self.assertTrue(check.ok)
            self.assertIn("61.218100", check.detail)
            self.assertIn("8 satellites", check.detail)

    def test_track_log_summary_rejects_missing_trackpoint_quality(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            track_path = tracks / "track-20260629.gpx"
            track_path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="61.2181" lon="-149.9003">'
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
                "</trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            track_path.chmod(0o600)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("missing satellite or HDOP quality fields", check.detail)

    def test_track_log_summary_rejects_negative_hdop(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            track_path = tracks / "track-20260629.gpx"
            track_path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="61.2181" lon="-149.9003">'
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
                "<hdop>-0.1</hdop>"
                "</trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            track_path.chmod(0o600)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("negative HDOP", check.detail)

    def test_track_log_summary_rejects_public_tracks_directory(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))
            track_path.parent.chmod(0o755)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("permissions are 0755", check.detail)

    def test_track_log_summary_rejects_symlinked_track_output(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            real_output = root / "real-tracks"
            track_path = real_output / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))
            link_output = root / "track-link"
            try:
                link_output.symlink_to(real_output, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = _track_log_summary(
                link_output,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertEqual(summary["track_output"], str(link_output))
            self.assertEqual(summary["track_output_is_symlink"], True)
            self.assertEqual(summary["track_storage_symlink_component"], str(link_output))
            self.assertFalse(check.ok)
            self.assertIn("expected real GPX track storage", check.detail)

    def test_track_log_summary_rejects_symlinked_track_output_ancestor(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            real_root = root / "real-storage"
            real_output = real_root / "noaa-tracks"
            track_path = real_output / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))
            link_root = root / "link-storage"
            try:
                link_root.symlink_to(real_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = _track_log_summary(
                link_root / "noaa-tracks",
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertEqual(summary["track_output"], str(link_root / "noaa-tracks"))
            self.assertEqual(summary["track_output_is_symlink"], False)
            self.assertEqual(summary["track_storage_symlink_component"], str(link_root))
            self.assertFalse(check.ok)
            self.assertIn("expected real GPX track storage", check.detail)

    def test_track_log_summary_rejects_public_track_file(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))
            track_path.chmod(0o644)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("permissions are 0644", check.detail)

    def test_read_trusted_gpx_track_file_rejects_writable_track_file_before_parsing(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            track_path = tracks / "track-20260629.gpx"
            track_path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="61.2181" lon="-149.9003">'
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
                "<sat>8</sat></trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            track_path.chmod(0o622)

            with self.assertRaisesRegex(RuntimeError, "permissions are 0622"):
                _read_trusted_gpx_track_file(track_path, expected_owner=os.getuid())

    def test_track_log_summary_waits_for_delayed_trackpoint(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"

            def write_later():
                time.sleep(0.05)
                with GPXTrackLogger(track_path) as logger:
                    logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))

            writer = threading.Thread(target=write_later)
            writer.start()
            try:
                summary = _track_log_summary(
                    root,
                    now=timestamp + timedelta(seconds=5),
                    boot_epoch=timestamp.timestamp() - 10,
                    wait_seconds=1.0,
                    poll_seconds=0.01,
                )
            finally:
                writer.join()

            self.assertTrue(summary["ok"])
            self.assertEqual(summary["latest_path"], str(track_path))

    def test_track_log_summary_rejects_stale_trackpoint(self):
        timestamp = datetime.now(timezone.utc) - timedelta(seconds=700)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            track_path = root / "tracks" / "track-20260629.gpx"
            with GPXTrackLogger(track_path) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))

            summary = _track_log_summary(root, now=timestamp + timedelta(seconds=700), boot_epoch=None)
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("stale", check.detail)

    def test_track_log_summary_rejects_non_finite_trackpoint_coordinates(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            track_path = tracks / "track-20260629.gpx"
            track_path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<gpx version="1.1" creator="test">\n'
                f'  <trk><trkseg><trkpt lat="NaN" lon="-149.9003">'
                f"<time>{timestamp.isoformat().replace('+00:00', 'Z')}</time>"
                "</trkpt></trkseg></trk>\n"
                "</gpx>\n",
                encoding="utf-8",
            )
            track_path.chmod(0o600)

            summary = _track_log_summary(
                root,
                now=timestamp + timedelta(seconds=5),
                boot_epoch=timestamp.timestamp() - 10,
            )
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("non-finite coordinates", check.detail)

    def test_track_log_summary_rejects_symlinked_track_file(self):
        timestamp = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            tracks = root / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            real_track = root / "real.gpx"
            with GPXTrackLogger(real_track) as logger:
                logger.append(GPSFix(latitude=61.2181, longitude=-149.9003, timestamp=timestamp, satellites=8, hdop=1.2))
            symlink_track = tracks / "track-20260629.gpx"
            try:
                symlink_track.symlink_to(real_track)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            summary = _track_log_summary(root, now=timestamp + timedelta(seconds=5), boot_epoch=None)
            check = _track_log_readiness_check(summary)

            self.assertFalse(summary["ok"])
            self.assertFalse(check.ok)
            self.assertIn("symlink", check.detail)

    def test_write_status_report_does_not_reuse_fixed_part_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / "status.json"
            fixed_part = root / "status.json.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")

            write_status_report({"ok": True}, output)

            self.assertEqual(fixed_part.read_text(encoding="utf-8"), "other writer\n")
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["ok"], True)
            self.assertFalse(list(root.glob(".status.json.*.part")))

    def test_write_status_report_tightens_public_output_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            root.chmod(0o755)
            output = root / "status.json"

            write_status_report({"ok": True}, output)

            self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_write_status_report_tightens_public_home_cache_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            cache_parent = root / ".cache"
            cache_parent.mkdir()
            cache_parent.chmod(0o755)
            old_home = os.environ.get("HOME")
            os.environ["HOME"] = str(root)
            try:
                output = Path("~/.cache/noaa-navionics/status.json")
                write_status_report({"ok": True}, output)
            finally:
                if old_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = old_home

            status_dir = cache_parent / "noaa-navionics"
            status_file = status_dir / "status.json"
            self.assertEqual(stat.S_IMODE(cache_parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(status_dir.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(status_file.stat().st_mode), 0o600)

    def test_write_status_report_rejects_symlinked_output_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_cache = root / "real-cache"
            real_cache.mkdir()
            cache_link = root / ".cache"
            try:
                cache_link.symlink_to(real_cache, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            output = cache_link / "noaa-navionics" / "status.json"

            with self.assertRaisesRegex(RuntimeError, "status report parent directory .* is a symlink"):
                write_status_report({"ok": True}, output)

            self.assertFalse((real_cache / "noaa-navionics").exists())

    def test_write_status_report_rejects_symlinked_output_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_home = root / "real-home"
            real_home.mkdir()
            home_link = root / "home-link"
            try:
                home_link.symlink_to(real_home, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            output = home_link / ".cache" / "noaa-navionics" / "status.json"

            with self.assertRaisesRegex(RuntimeError, "status report parent path contains a symlink"):
                write_status_report({"ok": True}, output)

            self.assertFalse((real_home / ".cache").exists())

    def test_write_status_report_syncs_file_and_directory(self):
        calls = []
        original_fsync = report_module.os.fsync
        report_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                output = Path(tmpdir) / "status.json"
                write_status_report({"ok": True}, output)
        finally:
            report_module.os.fsync = original_fsync

        self.assertGreaterEqual(len(calls), 2)

    def test_write_status_report_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = report_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        report_module.os.open = fake_open
        try:
            report_module._fsync_directory(Path("/tmp"))
        finally:
            report_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], Path("/tmp"))
        self.assertTrue(calls[0][1] & getattr(os, "O_DIRECTORY", 0))
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_install_wanted_by_targets_parse_only_install_section(self):
        targets = _install_wanted_by_targets(
            [
                "[Unit]",
                "WantedBy=wrong.target",
                "[Install]",
                "WantedBy=default.target timers.target",
                ";WantedBy=commented.target",
            ]
        )

        self.assertEqual(targets, ["default.target", "timers.target"])

    def test_install_wanted_by_targets_ignore_missing_install_section(self):
        targets = _install_wanted_by_targets(
            [
                "[Service]",
                "WantedBy=default.target",
            ]
        )

        self.assertEqual(targets, [])

    def test_user_unit_file_summary_rejects_symlinked_unit_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            unit_dir = root / ".config/systemd/user"
            unit_dir.mkdir(parents=True)
            real_unit = root / "real.timer"
            real_unit.write_text("[Install]\nWantedBy=timers.target\n", encoding="utf-8")
            unit_link = unit_dir / "noaa-navionics.timer"
            try:
                unit_link.symlink_to(real_unit)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with patch.dict(os.environ, {"HOME": str(root)}):
                summary = _user_unit_file_summary()

            state = summary["noaa-navionics.timer"]
            self.assertEqual(state["path"], str(unit_link))
            self.assertEqual(state["exists"], True)
            self.assertEqual(state["is_symlink"], True)
            self.assertEqual(state["directory_is_symlink"], False)
            self.assertEqual(state["path_symlink_component"], "")
            self.assertIn("user unit file path is a symlink", state["error"])
            self.assertNotIn("wanted_by", state)

    def test_user_unit_file_summary_rejects_symlinked_unit_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_unit_dir = root / "real-systemd-user"
            real_unit_dir.mkdir()
            real_unit = real_unit_dir / "noaa-navionics.timer"
            real_unit.write_text("[Install]\nWantedBy=timers.target\n", encoding="utf-8")
            config_dir = root / ".config/systemd"
            config_dir.mkdir(parents=True)
            unit_dir = config_dir / "user"
            try:
                unit_dir.symlink_to(real_unit_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with patch.dict(os.environ, {"HOME": str(root)}):
                summary = _user_unit_file_summary()

            state = summary["noaa-navionics.timer"]
            self.assertEqual(state["path"], str(unit_dir / "noaa-navionics.timer"))
            self.assertEqual(state["exists"], True)
            self.assertEqual(state["is_symlink"], False)
            self.assertEqual(state["directory_is_symlink"], True)
            self.assertEqual(state["path_symlink_component"], str(unit_dir))
            self.assertIn("user unit file directory is a symlink", state["error"])
            self.assertNotIn("wanted_by", state)

    def test_user_unit_file_summary_rejects_symlinked_unit_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_home = root / "real-home"
            unit_dir = real_home / ".config/systemd/user"
            unit_dir.mkdir(parents=True)
            real_unit = unit_dir / "noaa-navionics.timer"
            real_unit.write_text("[Install]\nWantedBy=timers.target\n", encoding="utf-8")
            link_home = root / "home-link"
            try:
                link_home.symlink_to(real_home, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with patch.dict(os.environ, {"HOME": str(link_home)}):
                summary = _user_unit_file_summary()

            state = summary["noaa-navionics.timer"]
            self.assertEqual(state["path"], str(link_home / ".config/systemd/user/noaa-navionics.timer"))
            self.assertEqual(state["exists"], True)
            self.assertEqual(state["is_symlink"], False)
            self.assertEqual(state["directory_is_symlink"], False)
            self.assertEqual(state["path_symlink_component"], str(link_home))
            self.assertIn("user unit file directory is a symlink", state["error"])
            self.assertNotIn("wanted_by", state)

    def test_user_unit_file_summary_records_owner_and_permissions(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            unit_dir = root / ".config/systemd/user"
            unit_dir.mkdir(parents=True)
            os.chmod(unit_dir, 0o700)
            unit_file = unit_dir / "noaa-navionics.timer"
            unit_file.write_text("[Install]\nWantedBy=timers.target\n", encoding="utf-8")
            os.chmod(unit_file, 0o600)

            with patch.dict(os.environ, {"HOME": str(root)}):
                summary = _user_unit_file_summary()

            state = summary["noaa-navionics.timer"]
            self.assertEqual(state["uid"], os.getuid())
            self.assertEqual(state["mode"], "0600")
            self.assertEqual(state["directory_uid"], os.getuid())
            self.assertEqual(state["directory_mode"], "0700")
            self.assertEqual(state["wanted_by"], ["timers.target"])

    def test_user_unit_file_summary_rejects_writable_unit_file_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            unit_dir = root / ".config/systemd/user"
            unit_dir.mkdir(parents=True)
            os.chmod(unit_dir, 0o700)
            unit_file = unit_dir / "noaa-navionics.timer"
            unit_file.write_text("[Install]\nWantedBy=timers.target\n", encoding="utf-8")
            os.chmod(unit_file, 0o622)

            with patch.dict(os.environ, {"HOME": str(root)}):
                summary = _user_unit_file_summary()

            state = summary["noaa-navionics.timer"]
            self.assertIn("has permissions 0622", state["error"])
            self.assertIn("expected no group/other write bits", state["error"])
            self.assertNotIn("wanted_by", state)

    def test_service_readiness_checks_accept_expected_onboard_units(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")

        self.assertTrue(all(check.ok for check in checks))
        self.assertIn("Chart Sync", [check.name for check in checks])

    def test_service_readiness_checks_accept_expected_loaded_unit_properties(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "inactive",
                "properties": {
                    "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics.service",
                    "ExecStartPre": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300 ; }",
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics sync-charts --config /home/pi/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30 ; }",
                    "Type": "oneshot",
                    "TimeoutStartUSec": "2h",
                    "Restart": "on-failure",
                    "RestartUSec": "30min",
                    "StartLimitIntervalUSec": "6h",
                    "StartLimitBurst": "3",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                    "UMask": "0077",
                },
            },
            "noaa-navionics.timer": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics.timer",
                    "TimersCalendar": "{ OnCalendar=weekly ; NextElapseUSecRealtime=Mon 2026-07-06 00:00:00 UTC }",
                    "Persistent": "yes",
                    "RandomizedDelayUSec": "30min",
                },
            },
            "noaa-navionics-track.service": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics log-track --config /home/pi/.config/noaa-navionics/config.ini --rotate-daily ; }",
                    "Type": "simple",
                    "StandardOutput": "null",
                    "Restart": "on-failure",
                    "RestartUSec": "10s",
                    "StartLimitIntervalUSec": "10min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                    "UMask": "0077",
                },
            },
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "FragmentPath": "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                    "Wants": "noaa-navionics-track.service",
                    "After": "noaa-navionics-track.service basic.target",
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds 60 --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Type": "oneshot",
                    "Environment": "NOAA_NAVIONICS_GPS_SECONDS=60",
                    "EnvironmentFiles": "/home/pi/.config/noaa-navionics/launcher.env",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                    "UMask": "0077",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.service",
                [],
            ),
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        settings_checks = [check for check in checks if check.name.endswith("Settings")]
        run_check = next(check for check in checks if check.name == "Boot Readiness Run")

        self.assertEqual(len(settings_checks), 4)
        self.assertTrue(all(check.ok for check in settings_checks))
        self.assertTrue(run_check.ok)

    def test_service_readiness_checks_fail_stale_loaded_unit_fragment_path(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "inactive",
                "properties": {
                    "FragmentPath": "/tmp/noaa-navionics.service",
                    "ExecStartPre": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300 ; }",
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics sync-charts --config /home/pi/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30 ; }",
                    "Type": "oneshot",
                    "TimeoutStartUSec": "2h",
                    "Restart": "on-failure",
                    "RestartUSec": "30min",
                    "StartLimitIntervalUSec": "6h",
                    "StartLimitBurst": "3",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.service",
                [],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        chart_settings = next(check for check in checks if check.name == "Chart Sync Settings")

        self.assertFalse(chart_settings.ok)
        self.assertIn("FragmentPath=/tmp/noaa-navionics.service", chart_settings.detail)
        self.assertIn("expected /home/pi/.config/systemd/user/noaa-navionics.service", chart_settings.detail)

    def test_service_readiness_checks_accept_unit_file_install_targets(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        install_checks = [check for check in checks if check.name.endswith("Install")]

        self.assertEqual(len(install_checks), 3)
        self.assertTrue(all(check.ok for check in install_checks))

    def test_service_readiness_checks_fail_public_unit_file_permissions(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
                mode="0666",
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("mode=0666", timer_install.detail)
        self.assertIn("expected no group/other write bits", timer_install.detail)

    def test_service_readiness_checks_fail_public_unit_directory_permissions(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
                directory_mode="0777",
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("directory_mode=0777", timer_install.detail)
        self.assertIn("expected no group/other write bits", timer_install.detail)

    def test_service_readiness_checks_fail_misowned_unit_file(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unexpected_uid = os.getuid() + 1
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
                uid=unexpected_uid,
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn(f"uid={unexpected_uid}", timer_install.detail)
        self.assertIn(f"expected {os.getuid()}", timer_install.detail)

    def test_service_readiness_checks_fail_symlinked_unit_file_install_target(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": {
                "path": "/home/pi/.config/systemd/user/noaa-navionics.timer",
                "exists": True,
                "is_symlink": True,
            },
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("unit file path is a symlink", timer_install.detail)

    def test_service_readiness_checks_fail_symlinked_unit_file_directory(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
                directory_is_symlink=True,
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("unit file directory is a symlink", timer_install.detail)

    def test_service_readiness_checks_fail_symlinked_unit_file_ancestor(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["timers.target"],
                path_symlink_component="/home/pi",
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("unit file path contains a symlink: /home/pi", timer_install.detail)

    def test_launcher_settings_check_accepts_fail_closed_settings(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "is_symlink": False,
                "mode": "0600",
                "values": {
                    "NOAA_NAVIONICS_GPS_SECONDS": "30",
                    "NOAA_NAVIONICS_READINESS_ATTEMPTS": "3",
                    "NOAA_NAVIONICS_READINESS_RETRY_DELAY": "10",
                    "NOAA_NAVIONICS_WARNING_SECONDS": "8",
                    "NOAA_NAVIONICS_OPENCPN_RESTARTS": "3",
                    "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY": "5",
                    "NOAA_NAVIONICS_START_ON_FAILED_READINESS": "no",
                },
            }
        )

        self.assertTrue(check.ok)
        self.assertIn("fail-closed", check.detail)

    def test_launcher_settings_check_fails_public_environment(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "is_symlink": False,
                "mode": "0644",
                "values": {"NOAA_NAVIONICS_GPS_SECONDS": "30"},
            }
        )

        self.assertFalse(check.ok)
        self.assertIn("expected private 0600", check.detail)

    def test_launcher_settings_check_fails_symlinked_environment(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "is_symlink": True,
                "values": {"NOAA_NAVIONICS_GPS_SECONDS": "30"},
            }
        )

        self.assertFalse(check.ok)
        self.assertIn("launcher environment path is a symlink", check.detail)

    def test_launcher_settings_check_fails_symlinked_environment_directory(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "is_symlink": False,
                "directory_is_symlink": True,
                "values": {"NOAA_NAVIONICS_GPS_SECONDS": "30"},
            }
        )

        self.assertFalse(check.ok)
        self.assertIn("launcher environment directory is a symlink", check.detail)

    def test_launcher_settings_check_fails_fail_open_override(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "values": {
                    "NOAA_NAVIONICS_GPS_SECONDS": "30",
                    "NOAA_NAVIONICS_START_ON_FAILED_READINESS": "yes",
                },
            }
        )

        self.assertFalse(check.ok)
        self.assertIn("START_ON_FAILED_READINESS is enabled", check.detail)

    def test_launcher_settings_check_fails_invalid_optional_timing_values(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "values": {
                    "NOAA_NAVIONICS_GPS_SECONDS": "30",
                    "NOAA_NAVIONICS_WARNING_SECONDS": "soon",
                    "NOAA_NAVIONICS_OPENCPN_RESTARTS": "-1",
                    "NOAA_NAVIONICS_OPENCPN_RESTART_DELAY": "soon",
                },
            }
        )

        self.assertFalse(check.ok)
        self.assertIn("NOAA_NAVIONICS_WARNING_SECONDS=soon expected non-negative integer", check.detail)
        self.assertIn("NOAA_NAVIONICS_OPENCPN_RESTARTS=-1 expected non-negative integer", check.detail)
        self.assertIn("NOAA_NAVIONICS_OPENCPN_RESTART_DELAY=soon expected non-negative integer", check.detail)

    def test_launcher_settings_check_fails_missing_gps_wait(self):
        check = _launcher_settings_check(
            {
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "values": {},
            }
        )

        self.assertFalse(check.ok)
        self.assertIn("NOAA_NAVIONICS_GPS_SECONDS=<missing>", check.detail)

    def test_service_readiness_checks_include_launcher_settings(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            launcher_settings={
                "path": "/home/pi/.config/noaa-navionics/launcher.env",
                "exists": True,
                "values": {
                    "NOAA_NAVIONICS_GPS_SECONDS": "10",
                    "NOAA_NAVIONICS_START_ON_FAILED_READINESS": "yes",
                },
            },
            gps_mode="gpsd",
        )
        launcher_check = next(check for check in checks if check.name == "Launcher Settings")

        self.assertFalse(launcher_check.ok)
        self.assertIn("START_ON_FAILED_READINESS is enabled", launcher_check.detail)

    def test_service_readiness_checks_include_user_linger(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            user={"name": "pi", "uid": 1000, "linger": "no"},
            gps_mode="gpsd",
        )
        linger_check = next(check for check in checks if check.name == "User Linger")

        self.assertFalse(linger_check.ok)
        self.assertIn("linger=no", linger_check.detail)

    def test_service_readiness_checks_include_desktop_startup(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {"path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop", "exists": False},
                "lightdm_autologin": {"path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf", "exists": False},
                "graphical_target": "multi-user.target",
                "lightdm_enabled": "disabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart missing", desktop_check.detail)
        self.assertIn("systemd default target is multi-user.target", desktop_check.detail)
        self.assertIn("lightdm.service is disabled", desktop_check.detail)

    def test_service_readiness_checks_fail_symlinked_desktop_startup_files(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {
                    "path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop",
                    "exists": True,
                    "is_symlink": True,
                },
                "lightdm_autologin": {
                    "path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf",
                    "exists": True,
                    "is_symlink": True,
                },
                "graphical_target": "graphical.target",
                "lightdm_enabled": "enabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart path is a symlink", desktop_check.detail)
        self.assertIn("LightDM autologin config path is a symlink", desktop_check.detail)

    def test_service_readiness_checks_fail_symlinked_desktop_startup_directories(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {
                    "path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": True,
                    "values": {
                        "Type": "Application",
                        "Name": "NOAA Navionics Chartplotter",
                        "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
                        "Terminal": "false",
                        "X-GNOME-Autostart-enabled": "true",
                    },
                },
                "lightdm_autologin": {
                    "path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": True,
                    "sections": ["Seat:*"],
                    "values": {
                        "autologin-user": "pi",
                        "autologin-user-timeout": "0",
                        "autologin-session": "LXDE-pi",
                    },
                },
                "graphical_target": "graphical.target",
                "lightdm_enabled": "enabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart directory is a symlink", desktop_check.detail)
        self.assertIn("LightDM autologin config directory is a symlink", desktop_check.detail)

    def test_service_readiness_checks_fail_symlinked_desktop_startup_ancestors(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {
                    "path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": False,
                    "path_symlink_component": "/home/pi",
                    "values": {
                        "Type": "Application",
                        "Name": "NOAA Navionics Chartplotter",
                        "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
                        "Terminal": "false",
                        "X-GNOME-Autostart-enabled": "true",
                    },
                },
                "lightdm_autologin": {
                    "path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": False,
                    "path_symlink_component": "/etc/lightdm",
                    "sections": ["Seat:*"],
                    "values": {
                        "autologin-user": "pi",
                        "autologin-user-timeout": "0",
                        "autologin-session": "LXDE-pi",
                    },
                },
                "graphical_target": "graphical.target",
                "lightdm_enabled": "enabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart path contains a symlink: /home/pi", desktop_check.detail)
        self.assertIn("LightDM autologin config path contains a symlink: /etc/lightdm", desktop_check.detail)

    def test_service_readiness_checks_fail_unsafe_desktop_startup_files(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(
            services,
            system_services,
            desktop={
                "autostart": {
                    "path": "/home/pi/.config/autostart/noaa-navionics-chartplotter.desktop",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": False,
                    "uid": os.getuid() + 1,
                    "mode": "0666",
                    "values": {
                        "Type": "Application",
                        "Name": "NOAA Navionics Chartplotter",
                        "Exec": 'sh -lc "$HOME/.local/bin/noaa-navionics-start-chartplotter"',
                        "Terminal": "false",
                        "X-GNOME-Autostart-enabled": "true",
                    },
                },
                "lightdm_autologin": {
                    "path": "/etc/lightdm/lightdm.conf.d/50-noaa-navionics-autologin.conf",
                    "exists": True,
                    "is_symlink": False,
                    "directory_is_symlink": False,
                    "uid": os.getuid() + 1,
                    "mode": "0666",
                    "sections": ["Seat:*"],
                    "values": {
                        "autologin-user": "pi",
                        "autologin-user-timeout": "0",
                        "autologin-session": "LXDE-pi",
                    },
                },
                "graphical_target": "graphical.target",
                "lightdm_enabled": "enabled",
            },
            gps_mode="gpsd",
        )
        desktop_check = next(check for check in checks if check.name == "Desktop Startup")

        self.assertFalse(desktop_check.ok)
        self.assertIn("desktop autostart is owned by uid", desktop_check.detail)
        self.assertIn("desktop autostart has permissions 0666", desktop_check.detail)
        self.assertIn("LightDM autologin config is owned by uid", desktop_check.detail)
        self.assertIn("LightDM autologin config has permissions 0666", desktop_check.detail)

    def test_service_readiness_checks_fail_stale_unit_file_install_target(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }
        unit_files = {
            "noaa-navionics.timer": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics.timer",
                ["default.target"],
            ),
            "noaa-navionics-track.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-track.service",
                ["default.target"],
            ),
            "noaa-navionics-preflight.service": trusted_unit_file(
                "/home/pi/.config/systemd/user/noaa-navionics-preflight.service",
                ["default.target"],
            ),
        }

        checks = _service_readiness_checks(services, system_services, unit_files=unit_files, gps_mode="gpsd")
        timer_install = next(check for check in checks if check.name == "Chart Timer Install")

        self.assertFalse(timer_install.ok)
        self.assertIn("WantedBy=default.target", timer_install.detail)
        self.assertIn("expected timers.target", timer_install.detail)

    def test_service_readiness_checks_fail_missing_loaded_unit_hardening(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "inactive",
                "properties": {
                    "ExecStartPre": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300 ; }",
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics sync-charts --config /home/pi/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30 ; }",
                    "Type": "oneshot",
                    "TimeoutStartUSec": "2h",
                    "Restart": "on-failure",
                    "RestartUSec": "30min",
                    "StartLimitIntervalUSec": "6h",
                    "StartLimitBurst": "3",
                    "NoNewPrivileges": "no",
                    "PrivateTmp": "no",
                },
            },
            "noaa-navionics.timer": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "TimersCalendar": "{ OnCalendar=weekly ; NextElapseUSecRealtime=Mon 2026-07-06 00:00:00 UTC }",
                    "Persistent": "yes",
                    "RandomizedDelayUSec": "30min",
                },
            },
            "noaa-navionics-track.service": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics log-track --config /home/pi/.config/noaa-navionics/config.ini --rotate-daily ; }",
                    "Type": "simple",
                    "StandardOutput": "null",
                    "Restart": "on-failure",
                    "RestartUSec": "10s",
                    "StartLimitIntervalUSec": "10min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                    "UMask": "0077",
                },
            },
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds 60 --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Type": "oneshot",
                    "EnvironmentFiles": "/home/pi/.config/noaa-navionics/launcher.env",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        chart_settings = next(check for check in checks if check.name == "Chart Sync Settings")

        self.assertFalse(chart_settings.ok)
        self.assertIn("NoNewPrivileges=no", chart_settings.detail)
        self.assertIn("PrivateTmp=no", chart_settings.detail)

    def test_service_readiness_checks_fail_stale_loaded_track_settings(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "Type": "oneshot",
                    "StandardOutput": "journal",
                    "Restart": "no",
                    "RestartUSec": "100ms",
                    "StartLimitIntervalUSec": "10min",
                    "StartLimitBurst": "60",
                },
            },
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        track_settings = next(check for check in checks if check.name == "Track Logger Settings")

        self.assertFalse(track_settings.ok)
        self.assertIn("Type=oneshot", track_settings.detail)
        self.assertIn("StandardOutput=journal", track_settings.detail)
        self.assertIn("Restart=no", track_settings.detail)

    def test_service_readiness_checks_fail_stale_loaded_boot_readiness_restart(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "Type": "simple",
                    "TimeoutStartUSec": "90s",
                    "Restart": "no",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "5min",
                    "StartLimitBurst": "5",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        boot_settings = next(check for check in checks if check.name == "Boot Readiness Settings")

        self.assertFalse(boot_settings.ok)
        self.assertIn("Type=simple", boot_settings.detail)
        self.assertIn("TimeoutStartUSec=90s", boot_settings.detail)
        self.assertIn("Restart=no", boot_settings.detail)

    def test_service_readiness_checks_fail_stale_boot_readiness_gps_wait_default(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds 60 --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Type": "oneshot",
                    "Environment": "NOAA_NAVIONICS_GPS_SECONDS=2",
                    "EnvironmentFiles": "/home/pi/.config/noaa-navionics/launcher.env",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        boot_settings = next(check for check in checks if check.name == "Boot Readiness Settings")

        self.assertFalse(boot_settings.ok)
        self.assertIn("Environment=NOAA_NAVIONICS_GPS_SECONDS=2", boot_settings.detail)
        self.assertIn("missing NOAA_NAVIONICS_GPS_SECONDS=60", boot_settings.detail)

    def test_service_readiness_checks_fail_missing_boot_readiness_track_ordering(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds 60 --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Type": "oneshot",
                    "Environment": "NOAA_NAVIONICS_GPS_SECONDS=60",
                    "EnvironmentFiles": "/home/pi/.config/noaa-navionics/launcher.env",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        boot_settings = next(check for check in checks if check.name == "Boot Readiness Settings")

        self.assertFalse(boot_settings.ok)
        self.assertIn("Wants=<missing> missing noaa-navionics-track.service", boot_settings.detail)
        self.assertIn("After=<missing> missing noaa-navionics-track.service", boot_settings.detail)

    def test_service_readiness_checks_fail_boot_readiness_never_ran(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "Type": "oneshot",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "0",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        run_check = next(check for check in checks if check.name == "Boot Readiness Run")

        self.assertFalse(run_check.ok)
        self.assertIn("ExecMainStartTimestampMonotonic=0", run_check.detail)

    def test_service_readiness_checks_fail_boot_readiness_exit_status(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "Type": "oneshot",
                    "Result": "exit-code",
                    "ExecMainStatus": "1",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        run_check = next(check for check in checks if check.name == "Boot Readiness Run")

        self.assertFalse(run_check.ok)
        self.assertIn("Result=exit-code", run_check.detail)
        self.assertIn("ExecMainStatus=1", run_check.detail)

    def test_service_readiness_checks_accept_boot_readiness_running_self_report(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "activating",
                "properties": {
                    "Type": "oneshot",
                    "Result": "",
                    "ExecMainStatus": "",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        run_check = next(check for check in checks if check.name == "Boot Readiness Run")

        self.assertTrue(run_check.ok)
        self.assertIn("active=activating", run_check.detail)
        self.assertIn("ExecMainStartTimestampMonotonic=123456789", run_check.detail)

    def test_service_readiness_checks_fail_loaded_command_missing_args(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ argv[]=/home/pi/.local/bin/noaa-navionics sync-charts ; }",
                    "Type": "oneshot",
                    "TimeoutStartUSec": "2h",
                    "Restart": "on-failure",
                    "RestartUSec": "30min",
                    "StartLimitIntervalUSec": "6h",
                    "StartLimitBurst": "3",
                },
            },
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        chart_settings = next(check for check in checks if check.name == "Chart Sync Settings")

        self.assertFalse(chart_settings.ok)
        self.assertIn("ExecStartPre=<missing>", chart_settings.detail)
        self.assertIn("missing noaa-navionics wait-network", chart_settings.detail)
        self.assertIn("missing --config", chart_settings.detail)
        self.assertIn("missing --retries 5", chart_settings.detail)

    def test_service_readiness_checks_fail_loaded_command_wrong_path(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "inactive",
                "properties": {
                    "ExecStartPre": "{ path=/tmp/noaa-navionics ; argv[]=/tmp/noaa-navionics wait-network --host www.charts.noaa.gov --port 443 --seconds 300 ; }",
                    "ExecStart": "{ path=/tmp/noaa-navionics ; argv[]=/tmp/noaa-navionics sync-charts --config /home/pi/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30 ; }",
                    "Type": "oneshot",
                    "TimeoutStartUSec": "2h",
                    "Restart": "on-failure",
                    "RestartUSec": "30min",
                    "StartLimitIntervalUSec": "6h",
                    "StartLimitBurst": "3",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                    "UMask": "0077",
                },
            },
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "ExecStart": "{ path=/tmp/noaa-navionics ; argv[]=/tmp/noaa-navionics log-track --config /home/pi/.config/noaa-navionics/config.ini --rotate-daily ; }",
                    "Type": "simple",
                    "StandardOutput": "null",
                    "Restart": "on-failure",
                    "RestartUSec": "10s",
                    "StartLimitIntervalUSec": "10min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                    "UMask": "0077",
                },
            },
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ path=/tmp/noaa-navionics ; argv[]=/tmp/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds 60 --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Wants": "noaa-navionics-track.service",
                    "After": "noaa-navionics-track.service",
                    "Type": "oneshot",
                    "Environment": "NOAA_NAVIONICS_GPS_SECONDS=60",
                    "EnvironmentFiles": "/home/pi/.config/noaa-navionics/launcher.env",
                    "Result": "success",
                    "ExecMainStatus": "0",
                    "ExecMainStartTimestampMonotonic": "123456789",
                    "TimeoutStartUSec": "infinity",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "30min",
                    "StartLimitBurst": "60",
                    "NoNewPrivileges": "yes",
                    "PrivateTmp": "yes",
                    "ProtectSystem": "full",
                    "UMask": "0077",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        chart_settings = next(check for check in checks if check.name == "Chart Sync Settings")
        track_settings = next(check for check in checks if check.name == "Track Logger Settings")
        boot_settings = next(check for check in checks if check.name == "Boot Readiness Settings")

        self.assertFalse(chart_settings.ok)
        self.assertIn("missing .local/bin/noaa-navionics", chart_settings.detail)
        self.assertFalse(track_settings.ok)
        self.assertIn("missing .local/bin/noaa-navionics", track_settings.detail)
        self.assertFalse(boot_settings.ok)
        self.assertIn("missing .local/bin/noaa-navionics", boot_settings.detail)

    def test_service_readiness_checks_fail_disabled_chart_timer(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "disabled", "active": "inactive"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        timer_check = next(check for check in checks if check.name == "Chart Timer")

        self.assertFalse(timer_check.ok)
        self.assertIn("disabled", timer_check.detail)

    def test_service_readiness_checks_allow_failed_chart_sync_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "failed"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        sync_check = next(check for check in checks if check.name == "Chart Sync")

        self.assertTrue(sync_check.ok)
        self.assertIn("manifest freshness", sync_check.detail)

    def test_service_readiness_checks_fail_disabled_chart_sync_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "disabled", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        sync_check = next(check for check in checks if check.name == "Chart Sync")

        self.assertFalse(sync_check.ok)
        self.assertIn("disabled", sync_check.detail)

    def test_service_readiness_checks_fail_missing_chart_sync_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "not-found", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        sync_check = next(check for check in checks if check.name == "Chart Sync")

        self.assertFalse(sync_check.ok)
        self.assertIn("not-found", sync_check.detail)

    def test_service_readiness_checks_fail_chart_sync_query_error(self):
        services = {
            "available": True,
            "noaa-navionics.service": {
                "enabled": "static",
                "active": "error: Failed to connect to bus",
            },
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        sync_check = next(check for check in checks if check.name == "Chart Sync")

        self.assertFalse(sync_check.ok)
        self.assertIn("Failed to connect", sync_check.detail)

    def test_service_readiness_checks_fail_missing_unit_query_result(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "not-found", "active": "unknown"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        timer_check = next(check for check in checks if check.name == "Chart Timer")

        self.assertFalse(timer_check.ok)
        self.assertIn("not-found", timer_check.detail)

    def test_service_readiness_checks_fail_failed_boot_readiness_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "failed"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        boot_check = next(check for check in checks if check.name == "Boot Readiness")

        self.assertFalse(boot_check.ok)
        self.assertIn("failed", boot_check.detail)

    def test_service_readiness_checks_fail_inactive_track_logger(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "inactive"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        track_check = next(check for check in checks if check.name == "Track Logger")

        self.assertFalse(track_check.ok)
        self.assertIn("inactive", track_check.detail)

    def test_service_readiness_checks_fail_disabled_gpsd_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "disabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        gpsd_check = next(check for check in checks if check.name == "GPSD Service")

        self.assertFalse(gpsd_check.ok)
        self.assertIn("disabled", gpsd_check.detail)

    def test_service_readiness_checks_fail_disabled_gpsd_socket(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "disabled", "active": "inactive"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        gpsd_socket_check = next(check for check in checks if check.name == "GPSD Socket")

        self.assertFalse(gpsd_socket_check.ok)
        self.assertIn("disabled", gpsd_socket_check.detail)

    def test_service_readiness_checks_fail_disabled_chrony_service(self):
        services = {
            "available": True,
            "noaa-navionics.service": {"enabled": "static", "active": "inactive"},
            "noaa-navionics.timer": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-track.service": {"enabled": "enabled", "active": "active"},
            "noaa-navionics-preflight.service": {"enabled": "enabled", "active": "inactive"},
        }
        system_services = {
            "available": True,
            "gpsd.socket": {"enabled": "enabled", "active": "active"},
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "disabled", "active": "inactive"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        chrony_check = next(check for check in checks if check.name == "Chrony Service")

        self.assertFalse(chrony_check.ok)
        self.assertIn("disabled", chrony_check.detail)


class GpsTests(unittest.TestCase):
    def _trusted_gps_device_patch(self):
        return patch(
            "noaa_navionics.health.check_gps_device_path",
            return_value=health_module.CheckResult(
                "GPS Device",
                True,
                "/dev/serial/by-id/mock-gps -> /dev/ttyACM0",
            ),
        )

    def test_parse_gga_sentence(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47"
        fix = parse_nmea_sentence(sentence)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertAlmostEqual(fix.latitude, 48.1173, places=4)
        self.assertAlmostEqual(fix.longitude, 11.5166667, places=4)
        self.assertEqual(fix.satellites, 8)
        self.assertEqual(fix.altitude_m, 545.4)

    def test_iter_fixes_rejects_gga_without_fix_quality(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,,08,0.9,545.4,M,46.9,M,,"
        fix = parse_nmea_sentence(sentence)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertIsNone(fix.fix_quality)
        self.assertFalse(fix.valid)
        self.assertEqual(list(iter_fixes([sentence])), [])

    def test_iter_fixes_rejects_gga_with_malformed_fix_quality(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,bad,08,0.9,545.4,M,46.9,M,,"
        fix = parse_nmea_sentence(sentence)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertIsNone(fix.fix_quality)
        self.assertFalse(fix.valid)
        self.assertEqual(list(iter_fixes([sentence])), [])

    def test_parse_nmea_ignores_non_finite_optional_numbers(self):
        gga = "$GPGGA,123519,4807.038,N,01131.000,E,1,NaN,Infinity,-Infinity,M,46.9,M,,"
        rmc = "$GPRMC,123519,A,4807.038,N,01131.000,E,NaN,Infinity,230394,003.1,W"

        gga_fix = parse_nmea_sentence(gga)
        rmc_fix = parse_nmea_sentence(rmc)

        self.assertIsNotNone(gga_fix)
        self.assertIsNotNone(rmc_fix)
        assert gga_fix is not None
        assert rmc_fix is not None
        self.assertIsNone(gga_fix.satellites)
        self.assertIsNone(gga_fix.hdop)
        self.assertIsNone(gga_fix.altitude_m)
        self.assertIsNone(rmc_fix.speed_knots)
        self.assertIsNone(rmc_fix.course_degrees)

    def test_parse_nmea_drops_impossible_optional_quality_and_motion(self):
        gga = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,-0.1,545.4,M,46.9,M,,"
        rmc = "$GPRMC,123519,A,4807.038,N,01131.000,E,-1.0,361.0,230394,003.1,W"

        gga_fix = parse_nmea_sentence(gga)
        rmc_fix = parse_nmea_sentence(rmc)

        self.assertIsNotNone(gga_fix)
        self.assertIsNotNone(rmc_fix)
        assert gga_fix is not None
        assert rmc_fix is not None
        self.assertIsNone(gga_fix.hdop)
        self.assertIsNone(rmc_fix.speed_knots)
        self.assertIsNone(rmc_fix.course_degrees)

    def test_gga_time_without_date_uses_nearest_utc_day(self):
        before_midnight = _parse_time_today("000010", now=datetime(2026, 6, 29, 23, 59, 50, tzinfo=timezone.utc))
        after_midnight = _parse_time_today("235950", now=datetime(2026, 6, 30, 0, 0, 10, tzinfo=timezone.utc))

        self.assertEqual(before_midnight, datetime(2026, 6, 30, 0, 0, 10, tzinfo=timezone.utc))
        self.assertEqual(after_midnight, datetime(2026, 6, 29, 23, 59, 50, tzinfo=timezone.utc))

    def test_gga_fractional_time_rounds_across_midnight(self):
        rounded = _parse_time_today("235959.9999999", now=datetime(2026, 6, 29, 23, 59, 59, tzinfo=timezone.utc))

        self.assertEqual(rounded, datetime(2026, 6, 30, 0, 0, 0, tzinfo=timezone.utc))

    def test_parse_gga_malformed_time_is_untimestamped(self):
        for time_value in ("badtime", "NaN000", "-123519"):
            with self.subTest(time_value=time_value):
                fix = parse_nmea_sentence(
                    f"$GPGGA,{time_value},4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
                )

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertIsNone(fix.timestamp)
                self.assertTrue(fix.valid)

    def test_parse_gga_rejects_impossible_time_fields(self):
        for time_value in ("240000", "236000", "235960", "126000"):
            with self.subTest(time_value=time_value):
                fix = parse_nmea_sentence(
                    f"$GPGGA,{time_value},4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
                )

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertIsNone(fix.timestamp)
                self.assertTrue(fix.valid)

    def test_parse_rmc_sentence(self):
        sentence = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A"
        fix = parse_nmea_sentence(sentence)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.timestamp.year, 1994)
        self.assertEqual(fix.speed_knots, 22.4)
        self.assertEqual(fix.course_degrees, 84.4)

    def test_parse_rmc_accepts_navigation_mode_fix(self):
        for mode in ("A", "D", "F", "P", "R"):
            with self.subTest(mode=mode):
                sentence = f"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,290626,,,{mode}"
                fix = parse_nmea_sentence(sentence)

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertTrue(fix.valid)

    def test_parse_rmc_rejects_non_navigation_mode_fix(self):
        for mode in ("E", "M", "N", "S", "X"):
            with self.subTest(mode=mode):
                sentence = f"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,290626,,,{mode}"

                self.assertIsNone(parse_nmea_sentence(sentence))
                self.assertEqual(list(iter_fixes([sentence])), [])

    def test_parse_rmc_fractional_time_rounds_across_date(self):
        sentence = "$GPRMC,235959.9999999,A,4807.038,N,01131.000,E,0.0,0.0,290626,003.1,W"
        fix = parse_nmea_sentence(sentence)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.timestamp, datetime(2026, 6, 30, 0, 0, 0, tzinfo=timezone.utc))

    def test_parse_rmc_malformed_timestamp_is_untimestamped(self):
        for time_value, date_value in (
            ("badtime", "230394"),
            ("123519", "badate"),
            ("123519", "310226"),
            ("NaN000", "230394"),
            ("-123519", "230394"),
        ):
            with self.subTest(time_value=time_value, date_value=date_value):
                fix = parse_nmea_sentence(
                    f"$GPRMC,{time_value},A,4807.038,N,01131.000,E,022.4,084.4,{date_value},003.1,W"
                )

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertIsNone(fix.timestamp)
                self.assertTrue(fix.valid)

    def test_parse_rmc_rejects_impossible_time_fields(self):
        for time_value in ("240000", "236000", "235960", "126000"):
            with self.subTest(time_value=time_value):
                fix = parse_nmea_sentence(
                    f"$GPRMC,{time_value},A,4807.038,N,01131.000,E,022.4,084.4,290626,003.1,W"
                )

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertIsNone(fix.timestamp)
                self.assertTrue(fix.valid)

    def test_parse_nmea_rejects_bad_coordinate_hemispheres(self):
        gga = parse_nmea_sentence("$GPGGA,123519,4807.038,X,01131.000,E,1,08,0.9,545.4,M,46.9,M,,")
        rmc = parse_nmea_sentence("$GPRMC,123519,A,4807.038,N,01131.000,X,022.4,084.4,230394,003.1,W")

        self.assertIsNone(gga)
        self.assertIsNone(rmc)
        self.assertEqual(
            list(
                iter_fixes(
                    [
                        "$GPGGA,123519,4807.038,X,01131.000,E,1,08,0.9,545.4,M,46.9,M,,",
                        "$GPRMC,123519,A,4807.038,N,01131.000,X,022.4,084.4,230394,003.1,W",
                    ]
                )
            ),
            [],
        )

    def test_parse_nmea_rejects_malformed_coordinate_numbers(self):
        bad_minutes = "$GPGGA,123519,4867.000,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
        bad_number = "$GPRMC,123519,A,48XX.038,N,01131.000,E,022.4,084.4,230394,003.1,W"

        self.assertIsNone(parse_nmea_sentence(bad_minutes))
        self.assertIsNone(parse_nmea_sentence(bad_number))
        self.assertEqual(list(iter_fixes([bad_minutes, bad_number])), [])

    def test_parse_nmea_rejects_impossible_coordinate_values(self):
        bad_latitude = "$GPGGA,123519,9100.000,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
        bad_longitude = "$GPRMC,123519,A,4807.038,N,18100.000,W,022.4,084.4,230394,003.1,W"
        negative_degrees = "$GPGGA,123519,-100.000,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
        non_finite = "$GPRMC,123519,A,48NaN,N,01131.000,E,022.4,084.4,230394,003.1,W"

        self.assertIsNone(parse_nmea_sentence(bad_latitude))
        self.assertIsNone(parse_nmea_sentence(bad_longitude))
        self.assertIsNone(parse_nmea_sentence(negative_degrees))
        self.assertIsNone(parse_nmea_sentence(non_finite))
        self.assertEqual(list(iter_fixes([bad_latitude, bad_longitude, negative_degrees, non_finite])), [])

    def test_iter_fixes_merges_gga_and_rmc(self):
        fixes = list(
            iter_fixes(
                [
                    "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47",
                    "$GPRMC,123520,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*60",
                ]
            )
        )
        self.assertGreaterEqual(len(fixes), 1)
        self.assertEqual(fixes[-1].satellites, 8)
        self.assertEqual(fixes[-1].speed_knots, 22.4)

    def test_gpx_logger_writes_trackpoint(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47"
        fix = parse_nmea_sentence(sentence)
        assert fix is not None
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)
            text = path.read_text(encoding="utf-8")
            self.assertIn("<trkpt lat=\"48.11730000\" lon=\"11.51666667\">", text)
            self.assertIn("<ele>545.40</ele>", text)
            self.assertIn("<sat>8</sat>", text)
            self.assertIn("<hdop>0.9</hdop>", text)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_gpx_logger_skips_invalid_direct_fix(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=math.nan,
            longitude=-149.0,
            satellites=8,
            hdop=1.2,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)

            text = path.read_text(encoding="utf-8")
            self.assertNotIn("<trkpt", text)
            self.assertNotIn("nan", text)

    def test_gpx_logger_skips_untimestamped_direct_fix(self):
        fix = GPSFix(latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)

            text = path.read_text(encoding="utf-8")
            self.assertNotIn("<trkpt", text)

    def test_gpx_logger_syncs_track_file_and_directory_to_disk(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        calls = []
        original_fsync = gps_module.os.fsync
        gps_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                path = Path(tmpdir) / "track.gpx"
                with GPXTrackLogger(path, fsync_interval_seconds=0) as logger:
                    logger.append(fix)
        finally:
            gps_module.os.fsync = original_fsync

        self.assertGreaterEqual(len(calls), 5)

    def test_gpx_logger_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = gps_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        gps_module.os.open = fake_open
        try:
            gps_module._fsync_directory(Path("/tmp"))
        finally:
            gps_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_gpx_logger_skips_missing_quality_fields(self):
        fix = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)

            text = path.read_text(encoding="utf-8")
            self.assertNotIn("<trkpt", text)

    def test_gpx_logger_tightens_public_track_parent(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            parent = Path(tmpdir) / "tracks"
            parent.mkdir()
            parent.chmod(0o755)
            path = parent / "track.gpx"

            with GPXTrackLogger(path, name="Test") as logger:
                logger.append(fix)

            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_gpx_logger_rejects_misowned_track_parent(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            parent = Path(tmpdir) / "tracks"
            parent.mkdir()
            path = parent / "track.gpx"
            other_uid = os.getuid() + 1

            with patch.object(gps_module.os, "getuid", return_value=other_uid):
                with self.assertRaisesRegex(RuntimeError, "is owned by uid"):
                    with GPXTrackLogger(path, name="Test") as logger:
                        logger.append(fix)

            self.assertFalse(path.exists())

    def test_gpx_logger_rejects_symlinked_track_parent(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "target"
            target.mkdir()
            link_parent = root / "track-parent"
            try:
                link_parent.symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "expected real GPX track storage"):
                with GPXTrackLogger(link_parent / "track.gpx") as logger:
                    logger.append(fix)

            self.assertFalse((target / "track.gpx").exists())

    def test_gpx_logger_rejects_symlinked_track_file(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "target.gpx"
            link = root / "track.gpx"
            target.write_text("existing\n", encoding="utf-8")
            try:
                link.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "expected a new regular GPX track file"):
                with GPXTrackLogger(link, name="Test") as logger:
                    logger.append(fix)

            self.assertEqual(target.read_text(encoding="utf-8"), "existing\n")

    def test_gpx_logger_does_not_overwrite_existing_file(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "track.gpx"
            path.write_text("existing", encoding="utf-8")

            with self.assertRaises(FileExistsError):
                with GPXTrackLogger(path) as logger:
                    logger.append(fix)

            self.assertEqual(path.read_text(encoding="utf-8"), "existing")

    def test_daily_track_path_uses_utc_date(self):
        timestamp = datetime(2026, 6, 29, 23, 30, tzinfo=timezone.utc)
        self.assertEqual(daily_track_path(Path("/tracks"), timestamp), Path("/tracks/tracks/track-20260629.gpx"))

    def test_log_rotating_tracks_writes_one_file_per_utc_day(self):
        fixes = [
            GPSFix(timestamp=datetime(2026, 6, 29, 23, 59, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2),
            GPSFix(timestamp=datetime(2026, 6, 30, 0, 1, tzinfo=timezone.utc), latitude=3.0, longitude=4.0, satellites=8, hdop=1.2),
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            with redirect_stdout(StringIO()):
                count, outputs = _log_rotating_tracks(iter(fixes), Path(tmpdir), deadline=None, sample=True)
            self.assertEqual(count, 2)
            self.assertEqual([path.name for path in outputs], ["track-20260629.gpx", "track-20260630.gpx"])
            self.assertEqual((Path(tmpdir) / "tracks").stat().st_mode & 0o777, 0o700)
            self.assertIn('lat="1.00000000"', outputs[0].read_text(encoding="utf-8"))
            self.assertIn('lat="3.00000000"', outputs[1].read_text(encoding="utf-8"))

    def test_log_rotating_tracks_rejects_symlinked_tracks_directory(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "target"
            target.mkdir()
            try:
                (root / "tracks").symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "symlink"):
                with redirect_stdout(StringIO()):
                    _log_rotating_tracks(iter([fix]), root, deadline=None, sample=True)

    def test_log_rotating_tracks_rejects_symlinked_base_directory(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "target"
            target.mkdir()
            link_base = root / "track-storage"
            try:
                link_base.symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "expected a private tracks directory"):
                with redirect_stdout(StringIO()):
                    _log_rotating_tracks(iter([fix]), link_base, deadline=None, sample=True)

            self.assertFalse((target / "tracks").exists())

    def test_log_single_track_closes_gpx_on_stop_signal_exception(self):
        def fixes():
            yield GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
            raise _TrackLoggerStop("SIGTERM")

        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "track.gpx"
            with redirect_stdout(StringIO()):
                with self.assertRaises(_TrackLoggerStop):
                    _log_single_track(fixes(), output, deadline=None, sample=False)

            text = output.read_text(encoding="utf-8")
            self.assertIn('lat="1.00000000"', text)
            self.assertTrue(text.endswith("</gpx>\n"))

    def test_log_single_track_does_not_create_file_without_fixes(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "track.gpx"
            with redirect_stdout(StringIO()):
                count = _log_single_track(iter([]), output, deadline=None, sample=True)

            self.assertEqual(count, 0)
            self.assertFalse(output.exists())

    def test_log_single_track_does_not_create_file_for_only_weak_fixes(self):
        weak = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=3,
            hdop=1.2,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "track.gpx"
            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                count = _log_single_track(_trackable_fixes(iter([weak])), output, deadline=None, sample=True)

            self.assertEqual(count, 0)
            self.assertFalse(output.exists())

    def test_log_single_track_does_not_create_file_for_null_island_fix(self):
        invalid = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=0.0,
            longitude=0.0,
            satellites=8,
            hdop=1.2,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "track.gpx"
            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                count = _log_single_track(_trackable_fixes(iter([invalid])), output, deadline=None, sample=True)

            self.assertEqual(count, 0)
            self.assertFalse(output.exists())

    def test_log_single_track_does_not_create_file_for_missing_coordinates(self):
        invalid = GPSFix(
            timestamp=datetime.now(timezone.utc),
            satellites=8,
            hdop=1.2,
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "track.gpx"
            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                count = _log_single_track(_trackable_fixes(iter([invalid])), output, deadline=None, sample=True)
            self.assertEqual(count, 0)
            self.assertFalse(output.exists())

    def test_trackable_fixes_skip_reported_weak_quality(self):
        now = datetime.now(timezone.utc)
        weak = GPSFix(
            timestamp=now,
            latitude=1.0,
            longitude=2.0,
            satellites=3,
            hdop=1.2,
        )
        good = GPSFix(
            timestamp=now,
            latitude=3.0,
            longitude=4.0,
            satellites=5,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([weak, good])))

        self.assertEqual(fixes, [good])
        self.assertIn("Skipping weak track fix", stderr.getvalue())

    def test_trackable_fixes_skip_untimestamped_quality_fix(self):
        now = datetime.now(timezone.utc)
        untimestamped = GPSFix(
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        timestamped = GPSFix(
            timestamp=now,
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([untimestamped, timestamped])))

        self.assertEqual(fixes, [timestamped])
        self.assertIn("Skipping untimestamped track fix", stderr.getvalue())

    def test_trackable_fixes_skip_stale_timestamped_fix(self):
        stale = GPSFix(
            timestamp=datetime.now(timezone.utc) - timedelta(minutes=10),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        fresh = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([stale, fresh])))

        self.assertEqual(fixes, [fresh])
        self.assertIn("Skipping stale track fix", stderr.getvalue())
        self.assertIn("stale", stderr.getvalue())

    def test_trackable_fixes_skip_future_timestamped_fix(self):
        future = GPSFix(
            timestamp=datetime.now(timezone.utc) + timedelta(minutes=10),
            latitude=1.0,
            longitude=2.0,
            satellites=8,
            hdop=1.2,
        )
        fresh = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([future, fresh])))

        self.assertEqual(fixes, [fresh])
        self.assertIn("Skipping stale track fix", stderr.getvalue())
        self.assertIn("future", stderr.getvalue())

    def test_trackable_fixes_skip_position_only_fix(self):
        position_only = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=1.0,
            longitude=2.0,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([position_only])))

        self.assertEqual(fixes, [])
        self.assertIn("missing satellite or HDOP quality fields", stderr.getvalue())

    def test_trackable_fixes_skip_position_only_before_quality_fix(self):
        now = datetime.now(timezone.utc)
        first = GPSFix(
            timestamp=now,
            latitude=1.0,
            longitude=2.0,
        )
        second = GPSFix(
            timestamp=now + timedelta(seconds=1),
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()):
            fixes = list(_trackable_fixes(iter([first, second])))

        self.assertEqual(fixes, [second])

    def test_trackable_fixes_skip_position_only_before_weak_quality(self):
        now = datetime.now(timezone.utc)
        position_only = GPSFix(
            timestamp=now,
            latitude=1.0,
            longitude=2.0,
        )
        weak = GPSFix(
            timestamp=now + timedelta(seconds=1),
            latitude=3.0,
            longitude=4.0,
            satellites=3,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()):
            fixes = list(_trackable_fixes(iter([position_only, weak])))

        self.assertEqual(fixes, [])

    def test_trackable_fixes_drop_untimestamped_position_only_fix(self):
        untimestamped = GPSFix(latitude=1.0, longitude=2.0)
        timestamped = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=3.0,
            longitude=4.0,
            satellites=8,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()):
            fixes = list(_trackable_fixes(iter([untimestamped, timestamped])))

        self.assertEqual(fixes, [timestamped])

    def test_trackable_fixes_skip_position_only_before_untimestamped_fix(self):
        timestamped = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=1.0,
            longitude=2.0,
        )
        untimestamped = GPSFix(latitude=3.0, longitude=4.0)

        with redirect_stderr(StringIO()):
            fixes = list(_trackable_fixes(iter([timestamped, untimestamped])))

        self.assertEqual(fixes, [])

    def test_shared_gps_quality_rejects_high_hdop(self):
        fix = GPSFix(latitude=1.0, longitude=2.0, satellites=8, hdop=9.9)

        self.assertIn("HDOP", gps_fix_quality_failure(fix))

    def test_shared_gps_quality_rejects_negative_hdop(self):
        fix = GPSFix(latitude=1.0, longitude=2.0, satellites=8, hdop=-0.1)

        self.assertIn("negative HDOP", gps_fix_quality_failure(fix))

    def test_shared_gps_quality_rejects_null_island_fix(self):
        fix = GPSFix(latitude=0.0, longitude=0.0, satellites=8, hdop=1.2)

        self.assertIn("0.000000, 0.000000", gps_fix_quality_failure(fix))

    def test_shared_gps_quality_rejects_out_of_range_coordinates(self):
        latitude = GPSFix(latitude=91.0, longitude=-149.0, satellites=8, hdop=1.2)
        longitude = GPSFix(latitude=61.0, longitude=-181.0, satellites=8, hdop=1.2)

        self.assertIn("latitude 91.000000 outside -90..90", gps_fix_quality_failure(latitude))
        self.assertIn("longitude -181.000000 outside -180..180", gps_fix_quality_failure(longitude))

    def test_shared_gps_quality_rejects_missing_coordinates(self):
        fix = GPSFix(satellites=8, hdop=1.2)

        self.assertIn("missing coordinates", gps_fix_quality_failure(fix))

    def test_shared_gps_quality_rejects_non_finite_coordinates(self):
        fix = GPSFix(latitude=math.nan, longitude=-149.0, satellites=8, hdop=1.2)

        self.assertIn("non-finite coordinates", gps_fix_quality_failure(fix))

    def test_track_signal_handler_raises_stop_exception(self):
        with self.assertRaisesRegex(_TrackLoggerStop, "SIGTERM"):
            _raise_track_logger_stop(signal.SIGTERM, None)

    def test_log_rotating_tracks_does_not_overwrite_existing_daily_file(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            existing = Path(tmpdir) / "tracks" / "track-20260629.gpx"
            existing.parent.mkdir()
            existing.write_text("old", encoding="utf-8")
            with redirect_stdout(StringIO()):
                count, outputs = _log_rotating_tracks(iter([fix]), Path(tmpdir), deadline=None, sample=True)
            self.assertEqual(count, 1)
            self.assertEqual(outputs[0].name, "track-20260629-1.gpx")
            self.assertEqual(existing.read_text(encoding="utf-8"), "old")

    def test_log_rotating_tracks_prunes_old_daily_files(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0, satellites=8, hdop=1.2)
        with tempfile.TemporaryDirectory() as tmpdir:
            tracks = Path(tmpdir) / "tracks"
            tracks.mkdir()
            old = tracks / "track-20260401.gpx"
            keep = tracks / "track-20260620.gpx"
            unrelated = tracks / "notes.gpx"
            old.write_text("old", encoding="utf-8")
            keep.write_text("keep", encoding="utf-8")
            unrelated.write_text("notes", encoding="utf-8")

            with redirect_stdout(StringIO()):
                _log_rotating_tracks(iter([fix]), Path(tmpdir), deadline=None, sample=True, retention_days=30)

            self.assertFalse(old.exists())
            self.assertTrue(keep.exists())
            self.assertTrue(unrelated.exists())
            self.assertTrue((tracks / "track-20260630.gpx").exists())

    def test_pruned_track_log_directory_is_synced(self):
        calls = []
        original_fsync = cli_module.os.fsync
        cli_module.os.fsync = lambda fd: calls.append(fd)
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                tracks = Path(tmpdir) / "tracks"
                tracks.mkdir()
                tracks.chmod(0o700)
                old = tracks / "track-20260401.gpx"
                old.write_text("old", encoding="utf-8")

                removed = cli_module._prune_old_track_logs(
                    Path(tmpdir),
                    retention_days=30,
                    now=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc),
                )
        finally:
            cli_module.os.fsync = original_fsync

        self.assertEqual([path.name for path in removed], ["track-20260401.gpx"])
        self.assertGreaterEqual(len(calls), 1)

    def test_gpx_track_directory_sync_uses_no_follow_open(self):
        calls = []
        original_open = cli_module.os.open

        def fake_open(path, flags):
            calls.append((Path(path), flags))
            raise OSError("stop before opening")

        cli_module.os.open = fake_open
        try:
            cli_module._fsync_directory(Path("/tmp"))
        finally:
            cli_module.os.open = original_open

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], Path("/tmp"))
        self.assertTrue(calls[0][1] & getattr(os, "O_DIRECTORY", 0))
        self.assertTrue(calls[0][1] & getattr(os, "O_NOFOLLOW", 0))

    def test_prune_old_track_logs_rejects_symlinked_old_track(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tracks = Path(tmpdir) / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            target = Path(tmpdir) / "target.gpx"
            target.write_text("existing\n", encoding="utf-8")
            old_link = tracks / "track-20260401.gpx"
            try:
                old_link.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            with self.assertRaisesRegex(RuntimeError, "refusing to prune GPX track logs"):
                cli_module._prune_old_track_logs(
                    Path(tmpdir),
                    retention_days=30,
                    now=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc),
                )

            self.assertTrue(old_link.is_symlink())
            self.assertEqual(target.read_text(encoding="utf-8"), "existing\n")

    def test_prune_old_track_logs_rejects_nonregular_old_track(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tracks = Path(tmpdir) / "tracks"
            tracks.mkdir()
            tracks.chmod(0o700)
            old_dir = tracks / "track-20260401.gpx"
            old_dir.mkdir()

            with self.assertRaisesRegex(RuntimeError, "not a regular GPX track file"):
                cli_module._prune_old_track_logs(
                    Path(tmpdir),
                    retention_days=30,
                    now=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc),
                )

            self.assertTrue(old_dir.is_dir())

    def test_parse_gpsd_tpv(self):
        payload = (
            '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
            '"lat":61.2181,"lon":-149.9003,"speed":2.0,"track":180.5,"alt":12.3}'
        )
        fix = parse_gpsd_tpv(payload)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertAlmostEqual(fix.latitude, 61.2181)
        self.assertAlmostEqual(fix.longitude, -149.9003)
        self.assertAlmostEqual(fix.speed_knots, 3.887688984)
        self.assertEqual(fix.course_degrees, 180.5)

    def test_parse_gpsd_tpv_rejects_non_finite_position(self):
        payload = '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z","lat":NaN,"lon":-149.9003}'

        self.assertIsNone(parse_gpsd_tpv(payload))

    def test_parse_gpsd_tpv_rejects_out_of_range_position(self):
        bad_latitude = '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z","lat":91.0,"lon":-149.9003}'
        bad_longitude = '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z","lat":61.2181,"lon":-181.0}'

        self.assertIsNone(parse_gpsd_tpv(bad_latitude))
        self.assertIsNone(parse_gpsd_tpv(bad_longitude))

    def test_parse_gpsd_tpv_rejects_malformed_fix_mode(self):
        base = '"class":"TPV","time":"2026-06-28T12:34:56.000Z","lat":61.2181,"lon":-149.9003'

        self.assertIsNone(parse_gpsd_tpv("{" + base + ',"mode":NaN}'))
        self.assertIsNone(parse_gpsd_tpv("{" + base + ',"mode":2.5}'))
        self.assertIsNone(parse_gpsd_tpv("{" + base + ',"mode":"bad"}'))

    def test_parse_gpsd_tpv_ignores_malformed_time(self):
        for time_value in ('"bad-time"', "12345", "true"):
            with self.subTest(time_value=time_value):
                payload = (
                    '{"class":"TPV","mode":3,"time":'
                    + time_value
                    + ',"lat":61.2181,"lon":-149.9003,"speed":2.0}'
                )
                fix = parse_gpsd_tpv(payload)

                self.assertIsNotNone(fix)
                assert fix is not None
                self.assertIsNone(fix.timestamp)
                self.assertAlmostEqual(fix.latitude, 61.2181)
                self.assertAlmostEqual(fix.speed_knots, 3.887688984)

    def test_parse_gpsd_tpv_drops_non_finite_optional_numbers(self):
        payload = (
            '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
            '"lat":61.2181,"lon":-149.9003,"speed":NaN,"track":Infinity,"alt":-Infinity}'
        )
        fix = parse_gpsd_tpv(payload)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertIsNone(fix.speed_knots)
        self.assertIsNone(fix.course_degrees)
        self.assertIsNone(fix.altitude_m)

    def test_parse_gpsd_tpv_drops_impossible_optional_motion(self):
        payload = (
            '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
            '"lat":61.2181,"lon":-149.9003,"speed":-0.1,"track":361.0,"alt":-12.3}'
        )
        fix = parse_gpsd_tpv(payload)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertIsNone(fix.speed_knots)
        self.assertIsNone(fix.course_degrees)
        self.assertEqual(fix.altitude_m, -12.3)

    def test_parse_gpsd_sky_uses_usat_and_hdop(self):
        payload = '{"class":"SKY","uSat":7,"nSat":11,"hdop":1.4}'
        fix = parse_gpsd_sky(payload)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 7)
        self.assertEqual(fix.hdop, 1.4)

    def test_parse_gpsd_sky_drops_non_finite_hdop(self):
        payload = '{"class":"SKY","uSat":7,"hdop":NaN}'
        fix = parse_gpsd_sky(payload)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 7)
        self.assertIsNone(fix.hdop)

    def test_parse_gpsd_sky_drops_negative_hdop(self):
        payload = '{"class":"SKY","uSat":7,"hdop":-0.1}'
        fix = parse_gpsd_sky(payload)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 7)
        self.assertIsNone(fix.hdop)

    def test_parse_gpsd_sky_ignores_malformed_usat(self):
        payload = '{"class":"SKY","uSat":NaN,"satellites":[{"used":true},{"used":false},{"used":true}]}'
        fix = parse_gpsd_sky(payload)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 2)

    def test_parse_gpsd_sky_counts_used_satellites(self):
        payload = (
            '{"class":"SKY","hdop":2.1,"satellites":['
            '{"PRN":1,"used":true},{"PRN":2,"used":false},{"PRN":3,"used":true}]}'
        )
        fix = parse_gpsd_sky(payload)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 2)
        self.assertEqual(fix.hdop, 2.1)

    def test_parse_nmea_gsa_quality(self):
        fix = parse_nmea_sentence("$GPGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5")

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.fix_quality, 3)
        self.assertEqual(fix.satellites, 4)
        self.assertEqual(fix.hdop, 0.9)

    def test_iter_fixes_merges_gsa_quality_into_rmc_position(self):
        fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
        fix_date = datetime.now(timezone.utc).strftime("%d%m%y")
        fixes = list(
            iter_fixes(
                [
                    f"$GPRMC,{fix_time},A,4807.038,N,01131.000,E,022.4,084.4,{fix_date},,,A",
                    "$GPGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5",
                ]
            )
        )

        self.assertEqual(len(fixes), 2)
        self.assertIsNone(fixes[0].satellites)
        self.assertEqual(fixes[1].satellites, 4)
        self.assertEqual(fixes[1].hdop, 0.9)
        self.assertAlmostEqual(fixes[1].latitude, 48.1173, places=4)

    def test_iter_gpsd_fixes_merges_sky_quality_into_tpv(self):
        original = gps_module.socket.create_connection

        class FakeSocket:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return StringIO(
                    '{"class":"SKY","uSat":5,"hdop":1.8}\n'
                    '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
                    '"lat":61.2181,"lon":-149.9003}\n'
                )

            def settimeout(self, timeout):
                self.timeout = timeout

        try:
            gps_module.socket.create_connection = lambda address, timeout=10.0: FakeSocket()
            fix = next(iter_gpsd_fixes(timeout=1))
        finally:
            gps_module.socket.create_connection = original

        self.assertEqual(fix.satellites, 5)
        self.assertEqual(fix.hdop, 1.8)
        self.assertAlmostEqual(fix.latitude, 61.2181)

    def test_iter_gpsd_fixes_ignores_stale_sky_quality(self):
        original_socket = gps_module.socket.create_connection
        original_monotonic = gps_module.time.monotonic

        class FakeSocket:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return StringIO(
                    '{"class":"SKY","uSat":3,"hdop":9.9}\n'
                    '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
                    '"lat":61.2181,"lon":-149.9003}\n'
                )

            def settimeout(self, timeout):
                self.timeout = timeout

        clock_values = iter([100.0, 121.0])
        try:
            gps_module.socket.create_connection = lambda address, timeout=10.0: FakeSocket()
            gps_module.time.monotonic = lambda: next(clock_values)
            fix = next(iter_gpsd_fixes(timeout=1, sky_max_age_seconds=10.0))
        finally:
            gps_module.socket.create_connection = original_socket
            gps_module.time.monotonic = original_monotonic

        self.assertIsNone(fix.satellites)
        self.assertIsNone(fix.hdop)
        self.assertAlmostEqual(fix.latitude, 61.2181)

    def test_iter_gpsd_fixes_clears_read_timeout_for_unbounded_stream(self):
        original_socket = gps_module.socket.create_connection

        class FakeSocket:
            def __init__(self):
                self.timeouts = []
                self.request = b""

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return StringIO(
                    '{"class":"TPV","mode":3,"time":"2026-06-28T12:34:56.000Z",'
                    '"lat":61.2181,"lon":-149.9003}\n'
                )

            def settimeout(self, timeout):
                self.timeouts.append(timeout)

        fake_socket = FakeSocket()
        calls = []

        def fake_create_connection(address, timeout=10.0):
            calls.append((address, timeout))
            return fake_socket

        try:
            gps_module.socket.create_connection = fake_create_connection
            fix = next(iter_gpsd_fixes(host="127.0.0.1", port=2947, timeout=7, max_duration=None))
        finally:
            gps_module.socket.create_connection = original_socket

        self.assertEqual(calls, [(("127.0.0.1", 2947), 7)])
        self.assertEqual(fake_socket.timeouts, [None])
        self.assertAlmostEqual(fix.latitude, 61.2181)

    def test_iter_gpsd_fixes_stops_after_max_duration_without_fixes(self):
        original_socket = gps_module.socket.create_connection
        original_monotonic = gps_module.time.monotonic

        class FakeHandle:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def readline(self):
                return '{"class":"TPV","mode":1}\n'

        class FakeSocket:
            def __init__(self):
                self.timeouts = []

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return None

            def sendall(self, data):
                self.request = data

            def makefile(self, mode, encoding=None, errors=None):
                return FakeHandle()

            def settimeout(self, timeout):
                self.timeouts.append(timeout)

        fake_socket = FakeSocket()

        def fake_monotonic():
            fake_monotonic.value += 0.06
            return fake_monotonic.value

        fake_monotonic.value = -0.06

        try:
            gps_module.socket.create_connection = lambda address, timeout=10.0: fake_socket
            gps_module.time.monotonic = fake_monotonic
            fixes = list(iter_gpsd_fixes(timeout=1, max_duration=0.1))
        finally:
            gps_module.socket.create_connection = original_socket
            gps_module.time.monotonic = original_monotonic

        self.assertEqual(fixes, [])
        self.assertTrue(fake_socket.timeouts)
        self.assertLessEqual(max(fake_socket.timeouts), 0.1)

    def test_check_gps_sample(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentence, encoding="ascii")
            result = check_gps_sample(path)
            self.assertTrue(result.ok)
            self.assertIn("48.117300", result.detail)

    def test_check_gps_sample_rejects_weak_fix_quality(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,03,0.9,545.4,M,46.9,M,,\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentence, encoding="ascii")
            result = check_gps_sample(path)
            self.assertFalse(result.ok)
            self.assertIn("weak GPS fix", result.detail)

    def test_check_gps_sample_rejects_missing_quality_fields(self):
        sentence = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,290626,,,A\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentence, encoding="ascii")
            result = check_gps_sample(path)
            self.assertFalse(result.ok)
            self.assertIn("missing satellite or HDOP quality fields", result.detail)

    def test_check_gps_sample_accepts_rmc_with_gsa_quality(self):
        fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
        fix_date = datetime.now(timezone.utc).strftime("%d%m%y")
        sentences = (
            f"$GPRMC,{fix_time},A,4807.038,N,01131.000,E,022.4,084.4,{fix_date},,,A\n"
            "$GPGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5\n"
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentences, encoding="ascii")
            result = check_gps_sample(path)
            self.assertTrue(result.ok)
            self.assertIn("4 satellites", result.detail)
            self.assertIn("HDOP 0.9", result.detail)

    def test_check_gps_sample_rejects_null_island_fix(self):
        sentence = "$GPGGA,123519,0000.000,N,00000.000,E,1,08,0.9,545.4,M,46.9,M,,\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentence, encoding="ascii")
            result = check_gps_sample(path)
            self.assertFalse(result.ok)
            self.assertIn("0.000000, 0.000000", result.detail)

    def test_check_gps_device_uses_configured_baud(self):
        captured = {}
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            captured["device"] = device
            captured["baud"] = baud
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertTrue(result.ok)
        self.assertEqual(captured, {"device": "/dev/serial/by-id/mock-gps", "baud": 9600})

    def test_check_gps_device_rejects_volatile_path_before_opening(self):
        original = health_module.open_nmea_stream

        def unexpected_open_nmea_stream(device, baud=4800):
            raise AssertionError("check_gps_device should reject volatile GPS device path before opening it")

        try:
            health_module.open_nmea_stream = unexpected_open_nmea_stream
            with tempfile.TemporaryDirectory() as tmpdir:
                device = Path(tmpdir) / "ttyACM0"
                device.write_text("", encoding="ascii")
                result = check_gps_device(str(device), baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("not checked because", result.detail)
        self.assertIn("not stable", result.detail)

    def test_check_gps_device_rejects_low_satellite_count(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},4807.038,N,01131.000,E,1,03,0.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("navigation-quality", result.detail)
        self.assertIn("weak GPS fix", result.detail)

    def test_check_gps_device_rejects_high_hdop(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},4807.038,N,01131.000,E,1,08,9.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("HDOP", result.detail)

    def test_check_gps_device_rejects_missing_quality_fields(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            fix_date = datetime.now(timezone.utc).strftime("%d%m%y")
            return BytesIO(
                f"$GPRMC,{fix_time},A,4807.038,N,01131.000,E,022.4,084.4,{fix_date},,,A\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("missing satellite or HDOP quality fields", result.detail)

    def test_check_gps_device_accepts_rmc_with_gsa_quality(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            fix_date = datetime.now(timezone.utc).strftime("%d%m%y")
            return BytesIO(
                (
                    f"$GPRMC,{fix_time},A,4807.038,N,01131.000,E,022.4,084.4,{fix_date},,,A\n"
                    "$GPGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5\n"
                ).encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertTrue(result.ok)
        self.assertIn("4 satellites", result.detail)
        self.assertIn("HDOP 0.9", result.detail)

    def test_check_gps_device_rejects_null_island_fix(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},0000.000,N,00000.000,E,1,08,0.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("0.000000, 0.000000", result.detail)

    def test_check_gps_device_rejects_out_of_range_coordinates(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},9100.000,N,18100.000,E,1,08,0.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("no fresh navigation-quality NMEA fix", result.detail)

    def test_check_gps_device_rejects_stale_timestamped_fix(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            return BytesIO(b"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W\n")

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("stale", result.detail)

    def test_check_gps_device_rejects_untimestamped_fix(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            return BytesIO(b"$GPGGA,,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,\n")

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            with self._trusted_gps_device_patch():
                result = check_gps_device("/dev/serial/by-id/mock-gps", baud=9600, seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("no timestamp", result.detail)

    def test_check_gpsd_rejects_stale_timestamped_fix(self):
        original = health_module.iter_gpsd_fixes
        stale = GPSFix(
            timestamp=datetime(2000, 1, 1, tzinfo=timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([stale])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("stale", result.detail)

    def test_check_gpsd_rejects_untimestamped_fix(self):
        original = health_module.iter_gpsd_fixes
        untimestamped = GPSFix(
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
            satellites=8,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([untimestamped])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("no timestamp", result.detail)

    def test_check_gpsd_rejects_weak_fix_quality_when_reported(self):
        original = health_module.iter_gpsd_fixes
        weak = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
            satellites=3,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([weak])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("weak GPS fix", result.detail)

    def test_check_gpsd_rejects_null_island_fix(self):
        original = health_module.iter_gpsd_fixes
        invalid = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=0.0,
            longitude=0.0,
            fix_quality=3,
            satellites=8,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([invalid])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("0.000000, 0.000000", result.detail)

    def test_check_gpsd_rejects_out_of_range_coordinates(self):
        original = health_module.iter_gpsd_fixes
        invalid = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=181.0,
            fix_quality=3,
            satellites=8,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([invalid])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("longitude 181.000000 outside -180..180", result.detail)

    def test_check_gpsd_waits_for_quality_after_initial_position(self):
        original = health_module.iter_gpsd_fixes
        position_only = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )
        weak = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
            satellites=3,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([position_only, weak])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("weak GPS fix", result.detail)

    def test_check_gpsd_accepts_later_quality_fix(self):
        original = health_module.iter_gpsd_fixes
        position_only = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )
        good = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.1,
            longitude=-149.1,
            fix_quality=3,
            satellites=6,
            hdop=1.2,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([position_only, good])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertTrue(result.ok)
        self.assertIn("6 satellites", result.detail)
        self.assertIn("61.100000", result.detail)

    def test_check_gpsd_rejects_position_only_fix_before_stream_error(self):
        original = health_module.iter_gpsd_fixes
        position_only = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )

        def fixes(**kwargs):
            yield position_only
            raise RuntimeError("stream ended")

        try:
            health_module.iter_gpsd_fixes = fixes
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("stream ended", result.detail)
        self.assertIn("missing satellite or HDOP quality fields", result.detail)

    def test_check_gpsd_rejects_position_only_fix_without_quality_fields(self):
        original = health_module.iter_gpsd_fixes
        fresh = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout, max_duration=None: iter([fresh])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertFalse(result.ok)
        self.assertIn("missing satellite or HDOP quality fields", result.detail)

    def test_check_gpsd_bounds_gpsd_iterator_by_wait_seconds(self):
        original = health_module.iter_gpsd_fixes
        calls = []

        def fake_iter_gpsd_fixes(host, port, timeout, max_duration=None):
            calls.append((host, port, timeout, max_duration))
            return iter([])

        try:
            health_module.iter_gpsd_fixes = fake_iter_gpsd_fixes
            result = check_gpsd(host="127.0.0.1", port=2947, seconds=7)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertEqual(calls, [("127.0.0.1", 2947, 7, 7)])
        self.assertFalse(result.ok)

    def test_check_gps_device_path_reports_missing_device(self):
        result = check_gps_device_path("/dev/serial/by-id/no-such-gps")
        self.assertFalse(result.ok)
        self.assertIn("does not exist", result.detail)

    def test_check_gps_device_path_accepts_stable_symlink(self):
        with (
            patch("noaa_navionics.health.Path.exists", return_value=True),
            patch("noaa_navionics.health.Path.is_dir", return_value=False),
            patch("noaa_navionics.health.Path.is_char_device", return_value=True),
            patch("noaa_navionics.health.Path.resolve", return_value=Path("/dev/ttyACM0")),
        ):
            stable = "/dev/serial/by-id/usb-gps"
            result = check_gps_device_path(str(stable))

            self.assertTrue(result.ok)
            self.assertIn("usb-gps", result.detail)

    def test_check_gps_device_path_rejects_non_character_stable_path(self):
        with (
            patch("noaa_navionics.health.Path.exists", return_value=True),
            patch("noaa_navionics.health.Path.is_dir", return_value=False),
            patch("noaa_navionics.health.Path.is_char_device", return_value=False),
            patch("noaa_navionics.health.Path.resolve", return_value=Path("/tmp/not-a-device")),
        ):
            result = check_gps_device_path("/dev/serial/by-id/usb-gps")

            self.assertFalse(result.ok)
            self.assertIn("character device", result.detail)

    def test_check_gps_device_path_rejects_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = check_gps_device_path(tmpdir)

            self.assertFalse(result.ok)
            self.assertIn("directory", result.detail)

    def test_stable_gps_device_path_rejects_bare_by_id_directory(self):
        self.assertFalse(health_module._stable_gps_device_path("/dev/serial/by-id/"))

    def test_stable_gps_device_path_rejects_nested_by_id_path(self):
        self.assertFalse(health_module._stable_gps_device_path("/dev/serial/by-id/mock/extra"))
        self.assertFalse(health_module._stable_gps_device_path("/dev/serial/by-id/../ttyS0"))

    def test_stable_gps_device_path_rejects_shell_metacharacters(self):
        self.assertFalse(health_module._stable_gps_device_path("/dev/serial/by-id/$(id)"))
        self.assertFalse(config_module._stable_gps_device_path("/dev/serial/by-id/$(id)"))

    def test_check_gps_device_path_rejects_unsafe_by_id_name_before_existence(self):
        result = check_gps_device_path("/dev/serial/by-id/$(id)")

        self.assertFalse(result.ok)
        self.assertIn("safe /dev/serial/by-id", result.detail)

    def test_check_gps_device_path_rejects_volatile_usb_name(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            device = Path(tmpdir) / "ttyUSB0"
            device.write_text("", encoding="ascii")

            result = check_gps_device_path(str(device))

            self.assertFalse(result.ok)
            self.assertIn("not stable", result.detail)

    def test_check_gps_device_path_rejects_unrecognized_existing_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            device = Path(tmpdir) / "ttyS0"
            device.write_text("", encoding="ascii")

            result = check_gps_device_path(str(device))

            self.assertFalse(result.ok)
            self.assertIn("recognized stable", result.detail)

    def test_check_gpsd_startup_config_accepts_expected_device(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/mock-gps"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertTrue(result.ok)
            self.assertIn("immediate polling", result.detail)

    def test_check_gpsd_startup_config_rejects_symlinked_config_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_config = root / "gpsd.real"
            real_config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/mock-gps"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )
            config = root / "gpsd"
            try:
                config.symlink_to(real_config)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("GPSD config path is a symlink", result.detail)
            self.assertIn(str(config), result.detail)

    def test_check_gpsd_startup_config_rejects_symlinked_config_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_root = root / "real-root"
            config_dir = real_root / "default"
            config_dir.mkdir(parents=True)
            config = config_dir / "gpsd"
            config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/mock-gps"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )
            link_root = root / "link-root"
            try:
                link_root.symlink_to(real_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_gpsd_startup_config(
                "/dev/serial/by-id/mock-gps",
                config_path=link_root / "default" / "gpsd",
            )

            self.assertFalse(result.ok)
            self.assertIn("GPSD config directory is a symlink", result.detail)
            self.assertIn(str(link_root), result.detail)

    def test_check_gpsd_startup_config_rejects_nonregular_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.mkdir()

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("GPSD config path is not a regular file", result.detail)

    def test_check_gpsd_startup_config_rejects_writable_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/mock-gps"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )
            config.chmod(0o666)

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("GPSD config", result.detail)
            self.assertIn("has permissions 0666", result.detail)

    def test_check_gpsd_startup_config_rejects_unsafe_expected_device(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/$(id)"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )

            result = check_gpsd_startup_config("/dev/serial/by-id/$(id)", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("safe stable path", result.detail)

    def test_check_gpsd_startup_config_rejects_mismatch_and_missing_polling(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.write_text(
                'START_DAEMON="false"\n'
                'USBAUTO="true"\n'
                'DEVICES="/dev/serial/by-id/other-gps"\n'
                'GPSD_OPTIONS=""\n',
                encoding="utf-8",
            )

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("START_DAEMON", result.detail)
            self.assertIn("USBAUTO", result.detail)
            self.assertIn("does not include -n", result.detail)
            self.assertIn("/dev/serial/by-id/mock-gps", result.detail)

    def test_check_gpsd_startup_config_rejects_extra_devices(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "gpsd"
            config.write_text(
                'START_DAEMON="true"\n'
                'USBAUTO="false"\n'
                'DEVICES="/dev/serial/by-id/mock-gps /dev/serial/by-id/old-gps"\n'
                'GPSD_OPTIONS="-n"\n',
                encoding="utf-8",
            )

            result = check_gpsd_startup_config("/dev/serial/by-id/mock-gps", config_path=config)

            self.assertFalse(result.ok)
            self.assertIn("must contain exactly", result.detail)
            self.assertIn("/dev/serial/by-id/old-gps", result.detail)

    def test_chart_check_requires_extracted_cells(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / "AK_ENCs.zip").write_bytes(b"not a real zip")
            zip_result = check_chart_dir(root)
            self.assertFalse(zip_result.ok)
            cell = root / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("", encoding="ascii")
            extracted_result = check_chart_dir(root)
            self.assertTrue(extracted_result.ok)

    def test_chart_check_ignores_symlinked_enc_cells(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "outside.000"
            target.write_text("not a trusted chart cell", encoding="ascii")
            charts = root / "charts"
            cell = charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            try:
                cell.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_dir(charts)

            self.assertFalse(result.ok)
            self.assertIn("no ENC .000 cells", result.detail)

    def test_chart_check_rejects_symlinked_chart_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_charts = root / "real-charts"
            cell = real_charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("", encoding="ascii")
            chart_link = root / "charts"
            try:
                chart_link.symlink_to(real_charts, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_chart_dir(chart_link)

            self.assertFalse(result.ok)
            self.assertIn("chart directory is a symlink", result.detail)

    def test_disk_check_requires_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "charts"
            path.write_text("not a directory", encoding="ascii")
            result = check_disk_space(path)
            self.assertFalse(result.ok)
            self.assertIn("not a directory", result.detail)

    def test_disk_check_rejects_symlinked_storage_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "real-charts"
            target.mkdir()
            link = root / "charts"
            link.symlink_to(target, target_is_directory=True)

            result = check_disk_space(link)

            self.assertFalse(result.ok)
            self.assertIn("is a symlink", result.detail)

    def test_disk_check_rejects_storage_under_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target_parent = root / "real-storage"
            charts = target_parent / "charts"
            charts.mkdir(parents=True)
            link_parent = root / "storage-link"
            try:
                link_parent.symlink_to(target_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")

            result = check_disk_space(link_parent / "charts")

            self.assertFalse(result.ok)
            self.assertIn("storage-link", result.detail)
            self.assertIn("is a symlink", result.detail)

    def test_disk_check_rejects_missing_parent_storage(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "missing-mount" / "charts"
            result = check_disk_space(path)
            self.assertFalse(result.ok)
            self.assertIn("does not exist", result.detail)

    def test_disk_check_reports_unwritable_directory(self):
        original = health_module._directory_writable
        try:
            health_module._directory_writable = lambda path: False
            with tempfile.TemporaryDirectory() as tmpdir:
                result = check_disk_space(Path(tmpdir))
            self.assertFalse(result.ok)
            self.assertIn("not writable", result.detail)
        finally:
            health_module._directory_writable = original

    def test_disk_check_rejects_public_storage_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            charts.mkdir()
            os.chmod(charts, 0o777)
            try:
                result = check_disk_space(charts)
            finally:
                os.chmod(charts, 0o700)

            self.assertFalse(result.ok)
            self.assertIn("expected no group/other write bits", result.detail)

    def test_disk_check_uses_configured_free_space_floor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            usage = shutil.disk_usage(tmpdir)
            min_free_gb = (usage.free / (1024 ** 3)) + 1.0

            result = check_disk_space(Path(tmpdir), min_free_gb=min_free_gb)

            self.assertFalse(result.ok)
            self.assertIn("minimum", result.detail)

    def test_disk_check_rejects_unmounted_removable_storage_path(self):
        original_roots = health_module.REMOVABLE_STORAGE_ROOTS
        original_ismount = health_module.os.path.ismount
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                removable_root = Path(tmpdir) / "mnt"
                charts = removable_root / "usb" / "charts"
                charts.mkdir(parents=True)
                health_module.REMOVABLE_STORAGE_ROOTS = (removable_root,)
                health_module.os.path.ismount = lambda path: False

                result = check_disk_space(charts)

            self.assertFalse(result.ok)
            self.assertIn("no mounted storage device", result.detail)
        finally:
            health_module.REMOVABLE_STORAGE_ROOTS = original_roots
            health_module.os.path.ismount = original_ismount

    def test_disk_check_accepts_mounted_removable_storage_parent(self):
        original_roots = health_module.REMOVABLE_STORAGE_ROOTS
        original_ismount = health_module.os.path.ismount
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                removable_root = Path(tmpdir) / "mnt"
                mount_point = removable_root / "usb"
                charts = mount_point / "charts"
                charts.mkdir(parents=True)
                health_module.REMOVABLE_STORAGE_ROOTS = (removable_root,)
                health_module.os.path.ismount = lambda path: Path(path) == mount_point

                result = check_disk_space(charts)

            self.assertTrue(result.ok)
        finally:
            health_module.REMOVABLE_STORAGE_ROOTS = original_roots
            health_module.os.path.ismount = original_ismount

    def test_preflight_checks_separate_track_storage(self):
        original = health_module._directory_writable
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                chart_dir = root / "charts"
                extract = chart_dir / "AK_ENCs"
                cell = extract / "US5AK3CM" / "US5AK3CM.000"
                cell.parent.mkdir(parents=True)
                cell.write_text("cell", encoding="ascii")
                now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
                (chart_dir / MANIFEST_NAME).write_text(
                    '{"created_at":"' + now + '",'
                    '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                    '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                    '"download":{"path":"","url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip","bytes":0,"sha256":""},'
                    f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                    encoding="utf-8",
                )
                sample = root / "sample.nmea"
                sample.write_text(
                    "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n",
                    encoding="ascii",
                )
                track_parent = root / "track-storage"
                track_parent.mkdir()
                track_output = track_parent / "tracks"
                health_module._directory_writable = lambda path: Path(path) != track_parent

                results = health_module.run_preflight(
                    chart_dir=chart_dir,
                    chart_package="state",
                    chart_value="AK",
                    gps_sample=sample,
                    track_output=track_output,
                )

            track_check = next(check for check in results if check.name == "Track Disk")
            self.assertFalse(track_check.ok)
            self.assertIn("not writable", track_check.detail)
        finally:
            health_module._directory_writable = original

    def test_preflight_rejects_missing_separate_track_storage_parent(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            chart_dir = root / "charts"
            extract = chart_dir / "AK_ENCs"
            cell = extract / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            (chart_dir / MANIFEST_NAME).write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"State AK","filename":"AK_ENCs.zip",'
                '"url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip"},'
                '"download":{"path":"","url":"https://www.charts.noaa.gov/ENCs/AK_ENCs.zip","bytes":0,"sha256":""},'
                f'"extract":{{"path":"{extract}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            sample = root / "sample.nmea"
            sample.write_text(
                "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n",
                encoding="ascii",
            )
            track_output = root / "missing-mount" / "tracks"

            results = health_module.run_preflight(
                chart_dir=chart_dir,
                chart_package="state",
                chart_value="AK",
                gps_sample=sample,
                track_output=track_output,
            )

        track_check = next(check for check in results if check.name == "Track Disk")
        self.assertFalse(track_check.ok)
        self.assertIn("does not exist", track_check.detail)

    def test_preflight_rejects_volatile_direct_serial_device_before_opening(self):
        original_open = health_module.open_nmea_stream

        def unexpected_open_nmea_stream(device, baud=4800):
            raise AssertionError("preflight should reject volatile GPS device path before opening it")

        try:
            health_module.open_nmea_stream = unexpected_open_nmea_stream
            with tempfile.TemporaryDirectory() as tmpdir:
                device = Path(tmpdir) / "ttyUSB0"
                device.write_text("", encoding="ascii")

                results = health_module.run_preflight(
                    chart_dir=Path(tmpdir) / "charts",
                    gps_device=str(device),
                    gps_seconds=0,
                )
        finally:
            health_module.open_nmea_stream = original_open

        device_check = next(check for check in results if check.name == "GPS Device")
        gps_check = next(check for check in results if check.name == "GPS")
        self.assertFalse(device_check.ok)
        self.assertIn("not stable", device_check.detail)
        self.assertFalse(gps_check.ok)
        self.assertIn("not checked because", gps_check.detail)


class PiHealthTests(unittest.TestCase):
    def test_check_source_revision_skips_non_pi(self):
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._is_raspberry_pi = lambda: False
            result = check_source_revision()
        finally:
            health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("skipping", result.detail)

    def test_check_source_revision_accepts_recorded_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123-dirty\n", encoding="utf-8")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertEqual(result.detail, "abc123-dirty")

    def test_check_source_revision_rejects_missing_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "missing"
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("cannot read deployed source revision", result.detail)

    def test_check_source_revision_rejects_symlinked_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_revision = root / "real-source-revision"
            real_revision.write_text("abc123\n", encoding="utf-8")
            revision = root / "source-revision"
            try:
                revision.symlink_to(real_revision)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("deployed source revision path is a symlink", result.detail)

    def test_check_source_revision_rejects_symlinked_revision_directory_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_dir = root / "real-source"
            real_dir.mkdir()
            real_revision = real_dir / "source-revision"
            real_revision.write_text("abc123\n", encoding="utf-8")
            link_dir = root / "source-link"
            try:
                link_dir.symlink_to(real_dir, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            revision = link_dir / "source-revision"
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("deployed source revision directory is a symlink", result.detail)

    def test_check_source_revision_rejects_symlinked_revision_ancestor_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            real_root = root / "real-install"
            real_dir = real_root / "noaa-navionics"
            real_dir.mkdir(parents=True)
            real_revision = real_dir / "source-revision"
            real_revision.write_text("abc123\n", encoding="utf-8")
            link_root = root / "install-link"
            try:
                link_root.symlink_to(real_root, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            revision = link_root / "noaa-navionics" / "source-revision"
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("deployed source revision directory is a symlink", result.detail)
            self.assertIn(str(link_root), result.detail)

    def test_check_source_revision_rejects_nonregular_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.mkdir()
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("not a regular file", result.detail)

    def test_check_source_revision_rejects_writable_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o620)
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                revision.chmod(0o600)
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("has permissions 0620", result.detail)

    def test_health_source_revision_reader_rejects_writable_revision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("abc123\n", encoding="utf-8")
            revision.chmod(0o622)
            try:
                with self.assertRaisesRegex(RuntimeError, "source revision path has permissions 0622"):
                    health_module._read_source_revision_text(revision)
            finally:
                revision.chmod(0o600)

    def test_check_source_revision_rejects_unknown_revision_on_pi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            revision = Path(tmpdir) / "source-revision"
            revision.write_text("unknown\n", encoding="utf-8")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_source_revision(revision)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("not recorded", result.detail)

    def test_check_system_clock_rejects_epoch_like_time(self):
        result = check_system_clock(datetime(1970, 1, 1, tzinfo=timezone.utc))
        self.assertFalse(result.ok)
        self.assertIn("system clock", result.detail)

    def test_check_system_clock_accepts_modern_time(self):
        result = check_system_clock(datetime(2026, 6, 29, tzinfo=timezone.utc))
        self.assertTrue(result.ok)

    def test_check_time_synchronization_skips_non_pi(self):
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._is_raspberry_pi = lambda: False
            result = check_time_synchronization()
        finally:
            health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("skipping", result.detail)

    def test_check_time_synchronization_accepts_synced_pi_clock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "timedatectl"
            fake.write_text("#!/bin/sh\necho SystemClockSynchronized=yes\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_time_synchronization()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertIn("synchronized", result.detail)

    def test_check_time_synchronization_accepts_ntp_fallback_yes(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "timedatectl"
            fake.write_text(
                "#!/bin/sh\n"
                "echo SystemClockSynchronized=no\n"
                "echo NTPSynchronized=yes\n",
                encoding="ascii",
            )
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_time_synchronization()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertIn("synchronized", result.detail)

    def test_check_time_synchronization_accepts_system_clock_yes_over_ntp_no(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "timedatectl"
            fake.write_text(
                "#!/bin/sh\n"
                "echo SystemClockSynchronized=yes\n"
                "echo NTPSynchronized=no\n",
                encoding="ascii",
            )
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_time_synchronization()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertIn("synchronized", result.detail)

    def test_check_time_synchronization_rejects_unsynced_pi_clock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "timedatectl"
            fake.write_text("#!/bin/sh\necho SystemClockSynchronized=no\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_time_synchronization()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("not synchronized", result.detail)

    def test_check_time_synchronization_reports_missing_timedatectl_on_pi(self):
        original_path = os.environ.get("PATH", "")
        original_is_pi = health_module._is_raspberry_pi
        try:
            os.environ["PATH"] = "/nonexistent"
            health_module._is_raspberry_pi = lambda: True
            result = check_time_synchronization()
        finally:
            os.environ["PATH"] = original_path
            health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("timedatectl", result.detail)

    def test_check_chrony_gps_time_config_skips_non_pi(self):
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._is_raspberry_pi = lambda: False
            result = check_chrony_gps_time_config()
        finally:
            health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("skipping", result.detail)

    def test_check_chrony_gps_time_config_accepts_managed_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.write_text("refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_config(config)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertIn("GPSD SHM 0", result.detail)

    def test_check_chrony_gps_time_config_rejects_commented_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.write_text("# refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_config(config)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("uncommented NOAA Navionics GPSD SHM 0", result.detail)

    def test_check_chrony_gps_time_config_rejects_nonregular_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.mkdir()
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_config(config)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("Chrony config is not a regular file", result.detail)

    def test_check_chrony_gps_time_config_rejects_writable_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.write_text("refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
            config.chmod(0o666)
            original_is_pi = health_module._is_raspberry_pi
            try:
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_config(config)
            finally:
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("has permissions 0666", result.detail)

    def test_read_trusted_config_lines_rejects_writable_config_before_parsing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "chrony.conf"
            config.write_text("refclock SHM 0 offset 0.5 delay 0.1 refid GPS\n", encoding="utf-8")
            config.chmod(0o666)

            with self.assertRaisesRegex(RuntimeError, "has permissions 0666"):
                _read_trusted_config_lines(config, label="Chrony config", expected_uid=os.getuid())

    def test_check_chrony_gps_time_source_skips_non_pi(self):
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._is_raspberry_pi = lambda: False
            result = check_chrony_gps_time_source()
        finally:
            health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("skipping", result.detail)

    def test_check_chrony_gps_time_source_accepts_usable_gps_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "chronyc"
            fake.write_text("#!/bin/sh\necho '#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms'\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_source(seconds=0)
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertIn("GPS", result.detail)

    def test_check_chrony_gps_time_source_rejects_unusable_gps_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "chronyc"
            fake.write_text("#!/bin/sh\necho '#? GPS 0 4 0 - +0ns[ +0ns] +/- 0ns'\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_source()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("not usable", result.detail)

    def test_check_chrony_gps_time_source_rejects_excluded_gps_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "chronyc"
            fake.write_text("#!/bin/sh\necho '#- GPS 0 4 377 8 +12us[ +20us] +/- 100ms'\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_source(seconds=0)
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("not usable", result.detail)

    def test_check_chrony_gps_time_source_waits_for_later_usable_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            counter = root / "count"
            fake = bin_dir / "chronyc"
            fake.write_text(
                "#!/bin/sh\n"
                f"count_file='{counter}'\n"
                'if [ -f "$count_file" ]; then\n'
                '  IFS= read -r count <"$count_file"\n'
                "else\n"
                "  count=0\n"
                "fi\n"
                'count=$((count + 1))\n'
                'echo "$count" >"$count_file"\n'
                'if [ "$count" -lt 2 ]; then\n'
                "  echo '#? GPS 0 4 0 - +0ns[ +0ns] +/- 0ns'\n"
                "else\n"
                "  echo '#+ GPS 0 4 377 8 +12us[ +20us] +/- 100ms'\n"
                "fi\n",
                encoding="ascii",
            )
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_source(seconds=1, poll_interval=0.01)
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertEqual(counter.read_text(encoding="ascii").strip(), "2")

    def test_check_chrony_gps_time_source_reports_missing_gps_refclock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "chronyc"
            fake.write_text("#!/bin/sh\necho '^* 192.0.2.1 2 6 377 10 +1ms[ +1ms] +/- 20ms'\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_chrony_gps_time_source(seconds=0)
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("GPS refclock", result.detail)

    def test_check_display_power_tool_reports_missing_xset(self):
        original_path = os.environ.get("PATH", "")
        try:
            os.environ["PATH"] = "/nonexistent"
            result = check_display_power_tool()
        finally:
            os.environ["PATH"] = original_path
        self.assertFalse(result.ok)
        self.assertIn("x11-xserver-utils", result.detail)

    def test_check_opencpn_accepts_trusted_local_command(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "opencpn"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: False
                result = check_opencpn()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertTrue(result.ok)
            self.assertIn("trusted executable", result.detail)

    def test_check_opencpn_rejects_symlinked_command(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            root = Path(tmpdir)
            bin_dir = root / "bin"
            bin_dir.mkdir(mode=0o700)
            real = root / "real-opencpn"
            real.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            real.chmod(0o755)
            fake = bin_dir / "opencpn"
            try:
                fake.symlink_to(real)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: False
                result = check_opencpn()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("symlink", result.detail)

    def test_check_opencpn_rejects_writable_command(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "opencpn"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            fake.chmod(0o775)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: False
                result = check_opencpn()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("expected no group/other write bits", result.detail)

    def test_check_opencpn_requires_root_owner_on_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "opencpn"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_opencpn()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("expected root", result.detail)

    def test_check_opencpn_requires_root_parent_on_pi(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_PARENT) as tmpdir:
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir(mode=0o700)
            fake = bin_dir / "opencpn"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_is_pi = health_module._is_raspberry_pi
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._is_raspberry_pi = lambda: True
                result = check_opencpn()
            finally:
                os.environ["PATH"] = original_path
                health_module._is_raspberry_pi = original_is_pi

            self.assertFalse(result.ok)
            self.assertIn("OpenCPN command directory is owned by uid", result.detail)
            self.assertIn("expected root", result.detail)

    def test_parse_throttled_value(self):
        self.assertEqual(_parse_throttled_value("throttled=0x50000"), 0x50000)
        self.assertEqual(_parse_throttled_value("throttled=3"), 3)
        self.assertIsNone(_parse_throttled_value("not-throttled"))
        self.assertIsNone(_parse_throttled_value("other=0x0"))
        self.assertIsNone(_parse_throttled_value("throttled=0x0 warning"))
        self.assertIsNone(_parse_throttled_value("warning\nthrottled=0x0"))

    def test_check_pi_throttling_reports_active_under_voltage(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "vcgencmd"
            fake.write_text("#!/bin/sh\necho throttled=0x1\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            try:
                os.environ["PATH"] = str(bin_dir)
                result = check_pi_throttling()
            finally:
                os.environ["PATH"] = original_path
            self.assertFalse(result.ok)
            self.assertIn("under-voltage", result.detail)

    def test_check_pi_throttling_rejects_historical_events(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "vcgencmd"
            fake.write_text("#!/bin/sh\necho throttled=0x50000\n", encoding="ascii")
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            try:
                os.environ["PATH"] = str(bin_dir)
                result = check_pi_throttling()
            finally:
                os.environ["PATH"] = original_path
            self.assertFalse(result.ok)
            self.assertIn("under-voltage occurred", result.detail)
            self.assertIn("throttling occurred", result.detail)

    def test_check_pi_throttling_reports_missing_command_on_pi(self):
        original_path = os.environ.get("PATH", "")
        original_is_pi = health_module._is_raspberry_pi
        try:
            os.environ["PATH"] = "/nonexistent"
            health_module._is_raspberry_pi = lambda: True
            result = check_pi_throttling()
        finally:
            os.environ["PATH"] = original_path
            health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("vcgencmd", result.detail)

    def test_check_pi_temperature_reports_normal_temperature(self):
        original_reader = health_module._read_pi_temperature
        try:
            health_module._read_pi_temperature = lambda: 42.5
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader

        self.assertTrue(result.ok)
        self.assertIn("42.5 C", result.detail)

    def test_check_pi_temperature_warns_when_warm(self):
        original_reader = health_module._read_pi_temperature
        try:
            health_module._read_pi_temperature = lambda: 72.0
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader

        self.assertTrue(result.ok)
        self.assertIn("warm", result.detail)

    def test_check_pi_temperature_fails_above_limit(self):
        original_reader = health_module._read_pi_temperature
        try:
            health_module._read_pi_temperature = lambda: 81.0
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader

        self.assertFalse(result.ok)
        self.assertIn("above 80 C limit", result.detail)

    def test_check_pi_temperature_rejects_non_finite_temperature(self):
        original_reader = health_module._read_pi_temperature
        try:
            health_module._read_pi_temperature = lambda: math.nan
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader

        self.assertFalse(result.ok)
        self.assertIn("non-finite", result.detail)

    def test_check_pi_temperature_reports_missing_sensor_on_pi(self):
        original_reader = health_module._read_pi_temperature
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._read_pi_temperature = lambda: None
            health_module._is_raspberry_pi = lambda: True
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader
            health_module._is_raspberry_pi = original_is_pi

        self.assertFalse(result.ok)
        self.assertIn("temperature sensor unavailable", result.detail)

    def test_check_pi_temperature_skips_missing_sensor_off_pi(self):
        original_reader = health_module._read_pi_temperature
        original_is_pi = health_module._is_raspberry_pi
        try:
            health_module._read_pi_temperature = lambda: None
            health_module._is_raspberry_pi = lambda: False
            result = check_pi_temperature()
        finally:
            health_module._read_pi_temperature = original_reader
            health_module._is_raspberry_pi = original_is_pi

        self.assertTrue(result.ok)
        self.assertIn("skipping", result.detail)

    def test_parse_vcgencmd_temperature(self):
        self.assertEqual(_parse_vcgencmd_temperature("temp=42.5'C"), 42.5)
        self.assertEqual(_parse_vcgencmd_temperature("temp=47'C"), 47.0)
        self.assertIsNone(_parse_vcgencmd_temperature("temperature unavailable"))
        self.assertIsNone(_parse_vcgencmd_temperature("temp=42.5"))
        self.assertIsNone(_parse_vcgencmd_temperature("warning temp=42.5'C"))
        self.assertIsNone(_parse_vcgencmd_temperature("temp=42.5'C warning"))

    def test_read_sysfs_pi_temperature(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            temp_file = Path(tmpdir) / "temp"
            temp_file.write_text("42500\n", encoding="ascii")

            self.assertEqual(health_module._read_sysfs_pi_temperature(temp_file), 42.5)

    def test_read_sysfs_pi_temperature_rejects_non_finite_values(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            temp_file = Path(tmpdir) / "temp"

            temp_file.write_text("nan\n", encoding="ascii")
            self.assertIsNone(health_module._read_sysfs_pi_temperature(temp_file))

            temp_file.write_text("inf\n", encoding="ascii")
            self.assertIsNone(health_module._read_sysfs_pi_temperature(temp_file))

    def test_read_pi_temperature_falls_back_to_vcgencmd(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            bin_dir = Path(tmpdir)
            fake = bin_dir / "vcgencmd"
            fake.write_text(
                "#!/bin/sh\n"
                "test \"$1\" = measure_temp || exit 2\n"
                "echo \"temp=43.7'C\"\n",
                encoding="ascii",
            )
            fake.chmod(0o755)
            original_path = os.environ.get("PATH", "")
            original_sysfs_reader = health_module._read_sysfs_pi_temperature
            try:
                os.environ["PATH"] = str(bin_dir)
                health_module._read_sysfs_pi_temperature = lambda path: None
                self.assertEqual(health_module._read_pi_temperature(), 43.7)
            finally:
                os.environ["PATH"] = original_path
                health_module._read_sysfs_pi_temperature = original_sysfs_reader


if __name__ == "__main__":
    unittest.main()
