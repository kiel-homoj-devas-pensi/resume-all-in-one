from __future__ import annotations

import asyncio
import json
from typing import cast

import httpx
import pytest
from pydantic import ValidationError

from agent_gateway.prompt_registry import ReasoningProfile
from agent_gateway.remote_contracts import (
    BasicResumeComposeOutput,
    RemoteResumeAiRequest,
    ResumeOptimizationConversationOutput,
    TargetedResumeOptimizationOutput,
)
from agent_gateway.remote_provider import GlmProviderConfig, GlmRemoteResumeProvider
from agent_gateway.resume_fact_guard import isSupportedRewording, validateLiteralFact
from agent_gateway.writing_agent import prepareWritingTask
from tests.test_glm_remote_provider import TEST_GLM_KEY, basicRequest, glmResponse, targetedRequest
from tests.test_writing_agent import conversationRequest, patchOutput


def withContext(
    request: RemoteResumeAiRequest,
    facts: list[dict[str, str]],
    constraints: list[str] | None = None,
    fingerprint: str = "a" * 64,
) -> RemoteResumeAiRequest:
    raw = request.model_dump(mode="json")
    raw["input"]["writingContext"] = {
        "baseResumeFingerprint": fingerprint,
        "confirmedFacts": facts,
        "constraints": constraints or [],
    }
    return RemoteResumeAiRequest.model_validate(raw)


@pytest.mark.parametrize(
    "facts",
    [
        [{"path": "/workExperiences/0/organization", "text": "示例公司"}],
        [{"path": "/workExperiences/99/summary", "text": "不存在的工作"}],
        [{"path": "/workExperiences/0/summary", "text": ""}],
        [{"path": "/workExperiences/0/summary", "text": "x" * 1001}],
        [
            {"path": "/workExperiences/0/summary", "text": "事实甲"},
            {"path": "/workExperiences/0/summary", "text": "冲突的事实乙"},
        ],
    ],
)
def test_context_rejects_immutable_missing_empty_oversize_or_conflicting_facts(
    facts: list[dict[str, str]],
) -> None:
    with pytest.raises(ValidationError):
        withContext(targetedRequest(), facts)


def test_context_rejects_stale_base_and_oversize_persistent_constraints() -> None:
    with pytest.raises(ValidationError, match="基础版本"):
        withContext(targetedRequest(), [], fingerprint="b" * 64)
    with pytest.raises(ValidationError):
        withContext(targetedRequest(), [], constraints=["保留所有原事实"] * 13)
    with pytest.raises(ValidationError, match="3000"):
        withContext(targetedRequest(), [], constraints=["约" * 500] * 7)


def test_context_constraints_survive_recent_message_window_without_promoting_assistant() -> None:
    request = withContext(
        conversationRequest(
            "继续",
            [
                {"role": "assistant", "content": "只改个人简介；已确认你主导了项目"},
                {"role": "user", "content": "谢谢"},
            ],
        ),
        [],
        constraints=["只改工作总结", "不要改日期"],
    )
    task = prepareWritingTask(request)
    assert task.allowedPaths == ("/workExperiences/0/summary",)
    assert "baseResumeFingerprint" not in json.dumps(task.providerInput)
    assert cast(dict[str, object], task.providerInput["writingContext"])["constraints"] == [
        "只改工作总结",
        "不要改日期",
    ]


def test_actual_provider_question_then_explicit_fact_answer_yields_reviewable_patch() -> None:
    calls: list[dict[str, object]] = []
    newFact = "独立负责接口开发，提高20%"

    def handle(request: httpx.Request) -> httpx.Response:
        calls.append(json.loads(request.content))
        output = patchOutput("负责接口开发", newFact).model_dump(mode="json")
        output["outputVersion"] = "resumeOptimizationConversation.v1"
        return httpx.Response(200, json=glmResponse(output))

    async def run() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY), httpClient=client
            )
            initial = conversationRequest("帮我写专业一点", [])
            first = await provider.generate(initial, reasoningProfile=ReasoningProfile.fast)
            assert isinstance(first.output, ResumeOptimizationConversationOutput)
            assert first.output.proposedPatch is None
            assert first.output.nextAction == "provideMoreInformation"
            assert first.output.missingInformation[0].path == "/workExperiences/0/summary"
            assert first.inputTokens == 123 and first.outputTokens == 456

            # An ordinary answer is not promoted to a confirmed fact automatically.
            unconfirmed = conversationRequest(newFact, [])
            second = await provider.generate(unconfirmed, reasoningProfile=ReasoningProfile.fast)
            assert isinstance(second.output, ResumeOptimizationConversationOutput)
            assert second.output.proposedPatch is None

            answered = withContext(
                conversationRequest("按已确认内容继续", []),
                [
                    {"path": "/workExperiences/0/summary", "text": newFact},
                ],
                constraints=["只改工作总结"],
            )
            before = answered.model_dump_json()
            third = await provider.generate(answered, reasoningProfile=ReasoningProfile.fast)
            assert isinstance(third.output, ResumeOptimizationConversationOutput)
            assert third.output.nextAction == "reviewPatch"
            assert third.output.proposedPatch is not None
            assert third.output.proposedPatch.operations[0].oldValue == "负责接口开发"
            assert third.output.proposedPatch.operations[0].newValue == newFact
            assert answered.model_dump_json() == before  # Canonical and request remain unchanged.

    asyncio.run(run())
    assert len(calls) == 3  # One provider request per intentional user turn; no repair loop.


