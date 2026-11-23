from __future__ import annotations

import re
import sqlite3
from collections.abc import Iterator
from contextlib import closing, contextmanager
from pathlib import Path


class UnsupportedDatabaseSchemaError(RuntimeError):
    pass


class GatewayDatabase:
    schemaVersion = 5

    def __init__(self, databasePath: Path) -> None:
        self.databasePath = databasePath

    def initialize(self) -> None:
        self.databasePath.parent.mkdir(parents=True, exist_ok=True)
        with self.immediateTransaction() as databaseConnection:
            self._applyMigrations(databaseConnection)

    def _applyMigrations(self, databaseConnection: sqlite3.Connection) -> None:
        currentVersion = int(databaseConnection.execute("PRAGMA user_version").fetchone()[0])
        if currentVersion == 0:
            self._createSchemaVersionOne(databaseConnection)
            databaseConnection.execute("PRAGMA user_version = 1")
            databaseConnection.execute(
                "INSERT INTO schema_migrations(version, applied_at_utc) "
                "VALUES (1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
            )
            currentVersion = 1
        if currentVersion == 1:
            self._migrateVersionOneToTwo(databaseConnection)
            databaseConnection.execute("PRAGMA user_version = 2")
            databaseConnection.execute(
                "INSERT INTO schema_migrations(version, applied_at_utc) "
                "VALUES (2, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
            )
            currentVersion = 2
        if currentVersion == 2:
            databaseConnection.execute("""
                CREATE TABLE usage_reconciliations (
                    operation_id TEXT PRIMARY KEY REFERENCES usage_operations(operation_id),
                    operator_id TEXT NOT NULL,
                    evidence_sha256 TEXT NOT NULL,
                    evidence_kind TEXT NOT NULL
                        CHECK (evidence_kind IN ('executed', 'notExecuted')),
                    finalized_at_utc TEXT NOT NULL
                )
            """)
            databaseConnection.execute("PRAGMA user_version = 3")
            databaseConnection.execute(
                "INSERT INTO schema_migrations(version, applied_at_utc) "
                "VALUES (3, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
            )
            currentVersion = 3
        if currentVersion == 3:
            databaseConnection.execute("""
                CREATE TABLE phone_challenges (
                    challenge_id TEXT PRIMARY KEY,
                    phone_hash TEXT NOT NULL,
                    purpose TEXT NOT NULL CHECK (purpose IN ('register', 'resetPassword')),
                    code_hash TEXT NOT NULL,
                    expires_at_utc TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    consumed_at_utc TEXT
                )
            """)
            databaseConnection.execute("""
                CREATE TABLE identity_rate_limits (
                    bucket_hash TEXT PRIMARY KEY,
                    window_start_utc TEXT NOT NULL,
                    attempts INTEGER NOT NULL
                )
            """)
            databaseConnection.execute("PRAGMA user_version = 4")
            databaseConnection.execute(
                "INSERT INTO schema_migrations(version, applied_at_utc) "
                "VALUES (4, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
            )
            currentVersion = 4
        if currentVersion == 4:
            from .sqlite_sms_schema import SMS_SCHEMA_STATEMENTS

            for statement in SMS_SCHEMA_STATEMENTS:
                databaseConnection.execute(statement)
            databaseConnection.execute("PRAGMA user_version = 5")
            databaseConnection.execute(
                "INSERT INTO schema_migrations(version, applied_at_utc) "
                "VALUES (5, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
            )
            currentVersion = 5
        if currentVersion != self.schemaVersion:
            raise UnsupportedDatabaseSchemaError(f"不支持 Gateway 数据库 schema v{currentVersion}")

    def checkSchema(self, *, withCloud: bool = False) -> None:
        """只读核对完整结构；实际库不建表、不升级，也不创建缺失文件。"""
        path = self.databasePath.resolve()
        targetVersion = 6 if withCloud else self.schemaVersion
        with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as actual:
            actual.execute("BEGIN")
            if int(actual.execute("PRAGMA user_version").fetchone()[0]) != targetVersion:
                raise UnsupportedDatabaseSchemaError("gateway_sqlite_schema_unavailable")
            with closing(sqlite3.connect(":memory:")) as expected:
                # 在内存中使用同一个迁移实现取得当前规范，避免另写一份 DDL。
                self._applyMigrations(expected)
                if withCloud:
                    from .sqlite_cloud_schema import applyCloudSchema

                    applyCloudSchema(expected)
                if self._schemaStatements(actual) != self._schemaStatements(expected):
                    raise UnsupportedDatabaseSchemaError("gateway_sqlite_schema_mismatch")
            versions = [
                row[0]
                for row in actual.execute("SELECT version FROM schema_migrations ORDER BY version")
            ]
            if versions != list(range(1, targetVersion + 1)):
                raise UnsupportedDatabaseSchemaError("gateway_sqlite_migration_records_mismatch")
            if actual.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                raise UnsupportedDatabaseSchemaError("gateway_sqlite_integrity_failure")
            if actual.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise UnsupportedDatabaseSchemaError("gateway_sqlite_foreign_key_failure")

    @staticmethod
    def _schemaStatements(connection: sqlite3.Connection) -> dict[tuple[str, str], str]:
        statements = {}
        for kind, name, sql in connection.execute(
            "SELECT type, name, sql FROM sqlite_schema "
            "WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'"
        ):
            # 只去掉字符串外的空白；用途字面值的大小写/空格必须保留。
            fragments = re.split(r"('(?:''|[^'])*')", sql)
            normalized = "".join(
                fragment if index % 2 else re.sub(r"\s+", "", fragment)
                for index, fragment in enumerate(fragments)
            )
            statements[(kind, name)] = normalized
        return statements

    @contextmanager
    def readConnection(self) -> Iterator[sqlite3.Connection]:
        databaseConnection = self._openConnection()
        try:
            yield databaseConnection
        finally:
            databaseConnection.close()

    @contextmanager
    def immediateTransaction(self) -> Iterator[sqlite3.Connection]:
        databaseConnection = self._openConnection()
        try:
            # quota 检查和占位必须先取得写锁，否则两个请求可能同时拿到第 10 个槽位。
            databaseConnection.execute("BEGIN IMMEDIATE")
            yield databaseConnection
            databaseConnection.commit()
        except Exception:
            databaseConnection.rollback()
            raise
        finally:
            databaseConnection.close()

    def _openConnection(self) -> sqlite3.Connection:
        databaseConnection = sqlite3.connect(
            self.databasePath,
            timeout=5.0,
            isolation_level=None,
        )
        databaseConnection.row_factory = sqlite3.Row
        databaseConnection.execute("PRAGMA foreign_keys = ON")
        databaseConnection.execute("PRAGMA busy_timeout = 5000")
        databaseConnection.execute("PRAGMA journal_mode = WAL")
        return databaseConnection

    @staticmethod
    def _createSchemaVersionOne(databaseConnection: sqlite3.Connection) -> None:
        schemaStatements = (
            """
            CREATE TABLE schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at_utc TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE accounts (
                account_id TEXT PRIMARY KEY,
                phone_e164 TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                phone_verified_at_utc TEXT NOT NULL,
                is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
                created_at_utc TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE account_sessions (
                session_id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
                token_hash TEXT NOT NULL UNIQUE,
                expires_at_utc TEXT NOT NULL,
                revoked_at_utc TEXT,
                created_at_utc TEXT NOT NULL
            )
            """,
            """
            CREATE INDEX account_sessions_account_id
                ON account_sessions(account_id)
            """,
            """
            CREATE TABLE subscription_snapshots (
                account_id TEXT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
                plan TEXT NOT NULL CHECK (plan IN ('free', 'pro')),
                starts_at_utc TEXT NOT NULL,
                ends_at_utc TEXT NOT NULL,
                source TEXT NOT NULL CHECK (source = 'fake'),
                updated_at_utc TEXT NOT NULL,
                CHECK (starts_at_utc < ends_at_utc)
            )
            """,
            """
            CREATE TABLE usage_operations (
                operation_id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
                capability TEXT NOT NULL CHECK (
                    capability IN (
                        'basicResumeCompose',
                        'targetedResumeOptimization',
                        'resumeOptimizationConversation'
                    )
                ),
                idempotency_key_hash TEXT NOT NULL,
                request_fingerprint_hash TEXT NOT NULL,
                status TEXT NOT NULL CHECK (
                    status IN (
                        'reserved',
                        'committed',
                        'released',
                        'pendingReconciliation'
                    )
                ),
                quota_window_start_utc TEXT NOT NULL,
                quota_window_end_utc TEXT NOT NULL,
                plan_at_reservation TEXT NOT NULL CHECK (
                    plan_at_reservation IN ('free', 'pro')
                ),
                created_at_utc TEXT NOT NULL,
                updated_at_utc TEXT NOT NULL,
                failure_code TEXT,
                UNIQUE (account_id, capability, idempotency_key_hash)
            )
            """,
            """
            CREATE INDEX usage_operations_monthly_quota
                ON usage_operations(
                    account_id,
                    capability,
                    quota_window_start_utc,
                    status
                )
            """,
        )
        for schemaStatement in schemaStatements:
            databaseConnection.execute(schemaStatement)

    @staticmethod
    def _migrateVersionOneToTwo(databaseConnection: sqlite3.Connection) -> None:
        # 只增加结算所需的整数元数据，避免为了幂等重放把 Provider 正文带入服务端存储。
        databaseConnection.execute("ALTER TABLE usage_operations ADD COLUMN prompt_version TEXT")
        databaseConnection.execute(
            "ALTER TABLE usage_operations ADD COLUMN input_tokens INTEGER "
            "CHECK (input_tokens IS NULL OR input_tokens >= 0)"
        )
        databaseConnection.execute(
            "ALTER TABLE usage_operations ADD COLUMN output_tokens INTEGER "
            "CHECK (output_tokens IS NULL OR output_tokens >= 0)"
        )
