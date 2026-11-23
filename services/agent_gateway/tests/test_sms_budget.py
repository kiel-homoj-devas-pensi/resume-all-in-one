from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import pytest

from agent_gateway.account_storage import (
    AccountSqlConnection,
    SqliteAccountDatabase,
    StorageUnavailableError,
    UnknownStorageCommitError,
)
from agent_gateway.database import GatewayDatabase
from agent_gateway.sms_budget import (
    SmsAttemptReplayError,
    SmsBudgetExceededError,
    SmsBudgetLedger,
    SmsBudgetPolicy,
)

NOW = datetime(2026, 10, 11, tzinfo=UTC)
PHONE = "+8613800000000"
SECRET = b"synthetic-sms-ledger-secret-32-bytes"


def policy(*, maximum: int = 2, budget: int = 12) -> SmsBudgetPolicy:
    return SmsBudgetPolicy(maximum, budget, 6, NOW + timedelta(days=1), frozenset({PHONE}))


def challenge() -> str:
    return "challenge-" + str(uuid4())


def fixture(path: Path) -> tuple[GatewayDatabase, SmsBudgetLedger]:
    database = GatewayDatabase(path)
    database.initialize()
    ledger = SmsBudgetLedger(SqliteAccountDatabase(database), policy(), auditSecret=SECRET)
    ledger.createApprovedPolicy(nowUtc=NOW)
    return database, ledger


def counters(database: GatewayDatabase) -> tuple[int, int, int]:
    with database.readConnection() as connection:
        row = connection.execute("SELECT attempts, reserved_cents FROM sms_send_budget").fetchone()
        count = connection.execute("SELECT COUNT(*) FROM sms_send_attempts").fetchone()[0]
        return int(row[0]), int(row[1]), int(count)


def test_unapproved_budget_is_not_created_by_startup_or_reservation(tmp_path: Path) -> None:
    database = GatewayDatabase(tmp_path / "budget.db")
    database.initialize()
    ledger = SmsBudgetLedger(SqliteAccountDatabase(database), policy(), auditSecret=SECRET)
    with pytest.raises(ValueError, match="not_approved"):
        ledger.assertApprovedPolicy()
    with pytest.raises(ValueError, match="not_approved"):
        ledger.reserve(challenge(), PHONE, "register", nowUtc=NOW)
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM sms_send_budget").fetchone()[0] == 0


@pytest.mark.parametrize("outcome", ["accepted", "rejected", "unknown"])
def test_every_outcome_keeps_count_and_cost_across_restart_and_repeat_approval(
    tmp_path: Path, outcome: str
) -> None:
    database, ledger = fixture(tmp_path / "budget.db")
    attempt = challenge()
    ledger.reserve(attempt, PHONE, "register", nowUtc=NOW)
    # 保留合法字面值类型，测试各终态不返还额度。
    if outcome == "accepted":
        ledger.finalize(attempt, "accepted", requestIdDigest="a" * 64, nowUtc=NOW)
    elif outcome == "rejected":
        ledger.finalize(attempt, "rejected", nowUtc=NOW)
    else:
        ledger.finalize(attempt, "unknown", nowUtc=NOW)
    restarted = SmsBudgetLedger(SqliteAccountDatabase(database), policy(), auditSecret=SECRET)
    restarted.createApprovedPolicy(nowUtc=NOW)
    restarted.assertApprovedPolicy()
    assert counters(database) == (1, 6, 1)
    with pytest.raises(SmsAttemptReplayError):
        restarted.reserve(attempt, PHONE, "register", nowUtc=NOW)
    restarted.reserve(challenge(), PHONE, "resetPassword", nowUtc=NOW)
    with pytest.raises(SmsBudgetExceededError):
        restarted.reserve(challenge(), PHONE, "register", nowUtc=NOW)
    assert counters(database) == (2, 12, 2)
    with database.readConnection() as connection:
        text = str([tuple(row) for row in connection.execute("SELECT * FROM sms_send_attempts")])
    assert PHONE not in text
    assert "123456" not in text


def _processReserve(path: str, attempt: str) -> bool:
    ledger = SmsBudgetLedger(
        SqliteAccountDatabase(GatewayDatabase(Path(path))), policy(), auditSecret=SECRET
    )
    try:
        ledger.reserve(attempt, PHONE, "register", nowUtc=NOW)
        return True
    except SmsBudgetExceededError, SmsAttemptReplayError:
        return False


