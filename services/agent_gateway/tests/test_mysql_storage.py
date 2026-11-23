from collections.abc import Mapping
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path
from threading import Event
from typing import Any

import pymysql
import pytest

from agent_gateway.account_storage import (
    AccountAlreadyExistsError,
    StorageUnavailableError,
    UnknownStorageCommitError,
)
from agent_gateway.database import UnsupportedDatabaseSchemaError
from agent_gateway.mysql_schema import migrateSyntheticSchema
from agent_gateway.mysql_storage import (
    MySqlAccountDatabase,
    MySqlAccountStore,
    MySqlConfig,
    connectMySql,
)


class FakeDriver:
    """只检验驱动调用与故障分支，不实现或冒充 MySQL 锁语义。"""

    def __init__(self) -> None:
        self.statements: list[tuple[str, tuple[object, ...]]] = []
        self.rows: list[Mapping[str, object] | None] = []
        self.executeError: Exception | None = None
        self.commitError: Exception | None = None
        self.rollbackError: Exception | None = None
        self.commits = 0
        self.rollbacks = 0
        self.closed = False
        self.cursorCloses = 0

    def cursor(self) -> FakeDriver:
        return self

    def begin(self) -> None:
        return None

    def execute(self, sql: str, parameters: tuple[object, ...]) -> int:
        self.statements.append((sql, parameters))
        if self.executeError:
            raise self.executeError
        return 1

    def fetchone(self) -> Mapping[str, object] | None:
        return self.rows.pop(0) if self.rows else None

    def fetchmany(self, size: int) -> tuple[Mapping[str, object], ...]:
        rows = tuple(row for row in self.rows[:size] if row is not None)
        del self.rows[:size]
        return rows

    def commit(self) -> None:
        self.commits += 1
        if self.commitError:
            raise self.commitError

    def rollback(self) -> None:
        self.rollbacks += 1
        if self.rollbackError:
            raise self.rollbackError

    def close(self) -> None:
        # 真实驱动的 cursor 与 connection 是不同对象，测试在工厂中分别包装。
        self.cursorCloses += 1


class FakeConnection:
    def __init__(self, driver: FakeDriver) -> None:
        self.driver = driver

    def cursor(self) -> FakeDriver:
        return self.driver

    def begin(self) -> None:
        self.driver.begin()

    def commit(self) -> None:
        self.driver.commit()

    def rollback(self) -> None:
        self.driver.rollback()

    def close(self) -> None:
        self.driver.closed = True


@pytest.fixture
def config(tmp_path: Path) -> MySqlConfig:
    ca = tmp_path / "synthetic-ca.pem"
    ca.write_text("not a real certificate; connector is fake")
    return MySqlConfig.fromDsn(
        "mysql://synthetic-user:private-password@db.invalid:3306/synthetic",
        ca,
        "2099-01-01T00:00:00Z",
    )


@pytest.mark.parametrize(
    "dsn",
    [
        "sqlite://synthetic",
        "mysql://u:p@host/db?tls=false",
        "mysql://u:p@host/db#secret",
        "mysql://u:p@host:bad/db",
        "mysql://u:p@host/db/other",
        "mysql://host/db",
    ],
)
def test_bad_dsn_errors_do_not_expose_input(config: MySqlConfig, dsn: str) -> None:
    with pytest.raises(ValueError) as error:
        MySqlConfig.fromDsn(dsn, config.caFile, "2099-01-01T00:00:00Z")
    assert dsn not in str(error.value)
    assert error.value.__suppress_context__


def test_expiry_ca_pool_and_repr_fail_closed(config: MySqlConfig) -> None:
    assert "private-password" not in repr(config)
    assert "synthetic-user" not in repr(config)
    with pytest.raises(ValueError):
        replace(config, caFile=config.caFile.with_name("missing.pem"))
    with pytest.raises(ValueError):
        replace(config, poolSize=5)
    with pytest.raises(ValueError):
        replace(config, poolWaitSeconds=float("nan"))
    with pytest.raises(ValueError):
        MySqlConfig.fromDsn("mysql://u:p@host/db", config.caFile, "2099-01-01T00:00:00")
    with pytest.raises(StorageUnavailableError):
        replace(config, expiresAtUtc=datetime(2000, 1, 1, tzinfo=UTC))


def test_persistent_service_database_does_not_invent_subscription_expiry(
    config: MySqlConfig, monkeypatch: pytest.MonkeyPatch,
) -> None:
    from agent_gateway import mysql_storage

    persistent = MySqlConfig.fromDsn("mysql://u:p@host/db", config.caFile)
    assert persistent.expiresAtUtc is None

    class FutureClock(datetime):
        @classmethod
        def now(cls, tz: object = None) -> datetime:
            return datetime(2100, 1, 1, tzinfo=UTC)

    monkeypatch.setattr(mysql_storage, "datetime", FutureClock)
    persistent.checkExpiry()
    with pytest.raises(StorageUnavailableError):
        config.checkExpiry()


