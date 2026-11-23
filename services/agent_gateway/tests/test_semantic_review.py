"""Marked review candidates are opt-in; hard fact checks remain mandatory."""

import asyncio
import json

import httpx
import pytest

from agent_gateway.prompt_registry import ReasoningProfile
from agent_gateway.remote_contracts import (
    BasicResumeComposeOutput,
    RemoteResumeAiRequest,
    ResumeOptimizationConversationOutput,
    TargetedResumeOptimizationInput,
    TargetedResumeOptimizationOutput,
    validateBasicComposeOutput,
    validateOptimizationOutput,
)
from agent_gateway.remote_provider import (
    GlmProviderConfig,
    GlmRemoteResumeProvider,
    InvalidRemoteProviderResponseError,
    RemoteProviderGeneration,
    _parseCapabilityOutput,
)
from agent_gateway.resume_fact_guard import SEMANTIC_REVIEW_WARNING
from tests.test_glm_remote_provider import TEST_GLM_KEY, basicRequest, glmResponse, targetedRequest
from tests.test_writing_agent import composeCase, patchOutput


@pytest.mark.parametrize("role", ["前端开发参与者", "独立负责人", "负责团队30人", "参与"])
def test_optional_project_role_does_not_block_spoken_material(role: str) -> None:
    source = "参与图书借阅登记网页，用Vue和JavaScript写过表单，没有正式工作经历。"
    payload = basicRequest().model_dump(mode="json")
    payload["input"]["naturalLanguageInput"] = True
    payload["input"]["sourceFragments"][0]["text"] = source
    output, _ = composeCase(
        {
            "profile": {"id": "p"},
            "projects": [
                {
                    "id": "project-1",
                    "name": "图书借阅登记网页",
                    "role": role,
                    "summary": "参与图书借阅登记网页，用Vue和JavaScript写过表单",
                }
            ],
        },
        [{"path": "/projects/0", "fragmentIds": ["fragment-1"]}],
        source,
    )
    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload), output.model_dump_json()
    )
    assert isinstance(parsed, BasicResumeComposeOutput)
    assert not parsed.missingInformation
    assert parsed.candidateResume.projects[0].role == ("参与" if role == "参与" else "")
    assert parsed.candidateResume.projects[0].summary == output.candidateResume.projects[0].summary
    assert parsed.candidateResume.projects[0].dateRange is None
    assert not parsed.candidateResume.workExperiences


@pytest.mark.parametrize("invention", ["参与Acme公司项目", "主导图书借阅登记网页", "提升30%"])
def test_omitting_optional_role_does_not_hide_other_invented_project_facts(invention: str) -> None:
    payload = basicRequest().model_dump(mode="json")
    payload["input"]["naturalLanguageInput"] = True
    source = "参与图书借阅登记网页，用Vue写过表单"
    payload["input"]["sourceFragments"][0]["text"] = source
    output, _ = composeCase(
        {
            "profile": {"id": "p"},
            "projects": [{"id": "project-1", "role": "前端开发参与者", "summary": invention}],
        },
        [{"path": "/projects/0", "fragmentIds": ["fragment-1"]}],
        source,
    )
    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload), output.model_dump_json()
    )
    assert parsed.missingInformation[0].path == "/projects/0/summary"
    assert not parsed.candidateResume.projects


def test_optional_role_without_citation_is_still_rejected() -> None:
    payload = basicRequest().model_dump(mode="json")
    payload["input"]["naturalLanguageInput"] = True
    output, _ = composeCase(
        {"profile": {"id": "p"}, "projects": [{"id": "p1", "role": "项目负责人"}]},
        [{"path": "/profile", "fragmentIds": ["fragment-1"]}],
        "三年后端开发经验",
    )
    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload), output.model_dump_json()
    )
    assert parsed.missingInformation[0].path == "/projects/0/role"


