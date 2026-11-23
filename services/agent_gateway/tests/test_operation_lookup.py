from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from agent_gateway.app import createApplication
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.settings import GatewaySettings
from agent_gateway.usage import ProductCapability, UsagePolicyService
from tests.support import sendAsgiRequest
from tests.test_remote_gateway import (
    VALID_PASSWORD,
    RecordingRemoteProvider,
    basicRequestBody,
    buildRemoteApplication,
)


def test_丢失响应后用动作键及用量ID查询且不重复调用(tmp_path: Path) -> None:
    provider = RecordingRemoteProvider()
    app, database, accountId, token, _ = buildRemoteApplication(tmp_path, provider)
    body = basicRequestBody()
    headers = {"Authorization": f"Bearer {token}", "X-Operation-Protocol": "0.4.0"}
    response = sendAsgiRequest(
        app, "POST", "/v1/resume-ai/requests", headers=headers, jsonBody=body
    )
    usageId = response.json()["operationId"]
    for selector in ({"idempotencyKey": body["idempotencyKey"]}, {"usageOperationId": usageId}):
        lookup = sendAsgiRequest(
            app,
            "POST",
            "/v1/resume-ai/operations/lookup",
            headers=headers,
            jsonBody={"protocolVersion": "0.4.0", "capability": "basicResumeCompose", **selector},
        )
        assert lookup.status_code == 200
        assert lookup.json()["usageOperationId"] == usageId
        assert lookup.json()["traceId"].startswith("operation-")
        assert lookup.json()["status"] == "committed"
        assert lookup.json()["nextAction"] == "resultUnavailable"
        assert lookup.json()["quotaOccupied"] is True
        assert lookup.json()["resultAvailable"] is False
    replay = sendAsgiRequest(app, "POST", "/v1/resume-ai/requests", headers=headers, jsonBody=body)
    assert replay.status_code == 409
    assert replay.json()["error"]["usageOperationId"] == usageId
    assert replay.json()["error"]["operationId"] == replay.json()["error"]["traceId"]
    assert provider.generateCallCount == 1
    # 重开服务、跨月查询仍找到同一操作，不重新占用当前月额度。
    policy = UsagePolicyService(database)
    assert (
        policy.findOwnedOperation(
            accountId=accountId,
            capability=ProductCapability.basicResumeCompose,
            idempotencyKey=str(body["idempotencyKey"]),
        )
        is not None
    )
    assert (
        policy.evaluateAccess(
            accountId=accountId,
            capability=ProductCapability.basicResumeCompose,
            nowUtc=datetime(2030, 1, 1, tzinfo=UTC),
        ).remainingMonthlyBasicGenerations
        == 9
    )
    reopened = createApplication(
        settings=GatewaySettings(),
        accountService=AccountService(database, FakePhoneOwnershipVerifier()),
        usagePolicy=policy,
        remoteResumeProvider=provider,
    )
    assert (
        sendAsgiRequest(
            reopened,
            "POST",
            "/v1/resume-ai/operations/lookup",
            headers=headers,
            jsonBody={
                "protocolVersion": "0.4.0",
                "capability": "basicResumeCompose",
                "usageOperationId": usageId,
            },
        ).json()["status"]
        == "committed"
    )


def test_其他账号及不存在记录返回同样未知状态(tmp_path: Path) -> None:
    provider = RecordingRemoteProvider()
    app, database, _, token, _ = buildRemoteApplication(tmp_path, provider)
    response = sendAsgiRequest(
        app,
        "POST",
        "/v1/resume-ai/requests",
        headers={"Authorization": f"Bearer {token}"},
        jsonBody=basicRequestBody(),
    )
    accountService = AccountService(database, FakePhoneOwnershipVerifier())
    phone = "+15550004321"
    accountService.registerAccount(
        phoneE164=phone,
        password=VALID_PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    otherToken = accountService.createSession(phoneE164=phone, password=VALID_PASSWORD).sessionToken
    for usageId in (response.json()["operationId"], "usage-missing"):
        lookup = sendAsgiRequest(
            app,
            "POST",
            "/v1/resume-ai/operations/lookup",
            headers={"Authorization": f"Bearer {otherToken}"},
            jsonBody={
                "protocolVersion": "0.4.0",
                "capability": "basicResumeCompose",
                "usageOperationId": usageId,
            },
        )
        assert lookup.json()["status"] == "notFound"
        assert lookup.json()["usageOperationId"] is None
        assert lookup.json()["nextAction"] == "queryLater"
    invalid = sendAsgiRequest(
        app,
        "POST",
        "/v1/resume-ai/operations/lookup",
        headers={"Authorization": f"Bearer {otherToken}"},
        jsonBody={
            "protocolVersion": "0.4.0",
            "capability": "basicResumeCompose",
            "idempotencyKey": "illegal/key",
        },
    )
    assert invalid.status_code == 400
    assert provider.generateCallCount == 1
