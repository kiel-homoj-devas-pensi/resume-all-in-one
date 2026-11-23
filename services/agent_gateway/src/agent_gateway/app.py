from __future__ import annotations

import asyncio
import hmac
import json
import logging
import secrets
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Annotated, Literal, Never

from fastapi import Depends, FastAPI, Header, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .account_lifecycle import AccountLifecycleService, FakeSmsSender, IdentityActionError
from .account_privileges import (
    AccountPrivilegeService,
    AccountPrivilegesResponse,
    PrivilegeGrantError,
)
from .account_storage import (
    AccountSqlDatabase,
    SqliteAccountDatabase,
    StorageUnavailableError,
    UnknownStorageCommitError,
)
from .aigc_metadata import (
    AIGC_HEADER,
    AIGC_OPENAPI_HEADERS,
    AIGC_VERSION,
    AIGC_VERSION_HEADER,
    InvalidAigcMetadata,
    cachedAigcHeader,
    prepareAigcTransmission,
)
from .boundary import GatewayBoundaryMiddleware, GatewayConcurrencyLimiter
from .canonical_snapshot import CanonicalSnapshotError
from .cloud_pages import CloudCursorError
from .cloud_routes import CloudRequestError, cloudRouter
from .cloud_runtime import CloudRuntimeLoadError, loadCloudRuntimeSettings
from .cloud_storage import (
    CloudAuthenticationError,
    CloudIdempotencyConflict,
    CloudNotAccessible,
    CloudResumeStore,
)
from .contracts import (
    JSON_BOUNDARY_RESPONSES,
    AccountAccessResponse,
    AccountQuotaResponse,
    AccountRegistrationRequest,
    AccountRegistrationResponse,
    AccountSessionRequest,
    AccountSessionResponse,
    GatewayAgentRequest,
    GatewayAgentSuccessResponse,
    GatewayError,
    GatewayErrorIssue,
    GatewayErrorResponse,
    GatewayHealthResponse,
)
from .database import GatewayDatabase
from .guest_identity import (
    GuestIdentityService,
    GuestLimitError,
    GuestSessionRequest,
    GuestSessionResponse,
)
from .identity import (
    AccountRegistrationUnavailableError,
    AccountService,
    AuthenticatedSubject,
    AuthenticationFailedError,
    FakePhoneOwnershipVerifier,
    InvalidAccountInputError,
    PhoneVerificationRequiredError,
)
from .lifecycle_routes import lifecycleRouter
from .lifecycle_storage import LifecycleStore, MySqlLifecycleStore, SqliteLifecycleStore
from .mysql_sms_schema import validateFullGatewaySchema, validateSmsSchema
from .mysql_storage import MySqlAccountDatabase, MySqlAccountStore, MySqlConfig
from .operation_contracts import (
    AccountIdentityResponse,
    OperationLookupRequest,
    OperationLookupResponse,
    OriginalResultRecoveryOptions,
)
from .pnvs_credentials import loadPnvsCredentials
from .pnvs_runtime import loadPnvsRuntimeSettings
from .pnvs_sender import PnvsSmsSender
from .pnvs_transport import PnvsSmsTransport
from .prompt_registry import ReasoningProfile
from .provider import (
    FakeAgentProvider,
    GatewayAgentProvider,
    InvalidProviderResponseError,
    ProviderUnavailableError,
)
from .remote_contracts import (
    RemoteExecutionMetadata,
    RemoteResumeAiRequest,
    RemoteResumeAiSuccessResponse,
    hasUsableCandidate,
)
from .remote_provider import (
    FakeRemoteResumeProvider,
    GlmProviderConfig,
    GlmRemoteResumeProvider,
    InvalidRemoteProviderResponseError,
    RemoteProviderOutcomeUnknownError,
    RemoteProviderRateLimitedError,
    RemoteProviderUnavailableError,
    RemoteResumeProvider,
)
from .remote_result_cache import RemoteResultCache, ResultCacheUnavailable
from .settings import GatewaySettings
from .sms_budget import SmsBudgetLedger
from .usage import (
    INVALID_CANDIDATE_USAGE_UNKNOWN,
    NO_USABLE_CANDIDATE,
    IdempotencyConflictError,
    MonthlyQuotaExhaustedError,
    ProductCapability,
    SubscriptionPlan,
    SubscriptionRequiredError,
    UsageOperation,
    UsageOperationStatus,
    UsagePolicyService,
    hashOperationValue,
)
from .usage_storage import MySqlUsageStore, SqliteUsageStore
from .volunteer_trial import TrialAdmissionClosedError, TrialModelBudget, loadVolunteerTrialPolicy


class GatewayHttpError(Exception):
    def __init__(
        self,
        *,
        statusCode: int,
        code: str,
        message: str,
        retryable: bool,
        responseHeaders: dict[str, str] | None = None,
    ) -> None:
        super().__init__(code)
        self.statusCode = statusCode
        self.code = code
        self.message = message
        self.retryable = retryable
        self.responseHeaders = responseHeaders


developmentBearer = HTTPBearer(
    auto_error=False,
    scheme_name="DevelopmentBearer",
    description="Task 017 本机开发期 Bearer token；不是生产鉴权。",
)
accountSessionBearer = HTTPBearer(
    auto_error=False,
    scheme_name="AccountSessionBearer",
    description="Task 018 opaque account session；数据库只保存 token 哈希。",
)


