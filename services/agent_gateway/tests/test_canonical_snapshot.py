from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

import pytest

from agent_gateway.canonical_snapshot import CanonicalSnapshot, CanonicalSnapshotError


@pytest.fixture
def snapshot() -> dict[str, Any]:
    repository = Path(__file__).resolve().parents[3]
    content = json.loads(
        (repository / "packages/resume_domain/test/fixtures/resume_v0_1.json").read_text(
            encoding="utf-8"
        )
    )
    return {
        "document": {
            "id": "document-synthetic",
            "title": " 合成快照 ",
            "currentVersionId": "version-synthetic",
            "createdAt": "2026-10-11T09:00:00+08:00",
            "updatedAt": "2026-10-11T01:00:00Z",
            "metadata": {"nested": [None, True, 1, 1.25, "保留"]},
            "futureDocument": {"values": [1, "  原样  "]},
        },
        "version": {
            "id": "version-synthetic",
            "documentId": "document-synthetic",
            "parentVersionId": None,
            "schemaVersion": "0.1.0",
            "source": "created",
            "createdAt": "2026-10-11T01:00:00.123456Z",
            "content": content,
            "futureVersion": {"nonEntityId": "profile-001"},
        },
    }


def encoded(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False).encode("utf-8")


def test_existing_dart_fixture_and_all_extensions_round_trip_without_mutation(
    snapshot: dict[str, Any],
) -> None:
    original = copy.deepcopy(snapshot)
    checked = CanonicalSnapshot(encoded(snapshot))
    assert checked.toJson() == original
    assert checked.documentId == "document-synthetic"
    assert checked.versionId == "version-synthetic"
    assert checked.parentVersionId is None
    assert checked.schemaVersion == "0.1.0"
    assert repr(checked) == "CanonicalSnapshot()"
    snapshot["version"]["content"]["profile"]["fullName"] = "later mutable value"
    loaded = checked.toJson()
    loaded["document"]["metadata"]["nested"].append("mutable return")
    assert checked.toJson() == original


def test_key_order_and_whitespace_do_not_change_fingerprint(snapshot: dict[str, Any]) -> None:
    first = CanonicalSnapshot(encoded(snapshot))
    second = CanonicalSnapshot(json.dumps(snapshot, sort_keys=True, indent=4).encode("utf-8"))
    assert first.payload == second.payload and first.fingerprint == second.fingerprint
    snapshot["document"]["title"] = "合成快照"
    assert CanonicalSnapshot(encoded(snapshot)).fingerprint != first.fingerprint


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("version", "content", "profile", "id"), " "),
        (("version", "content", "profile", "email"), "private-invalid-email"),
        (("version", "content", "workExperiences", 0, "id"), "profile-001"),
        (("version", "content", "projects", 0, "links", 0, "id"), "link-profile-001"),
        (("version", "content", "customSections", 0, "items", 0, "id"), "work-001"),
        (("version", "content", "workExperiences", 0, "organization"), " "),
        (("version", "content", "workExperiences", 0, "position"), ""),
        (("version", "content", "educations", 0, "institution"), ""),
        (("version", "content", "projects", 0, "name"), ""),
        (("version", "content", "skillGroups", 0, "name"), ""),
        (("version", "content", "skillGroups", 0, "skills", 0), " "),
        (("version", "content", "certifications", 0, "name"), ""),
        (("version", "content", "languages", 0, "name"), ""),
        (("version", "content", "languages", 0, "proficiency"), "unknown"),
        (("version", "content", "customSections", 0, "title"), ""),
        (("version", "content", "customSections", 0, "items", 0, "title"), ""),
        (("version", "content", "profile", "links", 0, "label"), ""),
        (("version", "content", "profile", "links", 0, "url"), "file:///private"),
        (("version", "content", "certifications", 0, "credentialUrl"), "relative/path"),
        (("version", "content", "workExperiences", 0, "dateRange", "start", "year"), True),
        (("version", "content", "workExperiences", 0, "dateRange", "start", "month"), 6.0),
        (("version", "content", "workExperiences", 0, "dateRange", "start", "year"), 1899),
        (("version", "content", "workExperiences", 0, "dateRange", "start", "month"), 13),
        (("version", "content", "workExperiences", 0, "dateRange", "isCurrent"), 1),
        (("version", "content", "workExperiences", 0, "dateRange", "end"), {"year": 2024}),
        (("version", "content", "educations", 0, "dateRange", "end"), {"year": 2017}),
        (("version", "content", "certifications", 0, "expiresOn"), {"year": 2023}),
        (("version", "content", "schemaVersion"), "9.9.9"),
        (("version", "schemaVersion"), "9.9.9"),
        (("version", "source"), "unconfirmedAi"),
        (("version", "documentId"), "another-document"),
        (("document", "currentVersionId"), "another-version"),
        (("document", "createdAt"), "2026-02-31T00:00:00Z"),
        (("version", "createdAt"), "2026-10-11T01:00:00"),
        (("document", "id"), ""),
        (("version", "parentVersionId"), "version-synthetic"),
    ],
    ids=[str(index) for index in range(36)],
)
def test_invalid_content_and_identity_never_produce_a_snapshot(
    snapshot: dict[str, Any], path: tuple[str | int, ...], value: object
) -> None:
    current: Any = snapshot
    for part in path[:-1]:
        current = current[part]
    current[path[-1]] = value
    with pytest.raises(CanonicalSnapshotError) as failure:
        CanonicalSnapshot(encoded(snapshot))
    assert str(failure.value) == "canonical_snapshot_invalid"
    assert "private" not in repr(failure.value)
    assert failure.value.__cause__ is None


