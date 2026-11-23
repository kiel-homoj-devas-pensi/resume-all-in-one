"""Durable anonymous AI identities. No phone, verified account or RDS credentials.

This SQLite authority is for the existing single Gateway host. It must live outside
releases, be ACL protected and backed up through SQLite's online backup API. It
must not be independently replicated across workers/hosts.
"""

from __future__ import annotations

import hashlib
import re
import secrets
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

from pydantic import Field

from .account_storage import AccountSqlConnection, SqliteAccountDatabase, StorageUnavailableError
from .contracts import StrictGatewayModel
from .database import GatewayDatabase, UnsupportedDatabaseSchemaError
from .identity import AuthenticationFailedError, requireUtc, toUtcText
from .open_test import OpenTestPolicy, openTestActive
from .usage import UsagePolicyService, parseUtcText, utcMonthWindow
from .usage_storage import RelationalUsageTransaction, UsageTransaction

GUEST_INSTALLATION_IDLE_DAYS = 60
GUEST_ISSUANCE_RETENTION_HOURS = 6
GUEST_ID_PATTERN = r"guest-[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}"


def guestIssuanceCutoff(nowUtc: datetime, *, lookAheadSeconds: int = 0) -> str:
    """Buckets before this UTC date have ended plus their retention allowance."""
    if type(lookAheadSeconds) is not int or not 0 <= lookAheadSeconds <= 300:
        raise ValueError("invalid_guest_issuance_bound")
    return (
        (
            requireUtc(nowUtc)
            - timedelta(hours=GUEST_ISSUANCE_RETENTION_HOURS)
            + timedelta(seconds=lookAheadSeconds)
        )
        .date()
        .isoformat()
    )


def clearIdleGuestInstallation(
    connection: sqlite3.Connection, row: sqlite3.Row, *, nowUtc: datetime
) -> bool:
    """Call only inside an immediate transaction. Preserve all historical ledgers."""
    now = requireUtc(nowUtc)
    guestId, digest = row["guest_id"], row["credential_hash"]
    seenText, createdText = row["last_seen_at_utc"], row["created_at_utc"]
    seen = requireUtc(datetime.fromisoformat(seenText))
    if toUtcText(seen) != seenText:
        raise ValueError("invalid_guest_installation_record")
    if seen + timedelta(days=GUEST_INSTALLATION_IDLE_DAYS) > now:
        return False
    created = requireUtc(datetime.fromisoformat(createdText))
    if (
        re.fullmatch(GUEST_ID_PATTERN, guestId) is None
        or re.fullmatch(r"[a-f0-9]{64}", digest) is None
        or toUtcText(created) != createdText
        or created > seen
    ):
        raise ValueError("invalid_guest_installation_record")
    tokenHash, expiryText = row["token_hash"], row["session_expires_at_utc"]
    if (tokenHash is None) != (expiryText is None):
        raise ValueError("invalid_guest_installation_record")
    if tokenHash is not None:
        expiry = requireUtc(datetime.fromisoformat(expiryText))
        if (
            re.fullmatch(r"[a-f0-9]{64}", tokenHash) is None
            or toUtcText(expiry) != expiryText
            or expiry > now
        ):
            raise ValueError("invalid_guest_installation_record")
    # NOT NULL/UNIQUE remains unchanged. This marker cannot equal SHA256(secret),
    # stores no replacement secret and preserves the historical guest foreign key.
    changed = connection.execute(
        "UPDATE guest_identities SET credential_hash=? WHERE guest_id=? "
        "AND credential_hash=? AND last_seen_at_utc=?",
        ("cleared:" + guestId, guestId, digest, seenText),
    ).rowcount
    if changed != 1:
        raise ValueError("guest_installation_storage_inconsistent")
    return True


class GuestLimitError(RuntimeError):
    pass


class GuestSessionRequest(StrictGatewayModel):
    installationSecret: str = Field(pattern=r"^[a-f0-9]{64}$", repr=False)


class GuestSessionResponse(StrictGatewayModel):
    protocolVersion: str = "0.1.0"
    guestId: str
    sessionToken: str = Field(repr=False)
    expiresAtUtc: datetime


