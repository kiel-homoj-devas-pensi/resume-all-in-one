from __future__ import annotations

import base64
import json
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from agent_gateway.account_lifecycle import AccountLifecycleService, FakeSmsSender
from agent_gateway.account_storage import (
    AccountSqlConnection,
    SqliteAccountDatabase,
    UnknownStorageCommitError,
)
from agent_gateway.app import createApplication
from agent_gateway.cloud_routes import decodeCloudResourceKey
from agent_gateway.cloud_storage import CloudResumeStore
from agent_gateway.database import GatewayDatabase, UnsupportedDatabaseSchemaError
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier, hashSecret
from agent_gateway.lifecycle_storage import SqliteLifecycleStore
from agent_gateway.settings import GatewaySettings
from agent_gateway.sqlite_cloud_schema import migrateSqliteCloudSchema
from agent_gateway.usage import UsagePolicyService
from tests.test_cloud_storage import POLICY, operation, snapshot

PREFIX = "/v1/cloud-resumes"
PASSWORD = "Cloud2026!"
TOKEN = "synthetic-cloud-token-one"
OTHER = "synthetic-cloud-token-two"


def resource(value: str) -> str:
    return base64.urlsafe_b64encode(value.encode()).decode().rstrip("=")


def documentPath(identity: str = "document-one") -> str:
    return PREFIX + "/documents/" + resource(identity)


def headers(token: str = TOKEN) -> dict[str, str]:
    return {"Authorization": "Bearer " + token, "X-Cloud-Protocol": "0.1.0"}


def action(op: str | None = None) -> dict[str, str]:
    return {"protocolVersion": "0.1.0", "clientOperationId": op or operation()}


@dataclass
class Harness:
    client: TestClient
    app: FastAPI
    database: GatewayDatabase
    sql: SqliteAccountDatabase
    accounts: AccountService
    lifecycle: AccountLifecycleService
    store: CloudResumeStore

    def consent(self, identity: str = "document-one", *, op: str | None = None) -> Any:
        result = self.client.post(
            documentPath(identity) + "/consents",
            headers=headers(),
            json={**action(op), "policyFingerprint": POLICY.fingerprint},
        )
        assert result.status_code == 200, result.text
        return result.json()["result"]

    def upload(
        self,
        value: dict[str, Any] | None = None,
        *,
        op: str | None = None,
        token: str = TOKEN,
        raw: bytes | None = None,
        document: str | None = None,
        version: str | None = None,
    ) -> Any:
        data = value or snapshot().toJson()
        supplied = {
            **headers(token),
            "Content-Type": "application/json",
            "Idempotency-Key": op or operation(),
            "X-Cloud-Policy-Fingerprint": POLICY.fingerprint,
        }
        if data["version"]["parentVersionId"] is not None:
            supplied["X-Cloud-Expected-Base"] = resource(data["version"]["parentVersionId"])
        return self.client.put(
            documentPath(document or data["document"]["id"])
            + "/versions/"
            + resource(version or data["version"]["id"]),
            headers=supplied,
            content=raw or json.dumps(data, ensure_ascii=False).encode(),
        )


@pytest.fixture
def gateway(tmp_path: Path) -> Iterator[Harness]:
    database = GatewayDatabase(tmp_path / "http-cloud.db")
    database.initialize()
    accounts = AccountService(database, FakePhoneOwnershipVerifier())
    passwordHash = accounts.passwordHasher.hashPassword(PASSWORD)
    with database.immediateTransaction() as connection:
        for account, phone, token in (
            ("account-one", "+00000000001", TOKEN),
            ("account-two", "+00000000002", OTHER),
        ):
            connection.execute(
                "INSERT INTO accounts VALUES (?,?,?,?,?,?)",
                (
                    account,
                    phone,
                    passwordHash,
                    "2026-01-01T00:00:00.000000Z",
                    1,
                    "2026-01-01T00:00:00.000000Z",
                ),
            )
            connection.execute(
                "INSERT INTO account_sessions VALUES (?,?,?,?,?,?)",
                (
                    "session-" + account,
                    account,
                    hashSecret(token),
                    "2099-01-01T00:00:00.000000Z",
                    None,
                    "2026-01-01T00:00:00.000000Z",
                ),
            )
    migrateSqliteCloudSchema(database)
    sql = SqliteAccountDatabase(database)
    store = CloudResumeStore(sql, POLICY, cursorSecret=b"c" * 32)
    lifecycle = AccountLifecycleService(
        accounts,
        FakeSmsSender(),
        otpSecret=b"o" * 32,
        store=SqliteLifecycleStore(database, withCloud=True),
    )
    app = createApplication(
        settings=GatewaySettings(),
        accountService=accounts,
        usagePolicy=UsagePolicyService(database),
        accountLifecycle=lifecycle,
        cloudStore=store,
    )
    with TestClient(app) as client:
        yield Harness(client, app, database, sql, accounts, lifecycle, store)


