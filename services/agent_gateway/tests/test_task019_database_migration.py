from __future__ import annotations

import sqlite3
from pathlib import Path

from agent_gateway.database import GatewayDatabase


def test_schema_v1_升级到_v2_只增加脱敏_usage_元数据(tmp_path: Path) -> None:
    databasePath = tmp_path / "gateway-v1.db"
    with sqlite3.connect(databasePath, isolation_level=None) as databaseConnection:
        databaseConnection.execute("BEGIN IMMEDIATE")
        GatewayDatabase._createSchemaVersionOne(databaseConnection)
        databaseConnection.execute("PRAGMA user_version = 1")
        databaseConnection.execute(
            "INSERT INTO schema_migrations(version, applied_at_utc) "
            "VALUES (1, '2026-10-03T00:00:00.000Z')"
        )
        databaseConnection.commit()

    database = GatewayDatabase(databasePath)
    database.initialize()

    with database.readConnection() as databaseConnection:
        schemaVersion = int(databaseConnection.execute("PRAGMA user_version").fetchone()[0])
        migrationVersions = [
            int(migrationRow["version"])
            for migrationRow in databaseConnection.execute(
                "SELECT version FROM schema_migrations ORDER BY version"
            )
        ]
        usageColumnNames = {
            str(column["name"])
            for column in databaseConnection.execute("PRAGMA table_info(usage_operations)")
        }

    assert schemaVersion == 5
    assert migrationVersions == [1, 2, 3, 4, 5]
    assert {"prompt_version", "input_tokens", "output_tokens"} <= usageColumnNames
    assert "provider_response" not in usageColumnNames
