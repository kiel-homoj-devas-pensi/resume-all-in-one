from __future__ import annotations

import sqlite3
from collections.abc import Iterator, Mapping
from contextlib import AbstractContextManager, contextmanager
from dataclasses import dataclass, field
from typing import Protocol

from .database import GatewayDatabase


class AccountAlreadyExistsError(RuntimeError):
    pass


class StorageUnavailableError(RuntimeError):
    pass


class UnknownStorageCommitError(StorageUnavailableError):
    """提交可能已完成，不能自动重放写入。"""


@dataclass(frozen=True)
class StoredAccount:
    accountId: str
    passwordHash: str = field(repr=False)
    active: bool


class AccountStore(Protocol):
    @property
    def authorityKey(self) -> tuple[str, ...]: ...

    def insertAccount(self, accountId: str, phone: str, passwordHash: str, now: str) -> None: ...

    def findAccount(self, phone: str) -> StoredAccount | None: ...

    def issueSession(
        self,
        accountId: str,
        expectedPasswordHash: str,
        sessionId: str,
        tokenHash: str,
        expiry: str,
        now: str,
    ) -> bool: ...

    def authenticate(self, tokenHash: str, now: str) -> str | None: ...

    def revokeSessions(self, accountId: str, now: str) -> None: ...


class AccountSqlConnection(Protocol):
    def execute(self, sql: str, parameters: tuple[object, ...] = ()) -> int: ...

    def fetchOne(
        self,
        sql: str,
        parameters: tuple[object, ...] = (),
    ) -> Mapping[str, object] | None: ...

    def fetchMany(
        self, sql: str, parameters: tuple[object, ...] = (), *, maximumRows: int
    ) -> tuple[Mapping[str, object], ...]: ...


class AccountSqlDatabase(Protocol):
    @property
    def authorityKey(self) -> tuple[str, ...]: ...

    def readConnection(self) -> AbstractContextManager[AccountSqlConnection]: ...

    def transaction(self) -> AbstractContextManager[AccountSqlConnection]: ...


def storedText(value: object) -> str:
    # MySQL VARBINARY 保持 ID 大小写及尾空格语义，驱动返回 bytes。
    if isinstance(value, bytes):
        return value.decode("ascii")
    return str(value)


