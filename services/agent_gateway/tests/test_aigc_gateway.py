from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest

from agent_gateway.aigc_metadata import AigcMetadata, decodeAigcHeader
from agent_gateway.app import createApplication
from agent_gateway.prompt_registry import ReasoningProfile
from agent_gateway.remote_contracts import RemoteResumeAiRequest
from agent_gateway.remote_provider import RemoteProviderGeneration
from tests.support import sendAsgiRequest
from tests.test_aigc_metadata import UPSTREAM
from tests.test_original_result_recovery import cache_at
from tests.test_remote_gateway import (
    RecordingRemoteProvider,
    accountHeaders,
    basicRequestBody,
    buildRemoteApplication,
)


class LabelledProvider(RecordingRemoteProvider):
    def __init__(self, upstream: AigcMetadata) -> None:
        super().__init__(usesNetwork=True)
        self.upstream = upstream

    async def generate(
        self, request: RemoteResumeAiRequest, *, reasoningProfile: ReasoningProfile
    ) -> RemoteProviderGeneration:
        generation = await super().generate(request, reasoningProfile=reasoningProfile)
        return replace(generation, upstreamAigc=self.upstream)


@pytest.mark.parametrize("network", [False, True])
def test_old_exact_json_contract_and_label_only_for_actual_network_candidate(
    tmp_path: Path, network: bool
) -> None:
    application, _, _, token, _ = buildRemoteApplication(
        tmp_path, RecordingRemoteProvider(usesNetwork=network)
    )
    response = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(token),
        jsonBody=basicRequestBody(),
    )
    assert response.status_code == 200
    assert set(response.json()) == {
        "protocolVersion",
        "operationId",
        "clientRequestId",
        "capability",
        "status",
        "output",
        "execution",
    }
    assert response.json()["protocolVersion"] == "0.3.0"
    assert set(response.json()["execution"]) == {"usesNetwork", "promptVersion"}
    if network:
        assert response.headers["X-Resume-AIGC-Version"] == "1"
        label = decodeAigcHeader(response.headers["X-Resume-AIGC"]).toObject()
        assert label["ContentProducer"] == label["ContentPropagator"] == "Ji Ouqi"
        assert label["ProduceID"] == label["PropagateID"] == response.json()["operationId"]
    else:
        assert (
            "X-Resume-AIGC" not in response.headers
            and "X-Resume-AIGC-Version" not in response.headers
        )


@pytest.mark.parametrize("recovery", [False, True])
def test_upstream_original_and_final_label_roundtrip_after_restart(
    tmp_path: Path, recovery: bool
) -> None:
    provider = LabelledProvider(AigcMetadata.fromObject(UPSTREAM))
    original, _, owner, token, _ = buildRemoteApplication(tmp_path, provider)
    cache = cache_at(tmp_path / "results")
    application = createApplication(
        settings=original.state.settings,
        accountService=original.state.accountService,
        usagePolicy=original.state.usagePolicy,
        remoteResumeProvider=provider,
        remoteResultCache=cache,
    )
    headers = accountHeaders(token)
    if recovery:
        headers["X-Result-Recovery"] = "0.1.0"
    submitted = sendAsgiRequest(
        application, "POST", "/v1/resume-ai/requests", headers=headers, jsonBody=basicRequestBody()
    )
    assert submitted.status_code == 200
    result = decodeAigcHeader(submitted.headers["X-Resume-AIGC"]).toObject()
    assert result["ContentProducer"] == UPSTREAM["ContentProducer"]
    assert result["PropagateID"] == submitted.json()["operationId"]
    receipt = cache.read(owner, submitted.json()["operationId"])
    assert receipt is not None and receipt["aigc"] == {
        "version": "1",
        "header": submitted.headers["X-Resume-AIGC"],
        "upstream": UPSTREAM,
    }
    restarted_provider = RecordingRemoteProvider()
    restarted = createApplication(
        settings=original.state.settings,
        accountService=original.state.accountService,
        usagePolicy=original.state.usagePolicy,
        remoteResumeProvider=restarted_provider,
        remoteResultCache=cache_at(tmp_path / "results"),
    )
    recovered = sendAsgiRequest(
        restarted,
        "POST",
        "/v1/resume-ai/results/lookup",
        headers=accountHeaders(token),
        jsonBody={
            "protocolVersion": "0.4.0",
            "capability": "basicResumeCompose",
            "usageOperationId": submitted.json()["operationId"],
        },
    )
    assert recovered.status_code == 200 and recovered.json() == submitted.json()
    assert recovered.headers["X-Resume-AIGC-Version"] == "1"
    assert recovered.headers["X-Resume-AIGC"] == submitted.headers["X-Resume-AIGC"]
    assert provider.generateCallCount == 1 and restarted_provider.generateCallCount == 0
    # Metadata integrity failure must not be silently turned into label absence.
    receipt["aigc"] = {"version": "1", "header": "invalid-value", "upstream": UPSTREAM}
    cache.save(owner, submitted.json()["operationId"], receipt)
    corrupt = sendAsgiRequest(
        restarted,
        "POST",
        "/v1/resume-ai/results/lookup",
        headers=accountHeaders(token),
        jsonBody={
            "protocolVersion": "0.4.0",
            "capability": "basicResumeCompose",
            "usageOperationId": submitted.json()["operationId"],
        },
    )
    assert corrupt.status_code == 503 and "X-Resume-AIGC" not in corrupt.headers
    assert "opaque-production-code" not in corrupt.text


