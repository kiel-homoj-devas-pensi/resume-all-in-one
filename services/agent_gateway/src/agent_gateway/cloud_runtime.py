from __future__ import annotations

import base64
from dataclasses import dataclass, field
from pathlib import Path
from typing import cast

from .cloud_storage import CloudSyncPolicy
from .windows_protected_configuration import loadProtectedPayload, parseProtectedObject

_FIELDS = {
    "schemaVersion",
    "syntheticOnly",
    "policyVersion",
    "region",
    "contentRetentionDays",
    "backupRetentionDays",
    "resourceIdentity",
    "cursorSecretBase64",
}


class CloudRuntimeLoadError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("cloud_runtime_configuration_unavailable")


@dataclass(frozen=True, slots=True, repr=False)
class CloudRuntimeSettings:
    policy: CloudSyncPolicy
    cursorSecret: bytes = field(repr=False)

    def __post_init__(self) -> None:
        if (
            not isinstance(self.policy, CloudSyncPolicy)
            or type(self.cursorSecret) is not bytes
            or len(self.cursorSecret) != 32
        ):
            raise CloudRuntimeLoadError()


def _runtimeSettings(payload: str) -> CloudRuntimeSettings:
    bundle = parseProtectedObject(payload)
    if (
        set(bundle) != _FIELDS
        or type(bundle["schemaVersion"]) is not int
        or bundle["schemaVersion"] != 1
        or bundle["syntheticOnly"] is not True
        or any(
            type(bundle[name]) is not str
            for name in ("policyVersion", "region", "resourceIdentity", "cursorSecretBase64")
        )
        or any(
            type(bundle[name]) is not int
            for name in ("contentRetentionDays", "backupRetentionDays")
        )
    ):
        raise CloudRuntimeLoadError()
    encoded = cast(str, bundle["cursorSecretBase64"])
    secret = base64.b64decode(encoded, validate=True)
    if len(secret) != 32 or base64.b64encode(secret).decode("ascii") != encoded:
        raise CloudRuntimeLoadError()
    return CloudRuntimeSettings(
        CloudSyncPolicy(
            cast(str, bundle["policyVersion"]),
            cast(str, bundle["region"]),
            cast(int, bundle["contentRetentionDays"]),
            cast(int, bundle["backupRetentionDays"]),
            cast(str, bundle["resourceIdentity"]),
        ),
        secret,
    )


def loadCloudRuntimeSettings(path: str | Path) -> CloudRuntimeSettings:
    try:
        return _runtimeSettings(loadProtectedPayload(path, kind="cloudRuntime"))
    except Exception:
        raise CloudRuntimeLoadError() from None