class GuestDatabase(GatewayDatabase):
    schemaVersion = 1801

    def _applyMigrations(self, databaseConnection: sqlite3.Connection) -> None:
        version = databaseConnection.execute("PRAGMA user_version").fetchone()[0]
        if version == self.schemaVersion:
            return
        if version != 0:
            raise UnsupportedDatabaseSchemaError("不是游客 AI 专用数据库")
        statements = (
            "CREATE TABLE guest_identities (guest_id TEXT PRIMARY KEY, "
            "credential_hash TEXT NOT NULL UNIQUE, token_hash TEXT UNIQUE, "
            "session_expires_at_utc TEXT, created_at_utc TEXT NOT NULL, "
            "last_seen_at_utc TEXT NOT NULL)",
            "CREATE TABLE guest_issuance (bucket_hash TEXT PRIMARY KEY, attempts INTEGER NOT NULL)",
            "CREATE TABLE usage_operations (operation_id TEXT PRIMARY KEY, "
            "account_id TEXT NOT NULL REFERENCES guest_identities(guest_id), "
            "capability TEXT NOT NULL, idempotency_key_hash TEXT NOT NULL, "
            "request_fingerprint_hash TEXT NOT NULL, status TEXT NOT NULL "
            "CHECK(status IN ('reserved','committed','released','pendingReconciliation')), "
            "quota_window_start_utc TEXT NOT NULL, quota_window_end_utc TEXT NOT NULL, "
            "plan_at_reservation TEXT NOT NULL CHECK(plan_at_reservation = 'free'), "
            "created_at_utc TEXT NOT NULL, updated_at_utc TEXT NOT NULL, failure_code TEXT, "
            "prompt_version TEXT, input_tokens INTEGER, output_tokens INTEGER, "
            "UNIQUE(account_id, capability, idempotency_key_hash))",
            "CREATE INDEX guest_usage_month ON usage_operations(created_at_utc, status)",
            "CREATE TABLE usage_reconciliations(operation_id TEXT PRIMARY KEY "
            "REFERENCES usage_operations(operation_id), operator_id TEXT NOT NULL, "
            "evidence_sha256 TEXT NOT NULL, evidence_kind TEXT NOT NULL, "
            "finalized_at_utc TEXT NOT NULL)",
        )
        for statement in statements:
            databaseConnection.execute(statement)
        databaseConnection.execute("PRAGMA user_version = 1801")


class GuestUsageTransaction(RelationalUsageTransaction):
    def __init__(
        self,
        connection: AccountSqlConnection,
        maximumMonthlyCalls: int,
        enabledUntilUtc: datetime | None,
        openTestPolicy: OpenTestPolicy | None = None,
    ) -> None:
        super().__init__(connection, mysql=False)
        self.maximumMonthlyCalls = maximumMonthlyCalls
        self.enabledUntilUtc = enabledUntilUtc
        self.openTestPolicy = openTestPolicy

    def lockAccount(self, accountId: str) -> None:
        if (
            self._read("SELECT guest_id FROM guest_identities WHERE guest_id = ?", (accountId,))
            is None
        ):
            raise StorageUnavailableError("游客身份不可用")

    def readPlan(self, accountId: str, now: str) -> str:
        return "free"

    def insertReservation(
        self,
        operationId: str,
        accountId: str,
        capability: str,
        keyHash: str,
        fingerprintHash: str,
        start: str,
        end: str,
        plan: str,
        now: str,
    ) -> None:
        unlimited = openTestActive(self.openTestPolicy, parseUtcText(now))
        if (
            not unlimited
            and self.enabledUntilUtc is not None
            and parseUtcText(now) >= self.enabledUntilUtc
        ):
            raise GuestLimitError("本轮游客体验已结束")
        # BEGIN IMMEDIATE serializes this global dispatch bound with the per-owner
        # quota reservation. Unknown calls stay occupied even without a candidate.
        row = self._read(
            "SELECT COUNT(*) AS calls FROM usage_operations "
            "WHERE created_at_utc >= ? AND created_at_utc < ? "
            "AND status <> 'released' AND NOT (status = 'committed' "
            "AND COALESCE(input_tokens, -1) = 0 AND COALESCE(output_tokens, -1) = 0)",
            (start, end),
        )
        if row is None or (not unlimited and int(str(row["calls"])) >= self.maximumMonthlyCalls):
            raise GuestLimitError("游客体验当前暂不可用，请稍后再试")
        super().insertReservation(
            operationId, accountId, capability, keyHash, fingerprintHash, start, end, plan, now
        )


class GuestUsageStore:
    def __init__(
        self,
        database: GuestDatabase,
        maximumMonthlyCalls: int,
        enabledUntilUtc: datetime | None,
        openTestPolicy: OpenTestPolicy | None = None,
    ) -> None:
        self.database = SqliteAccountDatabase(database)
        self.maximumMonthlyCalls = maximumMonthlyCalls
        self.enabledUntilUtc = enabledUntilUtc
        self.openTestPolicy = openTestPolicy

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return self.database.authorityKey

    @contextmanager
    def readConnection(self) -> Iterator[UsageTransaction]:
        with self.database.readConnection() as connection:
            yield GuestUsageTransaction(
                connection, self.maximumMonthlyCalls, self.enabledUntilUtc, self.openTestPolicy
            )

    @contextmanager
    def transaction(self) -> Iterator[UsageTransaction]:
        with self.database.transaction() as connection:
            yield GuestUsageTransaction(
                connection, self.maximumMonthlyCalls, self.enabledUntilUtc, self.openTestPolicy
            )


