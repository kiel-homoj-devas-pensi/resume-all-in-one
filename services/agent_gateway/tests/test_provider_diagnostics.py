from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import cast

import httpx
import pytest

import agent_gateway.remote_provider as providerModule
from agent_gateway.prompt_registry import ReasoningProfile
from agent_gateway.remote_contracts import (
    BasicResumeComposeOutput,
    RemoteResumeAiRequest,
    hasUsableCandidate,
)
from agent_gateway.remote_provider import (
    GlmProviderConfig,
    GlmRemoteResumeProvider,
    InvalidRemoteProviderResponseError,
    RemoteProviderGeneration,
)
from agent_gateway.resume_fact_guard import UnverifiedFactError

_privateMarker = "PRIVATE_BODY_AND_DYNAMIC_FIELD_72931"
_personalValues = {
    "fullName": "合成姓名",
    "phone": "+8613800000000",
    "email": "synthetic@example.com",
    "preciseAddress": "合成示例路",
}


def _request(personalField: str | None = None) -> RemoteResumeAiRequest:
    payload: dict[str, object] = {
        "inputType": "basicResumeCompose",
        "naturalLanguageInput": True,
        "sourceFragments": [{"fragmentId": "fragment-1", "text": "参与页面开发"}],
    }
    if personalField is not None:
        payload["personalData"] = {
            "consentedFields": [personalField],
            personalField: _personalValues[personalField],
        }
    return RemoteResumeAiRequest.model_validate(
        {
            "protocolVersion": "0.3.0",
            "clientRequestId": "diagnostic-request",
            "idempotencyKey": "diagnostic-idempotency",
            "capability": "basicResumeCompose",
            "input": payload,
        }
    )


def _output(personalField: str | None = None) -> dict[str, object]:
    profile: dict[str, object] = {"id": "profile-1", "headline": "参与页面开发"}
    references: list[dict[str, object]] = [
        {"path": "/profile/headline", "fragmentIds": ["fragment-1"]}
    ]
    if personalField is not None:
        profile[personalField] = _personalValues[personalField]
        references.append({"path": f"/profile/{personalField}", "fragmentIds": ["personal-form"]})
    return {
        "outputVersion": "basicResumeCompose.v1",
        "summary": "整理已有材料",
        "candidateResume": {"schemaVersion": "0.1.0", "profile": profile},
        "sourceReferences": references,
    }


def _envelope(content: object, finishReason: str = "stop") -> dict[str, object]:
    return {
        "choices": [{"finish_reason": finishReason, "message": {"content": content}}],
        "usage": {"prompt_tokens": 4265, "completion_tokens": 804},
    }


def _generate(
    body: object, request: RemoteResumeAiRequest | None = None
) -> RemoteProviderGeneration:
    calls = 0

    async def scenario() -> RemoteProviderGeneration:
        def respond(httpRequest: httpx.Request) -> httpx.Response:
            nonlocal calls
            del httpRequest
            calls += 1
            return httpx.Response(200, json=body)

        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey="synthetic-provider-key-not-a-secret"), httpClient=client
            )
            return await provider.generate(
                request or _request(), reasoningProfile=ReasoningProfile.fast
            )

    try:
        return asyncio.run(scenario())
    finally:
        assert calls == 1


@pytest.mark.parametrize("field", tuple(_personalValues))
def test_exact_consented_form_value_does_not_need_an_invented_fragment_reference(
    field: str,
) -> None:
    result = _generate(_envelope(json.dumps(_output(field))), _request(field))
    profile = result.output.model_dump(mode="json")["candidateResume"]["profile"]
    assert profile[field] == _personalValues[field]
    assert result.inputTokens == 4265 and result.outputTokens == 804
    assert result.output.model_dump(mode="json")["sourceReferences"] == [
        {"path": "/profile/headline", "fragmentIds": ["fragment-1"]}
    ]


@pytest.mark.parametrize("violation", ["changed_value", "not_consented", "only_bad_reference"])
def test_form_reference_compatibility_does_not_authorize_other_personal_values(
    violation: str,
) -> None:
    output = _output("fullName")
    request = _request("fullName")
    if violation == "changed_value":
        candidate = cast(dict[str, object], output["candidateResume"])
        cast(dict[str, object], candidate["profile"])["fullName"] = _privateMarker
    elif violation == "not_consented":
        request = _request()
    else:
        output["sourceReferences"] = [cast(list[object], output["sourceReferences"])[1]]
    with pytest.raises(InvalidRemoteProviderResponseError):
        _generate(_envelope(json.dumps(output)), request)


