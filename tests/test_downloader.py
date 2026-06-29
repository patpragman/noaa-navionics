from pathlib import Path
import sys
import tempfile
import textwrap
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from noaa_navionics.downloader import MANIFEST_NAME, Package, download_package, package_for, read_manifest, search_catalog
from noaa_navionics.config import package_kwargs, read_config, write_default_config
from noaa_navionics.gps import GPXTrackLogger, iter_fixes, parse_gpsd_tpv, parse_nmea_sentence
from noaa_navionics.health import check_chart_dir, check_chart_manifest, check_gps_sample


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


if __name__ == "__main__":
    unittest.main()
