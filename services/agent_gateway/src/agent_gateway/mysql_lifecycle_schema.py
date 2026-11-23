from __future__ import annotations

import hashlib

from .account_storage import AccountSqlConnection
from .mysql_schema import SCHEMA_DIGEST as ACCOUNT_DIGEST
from .mysql_schema import _require
from .mysql_storage import MySqlAccountDatabase
from .mysql_usage_schema import (
    USAGE_SCHEMA_DIGEST,
    _validateTables,
    _validateUsageStructure,
    migrateSyntheticUsageSchema,
    validateUsageSchema,
)

LIFECYCLE_SCHEMA_VERSION = 3
LIFECYCLE_SCHEMA_STATEMENTS = (
    """CREATE TABLE IF NOT EXISTS phone_challenges (
        challenge_id VARBINARY(64) NOT NULL PRIMARY KEY,
        phone_hash VARBINARY(64) NOT NULL,
        purpose VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        code_hash VARBINARY(64) NOT NULL,
        expires_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        attempts INT NOT NULL DEFAULT 0,
        consumed_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NULL,
        INDEX phone_challenges_purpose (phone_hash, purpose, consumed_at_utc),
        CONSTRAINT challenge_purpose CHECK (purpose IN ('register', 'resetPassword')),
        CONSTRAINT challenge_attempts CHECK (attempts >= 0)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS identity_rate_limits (
        bucket_hash VARBINARY(64) NOT NULL PRIMARY KEY,
        window_start_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        attempts INT NOT NULL,
        CONSTRAINT rate_attempts CHECK (attempts >= 0)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS phone_verification_guards (
        phone_hash VARBINARY(64) NOT NULL,
        purpose VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        PRIMARY KEY (phone_hash, purpose),
        CONSTRAINT guard_purpose CHECK (purpose IN ('register', 'resetPassword'))
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
)
LIFECYCLE_SCHEMA_DIGEST = hashlib.sha256(
    "\n".join(LIFECYCLE_SCHEMA_STATEMENTS).encode()
).hexdigest()
LIFECYCLE_COLUMNS = {
    "phone_challenges": (
        ("challenge_id", "varbinary(64)", None, "NO"),
        ("phone_hash", "varbinary(64)", None, "NO"),
        ("purpose", "varchar(16)", "ascii_bin", "NO"),
        ("code_hash", "varbinary(64)", None, "NO"),
        ("expires_at_utc", "char(27)", "ascii_bin", "NO"),
        ("attempts", "int", None, "NO"),
        ("consumed_at_utc", "char(27)", "ascii_bin", "YES"),
    ),
    "identity_rate_limits": (
        ("bucket_hash", "varbinary(64)", None, "NO"),
        ("window_start_utc", "char(27)", "ascii_bin", "NO"),
        ("attempts", "int", None, "NO"),
    ),
    "phone_verification_guards": (
        ("phone_hash", "varbinary(64)", None, "NO"),
        ("purpose", "varchar(16)", "ascii_bin", "NO"),
    ),
}
LIFECYCLE_CHECKS = {
    "phone_challenges": {
        "challenge_purpose": "purpose IN ('register', 'resetPassword')",
        "challenge_attempts": "attempts >= 0",
    },
    "identity_rate_limits": {"rate_attempts": "attempts >= 0"},
    "phone_verification_guards": {"guard_purpose": "purpose IN ('register', 'resetPassword')"},
}


def _validateLifecycleStructure(
    connection: AccountSqlConnection, *, includeUsage: bool = True
) -> None:
    if includeUsage:
        _validateUsageStructure(connection, tableCount=9)
    _validateTables(connection, LIFECYCLE_COLUMNS, LIFECYCLE_CHECKS)
    for table, columns, unique in (
        ("phone_challenges", "challenge_id", 0),
        ("phone_challenges", "phone_hash,purpose,consumed_at_utc", 1),
        ("identity_rate_limits", "bucket_hash", 0),
        ("phone_verification_guards", "phone_hash,purpose", 0),
    ):
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM (SELECT index_name FROM information_schema.statistics "
            "WHERE table_schema = DATABASE() AND table_name = %s AND non_unique = %s "
            "GROUP BY index_name HAVING GROUP_CONCAT(column_name ORDER BY seq_in_index "
            "SEPARATOR ',') = %s AND MAX(sub_part) IS NULL) AS required_index",
            (table, unique, columns),
        )
        _require(row is not None and row["count"] == 1)
    row = connection.fetchOne(
        "SELECT column_default AS default_value FROM "
        "information_schema.columns WHERE table_schema = DATABASE() AND "
        "table_name = 'phone_challenges' AND column_name = 'attempts'"
    )
    _require(row is not None and str(row["default_value"]) == "0")


def validateLifecycleSchema(connection: AccountSqlConnection) -> None:
    validateUsageSchema(connection, includesLifecycle=True)
    row = connection.fetchOne(
        "SELECT definition_sha256 FROM gateway_schema_migrations WHERE version = 3"
    )
    _require(row is not None and row["definition_sha256"] == LIFECYCLE_SCHEMA_DIGEST)
    _validateLifecycleStructure(connection, includeUsage=False)


def migrateSyntheticLifecycleSchema(database: MySqlAccountDatabase) -> None:
    with database.transaction() as connection:
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables WHERE "
            "table_schema = DATABASE() AND table_name = "
            "'gateway_schema_migrations'"
        )
        versionRow = (
            connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
            if row and row["count"] == 1
            else None
        )
        version = versionRow["version"] if versionRow else None
    if version in {None, 1}:
        migrateSyntheticUsageSchema(database)
    with database.transaction() as connection:
        row = connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
        _require(row is not None and row["version"] in {2, 3})
        if row and row["version"] == 3:
            validateLifecycleSchema(connection)
            return
        row = connection.fetchOne("SELECT COUNT(*) AS count FROM gateway_schema_migrations")
        _require(row is not None and row["count"] == 2)
        for existing, digest in ((1, ACCOUNT_DIGEST), (2, USAGE_SCHEMA_DIGEST)):
            row = connection.fetchOne(
                ("SELECT definition_sha256 FROM gateway_schema_migrations WHERE version = %s"),
                (existing,),
            )
            _require(row is not None and row["definition_sha256"] == digest)
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables WHERE "
            "table_schema = DATABASE() AND table_name NOT IN "
            "('gateway_schema_migrations', 'accounts', 'account_sessions', "
            "'subscription_snapshots', 'usage_operations', "
            "'usage_reconciliations', 'phone_challenges', "
            "'identity_rate_limits', 'phone_verification_guards')"
        )
        _require(row is not None and row["count"] == 0)
        for statement in LIFECYCLE_SCHEMA_STATEMENTS:
            connection.execute(statement)
        _validateLifecycleStructure(connection)
        for query in (
            "SELECT COUNT(*) AS count FROM phone_challenges",
            "SELECT COUNT(*) AS count FROM identity_rate_limits",
            "SELECT COUNT(*) AS count FROM phone_verification_guards",
        ):
            row = connection.fetchOne(query)
            _require(row is not None and row["count"] == 0)
        connection.execute(
            ("INSERT INTO gateway_schema_migrations(version, definition_sha256) VALUES (%s, %s)"),
            (3, LIFECYCLE_SCHEMA_DIGEST),
        )
