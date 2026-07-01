from __future__ import annotations

from pathlib import Path
from typing import Optional
import os
import stat
import sys


def cleanup_private_temp_file(
    path: Path,
    *,
    label: str,
    expected_uid: Optional[int] = None,
    expected_stat: Optional[os.stat_result] = None,
) -> None:
    target = Path(path)
    uid = os.getuid() if expected_uid is None else expected_uid
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(target, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as exc:
        print(f"{label} could not be inspected for cleanup; leaving it in place: {target}: {exc}", file=sys.stderr)
        return
    if not stat.S_ISREG(before.st_mode) or before.st_uid != uid or stat.S_IMODE(before.st_mode) & 0o022:
        print(f"{label} is not a trusted private file; leaving it in place: {target}", file=sys.stderr)
        return
    if expected_stat is not None and not os.path.samestat(before, expected_stat):
        print(f"{label} changed before cleanup; leaving it in place: {target}", file=sys.stderr)
        return

    try:
        dir_fd = os.open(target.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow)
    except OSError as exc:
        print(f"{label} directory could not be opened for cleanup; leaving it in place: {target}: {exc}", file=sys.stderr)
        return
    try:
        parent_stat = os.fstat(dir_fd)
        parent_mode = stat.S_IMODE(parent_stat.st_mode)
        if not stat.S_ISDIR(parent_stat.st_mode) or parent_stat.st_uid != uid or parent_mode & 0o022:
            print(f"{label} directory is not trusted for cleanup; leaving it in place: {target}", file=sys.stderr)
            return
        try:
            fd = os.open(target.name, os.O_RDONLY | nofollow, dir_fd=dir_fd)
        except FileNotFoundError:
            return
        except OSError as exc:
            print(f"{label} could not be opened for cleanup; leaving it in place: {target}: {exc}", file=sys.stderr)
            return
        try:
            opened = os.fstat(fd)
        finally:
            os.close(fd)
        if not os.path.samestat(before, opened):
            print(f"{label} changed before cleanup; leaving it in place: {target}", file=sys.stderr)
            return
        os.unlink(target.name, dir_fd=dir_fd)
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
