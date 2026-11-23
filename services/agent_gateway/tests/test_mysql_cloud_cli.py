from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

import pytest

from agent_gateway.account_storage import UnknownStorageCommitError
from agent_gateway.mysql_storage import MySqlConfig


def cliModule() -> ModuleType:
    path = Path(__file__).resolve().parents[1] / "scripts/run_mysql_synthetic_contract.py"
    spec = importlib.util.spec_from_file_location("synthetic_cloud_cli_test", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def config(tmp_path: Path) -> MySqlConfig:
    ca = tmp_path / "synthetic-ca.pem"
    ca.write_text("synthetic-no-network-ca", encoding="ascii")
    return MySqlConfig.fromDsn(
        "mysql://synthetic-business:synthetic-unused-password@127.0.0.1:18029/"
        "resume_gateway_synthetic_cli",
        ca,
        "2099-01-01T00:00:00Z",
    )


@pytest.mark.parametrize(
    "flags",
    [
        ["--with-cloud"],
        ["--with-cloud", "--migrate"],
        ["--with-cloud", "--dry-run", "--migrate"],
        ["--with-cloud", "--migrate", "--confirmed-quiescent", "--with-sms-budget"],
        ["--confirmed-quiescent"],
        ["--with-sms-budget"],
    ],
)
def test_invalid_cloud_choices_fail_before_reading_local_configuration(
    flags: list[str], monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    module = cliModule()
    monkeypatch.setattr(sys, "argv", ["cli", "--synthetic-only", *flags])

    def forbiddenConfiguration() -> None:
        raise AssertionError("must not read configuration for invalid choices")

    monkeypatch.setattr(module, "configuredSyntheticDatabase", forbiddenConfiguration)
    assert module.main() == 1
    assert capsys.readouterr().out.startswith("FAIL:")


@pytest.mark.parametrize("unknown", [False, True])
def test_cloud_readonly_check_never_runs_business_writes_and_unknown_is_explicit(
    tmp_path: Path,
    unknown: bool,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module = cliModule()
    configured = config(tmp_path)
    calls: list[str] = []

    class Database:
        def checkSchema(self, *, withCloud: bool = False) -> None:
            assert withCloud
            calls.append("check")
            if unknown:
                raise UnknownStorageCommitError("synthetic-private-error")

        def close(self) -> None:
            calls.append("close")

    monkeypatch.setattr(module, "configuredSyntheticDatabase", lambda: configured)
    monkeypatch.setattr(module, "MySqlAccountDatabase", lambda _: Database())
    monkeypatch.setattr(sys, "argv", ["cli", "--synthetic-only", "--with-cloud", "--dry-run"])
    assert module.main() == (2 if unknown else 0)
    assert calls == ["check", "close"]
    output = capsys.readouterr().out
    assert output.startswith("UNKNOWN:" if unknown else "PASS:")
    assert "synthetic-private-error" not in output


@pytest.mark.parametrize("target", ["same-identity", "wrong-database", "correct"])
def test_cloud_migration_requires_distinct_admin_same_target_and_explicit_stop_write(
    tmp_path: Path,
    target: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = cliModule()
    configured = config(tmp_path)
    user = "synthetic-business" if target == "same-identity" else "synthetic-admin"
    database = (
        "resume_gateway_synthetic_other" if target == "wrong-database" else configured.database
    )
    monkeypatch.setenv(
        "GATEWAY_DATABASE_MIGRATION_DSN",
        f"mysql://{user}:synthetic-unused-password@127.0.0.1:18029/{database}",
    )
    calls: list[str] = []

    class Database:
        def checkSchema(self, *, withCloud: bool = False) -> None:
            assert withCloud
            calls.append("check")

        def close(self) -> None:
            calls.append("close")

    monkeypatch.setattr(module, "configuredSyntheticDatabase", lambda: configured)
    monkeypatch.setattr(module, "MySqlAccountDatabase", lambda _: Database())
    monkeypatch.setattr(module, "migrateSyntheticCloudSchema", lambda _: calls.append("migrate"))
    monkeypatch.setattr(
        sys,
        "argv",
        ["cli", "--synthetic-only", "--with-cloud", "--migrate", "--confirmed-quiescent"],
    )
    assert module.main() == (0 if target == "correct" else 1)
    assert calls == (["migrate", "close", "check", "close"] if target == "correct" else [])
