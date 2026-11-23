from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest
import uvicorn
from fastapi import FastAPI

from agent_gateway import protected_startup as startup
from agent_gateway.settings import GatewaySettings

_KEY = "SYNTHETIC_MODEL_KEY_NO_NETWORK_20261013"
_DSN = "mysql://synthetic_business:synthetic_password@localhost:18029/synthetic_accounts"


def _bundle(folder: Path) -> dict[str, object]:
    for name in ("ca.pem", "pnvs.dpapi", "runtime.dpapi"):
        (folder / name).write_text("synthetic-test-only")
    return {
        "schemaVersion": 1,
        "glmApiKey": _KEY,
        "businessDatabaseDsn": _DSN,
        "databaseTlsCaFile": str(folder / "ca.pem"),
        "databaseExpiresAtUtc": "2099-01-01T00:00:00Z",
        "pnvsCredentialsPath": str(folder / "pnvs.dpapi"),
        "pnvsRuntimePath": str(folder / "runtime.dpapi"),
    }


def test_assembly_ignores_environment_and_passes_no_secret_arguments(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    bundle = _bundle(tmp_path)
    monkeypatch.setenv("AGENT_GATEWAY_TEST_BEARER_TOKEN", "synthetic-untrusted-token")
    monkeypatch.setenv("AGENT_GATEWAY_REMOTE_PROVIDER_MODE", "fake")
    monkeypatch.setenv("AGENT_GATEWAY_CLOUD_RUNTIME_PATH", "never-use-cloud")
    settings = startup._settingsFromPayload(json.dumps(bundle))
    monkeypatch.setattr(startup, "loadStartupSettings", lambda path: settings)
    application = FastAPI()
    observed: dict[str, object] = {}

    def create(*, settings: GatewaySettings) -> FastAPI:
        observed["settings"] = settings
        return application

    def run(app: FastAPI, **kwargs: object) -> None:
        assert app is application
        observed["run"] = kwargs

    monkeypatch.setattr(startup, "createApplication", create)
    monkeypatch.setattr(uvicorn, "run", run)
    environment = dict(os.environ)
    assert startup.main(["--configuration", str(tmp_path / "startup.dpapi")]) == 0
    assert os.environ == environment
    assert observed["run"] == {
        "host": "127.0.0.1",
        "port": 8000,
        "workers": 1,
        "access_log": False,
        "log_level": "warning",
    }
    assert observed["settings"] is settings
    assert settings.executionEnvironment == "production"
    assert settings.databaseBackend == "mysql" and settings.enableAccountPrivileges
    assert settings.testBearerToken is None and not settings.enableTask018FakeIdentity
    assert settings.cloudRuntimePath is None and settings.task018DatabasePath is None
    assert settings.remoteProviderMode == "glm"
    assert _KEY not in repr(settings) and _DSN not in repr(settings)
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("schemaVersion", True),
        ("schemaVersion", 3),
        ("glmApiKey", "short"),
        ("glmApiKey", _KEY + "\n"),
        ("glmApiKey", "a" * 257),
        ("businessDatabaseDsn", "mysql://root:secret@localhost/accounts?unsafe=true"),
        ("databaseExpiresAtUtc", "2099-01-01T00:00:00"),
        ("databaseTlsCaFile", "relative.pem"),
        ("pnvsRuntimePath", 123),
        ("pnvsCredentialsPath", "relative.dpapi"),
    ],
)
def test_invalid_bundle_rejected_before_service_creation(
    tmp_path: Path, field: str, value: object
) -> None:
    bundle = _bundle(tmp_path)
    bundle[field] = value
    with pytest.raises((startup.ProtectedStartupError, ValueError, RuntimeError)):
        startup._settingsFromPayload(json.dumps(bundle))


@pytest.mark.parametrize("extra", ["managementDatabaseDsn", "testBearerToken", "cloudRuntimePath"])
def test_no_management_or_development_overrides(tmp_path: Path, extra: str) -> None:
    bundle = _bundle(tmp_path)
    bundle[extra] = "unsafe"
    with pytest.raises(startup.ProtectedStartupError):
        startup._settingsFromPayload(json.dumps(bundle))


def test_persistent_startup_and_old_encrypted_bundle_have_no_service_expiry(tmp_path: Path) -> None:
    legacy = _bundle(tmp_path)
    legacy["databaseExpiresAtUtc"] = "2000-01-01T00:00:00Z"
    old_settings = startup._settingsFromPayload(json.dumps(legacy))
    assert old_settings.databaseExpiresAtUtc is None
    current = {key: value for key, value in legacy.items() if key != "databaseExpiresAtUtc"}
    current["schemaVersion"] = 2
    assert startup._settingsFromPayload(json.dumps(current)) == old_settings
    # An accidentally mixed bundle is rejected, rather than guessing its meaning.
    current["databaseExpiresAtUtc"] = "2099-01-01T00:00:00Z"
    with pytest.raises(startup.ProtectedStartupError):
        startup._settingsFromPayload(json.dumps(current))


