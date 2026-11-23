from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from agent_gateway.account_retention_schema import migrateSqliteRetentionSchema
from agent_gateway.privilege_schema import migrateSqlitePrivilegeSchema
from agent_gateway.recovery_schema import migrateSqliteRecoverySchema
from agent_gateway.sms_attempt_retention_schema import migrateSqliteSmsSummarySchema
from agent_gateway.usage import ProductCapability, UsageOperationStatus, UsagePolicyService
from tests.test_remote_gateway import RecordingRemoteProvider, buildRemoteApplication


@pytest.mark.parametrize("schema", [5, 11])
def test_cli_reconciles_existing_schema_without_migration(tmp_path: Path, schema: int) -> None:
    _, database, account, _, _ = buildRemoteApplication(tmp_path, RecordingRemoteProvider())
    policy = UsagePolicyService(database)
    now = datetime.now(UTC)
    operation = policy.reserveUsage(
        accountId=account,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="cli-synthetic",
        requestFingerprint="synthetic",
        nowUtc=now - timedelta(minutes=10),
    )
    policy.markAbandonedReservations(beforeUtc=now - timedelta(minutes=5))
    if schema == 11:
        migrateSqlitePrivilegeSchema(database)
        migrateSqliteRecoverySchema(database)
        migrateSqliteRetentionSchema(database)
        migrateSqliteSmsSummarySchema(database)
    evidence = tmp_path / "evidence.json"
    evidence.write_text(
        json.dumps(
            {
                "operationId": operation.operationId,
                "evidenceKind": "notExecuted",
                "providerReference": "synthetic-reviewed",
            }
        ),
        encoding="utf-8",
    )
    arguments = [
        sys.executable,
        "scripts/reconcile_usage.py",
        "--database",
        str(database.databasePath),
        "--operator",
        "synthetic-reviewer",
        "--verified-evidence",
        str(evidence),
        "--confirm-verified",
    ]
    environment = os.environ | {"PYTHONPATH": str(Path.cwd() / "src")}
    if schema == 11:
        wrong = subprocess.run(arguments, capture_output=True, timeout=20, env=environment)  # noqa: S603 — fixed local CLI, synthetic paths.
        assert wrong.returncode == 2
        current = policy.findOwnedOperation(
            accountId=account,
            capability=operation.capability,
            usageOperationId=operation.operationId,
        )
        assert current is not None and current.status is UsageOperationStatus.pendingReconciliation
    result = subprocess.run(  # noqa: S603 — fixed local CLI, synthetic paths.
        arguments + ["--schema-version", str(schema)],
        capture_output=True,
        timeout=20,
        env=environment,
    )
    assert result.returncode == 0
    assert b"released" in result.stdout
    repeated = subprocess.run(  # noqa: S603 — fixed local CLI, synthetic paths.
        arguments + ["--schema-version", str(schema)],
        capture_output=True,
        timeout=20,
        env=environment,
    )
    assert repeated.returncode == 0
    with database.readConnection() as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == schema
        assert connection.execute("SELECT COUNT(*) FROM usage_reconciliations").fetchone()[0] == 1
