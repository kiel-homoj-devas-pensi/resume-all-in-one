"""Bounded standard label transport; structural validity is not authenticity."""

from __future__ import annotations

import base64
import json
import re
from dataclasses import dataclass
from typing import cast
from uuid import UUID

SERVICE_CONTENT_IDENTITY = "Ji Ouqi"
AIGC_VERSION_HEADER = "X-Resume-AIGC-Version"
AIGC_HEADER = "X-Resume-AIGC"
AIGC_VERSION = "1"
MAXIMUM_AIGC_JSON_BYTES = 4096
MAXIMUM_AIGC_HEADER_CHARACTERS = 5462
AIGC_FIELDS = (
    "Label",
    "ContentProducer",
    "ProduceID",
    "ReservedCode1",
    "ContentPropagator",
    "PropagateID",
    "ReservedCode2",
)
AIGC_OPENAPI_HEADERS = {
    AIGC_VERSION_HEADER: {
        "description": "Present together with X-Resume-AIGC only for a labelled 200 result.",
        "schema": {"type": "string", "enum": [AIGC_VERSION]},
    },
    AIGC_HEADER: {
        "description": "Unpadded base64url of canonical seven-field AIGC JSON, "
        "at most 4096 UTF-8 bytes. "
        "Structural source preservation does not authenticate an upstream signature.",
        "schema": {
            "type": "string",
            "maxLength": MAXIMUM_AIGC_HEADER_CHARACTERS,
            "pattern": "^[A-Za-z0-9_-]+$",
        },
    },
}


class InvalidAigcMetadata(ValueError):
    def __init__(self) -> None:
        super().__init__("invalid_aigc_metadata")


