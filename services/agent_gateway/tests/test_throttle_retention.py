from __future__ import annotations

import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path
from threading import Barrier

import pytest

import agent_gateway.account_retention as retention
from agent_gateway.account_lifecycle import (
    AccountLifecycleService,
    FakeSmsSender,
    IdentityActionError,
)
from agent_gateway.account_retention_schema import migrateSqliteRetentionSchema
from agent_gateway.account_storage import SqliteAccountDatabase, SqliteAccountStore
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import (
    IDENTITY_RATE_LIMITS,
    AccountService,
    FakePhoneOwnershipVerifier,
    toUtcText,
)
from agent_gateway.lifecycle_storage import SqliteLifecycleStore
from agent_gateway.privilege_schema import migrateSqlitePrivilegeSchema
from agent_gateway.recovery_schema import migrateSqliteRecoverySchema
from agent_gateway.sms_budget import SmsBudgetLedger, SmsBudgetPolicy

NOW = datetime(2026, 10, 21, 8, tzinfo=UTC)
PHONE = "+155500029066"


def database(tmp_path: Path) -> GatewayDatabase:
    db = GatewayDatabase(tmp_path / "synthetic-throttle.sqlite")
    db.initialize()
    migrateSqlitePrivilegeSchema(db)
    migrateSqliteRecoverySchema(db)
    migrateSqliteRetentionSchema(db)
    return db


def add(db: GatewayDatabase, bucket: str, start: datetime) -> None:
    with db.immediateTransaction() as connection:
        connection.execute(
            "INSERT INTO identity_rate_limits VALUES (?,?,?)", (bucket, toUtcText(start), 8)
        )


def test_window_start_six_hours_is_earlier_than_end_deadline_and_keeps_active_buckets(
    tmp_path: Path,
) -> None:
    db = database(tmp_path)
    boundary = NOW - timedelta(hours=6)
    add(db, "a" * 64, boundary)
    add(db, "b" * 64, boundary + timedelta(microseconds=1))
    add(db, "c" * 64, NOW - timedelta(minutes=30))
    worker = retention.AccountRetentionWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    assert max(seconds for _, seconds in IDENTITY_RATE_LIMITS.values()) == 3600
    assert worker.purgeExpiredThrottles().deletedRecords == 1
    assert worker.purgeExpiredThrottles().deletedRecords == 0
    with db.readConnection() as connection:
        assert (
            connection.execute("SELECT SUM(attempts) FROM identity_rate_limits").fetchone()[0] == 16
        )
    assert worker.purgeExpiredThrottles(lookAheadSeconds=300).deletedRecords == 1
    with db.readConnection() as connection:
        assert (
            connection.execute("SELECT bucket_hash FROM identity_rate_limits").fetchone()[0]
            == "c" * 64
        )


@pytest.mark.parametrize("action", list(IDENTITY_RATE_LIMITS))
def test_all_real_action_windows_remain_blocked_until_window_ends(
    tmp_path: Path, action: str
) -> None:
    db = database(tmp_path)
    service = AccountLifecycleService(
        AccountService(SqliteAccountStore(db), FakePhoneOwnershipVerifier()),
        FakeSmsSender(),
        otpSecret=b"synthetic-throttle-retention-secret-32",
        store=SqliteLifecycleStore(db),
    )
    maximum, seconds = IDENTITY_RATE_LIMITS[action]
    for _ in range(maximum):
        service.chargeRate(action, PHONE, "synthetic-peer", nowUtc=NOW)
    worker = retention.AccountRetentionWorker(
        SqliteAccountDatabase(db), clock=lambda: NOW + timedelta(seconds=seconds - 1)
    )
    assert worker.purgeExpiredThrottles(lookAheadSeconds=300).deletedRecords == 0
    with pytest.raises(IdentityActionError, match="identity_rate_limited"):
        service.chargeRate(
            action, PHONE, "synthetic-peer", nowUtc=NOW + timedelta(seconds=seconds - 1)
        )
    service.chargeRate(action, PHONE, "synthetic-peer", nowUtc=NOW + timedelta(seconds=seconds))


