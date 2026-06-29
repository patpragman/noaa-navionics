from pathlib import Path
from datetime import datetime, timezone
from contextlib import redirect_stderr, redirect_stdout
from io import BytesIO, StringIO
from urllib.error import URLError
import json
import math
import sys
import signal
import tempfile
import textwrap
import time
import unittest
import zipfile
import os

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from noaa_navionics import health as health_module
from noaa_navionics import config as config_module
from noaa_navionics import downloader as downloader_module
from noaa_navionics import gps as gps_module
from noaa_navionics import cli as cli_module
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
from noaa_navionics.config import package_kwargs, read_config, write_default_config
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
    check_chrony_gps_time_source,
    check_opencpn_chart_config,
    check_opencpn_gpsd_config,
    check_pi_throttling,
    check_system_clock,
    check_time_synchronization,
    _parse_throttled_value,
)
from noaa_navionics.opencpn import (
    chart_directory_configured,
    configure_chart_directory,
    configure_gpsd_connection,
    gpsd_connection_configured,
    read_data_connections,
    read_chart_directories,
)
from noaa_navionics.report import build_status_report, format_status_text, write_status_report, _service_readiness_checks


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
            self.assertEqual(config.track_retention_days, 90)
            self.assertTrue(config.extract)

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
                "\n"
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/ttyACM0\n"
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
            self.assertEqual(config.gps_device, "/dev/ttyACM0")
            self.assertEqual(config.gps_baud, 9600)
            self.assertEqual(config.max_chart_age_days, 14)
            self.assertEqual(config.track_retention_days, 14)
            self.assertFalse(config.keep_zip)
            self.assertFalse(config.force)

    def test_invalid_gps_mode_fails_config_read(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "config.ini"
            path.write_text("[gps]\nmode = bluetooth\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "gps.mode"):
                read_config(path)

    def test_invalid_config_values_fail_fast(self):
        cases = [
            ("[charts]\npackage = potato\n", "charts.package"),
            ("[charts]\npackage = state\nvalue =\n", "charts.value"),
            ("[charts]\noutput =\n", "charts.output"),
            ("[charts]\nmax_age_days = 0\n", "charts.max_age_days"),
            ("[charts]\nextract = maybe\n", "charts.extract"),
            ("[gps]\nmode = serial\ndevice =\n", "gps.device"),
            ("[gps]\nbaud = 12345\n", "gps.baud"),
            ("[gps]\ngpsd_host = 127.0.0.1;bad\n", "gps.gpsd_host"),
            ("[gps]\ngpsd_port = 70000\n", "gps.gpsd_port"),
            ("[tracking]\noutput =\n", "tracking.output"),
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

            result = configure_chart_directory(charts, config_path=config)

            self.assertTrue(result.changed)
            self.assertEqual(result.key, "ChartDir1")
            self.assertTrue(config.exists())
            self.assertEqual(read_chart_directories(config), [charts.resolve()])
            self.assertTrue(chart_directory_configured(charts, config))

    def test_configure_chart_directory_is_idempotent_and_backs_up_existing_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"
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

    def test_configure_chart_directory_uses_unique_synced_temp_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            config.write_text("[Settings]\nShowStatusBar=1\n", encoding="utf-8")
            fixed_part = root / "opencpn.conf.part"
            fixed_part.write_text("other writer\n", encoding="utf-8")
            calls = []
            original_fsync = opencpn_module.os.fsync
            opencpn_module.os.fsync = lambda fd: calls.append(fd)
            try:
                result = configure_chart_directory(root / "charts", config_path=config)
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
            configure_chart_directory(charts, config_path=config)

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

    def test_check_opencpn_gpsd_config_reports_missing_and_configured(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"

            missing = check_opencpn_gpsd_config(config_path=config)
            self.assertFalse(missing.ok)

            configure_gpsd_connection(config_path=config)
            configured = check_opencpn_gpsd_config(config_path=config)
            self.assertTrue(configured.ok)

    def test_cli_configure_opencpn_skips_gpsd_for_serial_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            opencpn_config = root / "opencpn.conf"
            charts = root / "charts"
            app_config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {charts}\n"
                "\n"
                "[gps]\n"
                "mode = serial\n"
                "device = /dev/ttyUSB0\n",
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
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            app_config = root / "config.ini"
            opencpn_config = root / "opencpn.conf"
            charts = root / "charts"
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

    def test_gps_waits_reject_negative_seconds(self):
        self.assert_parse_error(["preflight", "--gps-seconds", "-1"])
        self.assert_parse_error(["status-report", "--gps-seconds", "-1"])

    def test_track_logger_rejects_non_positive_duration(self):
        self.assert_parse_error(["log-track", "--seconds", "0"])

    def test_track_logger_rejects_negative_retention_days(self):
        self.assert_parse_error(["log-track", "--retention-days", "-1"])


class ManifestTests(unittest.TestCase):
    class FakeResponse:
        def __init__(self, payload, content_length: str = "5"):
            self.headers = {"Content-Length": content_length}
            self.payload = BytesIO(payload)

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return None

        def read(self, size=-1):
            return self.payload.read(size)

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
            self.assertEqual(manifest["download"]["sha256"], result.sha256)
            self.assertEqual(manifest["extract"]["enc_cell_count"], 1)
            self.assertTrue(check_chart_manifest(output).ok)

    def test_existing_zip_extract_respects_no_keep_zip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir)
            existing = output / "AK_ENCs.zip"
            with zipfile.ZipFile(existing, "w") as archive:
                archive.writestr("US5AK3CM/US5AK3CM.000", "cell")
            package = Package("State AK", "https://example.invalid/AK_ENCs.zip", "AK_ENCs.zip")

            result = download_package(package, output, extract=True, keep_zip=False)

            self.assertTrue(result.skipped)
            self.assertFalse(existing.exists())
            self.assertTrue((output / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000").exists())
            manifest = read_manifest(output)
            self.assertEqual(manifest["download"]["bytes"], result.bytes_written)
            self.assertEqual(manifest["extract"]["enc_cell_count"], 1)

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

    def test_download_lock_blocks_concurrent_chart_update(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lock = root / DOWNLOAD_LOCK_NAME
            lock.write_text("busy\n", encoding="ascii")
            package = Package("Locked test", "https://example.invalid/chart.zip", "chart.zip")

            with self.assertRaisesRegex(RuntimeError, "already in progress"):
                download_package(package, root)

            self.assertTrue(lock.exists())

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

    def test_download_lock_cleanup_preserves_replaced_lock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lock = root / DOWNLOAD_LOCK_NAME

            with downloader_module._chart_update_lock(root):
                lock.write_text("new owner\n", encoding="ascii")

            self.assertEqual(lock.read_text(encoding="ascii"), "new owner\n")

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
            self.assertIn("only 1 remain", result.detail)

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
                '"download":{"sha256":"abc"},'
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

    def test_chart_package_rejects_update_bundle_as_primary_charts(self):
        result = check_chart_package("updates", "ten-days")
        self.assertFalse(result.ok)
        self.assertIn("not a complete chart set", result.detail)

    def test_chart_package_accepts_state_bundle(self):
        result = check_chart_package("state", "AK")
        self.assertTrue(result.ok)

    def test_chart_update_debris_fails_for_interrupted_sync_paths(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / ".AK_ENCs.previous").mkdir()
            (root / ".CA_ENCs.abcd.extracting").mkdir()

            result = check_chart_update_debris(root)

            self.assertFalse(result.ok)
            self.assertIn(".AK_ENCs.previous", result.detail)
            self.assertIn(".CA_ENCs.abcd.extracting", result.detail)

    def test_chart_update_debris_ignores_download_lock(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            (root / DOWNLOAD_LOCK_NAME).write_text("locked\n", encoding="ascii")

            result = check_chart_update_debris(root)

            self.assertTrue(result.ok)

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
    def test_build_and_write_status_report(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            charts = root / "charts"
            cell = charts / "AK_ENCs" / "US5AK3CM" / "US5AK3CM.000"
            cell.parent.mkdir(parents=True)
            cell.write_text("cell", encoding="ascii")
            manifest = charts / MANIFEST_NAME
            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            manifest.write_text(
                '{"created_at":"' + now + '",'
                '"package":{"label":"Test","filename":"AK_ENCs.zip","url":"file:///test.zip"},'
                f'"download":{{"path":"{charts / "AK_ENCs.zip"}","bytes":123,"sha256":"abc"}},'
                f'"extract":{{"path":"{cell.parent}","enc_cell_count":1}}}}\n',
                encoding="utf-8",
            )
            sample = root / "sample.nmea"
            sample.write_text(
                "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n",
                encoding="ascii",
            )
            config = root / "config.ini"
            config.write_text(
                "[charts]\n"
                "package = state\n"
                "value = AK\n"
                f"output = {charts}\n"
                "max_age_days = 30\n"
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
            original_revision_path = os.environ.get("NOAA_NAVIONICS_SOURCE_REVISION_PATH")
            original_boot_id_path = report_module.BOOT_ID_PATH
            os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = str(revision)
            report_module.BOOT_ID_PATH = boot_id
            try:
                report = build_status_report(config_path=config, gps_sample=sample)
            finally:
                report_module.BOOT_ID_PATH = original_boot_id_path
                if original_revision_path is None:
                    os.environ.pop("NOAA_NAVIONICS_SOURCE_REVISION_PATH", None)
                else:
                    os.environ["NOAA_NAVIONICS_SOURCE_REVISION_PATH"] = original_revision_path
            self.assertIn("checks", report)
            self.assertIn("services", report)
            self.assertIn("system_services", report)
            self.assertIn("service_checks", report)
            self.assertEqual(report["app"]["source_revision"], "abc123")
            self.assertEqual(report["config"]["extract"], True)
            self.assertEqual(report["config"]["keep_zip"], True)
            self.assertEqual(report["config"]["force"], True)
            self.assertEqual(report["host"]["boot_id"], "boot-abc")
            self.assertEqual(report["manifest"]["path"], str(manifest))
            self.assertEqual(report["manifest"]["exists"], True)
            self.assertEqual(report["manifest"]["created_at"], now)
            self.assertEqual(report["manifest"]["package"], "Test")
            self.assertEqual(report["manifest"]["package_filename"], "AK_ENCs.zip")
            self.assertEqual(report["manifest"]["url"], "file:///test.zip")
            self.assertEqual(report["manifest"]["download_path"], str(charts / "AK_ENCs.zip"))
            self.assertEqual(report["manifest"]["download_bytes"], 123)
            self.assertEqual(report["manifest"]["sha256"], "abc")
            self.assertEqual(report["manifest"]["extract_path"], str(cell.parent))
            self.assertEqual(report["manifest"]["enc_cell_count"], 1)
            self.assertFalse(report["ok"])
            text = format_status_text(report)
            self.assertIn("Ready: no", text)
            self.assertIn("Boot ID: boot-abc", text)
            self.assertIn("revision abc123", text)
            self.assertIn("package_filename: AK_ENCs.zip", text)
            self.assertIn("download_bytes: 123", text)
            self.assertIn(f"extract_path: {cell.parent}", text)
            self.assertIn("Service Checks:", text)
            self.assertIn("System Services:", text)
            output = root / "status.json"
            write_status_report(report, output)
            self.assertTrue(output.exists())

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
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics sync-charts --config /home/pi/.config/noaa-navionics/config.ini --retries 5 --retry-delay 30 ; }",
                    "Type": "oneshot",
                    "TimeoutStartUSec": "2h",
                    "Restart": "on-failure",
                    "RestartUSec": "30min",
                    "StartLimitIntervalUSec": "6h",
                    "StartLimitBurst": "3",
                },
            },
            "noaa-navionics.timer": {
                "enabled": "enabled",
                "active": "active",
                "properties": {
                    "TimersCalendar": "{ OnCalendar=weekly ; NextElapseUSecRealtime=Mon 2026-07-06 00:00:00 UTC }",
                    "Persistent": "yes",
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
                },
            },
            "noaa-navionics-preflight.service": {
                "enabled": "enabled",
                "active": "inactive",
                "properties": {
                    "ExecStart": "{ path=/home/pi/.local/bin/noaa-navionics ; argv[]=/home/pi/.local/bin/noaa-navionics status-report --config /home/pi/.config/noaa-navionics/config.ini --gps-seconds 10 --output /home/pi/.cache/noaa-navionics/status.json ; }",
                    "Type": "oneshot",
                    "EnvironmentFiles": "/home/pi/.config/noaa-navionics/launcher.env",
                    "Restart": "on-failure",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "5min",
                    "StartLimitBurst": "5",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        settings_checks = [check for check in checks if check.name.endswith("Settings")]

        self.assertEqual(len(settings_checks), 4)
        self.assertTrue(all(check.ok for check in settings_checks))

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
                    "Restart": "no",
                    "RestartUSec": "30s",
                    "StartLimitIntervalUSec": "5min",
                    "StartLimitBurst": "5",
                },
            },
        }
        system_services = {
            "available": True,
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        boot_settings = next(check for check in checks if check.name == "Boot Readiness Settings")

        self.assertFalse(boot_settings.ok)
        self.assertIn("Type=simple", boot_settings.detail)
        self.assertIn("Restart=no", boot_settings.detail)

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
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        chart_settings = next(check for check in checks if check.name == "Chart Sync Settings")

        self.assertFalse(chart_settings.ok)
        self.assertIn("missing --config", chart_settings.detail)
        self.assertIn("missing --retries 5", chart_settings.detail)

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
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        sync_check = next(check for check in checks if check.name == "Chart Sync")

        self.assertTrue(sync_check.ok)
        self.assertIn("manifest freshness", sync_check.detail)

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
            "gpsd.service": {"enabled": "disabled", "active": "active"},
            "chrony.service": {"enabled": "enabled", "active": "active"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        gpsd_check = next(check for check in checks if check.name == "GPSD Service")

        self.assertFalse(gpsd_check.ok)
        self.assertIn("disabled", gpsd_check.detail)

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
            "gpsd.service": {"enabled": "enabled", "active": "active"},
            "chrony.service": {"enabled": "disabled", "active": "inactive"},
        }

        checks = _service_readiness_checks(services, system_services, gps_mode="gpsd")
        chrony_check = next(check for check in checks if check.name == "Chrony Service")

        self.assertFalse(chrony_check.ok)
        self.assertIn("disabled", chrony_check.detail)


class GpsTests(unittest.TestCase):
    def test_parse_gga_sentence(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47"
        fix = parse_nmea_sentence(sentence)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertAlmostEqual(fix.latitude, 48.1173, places=4)
        self.assertAlmostEqual(fix.longitude, 11.5166667, places=4)
        self.assertEqual(fix.satellites, 8)
        self.assertEqual(fix.altitude_m, 545.4)

    def test_gga_time_without_date_uses_nearest_utc_day(self):
        before_midnight = _parse_time_today("000010", now=datetime(2026, 6, 29, 23, 59, 50, tzinfo=timezone.utc))
        after_midnight = _parse_time_today("235950", now=datetime(2026, 6, 30, 0, 0, 10, tzinfo=timezone.utc))

        self.assertEqual(before_midnight, datetime(2026, 6, 30, 0, 0, 10, tzinfo=timezone.utc))
        self.assertEqual(after_midnight, datetime(2026, 6, 29, 23, 59, 50, tzinfo=timezone.utc))

    def test_gga_fractional_time_rounds_across_midnight(self):
        rounded = _parse_time_today("235959.9999999", now=datetime(2026, 6, 29, 23, 59, 59, tzinfo=timezone.utc))

        self.assertEqual(rounded, datetime(2026, 6, 30, 0, 0, 0, tzinfo=timezone.utc))

    def test_parse_rmc_sentence(self):
        sentence = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A"
        fix = parse_nmea_sentence(sentence)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.timestamp.year, 1994)
        self.assertEqual(fix.speed_knots, 22.4)
        self.assertEqual(fix.course_degrees, 84.4)

    def test_parse_rmc_fractional_time_rounds_across_date(self):
        sentence = "$GPRMC,235959.9999999,A,4807.038,N,01131.000,E,0.0,0.0,290626,003.1,W"
        fix = parse_nmea_sentence(sentence)

        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.timestamp, datetime(2026, 6, 30, 0, 0, 0, tzinfo=timezone.utc))

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

    def test_gpx_logger_syncs_track_file_and_directory_to_disk(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0)
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

    def test_gpx_logger_does_not_overwrite_existing_file(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0)
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
            GPSFix(timestamp=datetime(2026, 6, 29, 23, 59, tzinfo=timezone.utc), latitude=1.0, longitude=2.0),
            GPSFix(timestamp=datetime(2026, 6, 30, 0, 1, tzinfo=timezone.utc), latitude=3.0, longitude=4.0),
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            with redirect_stdout(StringIO()):
                count, outputs = _log_rotating_tracks(iter(fixes), Path(tmpdir), deadline=None, sample=True)
            self.assertEqual(count, 2)
            self.assertEqual([path.name for path in outputs], ["track-20260629.gpx", "track-20260630.gpx"])
            self.assertIn('lat="1.00000000"', outputs[0].read_text(encoding="utf-8"))
            self.assertIn('lat="3.00000000"', outputs[1].read_text(encoding="utf-8"))

    def test_log_single_track_closes_gpx_on_stop_signal_exception(self):
        def fixes():
            yield GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0)
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
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
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
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
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

    def test_trackable_fixes_skip_reported_weak_quality(self):
        weak = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
            satellites=3,
            hdop=1.2,
        )
        good = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 1, tzinfo=timezone.utc),
            latitude=3.0,
            longitude=4.0,
            satellites=5,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()) as stderr:
            fixes = list(_trackable_fixes(iter([weak, good])))

        self.assertEqual(fixes, [good])
        self.assertIn("Skipping weak track fix", stderr.getvalue())

    def test_trackable_fixes_keep_position_only_fix(self):
        position_only = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
        )

        self.assertEqual(list(_trackable_fixes(iter([position_only]))), [position_only])

    def test_trackable_fixes_delay_position_only_until_next_fix(self):
        first = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
        )
        second = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 1, tzinfo=timezone.utc),
            latitude=3.0,
            longitude=4.0,
        )

        self.assertEqual(list(_trackable_fixes(iter([first, second]))), [first, second])

    def test_trackable_fixes_drop_pending_position_only_before_weak_quality(self):
        position_only = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc),
            latitude=1.0,
            longitude=2.0,
        )
        weak = GPSFix(
            timestamp=datetime(2026, 6, 29, 12, 1, tzinfo=timezone.utc),
            latitude=3.0,
            longitude=4.0,
            satellites=3,
            hdop=1.2,
        )

        with redirect_stderr(StringIO()):
            fixes = list(_trackable_fixes(iter([position_only, weak])))

        self.assertEqual(fixes, [])

    def test_shared_gps_quality_rejects_high_hdop(self):
        fix = GPSFix(latitude=1.0, longitude=2.0, satellites=8, hdop=9.9)

        self.assertIn("HDOP", gps_fix_quality_failure(fix))

    def test_shared_gps_quality_rejects_null_island_fix(self):
        fix = GPSFix(latitude=0.0, longitude=0.0, satellites=8, hdop=1.2)

        self.assertIn("0.000000, 0.000000", gps_fix_quality_failure(fix))

    def test_shared_gps_quality_rejects_out_of_range_coordinates(self):
        latitude = GPSFix(latitude=91.0, longitude=-149.0, satellites=8, hdop=1.2)
        longitude = GPSFix(latitude=61.0, longitude=-181.0, satellites=8, hdop=1.2)

        self.assertIn("latitude 91.000000 outside -90..90", gps_fix_quality_failure(latitude))
        self.assertIn("longitude -181.000000 outside -180..180", gps_fix_quality_failure(longitude))

    def test_shared_gps_quality_rejects_non_finite_coordinates(self):
        fix = GPSFix(latitude=math.nan, longitude=-149.0, satellites=8, hdop=1.2)

        self.assertIn("non-finite coordinates", gps_fix_quality_failure(fix))

    def test_track_signal_handler_raises_stop_exception(self):
        with self.assertRaisesRegex(_TrackLoggerStop, "SIGTERM"):
            _raise_track_logger_stop(signal.SIGTERM, None)

    def test_log_rotating_tracks_does_not_overwrite_existing_daily_file(self):
        fix = GPSFix(timestamp=datetime(2026, 6, 29, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0)
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
        fix = GPSFix(timestamp=datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc), latitude=1.0, longitude=2.0)
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

    def test_parse_gpsd_sky_uses_usat_and_hdop(self):
        payload = '{"class":"SKY","uSat":7,"nSat":11,"hdop":1.4}'
        fix = parse_gpsd_sky(payload)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.satellites, 7)
        self.assertEqual(fix.hdop, 1.4)

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
            result = check_gps_device("/dev/ttyACM0", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertTrue(result.ok)
        self.assertEqual(captured, {"device": "/dev/ttyACM0", "baud": 9600})

    def test_check_gps_device_rejects_low_satellite_count(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},4807.038,N,01131.000,E,1,03,0.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            result = check_gps_device("/dev/ttyACM0", baud=9600, seconds=1)
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
            result = check_gps_device("/dev/ttyACM0", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("HDOP", result.detail)

    def test_check_gps_device_rejects_null_island_fix(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            fix_time = datetime.now(timezone.utc).strftime("%H%M%S")
            return BytesIO(
                f"$GPGGA,{fix_time},0000.000,N,00000.000,E,1,08,0.9,545.4,M,46.9,M,,\n".encode("ascii")
            )

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            result = check_gps_device("/dev/ttyACM0", baud=9600, seconds=1)
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
            result = check_gps_device("/dev/ttyACM0", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertFalse(result.ok)
        self.assertIn("latitude 91.000000 outside -90..90", result.detail)

    def test_check_gps_device_rejects_stale_timestamped_fix(self):
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            return BytesIO(b"$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W\n")

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            result = check_gps_device("/dev/ttyACM0", baud=9600, seconds=1, max_fix_age_seconds=300)
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
            result = check_gps_device("/dev/ttyACM0", baud=9600, seconds=1, max_fix_age_seconds=300)
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
            health_module.iter_gpsd_fixes = lambda host, port, timeout: iter([stale])
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
            health_module.iter_gpsd_fixes = lambda host, port, timeout: iter([untimestamped])
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
            health_module.iter_gpsd_fixes = lambda host, port, timeout: iter([weak])
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
            health_module.iter_gpsd_fixes = lambda host, port, timeout: iter([invalid])
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
            health_module.iter_gpsd_fixes = lambda host, port, timeout: iter([invalid])
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
            health_module.iter_gpsd_fixes = lambda host, port, timeout: iter([position_only, weak])
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
            health_module.iter_gpsd_fixes = lambda host, port, timeout: iter([position_only, good])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertTrue(result.ok)
        self.assertIn("6 satellites", result.detail)
        self.assertIn("61.100000", result.detail)

    def test_check_gpsd_accepts_fresh_timestamped_fix(self):
        original = health_module.iter_gpsd_fixes
        fresh = GPSFix(
            timestamp=datetime.now(timezone.utc),
            latitude=61.0,
            longitude=-149.0,
            fix_quality=3,
        )

        try:
            health_module.iter_gpsd_fixes = lambda host, port, timeout: iter([fresh])
            result = check_gpsd(seconds=1, max_fix_age_seconds=300)
        finally:
            health_module.iter_gpsd_fixes = original

        self.assertTrue(result.ok)
        self.assertIn("61.000000", result.detail)

    def test_check_gps_device_path_reports_missing_device(self):
        result = check_gps_device_path("/dev/serial/by-id/no-such-gps")
        self.assertFalse(result.ok)
        self.assertIn("does not exist", result.detail)

    def test_check_gps_device_path_accepts_stable_symlink(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target = root / "ttyACM0"
            target.write_text("", encoding="ascii")
            stable = root / "dev" / "serial" / "by-id" / "usb-gps"
            stable.parent.mkdir(parents=True)
            stable.symlink_to(target)

            result = check_gps_device_path(str(stable))

            self.assertTrue(result.ok)
            self.assertIn("usb-gps", result.detail)

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

    def test_disk_check_requires_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "charts"
            path.write_text("not a directory", encoding="ascii")
            result = check_disk_space(path)
            self.assertFalse(result.ok)
            self.assertIn("not a directory", result.detail)

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
                    '"download":{"path":"","bytes":0,"sha256":""},'
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
                '"download":{"path":"","bytes":0,"sha256":""},'
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


class PiHealthTests(unittest.TestCase):
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

    def test_parse_throttled_value(self):
        self.assertEqual(_parse_throttled_value("throttled=0x50000"), 0x50000)
        self.assertEqual(_parse_throttled_value("throttled=3"), 3)
        self.assertIsNone(_parse_throttled_value("not-throttled"))

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

    def test_check_pi_throttling_allows_historical_events(self):
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
            self.assertTrue(result.ok)
            self.assertIn("historical", result.detail)

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


if __name__ == "__main__":
    unittest.main()
