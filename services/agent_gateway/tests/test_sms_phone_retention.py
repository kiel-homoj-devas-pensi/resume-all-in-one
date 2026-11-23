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

from agent_gateway.account_retention_schema import migrateSqliteRetentionSchema
from agent_gateway.account_storage import SqliteAccountDatabase, StorageUnavailableError
from agent_gateway.database import GatewayDatabase
from agent_gateway.privilege_schema import migrateSqlitePrivilegeSchema
from agent_gateway.recovery_schema import migrateSqliteRecoverySchema
from agent_gateway.sms_budget import SmsAttemptReplayError, SmsBudgetLedger, SmsBudgetPolicy
from agent_gateway.sms_phone_retention import SmsPhoneRetentionWorker

NOW = datetime(2026, 10, 21, 8, tzinfo=UTC)
OLD = NOW - timedelta(days=90)
PHONE = "+8613800000000"
SECRET = b"synthetic-phone-retention-ledger-secret-32"


def attempt(index: int) -> str:
    return f"challenge-00000000-0000-4000-8000-{index:012x}"


def fixture(tmp_path: Path, *, maximum: int = 5) -> tuple[GatewayDatabase, SmsBudgetLedger]:
    db = GatewayDatabase(tmp_path / "synthetic-sms.sqlite")
    db.initialize()
    migrateSqlitePrivilegeSchema(db)
    migrateSqliteRecoverySchema(db)
    migrateSqliteRetentionSchema(db)
    ledger = SmsBudgetLedger(SqliteAccountDatabase(db), policy(maximum), auditSecret=SECRET)
    ledger.createApprovedPolicy(nowUtc=OLD)
    return db, ledger


def policy(maximum: int = 5) -> SmsBudgetPolicy:
    return SmsBudgetPolicy(maximum, maximum * 6, 6, NOW + timedelta(days=1), frozenset({PHONE}))


@pytest.mark.parametrize("outcome", ["accepted", "rejected", "unknown", "reserved"])
def test_all_outcomes_keep_cost_replay_and_approval_after_phone_clear(
    tmp_path: Path, outcome: str
) -> None:
    db, ledger = fixture(tmp_path)
    ledger.reserve(attempt(1), PHONE, "register", nowUtc=OLD)
    if outcome == "accepted":
        ledger.finalize(attempt(1), "accepted", requestIdDigest="b" * 64, nowUtc=OLD)
    elif outcome == "rejected":
        ledger.finalize(attempt(1), "rejected", nowUtc=OLD)
    elif outcome == "unknown":
        ledger.finalize(attempt(1), "unknown", nowUtc=OLD)
    unchangedFields = (
        "SELECT challenge_id,policy_id,purpose,outcome,reserved_cents,created_at_utc,"
        "finalized_at_utc,request_id_digest,biz_id_digest FROM sms_send_attempts"
    )
    with db.readConnection() as connection:
        oldDigest = connection.execute("SELECT phone_hash FROM sms_send_attempts").fetchone()[0]
        before = connection.execute(unchangedFields).fetchone()
    worker = SmsPhoneRetentionWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    assert worker.clearOldPhoneDigests().clearedPhoneDigests == 1
    assert worker.clearOldPhoneDigests().clearedPhoneDigests == 0
    with db.readConnection() as connection:
        assert (
            connection.execute("SELECT phone_hash FROM sms_send_attempts").fetchone()[0]
            != oldDigest
        )
        assert connection.execute(unchangedFields).fetchone() == before
    restarted = SmsBudgetLedger(SqliteAccountDatabase(db), policy(), auditSecret=SECRET)
    restarted.assertApprovedPolicy()
    restarted.createApprovedPolicy(nowUtc=NOW)
    snapshot = restarted.approvedPolicySnapshot()
    assert snapshot["attempts"] == 1 and snapshot["reservedCents"] == 6
    with pytest.raises(SmsAttemptReplayError):
        restarted.reserve(attempt(1), PHONE, "register", nowUtc=NOW)


def test_ninety_day_boundary_and_limited_lookahead_keep_new_attempts(tmp_path: Path) -> None:
    db, ledger = fixture(tmp_path)
    ledger.reserve(attempt(1), PHONE, "register", nowUtc=OLD)
    ledger.reserve(attempt(2), PHONE, "register", nowUtc=OLD + timedelta(microseconds=1))
    ledger.reserve(attempt(3), PHONE, "register", nowUtc=NOW)
    assert (
        SmsPhoneRetentionWorker(
            SqliteAccountDatabase(db), clock=lambda: NOW - timedelta(microseconds=1)
        )
        .clearOldPhoneDigests()
        .clearedPhoneDigests
        == 0
    )
    worker = SmsPhoneRetentionWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    assert worker.clearOldPhoneDigests().clearedPhoneDigests == 1
    assert worker.clearOldPhoneDigests(lookAheadSeconds=300).clearedPhoneDigests == 1
    with db.readConnection() as connection:
        assert (
            len(
                connection.execute(
                    "SELECT phone_hash FROM sms_send_attempts WHERE challenge_id=?", (attempt(3),)
                ).fetchone()[0]
            )
            == 64
        )
    assert ledger.approvedPolicySnapshot()["reservedCents"] == 18