def test_production_database_ignores_legacy_service_deadline_but_development_is_bounded(
    tmp_path: Path,
) -> None:
    from dataclasses import replace

    from agent_gateway.account_storage import StorageUnavailableError
    from agent_gateway.app import _mySqlConfig

    settings = startup._settingsFromPayload(json.dumps(_bundle(tmp_path)))
    legacy = replace(settings, databaseExpiresAtUtc="2000-01-01T00:00:00Z")
    assert _mySqlConfig(legacy).expiresAtUtc is None
    with pytest.raises(StorageUnavailableError):
        _mySqlConfig(replace(legacy, executionEnvironment="development"))


def test_rejects_duplicate_keys_and_repository_references(tmp_path: Path) -> None:
    bundle = _bundle(tmp_path)
    with pytest.raises(RuntimeError):
        startup._settingsFromPayload(json.dumps(bundle)[:-1] + ',"schemaVersion":1}')
    bundle["databaseTlsCaFile"] = str(Path(__file__).resolve())
    with pytest.raises(startup.ProtectedStartupError):
        startup._settingsFromPayload(json.dumps(bundle))


@pytest.mark.parametrize(
    "path", [r"\\server\share\ca.pem", "//server/share/ca.pem", "D:/ca:stream"]
)
def test_windows_network_and_stream_references_rejected_without_file_access(
    monkeypatch: pytest.MonkeyPatch, path: str
) -> None:
    if os.name != "nt":
        pytest.skip("Windows local drive path syntax")

    def forbidden(self: Path, *, follow_symlinks: bool = True) -> os.stat_result:
        pytest.fail("Invalid reference must be rejected before file access")

    monkeypatch.setattr(Path, "stat", forbidden)
    with pytest.raises(startup.ProtectedStartupError):
        startup._localFile(path)


