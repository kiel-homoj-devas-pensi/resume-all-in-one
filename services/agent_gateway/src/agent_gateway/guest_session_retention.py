"""Bounded guest credential maintenance, preserving historical usage and fees."""

from __future__ import annotations

import re
import sqlite3
from collections.abc import Callable
from contextlib import closing
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

from .database import UnsupportedDatabaseSchemaError
from .guest_identity import (
    GUEST_ID_PATTERN,
    GUEST_INSTALLATION_IDLE_DAYS,
    GuestDatabase,
    clearIdleGuestInstallation,
    guestIssuanceCutoff,
)
from .identity import requireUtc, toUtcText

GUEST_TOKEN_RETENTION_HOURS = 6


@dataclass(frozen=True, slots=True)
class GuestIssuancePurgeBatch:
    scannedBuckets: int
    purgedBuckets: int
    invalidRecords: int
    moreCandidates: bool
    nextBucket: str | None = field(repr=False)


@dataclass(frozen=True, slots=True)
class GuestSessionClearBatch:
    scannedSessions: int
    clearedSessions: int
    invalidRecords: int
    moreCandidates: bool
    nextGuestId: str | None = field(repr=False)


@dataclass(frozen=True, slots=True)
class GuestInstallationClearBatch:
    scannedInstallations: int
    clearedInstallations: int
    invalidRecords: int
    moreCandidates: bool
    nextGuestId: str | None = field(repr=False)


def _existingDatabasePath(path: Path) -> Path:
    if (
        not path.is_absolute()
        or any(
            candidate.is_symlink() or candidate.is_junction() for candidate in (path, *path.parents)
        )
        or not path.is_file()
    ):
        raise ValueError("existing_private_guest_database_required")
    return path.resolve(strict=True)


def _validateSchema(connection: sqlite3.Connection) -> None:
    if connection.execute("PRAGMA user_version").fetchone()[0] != GuestDatabase.schemaVersion:
        raise UnsupportedDatabaseSchemaError("guest_retention_schema_mismatch")
    # Reuse the actual canonical migration in memory, never initialize the target.
    with closing(sqlite3.connect(":memory:")) as expected:
        GuestDatabase(Path(":memory:"))._applyMigrations(expected)
        if GuestDatabase._schemaStatements(connection) != GuestDatabase._schemaStatements(expected):
            raise UnsupportedDatabaseSchemaError("guest_retention_schema_mismatch")


