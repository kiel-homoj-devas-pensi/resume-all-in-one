from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest

from agent_gateway import cloud_runtime as runtime
from agent_gateway.windows_protected_configuration import ProtectionKind


def bundle() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "syntheticOnly": True,
        "policyVersion": "synthetic-v1",
        "region": "local-synthetic",
        "contentRetentionDays": 0,
        "backupRetentionDays": 0,
        "resourceIdentity": "synthetic-database",
        "cursorSecretBase64": base64.b64encode(b"c" * 32).decode(),
    }


def test_实际DPAPI跨加载保留同一秘密且输出无秘密(
    cloudRuntimeFiles: Path, capfd: pytest.CaptureFixture[str]
) -> None:
    path = cloudRuntimeFiles / "runtime.dpapi"
    original = path.read_bytes()
    first = runtime.loadCloudRuntimeSettings(path)
    second = runtime.loadCloudRuntimeSettings(path)
    assert len(first.cursorSecret) == 32 and first.cursorSecret == second.cursorSecret
    assert first.policy == second.policy and first.policy.policyVersion == "synthetic-v1"
    assert original == path.read_bytes()
    encoded = base64.b64encode(first.cursorSecret).decode()
    output = capfd.readouterr()
    assert encoded not in output.out + output.err + repr(first)


@pytest.mark.parametrize(
    "filename",
    ["inherited-acl", "boolean", "extra-field", "short-secret", "not-synthetic", "duplicate-field"],
)
def test_实际加密不合法字段或权限拒绝且错误脱敏(cloudRuntimeFiles: Path, filename: str) -> None:
    with pytest.raises(runtime.CloudRuntimeLoadError) as failure:
        runtime.loadCloudRuntimeSettings(cloudRuntimeFiles / (filename + ".dpapi"))
    assert str(failure.value) == "cloud_runtime_configuration_unavailable"
    assert failure.value.__cause__ is None and failure.value.__suppress_context__


@pytest.mark.parametrize(
    "field,value",
    [
        ("schemaVersion", True),
        ("schemaVersion", 2),
        ("syntheticOnly", 1),
        ("syntheticOnly", False),
        ("policyVersion", "PRIVATE_VALUE\n"),
        ("region", ""),
        ("resourceIdentity", "x" * 65),
        ("contentRetentionDays", True),
        ("contentRetentionDays", -1),
        ("backupRetentionDays", 3651),
        ("backupRetentionDays", 1.0),
        ("cursorSecretBase64", "PRIVATE_SECRET"),
        ("cursorSecretBase64", base64.b64encode(b"c" * 31).decode()),
        ("region", None),
    ],
)
def test_明确类型政策和秘密字段损坏不返回原输入(
    monkeypatch: pytest.MonkeyPatch, field: str, value: object
) -> None:
    data = bundle()
    data[field] = value

    def payload(path: str | Path, *, kind: ProtectionKind) -> str:
        assert kind == "cloudRuntime"
        return json.dumps(data)

    monkeypatch.setattr(runtime, "loadProtectedPayload", payload)
    with pytest.raises(runtime.CloudRuntimeLoadError) as failure:
        runtime.loadCloudRuntimeSettings("D:/synthetic-only.dpapi")
    assert "PRIVATE" not in str(failure.value) and failure.value.__suppress_context__


@pytest.mark.parametrize("kind", ["duplicate", "missing", "extra", "array"])
def test_配置对象边界不能默默接受重复或额外字段(monkeypatch: pytest.MonkeyPatch, kind: str) -> None:
    data = bundle()
    if kind == "missing":
        del data["region"]
    if kind == "extra":
        data["PRIVATE_FIELD"] = "PRIVATE_VALUE"
    serialized = json.dumps(data)
    if kind == "duplicate":
        serialized = serialized.replace('"schemaVersion": 1', '"schemaVersion":1,"schemaVersion":1')
    if kind == "array":
        serialized = "[" + serialized + "]"

    def payload(path: str | Path, *, kind: ProtectionKind) -> str:
        return serialized

    monkeypatch.setattr(runtime, "loadProtectedPayload", payload)
    with pytest.raises(runtime.CloudRuntimeLoadError):
        runtime.loadCloudRuntimeSettings("D:/synthetic-only.dpapi")
