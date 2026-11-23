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
    validateMySqlPrivilegeSchema,
    validateSqlitePrivilegeSchema,
)

SQLITE_RECOVERY_STATEMENT = """CREATE TABLE account_recovery_codes (
    account_id TEXT NOT NULL PRIMARY KEY REFERENCES accounts(account_id),
    code_hash TEXT NOT NULL CHECK (length(code_hash) IN (0, 64)),
    issued_at_utc TEXT NOT NULL
)"""
MYSQL_RECOVERY_STATEMENT = """CREATE TABLE IF NOT EXISTS account_recovery_codes (
    account_id VARBINARY(64) NOT NULL PRIMARY KEY,
    code_hash VARBINARY(64) NOT NULL,
    issued_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    FOREIGN KEY (account_id) REFERENCES accounts(account_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT recovery_hash_length CHECK (LENGTH(code_hash) IN (0, 64))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"""
MYSQL_RECOVERY_DIGEST = hashlib.sha256(MYSQL_RECOVERY_STATEMENT.encode()).hexdigest()
MYSQL_COLUMNS = {
    "account_recovery_codes": (
        ("account_id", "varbinary(64)", None, "NO"),
        ("code_hash", "varbinary(64)", None, "NO"),
        ("issued_at_utc", "char(27)", "ascii_bin", "NO"),
    )
}


def applySqliteRecoverySchema(connection: sqlite3.Connection) -> None:
    connection.execute(SQLITE_RECOVERY_STATEMENT)
    connection.execute("PRAGMA user_version = 8")
    connection.execute(
        "INSERT INTO schema_migrations(version, applied_at_utc) "
        "VALUES (8, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
    )


def migrateSqliteRecoverySchema(database: GatewayDatabase) -> None:
    with closing(
        sqlite3.connect(database.databasePath.resolve().as_uri() + "?mode=ro", uri=True)
    ) as c:
        version = c.execute("PRAGMA user_version").fetchone()[0]
    if version == 8:
        validateSqlitePrivilegeSchema(database, withRecovery=True)
        return
    validateSqlitePrivilegeSchema(database)
    with database.immediateTransaction() as c:
        if c.execute("PRAGMA user_version").fetchone()[0] != 7:
            raise UnsupportedDatabaseSchemaError("recovery_schema_changed")
        applySqliteRecoverySchema(c)
    validateSqlitePrivilegeSchema(database, withRecovery=True)


def _validateRecoveryTable(connection: AccountSqlConnection) -> None:
    _validateTables(
        connection,
        MYSQL_COLUMNS,
        {"account_recovery_codes": {"recovery_hash_length": "LENGTH(code_hash) IN (0, 64)"}},
    )
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.key_column_usage k JOIN "
        "information_schema.referential_constraints r ON r.constraint_schema=k.constraint_schema "
        "AND r.constraint_name=k.constraint_name WHERE k.constraint_schema=DATABASE() "
        "AND k.table_name='account_recovery_codes' AND k.column_name='account_id' "
        "AND k.referenced_table_name='accounts' AND k.referenced_column_name='account_id' "
        "AND r.delete_rule='RESTRICT' AND r.update_rule='RESTRICT'"
    )
    _require(row is not None and row["count"] == 1)
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.statistics "
        "WHERE table_schema=DATABASE() AND table_name='account_recovery_codes' "
        "AND index_name='PRIMARY' AND column_name='account_id' AND non_unique=0 "
        "AND seq_in_index=1 AND sub_part IS NULL"
    )
    _require(row is not None and row["count"] == 1)


def validateMySqlRecoverySchema(connection: AccountSqlConnection) -> None:
    validateMySqlPrivilegeSchema(connection, recoveryDigest=MYSQL_RECOVERY_DIGEST)
    _validateRecoveryTable(connection)


def migrateMySqlRecoverySchema(database: MySqlAccountDatabase) -> None:
    """Explicit maintenance migration; the Web process never creates or alters tables."""
    with database.transaction() as c:
        row = c.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
        _require(row is not None and row["version"] in {6, 7})
        if row is not None and row["version"] == 7:
            validateMySqlRecoverySchema(c)
            return
        _validateMySqlVersions(c, current=True)
        row = c.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables "
            "WHERE table_schema=DATABASE() AND table_name='account_recovery_codes'"
        )
        exists = row is not None and row["count"] == 1
        _validateMySqlBase(c, tableCount=18 if exists else 17)
        _validateMySqlGrantTable(c)
        if exists:
            _validateRecoveryTable(c)
            row = c.fetchOne("SELECT COUNT(*) AS count FROM account_recovery_codes")
            _require(row is not None and row["count"] == 0)
        c.execute(MYSQL_RECOVERY_STATEMENT)
        _validateRecoveryTable(c)
        c.execute(
            "INSERT INTO gateway_schema_migrations(version, definition_sha256) VALUES (%s,%s)",
            (7, MYSQL_RECOVERY_DIGEST),
        )
        validateMySqlRecoverySchema(c)
