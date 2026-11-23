from datetime import datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Request, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import Field, StringConstraints

from .account_lifecycle import AccountLifecycleService, IdentityActionError, VerificationPurpose
from .contracts import JSON_BOUNDARY_RESPONSES, GatewayErrorResponse, PhoneE164, StrictGatewayModel
from .password_policy import ExistingPassword, NewPassword

ChallengeId = Annotated[str, StringConstraints(min_length=1, max_length=64)]
Code = Annotated[str, StringConstraints(pattern=r"^[0-9]{6}$")]


class AccountOptions(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"] = "0.5.0"
    developmentSms: bool
    persistentLogin: Literal[False] = False
    recoveryCodes: bool | None = None


class VerificationRequest(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"]
    phoneE164: PhoneE164
    purpose: VerificationPurpose


class VerificationResponse(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"] = "0.5.0"
    challengeId: str
    expiresAtUtc: datetime
    developmentCode: str | None = None


class RegistrationRequest(VerificationRequest):
    purpose: Literal["register"] = "register"
    password: NewPassword = Field(repr=False)
    challengeId: ChallengeId
    code: Code = Field(repr=False)


class RegistrationResponse(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"] = "0.5.0"
    accountId: str


class LoginRequest(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"]
    phoneE164: PhoneE164
    password: ExistingPassword = Field(repr=False)


class SessionResponse(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"] = "0.5.0"
    sessionToken: str = Field(repr=False)
    expiresAtUtc: datetime


class RevokeRequest(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"]
    allDevices: bool


class PasswordChangeRequest(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"]
    currentPassword: ExistingPassword = Field(repr=False)
    newPassword: NewPassword = Field(repr=False)


class PasswordResetRequest(VerificationRequest):
    purpose: Literal["resetPassword"] = "resetPassword"
    newPassword: NewPassword = Field(repr=False)
    challengeId: ChallengeId
    code: Code = Field(repr=False)


class RecoveryResetRequest(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"]
    phoneE164: PhoneE164
    newPassword: NewPassword = Field(repr=False)
    recoveryCode: Annotated[str, StringConstraints(pattern=r"^[0-9A-F]{8}(?:-[0-9A-F]{8}){3}$")] = (
        Field(repr=False)
    )


class RecoveryCodeRequest(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"]
    currentPassword: ExistingPassword = Field(repr=False)


class RecoveryCodeResponse(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"] = "0.5.0"
    recoveryCode: str = Field(repr=False)


class RightsReceiptResponse(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"] = "0.5.0"
    receipt: Annotated[str, StringConstraints(min_length=1, max_length=2048)] = Field(repr=False)
    expiresAtUtc: datetime


class RightsReceiptRequest(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"]
    currentPassword: ExistingPassword = Field(repr=False)


class DeactivateRequest(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"]
    currentPassword: ExistingPassword = Field(repr=False)
    confirmation: Literal["DEACTIVATE"]


class ActionResponse(StrictGatewayModel):
    protocolVersion: Literal["0.5.0"] = "0.5.0"
    status: Literal["completed"] = "completed"


def lifecycleRouter(service: AccountLifecycleService | None) -> APIRouter:
    router = APIRouter(tags=["account-lifecycle"])
    bearer = HTTPBearer(auto_error=False, scheme_name="AccountLifecycleBearer")

    def requiredService() -> AccountLifecycleService:
        if service is None:
            raise IdentityActionError("account_service_unavailable", 503)
        return service

    def token(credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]) -> str:
        if credentials is None or credentials.scheme.lower() != "bearer":
            raise IdentityActionError("unauthenticated", 401)
        requiredService().accounts.authenticateSession(credentials.credentials)
        return credentials.credentials

    def peer(request: Request) -> str:
        # 不信任可由客户端伪造的 X-Forwarded-For；生产代理需单独建立可信配置。
        return "unknown" if request.client is None else request.client.host

    @router.get(
        "/v2/account/options", response_model=AccountOptions, response_model_exclude_none=True
    )
    def options(features: Literal["recoveryCodes"] | None = None) -> AccountOptions:
        identity = requiredService()
        return AccountOptions(
            developmentSms=identity.smsSender.developmentOnly,
            recoveryCodes=identity.enableRecoveryCodes if features == "recoveryCodes" else None,
        )

    @router.post(
        "/v2/account-verifications",
        response_model=VerificationResponse,
        responses={
            **JSON_BOUNDARY_RESPONSES,
            503: {
                "model": GatewayErrorResponse,
                "description": (
                    "verification_delivery_unavailable 或 verification_delivery_unknown；"
                    "retryable=false，不返回验证码挑战，不能自动重发"
                ),
            },
        },
    )
    def issue(body: VerificationRequest, request: Request) -> VerificationResponse:
        challenge = requiredService().issueCode(body.phoneE164, body.purpose, peer(request))
        return VerificationResponse(
            challengeId=challenge.challengeId,
            expiresAtUtc=challenge.expiresAtUtc,
            developmentCode=challenge.developmentCode,
        )

    @router.post(
        "/v2/accounts",
        response_model=RegistrationResponse,
        status_code=201,
        responses=JSON_BOUNDARY_RESPONSES,
    )
    def register(body: RegistrationRequest, request: Request) -> RegistrationResponse:
        accountId = requiredService().register(
            body.phoneE164, body.password, body.challengeId, body.code, peer(request)
        )
        return RegistrationResponse(accountId=accountId)

    @router.post(
        "/v2/account-sessions", response_model=SessionResponse, responses=JSON_BOUNDARY_RESPONSES
    )
    def login(body: LoginRequest, request: Request) -> SessionResponse:
        identity = requiredService()
        identity.chargeRate("login", body.phoneE164, peer(request))
        session = identity.accounts.createSession(phoneE164=body.phoneE164, password=body.password)
        return SessionResponse(sessionToken=session.sessionToken, expiresAtUtc=session.expiresAtUtc)

    @router.post(
        "/v2/account-sessions/revoke",
        response_model=ActionResponse,
        responses=JSON_BOUNDARY_RESPONSES,
    )
    def revoke(
        body: RevokeRequest, request: Request, sessionToken: Annotated[str, Depends(token)]
    ) -> ActionResponse:
        identity = requiredService()
        subject = identity.accounts.authenticateSession(sessionToken)
        identity.chargeRate("manage", subject.accountId, peer(request))
        identity.revoke(sessionToken, allDevices=body.allDevices)
        return ActionResponse()

    @router.post(
        "/v2/account/password", response_model=ActionResponse, responses=JSON_BOUNDARY_RESPONSES
    )
    def change(
        body: PasswordChangeRequest, request: Request, sessionToken: Annotated[str, Depends(token)]
    ) -> ActionResponse:
        identity = requiredService()
        subject = identity.accounts.authenticateSession(sessionToken)
        identity.chargeRate("manage", subject.accountId, peer(request))
        identity.changePassword(sessionToken, body.currentPassword, body.newPassword)
        return ActionResponse()

    @router.post(
        "/v2/account/password-reset",
        response_model=ActionResponse,
        responses=JSON_BOUNDARY_RESPONSES,
    )
    def reset(
        body: PasswordResetRequest | RecoveryResetRequest, request: Request
    ) -> ActionResponse:
        identity = requiredService()
        identity.chargeRate("manage", body.phoneE164, peer(request))
        if isinstance(body, RecoveryResetRequest):
            identity.resetWithRecoveryCode(body.phoneE164, body.newPassword, body.recoveryCode)
            return ActionResponse()
        identity.resetPassword(
            body.phoneE164, body.newPassword, body.challengeId, body.code, peer(request)
        )
        return ActionResponse()

    @router.post(
        "/v2/account/recovery-code",
        response_model=RecoveryCodeResponse,
        responses=JSON_BOUNDARY_RESPONSES,
    )
    def recoveryCode(
        body: RecoveryCodeRequest, request: Request, sessionToken: Annotated[str, Depends(token)]
    ) -> RecoveryCodeResponse:
        identity = requiredService()
        subject = identity.accounts.authenticateSession(sessionToken)
        identity.chargeRate("manage", subject.accountId, peer(request))
        return RecoveryCodeResponse(
            recoveryCode=identity.createRecoveryCode(sessionToken, body.currentPassword)
        )

    @router.post(
        "/v2/account/deactivate", response_model=ActionResponse, responses=JSON_BOUNDARY_RESPONSES
    )
    def deactivate(
        body: DeactivateRequest, request: Request, sessionToken: Annotated[str, Depends(token)]
    ) -> ActionResponse:
        identity = requiredService()
        subject = identity.accounts.authenticateSession(sessionToken)
        identity.chargeRate("manage", subject.accountId, peer(request))
        identity.deactivate(sessionToken, body.currentPassword)
        return ActionResponse()

    @router.post(
        "/v2/account/rights-request-receipt",
        response_model=RightsReceiptResponse,
        responses=JSON_BOUNDARY_RESPONSES,
    )
    def rightsReceipt(
        body: RightsReceiptRequest,
        request: Request,
        response: Response,
        sessionToken: Annotated[str, Depends(token)],
    ) -> RightsReceiptResponse:
        identity = requiredService()
        subject = identity.accounts.authenticateSession(sessionToken)
        identity.chargeRate("manage", subject.accountId, peer(request))
        receipt = identity.issueRightsRequestReceipt(sessionToken, body.currentPassword)
        response.headers["Cache-Control"] = "no-store"
        return RightsReceiptResponse.model_validate({"protocolVersion": "0.5.0", **receipt})

    return router
