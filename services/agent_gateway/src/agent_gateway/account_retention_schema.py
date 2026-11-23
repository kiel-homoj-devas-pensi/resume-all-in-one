"""Explicit maintenance migrations; unknown historical retirement times stay unknown."""

from __future__ import annotations

import hashlib
import sqlite3
from contextlib import closing

from .account_storage import AccountSqlConnection
from .database import GatewayDatabase, UnsupportedDatabaseSchemaError
from .mysql_schema import _require
from .mysql_storage import MySqlAccountDatabase
from .mysql_usage_schema import _validateTables
from .privilege_schema import (
    _validateMySqlBase,
    _validateMySqlGrantTable,
    _validateMySqlVersions,
    validateSqlitePrivilegeSchema,
)
from .recovery_schema import (
    MYSQL_RECOVERY_DIGEST,
    _validateRecoveryTable,
    validateMySqlRecoverySchema,
)

SQLITE_VERSION = 9
MYSQL_VERSION = 8
SQLITE_STATEMENT = """CREATE TABLE account_retirements (
    account_id TEXT NOT NULL PRIMARY KEY REFERENCES accounts(account_id),
    deactivated_at_utc TEXT NOT NULL,
    hold_until_utc TEXT,
    hold_kind TEXT CHECK (hold_kind IN ('legalObligation', 'actualDispute')),
    hold_evidence_sha256 TEXT,
    CHECK ((hold_until_utc IS NULL AND hold_kind IS NULL AND hold_evidence_sha256 IS NULL)
        OR (hold_until_utc IS NOT NULL AND hold_kind IS NOT NULL
        AND hold_evidence_sha256 IS NOT NULL AND length(hold_evidence_sha256)=64))
)"""
MYSQL_STATEMENT = """CREATE TABLE IF NOT EXISTS account_retirements (
    account_id VARBINARY(64) NOT NULL PRIMARY KEY,
    deactivated_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    hold_until_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NULL,
    hold_kind VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NULL,
    hold_evidence_sha256 VARBINARY(64) NULL,
    FOREIGN KEY (account_id) REFERENCES accounts(account_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT retirement_hold_kind CHECK (hold_kind IN ('legalObligation', 'actualDispute')),
    CONSTRAINT retirement_hold_complete CHECK (
        (hold_until_utc IS NULL AND hold_kind IS NULL AND hold_evidence_sha256 IS NULL)
        OR (hold_until_utc IS NOT NULL AND hold_kind IS NOT NULL
        AND hold_evidence_sha256 IS NOT NULL AND LENGTH(hold_evidence_sha256)=64))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"""
MYSQL_DIGEST = hashlib.sha256(MYSQL_STATEMENT.encode()).hexdigest()
MYSQL_COLUMNS = {
    "account_retirements": (
        ("account_id", "varbinary(64)", None, "NO"),
        ("deactivated_at_utc", "char(27)", "ascii_bin", "NO"),
        ("hold_until_utc", "char(27)", "ascii_bin", "YES"),
        ("hold_kind", "varchar(32)", "ascii_bin", "YES"),
        ("hold_evidence_sha256", "varbinary(64)", None, "YES"),
    )
}


def applySqliteRetentionSchema(connection: sqlite3.Connection) -> None:
    connection.execute(SQLITE_STATEMENT)
    connection.execute("PRAGMA user_version = 9")
    connection.execute(
        "INSERT INTO schema_migrations(version, applied_at_utc) "
        "VALUES (9, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
    )


def validateSqliteRetentionSchema(database: GatewayDatabase) -> None:
    validateSqlitePrivilegeSchema(database, withRecovery=True, withRetention=True)


