"""Compact old details; retain unresolved-labelled charges and the lifetime budget."""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

from .account_storage import AccountSqlDatabase, storedText
from .identity import requireUtc, toUtcText
from .sms_budget import smsStoredTotals
from .sms_phone_retention import _validAttemptId

SMS_DETAIL_RETENTION_DAYS = 90


@dataclass(frozen=True, slots=True)
class SmsSummaryBatch:
    scannedAttempts: int
    summarizedAttempts: int
    invalidRecords: int
    moreCandidates: bool
    nextAttemptId: str | None = field(repr=False)


class SmsAttemptSummaryWorker:
    def __init__(
        self,
        database: AccountSqlDatabase,
        *,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        if database.authorityKey[0] not in {"sqlite", "mysql"}:
            raise ValueError("sms_summary_database_required")
        self._database = database
        self._mysql = database.authorityKey[0] == "mysql"
        self._clock = clock

    def _sql(self, query: str, *, shared: bool = False, lock: bool = False) -> str:
        suffix = " FOR SHARE" if shared else " FOR UPDATE" if lock else ""
        return query.replace("?", "%s" if self._mysql else "?") + (suffix if self._mysql else "")

    def summarize(
        self, *, maximumAttempts: int = 100, afterAttemptId: str = "", lookAheadSeconds: int = 0
    ) -> SmsSummaryBatch:
        if (
            type(maximumAttempts) is not int
            or not 1 <= maximumAttempts <= 100
            or type(lookAheadSeconds) is not int
            or not 0 <= lookAheadSeconds <= 300
            or (afterAttemptId and not _validAttemptId(afterAttemptId))
        ):
            raise ValueError("sms_summary_bound_invalid")
        now = requireUtc(self._clock())
        cutoff = (
            now - timedelta(days=SMS_DETAIL_RETENTION_DAYS) + timedelta(seconds=lookAheadSeconds)
        )
        cutoffText = toUtcText(cutoff)
        with self._database.transaction() as c:
            budget = c.fetchOne(
                self._sql("SELECT * FROM sms_send_budget WHERE policy_id='pnvs'", shared=True)
            )
            if budget is None:
                return SmsSummaryBatch(0, 0, 0, False, None)
            summary = c.fetchOne(
                self._sql(
                    "SELECT attempts,reserved_cents,unresolved_attempts,unresolved_reserved_cents "
                    "FROM sms_send_summary WHERE policy_id='pnvs'",
                    lock=True,
                )
            )
            if summary is None:
                raise ValueError("sms_summary_missing")
            count, cents, unit = (
                int(str(budget[k]))
                for k in ("attempts", "reserved_cents", "reserve_per_attempt_cents")
            )
            if (
                unit < 6
                or not 0 <= count <= int(str(budget["maximum_attempts"]))
                or not 0 <= cents <= int(str(budget["budget_cents"]))
                or smsStoredTotals(c, mysql=self._mysql, withSummary=True, unit=unit)
                != (count, cents)
            ):
                raise ValueError("sms_budget_ledger_inconsistent")
            rows = c.fetchMany(
                self._sql(
                    "SELECT challenge_id,outcome,reserved_cents,created_at_utc,finalized_at_utc,"
                    "request_id_digest,biz_id_digest FROM sms_send_attempts WHERE policy_id='pnvs' "
                    "AND challenge_id>? "
                    "AND outcome IN ('accepted','rejected','unknown','reserved') "
                    "AND created_at_utc<=? ORDER BY challenge_id LIMIT ?",
                    lock=True,
                ),
                (afterAttemptId, cutoffText, maximumAttempts + 1),
                maximumRows=maximumAttempts + 1,
            )
            summarized = unresolved = invalid = 0
            for row in rows[:maximumAttempts]:
                try:
                    attemptId = storedText(row["challenge_id"])
                    createdText = storedText(row["created_at_utc"])
                    created = requireUtc(datetime.fromisoformat(createdText))
                    outcome = storedText(row["outcome"])
                    finalValue = row["finalized_at_utc"]
                    if outcome == "reserved":
                        validFinal = finalValue is None
                    else:
                        finalText = storedText(finalValue)
                        final = requireUtc(datetime.fromisoformat(finalText))
                        validFinal = toUtcText(final) == finalText and created <= final <= now
                    if (
                        not _validAttemptId(attemptId)
                        or outcome not in {"accepted", "rejected", "unknown", "reserved"}
                        or toUtcText(created) != createdText
                        or not validFinal
                        or created > cutoff
                        or row["reserved_cents"] != unit
                        or any(
                            value is not None
                            and (
                                outcome != "accepted"
                                or re.fullmatch(r"[a-f0-9]{64}", storedText(value)) is None
                            )
                            for value in (row["request_id_digest"], row["biz_id_digest"])
                        )
                    ):
                        raise ValueError("sms_summary_record_invalid")
                except TypeError, ValueError:
                    invalid += 1
                    continue
                changed = c.execute(
                    self._sql(
                        "DELETE FROM sms_send_attempts WHERE challenge_id=? "
                        "AND outcome=? AND created_at_utc=?"
                    ),
                    (attemptId, outcome, createdText),
                )
                if changed != 1:
                    raise ValueError("sms_summary_storage_inconsistent")
                summarized += 1
                unresolved += int(outcome in {"unknown", "reserved"})
            if summarized:
                changed = c.execute(
                    self._sql(
                        "UPDATE sms_send_summary SET attempts=?,reserved_cents=?,"
                        "unresolved_attempts=?,unresolved_reserved_cents=? "
                        "WHERE policy_id='pnvs'"
                    ),
                    (
                        int(str(summary["attempts"])) + summarized,
                        int(str(summary["reserved_cents"])) + summarized * unit,
                        int(str(summary["unresolved_attempts"])) + unresolved,
                        int(str(summary["unresolved_reserved_cents"])) + unresolved * unit,
                    ),
                )
                if changed != 1 or smsStoredTotals(
                    c, mysql=self._mysql, withSummary=True, unit=unit
                ) != (count, cents):
                    raise ValueError("sms_summary_storage_inconsistent")
                unchangedBudget = c.fetchOne(
                    self._sql("SELECT * FROM sms_send_budget WHERE policy_id='pnvs'", shared=True)
                )
                if unchangedBudget is None or dict(unchangedBudget) != dict(budget):
                    raise ValueError("sms_summary_budget_changed")
        return SmsSummaryBatch(
            min(len(rows), maximumAttempts),
            summarized,
            invalid,
            len(rows) > maximumAttempts,
            storedText(rows[maximumAttempts - 1]["challenge_id"])
            if len(rows) > maximumAttempts
            else None,
        )
