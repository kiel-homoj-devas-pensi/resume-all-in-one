from __future__ import annotations

import asyncio
import base64
import json
from copy import deepcopy
from pathlib import Path

import httpx
import pytest

from agent_gateway.aigc_metadata import (
    AIGC_FIELDS,
    AigcMetadata,
    InvalidAigcMetadata,
    cachedAigcHeader,
    decodeAigcHeader,
    encodeAigcHeader,
    extractUpstreamAigc,
    prepareAigcTransmission,
    serviceAigc,
    uniqueJsonObject,
)
from agent_gateway.prompt_registry import ReasoningProfile
from agent_gateway.remote_provider import (
    GlmProviderConfig,
    GlmRemoteResumeProvider,
    InvalidRemoteProviderResponseError,
    RemoteProviderGeneration,
)
from tests.test_glm_remote_provider import TEST_GLM_KEY, basicRequest, glmResponse

OPERATION = "usage-00000000-0000-4000-8000-000000000001"
UPSTREAM = {
    "Label": "1",
    "ContentProducer": "真实上游主体",
    "ProduceID": "real-upstream-id",
    "ReservedCode1": "opaque-production-code",
    "ContentPropagator": "真实原传播方",
    "PropagateID": "original-propagation-id",
    "ReservedCode2": "opaque-propagation-code",
}


def rawHeader(text: str) -> str:
    return base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")


def test_service_identity_real_operation_and_source_preservation_wrapper() -> None:
    own = serviceAigc(OPERATION)
    assert own.toObject() == {
        "Label": "1",
        "ContentProducer": "Ji Ouqi",
        "ProduceID": OPERATION,
        "ReservedCode1": "",
        "ContentPropagator": "Ji Ouqi",
        "PropagateID": OPERATION,
        "ReservedCode2": "",
    }
    upstream = AigcMetadata.fromObject(UPSTREAM)
    result = serviceAigc(OPERATION, upstream).toObject()
    assert (result["ContentProducer"], result["ProduceID"], result["ReservedCode1"]) == (
        UPSTREAM["ContentProducer"],
        UPSTREAM["ProduceID"],
        UPSTREAM["ReservedCode1"],
    )
    assert (result["ContentPropagator"], result["PropagateID"]) == ("Ji Ouqi", OPERATION)
    assert json.loads(result["ReservedCode2"]) == {"upstreamLabel": UPSTREAM}
    assert result["ReservedCode2"] != UPSTREAM["ReservedCode2"]


def test_ascii_canonical_header_unicode_quotes_slashes_and_dart_key_order() -> None:
    value = dict(UPSTREAM, ReservedCode1='中文😀"\\/')
    label = AigcMetadata.fromObject(value)
    encoded = encodeAigcHeader(label)
    assert encoded.isascii() and "=" not in encoded
    assert decodeAigcHeader(encoded) == label
    assert tuple(json.loads(label.toJson())) == AIGC_FIELDS
    assert "😀" in label.toJson()
    assert json.loads(label.toJson())["ReservedCode1"] == value["ReservedCode1"]


def test_shared_cross_language_vectors_match_real_encoder_and_source_identity() -> None:
    fixture = json.loads(
        (Path(__file__).parent / "fixtures/aigc-header-v1.json").read_text(encoding="utf-8")
    )
    assert fixture["schemaVersion"] == fixture["transportVersion"] == "1"
    assert (fixture["maximumJsonUtf8Bytes"], fixture["maximumHeaderCharacters"]) == (4096, 5462)
    assert len(fixture["vectors"]) == 2
    for vector in fixture["vectors"]:
        upstream = (
            None if vector["upstream"] is None else AigcMetadata.fromObject(vector["upstream"])
        )
        label = serviceAigc(vector["operationId"], upstream)
        assert label.toObject() == vector["expectedMetadata"]
        assert label.toJson() == vector["expectedInnerJson"]
        assert encodeAigcHeader(label) == vector["expectedHeader"]
        assert decodeAigcHeader(vector["expectedHeader"]) == label
        data = label.toObject()
        assert vector["expectedSourceIdentity"] == {
            "producer": data["ContentProducer"],
            "produceId": data["ProduceID"],
            "propagator": data["ContentPropagator"],
            "propagateId": data["PropagateID"],
        }
    assert (
        prepareAigcTransmission(
            operationId=OPERATION, usesNetwork=True, hasCandidate=False, upstream=None
        ).header
        is None
    )


@pytest.mark.parametrize("place", ["root", "choice", "message"])
def test_explicit_supported_carriers_preserve_the_original(place: str) -> None:
    envelope: dict[str, object] = {"choices": [{"message": {}}]}
    choices = envelope["choices"]
    assert isinstance(choices, list)
    node = (
        envelope if place == "root" else choices[0] if place == "choice" else choices[0]["message"]
    )
    node["AIGC"] = dict(reversed(list(UPSTREAM.items())))
    assert extractUpstreamAigc(envelope) == AigcMetadata.fromObject(UPSTREAM)
    node["AIGC"] = json.dumps(UPSTREAM, ensure_ascii=False)
    assert extractUpstreamAigc(envelope) == AigcMetadata.fromObject(UPSTREAM)
    assert extractUpstreamAigc({"id": "do-not-infer", "model": "glm-5.3"}) is None


