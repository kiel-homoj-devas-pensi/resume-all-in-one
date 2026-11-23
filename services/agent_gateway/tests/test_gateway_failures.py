from __future__ import annotations

import asyncio
import logging

import httpx

from agent_gateway.app import createApplication
from agent_gateway.settings import GatewaySettings
from tests.support import (
    TEST_BEARER_TOKEN,
    BlockingProvider,
    InvalidResponseProvider,
    SlowProvider,
    UnavailableProvider,
    UnexpectedFailureProvider,
    authorizedHeaders,
    sendAsgiRequest,
    validRequestBody,
)


def test_provider_已知故障映射为稳定错误() -> None:
    scenarios = (
        (UnavailableProvider(), 503, "provider_unavailable", True),
        (InvalidResponseProvider(), 502, "invalid_provider_response", False),
    )

    for provider, expectedStatus, expectedCode, expectedRetryable in scenarios:
        application = createApplication(
            settings=GatewaySettings(testBearerToken=TEST_BEARER_TOKEN),
            provider=provider,
        )
        gatewayResponse = sendAsgiRequest(
            application,
            "POST",
            "/v1/agent/requests",
            headers=authorizedHeaders(),
            jsonBody=validRequestBody(),
        )

        responseError = gatewayResponse.json()["error"]
        assert gatewayResponse.status_code == expectedStatus
        assert responseError["code"] == expectedCode
        assert responseError["retryable"] is expectedRetryable


def test_provider_超时只取消本次等待且不重试() -> None:
    application = createApplication(
        settings=GatewaySettings(
            testBearerToken=TEST_BEARER_TOKEN,
            providerTimeoutSeconds=0.01,
        ),
        provider=SlowProvider(),
    )

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/agent/requests",
        headers=authorizedHeaders(),
        jsonBody=validRequestBody(),
    )

    assert gatewayResponse.status_code == 504
    assert gatewayResponse.json()["error"]["code"] == "provider_timeout"


def test_未知异常被边界收敛且日志不含原始异常() -> None:
    failureMarker = "PRIVATE_EXCEPTION_MARKER"
    auditLogger = logging.getLogger("agent_gateway.tests.unknown_failure")
    application = createApplication(
        settings=GatewaySettings(testBearerToken=TEST_BEARER_TOKEN),
        provider=UnexpectedFailureProvider(failureMarker),
        auditLogger=auditLogger,
    )

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/agent/requests",
        headers=authorizedHeaders(),
        jsonBody=validRequestBody(),
        raiseAppExceptions=False,
    )

    assert gatewayResponse.status_code == 500
    assert gatewayResponse.json()["error"]["code"] == "internal_error"
    assert failureMarker not in gatewayResponse.text


def test_并发槽位耗尽后立即限流且完成后恢复() -> None:
    async def runConcurrentScenario() -> None:
        blockingProvider = BlockingProvider()
        application = createApplication(
            settings=GatewaySettings(
                testBearerToken=TEST_BEARER_TOKEN,
                maxConcurrentRequests=1,
            ),
            provider=blockingProvider,
        )
        transport = httpx.ASGITransport(app=application, raise_app_exceptions=False)
        async with httpx.AsyncClient(transport=transport, base_url="http://gateway.test") as client:
            firstRequest = asyncio.create_task(
                client.post(
                    "/v1/agent/requests",
                    headers=authorizedHeaders(),
                    json=validRequestBody(),
                )
            )
            await asyncio.wait_for(blockingProvider.requestStarted.wait(), timeout=1)

            limitedResponse = await client.post(
                "/v1/agent/requests",
                headers=authorizedHeaders(),
                json=validRequestBody() | {"clientRequestId": "client-request-002"},
            )
            assert limitedResponse.status_code == 429
            assert limitedResponse.headers["retry-after"] == "1"

            blockingProvider.allowCompletion.set()
            completedResponse = await firstRequest
            assert completedResponse.status_code == 200

            recoveredResponse = await client.post(
                "/v1/agent/requests",
                headers=authorizedHeaders(),
                json=validRequestBody() | {"clientRequestId": "client-request-003"},
            )
            assert recoveredResponse.status_code == 200

    asyncio.run(runConcurrentScenario())
