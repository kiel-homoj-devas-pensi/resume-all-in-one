from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType

import pytest

from agent_gateway.account_privileges import AccountPrivilegeService
from agent_gateway.account_storage import SqliteAccountDatabase, UnknownStorageCommitError
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.privilege_schema import validateSqlitePrivilegeSchema


def cli() -> ModuleType:
    path = Path(__file__).resolve().parents[1] / "scripts/manage_account_privileges.py"
    spec = importlib.util.spec_from_file_location("privilege_cli_test", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def invoke(module: ModuleType, monkeypatch: pytest.MonkeyPatch, *args: str) -> int:
    monkeypatch.setattr(sys, "argv", ["cli", *args])
    result = module.main()
    assert isinstance(result, int)
    return result


def test_cli_migration_is_explicit_and_grant_plan_is_read_only(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    database = GatewayDatabase(tmp_path / "synthetic.db")
    database.initialize()
    accounts = AccountService(database, FakePhoneOwnershipVerifier())
    phone = "+15550005555"
    account = accounts.registerAccount(
        phoneE164=phone,
        password="TestPass2026!",
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    monkeypatch.setenv("GATEWAY_DATABASE_BACKEND", "sqlite")
    monkeypatch.setenv("AGENT_GATEWAY_TASK018_DATABASE_PATH", str(database.databasePath))
    monkeypatch.setenv("AGENT_GATEWAY_PRIVILEGE_TARGET_PHONE", phone)
    module = cli()
    before = database.databasePath.read_bytes()
    assert invoke(module, monkeypatch, "migrate") == 1
    assert invoke(module, monkeypatch, "migrate", "--apply") == 1
    assert database.databasePath.read_bytes() == before
    assert invoke(module, monkeypatch, "migrate", "--apply", "--confirmed-quiescent") == 0
    validateSqlitePrivilegeSchema(database)
    service = AccountPrivilegeService(SqliteAccountDatabase(database))
    plan = (
        "--account-id",
        account,
        "--grant-id",
        "synthetic-grant",
        "--operator-id",
        "synthetic-op",
        "--evidence-sha256",
        "a" * 64,
    )
    assert invoke(module, monkeypatch, "grant", *plan, "--privilege", "permanentMember") == 0
    assert service.read(account).membership == "none"
    assert (
        invoke(module, monkeypatch, "grant", *plan, "--privilege", "permanentMember", "--apply")
        == 0
    )
    assert service.read(account).membership == "permanent"
    assert invoke(module, monkeypatch, "revoke", *plan) == 0
    assert service.read(account).membership == "permanent"
    assert invoke(module, monkeypatch, "revoke", *plan, "--apply") == 0
    assert service.read(account).membership == "none"
    output = capsys.readouterr().out
    assert (
        phone not in output and account not in output and str(database.databasePath) not in output
    )


def test_cli_unknown_commit_is_not_automatic_retry(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    module = cli()
    calls = 0

    def fail(*, write: bool) -> None:
        nonlocal calls
        calls += 1
        raise UnknownStorageCommitError("sensitive-internal-detail")

    monkeypatch.setattr(module, "configuredDatabase", fail)
    assert invoke(module, monkeypatch, "check") == 2
    result = json.loads(capsys.readouterr().out)
    assert calls == 1 and result == {
        "status": "outcome_unknown",
        "retryable": False,
        "next": "read_only_check",
    }


def test_cli_mysql_management_identity_cannot_be_same_or_another_target(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ca = tmp_path / "synthetic-ca.pem"
    ca.write_text("synthetic-no-network", encoding="ascii")
    monkeypatch.setenv("GATEWAY_DATABASE_BACKEND", "mysql")
    monkeypatch.setenv(
        "GATEWAY_DATABASE_DSN", "mysql://business:synthetic@127.0.0.1:18039/synthetic"
    )
    monkeypatch.setenv("GATEWAY_DATABASE_TLS_CA_FILE", str(ca))
    monkeypatch.setenv("GATEWAY_DATABASE_EXPIRES_AT_UTC", "2099-01-01T00:00:00Z")
    module = cli()
    for dsn in (
        "mysql://business:synthetic@127.0.0.1:18039/synthetic",
        "mysql://management:synthetic@127.0.0.1:18039/another",
    ):
        monkeypatch.setenv("GATEWAY_DATABASE_MIGRATION_DSN", dsn)
        with pytest.raises(ValueError, match="privilege_management_identity_mismatch"):
            module.configuredDatabase(write=True)