def test_year_precision_is_preserved_and_missing_month_compares_as_january(
    snapshot: dict[str, Any],
) -> None:
    period = snapshot["version"]["content"]["educations"][0]["dateRange"]
    period["start"] = {"year": 2022, "month": 6}
    period["end"] = {"year": 2022}
    with pytest.raises(CanonicalSnapshotError):
        CanonicalSnapshot(encoded(snapshot))
    period["start"] = {"year": 2022}
    checked = CanonicalSnapshot(encoded(snapshot)).toJson()
    assert checked["version"]["content"]["educations"][0]["dateRange"]["start"] == {"year": 2022}


@pytest.mark.parametrize(
    "payload",
    [
        b'{"document":{},"document":{},"version":{}}',
        b'{"unknown":{"private-key":1,"private-key":2}}',
        b'{"document":NaN}',
        b'{"document":Infinity}',
        b'{"document":1e999}',
        b"[]",
        b"{}",
        b"\xff",
        b"\xef\xbb\xbf{}",
        b"{} {}",
        b" " * 49_153,
        b"[" * 1200 + b"0" + b"]" * 1200,
    ],
    ids=[
        "duplicate-root",
        "duplicate-nested",
        "nan",
        "infinity",
        "overflow",
        "array",
        "missing",
        "utf8",
        "bom",
        "multiple",
        "bytes-limit",
        "deep",
    ],
)
def test_malformed_or_unbounded_json_fails_with_fixed_error(payload: bytes) -> None:
    with pytest.raises(CanonicalSnapshotError) as failure:
        CanonicalSnapshot(payload)
    assert failure.value.path == "$"
    assert failure.value.__cause__ is None


def test_unknown_fields_have_the_same_json_depth_node_and_number_limits(
    snapshot: dict[str, Any],
) -> None:
    for value in (float("inf"), "\ud800", 2**63):
        snapshot["version"]["content"]["futureRootField"] = value
        with pytest.raises(CanonicalSnapshotError):
            CanonicalSnapshot(json.dumps(snapshot).encode("ascii"))
    nested: object = "private-content"
    for _ in range(34):
        nested = {"private-user-key": nested}
    snapshot["version"]["content"]["futureRootField"] = nested
    with pytest.raises(CanonicalSnapshotError) as failure:
        CanonicalSnapshot(encoded(snapshot))
    assert failure.value.path == "$"
    snapshot["version"]["content"]["futureRootField"] = [None] * 8200
    with pytest.raises(CanonicalSnapshotError):
        CanonicalSnapshot(encoded(snapshot))


def test_blank_optional_fields_and_unknown_id_values_are_retained(snapshot: dict[str, Any]) -> None:
    content = snapshot["version"]["content"]
    content["profile"]["fullName"] = ""
    content["profile"]["email"] = ""
    content["profile"]["links"][0]["url"] = ""
    content["profile"]["futureProfileField"] = {"id": "profile-001"}
    assert CanonicalSnapshot(encoded(snapshot)).toJson() == snapshot


