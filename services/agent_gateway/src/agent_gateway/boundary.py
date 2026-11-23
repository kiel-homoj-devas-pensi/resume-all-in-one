from __future__ import annotations

import asyncio
import json
import logging
import math
from time import monotonic
from typing import cast
from uuid import uuid4

from starlette.types import ASGIApp, Message, Receive, Scope, Send

from .contracts import GatewayError, GatewayErrorResponse
from .settings import GatewaySettings


class _RequestBodyTooLargeError(Exception):
    pass


class _RequestStreamError(Exception):
    pass


class GatewayConcurrencyLimiter:
    def __init__(self, maximumConcurrentRequests: int) -> None:
        self._maximumConcurrentRequests = maximumConcurrentRequests
        self._activeRequestCount = 0
        self._stateLock = asyncio.Lock()

    async def tryAcquire(self) -> bool:
        async with self._stateLock:
            if self._activeRequestCount >= self._maximumConcurrentRequests:
                return False
            self._activeRequestCount += 1
            return True

    async def release(self) -> None:
        async with self._stateLock:
            if self._activeRequestCount == 0:
                raise RuntimeError("并发槽位释放次数超过获取次数")
            self._activeRequestCount -= 1


class GatewayBoundaryMiddleware:
    _limitedJsonPaths = {
        "/v1/agent/requests",
        "/v1/resume-ai/requests",
        "/v1/accounts",
        "/v1/account-sessions",
        "/v1/resume-ai/operations/lookup",
        "/v1/resume-ai/results/lookup",
        "/v2/account-verifications",
        "/v2/accounts",
        "/v2/account-sessions",
        "/v2/account-sessions/revoke",
        "/v2/account/password",
        "/v2/account/password-reset",
        "/v2/account/deactivate",
        "/v2/account/rights-request-receipt",
    }

    def __init__(
        self,
        app: ASGIApp,
        *,
        settings: GatewaySettings,
        concurrencyLimiter: GatewayConcurrencyLimiter,
        auditLogger: logging.Logger,
    ) -> None:
        self._app = app
        self._settings = settings
        self._concurrencyLimiter = concurrencyLimiter
        self._auditLogger = auditLogger

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return

        operationId = f"operation-{uuid4()}"
        requestState = cast(dict[str, object], scope.setdefault("state", {}))
        requestState["operationId"] = operationId
        requestPath = scope.get("path", "")
        requestStartedAt = monotonic()
        responseStatusCode = 500

        async def sendWithOperationId(message: Message) -> None:
            nonlocal responseStatusCode
            if message["type"] == "http.response.start":
                responseStatusCode = message["status"]
                responseHeaders = list(message.get("headers", []))
                if _cloudPath(requestPath):
                    responseHeaders = [
                        header
                        for header in responseHeaders
                        if header[0].lower() != b"cache-control"
                    ]
                    responseHeaders.append((b"cache-control", b"no-store"))
                responseHeaders.append((b"x-operation-id", operationId.encode("ascii")))
                message["headers"] = responseHeaders
            await send(message)

        acquiredConcurrencySlot = False
        try:
            cloudRequest = _cloudPath(requestPath)
            jsonRequest = (
                requestPath in self._limitedJsonPaths and scope.get("method") == "POST"
            ) or (cloudRequest and scope.get("method") in {"POST", "PUT", "PATCH", "DELETE"})
            if not jsonRequest and not cloudRequest:
                await self._app(scope, receive, sendWithOperationId)
                return

            contentType = _readHeader(scope, b"content-type")
            if jsonRequest and (
                contentType is None
                or contentType.split(b";", 1)[0].strip().lower() != b"application/json"
            ):
                responseStatusCode = 415
                await _sendGatewayError(
                    sendWithOperationId,
                    operationId=operationId,
                    statusCode=415,
                    code="invalid_request",
                    message="请求必须使用 application/json",
                    retryable=False,
                )
                return

            declaredContentLength = _readDeclaredContentLength(scope)
            if declaredContentLength is None:
                pass
            elif declaredContentLength < 0 or (
                declaredContentLength is not None
                and _readHeader(scope, b"transfer-encoding") is not None
            ):
                responseStatusCode = 400
                await _sendGatewayError(
                    sendWithOperationId,
                    operationId=operationId,
                    statusCode=400,
                    code="invalid_request",
                    message="Content-Length 不合法",
                    retryable=False,
                )
                return
            elif declaredContentLength > self._settings.maxRequestBodyBytes:
                responseStatusCode = 413
                await _sendGatewayError(
                    sendWithOperationId,
                    operationId=operationId,
                    statusCode=413,
                    code="invalid_request",
                    message="请求体超过允许上限",
                    retryable=False,
                )
                return

            acquiredConcurrencySlot = await self._concurrencyLimiter.tryAcquire()
            if not acquiredConcurrencySlot:
                responseStatusCode = 429
                await _sendGatewayError(
                    sendWithOperationId,
                    operationId=operationId,
                    statusCode=429,
                    code="rate_limited",
                    message="当前请求过多，请稍后重试",
                    retryable=True,
                    headers=((b"retry-after", b"1"),),
                )
                return

            try:
                receiveDeadline = monotonic() + self._settings.maxRequestBodySeconds
                async with asyncio.timeout(self._settings.maxRequestBodySeconds):
                    bufferedRequestMessages = await _bufferRequestMessages(
                        receive,
                        maximumBodyBytes=self._settings.maxRequestBodyBytes,
                        deadline=receiveDeadline,
                    )
            except _RequestBodyTooLargeError:
                responseStatusCode = 413
                await _sendGatewayError(
                    sendWithOperationId,
                    operationId=operationId,
                    statusCode=413,
                    code="invalid_request",
                    message="请求体超过允许上限",
                    retryable=False,
                )
                return
            except TimeoutError:
                await _sendGatewayError(
                    sendWithOperationId,
                    operationId=operationId,
                    statusCode=408,
                    code="request_timeout",
                    message="请求体接收超时",
                    retryable=False,
                )
                return
            except _RequestStreamError:
                await _sendGatewayError(
                    sendWithOperationId,
                    operationId=operationId,
                    statusCode=400,
                    code="invalid_request",
                    message="请求体未完整接收",
                    retryable=False,
                )
                return

            body = bufferedRequestMessages[0]["body"]
            if (not jsonRequest and body) or (jsonRequest and not _validJson(body)):
                await _sendGatewayError(
                    sendWithOperationId,
                    operationId=operationId,
                    statusCode=400,
                    code="invalid_request",
                    message="请求不符合 JSON 契约",
                    retryable=False,
                )
                return

            nextBufferedMessageIndex = 0

            async def receiveBufferedRequest() -> Message:
                nonlocal nextBufferedMessageIndex
                if nextBufferedMessageIndex < len(bufferedRequestMessages):
                    bufferedMessage = bufferedRequestMessages[nextBufferedMessageIndex]
                    nextBufferedMessageIndex += 1
                    return bufferedMessage
                return await receive()

            await self._app(scope, receiveBufferedRequest, sendWithOperationId)
        finally:
            if acquiredConcurrencySlot:
                await self._concurrencyLimiter.release()
            durationMilliseconds = int((monotonic() - requestStartedAt) * 1000)
            _writeBoundaryAuditEvent(
                self._auditLogger,
                operationId=operationId,
                routeName=_auditRouteName(requestPath),
                responseStatusCode=responseStatusCode,
                durationMilliseconds=durationMilliseconds,
                capability=_auditCapability(requestPath, requestState),
                usesNetwork=requestState.get("usesNetwork") is True,
            )


