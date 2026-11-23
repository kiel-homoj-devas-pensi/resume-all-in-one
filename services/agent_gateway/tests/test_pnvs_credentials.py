from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from agent_gateway import pnvs_credentials as loader
from agent_gateway import windows_protected_configuration as protected

_SYNTHETIC_ID = "SYNTHETIC_PNVS_ID_ONLY_20261010"
_SYNTHETIC_SECRET = "SYNTHETIC_PNVS_SECRET_ONLY_20261010"


def _bundle() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "ALIBABA_CLOUD_ACCESS_KEY_ID": _SYNTHETIC_ID,
        "ALIBABA_CLOUD_ACCESS_KEY_SECRET": _SYNTHETIC_SECRET,
        "PNVS_SIGN_NAME": "恒创联众",
        "PNVS_TEMPLATE_CODE": "100001",
        "PNVS_CODE_VARIABLE": "code",
        "PNVS_MINUTES_VARIABLE": "min",
    }


def test_python_loads_existing_powershell_format_without_disclosing_keys(
    encryptedFiles: Path, capfd: pytest.CaptureFixture[str]
) -> None:
    path = encryptedFiles / "synthetic.dpapi"
    original = path.read_bytes()
    credentials = loader.loadPnvsCredentials(path)
    assert credentials.accessKeyId == _SYNTHETIC_ID
    assert credentials.accessKeySecret == _SYNTHETIC_SECRET
    assert credentials.signName == "恒创联众"
    assert credentials.templateCode == "100001"
    assert _SYNTHETIC_ID not in repr(credentials)
    assert _SYNTHETIC_SECRET not in repr(credentials)
    assert capfd.readouterr() == ("", "")
    assert path.read_bytes() == original


@pytest.mark.parametrize("filename", ["corrupt.dpapi", "invalid-json.dpapi", "inherited-acl.dpapi"])
def test_rejects_invalid_or_publicly_readable_file_without_content(
    encryptedFiles: Path, filename: str, capfd: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(loader.PnvsCredentialLoadError) as failure:
        loader.loadPnvsCredentials(encryptedFiles / filename)
    assert str(failure.value) == "pnvs_credentials_unavailable"
    assert failure.value.__suppress_context__
    assert capfd.readouterr() == ("", "")


def test_checked_file_cannot_be_replaced_or_written_until_handle_closes(
    encryptedFiles: Path,
) -> None:
    path = encryptedFiles / "synthetic.dpapi"
    original = path.read_bytes()
    with protected._lockedFile(path):
        with pytest.raises(PermissionError):
            path.write_bytes(b"replacement")
        with pytest.raises(PermissionError):
            path.rename(path.with_suffix(".moved"))
        # ACL 验证仍能打开同一文件的只读句柄。
        protected._verifyProtectedFile(path, "pnvsCredentials")
    assert path.read_bytes() == original


@pytest.mark.parametrize(
    "path",
    ["relative.dpapi", r"\\server\share\pnvs.dpapi", "D:relative.dpapi", "D:/fake.dpapi:stream"],
)
def test_rejects_relative_network_or_alternate_stream_paths_before_open(path: str) -> None:
    with pytest.raises(loader.PnvsCredentialLoadError):
        loader.loadPnvsCredentials(path)


def test_rejects_repository_file_before_permission_or_dpapi_check() -> None:
    with pytest.raises(loader.PnvsCredentialLoadError):
        loader.loadPnvsCredentials(Path(__file__).resolve())


def test_non_windows_platform_never_reads_file(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(os, "name", "posix")
    with pytest.raises(loader.PnvsCredentialLoadError):
        loader.loadPnvsCredentials("D:/synthetic.dpapi")


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("schemaVersion", True),
        ("schemaVersion", 2),
        ("PNVS_CODE_VARIABLE", "other"),
        ("PNVS_MINUTES_VARIABLE", "other"),
        ("PNVS_SIGN_NAME", "unapproved"),
        ("PNVS_TEMPLATE_CODE", "100003"),
        ("ALIBABA_CLOUD_ACCESS_KEY_ID", 123),
        ("ALIBABA_CLOUD_ACCESS_KEY_SECRET", "synthetic invalid key"),
        ("ALIBABA_CLOUD_ACCESS_KEY_SECRET", "x" * 257),
    ],
)
def test_schema_or_unapproved_template_cannot_be_loaded(name: str, value: object) -> None:
    bundle = _bundle()
    bundle[name] = value
    with pytest.raises((loader.PnvsCredentialLoadError, ValueError)):
        loader._credentials(json.dumps(bundle))


def test_duplicate_unknown_or_missing_fields_are_rejected() -> None:
    bundle = _bundle()
    invalid = [
        (json.dumps(bundle)[:-1] + ',"schemaVersion":1}', protected.ProtectedConfigurationError),
        (json.dumps({**bundle, "extra": "unexpected"}), loader.PnvsCredentialLoadError),
        (
            json.dumps({key: value for key, value in bundle.items() if key != "schemaVersion"}),
            loader.PnvsCredentialLoadError,
        ),
        ("[]", protected.ProtectedConfigurationError),
    ]
    for payload, error in invalid:
        with pytest.raises(error):
            loader._credentials(payload)


def test_native_decryption_rejects_changed_dpapi_blob_without_raw_error(
    encryptedFiles: Path,
) -> None:
    ciphertext = (encryptedFiles / "synthetic.dpapi").read_bytes()
    altered = bytearray.fromhex(ciphertext.decode("ascii"))
    altered[-1] ^= 1
    with pytest.raises(protected.ProtectedConfigurationError) as failure:
        protected._unprotect(altered.hex().encode("ascii"))
    assert str(failure.value) == "protected_configuration_unavailable"


@pytest.mark.parametrize(
    "ciphertext", [b"", b"xyz", b"a", b"00" * 32_769], ids=["empty", "non-hex", "odd", "oversize"]
)
def test_native_decryption_rejects_invalid_encoding_before_windows_call(ciphertext: bytes) -> None:
    with pytest.raises(protected.ProtectedConfigurationError):
        protected._unprotect(ciphertext)


def test_dependency_failure_is_redacted_even_when_exception_contains_secret(
    monkeypatch: pytest.MonkeyPatch, encryptedFiles: Path, capfd: pytest.CaptureFixture[str]
) -> None:
    def fail(path: Path, kind: protected.ProtectionKind) -> None:
        raise RuntimeError(_SYNTHETIC_SECRET)

    monkeypatch.setattr(protected, "_verifyProtectedFile", fail)
    with pytest.raises(loader.PnvsCredentialLoadError) as failure:
        loader.loadPnvsCredentials(encryptedFiles / "synthetic.dpapi")
    assert str(failure.value) == "pnvs_credentials_unavailable"
    assert failure.value.__cause__ is None
    assert failure.value.__suppress_context__
    assert capfd.readouterr() == ("", "")
    # 失败也必须关闭文件句柄；不通过写入来破坏后续 fixture。
    path = encryptedFiles / "synthetic.dpapi"
    moved = path.with_suffix(".moved")
    path.rename(moved)
    moved.rename(path)
