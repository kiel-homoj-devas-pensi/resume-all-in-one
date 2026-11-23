from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from agent_gateway.account_retention import AccountRetentionWorker
from agent_gateway.account_retention_schema import migrateSqliteRetentionSchema
from agent_gateway.account_storage import SqliteAccountDatabase, StorageUnavailableError
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import toUtcText
from agent_gateway.lifecycle_storage import SqliteLifecycleStore
from agent_gateway.privilege_schema import migrateSqlitePrivilegeSchema
from agent_gateway.recovery_schema import migrateSqliteRecoverySchema
from agent_gateway.sms_budget import SmsAttemptReplayError, SmsBudgetLedger, SmsBudgetPolicy

NOW = datetime(2026, 10, 21, 8, tzinfo=UTC)
PHONE = "+8613800000000"


def database(tmp_path: Path) -> GatewayDatabase:
    db = GatewayDatabase(tmp_path / "synthetic-otp.sqlite")
    db.initialize()
    migrateSqlitePrivilegeSchema(db)
    migrateSqliteRecoverySchema(db)
    migrateSqliteRetentionSchema(db)
    return db


def addChallenge(
    db: GatewayDatabase, name: str, expiry: datetime, consumed: datetime | None = None
) -> None:
    with db.immediateTransaction() as connection:
        connection.execute(
            "INSERT INTO phone_challenges(challenge_id,phone_hash,purpose,code_hash,"
            "expires_at_utc,attempts,consumed_at_utc) VALUES (?,?,?,?,?,0,?)",
            (
                name,
                "a" * 64,
                "register",
                "b" * 64,
                toUtcText(expiry),
                None if consumed is None else toUtcText(consumed),
            ),
        )


def count(db: GatewayDatabase) -> int:
    with db.readConnection() as connection:
        return int(connection.execute("SELECT COUNT(*) FROM phone_challenges").fetchone()[0])


def test_expired_used_and_invalidated_challenges_use_earliest_six_hour_boundary(
    tmp_path: Path,
) -> None:
    db = database(tmp_path)
    boundary = NOW - timedelta(hours=6)
    addChallenge(db, "expired", boundary)
    addChallenge(db, "used", NOW + timedelta(minutes=5), boundary)
    addChallenge(db, "expired-before-late-invalidation", boundary, NOW)
    addChallenge(db, "recent", boundary + timedelta(microseconds=1))
    addChallenge(db, "active", NOW + timedelta(minutes=5))
    store = SqliteAccountDatabase(db)
    assert (
        AccountRetentionWorker(store, clock=lambda: NOW - timedelta(microseconds=1))
        .purgeInvalidChallenges()
        .deletedRecords
        == 0
    )
    result = AccountRetentionWorker(store, clock=lambda: NOW).purgeInvalidChallenges()
    assert result.deletedRecords == 3 and result.invalidRecords == 0
    assert count(db) == 2
    assert (
        AccountRetentionWorker(store, clock=lambda: NOW).purgeInvalidChallenges().deletedRecords
        == 0
    )


def test_resend_does_not_extend_old_expired_record_or_delete_new_challenge(tmp_path: Path) -> None:
    db = database(tmp_path)
    addChallenge(db, "old", NOW - timedelta(hours=7))
    lifecycle = SqliteLifecycleStore(db)
    with lifecycle.transaction() as connection:
        connection.replaceChallenge(
            "new",
            "a" * 64,
            "register",
            "b" * 64,
            toUtcText(NOW + timedelta(minutes=5)),
            toUtcText(NOW),
        )
    result = AccountRetentionWorker(
        SqliteAccountDatabase(db), clock=lambda: NOW
    ).purgeInvalidChallenges()
    assert result.deletedRecords == 1
    with lifecycle.readConnection() as connection:
        assert connection.findChallenge("old") is None
        current = connection.findChallenge("new")
        assert current is not None and current["consumed_at_utc"] is None


