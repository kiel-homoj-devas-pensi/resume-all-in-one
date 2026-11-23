from __future__ import annotations

from collections.abc import Iterator, Mapping
from contextlib import AbstractContextManager, contextmanager
from typing import Protocol

from .account_storage import AccountSqlConnection, AccountSqlDatabase, SqliteAccountDatabase
from .cloud_storage import retireAccountCloudDocuments
from .database import GatewayDatabase


class LifecycleTransaction(Protocol):
    def chargeRate(self, bucket: str, now: str, threshold: str) -> int: ...
    def lockPhonePurpose(self, phoneHash: str, purpose: str) -> None: ...
    def replaceChallenge(
        self, challengeId: str, phoneHash: str, purpose: str, codeHash: str, expiry: str, now: str
    ) -> None: ...
    def findChallenge(self, challengeId: str) -> Mapping[str, object] | None: ...
    def setChallengeAttempt(
        self, challengeId: str, attempts: int, consumed: str | None
    ) -> None: ...
    def invalidateChallenge(self, challengeId: str, now: str) -> None: ...
    def findAccount(self, accountId: str, *, lock: bool = False) -> Mapping[str, object] | None: ...
    def findActiveAccountByPhone(self, phone: str) -> str | None: ...
    def activeSession(self, accountId: str, tokenHash: str, now: str) -> bool: ...
    def revokeSessions(self, accountId: str, now: str, tokenHash: str | None = None) -> None: ...
    def replacePassword(self, accountId: str, passwordHash: str, now: str) -> None: ...
    def replaceRecoveryCode(self, accountId: str, digest: str, now: str) -> None: ...
    def readRecoveryCode(self, accountId: str) -> str | None: ...
    def deactivate(self, accountId: str, placeholder: str, now: str) -> None: ...


class LifecycleStore(Protocol):
    @property
    def authorityKey(self) -> tuple[str, ...]: ...
    @property
    def retiresCloudDocuments(self) -> bool: ...
    def readConnection(self) -> AbstractContextManager[LifecycleTransaction]: ...
    def transaction(self) -> AbstractContextManager[LifecycleTransaction]: ...