def createApplication(
    *,
    settings: GatewaySettings | None = None,
    provider: GatewayAgentProvider | None = None,
    accountService: AccountService | None = None,
    usagePolicy: UsagePolicyService | None = None,
    remoteResumeProvider: RemoteResumeProvider | None = None,
    auditLogger: logging.Logger | None = None,
    accountLifecycle: AccountLifecycleService | None = None,
    cloudStore: CloudResumeStore | None = None,
    remoteResultCache: RemoteResultCache | None = None,
    guestService: GuestIdentityService | None = None,
) -> FastAPI:
    gatewaySettings = settings or GatewaySettings.fromEnvironment()
    if gatewaySettings.enableAccountPrivileges and any(
        service is not None
        for service in (accountService, usagePolicy, accountLifecycle, cloudStore)
    ):
        raise ValueError("账号权益必须使用显式配置的同库工厂，不允许部分服务注入")
    if cloudStore is not None and gatewaySettings.executionEnvironment != "development":
        # 云资源、备份和客户端恢复尚未完成生产准入，注入也不能绕过。
        raise ValueError("生产云同步尚未开放")
    if gatewaySettings.cloudRuntimePath is not None and any(
        service is not None
        for service in (cloudStore, accountService, usagePolicy, accountLifecycle)
    ):
        raise ValueError("云运行配置不能与账户、生命周期或云存储注入混用")
    if gatewaySettings.executionEnvironment == "production" and (
        isinstance(provider, FakeAgentProvider)
        or isinstance(remoteResumeProvider, FakeRemoteResumeProvider)
        or (accountService is not None and accountService.usesDevelopmentIdentity)
        or (accountLifecycle is not None and accountLifecycle.smsSender.developmentOnly)
    ):
        # 显式 Fake 注入在打开数据库或加载配置前拒绝。
        raise ValueError("生产启动拒绝注入的 Fake 服务")
    gatewayProvider = provider
    if gatewayProvider is None and gatewaySettings.executionEnvironment == "development":
        gatewayProvider = FakeAgentProvider()
    gatewayAuditLogger = auditLogger or logging.getLogger("agent_gateway.audit")
    resultCache = remoteResultCache
    if resultCache is None and gatewaySettings.remoteResultDirectory is not None:
        resultCache = RemoteResultCache(gatewaySettings.remoteResultDirectory)
    if (
        gatewaySettings.executionEnvironment == "production"
        and resultCache is not None
        and not resultCache.productionProtected
    ):
        raise ValueError("生产结果恢复要求当前服务身份的本机保护")
    remoteTasks: set[asyncio.Task[RemoteResumeAiSuccessResponse]] = set()
    remoteTaskByOperation: dict[str, asyncio.Task[RemoteResumeAiSuccessResponse]] = {}

    cloudRuntime = (
        None
        if gatewaySettings.cloudRuntimePath is None
        else loadCloudRuntimeSettings(gatewaySettings.cloudRuntimePath)
    )
    gatewayAccountService, gatewayUsagePolicy, ownedMySqlDatabase = _resolveTask018Services(
        gatewaySettings,
        accountService=accountService,
        usagePolicy=usagePolicy,
        withCloud=cloudRuntime is not None,
    )
    try:
        accountPrivileges: AccountPrivilegeService | None = None
        if gatewaySettings.enableAccountPrivileges:
            if gatewayAccountService is None:
                raise ValueError("账号权益要求已配置的身份服务")
            privilegesDatabase: AccountSqlDatabase = (
                ownedMySqlDatabase
                if ownedMySqlDatabase is not None
                else SqliteAccountDatabase(gatewayAccountService.database)
            )
            accountPrivileges = AccountPrivilegeService(privilegesDatabase)
        accountLifecycle = _resolveAccountLifecycle(
            gatewaySettings,
            gatewayAccountService,
            ownedMySqlDatabase,
            accountLifecycle,
            # Privilege schema includes existing cloud tables even when upload is
            # disabled; deactivation must still retire any earlier cloud data.
            withCloud=cloudRuntime is not None or gatewaySettings.enableAccountPrivileges,
            cloudCursorSecret=None if cloudRuntime is None else cloudRuntime.cursorSecret,
        )
        if cloudRuntime is not None:
            if gatewayAccountService is None:
                raise ValueError("云运行配置缺少同库账户服务")
            cloudDatabase: AccountSqlDatabase = (
                ownedMySqlDatabase
                if ownedMySqlDatabase is not None
                else SqliteAccountDatabase(gatewayAccountService.database)
            )
            cloudStore = CloudResumeStore(
                cloudDatabase, cloudRuntime.policy, cursorSecret=cloudRuntime.cursorSecret
            )
        if cloudStore is not None:
            if (
                gatewayAccountService is None
                or cloudStore.authorityKey != gatewayAccountService.store.authorityKey
                or accountLifecycle is None
                or not accountLifecycle.retiresCloudDocuments
                or not cloudStore.hasCursorSecret
            ):
                raise ValueError("云同步必须同库鉴权、开启停用退休并配置独立游标签名密钥")
            if cloudRuntime is None:
                cloudStore.checkSchema()
        gatewayRemoteResumeProvider = _resolveRemoteResumeProvider(
            gatewaySettings,
            remoteResumeProvider,
        )
        if gatewaySettings.executionEnvironment == "production" and (
            gatewayAccountService is None
            or gatewayAccountService.usesDevelopmentIdentity
            or isinstance(gatewayRemoteResumeProvider, FakeRemoteResumeProvider)
            or accountLifecycle is None
            or accountLifecycle.smsSender.developmentOnly
            or isinstance(gatewayProvider, FakeAgentProvider)
        ):
            raise ValueError("生产启动拒绝未配置的真实身份服务和注入的 Fake 服务")
    except Exception:
        if ownedMySqlDatabase is not None:
            ownedMySqlDatabase.close()
        raise

    if guestService is not None and gatewaySettings.executionEnvironment == "production":
        raise ValueError("生产游客服务必须通过有截止时间和总调用上限的配置启动")
    if guestService is not None and gatewaySettings.guestDatabasePath is not None:
        raise ValueError("游客服务注入与配置不能混用")
    gatewayGuests = guestService
    if gatewaySettings.guestDatabasePath is not None:
        gatewayGuests = GuestIdentityService(
            gatewaySettings.guestDatabasePath,
            maximumMonthlyCalls=gatewaySettings.guestMonthlyCallLimit,
            enabledUntilUtc=datetime.fromisoformat(gatewaySettings.guestEnabledUntilUtc or ""),
            openTestPolicy=gatewaySettings.openTestPolicy,
        )
    if gatewayGuests is not None and resultCache is None:
        raise ValueError("游客 AI 必须启用原结果恢复")

    def authenticateAiSession(
        credentials: HTTPAuthorizationCredentials | None,
    ) -> tuple[AuthenticatedSubject, UsagePolicyService]:
        if credentials is not None and credentials.credentials.startswith("guest-"):
            if gatewayGuests is None or credentials.scheme.lower() != "bearer":
                raise GatewayHttpError(
                    statusCode=401,
                    code="unauthenticated",
                    message="游客身份已失效，请重新进入体验",
                    retryable=False,
                )
            try:
                owner = gatewayGuests.authenticate(credentials.credentials)
            except AuthenticationFailedError:
                raise GatewayHttpError(
                    statusCode=401,
                    code="unauthenticated",
                    message="游客身份已失效，请重新进入体验",
                    retryable=False,
                ) from None
            return AuthenticatedSubject(accountId=owner), gatewayGuests.usagePolicy
        if gatewayAccountService is None or gatewayUsagePolicy is None:
            raise GatewayHttpError(
                statusCode=503,
                code="account_service_unavailable",
                message="账号服务暂不可用",
                retryable=False,
            )
        return _authenticateAccountSession(gatewayAccountService, credentials), gatewayUsagePolicy

    async def purgeOriginalResults() -> None:
        while True:
            await asyncio.sleep(60)
            try:
                if resultCache is not None:
                    resultCache.purgeExpired()
            except ResultCacheUnavailable:
                gatewayAuditLogger.error("original_result_retention_unavailable")

    @asynccontextmanager
    async def gatewayLifespan(application: FastAPI) -> AsyncIterator[None]:
        del application
        retentionTask = (
            asyncio.create_task(purgeOriginalResults()) if resultCache is not None else None
        )
        try:
            yield
        finally:
            if retentionTask is not None:
                retentionTask.cancel()
                await asyncio.gather(retentionTask, return_exceptions=True)
            if remoteTasks:
                _, interrupted = await asyncio.wait(
                    remoteTasks, timeout=gatewaySettings.remoteProviderDeadlineSeconds + 5
                )
                for task in interrupted:
                    task.cancel()
                await asyncio.gather(*interrupted, return_exceptions=True)
            try:
                if isinstance(gatewayRemoteResumeProvider, GlmRemoteResumeProvider):
                    await gatewayRemoteResumeProvider.aclose()
            finally:
                if ownedMySqlDatabase is not None:
                    ownedMySqlDatabase.close()

    gatewayApplication = FastAPI(
        title="Resume All-in-One Agent Gateway",
        version="0.13.0",
        description=(
            "Task 017 合成探测、Task 018 账号与用量边界，以及 Task 019 严格字段投影的 "
            "Fake/GLM Provider 接口；Task 029C 云同步仅在显式合成开发装配中启用。"
        ),
        redoc_url=None,
        lifespan=gatewayLifespan,
    )
    gatewayApplication.state.settings = gatewaySettings
    gatewayApplication.state.provider = gatewayProvider
    gatewayApplication.state.accountService = gatewayAccountService
    gatewayApplication.state.usagePolicy = gatewayUsagePolicy
    gatewayApplication.state.remoteResumeProvider = gatewayRemoteResumeProvider
    gatewayApplication.state.accountLifecycle = accountLifecycle
    gatewayApplication.state.cloudStore = cloudStore
    gatewayApplication.include_router(lifecycleRouter(accountLifecycle))
    gatewayApplication.include_router(
        cloudRouter(
            cloudStore,
            gatewayAccountService,
            maximumRequestBytes=gatewaySettings.maxRequestBodyBytes,
        )
    )

    @gatewayApplication.exception_handler(CloudRequestError)
    @gatewayApplication.exception_handler(CloudAuthenticationError)
    @gatewayApplication.exception_handler(CloudNotAccessible)
    @gatewayApplication.exception_handler(CloudIdempotencyConflict)
    @gatewayApplication.exception_handler(CloudCursorError)
    @gatewayApplication.exception_handler(CanonicalSnapshotError)
    async def handleCloudError(request: Request, error: Exception) -> JSONResponse:
        issues = None
        if isinstance(error, CloudAuthenticationError):
            status, code = 401, "unauthenticated"
        elif isinstance(error, CloudNotAccessible):
            status, code = 404, "cloud_not_accessible"
        elif isinstance(error, CloudIdempotencyConflict):
            status, code = 409, "cloud_idempotency_conflict"
        elif isinstance(error, CloudCursorError):
            code = str(error)
            if code not in {"cloud_cursor_invalid", "cloud_cursor_expired", "cloud_sequence_ahead"}:
                code = "cloud_cursor_invalid"
            status = 409 if code != "cloud_cursor_invalid" else 400
        elif isinstance(error, CanonicalSnapshotError):
            status, code = 400, "canonical_snapshot_invalid"
            issues = (GatewayErrorIssue(path=error.path, code=error.code),)
        elif isinstance(error, CloudRequestError):
            status, code = error.statusCode, error.code
        else:
            raise error
        return _errorResponse(
            request,
            statusCode=status,
            code=code,
            message="云同步请求未完成，请核对当前状态",
            retryable=False,
            issues=issues,
        )

    @gatewayApplication.exception_handler(StorageUnavailableError)
    async def handleStorageUnavailable(
        request: Request, error: StorageUnavailableError
    ) -> JSONResponse:
        unknown = isinstance(error, UnknownStorageCommitError)
        return _errorResponse(
            request,
            statusCode=503,
            code="operation_outcome_unknown" if unknown else "storage_unavailable",
            message="保存结果暂不可确认，请查询原操作状态"
            if unknown
            else "数据服务暂不可用，请稍后确认操作状态",
            retryable=False,
        )

    @gatewayApplication.exception_handler(IdentityActionError)
    async def handleIdentityActionError(
        request: Request, error: IdentityActionError
    ) -> JSONResponse:
        return _errorResponse(
            request,
            statusCode=error.statusCode,
            code=error.code,
            message=(
                "短信发送结果无法确认，本次验证码已作废；请勿连续重复发送"
                if error.code == "verification_delivery_unknown"
                else "验证码暂未发出，请稍后重新请求"
                if error.code == "verification_delivery_unavailable"
                else "账户操作未完成，请检查验证码或稍后重试"
            ),
            retryable=False,
        )

    @gatewayApplication.exception_handler(AuthenticationFailedError)
    async def handleIdentityAuthenticationError(
        request: Request, error: AuthenticationFailedError
    ) -> JSONResponse:
        return _errorResponse(
            request, statusCode=401, code="unauthenticated", message="请求身份无效", retryable=False
        )

    @gatewayApplication.exception_handler(AccountRegistrationUnavailableError)
    async def handleIdentityRegistrationError(
        request: Request, error: AccountRegistrationUnavailableError
    ) -> JSONResponse:
        return _errorResponse(
            request,
            statusCode=409,
            code="account_registration_unavailable",
            message="当前无法完成账号注册",
            retryable=False,
        )

    gatewayApplication.add_middleware(
        GatewayBoundaryMiddleware,
        settings=gatewaySettings,
        concurrencyLimiter=GatewayConcurrencyLimiter(
            gatewaySettings.maxConcurrentRequests,
        ),
        auditLogger=gatewayAuditLogger,
    )

    async def requireDevelopmentBearer(
        credentials: Annotated[
            HTTPAuthorizationCredentials | None,
            Depends(developmentBearer),
        ],
    ) -> None:
        configuredToken = gatewaySettings.testBearerToken
        suppliedToken = None if credentials is None else credentials.credentials
        suppliedScheme = None if credentials is None else credentials.scheme
        authenticationSucceeded = (
            configuredToken is not None
            and suppliedToken is not None
            and suppliedScheme is not None
            and suppliedScheme.lower() == "bearer"
            and secrets.compare_digest(suppliedToken, configuredToken)
        )
        if not authenticationSucceeded:
            raise GatewayHttpError(
                statusCode=401,
                code="unauthenticated",
                message="请求身份无效",
                retryable=False,
            )

    @gatewayApplication.exception_handler(GatewayHttpError)
    async def handleGatewayHttpError(
        request: Request,
        gatewayError: GatewayHttpError,
    ) -> JSONResponse:
        return _errorResponse(
            request,
            statusCode=gatewayError.statusCode,
            code=gatewayError.code,
            message=gatewayError.message,
            retryable=gatewayError.retryable,
            responseHeaders=gatewayError.responseHeaders,
        )

    @gatewayApplication.exception_handler(GuestLimitError)
    async def handleGuestLimit(request: Request, error: GuestLimitError) -> JSONResponse:
        del error
        return _errorResponse(
            request,
            statusCode=503,
            code="guest_temporarily_unavailable",
            message="游客体验当前暂不可用，请稍后再试",
            retryable=False,
        )

    @gatewayApplication.post(
        "/v1/guest/sessions",
        response_model=GuestSessionResponse,
        responses={**JSON_BOUNDARY_RESPONSES, 503: {"model": GatewayErrorResponse}},
        tags=["guest"],
    )
    def createGuestSession(request: Request, body: GuestSessionRequest) -> GuestSessionResponse:
        if gatewayGuests is None:
            raise GuestLimitError
        # Forwarded headers supplied by a caller cannot mint extra identities.
        return gatewayGuests.createSession(
            body.installationSecret,
            clientAddress="unknown" if request.client is None else request.client.host,
        )

    @gatewayApplication.get("/v1/guest/identity", tags=["guest"])
    def readGuestIdentity(
        credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(accountSessionBearer)],
    ) -> dict[str, str]:
        if credentials is None or not credentials.credentials.startswith("guest-"):
            raise GatewayHttpError(
                statusCode=401, code="unauthenticated", message="游客身份无效", retryable=False
            )
        subject, _ = authenticateAiSession(credentials)
        return {"protocolVersion": "0.1.0", "guestId": subject.accountId}

    @gatewayApplication.exception_handler(RequestValidationError)
    async def handleRequestValidationError(
        request: Request,
        validationError: RequestValidationError,
    ) -> JSONResponse:
        validationIssues = tuple(
            GatewayErrorIssue(
                path="$"
                if issue["type"] == "extra_forbidden"
                else "/".join(str(pathSegment) for pathSegment in issue["loc"]),
                code=issue["type"],
            )
            for issue in validationError.errors()
        )
        return _errorResponse(
            request,
            statusCode=400,
            code="invalid_request",
            message="请求不符合 Gateway 契约",
            retryable=False,
            issues=validationIssues,
        )

    @gatewayApplication.exception_handler(Exception)
    async def handleUnexpectedError(
        request: Request,
        unexpectedError: Exception,
    ) -> JSONResponse:
        # HTTP 边界只记录固定分类，原始异常可能带正文、密钥或本机路径。
        del unexpectedError
        gatewayAuditLogger.error(
            "gateway_internal_error operationId=%s",
            _operationId(request),
        )
        return _errorResponse(
            request,
            statusCode=500,
            code="internal_error",
            message="Gateway 未能完成请求",
            retryable=False,
        )

    @gatewayApplication.get(
        "/health/live",
        response_model=GatewayHealthResponse,
        tags=["health"],
    )
    async def readLiveness() -> GatewayHealthResponse:
        return GatewayHealthResponse(status="alive")

    @gatewayApplication.get(
        "/health/ready",
        response_model=GatewayHealthResponse,
        responses={503: {"model": GatewayHealthResponse}},
        tags=["health"],
    )
    async def readReadiness() -> GatewayHealthResponse | JSONResponse:
        legacyContractReady = (
            gatewaySettings.testBearerToken is not None
            and gatewayProvider is not None
            and gatewayProvider.isReady
        )
        remoteResumeReady = (
            gatewayAccountService is not None
            and gatewayUsagePolicy is not None
            and gatewayRemoteResumeProvider.isReady
            and (resultCache is None or resultCache.isReady)
        )
        isReady = legacyContractReady or remoteResumeReady
        readiness = GatewayHealthResponse(status="ready" if isReady else "not_ready")
        if isReady:
            return readiness
        return JSONResponse(status_code=503, content=readiness.model_dump(mode="json"))

    @gatewayApplication.post(
        "/v1/accounts",
        response_model=AccountRegistrationResponse,
        status_code=201,
        responses={
            **JSON_BOUNDARY_RESPONSES,
            400: {"model": GatewayErrorResponse},
            403: {"model": GatewayErrorResponse},
            409: {"model": GatewayErrorResponse},
            413: {"model": GatewayErrorResponse},
            415: {"model": GatewayErrorResponse},
            429: {"model": GatewayErrorResponse},
            503: {"model": GatewayErrorResponse},
        },
        tags=["account"],
    )
    def registerAccount(
        registrationRequest: AccountRegistrationRequest,
    ) -> AccountRegistrationResponse:
        if gatewaySettings.executionEnvironment == "production":
            raise GatewayHttpError(
                statusCode=400,
                code="unsupported_account_protocol",
                message="请使用验证码账户接口",
                retryable=False,
            )
        if gatewayAccountService is None:
            raise GatewayHttpError(
                statusCode=503,
                code="account_service_unavailable",
                message="账号服务未启用",
                retryable=False,
            )
        try:
            accountId = gatewayAccountService.registerAccount(
                phoneE164=registrationRequest.phoneE164,
                password=registrationRequest.password,
                verificationProof=registrationRequest.verificationProof,
            )
        except InvalidAccountInputError as inputError:
            raise GatewayHttpError(
                statusCode=400,
                code="invalid_request",
                message="账号输入不符合要求",
                retryable=False,
            ) from inputError
        except PhoneVerificationRequiredError as verificationError:
            raise GatewayHttpError(
                statusCode=403,
                code="phone_verification_required",
                message="手机号所有权尚未验证",
                retryable=False,
            ) from verificationError
        except AccountRegistrationUnavailableError as registrationError:
            raise GatewayHttpError(
                statusCode=409,
                code="account_registration_unavailable",
                message="当前无法完成账号注册",
                retryable=False,
            ) from registrationError
        return AccountRegistrationResponse(accountId=accountId)

    @gatewayApplication.post(
        "/v1/account-sessions",
        response_model=AccountSessionResponse,
        responses={
            **JSON_BOUNDARY_RESPONSES,
            400: {"model": GatewayErrorResponse},
            401: {"model": GatewayErrorResponse},
            413: {"model": GatewayErrorResponse},
            415: {"model": GatewayErrorResponse},
            429: {"model": GatewayErrorResponse},
            503: {"model": GatewayErrorResponse},
        },
        tags=["account"],
    )
    def createAccountSession(
        sessionRequest: AccountSessionRequest,
    ) -> AccountSessionResponse:
        if gatewaySettings.executionEnvironment == "production":
            raise GatewayHttpError(
                statusCode=400,
                code="unsupported_account_protocol",
                message="请使用新版账户接口",
                retryable=False,
            )
        if gatewayAccountService is None:
            raise GatewayHttpError(
                statusCode=503,
                code="account_service_unavailable",
                message="账号服务未启用",
                retryable=False,
            )
        try:
            accountSession = gatewayAccountService.createSession(
                phoneE164=sessionRequest.phoneE164,
                password=sessionRequest.password,
            )
        except AuthenticationFailedError as authenticationError:
            raise GatewayHttpError(
                statusCode=401,
                code="unauthenticated",
                message="请求身份无效",
                retryable=False,
            ) from authenticationError
        return AccountSessionResponse(
            sessionToken=accountSession.sessionToken,
            expiresAtUtc=accountSession.expiresAtUtc,
        )

    @gatewayApplication.get(
        "/v1/account/quota/{capability}", response_model=AccountQuotaResponse, tags=["account"]
    )
    @gatewayApplication.get(
        "/v1/account/access/{capability}",
        response_model=AccountAccessResponse,
        responses={
            400: {"model": GatewayErrorResponse},
            401: {"model": GatewayErrorResponse},
            503: {"model": GatewayErrorResponse},
        },
        tags=["account"],
    )
    def readAccountAccess(
        capability: ProductCapability,
        credentials: Annotated[
            HTTPAuthorizationCredentials | None,
            Depends(accountSessionBearer),
        ],
    ) -> AccountQuotaResponse:
        if gatewayAccountService is None or gatewayUsagePolicy is None:
            raise GatewayHttpError(
                statusCode=503,
                code="account_service_unavailable",
                message="账号服务未启用",
                retryable=False,
            )
        authenticatedSubject, activeUsagePolicy = authenticateAiSession(credentials)
        accessDecision = activeUsagePolicy.evaluateAccess(
            accountId=authenticatedSubject.accountId,
            capability=capability,
        )
        return AccountQuotaResponse(
            capability=accessDecision.capability,
            plan=accessDecision.plan,
            allowed=accessDecision.allowed,
            reason=accessDecision.reason,
            remainingMonthlyBasicGenerations=(accessDecision.remainingMonthlyBasicGenerations),
            isUnlimited=accessDecision.isUnlimited,
            monthlyLimit=accessDecision.monthlyLimit,
            remainingMonthlyGenerations=accessDecision.remainingMonthlyGenerations,
            resetsAtUtc=accessDecision.resetsAtUtc,
        )

    @gatewayApplication.get(
        "/v1/account/identity", response_model=AccountIdentityResponse, tags=["account"]
    )
    def readAccountIdentity(
        credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(accountSessionBearer)],
    ) -> AccountIdentityResponse:
        if gatewayAccountService is None:
            raise GatewayHttpError(
                statusCode=503,
                code="account_service_unavailable",
                message="账号服务未启用",
                retryable=False,
            )
        subject = _authenticateAccountSession(gatewayAccountService, credentials)
        return AccountIdentityResponse(accountId=subject.accountId)

    @gatewayApplication.get(
        "/v1/account/privileges",
        response_model=AccountPrivilegesResponse,
        responses={401: {"model": GatewayErrorResponse}, 503: {"model": GatewayErrorResponse}},
        tags=["account"],
    )
    def readAccountPrivileges(
        credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(accountSessionBearer)],
    ) -> AccountPrivilegesResponse:
        if accountPrivileges is None or gatewayAccountService is None:
            raise GatewayHttpError(
                statusCode=503,
                code="account_privileges_unavailable",
                message="账号权益查询尚未开放",
                retryable=False,
            )
        subject = _authenticateAccountSession(gatewayAccountService, credentials)
        try:
            return accountPrivileges.read(subject.accountId)
        except PrivilegeGrantError:
            raise AuthenticationFailedError from None

    @gatewayApplication.post(
        "/v1/resume-ai/operations/lookup",
        response_model=OperationLookupResponse,
        responses=JSON_BOUNDARY_RESPONSES,
        tags=["resume-ai"],
    )
    def lookupOperation(
        request: Request,
        lookup: OperationLookupRequest,
        credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(accountSessionBearer)],
        quotaContract: Annotated[
            Literal["usableCandidate.v1"] | None, Header(alias="X-Quota-Contract")
        ] = None,
    ) -> OperationLookupResponse:
        if gatewayAccountService is None or gatewayUsagePolicy is None:
            raise GatewayHttpError(
                statusCode=503,
                code="account_service_unavailable",
                message="账号服务未启用",
                retryable=False,
            )
        subject, activeUsagePolicy = authenticateAiSession(credentials)
        activeUsagePolicy.markAbandonedReservations(
            beforeUtc=datetime.now(UTC)
            - timedelta(seconds=max(300, gatewaySettings.remoteProviderDeadlineSeconds + 60))
        )
        operation = activeUsagePolicy.findOwnedOperation(
            accountId=subject.accountId,
            capability=lookup.capability,
            usageOperationId=lookup.usageOperationId,
            idempotencyKey=lookup.idempotencyKey,
        )
        if operation is None:
            # 请求仍可能在途；查不到绝不是允许换 key 生成的证明。
            return OperationLookupResponse(
                traceId=_operationId(request),
                usageOperationId=None,
                capability=lookup.capability,
                status="notFound",
                quotaOccupied=False,
                nextAction="queryLater",
            )
        nextActions: dict[
            UsageOperationStatus,
            Literal["queryLater", "reconcile", "resultUnavailable", "explicitNewRequest"],
        ] = {
            UsageOperationStatus.reserved: "queryLater",
            UsageOperationStatus.pendingReconciliation: "reconcile",
            UsageOperationStatus.committed: "resultUnavailable",
            UsageOperationStatus.released: "explicitNewRequest",
        }
        return OperationLookupResponse(
            traceId=_operationId(request),
            usageOperationId=operation.operationId,
            capability=operation.capability,
            status=operation.status,
            quotaOccupied=(
                operation.quotaOccupied
                if quotaContract
                else operation.status is not UsageOperationStatus.released
            ),
            nextAction=(
                "explicitNewRequest"
                if quotaContract and operation.failureCode == INVALID_CANDIDATE_USAGE_UNKNOWN
                else nextActions[operation.status]
            ),
        )

    @gatewayApplication.get(
        "/v1/resume-ai/recovery-options",
        response_model=OriginalResultRecoveryOptions,
        tags=["resume-ai"],
    )
    async def readOriginalResultRecoveryOptions() -> OriginalResultRecoveryOptions:
        return OriginalResultRecoveryOptions(
            enabled=resultCache is not None and resultCache.isReady
        )

    @gatewayApplication.post(
        "/v1/resume-ai/results/lookup",
        response_model=RemoteResumeAiSuccessResponse,
        responses={
            200: {"headers": AIGC_OPENAPI_HEADERS},
            **JSON_BOUNDARY_RESPONSES,
            202: {"description": "Original task is still running"},
            **{code: {"model": GatewayErrorResponse} for code in (401, 404, 409, 410, 503)},
        },
        tags=["resume-ai"],
    )
    async def recoverOriginalRemoteResult(
        lookup: OperationLookupRequest,
        httpResponse: Response,
        credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(accountSessionBearer)],
    ) -> RemoteResumeAiSuccessResponse | JSONResponse:
        if gatewayAccountService is None or gatewayUsagePolicy is None or resultCache is None:
            raise GatewayHttpError(
                statusCode=503,
                code="result_recovery_unavailable",
                message="原任务恢复暂不可用",
                retryable=False,
            )
        subject, activeUsagePolicy = authenticateAiSession(credentials)
        operation = activeUsagePolicy.findOwnedOperation(
            accountId=subject.accountId,
            capability=lookup.capability,
            usageOperationId=lookup.usageOperationId,
            idempotencyKey=lookup.idempotencyKey,
        )
        if operation is None:
            raise GatewayHttpError(
                statusCode=404,
                code="original_result_unavailable",
                message="暂未找到原任务结果，请稍后查看",
                retryable=False,
            )
        try:
            cached = resultCache.read(subject.accountId, operation.operationId)
        except ResultCacheUnavailable as error:
            raise GatewayHttpError(
                statusCode=503,
                code="result_recovery_unavailable",
                message="原任务恢复暂不可用",
                retryable=False,
            ) from error
        if (
            cached is None or cached.get("state") != "succeeded"
        ) and operation.status is UsageOperationStatus.committed:
            raise GatewayHttpError(
                statusCode=410,
                code="original_result_expired",
                message="原结果已超过恢复保留期，输入资料仍保留；可以重新开始任务。",
                retryable=False,
            )
        if cached is None or cached.get("state") == "failed":
            raise GatewayHttpError(
                statusCode=409,
                code="original_result_unavailable",
                message="本次任务暂未完成，我们会保留原任务记录；请稍后查看",
                retryable=False,
            )
        if cached.get("state") == "running":
            if operation.operationId not in remoteTaskByOperation:
                # A process restart cannot turn a lost in-flight execution into
                # evidence that the supplier did not run it. Never regenerate it.
                if operation.status is UsageOperationStatus.reserved:
                    activeUsagePolicy.transitionUsage(
                        operationId=operation.operationId,
                        targetStatus=UsageOperationStatus.pendingReconciliation,
                        failureCode="worker_interrupted",
                    )
                resultCache.save(subject.accountId, operation.operationId, {"state": "failed"})
                raise GatewayHttpError(
                    statusCode=409,
                    code="original_result_unavailable",
                    message="本次任务暂未完成，请稍后查看",
                    retryable=False,
                )
            return JSONResponse(status_code=202, content={"status": "pending"})
        try:
            response = RemoteResumeAiSuccessResponse.model_validate(cached["response"])
            prompt = cached["promptVersion"]
            inputTokens, outputTokens = cached["inputTokens"], cached["outputTokens"]
            if (
                response.operationId != operation.operationId
                or response.capability != lookup.capability
                or prompt != response.execution.promptVersion
                or not isinstance(prompt, str)
                or type(inputTokens) is not int
                or type(outputTokens) is not int
                or inputTokens < 0
                or outputTokens < 0
                or operation.status is UsageOperationStatus.released
            ):
                raise ValueError("Invalid original receipt")
            aigcHeader = cachedAigcHeader(
                cached,
                operationId=response.operationId,
                usesNetwork=response.execution.usesNetwork,
                hasCandidate=hasUsableCandidate(response.output),
            )
        except Exception:
            raise GatewayHttpError(
                statusCode=503,
                code="result_recovery_unavailable",
                message="原任务结果暂不可用",
                retryable=False,
            ) from None
        # The encrypted complete provider receipt is execution evidence. This repairs
        # a crash between receipt persistence and the original usage commit, once.
        activeUsagePolicy.transitionUsage(
            operationId=operation.operationId,
            targetStatus=UsageOperationStatus.committed,
            failureCode=None if hasUsableCandidate(response.output) else NO_USABLE_CANDIDATE,
            promptVersion=prompt,
            inputTokens=inputTokens,
            outputTokens=outputTokens,
        )
        if aigcHeader is not None:
            httpResponse.headers[AIGC_VERSION_HEADER] = AIGC_VERSION
            httpResponse.headers[AIGC_HEADER] = aigcHeader
        return response

    @gatewayApplication.post(
        "/v1/resume-ai/requests",
        response_model=RemoteResumeAiSuccessResponse,
        responses={
            200: {"headers": AIGC_OPENAPI_HEADERS},
            **JSON_BOUNDARY_RESPONSES,
            400: {"model": GatewayErrorResponse},
            401: {"model": GatewayErrorResponse},
            403: {"model": GatewayErrorResponse},
            409: {"model": GatewayErrorResponse},
            413: {"model": GatewayErrorResponse},
            415: {"model": GatewayErrorResponse},
            429: {"model": GatewayErrorResponse},
            500: {"model": GatewayErrorResponse},
            502: {"model": GatewayErrorResponse},
            503: {"model": GatewayErrorResponse},
            504: {"model": GatewayErrorResponse},
        },
        tags=["resume-ai"],
    )
    async def submitRemoteResumeRequest(
        request: Request,
        resumeAiRequest: RemoteResumeAiRequest,
        httpResponse: Response,
        credentials: Annotated[
            HTTPAuthorizationCredentials | None,
            Depends(accountSessionBearer),
        ],
        recoveryMode: Annotated[Literal["0.1.0"] | None, Header(alias="X-Result-Recovery")] = None,
    ) -> RemoteResumeAiSuccessResponse:
        if gatewayAccountService is None or gatewayUsagePolicy is None:
            raise GatewayHttpError(
                statusCode=503,
                code="account_service_unavailable",
                message="账号服务未启用",
                retryable=False,
            )
        authenticatedSubject, activeUsagePolicy = authenticateAiSession(credentials)
        request.state.auditCapability = resumeAiRequest.capability.value

        try:
            usageReservation = activeUsagePolicy.reserveUsageForExecution(
                accountId=authenticatedSubject.accountId,
                capability=resumeAiRequest.capability,
                idempotencyKey=resumeAiRequest.idempotencyKey,
                requestFingerprint=_remoteRequestFingerprint(resumeAiRequest),
            )
        except SubscriptionRequiredError as accessError:
            raise GatewayHttpError(
                statusCode=403,
                code="subscription_required",
                message="当前能力需要有效月订阅",
                retryable=False,
            ) from accessError
        except MonthlyQuotaExhaustedError as quotaError:
            raise GatewayHttpError(
                statusCode=429,
                code="quota_exhausted",
                message="本月此项 AI 成果额度已用完",
                retryable=False,
            ) from quotaError
        except IdempotencyConflictError as conflictError:
            raise GatewayHttpError(
                statusCode=409,
                code="idempotency_conflict",
                message="幂等键已用于不同请求",
                retryable=False,
            ) from conflictError

        request.state.usageOperationId = usageReservation.operation.operationId
        if usageReservation.isReplay:
            _raiseForUsageReplay(usageReservation.operation)

        usageOperation = usageReservation.operation
        recoveryRequested = recoveryMode == "0.1.0"
        if recoveryRequested:
            if resultCache is None:
                activeUsagePolicy.transitionUsage(
                    operationId=usageOperation.operationId,
                    targetStatus=UsageOperationStatus.released,
                    failureCode="result_recovery_unavailable",
                )
                raise GatewayHttpError(
                    statusCode=503,
                    code="result_recovery_unavailable",
                    message="AI任务暂时不可用，请稍后再试",
                    retryable=False,
                )
            try:
                resultCache.reserve(authenticatedSubject.accountId, usageOperation.operationId)
            except ResultCacheUnavailable as error:
                activeUsagePolicy.transitionUsage(
                    operationId=usageOperation.operationId,
                    targetStatus=UsageOperationStatus.released,
                    failureCode="result_recovery_unavailable",
                )
                raise GatewayHttpError(
                    statusCode=503,
                    code="result_recovery_unavailable",
                    message="AI任务暂时不可用，请稍后再试",
                    retryable=False,
                ) from error
        if not recoveryRequested:
            return await executeRemoteResume(
                request,
                resumeAiRequest,
                usageOperation,
                authenticatedSubject.accountId,
                False,
                activeUsagePolicy,
                httpResponse,
            )
        task = asyncio.create_task(
            executeRemoteResume(
                request,
                resumeAiRequest,
                usageOperation,
                authenticatedSubject.accountId,
                True,
                activeUsagePolicy,
                httpResponse,
            )
        )
        remoteTasks.add(task)
        remoteTaskByOperation[usageOperation.operationId] = task

        def completed(original: asyncio.Task[RemoteResumeAiSuccessResponse]) -> None:
            remoteTasks.discard(original)
            remoteTaskByOperation.pop(usageOperation.operationId, None)
            # Consume detached exceptions, never log the source/response/exception text.
            if original.cancelled():
                failed = True
            else:
                failed = original.exception() is not None
            if failed and resultCache is not None:
                try:
                    current = activeUsagePolicy.findOwnedOperation(
                        accountId=authenticatedSubject.accountId,
                        capability=resumeAiRequest.capability,
                        usageOperationId=usageOperation.operationId,
                    )
                    if current is not None and current.status is UsageOperationStatus.reserved:
                        activeUsagePolicy.transitionUsage(
                            operationId=current.operationId,
                            targetStatus=UsageOperationStatus.pendingReconciliation,
                            failureCode="worker_interrupted"
                            if original.cancelled()
                            else "internal_error",
                        )
                    existing = resultCache.read(
                        authenticatedSubject.accountId, usageOperation.operationId
                    )
                    if existing is not None and existing.get("state") == "running":
                        resultCache.save(
                            authenticatedSubject.accountId,
                            usageOperation.operationId,
                            {"state": "failed"},
                        )
                except Exception:
                    gatewayAuditLogger.error("original_result_receipt_unavailable")

        task.add_done_callback(completed)
        # A frontend disconnect must not discard an already-running paid generation.
        return await asyncio.shield(task)

    async def executeRemoteResume(
        request: Request,
        resumeAiRequest: RemoteResumeAiRequest,
        usageOperation: UsageOperation,
        owner: str,
        recoveryRequested: bool,
        activeUsagePolicy: UsagePolicyService,
        httpResponse: Response,
    ) -> RemoteResumeAiSuccessResponse:
        reasoningProfile = (
            ReasoningProfile.fast
            if (
                usageOperation.planAtReservation is SubscriptionPlan.free
                or resumeAiRequest.capability is ProductCapability.basicResumeCompose
            )
            else ReasoningProfile.deep
        )
        request.state.usesNetwork = gatewayRemoteResumeProvider.usesNetwork
        try:
            # 外层 deadline 保护完整 Provider 路径；适配器自己的超时仍负责区分连接与读写失败。
            async with asyncio.timeout(gatewaySettings.remoteProviderDeadlineSeconds):
                providerGeneration = await gatewayRemoteResumeProvider.generate(
                    resumeAiRequest,
                    reasoningProfile=reasoningProfile,
                )
                try:
                    aigc = prepareAigcTransmission(
                        operationId=usageOperation.operationId,
                        usesNetwork=providerGeneration.usesNetwork,
                        hasCandidate=hasUsableCandidate(providerGeneration.output),
                        upstream=providerGeneration.upstreamAigc,
                    )
                except InvalidAigcMetadata as metadataError:
                    raise InvalidRemoteProviderResponseError(
                        promptVersion=providerGeneration.promptVersion,
                        inputTokens=providerGeneration.inputTokens,
                        outputTokens=providerGeneration.outputTokens,
                    ) from metadataError
        except TrialAdmissionClosedError as trialError:
            activeUsagePolicy.transitionUsage(
                operationId=usageOperation.operationId,
                targetStatus=UsageOperationStatus.released,
                failureCode="trial_admission_closed",
            )
            request.state.usesNetwork = False
            raise GatewayHttpError(
                statusCode=503,
                code="trial_admission_closed",
                message="本轮AI体验已到期或达到总次数上限，请联系测试负责人",
                retryable=False,
            ) from trialError
        except RemoteProviderRateLimitedError as rateLimitError:
            activeUsagePolicy.transitionUsage(
                operationId=usageOperation.operationId,
                targetStatus=UsageOperationStatus.released,
                failureCode="rate_limited",
            )
            raise GatewayHttpError(
                statusCode=429,
                code="rate_limited",
                message="当前远程请求过多，请稍后重试",
                retryable=True,
                responseHeaders={"Retry-After": str(rateLimitError.retryAfterSeconds)},
            ) from rateLimitError
        except RemoteProviderUnavailableError as providerError:
            activeUsagePolicy.transitionUsage(
                operationId=usageOperation.operationId,
                targetStatus=UsageOperationStatus.released,
                failureCode="provider_unavailable",
            )
            raise GatewayHttpError(
                statusCode=503,
                code="provider_unavailable",
                message="远程能力暂不可用",
                retryable=False,
            ) from providerError
        except InvalidRemoteProviderResponseError as providerError:
            if all(
                value is not None
                for value in (
                    providerError.promptVersion,
                    providerError.inputTokens,
                    providerError.outputTokens,
                )
            ):
                activeUsagePolicy.transitionUsage(
                    operationId=usageOperation.operationId,
                    targetStatus=UsageOperationStatus.committed,
                    failureCode=NO_USABLE_CANDIDATE,
                    promptVersion=providerError.promptVersion,
                    inputTokens=providerError.inputTokens,
                    outputTokens=providerError.outputTokens,
                )
            else:
                # Candidate rejection is known; provider usage is not. Preserve
                # the cost reservation while charging zero user result units.
                activeUsagePolicy.transitionUsage(
                    operationId=usageOperation.operationId,
                    targetStatus=UsageOperationStatus.pendingReconciliation,
                    failureCode=INVALID_CANDIDATE_USAGE_UNKNOWN,
                )
            raise GatewayHttpError(
                statusCode=502,
                code="invalid_provider_response",
                message="AI结果未通过内容或结构检查，请调整要求后重试；本地简历未改变",
                retryable=False,
            ) from providerError
        except ValueError as projectionError:
            activeUsagePolicy.transitionUsage(
                operationId=usageOperation.operationId,
                targetStatus=UsageOperationStatus.released,
                failureCode="invalid_request",
            )
            raise GatewayHttpError(
                statusCode=400,
                code="invalid_request",
                message="最小字段投影超过允许上限",
                retryable=False,
            ) from projectionError
        except TimeoutError as providerError:
            activeUsagePolicy.transitionUsage(
                operationId=usageOperation.operationId,
                targetStatus=UsageOperationStatus.pendingReconciliation,
                failureCode="provider_timeout",
            )
            raise GatewayHttpError(
                statusCode=504,
                code="provider_timeout",
                message="远程调用结果尚不确定",
                retryable=False,
            ) from providerError
        except RemoteProviderOutcomeUnknownError as providerError:
            gatewayAuditLogger.warning(
                "provider_outcome_unknown operationId=%s reason=%s",
                usageOperation.operationId,
                providerError.reason,
            )
            activeUsagePolicy.transitionUsage(
                operationId=usageOperation.operationId,
                targetStatus=UsageOperationStatus.pendingReconciliation,
                failureCode="provider_outcome_unknown",
            )
            raise GatewayHttpError(
                statusCode=503,
                code="provider_unavailable",
                message="远程调用结果尚不确定",
                retryable=False,
            ) from providerError
        except Exception:
            # 未知执行故障不能释放额度，否则客户端可能用新键重复触发已发送的请求。
            activeUsagePolicy.transitionUsage(
                operationId=usageOperation.operationId,
                targetStatus=UsageOperationStatus.pendingReconciliation,
                failureCode="internal_error",
            )
            raise

        response = RemoteResumeAiSuccessResponse(
            operationId=usageOperation.operationId,
            clientRequestId=resumeAiRequest.clientRequestId,
            capability=resumeAiRequest.capability,
            output=providerGeneration.output,
            execution=RemoteExecutionMetadata(
                usesNetwork=providerGeneration.usesNetwork,
                promptVersion=providerGeneration.promptVersion,
            ),
        )
        if providerGeneration.upstreamAigc is not None and not recoveryRequested:
            # Even a legacy caller must not cause the genuine original source
            # label to be discarded. Persist it with the complete receipt.
            try:
                if resultCache is None:
                    raise ResultCacheUnavailable
                resultCache.reserve(owner, usageOperation.operationId)
                resultCache.save(
                    owner,
                    usageOperation.operationId,
                    {
                        "state": "succeeded",
                        "response": response.model_dump(mode="json"),
                        "promptVersion": providerGeneration.promptVersion,
                        "inputTokens": providerGeneration.inputTokens,
                        "outputTokens": providerGeneration.outputTokens,
                        **aigc.receiptFields(),
                    },
                )
            except ResultCacheUnavailable as cacheError:
                # Execution is known, but a label-preserving result could not
                # be delivered. Keep supplier usage, charge no candidate result.
                activeUsagePolicy.transitionUsage(
                    operationId=usageOperation.operationId,
                    targetStatus=UsageOperationStatus.committed,
                    failureCode=NO_USABLE_CANDIDATE,
                    promptVersion=providerGeneration.promptVersion,
                    inputTokens=providerGeneration.inputTokens,
                    outputTokens=providerGeneration.outputTokens,
                )
                raise GatewayHttpError(
                    statusCode=503,
                    code="result_recovery_unavailable",
                    message="AI结果暂不可用，请稍后重试；本地简历未改变",
                    retryable=False,
                ) from cacheError
        elif recoveryRequested and resultCache is not None:
            resultCache.save(
                owner,
                usageOperation.operationId,
                {
                    "state": "succeeded",
                    "response": response.model_dump(mode="json"),
                    "promptVersion": providerGeneration.promptVersion,
                    "inputTokens": providerGeneration.inputTokens,
                    "outputTokens": providerGeneration.outputTokens,
                    **aigc.receiptFields(),
                },
            )
        activeUsagePolicy.transitionUsage(
            operationId=usageOperation.operationId,
            targetStatus=UsageOperationStatus.committed,
            failureCode=None
            if hasUsableCandidate(providerGeneration.output)
            else NO_USABLE_CANDIDATE,
            promptVersion=providerGeneration.promptVersion,
            inputTokens=providerGeneration.inputTokens,
            outputTokens=providerGeneration.outputTokens,
        )
        request.state.usesNetwork = providerGeneration.usesNetwork
        if aigc.header is not None:
            httpResponse.headers[AIGC_VERSION_HEADER] = AIGC_VERSION
            httpResponse.headers[AIGC_HEADER] = aigc.header
        return response

    @gatewayApplication.post(
        "/v1/agent/requests",
        response_model=GatewayAgentSuccessResponse,
        responses={
            **JSON_BOUNDARY_RESPONSES,
            400: {"model": GatewayErrorResponse},
            401: {"model": GatewayErrorResponse},
            413: {"model": GatewayErrorResponse},
            415: {"model": GatewayErrorResponse},
            429: {"model": GatewayErrorResponse},
            500: {"model": GatewayErrorResponse},
            502: {"model": GatewayErrorResponse},
            503: {"model": GatewayErrorResponse},
            504: {"model": GatewayErrorResponse},
        },
        dependencies=[Depends(requireDevelopmentBearer)],
        tags=["agent"],
    )
    async def submitAgentRequest(
        request: Request,
        agentRequest: GatewayAgentRequest,
    ) -> GatewayAgentSuccessResponse:
        if gatewayProvider is None:
            raise GatewayHttpError(
                statusCode=503,
                code="provider_unavailable",
                message="开发演示接口未启用",
                retryable=False,
            )
        try:
            # deadline 只包围 Provider 调用，避免把请求解析和响应序列化误判为 Provider 超时。
            async with asyncio.timeout(gatewaySettings.providerTimeoutSeconds):
                agentResponse = await gatewayProvider.generate(agentRequest)
        except TimeoutError as providerError:
            raise GatewayHttpError(
                statusCode=504,
                code="provider_timeout",
                message="Mock Provider 未在期限内完成",
                retryable=False,
            ) from providerError
        except ProviderUnavailableError as providerError:
            raise GatewayHttpError(
                statusCode=503,
                code="provider_unavailable",
                message="Mock Provider 暂不可用",
                retryable=True,
            ) from providerError
        except InvalidProviderResponseError as providerError:
            raise GatewayHttpError(
                statusCode=502,
                code="invalid_provider_response",
                message="Mock Provider 返回结构无效",
                retryable=False,
            ) from providerError

        return GatewayAgentSuccessResponse(
            operationId=_operationId(request),
            clientRequestId=agentRequest.clientRequestId,
            agentResponse=agentResponse,
        )

    return gatewayApplication


