from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
from types import ModuleType

import pytest

from agent_gateway.account_privileges import AccountPrivilegeService
from agent_gateway.account_storage import SqliteAccountDatabase, UnknownStorageCommitError
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.privilege_schema import migrateSqlitePrivilegeSchema


def cli() -> ModuleType:
    path = Path(__file__).resolve().parents[1] / "scripts/manage_account_privileges_secure.py"
    spec = importlib.util.spec_from_file_location("secure_privilege_test", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    module = cli()
    db = GatewayDatabase(tmp_path / "synthetic.db")
    db.initialize()
    phone = "+15550005555"
    account = AccountService(db, FakePhoneOwnershipVerifier()).registerAccount(
        phoneE164=phone,
        password="TestPass2026!",
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    migrateSqlitePrivilegeSchema(db)
    adapters = []

    class Adapter(SqliteAccountDatabase):
        def __init__(self, config):
            super().__init__(db)
            self.config = config
            self.transactions = 0
            adapters.append(self)

        def transaction(self):
            self.transactions += 1
            return super().transaction()

        def close(self):
            pass

    monkeypatch.setattr(module, "MySqlAccountDatabase", Adapter)
    monkeypatch.setattr(module, "_identity", lambda *_: "same-synthetic-server")
    ca = tmp_path / "synthetic-ca.pem"
    ca.write_text("SYNTHETIC_CA_NO_NETWORK")
    arguments = [
        "--host",
        "synthetic.example",
        "--database",
        "synthetic",
        "--ca-file",
        str(ca),
        "--expires-at-utc",
        "2099-01-01T00:00:00Z",
        "--account-id",
        account,
        "--grant-id",
        "synthetic-grant-admin",
        "--privilege",
        "admin",
        "--operator-id",
        "synthetic-operator",
        "--evidence-sha256",
        "a" * 64,
    ]
    return module, db, phone, account, arguments, adapters


def input_payload(monkeypatch: pytest.MonkeyPatch, module: ModuleType, phone: str, apply=False):
    payload = {"phone": phone, "resume_web": "  synthetic 中文 @:/?#%+\\'\"  "}
    if apply:
        payload["resume_maint"] = "synthetic-maintenance-password"
    monkeypatch.setattr(module.sys, "stdin", io.StringIO(json.dumps(payload, ensure_ascii=False)))
    return payload


def test_real_domain_plan_write_and_same_grant_readback(tmp_path, monkeypatch, capsys):
    module, db, phone, account, arguments, adapters = fixture(tmp_path, monkeypatch)
    service = AccountPrivilegeService(SqliteAccountDatabase(db))
    input_payload(monkeypatch, module, phone)
    assert module.main(arguments) == 0
    plan = json.loads(capsys.readouterr().out)
    assert plan["matchingGrantVerified"] is False and plan["role"] == "member"
    assert sum(a.transactions for a in adapters) == 0
    payload = input_payload(monkeypatch, module, phone, True)
    assert module.main(arguments + ["--apply", "--confirmed-grant"]) == 0
    output = capsys.readouterr().out
    result = json.loads(output)
    assert result["matchingGrantVerified"] is True and result["role"] == "admin"
    assert service.read(account).role == "admin"
    assert sum(a.transactions for a in adapters) == 1
    assert len(adapters) == 4  # plan, write preflight, maintenance, fresh readback
    assert adapters[1].config.password == payload["resume_web"]
    assert all(value not in output for value in (*payload.values(), account))
    input_payload(monkeypatch, module, phone)
    assert module.main(arguments) == 0
    assert json.loads(capsys.readouterr().out)["matchingGrantVerified"] is True
    assert sum(a.transactions for a in adapters) == 1


def test_wrong_phone_and_cross_server_never_write(tmp_path, monkeypatch, capsys):
    module, db, phone, account, arguments, adapters = fixture(tmp_path, monkeypatch)
    input_payload(monkeypatch, module, "+15550009999", True)
    assert module.main(arguments + ["--apply", "--confirmed-grant"]) == 1
    assert sum(a.transactions for a in adapters) == 0
    input_payload(monkeypatch, module, phone, True)
    monkeypatch.setattr(module, "_identity", lambda _, user, __: user)
    assert module.main(arguments + ["--apply", "--confirmed-grant"]) == 1
    assert sum(a.transactions for a in adapters) == 0
    assert AccountPrivilegeService(SqliteAccountDatabase(db)).read(account).role == "member"
    assert phone not in capsys.readouterr().out


def test_unknown_commit_never_retries_or_claims_success(tmp_path, monkeypatch, capsys):
    module, _, phone, _, arguments, _ = fixture(tmp_path, monkeypatch)
    original = module.AccountPrivilegeService.grant
    writes = 0

    def grant(self, *, apply=False, **kwargs):
        nonlocal writes
        if apply:
            writes += 1
            raise UnknownStorageCommitError("SENSITIVE_DRIVER_DETAIL")
        return original(self, apply=False, **kwargs)

    monkeypatch.setattr(module.AccountPrivilegeService, "grant", grant)
    input_payload(monkeypatch, module, phone, True)
    assert module.main(arguments + ["--apply", "--confirmed-grant"]) == 2
    output = capsys.readouterr().out
    assert writes == 1 and "SENSITIVE_DRIVER_DETAIL" not in output
    assert json.loads(output)["next"] == "read_only_same_grant_check"


@pytest.mark.parametrize(
    "raw",
    ["not-json", "{}", '{"phone":"a","phone":"b"}', "x" * 65537],
    ids=["invalid-json", "missing-fields", "duplicate-key", "oversized"],
)
def test_malformed_private_input_never_opens_database(tmp_path, monkeypatch, capsys, raw):
    module, _, _, _, arguments, adapters = fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(module.sys, "stdin", io.StringIO(raw))
    assert module.main(arguments) == 1 and adapters == []
    assert json.loads(capsys.readouterr().out)["status"] == "privilege_check_failed"


def test_explicit_write_confirmation_required_before_credentials(tmp_path, monkeypatch, capsys):
    module, _, phone, _, arguments, adapters = fixture(tmp_path, monkeypatch)
    input_payload(monkeypatch, module, phone, True)
    assert module.main(arguments + ["--apply"]) == 1 and adapters == []
    assert json.loads(capsys.readouterr().out)["writeRequested"] is True


@pytest.mark.parametrize("privilege", ["admin", "permanentMember"])
def test_concurrently_removed_privilege_is_not_reported_verified(
    tmp_path, monkeypatch, capsys, privilege
):
    module, _, phone, _, arguments, _ = fixture(tmp_path, monkeypatch)
    arguments[arguments.index("--privilege") + 1] = privilege
    original = module.AccountPrivilegeService.read

    def read(self, account_id):
        return original(self, account_id).model_copy(
            update={"role": "member", "membership": "none"}
        )

    monkeypatch.setattr(module.AccountPrivilegeService, "read", read)
    input_payload(monkeypatch, module, phone, True)
    assert module.main(arguments + ["--apply", "--confirmed-grant"]) == 1
    result = json.loads(capsys.readouterr().out)
    assert result["status"] == "privilege_check_failed"
    assert result["next"] == "read_only_same_grant_check"


@pytest.mark.parametrize(
    "code,category", [(1045, "credentials_rejected"), (1142, "query_not_permitted")]
)
def test_wrapped_maintenance_failure_has_safe_stage_and_no_write(
    tmp_path, monkeypatch, capsys, code, category
):
    import pymysql

    module, _, phone, _, arguments, adapters = fixture(tmp_path, monkeypatch)

    def identity(_, user, __):
        if user == "resume_maint":
            try:
                raise pymysql.err.OperationalError(code, "SENSITIVE_DRIVER_DETAIL")
            except pymysql.MySQLError:
                raise RuntimeError("PRIVATE_STORAGE_DETAIL") from None
        return "same-synthetic-server"

    monkeypatch.setattr(module, "_identity", identity)
    payload = input_payload(monkeypatch, module, phone, True)
    assert module.main(arguments + ["--apply", "--confirmed-grant"]) == 1
    output = capsys.readouterr().out
    result = json.loads(output)
    assert result["failureStage"] == "maintenance_identity_and_schema"
    assert result["failureCategory"] == category
    assert sum(a.transactions for a in adapters) == 0
    assert all(
        secret not in output
        for secret in (*payload.values(), "SENSITIVE_DRIVER_DETAIL", "PRIVATE_STORAGE_DETAIL")
    )


def test_grant_transaction_failure_is_distinct_from_identity_failure(tmp_path, monkeypatch, capsys):
    module, _, phone, _, arguments, _ = fixture(tmp_path, monkeypatch)
    original = module.AccountPrivilegeService.grant
    attempts = 0

    def grant(self, *, apply=False, **kwargs):
        nonlocal attempts
        if apply:
            attempts += 1
            raise RuntimeError("SENSITIVE_WRITE_DETAIL")
        return original(self, apply=False, **kwargs)

    monkeypatch.setattr(module.AccountPrivilegeService, "grant", grant)
    input_payload(monkeypatch, module, phone, True)
    assert module.main(arguments + ["--apply", "--confirmed-grant"]) == 1
    output = capsys.readouterr().out
    result = json.loads(output)
    assert result["failureStage"] == "maintenance_grant_transaction"
    assert result["failureCategory"] == "check_rejected"
    assert result["next"] == "read_only_same_grant_check" and attempts == 1
    assert "SENSITIVE_WRITE_DETAIL" not in output