class RelationalLifecycleTransaction:
    def __init__(
        self,
        connection: AccountSqlConnection,
        *,
        mysql: bool,
        withCloud: bool = False,
        withRetention: bool = False,
    ) -> None:
        self._connection = connection
        self._mysql = mysql
        self._withCloud = withCloud
        self._withRetention = withRetention

    def _sql(self, statement: str, *, lock: bool = False) -> str:
        return statement.replace("?", "%s" if self._mysql else "?") + (
            " FOR UPDATE" if lock and self._mysql else ""
        )

    def _read(
        self, statement: str, parameters: tuple[object, ...], *, lock: bool = False
    ) -> Mapping[str, object] | None:
        row = self._connection.fetchOne(self._sql(statement, lock=lock), parameters)
        if row is None:
            return None
        return {
            name: value.decode("ascii") if isinstance(value, bytes) else value
            for name, value in row.items()
        }

    def chargeRate(self, bucket: str, now: str, threshold: str) -> int:
        query = (
            "INSERT INTO identity_rate_limits(bucket_hash, window_start_utc, attempts) "
            "VALUES (?, ?, 0) ON DUPLICATE KEY UPDATE bucket_hash = bucket_hash"
            if self._mysql
            else "INSERT INTO identity_rate_limits(bucket_hash, window_start_utc, attempts) "
            "VALUES (?, ?, 0) ON CONFLICT(bucket_hash) DO NOTHING"
        )
        self._connection.execute(
            self._sql(query),
            (bucket, now),
        )
        row = self._read(
            ("SELECT window_start_utc, attempts FROM identity_rate_limits WHERE bucket_hash = ?"),
            (bucket,),
            lock=True,
        )
        if row is None:
            raise RuntimeError("限流桶写入后不可读")
        reset = str(row["window_start_utc"]) <= threshold
        count = 1 if reset else int(str(row["attempts"])) + 1
        window = now if reset else row["window_start_utc"]
        self._connection.execute(
            self._sql(
                "UPDATE identity_rate_limits SET window_start_utc = ?, attempts = "
                "? WHERE bucket_hash = ?"
            ),
            (window, count, bucket),
        )
        return count

    def lockPhonePurpose(self, phoneHash: str, purpose: str) -> None:
        if not self._mysql:
            # SQLite 的事务已经取得写锁，不改变已发布的 v4 Schema。
            return
        # Fixed lock slots retain no individual phone digest. Equal phones
        # always share a slot; collisions only serialize independent requests.
        # Keep the existing transactional row lock, schema and Web privileges.
        lockSlot = "lock-bucket:" + phoneHash[:2]
        self._connection.execute(
            self._sql(
                "INSERT INTO phone_verification_guards(phone_hash, purpose) "
                "VALUES (?, ?) ON DUPLICATE KEY UPDATE purpose = purpose"
            ),
            (lockSlot, purpose),
        )
        self._read(
            (
                "SELECT phone_hash FROM phone_verification_guards WHERE "
                "phone_hash = ? AND purpose = ?"
            ),
            (lockSlot, purpose),
            lock=True,
        )

    def replaceChallenge(
        self, challengeId: str, phoneHash: str, purpose: str, codeHash: str, expiry: str, now: str
    ) -> None:
        self._connection.execute(
            self._sql(
                "UPDATE phone_challenges SET consumed_at_utc = ? WHERE phone_hash "
                "= ? AND purpose = ? AND consumed_at_utc IS NULL"
            ),
            (now, phoneHash, purpose),
        )
        self._connection.execute(
            self._sql(
                "INSERT INTO phone_challenges(challenge_id, phone_hash, purpose, "
                "code_hash, expires_at_utc) VALUES (?, ?, ?, ?, ?)"
            ),
            (challengeId, phoneHash, purpose, codeHash, expiry),
        )

    def findChallenge(self, challengeId: str) -> Mapping[str, object] | None:
        return self._read(
            "SELECT * FROM phone_challenges WHERE challenge_id = ?", (challengeId,), lock=True
        )

    def setChallengeAttempt(self, challengeId: str, attempts: int, consumed: str | None) -> None:
        self._connection.execute(
            self._sql(
                "UPDATE phone_challenges SET attempts = ?, consumed_at_utc = ? "
                "WHERE challenge_id = ?"
            ),
            (attempts, consumed, challengeId),
        )

    def invalidateChallenge(self, challengeId: str, now: str) -> None:
        self._connection.execute(
            self._sql(
                "UPDATE phone_challenges SET consumed_at_utc = ? WHERE "
                "challenge_id = ? AND consumed_at_utc IS NULL"
            ),
            (now, challengeId),
        )

    def findAccount(self, accountId: str, *, lock: bool = False) -> Mapping[str, object] | None:
        return self._read(
            ("SELECT account_id, password_hash, is_active FROM accounts WHERE account_id = ?"),
            (accountId,),
            lock=lock,
        )

    def findActiveAccountByPhone(self, phone: str) -> str | None:
        row = self._read(
            ("SELECT account_id FROM accounts WHERE phone_e164 = ? AND is_active = 1"),
            (phone,),
            lock=True,
        )
        return None if row is None else str(row["account_id"])

    def activeSession(self, accountId: str, tokenHash: str, now: str) -> bool:
        row = self._read(
            (
                "SELECT session_id FROM account_sessions WHERE account_id = ? AND "
                "token_hash = ? AND revoked_at_utc IS NULL AND expires_at_utc > ?"
            ),
            (accountId, tokenHash, now),
            lock=True,
        )
        return row is not None

    def revokeSessions(self, accountId: str, now: str, tokenHash: str | None = None) -> None:
        query = (
            (
                "UPDATE account_sessions SET revoked_at_utc = ? WHERE account_id "
                "= ? AND revoked_at_utc IS NULL"
            )
            if tokenHash is None
            else (
                "UPDATE account_sessions SET revoked_at_utc = ? WHERE account_id "
                "= ? AND token_hash = ? AND revoked_at_utc IS NULL"
            )
        )
        parameters: tuple[object, ...] = (
            (now, accountId) if tokenHash is None else (now, accountId, tokenHash)
        )
        self._connection.execute(self._sql(query), parameters)

    def replacePassword(self, accountId: str, passwordHash: str, now: str) -> None:
        self._connection.execute(
            self._sql("UPDATE accounts SET password_hash = ? WHERE account_id = ?"),
            (passwordHash, accountId),
        )
        self.revokeSessions(accountId, now)

    def replaceRecoveryCode(self, accountId: str, digest: str, now: str) -> None:
        statement = (  # noqa: S608 — Both SQL alternatives are fixed literals.
            "INSERT INTO account_recovery_codes(account_id, code_hash, issued_at_utc) "
            "VALUES (?, ?, ?) "
        ) + (
            "ON DUPLICATE KEY UPDATE code_hash = VALUES(code_hash), "
            "issued_at_utc = VALUES(issued_at_utc)"
            if self._mysql
            else "ON CONFLICT(account_id) DO UPDATE SET code_hash = excluded.code_hash, "
            "issued_at_utc = excluded.issued_at_utc"
        )
        self._connection.execute(self._sql(statement), (accountId, digest, now))

    def readRecoveryCode(self, accountId: str) -> str | None:
        row = self._read(
            "SELECT code_hash FROM account_recovery_codes WHERE account_id = ?",
            (accountId,),
            lock=True,
        )
        return None if row is None else str(row["code_hash"])

    def deactivate(self, accountId: str, placeholder: str, now: str) -> None:
        if self._withRetention:
            # Same transaction as credential retirement: a failed insert must
            # roll back the whole action. Never infer this time from old sessions.
            self._connection.execute(
                self._sql(
                    "INSERT INTO account_retirements(account_id,deactivated_at_utc) VALUES (?,?)"
                ),
                (accountId, now),
            )
        if self._withCloud:
            retireAccountCloudDocuments(self._connection, accountId, now, mysql=self._mysql)
        self._connection.execute(
            self._sql(
                "UPDATE accounts SET is_active = 0, phone_e164 = ?, password_hash "
                "= '' WHERE account_id = ?"
            ),
            (placeholder, accountId),
        )
        self.revokeSessions(accountId, now)
        # The separate retention worker removes ordinary rows after 60 days.
        # The Web identity still has no DELETE or entitlement-write permission.


