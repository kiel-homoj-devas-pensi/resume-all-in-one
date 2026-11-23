from __future__ import annotations

import importlib
import sqlite3
from dataclasses import replace
from pathlib import Path
from typing import Any

import pytest
from darabonba.core import DaraCore
from fastapi.testclient import TestClient

from agent_gateway import app as factory
from agent_gateway import cloud_runtime as runtime
from agent_gateway.account_storage import SqliteAccountDatabase, StorageUnavailableError
from agent_gateway.cloud_runtime import CloudRuntimeLoadError, CloudRuntimeSettings
from agent_gateway.cloud_storage import CloudSession
from agent_gateway.database import GatewayDatabase, UnsupportedDatabaseSchemaError
from agent_gateway.identity import FakePhoneOwnershipVerifier, hashSecret
from agent_gateway.pnvs_runtime import loadPnvsRuntimeSettings
from agent_gateway.settings import GatewaySettings
from agent_gateway.sms_budget import SmsBudgetLedger
from agent_gateway.sqlite_cloud_schema import migrateSqliteCloudSchema
from tests.test_cloud_routes import PASSWORD, PREFIX, action, documentPath, headers, resource
from tests.test_cloud_storage import POLICY, operation, snapshot


def configured(
    tmp_path: Path, cloudRuntimeFiles: Path, *, migrate: bool = True
) -> tuple[GatewaySettings, GatewayDatabase]:
    database = GatewayDatabase(tmp_path / "synthetic-cloud.db")
    if migrate:
        database.initialize()
        migrateSqliteCloudSchema(database)
    return GatewaySettings(
        enableTask018FakeIdentity=True,
        task018DatabasePath=database.databasePath,
        cloudRuntimePath=cloudRuntimeFiles / "runtime.dpapi",
    ), database


