from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from dataclasses import replace
from pathlib import Path
from typing import Any

import pytest
from darabonba.core import DaraCore
from darabonba.response import DaraResponse
from fastapi.testclient import TestClient

from agent_gateway import app as factory
from agent_gateway.account_storage import SqliteAccountDatabase
from agent_gateway.database import GatewayDatabase, UnsupportedDatabaseSchemaError
from agent_gateway.pnvs_runtime import loadPnvsRuntimeSettings
from agent_gateway.privilege_schema import migrateSqlitePrivilegeSchema
from agent_gateway.provider import FakeAgentProvider
from agent_gateway.settings import GatewaySettings
from agent_gateway.sms_budget import SmsBudgetLedger


def test_importing_application_module_does_not_read_configuration_or_create_database(
    tmp_path: Path,
) -> None:
    databasePath = tmp_path / "must-not-exist.db"
    service = Path(__file__).resolve().parents[1]
    result = subprocess.run(  # noqa: S603 — 固定 Python，只导入模块，无外部请求。
        [
            sys.executable,
            "-c",
            "import agent_gateway.app as module; "
            "from agent_gateway import createApplication; "
            "assert callable(module.createApplication) and callable(createApplication); "
            "assert not hasattr(module, 'app')",
        ],
        env={
            **os.environ,
            "PYTHONPATH": str(service / "src"),
            "AGENT_GATEWAY_TASK018_DATABASE_PATH": str(databasePath),
            "AGENT_GATEWAY_PNVS_CREDENTIALS_PATH": "intentionally-invalid",
            "AGENT_GATEWAY_PNVS_RUNTIME_PATH": "intentionally-invalid",
        },
        check=False,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=15,
    )
    assert result.returncode == 0
    assert result.stdout == result.stderr == b""
    assert not databasePath.exists()


def configuredSettings(path: Path, credentials: Path, runtime: Path) -> GatewaySettings:
    return GatewaySettings(
        task018DatabasePath=path,
        pnvsCredentialsPath=credentials / "synthetic.dpapi",
        pnvsRuntimePath=runtime / "runtime.dpapi",
        executionEnvironment="production",
        remoteProviderMode="glm",
        glmApiKey="synthetic-never-calls-glm",
    )


def approveSynthetic(database: GatewayDatabase, settings: GatewaySettings) -> None:
    assert settings.pnvsRuntimePath is not None
    runtime = loadPnvsRuntimeSettings(settings.pnvsRuntimePath)
    SmsBudgetLedger(
        SqliteAccountDatabase(database), runtime.policy, auditSecret=runtime.auditSecret
    ).createApprovedPolicy()


@pytest.mark.parametrize("withPrivileges", [False, True])
def test_production_factory_reads_protected_settings_registers_and_restarts_without_refilling(
    tmp_path: Path,
    encryptedFiles: Path,
    pnvsRuntimeFiles: Path,
    monkeypatch: pytest.MonkeyPatch,
    withPrivileges: bool,
) -> None:
    database = GatewayDatabase(tmp_path / "gateway.db")
    database.initialize()
    settings = configuredSettings(database.databasePath, encryptedFiles, pnvsRuntimeFiles)
    approveSynthetic(database, settings)
    if withPrivileges:
        migrateSqlitePrivilegeSchema(database)
        settings = replace(settings, enableAccountPrivileges=True)
    calls: list[dict[str, Any]] = []

    def wire(request: Any, runtime: dict[str, Any]) -> DaraResponse:
        calls.append(dict(request.query))
        response = DaraResponse()
        response.status_code = 200
        response.headers = {"content-type": "application/json"}
        response.body = json.dumps(
            {"Code": "OK", "Success": True, "Model": {"OutId": request.query["OutId"]}}
        ).encode("utf-8")
        return response

    monkeypatch.delenv("DEBUG", raising=False)
    monkeypatch.setattr(DaraCore, "do_action", wire)
    app = factory.createApplication(settings=settings)
    assert app.state.provider is None
    assert not app.state.accountService.usesDevelopmentIdentity
    with TestClient(app) as client:
        assert client.get("/health/ready").status_code == 200
        assert client.get("/v2/account/options").json()["developmentSms"] is False
        result = client.post(
            "/v2/account-verifications",
            json={"protocolVersion": "0.5.0", "phoneE164": "+8613800000000", "purpose": "register"},
        )
        assert result.status_code == 200
        challenge = result.json()
        assert challenge["developmentCode"] is None
    code = json.loads(calls[0]["TemplateParam"])["code"]
    reopened = factory.createApplication(settings=settings)
    with TestClient(reopened) as client:
        registered = client.post(
            "/v2/accounts",
            json={
                "protocolVersion": "0.5.0",
                "phoneE164": "+8613800000000",
                "password": "Pnvs2026!",
                "challengeId": challenge["challengeId"],
                "code": code,
            },
        )
        assert registered.status_code == 201
        if withPrivileges:
            login = client.post(
                "/v2/account-sessions",
                json={
                    "protocolVersion": "0.5.0",
                    "phoneE164": "+8613800000000",
                    "password": "Pnvs2026!",
                },
            )
            assert login.status_code == 200
            privileges = client.get(
                "/v1/account/privileges",
                headers={
                    "Authorization": "Bearer " + login.json()["sessionToken"],
                },
            )
            assert privileges.status_code == 200
            assert privileges.json() == {
                "protocolVersion": "0.1.0",
                "accountId": registered.json()["accountId"],
                "role": "member",
                "membership": "none",
            }
        oldProtocol = client.post(
            "/v1/accounts",
            json={
                "protocolVersion": "0.2.0",
                "phoneE164": "+8613800000000",
                "password": "Pnvs2026!",
                "verificationProof": "task018-fake-phone-proof",
            },
        )
        assert oldProtocol.status_code == 400
        assert oldProtocol.json()["error"]["code"] == "unsupported_account_protocol"
    with database.readConnection() as connection:
        assert tuple(
            connection.execute("SELECT attempts,reserved_cents FROM sms_send_budget").fetchone()
        ) == (1, 6)
    assert len(calls) == 1


