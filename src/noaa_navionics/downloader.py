from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from http.client import HTTPException, IncompleteRead
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable, Optional, Union
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen
from datetime import datetime, timezone
import hashlib
import json
import os
import re
import shutil
import stat
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile

from ._safeio import cleanup_private_temp_file


BASE_URL = "https://www.charts.noaa.gov/ENCs/"
CATALOG_NAME = "ENCProdCat_19115.xml"
MANIFEST_NAME = "noaa-navionics-manifest.json"
DOWNLOAD_LOCK_NAME = ".noaa-navionics-download.lock"
DOWNLOAD_LOCK_STALE_SECONDS = 6 * 60 * 60
USER_AGENT = "noaa-navionics/0.1 (+https://www.charts.noaa.gov/ENCs/ENCs.shtml)"
BOOT_ID_PATH = Path("/proc/sys/kernel/random/boot_id")
BOOT_ID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

UPDATE_PACKAGES = {
    "one-day": "OneDay_ENCs.zip",
    "two-days": "TwoDays_ENCs.zip",
    "one-week": "OneWeek_ENCs.zip",
    "ten-days": "TenDays_ENCs.zip",
}
STATE_PACKAGES = {
    "AK",
    "AL",
    "AQ",
    "BS",
    "CA",
    "CT",
    "DE",
    "FL",
    "FM",
    "GA",
    "GT",
    "HI",
    "HT",
    "ID",
    "IL",
    "IN",
    "LA",
    "MA",
    "MD",
    "ME",
    "MH",
    "MI",
    "MN",
    "MS",
    "NC",
    "NH",
    "NJ",
    "NV",
    "NY",
    "OH",
    "OR",
    "PA",
    "PO",
    "PR",
    "PW",
    "RI",
    "SC",
    "SP",
    "TX",
    "VA",
    "VT",
    "WA",
    "WI",
}
COAST_GUARD_DISTRICT_PACKAGES = {1, 5, 7, 8, 9, 11, 13, 14, 17}
REGION_PACKAGES = {2, 3, 4, 6, 7, 8, 10, 12, 13, 14, 15, 17, 22, 24, 26, 30, 32, 34, 36, 40}


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
        if code not in STATE_PACKAGES:
            raise ValueError(f"state must be one of: {', '.join(sorted(STATE_PACKAGES))}")
        filename = f"{code}_ENCs.zip"
        return Package(f"State {code}", urljoin(base_url, filename), filename)

    if cgd:
        code = cgd.strip().upper().replace("CGD", "")
        if not code.isdigit():
            raise ValueError("Coast Guard district must be numeric, like 17")
        number = int(code)
        if number not in COAST_GUARD_DISTRICT_PACKAGES:
            supported = ", ".join(f"{value:02d}" for value in sorted(COAST_GUARD_DISTRICT_PACKAGES))
            raise ValueError(f"Coast Guard district must be one of: {supported}")
        filename = f"{number:02d}CGD_ENCs.zip"
        return Package(f"Coast Guard District {number:02d}", urljoin(base_url, filename), filename)

    if region:
        code = region.strip().upper().replace("REGION", "")
        if not code.isdigit():
            raise ValueError("region must be numeric, like 30")
        number = int(code)
        if number not in REGION_PACKAGES:
            supported = ", ".join(f"{value:02d}" for value in sorted(REGION_PACKAGES))
            raise ValueError(f"region must be one of: {supported}")
        filename = f"{number:02d}Region_ENCs.zip"
        return Package(f"Region {number:02d}", urljoin(base_url, filename), filename)

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
    _prepare_output_dir(output_path)
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

    if destination.is_symlink():
        raise RuntimeError(f"chart archive path is a symlink: {destination}")

    if destination.exists() and not force:
        destination_stat, digest = _hash_existing_download_path(destination)
        bytes_written = destination_stat.st_size
        result = DownloadResult(destination, package.url, bytes_written, skipped=True, sha256=digest)
        if package.filename == CATALOG_NAME:
            _validate_downloaded_catalog(destination)
        if extract and destination.suffix.lower() == ".zip":
            if _matching_previous_manifest(output_path, package, result, digest) is None:
                raise RuntimeError(
                    "existing chart ZIP does not match a prior verified manifest; "
                    f"rerun with --force or remove cached chart archive: {destination}"
                )
            extracted_to = extract_zip(destination, output_path / destination.stem)
            if not keep_zip:
                _remove_download_archive(destination, output_path, expected_stat=destination_stat)
            result = DownloadResult(destination, package.url, bytes_written, True, extracted_to, digest)
            write_manifest(output_path, package, result)
        return result

    if retries < 1:
        raise ValueError("retries must be at least 1")
    tmp_path = destination.with_suffix(destination.suffix + ".part")
    if tmp_path.exists() or tmp_path.is_symlink():
        raise RuntimeError(f"partial download already exists; remove interrupted chart update debris: {tmp_path}")
    request = Request(package.url, headers={"User-Agent": USER_AGENT})
    written = 0
    digest = ""
    download_url = package.url
    tmp_stat: Optional[os.stat_result] = None
    for attempt in range(1, retries + 1):
        hasher = hashlib.sha256()
        written = 0
        tmp_stat = None
        try:
            with urlopen(request, timeout=timeout) as response:
                download_url = _response_url(response, package.url)
                if not _download_url_matches_package(download_url, package.url):
                    raise URLError(
                        f"download URL {download_url} does not match package filename from "
                        f"{package.url} or uses a non-HTTPS redirect or non-NOAA host"
                    )
                total = _content_length(response)
                with _open_exclusive_private_binary(tmp_path) as target:
                    tmp_stat = os.fstat(target.fileno())
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
        except (HTTPError, URLError, TimeoutError, ConnectionError, HTTPException, OSError) as exc:
            if tmp_stat is not None:
                _remove_interrupted_download_partial(
                    tmp_path,
                    output_path,
                    missing_ok=True,
                    expected_stat=tmp_stat,
                )
            if attempt < retries and _retryable_download_error(exc):
                time.sleep(retry_delay)
                continue
            raise RuntimeError(f"download failed for {package.url}: {exc}") from exc
        digest = hasher.hexdigest()
        break

    try:
        if extract and destination.suffix.lower() == ".zip":
            _validate_downloaded_zip(tmp_path)
        if package.filename == CATALOG_NAME:
            _validate_downloaded_catalog(tmp_path)
    except Exception:
        _remove_interrupted_download_partial(
            tmp_path,
            output_path,
            missing_ok=True,
            expected_stat=tmp_stat,
        )
        raise
    _prepare_output_dir(output_path)
    if destination.is_symlink():
        _remove_interrupted_download_partial(
            tmp_path,
            output_path,
            missing_ok=True,
            expected_stat=tmp_stat,
        )
        raise RuntimeError(f"chart archive path is a symlink before promotion: {destination}")
    os.replace(tmp_path, destination)
    _fsync_directory(output_path)
    destination_stat = destination.lstat()
    extracted_to = None
    if extract and destination.suffix.lower() == ".zip":
        extracted_to = extract_zip(destination, output_path / destination.stem)
        if not keep_zip:
            _remove_download_archive(destination, output_path, expected_stat=destination_stat)

    result = DownloadResult(destination, download_url, written, False, extracted_to, digest)
    write_manifest(output_path, package, result)
    return result


