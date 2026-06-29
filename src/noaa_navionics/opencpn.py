from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
import os
import re


DEFAULT_OPENCPN_CONFIG_PATH = Path("~/.opencpn/opencpn.conf")
FLATPAK_OPENCPN_CONFIG_PATH = Path("~/.var/app/org.opencpn.OpenCPN/config/opencpn/opencpn.conf")

_SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*$")
_CHART_DIR_RE = re.compile(r"^\s*ChartDir(\d+)\s*=\s*(.*?)\s*$")


@dataclass(frozen=True)
class OpenCPNConfigResult:
    config_path: Path
    chart_dir: Path
    changed: bool
    key: str
    backup_path: Optional[Path] = None
    dry_run: bool = False


def opencpn_config_path(explicit: Optional[Path] = None) -> Path:
    if explicit:
        return Path(explicit).expanduser()
    candidates = [DEFAULT_OPENCPN_CONFIG_PATH.expanduser(), FLATPAK_OPENCPN_CONFIG_PATH.expanduser()]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def read_chart_directories(config_path: Optional[Path] = None) -> list[Path]:
    path = opencpn_config_path(config_path)
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8", errors="ignore")
    return [Path(value).expanduser() for _, value in _chart_dir_entries(text)]


def chart_directory_configured(chart_dir: Path, config_path: Optional[Path] = None) -> bool:
    wanted = _normalize_chart_dir(chart_dir)
    return any(_normalize_chart_dir(existing) == wanted for existing in read_chart_directories(config_path))


def configure_chart_directory(
    chart_dir: Path,
    *,
    config_path: Optional[Path] = None,
    backup: bool = True,
    dry_run: bool = False,
) -> OpenCPNConfigResult:
    target = opencpn_config_path(config_path)
    wanted = _normalize_chart_dir(chart_dir)
    original = target.read_text(encoding="utf-8", errors="ignore") if target.exists() else ""
    updated, changed, key = _set_chart_directory(original, wanted)
    backup_path = None

    if changed and not dry_run:
        target.parent.mkdir(parents=True, exist_ok=True)
        if backup and target.exists():
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            backup_path = target.with_name(f"{target.name}.noaa-navionics.{stamp}.bak")
            backup_path.write_bytes(target.read_bytes())
        tmp = target.with_suffix(target.suffix + ".part")
        tmp.write_text(updated, encoding="utf-8")
        os.replace(tmp, target)

    return OpenCPNConfigResult(
        config_path=target,
        chart_dir=wanted,
        changed=changed,
        key=key,
        backup_path=backup_path,
        dry_run=dry_run,
    )


def opencpn_running() -> bool:
    proc = Path("/proc")
    if not proc.exists():
        return False
    for comm in proc.glob("[0-9]*/comm"):
        try:
            if comm.read_text(encoding="utf-8", errors="ignore").strip() == "opencpn":
                return True
        except OSError:
            continue
    return False


def _set_chart_directory(text: str, chart_dir: Path) -> tuple[str, bool, str]:
    lines = text.splitlines(keepends=True)
    existing = _chart_dir_entries(text)
    for key, value in existing:
        if _normalize_chart_dir(Path(value)) == chart_dir:
            return text, False, key

    numbers = [_chart_dir_number(key) for key, _ in existing]
    next_number = max([number for number in numbers if number is not None], default=0) + 1
    key = f"ChartDir{next_number}"
    new_line = f"{key}={chart_dir}\n"

    start, end = _chart_directories_section(lines)
    if start is None:
        if lines and not lines[-1].endswith(("\n", "\r")):
            lines[-1] = lines[-1] + "\n"
        if lines and any(line.strip() for line in lines):
            lines.append("\n")
        lines.extend(["[ChartDirectories]\n", new_line])
        return "".join(lines), True, key

    insert_at = end if end is not None else len(lines)
    if insert_at > 0 and not lines[insert_at - 1].endswith(("\n", "\r")):
        lines[insert_at - 1] = lines[insert_at - 1] + "\n"
    lines.insert(insert_at, new_line)
    return "".join(lines), True, key


def _chart_dir_entries(text: str) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    in_section = False
    for line in text.splitlines():
        section = _SECTION_RE.match(line)
        if section:
            in_section = section.group(1).strip().lower() == "chartdirectories"
            continue
        if not in_section:
            continue
        match = _CHART_DIR_RE.match(line)
        if match:
            entries.append((f"ChartDir{match.group(1)}", match.group(2).strip()))
    return entries


def _chart_directories_section(lines: list[str]) -> tuple[Optional[int], Optional[int]]:
    start = None
    for index, line in enumerate(lines):
        section = _SECTION_RE.match(line)
        if not section:
            continue
        if section.group(1).strip().lower() == "chartdirectories":
            start = index
            continue
        if start is not None:
            return start, index
    return start, None


def _chart_dir_number(key: str) -> Optional[int]:
    match = re.match(r"ChartDir(\d+)$", key)
    return int(match.group(1)) if match else None


def _normalize_chart_dir(path: Path) -> Path:
    return Path(path).expanduser().resolve(strict=False)