def uniqueJsonObject(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise InvalidAigcMetadata
        result[key] = value
    return result


@dataclass(frozen=True, slots=True, repr=False)
class AigcMetadata:
    values: tuple[str, ...]

    def __post_init__(self) -> None:
        if len(self.values) != len(AIGC_FIELDS) or self.values[0] not in {"1", "2", "3"}:
            raise InvalidAigcMetadata
        for key, value in zip(AIGC_FIELDS, self.values, strict=True):
            if not isinstance(value, str):
                raise InvalidAigcMetadata
            reserved = key.startswith("ReservedCode")
            if (not reserved and not value.strip()) or any(
                ord(char) < 0x20
                or 0x7F <= ord(char) <= 0x9F
                or 0xD800 <= ord(char) <= 0xDFFF
                or 0x200B <= ord(char) <= 0x200F
                or 0x2028 <= ord(char) <= 0x202E
                or 0x2060 <= ord(char) <= 0x206F
                or ord(char) == 0xFEFF
                for char in value
            ):
                raise InvalidAigcMetadata
            # Match Dart String.length (UTF-16 units), not Python code points.
            if len(value.encode("utf-16-le")) // 2 > (4096 if reserved else 512):
                raise InvalidAigcMetadata
        if len(self.toJson().encode("utf-8")) > MAXIMUM_AIGC_JSON_BYTES:
            raise InvalidAigcMetadata

    @classmethod
    def fromObject(cls, value: object) -> AigcMetadata:
        if (
            not isinstance(value, dict)
            or set(value) != set(AIGC_FIELDS)
            or not all(isinstance(item, str) for item in value.values())
        ):
            raise InvalidAigcMetadata
        return cls(tuple(cast(str, value[key]) for key in AIGC_FIELDS))

    def toObject(self) -> dict[str, str]:
        return dict(zip(AIGC_FIELDS, self.values, strict=True))

    def toJson(self) -> str:
        # This order/escaping is the private HTTP transport's canonical form.
        return json.dumps(self.toObject(), ensure_ascii=False, separators=(",", ":"))


def extractUpstreamAigc(envelope: object) -> AigcMetadata | None:
    """Only explicit AIGC objects at root, choice, and message.

    These are supported structural carriers, not a claim that Zhipu documents
    or always emits them. Do not search arbitrary user/model prose or HTTP
    headers and do not infer a provider identity from model/id/request_id.
    """
    found: AigcMetadata | None = None

    def inspect(node: object) -> None:
        nonlocal found
        if not isinstance(node, dict) or "AIGC" not in node:
            return
        source = node["AIGC"]
        if isinstance(source, str):
            try:
                if len(source.encode("utf-8")) > MAXIMUM_AIGC_JSON_BYTES:
                    raise InvalidAigcMetadata
                source = json.loads(source, object_pairs_hook=uniqueJsonObject)
            except ValueError, UnicodeError:
                raise InvalidAigcMetadata from None
        label = AigcMetadata.fromObject(source)
        if found is not None and found != label:
            raise InvalidAigcMetadata
        found = label

    inspect(envelope)
    if isinstance(envelope, dict) and isinstance(envelope.get("choices"), list):
        choices = envelope["choices"]
        if len(choices) > 16:
            raise InvalidAigcMetadata
        for choice in choices:
            inspect(choice)
            if isinstance(choice, dict):
                inspect(choice.get("message"))
    return found


def serviceAigc(operationId: str, upstream: AigcMetadata | None = None) -> AigcMetadata:
    try:
        if not operationId.startswith("usage-") or str(UUID(operationId[6:])) != operationId[6:]:
            raise ValueError
    except ValueError, AttributeError:
        raise InvalidAigcMetadata from None
    if upstream is None:
        return AigcMetadata(
            (
                "1",
                SERVICE_CONTENT_IDENTITY,
                operationId,
                "",
                SERVICE_CONTENT_IDENTITY,
                operationId,
                "",
            )
        )
    values = upstream.toObject()
    # Reserved strings are opaque source values. No claim is made that an
    # upstream signature authenticates this newly updated propagation pair.
    values["ContentPropagator"] = SERVICE_CONTENT_IDENTITY
    values["PropagateID"] = operationId
    # The previous propagation signature/code must not masquerade as this
    # service's integrity credential after its propagation fields changed.
    values["ReservedCode2"] = json.dumps(
        {"upstreamLabel": upstream.toObject()}, ensure_ascii=False, separators=(",", ":")
    )
    return AigcMetadata.fromObject(values)


def encodeAigcHeader(metadata: AigcMetadata) -> str:
    value = base64.urlsafe_b64encode(metadata.toJson().encode("utf-8")).decode("ascii").rstrip("=")
    if len(value) > MAXIMUM_AIGC_HEADER_CHARACTERS:
        raise InvalidAigcMetadata
    return value


def decodeAigcHeader(value: object) -> AigcMetadata:
    if (
        not isinstance(value, str)
        or not 1 <= len(value) <= MAXIMUM_AIGC_HEADER_CHARACTERS
        or re.fullmatch(r"[A-Za-z0-9_-]+", value) is None
    ):
        raise InvalidAigcMetadata
    try:
        decoded = base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
        if len(decoded) > MAXIMUM_AIGC_JSON_BYTES:
            raise InvalidAigcMetadata
        text = decoded.decode("utf-8")
        label = AigcMetadata.fromObject(json.loads(text, object_pairs_hook=uniqueJsonObject))
        if text != label.toJson() or value != encodeAigcHeader(label):
            raise InvalidAigcMetadata
        return label
    except ValueError, UnicodeError:
        raise InvalidAigcMetadata from None


@dataclass(frozen=True, slots=True, repr=False)
class AigcTransmission:
    header: str | None
    upstream: AigcMetadata | None

    def receiptFields(self) -> dict[str, object]:
        return {
            "receiptVersion": "0.2.0",
            "aigc": {
                "version": AIGC_VERSION,
                "header": self.header,
                "upstream": None if self.upstream is None else self.upstream.toObject(),
            },
        }


def prepareAigcTransmission(
    *,
    operationId: str,
    usesNetwork: bool,
    hasCandidate: bool,
    upstream: AigcMetadata | None,
) -> AigcTransmission:
    if upstream is not None and (not isinstance(upstream, AigcMetadata) or not usesNetwork):
        raise InvalidAigcMetadata
    header = (
        encodeAigcHeader(serviceAigc(operationId, upstream))
        if usesNetwork and hasCandidate
        else None
    )
    return AigcTransmission(header, upstream)


def cachedAigcHeader(
    receipt: dict[str, object], *, operationId: str, usesNetwork: bool, hasCandidate: bool
) -> str | None:
    if "receiptVersion" not in receipt and "aigc" not in receipt:
        # Original legacy receipts are returned without claiming a new label.
        return None
    if receipt.get("receiptVersion") != "0.2.0":
        raise InvalidAigcMetadata
    aigc = receipt.get("aigc")
    if (
        not isinstance(aigc, dict)
        or set(aigc) != {"version", "header", "upstream"}
        or aigc["version"] != AIGC_VERSION
    ):
        raise InvalidAigcMetadata
    upstream = None if aigc["upstream"] is None else AigcMetadata.fromObject(aigc["upstream"])
    expected = prepareAigcTransmission(
        operationId=operationId,
        usesNetwork=usesNetwork,
        hasCandidate=hasCandidate,
        upstream=upstream,
    )
    if aigc["header"] != expected.header:
        raise InvalidAigcMetadata
    if expected.header is not None:
        decodeAigcHeader(expected.header)
    return expected.header