def _readHeader(scope: Scope, headerName: bytes) -> bytes | None:
    requestHeaders = cast(list[tuple[bytes, bytes]], scope.get("headers", []))
    for currentName, currentValue in requestHeaders:
        if currentName.lower() == headerName:
            return currentValue
    return None


def _readDeclaredContentLength(scope: Scope) -> int | None:
    values = [
        value for name, value in scope.get("headers", []) if name.lower() == b"content-length"
    ]
    if not values:
        return None
    if len(values) != 1 or not values[0].isdigit() or len(values[0]) > 20:
        return -1
    return int(values[0])


async def _bufferRequestMessages(
    receive: Receive,
    *,
    maximumBodyBytes: int,
    deadline: float,
) -> tuple[Message, ...]:
    body = bytearray()
    while True:
        requestMessage = await receive()
        if monotonic() >= deadline:
            # 即使接收器连续立即返回空帧、不让事件循环切换，也不能延长接收期限。
            raise TimeoutError
        if requestMessage["type"] != "http.request":
            raise _RequestStreamError

        chunk = requestMessage.get("body", b"")
        if len(body) + len(chunk) > maximumBodyBytes:
            raise _RequestBodyTooLargeError
        body.extend(chunk)
        if not requestMessage.get("more_body", False):
            break

    # 合并内容而非缓存帧：空分块不会增加内存；容量仍按原始字节累计。
    return ({"type": "http.request", "body": bytes(body), "more_body": False},)