def _resolveAccountLifecycle(
    settings: GatewaySettings,
    accounts: AccountService | None,
    ownedMySqlDatabase: MySqlAccountDatabase | None,
    injected: AccountLifecycleService | None,
    *,
    withCloud: bool = False,
    cloudCursorSecret: bytes | None = None,
) -> AccountLifecycleService | None:
    if injected is not None:
        if settings.usesPnvs:
            raise ValueError("PNVS 启动配置不能同时注入验证码生命周期")
        if injected.accounts is not accounts:
            raise ValueError("验证码生命周期与登录服务必须绑定同一个账户服务")
        return injected
    if accounts is None:
        return None
    if not (settings.enableTask018FakeIdentity or settings.usesPnvs):
        return None
    lifecycleStore: LifecycleStore
    budgetDatabase: AccountSqlDatabase
    if ownedMySqlDatabase is not None:
        lifecycleStore = MySqlLifecycleStore(
            ownedMySqlDatabase, withCloud=withCloud, withRetention=settings.enableAccountRetention
        )
        budgetDatabase = ownedMySqlDatabase
    elif accounts.store.authorityKey[0] == "sqlite":
        database = GatewayDatabase(Path(accounts.store.authorityKey[1]))
        lifecycleStore = SqliteLifecycleStore(
            database, withCloud=withCloud, withRetention=settings.enableAccountRetention
        )
        budgetDatabase = SqliteAccountDatabase(database)
    else:
        raise ValueError("注入 MySQL 账户时必须显式提供同库的验证码生命周期")
    if settings.usesPnvs:
        runtimePath, credentialsPath = settings.pnvsRuntimePath, settings.pnvsCredentialsPath
        if runtimePath is None or credentialsPath is None:
            raise ValueError("pnvs_configuration_missing")
        trialPolicy = (
            None
            if settings.volunteerTrialPolicyPath is None
            else loadVolunteerTrialPolicy(settings.volunteerTrialPolicyPath)
        )
        runtime = (
            loadPnvsRuntimeSettings(runtimePath)
            if trialPolicy is None
            else loadPnvsRuntimeSettings(runtimePath, trialPolicy=trialPolicy)
        )
        if cloudCursorSecret is not None and any(
            hmac.compare_digest(cloudCursorSecret, secret)
            for secret in (runtime.otpSecret, runtime.auditSecret)
        ):
            raise CloudRuntimeLoadError()
        if (
            trialPolicy is None
            and runtime.policy.expiresAtUtc <= datetime.now(UTC)
            and settings.openTestPolicy is None
        ):
            raise ValueError("pnvs_runtime_policy_expired")
        ledger = SmsBudgetLedger(
            budgetDatabase,
            runtime.policy,
            auditSecret=runtime.auditSecret,
            withSummary=settings.enableSmsAttemptRetention,
            openTestPolicy=settings.openTestPolicy,
        )
        # 先证明政策已由管理身份批准，再加载 AccessKey。构造/重启不批准。
        ledger.assertApprovedPolicy()
        sender = PnvsSmsSender(ledger, PnvsSmsTransport(loadPnvsCredentials(credentialsPath)))
        return AccountLifecycleService(
            accounts,
            sender,
            otpSecret=runtime.otpSecret,
            store=lifecycleStore,
            enableRecoveryCodes=settings.enableRecoveryCodes,
            trialPeerMaximum=(
                None if trialPolicy is None else min(trialPolicy.smsMaximumAttempts, 20)
            ),
        )
    return AccountLifecycleService(
        accounts,
        FakeSmsSender(),
        # 仅开发 Fake 分支；真实秘密稳定保存在独立受限运行文件内。
        otpSecret=b"task026-development-only-otp-secret-never-production",
        store=lifecycleStore,
        enableRecoveryCodes=settings.enableRecoveryCodes,
    )


