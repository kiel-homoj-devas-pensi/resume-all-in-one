from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal, DecimalException
from typing import Annotated, Any, Literal, cast
from urllib.parse import urlsplit

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, ValidationError, model_validator

MAXIMUM_SNAPSHOT_BYTES = 49_152
MAXIMUM_JSON_DEPTH = 32
MAXIMUM_JSON_NODES = 8_192


class CanonicalSnapshotError(ValueError):
    def __init__(self, code: str = "invalid_json", path: str = "$") -> None:
        super().__init__("canonical_snapshot_invalid")
        self.code = code
        self.path = path


def _nonempty(value: str) -> str:
    if not value.strip():
        raise ValueError("required_text")
    return value


def _url(value: str) -> str:
    if not value.strip():
        return value
    try:
        parts = urlsplit(value)
        if (
            parts.scheme not in {"http", "https"}
            or not parts.hostname
            or any(character.isspace() or ord(character) < 32 for character in value)
        ):
            raise ValueError("absolute_http_url_required")
        # 检查非法端口/括号，不访问 URL、不探测域名。
        _ = parts.port
    except ValueError:
        raise ValueError("absolute_http_url_required") from None
    return value


def _timestamp(value: str) -> str:
    if not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
        r"(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})",
        value,
    ):
        raise ValueError("timestamp_required")
    # fromisoformat 也会归一化 +08:60，须在解析前拒绝原始偏移溢出。
    if value[-1] != "Z" and (int(value[-5:-3]) >= 24 or int(value[-2:]) >= 60):
        raise ValueError("timestamp_required")
    try:
        parsed = datetime.fromisoformat(value)
        original = tuple(
            int(value[start:end])
            for start, end in (
                (0, 4),
                (5, 7),
                (8, 10),
                (11, 13),
                (14, 16),
                (17, 19),
            )
        )
        if parsed.tzinfo is None or original != (
            parsed.year,
            parsed.month,
            parsed.day,
            parsed.hour,
            parsed.minute,
            parsed.second,
        ):
            raise ValueError("timestamp_required")
    except ValueError:
        raise ValueError("timestamp_required") from None
    return value


NonemptyText = Annotated[str, AfterValidator(_nonempty)]
HttpUrl = Annotated[str, AfterValidator(_url)]
Timestamp = Annotated[str, AfterValidator(_timestamp)]


class _CanonicalModel(BaseModel):
    # 与 AI 投影不同：不删除扩展、不 trim、不接受类型转换。
    model_config = ConfigDict(extra="allow", strict=True, hide_input_in_errors=True)


class _Date(_CanonicalModel):
    year: int = Field(ge=1900, le=2200)
    month: int | None = Field(default=None, ge=1, le=12)

    def order(self) -> tuple[int, int]:
        # 与 ResumeDate.compareTo 相同：未知月份用于比较时取一月，保存不补月。
        return self.year, self.month or 1


class _DateRange(_CanonicalModel):
    start: _Date
    end: _Date | None = None
    isCurrent: bool

    @model_validator(mode="after")
    def checkRange(self) -> _DateRange:
        if (self.isCurrent and self.end is not None) or (
            self.end is not None and self.end.order() < self.start.order()
        ):
            raise ValueError("invalid_date_range")
        return self


class _Entity(_CanonicalModel):
    id: NonemptyText


class _Link(_Entity):
    label: NonemptyText
    url: HttpUrl


class _Profile(_Entity):
    fullName: str
    headline: str
    email: str
    phone: str
    location: str
    links: list[_Link]

    @model_validator(mode="after")
    def checkEmail(self) -> _Profile:
        if self.email and not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", self.email):
            raise ValueError("invalid_email")
        return self


class _Work(_Entity):
    organization: NonemptyText
    position: NonemptyText
    dateRange: _DateRange
    summary: str
    highlights: list[str]


class _Education(_Entity):
    institution: NonemptyText
    degree: str
    fieldOfStudy: str
    dateRange: _DateRange
    highlights: list[str]