def _hash_existing_download_path(path: Path) -> tuple[os.stat_result, str]:
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        raise RuntimeError(f"chart download path contains a symlink: {symlink_component}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        if path.is_symlink():
            raise RuntimeError(f"chart archive path is a symlink: {path}") from exc
        raise RuntimeError(f"could not open chart download path {path}: {exc}") from exc
    try:
        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"chart download path is not a regular file: {path}")
        if stat_result.st_uid != os.getuid():
            raise RuntimeError(
                f"chart download path {path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"chart download path {path} has permissions {mode:04o}, expected no group/other write bits"
            )
        hasher = hashlib.sha256()
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                hasher.update(chunk)
        return stat_result, hasher.hexdigest()
    finally:
        if fd >= 0:
            os.close(fd)


def _remove_download_archive(
    path: Path,
    output_path: Path,
    *,
    expected_stat: Optional[os.stat_result] = None,
) -> None:
    try:
        stat_result = path.lstat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect chart archive before removal {path}: {exc}") from exc
    if stat.S_ISLNK(stat_result.st_mode):
        raise RuntimeError(f"chart archive path is a symlink before removal: {path}")
    if not stat.S_ISREG(stat_result.st_mode):
        raise RuntimeError(f"chart archive path is not a regular file before removal: {path}")
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"chart archive path {path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
        )
    mode = stat_result.st_mode & 0o777
    if mode & 0o022:
        raise RuntimeError(
            f"chart archive path {path} has permissions {mode:04o}, expected no group/other write bits"
        )
    if expected_stat is not None and not os.path.samestat(stat_result, expected_stat):
        raise RuntimeError(f"chart archive path changed before cleanup; leaving it in place: {path}")
    cleanup_private_temp_file(path, label="chart archive cleanup", expected_stat=stat_result)