class RelationalAccountStore:
    def __init__(
        self,
        database: AccountSqlDatabase,
        *,
        parameter: str,
        accountLock: str,
    ) -> None:
        if parameter not in {"?", "%s"} or accountLock not in {"", " FOR UPDATE"}:
            raise ValueError("无效存储方言")
        self._sqlDatabase = database
        self._parameter = parameter
        self._accountLock = accountLock

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return self._sqlDatabase.authorityKey

    def _sql(self, statement: str, *, lockAccount: bool = False) -> str:
        # 只转换本适配器固定 SQL 的占位符，数据始终另行绑定。
        return statement.replace("?", self._parameter) + (self._accountLock if lockAccount else "")

    def insertAccount(self, accountId: str, phone: str, passwordHash: str, now: str) -> None:
        with self._sqlDatabase.transaction() as connection:
            connection.execute(
                self._sql(
                    "INSERT INTO accounts(account_id, phone_e164, password_hash, "
                    "phone_verified_at_utc, created_at_utc, is_active) VALUES (?, ?, ?, ?, ?, 1)"
                ),
                (accountId, phone, passwordHash, now, now),
            )

    def findAccount(self, phone: str) -> StoredAccount | None:
        with self._sqlDatabase.readConnection() as connection:
            row = connection.fetchOne(
                self._sql(
                    "SELECT account_id, password_hash, is_active FROM accounts WHERE phone_e164 = ?"
                ),
                (phone,),
            )
        if row is None:
            return None
        return StoredAccount(
            storedText(row["account_id"]),
            storedText(row["password_hash"]),
            row["is_active"] == 1,
        )

    def issueSession(
        self,
        accountId: str,
        expectedPasswordHash: str,
        sessionId: str,
        tokenHash: str,
        expiry: str,
        now: str,
    ) -> bool:
        with self._sqlDatabase.transaction() as connection:
            # 与未来改密/停用共用账户行锁，复核与插入必须同一事务。
            row = connection.fetchOne(
                self._sql(
                    "SELECT password_hash, is_active FROM accounts WHERE account_id = ?",
                    lockAccount=True,
                ),
                (accountId,),
            )
            if (
                row is None
                or row["is_active"] != 1
                or storedText(row["password_hash"]) != expectedPasswordHash
            ):
                return False
            connection.execute(
                self._sql(
                    "INSERT INTO account_sessions(session_id, account_id, token_hash, "
                    "expires_at_utc, created_at_utc, revoked_at_utc) VALUES (?, ?, ?, ?, ?, NULL)"
                ),
                (sessionId, accountId, tokenHash, expiry, now),
            )
        return True

    def authenticate(self, tokenHash: str, now: str) -> str | None:
        with self._sqlDatabase.readConnection() as connection:
            row = connection.fetchOne(
                self._sql(
                    "SELECT s.account_id FROM account_sessions s JOIN accounts a "
                    "ON a.account_id = s.account_id "
                    "WHERE s.token_hash = ? AND s.expires_at_utc > ? "
                    "AND s.revoked_at_utc IS NULL AND a.is_active = 1"
                ),
                (tokenHash, now),
            )
        return None if row is None else storedText(row["account_id"])

    def revokeSessions(self, accountId: str, now: str) -> None:
        with self._sqlDatabase.transaction() as connection:
            connection.fetchOne(
                self._sql("SELECT account_id FROM accounts WHERE account_id = ?", lockAccount=True),
                (accountId,),
            )
            connection.execute(
                self._sql(
                    "UPDATE account_sessions SET revoked_at_utc = ? "
                    "WHERE account_id = ? AND revoked_at_utc IS NULL"
                ),
                (now, accountId),
            )


class _SqliteConnection:
    def __init__(self, connection: sqlite3.Connection) -> None:
        self._connection = connection

    def execute(self, sql: str, parameters: tuple[object, ...] = ()) -> int:
        try:
            return self._connection.execute(sql, parameters).rowcount
        except sqlite3.IntegrityError as error:
            if error.sqlite_errorcode == sqlite3.SQLITE_CONSTRAINT_UNIQUE:
                raise AccountAlreadyExistsError("账户唯一键冲突") from None
            raise StorageUnavailableError("存储约束失败") from None

    def fetchOne(
        self,
        sql: str,
        parameters: tuple[object, ...] = (),
    ) -> Mapping[str, object] | None:
        row = self._connection.execute(sql, parameters).fetchone()
        return None if row is None else dict(row)

    def fetchMany(
        self, sql: str, parameters: tuple[object, ...] = (), *, maximumRows: int
    ) -> tuple[Mapping[str, object], ...]:
        if type(maximumRows) is not int or not 1 <= maximumRows <= 201:
            raise ValueError("invalid_storage_row_bound")
        cursor = self._connection.cursor()
        try:
            cursor.execute(sql, parameters)
            rows = cursor.fetchmany(maximumRows + 1)
            if len(rows) > maximumRows:
                raise StorageUnavailableError("storage_row_bound_exceeded")
            return tuple(dict(row) for row in rows)
        except sqlite3.Error:
            raise StorageUnavailableError("storage_read_unavailable") from None
        finally:
            cursor.close()


class SqliteAccountDatabase:
    def __init__(self, database: GatewayDatabase) -> None:
        self._database = database

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return ("sqlite", str(self._database.databasePath.resolve()))

    @contextmanager
    def readConnection(self) -> Iterator[AccountSqlConnection]:
        with self._database.readConnection() as connection:
            yield _SqliteConnection(connection)

    @contextmanager
    def transaction(self) -> Iterator[AccountSqlConnection]:
        with self._database.immediateTransaction() as connection:
            yield _SqliteConnection(connection)


class SqliteAccountStore(RelationalAccountStore):
    def __init__(self, database: GatewayDatabase) -> None:
        super().__init__(SqliteAccountDatabase(database), parameter="?", accountLock="")