class _Project(_Entity):
    name: NonemptyText
    role: str
    dateRange: _DateRange | None = None
    summary: str
    highlights: list[str]
    links: list[_Link]


class _Skills(_Entity):
    name: NonemptyText
    skills: list[NonemptyText]


class _Certification(_Entity):
    name: NonemptyText
    issuer: str
    issuedOn: _Date | None = None
    expiresOn: _Date | None = None
    credentialId: str
    credentialUrl: HttpUrl

    @model_validator(mode="after")
    def checkExpiry(self) -> _Certification:
        if (
            self.issuedOn is not None
            and self.expiresOn is not None
            and (self.expiresOn.order() < self.issuedOn.order())
        ):
            raise ValueError("invalid_certificate_dates")
        return self


class _Language(_Entity):
    name: NonemptyText
    proficiency: Literal["native", "fluent", "professional", "intermediate", "basic", "unspecified"]


class _CustomItem(_Entity):
    title: NonemptyText
    description: str


class _CustomSection(_Entity):
    title: NonemptyText
    items: list[_CustomItem]


class _Content(_CanonicalModel):
    schemaVersion: Literal["0.1.0"]
    profile: _Profile
    workExperiences: list[_Work]
    educations: list[_Education]
    projects: list[_Project]
    skillGroups: list[_Skills]
    certifications: list[_Certification]
    languages: list[_Language]
    customSections: list[_CustomSection]
    unmapped: dict[str, Any]


class _Document(_Entity):
    title: NonemptyText
    currentVersionId: str | None = None
    createdAt: Timestamp
    updatedAt: Timestamp
    metadata: dict[str, Any]


class _Version(_Entity):
    documentId: NonemptyText
    parentVersionId: NonemptyText | None = None
    schemaVersion: Literal["0.1.0"]
    content: _Content
    source: Literal["created", "edited", "imported", "aiConfirmed", "restored", "migrated"]
    createdAt: Timestamp


class _Snapshot(_CanonicalModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)
    document: _Document
    version: _Version


def _uniqueKeys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise CanonicalSnapshotError()
        result[key] = value
    return result


def _rejectConstant(value: str) -> None:
    del value
    raise CanonicalSnapshotError()


def _losslessFloat(token: str) -> float:
    value = float(token)
    try:
        # 不把过小数变成 0，也不把高精度扩展值悄悄截成另一个 JSON 数。
        if not math.isfinite(value) or Decimal(token) != Decimal(str(value)):
            raise CanonicalSnapshotError("json_number")
    except DecimalException:
        raise CanonicalSnapshotError("json_number") from None
    return value


def _checkJsonBounds(value: object) -> None:
    stack = [(value, 0)]
    visited = 0
    while stack:
        item, depth = stack.pop()
        visited += 1
        if depth > MAXIMUM_JSON_DEPTH or visited > MAXIMUM_JSON_NODES:
            raise CanonicalSnapshotError("json_bounds")
        if isinstance(item, dict):
            # 键也占节点；不能用很多空容器/短键绕过预算。
            visited += len(item)
            for key, child in item.items():
                key.encode("utf-8")
                stack.append((child, depth + 1))
        elif isinstance(item, list):
            stack.extend((child, depth + 1) for child in item)
        elif isinstance(item, str):
            item.encode("utf-8")
        elif type(item) is int and not -(2**63) <= item < 2**63:
            # Dart Android 的整数边界；不能把未知大整数静默转成有损 float。
            raise CanonicalSnapshotError("json_number")
        elif isinstance(item, float) and not math.isfinite(item):
            raise CanonicalSnapshotError("json_number")
    if visited > MAXIMUM_JSON_NODES:
        raise CanonicalSnapshotError("json_bounds")