def _remove_interrupted_download_partial(
    path: Path,
    output_path: Path,
    *,
    missing_ok: bool = False,
    expected_stat: Optional[os.stat_result] = None,
) -> None:
    try:
        stat_result = path.lstat()
    except FileNotFoundError:
        if missing_ok:
            return
        raise
    except OSError as exc:
        raise RuntimeError(f"could not inspect partial download before cleanup {path}: {exc}") from exc
    if stat.S_ISLNK(stat_result.st_mode):
        raise RuntimeError(f"partial download path is a symlink before cleanup: {path}")
    if not stat.S_ISREG(stat_result.st_mode):
        raise RuntimeError(f"partial download path is not a regular file before cleanup: {path}")
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"partial download path {path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
        )
    mode = stat_result.st_mode & 0o777
    if mode & 0o022:
        raise RuntimeError(
            f"partial download path {path} has permissions {mode:04o}, expected no group/other write bits"
        )
    if expected_stat is not None and not os.path.samestat(stat_result, expected_stat):
        raise RuntimeError(f"partial download path changed before cleanup; leaving it in place: {path}")
    cleanup_private_temp_file(path, label="partial download cleanup", expected_stat=stat_result)


def extract_zip(zip_path: Path, destination: Path) -> Path:
    destination = Path(destination).expanduser()
    parent = destination.parent
    _prepare_output_dir(parent)
    if destination.is_symlink():
        raise RuntimeError(f"chart extraction destination is a symlink: {destination}")
    if destination.exists() and not destination.is_dir():
        raise RuntimeError(f"chart extraction destination is not a directory: {destination}")
    _validate_zip_members_and_crc(zip_path, label="chart ZIP")
    staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}.", suffix=".extracting", dir=parent))
    previous = parent / f".{destination.name}.previous"
    try:
        staging_root = staging.resolve()
        with zipfile.ZipFile(zip_path) as archive:
            for member in archive.infolist():
                if _zip_member_path_is_unsafe(member.filename):
                    raise RuntimeError(f"unsafe ZIP member path: {member.filename}")
                target = staging / member.filename
                try:
                    target.resolve().relative_to(staging_root)
                except ValueError as exc:
                    raise RuntimeError(f"unsafe ZIP member path: {member.filename}") from exc
            archive.extractall(staging)
        _harden_extracted_chart_tree(staging)
        if count_enc_cells(staging) <= 0:
            raise RuntimeError(f"extracted ZIP contains no ENC .000 cells: {zip_path}")
        _fsync_tree(staging)
    except Exception:
        _remove_path(staging, missing_ok=True, label="chart extraction staging")
        raise

    moved_existing_to_previous = False
    installed_staging = False
    try:
        _prepare_output_dir(parent)
        if destination.is_symlink():
            raise RuntimeError(f"chart extraction destination is a symlink before promotion: {destination}")
        if previous.exists() or previous.is_symlink():
            _remove_path(previous, label="previous chart extraction")
        if destination.exists():
            destination.rename(previous)
            moved_existing_to_previous = True
        staging.rename(destination)
        installed_staging = True
        _fsync_directory(parent)
    except Exception:
        if installed_staging and destination.exists():
            _remove_path(destination, label="new chart extraction")
        if moved_existing_to_previous and previous.exists() and not destination.exists():
            previous.rename(destination)
            _fsync_directory(parent)
        _remove_path(staging, missing_ok=True, label="chart extraction staging")
        raise
    else:
        _remove_path(previous, missing_ok=True, label="previous chart extraction")
        _fsync_directory(parent)
    return destination


def _zip_member_path_is_unsafe(filename: str) -> bool:
    if not filename or "\\" in filename:
        return True
    member_path = PurePosixPath(filename)
    if member_path.is_absolute():
        return True
    stripped = filename.rstrip("/")
    if not stripped:
        return True
    parts = stripped.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        return True
    if ":" in parts[0]:
        return True
    return False


def _validate_downloaded_zip(zip_path: Path) -> None:
    enc_cell_count = _validate_zip_members_and_crc(zip_path, label="downloaded ZIP")
    if enc_cell_count <= 0:
        raise RuntimeError(f"downloaded ZIP contains no ENC .000 cells: {zip_path}")


def _validate_downloaded_catalog(catalog_path: Path) -> None:
    try:
        for entry in iter_catalog_entries(catalog_path):
            if _catalog_entry_name_looks_like_enc(entry.name) and entry.url.lower().endswith(".zip"):
                return
    except ET.ParseError as exc:
        raise RuntimeError(f"downloaded catalog XML is not parseable: {catalog_path}") from exc
    except OSError as exc:
        raise RuntimeError(f"could not read downloaded catalog XML {catalog_path}: {exc}") from exc
    raise RuntimeError(f"downloaded catalog XML contains no NOAA ENC chart metadata: {catalog_path}")


def _catalog_entry_name_looks_like_enc(name: str) -> bool:
    value = name.strip().upper()
    return len(value) >= 6 and value.startswith("US") and value.isalnum()