def test_关闭能力只读发现且无数据库创建(tmp_path: Path) -> None:
    databasePath = tmp_path / "missing.db"
    with TestClient(
        createApplication(settings=GatewaySettings(task018DatabasePath=databasePath))
    ) as client:
        response = client.get(PREFIX + "/options")
        assert response.status_code == 200
        assert response.json()["enabled"] is False
        assert response.json()["policy"] is None
        assert response.headers["cache-control"] == "no-store"
        denied = client.get(PREFIX + "/documents", headers=headers())
        assert denied.status_code == 503
        assert denied.json()["error"]["code"] == "cloud_sync_disabled"
    assert not databasePath.exists()


def test_同意上传读取保留全部未知字段和稳定身份(gateway: Harness) -> None:
    options = gateway.client.get(PREFIX + "/options").json()
    assert options["enabled"] is True and options["developmentOnly"] is True
    assert options["policyFingerprint"] == POLICY.fingerprint
    value = snapshot().toJson()
    identity, version = " /文档 A/ ", "版本/一"
    value["document"]["id"] = identity
    value["document"]["currentVersionId"] = version
    value["version"].update(id=version, documentId=identity)
    gateway.consent(identity)
    uploaded = gateway.upload(value)
    assert uploaded.status_code == 200
    assert uploaded.json()["result"]["outcome"] == "applied"
    for path in (
        documentPath(identity) + "/current",
        documentPath(identity) + "/versions/" + resource(version),
    ):
        downloaded = gateway.client.get(path, headers=headers())
        assert downloaded.status_code == 200
        assert downloaded.json()["snapshot"] == value
        assert downloaded.headers["cache-control"] == "no-store"
        assert len(downloaded.content) <= 65536


def test_相同动作重放及不同内容冲突并可查询原操作(gateway: Harness) -> None:
    gateway.consent()
    op = operation()
    first = gateway.upload(op=op)
    assert first.status_code == 200
    assert gateway.upload(op=op).json() == first.json()
    changed = snapshot().toJson()
    changed["document"]["title"] = "PRIVATE_CHANGED"
    conflict = gateway.upload(changed, op=op)
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "cloud_idempotency_conflict"
    assert "PRIVATE_CHANGED" not in conflict.text
    assert (
        gateway.client.get(PREFIX + "/operations/" + op, headers=headers()).json() == first.json()
    )
    assert (
        gateway.client.get(PREFIX + "/operations/" + op, headers=headers(OTHER)).status_code == 404
    )
    assert (
        len(gateway.client.get(documentPath() + "/versions", headers=headers()).json()["items"])
        == 1
    )


def test_同基础两端冲突拒绝仍绑定原操作(gateway: Harness) -> None:
    gateway.consent()
    assert gateway.upload().json()["result"]["outcome"] == "applied"
    assert (
        gateway.upload(snapshot("version-two", "version-one").toJson()).json()["result"]["outcome"]
        == "applied"
    )
    op = operation()
    rejected = gateway.upload(snapshot("version-three", "version-one").toJson(), op=op)
    assert rejected.status_code == 200
    assert rejected.json()["result"]["outcome"] == "rejected"
    assert rejected.json()["result"]["code"] == "cloud_write_conflict"
    assert (
        gateway.upload(snapshot("version-three", "version-one").toJson(), op=op).json()
        == rejected.json()
    )
    assert (
        gateway.client.get(documentPath() + "/current", headers=headers()).json()["snapshot"][
            "version"
        ]["id"]
        == "version-two"
    )


def test_未同意及政策变动不能上传(gateway: Harness) -> None:
    denied = gateway.upload().json()["result"]
    assert denied["outcome"] == "rejected" and denied["code"] == "cloud_consent_required"
    response = gateway.client.post(
        documentPath() + "/consents",
        headers=headers(),
        json={**action(), "policyFingerprint": "f" * 64},
    )
    assert response.json()["result"]["code"] == "cloud_policy_changed"
    assert gateway.client.get(documentPath() + "/current", headers=headers()).status_code == 404


