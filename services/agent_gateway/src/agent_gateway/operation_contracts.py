from __future__ import annotations

from typing import Annotated, Literal, Self

from pydantic import StringConstraints, model_validator

from .contracts import StrictGatewayModel
from .usage import ProductCapability, UsageOperationStatus

OperationKey = Annotated[
    str, StringConstraints(min_length=1, max_length=256, pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
]


class AccountIdentityResponse(StrictGatewayModel):
    protocolVersion: Literal["0.4.0"] = "0.4.0"
    accountId: str


class OriginalResultRecoveryOptions(StrictGatewayModel):
    protocolVersion: Literal["0.1.0"] = "0.1.0"
    enabled: bool
    resultRetentionSeconds: Literal[86400] = 86400


class OperationLookupRequest(StrictGatewayModel):
    protocolVersion: Literal["0.4.0"]
    capability: ProductCapability
    usageOperationId: OperationKey | None = None
    idempotencyKey: OperationKey | None = None

    @model_validator(mode="after")
    def requireOneLookupKey(self) -> Self:
        if (self.usageOperationId is None) == (self.idempotencyKey is None):
            raise ValueError("必须提供一个查询键")
        return self


class OperationLookupResponse(StrictGatewayModel):
    protocolVersion: Literal["0.4.0"] = "0.4.0"
    traceId: str
    usageOperationId: str | None
    capability: ProductCapability
    status: UsageOperationStatus | Literal["notFound"]
    quotaOccupied: bool
    nextAction: Literal["queryLater", "reconcile", "resultUnavailable", "explicitNewRequest"]
    resultAvailable: Literal[False] = False
