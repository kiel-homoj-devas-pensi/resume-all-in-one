from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from fastapi import FastAPI

from agent_gateway.app import createApplication
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.prompt_registry import ReasoningProfile
from agent_gateway.remote_contracts import RemoteResumeAiRequest
from agent_gateway.remote_provider import (
    FakeRemoteResumeProvider,
    InvalidRemoteProviderResponseError,
    RemoteProviderGeneration,
    RemoteProviderOutcomeUnknownError,
    RemoteProviderRateLimitedError,
    RemoteProviderUnavailableError,
    RemoteResumeProvider,
)
from agent_gateway.settings import GatewaySettings
from agent_gateway.usage import SubscriptionService, UsagePolicyService
from tests.support import sendAsgiRequest

VALID_PASSWORD = "TestPass2026!"
SYNTHETIC_PHONE = "+15550001234"


class RecordingRemoteProvider:
    def __init__(self, *, usesNetwork: bool = False) -> None:
        self._usesNetwork = usesNetwork
        self.generateCallCount = 0
        self.reasoningProfiles: list[ReasoningProfile] = []
        self.requests: list[RemoteResumeAiRequest] = []
        self._fakeProvider = FakeRemoteResumeProvider()

    @property
    def isReady(self) -> bool:
        return True

    @property
    def usesNetwork(self) -> bool:
        return self._usesNetwork

    async def generate(
        self,
        request: RemoteResumeAiRequest,
        *,
        reasoningProfile: ReasoningProfile,
    ) -> RemoteProviderGeneration:
        self.generateCallCount += 1
        self.reasoningProfiles.append(reasoningProfile)
        self.requests.append(request)
        fakeGeneration = await self._fakeProvider.generate(
            request,
            reasoningProfile=reasoningProfile,
        )
        return RemoteProviderGeneration(
            output=fakeGeneration.output,
            promptVersion=fakeGeneration.promptVersion,
            inputTokens=17,
            outputTokens=29,
            usesNetwork=self._usesNetwork,
        )


class FailingRemoteProvider:
    def __init__(self, providerError: Exception) -> None:
        self._providerError = providerError

    @property
    def isReady(self) -> bool:
        return True

    @property
    def usesNetwork(self) -> bool:
        return True

    async def generate(
        self,
        request: RemoteResumeAiRequest,
        *,
        reasoningProfile: ReasoningProfile,
    ) -> RemoteProviderGeneration:
        del reasoningProfile, request
        raise self._providerError


class SlowRemoteProvider:
    @property
    def isReady(self) -> bool:
        return True

    @property
    def usesNetwork(self) -> bool:
        return True

    async def generate(
        self,
        request: RemoteResumeAiRequest,
        *,
        reasoningProfile: ReasoningProfile,
    ) -> RemoteProviderGeneration:
        del reasoningProfile, request
        await asyncio.sleep(60)
        raise AssertionError("deadline 应先终止 Provider")


