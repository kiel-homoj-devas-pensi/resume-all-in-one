from __future__ import annotations

import hashlib
import hmac
import json
import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Literal
from uuid import UUID

from .account_lifecycle import VerificationPurpose
from .account_storage import AccountSqlConnection, AccountSqlDatabase, storedText
from .identity import requireUtc, toUtcText
from .open_test import OpenTestPolicy, openTestActive

SmsOutcome = Literal["accepted", "rejected", "unknown"]
# 已核对 PNVS API 小规模按量价；实际启用仍需按当期价格配置更高的预留值。
MINIMUM_PNVS_RESERVE_CENTS = 6


def smsStoredTotals(
    connection: AccountSqlConnection, *, mysql: bool, withSummary: bool, unit: int
) -> tuple[int, int]:
    query = (
        "SELECT COUNT(*) AS attempts, COALESCE(SUM(reserved_cents), 0) AS cents, "
        "COALESCE(SUM(CASE WHEN reserved_cents != ? THEN 1 ELSE 0 END), 0) AS invalid "
        "FROM sms_send_attempts WHERE policy_id = ?"
    )
    parameters: tuple[object, ...] = (unit, "pnvs")
    if withSummary:
        # One statement observes live rows and archive atomically, even while a
        # startup reader and compactor both hold shared policy locks.
        query = (
            "SELECT live.attempts,live.cents,live.invalid,s.attempts AS archived_attempts,"  # noqa: S608 — fixed SQL fragments only.
            "s.reserved_cents AS archived_cents,s.unresolved_attempts,s.unresolved_reserved_cents "
            "FROM (" + query + ") live "
            "LEFT JOIN sms_send_summary s ON s.policy_id=?"
        )
        parameters += ("pnvs",)
    totals = connection.fetchOne(query.replace("?", "%s" if mysql else "?"), parameters)
    if totals is None or int(str(totals["invalid"])) != 0:
        raise ValueError("sms_budget_ledger_inconsistent")
    archived = archivedCents = 0
    if withSummary:
        if totals["archived_attempts"] is None or totals["archived_cents"] is None:
            raise ValueError("sms_summary_missing")
        archived, archivedCents = (
            int(str(totals["archived_attempts"])),
            int(str(totals["archived_cents"])),
        )
        unresolved, unresolvedCents = (
            int(str(totals["unresolved_attempts"])),
            int(str(totals["unresolved_reserved_cents"])),
        )
        if (
            archived < 0
            or archivedCents != archived * unit
            or not 0 <= unresolved <= archived
            or unresolvedCents != unresolved * unit
        ):
            raise ValueError("sms_summary_inconsistent")
    return int(str(totals["attempts"])) + archived, int(str(totals["cents"])) + archivedCents


class SmsBudgetExceededError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("sms_budget_exceeded")


class SmsAttemptReplayError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("sms_attempt_already_reserved")


@dataclass(frozen=True, slots=True, repr=False)
class SmsBudgetPolicy:
    maximumAttempts: int
    budgetCents: int
    reservePerAttemptCents: int
    expiresAtUtc: datetime
    allowedPhones: frozenset[str]
    recipientScope: Literal["allowlist", "unregistered"] = "allowlist"
    enabled: bool = True

    def __post_init__(self) -> None:
        if (
            type(self.maximumAttempts) is not int
            or not 1 <= self.maximumAttempts <= 10_000
            or type(self.budgetCents) is not int
            or not 1 <= self.budgetCents <= 1_000_000
            or type(self.reservePerAttemptCents) is not int
            or not MINIMUM_PNVS_RESERVE_CENTS <= self.reservePerAttemptCents <= self.budgetCents
            or not isinstance(self.allowedPhones, frozenset)
            or self.recipientScope not in {"allowlist", "unregistered"}
            or type(self.enabled) is not bool
            or not (
                1 <= len(self.allowedPhones) <= 100
                if self.recipientScope == "allowlist"
                else len(self.allowedPhones) == 0
            )
            or any(
                not isinstance(phone, str) or re.fullmatch(r"\+861[3-9][0-9]{9}", phone) is None
                for phone in self.allowedPhones
            )
            or not isinstance(self.expiresAtUtc, datetime)
        ):
            raise ValueError("invalid_sms_budget_policy")
        requireUtc(self.expiresAtUtc)


