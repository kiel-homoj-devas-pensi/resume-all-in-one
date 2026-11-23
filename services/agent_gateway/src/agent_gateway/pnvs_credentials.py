from __future__ import annotations

from pathlib import Path
from typing import cast

from .pnvs_transport import PnvsCredentials
from .windows_protected_configuration import loadProtectedPayload, parseProtectedObject

_FIELDS = {
    "schemaVersion",
    "ALIBABA_CLOUD_ACCESS_KEY_ID",
    "ALIBABA_CLOUD_ACCESS_KEY_SECRET",
    "PNVS_SIGN_NAME",
    "PNVS_TEMPLATE_CODE",
    "PNVS_CODE_VARIABLE",
    "PNVS_MINUTES_VARIABLE",
}


class PnvsCredentialLoadError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("pnvs_credentials_unavailable")


def _credentials(payload: str) -> PnvsCredentials:
    bundle = parseProtectedObject(payload)
    if set(bundle) != _FIELDS:
        raise PnvsCredentialLoadError()
    if (
        type(bundle["schemaVersion"]) is not int
        or bundle["schemaVersion"] != 1
        or bundle["PNVS_CODE_VARIABLE"] != "code"
        or bundle["PNVS_MINUTES_VARIABLE"] != "min"
        or any(not isinstance(bundle[name], str) for name in _FIELDS - {"schemaVersion"})
    ):
        raise PnvsCredentialLoadError()
    return PnvsCredentials(
        accessKeyId=cast(str, bundle["ALIBABA_CLOUD_ACCESS_KEY_ID"]),
        accessKeySecret=cast(str, bundle["ALIBABA_CLOUD_ACCESS_KEY_SECRET"]),
        signName=cast(str, bundle["PNVS_SIGN_NAME"]),
        templateCode=cast(str, bundle["PNVS_TEMPLATE_CODE"]),
    )


def loadPnvsCredentials(path: str | Path) -> PnvsCredentials:
    try:
        return _credentials(loadProtectedPayload(path, kind="pnvsCredentials"))
    except Exception:
        raise PnvsCredentialLoadError() from None