def _resolveTask018Services(
    settings: GatewaySettings,
    *,
    accountService: AccountService | None,
    usagePolicy: UsagePolicyService | None,
    withCloud: bool = False,
) -> tuple[AccountService | None, UsagePolicyService | None, MySqlAccountDatabase | None]:
    if settings.usesPnvs and (accountService is not None or usagePolicy is not None):
        raise ValueError("PNVS 启动配置不能同时注入账户或用量服务")
    if (accountService is None) != (usagePolicy is None):
        raise ValueError("AccountService 与 UsagePolicyService 必须同时注入")
    if accountService is not None and usagePolicy is not None:
        authority = accountService.store.authorityKey
        if authority != usagePolicy.authorityKey:
            raise ValueError("账户与用量必须使用同一个权威数据库")
        if authority[0] != settings.databaseBackend:
            raise ValueError("注入服务与配置的数据库后端不匹配")
        if settings.databaseBackend == "mysql":
            config = _mySqlConfig(settings)
            expected = ("mysql", config.host.lower(), str(config.port), config.database)
            if authority != expected:
                raise ValueError("注入服务与配置的权威数据库不匹配")
        elif settings.task018DatabasePath is not None and authority != (
            "sqlite",
            str(settings.task018DatabasePath.resolve()),
        ):
            raise ValueError("注入服务与配置的权威数据库不匹配")
        return accountService, usagePolicy, None
    if not (settings.enableTask018FakeIdentity or settings.usesPnvs):
        return None, None, None
    if settings.databaseBackend == "mysql":
        database = MySqlAccountDatabase(_mySqlConfig(settings))
        try:
            # 业务进程只检查最新结构，不执行 DDL、不回退到 SQLite。
            with database.transaction() as connection:
                if settings.enableAccountRetention:
                    from .account_retention_permissions import validateRetentionWebPrivileges
                    from .account_retention_schema import validateMySqlRetentionSchema

                    if settings.enableSmsAttemptRetention:
                        from .account_retention_permissions import validateSmsSummaryWebPrivileges
                        from .sms_attempt_retention_schema import validateMySqlSmsSummarySchema

                        validateMySqlSmsSummarySchema(connection)
                        validateSmsSummaryWebPrivileges(connection)
                    else:
                        validateMySqlRetentionSchema(connection)
                    validateRetentionWebPrivileges(connection)
                elif settings.enableRecoveryCodes:
                    from .recovery_schema import validateMySqlRecoverySchema

                    validateMySqlRecoverySchema(connection)
                elif settings.enableAccountPrivileges:
                    from .privilege_schema import validateMySqlPrivilegeSchema

                    validateMySqlPrivilegeSchema(connection)
                elif withCloud:
                    from .mysql_cloud_schema import validateCloudSchema

                    validateCloudSchema(connection)
                else:
                    (validateSmsSchema if settings.usesPnvs else validateFullGatewaySchema)(
                        connection
                    )
                if settings.openTestPolicy is not None and settings.openTestPolicy.enabled:
                    from .open_test import validateOpenTestSmsPrivileges

                    validateOpenTestSmsPrivileges(connection)
            return (
                AccountService(
                    MySqlAccountStore(database),
                    None if settings.usesPnvs else FakePhoneOwnershipVerifier(),
                ),
                UsagePolicyService(
                    MySqlUsageStore(database, withPrivileges=settings.enableAccountPrivileges),
                    openTestPolicy=settings.openTestPolicy,
                ),
                database,
            )
        except Exception:
            database.close()
            raise
    if settings.task018DatabasePath is None:
        raise ValueError("SQLite 身份服务需要数据库路径")

    task018Database = GatewayDatabase(settings.task018DatabasePath)
    if settings.enableAccountPrivileges:
        from .privilege_schema import validateSqlitePrivilegeSchema

        validateSqlitePrivilegeSchema(
            task018Database,
            withRecovery=settings.enableRecoveryCodes,
            withRetention=settings.enableAccountRetention,
            withSmsSummary=settings.enableSmsAttemptRetention,
            withSmsUnresolved=settings.enableSmsAttemptRetention,
        )
    elif settings.usesPnvs or withCloud:
        task018Database.checkSchema(withCloud=withCloud)
    else:
        task018Database.initialize()
    return (
        AccountService(
            task018Database, None if settings.usesPnvs else FakePhoneOwnershipVerifier()
        ),
        UsagePolicyService(
            SqliteUsageStore(task018Database, withPrivileges=True)
            if settings.enableAccountPrivileges
            else task018Database,
            openTestPolicy=settings.openTestPolicy,
        ),
        None,
    )


