from __future__ import annotations

from agent_gateway.app import createApplication
from agent_gateway.settings import GatewaySettings
from tests.support import (
    TEST_BEARER_TOKEN,
    RecordingProvider,
    authorizedHeaders,
    sendAsgiRequest,
    validRequestBody,
)


def test_健康检查不执行_provider_且缺少配置时安全失败() -> None:
    provider = RecordingProvider()
    application = createApplication(settings=GatewaySettings(), provider=provider)

    liveResponse = sendAsgiRequest(application, "GET", "/health/live")
    readyResponse = sendAsgiRequest(application, "GET", "/health/ready")

    assert liveResponse.status_code == 200
    assert liveResponse.json() == {"status": "alive"}
    assert readyResponse.status_code == 503
    assert readyResponse.json() == {"status": "not_ready"}
    assert provider.generateCallCount == 0


def test_配置开发期_token_且_provider_可用时进入就绪状态() -> None:
    application = createApplication(
        settings=GatewaySettings(testBearerToken=TEST_BEARER_TOKEN),
        provider=RecordingProvider(),
    )

    readyResponse = sendAsgiRequest(application, "GET", "/health/ready")

    assert readyResponse.status_code == 200
    assert readyResponse.json() == {"status": "ready"}


def test_合法合成请求返回固定_mock_响应且不回显输入() -> None:
    privateInputMarker = "SYNTHETIC_INPUT_MUST_NOT_BE_ECHOED"
    requestBody = validRequestBody() | {"syntheticInput": privateInputMarker}
    application = createApplication(
        settings=GatewaySettings(testBearerToken=TEST_BEARER_TOKEN),
    )

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/agent/requests",
        headers=authorizedHeaders(),
        jsonBody=requestBody,
    )

    responseBody = gatewayResponse.json()
    assert gatewayResponse.status_code == 200
    assert gatewayResponse.headers["x-operation-id"] == responseBody["operationId"]
    assert responseBody == {
        "protocolVersion": "0.1.0",
        "operationId": responseBody["operationId"],
        "clientRequestId": "client-request-001",
        "status": "succeeded",
        "agentResponse": {
            "summary": "Mock Provider 已完成契约探测",
            "proposedPatch": None,
            "citations": [],
            "warnings": ["仅使用合成输入，未调用远程 Provider"],
            "nextAction": "none",
        },
        "execution": {"providerMode": "mock", "usesNetwork": False},
    }
    assert privateInputMarker not in gatewayResponse.text


def test_缺少和错误_token_返回相同鉴权语义() -> None:
    application = createApplication(
        settings=GatewaySettings(testBearerToken=TEST_BEARER_TOKEN),
    )

    missingTokenResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/agent/requests",
        jsonBody=validRequestBody(),
    )
    wrongTokenResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/agent/requests",
        headers={"Authorization": "Bearer wrong-token-value"},
        jsonBody=validRequestBody(),
    )

    for gatewayResponse in (missingTokenResponse, wrongTokenResponse):
        responseError = gatewayResponse.json()["error"]
        assert gatewayResponse.status_code == 401
        assert responseError["code"] == "unauthenticated"
        assert responseError["message"] == "请求身份无效"
        assert responseError["retryable"] is False
        assert gatewayResponse.headers["x-operation-id"] == responseError["operationId"]