def test_challenge_cleanup_preserves_fees_replay_and_throttle_counters(tmp_path: Path) -> None:
    db = database(tmp_path)
    ledger = SmsBudgetLedger(
        SqliteAccountDatabase(db),
        SmsBudgetPolicy(2, 12, 6, NOW + timedelta(days=1), frozenset({PHONE})),
        auditSecret=b"synthetic-otp-retention-secret-32bytes",
    )
    ledger.createApprovedPolicy(nowUtc=NOW)
    challenge = "challenge-00000000-0000-4000-8000-000000000001"
    ledger.reserve(challenge, PHONE, "register", nowUtc=NOW)
    ledger.finalize(challenge, "unknown", nowUtc=NOW)
    addChallenge(db, challenge, NOW - timedelta(hours=7))
    lifecycle = SqliteLifecycleStore(db)
    with lifecycle.transaction() as connection:
        connection.chargeRate(
            "synthetic-rate", toUtcText(NOW), toUtcText(NOW - timedelta(minutes=1))
        )
    assert (
        AccountRetentionWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
        .purgeInvalidChallenges()
        .deletedRecords
        == 1
    )
    with db.readConnection() as connection:
        budget = connection.execute(
            "SELECT attempts,reserved_cents FROM sms_send_budget"
        ).fetchone()
        assert tuple(budget) == (1, 6)
        assert connection.execute("SELECT COUNT(*) FROM sms_send_attempts").fetchone()[0] == 1
        assert connection.execute("SELECT attempts FROM identity_rate_limits").fetchone()[0] == 1
    with pytest.raises(SmsAttemptReplayError):
        ledger.reserve(challenge, PHONE, "register", nowUtc=NOW)


def test_challenge_pagination_precleanup_window_and_corruption(tmp_path: Path) -> None:
    db = database(tmp_path)
    for number in range(101):
        addChallenge(db, f"c{number:03}", NOW - timedelta(hours=6) + timedelta(minutes=5))
    addChallenge(db, "active", NOW + timedelta(minutes=5))
    addChallenge(db, "z-invalid", NOW)
    with db.immediateTransaction() as connection:
        connection.execute(
            "UPDATE phone_challenges SET expires_at_utc='0000' WHERE challenge_id='z-invalid'"
        )
    worker = AccountRetentionWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    first = worker.purgeInvalidChallenges(lookAheadSeconds=300)
    assert first.deletedRecords == 100 and first.nextRecordId == "c099"
    last = worker.purgeInvalidChallenges(afterChallengeId=first.nextRecordId, lookAheadSeconds=300)
    assert last.deletedRecords == 1 and last.invalidRecords == 1 and not last.moreCandidates
    assert count(db) == 2


def test_failed_challenge_batch_rolls_back_prior_deletions(tmp_path: Path) -> None:
    db = database(tmp_path)
    addChallenge(db, "a", NOW - timedelta(hours=7))
    addChallenge(db, "b", NOW - timedelta(hours=7))
    with db.immediateTransaction() as connection:
        connection.execute(
            "CREATE TRIGGER synthetic_abort_otp BEFORE DELETE ON phone_challenges "
            "WHEN OLD.challenge_id='b' BEGIN SELECT RAISE(ABORT, 'synthetic'); END"
        )
    with pytest.raises(StorageUnavailableError):
        AccountRetentionWorker(
            SqliteAccountDatabase(db), clock=lambda: NOW
        ).purgeInvalidChallenges()
    assert count(db) == 2


def test_challenge_cli_defaults_read_only_and_requires_confirmed_target(tmp_path: Path) -> None:
    db = database(tmp_path)
    addChallenge(db, "old", datetime.now(UTC) - timedelta(hours=7))
    root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment.update(
        {
            "GATEWAY_DATABASE_BACKEND": "sqlite",
            "AGENT_GATEWAY_TASK018_DATABASE_PATH": str(db.databasePath),
            "PYTHONPATH": str(root / "src"),
        }
    )
    command = [
        sys.executable,
        str(root / "scripts/manage_account_retention.py"),
        "purge-challenges",
    ]
    dry = subprocess.run(command, env=environment, capture_output=True, check=False)  # noqa: S603
    assert dry.returncode == 0 and not json.loads(dry.stdout)["writeRequested"] and count(db) == 1
    denied = subprocess.run(  # noqa: S603
        command + ["--apply"], env=environment, capture_output=True, check=False
    )
    assert denied.returncode == 1 and count(db) == 1
    done = subprocess.run(  # noqa: S603
        command + ["--apply", "--confirmed-target"],
        env=environment,
        capture_output=True,
        check=False,
    )
    result = json.loads(done.stdout)
    assert done.returncode == 0 and result["deletedChallenges"] == 1
    assert result["invalidChallengeMaximumHours"] == 6 and count(db) == 0
