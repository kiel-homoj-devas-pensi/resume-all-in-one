"""Explicitly managed runtime SQLite snapshots; never discover or restore old backups.

The root must be private to the gateway operator. Path checks defend accidental
reparse/hard-link redirection, not a hostile administrator replacing files between
system calls. No source path, database row or exception detail is included in reports.
"""

from __future__ import annotations

import hashlib
import json
import math
import multiprocessing
import os
import re
import sqlite3
import time
import uuid
from collections.abc import Iterator
from contextlib import closing, contextmanager
from dataclasses import asdict, dataclass
from multiprocessing.connection import Connection
from pathlib import Path
from typing import Any

RETENTION_SECONDS = 7 * 24 * 60 * 60
_MARKER = '{"format":"gateway-runtime-backups","version":1}\n'
_ID = re.compile(r"[0-9a-f]{32}\Z")
_ROLES = frozenset({"trial", "guest", "results"})
_PAYLOADS = ("staged.sqlite3", "backup.sqlite3")
_SIDECARS = tuple("staged.sqlite3" + suffix for suffix in ("-wal", "-shm", "-journal"))


class RuntimeBackupError(RuntimeError):
    """Only fixed, non-sensitive status codes may cross the management boundary."""


@dataclass(frozen=True, slots=True)
class ManagedBackup:
    backupId: str
    role: str
    createdAtEpoch: float
    expiresAtEpoch: float
    sha256: str
    sizeBytes: int


@dataclass(frozen=True, slots=True)
class CleanupReport:
    scanned: int
    deleted: int
    retained: int
    ignored: int
    failures: int
    overdue: int
    applied: bool


def _safePath(path: Path) -> Path:
    if not path.is_absolute() or ".." in path.parts:
        raise RuntimeBackupError("backup_path_invalid")
    if os.name == "nt" and (str(path).startswith("\\\\") or ":" in str(path)[2:]):
        raise RuntimeBackupError("backup_path_invalid")
    for candidate in (path, *path.parents):
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            continue
        if candidate.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
            raise RuntimeBackupError("backup_path_invalid")
        if candidate.is_file() and info.st_nlink != 1:
            raise RuntimeBackupError("backup_path_invalid")
    return path


def initializeRoot(root: Path) -> None:
    """Initialize only an empty, explicitly selected directory; never adopt old files."""
    root = _safePath(root)
    if not root.parent.is_dir():
        raise RuntimeBackupError("backup_path_invalid")
    root.mkdir(exist_ok=True)
    if not root.is_dir() or any(root.iterdir()):
        raise RuntimeBackupError("backup_root_not_empty")
    with (root / "registry.json").open("x", encoding="utf-8") as stream:
        stream.write(_MARKER)
        stream.flush()
        os.fsync(stream.fileno())


def _requireRoot(root: Path) -> None:
    _safePath(root)
    marker = _safePath(root / "registry.json")
    if not root.is_dir() or not marker.is_file() or marker.stat().st_size > 128:
        raise RuntimeBackupError("backup_registry_invalid")
    if marker.read_text(encoding="utf-8") != _MARKER:
        raise RuntimeBackupError("backup_registry_invalid")


@contextmanager
def _locked(root: Path) -> Iterator[None]:
    _requireRoot(root)
    lock = _safePath(root / "registry.lock")
    # OS advisory locks are released if the process terminates; no stale-lock guessing.
    with lock.open("a+b") as stream:
        stream.seek(0, os.SEEK_END)
        if stream.tell() == 0:
            stream.write(b"0")
            stream.flush()
        stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)  # type: ignore[attr-defined]
        except OSError:
            raise RuntimeBackupError("backup_busy") from None
        try:
            _requireRoot(root)
            yield
        finally:
            stream.seek(0)
            if os.name == "nt":
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)  # type: ignore[attr-defined]


def _copyWorker(source: str, staged: str, channel: Connection) -> None:
    try:
        with (
            closing(sqlite3.connect(Path(source).as_uri() + "?mode=ro", uri=True)) as src,
            closing(sqlite3.connect(staged)) as dst,
        ):
            src.backup(dst, pages=128, sleep=0.05)
            if dst.execute("PRAGMA journal_mode=DELETE").fetchone() != ("delete",):
                raise RuntimeBackupError("backup_failed")
            if dst.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise RuntimeBackupError("backup_failed")
            if dst.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise RuntimeBackupError("backup_failed")
        with Path(staged).open("r+b") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
            os.fsync(stream.fileno())
        channel.send((digest, Path(staged).stat().st_size))
    except BaseException:
        channel.send(None)
    finally:
        channel.close()


def _copyWithTimeout(source: Path, staged: Path, timeoutSeconds: float) -> tuple[str, int]:
    context = multiprocessing.get_context("spawn")
    receive, send = context.Pipe(duplex=False)
    process = context.Process(target=_copyWorker, args=(str(source), str(staged), send))
    started = False
    try:
        process.start()
        started = True
        send.close()
        process.join(timeoutSeconds)
        if process.is_alive():
            raise RuntimeBackupError("backup_timeout")
        if process.exitcode != 0 or not receive.poll():
            raise RuntimeBackupError("backup_failed")
        result = receive.recv()
        if result is None:
            raise RuntimeBackupError("backup_failed")
        digest, size = result
        return str(digest), int(size)
    finally:
        if started:
            if process.is_alive():
                process.terminate()
                process.join(5)
            if process.is_alive():
                process.kill()
                process.join(5)
            process.close()
        send.close()
        receive.close()