def migrateSqliteRetentionSchema(database: GatewayDatabase) -> None:
    with closing(
        sqlite3.connect(database.databasePath.resolve().as_uri() + "?mode=ro", uri=True)
    ) as connection:
        version = connection.execute("PRAGMA user_version").fetchone()[0]
    if version == SQLITE_VERSION:
        validateSqliteRetentionSchema(database)
        return
    validateSqlitePrivilegeSchema(database, withRecovery=True)
    with database.immediateTransaction() as connection:
        if connection.execute("PRAGMA user_version").fetchone()[0] != 8:
            raise UnsupportedDatabaseSchemaError("retention_schema_changed")
        applySqliteRetentionSchema(connection)
    # Existing inactive accounts intentionally get no fabricated timestamp.
    validateSqliteRetentionSchema(database)


def _validateRetirementTable(connection: AccountSqlConnection) -> None:
    _validateTables(
        connection,
        MYSQL_COLUMNS,
        {
            "account_retirements": {
                "retirement_hold_kind": "hold_kind IN ('legalObligation', 'actualDispute')",
                "retirement_hold_complete": "(hold_until_utc IS NULL AND hold_kind IS NULL "
                "AND hold_evidence_sha256 IS NULL) "
                "OR (hold_until_utc IS NOT NULL AND hold_kind IS NOT NULL "
                "AND hold_evidence_sha256 IS NOT NULL AND LENGTH(hold_evidence_sha256)=64)",
            }
        },
    )
    for query in (
        "SELECT COUNT(*) AS count FROM information_schema.key_column_usage k JOIN "
        "information_schema.referential_constraints r ON r.constraint_schema=k.constraint_schema "
        "AND r.constraint_name=k.constraint_name WHERE k.constraint_schema=DATABASE() "
        "AND k.table_name='account_retirements' AND k.column_name='account_id' "
        "AND k.referenced_table_name='accounts' AND k.referenced_column_name='account_id' "
        "AND r.delete_rule='RESTRICT' AND r.update_rule='RESTRICT'",
        "SELECT COUNT(*) AS count FROM information_schema.statistics "
        "WHERE table_schema=DATABASE() AND table_name='account_retirements' "
        "AND index_name='PRIMARY' AND column_name='account_id' AND non_unique=0 "
        "AND seq_in_index=1 AND sub_part IS NULL",
    ):
        row = connection.fetchOne(query)
        _require(row is not None and row["count"] == 1)


def validateMySqlRetentionSchema(connection: AccountSqlConnection) -> None:
    _validateMySqlVersions(
        connection,
        current=True,
        recoveryDigest=MYSQL_RECOVERY_DIGEST,
        retentionDigest=MYSQL_DIGEST,
    )
    _validateMySqlBase(connection, tableCount=19)
    _validateMySqlGrantTable(connection)
    _validateRecoveryTable(connection)
    _validateRetirementTable(connection)


def migrateMySqlRetentionSchema(database: MySqlAccountDatabase) -> None:
    """Dedicated quiescent maintenance identity; interrupted DDL must be inspected."""
    with database.transaction() as connection:
        row = connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
        _require(row is not None and row["version"] in {7, MYSQL_VERSION})
        if row is not None and row["version"] == MYSQL_VERSION:
            validateMySqlRetentionSchema(connection)
            return
        # MySQL DDL auto-commits: accept only an exactly matching, empty, unmarked
        # retirement table from an interrupted attempt, never alter an unknown one.
        exists = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables "
            "WHERE table_schema=DATABASE() AND table_name='account_retirements'"
        )
        if exists is not None and exists["count"] == 1:
            _validateMySqlVersions(connection, current=True, recoveryDigest=MYSQL_RECOVERY_DIGEST)
            _validateMySqlBase(connection, tableCount=19)
            _validateMySqlGrantTable(connection)
            _validateRecoveryTable(connection)
            _validateRetirementTable(connection)
            count = connection.fetchOne("SELECT COUNT(*) AS count FROM account_retirements")
            _require(count is not None and count["count"] == 0)
        else:
            validateMySqlRecoverySchema(connection)
        connection.execute(MYSQL_STATEMENT)
        _validateRetirementTable(connection)
        connection.execute(
            "INSERT INTO gateway_schema_migrations(version, definition_sha256) VALUES (%s,%s)",
            (MYSQL_VERSION, MYSQL_DIGEST),
        )
        validateMySqlRetentionSchema(connection)