def test_upstream_without_receipt_cache_fails_without_charging_candidate_result(
    tmp_path: Path,
) -> None:
    provider = LabelledProvider(AigcMetadata.fromObject(UPSTREAM))
    application, database, _, token, _ = buildRemoteApplication(tmp_path, provider)
    response = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(token),
        jsonBody=basicRequestBody(),
    )
    assert response.status_code == 503 and "X-Resume-AIGC" not in response.headers
    assert provider.generateCallCount == 1
    with database.readConnection() as connection:
        row = connection.execute(
            "SELECT status,failure_code,input_tokens,output_tokens FROM usage_operations"
        ).fetchone()
        assert tuple(row) == ("committed", "no_usable_candidate", 17, 29)


def test_final_wrapper_oversize_rejection_keeps_known_usage_and_no_success_header(
    tmp_path: Path,
) -> None:
    value = dict(UPSTREAM, ReservedCode1="a" * 3000)
    provider = LabelledProvider(AigcMetadata.fromObject(value))
    application, database, _, token, _ = buildRemoteApplication(tmp_path, provider)
    response = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(token),
        jsonBody=basicRequestBody(),
    )
    assert (
        response.status_code == 502
        and response.json()["error"]["code"] == "invalid_provider_response"
    )
    assert "X-Resume-AIGC" not in response.headers and "a" * 3000 not in response.text
    with database.readConnection() as connection:
        row = connection.execute(
            "SELECT status,failure_code,input_tokens,output_tokens FROM usage_operations"
        ).fetchone()
        assert tuple(row) == ("committed", "no_usable_candidate", 17, 29)


def test_legacy_cached_receipt_has_no_invented_new_label(tmp_path: Path) -> None:
    provider = RecordingRemoteProvider(usesNetwork=True)
    original, _, owner, token, _ = buildRemoteApplication(tmp_path, provider)
    cache = cache_at(tmp_path / "results")
    application = createApplication(
        settings=original.state.settings,
        accountService=original.state.accountService,
        usagePolicy=original.state.usagePolicy,
        remoteResumeProvider=provider,
        remoteResultCache=cache,
    )
    submitted = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers={**accountHeaders(token), "X-Result-Recovery": "0.1.0"},
        jsonBody=basicRequestBody(),
    )
    receipt = cache.read(owner, submitted.json()["operationId"])
    assert receipt is not None
    del receipt["receiptVersion"]
    del receipt["aigc"]
    cache.save(owner, submitted.json()["operationId"], receipt)
    restored = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/results/lookup",
        headers=accountHeaders(token),
        jsonBody={
            "protocolVersion": "0.4.0",
            "capability": "basicResumeCompose",
            "usageOperationId": submitted.json()["operationId"],
        },
    )
    assert restored.status_code == 200 and restored.json() == submitted.json()
    assert (
        "X-Resume-AIGC" not in restored.headers and "X-Resume-AIGC-Version" not in restored.headers
    )