def createManagedBackup(
    root: Path, source: Path, *, role: str, timeoutSeconds: float = 60.0
) -> ManagedBackup:
    """Register creation time BEFORE copying, including any interrupted partial copy.

    Supports the separate trial/guest/result SQLite databases, not RDS or arbitrary
    historic snapshots. Does not migrate the source or alter allowances.
    """
    if role not in _ROLES:
        raise RuntimeBackupError("backup_role_invalid")
    if (
        isinstance(timeoutSeconds, bool)
        or not math.isfinite(timeoutSeconds)
        or not 0 < timeoutSeconds <= 3600
    ):
        raise RuntimeBackupError("backup_timeout_invalid")
    source = _safePath(source)
    if not source.is_file():
        raise RuntimeBackupError("backup_source_unavailable")
    # A managed snapshot must never itself become the live source.
    if source.is_relative_to(root):
        raise RuntimeBackupError("backup_source_invalid")
    with _locked(root):
        identity = uuid.uuid4().hex
        folder = root / identity
        folder.mkdir()
        created = time.time()
        entry: dict[str, Any] = {
            "version": 1,
            "backupId": identity,
            "role": role,
            "createdAtEpoch": created,
            "expiresAtEpoch": created + RETENTION_SECONDS,
        }
        with (folder / "entry.json").open("x", encoding="utf-8") as stream:
            json.dump(entry, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        # If copying/validation fails, the registered partial file remains recoverably
        # identifiable for cleanup; it is never exposed as a completed backup.
        digest, size = _copyWithTimeout(source, folder / "staged.sqlite3", timeoutSeconds)
        _safePath(folder / "staged.sqlite3")
        if time.time() >= entry["expiresAtEpoch"]:
            raise RuntimeBackupError("backup_expired_during_creation")
        os.rename(folder / "staged.sqlite3", folder / "backup.sqlite3")
        return ManagedBackup(identity, role, created, created + RETENTION_SECONDS, digest, size)


def _entry(folder: Path) -> dict[str, Any]:
    _safePath(folder)
    path = _safePath(folder / "entry.json")
    if not folder.is_dir() or not path.is_file() or path.stat().st_size > 2048:
        raise RuntimeBackupError("backup_entry_invalid")
    value: Any = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or set(value) != {
        "version",
        "backupId",
        "role",
        "createdAtEpoch",
        "expiresAtEpoch",
    }:
        raise RuntimeBackupError("backup_entry_invalid")
    created, expires = value["createdAtEpoch"], value["expiresAtEpoch"]
    if (
        value["version"] != 1
        or isinstance(value["version"], bool)
        or value["backupId"] != folder.name
        or value["role"] not in _ROLES
        or isinstance(created, bool)
        or not isinstance(created, int | float)
        or not math.isfinite(created)
        or created <= 0
        or isinstance(expires, bool)
        or not isinstance(expires, int | float)
        or expires != created + RETENTION_SECONDS
    ):
        raise RuntimeBackupError("backup_entry_invalid")
    return value


def _deleteEntry(folder: Path) -> None:
    # Validate EVERY child before any deletion: never recurse into an unknown object.
    allowed = {"entry.json", *_PAYLOADS, *_SIDECARS}
    children = list(folder.iterdir())
    for child in children:
        _safePath(child)
        if child.name not in allowed or not child.is_file():
            raise RuntimeBackupError("backup_entry_unsafe")
    for child in children:
        if child.name != "entry.json":
            _safePath(child).unlink()
    # Registration survives any interrupted/failed data removal, enabling a retry.
    (folder / "entry.json").unlink()
    folder.rmdir()


def cleanupManagedBackups(
    root: Path, *, apply: bool = False, lookAheadSeconds: int = 0
) -> CleanupReport:
    """Delete only registered objects due at/before now+lookahead; default is dry run.

    A five-minute task uses a five-minute lookahead, permitting early deletion so
    healthy scheduling need not extend a seven-day ceiling. Outages/clock rollback
    cannot be solved by a local task; overdue counts must be monitored operationally.
    """
    if (
        isinstance(lookAheadSeconds, bool)
        or not isinstance(lookAheadSeconds, int)
        or not 0 <= lookAheadSeconds <= 300
    ):
        raise RuntimeBackupError("backup_lookahead_invalid")
    scanned = deleted = retained = ignored = failures = overdue = 0
    with _locked(root):
        now = time.time()
        for folder in root.iterdir():
            if folder.name in {"registry.json", "registry.lock"}:
                continue
            if not _ID.fullmatch(folder.name):
                ignored += 1
                continue
            scanned += 1
            try:
                entry = _entry(folder)
                if entry["expiresAtEpoch"] > now + lookAheadSeconds:
                    retained += 1
                    continue
                if entry["expiresAtEpoch"] < now:
                    overdue += 1
                if apply:
                    _deleteEntry(folder)
                    deleted += 1
            except RuntimeBackupError, OSError, ValueError, TypeError:
                failures += 1
    return CleanupReport(scanned, deleted, retained, ignored, failures, overdue, apply)


def reportDictionary(report: ManagedBackup | CleanupReport) -> dict[str, Any]:
    return asdict(report)
