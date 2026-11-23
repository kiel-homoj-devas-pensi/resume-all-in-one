from __future__ import annotations

import pytest
from pydantic import ValidationError

from agent_gateway.prompt_registry import promptFor
from agent_gateway.remote_contracts import (
    BasicResumeComposeInput,
    BasicResumeComposeOutput,
    RemoteResumeAiRequest,
    ResumeOptimizationConversationInput,
    ResumeOptimizationConversationOutput,
    TargetedResumeOptimizationInput,
    TargetedResumeOptimizationOutput,
    validateBasicComposeOutput,
    validateOptimizationOutput,
)
from agent_gateway.resume_fact_guard import UnverifiedFactError
from agent_gateway.usage import ProductCapability


@pytest.mark.parametrize(
    "field,value",
    [
        ("fullName", "合成测试用户"),
        ("email", "synthetic@example.invalid"),
        ("phone", "SYNTHETIC-PHONE"),
        ("preciseAddress", "合成测试地点"),
    ],
)
def test_explicit_personal_form_is_a_source_without_narrative_repetition(
    field: str, value: str
) -> None:
    request = BasicResumeComposeInput.model_validate(
        {
            "inputType": "basicResumeCompose",
            "naturalLanguageInput": True,
            "sourceFragments": [{"fragmentId": "f", "text": "参与接口开发"}],
            "personalData": {"consentedFields": [field], field: value},
        }
    )
    output = BasicResumeComposeOutput.model_validate(
        {
            "outputVersion": "basicResumeCompose.v1",
            "summary": "已整理",
            "candidateResume": {
                "schemaVersion": "0.1.0",
                "profile": {"id": "p", field: value},
                "customSections": [
                    {
                        "id": "s",
                        "title": "接口开发",
                        "items": [{"id": "i", "description": "参与接口开发"}],
                    }
                ],
            },
            "sourceReferences": [{"path": "/customSections/0", "fragmentIds": ["f"]}],
        }
    )
    assert not validateBasicComposeOutput(output, request, allowSemanticReview=True)
    altered = output.model_dump(mode="json")
    altered["candidateResume"]["profile"][field] = "模型改写内容"
    with pytest.raises(UnverifiedFactError, match="已授权基础信息不得改写"):
        validateBasicComposeOutput(
            BasicResumeComposeOutput.model_validate(altered), request, allowSemanticReview=True
        )
    local_only = request.model_copy(update={"personalData": None})
    with pytest.raises(UnverifiedFactError, match="来源覆盖"):
        validateBasicComposeOutput(output, local_only, allowSemanticReview=True)


def test_personal_form_does_not_authorize_other_fields_or_invalid_citations() -> None:
    request = BasicResumeComposeInput.model_validate(
        {
            "inputType": "basicResumeCompose",
            "naturalLanguageInput": True,
            "sourceFragments": [{"fragmentId": "f", "text": "参与接口开发"}],
            "personalData": {"consentedFields": ["fullName"], "fullName": "合成测试用户"},
        }
    )
    output = BasicResumeComposeOutput.model_validate(
        {
            "outputVersion": "basicResumeCompose.v1",
            "summary": "已整理",
            "candidateResume": {
                "schemaVersion": "0.1.0",
                "profile": {
                    "id": "p",
                    "fullName": "合成测试用户",
                    "email": "invented@example.invalid",
                },
            },
            "sourceReferences": [{"path": "/profile", "fragmentIds": ["f"]}],
        }
    )
    with pytest.raises(UnverifiedFactError) as rejected:
        validateBasicComposeOutput(output, request, allowSemanticReview=True)
    assert rejected.value.path == "/profile/email"
    altered = output.model_dump(mode="json")
    altered["candidateResume"]["profile"]["email"] = ""
    altered["sourceReferences"][0]["fragmentIds"] = ["unknown"]
    with pytest.raises(ValueError, match="不存在的 fragmentId"):
        validateBasicComposeOutput(
            BasicResumeComposeOutput.model_validate(altered), request, allowSemanticReview=True
        )


def resumeProjection() -> dict[str, object]:
    return {
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
                "highlights": ["完成订单模块"],
            }
        ],
        "educations": [],
        "projects": [],
        "skillGroups": [],
        "certifications": [],
        "languages": [],
        "customSections": [],
    }


def test_远程投影拒绝未知字段和未逐项同意的个人信息() -> None:
    invalidResume = resumeProjection()
    invalidResume["unmapped"] = {"raw": "不得上传"}

    with pytest.raises(ValidationError):
        TargetedResumeOptimizationInput.model_validate(
            {
                "inputType": "targetedResumeOptimization",
                "baseResumeFingerprint": "a" * 64,
                "resume": invalidResume,
                "targetJobTitle": "后端工程师",
            }
        )

    with pytest.raises(ValidationError):
        BasicResumeComposeInput.model_validate(
            {
                "inputType": "basicResumeCompose",
                "sourceFragments": [{"fragmentId": "fragment-1", "text": "三年后端开发经验"}],
                "personalData": {
                    "consentedFields": ["fullName"],
                    "fullName": "测试姓名",
                    "phone": "13800000000",
                },
            }
        )


def test_岗位描述和最近三轮由_dto_硬限制() -> None:
    with pytest.raises(ValidationError):
        TargetedResumeOptimizationInput.model_validate(
            {
                "inputType": "targetedResumeOptimization",
                "baseResumeFingerprint": "b" * 64,
                "resume": resumeProjection(),
                "targetJobTitle": "后端工程师",
                "jobDescription": "岗" * 2001,
            }
        )

    with pytest.raises(ValidationError):
        RemoteResumeAiRequest.model_validate(
            {
                "protocolVersion": "0.3.0",
                "clientRequestId": "request-1",
                "idempotencyKey": "idempotency-1",
                "capability": "resumeOptimizationConversation",
                "input": {
                    "inputType": "resumeOptimizationConversation",
                    "conversationToken": "conversation-1",
                    "baseResumeFingerprint": "c" * 64,
                    "resume": resumeProjection(),
                    "recentMessages": [
                        {"role": "user", "content": f"消息-{messageNumber}"}
                        for messageNumber in range(7)
                    ],
                    "userMessage": "继续优化",
                },
            }
        )


