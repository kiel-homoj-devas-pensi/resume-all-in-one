from __future__ import annotations

import sqlite3
from contextlib import closing

from .database import GatewayDatabase, UnsupportedDatabaseSchemaError

CLOUD_SCHEMA_VERSION = 6
CLOUD_SCHEMA_STATEMENTS = (
    """CREATE TABLE cloud_account_state (
        account_id TEXT PRIMARY KEY REFERENCES accounts(account_id),
        last_sequence INTEGER NOT NULL CHECK (last_sequence >= 0)
    )""",
    """CREATE TABLE cloud_documents (
        account_id TEXT NOT NULL REFERENCES accounts(account_id),
        document_id BLOB NOT NULL CHECK (typeof(document_id) = 'blob' AND
        length(document_id) BETWEEN 1 AND 512),
        current_version_id BLOB NOT NULL CHECK (typeof(current_version_id) = 'blob'
        AND length(current_version_id) BETWEEN 1 AND 512),
        document_json BLOB NOT NULL CHECK (typeof(document_json) = 'blob' AND
        length(document_json) BETWEEN 1 AND 49152),
        last_sequence INTEGER NOT NULL CHECK (last_sequence > 0),
        content_retention_days INTEGER NOT NULL CHECK (content_retention_days BETWEEN 0 AND 3650),
        deleted_at_utc TEXT,
        PRIMARY KEY (account_id, document_id)
    )""",
    "CREATE INDEX cloud_documents_changes "
    "ON cloud_documents(account_id, last_sequence, document_id)",
    """CREATE TABLE cloud_versions (
        account_id TEXT NOT NULL,
        document_id BLOB NOT NULL,
        version_id BLOB NOT NULL CHECK (typeof(version_id) = 'blob' AND
        length(version_id) BETWEEN 1 AND 512),
        parent_version_id BLOB CHECK (parent_version_id IS NULL OR
        (typeof(parent_version_id) = 'blob' AND length(parent_version_id) BETWEEN 1
        AND 512)),
        snapshot_payload BLOB NOT NULL CHECK (typeof(snapshot_payload) = 'blob' AND
        length(snapshot_payload) BETWEEN 1 AND 49152),
        snapshot_sha256 TEXT NOT NULL CHECK (length(snapshot_sha256) = 64),
        commit_sequence INTEGER NOT NULL CHECK (commit_sequence > 0),
        committed_at_utc TEXT NOT NULL,
        PRIMARY KEY (account_id, document_id, version_id),
        UNIQUE (account_id, commit_sequence),
        FOREIGN KEY (account_id, document_id) REFERENCES cloud_documents(account_id, document_id),
        FOREIGN KEY (account_id, document_id, parent_version_id) REFERENCES
        cloud_versions(account_id, document_id, version_id)
    )""",
    """CREATE TABLE cloud_operations (
        account_id TEXT NOT NULL REFERENCES accounts(account_id),
        operation_id TEXT NOT NULL,
        action TEXT NOT NULL CHECK (action IN ('grantConsent', 'revokeConsent',
        'appendVersion', 'deleteDocument')),
        document_id BLOB NOT NULL CHECK (typeof(document_id) = 'blob' AND
        length(document_id) BETWEEN 1 AND 512),
        request_fingerprint TEXT NOT NULL CHECK (length(request_fingerprint) = 64),
        outcome TEXT NOT NULL CHECK (outcome IN ('applied', 'rejected')),
        result_code TEXT NOT NULL CHECK (result_code IN ('ok',
        'cloud_policy_changed', 'cloud_consent_required', 'cloud_write_conflict',
        'cloud_not_accessible', 'cloud_version_exists',
        'cloud_document_time_changed')),
        version_id BLOB,
        result_sequence INTEGER,
        committed_at_utc TEXT NOT NULL,
        PRIMARY KEY (account_id, operation_id),
        CHECK ((outcome = 'applied' AND result_code = 'ok' AND result_sequence IS
        NOT NULL AND result_sequence > 0) OR
               (outcome = 'rejected' AND result_code <> 'ok' AND
               result_sequence IS NULL AND version_id IS NULL))
    )""",
    """CREATE TABLE cloud_consents (
        account_id TEXT NOT NULL,
        document_id BLOB NOT NULL CHECK (typeof(document_id) = 'blob' AND
        length(document_id) BETWEEN 1 AND 512),
        consent_id TEXT NOT NULL,
        policy_version TEXT NOT NULL,
        policy_fingerprint TEXT NOT NULL CHECK (length(policy_fingerprint) = 64),
        accepted_at_utc TEXT NOT NULL,
        revoked_at_utc TEXT,
        PRIMARY KEY (account_id, consent_id),
        FOREIGN KEY (account_id, consent_id) REFERENCES cloud_operations(account_id, operation_id)
    )""",
    "CREATE INDEX cloud_consents_document "
    "ON cloud_consents(account_id, document_id, policy_version, revoked_at_utc)",
)


def applyCloudSchema(connection: sqlite3.Connection) -> None:
    for statement in CLOUD_SCHEMA_STATEMENTS:
        connection.execute(statement)
    connection.execute("PRAGMA user_version = 6")
    connection.execute(
        "INSERT INTO schema_migrations(version, applied_at_utc) "
        "VALUES (6, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
    )


def migrateSqliteCloudSchema(database: GatewayDatabase) -> None:
    # 显式管理入口要求已有库；不初始化或发现电脑上的其他数据库。
    with closing(
        sqlite3.connect(database.databasePath.resolve().as_uri() + "?mode=ro", uri=True)
    ) as connection:
        version = connection.execute("PRAGMA user_version").fetchone()[0]
    if version not in {5, 6}:
        raise UnsupportedDatabaseSchemaError("cloud_sqlite_schema_unavailable")
    database.checkSchema(withCloud=version == 6)
    if version == 6:
        return
    with database.immediateTransaction() as connection:
        if connection.execute("PRAGMA user_version").fetchone()[0] != 5:
            raise UnsupportedDatabaseSchemaError("cloud_sqlite_schema_changed")
        applyCloudSchema(connection)
