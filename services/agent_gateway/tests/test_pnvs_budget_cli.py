from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from uuid import uuid4

import pytest

from agent_gateway.account_storage import SqliteAccountDatabase
from agent_gateway.database import GatewayDatabase
from agent_gateway.pnvs_runtime import loadPnvsRuntimeSettings
from agent_gateway.privilege_schema import migrateSqlitePrivilegeSchema
from agent_gateway.sms_budget import SmsBudgetLedger


def invoke(
    path: Path, runtime: Path, *, apply: bool = False, privileges: str = "false"
) -> tuple[int, dict[str, object]]:
    service = Path(__file__).resolve().parents[1]
    command = [
        sys.executable,
        str(service / "scripts/approve_pnvs_budget.py"),
        "--encrypted-runtime-path",
        str(runtime),
    ]
    if apply:
        command.append("--apply-approved-budget")
    environment = {
        **os.environ,
        "PYTHONPATH": str(service / "src"),
        "GATEWAY_DATABASE_BACKEND": "sqlite",
        "AGENT_GATEWAY_TASK018_DATABASE_PATH": str(path),
        "AGENT_GATEWAY_ENABLE_ACCOUNT_PRIVILEGES": privileges,
        # 管理命令不启动应用，也不加载这条故意不可用的凭据路径。
        "AGENT_GATEWAY_PNVS_CREDENTIALS_PATH": str(path.parent / "absent-credentials.dpapi"),
    }
    result = subprocess.run(  # noqa: S603 — 固定脚本，仅合成配置路径。
        command,
        env=environment,
        check=False,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.stderr == ""
    return result.returncode, json.loads(result.stdout)


@pytest.mark.parametrize("withPrivileges", [False, True])
def test_only_explicit_approval_creates_policy_and_repeated_approval_never_refills(
    tmp_path: Path,
    pnvsRuntimeFiles: Path,
    withPrivileges: bool,
) -> None:
    database = GatewayDatabase(tmp_path / "budget.db")
    database.initialize()
    if withPrivileges:
        migrateSqlitePrivilegeSchema(database)
    flag = "true" if withPrivileges else "false"
    runtimePath = pnvsRuntimeFiles / "runtime.dpapi"
    code, status = invoke(database.databasePath, runtimePath, privileges=flag)
    assert code == 1 and status == {"status": "check_failed", "retryable": False}
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM sms_send_budget").fetchone()[0] == 0

    code, status = invoke(database.databasePath, runtimePath, apply=True, privileges=flag)
    assert code == 0
    assert status == {
        "status": "approved_policy_verified",
        "writeRequested": True,
        "smsRequests": 0,
        "accessKeyRead": False,
        "expired": False,
    }
    runtime = loadPnvsRuntimeSettings(runtimePath)
    ledger = SmsBudgetLedger(
        SqliteAccountDatabase(database), runtime.policy, auditSecret=runtime.auditSecret
    )
    challenge = "challenge-" + str(uuid4())
    ledger.reserve(challenge, next(iter(runtime.policy.allowedPhones)), "register")
    ledger.finalize(challenge, "unknown")
    for apply in (False, True):
        code, status = invoke(database.databasePath, runtimePath, apply=apply, privileges=flag)
        assert code == 0 and status["writeRequested"] is apply
    with database.readConnection() as connection:
        assert tuple(
            connection.execute("SELECT attempts,reserved_cents FROM sms_send_budget").fetchone()
        ) == (1, 6)
        assert (
            connection.execute("SELECT outcome FROM sms_send_attempts").fetchone()[0] == "unknown"
        )


def test_approval_command_never_creates_a_missing_database(
    tmp_path: Path, pnvsRuntimeFiles: Path
) -> None:
    path = tmp_path / "missing.db"
    code, status = invoke(path, pnvsRuntimeFiles / "runtime.dpapi", apply=True)
    assert code == 1 and status["status"] == "check_failed"
    assert not path.exists()


@pytest.mark.parametrize(
    "scenario", ["old-enabled", "new-disabled", "invalid-flag", "missing-table"]
)
def test_privileges_schema_must_match_explicit_flag_without_migration_or_approval(
    tmp_path: Path,
    pnvsRuntimeFiles: Path,
    scenario: str,
) -> None:
    database = GatewayDatabase(tmp_path / "schema-check.db")
    database.initialize()
    if scenario in {"new-disabled", "missing-table"}:
        migrateSqlitePrivilegeSchema(database)
    if scenario == "missing-table":
        with database.immediateTransaction() as connection:
            connection.execute("DROP TABLE account_privilege_grants")
    flag = (
        "false" if scenario == "new-disabled" else "yes" if scenario == "invalid-flag" else "true"
    )
    before = database.databasePath.read_bytes()
    code, status = invoke(
        database.databasePath, pnvsRuntimeFiles / "runtime.dpapi", apply=True, privileges=flag
    )
    assert code == 1 and status["status"] == "check_failed"
    assert database.databasePath.read_bytes() == before
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM sms_send_budget").fetchone()[0] == 0
