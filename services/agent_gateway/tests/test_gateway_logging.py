from __future__ import annotations

import logging

import pytest

from agent_gateway.app import createApplication
from agent_gateway.settings import GatewaySettings
from tests.support import (
    UnavailableProvider,
    UnexpectedFailureProvider,
    sendAsgiRequest,
    validRequestBody,
)


def test_审计日志只包含白名单元数据(caplog: pytest.LogCaptureFixture) -> None:
    privateInputMarker = "PRIVATE_BODY_MARKER"
    privateTokenMarker = "PRIVATE_TOKEN_MARKER_017"
    privateFailureMarker = "PRIVATE_FAILURE_MARKER_017"
    privatePathMarker = "PRIVATE_PATH_MARKER_017"
    auditLogger = logging.getLogger("agent_gateway.tests.audit_allowlist")
    caplog.set_level(logging.INFO, logger=auditLogger.name)

    commonSettings = GatewaySettings(testBearerToken=privateTokenMarker)
    successApplication = createApplication(
        settings=commonSettings,
        auditLogger=auditLogger,
    )
    validationApplication = createApplication(
        settings=commonSettings,
        auditLogger=auditLogger,
    )
    unavailableApplication = createApplication(
        settings=commonSettings,
        provider=UnavailableProvider(),
        auditLogger=auditLogger,
    )
    failureApplication = createApplication(
        settings=commonSettings,
        provider=UnexpectedFailureProvider(privateFailureMarker),
        auditLogger=auditLogger,
    )

    requestHeaders = {"Authorization": f"Bearer {privateTokenMarker}"}
    successResponse = sendAsgiRequest(
        successApplication,
        "POST",
        "/v1/agent/requests",
        headers=requestHeaders,
        jsonBody=validRequestBody() | {"syntheticInput": privateInputMarker},
    )
    validationResponse = sendAsgiRequest(
        validationApplication,
        "POST",
        "/v1/agent/requests",
        headers=requestHeaders,
        jsonBody=validRequestBody()
        | {"syntheticInput": privateInputMarker, "privateExtra": privateInputMarker},
    )
    unavailableResponse = sendAsgiRequest(
        unavailableApplication,
        "POST",
        "/v1/agent/requests",
        headers=requestHeaders,
        jsonBody=validRequestBody() | {"syntheticInput": privateInputMarker},
    )
    failureResponse = sendAsgiRequest(
        failureApplication,
        "POST",
        "/v1/agent/requests",
        headers=requestHeaders,
        jsonBody=validRequestBody() | {"syntheticInput": privateInputMarker},
        raiseAppExceptions=False,
    )
    unmatchedRouteResponse = sendAsgiRequest(
        successApplication,
        "GET",
        f"/{privatePathMarker}",
    )

    assert [
        successResponse.status_code,
        validationResponse.status_code,
        unavailableResponse.status_code,
        failureResponse.status_code,
        unmatchedRouteResponse.status_code,
    ] == [200, 400, 503, 500, 404]
    combinedLogs = "\n".join(caplog.messages)
    assert combinedLogs.count("gateway_request") == 5
    assert "gateway_internal_error" in combinedLogs
    assert "gatewayContractProbe" in combinedLogs
    assert "route=unmatched" in combinedLogs
    assert privateInputMarker not in combinedLogs
    assert privateTokenMarker not in combinedLogs
    assert privateFailureMarker not in combinedLogs
    assert privatePathMarker not in combinedLogs