def _validate_zip_members_and_crc(zip_path: Path, *, label: str) -> int:
    try:
        with zipfile.ZipFile(zip_path) as archive:
            for member in archive.infolist():
                if _zip_member_path_is_unsafe(member.filename):
                    raise RuntimeError(f"{label} has unsafe member path: {member.filename}")
            bad_member = archive.testzip()
            if bad_member is not None:
                raise RuntimeError(f"{label} has a failed CRC member: {bad_member}")
            enc_cell_count = sum(
                1
                for member in archive.infolist()
                if not member.is_dir() and member.filename.lower().endswith(".000")
            )
    except zipfile.BadZipFile as exc:
        raise RuntimeError(f"{label} is not a valid archive: {zip_path}") from exc
    return enc_cell_count


def _harden_extracted_chart_tree(root: Path) -> None:
    root = Path(root)
    for current_root, dirnames, filenames in os.walk(root):
        current = Path(current_root)
        _harden_extracted_chart_path(current, directory=True)
        for dirname in list(dirnames):
            _harden_extracted_chart_path(current / dirname, directory=True)
        for filename in filenames:
            _harden_extracted_chart_path(current / filename, directory=False)


def _harden_extracted_chart_path(path: Path, *, directory: bool) -> None:
    try:
        stat_result = path.lstat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect extracted chart path before install {path}: {exc}") from exc
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"extracted chart path {path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
        )
    if directory:
        if not stat.S_ISDIR(stat_result.st_mode):
            raise RuntimeError(f"extracted chart path is not a directory before install: {path}")
        mode = 0o700
    else:
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"extracted chart path is not a regular file before install: {path}")
        mode = 0o600
    try:
        os.chmod(path, mode)
    except OSError as exc:
        raise RuntimeError(f"could not make extracted chart path private before install {path}: {exc}") from exc
    try:
        current_stat = path.lstat()
    except OSError as exc:
        raise RuntimeError(f"could not reinspect extracted chart path before install {path}: {exc}") from exc
    if directory and not stat.S_ISDIR(current_stat.st_mode):
        raise RuntimeError(f"extracted chart path changed before install: {path}")
    if not directory and not stat.S_ISREG(current_stat.st_mode):
        raise RuntimeError(f"extracted chart path changed before install: {path}")
    current_mode = current_stat.st_mode & 0o777
    if current_mode != mode:
        raise RuntimeError(
            f"extracted chart path {path} has permissions {current_mode:04o}, expected {mode:04o}"
        )


def sha256_file(path: Path) -> str:
    _, digest = _hash_existing_download_path(Path(path).expanduser())
    return digest


def _open_exclusive_private_binary(path: Path):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)
        return os.fdopen(fd, "wb")
    except Exception:
        os.close(fd)
        raise


def _remove_path(path: Path, *, missing_ok: bool = False, label: str = "chart update path") -> None:
    try:
        validated_stat = _validate_removable_chart_tree(path, label=label)
        current_stat = path.lstat()
        if not os.path.samestat(validated_stat, current_stat):
            raise RuntimeError(f"{label} changed before cleanup; leaving it in place: {path}")
        if stat.S_ISDIR(validated_stat.st_mode):
            if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):
                raise RuntimeError(
                    "Python shutil.rmtree is not symlink-attack resistant on this platform; "
                    f"leaving {label} in place: {path}"
                )
            shutil.rmtree(path)
        else:
            parent_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
            try:
                name_stat = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
                if not os.path.samestat(validated_stat, name_stat):
                    raise RuntimeError(f"{label} changed before cleanup; leaving it in place: {path}")
                os.unlink(path.name, dir_fd=parent_fd)
            finally:
                os.close(parent_fd)
    except FileNotFoundError:
        if not missing_ok:
            raise


def _validate_removable_chart_tree(path: Path, *, label: str) -> os.stat_result:
    def validate_one(candidate: Path) -> os.stat_result:
        try:
            stat_result = candidate.lstat()
        except FileNotFoundError:
            raise
        except OSError as exc:
            raise RuntimeError(f"could not inspect {label} before cleanup {candidate}: {exc}") from exc
        if stat.S_ISLNK(stat_result.st_mode):
            raise RuntimeError(f"{label} path is a symlink before cleanup: {candidate}")
        if not (stat.S_ISDIR(stat_result.st_mode) or stat.S_ISREG(stat_result.st_mode)):
            raise RuntimeError(f"{label} path is not a regular file or directory before cleanup: {candidate}")
        if stat_result.st_uid != os.getuid():
            raise RuntimeError(f"{label} path {candidate} is owned by uid {stat_result.st_uid}, expected {os.getuid()}")
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(f"{label} path {candidate} has permissions {mode:04o}, expected no group/other write bits")
        return stat_result

    root_stat = validate_one(path)
    if not stat.S_ISDIR(root_stat.st_mode):
        return root_stat
    for current_root, dirnames, filenames in os.walk(path):
        current = Path(current_root)
        validate_one(current)
        for name in [*dirnames, *filenames]:
            validate_one(current / name)
    return root_stat


