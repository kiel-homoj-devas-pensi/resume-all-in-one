from __future__ import annotations

import importlib.util
import json
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from types import ModuleType

import pytest

from agent_gateway.account_storage import AccountSqlConnection, UnknownStorageCommitError
from agent_gateway.mysql_bootstrap import BootstrapPlan, BootstrapRejectedError


def cli() -> ModuleType:
    path = Path(__file__).resolve().parents[1] / "scripts/prepare_mysql_schema.py"
    spec = importlib.util.spec_from_file_location("bootstrap_cli_test", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class NoNetworkDatabase:
    made: list[NoNetworkDatabase] = []

    def __init__(self, config: object) -> None:
        self.closed = False
        self.made.append(self)

    @contextmanager
    def readConnection(self) -> Iterator[AccountSqlConnection]:
        yield pytest.fail("read-only inspection supplied via monkeypatch")

    def close(self) -> None:
        self.closed = True


@pytest.mark.parametrize("arguments", [[], ["plan"], ["check"]])
def test_default_read_only_never_reads_management_dsn(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    arguments: list[str],
) -> None:
    module = cli()
    configured: list[str] = []

    def config(name: str) -> object:
        configured.append(name)
        return object()

    monkeypatch.setattr(module, "_config", config)
    monkeypatch.setattr(module, "MySqlAccountDatabase", NoNetworkDatabase)

    @contextmanager
    def read(self: NoNetworkDatabase) -> Iterator[None]:
        yield None

    monkeypatch.setattr(NoNetworkDatabase, "readConnection", read)
    monkeypatch.setattr(module, "inspectSchema", lambda c: BootstrapPlan("empty", 0))
    assert module.main(arguments) == (1 if arguments == ["check"] else 0)
    assert configured == ["GATEWAY_DATABASE_DSN"]
    assert all(item.closed for item in NoNetworkDatabase.made)
    data = json.loads(capsys.readouterr().out)
    assert data["retryable"] is False


def test_apply_confirmation_rejection_precedes_connecting(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module = cli()
    monkeypatch.setattr(module, "_config", lambda name: object())

    def reject(*args: object, **kwargs: object) -> None:
        raise BootstrapRejectedError("explicit_confirmations_required")

    monkeypatch.setattr(module, "validateTarget", reject)
    monkeypatch.setattr(module, "MySqlAccountDatabase", lambda config: pytest.fail("no connection"))
    assert module.main(["--apply"]) == 1
    assert json.loads(capsys.readouterr().out)["reason"] == "explicit_confirmations_required"


def test_apply_passes_explicit_target_and_confirmations_and_cleans_both_identities(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module = cli()
    configured: list[str] = []

    def config(name: str) -> object:
        configured.append(name)
        return object()

    targets: list[dict[str, object]] = []
    writes: list[dict[str, object]] = []

    def validate(*args: object, **kwargs: object) -> None:
        targets.append(kwargs)

    def prepare(*args: object, **kwargs: object) -> BootstrapPlan:
        writes.append(kwargs)
        return BootstrapPlan("schema_verified", 17)

    monkeypatch.setattr(module, "_config", config)
    monkeypatch.setattr(module, "MySqlAccountDatabase", NoNetworkDatabase)
    monkeypatch.setattr(module, "validateTarget", validate)
    monkeypatch.setattr(module, "prepareEmptySchema", prepare)
    assert (
        module.main(
            [
                "plan",
                "--apply",
                "--expected-host",
                "synthetic.local",
                "--expected-port",
                "3336",
                "--expected-database",
                "synthetic_bootstrap",
                "--confirmed-quiescent",
                "--confirmed-dedicated-empty",
            ]
        )
        == 0
    )
    assert configured == ["GATEWAY_DATABASE_DSN", "GATEWAY_DATABASE_MIGRATION_DSN"]
    assert targets == [
        {
            "expectedHost": "synthetic.local",
            "expectedPort": 3336,
            "expectedDatabase": "synthetic_bootstrap",
            "confirmedQuiescent": True,
            "confirmedDedicatedEmpty": True,
        }
    ]
    assert writes == [
        {
            "expectedDatabase": "synthetic_bootstrap",
            "confirmedQuiescent": True,
            "confirmedDedicatedEmpty": True,
        }
    ]
    assert all(item.closed for item in NoNetworkDatabase.made)
    data = json.loads(capsys.readouterr().out)
    assert data["status"] == "schema_verified" and data["businessRowsWritten"] == 0


@pytest.mark.parametrize(
    "error,exitCode",
    [
        (UnknownStorageCommitError("mysql://manager:private-password@internal-host/db"), 2),
        (ValueError("mysql://manager:private-password@internal-host/db"), 1),
    ],
)
def test_config_errors_and_unknown_outcome_are_redacted_and_not_retried(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    error: Exception,
    exitCode: int,
) -> None:
    module = cli()
    calls: list[str] = []

    def config(name: str) -> None:
        calls.append(name)
        raise error

    monkeypatch.setattr(module, "_config", config)
    assert module.main([]) == exitCode
    output = capsys.readouterr().out
    assert "private-password" not in output and "internal-host" not in output
    assert len(calls) == 1
    assert json.loads(output)["retryable"] is False
