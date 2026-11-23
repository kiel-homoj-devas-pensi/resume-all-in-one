from __future__ import annotations

import asyncio
import json
from typing import cast

import pytest
from starlette.types import Message, Scope

from agent_gateway.app import createApplication
from agent_gateway.settings import GatewaySettings
from tests.support import (
    TEST_BEARER_TOKEN,
    authorizedHeaders,
    sendAsgiRequest,
    validRequestBody,
)


@pytest.mark.parametrize(
    ("changedFields", "expectedIssueCode"),
    [
        ({"protocolVersion": "9.9.9"}, "literal_error"),
        ({"capability": "writeResume"}, "literal_error"),
        ({"clientRequestId": "含中文"}, "string_pattern_mismatch"),
        ({"syntheticInput": " "}, "string_too_short"),
        ({"syntheticInput": "测" * 513}, "string_too_long"),
        ({"unexpectedField": "rejected"}, "extra_forbidden"),
    ],
)
def test_非法协议字段返回稳定校验分类(
    changedFields: dict[str, str],
    expectedIssueCode: str,
) -> None:
    application = createApplication(
        settings=GatewaySettings(testBearerToken=TEST_BEARER_TOKEN),
    )
    requestBody = validRequestBody() | changedFields

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/agent/requests",
        headers=authorizedHeaders(),
        jsonBody=requestBody,
    )

    responseError = gatewayResponse.json()["error"]
    assert gatewayResponse.status_code == 400
    assert responseError["code"] == "invalid_request"
    assert expectedIssueCode in {issue["code"] for issue in responseError["issues"]}
    assert all("input" not in issue for issue in responseError["issues"])


def test_非法_json_不回传解析器原文() -> None:
    application = createApplication(
        settings=GatewaySettings(testBearerToken=TEST_BEARER_TOKEN),
    )
    invalidJsonMarker = "INVALID_JSON_PRIVATE_MARKER"

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/agent/requests",
        headers={**authorizedHeaders(), "Content-Type": "application/json"},
        content=f'{{"syntheticInput":"{invalidJsonMarker}"',
    )

    assert gatewayResponse.status_code == 400
    assert gatewayResponse.json()["error"]["code"] == "invalid_request"
    assert invalidJsonMarker not in gatewayResponse.text


def test_非_json_content_type_在解析前拒绝() -> None:
    application = createApplication(
        settings=GatewaySettings(testBearerToken=TEST_BEARER_TOKEN),
    )

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/agent/requests",
        headers={**authorizedHeaders(), "Content-Type": "text/plain"},
        content="synthetic",
    )

    assert gatewayResponse.status_code == 415
    assert gatewayResponse.json()["error"]["code"] == "invalid_request"


def test_声明长度超过上限时不读取请求体() -> None:
    application = createApplication(
        settings=GatewaySettings(
            testBearerToken=TEST_BEARER_TOKEN,
            maxRequestBodyBytes=32,
        ),
    )

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/agent/requests",
        headers={
            **authorizedHeaders(),
            "Content-Type": "application/json",
            "Content-Length": "100",
        },
        content=b"{}",
    )

    assert gatewayResponse.status_code == 413
    assert gatewayResponse.json()["error"]["code"] == "invalid_request"


def test_实际接收字节超过伪造声明长度时仍被拒绝() -> None:
    oversizedBody = json.dumps(validRequestBody() | {"padding": "x" * 128}).encode()
    application = createApplication(
        settings=GatewaySettings(
            testBearerToken=TEST_BEARER_TOKEN,
            maxRequestBodyBytes=64,
        ),
    )

    sentMessages: list[Message] = []
    bodyDelivered = False

    async def receiveRequest() -> Message:
        nonlocal bodyDelivered
        if bodyDelivered:
            return {"type": "http.disconnect"}
        bodyDelivered = True
        return {"type": "http.request", "body": oversizedBody, "more_body": False}

    async def captureResponse(message: Message) -> None:
        sentMessages.append(message)

    requestScope = cast(
        Scope,
        {
            "type": "http",
            "asgi": {"version": "3.0"},
            "http_version": "1.1",
            "method": "POST",
            "scheme": "http",
            "path": "/v1/agent/requests",
            "raw_path": b"/v1/agent/requests",
            "query_string": b"",
            "root_path": "",
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", b"1"),
                (b"authorization", f"Bearer {TEST_BEARER_TOKEN}".encode()),
            ],
            "client": ("127.0.0.1", 50000),
            "server": ("gateway.test", 80),
        },
    )

    asyncio.run(application(requestScope, receiveRequest, captureResponse))

    responseStart = next(
        message for message in sentMessages if message["type"] == "http.response.start"
    )
    responseBody = next(
        message for message in sentMessages if message["type"] == "http.response.body"
    )
    assert responseStart["status"] == 413
    assert json.loads(responseBody["body"])["error"]["code"] == "invalid_request"