class GuestIdentityService:
    def __init__(
        self,
        path: Path,
        *,
        maximumMonthlyCalls: int,
        maximumMonthlyIdentities: int = 500,
        maximumDailyIssuancePerIp: int = 10,
        enabledUntilUtc: datetime | None = None,
        openTestPolicy: OpenTestPolicy | None = None,
    ) -> None:
        if not path.is_absolute() or maximumMonthlyCalls < 1 or maximumMonthlyIdentities < 1:
            raise ValueError("游客身份要求独立绝对路径及正整数上限")
        if maximumDailyIssuancePerIp < 1:
            raise ValueError("游客发放上限必须为正整数")
        self.database = GuestDatabase(path)
        self.database.initialize()
        self.openTestPolicy = openTestPolicy
        self.enabledUntilUtc = None if enabledUntilUtc is None else requireUtc(enabledUntilUtc)
        self.maximumMonthlyIdentities = maximumMonthlyIdentities
        self.maximumDailyIssuancePerIp = maximumDailyIssuancePerIp
        self.usagePolicy = UsagePolicyService(
            GuestUsageStore(
                self.database, maximumMonthlyCalls, self.enabledUntilUtc, openTestPolicy
            ),
            guest=True,
            openTestPolicy=openTestPolicy,
        )

    def createSession(
        self, installationSecret: str, *, clientAddress: str, nowUtc: datetime | None = None
    ) -> GuestSessionResponse:
        if not re.fullmatch(r"[a-f0-9]{64}", installationSecret):
            raise ValueError("无效游客凭证")
        now = requireUtc(nowUtc or datetime.now(UTC))
        start, end = utcMonthWindow(now)
        credentialHash = hashlib.sha256(installationSecret.encode("ascii")).hexdigest()
        token = "guest-" + secrets.token_urlsafe(32)
        expires = now + timedelta(hours=24)
        with self.database.immediateTransaction() as connection:
            row = connection.execute(
                "SELECT guest_id,credential_hash,created_at_utc,last_seen_at_utc,token_hash,"
                "session_expires_at_utc FROM guest_identities WHERE credential_hash = ?",
                (credentialHash,),
            ).fetchone()
            if row is not None and clearIdleGuestInstallation(connection, row, nowUtc=now):
                row = None
            if row is None:
                if (
                    not openTestActive(self.openTestPolicy, now)
                    and self.enabledUntilUtc is not None
                    and now >= self.enabledUntilUtc
                ):
                    raise GuestLimitError
                count = connection.execute(
                    "SELECT COUNT(*) FROM guest_identities WHERE created_at_utc >= ? "
                    "AND created_at_utc < ?",
                    (toUtcText(start), toUtcText(end)),
                ).fetchone()[0]
                if count >= self.maximumMonthlyIdentities:
                    raise GuestLimitError
                # Store a daily digest, never the address. Ended UTC buckets are
                # kept at most six hours; independent maintenance also runs idle.
                day = now.date().isoformat()
                bucket = day + ":" + hashlib.sha256((day + clientAddress).encode()).hexdigest()
                connection.execute(
                    "DELETE FROM guest_issuance WHERE bucket_hash < ?",
                    (guestIssuanceCutoff(now),),
                )
                prior = connection.execute(
                    "SELECT attempts FROM guest_issuance WHERE bucket_hash = ?", (bucket,)
                ).fetchone()
                if prior is not None and prior[0] >= self.maximumDailyIssuancePerIp:
                    raise GuestLimitError
                connection.execute(
                    "INSERT INTO guest_issuance VALUES (?, 1) "
                    "ON CONFLICT(bucket_hash) DO UPDATE SET attempts = attempts + 1",
                    (bucket,),
                )
                guestId = "guest-" + str(uuid4())
                connection.execute(
                    "INSERT INTO guest_identities(guest_id,credential_hash,"
                    "created_at_utc,last_seen_at_utc) VALUES (?,?,?,?)",
                    (guestId, credentialHash, toUtcText(now), toUtcText(now)),
                )
            else:
                guestId = str(row["guest_id"])
            connection.execute(
                "UPDATE guest_identities SET token_hash = ?, "
                "session_expires_at_utc = ?, last_seen_at_utc = ? WHERE guest_id = ?",
                (
                    hashlib.sha256(token.encode()).hexdigest(),
                    toUtcText(expires),
                    toUtcText(now),
                    guestId,
                ),
            )
        return GuestSessionResponse(guestId=guestId, sessionToken=token, expiresAtUtc=expires)

    def authenticate(self, token: str, *, nowUtc: datetime | None = None) -> str:
        if not token.startswith("guest-") or len(token) > 128:
            raise AuthenticationFailedError
        now = requireUtc(nowUtc or datetime.now(UTC))
        with self.database.readConnection() as connection:
            row = connection.execute(
                "SELECT guest_id FROM guest_identities WHERE token_hash = ? "
                "AND session_expires_at_utc > ?",
                (hashlib.sha256(token.encode()).hexdigest(), toUtcText(now)),
            ).fetchone()
        if row is None:
            raise AuthenticationFailedError
        return str(row["guest_id"])