@pytest.mark.parametrize("project_name", ["校园失物招领系统", "虚构公司项目", "", "失物招领网页"])
@pytest.mark.parametrize("group_name", ["前端开发技能", ""])
def test_descriptive_labels_do_not_block_or_become_invented_resume_facts(
    project_name: str, group_name: str
) -> None:
    source = "参与失物招领网页，用Vue写过表单，会基础HTML和CSS，日期记不清。"
    payload = basicRequest().model_dump(mode="json")
    payload["input"].update(naturalLanguageInput=True)
    payload["input"]["sourceFragments"][0]["text"] = source
    output, _ = composeCase(
        {
            "profile": {"id": "p"},
            "projects": [
                {
                    "id": "project-1",
                    "name": project_name,
                    "role": "开发成员",
                    "summary": "参与失物招领网页，用Vue写过表单",
                }
            ],
            "skillGroups": [{"id": "skills-1", "name": group_name, "skills": ["HTML", "CSS"]}],
        },
        [
            {"path": "/projects/0", "fragmentIds": ["fragment-1"]},
            {"path": "/skillGroups/0", "fragmentIds": ["fragment-1"]},
        ],
        source,
    )
    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload), output.model_dump_json()
    )
    assert isinstance(parsed, BasicResumeComposeOutput)
    assert not parsed.missingInformation
    assert parsed.candidateResume.projects[0].name == (
        "失物招领网页" if project_name == "失物招领网页" else "项目经历"
    )
    assert parsed.candidateResume.projects[0].role == ""
    assert parsed.candidateResume.projects[0].dateRange is None
    assert parsed.candidateResume.skillGroups[0].name == "技能"
    assert parsed.candidateResume.skillGroups[0].skills == ("HTML", "CSS")
    assert "虚构公司" not in parsed.model_dump_json()


def test_fixed_layout_name_does_not_authorize_new_skill_or_date() -> None:
    payload = basicRequest().model_dump(mode="json")
    payload["input"]["naturalLanguageInput"] = True
    payload["input"]["sourceFragments"][0]["text"] = "参与网页开发，会HTML，日期不记得"
    for field, candidate, expected_path in [
        (
            "skillGroups",
            [{"id": "s", "name": "技能", "skills": ["Kubernetes"]}],
            "/skillGroups/0/skills/0",
        ),
        (
            "projects",
            [{"id": "p1", "name": "项目经历", "dateRange": {"start": {"year": 2025}}}],
            "/projects/0/dateRange/start/year",
        ),
        ("certifications", [{"id": "c", "name": "技能"}], "/certifications/0/name"),
    ]:
        output, _ = composeCase(
            {"profile": {"id": "p"}, field: candidate},
            [{"path": "/" + field, "fragmentIds": ["fragment-1"]}],
            "参与网页开发",
        )
        parsed = _parseCapabilityOutput(
            RemoteResumeAiRequest.model_validate(payload), output.model_dump_json()
        )
        assert parsed.missingInformation[0].path == expected_path


def test_blank_name_gets_only_a_layout_citation_from_its_existing_project_content() -> None:
    payload = basicRequest().model_dump(mode="json")
    payload["input"]["naturalLanguageInput"] = True
    payload["input"]["sourceFragments"][0]["text"] = "参与网页开发"
    output, _ = composeCase(
        {"profile": {"id": "p"}, "projects": [{"id": "p1", "summary": "参与网页开发"}]},
        [{"path": "/projects/0/summary", "fragmentIds": ["fragment-1"]}],
        "参与网页开发",
    )
    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload), output.model_dump_json()
    )
    assert isinstance(parsed, BasicResumeComposeOutput)
    assert not parsed.missingInformation
    assert parsed.candidateResume.projects[0].name == "项目经历"
    assert parsed.sourceReferences[-1].path == "/projects/0/name"


@pytest.mark.parametrize("name", ["前端技术", "HTML", ""])
def test_group_title_can_use_verified_child_sources_without_requiring_a_model_citation(
    name: str,
) -> None:
    payload = basicRequest().model_dump(mode="json")
    payload["input"]["naturalLanguageInput"] = True
    payload["input"]["sourceFragments"][0]["text"] = "会基础HTML和CSS"
    output, _ = composeCase(
        {
            "profile": {"id": "p"},
            "skillGroups": [{"id": "s", "name": name, "skills": ["HTML", "CSS"]}],
        },
        [{"path": "/skillGroups/0/skills", "fragmentIds": ["fragment-1"]}],
        "会基础HTML和CSS",
    )
    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload), output.model_dump_json()
    )
    assert isinstance(parsed, BasicResumeComposeOutput)
    assert not parsed.missingInformation
    assert parsed.candidateResume.skillGroups[0].name == ("HTML" if name == "HTML" else "技能")
    assert parsed.sourceReferences[-1].path == "/skillGroups/0/name"
    assert parsed.candidateResume.skillGroups[0].skills == ("HTML", "CSS")


