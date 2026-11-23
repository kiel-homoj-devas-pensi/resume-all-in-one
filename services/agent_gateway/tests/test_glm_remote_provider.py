from __future__ import annotations

import asyncio
import json
from typing import cast

import httpx
import pytest

from agent_gateway.prompt_registry import ReasoningProfile
from agent_gateway.remote_contracts import RemoteResumeAiRequest
from agent_gateway.remote_provider import (
    GLM_CHAT_COMPLETIONS_ENDPOINT,
    BoundedProviderGate,
    GlmProviderConfig,
    GlmRemoteResumeProvider,
    InvalidRemoteProviderResponseError,
    RemoteProviderGeneration,
    RemoteProviderRateLimitedError,
    RemoteProviderUnavailableError,
)

TEST_GLM_KEY = "task019-local-glm-key-not-secret"


def basicRequest() -> RemoteResumeAiRequest:
    return RemoteResumeAiRequest.model_validate(
        {
            "protocolVersion": "0.3.0",
            "clientRequestId": "request-basic-1",
            "idempotencyKey": "idempotency-basic-1",
            "capability": "basicResumeCompose",
            "input": {
                "inputType": "basicResumeCompose",
                "sourceFragments": [
                    {
                        "fragmentId": "fragment-1",
                        "category": "work",
                        "text": "三年后端开发经验",
                    }
                ],
            },
        }
    )


def targetedRequest() -> RemoteResumeAiRequest:
    return RemoteResumeAiRequest.model_validate(
        {
            "protocolVersion": "0.3.0",
            "clientRequestId": "request-targeted-1",
            "idempotencyKey": "idempotency-targeted-1",
            "capability": "targetedResumeOptimization",
            "input": {
                "inputType": "targetedResumeOptimization",
                "baseResumeFingerprint": "a" * 64,
                "resume": {
                    "schemaVersion": "0.1.0",
                    "profile": {
                        "id": "profile-1",
                        "headline": "后端开发工程师",
                        "coarseLocation": "杭州",
                    },
                    "workExperiences": [
                        {
                            "id": "work-1",
                            "organization": "示例公司",
                            "position": "开发工程师",
                            "summary": "负责接口开发",
                            "highlights": [],
                        }
                    ],
                },
                "targetJobTitle": "后端工程师",
                "jobDescription": "负责高并发接口设计",
            },
        }
    )


def glmResponse(content: dict[str, object]) -> dict[str, object]:
    return {
        "id": "provider-response-id",
        "model": "glm-5.3",
        "choices": [
            {
                "finish_reason": "stop",
                "message": {
                    "role": "assistant",
                    "content": json.dumps(content, ensure_ascii=False),
                },
            }
        ],
        "usage": {
            "prompt_tokens": 123,
            "completion_tokens": 456,
            "total_tokens": 579,
        },
    }


def test_基础生成使用官方_endpoint_low_档和_json_模式() -> None:
    capturedRequests: list[httpx.Request] = []

    async def handleRequest(request: httpx.Request) -> httpx.Response:
        capturedRequests.append(request)
        return httpx.Response(
            200,
            json=glmResponse(
                {
                    "outputVersion": "basicResumeCompose.v1",
                    "summary": "已整理候选简历",
                    "candidateResume": {
                        "schemaVersion": "0.1.0",
                        "profile": {
                            "id": "candidate-profile",
                            "headline": "后端开发经验",
                            "coarseLocation": "",
                        },
                    },
                    "sourceReferences": [
                        {
                            "path": "/profile/headline",
                            "fragmentIds": ["fragment-1"],
                        }
                    ],
                }
            ),
        )

    async def runScenario() -> RemoteProviderGeneration:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handleRequest)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY),
                httpClient=client,
            )
            return await provider.generate(
                basicRequest(),
                reasoningProfile=ReasoningProfile.fast,
            )

    generation = asyncio.run(runScenario())

    assert len(capturedRequests) == 1
    capturedRequest = capturedRequests[0]
    assert str(capturedRequest.url) == GLM_CHAT_COMPLETIONS_ENDPOINT
    assert capturedRequest.headers["Authorization"] == f"Bearer {TEST_GLM_KEY}"
    providerBody = cast(dict[str, object], json.loads(capturedRequest.content))
    assert providerBody["model"] == "glm-5.3"
    assert providerBody["thinking"] == {"type": "enabled"}
    assert providerBody["reasoning_effort"] == "low"
    assert providerBody["response_format"] == {"type": "json_object"}
    assert providerBody["max_tokens"] == 4096
    assert generation.promptVersion == "basic-resume-compose.v15"
    assert generation.inputTokens == 123
    assert generation.outputTokens == 456


