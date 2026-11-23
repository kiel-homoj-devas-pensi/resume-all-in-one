"""Explicit, quiescent summary migration; deployed migrations remain immutable."""

from __future__ import annotations

import hashlib
import sqlite3
from contextlib import closing

from .account_retention_schema import MYSQL_DIGEST as RETENTION_DIGEST
from .account_retention_schema import _validateRetirementTable, validateSqliteRetentionSchema
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
from .recovery_schema import MYSQL_RECOVERY_DIGEST, _validateRecoveryTable

SQLITE_STATEMENT = """CREATE TABLE sms_send_summary (
    policy_id TEXT NOT NULL PRIMARY KEY REFERENCES sms_send_budget(policy_id),
    attempts INTEGER NOT NULL CHECK (attempts>=0),
    reserved_cents INTEGER NOT NULL CHECK (reserved_cents>=0)
)"""
MYSQL_STATEMENT = """CREATE TABLE IF NOT EXISTS sms_send_summary (
    policy_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    attempts INT NOT NULL,
    reserved_cents INT NOT NULL,
    FOREIGN KEY (policy_id) REFERENCES sms_send_budget(policy_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT sms_summary_attempts CHECK (attempts>=0),
    CONSTRAINT sms_summary_cents CHECK (reserved_cents>=0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin"""
MYSQL_DIGEST = hashlib.sha256(MYSQL_STATEMENT.encode()).hexdigest()

# Keep the v10/v9 definitions above immutable. Unresolved figures are a subset
# of the archived totals, not a second charge or a refundable balance.
SQLITE_UNRESOLVED_STATEMENTS = (
    "ALTER TABLE sms_send_summary ADD COLUMN unresolved_attempts INTEGER NOT NULL DEFAULT 0 "
    "CHECK (unresolved_attempts>=0 AND unresolved_attempts<=attempts)",
    "ALTER TABLE sms_send_summary ADD COLUMN unresolved_reserved_cents INTEGER NOT NULL DEFAULT 0 "
    "CHECK (unresolved_reserved_cents>=0 AND unresolved_reserved_cents<=reserved_cents)",
)
MYSQL_UNRESOLVED_STATEMENT = """ALTER TABLE sms_send_summary
    ADD COLUMN unresolved_attempts INT NOT NULL DEFAULT 0,
    ADD COLUMN unresolved_reserved_cents INT NOT NULL DEFAULT 0,
    ADD CONSTRAINT sms_summary_unresolved_attempts
        CHECK (unresolved_attempts>=0 AND unresolved_attempts<=attempts),
    ADD CONSTRAINT sms_summary_unresolved_cents
        CHECK (unresolved_reserved_cents>=0 AND unresolved_reserved_cents<=reserved_cents)"""
MYSQL_UNRESOLVED_DIGEST = hashlib.sha256(MYSQL_UNRESOLVED_STATEMENT.encode()).hexdigest()


def applySqliteSmsSummarySchema(connection: sqlite3.Connection) -> None:
    connection.execute(SQLITE_STATEMENT)
    connection.execute("PRAGMA user_version=10")
    connection.execute(
        "INSERT INTO schema_migrations(version,applied_at_utc) "
        "VALUES(10,strftime('%Y-%m-%dT%H:%M:%fZ','now'))"
    )


def applySqliteSmsUnresolvedSchema(connection: sqlite3.Connection) -> None:
    for statement in SQLITE_UNRESOLVED_STATEMENTS:
        connection.execute(statement)
    connection.execute("PRAGMA user_version=11")
    connection.execute(
        "INSERT INTO schema_migrations(version,applied_at_utc) "
        "VALUES(11,strftime('%Y-%m-%dT%H:%M:%fZ','now'))"
    )


def validateSqliteSmsSummarySchema(
    database: GatewayDatabase, *, withUnresolved: bool = True
) -> None:
    validateSqlitePrivilegeSchema(
        database,
        withRecovery=True,
        withRetention=True,
        withSmsSummary=True,
        withSmsUnresolved=withUnresolved,
    )


def migrateSqliteSmsSummarySchema(database: GatewayDatabase) -> None:
    with closing(
        sqlite3.connect(database.databasePath.resolve().as_uri() + "?mode=ro", uri=True)
    ) as c:
        version = c.execute("PRAGMA user_version").fetchone()[0]
    if version == 11:
        validateSqliteSmsSummarySchema(database)
        return
    if version == 10:
        validateSqliteSmsSummarySchema(database, withUnresolved=False)
    else:
        validateSqliteRetentionSchema(database)
    with database.immediateTransaction() as c:
        if c.execute("PRAGMA user_version").fetchone()[0] != version:
            raise UnsupportedDatabaseSchemaError("sms_summary_schema_changed")
        if version == 9:
            applySqliteSmsSummarySchema(c)
            c.execute("INSERT INTO sms_send_summary SELECT policy_id,0,0 FROM sms_send_budget")
        applySqliteSmsUnresolvedSchema(c)
    validateSqliteSmsSummarySchema(database)