def test_fixed_group_title_cannot_cover_a_skill_with_no_citation() -> None:
    payload = basicRequest().model_dump(mode="json")
    payload["input"]["naturalLanguageInput"] = True
    output, _ = composeCase(
        {"profile": {"id": "p"}, "skillGroups": [{"id": "s", "name": "前端", "skills": ["HTML"]}]},
        [{"path": "/profile", "fragmentIds": ["fragment-1"]}],
        "三年后端开发经验",
    )
    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload), output.model_dump_json()
    )
    assert parsed.missingInformation[0].path == "/skillGroups/0/skills/0"


@pytest.mark.parametrize(
    "question",
    [
        "是否愿意补充学校、专业等教育背景信息？",
        "是否方便补充教育背景？",
        "可选：如有教育背景可稍后填写。",
    ],
)
def test_optional_education_invitation_keeps_the_valid_candidate(question: str) -> None:
    payload = basicRequest().model_dump(mode="json")
    payload["input"]["naturalLanguageInput"] = True
    payload["input"]["sourceFragments"][0]["text"] = "参与网页开发"
    output, _ = composeCase(
        {
            "profile": {"id": "p"},
            "projects": [{"id": "p1", "name": "网页", "summary": "参与网页开发"}],
        },
        [{"path": "/projects/0", "fragmentIds": ["fragment-1"]}],
        "参与网页开发",
    )
    data = output.model_dump(mode="json")
    data["missingInformation"] = [
        {"path": "/educations", "question": question},
        {"path": "/profile", "question": "是否愿意提供姓名或联系方式以便放入简历？"},
    ]
    parsed = _parseCapabilityOutput(RemoteResumeAiRequest.model_validate(payload), json.dumps(data))
    assert isinstance(parsed, BasicResumeComposeOutput)
    assert not parsed.missingInformation
    assert parsed.candidateResume.projects[0].summary == "参与网页开发"
    assert not parsed.candidateResume.educations


@pytest.mark.parametrize(
    "question",
    [
        "是否愿意确认两处毕业年份冲突，应使用哪一年？",
        "请核实毕业学校，原材料存在不一致。",
        "哪个学校属于本科教育？",
    ],
)
def test_critical_education_conflicts_are_not_filtered_as_optional(question: str) -> None:
    payload = basicRequest().model_dump(mode="json")
    payload["input"]["naturalLanguageInput"] = True
    output, _ = composeCase(
        {"profile": {"id": "p"}},
        [{"path": "/profile", "fragmentIds": ["fragment-1"]}],
        "三年后端开发经验",
    )
    data = output.model_dump(mode="json")
    data["missingInformation"] = [{"path": "/educations", "question": question}]
    parsed = _parseCapabilityOutput(RemoteResumeAiRequest.model_validate(payload), json.dumps(data))
    assert parsed.missingInformation[0].question == question


def test_provider_keeps_candidate_and_actual_usage_after_optional_question_filtering() -> None:
    calls = 0
    payload = basicRequest().model_dump(mode="json")
    payload["input"]["naturalLanguageInput"] = True

    async def handler(_: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(
            200,
            json=glmResponse(
                {
                    "outputVersion": "basicResumeCompose.v1",
                    "summary": "请补充个人信息",
                    "candidateResume": {
                        "schemaVersion": "0.1.0",
                        "profile": {"id": "p", "headline": "后端开发经验"},
                    },
                    "sourceReferences": [
                        {"path": "/profile/headline", "fragmentIds": ["fragment-1"]}
                    ],
                    "missingInformation": [
                        {"path": "/profile", "question": "是否愿意提供姓名或联系方式以便放入简历？"}
                    ],
                }
            ),
        )

    async def scenario() -> RemoteProviderGeneration:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            return await GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY), httpClient=client
            ).generate(
                RemoteResumeAiRequest.model_validate(payload),
                reasoningProfile=ReasoningProfile.fast,
            )

    generation = asyncio.run(scenario())
    assert calls == 1
    assert isinstance(generation.output, BasicResumeComposeOutput)
    assert not generation.output.missingInformation
    assert generation.output.candidateResume.profile.headline == "后端开发经验"
    assert generation.inputTokens == 123 and generation.outputTokens == 456


