from __future__ import annotations

import hashlib
import sqlite3
from contextlib import closing

from .account_storage import AccountSqlConnection
from .database import GatewayDatabase, UnsupportedDatabaseSchemaError
from .mysql_cloud_schema import (
    CLOUD_CHECKS,
    CLOUD_COLUMNS,
    CLOUD_SCHEMA_DIGEST,
    _validateCloudKeys,
    migrateSyntheticCloudSchema,
)
from .mysql_lifecycle_schema import LIFECYCLE_SCHEMA_DIGEST
from .mysql_schema import SCHEMA_DIGEST as ACCOUNT_DIGEST
from .mysql_schema import _require
from .mysql_sms_schema import SMS_SCHEMA_DIGEST, _validateSmsStructure
from .mysql_storage import MySqlAccountDatabase
from .mysql_usage_schema import USAGE_SCHEMA_DIGEST, _validateTables
from .sqlite_cloud_schema import applyCloudSchema, migrateSqliteCloudSchema

SQLITE_PRIVILEGE_VERSION = 7
MYSQL_PRIVILEGE_VERSION = 6
SQLITE_STATEMENTS = (
    """CREATE TABLE account_privilege_grants (
        grant_id TEXT NOT NULL PRIMARY KEY,
        account_id TEXT NOT NULL REFERENCES accounts(account_id),
        privilege TEXT NOT NULL CHECK (privilege IN ('admin', 'permanentMember')),
        operator_id TEXT NOT NULL,
        evidence_sha256 TEXT NOT NULL CHECK (length(evidence_sha256) = 64),
        granted_at_utc TEXT NOT NULL,
        revoked_at_utc TEXT,
        revoked_by TEXT,
        revocation_evidence_sha256 TEXT,
        UNIQUE (account_id, privilege),
        CHECK ((revoked_at_utc IS NULL AND revoked_by IS NULL AND
            revocation_evidence_sha256 IS NULL) OR
            (revoked_at_utc IS NOT NULL AND revoked_by IS NOT NULL AND
            revocation_evidence_sha256 IS NOT NULL AND
            length(revocation_evidence_sha256) = 64))
    )""",
)
MYSQL_STATEMENTS = (
    """CREATE TABLE IF NOT EXISTS account_privilege_grants (
        grant_id VARBINARY(64) NOT NULL PRIMARY KEY,
        account_id VARBINARY(64) NOT NULL,
        privilege VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        operator_id VARBINARY(64) NOT NULL,
        evidence_sha256 VARBINARY(64) NOT NULL,
        granted_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        revoked_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NULL,
        revoked_by VARBINARY(64) NULL,
        revocation_evidence_sha256 VARBINARY(64) NULL,
        UNIQUE KEY account_privilege_once (account_id, privilege),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id)
            ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT privilege_kind CHECK (privilege IN ('admin', 'permanentMember')),
        CONSTRAINT privilege_evidence CHECK (LENGTH(evidence_sha256) = 64),
        CONSTRAINT privilege_revocation CHECK (
            (revoked_at_utc IS NULL AND revoked_by IS NULL AND
                revocation_evidence_sha256 IS NULL) OR
            (revoked_at_utc IS NOT NULL AND revoked_by IS NOT NULL AND
                revocation_evidence_sha256 IS NOT NULL AND
                LENGTH(revocation_evidence_sha256) = 64))
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
)
MYSQL_PRIVILEGE_DIGEST = hashlib.sha256("\n".join(MYSQL_STATEMENTS).encode()).hexdigest()
MYSQL_COLUMNS = {
    "account_privilege_grants": (
        ("grant_id", "varbinary(64)", None, "NO"),
        ("account_id", "varbinary(64)", None, "NO"),
        ("privilege", "varchar(16)", "ascii_bin", "NO"),
        ("operator_id", "varbinary(64)", None, "NO"),
        ("evidence_sha256", "varbinary(64)", None, "NO"),
        ("granted_at_utc", "char(27)", "ascii_bin", "NO"),
        ("revoked_at_utc", "char(27)", "ascii_bin", "YES"),
        ("revoked_by", "varbinary(64)", None, "YES"),
        ("revocation_evidence_sha256", "varbinary(64)", None, "YES"),
    )
}
MYSQL_CHECKS = {
    "account_privilege_grants": {
        "privilege_kind": "privilege IN ('admin', 'permanentMember')",
        "privilege_evidence": "LENGTH(evidence_sha256) = 64",
        "privilege_revocation": "(revoked_at_utc IS NULL AND revoked_by IS NULL AND "
        "revocation_evidence_sha256 IS NULL) OR (revoked_at_utc IS NOT NULL AND "
        "revoked_by IS NOT NULL AND revocation_evidence_sha256 IS NOT NULL AND "
        "LENGTH(revocation_evidence_sha256) = 64)",
    }
}


def applySqlitePrivilegeSchema(connection: sqlite3.Connection) -> None:
    for statement in SQLITE_STATEMENTS:
        connection.execute(statement)
    connection.execute("PRAGMA user_version = 7")
    connection.execute(
        "INSERT INTO schema_migrations(version, applied_at_utc) "
        "VALUES (7, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
    )


def validateSqlitePrivilegeSchema(
    database: GatewayDatabase,
    *,
    withRecovery: bool = False,
    withRetention: bool = False,
    withSmsSummary: bool = False,
    withSmsUnresolved: bool = False,
) -> None:
    if withSmsUnresolved and not withSmsSummary:
        raise ValueError("sms_unresolved_requires_summary_schema")
    if withSmsSummary and not withRetention:
        raise ValueError("sms_summary_requires_retention_schema")
    if withRetention and not withRecovery:
        raise ValueError("retention_requires_recovery_schema")
    with closing(
        sqlite3.connect(database.databasePath.resolve().as_uri() + "?mode=ro", uri=True)
    ) as c:
        c.execute("BEGIN")
        version = (
            11
            if withSmsUnresolved
            else 10
            if withSmsSummary
            else 9
            if withRetention
            else 8
            if withRecovery
            else SQLITE_PRIVILEGE_VERSION
        )
        if c.execute("PRAGMA user_version").fetchone()[0] != version:
            raise UnsupportedDatabaseSchemaError("privilege_schema_unavailable")
        with closing(sqlite3.connect(":memory:")) as expected:
            database._applyMigrations(expected)
            applyCloudSchema(expected)
            applySqlitePrivilegeSchema(expected)
            if withRecovery:
                from .recovery_schema import applySqliteRecoverySchema

                applySqliteRecoverySchema(expected)
            if withRetention:
                from .account_retention_schema import applySqliteRetentionSchema

                applySqliteRetentionSchema(expected)
            if withSmsSummary:
                from .sms_attempt_retention_schema import applySqliteSmsSummarySchema

                applySqliteSmsSummarySchema(expected)
            if withSmsUnresolved:
                from .sms_attempt_retention_schema import applySqliteSmsUnresolvedSchema

                applySqliteSmsUnresolvedSchema(expected)
            if database._schemaStatements(c) != database._schemaStatements(expected):
                raise UnsupportedDatabaseSchemaError("privilege_schema_mismatch")
        versions = [
            row[0] for row in c.execute("SELECT version FROM schema_migrations ORDER BY version")
        ]
        if (
            versions != list(range(1, version + 1))
            or c.execute("PRAGMA quick_check").fetchall() != [("ok",)]
            or c.execute("PRAGMA foreign_key_check").fetchone() is not None
        ):
            raise UnsupportedDatabaseSchemaError("privilege_schema_integrity_failure")


def migrateSqlitePrivilegeSchema(database: GatewayDatabase) -> None:
    with closing(
        sqlite3.connect(database.databasePath.resolve().as_uri() + "?mode=ro", uri=True)
    ) as c:
        version = c.execute("PRAGMA user_version").fetchone()[0]
    if version == SQLITE_PRIVILEGE_VERSION:
        validateSqlitePrivilegeSchema(database)
        return
    if version not in {5, 6}:
        raise UnsupportedDatabaseSchemaError("privilege_schema_unavailable")
    migrateSqliteCloudSchema(database)
    with database.immediateTransaction() as c:
        if c.execute("PRAGMA user_version").fetchone()[0] != 6:
            raise UnsupportedDatabaseSchemaError("privilege_schema_changed")
        applySqlitePrivilegeSchema(c)
    validateSqlitePrivilegeSchema(database)


def _validateMySqlVersions(
    connection: AccountSqlConnection,
    *,
    current: bool,
    recoveryDigest: str | None = None,
    retentionDigest: str | None = None,
    smsSummaryDigest: str | None = None,
    smsUnresolvedDigest: str | None = None,
) -> None:
    definitions: tuple[tuple[int, str], ...] = (
        (1, ACCOUNT_DIGEST),
        (2, USAGE_SCHEMA_DIGEST),
        (3, LIFECYCLE_SCHEMA_DIGEST),
        (4, SMS_SCHEMA_DIGEST),
        (5, CLOUD_SCHEMA_DIGEST),
    )
    if current:
        definitions += ((MYSQL_PRIVILEGE_VERSION, MYSQL_PRIVILEGE_DIGEST),)
    if recoveryDigest is not None:
        definitions += ((7, recoveryDigest),)
    if retentionDigest is not None:
        definitions += ((8, retentionDigest),)
    if smsSummaryDigest is not None:
        definitions += ((9, smsSummaryDigest),)
    if smsUnresolvedDigest is not None:
        definitions += ((10, smsUnresolvedDigest),)
    row = connection.fetchOne("SELECT COUNT(*) AS count FROM gateway_schema_migrations")
    _require(row is not None and row["count"] == len(definitions))
    for version, digest in definitions:
        row = connection.fetchOne(
            "SELECT definition_sha256 FROM gateway_schema_migrations WHERE version=%s", (version,)
        )
        _require(row is not None and row["definition_sha256"] == digest)


def _validateMySqlBase(connection: AccountSqlConnection, *, tableCount: int) -> None:
    _validateSmsStructure(connection, tableCount=tableCount)
    _validateTables(connection, CLOUD_COLUMNS, CLOUD_CHECKS)
    _validateCloudKeys(connection, CLOUD_COLUMNS)


def _validateMySqlGrantTable(connection: AccountSqlConnection) -> None:
    _validateTables(connection, MYSQL_COLUMNS, MYSQL_CHECKS)
    row = connection.fetchOne(
        "SELECT COUNT(DISTINCT index_name) AS count FROM information_schema.statistics "
        "WHERE table_schema=DATABASE() AND table_name='account_privilege_grants'"
    )
    _require(row is not None and row["count"] == 2)
    for columns in ("grant_id", "account_id,privilege"):
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM (SELECT index_name FROM information_schema.statistics "
            "WHERE table_schema=DATABASE() AND table_name='account_privilege_grants' "
            "AND non_unique=0 GROUP BY index_name HAVING "
            "GROUP_CONCAT(column_name ORDER BY seq_in_index SEPARATOR ',')=%s "
            "AND MAX(sub_part) IS NULL) AS privilege_required_index",
            (columns,),
        )
        _require(row is not None and row["count"] == 1)
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.referential_constraints "
        "WHERE constraint_schema=DATABASE() AND table_name='account_privilege_grants'"
    )
    _require(row is not None and row["count"] == 1)
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.key_column_usage k JOIN "
        "information_schema.referential_constraints r ON r.constraint_schema=k.constraint_schema "
        "AND r.constraint_name=k.constraint_name WHERE k.constraint_schema=DATABASE() "
        "AND k.table_name='account_privilege_grants' AND k.column_name='account_id' "
        "AND k.referenced_table_name='accounts' AND k.referenced_column_name='account_id' "
        "AND r.delete_rule='RESTRICT' AND r.update_rule='RESTRICT'"
    )
    _require(row is not None and row["count"] == 1)


def validateMySqlPrivilegeSchema(
    connection: AccountSqlConnection, *, recoveryDigest: str | None = None
) -> None:
    _validateMySqlVersions(connection, current=True, recoveryDigest=recoveryDigest)
    _validateMySqlBase(connection, tableCount=18 if recoveryDigest is not None else 17)
    _validateMySqlGrantTable(connection)


def migrateMySqlPrivilegeSchema(database: MySqlAccountDatabase) -> None:
    # Explicit, quiescent administrative migration. DDL auto-commits on MySQL;
    # only a complete empty unmarked table can be recovered after interruption.
    with database.readConnection() as connection:
        row = connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
        _require(row is not None and row["version"] in {4, 5, 6})
        version = row["version"] if row else None
    if version == 4:
        migrateSyntheticCloudSchema(database)
    with database.transaction() as connection:
        row = connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
        _require(row is not None and row["version"] in {5, 6})
        if row is not None and row["version"] == 6:
            validateMySqlPrivilegeSchema(connection)
            return
        _validateMySqlVersions(connection, current=False)
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema=DATABASE() "
            "AND table_name='account_privilege_grants'"
        )
        exists = row is not None and row["count"] == 1
        _validateMySqlBase(connection, tableCount=17 if exists else 16)
        if exists:
            _validateMySqlGrantTable(connection)
            row = connection.fetchOne("SELECT COUNT(*) AS count FROM account_privilege_grants")
            _require(row is not None and row["count"] == 0)
        for statement in MYSQL_STATEMENTS:
            connection.execute(statement)
        _validateMySqlBase(connection, tableCount=17)
        _validateMySqlGrantTable(connection)
        row = connection.fetchOne("SELECT COUNT(*) AS count FROM account_privilege_grants")
        _require(row is not None and row["count"] == 0)
        connection.execute(
            "INSERT INTO gateway_schema_migrations(version, definition_sha256) VALUES (%s,%s)",
            (MYSQL_PRIVILEGE_VERSION, MYSQL_PRIVILEGE_DIGEST),
        )
