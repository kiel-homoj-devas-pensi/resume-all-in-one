from __future__ import annotations

import hashlib

from .account_storage import AccountSqlConnection
from .mysql_lifecycle_schema import (
    LIFECYCLE_SCHEMA_DIGEST,
    _validateLifecycleStructure,
    migrateSyntheticLifecycleSchema,
    validateLifecycleSchema,
)
from .mysql_schema import SCHEMA_DIGEST as ACCOUNT_DIGEST
from .mysql_schema import _require
from .mysql_storage import MySqlAccountDatabase
from .mysql_usage_schema import USAGE_SCHEMA_DIGEST, _validateTables, _validateUsageStructure

SMS_SCHEMA_VERSION = 4
SMS_SCHEMA_STATEMENTS = (
    """CREATE TABLE IF NOT EXISTS sms_send_budget (
        policy_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
        policy_fingerprint VARBINARY(64) NOT NULL,
        maximum_attempts INT NOT NULL,
        budget_cents INT NOT NULL,
        reserve_per_attempt_cents INT NOT NULL,
        attempts INT NOT NULL,
        reserved_cents INT NOT NULL,
        expires_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        created_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        CONSTRAINT sms_budget_singleton CHECK (policy_id = 'pnvs'),
        CONSTRAINT sms_budget_maximum CHECK (maximum_attempts > 0),
        CONSTRAINT sms_budget_cents CHECK (budget_cents > 0),
        CONSTRAINT sms_budget_unit CHECK (reserve_per_attempt_cents > 0),
        CONSTRAINT sms_budget_attempts CHECK (attempts >= 0 AND attempts <= maximum_attempts),
        CONSTRAINT sms_budget_reserved CHECK (
            reserved_cents >= 0 AND reserved_cents <= budget_cents)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS sms_send_attempts (
        challenge_id VARBINARY(64) NOT NULL PRIMARY KEY,
        policy_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        phone_hash VARBINARY(64) NOT NULL,
        purpose VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        outcome VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        reserved_cents INT NOT NULL,
        created_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        finalized_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NULL,
        request_id_digest VARBINARY(64) NULL,
        biz_id_digest VARBINARY(64) NULL,
        INDEX sms_send_attempts_policy (policy_id),
        FOREIGN KEY (policy_id) REFERENCES sms_send_budget(policy_id)
            ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT sms_attempt_purpose CHECK (purpose IN ('register', 'resetPassword')),
        CONSTRAINT sms_attempt_outcome CHECK (
            outcome IN ('reserved', 'accepted', 'rejected', 'unknown')),
        CONSTRAINT sms_attempt_cents CHECK (reserved_cents > 0),
        CONSTRAINT sms_attempt_finalized CHECK (
            (outcome = 'reserved' AND finalized_at_utc IS NULL) OR
            (outcome <> 'reserved' AND finalized_at_utc IS NOT NULL))
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
)
SMS_SCHEMA_DIGEST = hashlib.sha256("\n".join(SMS_SCHEMA_STATEMENTS).encode()).hexdigest()
SMS_COLUMNS = {
    "sms_send_budget": (
        ("policy_id", "varchar(16)", "ascii_bin", "NO"),
        ("policy_fingerprint", "varbinary(64)", None, "NO"),
        ("maximum_attempts", "int", None, "NO"),
        ("budget_cents", "int", None, "NO"),
        ("reserve_per_attempt_cents", "int", None, "NO"),
        ("attempts", "int", None, "NO"),
        ("reserved_cents", "int", None, "NO"),
        ("expires_at_utc", "char(27)", "ascii_bin", "NO"),
        ("created_at_utc", "char(27)", "ascii_bin", "NO"),
    ),
    "sms_send_attempts": (
        ("challenge_id", "varbinary(64)", None, "NO"),
        ("policy_id", "varchar(16)", "ascii_bin", "NO"),
        ("phone_hash", "varbinary(64)", None, "NO"),
        ("purpose", "varchar(16)", "ascii_bin", "NO"),
        ("outcome", "varchar(16)", "ascii_bin", "NO"),
        ("reserved_cents", "int", None, "NO"),
        ("created_at_utc", "char(27)", "ascii_bin", "NO"),
        ("finalized_at_utc", "char(27)", "ascii_bin", "YES"),
        ("request_id_digest", "varbinary(64)", None, "YES"),
        ("biz_id_digest", "varbinary(64)", None, "YES"),
    ),
}
SMS_CHECKS = {
    "sms_send_budget": {
        "sms_budget_singleton": "policy_id = 'pnvs'",
        "sms_budget_maximum": "maximum_attempts > 0",
        "sms_budget_cents": "budget_cents > 0",
        "sms_budget_unit": "reserve_per_attempt_cents > 0",
        "sms_budget_attempts": "attempts >= 0 AND attempts <= maximum_attempts",
        "sms_budget_reserved": "reserved_cents >= 0 AND reserved_cents <= budget_cents",
    },
    "sms_send_attempts": {
        "sms_attempt_purpose": "purpose IN ('register', 'resetPassword')",
        "sms_attempt_outcome": "outcome IN ('reserved', 'accepted', 'rejected', 'unknown')",
        "sms_attempt_cents": "reserved_cents > 0",
        "sms_attempt_finalized": (
            "(outcome = 'reserved' AND finalized_at_utc IS NULL) OR "
            "(outcome <> 'reserved' AND finalized_at_utc IS NOT NULL)"
        ),
    },
}


def _validateVersions(connection: AccountSqlConnection, *, includesSms: bool) -> None:
    definitions: tuple[tuple[int, str], ...] = (
        (1, ACCOUNT_DIGEST),
        (2, USAGE_SCHEMA_DIGEST),
        (3, LIFECYCLE_SCHEMA_DIGEST),
    )
    if includesSms:
        definitions += ((4, SMS_SCHEMA_DIGEST),)
    row = connection.fetchOne("SELECT COUNT(*) AS count FROM gateway_schema_migrations")
    _require(row is not None and row["count"] == len(definitions))
    for version, digest in definitions:
        row = connection.fetchOne(
            "SELECT definition_sha256 FROM gateway_schema_migrations WHERE version = %s",
            (version,),
        )
        _require(row is not None and row["definition_sha256"] == digest)


def _validateSmsStructure(connection: AccountSqlConnection, *, tableCount: int = 11) -> None:
    _validateUsageStructure(connection, tableCount=tableCount)
    _validateLifecycleStructure(connection, includeUsage=False)
    _validateTables(connection, SMS_COLUMNS, SMS_CHECKS)
    for table, column, unique in (
        ("sms_send_budget", "policy_id", 0),
        ("sms_send_attempts", "challenge_id", 0),
        ("sms_send_attempts", "policy_id", 1),
    ):
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM (SELECT index_name FROM information_schema.statistics "
            "WHERE table_schema = DATABASE() AND table_name = %s AND non_unique = %s "
            "GROUP BY index_name HAVING COUNT(*) = 1 AND MAX(column_name) = %s "
            "AND MAX(sub_part) IS NULL) AS required_sms_key",
            (table, unique, column),
        )
        _require(row is not None and row["count"] == 1)
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.key_column_usage k JOIN "
        "information_schema.referential_constraints r ON "
        "r.constraint_schema = k.constraint_schema AND r.constraint_name = k.constraint_name "
        "WHERE k.constraint_schema = DATABASE() AND k.table_name = 'sms_send_attempts' "
        "AND k.column_name = 'policy_id' AND k.referenced_table_name = 'sms_send_budget' "
        "AND k.referenced_column_name = 'policy_id' AND r.delete_rule = 'RESTRICT' "
        "AND r.update_rule = 'RESTRICT'"
    )
    _require(row is not None and row["count"] == 1)


def validateSmsSchema(connection: AccountSqlConnection) -> None:
    _validateVersions(connection, includesSms=True)
    _validateSmsStructure(connection)


def validateFullGatewaySchema(connection: AccountSqlConnection) -> None:
    row = connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
    _require(row is not None and row["version"] in {3, 4})
    if row is not None and row["version"] == 4:
        validateSmsSchema(connection)
    else:
        validateLifecycleSchema(connection)


def migrateSyntheticSmsSchema(database: MySqlAccountDatabase) -> None:
    with database.transaction() as connection:
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables WHERE "
            "table_schema = DATABASE() AND table_name = 'gateway_schema_migrations'"
        )
        current = (
            connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
            if row and row["count"] == 1
            else None
        )
    if current is None or current["version"] in {None, 1, 2}:
        migrateSyntheticLifecycleSchema(database)
    with database.transaction() as connection:
        row = connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
        _require(row is not None and row["version"] in {3, 4})
        if row is not None and row["version"] == 4:
            validateSmsSchema(connection)
            return
        _validateVersions(connection, includesSms=False)
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables WHERE "
            "table_schema = DATABASE() AND table_name NOT IN "
            "('gateway_schema_migrations', 'accounts', 'account_sessions', "
            "'subscription_snapshots', 'usage_operations', 'usage_reconciliations', "
            "'phone_challenges', 'identity_rate_limits', 'phone_verification_guards', "
            "'sms_send_budget', 'sms_send_attempts')"
        )
        _require(row is not None and row["count"] == 0)
        # 保留旧摘要；DDL 失败可留下空表，重跑先检查完整结构，版本最后写。
        for statement in SMS_SCHEMA_STATEMENTS:
            connection.execute(statement)
        _validateSmsStructure(connection)
        for query in (
            "SELECT COUNT(*) AS count FROM sms_send_budget",
            "SELECT COUNT(*) AS count FROM sms_send_attempts",
        ):
            row = connection.fetchOne(query)
            _require(row is not None and row["count"] == 0)
        connection.execute(
            "INSERT INTO gateway_schema_migrations(version, definition_sha256) VALUES (%s, %s)",
            (4, SMS_SCHEMA_DIGEST),
        )