def _mySqlConfig(settings: GatewaySettings) -> MySqlConfig:
    if not settings.databaseDsn or settings.databaseTlsCaFile is None:
        raise ValueError("MySQL 身份服务需要完整 DSN 和 TLS 配置")
    if settings.executionEnvironment != "production" and not settings.databaseExpiresAtUtc:
        raise ValueError("开发数据库需要显式到期配置")
    return MySqlConfig.fromDsn(
        settings.databaseDsn,
        settings.databaseTlsCaFile,
        None if settings.executionEnvironment == "production" else settings.databaseExpiresAtUtc,
    )


def _resolveRemoteResumeProvider(
    settings: GatewaySettings,
    remoteResumeProvider: RemoteResumeProvider | None,
) -> RemoteResumeProvider:
    if remoteResumeProvider is not None:
        return remoteResumeProvider
    if settings.remoteProviderMode == "fake":
        return FakeRemoteResumeProvider()
    if settings.glmApiKey is None:
        raise ValueError("GLM API Key 未配置")
    return GlmRemoteResumeProvider(
        GlmProviderConfig(
            apiKey=settings.glmApiKey,
            requestTimeoutSeconds=settings.remoteProviderRequestTimeoutSeconds,
            maximumActiveRequests=settings.remoteProviderMaximumActiveRequests,
            maximumQueuedRequests=settings.remoteProviderMaximumQueuedRequests,
            queueWaitSeconds=settings.remoteProviderQueueWaitSeconds,
        ),
        trialBudget=(
            None
            if settings.volunteerTrialPolicyPath is None
            else TrialModelBudget(
                settings.volunteerTrialPolicyPath.parent / "model-dispatches.sqlite3",
                loadVolunteerTrialPolicy(settings.volunteerTrialPolicyPath),
                openTestPolicy=settings.openTestPolicy,
            )
        ),
    )