def test_unapproved_policy_fails_before_accesskey_read_and_never_creates_budget(
    tmp_path: Path, encryptedFiles: Path, pnvsRuntimeFiles: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = GatewayDatabase(tmp_path / "unapproved.db")
    database.initialize()
    settings = configuredSettings(database.databasePath, encryptedFiles, pnvsRuntimeFiles)
    read = False

    def forbid(path: Path) -> Any:
        nonlocal read
        read = True
        raise AssertionError("AccessKey must not be loaded")

    monkeypatch.setattr(factory, "loadPnvsCredentials", forbid)
    with pytest.raises(ValueError, match="not_approved"):
        factory.createApplication(settings=settings)
    assert not read
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM sms_send_budget").fetchone()[0] == 0


def test_missing_sqlite_file_is_not_created_by_real_factory(
    tmp_path: Path, encryptedFiles: Path, pnvsRuntimeFiles: Path
) -> None:
    path = tmp_path / "missing.db"
    with pytest.raises(sqlite3.OperationalError):
        factory.createApplication(
            settings=configuredSettings(path, encryptedFiles, pnvsRuntimeFiles)
        )
    assert not path.exists()


def test_old_sqlite_schema_is_not_migrated_by_real_startup(
    tmp_path: Path, encryptedFiles: Path, pnvsRuntimeFiles: Path
) -> None:
    database = GatewayDatabase(tmp_path / "old.db")
    database.initialize()
    with database.immediateTransaction() as connection:
        connection.execute("DROP TABLE sms_send_attempts")
        connection.execute("DROP TABLE sms_send_budget")
        connection.execute("DELETE FROM schema_migrations WHERE version=5")
        connection.execute("PRAGMA user_version=4")
    with pytest.raises(UnsupportedDatabaseSchemaError):
        factory.createApplication(
            settings=configuredSettings(database.databasePath, encryptedFiles, pnvsRuntimeFiles)
        )
    with database.readConnection() as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 4
        assert (
            connection.execute(
                "SELECT COUNT(*) FROM sqlite_schema WHERE name='sms_send_budget'"
            ).fetchone()[0]
            == 0
        )


def test_partial_or_fake_conflicting_settings_are_rejected(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        GatewaySettings(pnvsCredentialsPath=tmp_path / "credentials.dpapi")
    with pytest.raises(ValueError):
        GatewaySettings(
            pnvsCredentialsPath=tmp_path / "credentials.dpapi",
            pnvsRuntimePath=tmp_path / "runtime.dpapi",
            task018DatabasePath=tmp_path / "gateway.db",
            enableTask018FakeIdentity=True,
        )


def test_real_startup_still_rejects_explicit_fake_provider(
    tmp_path: Path, encryptedFiles: Path, pnvsRuntimeFiles: Path
) -> None:
    database = GatewayDatabase(tmp_path / "fake-injection.db")
    database.initialize()
    settings = configuredSettings(database.databasePath, encryptedFiles, pnvsRuntimeFiles)
    approveSynthetic(database, settings)
    with pytest.raises(ValueError, match="Fake"):
        factory.createApplication(settings=settings, provider=FakeAgentProvider())


def test_read_only_schema_check_preserves_rows_and_rejects_missing_constraint(
    tmp_path: Path,
) -> None:
    database = GatewayDatabase(tmp_path / "schema.db")
    database.initialize()
    with database.immediateTransaction() as connection:
        connection.execute("INSERT INTO identity_rate_limits VALUES ('synthetic','old',3)")
    database.checkSchema()
    with database.readConnection() as connection:
        assert connection.execute("SELECT attempts FROM identity_rate_limits").fetchone()[0] == 3
    with database.immediateTransaction() as connection:
        connection.execute("DROP TABLE sms_send_attempts")
    with pytest.raises(UnsupportedDatabaseSchemaError, match="mismatch"):
        database.checkSchema()
