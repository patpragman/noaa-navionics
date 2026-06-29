from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Optional, Union
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin
from urllib.request import Request, urlopen
from datetime import datetime, timezone
import hashlib
import json
import os
import shutil
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile


BASE_URL = "https://www.charts.noaa.gov/ENCs/"
CATALOG_NAME = "ENCProdCat_19115.xml"
MANIFEST_NAME = "noaa-navionics-manifest.json"
DOWNLOAD_LOCK_NAME = ".noaa-navionics-download.lock"
DOWNLOAD_LOCK_STALE_SECONDS = 6 * 60 * 60
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
    sha256: str = ""


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
    retries: int = 1,
    retry_delay: float = 2.0,
    progress: Optional[ProgressCallback] = None,
) -> DownloadResult:
    output_path = Path(output_dir).expanduser()
    output_path.mkdir(parents=True, exist_ok=True)
    with _chart_update_lock(output_path):
        return _download_package_unlocked(
            package,
            output_path,
            extract=extract,
            keep_zip=keep_zip,
            force=force,
            timeout=timeout,
            retries=retries,
            retry_delay=retry_delay,
            progress=progress,
        )


def _download_package_unlocked(
    package: Package,
    output_path: Path,
    *,
    extract: bool,
    keep_zip: bool,
    force: bool,
    timeout: float,
    retries: int,
    retry_delay: float,
    progress: Optional[ProgressCallback],
) -> DownloadResult:
    destination = output_path / package.filename

    if destination.exists() and not force:
        digest = sha256_file(destination)
        bytes_written = destination.stat().st_size
        result = DownloadResult(destination, package.url, bytes_written, skipped=True, sha256=digest)
        if extract and destination.suffix.lower() == ".zip":
            extracted_to = extract_zip(destination, output_path / destination.stem)
            if not keep_zip:
                destination.unlink()
                _fsync_directory(output_path)
            result = DownloadResult(destination, package.url, bytes_written, True, extracted_to, digest)
            write_manifest(output_path, package, result)
        return result

    if retries < 1:
        raise ValueError("retries must be at least 1")
    tmp_path = destination.with_suffix(destination.suffix + ".part")
    request = Request(package.url, headers={"User-Agent": USER_AGENT})
    written = 0
    digest = ""
    for attempt in range(1, retries + 1):
        hasher = hashlib.sha256()
        written = 0
        try:
            with urlopen(request, timeout=timeout) as response:
                total = _content_length(response)
                with tmp_path.open("wb") as target:
                    while True:
                        chunk = response.read(1024 * 256)
                        if not chunk:
                            break
                        target.write(chunk)
                        hasher.update(chunk)
                        written += len(chunk)
                        if progress:
                            progress(written, total)
                    target.flush()
                    os.fsync(target.fileno())
                if total is not None and written != total:
                    raise URLError(f"incomplete download: received {written} of {total} bytes")
        except (HTTPError, URLError, TimeoutError) as exc:
            if tmp_path.exists():
                tmp_path.unlink()
            if attempt < retries and _retryable_download_error(exc):
                time.sleep(retry_delay)
                continue
            raise RuntimeError(f"download failed for {package.url}: {exc}") from exc
        digest = hasher.hexdigest()
        break

    os.replace(tmp_path, destination)
    _fsync_directory(output_path)
    extracted_to = None
    if extract and destination.suffix.lower() == ".zip":
        extracted_to = extract_zip(destination, output_path / destination.stem)
        if not keep_zip:
            destination.unlink()
            _fsync_directory(output_path)

    result = DownloadResult(destination, package.url, written, False, extracted_to, digest)
    write_manifest(output_path, package, result)
    return result


def extract_zip(zip_path: Path, destination: Path) -> Path:
    destination = Path(destination).expanduser()
    parent = destination.parent
    parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}.", suffix=".extracting", dir=parent))
    previous = parent / f".{destination.name}.previous"
    try:
        staging_root = staging.resolve()
        with zipfile.ZipFile(zip_path) as archive:
            for member in archive.infolist():
                target = staging / member.filename
                try:
                    target.resolve().relative_to(staging_root)
                except ValueError as exc:
                    raise RuntimeError(f"unsafe ZIP member path: {member.filename}") from exc
            archive.extractall(staging)
        if count_enc_cells(staging) <= 0:
            raise RuntimeError(f"extracted ZIP contains no ENC .000 cells: {zip_path}")
        _fsync_tree(staging)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    try:
        if previous.exists() or previous.is_symlink():
            _remove_path(previous)
        if destination.exists():
            destination.rename(previous)
        staging.rename(destination)
        _fsync_directory(parent)
    except Exception:
        if destination.exists():
            _remove_path(destination)
        if previous.exists() and not destination.exists():
            previous.rename(destination)
            _fsync_directory(parent)
        shutil.rmtree(staging, ignore_errors=True)
        raise
    else:
        _remove_path(previous, missing_ok=True)
        _fsync_directory(parent)
    return destination


def sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with Path(path).open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            hasher.update(chunk)
    return hasher.hexdigest()


def _remove_path(path: Path, *, missing_ok: bool = False) -> None:
    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    except FileNotFoundError:
        if not missing_ok:
            raise


def _fsync_tree(root: Path) -> None:
    path = Path(root)
    if not path.exists():
        return
    for current_root, dirnames, filenames in os.walk(path):
        current = Path(current_root)
        for filename in filenames:
            file_path = current / filename
            try:
                with file_path.open("rb") as handle:
                    os.fsync(handle.fileno())
            except OSError:
                continue
        for dirname in dirnames:
            _fsync_directory(current / dirname)
        _fsync_directory(current)


def _fsync_directory(path: Path) -> None:
    try:
        fd = os.open(Path(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


@contextmanager
def _chart_update_lock(output_path: Path):
    lock_path = Path(output_path) / DOWNLOAD_LOCK_NAME
    lock_fd: Optional[int] = None
    lock_text = f"pid={os.getpid()} created_at={datetime.now(timezone.utc).isoformat()}\n"
    while True:
        try:
            lock_fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            os.write(lock_fd, lock_text.encode("ascii"))
            break
        except FileExistsError as exc:
            if _lock_is_stale(lock_path):
                try:
                    lock_path.unlink()
                except FileNotFoundError:
                    continue
                except OSError:
                    pass
                continue
            raise RuntimeError(f"chart update already in progress; lock exists at {lock_path}") from exc
    try:
        yield
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        try:
            if lock_path.read_text(encoding="ascii", errors="ignore") == lock_text:
                lock_path.unlink()
        except FileNotFoundError:
            pass


def _lock_is_stale(lock_path: Path, *, stale_seconds: int = DOWNLOAD_LOCK_STALE_SECONDS) -> bool:
    try:
        age_seconds = time.time() - lock_path.stat().st_mtime
    except OSError:
        return False
    return age_seconds > stale_seconds


def write_manifest(output_dir: Union[Path, str], package: Package, result: DownloadResult) -> Path:
    output_path = Path(output_dir).expanduser()
    output_path.mkdir(parents=True, exist_ok=True)
    digest = result.sha256
    if not digest and result.path.exists():
        digest = sha256_file(result.path)
    manifest = {
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "package": {
            "label": package.label,
            "url": package.url,
            "filename": package.filename,
        },
        "download": {
            "path": str(result.path),
            "url": result.url,
            "bytes": result.bytes_written,
            "sha256": digest,
            "skipped": result.skipped,
        },
        "extract": {
            "path": str(result.extracted_to) if result.extracted_to else "",
            "enc_cell_count": count_enc_cells(result.extracted_to) if result.extracted_to else 0,
        },
    }
    target = output_path / MANIFEST_NAME
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=output_path,
            prefix=f".{target.name}.",
            suffix=".part",
            delete=False,
        ) as handle:
            tmp_path = Path(handle.name)
            handle.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, target)
        _fsync_directory(output_path)
    finally:
        if tmp_path is not None:
            try:
                tmp_path.unlink()
            except FileNotFoundError:
                pass
    return target


def read_manifest(output_dir: Union[Path, str]) -> dict[str, object]:
    path = Path(output_dir).expanduser() / MANIFEST_NAME
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def count_enc_cells(root: Optional[Path]) -> int:
    if root is None or not Path(root).exists():
        return 0
    return sum(1 for _ in Path(root).rglob("*.000"))


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


def _retryable_download_error(exc: BaseException) -> bool:
    if isinstance(exc, HTTPError):
        return exc.code in {408, 429, 500, 502, 503, 504}
    return isinstance(exc, (URLError, TimeoutError))


def _local_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def _text(elem: ET.Element) -> str:
    return "".join(elem.itertext()).strip()