def test_concurrent_late_finalize_keeps_outcome_request_digest_and_charge(tmp_path: Path) -> None:
    db, ledger = fixture(tmp_path)
    ledger.reserve(attempt(1), PHONE, "register", nowUtc=OLD)
    barrier = Barrier(2)

    def clear() -> int:
        barrier.wait(timeout=10)
        return (
            SmsPhoneRetentionWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
            .clearOldPhoneDigests()
            .clearedPhoneDigests
        )

    def finalize() -> None:
        barrier.wait(timeout=10)
        ledger.finalize(attempt(1), "accepted", requestIdDigest="a" * 64, nowUtc=NOW)

    with ThreadPoolExecutor(max_workers=2) as executor:
        cleared, finalized = executor.submit(clear), executor.submit(finalize)
        assert cleared.result(timeout=15) == 1
        finalized.result(timeout=15)
    with db.readConnection() as connection:
        row = connection.execute(
            "SELECT phone_hash,outcome,request_id_digest FROM sms_send_attempts"
        ).fetchone()
        assert len(row[0]) != 64 and row[1] == "accepted" and row[2] == "a" * 64
    assert ledger.approvedPolicySnapshot()["reservedCents"] == 6


def test_bounded_pagination_preserves_every_attempt_and_total(tmp_path: Path) -> None:
    db, ledger = fixture(tmp_path, maximum=150)
    for index in range(101):
        ledger.reserve(attempt(index), PHONE, "register", nowUtc=OLD)
    worker = SmsPhoneRetentionWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    first = worker.clearOldPhoneDigests()
    assert (
        first.clearedPhoneDigests == 100
        and first.moreCandidates
        and first.nextAttemptId is not None
    )
    assert worker.clearOldPhoneDigests(afterAttemptId=first.nextAttemptId).clearedPhoneDigests == 1
    snapshot = ledger.approvedPolicySnapshot()
    assert snapshot["attempts"] == 101 and snapshot["reservedCents"] == 606


def test_mid_batch_failure_rolls_back_phone_changes_and_keeps_ledger(tmp_path: Path) -> None:
    db, ledger = fixture(tmp_path)
    for index in (1, 2):
        ledger.reserve(attempt(index), PHONE, "register", nowUtc=OLD)
    with db.immediateTransaction() as connection:
        connection.execute(
            "CREATE TRIGGER synthetic_abort BEFORE UPDATE ON sms_send_attempts "
            "WHEN OLD.challenge_id='challenge-00000000-0000-4000-8000-000000000002' "
            "BEGIN SELECT RAISE(ABORT,'synthetic'); END"
        )
    with pytest.raises(StorageUnavailableError):
        SmsPhoneRetentionWorker(SqliteAccountDatabase(db), clock=lambda: NOW).clearOldPhoneDigests()
    with db.readConnection() as connection:
        assert (
            connection.execute(
                "SELECT COUNT(*) FROM sms_send_attempts WHERE length(phone_hash)=64"
            ).fetchone()[0]
            == 2
        )
    assert ledger.approvedPolicySnapshot()["reservedCents"] == 12


def test_bad_creation_time_is_visible_without_guessing_or_changing_cost(tmp_path: Path) -> None:
    db, ledger = fixture(tmp_path)
    ledger.reserve(attempt(1), PHONE, "register", nowUtc=OLD)
    with db.immediateTransaction() as connection:
        connection.execute("UPDATE sms_send_attempts SET created_at_utc='0000'")
    result = SmsPhoneRetentionWorker(
        SqliteAccountDatabase(db), clock=lambda: NOW
    ).clearOldPhoneDigests()
    assert result.invalidRecords == 1 and result.clearedPhoneDigests == 0
    assert ledger.approvedPolicySnapshot()["reservedCents"] == 6


def test_cli_is_read_only_until_target_confirmed_and_keeps_unknown_charge(tmp_path: Path) -> None:
    db, ledger = fixture(tmp_path)
    ledger.reserve(attempt(1), PHONE, "register", nowUtc=datetime.now(UTC) - timedelta(days=91))
    ledger.finalize(attempt(1), "unknown", nowUtc=NOW)
    root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment.update(
        GATEWAY_DATABASE_BACKEND="sqlite",
        AGENT_GATEWAY_TASK018_DATABASE_PATH=str(db.databasePath),
        PYTHONPATH=str(root / "src"),
    )
    command = [
        sys.executable,
        str(root / "scripts/manage_account_retention.py"),
        "clear-sms-phone-digests",
    ]
    dry = subprocess.run(command, env=environment, capture_output=True, check=False)  # noqa: S603
    assert dry.returncode == 0 and json.loads(dry.stdout)["dueSmsPhoneDigests"] == 1
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
    assert applied.returncode == 0 and result["clearedPhoneDigests"] == 1
    assert result["phoneDigestMaximumNaturalDays"] == 90
    assert ledger.approvedPolicySnapshot()["reservedCents"] == 6