def _fsync_tree(root: Path) -> None:
    path = Path(root)
    if not path.exists():
        return
    for current_root, dirnames, filenames in os.walk(path):
        current = Path(current_root)
        dirnames[:] = [dirname for dirname in dirnames if not (current / dirname).is_symlink()]
        for filename in filenames:
            file_path = current / filename
            try:
                initial = file_path.lstat()
            except OSError:
                continue
            if not stat.S_ISREG(initial.st_mode):
                continue
            try:
                fd = os.open(file_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            except OSError:
                continue
            try:
                opened = os.fstat(fd)
                if stat.S_ISREG(opened.st_mode):
                    os.fsync(fd)
            except OSError:
                pass
            finally:
                os.close(fd)
        for dirname in dirnames:
            _fsync_directory(current / dirname)
        _fsync_directory(current)


def _fsync_directory(path: Path) -> None:
    try:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(Path(path), flags)
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
    lock_text = (
        f"pid={os.getpid()} "
        f"boot_id={_current_boot_id()} "
        f"created_at={datetime.now(timezone.utc).isoformat()}\n"
    )
    while True:
        try:
            lock_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            opened_fd = os.open(lock_path, lock_flags, 0o600)
        except FileExistsError as exc:
            if lock_path.is_symlink():
                raise RuntimeError(f"chart update lock path is a symlink: {lock_path}") from exc
            stale_lock_stat = _validate_stale_lock_for_cleanup(lock_path)
            if _lock_is_stale(lock_path):
                cleanup_private_temp_file(
                    lock_path,
                    label="chart update lock cleanup",
                    expected_stat=stale_lock_stat,
                )
                continue
            raise RuntimeError(f"chart update already in progress; lock exists at {lock_path}") from exc
        except OSError as exc:
            if lock_path.is_symlink():
                raise RuntimeError(f"chart update lock path is a symlink: {lock_path}") from exc
            raise
        try:
            lock_fd = opened_fd
            lock_stat = os.fstat(lock_fd)
            os.fchmod(lock_fd, 0o600)
            os.write(lock_fd, lock_text.encode("ascii"))
            os.fsync(lock_fd)
            _fsync_directory(output_path)
            break
        except OSError as exc:
            os.close(lock_fd)
            lock_fd = None
            cleanup_private_temp_file(lock_path, label="chart update lock cleanup", expected_stat=lock_stat)
            if lock_path.is_symlink():
                raise RuntimeError(f"chart update lock path is a symlink: {lock_path}") from exc
            raise
    try:
        yield
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        try:
            if lock_path.is_symlink():
                return
            if _read_chart_update_lock_text(lock_path) == lock_text:
                cleanup_private_temp_file(lock_path, label="chart update lock cleanup", expected_stat=lock_stat)
        except FileNotFoundError:
            pass
        except RuntimeError:
            pass


def _validate_stale_lock_for_cleanup(lock_path: Path) -> os.stat_result:
    try:
        lock_stat = lock_path.lstat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect stale chart update lock before cleanup: {lock_path}: {exc}") from exc
    if not stat.S_ISREG(lock_stat.st_mode):
        raise RuntimeError(f"chart update lock path is not a regular file; leaving it in place: {lock_path}")
    expected_uid = os.getuid()
    if lock_stat.st_uid != expected_uid:
        raise RuntimeError(
            f"chart update lock path is owned by uid {lock_stat.st_uid}, "
            f"expected {expected_uid}; leaving it in place: {lock_path}"
        )
    mode = lock_stat.st_mode & 0o777
    if mode != 0o600:
        raise RuntimeError(
            f"chart update lock path has permissions {mode:04o}, "
            f"expected private 0600; leaving it in place: {lock_path}"
        )
    return lock_stat


def _lock_is_stale(lock_path: Path, *, stale_seconds: int = DOWNLOAD_LOCK_STALE_SECONDS) -> bool:
    try:
        age_seconds = time.time() - lock_path.lstat().st_mtime
    except OSError:
        return False
    if age_seconds <= stale_seconds:
        return False
    lock_text = _read_chart_update_lock_text(lock_path)
    owner_pid = _lock_field(lock_text, "pid")
    owner_boot_id = _lock_field(lock_text, "boot_id")
    if owner_pid and owner_pid.isdigit():
        current_boot_id = _current_boot_id()
        if _valid_boot_id(owner_boot_id) and _valid_boot_id(current_boot_id) and owner_boot_id != current_boot_id:
            return True
        if _pid_is_running(int(owner_pid)):
            return False
    return True


def _read_chart_update_lock_text(lock_path: Path) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(lock_path, flags)
    except FileNotFoundError:
        raise
    except OSError as exc:
        if lock_path.is_symlink():
            raise RuntimeError(f"chart update lock path is a symlink: {lock_path}") from exc
        raise RuntimeError(f"could not open chart update lock: {lock_path}: {exc}") from exc

    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"chart update lock path is not a regular file; leaving it in place: {lock_path}")
        expected_uid = os.getuid()
        if opened.st_uid != expected_uid:
            raise RuntimeError(
                f"chart update lock path is owned by uid {opened.st_uid}, "
                f"expected {expected_uid}; leaving it in place: {lock_path}"
            )
        mode = opened.st_mode & 0o777
        if mode != 0o600:
            raise RuntimeError(
                f"chart update lock path has permissions {mode:04o}, "
                f"expected private 0600; leaving it in place: {lock_path}"
            )
        with os.fdopen(fd, encoding="ascii", errors="ignore") as handle:
            fd = -1
            return handle.read()
    finally:
        if fd >= 0:
            os.close(fd)