def buildRemoteApplication(
    temporaryDirectory: Path,
    remoteProvider: RemoteResumeProvider,
    *,
    providerDeadlineSeconds: float = 1.0,
    auditLogger: logging.Logger | None = None,
) -> tuple[FastAPI, GatewayDatabase, str, str, SubscriptionService]:
    database = GatewayDatabase(temporaryDirectory / "gateway.db")
    database.initialize()
    accountService = AccountService(database, FakePhoneOwnershipVerifier())
    accountId = accountService.registerAccount(
        phoneE164=SYNTHETIC_PHONE,
        password=VALID_PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    accountSession = accountService.createSession(
        phoneE164=SYNTHETIC_PHONE,
        password=VALID_PASSWORD,
    )
    application = createApplication(
        settings=GatewaySettings(
            remoteProviderDeadlineSeconds=providerDeadlineSeconds,
        ),
        accountService=accountService,
        usagePolicy=UsagePolicyService(database),
        remoteResumeProvider=remoteProvider,
        auditLogger=auditLogger,
    )
    return (
        application,
        database,
        accountId,
        accountSession.sessionToken,
        SubscriptionService(database),
    )


def basicRequestBody(
    *,
    idempotencyKey: str = "basic-generation-001",
    fragmentText: str = "三年后端开发经验",
) -> dict[str, object]:
    return {
        "protocolVersion": "0.3.0",
        "clientRequestId": "client-basic-001",
        "idempotencyKey": idempotencyKey,
        "capability": "basicResumeCompose",
        "input": {
            "inputType": "basicResumeCompose",
            "sourceFragments": [
                {
                    "fragmentId": "fragment-work-1",
                    "category": "work",
                    "text": fragmentText,
                }
            ],
        },
    }


def targetedRequestBody() -> dict[str, object]:
    return {
        "protocolVersion": "0.3.0",
        "clientRequestId": "client-targeted-001",
        "idempotencyKey": "targeted-generation-001",
        "capability": "targetedResumeOptimization",
        "input": {
            "inputType": "targetedResumeOptimization",
            "baseResumeFingerprint": "a" * 64,
            "resume": {
                "schemaVersion": "0.1.0",
                "profile": {
                    "id": "profile-1",
                    "headline": "后端开发工程师",
                    "coarseLocation": "杭州",
                },
            },
            "targetJobTitle": "高级后端工程师",
            "jobDescription": "负责高并发接口设计",
        },
    }


def accountHeaders(sessionToken: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {sessionToken}"}


def readOnlyUsageRow(database: GatewayDatabase) -> dict[str, object]:
    with database.readConnection() as databaseConnection:
        operationRow = databaseConnection.execute(
            "SELECT * FROM usage_operations ORDER BY created_at_utc DESC LIMIT 1"
        ).fetchone()
    assert operationRow is not None
    return dict(operationRow)


def test_免费基础生成使用_fast_并提交脱敏用量(tmp_path: Path) -> None:
    remoteProvider = RecordingRemoteProvider(usesNetwork=False)
    application, database, _, sessionToken, _ = buildRemoteApplication(
        tmp_path,
        remoteProvider,
    )

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(sessionToken),
        jsonBody=basicRequestBody(),
    )

    assert gatewayResponse.status_code == 200
    assert gatewayResponse.json()["execution"] == {
        "usesNetwork": False,
        "promptVersion": "basic-resume-compose.v15",
    }
    assert remoteProvider.reasoningProfiles == [ReasoningProfile.fast]
    usageRow = readOnlyUsageRow(database)
    assert usageRow["status"] == "committed"
    assert usageRow["prompt_version"] == "basic-resume-compose.v15"
    assert usageRow["input_tokens"] == 17
    assert usageRow["output_tokens"] == 29
    assert "三年后端开发经验".encode() not in database.databasePath.read_bytes()


def test_普通与会员均可岗位优化并沿用各自推理配置(tmp_path: Path) -> None:
    freeProvider = RecordingRemoteProvider()
    freeApplication, _, _, freeSessionToken, _ = buildRemoteApplication(
        tmp_path / "free",
        freeProvider,
    )
    freeResponse = sendAsgiRequest(
        freeApplication,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(freeSessionToken),
        jsonBody=targetedRequestBody(),
    )

    proProvider = RecordingRemoteProvider()
    proApplication, _, accountId, proSessionToken, subscriptionService = buildRemoteApplication(
        tmp_path / "pro", proProvider
    )
    nowUtc = datetime.now(UTC)
    subscriptionService.setFakeProSubscription(
        accountId=accountId,
        startsAtUtc=nowUtc - timedelta(days=1),
        endsAtUtc=nowUtc + timedelta(days=29),
    )
    proResponse = sendAsgiRequest(
        proApplication,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(proSessionToken),
        jsonBody=targetedRequestBody(),
    )

    assert freeResponse.status_code == 200
    assert freeProvider.reasoningProfiles == [ReasoningProfile.fast]
    assert freeProvider.generateCallCount == 1
    assert proResponse.status_code == 200
    assert proProvider.reasoningProfiles == [ReasoningProfile.deep]


def test_成功请求重放与同键异内容均不再次调用_provider(tmp_path: Path) -> None:
    remoteProvider = RecordingRemoteProvider()
    application, _, _, sessionToken, _ = buildRemoteApplication(tmp_path, remoteProvider)

    firstResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(sessionToken),
        jsonBody=basicRequestBody(),
    )
    replayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(sessionToken),
        jsonBody=basicRequestBody(),
    )
    conflictResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(sessionToken),
        jsonBody=basicRequestBody(fragmentText="不同的业务输入"),
    )

    assert firstResponse.status_code == 200
    assert replayResponse.status_code == 409
    assert replayResponse.json()["error"]["code"] == "operation_already_completed"
    assert conflictResponse.status_code == 409
    assert conflictResponse.json()["error"]["code"] == "idempotency_conflict"
    assert remoteProvider.generateCallCount == 1