@pytest.mark.parametrize("sameChallenge", [False, True])
def test_independent_processes_cannot_send_twice_or_take_last_slot_twice(
    tmp_path: Path, sameChallenge: bool
) -> None:
    database, ledger = fixture(tmp_path / "budget.db")
    ledger.reserve(challenge(), PHONE, "register", nowUtc=NOW)
    first = challenge()
    with ProcessPoolExecutor(max_workers=2) as workers:
        tasks = [
            workers.submit(_processReserve, str(database.databasePath), first),
            workers.submit(
                _processReserve, str(database.databasePath), first if sameChallenge else challenge()
            ),
        ]
        results = [task.result(timeout=20) for task in tasks]
    assert sorted(results) == [False, True]
    assert counters(database) == (2, 12, 2)


def test_cost_limit_is_enforced_before_maximum_attempts(tmp_path: Path) -> None:
    database = GatewayDatabase(tmp_path / "budget.db")
    database.initialize()
    ledger = SmsBudgetLedger(
        SqliteAccountDatabase(database), policy(maximum=10, budget=11), auditSecret=SECRET
    )
    ledger.createApprovedPolicy(nowUtc=NOW)
    ledger.reserve(challenge(), PHONE, "register", nowUtc=NOW)
    with pytest.raises(SmsBudgetExceededError):
        ledger.reserve(challenge(), PHONE, "register", nowUtc=NOW)
    assert counters(database) == (1, 6, 1)


class LostCommitDatabase(SqliteAccountDatabase):
    @contextmanager
    def transaction(self) -> Iterator[AccountSqlConnection]:
        with super().transaction() as connection:
            yield connection
        raise UnknownStorageCommitError("synthetic lost commit acknowledgement")


def test_unknown_reservation_commit_gives_no_qualification_and_keeps_original_slot(
    tmp_path: Path,
) -> None:
    database, _ = fixture(tmp_path / "budget.db")
    lost = SmsBudgetLedger(LostCommitDatabase(database), policy(), auditSecret=SECRET)
    attempt = challenge()
    with pytest.raises(UnknownStorageCommitError):
        lost.reserve(attempt, PHONE, "register", nowUtc=NOW)
    assert counters(database) == (1, 6, 1)
    recovered = SmsBudgetLedger(SqliteAccountDatabase(database), policy(), auditSecret=SECRET)
    with pytest.raises(SmsAttemptReplayError):
        recovered.reserve(attempt, PHONE, "register", nowUtc=NOW)


def test_failed_counter_update_rolls_back_attempt_insert_and_budget(tmp_path: Path) -> None:
    database, ledger = fixture(tmp_path / "budget.db")
    with database.immediateTransaction() as connection:
        connection.execute(
            "CREATE TRIGGER fail_budget BEFORE UPDATE ON sms_send_budget "
            "BEGIN SELECT RAISE(ABORT, 'synthetic budget fault'); END"
        )
    with pytest.raises(StorageUnavailableError):
        ledger.reserve(challenge(), PHONE, "register", nowUtc=NOW)
    assert counters(database) == (0, 0, 0)


def test_inconsistent_counters_fail_closed_without_reset_or_new_attempt(tmp_path: Path) -> None:
    database, ledger = fixture(tmp_path / "budget.db")
    ledger.reserve(challenge(), PHONE, "register", nowUtc=NOW)
    with database.immediateTransaction() as connection:
        connection.execute("UPDATE sms_send_budget SET attempts = 0, reserved_cents = 0")
    with pytest.raises(ValueError, match="inconsistent"):
        ledger.reserve(challenge(), PHONE, "register", nowUtc=NOW)
    assert counters(database) == (0, 0, 1)


@pytest.mark.parametrize(
    "changedField", ["maximum", "budget", "unit", "expiry", "phones", "secret"]
)
def test_configuration_changes_cannot_silently_create_another_budget(
    tmp_path: Path, changedField: str
) -> None:
    database, ledger = fixture(tmp_path / "budget.db")
    ledger.reserve(challenge(), PHONE, "register", nowUtc=NOW)
    configured = policy()
    secret = SECRET
    if changedField == "maximum":
        configured = replace(configured, maximumAttempts=3)
    elif changedField == "budget":
        configured = replace(configured, budgetCents=18)
    elif changedField == "unit":
        configured = replace(configured, reservePerAttemptCents=7)
    elif changedField == "expiry":
        configured = replace(configured, expiresAtUtc=NOW + timedelta(days=2))
    elif changedField == "phones":
        configured = replace(configured, allowedPhones=frozenset({"+8613900000000"}))
    else:
        secret = b"different-synthetic-audit-secret-32-bytes"
    changed = SmsBudgetLedger(SqliteAccountDatabase(database), configured, auditSecret=secret)
    with pytest.raises(ValueError, match="policy_mismatch"):
        changed.createApprovedPolicy(nowUtc=NOW)
    assert counters(database) == (1, 6, 1)


