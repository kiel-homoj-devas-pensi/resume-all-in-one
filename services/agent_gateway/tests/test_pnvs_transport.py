from __future__ import annotations

import hashlib
import json
from typing import Any

import pytest
from darabonba.core import DaraCore
from darabonba.exceptions import RetryError
from darabonba.response import DaraResponse

from agent_gateway.account_lifecycle import (
    SmsSendOutcomeUnknownError,
    SmsSendRejectedError,
)
from agent_gateway.pnvs_transport import PNVS_ENDPOINT, PnvsCredentials, PnvsSmsTransport

PHONE = "+8613800000000"
CODE = "019234"
CHALLENGE = "challenge-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"


def credentials() -> PnvsCredentials:
    return PnvsCredentials(
        "synthetic-access-key-id", "synthetic-access-key-secret", "恒创联众", "100001"
    )


class SdkHttpBoundary:
    """替换最后的 HTTP 动作，仍执行真实 SDK 参数转换、签名与重试循环。"""

    def __init__(self) -> None:
        self.calls: list[tuple[Any, dict[str, Any]]] = []
        self.failure: Exception | None = None
        self.status = 200
        self.body: object = {
            "Code": "OK",
            "Success": True,
            "RequestId": "synthetic-request-id",
            "Model": {"BizId": "synthetic-biz-id", "OutId": CHALLENGE},
        }

    def send(self, request: Any, runtime: dict[str, Any]) -> DaraResponse:
        self.calls.append((request, runtime))
        if self.failure is not None:
            raise self.failure
        response = DaraResponse()
        response.status_code = self.status
        response.headers = {"content-type": "application/json"}
        response.body = json.dumps(self.body).encode("utf-8")
        return response


@pytest.fixture
def wire(monkeypatch: pytest.MonkeyPatch) -> SdkHttpBoundary:
    monkeypatch.delenv("DEBUG", raising=False)
    boundary = SdkHttpBoundary()
    monkeypatch.setattr(DaraCore, "do_action", boundary.send)
    return boundary


def test_official_sdk_sends_local_code_once_with_fixed_endpoint_and_no_retries(
    wire: SdkHttpBoundary,
) -> None:
    acceptance = PnvsSmsTransport(credentials()).sendVerification(
        PHONE, CODE, "register", challengeId=CHALLENGE
    )
    assert len(wire.calls) == 1
    request, runtime = wire.calls[0]
    assert request.protocol == "HTTPS"
    assert request.method == "POST"
    assert request.headers["host"] == PNVS_ENDPOINT
    assert request.headers["x-acs-action"] == "SendSmsVerifyCode"
    assert request.headers["x-acs-version"] == "2017-05-25"
    assert request.query["CountryCode"] == "86"
    assert request.query["PhoneNumber"] == PHONE[3:]
    assert request.query["SignName"] == "恒创联众"
    assert request.query["TemplateCode"] == "100001"
    assert json.loads(request.query["TemplateParam"]) == {"code": CODE, "min": "5"}
    assert request.query["OutId"] == CHALLENGE
    assert request.query["ReturnVerifyCode"] == "False"
    assert request.query["AutoRetry"] == "0"
    assert request.query["ValidTime"] == "300"
    assert request.query["CodeLength"] == "6"
    assert request.query["DuplicatePolicy"] == "1"
    assert request.query["SchemeName"] == "resume-register"
    assert runtime["ignoreSSL"] is False
    assert runtime["tlsMinVersion"] == "TLSv1.2"
    assert runtime["connectTimeout"] == runtime["readTimeout"] == 5_000
    assert runtime["retryOptions"].retryable is False
    assert runtime["retryOptions"].max_attempts == 1
    assert acceptance.requestIdDigest == hashlib.sha256(b"synthetic-request-id").hexdigest()
    assert acceptance.bizIdDigest == hashlib.sha256(b"synthetic-biz-id").hexdigest()
    assert CODE not in repr(acceptance)
    assert PHONE not in repr(acceptance)


def test_password_reset_uses_reset_template_and_separate_scheme(wire: SdkHttpBoundary) -> None:
    PnvsSmsTransport(credentials()).sendVerification(
        PHONE, CODE, "resetPassword", challengeId=CHALLENGE
    )
    assert wire.calls[0][0].query["SchemeName"] == "resume-reset"
    assert wire.calls[0][0].query["TemplateCode"] == "100003"


@pytest.mark.parametrize(
    "errorCode", ["FREQUENCY_FAIL", "BUSINESS_LIMIT_CONTROL", "isv.AMOUNT_NOT_ENOUGH"]
)
def test_http_success_with_explicit_business_failure_is_rejected_once(
    wire: SdkHttpBoundary, errorCode: str
) -> None:
    wire.body = {"Success": False, "Code": errorCode, "Message": f"private {PHONE} {CODE}"}
    with pytest.raises(SmsSendRejectedError) as error:
        PnvsSmsTransport(credentials()).sendVerification(
            PHONE, CODE, "register", challengeId=CHALLENGE
        )
    assert len(wire.calls) == 1
    assert str(error.value) == "sms_send_rejected"
    assert error.value.__cause__ is None