class SmsBudgetLedger:
    """单一 PNVS 预算；启动只核对，批准配置的首次写入由独立管理操作完成。"""

    def __init__(
        self,
        database: AccountSqlDatabase,
        policy: SmsBudgetPolicy,
        *,
        auditSecret: bytes,
        withSummary: bool = False,
        openTestPolicy: OpenTestPolicy | None = None,
    ) -> None:
        if (
            not isinstance(auditSecret, bytes)
            or len(auditSecret) < 32
            or database.authorityKey[0] not in {"sqlite", "mysql"}
            or type(withSummary) is not bool
        ):
            raise ValueError("invalid_sms_budget_storage")
        self._database = database
        self._mysql = database.authorityKey[0] == "mysql"
        self._policy = policy
        self._secret = auditSecret
        self._withSummary = withSummary
        self._openTestPolicy = openTestPolicy
        canonicalPolicy: dict[str, object] = {
            "maximumAttempts": policy.maximumAttempts,
            "budgetCents": policy.budgetCents,
            "reservePerAttemptCents": policy.reservePerAttemptCents,
            "expiresAtUtc": toUtcText(policy.expiresAtUtc),
            "allowedPhones": sorted(policy.allowedPhones),
        }
        # Preserve the deployed v1 allowlist fingerprint byte for byte.
        # The emergency disable switch can only narrow already approved limits.
        if policy.recipientScope != "allowlist":
            canonicalPolicy["recipientScope"] = policy.recipientScope
        canonical = json.dumps(
            canonicalPolicy,
            separators=(",", ":"),
        )
        self._fingerprint = self._digest("policy:" + canonical)

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return self._database.authorityKey

    @property
    def policyFingerprint(self) -> str:
        return self._fingerprint

    def approvedPolicySnapshot(self) -> dict[str, str | int]:
        """Read a consistent, credential-free policy and retained usage for maintenance."""
        with self._database.transaction() as connection:
            counters = self._policyRow(connection, sharedLock=True)
            if counters is None:
                raise ValueError("sms_budget_not_approved")
            return {
                "policyFingerprint": self._fingerprint,
                "maximumAttempts": self._policy.maximumAttempts,
                "budgetCents": self._policy.budgetCents,
                "reservePerAttemptCents": self._policy.reservePerAttemptCents,
                "expiresAtUtc": toUtcText(self._policy.expiresAtUtc),
                "attempts": counters[0],
                "reservedCents": counters[1],
            }

    def _digest(self, value: str) -> str:
        return hmac.new(self._secret, value.encode(), hashlib.sha256).hexdigest()

    def _sql(self, statement: str, *, lock: bool = False) -> str:
        return statement.replace("?", "%s" if self._mysql else "?") + (
            " FOR UPDATE" if self._mysql and lock else ""
        )

    def _policyRow(
        self, connection: AccountSqlConnection, *, sharedLock: bool = False
    ) -> tuple[int, int] | None:
        statement = self._sql(
            "SELECT * FROM sms_send_budget WHERE policy_id = ?", lock=not sharedLock
        )
        if self._mysql and sharedLock:
            # MySQL 8.0.22+: policy readers/first approvers need SELECT, not policy UPDATE.
            statement += " FOR SHARE"
        row = connection.fetchOne(statement, ("pnvs",))
        if row is None:
            return None
        policy = self._policy
        count, cents = int(str(row["attempts"])), int(str(row["reserved_cents"]))
        # Stored ceilings grow only to actual retained totals. The approved
        # fingerprint/configuration remains the finite admission authority.
        if (
            not hmac.compare_digest(storedText(row["policy_fingerprint"]), self._fingerprint)
            or row["maximum_attempts"] != max(policy.maximumAttempts, count)
            or row["budget_cents"] != max(policy.budgetCents, cents)
            or row["reserve_per_attempt_cents"] != policy.reservePerAttemptCents
            or storedText(row["expires_at_utc"]) != toUtcText(policy.expiresAtUtc)
        ):
            raise ValueError("sms_budget_policy_mismatch")
        totals = smsStoredTotals(
            connection,
            mysql=self._mysql,
            withSummary=self._withSummary,
            unit=policy.reservePerAttemptCents,
        )
        if (count, cents) != totals or count < 0 or cents < 0:
            raise ValueError("sms_budget_ledger_inconsistent")
        return count, cents

    def createApprovedPolicy(self, *, nowUtc: datetime | None = None) -> None:
        now = requireUtc(nowUtc or datetime.now(UTC))
        if now >= self._policy.expiresAtUtc:
            raise ValueError("sms_budget_policy_expired")
        with self._database.transaction() as connection:
            if self._policyRow(connection, sharedLock=True) is not None:
                # 重跑只核对，不能通过启动或再次批准相同配置恢复已使用额度。
                return
            connection.execute(
                self._sql(
                    "INSERT INTO sms_send_budget (policy_id, policy_fingerprint, maximum_attempts, "
                    "budget_cents, reserve_per_attempt_cents, attempts, reserved_cents, "
                    "expires_at_utc, created_at_utc) VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?)"
                ),
                (
                    "pnvs",
                    self._fingerprint,
                    self._policy.maximumAttempts,
                    self._policy.budgetCents,
                    self._policy.reservePerAttemptCents,
                    toUtcText(self._policy.expiresAtUtc),
                    toUtcText(now),
                ),
            )
            if self._withSummary:
                connection.execute(
                    self._sql(
                        "INSERT INTO sms_send_summary(policy_id,attempts,reserved_cents) "
                        "VALUES(?,0,0)"
                    ),
                    ("pnvs",),
                )

    def assertApprovedPolicy(self) -> None:
        with self._database.transaction() as connection:
            if self._policyRow(connection, sharedLock=True) is None:
                raise ValueError("sms_budget_not_approved")

    def reserve(
        self,
        challengeId: str,
        phone: str,
        purpose: VerificationPurpose,
        *,
        nowUtc: datetime | None = None,
    ) -> None:
        now = requireUtc(nowUtc or datetime.now(UTC))
        unlimited = openTestActive(self._openTestPolicy, now)
        publicRegistration = (
            (unlimited or self._policy.recipientScope == "unregistered")
            and purpose == "register"
            and re.fullmatch(r"\+861[3-9][0-9]{9}", phone) is not None
        )
        if not publicRegistration and (
            self._policy.recipientScope != "allowlist"
            or phone not in self._policy.allowedPhones
            or purpose not in {"register", "resetPassword"}
        ):
            raise ValueError("sms_recipient_not_allowed")
        try:
            identity = UUID(challengeId.removeprefix("challenge-"))
        except ValueError:
            raise ValueError("invalid_sms_challenge") from None
        if challengeId != f"challenge-{identity}" or identity.version != 4:
            raise ValueError("invalid_sms_challenge")
        now = requireUtc(nowUtc or datetime.now(UTC))
        if not unlimited and (not self._policy.enabled or now >= self._policy.expiresAtUtc):
            raise SmsBudgetExceededError
        with self._database.transaction() as connection:
            counters = self._policyRow(connection)
            if counters is None:
                raise ValueError("sms_budget_not_approved")
            existing = connection.fetchOne(
                self._sql("SELECT outcome FROM sms_send_attempts WHERE challenge_id = ?"),
                (challengeId,),
            )
            if existing is not None:
                raise SmsAttemptReplayError
            if self._withSummary:
                challenge = connection.fetchOne(
                    self._sql(
                        "SELECT purpose,expires_at_utc,consumed_at_utc FROM phone_challenges "
                        "WHERE challenge_id=?"
                    ),
                    (challengeId,),
                )
                if challenge is None or challenge["consumed_at_utc"] is not None:
                    raise SmsAttemptReplayError
                expiryText = storedText(challenge["expires_at_utc"])
                expiry = requireUtc(datetime.fromisoformat(expiryText))
                if (
                    storedText(challenge["purpose"]) != purpose
                    or toUtcText(expiry) != expiryText
                    or not now < expiry <= now + timedelta(minutes=5)
                ):
                    raise SmsAttemptReplayError
            count, cents = counters
            unit = self._policy.reservePerAttemptCents
            unlimited = openTestActive(self._openTestPolicy, nowUtc)
            if not unlimited and (
                not self._policy.enabled
                or requireUtc(nowUtc or datetime.now(UTC)) >= self._policy.expiresAtUtc
                or count >= self._policy.maximumAttempts
                or cents + unit > self._policy.budgetCents
            ):
                raise SmsBudgetExceededError
            connection.execute(
                self._sql(
                    "INSERT INTO sms_send_attempts (challenge_id, policy_id, phone_hash, purpose, "
                    "outcome, reserved_cents, created_at_utc) VALUES (?, ?, ?, ?, 'reserved', ?, ?)"
                ),
                (
                    challengeId,
                    "pnvs",
                    self._digest("phone:" + phone),
                    purpose,
                    unit,
                    toUtcText(now),
                ),
            )
            ceilingCount = max(self._policy.maximumAttempts, count + 1)
            ceilingCents = max(self._policy.budgetCents, cents + unit)
            if unlimited and (
                count + 1 > self._policy.maximumAttempts or cents + unit > self._policy.budgetCents
            ):
                changed = connection.execute(
                    self._sql(
                        "UPDATE sms_send_budget SET attempts=?,reserved_cents=?,"
                        "maximum_attempts=?,budget_cents=? WHERE policy_id=?"
                    ),
                    (count + 1, cents + unit, ceilingCount, ceilingCents, "pnvs"),
                )
            else:
                changed = connection.execute(
                    self._sql(
                        "UPDATE sms_send_budget SET attempts=?,reserved_cents=? WHERE policy_id=?"
                    ),
                    (count + 1, cents + unit, "pnvs"),
                )
            if changed != 1:
                raise ValueError("sms_budget_ledger_inconsistent")
        # 只有正常确认提交，调用者才有发送资格；未知提交不返回成功、不重放。

    def finalize(
        self,
        challengeId: str,
        outcome: SmsOutcome,
        *,
        requestIdDigest: str | None = None,
        bizIdDigest: str | None = None,
        nowUtc: datetime | None = None,
    ) -> None:
        if outcome not in {"accepted", "rejected", "unknown"} or any(
            value is not None and re.fullmatch(r"[0-9a-f]{64}", value) is None
            for value in (requestIdDigest, bizIdDigest)
        ):
            raise ValueError("invalid_sms_outcome")
        if outcome != "accepted" and (requestIdDigest is not None or bizIdDigest is not None):
            raise ValueError("invalid_sms_outcome")
        now = requireUtc(nowUtc or datetime.now(UTC))
        with self._database.transaction() as connection:
            if self._policyRow(connection) is None:
                raise ValueError("sms_budget_not_approved")
            changed = connection.execute(
                self._sql(
                    "UPDATE sms_send_attempts SET outcome = ?, finalized_at_utc = ?, "
                    "request_id_digest = ?, biz_id_digest = ? "
                    "WHERE challenge_id = ? AND policy_id = ? AND outcome = 'reserved'"
                ),
                (outcome, toUtcText(now), requestIdDigest, bizIdDigest, challengeId, "pnvs"),
            )
            if changed != 1:
                raise ValueError("sms_attempt_not_reserved")
        # 所有尝试保守占位；最终状态不会返还次数或费用，也不以新进程重置策略。
