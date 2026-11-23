from __future__ import annotations

import logging
from pathlib import Path

import pytest
from fastapi import FastAPI

from agent_gateway.app import createApplication
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.settings import GatewaySettings
from agent_gateway.usage import UsagePolicyService
from tests.support import sendAsgiRequest

SYNTHETIC_PHONE = "+15550001234"
VALID_PASSWORD = "TestPass2026!"


def buildTask018Application(temporaryDirectory: Path) -> FastAPI:
    database = GatewayDatabase(temporaryDirectory / "gateway.db")
    database.initialize()
    return createApplication(
        settings=GatewaySettings(),
        accountService=AccountService(database, FakePhoneOwnershipVerifier()),
        usagePolicy=UsagePolicyService(database),
    )


def registrationBody() -> dict[str, str]:
    return {
        "protocolVersion": "0.2.0",
        "phoneE164": SYNTHETIC_PHONE,
        "password": VALID_PASSWORD,
        "verificationProof": FakePhoneOwnershipVerifier.developmentProof,
    }


def test_注册登录后可读取免费基础生成剩余额度(tmp_path: Path) -> None:
    application = buildTask018Application(tmp_path)

    registrationResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/accounts",
        jsonBody=registrationBody(),
    )
    sessionResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/account-sessions",
        jsonBody={
            "protocolVersion": "0.2.0",
            "phoneE164": SYNTHETIC_PHONE,
            "password": VALID_PASSWORD,
        },
    )
    sessionToken = sessionResponse.json()["sessionToken"]
    accessResponse = sendAsgiRequest(
        application,
        "GET",
        "/v1/account/access/basicResumeCompose",
        headers={"Authorization": f"Bearer {sessionToken}"},
    )

    assert registrationResponse.status_code == 201
    assert registrationResponse.json()["accountId"].startswith("account-")
    assert sessionResponse.status_code == 200
    assert accessResponse.status_code == 200
    assert accessResponse.json() == {
        "protocolVersion": "0.2.0",
        "capability": "basicResumeCompose",
        "plan": "free",
        "allowed": True,
        "reason": "allowed",
        "remainingMonthlyBasicGenerations": 9,
    }


def test_错误登录与无效会话使用同一认证错误(tmp_path: Path) -> None:
    application = buildTask018Application(tmp_path)
    sendAsgiRequest(application, "POST", "/v1/accounts", jsonBody=registrationBody())

    wrongPasswordResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/account-sessions",
        jsonBody={
            "protocolVersion": "0.2.0",
            "phoneE164": SYNTHETIC_PHONE,
            "password": "WrongPass2026!",
        },
    )
    invalidSessionResponse = sendAsgiRequest(
        application,
        "GET",
        "/v1/account/access/basicResumeCompose",
        headers={"Authorization": "Bearer invalid-session-token"},
    )

    for authenticationResponse in (wrongPasswordResponse, invalidSessionResponse):
        assert authenticationResponse.status_code == 401
        responseError = authenticationResponse.json()["error"]
        assert responseError["code"] == "unauthenticated"
        assert responseError["message"] == "请求身份无效"


def test_未显式启用_fake_身份时账号接口安全失败() -> None:
    application = createApplication(settings=GatewaySettings())

    gatewayResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/accounts",
        jsonBody=registrationBody(),
    )

    assert gatewayResponse.status_code == 503
    assert gatewayResponse.json()["error"]["code"] == "account_service_unavailable"


def test_账号日志不包含手机号_密码_证明或会话令牌(
    tmp_path: Path,
    caplog: pytest.LogCaptureFixture,
) -> None:
    database = GatewayDatabase(tmp_path / "gateway.db")
    database.initialize()
    auditLogger = logging.getLogger("agent_gateway.tests.task018_privacy")
    caplog.set_level(logging.INFO, logger=auditLogger.name)
    application = createApplication(
        settings=GatewaySettings(),
        accountService=AccountService(database, FakePhoneOwnershipVerifier()),
        usagePolicy=UsagePolicyService(database),
        auditLogger=auditLogger,
    )

    sendAsgiRequest(application, "POST", "/v1/accounts", jsonBody=registrationBody())
    sessionResponse = sendAsgiRequest(
        application,
        "POST",
        "/v1/account-sessions",
        jsonBody={
            "protocolVersion": "0.2.0",
            "phoneE164": SYNTHETIC_PHONE,
            "password": VALID_PASSWORD,
        },
    )
    sessionToken = sessionResponse.json()["sessionToken"]
    sendAsgiRequest(
        application,
        "GET",
        "/v1/account/access/basicResumeCompose",
        headers={"Authorization": f"Bearer {sessionToken}"},
    )

    combinedLogs = "\n".join(caplog.messages)
    assert "/v1/account/access/{capability}" in combinedLogs
    for privateMarker in (
        SYNTHETIC_PHONE,
        VALID_PASSWORD,
        FakePhoneOwnershipVerifier.developmentProof,
        sessionToken,
        "basicResumeCompose",
    ):
        assert privateMarker not in combinedLogs
