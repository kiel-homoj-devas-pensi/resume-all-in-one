from __future__ import annotations

import hashlib
from collections.abc import Iterable

from .account_storage import AccountSqlConnection
from .mysql_lifecycle_schema import LIFECYCLE_SCHEMA_DIGEST
from .mysql_schema import SCHEMA_DIGEST as ACCOUNT_SCHEMA_DIGEST
from .mysql_schema import _require
from .mysql_sms_schema import (
    SMS_SCHEMA_DIGEST,
    _validateSmsStructure,
    _validateVersions,
    migrateSyntheticSmsSchema,
)
from .mysql_storage import MySqlAccountDatabase
from .mysql_usage_schema import USAGE_SCHEMA_DIGEST, _validateTables

CLOUD_SCHEMA_VERSION = 5
CLOUD_SCHEMA_STATEMENTS = (
    """CREATE TABLE IF NOT EXISTS cloud_account_state (
        account_id VARBINARY(64) NOT NULL PRIMARY KEY,
        last_sequence BIGINT NOT NULL,
        FOREIGN KEY (account_id) REFERENCES accounts(account_id)
            ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT cloud_state_sequence CHECK (last_sequence >= 0)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS cloud_documents (
        account_id VARBINARY(64) NOT NULL,
        document_id VARBINARY(512) NOT NULL,
        current_version_id VARBINARY(512) NOT NULL,
        document_json BLOB NOT NULL,
        last_sequence BIGINT NOT NULL,
        content_retention_days INT NOT NULL,
        deleted_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NULL,
        PRIMARY KEY (account_id, document_id),
        INDEX cloud_documents_changes (account_id, last_sequence, document_id),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id)
            ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT cloud_document_id CHECK ((LENGTH(document_id) >= 1 AND
        LENGTH(document_id) <= 512)),
        CONSTRAINT cloud_document_version CHECK ((LENGTH(current_version_id) >= 1 AND
        LENGTH(current_version_id) <= 512)),
        CONSTRAINT cloud_document_json CHECK ((LENGTH(document_json) >= 1 AND
        LENGTH(document_json) <= 49152)),
        CONSTRAINT cloud_document_sequence CHECK (last_sequence > 0),
        CONSTRAINT cloud_document_retention CHECK ((content_retention_days >= 0 AND
        content_retention_days <= 3650))
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS cloud_versions (
        account_id VARBINARY(64) NOT NULL,
        document_id VARBINARY(512) NOT NULL,
        version_id VARBINARY(512) NOT NULL,
        parent_version_id VARBINARY(512) NULL,
        snapshot_payload BLOB NOT NULL,
        snapshot_sha256 VARBINARY(64) NOT NULL,
        commit_sequence BIGINT NOT NULL,
        committed_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        PRIMARY KEY (account_id, document_id, version_id),
        UNIQUE KEY cloud_versions_sequence (account_id, commit_sequence),
        INDEX cloud_versions_parent (account_id, document_id, parent_version_id),
        FOREIGN KEY (account_id, document_id)
            REFERENCES cloud_documents(account_id, document_id)
            ON DELETE RESTRICT ON UPDATE RESTRICT,
        FOREIGN KEY (account_id, document_id, parent_version_id)
            REFERENCES cloud_versions(account_id, document_id, version_id)
            ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT cloud_version_id CHECK ((LENGTH(version_id) >= 1 AND LENGTH(version_id) <= 512)),
        CONSTRAINT cloud_version_parent CHECK (
            parent_version_id IS NULL OR (LENGTH(parent_version_id) >= 1 AND
            LENGTH(parent_version_id) <= 512)),
        CONSTRAINT cloud_version_payload CHECK ((LENGTH(snapshot_payload) >= 1 AND
        LENGTH(snapshot_payload) <= 49152)),
        CONSTRAINT cloud_version_digest CHECK (LENGTH(snapshot_sha256) = 64),
        CONSTRAINT cloud_version_sequence CHECK (commit_sequence > 0)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS cloud_operations (
        account_id VARBINARY(64) NOT NULL,
        operation_id VARBINARY(64) NOT NULL,
        action VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        document_id VARBINARY(512) NOT NULL,
        request_fingerprint VARBINARY(64) NOT NULL,
        outcome VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        result_code VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        version_id VARBINARY(512) NULL,
        result_sequence BIGINT NULL,
        committed_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        PRIMARY KEY (account_id, operation_id),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id)
            ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT cloud_operation_action CHECK (
            action IN ('grantConsent', 'revokeConsent', 'appendVersion', 'deleteDocument')),
        CONSTRAINT cloud_operation_document CHECK ((LENGTH(document_id) >= 1 AND
        LENGTH(document_id) <= 512)),
        CONSTRAINT cloud_operation_digest CHECK (LENGTH(request_fingerprint) = 64),
        CONSTRAINT cloud_operation_outcome CHECK (outcome IN ('applied', 'rejected')),
        CONSTRAINT cloud_operation_code CHECK (result_code IN (
            'ok', 'cloud_policy_changed', 'cloud_consent_required', 'cloud_write_conflict',
            'cloud_not_accessible', 'cloud_version_exists', 'cloud_document_time_changed')),
        CONSTRAINT cloud_operation_result CHECK (
            (outcome = 'applied' AND result_code = 'ok' AND result_sequence IS NOT NULL
                AND result_sequence > 0) OR
            (outcome = 'rejected' AND result_code <> 'ok' AND result_sequence IS NULL
                AND version_id IS NULL))
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS cloud_consents (
        account_id VARBINARY(64) NOT NULL,
        document_id VARBINARY(512) NOT NULL,
        consent_id VARBINARY(64) NOT NULL,
        policy_version VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        policy_fingerprint VARBINARY(64) NOT NULL,
        accepted_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        revoked_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NULL,
        PRIMARY KEY (account_id, consent_id),
        INDEX cloud_consents_document (account_id, document_id, policy_version, revoked_at_utc),
        FOREIGN KEY (account_id, consent_id)
            REFERENCES cloud_operations(account_id, operation_id)
            ON DELETE RESTRICT ON UPDATE RESTRICT,
        CONSTRAINT cloud_consent_document CHECK ((LENGTH(document_id) >= 1 AND
        LENGTH(document_id) <= 512)),
        CONSTRAINT cloud_consent_digest CHECK (LENGTH(policy_fingerprint) = 64)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
)
CLOUD_SCHEMA_DIGEST = hashlib.sha256("\n".join(CLOUD_SCHEMA_STATEMENTS).encode()).hexdigest()
CLOUD_COLUMNS = {
    "cloud_account_state": (
        ("account_id", "varbinary(64)", None, "NO"),
        ("last_sequence", "bigint", None, "NO"),
    ),
    "cloud_documents": (
        ("account_id", "varbinary(64)", None, "NO"),
        ("document_id", "varbinary(512)", None, "NO"),
        ("current_version_id", "varbinary(512)", None, "NO"),
        ("document_json", "blob", None, "NO"),
        ("last_sequence", "bigint", None, "NO"),
        ("content_retention_days", "int", None, "NO"),
        ("deleted_at_utc", "char(27)", "ascii_bin", "YES"),
    ),
    "cloud_versions": (
        ("account_id", "varbinary(64)", None, "NO"),
        ("document_id", "varbinary(512)", None, "NO"),
        ("version_id", "varbinary(512)", None, "NO"),
        ("parent_version_id", "varbinary(512)", None, "YES"),
        ("snapshot_payload", "blob", None, "NO"),
        ("snapshot_sha256", "varbinary(64)", None, "NO"),
        ("commit_sequence", "bigint", None, "NO"),
        ("committed_at_utc", "char(27)", "ascii_bin", "NO"),
    ),
    "cloud_operations": (
        ("account_id", "varbinary(64)", None, "NO"),
        ("operation_id", "varbinary(64)", None, "NO"),
        ("action", "varchar(16)", "ascii_bin", "NO"),
        ("document_id", "varbinary(512)", None, "NO"),
        ("request_fingerprint", "varbinary(64)", None, "NO"),
        ("outcome", "varchar(16)", "ascii_bin", "NO"),
        ("result_code", "varchar(40)", "ascii_bin", "NO"),
        ("version_id", "varbinary(512)", None, "YES"),
        ("result_sequence", "bigint", None, "YES"),
        ("committed_at_utc", "char(27)", "ascii_bin", "NO"),
    ),
    "cloud_consents": (
        ("account_id", "varbinary(64)", None, "NO"),
        ("document_id", "varbinary(512)", None, "NO"),
        ("consent_id", "varbinary(64)", None, "NO"),
        ("policy_version", "varchar(64)", "ascii_bin", "NO"),
        ("policy_fingerprint", "varbinary(64)", None, "NO"),
        ("accepted_at_utc", "char(27)", "ascii_bin", "NO"),
        ("revoked_at_utc", "char(27)", "ascii_bin", "YES"),
    ),
}
CLOUD_CHECKS = {
    "cloud_account_state": {"cloud_state_sequence": "last_sequence >= 0"},
    "cloud_documents": {
        "cloud_document_id": "(LENGTH(document_id) >= 1 AND LENGTH(document_id) <= 512)",
        "cloud_document_version": "(LENGTH(current_version_id) >= 1 AND "
        "LENGTH(current_version_id) <= 512)",
        "cloud_document_json": "(LENGTH(document_json) >= 1 AND LENGTH(document_json) <= 49152)",
        "cloud_document_sequence": "last_sequence > 0",
        "cloud_document_retention": "(content_retention_days >= 0 AND "
        "content_retention_days <= 3650)",
    },
    "cloud_versions": {
        "cloud_version_id": "(LENGTH(version_id) >= 1 AND LENGTH(version_id) <= 512)",
        "cloud_version_parent": "parent_version_id IS NULL OR (LENGTH(parent_version_id) "
        ">= 1 AND LENGTH(parent_version_id) <= 512)",
        "cloud_version_payload": "(LENGTH(snapshot_payload) >= 1 AND "
        "LENGTH(snapshot_payload) <= 49152)",
        "cloud_version_digest": "LENGTH(snapshot_sha256) = 64",
        "cloud_version_sequence": "commit_sequence > 0",
    },
    "cloud_operations": {
        "cloud_operation_action": "action IN ('grantConsent', 'revokeConsent', "
        "'appendVersion', 'deleteDocument')",
        "cloud_operation_document": "(LENGTH(document_id) >= 1 AND LENGTH(document_id) <= 512)",
        "cloud_operation_digest": "LENGTH(request_fingerprint) = 64",
        "cloud_operation_outcome": "outcome IN ('applied', 'rejected')",
        "cloud_operation_code": "result_code IN ('ok', 'cloud_policy_changed', "
        "'cloud_consent_required', 'cloud_write_conflict', 'cloud_not_accessible', "
        "'cloud_version_exists', 'cloud_document_time_changed')",
        "cloud_operation_result": "(outcome = 'applied' AND result_code = 'ok' AND "
        "result_sequence IS NOT NULL AND result_sequence > 0) OR (outcome = 'rejected' AND "
        "result_code <> 'ok' AND result_sequence IS NULL AND version_id IS NULL)",
    },
    "cloud_consents": {
        "cloud_consent_document": "(LENGTH(document_id) >= 1 AND LENGTH(document_id) <= 512)",
        "cloud_consent_digest": "LENGTH(policy_fingerprint) = 64",
    },
}
CLOUD_INDEXES = {
    "cloud_account_state": (("account_id", 0),),
    "cloud_documents": (("account_id,document_id", 0), ("account_id,last_sequence,document_id", 1)),
    "cloud_versions": (
        ("account_id,document_id,version_id", 0),
        ("account_id,commit_sequence", 0),
        ("account_id,document_id,parent_version_id", 1),
    ),
    "cloud_operations": (("account_id,operation_id", 0),),
    "cloud_consents": (
        ("account_id,consent_id", 0),
        ("account_id,document_id,policy_version,revoked_at_utc", 1),
    ),
}
CLOUD_FOREIGN_KEYS = {
    "cloud_account_state": (("account_id", "accounts", "account_id"),),
    "cloud_documents": (("account_id", "accounts", "account_id"),),
    "cloud_versions": (
        ("account_id,document_id", "cloud_documents", "account_id,document_id"),
        (
            "account_id,document_id,parent_version_id",
            "cloud_versions",
            "account_id,document_id,version_id",
        ),
    ),
    "cloud_operations": (("account_id", "accounts", "account_id"),),
    "cloud_consents": (("account_id,consent_id", "cloud_operations", "account_id,operation_id"),),
}


CLOUD_ROW_COUNTS = {
    "cloud_account_state": "SELECT COUNT(*) AS count FROM cloud_account_state",
    "cloud_documents": "SELECT COUNT(*) AS count FROM cloud_documents",
    "cloud_versions": "SELECT COUNT(*) AS count FROM cloud_versions",
    "cloud_operations": "SELECT COUNT(*) AS count FROM cloud_operations",
    "cloud_consents": "SELECT COUNT(*) AS count FROM cloud_consents",
}


def _validateCloudKeys(connection: AccountSqlConnection, tables: Iterable[str]) -> None:
    for table in tables:
        indexes = CLOUD_INDEXES[table]
        row = connection.fetchOne(
            "SELECT COUNT(DISTINCT index_name) AS count FROM information_schema.statistics "
            "WHERE table_schema=DATABASE() AND table_name=%s",
            (table,),
        )
        _require(row is not None and row["count"] == len(indexes))
        for columns, nonUnique in indexes:
            row = connection.fetchOne(
                "SELECT COUNT(*) AS count FROM (SELECT index_name FROM "
                "information_schema.statistics "
                "WHERE table_schema=DATABASE() AND table_name=%s AND non_unique=%s "
                "GROUP BY index_name HAVING GROUP_CONCAT(column_name ORDER BY seq_in_index "
                "SEPARATOR ',')=%s AND MAX(sub_part) IS NULL) AS cloud_required_index",
                (table, nonUnique, columns),
            )
            _require(row is not None and row["count"] == 1)
        keys = CLOUD_FOREIGN_KEYS[table]
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.referential_constraints "
            "WHERE constraint_schema=DATABASE() AND table_name=%s",
            (table,),
        )
        _require(row is not None and row["count"] == len(keys))
        for columns, target, targetColumns in keys:
            row = connection.fetchOne(
                "SELECT COUNT(*) AS count FROM (SELECT k.constraint_name FROM "
                "information_schema.key_column_usage k JOIN "
                "information_schema.referential_constraints r ON "
                "r.constraint_schema=k.constraint_schema AND r.constraint_name=k.constraint_name "
                "WHERE k.constraint_schema=DATABASE() AND k.table_name=%s "
                "AND k.referenced_table_name=%s AND r.delete_rule='RESTRICT' "
                "AND r.update_rule='RESTRICT' GROUP BY k.constraint_name HAVING "
                "GROUP_CONCAT(k.column_name ORDER BY k.ordinal_position SEPARATOR ',')=%s "
                "AND GROUP_CONCAT(k.referenced_column_name ORDER BY k.ordinal_position "
                "SEPARATOR ',')=%s) AS cloud_required_foreign_key",
                (table, target, columns, targetColumns),
            )
            _require(row is not None and row["count"] == 1)


def validateCloudSchema(connection: AccountSqlConnection) -> None:
    row = connection.fetchOne("SELECT COUNT(*) AS count FROM gateway_schema_migrations")
    _require(row is not None and row["count"] == 5)
    for version, digest in (
        (1, ACCOUNT_SCHEMA_DIGEST),
        (2, USAGE_SCHEMA_DIGEST),
        (3, LIFECYCLE_SCHEMA_DIGEST),
        (4, SMS_SCHEMA_DIGEST),
        (5, CLOUD_SCHEMA_DIGEST),
    ):
        row = connection.fetchOne(
            "SELECT definition_sha256 FROM gateway_schema_migrations WHERE version=%s",
            (version,),
        )
        _require(row is not None and row["definition_sha256"] == digest)
    _validateSmsStructure(connection, tableCount=16)
    _validateTables(connection, CLOUD_COLUMNS, CLOUD_CHECKS)
    _validateCloudKeys(connection, CLOUD_COLUMNS)


def _knownTables(connection: AccountSqlConnection) -> int:
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema=DATABASE() "
        "AND table_name NOT IN ('gateway_schema_migrations','accounts','account_sessions',"
        "'subscription_snapshots','usage_operations','usage_reconciliations','phone_challenges',"
        "'identity_rate_limits','phone_verification_guards','sms_send_budget','sms_send_attempts',"
        "'cloud_account_state','cloud_documents','cloud_versions','cloud_operations',"
        "'cloud_consents')"
    )
    _require(row is not None and row["count"] == 0)
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema=DATABASE()"
    )
    _require(row is not None)
    return int(str(row["count"])) if row else 0


def migrateSyntheticCloudSchema(database: MySqlAccountDatabase) -> None:
    # 单个管理者先停写；MySQL DDL 会自动提交，不承诺回滚已建的表。
    with database.transaction() as connection:
        count = _knownTables(connection)
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema=DATABASE() "
            "AND table_name='gateway_schema_migrations'"
        )
        if row is not None and row["count"] == 1:
            current = connection.fetchOne(
                "SELECT MAX(version) AS version FROM gateway_schema_migrations"
            )
            version = current["version"] if current else None
        else:
            _require(count == 0)
            version = None
        _require(version in {None, 1, 2, 3, 4, 5})
        if version not in {4, 5}:
            row = connection.fetchOne(
                "SELECT COUNT(*) AS count FROM information_schema.tables WHERE "
                "table_schema=DATABASE() "
                "AND table_name IN ('cloud_account_state','cloud_documents','cloud_versions',"
                "'cloud_operations','cloud_consents')"
            )
            _require(row is not None and row["count"] == 0)
    if version not in {4, 5}:
        migrateSyntheticSmsSchema(database)
    with database.transaction() as connection:
        count = _knownTables(connection)
        row = connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
        _require(row is not None and row["version"] in {4, 5})
        if row is not None and row["version"] == 5:
            validateCloudSchema(connection)
            return
        _validateVersions(connection, includesSms=True)
        _validateSmsStructure(connection, tableCount=count)
        existing = {}
        for table, columns in CLOUD_COLUMNS.items():
            row = connection.fetchOne(
                "SELECT COUNT(*) AS count FROM information_schema.tables WHERE "
                "table_schema=DATABASE() "
                "AND table_name=%s",
                (table,),
            )
            if row is not None and row["count"] == 1:
                existing[table] = columns
        # 先查所有已存在云表的结构和空值；不建新表后才发现未标记的数据。
        _validateTables(connection, existing, {table: CLOUD_CHECKS[table] for table in existing})
        _validateCloudKeys(connection, existing)
        for table in existing:
            # table 只能来自上面的固定字典，不接受调用者标识符。
            row = connection.fetchOne(CLOUD_ROW_COUNTS[table])
            _require(row is not None and row["count"] == 0)
        for statement in CLOUD_SCHEMA_STATEMENTS:
            connection.execute(statement)
        _validateSmsStructure(connection, tableCount=16)
        _validateTables(connection, CLOUD_COLUMNS, CLOUD_CHECKS)
        _validateCloudKeys(connection, CLOUD_COLUMNS)
        for table in CLOUD_COLUMNS:
            row = connection.fetchOne(CLOUD_ROW_COUNTS[table])
            _require(row is not None and row["count"] == 0)
        connection.execute(
            "INSERT INTO gateway_schema_migrations(version, definition_sha256) VALUES (%s,%s)",
            (CLOUD_SCHEMA_VERSION, CLOUD_SCHEMA_DIGEST),
        )
