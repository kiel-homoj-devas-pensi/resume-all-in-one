from __future__ import annotations

import base64
import hmac
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import cast

from .sms_budget import SmsBudgetPolicy
from .volunteer_trial import VolunteerTrialPolicy
from .windows_protected_configuration import loadProtectedPayload, parseProtectedObject

_FIELDS = {
    "schemaVersion",
    "otpSecretBase64",
    "auditSecretBase64",
    "allowedPhones",
    "maximumAttempts",
    "budgetCents",
    "reservePerAttemptCents",
    "expiresAtUtc",
}


class PnvsRuntimeLoadError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("pnvs_runtime_configuration_unavailable")


@dataclass(frozen=True, slots=True, repr=False)
class PnvsRuntimeSettings:
    otpSecret: bytes
    auditSecret: bytes
    policy: SmsBudgetPolicy

    def __post_init__(self) -> None:
        if (
            not isinstance(self.otpSecret, bytes)
            or not isinstance(self.auditSecret, bytes)
            or len(self.otpSecret) != 32
            or len(self.auditSecret) != 32
            or hmac.compare_digest(self.otpSecret, self.auditSecret)
            or not isinstance(self.policy, SmsBudgetPolicy)
        ):
            raise PnvsRuntimeLoadError()


def _secret(value: object) -> bytes:
    if not isinstance(value, str):
        raise PnvsRuntimeLoadError()
    secret = base64.b64decode(value, validate=True)
    if len(secret) != 32 or base64.b64encode(secret).decode("ascii") != value:
        raise PnvsRuntimeLoadError()
    return secret


def _runtimeSettings(payload: str) -> PnvsRuntimeSettings:
    bundle = parseProtectedObject(payload)
    if (
        set(bundle) != _FIELDS
        or type(bundle["schemaVersion"]) is not int
        or bundle["schemaVersion"] != 1
    ):
        raise PnvsRuntimeLoadError()
    phones = bundle["allowedPhones"]
    expiry = bundle["expiresAtUtc"]
    if (
        not isinstance(phones, list)
        or not 1 <= len(phones) <= 100
        or any(not isinstance(phone, str) for phone in phones)
        or len(set(phones)) != len(phones)
        or not isinstance(expiry, str)
        or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z", expiry)
        is None
    ):
        raise PnvsRuntimeLoadError()
    for name in ("maximumAttempts", "budgetCents", "reservePerAttemptCents"):
        if type(bundle[name]) is not int:
            raise PnvsRuntimeLoadError()
    policy = SmsBudgetPolicy(
        maximumAttempts=cast(int, bundle["maximumAttempts"]),
        budgetCents=cast(int, bundle["budgetCents"]),
        reservePerAttemptCents=cast(int, bundle["reservePerAttemptCents"]),
        expiresAtUtc=datetime.fromisoformat(expiry),
        allowedPhones=frozenset(cast(list[str], phones)),
    )
    return PnvsRuntimeSettings(
        _secret(bundle["otpSecretBase64"]), _secret(bundle["auditSecretBase64"]), policy
    )


def loadPnvsRuntimeSettings(
    path: str | Path, *, trialPolicy: VolunteerTrialPolicy | None = None
) -> PnvsRuntimeSettings:
    try:
        runtime = _runtimeSettings(loadProtectedPayload(path, kind="pnvsRuntime"))
        if trialPolicy is None:
            return runtime
        return PnvsRuntimeSettings(runtime.otpSecret, runtime.auditSecret, trialPolicy.smsPolicy())
    except Exception:
        raise PnvsRuntimeLoadError() from None
