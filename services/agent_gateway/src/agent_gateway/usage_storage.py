from __future__ import annotations

from collections.abc import Iterator, Mapping
from contextlib import AbstractContextManager, contextmanager
from typing import Protocol

from .account_storage import (
    AccountSqlConnection,
    AccountSqlDatabase,
    SqliteAccountDatabase,
    StorageUnavailableError,
)
from .database import GatewayDatabase


class UsageTransaction(Protocol):
    def lockAccount(self, accountId: str) -> None: ...
    def findOwned(
        self, accountId: str, capability: str, key: str, byId: bool
    ) -> Mapping[str, object] | None: ...
    def findOperation(
        self, operationId: str, *, lock: bool = False
    ) -> Mapping[str, object] | None: ...
    def findReconciliation(self, operationId: str) -> Mapping[str, object] | None: ...
    def readPlan(self, accountId: str, now: str) -> str: ...
    def countMonthly(self, accountId: str, start: str, end: str, *, basic: bool = True) -> int: ...
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
    ) -> None: ...
    def updateOperation(
        self,
        operationId: str,
        status: str,
        now: str,
        failure: str | None,
        prompt: str | None,
        inputTokens: int | None,
        outputTokens: int | None,
        *,
        replaceMetadata: bool = False,
    ) -> None: ...
    def insertReconciliation(
        self, operationId: str, operatorId: str, evidenceSha256: str, kind: str, now: str
    ) -> None: ...
    def markAbandoned(self, before: str) -> int: ...
    def setFakeSubscription(self, accountId: str, start: str, end: str, now: str) -> None: ...


class UsageStore(Protocol):
    @property
    def authorityKey(self) -> tuple[str, ...]: ...

    def readConnection(self) -> AbstractContextManager[UsageTransaction]: ...
    def transaction(self) -> AbstractContextManager[UsageTransaction]: ...