def _lock_field(lock_text: str, name: str) -> str:
    prefix = f"{name}="
    for field in lock_text.split():
        if field.startswith(prefix):
            return field[len(prefix) :].strip()
    return ""


def _current_boot_id() -> str:
    try:
        value = _read_current_boot_id_text(BOOT_ID_PATH)
    except (OSError, RuntimeError):
        return ""
    return value if _valid_boot_id(value) else ""


def _read_current_boot_id_text(path: Path) -> str:
    target = Path(path)
    try:
        before = os.stat(target, follow_symlinks=False)
    except OSError:
        if target.is_symlink():
            raise RuntimeError(f"current boot ID path is a symlink: {target}")
        raise
    if stat.S_ISLNK(before.st_mode):
        raise RuntimeError(f"current boot ID path is a symlink: {target}")
    if not stat.S_ISREG(before.st_mode):
        raise RuntimeError(f"current boot ID path is not a regular file: {target}")
    try:
        fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        if target.is_symlink():
            raise RuntimeError(f"current boot ID path is a symlink: {target}")
        raise
    try:
        opened = os.fstat(fd)
        if before.st_dev != opened.st_dev or before.st_ino != opened.st_ino:
            raise RuntimeError(f"current boot ID path changed before it could be read: {target}")
        if not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"current boot ID path is not a regular file when opened: {target}")
        with os.fdopen(fd, encoding="ascii") as handle:
            fd = -1
            return handle.read().strip()
    finally:
        if fd >= 0:
            os.close(fd)


def _valid_boot_id(value: str) -> bool:
    return bool(BOOT_ID_RE.fullmatch(value))


