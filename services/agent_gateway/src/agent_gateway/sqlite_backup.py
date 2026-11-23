from __future__ import annotations

import hashlib
import math
import multiprocessing
import os
import sqlite3
import tempfile
import time
from contextlib import closing
from dataclasses import dataclass
from multiprocessing.connection import Connection
from pathlib import Path
from typing import Literal

from .account_retention_schema import validateSqliteRetentionSchema
from .database import GatewayDatabase
from .privilege_schema import validateSqlitePrivilegeSchema
from .sms_attempt_retention_schema import validateSqliteSmsSummarySchema


class SqliteBackupError(RuntimeError):
    def __init__(self, code: str = "backup_failed") -> None:
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class SqliteBackupResult:
    sha256: str
    sizeBytes: int


def _localPath(path: Path) -> Path:
    if not path.is_absolute():
        raise SqliteBackupError("backup_path_invalid")
    # Local trusted directories only; do not follow a junction/symlink to another target.
    for candidate in (path, *path.parents):
        if candidate.is_symlink() or (
            os.name == "nt"
            and candidate.exists()
            and candidate.stat(follow_symlinks=False).st_file_attributes & 0x400
        ):
            raise SqliteBackupError("backup_path_invalid")
    if os.name == "nt" and (str(path).startswith("\\\\") or ":" in str(path)[2:]):
        raise SqliteBackupError("backup_path_invalid")
    return path.resolve()


def _copyWorker(
    source: str, staged: str, result: Connection, schemaVersion: Literal[7, 9, 10, 11] = 7
) -> None:
    try:
        with (
            closing(
                sqlite3.connect(Path(source).as_uri() + "?mode=ro", uri=True, timeout=0.2)
            ) as src,
            closing(sqlite3.connect(staged, timeout=0.2)) as dst,
        ):
            src.backup(dst, pages=128, sleep=0.05)
            # A verified delivery consists of one self-contained file, not live WAL sidecars.
            if dst.execute("PRAGMA journal_mode = DELETE").fetchone()[0] != "delete":
                raise SqliteBackupError()
            if dst.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise SqliteBackupError()
            if dst.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise SqliteBackupError()
        database = GatewayDatabase(Path(staged))
        if schemaVersion == 11:
            validateSqliteSmsSummarySchema(database)
        elif schemaVersion == 10:
            validateSqliteSmsSummarySchema(database, withUnresolved=False)
        elif schemaVersion == 9:
            validateSqliteRetentionSchema(database)
        else:
            validateSqlitePrivilegeSchema(database)
        with Path(staged).open("r+b") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
            os.fsync(stream.fileno())
        result.send((digest, Path(staged).stat().st_size))
    except BaseException:
        # The child must never emit SQLite exceptions, paths, data, or credentials.
        result.send(None)
    finally:
        result.close()


def _requireVacantDestination(destination: Path) -> None:
    # Orphaned SQLite journals belong to the old database even if its main file is gone.
    # lexists also treats a dangling symlink as occupied; never remove any target sidecar.
    if any(
        os.path.lexists(str(destination) + suffix) for suffix in ("", "-wal", "-shm", "-journal")
    ):
        raise SqliteBackupError("backup_destination_exists")


def backupSqlite(
    source: Path,
    destination: Path,
    *,
    timeoutSeconds: float = 60.0,
    schemaVersion: Literal[7, 9, 10, 11] = 7,
) -> SqliteBackupResult:
    """Verify explicitly selected v7/v9/v10/v11 schema; never migrate, overwrite or restore.

    Legacy callers retain v7 validation. Current account-retention databases must
    explicitly request v9; a mismatched or malformed schema is never auto-adopted.
    """
    if type(schemaVersion) is not int or schemaVersion not in {7, 9, 10, 11}:
        raise SqliteBackupError("backup_schema_invalid")
    if (
        isinstance(timeoutSeconds, bool)
        or not math.isfinite(timeoutSeconds)
        or not 0 < timeoutSeconds <= 3600
    ):
        raise SqliteBackupError("backup_timeout_invalid")
    source = _localPath(source)
    destination = _localPath(destination)
    if not source.is_file():
        raise SqliteBackupError("backup_source_unavailable")
    _requireVacantDestination(destination)
    if not destination.parent.is_dir():
        raise SqliteBackupError("backup_path_invalid")
    # The parent owns the only worker and an exclusive same-volume staging directory.
    # Hard-link publication fails atomically if another actor creates the final name.
    staging = Path(tempfile.mkdtemp(prefix=".gateway-backup-", dir=destination.parent))
    staged = staging / "backup.db"
    context = multiprocessing.get_context("spawn")
    receive, send = context.Pipe(duplex=False)
    process = context.Process(
        target=_copyWorker, args=(str(source), str(staged), send, schemaVersion)
    )
    started = False
    try:
        deadline = time.monotonic() + timeoutSeconds
        process.start()
        started = True
        send.close()
        process.join(max(0, deadline - time.monotonic()))
        if process.is_alive() or time.monotonic() >= deadline:
            raise SqliteBackupError("backup_timeout")
        if process.exitcode != 0 or not receive.poll():
            raise SqliteBackupError()
        value = receive.recv()
        if value is None:
            raise SqliteBackupError()
        digest, size = value
        # No completed target exists until all integrity and schema checks succeeded.
        _requireVacantDestination(destination)
        os.link(staged, destination)
        return SqliteBackupResult(sha256=digest, sizeBytes=size)
    except FileExistsError:
        raise SqliteBackupError("backup_destination_exists") from None
    except SqliteBackupError:
        raise
    except Exception:
        raise SqliteBackupError() from None
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
        # Delete only our known files, never recurse or remove an unrelated destination.
        for suffix in ("", "-wal", "-shm", "-journal"):
            Path(str(staged) + suffix).unlink(missing_ok=True)
        staging.rmdir()
