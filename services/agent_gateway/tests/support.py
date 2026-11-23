from __future__ import annotations

import asyncio
from collections.abc import Mapping
from typing import Any

import httpx
from starlette.types import ASGIApp

from agent_gateway.contracts import AgentResponsePayload, GatewayAgentRequest
from agent_gateway.provider import (
    InvalidProviderResponseError,
    ProviderUnavailableError,
)

TEST_BEARER_TOKEN = "task017-test-token-not-a-secret"


def validRequestBody() -> dict[str, str]:
    return {
        "protocolVersion": "0.1.0",
        "clientRequestId": "client-request-001",
        "capability": "gatewayContractProbe",
        "syntheticInput": "只用于测试的合成文本",
    }


def authorizedHeaders() -> dict[str, str]:
    return {"Authorization": f"Bearer {TEST_BEARER_TOKEN}"}


def sendAsgiRequest(
    application: ASGIApp,
    method: str,
    path: str,
    *,
    headers: Mapping[str, str] | None = None,
    jsonBody: Any | None = None,
    content: str | bytes | None = None,
    raiseAppExceptions: bool = True,
) -> httpx.Response:
    async def sendRequest() -> httpx.Response:
        transport = httpx.ASGITransport(
            app=application,
            raise_app_exceptions=raiseAppExceptions,
        )
        async with httpx.AsyncClient(
            transport=transport,
            base_url="http://gateway.test",
        ) as client:
            return await client.request(
                method,
                path,
                headers=headers,
                json=jsonBody,
                content=content,
            )

    return asyncio.run(sendRequest())


class RecordingProvider:
    def __init__(self, *, isReady: bool = True) -> None:
        self._isReady = isReady
        self.generateCallCount = 0

    @property
    def isReady(self) -> bool:
        return self._isReady

    async def generate(self, agentRequest: GatewayAgentRequest) -> AgentResponsePayload:
        del agentRequest
        self.generateCallCount += 1
        return AgentResponsePayload(summary="测试替身已完成契约探测")


class UnavailableProvider:
    @property
    def isReady(self) -> bool:
        return True

    async def generate(self, agentRequest: GatewayAgentRequest) -> AgentResponsePayload:
        del agentRequest
        raise ProviderUnavailableError


class InvalidResponseProvider:
    @property
    def isReady(self) -> bool:
        return True

    async def generate(self, agentRequest: GatewayAgentRequest) -> AgentResponsePayload:
        del agentRequest
        raise InvalidProviderResponseError


class UnexpectedFailureProvider:
    def __init__(self, failureMarker: str) -> None:
        self._failureMarker = failureMarker

    @property
    def isReady(self) -> bool:
        return True

    async def generate(self, agentRequest: GatewayAgentRequest) -> AgentResponsePayload:
        del agentRequest
        raise RuntimeError(self._failureMarker)


class SlowProvider:
    @property
    def isReady(self) -> bool:
        return True

    async def generate(self, agentRequest: GatewayAgentRequest) -> AgentResponsePayload:
        del agentRequest
        await asyncio.sleep(60)
        return AgentResponsePayload(summary="不应抵达")


class BlockingProvider:
    def __init__(self) -> None:
        self.requestStarted = asyncio.Event()
        self.allowCompletion = asyncio.Event()

    @property
    def isReady(self) -> bool:
        return True

    async def generate(self, agentRequest: GatewayAgentRequest) -> AgentResponsePayload:
        del agentRequest
        self.requestStarted.set()
        await self.allowCompletion.wait()
        return AgentResponsePayload(summary="并发测试请求已完成")
