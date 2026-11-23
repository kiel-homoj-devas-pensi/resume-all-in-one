import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path

import pytest

from agent_gateway.account_storage import SqliteAccountStore
from agent_gateway.app import createApplication
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import (
    AccountRegistrationUnavailableError,
    AccountService,
    AuthenticationFailedError,
    FakePhoneOwnershipVerifier,
)
from agent_gateway.settings import GatewaySettings
from agent_gateway.usage import UsagePolicyService

PHONE = "+15550002901"
PASSWORD = "Store029a!"
NOW = datetime(2026, 10, 10, tzinfo=UTC)


def serviceFor(path: Path) -> AccountService:
    database = GatewayDatabase(path)
    database.initialize()
    return AccountService(SqliteAccountStore(database), FakePhoneOwnershipVerifier())


def test_synthetic_cli_import_does_not_start_http_or_read_real_configuration() -> None:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("GATEWAY_", "AGENT_GATEWAY_"))
    }
    environment.update(GATEWAY_DATABASE_BACKEND="mysql", PYTHONPATH="src", PYTHONIOENCODING="utf-8")
    result = subprocess.run(
        [sys.executable, "scripts/run_mysql_synthetic_contract.py", "--synthetic-only"],
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    assert result.returncode == 0
    assert "SKIP" in result.stdout and "真实数据库验收未执行" in result.stdout
    assert not result.stderr


def test_two_connections_register_one_account_and_sessions_survive_restart(tmp_path: Path) -> None:
    path = tmp_path / "synthetic.db"
    services = [serviceFor(path), serviceFor(path)]

    def register(service: AccountService) -> str | None:
        try:
            return service.registerAccount(
                phoneE164=PHONE,
                password=PASSWORD,
                verificationProof=FakePhoneOwnershipVerifier.developmentProof,
            )
        except AccountRegistrationUnavailableError:
            return None

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(register, services))
    assert sum(value is not None for value in results) == 1
    session = services[0].createSession(phoneE164=PHONE, password=PASSWORD, nowUtc=NOW)
    restarted = serviceFor(path)
    assert (
        restarted.authenticateSession(session.sessionToken, nowUtc=NOW).accountId
        == session.accountId
    )
    restarted.revokeAllSessions(session.accountId, nowUtc=NOW)
    with pytest.raises(AuthenticationFailedError):
        services[1].authenticateSession(session.sessionToken, nowUtc=NOW)


def test_password_changed_after_verification_does_not_issue_session(tmp_path: Path) -> None:
    database = GatewayDatabase(tmp_path / "race.db")
    database.initialize()
    store = SqliteAccountStore(database)
    store.insertAccount("account-race", PHONE, "old-hash", "2026-10-10T00:00:00.000000Z")
    with database.immediateTransaction() as connection:
        connection.execute("UPDATE accounts SET password_hash = 'new-hash'")
    assert not store.issueSession(
        "account-race",
        "old-hash",
        "session-race",
        "a" * 64,
        "2026-11-09T00:00:00.000000Z",
        "2026-10-10T00:00:00.000000Z",
    )
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM account_sessions").fetchone()[0] == 0


def test_session_insert_failure_rolls_back_without_issuing_token(tmp_path: Path) -> None:
    database = GatewayDatabase(tmp_path / "rollback.db")
    database.initialize()
    store = SqliteAccountStore(database)
    store.insertAccount("account-test", PHONE, "hash", "2026-10-10T00:00:00.000000Z")
    with database.immediateTransaction() as connection:
        connection.execute(
            "CREATE TRIGGER deny_session BEFORE INSERT ON account_sessions "
            "BEGIN SELECT RAISE(ABORT, 'synthetic fault'); END"
        )
    from agent_gateway.account_storage import StorageUnavailableError

    with pytest.raises(StorageUnavailableError):
        store.issueSession(
            "account-test",
            "hash",
            "session-test",
            "a" * 64,
            "2026-11-09T00:00:00.000000Z",
            "2026-10-10T00:00:00.000000Z",
        )
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM account_sessions").fetchone()[0] == 0
        assert connection.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 1


def test_invalid_backend_and_mixed_configuration_fail_without_creating_sqlite(
    tmp_path: Path,
) -> None:
    path = tmp_path / "must-not-exist.db"
    with pytest.raises(ValueError):
        GatewaySettings(databaseBackend="other")  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        GatewaySettings(databaseBackend="mysql", task018DatabasePath=path)
    assert not path.exists()


def test_full_gateway_rejects_incomplete_mysql_configuration_without_sqlite_fallback(
    tmp_path: Path,
) -> None:
    ca = tmp_path / "ca.pem"
    ca.write_text("synthetic config only")
    settings = GatewaySettings(
        databaseBackend="mysql",
        databaseDsn="mysql://user:secret@db.invalid/synthetic",
        databaseTlsCaFile=ca,
        enableTask018FakeIdentity=True,
    )
    assert "secret" not in repr(settings)
    with pytest.raises(ValueError, match="到期配置"):
        createApplication(settings=settings)
    assert not (tmp_path / "gateway.db").exists()


def test_injected_account_and_usage_services_cannot_write_separate_databases(
    tmp_path: Path,
) -> None:
    accountDatabase = GatewayDatabase(tmp_path / "accounts.db")
    accountDatabase.initialize()
    usageDatabase = GatewayDatabase(tmp_path / "usage.db")
    usageDatabase.initialize()
    with pytest.raises(ValueError, match="权威数据库"):
        createApplication(
            settings=GatewaySettings(),
            accountService=AccountService(accountDatabase, FakePhoneOwnershipVerifier()),
            usagePolicy=UsagePolicyService(usageDatabase),
        )
    application = createApplication(
        settings=GatewaySettings(),
        accountService=AccountService(
            SqliteAccountStore(accountDatabase), FakePhoneOwnershipVerifier()
        ),
        usagePolicy=UsagePolicyService(accountDatabase),
    )
    assert application is not None
