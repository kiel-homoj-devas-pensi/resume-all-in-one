from __future__ import annotations

import re

from .account_lifecycle import (
    SmsSendOutcomeUnknownError,
    SmsSendRejectedError,
    VerificationPurpose,
)
from .pnvs_transport import PnvsSmsTransport
from .sms_budget import SmsBudgetLedger


class PnvsSmsSender:
    """将已批准的持久预算与一次 PNVS 请求连接，不持锁执行网络调用。"""

    developmentOnly = False

    def __init__(self, ledger: SmsBudgetLedger, transport: PnvsSmsTransport) -> None:
        ledger.assertApprovedPolicy()
        self._ledger = ledger
        self._transport = transport

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return self._ledger.authorityKey

    def sendCode(
        self, phoneE164: str, code: str, purpose: VerificationPurpose, *, challengeId: str
    ) -> None:
        if re.fullmatch(r"[0-9]{6}", code) is None:
            raise ValueError("invalid_pnvs_request")
        # reserve 正常返回才代表确认提交。拒绝、未知提交与同挑战重放
        # 都在网络请求之前退出，不自动创建政策或恢复额度。
        self._ledger.reserve(challengeId, phoneE164, purpose)
        try:
            acceptance = self._transport.sendVerification(
                phoneE164, code, purpose, challengeId=challengeId
            )
        except SmsSendRejectedError:
            try:
                self._ledger.finalize(challengeId, "rejected")
            except Exception:
                raise SmsSendOutcomeUnknownError() from None
            raise SmsSendRejectedError() from None
        except Exception:
            try:
                self._ledger.finalize(challengeId, "unknown")
            except Exception:
                # 保留 reserved 同样占用预算；不能为补写终态再发短信。
                raise SmsSendOutcomeUnknownError() from None
            raise SmsSendOutcomeUnknownError() from None
        try:
            self._ledger.finalize(
                challengeId,
                "accepted",
                requestIdDigest=acceptance.requestIdDigest,
                bizIdDigest=acceptance.bizIdDigest,
            )
        except Exception:
            # 供应商已受理但本地终态不可确认，不能向客户端确认成功，
            # 更不能重复网络调用。可能已提交的终态保留原样。
            raise SmsSendOutcomeUnknownError() from None
