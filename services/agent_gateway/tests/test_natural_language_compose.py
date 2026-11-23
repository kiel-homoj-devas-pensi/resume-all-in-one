import pytest

from agent_gateway.remote_contracts import (
    BasicResumeComposeInput,
    BasicResumeComposeOutput,
    validateBasicComposeOutput,
)


def test_natural_language_extracts_personal_facts_only_from_cited_consented_input() -> None:
    request = BasicResumeComposeInput.model_validate(
        {
            "inputType": "basicResumeCompose",
            "naturalLanguageInput": True,
            "sourceFragments": [
                {
                    "fragmentId": "fragment-1",
                    "text": (
                        "我叫张三，手机号13800000000，邮箱test@example.com。"
                        "想找运营助理，暂无工作经验。"
                    ),
                }
            ],
        }
    )
    output = BasicResumeComposeOutput.model_validate(
        {
            "outputVersion": "basicResumeCompose.v1",
            "summary": "整理已提供的基本信息，经历留空",
            "candidateResume": {
                "schemaVersion": "0.1.0",
                "profile": {
                    "id": "candidate-profile",
                    "fullName": "张三",
                    "phone": "13800000000",
                    "email": "test@example.com",
                },
            },
            "sourceReferences": [
                {"path": "/profile/" + field, "fragmentIds": ["fragment-1"]}
                for field in ("fullName", "phone", "email")
            ],
        }
    )
    validateBasicComposeOutput(output, request)
    with pytest.raises(ValueError):
        validateBasicComposeOutput(
            output, request.model_copy(update={"naturalLanguageInput": False})
        )
    invented = output.model_dump(mode="json")
    invented["candidateResume"]["profile"]["phone"] = "13999999999"
    with pytest.raises(ValueError):
        validateBasicComposeOutput(BasicResumeComposeOutput.model_validate(invented), request)


@pytest.mark.parametrize(
    "text",
    [
        "去年学校做过一个小程序，主要跟同学一起写页面，想找前端，数据库也碰过一点",
        "会一点Flutter 想先找实习 日期还记不清 跟同学一起写过页面",
        "没有工作经验，但参与学校活动，先跳过不清楚的日期",
    ],
)
def test_informal_undated_material_does_not_require_a_template(text: str) -> None:
    from agent_gateway.remote_contracts import RemoteResumeAiRequest
    from agent_gateway.usage import ProductCapability
    from agent_gateway.writing_agent import prepareWritingTask

    request = RemoteResumeAiRequest.model_validate(
        {
            "protocolVersion": "0.3.0",
            "clientRequestId": "natural-text-1",
            "idempotencyKey": "natural-idem-1",
            "capability": ProductCapability.basicResumeCompose,
            "input": {
                "inputType": "basicResumeCompose",
                "naturalLanguageInput": True,
                "sourceFragments": [{"fragmentId": "fragment-1", "text": text}],
            },
        }
    )
    task = prepareWritingTask(request)
    assert task.clarificationQuestion is None
    assert text in str(task.providerInput)


def test_undated_facts_can_be_kept_without_inventing_dates_or_employment() -> None:
    text = "去年学校做过一个小程序，主要跟同学一起写页面，想找前端，数据库也碰过一点"
    request = BasicResumeComposeInput.model_validate(
        {
            "inputType": "basicResumeCompose",
            "naturalLanguageInput": True,
            "sourceFragments": [{"fragmentId": "fragment-1", "text": text}],
        }
    )
    output = BasicResumeComposeOutput.model_validate(
        {
            "outputVersion": "basicResumeCompose.v1",
            "summary": "整理已提供的经历，未补造日期",
            "candidateResume": {
                "schemaVersion": "0.1.0",
                "profile": {"id": "candidate-profile", "headline": "前端"},
                "customSections": [
                    {
                        "id": "section-1",
                        "title": "经历与能力",
                        "items": [
                            {
                                "id": "item-1",
                                "title": "小程序",
                                "description": "去年学校做过一个小程序，主要跟同学一起写页面",
                            }
                        ],
                    }
                ],
            },
            "sourceReferences": [
                {"path": "/profile/headline", "fragmentIds": ["fragment-1"]},
                {"path": "/customSections", "fragmentIds": ["fragment-1"]},
            ],
        }
    )
    assert validateBasicComposeOutput(output, request, allowSemanticReview=True)
    assert output.candidateResume.workExperiences == ()
    assert output.candidateResume.educations == ()
    assert output.missingInformation == ()