@pytest.mark.parametrize("allow_review", [False, True])
@pytest.mark.parametrize("conversation", [False, True])
def test_fluent_rewrite_is_marked_only_for_opted_in_clients(
    allow_review: bool, conversation: bool
) -> None:
    payload = targetedRequest().model_dump(mode="json")
    payload["input"]["allowSemanticReview"] = allow_review
    output = patchOutput("负责接口开发", "负责接口功能的研发与维护").model_dump(mode="json")
    if conversation:
        payload["capability"] = "resumeOptimizationConversation"
        payload["input"]["inputType"] = "resumeOptimizationConversation"
        payload["input"].pop("userInstruction")
        payload["input"]["conversationToken"] = "synthetic-conversation-1"
        payload["input"]["userMessage"] = "帮我润色工作描述，不夸大经历"
        output["outputVersion"] = "resumeOptimizationConversation.v1"
    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload), json.dumps(output)
    )
    assert isinstance(
        parsed, (TargetedResumeOptimizationOutput, ResumeOptimizationConversationOutput)
    )
    assert (parsed.proposedPatch is not None) is allow_review
    assert (SEMANTIC_REVIEW_WARNING in parsed.warnings) is allow_review
    if not allow_review:
        assert parsed.nextAction == "provideMoreInformation"


def test_natural_compose_can_offer_a_marked_rewrite_but_not_missing_citations() -> None:
    output, request = composeCase(
        {"profile": {"id": "p", "headline": "后端接口研发"}},
        [{"path": "/profile/headline", "fragmentIds": ["source-1"]}],
        "做后端接口开发",
    )
    assert validateBasicComposeOutput(output, request, allowSemanticReview=True)
    with pytest.raises(ValueError, match="来源覆盖"):
        validateBasicComposeOutput(
            output.model_copy(update={"sourceReferences": ()}),
            request,
            allowSemanticReview=True,
        )


@pytest.mark.parametrize(
    ("old", "new"),
    [
        ("参与开发", "主导开发"),
        ("协助开发", "独立负责开发"),
        ("提升10%", "提升30%"),
        ("使用Python开发", "使用Python和Kubernetes开发"),
        ("未负责团队管理", "负责团队管理"),
    ],
)
def test_opt_in_review_never_authorizes_detected_invention(old: str, new: str) -> None:
    request_input = targetedRequest().input
    assert isinstance(request_input, TargetedResumeOptimizationInput)
    resume = request_input.resume.model_copy(
        update={
            "workExperiences": (
                request_input.resume.workExperiences[0].model_copy(update={"summary": old}),
            )
        }
    )
    with pytest.raises(ValueError, match="事实"):
        validateOptimizationOutput(patchOutput(old, new), resume, allowSemanticReview=True)


def test_marked_candidate_uses_one_model_request_and_keeps_actual_usage() -> None:
    calls = 0
    request = basicRequest().model_dump(mode="json")
    request["input"]["naturalLanguageInput"] = True
    output, _ = composeCase(
        {"profile": {"id": "p", "headline": "后端研发经验"}},
        [{"path": "/profile/headline", "fragmentIds": ["fragment-1"]}],
        "三年后端开发经验",
    )

    async def handler(_: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json=glmResponse(output.model_dump(mode="json")))

    async def scenario() -> RemoteProviderGeneration:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY), httpClient=client
            )
            return await provider.generate(
                RemoteResumeAiRequest.model_validate(request),
                reasoningProfile=ReasoningProfile.fast,
            )

    generation = asyncio.run(scenario())
    assert calls == 1
    assert SEMANTIC_REVIEW_WARNING in generation.output.warnings
    assert generation.inputTokens == 123
    assert generation.outputTokens == 456


