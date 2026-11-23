from __future__ import annotations

from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import cast

import pytest

from agent_gateway import mysql_bootstrap as bootstrap
from agent_gateway.account_storage import AccountSqlConnection, UnknownStorageCommitError
from agent_gateway.database import UnsupportedDatabaseSchemaError
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig


class SyntheticConnection:
    def __init__(self, *, user: str = "manager@localhost") -> None:
        self.user = user
        self.server = "synthetic-server"
        self.database = "synthetic_bootstrap"
        self.tables: dict[str, int] = {}
        self.objects = 0
        self.wholeSchemaRead = 1
        self.lock = 1
        self.release = 1
        self.sql: list[tuple[str, tuple[object, ...]]] = []
        self.digests: list[tuple[object, ...]] = []
        self.failDdlAt: int | None = None

    def fetchOne(
        self, sql: str, parameters: tuple[object, ...] = ()
    ) -> Mapping[str, object] | None:
        if "CURRENT_USER() AS effective_user" in sql:
            return {
                "selected_database": self.database,
                "effective_user": self.user,
                "server_identity": self.server,
            }
        if "schema_privileges" in sql:
            return {"count": self.wholeSchemaRead}
        if "GET_LOCK" in sql:
            return {"acquired": self.lock}
        if "RELEASE_LOCK" in sql:
            return {"released": self.release}
        if "information_schema.tables" in sql:
            return {
                "count": int(str(parameters[0]) in self.tables) if parameters else len(self.tables)
            }
        if any(f"information_schema.{item}" in sql for item in ("routines", "triggers", "events")):
            return {"count": self.objects}
        if sql.startswith("SELECT COUNT(*) AS count FROM "):
            return {"count": self.tables[sql.rsplit(" ", 1)[-1]]}
        raise AssertionError(sql)

    def fetchMany(
        self, sql: str, parameters: tuple[object, ...] = (), *, maximumRows: int
    ) -> tuple[Mapping[str, object], ...]:
        raise AssertionError("unneeded row read")

    def execute(self, sql: str, parameters: tuple[object, ...] = ()) -> int:
        self.sql.append((sql, parameters))
        if sql.startswith("CREATE TABLE"):
            self.tables[sql.split()[5]] = 0
            if self.failDdlAt == len(self.tables):
                raise RuntimeError("synthetic interrupted DDL with sensitive detail")
        elif sql.startswith("INSERT INTO gateway_schema_migrations"):
            self.digests.append(parameters)
        else:
            raise AssertionError("Business-data writes are forbidden")
        return 1


class SyntheticDatabase:
    def __init__(self, connection: SyntheticConnection) -> None:
        self.connection = connection
        self.failCommit = False
        self.transactions = 0

    @contextmanager
    def transaction(self) -> Iterator[AccountSqlConnection]:
        self.transactions += 1
        yield self.connection
        if self.failCommit:
            raise UnknownStorageCommitError("synthetic secret")

    def readConnection(self) -> Iterator[AccountSqlConnection]:
        raise AssertionError("use contextmanager binding below")


def pair(monkeypatch: pytest.MonkeyPatch) -> tuple[SyntheticDatabase, SyntheticDatabase]:
    business = SyntheticDatabase(SyntheticConnection(user="business@localhost"))
    management = SyntheticDatabase(SyntheticConnection())
    # Same synthetic schema; separate effective identities and transactional contexts.
    business.connection.tables = management.connection.tables
    monkeypatch.setattr(SyntheticDatabase, "readConnection", SyntheticDatabase.transaction)
    monkeypatch.setattr(bootstrap, "_validateMySqlBase", lambda c, *, tableCount: None)
    monkeypatch.setattr(bootstrap, "_validateMySqlGrantTable", lambda c: None)
    monkeypatch.setattr(bootstrap, "validateMySqlPrivilegeSchema", lambda c: None)
    return business, management


def apply(business: SyntheticDatabase, management: SyntheticDatabase) -> bootstrap.BootstrapPlan:
    return bootstrap.prepareEmptySchema(
        cast(MySqlAccountDatabase, business),
        cast(MySqlAccountDatabase, management),
        expectedDatabase="synthetic_bootstrap",
        confirmedQuiescent=True,
        confirmedDedicatedEmpty=True,
    )


