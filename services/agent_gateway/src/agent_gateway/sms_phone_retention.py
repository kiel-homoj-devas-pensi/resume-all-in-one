"""Clear old phone correlation without deleting SMS attempt or budget evidence."""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from uuid import UUID

from .account_storage import AccountSqlDatabase, StorageUnavailableError, storedText
from .identity import requireUtc, toUtcText

SMS_PHONE_RETENTION_DAYS = 90
PHONE_DIGEST_CLEARED_MARKER = "cleared"


def _validAttemptId(value: str) -> bool:
    try:
        identity = UUID(value.removeprefix("challenge-"))
    except ValueError:
        return False
    return value == f"challenge-{identity}" and identity.version == 4


@dataclass(frozen=True, slots=True)
class SmsPhoneClearBatch:
    scannedAttempts: int
    clearedPhoneDigests: int
    invalidRecords: int
    moreCandidates: bool
    nextAttemptId: str | None = field(repr=False)


class SmsPhoneRetentionWorker:
    """Requires an already-validated account schema and separate management identity."""

    def __init__(
        self,
        database: AccountSqlDatabase,
        *,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        if database.authorityKey[0] not in {"sqlite", "mysql"}:
            raise ValueError("sms_retention_database_required")
        self._database = database
        self._mysql = database.authorityKey[0] == "mysql"
        self._clock = clock

    def _sql(self, query: str) -> str:
        return query.replace("?", "%s" if self._mysql else "?")

    def clearOldPhoneDigests(
        self, *, maximumAttempts: int = 100, afterAttemptId: str = "", lookAheadSeconds: int = 0
    ) -> SmsPhoneClearBatch:
        if (
            type(maximumAttempts) is not int
            or not 1 <= maximumAttempts <= 100
            or type(lookAheadSeconds) is not int
            or not 0 <= lookAheadSeconds <= 300
            or (afterAttemptId and not _validAttemptId(afterAttemptId))
        ):
            raise ValueError("invalid_sms_retention_bound")
        cutoff = (
            requireUtc(self._clock())
            - timedelta(days=SMS_PHONE_RETENTION_DAYS)
            + timedelta(seconds=lookAheadSeconds)
        )
        cutoffText = toUtcText(cutoff)
        cleared = invalid = 0
        with self._database.transaction() as connection:
            # The conditional UPDATE acquires the write lock and rechecks the old
            # digest/time. No locking read or budget lock is needed; finalization
            # can still change its own columns without reintroducing the phone.
            rows = connection.fetchMany(
                self._sql(
                    "SELECT challenge_id,phone_hash,created_at_utc FROM sms_send_attempts "
                    "WHERE challenge_id>? AND phone_hash<>? AND created_at_utc<=? "
                    "ORDER BY challenge_id LIMIT ?",
                ),
                (afterAttemptId, PHONE_DIGEST_CLEARED_MARKER, cutoffText, maximumAttempts + 1),
                maximumRows=maximumAttempts + 1,
            )
            for row in rows[:maximumAttempts]:
                try:
                    attemptId = storedText(row["challenge_id"])
                    digest = storedText(row["phone_hash"])
                    createdText = storedText(row["created_at_utc"])
                    created = requireUtc(datetime.fromisoformat(createdText))
                    if (
                        not _validAttemptId(attemptId)
                        or re.fullmatch(r"[a-f0-9]{64}", digest) is None
                        or toUtcText(created) != createdText
                        or created > cutoff
                    ):
                        raise ValueError("invalid_sms_retention_record")
                except TypeError, ValueError:
                    invalid += 1
                    continue
                changed = connection.execute(
                    self._sql(
                        "UPDATE sms_send_attempts SET phone_hash=? WHERE challenge_id=? "
                        "AND phone_hash=? AND created_at_utc=? AND created_at_utc<=?"
                    ),
                    (PHONE_DIGEST_CLEARED_MARKER, attemptId, digest, createdText, cutoffText),
                )
                if changed not in (0, 1):
                    raise StorageUnavailableError("sms_retention_storage_inconsistent")
                cleared += changed
        return SmsPhoneClearBatch(
            min(len(rows), maximumAttempts),
            cleared,
            invalid,
            len(rows) > maximumAttempts,
            storedText(rows[maximumAttempts - 1]["challenge_id"])
            if len(rows) > maximumAttempts
            else None,
        )