def test_高级优化使用_high_档且不发送本地版本指纹() -> None:
    capturedUserContent = ""
    capturedReasoningEffort = ""

    async def handleRequest(request: httpx.Request) -> httpx.Response:
        nonlocal capturedReasoningEffort, capturedUserContent
        providerBody = cast(dict[str, object], json.loads(request.content))
        messages = cast(list[dict[str, object]], providerBody["messages"])
        capturedUserContent = cast(str, messages[1]["content"])
        capturedReasoningEffort = cast(str, providerBody["reasoning_effort"])
        return httpx.Response(
            200,
            json=glmResponse(
                {
                    "outputVersion": "targetedResumeOptimization.v1",
                    "summary": "建议突出接口开发",
                    "proposedPatch": {
                        "operations": [
                            {
                                "type": "replace",
                                "path": "/workExperiences/0/summary",
                                "oldValue": "负责接口开发",
                                "newValue": "负责高并发接口设计与交付",
                                "reason": "贴近目标岗位",
                                "source": "remoteAi",
                                "category": "wording",
                            }
                        ]
                    },
                    "nextAction": "reviewPatch",
                }
            ),
        )

    async def runScenario() -> object:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handleRequest)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY),
                httpClient=client,
            )
            return await provider.generate(
                targetedRequest(),
                reasoningProfile=ReasoningProfile.deep,
            )

    asyncio.run(runScenario())

    decodedUserContent = cast(dict[str, object], json.loads(capturedUserContent))
    serializedUserContent = json.dumps(decodedUserContent, ensure_ascii=False)
    assert "baseResumeFingerprint" not in serializedUserContent
    assert "idempotency" not in serializedUserContent
    assert "request-targeted-1" not in serializedUserContent
    assert capturedReasoningEffort == "high"


def test_无效_json_和不匹配_old_value_均被拒绝() -> None:
    responseBodies: list[dict[str, object]] = [
        {
            "choices": [{"finish_reason": "stop", "message": {"content": "not-json"}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1},
        },
        glmResponse(
            {
                "outputVersion": "targetedResumeOptimization.v1",
                "summary": "错误建议",
                "proposedPatch": {
                    "operations": [
                        {
                            "type": "replace",
                            "path": "/workExperiences/0/summary",
                            "oldValue": "并非原值",
                            "newValue": "改写文本",
                            "reason": "测试",
                            "source": "remoteAi",
                            "category": "wording",
                        }
                    ]
                },
                "nextAction": "reviewPatch",
            }
        ),
    ]

    async def assertResponseRejected(responseBody: dict[str, object]) -> None:
        def handleRequest(request: httpx.Request) -> httpx.Response:
            del request
            return httpx.Response(200, json=responseBody)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handleRequest)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY),
                httpClient=client,
            )
            with pytest.raises(InvalidRemoteProviderResponseError) as caught:
                await provider.generate(
                    targetedRequest(),
                    reasoningProfile=ReasoningProfile.deep,
                )

            usage = cast(dict[str, int], responseBody["usage"])
            assert caught.value.inputTokens == usage["prompt_tokens"]
            assert caught.value.outputTokens == usage["completion_tokens"]
            assert caught.value.promptVersion is not None

    for responseBody in responseBodies:
        asyncio.run(assertResponseRejected(responseBody))


def test_provider_限流和配置错误不自动重试() -> None:
    async def assertSingleFailure(
        statusCode: int,
        expectedError: type[Exception],
    ) -> int:
        callCount = 0

        def handleRequest(request: httpx.Request) -> httpx.Response:
            nonlocal callCount
            del request
            callCount += 1
            return httpx.Response(statusCode, headers={"Retry-After": "5"})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handleRequest)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY),
                httpClient=client,
            )
            with pytest.raises(expectedError):
                await provider.generate(
                    basicRequest(),
                    reasoningProfile=ReasoningProfile.fast,
                )
        return callCount

    for statusCode, expectedError in (
        (429, RemoteProviderRateLimitedError),
        (401, RemoteProviderUnavailableError),
    ):
        assert asyncio.run(assertSingleFailure(statusCode, expectedError)) == 1


def test_有界队列在活动槽和等待槽都占满时立即拒绝() -> None:
    async def runScenario() -> None:
        gate = BoundedProviderGate(
            maximumActiveRequests=1,
            maximumQueuedRequests=1,
            queueWaitSeconds=5,
        )
        await gate.acquire()
        waitingRequest = asyncio.create_task(gate.acquire())
        await asyncio.sleep(0)
        with pytest.raises(RemoteProviderRateLimitedError):
            await gate.acquire()
        await gate.release()
        await waitingRequest
        await gate.release()

    asyncio.run(runScenario())