def test_identical_carriers_are_consistent_conflicts_and_duplicate_keys_rejected() -> None:
    envelope = {"AIGC": UPSTREAM, "choices": [{"AIGC": UPSTREAM}]}
    assert extractUpstreamAigc(envelope) == AigcMetadata.fromObject(UPSTREAM)
    envelope["choices"] = [{"AIGC": dict(UPSTREAM, ProduceID="conflicting-id")}]
    with pytest.raises(InvalidAigcMetadata):
        extractUpstreamAigc(envelope)
    with pytest.raises(InvalidAigcMetadata):
        json.loads('{"AIGC":{},"AIGC":{}}', object_pairs_hook=uniqueJsonObject)


@pytest.mark.parametrize(
    "changes",
    [
        {"Label": "0"},
        {"Label": 1},
        {"ProduceID": ""},
        {"ContentProducer": "  "},
        {"ReservedCode2": "private\r\nvalue"},
        {"ReservedCode1": "\u0085"},
        {"ReservedCode1": "\ud800"},
        {"ReservedCode1": "\u200b"},
        {"ReservedCode1": "\u2028"},
        {"ReservedCode1": "\u2029"},
        {"ReservedCode1": "\u202e"},
        {"ReservedCode1": "\u2060"},
        {"ReservedCode1": "\ufeff"},
        {"ProduceID": "😀" * 257},
        {"ReservedCode1": "a" * 4097},
        {"unknown": "must-not-strip"},
    ],
)
def test_invalid_metadata_never_echoes_source_values(changes: dict[str, object]) -> None:
    with pytest.raises(InvalidAigcMetadata) as error:
        AigcMetadata.fromObject({**UPSTREAM, **changes})
    assert str(error.value) == "invalid_aigc_metadata"


def test_exact_4096_byte_5462_character_bound_and_wrapper_expansion_failure() -> None:
    value = serviceAigc(OPERATION).toObject()
    size = len(AigcMetadata.fromObject(value).toJson().encode())
    value["ReservedCode1"] = "a" * (4096 - size)
    label = AigcMetadata.fromObject(value)
    assert len(label.toJson().encode()) == 4096
    assert len(encodeAigcHeader(label)) == 5462
    assert decodeAigcHeader(encodeAigcHeader(label)) == label
    with pytest.raises(InvalidAigcMetadata):
        AigcMetadata.fromObject({**value, "ReservedCode1": value["ReservedCode1"] + "a"})
    with pytest.raises(InvalidAigcMetadata):
        serviceAigc(OPERATION, label)


@pytest.mark.parametrize("alteration", ["padding", "whitespace", "duplicate", "order", "oversize"])
def test_internal_header_rejects_noncanonical_or_oversize(alteration: str) -> None:
    label = serviceAigc(OPERATION)
    if alteration == "padding":
        value = encodeAigcHeader(label) + "="
    elif alteration == "whitespace":
        value = rawHeader(json.dumps(label.toObject()))
    elif alteration == "duplicate":
        value = rawHeader(label.toJson()[:-1] + ',"Label":"1"}')
    elif alteration == "order":
        value = rawHeader(
            json.dumps(dict(reversed(list(label.toObject().items()))), separators=(",", ":"))
        )
    else:
        value = "a" * 5463
    with pytest.raises(InvalidAigcMetadata):
        decodeAigcHeader(value)


def test_receipt_full_binding_and_old_receipt_compatibility() -> None:
    transmission = prepareAigcTransmission(
        operationId=OPERATION,
        usesNetwork=True,
        hasCandidate=True,
        upstream=AigcMetadata.fromObject(UPSTREAM),
    )
    receipt = transmission.receiptFields()
    assert (
        cachedAigcHeader(receipt, operationId=OPERATION, usesNetwork=True, hasCandidate=True)
        == transmission.header
    )
    assert cachedAigcHeader({}, operationId=OPERATION, usesNetwork=True, hasCandidate=True) is None
    for network, candidate, operation in (
        (False, True, OPERATION),
        (True, False, OPERATION),
        (True, True, "usage-00000000-0000-4000-8000-000000000002"),
    ):
        with pytest.raises(InvalidAigcMetadata):
            cachedAigcHeader(
                receipt, operationId=operation, usesNetwork=network, hasCandidate=candidate
            )
    altered = deepcopy(receipt)
    altered["aigc"] = {"version": "1", "header": transmission.header, "upstream": None}
    with pytest.raises(InvalidAigcMetadata):
        cachedAigcHeader(altered, operationId=OPERATION, usesNetwork=True, hasCandidate=True)
    with pytest.raises(InvalidAigcMetadata):
        cachedAigcHeader(
            {"receiptVersion": "0.2.0"}, operationId=OPERATION, usesNetwork=True, hasCandidate=True
        )


@pytest.mark.parametrize("valid", [True, False])
def test_glm_parser_preserves_source_label_or_rejects_with_known_execution_usage(
    valid: bool,
) -> None:
    content: dict[str, object] = {
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
        "sourceReferences": [{"path": "/profile/headline", "fragmentIds": ["fragment-1"]}],
    }
    envelope = glmResponse(content)
    envelope["AIGC"] = UPSTREAM if valid else dict(UPSTREAM, ProduceID="private\ninvalid")

    async def scenario() -> RemoteProviderGeneration:
        async def handle(request: httpx.Request) -> httpx.Response:
            del request
            return httpx.Response(200, json=envelope)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig(apiKey=TEST_GLM_KEY), httpClient=client
            )
            return await provider.generate(basicRequest(), reasoningProfile=ReasoningProfile.fast)

    if valid:
        generation = asyncio.run(scenario())
        assert generation.upstreamAigc == AigcMetadata.fromObject(UPSTREAM)
    else:
        with pytest.raises(InvalidRemoteProviderResponseError) as error:
            asyncio.run(scenario())
        assert (error.value.inputTokens, error.value.outputTokens) == (123, 456)
        assert "private" not in str(error.value)
