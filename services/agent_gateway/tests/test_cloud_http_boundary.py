from __future__ import annotations

import asyncio
import logging
from typing import cast

import pytest
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from agent_gateway import boundary as boundaryModule
from agent_gateway.app import createApplication
from agent_gateway.boundary import GatewayBoundaryMiddleware, GatewayConcurrencyLimiter
from agent_gateway.settings import GatewaySettings
from tests.support import TEST_BEARER_TOKEN, authorizedHeaders, sendAsgiRequest, validRequestBody

PATH = "/v1/cloud-resumes/documents/PRIVATE_DOCUMENT/versions/PRIVATE_VERSION"


def scope(
    method: str = "PUT",
    headers: list[tuple[bytes, bytes]] | None = None,
    *,
    path: str = PATH,
) -> Scope:
    return cast(
        Scope,
        {
            "type": "http",
            "method": method,
            "path": path,
            "query_string": b"cursor=PRIVATE_QUERY",
            "headers": headers if headers is not None else [(b"content-type", b"application/json")],
        },
    )


def middleware(
    app: ASGIApp,
    *,
    seconds: float = 10,
    limit: int = 65536,
    logger: logging.Logger | None = None,
) -> GatewayBoundaryMiddleware:
    return GatewayBoundaryMiddleware(
        app,
        settings=GatewaySettings(maxRequestBodyBytes=limit, maxRequestBodySeconds=seconds),
        concurrencyLimiter=GatewayConcurrencyLimiter(1),
        auditLogger=logger or logging.getLogger("agent_gateway.tests.cloud_boundary"),
    )


def runRequest(
    boundary: GatewayBoundaryMiddleware, requestScope: Scope, messages: list[Message]
) -> list[Message]:
    output: list[Message] = []

    async def receive() -> Message:
        return messages.pop(0) if messages else {"type": "http.disconnect"}

    async def send(message: Message) -> None:
        output.append(message)

    asyncio.run(boundary(requestScope, receive, send))
    return output


def status(messages: list[Message]) -> int:
    return cast(
        int,
        next(message["status"] for message in messages if message["type"] == "http.response.start"),
    )


class EchoApplication:
    def __init__(self) -> None:
        self.calls = 0
        self.received: list[Message] = []

    async def __call__(self, requestScope: Scope, receive: Receive, send: Send) -> None:
        del requestScope
        self.calls += 1
        while True:
            item = await receive()
            self.received.append(item)
            if not item.get("more_body", False):
                break
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"{}"})


@pytest.mark.parametrize("method", ["POST", "PUT", "PATCH", "DELETE"])
def test_dynamic_cloud_writes_reject_media_type_and_oversize_before_application(
    method: str,
) -> None:
    app = EchoApplication()
    boundary = middleware(app, limit=16)
    invalidType = runRequest(boundary, scope(method, [(b"content-type", b"text/plain")]), [])
    assert status(invalidType) == 415
    headers = [(b"content-type", b"application/json"), (b"content-length", b"17")]
    tooLarge = runRequest(boundary, scope(method, headers), [])
    assert status(tooLarge) == 413 and app.calls == 0
    assert all(
        any(name == b"x-operation-id" for name, _ in message["headers"])
        for message in (invalidType[0], tooLarge[0])
    )


def test_chunked_body_limit_uses_actual_bytes_and_releases_slot_after_failure() -> None:
    app = EchoApplication()
    boundary = middleware(app, limit=8)
    failed = runRequest(
        boundary,
        scope(headers=[(b"content-type", b"application/json"), (b"content-length", b"1")]),
        [
            {"type": "http.request", "body": b'{"x":"', "more_body": True},
            {"type": "http.request", "body": b'private"}', "more_body": False},
        ],
    )
    assert status(failed) == 413 and app.calls == 0
    valid = runRequest(
        boundary, scope(), [{"type": "http.request", "body": b"{}", "more_body": False}]
    )
    assert status(valid) == 200 and app.calls == 1


def test_empty_and_single_byte_chunks_are_coalesced_without_changing_body() -> None:
    app = EchoApplication()
    body = b'{"x":1}'
    frames: list[Message] = [
        {"type": "http.request", "body": b"", "more_body": True} for _ in range(2000)
    ]
    frames.extend(
        {"type": "http.request", "body": bytes([value]), "more_body": True} for value in body
    )
    frames.append({"type": "http.request", "body": b"", "more_body": False})
    result = runRequest(middleware(app), scope(), frames)
    assert status(result) == 200 and len(app.received) == 1
    assert app.received[0]["body"] == body and app.received[0]["more_body"] is False


@pytest.mark.parametrize(
    "body",
    [
        b'{"x":1,"x":2}',
        b'{"nested":{"x":1,"x":2}}',
        b'{"x":NaN}',
        b'{"x":Infinity}',
        b'{"x":1e999}',
        b"\xff",
        b"\xef\xbb\xbf{}",
        b'{"PRIVATE_BODY"',
        b"[" * 1500 + b"]" * 1500,
    ],
)
def test_invalid_json_is_rejected_without_business_call_or_private_echo(body: bytes) -> None:
    app = EchoApplication()
    result = runRequest(
        middleware(app), scope(), [{"type": "http.request", "body": body, "more_body": False}]
    )
    assert status(result) == 400 and app.calls == 0
    encoded = b"".join(
        message.get("body", b"") for message in result if message["type"] == "http.response.body"
    ).decode()
    assert "PRIVATE_BODY" not in encoded