@pytest.mark.parametrize(
    ("providerError", "expectedStatus", "expectedCode", "expectedUsageStatus"),
    [
        (
            RemoteProviderRateLimitedError(7),
            429,
            "rate_limited",
            "released",
        ),
        (
            RemoteProviderUnavailableError(),
            503,
            "provider_unavailable",
            "released",
        ),
        (
            InvalidRemoteProviderResponseError(),
            502,
            "invalid_provider_response",
            "pendingReconciliation",
        ),
        (
            RemoteProviderOutcomeUnknownError(),
            503,
            "provider_unavailable",
            "pendingReconciliation",
        ),
    ],
)
def test_provider_失败按结果确定性迁移用量状态(
    tmp_path: Path,
    providerError: Exception,
    expectedStatus: int,
    expectedCode: str,
    expectedUsageStatus: str,
) -> None:
    application, database, _, sessionToken, _ = buildRemoteApplication(
        tmp_path,
        FailingRemoteProvider(providerError),
    )

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(sessionToken),
        jsonBody=basicRequestBody(),
    )

    assert gatewayResponse.status_code == expectedStatus
    assert gatewayResponse.json()["error"]["code"] == expectedCode
    assert readOnlyUsageRow(database)["status"] == expectedUsageStatus
    if isinstance(providerError, RemoteProviderRateLimitedError):
        assert gatewayResponse.headers["Retry-After"] == "7"


def test_进程级_deadline_进入待对账且不允许同键自动重试(tmp_path: Path) -> None:
    application, database, _, sessionToken, _ = buildRemoteApplication(
        tmp_path,
        SlowRemoteProvider(),
        providerDeadlineSeconds=0.01,
    )

    timeoutResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(sessionToken),
        jsonBody=basicRequestBody(),
    )
    replayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(sessionToken),
        jsonBody=basicRequestBody(),
    )

    assert timeoutResponse.status_code == 504
    assert timeoutResponse.json()["error"]["code"] == "provider_timeout"
    assert readOnlyUsageRow(database)["status"] == "pendingReconciliation"
    assert replayResponse.status_code == 409
    assert replayResponse.json()["error"]["code"] == "operation_pending_reconciliation"


def test_远程请求日志不包含简历_身份字段或会话令牌(
    tmp_path: Path,
    caplog: pytest.LogCaptureFixture,
) -> None:
    auditLogger = logging.getLogger("agent_gateway.tests.task019_privacy")
    caplog.set_level(logging.INFO, logger=auditLogger.name)
    privateResumeText = "仅用于日志泄露测试的后端履历"
    remoteProvider = RecordingRemoteProvider(usesNetwork=True)
    application, _, _, sessionToken, _ = buildRemoteApplication(
        tmp_path,
        remoteProvider,
        auditLogger=auditLogger,
    )
    requestBody = basicRequestBody(fragmentText=privateResumeText)
    requestInput = requestBody["input"]
    assert isinstance(requestInput, dict)
    requestInput["personalData"] = {
        "consentedFields": ["fullName"],
        "fullName": "隐私测试姓名",
    }

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(sessionToken),
        jsonBody=requestBody,
    )

    combinedLogs = "\n".join(caplog.messages)
    assert gatewayResponse.status_code == 200
    assert "capability=basicResumeCompose" in combinedLogs
    assert "usesNetwork=true" in combinedLogs
    for privateMarker in (
        privateResumeText,
        "隐私测试姓名",
        sessionToken,
        "basic-generation-001",
        "fragment-work-1",
    ):
        assert privateMarker not in combinedLogs


def test_请求校验失败不会占用免费额度(tmp_path: Path) -> None:
    remoteProvider = RecordingRemoteProvider()
    application, database, _, sessionToken, _ = buildRemoteApplication(
        tmp_path,
        remoteProvider,
    )
    invalidRequestBody = basicRequestBody()
    invalidRequestBody["unexpected"] = "不得接受"

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(sessionToken),
        jsonBody=invalidRequestBody,
    )

    with database.readConnection() as databaseConnection:
        operationCount = databaseConnection.execute(
            "SELECT COUNT(*) FROM usage_operations"
        ).fetchone()[0]
    assert gatewayResponse.status_code == 400
    assert operationCount == 0
    assert remoteProvider.generateCallCount == 0
