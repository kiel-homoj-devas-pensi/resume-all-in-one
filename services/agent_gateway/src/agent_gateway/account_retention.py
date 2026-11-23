"""Bounded administrative retirement cleanup, separate from the Web identity."""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Literal

from .account_storage import (
    AccountSqlConnection,
    AccountSqlDatabase,
    StorageUnavailableError,
    storedText,
)
from .identity import IDENTITY_RATE_LIMITS, requireUtc, toUtcText

ACCOUNT_RETENTION_DAYS = 60
SESSION_RETENTION_HOURS = 6
CHALLENGE_RETENTION_HOURS = 6
THROTTLE_HOURS_FROM_WINDOW_START = 6


@dataclass(frozen=True, slots=True)
class SessionPurgeBatch:
    scannedSessions: int
    deletedSessions: int
    invalidRecords: int
    moreCandidates: bool
    nextSessionId: str | None = field(repr=False)


@dataclass(frozen=True, slots=True)
class RetentionPurgeBatch:
    scannedRecords: int
    deletedRecords: int
    invalidRecords: int
    moreCandidates: bool
    nextRecordId: str | None = field(repr=False)


@dataclass(frozen=True, slots=True)
class AccountPurgeBatch:
    scannedAccounts: int
    deletedAccounts: int
    unknownDeactivationTimes: int
    blockedUnsettledAccounts: int
    heldAccounts: int
    unfinishedCloudAccounts: int
    invalidRecords: int
    moreCandidates: bool
    nextAccountId: str | None = field(repr=False)


