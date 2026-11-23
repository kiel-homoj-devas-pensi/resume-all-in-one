from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass
from typing import Protocol, cast
from uuid import UUID

from alibabacloud_dypnsapi20170525.client import Client
from alibabacloud_dypnsapi20170525.models import (
    SendSmsVerifyCodeRequest,
    SendSmsVerifyCodeResponse,
)
from alibabacloud_tea_openapi.models import Config
from alibabacloud_tea_util.models import RuntimeOptions
from darabonba.policy.retry import RetryOptions

from .account_lifecycle import (
    SmsSendOutcomeUnknownError,
    SmsSendRejectedError,
    VerificationPurpose,
)

PNVS_ENDPOINT = "dypnsapi.aliyuncs.com"
# 平台赠送模板按业务用途选择；100001 是登录/注册，100003 是重置密码。
PNVS_RESET_TEMPLATE_CODE = "100003"


@dataclass(frozen=True, slots=True, repr=False)
class PnvsCredentials:
    accessKeyId: str
    accessKeySecret: str
    signName: str
    templateCode: str

    def __post_init__(self) -> None:
        for value in (self.accessKeyId, self.accessKeySecret):
            if (
                not isinstance(value, str)
                or not 16 <= len(value) <= 256
                or any(char.isspace() for char in value)
            ):
                raise ValueError("invalid_pnvs_credentials")
            if any(ord(char) < 32 or ord(char) == 127 for char in value):
                raise ValueError("invalid_pnvs_credentials")
        if self.signName != "恒创联众" or self.templateCode != "100001":
            # 本轮只实现负责人已确认的签名与模板，不猜测其他模板变量。
            raise ValueError("unsupported_pnvs_template")


@dataclass(frozen=True, slots=True)
class SmsAcceptance:
    requestIdDigest: str | None
    bizIdDigest: str | None


class _PnvsClient(Protocol):
    def send_sms_verify_code_with_options(
        self, request: SendSmsVerifyCodeRequest, runtime: RuntimeOptions
    ) -> SendSmsVerifyCodeResponse: ...


def _identifierDigest(value: object) -> str | None:
    if not isinstance(value, str) or not value or len(value) > 256:
        return None
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class PnvsSmsTransport:
    """一次受理请求的供应商边界；应用启用前还须接入持久预算和号码白名单。"""

    def __init__(self, credentials: PnvsCredentials) -> None:
        self._assertDebugDisabled()
        config = Config(
            access_key_id=credentials.accessKeyId,
            access_key_secret=credentials.accessKeySecret,
            type="access_key",
            endpoint=PNVS_ENDPOINT,
            protocol="HTTPS",
            connect_timeout=5_000,
            read_timeout=5_000,
            tls_min_version="TLSv1.2",
            # 新版 OpenAPI 的循环不读取旧 RuntimeOptions.autoretry。
            retry_options=RetryOptions(retryable=False, max_attempts=1),
        )
        self._client = cast(_PnvsClient, Client(config))
        self._signName = credentials.signName
        self._templateCode = credentials.templateCode

    @staticmethod
    def _assertDebugDisabled() -> None:
        # 官方底层在 DEBUG=sdk 时打印请求；不能靠捕获异常保护这些输出。
        if os.environ.get("DEBUG", "").lower() == "sdk":
            raise ValueError("pnvs_sdk_debug_forbidden")

    def sendVerification(
        self, phoneE164: str, code: str, purpose: VerificationPurpose, *, challengeId: str
    ) -> SmsAcceptance:
        self._assertDebugDisabled()
        if (
            re.fullmatch(r"\+861[3-9][0-9]{9}", phoneE164) is None
            or re.fullmatch(r"[0-9]{6}", code) is None
            or purpose not in {"register", "resetPassword"}
        ):
            raise ValueError("invalid_pnvs_request")
        try:
            challengeUuid = UUID(challengeId.removeprefix("challenge-"))
        except ValueError:
            raise ValueError("invalid_pnvs_challenge") from None
        if challengeId != f"challenge-{challengeUuid}" or challengeUuid.version != 4:
            raise ValueError("invalid_pnvs_challenge")
        request = SendSmsVerifyCodeRequest(
            country_code="86",
            phone_number=phoneE164[3:],
            sign_name=self._signName,
            template_code=(
                self._templateCode if purpose == "register" else PNVS_RESET_TEMPLATE_CODE
            ),
            template_param=json.dumps({"code": code, "min": "5"}, separators=(",", ":")),
            out_id=challengeId,
            scheme_name="resume-register" if purpose == "register" else "resume-reset",
            code_length=6,
            valid_time=300,
            duplicate_policy=1,
            interval=60,
            return_verify_code=False,
            auto_retry=0,
        )
        runtime = RuntimeOptions(
            autoretry=False,
            max_attempts=1,
            ignore_ssl=False,
            connect_timeout=5_000,
            read_timeout=5_000,
        )
        try:
            response = self._client.send_sms_verify_code_with_options(request, runtime)
        except Exception:
            # 超时、服务异常及 SDK 解析失败均可能发生在受理后，绝不自动重发。
            # SDK 异常可能包含手机号、验证码或签名材料，不传播原异常。
            raise SmsSendOutcomeUnknownError from None
        body = response.body
        if body is None:
            raise SmsSendOutcomeUnknownError
        if body.success is False:
            raise SmsSendRejectedError
        if response.status_code != 200 or body.success is not True or body.code != "OK":
            raise SmsSendOutcomeUnknownError
        model = body.model
        if model is not None and model.out_id not in (None, challengeId):
            raise SmsSendOutcomeUnknownError
        # 受理不代表送达；不返回 Message、号码、验证码或供应商原始标识。
        return SmsAcceptance(
            _identifierDigest(body.request_id),
            _identifierDigest(model.biz_id) if model is not None else None,
        )
