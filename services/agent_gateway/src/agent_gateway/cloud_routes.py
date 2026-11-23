import base64
import binascii
from dataclasses import asdict
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Path, Query, Request
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from .account_storage import StorageUnavailableError
from .canonical_snapshot import MAXIMUM_SNAPSHOT_BYTES, CanonicalSnapshot
from .cloud_contracts import (
    CloudActionRequest,
    CloudConsentRequest,
    CloudDocumentPageResponse,
    CloudOperationId,
    CloudOperationResponse,
    CloudOptionsResponse,
    CloudProtocol,
    CloudSnapshotResponse,
    CloudVersionPageResponse,
    PolicyFingerprint,
)
from .cloud_storage import CloudNotAccessible, CloudResumeStore, CloudSession
from .contracts import JSON_BOUNDARY_RESPONSES, GatewayErrorResponse
from .identity import AccountService, AuthenticationFailedError, hashSecret


class CloudRequestError(ValueError):
    def __init__(self, code: str, statusCode: int = 400) -> None:
        super().__init__(code)
        self.code = code
        self.statusCode = statusCode


def decodeCloudResourceKey(value: str) -> str:
    # URI 只承载原稳定 ID 的规范无填充 base64url，不生成另一套数据库身份。
    try:
        if not 1 <= len(value) <= 683 or not value.isascii():
            raise ValueError
        raw = base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
        if not 1 <= len(raw) <= 512 or base64.urlsafe_b64encode(raw).decode().rstrip("=") != value:
            raise ValueError
        identity = raw.decode("utf-8")
        if not identity.strip():
            raise ValueError
        return identity
    except ValueError, UnicodeError, binascii.Error:
        raise CloudRequestError("invalid_cloud_resource_key") from None


def _singleHeader(request: Request, name: str, *, required: bool = True) -> str | None:
    values = request.headers.getlist(name)
    if (required and len(values) != 1) or len(values) > 1:
        raise CloudRequestError("invalid_cloud_headers")
    return values[0] if values else None


def _response(model: BaseModel) -> JSONResponse:
    response = JSONResponse(model.model_dump(mode="json"))
    # 单页项目先限额，最终再核对协议封装、游标和 UTF-8 编码后的实际字节。
    if len(response.body) > 65_536:
        raise StorageUnavailableError("cloud_response_unavailable")
    return response