def test_concurrent_cleanup_and_new_attempt_preserve_new_window(tmp_path: Path) -> None:
    db = database(tmp_path)
    bucket = "a" * 64
    add(db, bucket, NOW - timedelta(hours=7))
    barrier = Barrier(2)

    def sweep() -> None:
        barrier.wait(timeout=10)
        retention.AccountRetentionWorker(
            SqliteAccountDatabase(db), clock=lambda: NOW
        ).purgeExpiredThrottles()

    def charge() -> None:
        barrier.wait(timeout=10)
        with SqliteLifecycleStore(db).transaction() as connection:
            assert (
                connection.chargeRate(
                    bucket, toUtcText(NOW), toUtcText(NOW - timedelta(seconds=60))
                )
                == 1
            )

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(sweep), executor.submit(charge)]
        for future in futures:
            future.result(timeout=15)
    with db.readConnection() as connection:
        row = connection.execute(
            "SELECT window_start_utc,attempts FROM identity_rate_limits"
        ).fetchone()
        assert tuple(row) == (toUtcText(NOW), 1)


def test_future_long_window_fails_closed_and_pagination_advances(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    db = database(tmp_path)
    for i in range(101):
        add(db, f"{i:064x}", NOW - timedelta(hours=7))
    worker = retention.AccountRetentionWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    first = worker.purgeExpiredThrottles()
    assert first.deletedRecords == 100 and first.moreCandidates and first.nextRecordId is not None
    assert worker.purgeExpiredThrottles(afterBucketHash=first.nextRecordId).deletedRecords == 1
    add(db, "f" * 64, NOW - timedelta(hours=7))
    monkeypatch.setattr(retention, "IDENTITY_RATE_LIMITS", {"future": (1, 6 * 3600)})
    with pytest.raises(ValueError, match="throttle_window_retention_incompatible"):
        worker.purgeExpiredThrottles()
    with db.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM identity_rate_limits").fetchone()[0] == 1


def test_throttle_sweep_does_not_delete_sms_budget_or_attempt_ledger(tmp_path: Path) -> None:
    db = database(tmp_path)
    ledgerPhone = "+8613800000000"
    ledger = SmsBudgetLedger(
        SqliteAccountDatabase(db),
        SmsBudgetPolicy(2, 12, 6, NOW + timedelta(days=1), frozenset({ledgerPhone})),
        auditSecret=b"synthetic-throttle-budget-secret-32",
    )
    ledger.createApprovedPolicy(nowUtc=NOW)
    ledger.reserve(
        "challenge-00000000-0000-4000-8000-000000000001", ledgerPhone, "register", nowUtc=NOW
    )
    add(db, "a" * 64, NOW - timedelta(hours=7))
    assert (
        retention.AccountRetentionWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
        .purgeExpiredThrottles()
        .deletedRecords
        == 1
    )
    with db.readConnection() as connection:
        assert tuple(
            connection.execute("SELECT attempts,reserved_cents FROM sms_send_budget").fetchone()
        ) == (1, 6)
        assert connection.execute("SELECT COUNT(*) FROM sms_send_attempts").fetchone()[0] == 1


def test_cli_read_only_then_explicit_cleanup(tmp_path: Path) -> None:
    db = database(tmp_path)
    add(db, "a" * 64, datetime.now(UTC) - timedelta(hours=7))
    root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment.update(
        GATEWAY_DATABASE_BACKEND="sqlite",
        AGENT_GATEWAY_TASK018_DATABASE_PATH=str(db.databasePath),
        PYTHONPATH=str(root / "src"),
    )
    command = [sys.executable, str(root / "scripts/manage_account_retention.py"), "purge-throttles"]
    dry = subprocess.run(command, env=environment, capture_output=True, check=False)  # noqa: S603
    assert dry.returncode == 0 and json.loads(dry.stdout)["dueThrottleBuckets"] == 1
    denied = subprocess.run(  # noqa: S603
        command + ["--apply"], env=environment, capture_output=True, check=False
    )
    assert denied.returncode == 1
    applied = subprocess.run(  # noqa: S603
        command + ["--apply", "--confirmed-target"],
        env=environment,
        capture_output=True,
        check=False,
    )
    result = json.loads(applied.stdout)
    assert applied.returncode == 0 and result["deletedThrottleBuckets"] == 1
    assert result["maximumHoursFromWindowStart"] == 6