def test_changed_consented_value_with_valid_fragments_still_has_no_deliverable_candidate() -> None:
    output = _output("fullName")
    candidate = cast(dict[str, object], output["candidateResume"])
    cast(dict[str, object], candidate["profile"])["fullName"] = _privateMarker
    cast(list[dict[str, object]], output["sourceReferences"])[1]["fragmentIds"] = ["fragment-1"]
    result = _generate(_envelope(json.dumps(output)), _request("fullName"))
    assert result.output.missingInformation
    assert not hasUsableCandidate(result.output)
    assert _privateMarker not in result.output.model_dump_json()


@pytest.mark.parametrize("path", ["/profile", "/profile/headline", "/projects/0/summary"])
def test_parent_and_other_invalid_references_are_never_removed(path: str) -> None:
    output = _output("fullName")
    cast(list[dict[str, object]], output["sourceReferences"]).append(
        {"path": path, "fragmentIds": [_privateMarker]}
    )
    with pytest.raises(InvalidRemoteProviderResponseError):
        _generate(_envelope(json.dumps(output)), _request("fullName"))


@pytest.mark.parametrize(
    ("case", "stage", "errorType", "location"),
    [
        ("envelope", "envelope", "string_type", "/choices/0/message/content"),
        ("finish", "finish_reason", "invalid_response", "/choices/0/finish_reason"),
        ("json", "json", "json_decode_error", "/"),
        ("schema", "schema", "string_type", "/summary"),
        ("dynamic_key", "schema", "extra_forbidden", "/"),
        ("reference", "candidate_references", "invalid_reference", "/sourceReferences"),
    ],
)
def test_rejection_diagnostics_are_structural_and_usage_survives(
    case: str, stage: str, errorType: str, location: str, caplog: pytest.LogCaptureFixture
) -> None:
    output = _output()
    body = _envelope(json.dumps(output))
    if case == "envelope":
        body = _envelope({_privateMarker: _privateMarker})
    elif case == "finish":
        body = _envelope(_privateMarker, _privateMarker)
    elif case == "json":
        body = _envelope("{" + _privateMarker)
    elif case == "schema":
        output["summary"] = [_privateMarker]
        body = _envelope(json.dumps(output))
    elif case == "dynamic_key":
        output[_privateMarker] = _privateMarker
        body = _envelope(json.dumps(output))
    elif case == "reference":
        output["sourceReferences"] = [
            {"path": "/profile/headline", "fragmentIds": [_privateMarker]}
        ]
        body = _envelope(json.dumps(output))
    with pytest.raises(InvalidRemoteProviderResponseError) as caught:
        _generate(body)
    assert caught.value.inputTokens == 4265 and caught.value.outputTokens == 804
    assert caught.value.promptVersion is not None
    records = [record for record in caplog.records if record.name == "agent_gateway.audit"]
    assert len(records) == 1
    assert records[0].getMessage() == (
        f"provider_response_rejected stage={stage} error_type={errorType} location={location}"
    )
    assert _privateMarker not in caplog.text


