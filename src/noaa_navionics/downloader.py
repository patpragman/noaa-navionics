from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Optional, Union
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin
from urllib.request import Request, urlopen
import os
import xml.etree.ElementTree as ET
import zipfile


BASE_URL = "https://www.charts.noaa.gov/ENCs/"
CATALOG_NAME = "ENCProdCat_19115.xml"
USER_AGENT = "noaa-navionics/0.1 (+https://www.charts.noaa.gov/ENCs/ENCs.shtml)"

UPDATE_PACKAGES = {
    "one-day": "OneDay_ENCs.zip",
    "two-days": "TwoDays_ENCs.zip",
    "one-week": "OneWeek_ENCs.zip",
    "ten-days": "TenDays_ENCs.zip",
}


@dataclass(frozen=True)
class Package:
    label: str
    url: str
    filename: str


@dataclass(frozen=True)
class DownloadResult:
    path: Path
    url: str
    bytes_written: int
    skipped: bool = False
    extracted_to: Optional[Path] = None


@dataclass(frozen=True)
class CatalogEntry:
    name: str
    title: str
    url: str
    edition: str = ""
    states: tuple[str, ...] = ()
    regions: tuple[str, ...] = ()
    coast_guard_districts: tuple[str, ...] = ()
    zipfile_datetime: str = ""


ProgressCallback = Callable[[int, Optional[int]], None]


def package_for(
    *,
    state: Optional[str] = None,
    cgd: Optional[str] = None,
    region: Optional[str] = None,
    updates: Optional[str] = None,
    chart: Optional[str] = None,
    all_charts: bool = False,
    catalog: bool = False,
    base_url: str = BASE_URL,
) -> Package:
    selected = [
        bool(state),
        bool(cgd),
        bool(region),
        bool(updates),
        bool(chart),
        all_charts,
        catalog,
    ]
    if sum(selected) != 1:
        raise ValueError("choose exactly one package selector")

    if state:
        code = state.strip().upper()
        if len(code) != 2 or not code.isalpha():
            raise ValueError("state must be a two-letter NOAA state/territory code")
        filename = f"{code}_ENCs.zip"
        return Package(f"State {code}", urljoin(base_url, filename), filename)

    if cgd:
        code = cgd.strip().upper().replace("CGD", "")
        if not code.isdigit():
            raise ValueError("Coast Guard district must be numeric, like 17")
        filename = f"{int(code):02d}CGD_ENCs.zip"
        return Package(f"Coast Guard District {int(code):02d}", urljoin(base_url, filename), filename)

    if region:
        code = region.strip().upper().replace("REGION", "")
        if not code.isdigit():
            raise ValueError("region must be numeric, like 30")
        filename = f"{int(code):02d}Region_ENCs.zip"
        return Package(f"Region {int(code):02d}", urljoin(base_url, filename), filename)

    if updates:
        key = normalize_update_key(updates)
        filename = UPDATE_PACKAGES[key]
        return Package(f"Updates {key}", urljoin(base_url, filename), filename)

    if chart:
        code = chart.strip().upper()
        if not code.isalnum() or len(code) < 6:
            raise ValueError("chart must be an ENC cell name, like US5AK3CM")
        filename = f"{code}.zip"
        return Package(f"Chart {code}", urljoin(base_url, filename), filename)

    if all_charts:
        return Package("All ENCs", urljoin(base_url, "All_ENCs.zip"), "All_ENCs.zip")

    return Package("ENC Product Catalog", urljoin(base_url, CATALOG_NAME), CATALOG_NAME)


def normalize_update_key(value: str) -> str:
    key = value.strip().lower().replace("_", "-").replace(" ", "-")
    aliases = {
        "1": "one-day",
        "1-day": "one-day",
        "oneday": "one-day",
        "one-day": "one-day",
        "2": "two-days",
        "2-day": "two-days",
        "2-days": "two-days",
        "twoday": "two-days",
        "twodays": "two-days",
        "two-day": "two-days",
        "two-days": "two-days",
        "week": "one-week",
        "1-week": "one-week",
        "oneweek": "one-week",
        "one-week": "one-week",
        "10": "ten-days",
        "10-day": "ten-days",
        "10-days": "ten-days",
        "tenday": "ten-days",
        "tendays": "ten-days",
        "ten-day": "ten-days",
        "ten-days": "ten-days",
    }
    if key not in aliases:
        raise ValueError(f"updates must be one of: {', '.join(UPDATE_PACKAGES)}")
    return aliases[key]