def test_driver_requires_certificate_hostname_and_bounded_timeouts(
    config: MySqlConfig,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    options: dict[str, object] = {}
    driver = FakeDriver()

    def connect(**kwargs: Any) -> FakeConnection:
        options.update(kwargs)
        return FakeConnection(driver)

    monkeypatch.setattr(pymysql, "connect", connect)
    connectMySql(config)
    assert options["ssl_verify_cert"] is True
    assert options["ssl_verify_identity"] is True
    assert options["ssl_ca"] == str(config.caFile)
    assert options["local_infile"] is False
    assert options["read_timeout"] == options["write_timeout"] == options["connect_timeout"] == 5


def test_mysql_binding_and_account_lock_prevent_stale_password_session(config: MySqlConfig) -> None:
    driver = FakeDriver()
    database = MySqlAccountDatabase(config, lambda _: FakeConnection(driver))
    store = MySqlAccountStore(database)
    driver.rows = [{"account_id": b"account-A", "password_hash": "old", "is_active": 1}]
    account = store.findAccount("+15550002901")
    assert account is not None and account.accountId == "account-A"
    driver.rows = [{"password_hash": "changed", "is_active": 1}]
    assert not store.issueSession("account-A", "old", "session", "hash", "expiry", "now")
    assert "FOR UPDATE" in driver.statements[-1][0]
    assert "?" not in driver.statements[-1][0]
    assert not any("INSERT INTO account_sessions" in sql for sql, _ in driver.statements)
    driver.rows = [{"password_hash": "changed", "is_active": 1}]
    assert store.issueSession("account-A", "changed", "session", "hash", "expiry", "now")
    assert driver.statements[-1][1] == ("session", "account-A", "hash", "expiry", "now")
    database.close()
    assert driver.closed


@pytest.mark.parametrize(
    "code,exception", [(1062, AccountAlreadyExistsError), (1452, StorageUnavailableError)]
)
def test_duplicate_and_other_integrity_failures_are_distinct_and_redacted(
    config: MySqlConfig,
    code: int,
    exception: type[Exception],
) -> None:
    driver = FakeDriver()
    driver.executeError = pymysql.IntegrityError(code, "private-password +15550002901")
    database = MySqlAccountDatabase(config, lambda _: FakeConnection(driver))
    with pytest.raises(exception) as error:
        MySqlAccountStore(database).insertAccount("account", "phone", "hash", "now")
    assert "private-password" not in str(error.value)
    assert driver.commits == 0 and driver.rollbacks == 1 and driver.closed


def test_unknown_commit_never_retries_and_next_call_uses_new_connection(
    config: MySqlConfig,
) -> None:
    first, second = FakeDriver(), FakeDriver()
    first.commitError = pymysql.OperationalError(2013, "private-password unknown commit")
    first.rollbackError = RuntimeError("rollback must not replace original failure")
    pending = [first, second]
    calls = 0

    def connect(_: MySqlConfig) -> FakeConnection:
        nonlocal calls
        calls += 1
        return FakeConnection(pending.pop(0))

    database = MySqlAccountDatabase(config, connect)
    store = MySqlAccountStore(database)
    with pytest.raises(UnknownStorageCommitError) as error:
        store.insertAccount("account", "phone", "hash", "now")
    assert "private-password" not in str(error.value)
    assert calls == 1 and first.commits == 1 and first.closed
    second.rows = [None]
    assert store.findAccount("phone") is None
    assert calls == 2
    database.close()


def test_pool_caps_concurrent_connections_and_timeout_does_not_connect(config: MySqlConfig) -> None:
    calls = 0
    entered = [Event(), Event()]
    release = Event()

    def connect(_: MySqlConfig) -> FakeConnection:
        nonlocal calls
        calls += 1
        return FakeConnection(FakeDriver())

    database = MySqlAccountDatabase(replace(config, poolSize=2, poolWaitSeconds=0.05), connect)

    def hold(index: int) -> None:
        with database.transaction():
            entered[index].set()
            assert release.wait(timeout=5)

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(hold, index) for index in range(2)]
        try:
            assert all(event.wait(timeout=5) for event in entered)
            with pytest.raises(StorageUnavailableError, match="等待超时"):
                with database.transaction():
                    pytest.fail("不得取得第三个连接")
            assert calls == 2
        finally:
            release.set()
        for future in futures:
            future.result()
    database.close()
    with pytest.raises(StorageUnavailableError, match="已关闭"):
        with database.transaction():
            pytest.fail("关闭后不得租借")


def test_unknown_schema_and_ddl_failure_never_mark_migration_success(config: MySqlConfig) -> None:
    driver = FakeDriver()
    database = MySqlAccountDatabase(config, lambda _: FakeConnection(driver))
    driver.rows = [{"version": 99}]
    with pytest.raises(UnsupportedDatabaseSchemaError):
        database.checkSchema()
    driver = FakeDriver()
    driver.executeError = pymysql.OperationalError(1142, "private-password DDL denied")
    database = MySqlAccountDatabase(config, lambda _: FakeConnection(driver))
    with pytest.raises(StorageUnavailableError):
        migrateSyntheticSchema(database)
    assert not any("INSERT INTO gateway_schema_migrations" in sql for sql, _ in driver.statements)
    assert driver.commits == 0