def test_撤销阻止上传但原所有者仍可读取(gateway: Harness) -> None:
    gateway.consent()
    assert gateway.upload().json()["result"]["outcome"] == "applied"
    revoke = gateway.client.post(
        documentPath() + "/consents/revoke", headers=headers(), json=action()
    )
    assert revoke.json()["result"]["outcome"] == "applied"
    assert (
        gateway.upload(snapshot("version-two", "version-one").toJson()).json()["result"]["code"]
        == "cloud_consent_required"
    )
    assert gateway.client.get(documentPath() + "/current", headers=headers()).status_code == 200


def test_删除拒绝正文并防止成功重放使文档复活(gateway: Harness) -> None:
    gateway.consent()
    op = operation()
    original = gateway.upload(op=op)
    deleted = gateway.client.post(documentPath() + "/delete", headers=headers(), json=action())
    assert deleted.json()["result"]["outcome"] == "applied"
    assert gateway.upload(op=op).json() == original.json()
    for path in ("/current", "/versions", "/versions/" + resource("version-one")):
        assert gateway.client.get(documentPath() + path, headers=headers()).status_code == 404
    assert gateway.consent()["code"] == "cloud_not_accessible"
    items = gateway.client.get(PREFIX + "/documents?includeDeleted=true", headers=headers()).json()[
        "items"
    ]
    assert len(items) == 1 and items[0]["deletedAtUtc"] is not None
    assert items[0]["title"] is None


@pytest.mark.parametrize("path", ["/current", "/versions", "/versions/" + resource("version-one")])
def test_跨账号与缺失同为不可访问(gateway: Harness, path: str) -> None:
    gateway.consent()
    gateway.upload()
    other = gateway.client.get(documentPath() + path, headers=headers(OTHER))
    missing = gateway.client.get(documentPath("missing") + path, headers=headers())
    assert other.status_code == missing.status_code == 404
    assert (
        other.json()["error"]["code"] == missing.json()["error"]["code"] == "cloud_not_accessible"
    )
    assert "合成文档" not in other.text


@pytest.mark.parametrize("failure", ["expired", "revoked", "inactive"])
def test_会话或账户失效不能读取或追加(gateway: Harness, failure: str) -> None:
    gateway.consent()
    gateway.upload()
    with gateway.database.immediateTransaction() as connection:
        if failure == "inactive":
            connection.execute("UPDATE accounts SET is_active=0 WHERE account_id='account-one'")
        else:
            connection.execute(
                "UPDATE account_sessions SET expires_at_utc='2000-01-01T00:00:00.000000Z' "
                "WHERE account_id='account-one'"
                if failure == "expired"
                else "UPDATE account_sessions SET revoked_at_utc='2000-01-01T00:00:00.000000Z' "
                "WHERE account_id='account-one'"
            )
    assert gateway.client.get(documentPath() + "/current", headers=headers()).status_code == 401
    assert gateway.upload(snapshot("version-two", "version-one").toJson()).status_code == 401


def test_账号停用走原生命周期且同事务退休文档(gateway: Harness) -> None:
    gateway.consent()
    gateway.upload()
    response = gateway.client.post(
        "/v2/account/deactivate",
        headers=headers(),
        json={
            "protocolVersion": "0.5.0",
            "currentPassword": PASSWORD,
            "confirmation": "DEACTIVATE",
        },
    )
    assert response.status_code == 200, response.text
    assert gateway.client.get(documentPath() + "/current", headers=headers()).status_code == 401
    with gateway.database.readConnection() as connection:
        assert (
            connection.execute("SELECT deleted_at_utc FROM cloud_documents").fetchone()[0]
            is not None
        )
        assert (
            connection.execute("SELECT revoked_at_utc FROM cloud_consents").fetchone()[0]
            is not None
        )


@pytest.mark.parametrize("identity", ["", "=", "YWJj=", "+w", "_w", "ICA", "a" * 684])
def test_不规范或无效路径身份不进入数据库(identity: str) -> None:
    with pytest.raises(ValueError, match="invalid_cloud_resource_key"):
        decodeCloudResourceKey(identity)


@pytest.mark.parametrize("kind", ["mismatch", "lossy", "int", "duplicate", "rawsize", "unknown"])
def test_原始快照边界拒绝且不新增版本(gateway: Harness, kind: str) -> None:
    gateway.consent()
    value = snapshot().toJson()
    raw = json.dumps(value, ensure_ascii=False).encode()
    if kind == "lossy":
        raw = raw.replace(b"1.25", b"1.0000000000000000001")
    elif kind == "int":
        raw = raw.replace(b"1.25", b"9223372036854775808")
    elif kind == "duplicate":
        raw = raw.replace(
            b'"futureDocument": true', b'"futureDocument": true,"futureDocument":false'
        )
    elif kind == "rawsize":
        raw = b" " * (49153 - len(raw)) + raw
    elif kind == "unknown":
        value["PRIVATE_UNKNOWN"] = "PRIVATE_VALUE"
        raw = json.dumps(value).encode()
    response = gateway.upload(raw=raw, document="different" if kind == "mismatch" else None)
    assert response.status_code == 400, response.text
    assert "PRIVATE" not in response.text
    with gateway.database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 0


