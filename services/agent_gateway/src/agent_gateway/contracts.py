from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from .password_policy import ExistingPassword, NewPassword
from .usage import ProductCapability, SubscriptionPlan

ProtocolVersion = Literal["0.1.0"]
GatewayCapability = Literal["gatewayContractProbe"]


class StrictGatewayModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class GatewayAgentRequest(StrictGatewayModel):
    protocolVersion: ProtocolVersion
    clientRequestId: Annotated[
        str,
        StringConstraints(
            min_length=1,
            max_length=64,
            pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]*$",
        ),
    ]
    capability: GatewayCapability
    syntheticInput: Annotated[
        str,
        StringConstraints(strip_whitespace=True, min_length=1, max_length=512),
    ]


class AgentResponsePayload(StrictGatewayModel):
    summary: Annotated[str, StringConstraints(min_length=1, max_length=256)]
    proposedPatch: None = None
    citations: tuple[str, ...] = ()
    warnings: tuple[str, ...] = ()
    nextAction: Literal["none"] = "none"


class GatewayExecutionMetadata(StrictGatewayModel):
    providerMode: Literal["mock"] = "mock"
    usesNetwork: Literal[False] = False


class GatewayAgentSuccessResponse(StrictGatewayModel):
    protocolVersion: ProtocolVersion = "0.1.0"
    operationId: str
    clientRequestId: str
    status: Literal["succeeded"] = "succeeded"
    agentResponse: AgentResponsePayload
    execution: GatewayExecutionMetadata = Field(default_factory=GatewayExecutionMetadata)


class GatewayErrorIssue(StrictGatewayModel):
    path: str
    code: str


class GatewayError(StrictGatewayModel):
    code: str
    message: str
    operationId: str
    retryable: bool
    issues: tuple[GatewayErrorIssue, ...] | None = None


class GatewayErrorResponse(StrictGatewayModel):
    error: GatewayError


JSON_BOUNDARY_RESPONSES: dict[int | str, dict[str, Any]] = {
    400: {"model": GatewayErrorResponse},
    408: {
        "model": GatewayErrorResponse,
        "description": "request_timeout；正文未完整接收，未进入业务处理",
    },
    413: {"model": GatewayErrorResponse},
    415: {"model": GatewayErrorResponse},
    429: {"model": GatewayErrorResponse},
}


class GatewayHealthResponse(StrictGatewayModel):
    status: Literal["alive", "ready", "not_ready"]


Task018ProtocolVersion = Literal["0.2.0"]
PhoneE164 = Annotated[
    str,
    StringConstraints(pattern=r"^\+[1-9][0-9]{7,14}$"),
]
AccountPassword = NewPassword


class AccountRegistrationRequest(StrictGatewayModel):
    protocolVersion: Task018ProtocolVersion
    phoneE164: PhoneE164
    password: AccountPassword
    verificationProof: Annotated[str, StringConstraints(min_length=1, max_length=128)]


class AccountRegistrationResponse(StrictGatewayModel):
    protocolVersion: Task018ProtocolVersion = "0.2.0"
    accountId: str
    status: Literal["registered"] = "registered"


class AccountSessionRequest(StrictGatewayModel):
    protocolVersion: Task018ProtocolVersion
    phoneE164: PhoneE164
    password: ExistingPassword = Field(repr=False)


class AccountSessionResponse(StrictGatewayModel):
    protocolVersion: Task018ProtocolVersion = "0.2.0"
    sessionToken: str
    expiresAtUtc: datetime


class AccountAccessResponse(StrictGatewayModel):
    protocolVersion: Task018ProtocolVersion = "0.2.0"
    capability: ProductCapability
    plan: SubscriptionPlan
    allowed: bool
    reason: Literal["allowed", "subscription_required", "quota_exhausted"]
    remainingMonthlyBasicGenerations: int | None


class AccountQuotaResponse(AccountAccessResponse):
    """Result quota endpoint; legacy access response remains an exact-key contract."""

    isUnlimited: bool = False
    monthlyLimit: int
    remainingMonthlyGenerations: int
    resetsAtUtc: datetime
    countingUnit: Literal["usableCandidate"] = "usableCandidate"
