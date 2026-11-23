from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest

from agent_gateway import pnvs_runtime as runtime
from agent_gateway.windows_protected_configuration import ProtectionKind


def bundle() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "otpSecretBase64": base64.b64encode(b"o" * 32).decode("ascii"),
        "auditSecretBase64": base64.b64encode(b"a" * 32).decode("ascii"),
        "allowedPhones": ["+8613800000000"],
        "maximumAttempts": 2,
        "budgetCents": 12,
        "reservePerAttemptCents": 6,
        "expiresAtUtc": "2099-01-01T00:00:00.000000Z",
    }


def test_native_runtime_round_trip_keeps_independent_secrets_and_file_unchanged(
    pnvsRuntimeFiles: Path, capfd: pytest.CaptureFixture[str]
) -> None:
    path = pnvsRuntimeFiles / "runtime.dpapi"
    original = path.read_bytes()
    first = runtime.loadPnvsRuntimeSettings(path)
    second = runtime.loadPnvsRuntimeSettings(path)
    matching = first.otpSecret == second.otpSecret and first.auditSecret == second.auditSecret
    independent = first.otpSecret != first.auditSecret
    assert matching and independent
    assert first.policy.maximumAttempts == 2
    assert first.policy.budgetCents == 12
    assert first.policy.allowedPhones == frozenset({"+8613800000000"})
    representation = repr(first)
    assert "otpSecret" not in representation and "+8613800000000" not in representation
    assert capfd.readouterr() == ("", "")
    assert path.read_bytes() == original


@pytest.mark.parametrize(
    "filename", ["inherited-acl.dpapi", "same-secret.dpapi", "boolean.dpapi", "extra-field.dpapi"]
)
def test_runtime_rejects_wrong_permissions_and_encrypted_invalid_settings(
    pnvsRuntimeFiles: Path, filename: str, capfd: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(runtime.PnvsRuntimeLoadError) as failure:
        runtime.loadPnvsRuntimeSettings(pnvsRuntimeFiles / filename)
    assert str(failure.value) == "pnvs_runtime_configuration_unavailable"
    assert failure.value.__suppress_context__
    assert capfd.readouterr() == ("", "")


@pytest.mark.parametrize(
    ("name", "value"),
    [
        pytest.param("schemaVersion", True, id="boolean-version"),
        pytest.param("maximumAttempts", True, id="boolean-count"),
        pytest.param("budgetCents", 1.2, id="float-money"),
        pytest.param("reservePerAttemptCents", 5, id="below-price"),
        pytest.param("maximumAttempts", 0, id="zero-count"),
        pytest.param("allowedPhones", ["+15550000001"], id="foreign-number"),
        pytest.param("allowedPhones", ["+8613800000000"] * 2, id="duplicate-number"),
        pytest.param("allowedPhones", "+8613800000000", id="not-list"),
        pytest.param("expiresAtUtc", "2099-01-01T00:00:00+08:00", id="non-utc"),
        pytest.param("expiresAtUtc", "2099-02-30T00:00:00.000000Z", id="invalid-date"),
        pytest.param("otpSecretBase64", "bad-base64", id="bad-encoding"),
        pytest.param("otpSecretBase64", "b29vbw==", id="short-secret"),
    ],
)
def test_runtime_schema_failure_is_redacted(
    monkeypatch: pytest.MonkeyPatch, name: str, value: object
) -> None:
    invalid = bundle()
    invalid[name] = value

    def payload(path: str | Path, *, kind: ProtectionKind) -> str:
        assert kind == "pnvsRuntime"
        return json.dumps(invalid)

    monkeypatch.setattr(runtime, "loadProtectedPayload", payload)
    with pytest.raises(runtime.PnvsRuntimeLoadError) as failure:
        runtime.loadPnvsRuntimeSettings("D:/synthetic-runtime.dpapi")
    assert str(failure.value) == "pnvs_runtime_configuration_unavailable"
    assert failure.value.__suppress_context__


def test_runtime_rejects_duplicate_missing_extra_fields_or_reused_secret(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    original = bundle()
    values = [
        json.dumps(original)[:-1] + ',"schemaVersion":1}',
        json.dumps({**original, "extra": "unexpected"}),
        json.dumps({key: value for key, value in original.items() if key != "budgetCents"}),
        json.dumps({**original, "auditSecretBase64": original["otpSecretBase64"]}),
    ]
    for value in values:

        def payload(path: str | Path, *, kind: ProtectionKind, captured: str = value) -> str:
            return captured

        monkeypatch.setattr(runtime, "loadProtectedPayload", payload)
        with pytest.raises(runtime.PnvsRuntimeLoadError):
            runtime.loadPnvsRuntimeSettings("D:/synthetic-runtime.dpapi")