@pytest.mark.parametrize("unit", [0, 1, 5])
def test_under_reserved_price_cannot_enable_an_approved_policy(unit: int) -> None:
    with pytest.raises(ValueError, match="invalid_sms_budget_policy"):
        replace(policy(), reservePerAttemptCents=unit)


def test_expired_policy_and_unlisted_recipient_do_not_get_a_slot(tmp_path: Path) -> None:
    database, ledger = fixture(tmp_path / "budget.db")
    with pytest.raises(ValueError, match="not_allowed"):
        ledger.reserve(challenge(), "+8613900000000", "register", nowUtc=NOW)
    with pytest.raises(SmsBudgetExceededError):
        ledger.reserve(challenge(), PHONE, "register", nowUtc=NOW + timedelta(days=1))
    assert counters(database) == (0, 0, 0)


def test_competing_finalization_keeps_one_terminal_outcome_and_never_refunds(
    tmp_path: Path,
) -> None:
    database, ledger = fixture(tmp_path / "budget.db")
    attempt = challenge()
    ledger.reserve(attempt, PHONE, "register", nowUtc=NOW)

    def finalize(accepted: bool) -> bool:
        independent = SmsBudgetLedger(SqliteAccountDatabase(database), policy(), auditSecret=SECRET)
        try:
            independent.finalize(attempt, "accepted" if accepted else "unknown", nowUtc=NOW)
            return True
        except ValueError:
            return False

    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(finalize, [True, False]))
    assert sorted(results) == [False, True]
    assert counters(database) == (1, 6, 1)
    with pytest.raises(ValueError, match="invalid_sms_outcome"):
        ledger.finalize(attempt, "accepted", requestIdDigest=PHONE, nowUtc=NOW)


def test_v4_upgrade_preserves_old_rows_and_migration_records(tmp_path: Path) -> None:
    database, _ = fixture(tmp_path / "old.db")
    with database.immediateTransaction() as connection:
        connection.execute("DROP TABLE sms_send_attempts")
        connection.execute("DROP TABLE sms_send_budget")
        connection.execute("DELETE FROM schema_migrations WHERE version = 5")
        connection.execute("PRAGMA user_version = 4")
        connection.execute(
            "INSERT INTO identity_rate_limits VALUES ('synthetic-old-bucket', 'old', 3)"
        )
        original = [tuple(row) for row in connection.execute("SELECT * FROM schema_migrations")]
    database.initialize()
    database.initialize()
    with database.readConnection() as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 5
        assert [
            tuple(row)
            for row in connection.execute("SELECT * FROM schema_migrations WHERE version < 5")
        ] == original
        assert connection.execute("SELECT attempts FROM identity_rate_limits").fetchone()[0] == 3
        assert connection.execute("SELECT COUNT(*) FROM sms_send_budget").fetchone()[0] == 0


def test_v4_upgrade_failure_rolls_back_ddl_without_recording_v5(tmp_path: Path) -> None:
    database = GatewayDatabase(tmp_path / "old.db")
    database.initialize()
    with database.immediateTransaction() as connection:
        connection.execute("DROP TABLE sms_send_attempts")
        connection.execute("DROP TABLE sms_send_budget")
        connection.execute("DELETE FROM schema_migrations WHERE version = 5")
        connection.execute("PRAGMA user_version = 4")
        connection.execute("CREATE TABLE sms_send_attempts (wrong TEXT)")
    with pytest.raises(sqlite3.OperationalError):
        database.initialize()
    with database.readConnection() as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 4
        assert (
            connection.execute(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 5"
            ).fetchone()[0]
            == 0
        )
        assert (
            connection.execute(
                "SELECT name FROM sqlite_schema WHERE name = 'sms_send_budget'"
            ).fetchone()
            is None
        )