def test_已真实提交但丢失确认只查询原操作不自动追加(
    gateway: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    gateway.consent()
    original = gateway.sql.transaction
    writes = 0

    @contextmanager
    def lostAcknowledgement() -> Iterator[AccountSqlConnection]:
        nonlocal writes
        with original() as connection:
            yield connection
        writes += 1
        raise UnknownStorageCommitError("synthetic_ack_lost")

    monkeypatch.setattr(gateway.sql, "transaction", lostAcknowledgement)
    op = operation()
    response = gateway.upload(op=op)
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "operation_outcome_unknown"
    assert response.json()["error"]["retryable"] is False and writes == 1
    monkeypatch.setattr(gateway.sql, "transaction", original)
    looked = gateway.client.get(PREFIX + "/operations/" + op, headers=headers())
    assert looked.json()["result"]["outcome"] == "applied"
    assert (
        len(gateway.client.get(documentPath() + "/versions", headers=headers()).json()["items"])
        == 1
    )


def test_分页游标限定参数账号且响应包含封装仍有界(gateway: Harness) -> None:
    gateway.consent()
    gateway.upload()
    gateway.upload(snapshot("version-two", "version-one").toJson())
    url = documentPath() + "/versions?pageSize=1"
    first = gateway.client.get(url, headers=headers())
    cursor = first.json()["nextCursor"]
    assert cursor and len(first.content) <= 65536
    second = gateway.client.get(url, headers=headers(), params={"cursor": cursor, "pageSize": 1})
    assert second.status_code == 200 and second.json()["items"][0]["versionId"] == "version-two"
    wrong = gateway.client.get(
        documentPath() + "/versions?pageSize=2",
        headers=headers(),
        params={"cursor": cursor, "pageSize": 2},
    )
    assert wrong.status_code == 400
    assert (
        gateway.client.get(
            url, headers=headers(OTHER), params={"cursor": cursor, "pageSize": 1}
        ).status_code
        == 404
    )
    assert (
        gateway.client.get(PREFIX + "/documents?sinceSequence=999", headers=headers()).status_code
        == 409
    )


def test_重复鉴权协议动作和分页参数拒绝(gateway: Harness) -> None:
    supplied = list(headers().items()) + [("Authorization", "Bearer " + OTHER)]
    assert gateway.client.get(PREFIX + "/documents", headers=supplied).status_code == 401
    supplied = list(headers().items()) + [("X-Cloud-Protocol", "0.1.0")]
    assert gateway.client.get(PREFIX + "/documents", headers=supplied).status_code == 400
    assert (
        gateway.client.get(
            PREFIX + "/documents?pageSize=1&pageSize=2", headers=headers()
        ).status_code
        == 400
    )
    gateway.consent()
    supplied = list(headers().items()) + [
        ("Content-Type", "application/json"),
        ("Idempotency-Key", operation()),
        ("Idempotency-Key", operation()),
        ("X-Cloud-Policy-Fingerprint", POLICY.fingerprint),
    ]
    assert (
        gateway.client.put(
            documentPath() + "/versions/" + resource("version-one"),
            headers=supplied,
            content=snapshot().payload,
        ).status_code
        == 400
    )


@pytest.mark.parametrize("failure", ["missing-key", "lifecycle", "other-db", "schema"])
def test_缺游标退休同库或完整结构不能启用(gateway: Harness, tmp_path: Path, failure: str) -> None:
    store, lifecycle = gateway.store, gateway.lifecycle
    if failure == "missing-key":
        store = CloudResumeStore(gateway.sql, POLICY)
    elif failure == "lifecycle":
        lifecycle = AccountLifecycleService(gateway.accounts, FakeSmsSender(), otpSecret=b"o" * 32)
    elif failure == "other-db":
        store = CloudResumeStore(
            SqliteAccountDatabase(GatewayDatabase(tmp_path / "absent.db")),
            POLICY,
            cursorSecret=b"c" * 32,
        )
    else:
        with gateway.database.immediateTransaction() as connection:
            connection.execute("DROP INDEX cloud_documents_changes")
    with pytest.raises((ValueError, UnsupportedDatabaseSchemaError)):
        createApplication(
            settings=GatewaySettings(),
            accountService=gateway.accounts,
            usagePolicy=UsagePolicyService(gateway.database),
            accountLifecycle=lifecycle,
            cloudStore=store,
        )
    assert not (tmp_path / "absent.db").exists()


def test_生产注入云能力在数据库解析之前拒绝(gateway: Harness) -> None:
    settings = GatewaySettings(
        executionEnvironment="production",
        remoteProviderMode="glm",
        glmApiKey="synthetic-no-network",
    )
    with pytest.raises(ValueError, match="生产云同步尚未开放"):
        createApplication(settings=settings, cloudStore=gateway.store)


def test_会话初验后撤销仍由云事务再次拒绝(
    gateway: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    gateway.consent()
    original = gateway.accounts.authenticateSession

    def revokeAfterAuthenticate(token: str, *, nowUtc: datetime | None = None) -> Any:
        subject = original(token, nowUtc=nowUtc)
        gateway.accounts.revokeAllSessions(subject.accountId)
        return subject

    monkeypatch.setattr(gateway.accounts, "authenticateSession", revokeAfterAuthenticate)
    assert gateway.upload().status_code == 401
    with gateway.database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 0


def test_完整分页含大标题与游标不截断也不超响应容量(gateway: Harness) -> None:
    title = "中" * 9000
    for index in range(3):
        value = snapshot().toJson()
        identity = "large-" + str(index)
        value["document"].update(id=identity, title=title)
        value["version"]["documentId"] = identity
        gateway.consent(identity)
        assert gateway.upload(value).json()["result"]["outcome"] == "applied"
    response = gateway.client.get(PREFIX + "/documents", headers=headers())
    assert response.status_code == 200
    assert len(response.content) <= 65536
    page = response.json()
    assert len(page["items"]) == 2 and all(item["title"] == title for item in page["items"])
    assert page["nextCursor"] is not None
    nextPage = gateway.client.get(
        PREFIX + "/documents", headers=headers(), params={"cursor": page["nextCursor"]}
    )
    assert nextPage.status_code == 200 and len(nextPage.content) <= 65536
    assert nextPage.json()["items"][0]["title"] == title
    assert nextPage.json()["nextCursor"] is None


@pytest.mark.parametrize("supplied", [{}, {"X-Cloud-Protocol": "0.1.0"}, headers("invalid")])
def test_缺失或伪造会话不返回正文(gateway: Harness, supplied: dict[str, str]) -> None:
    response = gateway.client.get(PREFIX + "/documents", headers=supplied)
    assert response.status_code in {400, 401}
    assert response.headers["cache-control"] == "no-store"


@pytest.mark.parametrize("protocol", ["0.5.0", "0.4.0", "PRIVATE_PROTOCOL"])
def test_云协议不借用账号或模型协议(gateway: Harness, protocol: str) -> None:
    supplied = {**headers(), "X-Cloud-Protocol": protocol}
    response = gateway.client.get(PREFIX + "/documents", headers=supplied)
    assert response.status_code == 400 and "PRIVATE" not in response.text


def test_快照输入没有可伪造的账号归属(gateway: Harness) -> None:
    value = snapshot().toJson()
    value["accountId"] = "account-two"
    response = gateway.upload(value)
    assert response.status_code == 400
    assert response.json()["error"]["issues"][0]["path"] == "$"
    assert gateway.client.get(PREFIX + "/documents", headers=headers(OTHER)).json()["items"] == []


def test_重启应用读取数据库中的原操作并续读同一游标(gateway: Harness) -> None:
    gateway.consent()
    op = operation()
    original = gateway.upload(op=op).json()
    gateway.upload(snapshot("version-two", "version-one").toJson())
    page = gateway.client.get(documentPath() + "/versions?pageSize=1", headers=headers()).json()
    store = CloudResumeStore(
        SqliteAccountDatabase(gateway.database), POLICY, cursorSecret=b"c" * 32
    )
    restarted = createApplication(
        settings=GatewaySettings(),
        accountService=gateway.accounts,
        usagePolicy=UsagePolicyService(gateway.database),
        accountLifecycle=gateway.lifecycle,
        cloudStore=store,
    )
    with TestClient(restarted) as client:
        assert client.get(PREFIX + "/operations/" + op, headers=headers()).json() == original
        result = client.get(
            documentPath() + "/versions",
            headers=headers(),
            params={"pageSize": 1, "cursor": page["nextCursor"]},
        )
        assert result.status_code == 200 and result.json()["items"][0]["versionId"] == "version-two"