def test_empty_preparation_only_writes_versioned_ddl_and_six_markers(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    business, management = pair(monkeypatch)
    assert bootstrap.inspectSchema(business.connection).state == "empty"
    assert not management.connection.sql
    assert apply(business, management).state == "schema_verified"
    assert len(management.connection.tables) == 17
    assert [sql for sql, _ in management.connection.sql[:17]] == list(bootstrap.DDL)
    assert management.connection.digests == list(enumerate(bootstrap.DIGESTS, 1))
    before = list(management.connection.sql)
    assert apply(business, management).state == "schema_verified"
    assert management.connection.sql == before


@pytest.mark.parametrize("quiescent,dedicated", [(False, True), (True, False), (False, False)])
def test_public_preparation_api_also_requires_confirmations_before_connecting(
    monkeypatch: pytest.MonkeyPatch,
    quiescent: bool,
    dedicated: bool,
) -> None:
    business, management = pair(monkeypatch)
    with pytest.raises(bootstrap.BootstrapRejectedError, match="confirmations"):
        bootstrap.prepareEmptySchema(
            cast(MySqlAccountDatabase, business),
            cast(MySqlAccountDatabase, management),
            expectedDatabase="synthetic_bootstrap",
            confirmedQuiescent=quiescent,
            confirmedDedicatedEmpty=dedicated,
        )
    assert business.transactions == management.transactions == 0


@pytest.mark.parametrize("nonempty", [False, True])
def test_partial_schema_rejects_before_any_ddl(
    monkeypatch: pytest.MonkeyPatch,
    nonempty: bool,
) -> None:
    business, management = pair(monkeypatch)
    management.connection.tables["accounts"] = int(nonempty)
    with pytest.raises(bootstrap.BootstrapRejectedError, match="partial_") as captured:
        apply(business, management)
    assert captured.value.visibleTables == 1
    assert str(captured.value) == (
        "partial_nonempty_schema" if nonempty else "partial_or_foreign_schema"
    )
    assert not management.connection.sql


@pytest.mark.parametrize(
    "field,value",
    [
        ("user", "business@localhost"),
        ("server", "different-server"),
        ("database", "other_database"),
        ("wholeSchemaRead", 0),
        ("lock", 0),
        ("objects", 1),
    ],
)
def test_runtime_identity_schema_and_serialization_gates(
    monkeypatch: pytest.MonkeyPatch,
    field: str,
    value: object,
) -> None:
    business, management = pair(monkeypatch)
    setattr(management.connection, field, value)
    with pytest.raises(bootstrap.BootstrapRejectedError):
        apply(business, management)
    assert not management.connection.sql


def test_full_v6_validator_failure_cannot_be_treated_as_valid(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    business, management = pair(monkeypatch)
    management.connection.tables.update(dict.fromkeys(bootstrap.KNOWN_TABLES, 0))

    def fail(c: AccountSqlConnection) -> None:
        raise UnsupportedDatabaseSchemaError("private-detail")

    monkeypatch.setattr(bootstrap, "validateMySqlPrivilegeSchema", fail)
    with pytest.raises(bootstrap.BootstrapRejectedError, match="schema_mismatch"):
        apply(business, management)
    assert not management.connection.sql


@pytest.mark.parametrize("failure", ["ddl", "validation", "commit", "release"])
def test_unknown_outcome_is_never_retried_and_partial_state_is_preserved(
    monkeypatch: pytest.MonkeyPatch,
    failure: str,
) -> None:
    business, management = pair(monkeypatch)
    if failure == "ddl":
        management.connection.failDdlAt = 2
    elif failure == "validation":

        def fail(c: AccountSqlConnection, *, tableCount: int) -> None:
            raise UnsupportedDatabaseSchemaError("private validation detail")

        monkeypatch.setattr(bootstrap, "_validateMySqlBase", fail)
    elif failure == "commit":
        management.failCommit = True
    else:
        management.connection.release = 0
    with pytest.raises(UnknownStorageCommitError, match="bootstrap_outcome_unknown"):
        apply(business, management)
    assert management.transactions == 1
    assert len(management.connection.tables) == (2 if failure == "ddl" else 17)
    assert all(not sql.startswith(("DROP ", "DELETE ")) for sql, _ in management.connection.sql)
    if failure == "ddl":
        before = list(management.connection.sql)
        with pytest.raises(bootstrap.BootstrapRejectedError, match="partial"):
            apply(business, management)
        assert management.connection.sql == before


def test_target_confirmation_is_exact_and_distinct_identity_is_required(tmp_path: Path) -> None:
    ca = tmp_path / "synthetic-ca.pem"
    ca.write_text("synthetic-only")
    config = MySqlConfig(
        "synthetic.local",
        3306,
        "synthetic_bootstrap",
        "business",
        "secret",
        ca,
        datetime.now(UTC) + timedelta(days=1),
    )
    management = replace(config, user="manager")
    kwargs = {
        "expectedHost": "SYNTHETIC.local",
        "expectedPort": 3306,
        "expectedDatabase": "synthetic_bootstrap",
        "confirmedQuiescent": True,
        "confirmedDedicatedEmpty": True,
    }
    bootstrap.validateTarget(config, management, **kwargs)  # type: ignore[arg-type]
    for candidate in (
        config,
        replace(management, host="other.local"),
        replace(management, port=3307),
        replace(management, database="other"),
    ):
        with pytest.raises(bootstrap.BootstrapRejectedError):
            bootstrap.validateTarget(config, candidate, **kwargs)  # type: ignore[arg-type]
    for key in ("confirmedQuiescent", "confirmedDedicatedEmpty"):
        with pytest.raises(bootstrap.BootstrapRejectedError, match="confirmations"):
            bootstrap.validateTarget(config, management, **{**kwargs, key: False})  # type: ignore[arg-type]