def cloudRouter(
    store: CloudResumeStore | None, accounts: AccountService | None, *, maximumRequestBytes: int
) -> APIRouter:
    router = APIRouter(prefix="/v1/cloud-resumes", tags=["cloud-resumes"])
    bearer = HTTPBearer(
        auto_error=False,
        scheme_name="AccountSessionBearer",
        description="Task 018 opaque account session；数据库只保存 token 哈希。",
    )
    errors = {
        **JSON_BOUNDARY_RESPONSES,
        401: {"model": GatewayErrorResponse},
        404: {"model": GatewayErrorResponse},
        409: {"model": GatewayErrorResponse},
        503: {
            "model": GatewayErrorResponse,
            "description": "关闭/存储不可用/提交结果未知；retryable=false，先查询原操作",
        },
    }

    def requiredStore() -> CloudResumeStore:
        if store is None:
            raise CloudRequestError("cloud_sync_disabled", 503)
        return store

    def identity(
        request: Request,
        credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
        protocol: Annotated[CloudProtocol, Header(alias="X-Cloud-Protocol")],
    ) -> CloudSession:
        del protocol
        requiredStore()
        _singleHeader(request, "x-cloud-protocol")
        if any(len(request.query_params.getlist(name)) != 1 for name in request.query_params):
            raise CloudRequestError("invalid_cloud_query")
        if (
            len(request.headers.getlist("authorization")) != 1
            or credentials is None
            or credentials.scheme.lower() != "bearer"
            or not 1 <= len(credentials.credentials) <= 512
            or accounts is None
        ):
            raise AuthenticationFailedError
        subject = accounts.authenticateSession(credentials.credentials)
        return CloudSession(subject.accountId, hashSecret(credentials.credentials))

    def documentId(documentKey: Annotated[str, Path(max_length=683)]) -> str:
        return decodeCloudResourceKey(documentKey)

    def versionId(versionKey: Annotated[str, Path(max_length=683)]) -> str:
        return decodeCloudResourceKey(versionKey)

    @router.get("/options", response_model=CloudOptionsResponse, responses=errors)
    def options() -> JSONResponse:
        return _response(
            CloudOptionsResponse(
                enabled=store is not None,
                policy=None if store is None else store.policy,
                policyFingerprint=None if store is None else store.policy.fingerprint,
                maximumSnapshotBytes=min(MAXIMUM_SNAPSHOT_BYTES, maximumRequestBytes),
                maximumRequestBytes=maximumRequestBytes,
            )
        )

    @router.get("/documents", response_model=CloudDocumentPageResponse, responses=errors)
    def documents(
        session: Annotated[CloudSession, Depends(identity)],
        pageSize: Annotated[int, Query(ge=1, le=50)] = 20,
        sinceSequence: Annotated[int, Query(ge=0, le=2**63 - 1)] = 0,
        includeDeleted: Annotated[str, Query(pattern=r"^(true|false)$")] = "false",
        cursor: Annotated[str | None, Query(min_length=1, max_length=2048)] = None,
    ) -> JSONResponse:
        page = requiredStore().listDocuments(
            session,
            pageSize=pageSize,
            sinceSequence=sinceSequence,
            includeDeleted=includeDeleted == "true",
            cursor=cursor,
        )
        return _response(CloudDocumentPageResponse(**asdict(page)))

    @router.get(
        "/documents/{documentKey}/versions",
        response_model=CloudVersionPageResponse,
        responses=errors,
    )
    def versions(
        document: Annotated[str, Depends(documentId)],
        session: Annotated[CloudSession, Depends(identity)],
        pageSize: Annotated[int, Query(ge=1, le=50)] = 20,
        cursor: Annotated[str | None, Query(min_length=1, max_length=2048)] = None,
    ) -> JSONResponse:
        page = requiredStore().listVersions(session, document, pageSize=pageSize, cursor=cursor)
        return _response(CloudVersionPageResponse(**asdict(page)))

    @router.get(
        "/documents/{documentKey}/current", response_model=CloudSnapshotResponse, responses=errors
    )
    def current(
        document: Annotated[str, Depends(documentId)],
        session: Annotated[CloudSession, Depends(identity)],
    ) -> JSONResponse:
        snapshot = requiredStore().getCurrent(session, document)
        return _response(CloudSnapshotResponse(snapshot=snapshot.toJson()))

    @router.get(
        "/documents/{documentKey}/versions/{versionKey}",
        response_model=CloudSnapshotResponse,
        responses=errors,
    )
    def version(
        document: Annotated[str, Depends(documentId)],
        version: Annotated[str, Depends(versionId)],
        session: Annotated[CloudSession, Depends(identity)],
    ) -> JSONResponse:
        snapshot = requiredStore().getVersion(session, document, version)
        return _response(CloudSnapshotResponse(snapshot=snapshot.toJson()))

    @router.post(
        "/documents/{documentKey}/consents", response_model=CloudOperationResponse, responses=errors
    )
    def consent(
        body: CloudConsentRequest,
        document: Annotated[str, Depends(documentId)],
        session: Annotated[CloudSession, Depends(identity)],
    ) -> JSONResponse:
        result = requiredStore().grantConsent(
            session, document, body.clientOperationId, body.policyFingerprint
        )
        return _response(CloudOperationResponse(result=result))

    @router.post(
        "/documents/{documentKey}/consents/revoke",
        response_model=CloudOperationResponse,
        responses=errors,
    )
    def revoke(
        body: CloudActionRequest,
        document: Annotated[str, Depends(documentId)],
        session: Annotated[CloudSession, Depends(identity)],
    ) -> JSONResponse:
        result = requiredStore().revokeConsent(session, document, body.clientOperationId)
        return _response(CloudOperationResponse(result=result))

    @router.post(
        "/documents/{documentKey}/delete", response_model=CloudOperationResponse, responses=errors
    )
    def delete(
        body: CloudActionRequest,
        document: Annotated[str, Depends(documentId)],
        session: Annotated[CloudSession, Depends(identity)],
    ) -> JSONResponse:
        result = requiredStore().deleteDocument(session, document, body.clientOperationId)
        return _response(CloudOperationResponse(result=result))

    @router.get(
        "/operations/{clientOperationId}", response_model=CloudOperationResponse, responses=errors
    )
    def operation(
        clientOperationId: CloudOperationId,
        session: Annotated[CloudSession, Depends(identity)],
    ) -> JSONResponse:
        result = requiredStore().lookupOperation(session, clientOperationId)
        if result is None:
            raise CloudNotAccessible()
        return _response(CloudOperationResponse(result=result))

    def appendRaw(
        raw: bytes,
        session: CloudSession,
        document: str,
        version: str,
        operationId: str,
        fingerprint: str,
        expected: str | None,
    ) -> JSONResponse:
        snapshot = CanonicalSnapshot(raw)
        if snapshot.documentId != document or snapshot.versionId != version:
            raise CloudRequestError("cloud_snapshot_identity_mismatch")
        result = requiredStore().appendVersion(
            session, operationId, snapshot, expected, fingerprint
        )
        return _response(CloudOperationResponse(result=result))

    @router.put(
        "/documents/{documentKey}/versions/{versionKey}",
        response_model=CloudOperationResponse,
        responses=errors,
        openapi_extra={
            "requestBody": {
                "required": True,
                "content": {
                    "application/json": {
                        "schema": {
                            "type": "object",
                            "required": ["document", "version"],
                            "additionalProperties": False,
                            "properties": {
                                "document": {"type": "object"},
                                "version": {"type": "object"},
                            },
                            "description": (
                                "Canonical v0.1 完整原始快照；49152 UTF-8 字节、深度32、节点8192；"
                                "拒绝数字精度丢失，保留扩展字段"
                            ),
                        }
                    }
                },
            }
        },
    )
    async def append(
        request: Request,
        document: Annotated[str, Depends(documentId)],
        version: Annotated[str, Depends(versionId)],
        session: Annotated[CloudSession, Depends(identity)],
        operationId: Annotated[CloudOperationId, Header(alias="Idempotency-Key")],
        fingerprint: Annotated[PolicyFingerprint, Header(alias="X-Cloud-Policy-Fingerprint")],
        expectedBase: Annotated[
            str | None, Header(alias="X-Cloud-Expected-Base", min_length=1, max_length=683)
        ] = None,
    ) -> JSONResponse:
        _singleHeader(request, "idempotency-key")
        _singleHeader(request, "x-cloud-policy-fingerprint")
        _singleHeader(request, "x-cloud-expected-base", required=False)
        expected = None if expectedBase is None else decodeCloudResourceKey(expectedBase)
        raw = await request.body()
        # Request 读取是异步；严格原字节校验和同步驱动事务在原生线程池执行。
        return await run_in_threadpool(
            appendRaw, raw, session, document, version, operationId, fingerprint, expected
        )

    return router
