from __future__ import annotations

from typing import Protocol

from .contracts import AgentResponsePayload, GatewayAgentRequest


class ProviderUnavailableError(RuntimeError):
    pass


class InvalidProviderResponseError(RuntimeError):
    pass


class GatewayAgentProvider(Protocol):
    @property
    def isReady(self) -> bool: ...

    async def generate(self, agentRequest: GatewayAgentRequest) -> AgentResponsePayload: ...


class FakeAgentProvider:
    @property
    def isReady(self) -> bool:
        return True

    async def generate(self, agentRequest: GatewayAgentRequest) -> AgentResponsePayload:
        # Fake 只证明契约能走通，刻意不回显输入，避免示例代码形成正文日志习惯。
        del agentRequest
        return AgentResponsePayload(
            summary="Mock Provider 已完成契约探测",
            warnings=("仅使用合成输入，未调用远程 Provider",),
        )