def _pid_is_running(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def write_manifest(output_dir: Union[Path, str], package: Package, result: DownloadResult) -> Path:
    output_path = Path(output_dir).expanduser()
    _prepare_output_dir(output_path)
    digest = result.sha256
    if not digest and result.path.exists():
        digest = sha256_file(result.path)
    created_at, created_at_source = _manifest_created_at(output_path, package, result, digest)
    download_url = _manifest_download_url(output_path, package, result, digest)
    manifest = {
        "created_at": created_at,
        "created_at_source": created_at_source,
        "package": {
            "label": package.label,
            "url": package.url,
            "filename": package.filename,
        },
        "download": {
            "path": str(result.path),
            "url": download_url,
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
    _validate_manifest_replace_target(target)
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
        _prepare_output_dir(output_path)
        _validate_manifest_replace_target(target)
        os.replace(tmp_path, target)
        _fsync_directory(output_path)
    finally:
        if tmp_path is not None:
            cleanup_private_temp_file(tmp_path, label="chart manifest temp")
    return target


def _validate_manifest_replace_target(target: Path) -> None:
    if target.is_symlink():
        raise RuntimeError(f"refusing to replace symlinked chart manifest path: {target}")
    if not target.exists():
        return
    if not target.is_file():
        raise RuntimeError(f"refusing to replace non-regular chart manifest path: {target}")
    try:
        stat_result = target.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect chart manifest path before replacement {target}: {exc}") from exc
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"refusing to replace chart manifest path {target} owned by uid {stat_result.st_uid}, "
            f"expected {os.getuid()}"
        )
    mode = stat_result.st_mode & 0o777
    if mode & 0o022:
        raise RuntimeError(
            f"refusing to replace chart manifest path {target} with permissions {mode:04o}; "
            "expected no group/other write bits"
        )


def _prepare_output_dir(output_path: Path) -> None:
    symlink_component = _first_symlink_ancestor(output_path)
    if symlink_component is not None:
        raise RuntimeError(f"chart output path contains a symlink: {symlink_component}")
    output_path.mkdir(parents=True, exist_ok=True)
    symlink_component = _first_symlink_ancestor(output_path)
    if symlink_component is not None:
        raise RuntimeError(f"chart output path contains a symlink: {symlink_component}")
    if not output_path.is_dir():
        raise RuntimeError(f"chart output path is not a directory: {output_path}")
    try:
        stat_result = output_path.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect chart output directory {output_path}: {exc}") from exc
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"chart output directory {output_path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
        )
    try:
        os.chmod(output_path, 0o700)
    except OSError as exc:
        raise RuntimeError(f"could not make chart output directory private: {output_path}: {exc}") from exc
    if output_path.is_symlink():
        raise RuntimeError(f"chart output directory {output_path} became a symlink after permission tightening")
    try:
        stat_result = output_path.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect chart output directory after permission tightening {output_path}: {exc}") from exc
    if stat_result.st_uid != os.getuid():
        raise RuntimeError(
            f"chart output directory {output_path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
        )
    mode = stat_result.st_mode & 0o777
    if mode & 0o077:
        raise RuntimeError(
            f"chart output directory {output_path} has permissions {mode:04o}, expected private 0700"
        )
    _fsync_directory(output_path)
    _fsync_directory(output_path.parent)


def _first_symlink_ancestor(path: Path) -> Optional[Path]:
    current = Path(path).expanduser()
    for candidate in [current, *current.parents]:
        if candidate.is_symlink():
            return candidate
    return None


def _manifest_created_at(
    output_path: Path,
    package: Package,
    result: DownloadResult,
    digest: str,
) -> tuple[str, str]:
    if not result.skipped:
        return _utc_now_text(), "download"
    previous_created_at = _matching_previous_manifest_created_at(output_path, package, result, digest)
    if previous_created_at:
        return previous_created_at, "previous-manifest"
    return _archive_mtime_text(result.path), "unverified-cache"


def _matching_previous_manifest_created_at(
    output_path: Path,
    package: Package,
    result: DownloadResult,
    digest: str,
) -> str:
    manifest = _matching_previous_manifest(output_path, package, result, digest)
    if manifest is None:
        return ""
    return str(manifest.get("created_at", "")).strip()


def _manifest_download_url(
    output_path: Path,
    package: Package,
    result: DownloadResult,
    digest: str,
) -> str:
    if not result.skipped:
        return result.url
    manifest = _matching_previous_manifest(output_path, package, result, digest)
    if manifest is None:
        return result.url
    download = manifest.get("download", {})
    if not isinstance(download, dict):
        return result.url
    previous_url = str(download.get("url", "")).strip()
    return previous_url or result.url


def _matching_previous_manifest(
    output_path: Path,
    package: Package,
    result: DownloadResult,
    digest: str,
) -> Optional[dict[str, object]]:
    manifest_path = output_path / MANIFEST_NAME
    if manifest_path.is_symlink():
        raise RuntimeError(f"previous chart manifest path is a symlink: {manifest_path}")
    if not manifest_path.exists():
        return None
    if not manifest_path.is_file():
        raise RuntimeError(f"previous chart manifest path is not a regular file: {manifest_path}")
    try:
        manifest_stat = manifest_path.stat()
    except OSError as exc:
        raise RuntimeError(f"could not inspect previous chart manifest path {manifest_path}: {exc}") from exc
    if manifest_stat.st_uid != os.getuid():
        raise RuntimeError(
            f"previous chart manifest path {manifest_path} is owned by uid {manifest_stat.st_uid}, "
            f"expected {os.getuid()}"
        )
    manifest_mode = manifest_stat.st_mode & 0o777
    if manifest_mode & 0o022:
        raise RuntimeError(
            f"previous chart manifest path {manifest_path} has permissions {manifest_mode:04o}, "
            "expected no group/other write bits"
        )
    try:
        manifest = read_manifest(output_path, expected_stat=manifest_stat)
    except RuntimeError:
        raise
    except Exception:
        return None
    created_at = str(manifest.get("created_at", "")).strip()
    created_at_source = str(manifest.get("created_at_source", "")).strip()
    package_section = manifest.get("package", {})
    download = manifest.get("download", {})
    if not created_at or not isinstance(package_section, dict) or not isinstance(download, dict):
        return None
    if created_at_source not in {"download", "previous-manifest"}:
        return None
    if package_section.get("filename") != package.filename or package_section.get("url") != package.url:
        return None
    previous_path = Path(str(download.get("path", ""))).expanduser()
    if previous_path.name != result.path.name:
        return None
    try:
        previous_bytes = int(download.get("bytes", 0))
    except (TypeError, ValueError):
        return None
    previous_digest = str(download.get("sha256", "")).strip().lower()
    if previous_bytes != result.bytes_written or previous_digest != digest.lower():
        return None
    previous_url = str(download.get("url", "")).strip()
    if previous_url and not _download_url_matches_package(previous_url, package.url):
        return None
    return manifest


def _response_url(response: object, fallback: str) -> str:
    geturl = getattr(response, "geturl", None)
    if callable(geturl):
        try:
            value = str(geturl()).strip()
        except Exception:
            value = ""
        if value:
            return value
    return fallback


def _download_url_matches_package(download_url: str, package_url: str) -> bool:
    if download_url == package_url:
        return True
    parsed_package = urlparse(package_url)
    if parsed_package.scheme.lower() != "https":
        return True
    parsed_download = urlparse(download_url)
    if parsed_download.scheme.lower() != "https":
        return False
    download_filename = Path(parsed_download.path).name
    package_filename = Path(parsed_package.path).name
    if not download_filename or not package_filename or download_filename != package_filename:
        return False
    return _is_noaa_host(parsed_package.hostname) and _is_noaa_host(parsed_download.hostname)


def _is_noaa_host(hostname: Optional[str]) -> bool:
    host = (hostname or "").strip(".").lower()
    return host == "noaa.gov" or host.endswith(".noaa.gov")


def _archive_mtime_text(path: Path) -> str:
    try:
        timestamp = Path(path).stat().st_mtime
    except OSError:
        return _utc_now_text()
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def _utc_now_text() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def read_manifest(
    output_dir: Union[Path, str],
    *,
    expected_stat: Optional[os.stat_result] = None,
) -> dict[str, object]:
    path = Path(output_dir).expanduser() / MANIFEST_NAME
    fd = _open_manifest_for_read(path, expected_stat=expected_stat)
    with os.fdopen(fd, encoding="utf-8") as handle:
        return json.load(handle)


def _open_manifest_for_read(path: Path, *, expected_stat: Optional[os.stat_result] = None) -> int:
    if path.is_symlink():
        raise RuntimeError(f"manifest path is a symlink: {path}")
    symlink_component = _first_symlink_ancestor(path.parent)
    if symlink_component is not None:
        raise RuntimeError(f"manifest directory contains a symlink: {symlink_component}")
    if path.parent.exists():
        if not path.parent.is_dir():
            raise RuntimeError(f"manifest parent is not a directory: {path.parent}")
        try:
            directory_stat = path.parent.stat()
        except OSError as exc:
            raise RuntimeError(f"could not inspect manifest directory {path.parent}: {exc}") from exc
        if directory_stat.st_uid != os.getuid():
            raise RuntimeError(
                f"manifest directory {path.parent} is owned by uid {directory_stat.st_uid}, "
                f"expected {os.getuid()}"
            )
        directory_mode = directory_stat.st_mode & 0o777
        if directory_mode & 0o022:
            raise RuntimeError(
                f"manifest directory {path.parent} has permissions {directory_mode:04o}, "
                "expected no group/other write bits"
            )
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        if path.is_symlink():
            raise RuntimeError(f"manifest path is a symlink: {path}")
        raise
    try:
        stat_result = os.fstat(fd)
        if expected_stat is not None and (
            stat_result.st_dev != expected_stat.st_dev
            or stat_result.st_ino != expected_stat.st_ino
        ):
            raise RuntimeError(f"manifest path changed before it could be read: {path}")
        if not stat.S_ISREG(stat_result.st_mode):
            raise RuntimeError(f"manifest path is not a regular file: {path}")
        if stat_result.st_uid != os.getuid():
            raise RuntimeError(
                f"manifest path {path} is owned by uid {stat_result.st_uid}, expected {os.getuid()}"
            )
        mode = stat_result.st_mode & 0o777
        if mode & 0o022:
            raise RuntimeError(
                f"manifest path {path} has permissions {mode:04o}, expected no group/other write bits"
            )
    except Exception:
        os.close(fd)
        raise
    return fd


def count_enc_cells(root: Optional[Path]) -> int:
    if root is None or not Path(root).exists():
        return 0
    return sum(1 for path in Path(root).rglob("*.000") if path.is_file() and not path.is_symlink())


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
    if isinstance(exc, (ConnectionError, IncompleteRead, HTTPException)):
        return True
    return isinstance(exc, (URLError, TimeoutError))


def _local_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def _text(elem: ET.Element) -> str:
    return "".join(elem.itertext()).strip()