def test_writing_scope_diagnostics_persist_without_exception_text_or_tokens(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    def rejectScope(*args: object) -> None:
        del args
        raise ValueError(_privateMarker)

    monkeypatch.setattr(providerModule, "validateWritingScope", rejectScope)
    sink = tmp_path / "operations.log"
    logger = logging.getLogger("agent_gateway.audit")
    handler = logging.FileHandler(sink, encoding="utf-8")
    logger.addHandler(handler)
    try:
        with pytest.raises(InvalidRemoteProviderResponseError) as caught:
            _generate(_envelope(json.dumps(_output())))
        assert caught.value.inputTokens == 4265 and caught.value.outputTokens == 804
    finally:
        logger.removeHandler(handler)
        handler.close()
    persisted = sink.read_text(encoding="utf-8")
    assert "stage=writing_scope error_type=value_error location=/" in persisted
    for excluded in [_privateMarker, "参与页面开发", "4265", "804", "synthetic-provider-key"]:
        assert excluded not in persisted and excluded not in caplog.text


@pytest.mark.parametrize("section", ["workExperiences", "educations", "projects"])
def test_unknown_date_invitation_keeps_existing_candidate_without_inventing_dates(
    section: str,
) -> None:
    output = _output()
    candidate = cast(dict[str, object], output["candidateResume"])
    candidate[section] = [{"id": "experience-1", "dateRange": None, "highlights": ["参与页面开发"]}]
    cast(list[dict[str, object]], output["sourceReferences"]).append(
        {"path": f"/{section}/0", "fragmentIds": ["fragment-1"]}
    )
    output["missingInformation"] = [
        {"path": f"/{section}/0/dateRange", "question": "这段经历是否有起止时间？"}
    ]
    result = _generate(_envelope(json.dumps(output)))
    assert hasUsableCandidate(result.output)
    assert not result.output.missingInformation
    saved = result.output.model_dump(mode="json")["candidateResume"][section][0]
    assert saved["dateRange"] is None and saved["highlights"] == ["参与页面开发"]
    assert result.inputTokens == 4265 and result.outputTokens == 804


@pytest.mark.parametrize(
    "question", ["起止时间存在冲突，哪个正确？", "请核实开始和结束时间是否一致。"]
)
def test_date_conflict_remains_a_blocking_question(question: str) -> None:
    output = _output()
    output["missingInformation"] = [{"path": "/projects/0/dateRange", "question": question}]
    result = _generate(_envelope(json.dumps(output)))
    assert result.output.missingInformation[0].question == question
    assert not hasUsableCandidate(result.output)


def test_date_invitation_does_not_make_an_empty_response_deliverable() -> None:
    output = _output()
    cast(dict[str, object], cast(dict[str, object], output["candidateResume"])["profile"])[
        "headline"
    ] = ""
    output["missingInformation"] = [
        {"path": "/projects/0/dateRange", "question": "是否有时间信息？"}
    ]
    result = _generate(_envelope(json.dumps(output)))
    assert result.output.missingInformation
    assert not hasUsableCandidate(result.output)


def test_filtering_optional_date_questions_still_rejects_an_invented_year() -> None:
    output = _output()
    cast(dict[str, object], output["candidateResume"])["workExperiences"] = [
        {"id": "work-1", "dateRange": {"start": {"year": 2025}}, "highlights": ["参与页面开发"]}
    ]
    cast(list[dict[str, object]], output["sourceReferences"]).append(
        {"path": "/workExperiences/0", "fragmentIds": ["fragment-1"]}
    )
    output["missingInformation"] = [
        {"path": "/workExperiences/0/dateRange", "question": "是否有起止时间？"}
    ]
    result = _generate(_envelope(json.dumps(output)))
    assert result.output.missingInformation[0].path == "/workExperiences/0/dateRange/start/year"
    assert not hasUsableCandidate(result.output)


def _customSectionOutput(title: str = "Generated section") -> dict[str, object]:
    return {
        "outputVersion": "basicResumeCompose.v1",
        "summary": "Organized the supplied facts",
        "candidateResume": {
            "schemaVersion": "0.1.0",
            "profile": {"id": "profile-1"},
            "customSections": [
                {
                    "id": "section-1",
                    "title": title,
                    "items": [
                        {
                            "id": "item-1",
                            "title": "Web project",
                            "description": "Contributed to the web pages.",
                        }
                    ],
                }
            ],
        },
        "sourceReferences": [{"path": "/customSections/0/items/0", "fragmentIds": ["fragment-1"]}],
    }


def _englishCustomRequest(sourcePrefix: str = "") -> RemoteResumeAiRequest:
    payload = _request().model_dump(mode="json")
    payload["input"]["sourceFragments"][0]["text"] = (
        sourcePrefix + "Web project. Contributed to the web pages."
    )
    return RemoteResumeAiRequest.model_validate(payload)


@pytest.mark.parametrize(
    "title", ["Generated section", "经历与能力", _privateMarker, "主导99个项目"]
)
def test_custom_layout_title_without_its_own_reference_keeps_verified_items(title: str) -> None:
    output = _customSectionOutput(title)
    result = _generate(_envelope(json.dumps(output)), _englishCustomRequest())
    assert isinstance(result.output, BasicResumeComposeOutput)
    assert hasUsableCandidate(result.output)
    section = result.output.model_dump(mode="json")["candidateResume"]["customSections"][0]
    assert section["title"] == "经历与能力"
    assert (
        section["items"]
        == (
            cast(
                list[dict[str, object]],
                cast(dict[str, object], output["candidateResume"])["customSections"],
            )[0]["items"]
        )
    )
    assert any(
        reference.path == "/customSections/0/title" and reference.fragmentIds == ("fragment-1",)
        for reference in result.output.sourceReferences
    )
    assert result.inputTokens == 4265 and result.outputTokens == 804


def test_explicit_source_custom_title_is_retained_with_a_real_source_reference() -> None:
    output = _customSectionOutput("Practical experience")
    result = _generate(
        _envelope(json.dumps(output)), _englishCustomRequest("Practical experience. ")
    )
    section = result.output.model_dump(mode="json")["candidateResume"]["customSections"][0]
    assert hasUsableCandidate(result.output) and section["title"] == "Practical experience"


@pytest.mark.parametrize(
    "violation", ["invented_number", "missing_item_reference", "unknown_reference"]
)
def test_neutral_custom_title_never_authorizes_unsupported_item_facts_or_references(
    violation: str,
) -> None:
    output = _customSectionOutput()
    candidate = cast(dict[str, object], output["candidateResume"])
    section = cast(list[dict[str, object]], candidate["customSections"])[0]
    if violation == "invented_number":
        cast(list[dict[str, object]], section["items"])[0]["description"] = "Delivered 99 projects."
    elif violation == "missing_item_reference":
        output["sourceReferences"] = [
            {"path": "/customSections/0/title", "fragmentIds": ["fragment-1"]}
        ]
    else:
        cast(list[dict[str, object]], output["sourceReferences"]).append(
            {"path": "/customSections/0/items/0", "fragmentIds": [_privateMarker]}
        )
    if violation == "unknown_reference":
        with pytest.raises(InvalidRemoteProviderResponseError):
            _generate(_envelope(json.dumps(output)), _englishCustomRequest())
    else:
        result = _generate(_envelope(json.dumps(output)), _englishCustomRequest())
        assert not hasUsableCandidate(result.output) and result.output.missingInformation


def test_custom_layout_title_without_any_item_content_is_not_a_candidate() -> None:
    output = _customSectionOutput()
    candidate = cast(dict[str, object], output["candidateResume"])
    cast(list[dict[str, object]], candidate["customSections"])[0]["items"] = []
    output["sourceReferences"] = [
        {"path": "/customSections/0/title", "fragmentIds": ["fragment-1"]}
    ]
    with pytest.raises(InvalidRemoteProviderResponseError):
        _generate(_envelope(json.dumps(output)), _englishCustomRequest())


@pytest.mark.parametrize(
    ("violation", "reasonCode"),
    [
        ("coverage", "source_coverage_missing"),
        ("entity", "entity_unsupported"),
        ("number", "number_or_date_mismatch"),
        ("responsibility", "responsibility_escalation"),
        ("personal", "personal_data_changed"),
        ("semantic", "semantic_review_required"),
    ],
)
def test_real_fact_validation_failures_emit_only_stable_reason_codes(
    violation: str, reasonCode: str, caplog: pytest.LogCaptureFixture
) -> None:
    request = _request("fullName") if violation == "personal" else _request()
    output = _output("fullName") if violation == "personal" else _output()
    candidate = cast(dict[str, object], output["candidateResume"])
    profile = cast(dict[str, object], candidate["profile"])
    if violation == "coverage":
        output["sourceReferences"] = [{"path": "/profile/id", "fragmentIds": ["fragment-1"]}]
    elif violation == "entity":
        candidate["workExperiences"] = [{"id": "work-1", "organization": "未提供的单位"}]
        cast(list[dict[str, object]], output["sourceReferences"]).append(
            {"path": "/workExperiences/0", "fragmentIds": ["fragment-1"]}
        )
    elif violation == "number":
        profile["headline"] = "参与99个页面开发"
    elif violation == "responsibility":
        profile["headline"] = "主导页面开发"
    elif violation == "personal":
        profile["fullName"] = _privateMarker
        cast(list[dict[str, object]], output["sourceReferences"])[1]["fragmentIds"] = ["fragment-1"]
    else:
        payload = request.model_dump(mode="json")
        payload["input"]["naturalLanguageInput"] = False
        request = RemoteResumeAiRequest.model_validate(payload)
        profile["headline"] = "开发网站交互"
    result = _generate(_envelope(json.dumps(output)), request)
    assert not hasUsableCandidate(result.output)
    assert f"error_type={reasonCode}" in caplog.text and f"reason={reasonCode}" in caplog.text
    assert _privateMarker not in caplog.text


def test_unknown_fact_reason_and_dynamic_path_are_never_echoed(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    def rejectFact(*args: object, **kwargs: object) -> bool:
        del args, kwargs
        raise UnverifiedFactError(_privateMarker, path="/profile/" + _privateMarker)

    monkeypatch.setattr(providerModule, "validateBasicComposeOutput", rejectFact)
    result = _generate(_envelope(json.dumps(_output())))
    assert not hasUsableCandidate(result.output)
    assert "error_type=unverified_fact location=/profile" in caplog.text
    assert "path=/profile reason=unverified_fact" in caplog.text
    assert _privateMarker not in caplog.text