class GuestSessionRetentionWorker:
    def __init__(
        self, path: Path, *, clock: Callable[[], datetime] = lambda: datetime.now(UTC)
    ) -> None:
        self._path = _existingDatabasePath(path)
        self._clock = clock

    def inspect(self) -> dict[str, int]:
        now = requireUtc(self._clock())
        with closing(sqlite3.connect(self._path.as_uri() + "?mode=ro", uri=True)) as connection:
            _validateSchema(connection)
            row = connection.execute(
                "SELECT COUNT(*),"
                "COALESCE(SUM(token_hash IS NOT NULL),0),"
                "COALESCE(SUM(session_expires_at_utc<=?),0),"
                "COALESCE(SUM(session_expires_at_utc<=?),0),"
                "COALESCE(SUM((token_hash IS NULL)<>(session_expires_at_utc IS NULL)),0),"
                "COALESCE(SUM(credential_hash<>('cleared:'||guest_id)),0),"
                "COALESCE(SUM(credential_hash<>('cleared:'||guest_id) AND last_seen_at_utc<=?),0) "
                "FROM guest_identities",
                (
                    toUtcText(now),
                    toUtcText(now - timedelta(hours=GUEST_TOKEN_RETENTION_HOURS)),
                    toUtcText(now - timedelta(days=GUEST_INSTALLATION_IDLE_DAYS)),
                ),
            ).fetchone()
            if row is None:
                raise ValueError("guest_retention_inspection_unavailable")
            result = dict(
                zip(
                    (
                        "guestIdentities",
                        "storedSessionTokens",
                        "expiredSessionTokens",
                        "dueSessionTokens",
                        "inconsistentSessionPairs",
                        "storedInstallationCredentials",
                        "dueIdleInstallations",
                    ),
                    (int(value) for value in row),
                    strict=True,
                )
            )
            issuance = connection.execute(
                "SELECT COUNT(*),COALESCE(SUM(bucket_hash<?),0) FROM guest_issuance",
                (guestIssuanceCutoff(now),),
            ).fetchone()
            if issuance is None:
                raise ValueError("guest_retention_inspection_unavailable")
            result.update(
                storedIssuanceBuckets=int(issuance[0]), dueIssuanceBuckets=int(issuance[1])
            )
            return result

    def purgeExpiredIssuance(
        self, *, maximumBuckets: int = 100, afterBucket: str = "", lookAheadSeconds: int = 0
    ) -> GuestIssuancePurgeBatch:
        if (
            type(maximumBuckets) is not int
            or not 1 <= maximumBuckets <= 100
            or (afterBucket and (not isinstance(afterBucket, str) or len(afterBucket) > 256))
        ):
            raise ValueError("invalid_guest_issuance_bound")
        cutoff = guestIssuanceCutoff(self._clock(), lookAheadSeconds=lookAheadSeconds)
        with closing(
            sqlite3.connect(
                self._path.as_uri() + "?mode=rw", uri=True, isolation_level=None, timeout=5
            )
        ) as connection:
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("BEGIN IMMEDIATE")
            try:
                _validateSchema(connection)
                rows = connection.execute(
                    "SELECT bucket_hash,attempts FROM guest_issuance "
                    "WHERE bucket_hash>? AND bucket_hash<? ORDER BY bucket_hash LIMIT ?",
                    (afterBucket, cutoff, maximumBuckets + 1),
                ).fetchall()
                purged = invalid = 0
                for bucket, attempts in rows[:maximumBuckets]:
                    try:
                        if (
                            not isinstance(bucket, str)
                            or re.fullmatch(r"\d{4}-\d{2}-\d{2}:[a-f0-9]{64}", bucket) is None
                            or date.fromisoformat(bucket[:10]).isoformat() != bucket[:10]
                            or type(attempts) is not int
                            or attempts < 1
                        ):
                            raise ValueError("invalid_guest_issuance_record")
                    except TypeError, ValueError:
                        invalid += 1
                        continue
                    changed = connection.execute(
                        "DELETE FROM guest_issuance WHERE bucket_hash=? AND attempts=? "
                        "AND bucket_hash<?",
                        (bucket, attempts, cutoff),
                    ).rowcount
                    if changed != 1:
                        raise ValueError("guest_issuance_storage_inconsistent")
                    purged += changed
                connection.commit()
            except Exception:
                connection.rollback()
                raise
        return GuestIssuancePurgeBatch(
            min(len(rows), maximumBuckets),
            purged,
            invalid,
            len(rows) > maximumBuckets,
            str(rows[maximumBuckets - 1][0]) if len(rows) > maximumBuckets else None,
        )

    def clearExpiredSessions(
        self, *, maximumSessions: int = 100, afterGuestId: str = "", lookAheadSeconds: int = 0
    ) -> GuestSessionClearBatch:
        if (
            type(maximumSessions) is not int
            or not 1 <= maximumSessions <= 100
            or type(lookAheadSeconds) is not int
            or not 0 <= lookAheadSeconds <= 300
            or (afterGuestId and re.fullmatch(GUEST_ID_PATTERN, afterGuestId) is None)
        ):
            raise ValueError("invalid_guest_retention_bound")
        cutoff = (
            requireUtc(self._clock())
            - timedelta(hours=GUEST_TOKEN_RETENTION_HOURS)
            + timedelta(seconds=lookAheadSeconds)
        )
        cutoffText = toUtcText(cutoff)
        with closing(
            sqlite3.connect(
                self._path.as_uri() + "?mode=rw", uri=True, isolation_level=None, timeout=5
            )
        ) as connection:
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("BEGIN IMMEDIATE")
            try:
                _validateSchema(connection)
                rows = connection.execute(
                    "SELECT guest_id,token_hash,session_expires_at_utc FROM guest_identities "
                    "WHERE guest_id>? AND session_expires_at_utc<=? ORDER BY guest_id LIMIT ?",
                    (afterGuestId, cutoffText, maximumSessions + 1),
                ).fetchall()
                cleared = invalid = 0
                for row in rows[:maximumSessions]:
                    guestId, digest, expiryText = row
                    try:
                        expiry = requireUtc(datetime.fromisoformat(expiryText))
                        if (
                            re.fullmatch(GUEST_ID_PATTERN, guestId) is None
                            or not isinstance(digest, str)
                            or re.fullmatch(r"[a-f0-9]{64}", digest) is None
                            or toUtcText(expiry) != expiryText
                            or expiry > cutoff
                        ):
                            raise ValueError("invalid_guest_session_record")
                    except TypeError, ValueError:
                        invalid += 1
                        continue
                    # Serialize with session replacement; recheck both values.
                    changed = connection.execute(
                        "UPDATE guest_identities SET token_hash=NULL,session_expires_at_utc=NULL "
                        "WHERE guest_id=? AND token_hash=? AND session_expires_at_utc=? "
                        "AND session_expires_at_utc<=?",
                        (guestId, digest, expiryText, cutoffText),
                    ).rowcount
                    if changed not in (0, 1):
                        raise ValueError("guest_retention_storage_inconsistent")
                    cleared += changed
                connection.commit()
            except Exception:
                connection.rollback()
                raise
        return GuestSessionClearBatch(
            min(len(rows), maximumSessions),
            cleared,
            invalid,
            len(rows) > maximumSessions,
            str(rows[maximumSessions - 1]["guest_id"]) if len(rows) > maximumSessions else None,
        )

    def clearIdleInstallations(
        self, *, maximumInstallations: int = 100, afterGuestId: str = ""
    ) -> GuestInstallationClearBatch:
        if (
            type(maximumInstallations) is not int
            or not 1 <= maximumInstallations <= 100
            or (afterGuestId and re.fullmatch(GUEST_ID_PATTERN, afterGuestId) is None)
        ):
            raise ValueError("invalid_guest_installation_bound")
        now = requireUtc(self._clock())
        cutoff = toUtcText(now - timedelta(days=GUEST_INSTALLATION_IDLE_DAYS))
        with closing(
            sqlite3.connect(
                self._path.as_uri() + "?mode=rw", uri=True, isolation_level=None, timeout=5
            )
        ) as connection:
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("BEGIN IMMEDIATE")
            try:
                _validateSchema(connection)
                rows = connection.execute(
                    "SELECT guest_id,credential_hash,created_at_utc,last_seen_at_utc,token_hash,"
                    "session_expires_at_utc FROM guest_identities WHERE guest_id>? "
                    "AND credential_hash<>('cleared:'||guest_id) AND last_seen_at_utc<=? "
                    "ORDER BY guest_id LIMIT ?",
                    (afterGuestId, cutoff, maximumInstallations + 1),
                ).fetchall()
                cleared = invalid = 0
                for row in rows[:maximumInstallations]:
                    try:
                        cleared += clearIdleGuestInstallation(connection, row, nowUtc=now)
                    except TypeError, ValueError:
                        invalid += 1
                connection.commit()
            except Exception:
                connection.rollback()
                raise
        return GuestInstallationClearBatch(
            min(len(rows), maximumInstallations),
            cleared,
            invalid,
            len(rows) > maximumInstallations,
            str(rows[maximumInstallations - 1]["guest_id"])
            if len(rows) > maximumInstallations
            else None,
        )