def _uniqueJsonKeys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("invalid_json")
        value[key] = item
    return value


def _finiteJsonFloat(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError("invalid_json")
    return parsed


def _rejectJsonConstant(value: str) -> object:
    del value
    raise ValueError("invalid_json")


def _validJson(body: bytes) -> bool:
    try:
        value = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_uniqueJsonKeys,
            parse_constant=_rejectJsonConstant,
            parse_float=_finiteJsonFloat,
        )
        pending: list[tuple[object, int]] = [(value, 1)]
        while pending:
            item, depth = pending.pop()
            if isinstance(item, dict | list):
                if depth > 64:
                    return False
                children = item.values() if isinstance(item, dict) else item
                pending.extend((child, depth + 1) for child in children)
        return True
    except ValueError, UnicodeError, RecursionError:
        return False


def _cloudPath(path: str) -> bool:
    return path == "/v1/cloud-resumes" or path.startswith("/v1/cloud-resumes/")


async def _sendGatewayError(
    send: Send,
    *,
    operationId: str,
    statusCode: int,
    code: str,
    message: str,
    retryable: bool,
    headers: tuple[tuple[bytes, bytes], ...] = (),
) -> None:
    errorPayload = GatewayErrorResponse(
        error=GatewayError(
            code=code,
            message=message,
            operationId=operationId,
            retryable=retryable,
        )
    )
    responseBody = json.dumps(
        errorPayload.model_dump(mode="json", exclude_none=True),
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    responseHeaders = [
        (b"content-type", b"application/json; charset=utf-8"),
        (b"content-length", str(len(responseBody)).encode("ascii")),
        *headers,
    ]
    await send({"type": "http.response.start", "status": statusCode, "headers": responseHeaders})
    await send({"type": "http.response.body", "body": responseBody})


def _writeBoundaryAuditEvent(
    auditLogger: logging.Logger,
    *,
    operationId: str,
    routeName: str,
    responseStatusCode: int,
    durationMilliseconds: int,
    capability: str,
    usesNetwork: bool,
) -> None:
    # 只允许固定元数据进入日志；正文、Header 与异常对象根本不进入该函数参数。
    auditLogger.info(
        "gateway_request operationId=%s route=%s statusCode=%d durationMs=%d "
        "capability=%s usesNetwork=%s",
        operationId,
        routeName,
        responseStatusCode,
        durationMilliseconds,
        capability,
        str(usesNetwork).lower(),
    )


def _auditRouteName(requestPath: str) -> str:
    if _cloudPath(requestPath):
        return "/v1/cloud-resumes/{resource}"
    fixedRoutes = {
        "/health/live",
        "/health/ready",
        "/v1/agent/requests",
        "/v1/resume-ai/requests",
        "/v1/accounts",
        "/v1/account-sessions",
    }
    if requestPath in fixedRoutes:
        return requestPath
    if requestPath.startswith("/v1/account/access/"):
        return "/v1/account/access/{capability}"
    if requestPath in {"/docs", "/docs/oauth2-redirect", "/openapi.json"}:
        return "documentation"
    return "unmatched"


def _auditCapability(requestPath: str, requestState: dict[str, object]) -> str:
    if _cloudPath(requestPath):
        return "cloudResumeSync"
    if requestPath == "/v1/agent/requests":
        return "gatewayContractProbe"
    if requestPath == "/v1/resume-ai/requests":
        validatedCapability = requestState.get("auditCapability")
        if validatedCapability in {
            "basicResumeCompose",
            "targetedResumeOptimization",
            "resumeOptimizationConversation",
        }:
            return str(validatedCapability)
        return "remoteResumeAi"
    if requestPath.startswith("/v1/account/access/"):
        return "accessDecision"
    return "none"
