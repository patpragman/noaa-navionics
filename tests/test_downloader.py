from pathlib import Path
from datetime import datetime, timezone
from contextlib import redirect_stdout
from io import BytesIO, StringIO
import sys
import tempfile
import textwrap
import unittest
import zipfile
import os

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from noaa_navionics import health as health_module
from noaa_navionics.downloader import (
    MANIFEST_NAME,
    Package,
    download_package,
    extract_zip,
    package_for,
    read_manifest,
    search_catalog,
)
from noaa_navionics.config import package_kwargs, read_config, write_default_config
from noaa_navionics.cli import _log_rotating_tracks
from noaa_navionics.gps import GPSFix, GPXTrackLogger, daily_track_path, iter_fixes, parse_gpsd_tpv, parse_nmea_sentence
from noaa_navionics.health import (
    check_chart_dir,
    check_chart_manifest,
    check_gps_device,
    check_gps_sample,
    check_opencpn_chart_config,
    check_opencpn_gpsd_config,
    check_pi_throttling,
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
from noaa_navionics.report import build_status_report, format_status_text, write_status_report


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
            self.assertEqual(config.max_chart_age_days, 30)
            self.assertTrue(config.extract)

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
                "gpsd_port = 2947\n",
                encoding="utf-8",
            )
            config = read_config(path)
            self.assertEqual(package_kwargs(config), {"cgd": "17"})
            self.assertEqual(config.gps_mode, "serial")
            self.assertEqual(config.gps_device, "/dev/ttyACM0")
            self.assertEqual(config.gps_baud, 9600)
            self.assertEqual(config.max_chart_age_days, 14)
            self.assertFalse(config.keep_zip)
            self.assertFalse(config.force)


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

    def test_check_opencpn_chart_config_reports_missing_and_configured(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            config = root / "opencpn.conf"
            charts = root / "charts"

            missing = check_opencpn_chart_config(charts, config)
            self.assertFalse(missing.ok)

            configure_chart_directory(charts, config_path=config)
            configured = check_opencpn_chart_config(charts, config)
            self.assertTrue(configured.ok)

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

    def test_check_opencpn_gpsd_config_reports_missing_and_configured(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config = Path(tmpdir) / "opencpn.conf"

            missing = check_opencpn_gpsd_config(config_path=config)
            self.assertFalse(missing.ok)

            configure_gpsd_connection(config_path=config)
            configured = check_opencpn_gpsd_config(config_path=config)
            self.assertTrue(configured.ok)


class ManifestTests(unittest.TestCase):
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
            self.assertEqual(manifest["download"]["sha256"], result.sha256)
            self.assertEqual(manifest["extract"]["enc_cell_count"], 1)
            self.assertTrue(check_chart_manifest(output).ok)

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
                '"package":{"label":"Test","url":"file:///test.zip"},'
                '"download":{"sha256":"abc"},'
                '"extract":{"enc_cell_count":1}}\n',
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

            report = build_status_report(config_path=config, gps_sample=sample)
            self.assertIn("checks", report)
            self.assertIn("services", report)
            self.assertEqual(report["manifest"]["package"], "Test")
            self.assertFalse(report["ok"])
            text = format_status_text(report)
            self.assertIn("Ready: no", text)
            output = root / "status.json"
            write_status_report(report, output)
            self.assertTrue(output.exists())


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

    def test_parse_rmc_sentence(self):
        sentence = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A"
        fix = parse_nmea_sentence(sentence)
        self.assertIsNotNone(fix)
        assert fix is not None
        self.assertEqual(fix.timestamp.year, 1994)
        self.assertEqual(fix.speed_knots, 22.4)
        self.assertEqual(fix.course_degrees, 84.4)

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

    def test_check_gps_sample(self):
        sentence = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "sample.nmea"
            path.write_text(sentence, encoding="ascii")
            result = check_gps_sample(path)
            self.assertTrue(result.ok)
            self.assertIn("48.117300", result.detail)

    def test_check_gps_device_uses_configured_baud(self):
        captured = {}
        original = health_module.open_nmea_stream

        def fake_open_nmea_stream(device, baud=4800):
            captured["device"] = device
            captured["baud"] = baud
            return BytesIO(b"$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\n")

        try:
            health_module.open_nmea_stream = fake_open_nmea_stream
            result = check_gps_device("/dev/ttyACM0", baud=9600, seconds=1)
        finally:
            health_module.open_nmea_stream = original

        self.assertTrue(result.ok)
        self.assertEqual(captured, {"device": "/dev/ttyACM0", "baud": 9600})

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


class PiHealthTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