class RelationalLifecycleStore:
    def __init__(
        self,
        database: AccountSqlDatabase,
        *,
        mysql: bool,
        withCloud: bool = False,
        withRetention: bool = False,
    ) -> None:
        self._database = database
        self._mysql = mysql
        self._withCloud = withCloud
        self._withRetention = withRetention

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return self._database.authorityKey

    @property
    def retiresCloudDocuments(self) -> bool:
        return self._withCloud

    @contextmanager
    def readConnection(self) -> Iterator[LifecycleTransaction]:
        with self._database.readConnection() as connection:
            yield RelationalLifecycleTransaction(
                connection,
                mysql=self._mysql,
                withCloud=self._withCloud,
                withRetention=self._withRetention,
            )

    @contextmanager
    def transaction(self) -> Iterator[LifecycleTransaction]:
        with self._database.transaction() as connection:
            yield RelationalLifecycleTransaction(
                connection,
                mysql=self._mysql,
                withCloud=self._withCloud,
                withRetention=self._withRetention,
            )


class SqliteLifecycleStore(RelationalLifecycleStore):
    def __init__(
        self, database: GatewayDatabase, *, withCloud: bool = False, withRetention: bool = False
    ) -> None:
        super().__init__(
            SqliteAccountDatabase(database),
            mysql=False,
            withCloud=withCloud,
            withRetention=withRetention,
        )


class MySqlLifecycleStore(RelationalLifecycleStore):
    def __init__(
        self, database: AccountSqlDatabase, *, withCloud: bool = False, withRetention: bool = False
    ) -> None:
        super().__init__(database, mysql=True, withCloud=withCloud, withRetention=withRetention)