@pytest.mark.parametrize("status", [400, 429, 500, 503])
def test_http_error_is_conservatively_unknown_and_never_retried(
    wire: SdkHttpBoundary, status: int
) -> None:
    wire.status = status
    wire.body = {"Code": "ServiceUnavailable", "Message": f"private {PHONE} {CODE}"}
    with pytest.raises(SmsSendOutcomeUnknownError) as error:
        PnvsSmsTransport(credentials()).sendVerification(
            PHONE, CODE, "register", challengeId=CHALLENGE
        )
    assert len(wire.calls) == 1
    assert str(error.value) == "sms_send_outcome_unknown"
    assert error.value.__suppress_context__


def test_network_timeout_keeps_unknown_result_without_second_http_attempt(
    wire: SdkHttpBoundary, capsys: pytest.CaptureFixture[str]
) -> None:
    wire.failure = RetryError(f"private {PHONE} {CODE} synthetic-access-key-secret")
    with pytest.raises(SmsSendOutcomeUnknownError) as error:
        PnvsSmsTransport(credentials()).sendVerification(
            PHONE, CODE, "register", challengeId=CHALLENGE
        )
    assert len(wire.calls) == 1
    assert error.value.__cause__ is None
    assert error.value.__suppress_context__
    captured = capsys.readouterr()
    assert captured.out == captured.err == ""


@pytest.mark.parametrize(
    "body",
    [
        {},
        None,
        [],
        {"Code": "OK"},
        {"Success": True, "Code": "different"},
        {"Success": True, "Code": "OK", "Model": {"OutId": "other-challenge"}},
    ],
)
def test_incomplete_or_conflicting_response_is_not_treated_as_acceptance(
    wire: SdkHttpBoundary, body: object
) -> None:
    wire.body = body
    with pytest.raises(SmsSendOutcomeUnknownError):
        PnvsSmsTransport(credentials()).sendVerification(
            PHONE, CODE, "register", challengeId=CHALLENGE
        )
    assert len(wire.calls) == 1


@pytest.mark.parametrize("phone", ["+15550000001", "+8612000000000", "+861380000000０"])
def test_unsupported_phone_is_rejected_before_supplier_request(
    wire: SdkHttpBoundary, phone: str
) -> None:
    with pytest.raises(ValueError, match="invalid_pnvs_request"):
        PnvsSmsTransport(credentials()).sendVerification(
            phone, CODE, "register", challengeId=CHALLENGE
        )
    assert wire.calls == []


@pytest.mark.parametrize("code", ["12345", "12 456", "１２３４５６"])
def test_invalid_code_is_rejected_before_supplier_request(wire: SdkHttpBoundary, code: str) -> None:
    with pytest.raises(ValueError, match="invalid_pnvs_request"):
        PnvsSmsTransport(credentials()).sendVerification(
            PHONE, code, "register", challengeId=CHALLENGE
        )
    assert wire.calls == []


@pytest.mark.parametrize(
    "challenge", [PHONE, "other", "challenge-aaaaaaaa-aaaa-1aaa-8aaa-aaaaaaaaaaaa"]
)
def test_out_id_cannot_contain_personal_data(wire: SdkHttpBoundary, challenge: str) -> None:
    with pytest.raises(ValueError, match="invalid_pnvs_challenge"):
        PnvsSmsTransport(credentials()).sendVerification(
            PHONE, CODE, "register", challengeId=challenge
        )
    assert wire.calls == []


def test_sensitive_sdk_debug_is_refused_at_start_and_before_each_send(
    wire: SdkHttpBoundary, monkeypatch: pytest.MonkeyPatch
) -> None:
    transport = PnvsSmsTransport(credentials())
    monkeypatch.setenv("DEBUG", "SdK")
    with pytest.raises(ValueError, match="pnvs_sdk_debug_forbidden"):
        PnvsSmsTransport(credentials())
    with pytest.raises(ValueError, match="pnvs_sdk_debug_forbidden"):
        transport.sendVerification(PHONE, CODE, "register", challengeId=CHALLENGE)
    assert wire.calls == []


def test_credentials_repr_and_invalid_configuration_do_not_disclose_secret() -> None:
    assert "synthetic-access" not in repr(credentials())
    with pytest.raises(ValueError, match="invalid_pnvs_credentials"):
        PnvsCredentials("short", "private\nsecret", "恒创联众", "100001")
    with pytest.raises(ValueError, match="unsupported_pnvs_template"):
        PnvsCredentials("synthetic-access-key-id", "synthetic-access-key-secret", "other", "100001")