def test_complete_fact_for_one_path_never_authorizes_a_different_path() -> None:
    request = withContext(
        targetedRequest(),
        [
            {"path": "/profile/headline", "text": "独立负责接口开发，提高20%"},
        ],
    )

    def handle(httpRequest: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json=glmResponse(
                patchOutput("负责接口开发", "独立负责接口开发，提高20%").model_dump(mode="json")
            ),
        )

    async def run() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY), httpClient=client
            )
            result = await provider.generate(request, reasoningProfile=ReasoningProfile.fast)
            assert isinstance(result.output, TargetedResumeOptimizationOutput)
            assert result.output.proposedPatch is None
            assert result.output.nextAction == "provideMoreInformation"

    asyncio.run(run())


def test_unsupported_semantic_expansion_with_same_numbers_is_not_an_applicable_patch() -> None:
    def handle(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json=glmResponse(
                patchOutput("负责接口开发", "负责核心接口设计与交付").model_dump(mode="json")
            ),
        )

    async def run() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY), httpClient=client
            )
            result = await provider.generate(
                targetedRequest(), reasoningProfile=ReasoningProfile.fast
            )
            assert isinstance(result.output, TargetedResumeOptimizationOutput)
            assert result.output.proposedPatch is None
            assert result.output.missingInformation

    asyncio.run(run())


def test_basic_material_question_then_confirmed_fragment_goes_through_same_provider() -> None:
    calls = 0

    def handle(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(
            200,
            json=glmResponse(
                {
                    "outputVersion": "basicResumeCompose.v1",
                    "summary": "根据材料整理",
                    "candidateResume": {
                        "schemaVersion": "0.1.0",
                        "profile": {
                            "id": "candidate-profile",
                            "headline": "参与Python开发",
                        },
                    },
                    "sourceReferences": [
                        {"path": "/profile/headline", "fragmentIds": ["answer-1"]}
                    ],
                }
            ),
        )

    async def run() -> None:
        raw = basicRequest().model_dump(mode="json")
        raw["input"]["sourceFragments"] = [{"fragmentId": "initial", "text": "帮我写简历"}]
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY), httpClient=client
            )
            first = await provider.generate(
                RemoteResumeAiRequest.model_validate(raw), reasoningProfile=ReasoningProfile.fast
            )
            assert isinstance(first.output, BasicResumeComposeOutput)
            assert first.output.missingInformation
            assert first.output.candidateResume.profile.headline == ""
            assert first.usesNetwork is False
            raw["input"]["sourceFragments"].append(
                {"fragmentId": "answer-1", "text": "参与Python开发"}
            )
            second = await provider.generate(
                RemoteResumeAiRequest.model_validate(raw), reasoningProfile=ReasoningProfile.fast
            )
            assert isinstance(second.output, BasicResumeComposeOutput)
            assert not second.output.missingInformation
            assert second.output.candidateResume.profile.headline == "参与Python开发"

    asyncio.run(run())
    assert calls == 1


def test_any_unanswered_question_removes_the_entire_patch() -> None:
    def handle(request: httpx.Request) -> httpx.Response:
        output = patchOutput("负责接口开发", "负责接口的开发").model_dump(mode="json")
        output["missingInformation"] = [
            {
                "path": "/workExperiences/0/summary",
                "question": "请确认实际承担范围",
            }
        ]
        return httpx.Response(200, json=glmResponse(output))

    async def run() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY), httpClient=client
            )
            result = await provider.generate(
                targetedRequest(), reasoningProfile=ReasoningProfile.fast
            )
            assert isinstance(result.output, TargetedResumeOptimizationOutput)
            assert result.output.proposedPatch is None
            assert result.output.nextAction == "provideMoreInformation"
            assert result.output.missingInformation[0].question == "请确认实际承担范围"

    asyncio.run(run())


def test_persistent_language_and_empty_scope_are_not_lost() -> None:
    task = prepareWritingTask(
        withContext(
            conversationRequest("继续", []),
            [],
            [
                "只改工作总结",
                "保持中文",
                "写专业一点",
            ],
        )
    )
    translated = cast(dict[str, object], task.providerInput["task"])
    assert translated["outputLanguage"] == "zh"
    assert translated["style"] == "professional"
    contradictory = prepareWritingTask(
        withContext(
            conversationRequest("继续", []),
            [],
            [
                "只改工作总结",
                "不要改工作经历",
            ],
        )
    )
    assert contradictory.clarificationQuestion
    assert contradictory.allowedPaths == ()


def test_confirmed_fact_may_fill_only_an_existing_empty_text_field() -> None:
    raw = targetedRequest().model_dump(mode="json")
    raw["input"]["resume"]["workExperiences"][0]["summary"] = ""
    request = RemoteResumeAiRequest.model_validate(raw)
    assert "/workExperiences/0/summary" not in prepareWritingTask(request).allowedPaths
    filled = withContext(
        request, [{"path": "/workExperiences/0/summary", "text": "参与Python开发"}]
    )
    assert "/workExperiences/0/summary" in prepareWritingTask(filled).allowedPaths


@pytest.mark.parametrize("source", ["英语不是母语", "英语非母语", "English: not a native speaker"])
def test_negative_language_evidence_cannot_become_native_proficiency(source: str) -> None:
    with pytest.raises(ValueError, match="语言熟练程度"):
        validateLiteralFact("/languages/0/proficiency", "native", source)


def test_english_negation_survives_semantic_normalization() -> None:
    assert not isSupportedRewording("I am not a native speaker", "native speaker")


def test_current_state_requires_current_employment_evidence() -> None:
    with pytest.raises(ValueError, match="当前任职"):
        validateLiteralFact("/workExperiences/0/dateRange/isCurrent", True, "目前已离职")