def test_failed_configuration_cannot_leak_or_start(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def fail(path: Path) -> GatewaySettings:
        raise RuntimeError(_DSN + _KEY)

    monkeypatch.setattr(startup, "loadStartupSettings", fail)
    assert startup.main(["--configuration", "unavailable.dpapi"]) == 1
    stdout, stderr = capsys.readouterr()
    assert stdout == ""
    assert _DSN not in stderr and _KEY not in stderr and "protected_startup_failed" in stderr


def test_unsupported_cli_input_is_not_echoed(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as failure:
        startup.main(["--configuration", "unavailable.dpapi", "--api-key", _KEY])
    assert failure.value.code == 2
    stdout, stderr = capsys.readouterr()
    assert stdout == "" and "arguments_invalid" in stderr and _KEY not in stderr


@pytest.fixture(scope="module")
def startupFiles(tmp_path_factory: pytest.TempPathFactory) -> Path:
    if os.name != "nt":
        pytest.skip("Windows CurrentUser DPAPI integration")
    folder = tmp_path_factory.mktemp("protected-startup") / "synthetic"
    service = Path(__file__).resolve().parents[1]
    powershell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    result = subprocess.run(  # noqa: S603 — fixed system binary and synthetic test script.
        [
            str(powershell),
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(service / "scripts/test_gateway_startup.ps1"),
            "-TestDirectory",
            str(folder),
        ],
        capture_output=True,
        timeout=30,
        check=False,
        creationflags=subprocess.CREATE_NO_WINDOW,
        env={**os.environ, "PSModulePath": str(powershell.parent / "Modules")},
    )
    assert result.returncode == 0, "synthetic protected fixture failed"
    assert _KEY.encode() not in result.stdout + result.stderr
    assert _DSN.encode() not in result.stdout + result.stderr
    return folder


def test_actual_current_user_dpapi_to_check_only_has_no_network_or_writes(
    startupFiles: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    before = {path.name: path.read_bytes() for path in startupFiles.iterdir()}

    def forbidden(**kwargs: object) -> FastAPI:
        pytest.fail("CheckOnly must not construct database/provider/sender")

    monkeypatch.setattr(startup, "createApplication", forbidden)
    settings = startup.loadStartupSettings(startupFiles / "startup.dpapi")
    assert settings.glmApiKey == _KEY and settings.databaseDsn == _DSN
    assert (
        startup.main(["--configuration", str(startupFiles / "startup.dpapi"), "--check-only"]) == 0
    )
    assert {path.name: path.read_bytes() for path in startupFiles.iterdir()} == before
    stdout, stderr = capsys.readouterr()
    assert stderr == "" and "no network or database access" in stdout
    assert _KEY not in stdout and _DSN not in stdout


@pytest.mark.parametrize("filename", ["inherited.dpapi", "corrupt.dpapi"])
def test_actual_invalid_permission_or_dpapi_blob_is_redacted(
    startupFiles: Path, filename: str, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(startup.ProtectedStartupError) as failure:
        startup.loadStartupSettings(startupFiles / filename)
    assert failure.value.__suppress_context__ and failure.value.__cause__ is None
    assert capsys.readouterr() == ("", "")


def test_dependency_failure_is_redacted(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    def fail(path: Path, *, kind: str) -> str:
        raise RuntimeError(_KEY)

    monkeypatch.setattr(startup, "loadProtectedPayload", fail)
    with pytest.raises(startup.ProtectedStartupError) as failure:
        startup.loadStartupSettings(tmp_path / "startup.dpapi")
    assert str(failure.value) == "protected_startup_configuration_unavailable"
    assert failure.value.__suppress_context__


@pytest.mark.parametrize(
    "name", ["GATEWAY_DATABASE_MIGRATION_DSN", "GATEWAY_DATABASE_MANAGEMENT_DSN"]
)
def test_management_credentials_rejected_before_protected_files_are_read(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, name: str
) -> None:
    def forbidden(path: Path, *, kind: str) -> str:
        pytest.fail("Management DSN must be refused before any protected file read")

    monkeypatch.setenv(name, _DSN)
    monkeypatch.setattr(startup, "loadProtectedPayload", forbidden)
    with pytest.raises(startup.ProtectedStartupError):
        startup.loadStartupSettings(tmp_path / "unread.dpapi")


def test_actual_powershell_check_only_launches_protected_python_entry(startupFiles: Path) -> None:
    service = Path(__file__).resolve().parents[1]
    powershell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    result = subprocess.run(  # noqa: S603 — fixed wrapper, synthetic encrypted path only.
        [
            str(powershell),
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(service / "scripts/start_protected_gateway.ps1"),
            "-EncryptedStartupPath",
            str(startupFiles / "startup.dpapi"),
            "-CheckOnly",
        ],
        capture_output=True,
        timeout=30,
        check=False,
        creationflags=subprocess.CREATE_NO_WINDOW,
        env={**os.environ, "PSModulePath": str(powershell.parent / "Modules")},
    )
    assert result.returncode == 0, "synthetic protected launcher failed"
    assert b"protected_startup_local_check_passed" in result.stdout
    assert _KEY.encode() not in result.stdout + result.stderr
    assert _DSN.encode() not in result.stdout + result.stderr


def test_guest_sidecar_is_bounded_private_and_never_rewrites_credentials_or_creates_database(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = GatewaySettings()
    assert startup._guestSettings(settings, tmp_path) is settings
    folder = tmp_path / "guest-ai"
    folder.mkdir()
    policy = folder / "policy.json"
    data: dict[str, object] = {
        "schemaVersion": 1,
        "enabled": True,
        "maximumMonthlyCalls": 16,
        "enabledUntilUtc": "2026-10-24T00:00:00Z",
    }
    policy.write_text(json.dumps(data), encoding="utf-8")
    observed: list[Path] = []
    monkeypatch.setattr(startup, "verifyWindowsResultDirectory", observed.append)
    configured = startup._guestSettings(settings, tmp_path)
    assert configured.guestDatabasePath == folder / "guest-ai.sqlite3"
    assert configured.guestMonthlyCallLimit == 16
    assert observed == [folder]
    assert not configured.guestDatabasePath.exists()
    assert settings.guestDatabasePath is None
    assert json.loads(policy.read_text(encoding="utf-8")) == data
    policy.write_text(json.dumps(data | {"enabled": False}), encoding="utf-8")
    assert startup._guestSettings(settings, tmp_path) is settings


@pytest.mark.parametrize(
    "field,value",
    [
        ("enabled", 1),
        ("maximumMonthlyCalls", 0),
        ("maximumMonthlyCalls", 101),
        ("maximumMonthlyCalls", True),
        ("enabledUntilUtc", "2026-10-24T00:00:00"),
    ],
)
def test_guest_sidecar_refuses_unbounded_or_ambiguous_policy(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    field: str,
    value: object,
) -> None:
    folder = tmp_path / "guest-ai"
    folder.mkdir()
    data: dict[str, object] = {
        "schemaVersion": 1,
        "enabled": True,
        "maximumMonthlyCalls": 16,
        "enabledUntilUtc": "2026-10-24T00:00:00Z",
    }
    (folder / "policy.json").write_text(json.dumps(data | {field: value}), encoding="utf-8")
    monkeypatch.setattr(startup, "verifyWindowsResultDirectory", lambda path: None)
    with pytest.raises((startup.ProtectedStartupError, ValueError)):
        startup._guestSettings(GatewaySettings(), tmp_path)