def download_package(
    package: Package,
    output_dir: Union[Path, str],
    *,
    extract: bool = False,
    keep_zip: bool = True,
    force: bool = False,
    timeout: float = 60,
    progress: Optional[ProgressCallback] = None,
) -> DownloadResult:
    output_path = Path(output_dir).expanduser()
    output_path.mkdir(parents=True, exist_ok=True)
    destination = output_path / package.filename

    if destination.exists() and not force:
        result = DownloadResult(destination, package.url, destination.stat().st_size, skipped=True)
        if extract and destination.suffix.lower() == ".zip":
            extracted_to = extract_zip(destination, output_path / destination.stem)
            result = DownloadResult(destination, package.url, destination.stat().st_size, True, extracted_to)
        return result

    tmp_path = destination.with_suffix(destination.suffix + ".part")
    request = Request(package.url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(request, timeout=timeout) as response:
            total = _content_length(response)
            written = 0
            with tmp_path.open("wb") as target:
                while True:
                    chunk = response.read(1024 * 256)
                    if not chunk:
                        break
                    target.write(chunk)
                    written += len(chunk)
                    if progress:
                        progress(written, total)
    except (HTTPError, URLError, TimeoutError) as exc:
        if tmp_path.exists():
            tmp_path.unlink()
        raise RuntimeError(f"download failed for {package.url}: {exc}") from exc

    os.replace(tmp_path, destination)
    extracted_to = None
    if extract and destination.suffix.lower() == ".zip":
        extracted_to = extract_zip(destination, output_path / destination.stem)
        if not keep_zip:
            destination.unlink()

    return DownloadResult(destination, package.url, written, False, extracted_to)


def extract_zip(zip_path: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as archive:
        for member in archive.infolist():
            target = destination / member.filename
            resolved = target.resolve()
            if not str(resolved).startswith(str(destination.resolve())):
                raise RuntimeError(f"unsafe ZIP member path: {member.filename}")
        archive.extractall(destination)
    return destination


def download_catalog(output_dir: Union[Path, str], **kwargs: object) -> DownloadResult:
    return download_package(package_for(catalog=True), output_dir, **kwargs)


def iter_catalog_entries(source: Union[Path, str]) -> Iterable[CatalogEntry]:
    path = Path(source).expanduser()
    context = ET.iterparse(path, events=("end",))
    for _, elem in context:
        if _local_name(elem.tag) != "MD_Metadata":
            continue
        entry = _entry_from_metadata(elem)
        elem.clear()
        if entry:
            yield entry


def search_catalog(source: Union[Path, str], query: str, *, limit: int = 20) -> list[CatalogEntry]:
    needle = query.strip().lower()
    if not needle:
        return []

    matches: list[CatalogEntry] = []
    for entry in iter_catalog_entries(source):
        haystack = " ".join(
            [entry.name, entry.title, *entry.states, *entry.regions, *entry.coast_guard_districts]
        ).lower()
        if needle in haystack:
            matches.append(entry)
            if len(matches) >= limit:
                break
    return matches


def ensure_catalog(output_dir: Union[Path, str], *, timeout: float = 60, force: bool = False) -> Path:
    result = download_catalog(output_dir, timeout=timeout, force=force)
    return result.path


def _entry_from_metadata(elem: ET.Element) -> Optional[CatalogEntry]:
    name = _first_title(elem)
    if not name or name == "NOAA ENC Product Catalog":
        return None

    title = _first_alternate_title(elem)
    url = ""
    edition = ""
    states: list[str] = []
    regions: list[str] = []
    districts: list[str] = []
    zipfile_datetime = ""

    for node in elem.iter():
        local = _local_name(node.tag)
        value = _text(node)
        if not value:
            continue
        if local == "URL" and value.endswith(".zip"):
            url = value
        elif local == "CharacterString":
            lower = value.lower()
            if lower.startswith("state:"):
                states.append(value.split(":", 1)[1].strip())
            elif lower.startswith("region:"):
                regions.append(value.split(":", 1)[1].strip())
            elif lower.startswith("coast guard district:"):
                districts.append(value.split(":", 1)[1].strip())
            elif lower.startswith("zipfile date and time:"):
                zipfile_datetime = value.split(":", 1)[1].strip()
        elif local == "edition":
            edition = value

    if not url:
        url = urljoin(BASE_URL, f"{name}.zip")

    return CatalogEntry(
        name=name,
        title=title,
        url=url,
        edition=edition,
        states=tuple(states),
        regions=tuple(regions),
        coast_guard_districts=tuple(districts),
        zipfile_datetime=zipfile_datetime,
    )


def _first_title(elem: ET.Element) -> str:
    for node in elem.iter():
        if _local_name(node.tag) == "title":
            for child in node.iter():
                if _local_name(child.tag) == "CharacterString":
                    return _text(child)
    return ""


def _first_alternate_title(elem: ET.Element) -> str:
    for node in elem.iter():
        if _local_name(node.tag) == "alternateTitle":
            for child in node.iter():
                if _local_name(child.tag) == "CharacterString":
                    return _text(child)
    return ""


def _content_length(response: object) -> Optional[int]:
    headers = getattr(response, "headers", {})
    try:
        value = headers.get("Content-Length")
    except AttributeError:
        value = None
    if not value:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def _local_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def _text(elem: ET.Element) -> str:
    return "".join(elem.itertext()).strip()