def test_shared_dart_gateway_cases_match_and_preserve_valid_values(
    snapshot: dict[str, Any],
) -> None:
    repository = Path(__file__).resolve().parents[3]
    cases = json.loads(
        (
            repository / "packages/resume_domain/test/fixtures/cloud_content_cases_v0_1.json"
        ).read_text(encoding="utf-8")
    )
    for scenario in cases:
        changed = copy.deepcopy(snapshot)
        container = changed["version"]["content"]
        for part in scenario["path"][:-1]:
            container = container[part]
        container[scenario["path"][-1]] = scenario["value"]
        if scenario["accepted"]:
            assert CanonicalSnapshot(encoded(changed)).toJson() == changed
        else:
            with pytest.raises(CanonicalSnapshotError):
                CanonicalSnapshot(encoded(changed))


def test_duplicate_entity_error_keeps_safe_rule_and_known_path(snapshot: dict[str, Any]) -> None:
    snapshot["version"]["content"]["workExperiences"][0]["id"] = "profile-001"
    with pytest.raises(CanonicalSnapshotError) as failure:
        CanonicalSnapshot(encoded(snapshot))
    assert failure.value.code == "stable_id_unique"
    assert failure.value.path == "/version/content/workExperiences/0/id"


def test_document_write_constraints_match_local_repository(snapshot: dict[str, Any]) -> None:
    snapshot["document"]["title"] = " "
    with pytest.raises(CanonicalSnapshotError):
        CanonicalSnapshot(encoded(snapshot))
    snapshot["document"]["title"] = "保留时间"
    snapshot["document"]["updatedAt"] = "2026-10-11T00:59:59.999999Z"
    with pytest.raises(CanonicalSnapshotError) as failure:
        CanonicalSnapshot(encoded(snapshot))
    assert failure.value.code == "document_time_order"
    snapshot["document"]["updatedAt"] = "2026-10-11T01:00:00Z"
    assert CanonicalSnapshot(encoded(snapshot)).toJson() == snapshot


def test_shared_timestamp_cases_reject_normalized_overflow(snapshot: dict[str, Any]) -> None:
    repository = Path(__file__).resolve().parents[3]
    cases = json.loads(
        (
            repository / "packages/resume_domain/test/fixtures/cloud_timestamp_cases_v0_1.json"
        ).read_text(encoding="utf-8")
    )
    for scenario in cases:
        changed = copy.deepcopy(snapshot)
        for field in ("createdAt", "updatedAt"):
            changed["document"][field] = scenario["value"]
        changed["version"]["createdAt"] = scenario["value"]
        if scenario["accepted"]:
            assert CanonicalSnapshot(encoded(changed)).toJson() == changed
        else:
            with pytest.raises(CanonicalSnapshotError):
                CanonicalSnapshot(encoded(changed))


@pytest.mark.parametrize("number", ["1e-999", "1.234567890123456789", "1e999", "1e" + "9" * 100])
def test_unknown_numbers_that_cannot_round_trip_are_rejected(
    snapshot: dict[str, Any], number: str
) -> None:
    snapshot["document"]["metadata"]["number"] = "replace-number-token"
    payload = encoded(snapshot).replace(b'"replace-number-token"', number.encode("ascii"))
    with pytest.raises(CanonicalSnapshotError) as failure:
        CanonicalSnapshot(payload)
    assert failure.value.code == "json_number"
    assert failure.value.path == "$"


def test_exact_boundary_limits_and_signed_integers_are_preserved(snapshot: dict[str, Any]) -> None:
    snapshot["document"]["metadata"] = {"minimum": -(2**63), "maximum": 2**63 - 1, "zero": -0.0}
    assert CanonicalSnapshot(encoded(snapshot)).toJson() == snapshot
    base = CanonicalSnapshot(encoded(snapshot)).payload
    accepted = CanonicalSnapshot(base + b" " * (49_152 - len(base)))
    assert accepted.payload == base
    with pytest.raises(CanonicalSnapshotError):
        CanonicalSnapshot(base + b" " * (49_153 - len(base)))