def _authenticateAccountSession(
    accountService: AccountService,
    credentials: HTTPAuthorizationCredentials | None,
) -> AuthenticatedSubject:
    suppliedToken = None if credentials is None else credentials.credentials
    suppliedScheme = None if credentials is None else credentials.scheme
    if suppliedToken is None or suppliedScheme is None or suppliedScheme.lower() != "bearer":
        raise GatewayHttpError(
            statusCode=401,
            code="unauthenticated",
            message="请求身份无效",
            retryable=False,
        )
    try:
        return accountService.authenticateSession(suppliedToken)
    except AuthenticationFailedError as authenticationError:
        raise GatewayHttpError(
            statusCode=401,
            code="unauthenticated",
            message="请求身份无效",
            retryable=False,
        ) from authenticationError


def _remoteRequestFingerprint(resumeAiRequest: RemoteResumeAiRequest) -> str:
    # clientRequestId 和幂等键都是传输元数据；业务指纹只覆盖实际能力与字段投影。
    canonicalRequest = json.dumps(
        {
            "capability": resumeAiRequest.capability.value,
            "input": resumeAiRequest.input.model_dump(mode="json", exclude_none=True),
        },
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    return hashOperationValue(canonicalRequest)


def _raiseForUsageReplay(usageOperation: UsageOperation) -> Never:
    replayErrorByStatus = {
        UsageOperationStatus.reserved: (
            "operation_in_progress",
            "同一请求正在执行",
        ),
        UsageOperationStatus.committed: (
            "operation_already_completed",
            "同一请求已经完成，请使用客户端已保存结果",
        ),
        UsageOperationStatus.released: (
            "operation_released",
            "原请求未结算，请使用新的幂等键明确重试",
        ),
        UsageOperationStatus.pendingReconciliation: (
            "operation_pending_reconciliation",
            "原请求结果待对账，不得自动重试",
        ),
    }
    errorCode, errorMessage = replayErrorByStatus[usageOperation.status]
    raise GatewayHttpError(
        statusCode=409,
        code=errorCode,
        message=errorMessage,
        retryable=False,
    )


def _operationId(request: Request) -> str:
    operationId = getattr(request.state, "operationId", None)
    if not isinstance(operationId, str):
        return "operation-unavailable"
    return operationId


def _errorResponse(
    request: Request,
    *,
    statusCode: int,
    code: str,
    message: str,
    retryable: bool,
    issues: tuple[GatewayErrorIssue, ...] | None = None,
    responseHeaders: dict[str, str] | None = None,
) -> JSONResponse:
    errorPayload = GatewayErrorResponse(
        error=GatewayError(
            code=code,
            message=message,
            operationId=_operationId(request),
            retryable=retryable,
            issues=issues,
        )
    )
    payload = errorPayload.model_dump(mode="json", exclude_none=True)
    if request.headers.get("x-operation-protocol") == "0.4.0":
        payload["error"].update(
            {
                "operationProtocolVersion": "0.4.0",
                "traceId": _operationId(request),
                "usageOperationId": getattr(request.state, "usageOperationId", None),
            }
        )
    return JSONResponse(
        status_code=statusCode,
        content=payload,
        headers=responseHeaders,
    )