@pytest.mark.parametrize("conversation", [False, True])
def test_one_unsupported_rewrite_does_not_discard_other_verified_edits(conversation: bool) -> None:
    payload = targetedRequest().model_dump(mode="json")
    payload["input"]["allowSemanticReview"] = True
    payload["input"]["resume"]["projects"] = [{"id": "p1", "summary": "参与表单开发"}]
    output = patchOutput("负责接口开发", "主导接口开发").model_dump(mode="json")
    safe = patchOutput("参与表单开发", "参与表单功能的开发", "/projects/0/summary")
    assert safe.proposedPatch is not None
    output["proposedPatch"]["operations"].append(
        safe.proposedPatch.operations[0].model_dump(mode="json")
    )
    if conversation:
        payload["capability"] = "resumeOptimizationConversation"
        payload["input"]["inputType"] = "resumeOptimizationConversation"
        payload["input"].pop("userInstruction")
        payload["input"].update(conversationToken="synthetic-task", userMessage="继续原任务")
        output["outputVersion"] = "resumeOptimizationConversation.v1"

    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload), json.dumps(output)
    )

    assert isinstance(
        parsed, (TargetedResumeOptimizationOutput, ResumeOptimizationConversationOutput)
    )
    assert parsed.proposedPatch is not None
    assert [op.path for op in parsed.proposedPatch.operations] == ["/projects/0/summary"]
    assert parsed.proposedPatch.operations[0].newValue == "参与表单功能的开发"
    assert not parsed.missingInformation
    assert any("未采用" in warning for warning in parsed.warnings)
    assert SEMANTIC_REVIEW_WARNING in parsed.warnings


@pytest.mark.parametrize(
    ("old", "new"),
    [
        ("Participated in Flutter page development.", "Contributed to Flutter page development."),
        ("Assisted with Flutter page development.", "Helped with Flutter page development."),
        ("参与Flutter页面开发", "协作参与Flutter页面功能开发"),
    ],
)
def test_equivalent_participation_wording_can_be_reviewed(old: str, new: str) -> None:
    payload = targetedRequest().model_dump(mode="json")
    payload["input"]["allowSemanticReview"] = True
    payload["input"]["resume"]["workExperiences"][0]["summary"] = old
    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload), patchOutput(old, new).model_dump_json()
    )
    assert isinstance(parsed, TargetedResumeOptimizationOutput)
    assert parsed.proposedPatch is not None
    assert parsed.proposedPatch.operations[0].newValue == new
    assert SEMANTIC_REVIEW_WARNING in parsed.warnings


@pytest.mark.parametrize("violation", ["stale_value", "duplicate_path", "immutable_path"])
def test_partial_fact_filter_does_not_hide_structural_or_version_errors(violation: str) -> None:
    payload = targetedRequest().model_dump(mode="json")
    payload["input"]["allowSemanticReview"] = True
    output = patchOutput("负责接口开发", "主导接口开发").model_dump(mode="json")
    extra = dict(output["proposedPatch"]["operations"][0])
    if violation == "stale_value":
        extra.update(path="/profile/headline", oldValue="过期基础版本", newValue="后端研发")
    elif violation == "immutable_path":
        extra.update(path="/profile/coarseLocation", oldValue="杭州", newValue="上海")
    output["proposedPatch"]["operations"].append(extra)
    with pytest.raises(InvalidRemoteProviderResponseError):
        _parseCapabilityOutput(RemoteResumeAiRequest.model_validate(payload), json.dumps(output))


def test_fact_rejection_reaches_existing_audit_sink_without_resume_body(
    caplog: pytest.LogCaptureFixture,
) -> None:
    old = "负责接口开发，BODY_MUST_NOT_LOG"
    payload = targetedRequest().model_dump(mode="json")
    payload["input"]["resume"]["workExperiences"][0]["summary"] = old
    parsed = _parseCapabilityOutput(
        RemoteResumeAiRequest.model_validate(payload),
        patchOutput(old, "主导接口开发，BODY_MUST_NOT_LOG").model_dump_json(),
    )
    assert parsed.missingInformation
    records = [r for r in caplog.records if "resume_fact_rejected" in r.message]
    assert records and all(r.name == "agent_gateway.audit" for r in records)
    assert all("/workExperiences/0/summary" in r.message for r in records)
    assert "BODY_MUST_NOT_LOG" not in caplog.text