class AccountRetentionWorker:
    """Requires the versioned retirement schema and a dedicated management role.

    A result with blocked/unknown/unfinished counts is actionable unfinished work,
    never a successful assertion that all expired records have been removed.
    No SMS, provider calls, Web startup scheduling or account restoration occurs.
    """

    def __init__(
        self,
        database: AccountSqlDatabase,
        *,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        if database.authorityKey[0] not in {"sqlite", "mysql"}:
            raise ValueError("invalid_retention_database")
        self._database = database
        self._mysql = database.authorityKey[0] == "mysql"
        self._clock = clock

    def _sql(self, text: str, *, lock: bool = False) -> str:
        return text.replace("?", "%s" if self._mysql else "?") + (
            " FOR UPDATE" if self._mysql and lock else ""
        )

    def purgeInvalidSessions(
        self,
        *,
        maximumSessions: int = 100,
        afterSessionId: str = "",
        lookAheadSeconds: int = 0,
    ) -> SessionPurgeBatch:
        batch = self._purgeExpiredRecords(
            "sessions", maximumSessions, afterSessionId, lookAheadSeconds
        )
        return SessionPurgeBatch(
            batch.scannedRecords,
            batch.deletedRecords,
            batch.invalidRecords,
            batch.moreCandidates,
            batch.nextRecordId,
        )

    def purgeInvalidChallenges(
        self,
        *,
        maximumChallenges: int = 100,
        afterChallengeId: str = "",
        lookAheadSeconds: int = 0,
    ) -> RetentionPurgeBatch:
        return self._purgeExpiredRecords(
            "challenges", maximumChallenges, afterChallengeId, lookAheadSeconds
        )

    def _purgeExpiredRecords(
        self,
        kind: Literal["sessions", "challenges", "throttles"],
        maximumRecords: int,
        afterRecordId: str,
        lookAheadSeconds: int,
    ) -> RetentionPurgeBatch:
        """Sweep fixed record categories without touching charging or replay ledgers.

        A five-minute scheduled sweep can delete up to five minutes early to
        stay within the six-hour maximum during normal operation. Overdue jobs,
        scan bounds and failures require monitoring. Fixed queries select the
        earliest expiry/revocation/consumption, so later invalidation cannot
        extend retention. No Web scheduler, grants or schema changes occur here.
        """
        boundError = f"invalid_{kind}_retention_bound"
        if kind == "sessions":
            boundError = "invalid_session_retention_bound"
        elif kind == "challenges":
            boundError = "invalid_challenge_retention_bound"
        identifierPattern = r"[a-f0-9]{64}" if kind == "throttles" else r"[A-Za-z0-9._:-]{1,128}"
        if (
            type(maximumRecords) is not int
            or not 1 <= maximumRecords <= 100
            or type(lookAheadSeconds) is not int
            or not 0 <= lookAheadSeconds <= 300
            or (afterRecordId and re.fullmatch(identifierPattern, afterRecordId) is None)
        ):
            raise ValueError(boundError)
        if kind == "sessions":
            hours = SESSION_RETENTION_HOURS
            select = (
                "SELECT session_id AS record_id,expires_at_utc AS eligible_at_utc,"
                "revoked_at_utc AS invalidated_at_utc FROM account_sessions "
                "WHERE session_id>? AND (expires_at_utc<=? OR revoked_at_utc<=?) "
                "ORDER BY session_id LIMIT ?"
            )
            delete = (
                "DELETE FROM account_sessions WHERE session_id=? "
                "AND (expires_at_utc<=? OR revoked_at_utc<=?)"
            )
        elif kind == "challenges":
            hours = CHALLENGE_RETENTION_HOURS
            select = (
                "SELECT challenge_id AS record_id,expires_at_utc AS eligible_at_utc,"
                "consumed_at_utc AS invalidated_at_utc FROM phone_challenges "
                "WHERE challenge_id>? AND (expires_at_utc<=? OR consumed_at_utc<=?) "
                "ORDER BY challenge_id LIMIT ?"
            )
            delete = (
                "DELETE FROM phone_challenges WHERE challenge_id=? "
                "AND (expires_at_utc<=? OR consumed_at_utc<=?)"
            )
        else:
            hours = THROTTLE_HOURS_FROM_WINDOW_START
            # No action can be recovered from the HMAC bucket. Delete earlier
            # than the promised end+6h instead: start+6h is safely beyond every
            # supported window. Fail closed if a future window invalidates this
            # invariant, including the scheduler's permitted early sweep.
            maximumWindow = max(seconds for _, seconds in IDENTITY_RATE_LIMITS.values())
            if maximumWindow + lookAheadSeconds >= hours * 3600:
                raise ValueError("throttle_window_retention_incompatible")
            select = (
                "SELECT bucket_hash AS record_id,window_start_utc AS eligible_at_utc,"
                "NULL AS invalidated_at_utc FROM identity_rate_limits "
                "WHERE bucket_hash>? AND window_start_utc<=? "
                "ORDER BY bucket_hash LIMIT ?"
            )
            delete = "DELETE FROM identity_rate_limits WHERE bucket_hash=? AND window_start_utc<=?"
        cutoff = (
            requireUtc(self._clock()) - timedelta(hours=hours) + timedelta(seconds=lookAheadSeconds)
        )
        cutoffText = toUtcText(cutoff)
        cutoffBindings = (cutoffText,) if kind == "throttles" else (cutoffText, cutoffText)
        deleted = invalid = 0
        with self._database.transaction() as connection:
            rows = connection.fetchMany(
                self._sql(select, lock=True),
                (afterRecordId, *cutoffBindings, maximumRecords + 1),
                maximumRows=maximumRecords + 1,
            )
            for row in rows[:maximumRecords]:
                recordId = storedText(row["record_id"])
                try:
                    expiry = requireUtc(datetime.fromisoformat(storedText(row["eligible_at_utc"])))
                    invalidated = (
                        None
                        if row["invalidated_at_utc"] is None
                        else requireUtc(
                            datetime.fromisoformat(storedText(row["invalidated_at_utc"]))
                        )
                    )
                    if re.fullmatch(identifierPattern, recordId) is None or (
                        expiry > cutoff and (invalidated is None or invalidated > cutoff)
                    ):
                        raise ValueError("invalid_credential_retention_record")
                except TypeError, ValueError:
                    invalid += 1
                    continue
                # Lock and recheck eligibility at deletion; active records and
                # unrelated budgets remain intact even during concurrent use.
                changed = connection.execute(self._sql(delete), (recordId, *cutoffBindings))
                if changed not in (0, 1):
                    raise StorageUnavailableError("credential_retention_storage_inconsistent")
                deleted += changed
        return RetentionPurgeBatch(
            min(len(rows), maximumRecords),
            deleted,
            invalid,
            len(rows) > maximumRecords,
            storedText(rows[maximumRecords - 1]["record_id"])
            if len(rows) > maximumRecords
            else None,
        )

    def purgeExpiredThrottles(
        self,
        *,
        maximumBuckets: int = 100,
        afterBucketHash: str = "",
        lookAheadSeconds: int = 0,
    ) -> RetentionPurgeBatch:
        return self._purgeExpiredRecords(
            "throttles", maximumBuckets, afterBucketHash, lookAheadSeconds
        )

    def runBatch(
        self,
        *,
        maximumAccounts: int = 20,
        maximumCloudVersionsPerAccount: int = 200,
        afterAccountId: str = "",
    ) -> AccountPurgeBatch:
        if type(maximumAccounts) is not int or not 1 <= maximumAccounts <= 20:
            raise ValueError("invalid_retention_bound")
        if (
            type(maximumCloudVersionsPerAccount) is not int
            or not 1 <= maximumCloudVersionsPerAccount <= 200
        ):
            raise ValueError("invalid_retention_bound")
        if afterAccountId and re.fullmatch(r"[A-Za-z0-9._:-]{1,64}", afterAccountId) is None:
            raise ValueError("invalid_retention_position")
        now = requireUtc(self._clock())
        with self._database.readConnection() as connection:
            unknown = connection.fetchOne(
                "SELECT COUNT(*) AS count FROM accounts a LEFT JOIN account_retirements r "
                "ON r.account_id=a.account_id WHERE a.is_active=0 AND r.account_id IS NULL"
            )
            rows = connection.fetchMany(
                self._sql(
                    "SELECT r.account_id FROM account_retirements r JOIN accounts a "
                    "ON a.account_id=r.account_id WHERE a.is_active=0 AND r.account_id>? "
                    "AND r.deactivated_at_utc<=? ORDER BY r.account_id LIMIT ?"
                ),
                (
                    afterAccountId,
                    toUtcText(now - timedelta(days=ACCOUNT_RETENTION_DAYS)),
                    maximumAccounts + 1,
                ),
                maximumRows=maximumAccounts + 1,
            )
        if unknown is None or type(unknown["count"]) is not int:
            raise StorageUnavailableError("retention_storage_inconsistent")
        deleted = blocked = held = unfinished = invalid = 0
        for row in rows[:maximumAccounts]:
            outcome = self._purge(storedText(row["account_id"]), maximumCloudVersionsPerAccount)
            deleted += outcome == "deleted"
            blocked += outcome == "unsettled"
            held += outcome == "held"
            unfinished += outcome == "unfinishedCloud"
            invalid += outcome == "invalid"
        return AccountPurgeBatch(
            min(len(rows), maximumAccounts),
            deleted,
            unknown["count"],
            blocked,
            held,
            unfinished,
            invalid,
            len(rows) > maximumAccounts,
            (
                storedText(rows[maximumAccounts - 1]["account_id"])
                if len(rows) > maximumAccounts
                else None
            ),
        )

    def _purge(
        self, accountId: str, maximumCloudVersions: int, *, earlierDeletion: bool = False
    ) -> Literal["deleted", "absent", "notDue", "unsettled", "held", "unfinishedCloud", "invalid"]:
        with self._database.transaction() as connection:
            account = connection.fetchOne(
                self._sql("SELECT is_active FROM accounts WHERE account_id=?", lock=True),
                (accountId,),
            )
            if account is None:
                return "absent"
            if account["is_active"] != 0:
                return "notDue"
            retirement = connection.fetchOne(
                self._sql("SELECT * FROM account_retirements WHERE account_id=?", lock=True),
                (accountId,),
            )
            if retirement is None and not earlierDeletion:
                # Historical unknown times require verified maintenance backfill,
                # not a guessed timestamp or a fresh 60-day period.
                return "invalid"
            now = requireUtc(self._clock())
            try:
                retired = (
                    None
                    if retirement is None
                    else requireUtc(
                        datetime.fromisoformat(storedText(retirement["deactivated_at_utc"]))
                    )
                )
                if retired is not None and retired > now:
                    return "invalid"
                holdUntil = None if retirement is None else retirement["hold_until_utc"]
                if retirement is not None and holdUntil is not None:
                    until = requireUtc(datetime.fromisoformat(storedText(holdUntil)))
                    evidence = storedText(retirement["hold_evidence_sha256"])
                    if (
                        retirement["hold_kind"] is None
                        or storedText(retirement["hold_kind"])
                        not in {"legalObligation", "actualDispute"}
                        or re.fullmatch(r"[a-f0-9]{64}", evidence) is None
                    ):
                        return "invalid"
                    if until > now:
                        return "held"
                if (
                    not earlierDeletion
                    and retired is not None
                    and retired + timedelta(days=ACCOUNT_RETENTION_DAYS) > now
                ):
                    return "notDue"
            except ValueError, OverflowError:
                return "invalid"
            # Account lock prevents new reservations; existing execution has a
            # reserved/unknown row. Terminal operations cannot become pending.
            pending = connection.fetchOne(
                self._sql(
                    "SELECT operation_id FROM usage_operations WHERE account_id=? "
                    "AND status NOT IN ('committed','released') LIMIT 1",
                    lock=True,
                ),
                (accountId,),
            )
            if pending is not None:
                return "unsettled"
            activeDocument = connection.fetchOne(
                self._sql(
                    "SELECT document_id FROM cloud_documents WHERE account_id=? "
                    "AND deleted_at_utc IS NULL LIMIT 1",
                    lock=True,
                ),
                (accountId,),
            )
            if activeDocument is not None:
                # Deactivation must retire cloud data before any content purge.
                return "invalid"
            versions = connection.fetchMany(
                self._sql(
                    "SELECT document_id,version_id FROM cloud_versions WHERE account_id=? "
                    "ORDER BY commit_sequence DESC LIMIT ?",
                    lock=True,
                ),
                (accountId, maximumCloudVersions + 1),
                maximumRows=maximumCloudVersions + 1,
            )
            for version in versions[:maximumCloudVersions]:
                connection.execute(
                    self._sql(
                        "DELETE FROM cloud_versions WHERE account_id=? "
                        "AND document_id=? AND version_id=?"
                    ),
                    (accountId, version["document_id"], version["version_id"]),
                )
            if len(versions) > maximumCloudVersions:
                return "unfinishedCloud"
            # Fixed statements only. No identities, hashes or content are copied
            # to an anonymization table; the ordinary relationship is deleted.
            for statement in (
                "DELETE FROM cloud_consents WHERE account_id=?",
                "DELETE FROM cloud_operations WHERE account_id=?",
                "DELETE FROM cloud_documents WHERE account_id=?",
                "DELETE FROM cloud_account_state WHERE account_id=?",
                "DELETE FROM account_recovery_codes WHERE account_id=?",
                "DELETE FROM account_privilege_grants WHERE account_id=?",
                "DELETE FROM usage_reconciliations WHERE operation_id IN "
                "(SELECT operation_id FROM usage_operations WHERE account_id=?)",
                "DELETE FROM usage_operations WHERE account_id=?",
                "DELETE FROM subscription_snapshots WHERE account_id=?",
                "DELETE FROM account_sessions WHERE account_id=?",
                "DELETE FROM account_retirements WHERE account_id=?",
                "DELETE FROM accounts WHERE account_id=? AND is_active=0",
            ):
                changed = connection.execute(self._sql(statement), (accountId,))
                if statement.startswith("DELETE FROM accounts ") and changed != 1:
                    raise StorageUnavailableError("retention_storage_inconsistent")
            return "deleted"

    def fulfillEarlierDeletion(
        self, *, accountId: str, verifiedRequestSha256: str, maximumCloudVersions: int = 200
    ) -> str:
        """Trusted handler only, after verification and deactivation; no public route.

        A valid earlier deletion request must not wait 60 days. Evidence is held
        in the separate minimal rights-request register, not copied into this DB.
        Unsettled execution and a specifically evidenced unexpired legal hold
        remain explicit blockers requiring prompt handling and feedback.
        """
        if (
            re.fullmatch(r"[A-Za-z0-9._:-]{1,64}", accountId) is None
            or re.fullmatch(r"[a-f0-9]{64}", verifiedRequestSha256) is None
            or type(maximumCloudVersions) is not int
            or not 1 <= maximumCloudVersions <= 200
        ):
            raise ValueError("verified_deletion_request_required")
        return self._purge(accountId, maximumCloudVersions, earlierDeletion=True)


def recordRetentionHold(
    connection: AccountSqlConnection,
    *,
    mysql: bool,
    accountId: str,
    kind: Literal["legalObligation", "actualDispute"],
    untilUtc: datetime,
    evidenceSha256: str,
) -> None:
    """Same management transaction as the real case record; no indefinite holds.

    The evidence record must identify the exact necessary retained scope and
    basis. This helper cannot itself establish a lawful basis for holding data.
    """
    if (
        kind not in {"legalObligation", "actualDispute"}
        or re.fullmatch(r"[a-f0-9]{64}", evidenceSha256) is None
    ):
        raise ValueError("invalid_retention_hold")
    query = (
        "SELECT is_active FROM accounts WHERE account_id=? FOR UPDATE"
        if mysql
        else "SELECT is_active FROM accounts WHERE account_id=?"
    )
    row = connection.fetchOne(query.replace("?", "%s" if mysql else "?"), (accountId,))
    if row is None or row["is_active"] != 0:
        raise ValueError("retired_account_required")
    changed = connection.execute(
        (
            "UPDATE account_retirements SET hold_kind=?,hold_until_utc=?,hold_evidence_sha256=? "
            "WHERE account_id=?"
        ).replace("?", "%s" if mysql else "?"),
        (kind, toUtcText(requireUtc(untilUtc)), evidenceSha256, accountId),
    )
    if changed != 1:
        raise ValueError("retirement_record_required")
