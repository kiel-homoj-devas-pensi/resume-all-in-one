from __future__ import annotations

import importlib.util
import io
import json
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import ModuleType

import pytest

from agent_gateway.account_storage import (
    AccountSqlConnection,
    SqliteAccountDatabase,
    UnknownStorageCommitError,
)
from agent_gateway.database import GatewayDatabase
from agent_gateway.mysql_storage import MySqlConfig
from agent_gateway.pnvs_runtime import PnvsRuntimeSettings
from agent_gateway.sms_budget import SmsBudgetLedger, SmsBudgetPolicy

SERVER = "aeb7ec07-2bf3-4de1-9664-cd7aa52a4ef7"


def _module() -> ModuleType:
    path = Path(__file__).resolve().parents[1] / "scripts/approve_pnvs_budget_secure.py"
    spec = importlib.util.spec_from_file_location("secure_budget", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Connection:
    def __init__(self, owner: Database, wrapped: AccountSqlConnection) -> None:
        self.owner, self.wrapped, self.written = owner, wrapped, False

    def execute(self, sql: str, parameters: tuple[object, ...] = ()) -> int:
        assert sql.startswith("INSERT INTO sms_send_budget"), (
            "only existing policy INSERT permitted"
        )
        self.owner.writes += 1
        self.written = True
        return self.wrapped.execute(sql.replace("%s", "?"), parameters)

    def fetchOne(self, sql: str, parameters: tuple[object, ...] = ()) -> object:
        if "VERSION()" in sql:
            return {"mysql_version": self.owner.version}
        if "@@server_uuid" in sql:
            return {
                "server_uuid": self.owner.server,
                "identity": self.owner.identity,
                "database_name": self.owner.schema,
            }
        if sql.startswith("SELECT * FROM sms_send_budget"):
            self.owner.policyLocks.append("shared" if sql.endswith(" FOR SHARE") else "exclusive")
        return self.wrapped.fetchOne(
            sql.replace("%s", "?").removesuffix(" FOR UPDATE").removesuffix(" FOR SHARE"),
            parameters,
        )


class Database:
    def __init__(self, config: MySqlConfig, wrapped: SqliteAccountDatabase) -> None:
        self.config, self.wrapped = config, wrapped
        self.server, self.identity, self.schema = (
            SERVER,
            config.user + "@synthetic",
            config.database,
        )
        self.writes, self.validated, self.closed, self.unknown = 0, 0, False, False
        self.version = "8.0.46"
        self.policyLocks: list[str] = []

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return "mysql", self.config.host, str(self.config.port), self.config.database

    @contextmanager
    def transaction(self) -> Iterator[Connection]:
        assert not self.closed
        with self.wrapped.transaction() as connection:
            adapted = Connection(self, connection)
            yield adapted
        if self.unknown and adapted.written:
            raise UnknownStorageCommitError("synthetic DSN and password must not appear")

    def readConnection(self) -> object:
        return self.transaction()

    def close(self) -> None:
        self.closed = True


@pytest.fixture
def scenario(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> tuple[ModuleType, list[str], list[Database], PnvsRuntimeSettings]:
    module = _module()
    ca, runtimeFile = tmp_path / "ca.pem", tmp_path / "runtime.dpapi"
    ca.write_text("synthetic no network")
    runtimeFile.write_text("synthetic loader mocked")
    database = GatewayDatabase(tmp_path / "synthetic.db")
    database.initialize()
    wrapper = SqliteAccountDatabase(database)
    made: list[Database] = []

    def construct(config: MySqlConfig) -> Database:
        result = Database(config, wrapper)
        made.append(result)
        return result

    def validate(connection: Connection) -> None:
        connection.owner.validated += 1

    runtime = PnvsRuntimeSettings(
        b"o" * 32,
        b"a" * 32,
        SmsBudgetPolicy(
            10, 60, 6, datetime.now(UTC) + timedelta(days=1), frozenset({"+8613800138000"})
        ),
    )
    monkeypatch.setattr(module, "MySqlAccountDatabase", construct)
    monkeypatch.setattr(module, "validateMySqlPrivilegeSchema", validate)
    monkeypatch.setattr(module, "loadPnvsRuntimeSettings", lambda path: runtime)
    args = [
        "--host",
        "synthetic.example",
        "--port",
        "18029",
        "--database",
        "synthetic",
        "--ca-file",
        str(ca),
        "--encrypted-runtime-path",
        str(runtimeFile),
        "--expires-at-utc",
        "2099-01-01T00:00:00Z",
    ]
    return module, args, made, runtime


def _invoke(
    module: ModuleType,
    args: list[str],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    *,
    apply: bool = False,
) -> tuple[int, dict[str, object]]:
    credentials = {"resume_web": " synthetic @:/?#%+中文 "}
    if apply:
        credentials["resume_maint"] = "synthetic-maint-password"
        args = [*args, "--apply-approved-budget", "--confirmed-policy-approval"]
    monkeypatch.setattr(module.sys, "stdin", io.StringIO(json.dumps(credentials)))
    code = module.main(args)
    captured = capsys.readouterr()
    assert captured.err == ""
    assert all(secret not in captured.out for secret in credentials.values())
    assert "mysql://" not in captured.out and "policy_fingerprint" not in captured.out
    return code, json.loads(captured.out)


def test_default_only_reads_and_explicit_approval_uses_fresh_business_identity(
    scenario: tuple[ModuleType, list[str], list[Database], PnvsRuntimeSettings],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module, args, made, runtime = scenario
    code, result = _invoke(module, args, monkeypatch, capsys)
    assert code == 1 and result["status"] == "policy_not_approved"
    assert len(made) == 1 and made[0].writes == 0 and made[0].validated == 1
    assert made[0].closed and made[0].config.password == " synthetic @:/?#%+中文 "
    made.clear()
    code, result = _invoke(module, args, monkeypatch, capsys, apply=True)
    assert code == 0 and result["status"] == "approved_policy_verified"
    assert [item.config.user for item in made] == ["resume_web", "resume_maint", "resume_web"]
    assert [item.writes for item in made] == [0, 1, 0]
    assert all(item.validated == 1 and item.closed for item in made)
    assert all(lock == "shared" for item in made for lock in item.policyLocks)
    assert result["attemptsRemaining"] == 10 and result["budgetRemainingCents"] == 60
    # A matching repeated explicit approval must verify, never reset an existing reservation.
    ledger = SmsBudgetLedger(made[-1].wrapped, runtime.policy, auditSecret=runtime.auditSecret)
    ledger.reserve("challenge-7c89e9f0-6a42-4e07-948f-680fb8a19b94", "+8613800138000", "register")
    made.clear()
    code, result = _invoke(module, args, monkeypatch, capsys, apply=True)
    assert code == 0 and result["attemptsUsed"] == 1 and result["reservedCents"] == 6
    assert result["attemptsRemaining"] == 9 and result["budgetRemainingCents"] == 54
    assert all(item.writes == 0 for item in made)


@pytest.mark.parametrize("mismatch", ["server", "identity", "schema", "v6"])
def test_both_actual_identities_and_full_schema_verified_before_any_write(
    scenario: tuple[ModuleType, list[str], list[Database], PnvsRuntimeSettings],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    mismatch: str,
) -> None:
    module, args, made, _ = scenario
    original = module.MySqlAccountDatabase

    def construct(config: MySqlConfig) -> Database:
        database: Database = original(config)
        if config.user == "resume_maint":
            if mismatch == "server":
                database.server = "2230d980-19db-4d70-920f-a6bba057d9f5"
            elif mismatch == "identity":
                database.identity = "resume_web@synthetic"
            elif mismatch == "schema":
                database.schema = "wrong_database"
        return database

    monkeypatch.setattr(module, "MySqlAccountDatabase", construct)
    if mismatch == "v6":

        def reject(connection: Connection) -> None:
            raise ValueError("synthetic-secret invalid old schema")

        monkeypatch.setattr(module, "validateMySqlPrivilegeSchema", reject)
    code, result = _invoke(module, args, monkeypatch, capsys, apply=True)
    assert code == 1 and result["status"] == "budget_check_failed"
    assert all(item.closed and item.writes == 0 for item in made)


def test_unknown_commit_is_not_retried_and_only_read_only_next_is_reported(
    scenario: tuple[ModuleType, list[str], list[Database], PnvsRuntimeSettings],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module, args, made, _ = scenario
    original = module.MySqlAccountDatabase

    def construct(config: MySqlConfig) -> Database:
        database: Database = original(config)
        database.unknown = config.user == "resume_maint"
        return database

    monkeypatch.setattr(module, "MySqlAccountDatabase", construct)
    code, result = _invoke(module, args, monkeypatch, capsys, apply=True)
    assert code == 2 and result["status"] == "outcome_unknown"
    assert result["next"] == "read_only_check" and result["retryable"] is False
    assert len(made) == 2 and sum(item.writes for item in made) == 1
    assert all(item.closed for item in made)
    code, result = _invoke(module, args, monkeypatch, capsys)
    assert code == 0 and result["status"] == "approved_policy_verified"


def test_fresh_business_identity_mismatch_does_not_replay_successful_approval(
    scenario: tuple[ModuleType, list[str], list[Database], PnvsRuntimeSettings],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module, args, made, _ = scenario
    original = module.MySqlAccountDatabase

    def construct(config: MySqlConfig) -> Database:
        database: Database = original(config)
        if len(made) == 3:
            database.server = "2230d980-19db-4d70-920f-a6bba057d9f5"
        return database

    monkeypatch.setattr(module, "MySqlAccountDatabase", construct)
    code, result = _invoke(module, args, monkeypatch, capsys, apply=True)
    assert code == 1 and result["status"] == "budget_check_failed"
    assert result["next"] == "read_only_check"
    assert sum(item.writes for item in made) == 1 and all(item.closed for item in made)
    code, result = _invoke(module, args, monkeypatch, capsys)
    assert code == 0 and result["status"] == "approved_policy_verified"


def test_expired_existing_policy_can_be_read_without_any_write(
    scenario: tuple[ModuleType, list[str], list[Database], PnvsRuntimeSettings],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module, args, made, runtime = scenario
    expired = PnvsRuntimeSettings(
        runtime.otpSecret,
        runtime.auditSecret,
        SmsBudgetPolicy(10, 60, 6, datetime(2000, 1, 2, tzinfo=UTC), runtime.policy.allowedPhones),
    )
    _invoke(module, args, monkeypatch, capsys)
    ledger = SmsBudgetLedger(made[0].wrapped, expired.policy, auditSecret=expired.auditSecret)
    ledger.createApprovedPolicy(nowUtc=datetime(2000, 1, 1, tzinfo=UTC))
    made.clear()
    monkeypatch.setattr(module, "loadPnvsRuntimeSettings", lambda path: expired)
    code, result = _invoke(module, args, monkeypatch, capsys)
    assert code == 0 and result["expired"] is True and result["attemptsUsed"] == 0
    assert all(item.writes == 0 for item in made)


def test_missing_confirmation_and_duplicate_input_never_construct_database(
    scenario: tuple[ModuleType, list[str], list[Database], PnvsRuntimeSettings],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module, args, made, _ = scenario
    monkeypatch.setattr(module.sys, "stdin", io.StringIO('{"resume_web":"x","resume_web":"y"}'))
    assert module.main(args) == 1
    assert json.loads(capsys.readouterr().out)["status"] == "budget_check_failed"
    code, _ = _invoke(module, [*args, "--apply-approved-budget"], monkeypatch, capsys)
    assert code == 1 and made == []


@pytest.mark.parametrize(
    "version", ["5.7.44", "8.0.21", "10.11.3-MariaDB", "8.0.46-TiDB", "unknown"]
)
def test_actual_server_version_is_checked_before_schema_and_write(
    scenario: tuple[ModuleType, list[str], list[Database], PnvsRuntimeSettings],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    version: str,
) -> None:
    module, args, made, _ = scenario
    original = module.MySqlAccountDatabase

    def construct(config: MySqlConfig) -> Database:
        database: Database = original(config)
        database.version = version
        return database

    monkeypatch.setattr(module, "MySqlAccountDatabase", construct)
    code, result = _invoke(module, args, monkeypatch, capsys, apply=True)
    assert code == 1 and result["status"] == "unsupported_mysql_version"
    assert len(made) == 1 and made[0].validated == 0 and made[0].writes == 0 and made[0].closed


@pytest.mark.parametrize("version", ["8.0.22", "8.0.46", "8.0.36-aliyun", "8.4.0"])
def test_shared_lock_supported_mysql_version_does_not_change_policy(
    scenario: tuple[ModuleType, list[str], list[Database], PnvsRuntimeSettings],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    version: str,
) -> None:
    module, args, made, _ = scenario
    original = module.MySqlAccountDatabase

    def construct(config: MySqlConfig) -> Database:
        database: Database = original(config)
        database.version = version
        return database

    monkeypatch.setattr(module, "MySqlAccountDatabase", construct)
    code, result = _invoke(module, args, monkeypatch, capsys, apply=True)
    assert code == 0 and result["status"] == "approved_policy_verified"
    assert sum(item.writes for item in made) == 1