def test_原生工厂同库启用并能重启查询原操作与游标(tmp_path: Path, cloudRuntimeFiles: Path) -> None:
    settings, database = configured(tmp_path, cloudRuntimeFiles)
    app = factory.createApplication(settings=settings)
    assert app.state.accountLifecycle.retiresCloudDocuments
    assert app.state.cloudStore.authorityKey == app.state.usagePolicy.authorityKey
    accounts = app.state.accountService
    accounts.registerAccount(
        phoneE164="+15550001111",
        password=PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    token = accounts.createSession(phoneE164="+15550001111", password=PASSWORD).sessionToken
    supplied = headers(token)
    with TestClient(app) as client:
        info = client.get(PREFIX + "/options").json()
        assert info["enabled"] and info["developmentOnly"]
        consent = client.post(
            documentPath() + "/consents",
            headers=supplied,
            json={**action(), "policyFingerprint": info["policyFingerprint"]},
        )
        assert consent.json()["result"]["outcome"] == "applied"
        op = operation()
        uploadHeaders = {
            **supplied,
            "Content-Type": "application/json",
            "Idempotency-Key": op,
            "X-Cloud-Policy-Fingerprint": info["policyFingerprint"],
        }
        first = client.put(
            documentPath() + "/versions/" + resource("version-one"),
            headers=uploadHeaders,
            content=snapshot().payload,
        )
        assert first.json()["result"]["outcome"] == "applied"
        uploadHeaders.update(
            {"Idempotency-Key": operation(), "X-Cloud-Expected-Base": resource("version-one")}
        )
        assert (
            client.put(
                documentPath() + "/versions/" + resource("version-two"),
                headers=uploadHeaders,
                content=snapshot("version-two", "version-one").payload,
            ).json()["result"]["outcome"]
            == "applied"
        )
        cursor = client.get(documentPath() + "/versions?pageSize=1", headers=supplied).json()[
            "nextCursor"
        ]
    restarted = factory.createApplication(settings=settings)
    with TestClient(restarted) as client:
        assert client.get(PREFIX + "/operations/" + op, headers=supplied).json() == first.json()
        page = client.get(
            documentPath() + "/versions", headers=supplied, params={"pageSize": 1, "cursor": cursor}
        )
        assert page.status_code == 200 and page.json()["items"][0]["versionId"] == "version-two"
        retired = client.post(
            "/v2/account/deactivate",
            headers=supplied,
            json={
                "protocolVersion": "0.5.0",
                "currentPassword": PASSWORD,
                "confirmation": "DEACTIVATE",
            },
        )
        assert retired.status_code == 200
    with database.readConnection() as connection:
        assert (
            connection.execute("SELECT deleted_at_utc FROM cloud_documents").fetchone()[0]
            is not None
        )


@pytest.mark.parametrize("kind", ["missing", "old", "unknown-table"])
def test_云启动缺失旧结构或外来表不创建也不迁移(
    tmp_path: Path, cloudRuntimeFiles: Path, kind: str
) -> None:
    settings, database = configured(tmp_path, cloudRuntimeFiles, migrate=False)
    if kind != "missing":
        database.initialize()
        if kind == "unknown-table":
            migrateSqliteCloudSchema(database)
            with database.immediateTransaction() as connection:
                connection.execute("CREATE TABLE foreign_table(id INTEGER)")
    before = database.databasePath.read_bytes() if database.databasePath.exists() else None
    with pytest.raises((UnsupportedDatabaseSchemaError, StorageUnavailableError, sqlite3.Error)):
        factory.createApplication(settings=settings)
    if before is None:
        assert not database.databasePath.exists()
    else:
        assert database.databasePath.read_bytes() == before


def test_无效配置在账户库接入前拒绝(
    tmp_path: Path, cloudRuntimeFiles: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings, _ = configured(tmp_path, cloudRuntimeFiles)
    invalid = GatewaySettings(
        enableTask018FakeIdentity=True,
        task018DatabasePath=settings.task018DatabasePath,
        cloudRuntimePath=cloudRuntimeFiles / "short-secret.dpapi",
    )

    def forbidden(*args: Any, **kwargs: Any) -> Any:
        pytest.fail("Invalid configuration reached account database resolution")

    monkeypatch.setattr(factory, "_resolveTask018Services", forbidden)
    with pytest.raises(CloudRuntimeLoadError):
        factory.createApplication(settings=invalid)


def test_模块导入不会读取云配置或打开库(monkeypatch: pytest.MonkeyPatch) -> None:
    def forbidden(path: str | Path) -> Any:
        pytest.fail("Import loaded cloud configuration")

    try:
        with monkeypatch.context() as guard:
            guard.setattr(runtime, "loadCloudRuntimeSettings", forbidden)
            importlib.reload(factory)
    finally:
        # 临时替身恢复后重新绑定 imported alias，不让它污染后续测试。
        importlib.reload(factory)


def test_生产路径门禁在读取任何配置前发生(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="生产云同步尚未开放"):
        GatewaySettings(
            executionEnvironment="production", cloudRuntimePath=tmp_path / "PRIVATE.dpapi"
        )


def test_配置必须明确启用同库身份且路径是Path(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="同库账户身份"):
        GatewaySettings(cloudRuntimePath=tmp_path / "synthetic.dpapi")


def test_云运行路径从环境进入但不读内容(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AGENT_GATEWAY_CLOUD_RUNTIME_PATH", str(tmp_path / "synthetic.dpapi"))
    monkeypatch.setenv("AGENT_GATEWAY_ENABLE_TASK018_FAKE_IDENTITY", "true")
    monkeypatch.setenv("AGENT_GATEWAY_TASK018_DATABASE_PATH", str(tmp_path / "synthetic.db"))
    settings = GatewaySettings.fromEnvironment()
    assert settings.cloudRuntimePath == tmp_path / "synthetic.dpapi"
    assert not settings.cloudRuntimePath.exists()


def test_运行文件不能混用另一份账户注入(tmp_path: Path, cloudRuntimeFiles: Path) -> None:
    settings, _ = configured(tmp_path, cloudRuntimeFiles)
    actual = factory.createApplication(settings=settings)
    with pytest.raises(ValueError, match="不能.*混用"):
        factory.createApplication(settings=settings, accountService=actual.state.accountService)


def test_轮换游标秘密后旧游标失败但原操作仍在(tmp_path: Path, cloudRuntimeFiles: Path) -> None:
    settings, _ = configured(tmp_path, cloudRuntimeFiles)
    app = factory.createApplication(settings=settings)
    accounts = app.state.accountService
    account = accounts.registerAccount(
        phoneE164="+15550001111",
        password=PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    token = accounts.createSession(phoneE164="+15550001111", password=PASSWORD).sessionToken
    store = app.state.cloudStore
    identity = CloudSession(account, hashSecret(token))
    store.grantConsent(identity, "document-one", operation(), store.policy.fingerprint)
    op = operation()
    store.appendVersion(identity, op, snapshot(), None, store.policy.fingerprint)
    store.appendVersion(
        identity,
        operation(),
        snapshot("version-two", "version-one"),
        "version-one",
        store.policy.fingerprint,
    )
    with TestClient(app) as client:
        page = client.get(documentPath() + "/versions?pageSize=1", headers=headers(token)).json()
    rotated = factory.createApplication(
        settings=replace(settings, cloudRuntimePath=cloudRuntimeFiles / "runtime-rotated.dpapi")
    )
    with TestClient(rotated) as client:
        failed = client.get(
            documentPath() + "/versions",
            headers=headers(token),
            params={"pageSize": 1, "cursor": page["nextCursor"]},
        )
        assert (
            failed.status_code == 400 and failed.json()["error"]["code"] == "cloud_cursor_invalid"
        )
        assert (
            client.get(PREFIX + "/operations/" + op, headers=headers(token)).json()["result"][
                "outcome"
            ]
            == "applied"
        )


@pytest.mark.parametrize("reused", ["otpSecret", "auditSecret"])
def test_游标不可借用PNVS秘密且拒绝前未加载AccessKey(
    tmp_path: Path,
    cloudRuntimeFiles: Path,
    pnvsRuntimeFiles: Path,
    encryptedFiles: Path,
    monkeypatch: pytest.MonkeyPatch,
    reused: str,
) -> None:
    settings, _ = configured(tmp_path, cloudRuntimeFiles)
    pnvs = loadPnvsRuntimeSettings(pnvsRuntimeFiles / "runtime.dpapi")
    settings = replace(
        settings,
        enableTask018FakeIdentity=False,
        pnvsRuntimePath=pnvsRuntimeFiles / "runtime.dpapi",
        pnvsCredentialsPath=encryptedFiles / "synthetic.dpapi",
    )

    def reusedRuntime(path: str | Path) -> CloudRuntimeSettings:
        return CloudRuntimeSettings(POLICY, getattr(pnvs, reused))

    def forbidden(path: str | Path) -> Any:
        pytest.fail("Reused secret reached AccessKey loading")

    monkeypatch.setattr(factory, "loadCloudRuntimeSettings", reusedRuntime)
    monkeypatch.setattr(factory, "loadPnvsCredentials", forbidden)
    with pytest.raises(CloudRuntimeLoadError):
        factory.createApplication(settings=settings)


def test_云运行配置不批准PNVS预算或绕过凭据门禁(
    tmp_path: Path,
    cloudRuntimeFiles: Path,
    pnvsRuntimeFiles: Path,
    encryptedFiles: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings, _ = configured(tmp_path, cloudRuntimeFiles)
    settings = replace(
        settings,
        enableTask018FakeIdentity=False,
        pnvsRuntimePath=pnvsRuntimeFiles / "runtime.dpapi",
        pnvsCredentialsPath=encryptedFiles / "synthetic.dpapi",
    )

    def forbidden(path: str | Path) -> Any:
        pytest.fail("Unapproved PNVS budget reached AccessKey loading")

    monkeypatch.setattr(factory, "loadPnvsCredentials", forbidden)
    with pytest.raises(ValueError, match="sms_budget_not_approved"):
        factory.createApplication(settings=settings)


def test_获批合成PNVS预算与云工厂同库重启不补额且不发短信(
    tmp_path: Path,
    cloudRuntimeFiles: Path,
    pnvsRuntimeFiles: Path,
    encryptedFiles: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings, database = configured(tmp_path, cloudRuntimeFiles)
    settings = replace(
        settings,
        enableTask018FakeIdentity=False,
        pnvsRuntimePath=pnvsRuntimeFiles / "runtime.dpapi",
        pnvsCredentialsPath=encryptedFiles / "synthetic.dpapi",
    )
    pnvs = loadPnvsRuntimeSettings(pnvsRuntimeFiles / "runtime.dpapi")
    SmsBudgetLedger(
        SqliteAccountDatabase(database), pnvs.policy, auditSecret=pnvs.auditSecret
    ).createApprovedPolicy()
    with database.readConnection() as connection:
        before = dict(connection.execute("SELECT * FROM sms_send_budget").fetchone())

    def forbidden(*args: Any, **kwargs: Any) -> Any:
        pytest.fail("Startup reached SMS HTTP transport")

    monkeypatch.delenv("DEBUG", raising=False)
    monkeypatch.setattr(DaraCore, "do_action", forbidden)
    for _ in range(2):
        app = factory.createApplication(settings=settings)
        assert app.state.accountLifecycle.retiresCloudDocuments
        assert not app.state.accountService.usesDevelopmentIdentity
        with TestClient(app) as client:
            assert client.get(PREFIX + "/options").json()["enabled"]
            assert client.get("/v2/account/options").json()["developmentSms"] is False
    with database.readConnection() as connection:
        assert dict(connection.execute("SELECT * FROM sms_send_budget").fetchone()) == before
        assert connection.execute("SELECT COUNT(*) FROM sms_send_attempts").fetchone()[0] == 0