@pytest.mark.parametrize(
    "headers",
    [
        [(b"content-length", b"2"), (b"content-length", b"2")],
        [(b"content-length", b"2"), (b"content-length", b"3")],
        [(b"content-length", b"-1")],
        [(b"content-length", b"+2")],
        [(b"content-length", b"2,2")],
        [(b"content-length", b"1" * 21)],
        [(b"content-length", b"2"), (b"transfer-encoding", b"chunked")],
    ],
)
def test_ambiguous_lengths_fail_before_consuming_body(headers: list[tuple[bytes, bytes]]) -> None:
    app = EchoApplication()
    result = runRequest(
        middleware(app), scope(headers=[(b"content-type", b"application/json"), *headers]), []
    )
    assert status(result) == 400 and app.calls == 0


def test_disconnect_or_invalid_stream_never_calls_application() -> None:
    app = EchoApplication()
    boundary = middleware(app)
    for last in ({"type": "http.disconnect"}, {"type": "unexpected"}):
        result = runRequest(
            boundary,
            scope(),
            [{"type": "http.request", "body": b'{"private":', "more_body": True}, last],
        )
        assert status(result) == 400
    assert app.calls == 0


def test_slow_receive_times_out_and_releases_concurrency_slot() -> None:
    async def scenario() -> None:
        app = EchoApplication()
        boundary = middleware(app, seconds=0.02)
        output: list[Message] = []

        async def slow() -> Message:
            await asyncio.sleep(1)
            return {"type": "http.request", "body": b"{}"}

        async def send(message: Message) -> None:
            output.append(message)

        await boundary(scope(), slow, send)
        assert status(output) == 408 and app.calls == 0
        output.clear()

        async def fast() -> Message:
            return {"type": "http.request", "body": b"{}"}

        await boundary(scope(), fast, send)
        assert status(output) == 200 and app.calls == 1

    asyncio.run(scenario())


def test_immediately_available_empty_frames_cannot_extend_receive_deadline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ticks = [0.0]

    def advancingClock() -> float:
        ticks[0] += 0.5
        return ticks[0]

    monkeypatch.setattr(boundaryModule, "monotonic", advancingClock)
    app = EchoApplication()
    frames: list[Message] = [
        {"type": "http.request", "body": b"", "more_body": True} for _ in range(100)
    ]
    result = runRequest(middleware(app), scope(), frames)
    assert status(result) == 408 and app.calls == 0 and frames


def test_cloud_read_and_write_share_concurrency_limiter_and_audit_uses_only_template(
    caplog: pytest.LogCaptureFixture,
) -> None:
    async def scenario() -> None:
        entered, allowed = asyncio.Event(), asyncio.Event()
        logger = logging.getLogger("agent_gateway.tests.cloud_audit")
        caplog.set_level(logging.INFO, logger=logger.name)

        async def blocking(requestScope: Scope, receive: Receive, send: Send) -> None:
            del requestScope, receive
            entered.set()
            await allowed.wait()
            await send({"type": "http.response.start", "status": 200, "headers": []})
            await send({"type": "http.response.body", "body": b"{}"})

        boundary = middleware(blocking, logger=logger)

        async def empty() -> Message:
            return {"type": "http.request", "body": b""}

        async def jsonBody() -> Message:
            return {"type": "http.request", "body": b"{}"}

        firstMessages: list[Message] = []
        secondMessages: list[Message] = []

        async def firstSend(message: Message) -> None:
            firstMessages.append(message)

        async def secondSend(message: Message) -> None:
            secondMessages.append(message)

        first = asyncio.create_task(boundary(scope("GET", []), empty, firstSend))
        await asyncio.wait_for(entered.wait(), 1)
        await boundary(scope(), jsonBody, secondSend)
        assert status(secondMessages) == 429
        allowed.set()
        await first
        assert status(firstMessages) == 200
        assert all("PRIVATE_" not in message for message in caplog.messages)
        assert any(
            "cloudResumeSync" in message and "{resource}" in message for message in caplog.messages
        )

    asyncio.run(scenario())


def test_cloud_get_body_is_rejected_and_lookalike_namespace_does_not_match() -> None:
    app = EchoApplication()
    boundary = middleware(app)
    failed = runRequest(boundary, scope("GET", []), [{"type": "http.request", "body": b"private"}])
    assert status(failed) == 400 and app.calls == 0
    unrelated = runRequest(
        boundary,
        scope("PUT", [], path="/v1/cloud-resumes-other"),
        [{"type": "http.request", "body": b"ordinary"}],
    )
    assert status(unrelated) == 200 and app.calls == 1


def test_legacy_gateway_unknown_field_name_is_not_reflected_to_client() -> None:
    application = createApplication(settings=GatewaySettings(testBearerToken=TEST_BEARER_TOKEN))
    response = sendAsgiRequest(
        application,
        "POST",
        "/v1/agent/requests",
        headers=authorizedHeaders(),
        jsonBody=validRequestBody() | {"PRIVATE_FIELD_NAME": "synthetic"},
    )
    assert response.status_code == 400 and "PRIVATE_FIELD_NAME" not in response.text
    assert response.json()["error"]["issues"][0]["path"] == "$"