def _checkIdentities(snapshot: _Snapshot) -> None:
    document, version = snapshot.document, snapshot.version
    if datetime.fromisoformat(document.updatedAt) < datetime.fromisoformat(document.createdAt):
        raise CanonicalSnapshotError("document_time_order", "/document/updatedAt")
    if (
        document.id != version.documentId
        or document.currentVersionId != version.id
        or (version.parentVersionId == version.id)
    ):
        raise CanonicalSnapshotError("snapshot_identity")
    content = version.content
    entities: list[tuple[_Entity, str]] = [(content.profile, "/version/content/profile/id")]
    entities.extend(
        (link, f"/version/content/profile/links/{index}/id")
        for index, link in enumerate(content.profile.links)
    )
    for fieldName in (
        "workExperiences",
        "educations",
        "projects",
        "skillGroups",
        "certifications",
        "languages",
        "customSections",
    ):
        values: list[_Entity] = getattr(content, fieldName)
        for index, entity in enumerate(values):
            path = f"/version/content/{fieldName}/{index}"
            entities.append((entity, path + "/id"))
            if isinstance(entity, _Project):
                entities.extend(
                    (link, f"{path}/links/{i}/id") for i, link in enumerate(entity.links)
                )
            elif isinstance(entity, _CustomSection):
                entities.extend(
                    (item, f"{path}/items/{i}/id") for i, item in enumerate(entity.items)
                )
    identities: set[str] = set()
    for entity, path in entities:
        if entity.id in identities:
            raise CanonicalSnapshotError("stable_id_unique", path)
        identities.add(entity.id)


@dataclass(frozen=True, slots=True)
class CanonicalSnapshot:
    payload: bytes = field(repr=False)
    documentId: str = field(init=False, repr=False)
    versionId: str = field(init=False, repr=False)
    parentVersionId: str | None = field(init=False, repr=False)
    schemaVersion: str = field(init=False, repr=False)
    fingerprint: str = field(init=False, repr=False)

    def __post_init__(self) -> None:
        if type(self.payload) is not bytes or not 0 < len(self.payload) <= MAXIMUM_SNAPSHOT_BYTES:
            raise CanonicalSnapshotError("snapshot_bytes")
        try:
            value = json.loads(
                self.payload.decode("utf-8"),
                object_pairs_hook=_uniqueKeys,
                parse_constant=_rejectConstant,
                parse_float=_losslessFloat,
            )
            _checkJsonBounds(value)
            if not isinstance(value, dict) or set(value) != {"document", "version"}:
                raise CanonicalSnapshotError()
            checked = _Snapshot.model_validate(value)
            _checkIdentities(checked)
            # 保存原值，不序列化校验模型：不能补默认字段、重写时间或丢扩展。
            canonical = json.dumps(
                value,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
            if len(canonical) > MAXIMUM_SNAPSHOT_BYTES:
                raise CanonicalSnapshotError("snapshot_bytes")
        except ValidationError as error:
            # 只取已知字段/数组索引，不传 input、ctx 或原消息。额外的客户端字段
            # 可含个人值，容器层额外字段错误也不能把该字段名返回出去。
            first = error.errors(include_url=False, include_context=False, include_input=False)[0]
            path = (
                "$"
                if first["type"] == "extra_forbidden"
                else "/" + "/".join(str(part) for part in first["loc"])
            )
            raise CanonicalSnapshotError("invalid_shape", path) from None
        except CanonicalSnapshotError:
            raise
        except ValueError, UnicodeError, RecursionError:
            raise CanonicalSnapshotError() from None
        object.__setattr__(self, "payload", canonical)
        object.__setattr__(self, "documentId", checked.document.id)
        object.__setattr__(self, "versionId", checked.version.id)
        object.__setattr__(self, "parentVersionId", checked.version.parentVersionId)
        object.__setattr__(self, "schemaVersion", checked.version.schemaVersion)
        object.__setattr__(self, "fingerprint", hashlib.sha256(canonical).hexdigest())

    def toJson(self) -> dict[str, Any]:
        # 每次读取给出独立对象；外部修改不会改变待提交的不可变字节。
        return cast(dict[str, Any], json.loads(self.payload))