def test_capability_不能与输入类型错配() -> None:
    with pytest.raises(ValidationError):
        RemoteResumeAiRequest.model_validate(
            {
                "protocolVersion": "0.3.0",
                "clientRequestId": "request-1",
                "idempotencyKey": "idempotency-1",
                "capability": "targetedResumeOptimization",
                "input": {
                    "inputType": "basicResumeCompose",
                    "sourceFragments": [{"fragmentId": "fragment-1", "text": "三年后端开发经验"}],
                },
            }
        )


def test_基础候选必须引用本次真实存在的_fragment() -> None:
    requestInput = BasicResumeComposeInput.model_validate(
        {
            "inputType": "basicResumeCompose",
            "sourceFragments": [{"fragmentId": "fragment-1", "text": "三年后端开发经验"}],
        }
    )
    candidateResume = {
        "schemaVersion": "0.1.0",
        "profile": {"id": "profile-1", "headline": "后端开发经验"},
    }
    validOutput = BasicResumeComposeOutput.model_validate(
        {
            "outputVersion": "basicResumeCompose.v1",
            "summary": "已整理候选简历",
            "candidateResume": candidateResume,
            "sourceReferences": [{"path": "/profile/headline", "fragmentIds": ["fragment-1"]}],
        }
    )
    invalidOutput = validOutput.model_copy(
        update={
            "sourceReferences": (
                validOutput.sourceReferences[0].model_copy(
                    update={"fragmentIds": ("unknown-fragment",)}
                ),
            )
        }
    )

    validateBasicComposeOutput(validOutput, requestInput)
    with pytest.raises(ValueError, match="fragmentId"):
        validateBasicComposeOutput(invalidOutput, requestInput)


def test_优化_patch_只能改写白名单文本且_old_value_必须匹配() -> None:
    requestInput = TargetedResumeOptimizationInput.model_validate(
        {
            "inputType": "targetedResumeOptimization",
            "baseResumeFingerprint": "d" * 64,
            "resume": resumeProjection(),
            "targetJobTitle": "后端工程师",
        }
    )
    validOutput = TargetedResumeOptimizationOutput.model_validate(
        {
            "outputVersion": "targetedResumeOptimization.v1",
            "summary": "建议突出接口开发成果",
            "proposedPatch": {
                "operations": [
                    {
                        "type": "replace",
                        "path": "/workExperiences/0/summary",
                        "oldValue": "负责接口开发",
                        "newValue": "负责接口的开发",
                        "reason": "更贴近岗位职责",
                        "source": "remoteAi",
                        "category": "wording",
                    }
                ]
            },
            "nextAction": "reviewPatch",
        }
    )
    validPatch = validOutput.proposedPatch
    assert validPatch is not None
    invalidOutput = validOutput.model_copy(
        update={
            "proposedPatch": validPatch.model_copy(
                update={
                    "operations": (
                        validPatch.operations[0].model_copy(
                            update={"path": "/workExperiences/0/organization"}
                        ),
                    )
                }
            )
        }
    )

    validateOptimizationOutput(validOutput, requestInput.resume)
    with pytest.raises(ValueError, match="白名单"):
        validateOptimizationOutput(invalidOutput, requestInput.resume)


def test_三项_prompt_版本和输出预算固定在_gateway_边界() -> None:
    basicPrompt = promptFor(ProductCapability.basicResumeCompose)
    targetedPrompt = promptFor(ProductCapability.targetedResumeOptimization)
    conversationPrompt = promptFor(ProductCapability.resumeOptimizationConversation)

    assert basicPrompt.version == "basic-resume-compose.v15"
    assert basicPrompt.maxOutputTokens == 4096
    assert targetedPrompt.version == "targeted-resume-optimization.v9"
    assert targetedPrompt.maxOutputTokens == 4096
    assert conversationPrompt.version == "resume-optimization-conversation.v9"
    assert conversationPrompt.maxOutputTokens == 4096
    assert "不得补造" in basicPrompt.systemPrompt
    assert "最近最多三轮" in conversationPrompt.systemPrompt


def test_多轮输出没有_patch_时不能要求审阅() -> None:
    invalidOutput = ResumeOptimizationConversationOutput.model_validate(
        {
            "outputVersion": "resumeOptimizationConversation.v1",
            "summary": "需要补充目标岗位",
            "proposedPatch": None,
            "nextAction": "reviewPatch",
        }
    )

    requestInput = RemoteResumeAiRequest.model_validate(
        {
            "protocolVersion": "0.3.0",
            "clientRequestId": "request-2",
            "idempotencyKey": "idempotency-2",
            "capability": "resumeOptimizationConversation",
            "input": {
                "inputType": "resumeOptimizationConversation",
                "conversationToken": "conversation-2",
                "baseResumeFingerprint": "e" * 64,
                "resume": resumeProjection(),
                "userMessage": "继续优化",
            },
        }
    )
    assert requestInput.capability is ProductCapability.resumeOptimizationConversation
    assert isinstance(requestInput.input, ResumeOptimizationConversationInput)
    with pytest.raises(ValueError, match="不能要求"):
        validateOptimizationOutput(invalidOutput, requestInput.input.resume)
