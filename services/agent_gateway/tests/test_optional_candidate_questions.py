import json

import pytest

from agent_gateway.remote_contracts import (
    BasicResumeComposeOutput,
    RemoteResumeAiRequest,
    hasUsableCandidate,
)
from agent_gateway.remote_provider import (
    InvalidRemoteProviderResponseError,
    _parseCapabilityOutput,
)
from agent_gateway.writing_agent import requireAnswersBeforeCandidate


def request() -> RemoteResumeAiRequest:
    return RemoteResumeAiRequest.model_validate(
        {
            "protocolVersion": "0.3.0",
            "clientRequestId": "optional-question-request",
            "idempotencyKey": "optional-question-key",
            "capability": "basicResumeCompose",
            "input": {
                "inputType": "basicResumeCompose",
                "naturalLanguageInput": True,
                "sourceFragments": [
                    {"fragmentId": "source-1", "text": "我参与项目，用Flutter编写页面。"}
                ],
            },
        }
    )


def output(path: str, question: str, *, empty: bool = False) -> dict[str, object]:
    return {
        "outputVersion": "basicResumeCompose.v1",
        "summary": "整理现有材料",
        "candidateResume": {
            "schemaVersion": "0.1.0",
            "profile": {"id": "profile-1"},
            "projects": []
            if empty
            else [
                {"id": "project-1", "name": "项目经历", "summary": "参与项目，用Flutter编写页面"}
            ],
        },
        "sourceReferences": [
            {"path": "/profile" if empty else "/projects/0", "fragmentIds": ["source-1"]}
        ],
        "missingInformation": [{"path": path, "question": question}],
        "warnings": [],
    }


@pytest.mark.parametrize(
    ("path", "question"),
    [
        ("/educations", "教育背景未提供，如需展示可补充学校、专业、学历和时间。"),
        ("/educations/0/institution", "如果需要展示教育背景，可补充学校。"),
        ("/profile/phone", "联系电话未提供，如需展示可补充。"),
        (
            "/workExperiences/0/highlights",
            "是否有可量化的成果（如修复问题数、测试覆盖率等）可补充到工作经历中？",
        ),
        ("/projects/0/highlights/0", "如有量化成果，可补充测试覆盖率。"),
    ],
)
def test_optional_invitations_do_not_discard_a_valid_existing_candidate(
    path: str, question: str
) -> None:
    parsed = _parseCapabilityOutput(request(), json.dumps(output(path, question)))
    delivered = requireAnswersBeforeCandidate(parsed, request())
    assert isinstance(delivered, BasicResumeComposeOutput)
    assert delivered.candidateResume.projects[0].summary == "参与项目，用Flutter编写页面"
    assert not delivered.missingInformation
    assert hasUsableCandidate(delivered)


@pytest.mark.parametrize(
    ("path", "question"),
    [
        ("/educations", "两处学校信息不一致，请确认哪一所正确。"),
        ("/workExperiences/0/highlights", "请确认测试覆盖率是20%还是30%，哪一个正确？"),
        ("/workExperiences/0/summary", "请补充实际职责。"),
    ],
)
def test_genuine_conflicts_and_material_questions_still_block_delivery(
    path: str, question: str
) -> None:
    parsed = _parseCapabilityOutput(request(), json.dumps(output(path, question)))
    delivered = requireAnswersBeforeCandidate(parsed, request())
    assert delivered.missingInformation
    assert not hasUsableCandidate(delivered)


def test_optional_invitation_cannot_turn_an_empty_shell_into_a_candidate() -> None:
    parsed = _parseCapabilityOutput(
        request(), json.dumps(output("/educations", "教育未提供，如需可补充。", empty=True))
    )
    assert parsed.missingInformation
    assert not hasUsableCandidate(parsed)
    empty = parsed.model_copy(update={"missingInformation": ()})
    assert not hasUsableCandidate(empty)
    with pytest.raises(InvalidRemoteProviderResponseError):
        _parseCapabilityOutput(request(), empty.model_dump_json())