class RelationalUsageTransaction:
    def __init__(
        self, connection: AccountSqlConnection, *, mysql: bool, withPrivileges: bool = False
    ) -> None:
        self._connection = connection
        self._mysql = mysql
        self._withPrivileges = withPrivileges

    def _sql(self, statement: str, *, lock: bool = False) -> str:
        return statement.replace("?", "%s" if self._mysql else "?") + (
            " FOR UPDATE" if self._mysql and lock else ""
        )

    def _read(
        self, statement: str, parameters: tuple[object, ...], *, lock: bool = False
    ) -> Mapping[str, object] | None:
        row = self._connection.fetchOne(self._sql(statement, lock=lock), parameters)
        if row is None:
            return None
        # 二进制 ID/摘要不经过大小写不敏感的字符排序，也不把 bytes 的 repr 当成 ID。
        return {
            name: value.decode("ascii") if isinstance(value, bytes) else value
            for name, value in row.items()
        }

    def lockAccount(self, accountId: str) -> None:
        row = self._read(
            "SELECT account_id, is_active FROM accounts WHERE account_id = ?",
            (accountId,),
            lock=True,
        )
        if row is None or row["is_active"] != 1:
            raise StorageUnavailableError("用量账户不可用")

    def findOwned(
        self, accountId: str, capability: str, key: str, byId: bool
    ) -> Mapping[str, object] | None:
        query = (
            "SELECT * FROM usage_operations WHERE account_id = ? "
            "AND capability = ? AND operation_id = ?"
            if byId
            else "SELECT * FROM usage_operations WHERE account_id = ? "
            "AND capability = ? AND idempotency_key_hash = ?"
        )
        return self._read(
            query,
            (accountId, capability, key),
        )

    def findOperation(self, operationId: str, *, lock: bool = False) -> Mapping[str, object] | None:
        return self._read(
            "SELECT * FROM usage_operations WHERE operation_id = ?", (operationId,), lock=lock
        )

    def findReconciliation(self, operationId: str) -> Mapping[str, object] | None:
        return self._read(
            "SELECT * FROM usage_reconciliations WHERE operation_id = ?", (operationId,)
        )

    def readPlan(self, accountId: str, now: str) -> str:
        if self._withPrivileges:
            from .account_privileges import hasPermanentMembership

            if hasPermanentMembership(self._connection, accountId, mysql=self._mysql):
                return "pro"
        row = self._read(
            "SELECT plan FROM subscription_snapshots WHERE account_id = ? "
            "AND starts_at_utc <= ? AND ends_at_utc > ?",
            (accountId, now, now),
        )
        return "free" if row is None else str(row["plan"])

    def countMonthly(self, accountId: str, start: str, end: str, *, basic: bool = True) -> int:
        # A committed provider call can yield zero reviewable candidates. Keep its
        # prompt/tokens/status for cost audit, exclude only this explicit outcome.
        capabilities = (
            ("basicResumeCompose", "basicResumeCompose")
            if basic
            else ("targetedResumeOptimization", "resumeOptimizationConversation")
        )
        row = self._read(
            "SELECT COUNT(*) AS operation_count FROM usage_operations WHERE account_id = ? "
            "AND capability IN (?, ?) AND created_at_utc >= ? AND created_at_utc < ? "
            "AND (failure_code IS NULL OR failure_code <> 'invalid_candidate_usage_unknown') "
            "AND (status IN ('reserved', 'pendingReconciliation') OR "
            "(status = 'committed' AND (failure_code IS NULL "
            "OR failure_code <> 'no_usable_candidate')))",
            (accountId, *capabilities, start, end),
        )
        if row is None:
            raise StorageUnavailableError("用量计数不可用")
        return int(str(row["operation_count"]))

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
        self._connection.execute(
            self._sql(
                "INSERT INTO usage_operations(operation_id, account_id, capability, "
                "idempotency_key_hash, request_fingerprint_hash, status, quota_window_start_utc, "
                "quota_window_end_utc, plan_at_reservation, created_at_utc, updated_at_utc, "
                "failure_code) VALUES (?, ?, ?, ?, ?, 'reserved', ?, ?, ?, ?, ?, NULL)"
            ),
            (
                operationId,
                accountId,
                capability,
                keyHash,
                fingerprintHash,
                start,
                end,
                plan,
                now,
                now,
            ),
        )

    def updateOperation(
        self,
        operationId: str,
        status: str,
        now: str,
        failure: str | None,
        prompt: str | None,
        inputTokens: int | None,
        outputTokens: int | None,
        *,
        replaceMetadata: bool = False,
    ) -> None:
        query = (
            "UPDATE usage_operations SET status = ?, updated_at_utc = ?, failure_code = ?, "
            "prompt_version = ?, input_tokens = ?, output_tokens = ? WHERE operation_id = ?"
            if replaceMetadata
            else "UPDATE usage_operations SET status = ?, updated_at_utc = ?, failure_code = ?, "
            "prompt_version = COALESCE(?, prompt_version), "
            "input_tokens = COALESCE(?, input_tokens), "
            "output_tokens = COALESCE(?, output_tokens) WHERE operation_id = ?"
        )
        count = self._connection.execute(
            self._sql(query),
            (status, now, failure, prompt, inputTokens, outputTokens, operationId),
        )
        if count != 1:
            raise StorageUnavailableError("用量更新未完成")

    def insertReconciliation(
        self, operationId: str, operatorId: str, evidenceSha256: str, kind: str, now: str
    ) -> None:
        self._connection.execute(
            self._sql(
                "INSERT INTO usage_reconciliations(operation_id, operator_id, evidence_sha256, "
                "evidence_kind, finalized_at_utc) VALUES (?, ?, ?, ?, ?)"
            ),
            (operationId, operatorId, evidenceSha256, kind, now),
        )

    def markAbandoned(self, before: str) -> int:
        return self._connection.execute(
            self._sql(
                "UPDATE usage_operations SET status = 'pendingReconciliation', "
                "failure_code = 'execution_interrupted' "
                "WHERE status = 'reserved' AND updated_at_utc < ?"
            ),
            (before,),
        )

    def setFakeSubscription(self, accountId: str, start: str, end: str, now: str) -> None:
        base = (
            "INSERT INTO subscription_snapshots(account_id, plan, starts_at_utc, ends_at_utc, "
            "source, updated_at_utc) VALUES (?, 'pro', ?, ?, 'fake', ?) "
        )
        if self._mysql:
            suffix = (
                "ON DUPLICATE KEY UPDATE plan = 'pro', starts_at_utc = ?, ends_at_utc = ?, "
                "source = 'fake', updated_at_utc = ?"
            )
            parameters: tuple[object, ...] = (accountId, start, end, now, start, end, now)
        else:
            suffix = (
                "ON CONFLICT(account_id) DO UPDATE SET plan = excluded.plan, "
                "starts_at_utc = excluded.starts_at_utc, ends_at_utc = excluded.ends_at_utc, "
                "source = excluded.source, updated_at_utc = excluded.updated_at_utc"
            )
            parameters = (accountId, start, end, now)
        self._connection.execute(self._sql(base + suffix), parameters)


class RelationalUsageStore:
    def __init__(
        self, database: AccountSqlDatabase, *, mysql: bool, withPrivileges: bool = False
    ) -> None:
        self._database = database
        self._mysql = mysql
        self._withPrivileges = withPrivileges

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return self._database.authorityKey

    @contextmanager
    def readConnection(self) -> Iterator[UsageTransaction]:
        with self._database.readConnection() as connection:
            yield RelationalUsageTransaction(
                connection, mysql=self._mysql, withPrivileges=self._withPrivileges
            )

    @contextmanager
    def transaction(self) -> Iterator[UsageTransaction]:
        with self._database.transaction() as connection:
            yield RelationalUsageTransaction(
                connection, mysql=self._mysql, withPrivileges=self._withPrivileges
            )


class SqliteUsageStore(RelationalUsageStore):
    def __init__(self, database: GatewayDatabase, *, withPrivileges: bool = False) -> None:
        super().__init__(
            SqliteAccountDatabase(database), mysql=False, withPrivileges=withPrivileges
        )


class MySqlUsageStore(RelationalUsageStore):
    def __init__(self, database: AccountSqlDatabase, *, withPrivileges: bool = False) -> None:
        super().__init__(database, mysql=True, withPrivileges=withPrivileges)