def _validateSummary(connection: AccountSqlConnection, *, withUnresolved: bool = False) -> None:
    _validateTables(
        connection,
        {
            "sms_send_summary": (
                ("policy_id", "varchar(16)", "ascii_bin", "NO"),
                ("attempts", "int", None, "NO"),
                ("reserved_cents", "int", None, "NO"),
            )
            + (
                (
                    ("unresolved_attempts", "int", None, "NO"),
                    ("unresolved_reserved_cents", "int", None, "NO"),
                )
                if withUnresolved
                else ()
            )
        },
        {
            "sms_send_summary": {
                "sms_summary_attempts": "attempts>=0",
                "sms_summary_cents": "reserved_cents>=0",
                **(
                    {
                        "sms_summary_unresolved_attempts": (
                            "unresolved_attempts>=0 AND unresolved_attempts<=attempts"
                        ),
                        "sms_summary_unresolved_cents": (
                            "unresolved_reserved_cents>=0 "
                            "AND unresolved_reserved_cents<=reserved_cents"
                        ),
                    }
                    if withUnresolved
                    else {}
                ),
            }
        },
    )
    for query in (
        "SELECT COUNT(DISTINCT index_name) AS count FROM information_schema.statistics "
        "WHERE table_schema=DATABASE() AND table_name='sms_send_summary'",
        "SELECT COUNT(*) AS count FROM information_schema.statistics WHERE table_schema=DATABASE() "
        "AND table_name='sms_send_summary' AND index_name='PRIMARY' AND column_name='policy_id' "
        "AND non_unique=0 AND seq_in_index=1 AND sub_part IS NULL",
        "SELECT COUNT(*) AS count FROM information_schema.key_column_usage k JOIN "
        "information_schema.referential_constraints r ON r.constraint_schema=k.constraint_schema "
        "AND r.constraint_name=k.constraint_name WHERE k.constraint_schema=DATABASE() "
        "AND k.table_name='sms_send_summary' AND k.column_name='policy_id' "
        "AND k.referenced_table_name='sms_send_budget' AND k.referenced_column_name='policy_id' "
        "AND r.delete_rule='RESTRICT' AND r.update_rule='RESTRICT'",
    ):
        row = connection.fetchOne(query)
        _require(row is not None and row["count"] == 1)


def _validateBase(
    connection: AccountSqlConnection,
    *,
    marked: bool,
    withUnresolved: bool = False,
    unresolvedMarked: bool = False,
) -> None:
    _validateMySqlVersions(
        connection,
        current=True,
        recoveryDigest=MYSQL_RECOVERY_DIGEST,
        retentionDigest=RETENTION_DIGEST,
        smsSummaryDigest=MYSQL_DIGEST if marked else None,
        smsUnresolvedDigest=MYSQL_UNRESOLVED_DIGEST if unresolvedMarked else None,
    )
    _validateMySqlBase(connection, tableCount=20)
    _validateMySqlGrantTable(connection)
    _validateRecoveryTable(connection)
    _validateRetirementTable(connection)
    _validateSummary(connection, withUnresolved=withUnresolved)


def validateMySqlSmsSummarySchema(
    connection: AccountSqlConnection, *, withUnresolved: bool = True
) -> None:
    _validateBase(
        connection, marked=True, withUnresolved=withUnresolved, unresolvedMarked=withUnresolved
    )


def migrateMySqlSmsSummarySchema(database: MySqlAccountDatabase) -> None:
    from .account_retention_schema import validateMySqlRetentionSchema

    with database.transaction() as c:
        row = c.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
        _require(row is not None and row["version"] in {8, 9, 10})
        if row is not None and row["version"] == 10:
            validateMySqlSmsSummarySchema(c)
            return
        if row is not None and row["version"] == 9:
            _migrateMySqlUnresolved(c)
            return
        exists = c.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables "
            "WHERE table_schema=DATABASE() AND table_name='sms_send_summary'"
        )
        if exists is not None and exists["count"] == 1:
            _validateBase(c, marked=False)
            count = c.fetchOne("SELECT COUNT(*) AS count FROM sms_send_summary")
            _require(count is not None and count["count"] == 0)
        else:
            validateMySqlRetentionSchema(c)
        c.execute(MYSQL_STATEMENT)
        _validateSummary(c)
        c.execute("INSERT INTO sms_send_summary SELECT policy_id,0,0 FROM sms_send_budget")
        c.execute(
            "INSERT INTO gateway_schema_migrations(version,definition_sha256) VALUES(%s,%s)",
            (9, MYSQL_DIGEST),
        )
        validateMySqlSmsSummarySchema(c, withUnresolved=False)
        _migrateMySqlUnresolved(c)


def _migrateMySqlUnresolved(connection: AccountSqlConnection) -> None:
    # MySQL DDL commits independently. A rerun may adopt only the exact complete
    # ALTER with zero subset counters; partial/mismatched structures fail closed.
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.columns "
        "WHERE table_schema=DATABASE() AND table_name='sms_send_summary' "
        "AND column_name='unresolved_attempts'"
    )
    if row is not None and row["count"] == 1:
        _validateBase(connection, marked=True, withUnresolved=True)
        nonzero = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM sms_send_summary "
            "WHERE unresolved_attempts<>0 OR unresolved_reserved_cents<>0"
        )
        _require(nonzero is not None and nonzero["count"] == 0)
    else:
        validateMySqlSmsSummarySchema(connection, withUnresolved=False)
        connection.execute(MYSQL_UNRESOLVED_STATEMENT)
        _validateBase(connection, marked=True, withUnresolved=True)
    connection.execute(
        "INSERT INTO gateway_schema_migrations(version,definition_sha256) VALUES(%s,%s)",
        (10, MYSQL_UNRESOLVED_DIGEST),
    )
    validateMySqlSmsSummarySchema(connection)
