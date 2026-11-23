from __future__ import annotations

import json
import os
import subprocess
import sys
from collections.abc import Iterator, Mapping
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from threading import Barrier
from typing import Literal
from uuid import uuid4

import pytest
from starlette.testclient import TestClient

from agent_gateway import app as factory
from agent_gateway import sms_attempt_retention_schema as summarySchema
from agent_gateway.account_retention_permissions import (
    validatePurgerPrivileges,
    validateSmsSummaryWebPrivileges,
)
from agent_gateway.account_retention_schema import migrateSqliteRetentionSchema
from agent_gateway.account_storage import (
    AccountSqlConnection,
    SqliteAccountDatabase,
    StorageUnavailableError,
)
from agent_gateway.database import GatewayDatabase, UnsupportedDatabaseSchemaError
from agent_gateway.identity import toUtcText
from agent_gateway.pnvs_runtime import PnvsRuntimeSettings
from agent_gateway.pnvs_sender import PnvsSmsSender
from agent_gateway.pnvs_transport import PnvsSmsTransport, SmsAcceptance
from agent_gateway.privilege_schema import migrateSqlitePrivilegeSchema
from agent_gateway.recovery_schema import migrateSqliteRecoverySchema
from agent_gateway.settings import GatewaySettings
from agent_gateway.sms_attempt_retention import SmsAttemptSummaryWorker
from agent_gateway.sms_attempt_retention_schema import (
    applySqliteSmsSummarySchema,
    migrateSqliteSmsSummarySchema,
    validateSqliteSmsSummarySchema,
)
from agent_gateway.sms_budget import SmsAttemptReplayError, SmsBudgetLedger, SmsBudgetPolicy
from agent_gateway.sqlite_backup import SqliteBackupError, backupSqlite

NOW = datetime(2026, 10, 21, 8, tzinfo=UTC)
OLD = NOW - timedelta(days=90)
PHONE = "+8613800000000"
SECRET = b"s" * 32


def make(
    tmp_path: Path, *, summary: bool = True
) -> tuple[GatewayDatabase, SmsBudgetLedger, SmsBudgetPolicy]:
    db = GatewayDatabase(tmp_path / "sms.sqlite3")
    db.initialize()
    migrateSqlitePrivilegeSchema(db)
    migrateSqliteRecoverySchema(db)
    migrateSqliteRetentionSchema(db)
    policy = SmsBudgetPolicy(150, 900, 6, datetime(2099, 1, 1, tzinfo=UTC), frozenset({PHONE}))
    ledger = SmsBudgetLedger(SqliteAccountDatabase(db), policy, auditSecret=SECRET)
    ledger.createApprovedPolicy(nowUtc=OLD)
    if summary:
        migrateSqliteSmsSummarySchema(db)
        ledger = SmsBudgetLedger(
            SqliteAccountDatabase(db), policy, auditSecret=SECRET, withSummary=True
        )
    return db, ledger, policy


def seed(
    db: GatewayDatabase,
    ledger: SmsBudgetLedger,
    created: datetime,
    outcome: Literal["accepted", "rejected", "reserved", "unknown"] = "accepted",
) -> str:
    attempt = "challenge-" + str(uuid4())
    with db.immediateTransaction() as c:
        c.execute(
            "INSERT INTO phone_challenges(challenge_id,phone_hash,purpose,code_hash,"
            "expires_at_utc) "
            "VALUES(?,?,'register',?,?)",
            (attempt, "a" * 64, "b" * 64, toUtcText(created + timedelta(minutes=5))),
        )
    ledger.reserve(attempt, PHONE, "register", nowUtc=created)
    if outcome != "reserved":
        ledger.finalize(attempt, outcome, nowUtc=created)
    return attempt


def counts(db: GatewayDatabase) -> tuple[int, int, int, int, int]:
    with db.readConnection() as c:
        budget = c.execute("SELECT attempts,reserved_cents FROM sms_send_budget").fetchone()
        archive = c.execute("SELECT attempts,reserved_cents FROM sms_send_summary").fetchone()
        live = c.execute("SELECT COUNT(*) FROM sms_send_attempts").fetchone()[0]
        return budget[0], budget[1], live, archive[0], archive[1]


def test_explicit_migration_preserves_old_spend_and_repeat_never_resets_archive(
    tmp_path: Path,
) -> None:
    db, legacy, policy = make(tmp_path, summary=False)
    seed(db, legacy, OLD)
    seed(db, legacy, OLD, "unknown")
    migrateSqliteSmsSummarySchema(db)
    assert counts(db) == (2, 12, 2, 0, 0)
    assert (
        SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
        .summarize()
        .summarizedAttempts
        == 2
    )
    migrateSqliteSmsSummarySchema(db)
    current = SmsBudgetLedger(
        SqliteAccountDatabase(db), policy, auditSecret=SECRET, withSummary=True
    )
    current.createApprovedPolicy(nowUtc=NOW)
    assert current.approvedPolicySnapshot()["reservedCents"] == 12
    assert counts(db) == (2, 12, 0, 2, 12)
    with pytest.raises(ValueError, match="inconsistent"):
        legacy.assertApprovedPolicy()


def unresolvedCounts(db: GatewayDatabase) -> tuple[int, int]:
    with db.readConnection() as c:
        row = c.execute(
            "SELECT unresolved_attempts,unresolved_reserved_cents FROM sms_send_summary"
        ).fetchone()
    return row[0], row[1]


def test_upgrade_from_ten_preserves_existing_known_summary_and_old_backup(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path, summary=False)
    known = seed(db, ledger, OLD)
    seed(db, ledger, OLD, "unknown")
    with db.immediateTransaction() as c:
        applySqliteSmsSummarySchema(c)
        c.execute("INSERT INTO sms_send_summary SELECT policy_id,1,6 FROM sms_send_budget")
        c.execute("DELETE FROM sms_send_attempts WHERE challenge_id=?", (known,))
    validateSqliteSmsSummarySchema(db, withUnresolved=False)
    snapshot = tmp_path / "old-ten.db"
    backupSqlite(db.databasePath, snapshot, schemaVersion=10)
    validateSqliteSmsSummarySchema(GatewayDatabase(snapshot), withUnresolved=False)
    migrateSqliteSmsSummarySchema(db)
    assert counts(db) == (2, 12, 1, 1, 6) and unresolvedCounts(db) == (0, 0)
    SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW).summarize()
    migrateSqliteSmsSummarySchema(db)
    assert counts(db) == (2, 12, 0, 2, 12) and unresolvedCounts(db) == (1, 6)
    # Source upgrade does not rewrite the independent old recovery point.
    validateSqliteSmsSummarySchema(GatewayDatabase(snapshot), withUnresolved=False)


@pytest.mark.parametrize("outcome", ["unknown", "reserved"])
def test_unresolved_exact_boundary_removes_ids_and_late_callbacks_cannot_refund_or_resend(
    tmp_path: Path, outcome: Literal["unknown", "reserved"]
) -> None:
    db, ledger, policy = make(tmp_path)
    old = seed(db, ledger, OLD, outcome)
    seed(db, ledger, OLD + timedelta(microseconds=1), outcome)
    worker = SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    assert worker.summarize().summarizedAttempts == 1
    assert worker.summarize().summarizedAttempts == 0
    assert counts(db) == (2, 12, 1, 1, 6) and unresolvedCounts(db) == (1, 6)
    with pytest.raises(ValueError, match="not_reserved"):
        ledger.finalize(old, "accepted", nowUtc=NOW)
    with pytest.raises(SmsAttemptReplayError):
        ledger.reserve(old, PHONE, "register", nowUtc=NOW)
    current = SmsBudgetLedger(
        SqliteAccountDatabase(db), policy, auditSecret=SECRET, withSummary=True
    )
    current.createApprovedPolicy(nowUtc=NOW)
    assert counts(db) == (2, 12, 1, 1, 6) and unresolvedCounts(db) == (1, 6)


def test_unresolved_compaction_and_finalizer_race_keeps_exactly_one_charge(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path)
    pending = seed(db, ledger, OLD, "reserved")
    barrier = Barrier(3)

    def compact() -> int:
        barrier.wait()
        return (
            SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
            .summarize()
            .summarizedAttempts
        )

    def finalize() -> bool:
        barrier.wait()
        try:
            ledger.finalize(pending, "accepted", nowUtc=NOW)
        except ValueError as error:
            assert str(error) == "sms_attempt_not_reserved"
            return False
        return True

    with ThreadPoolExecutor(max_workers=3) as pool:
        first, second, callback = pool.submit(compact), pool.submit(compact), pool.submit(finalize)
        assert first.result(timeout=10) + second.result(timeout=10) == 1
        known = callback.result(timeout=10)
    assert counts(db) == (1, 6, 0, 1, 6)
    assert unresolvedCounts(db) == ((0, 0) if known else (1, 6))
    ledger.assertApprovedPolicy()


def test_unresolved_subset_tampering_blocks_further_sends(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path)
    seed(db, ledger, OLD, "unknown")
    SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW).summarize()
    with db.immediateTransaction() as c:
        # Still satisfies simple DB range checks, but breaks count*approved unit.
        c.execute("UPDATE sms_send_summary SET unresolved_reserved_cents=5")
    with pytest.raises(ValueError, match="inconsistent"):
        seed(db, ledger, NOW, "reserved")
    assert counts(db) == (1, 6, 0, 1, 6)


@pytest.mark.parametrize("outcome", ["unknown", "reserved"])
def test_unresolved_update_failure_rolls_back_removal_and_preserves_charge(
    tmp_path: Path, outcome: Literal["unknown", "reserved"]
) -> None:
    db, ledger, _ = make(tmp_path)
    seed(db, ledger, OLD, outcome)
    with db.immediateTransaction() as c:
        c.execute(
            "CREATE TRIGGER synthetic_abort BEFORE UPDATE ON sms_send_summary "
            "BEGIN SELECT RAISE(ABORT,'synthetic'); END"
        )
    with pytest.raises(StorageUnavailableError):
        SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW).summarize()
    assert counts(db) == (1, 6, 1, 0, 0) and unresolvedCounts(db) == (0, 0)
    ledger.assertApprovedPolicy()


@pytest.mark.parametrize("outcome", ["unknown", "reserved"])
def test_unresolved_invalid_finalization_is_reported_without_deleting(
    tmp_path: Path, outcome: str
) -> None:
    db, ledger, _ = make(tmp_path)
    seed(db, ledger, OLD, "unknown" if outcome == "unknown" else "reserved")
    with db.immediateTransaction() as c:
        # Simulate damaged storage; ordinary writes already reject this state.
        c.execute("PRAGMA ignore_check_constraints=ON")
        c.execute(
            "UPDATE sms_send_attempts SET finalized_at_utc=?",
            (None if outcome == "unknown" else toUtcText(NOW),),
        )
        c.execute("PRAGMA ignore_check_constraints=OFF")
    result = SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW).summarize()
    assert result.invalidRecords == 1 and result.summarizedAttempts == 0
    assert counts(db) == (1, 6, 1, 0, 0) and unresolvedCounts(db) == (0, 0)


def test_missing_latest_schema_fails_startup_until_explicit_upgrade(tmp_path: Path) -> None:
    db, _, _ = make(tmp_path, summary=False)
    with db.immediateTransaction() as c:
        applySqliteSmsSummarySchema(c)
        c.execute("INSERT INTO sms_send_summary SELECT policy_id,0,0 FROM sms_send_budget")
    settings = GatewaySettings(
        task018DatabasePath=db.databasePath,
        enableTask018FakeIdentity=True,
        enableAccountPrivileges=True,
        enableRecoveryCodes=True,
        enableAccountRetention=True,
        enableSmsAttemptRetention=True,
    )
    with pytest.raises(UnsupportedDatabaseSchemaError):
        factory.createApplication(settings=settings)
    migrateSqliteSmsSummarySchema(db)
    factory.createApplication(settings=settings)


def test_sqlite_partial_unmarked_extension_is_rejected_without_reset(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path, summary=False)
    seed(db, ledger, OLD, "unknown")
    with db.immediateTransaction() as c:
        applySqliteSmsSummarySchema(c)
        c.execute("INSERT INTO sms_send_summary SELECT policy_id,0,0 FROM sms_send_budget")
        c.execute(summarySchema.SQLITE_UNRESOLVED_STATEMENTS[0])
    with pytest.raises(UnsupportedDatabaseSchemaError):
        migrateSqliteSmsSummarySchema(db)
    assert counts(db) == (1, 6, 1, 0, 0)


class UnresolvedMigrationProbe:
    """Control-flow probe only; real MySQL metadata and atomic DDL remain unaccepted."""

    def __init__(self, *, altered: bool, nonzero: bool = False) -> None:
        self.altered, self.nonzero = altered, nonzero
        self.calls: list[tuple[str, tuple[object, ...]]] = []

    def fetchOne(self, query: str, parameters: tuple[object, ...] = ()) -> Mapping[str, object]:
        del parameters
        if "information_schema.columns" in query:
            return {"count": int(self.altered)}
        assert "unresolved_attempts<>0" in query
        return {"count": int(self.nonzero)}

    def execute(self, query: str, parameters: tuple[object, ...] = ()) -> int:
        self.calls.append((query, parameters))
        return 1

    def fetchMany(
        self, query: str, parameters: tuple[object, ...] = (), *, maximumRows: int = 100
    ) -> tuple[Mapping[str, object], ...]:
        raise AssertionError("unexpected metadata path")


@pytest.mark.parametrize("altered,nonzero", [(False, False), (True, False), (True, True)])
def test_mysql_extension_adopts_only_empty_exact_unmarked_subset(
    monkeypatch: pytest.MonkeyPatch, altered: bool, nonzero: bool
) -> None:
    probe = UnresolvedMigrationProbe(altered=altered, nonzero=nonzero)
    validations: list[dict[str, bool]] = []

    def validate(connection: AccountSqlConnection, **flags: bool) -> None:
        assert connection is probe
        validations.append(flags)

    monkeypatch.setattr(summarySchema, "_validateBase", validate)
    if nonzero:
        with pytest.raises(UnsupportedDatabaseSchemaError):
            summarySchema._migrateMySqlUnresolved(probe)
        assert probe.calls == []
    else:
        summarySchema._migrateMySqlUnresolved(probe)
        assert any(flags.get("unresolvedMarked") for flags in validations)
        if not altered:
            assert probe.calls[0] == (summarySchema.MYSQL_UNRESOLVED_STATEMENT, ())
        assert probe.calls[-1][1] == (10, summarySchema.MYSQL_UNRESOLVED_DIGEST)
    assert any(flags.get("withUnresolved") for flags in validations)


@pytest.mark.parametrize("outcome", ["accepted", "rejected"])
def test_ninety_days_clears_all_details_but_preserves_unresolved_charges_and_budget(
    tmp_path: Path, outcome: Literal["accepted", "rejected"]
) -> None:
    db, ledger, _ = make(tmp_path)
    old = seed(db, ledger, OLD, outcome)
    unknown = seed(db, ledger, OLD, "unknown")
    pending = seed(db, ledger, OLD, "reserved")
    recent = seed(db, ledger, OLD + timedelta(microseconds=1))
    worker = SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    assert worker.summarize().summarizedAttempts == 3
    assert worker.summarize().summarizedAttempts == 0
    assert counts(db) == (4, 24, 1, 3, 18)
    with db.readConnection() as c:
        remaining = {row[0] for row in c.execute("SELECT challenge_id FROM sms_send_attempts")}
        unresolved = c.execute(
            "SELECT unresolved_attempts,unresolved_reserved_cents FROM sms_send_summary"
        ).fetchone()
    assert tuple(unresolved) == (2, 12)
    assert remaining == {recent} and not {unknown, pending, old} & remaining
    ledger.assertApprovedPolicy()
    with pytest.raises(SmsAttemptReplayError):
        ledger.reserve(old, PHONE, "register", nowUtc=NOW)


def test_fresh_challenge_required_and_early_sweep_only_touches_old_known_records(
    tmp_path: Path,
) -> None:
    db, ledger, _ = make(tmp_path)
    seed(db, ledger, OLD + timedelta(seconds=300))
    worker = SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    assert worker.summarize().summarizedAttempts == 0
    assert worker.summarize(lookAheadSeconds=300).summarizedAttempts == 1
    with pytest.raises(SmsAttemptReplayError):
        ledger.reserve("challenge-" + str(uuid4()), PHONE, "register", nowUtc=NOW)
    seed(db, ledger, NOW, "reserved")
    assert counts(db) == (2, 12, 1, 1, 6)


def test_paging_preserves_total_counters_and_summary_has_no_request_identifier(
    tmp_path: Path,
) -> None:
    db, ledger, _ = make(tmp_path)
    for _ in range(101):
        seed(db, ledger, OLD)
    worker = SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    first = worker.summarize()
    assert first.summarizedAttempts == 100 and first.moreCandidates and first.nextAttemptId
    assert worker.summarize(afterAttemptId=first.nextAttemptId).summarizedAttempts == 1
    assert counts(db) == (101, 606, 0, 101, 606)
    with db.readConnection() as c:
        assert [r[1] for r in c.execute("PRAGMA table_info(sms_send_summary)")] == [
            "policy_id",
            "attempts",
            "reserved_cents",
            "unresolved_attempts",
            "unresolved_reserved_cents",
        ]
    ledger.assertApprovedPolicy()


def test_failed_summary_update_rolls_back_deleted_details(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path)
    seed(db, ledger, OLD)
    with db.immediateTransaction() as c:
        c.execute(
            "CREATE TRIGGER synthetic_abort BEFORE UPDATE ON sms_send_summary "
            "BEGIN SELECT RAISE(ABORT,'synthetic'); END"
        )
    with pytest.raises(StorageUnavailableError):
        SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW).summarize()
    assert counts(db) == (1, 6, 1, 0, 0)
    ledger.assertApprovedPolicy()


def test_unexpected_budget_change_also_rolls_back_compaction(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path)
    seed(db, ledger, OLD)
    with db.immediateTransaction() as c:
        c.execute(
            "CREATE TRIGGER synthetic_change AFTER DELETE ON sms_send_attempts "
            "BEGIN UPDATE sms_send_budget SET attempts=0,reserved_cents=0; END"
        )
    with pytest.raises(ValueError, match="budget_changed"):
        SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW).summarize()
    assert counts(db) == (1, 6, 1, 0, 0)
    ledger.assertApprovedPolicy()


def test_tampered_summary_and_bad_final_time_fail_closed(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path)
    seed(db, ledger, OLD)
    with db.immediateTransaction() as c:
        c.execute("UPDATE sms_send_attempts SET finalized_at_utc='0000'")
    result = SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW).summarize()
    assert result.invalidRecords == 1 and result.summarizedAttempts == 0
    with db.immediateTransaction() as c:
        c.execute("UPDATE sms_send_summary SET attempts=1,reserved_cents=6")
    with pytest.raises(ValueError, match="inconsistent"):
        ledger.assertApprovedPolicy()


def test_concurrent_compaction_and_new_reservation_preserve_all_charges(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path)
    seed(db, ledger, OLD)
    barrier = Barrier(2)

    def compact() -> None:
        barrier.wait()
        SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW).summarize()

    def reserve() -> None:
        barrier.wait()
        seed(db, ledger, NOW, "reserved")

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(compact), pool.submit(reserve)]
        for f in futures:
            f.result(timeout=10)
    assert counts(db) == (2, 12, 1, 1, 6)
    ledger.assertApprovedPolicy()


def test_late_finalization_and_parallel_compactors_never_double_count(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path)
    pending = seed(db, ledger, OLD, "reserved")
    worker = SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW)
    ledger.finalize(pending, "accepted", nowUtc=NOW)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(worker.summarize), pool.submit(worker.summarize)]
        assert sum(f.result(timeout=10).summarizedAttempts for f in futures) == 1
    assert counts(db) == (1, 6, 0, 1, 6)


class Probe(PnvsSmsTransport):
    def __init__(self) -> None:
        self.calls = 0

    def sendVerification(
        self,
        phoneE164: str,
        code: str,
        purpose: Literal["register", "resetPassword"],
        *,
        challengeId: str,
    ) -> SmsAcceptance:
        self.calls += 1
        return SmsAcceptance("a" * 64, "b" * 64)


def test_actual_factory_issues_fresh_challenge_after_archive_without_refilling(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    db, ledger, policy = make(tmp_path)
    old = seed(db, ledger, OLD)
    SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW).summarize()
    probe = Probe()
    runtime = PnvsRuntimeSettings(b"o" * 32, SECRET, policy)
    monkeypatch.setattr(factory, "loadPnvsRuntimeSettings", lambda path: runtime)
    monkeypatch.setattr(factory, "loadPnvsCredentials", lambda path: None)
    monkeypatch.setattr(factory, "PnvsSmsTransport", lambda credentials: probe)
    settings = GatewaySettings(
        task018DatabasePath=db.databasePath,
        enableAccountPrivileges=True,
        enableRecoveryCodes=True,
        enableAccountRetention=True,
        enableSmsAttemptRetention=True,
        pnvsCredentialsPath=tmp_path / "credentials.dpapi",
        pnvsRuntimePath=tmp_path / "runtime.dpapi",
    )
    app = factory.createApplication(settings=settings)
    with TestClient(app) as client:
        response = client.post(
            "/v2/account-verifications",
            json={"protocolVersion": "0.5.0", "phoneE164": PHONE, "purpose": "register"},
        )
        assert response.status_code == 200
    assert probe.calls == 1 and counts(db) == (2, 12, 1, 1, 6)
    with pytest.raises(SmsAttemptReplayError):
        PnvsSmsSender(ledger, probe).sendCode(PHONE, "123456", "register", challengeId=old)
    assert probe.calls == 1
    factory.createApplication(settings=settings)
    assert counts(db) == (2, 12, 1, 1, 6)


def test_schema_eleven_backup_is_explicit_consistent_and_never_downgraded(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path)
    seed(db, ledger, OLD)
    SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW).summarize()
    destination = tmp_path / "snapshot.db"
    with pytest.raises(SqliteBackupError):
        backupSqlite(db.databasePath, destination, schemaVersion=9)
    assert not destination.exists()
    with pytest.raises(SqliteBackupError):
        backupSqlite(db.databasePath, destination, schemaVersion=10)
    backupSqlite(db.databasePath, destination, schemaVersion=11)
    validateSqliteSmsSummarySchema(GatewayDatabase(destination))
    assert counts(GatewayDatabase(destination)) == (1, 6, 0, 1, 6)


def test_cli_dry_quiescent_migration_then_explicit_summary(tmp_path: Path) -> None:
    db, ledger, _ = make(tmp_path, summary=False)
    seed(db, ledger, datetime.now(UTC) - timedelta(days=91))
    root = Path(__file__).resolve().parents[1]
    env = {
        **os.environ,
        "PYTHONPATH": str(root / "src"),
        "AGENT_GATEWAY_TASK018_DATABASE_PATH": str(db.databasePath),
        "GATEWAY_DATABASE_BACKEND": "sqlite",
    }
    command = [sys.executable, str(root / "scripts/manage_account_retention.py")]
    dry = subprocess.run(command + ["migrate-sms-summary"], env=env, capture_output=True)  # noqa: S603
    assert dry.returncode == 0
    denied = subprocess.run(  # noqa: S603
        command + ["migrate-sms-summary", "--apply", "--confirmed-target"],
        env=env,
        capture_output=True,
    )  # noqa: S603
    assert denied.returncode == 1
    applied = subprocess.run(  # noqa: S603
        command + ["migrate-sms-summary", "--apply", "--confirmed-target", "--confirmed-quiescent"],
        env=env,
        capture_output=True,
    )  # noqa: S603
    assert applied.returncode == 0
    dry = subprocess.run(command + ["summarize-sms-attempts"], env=env, capture_output=True)  # noqa: S603
    assert dry.returncode == 0 and json.loads(dry.stdout)["dueSmsAttempts"] == 1
    assert counts(db) == (1, 6, 1, 0, 0)
    applied = subprocess.run(  # noqa: S603
        command + ["summarize-sms-attempts", "--apply", "--confirmed-target"],
        env=env,
        capture_output=True,
    )  # noqa: S603
    assert applied.returncode == 0 and json.loads(applied.stdout)["summarizedAttempts"] == 1
    assert counts(db) == (1, 6, 0, 1, 6)


def test_feature_requires_explicit_schema_and_parent_flags(tmp_path: Path) -> None:
    db, _, _ = make(tmp_path, summary=False)
    with pytest.raises(ValueError):
        GatewaySettings(enableSmsAttemptRetention=True)
    settings = GatewaySettings(
        task018DatabasePath=db.databasePath,
        enableTask018FakeIdentity=True,
        enableAccountPrivileges=True,
        enableRecoveryCodes=True,
        enableAccountRetention=True,
        enableSmsAttemptRetention=True,
    )
    with pytest.raises(UnsupportedDatabaseSchemaError):
        factory.createApplication(settings=settings)


class DialectConnection:
    """MySQL syntax/bindings only; SQLite here does not prove InnoDB concurrency."""

    def __init__(self, inner: AccountSqlConnection, calls: list[str]) -> None:
        self.inner, self.calls = inner, calls

    def sql(self, query: str) -> str:
        assert "?" not in query
        self.calls.append(query)
        return query.removesuffix(" FOR SHARE").removesuffix(" FOR UPDATE").replace("%s", "?")

    def execute(self, query: str, parameters: tuple[object, ...] = ()) -> int:
        return self.inner.execute(self.sql(query), parameters)

    def fetchOne(
        self, query: str, parameters: tuple[object, ...] = ()
    ) -> Mapping[str, object] | None:
        return self.inner.fetchOne(self.sql(query), parameters)

    def fetchMany(
        self, query: str, parameters: tuple[object, ...] = (), *, maximumRows: int
    ) -> tuple[Mapping[str, object], ...]:
        return self.inner.fetchMany(self.sql(query), parameters, maximumRows=maximumRows)


class DialectDatabase:
    authorityKey = ("mysql", "synthetic-only")

    def __init__(self, db: GatewayDatabase) -> None:
        self.inner = SqliteAccountDatabase(db)
        self.calls: list[str] = []

    @contextmanager
    def transaction(self) -> Iterator[AccountSqlConnection]:
        with self.inner.transaction() as c:
            yield DialectConnection(c, self.calls)

    @contextmanager
    def readConnection(self) -> Iterator[AccountSqlConnection]:
        with self.inner.readConnection() as c:
            yield DialectConnection(c, self.calls)


def test_mysql_bound_queries_lock_policy_before_summary_and_never_update_budget(
    tmp_path: Path,
) -> None:
    db, ledger, _ = make(tmp_path)
    seed(db, ledger, OLD)
    dialect = DialectDatabase(db)
    assert SmsAttemptSummaryWorker(dialect, clock=lambda: NOW).summarize().summarizedAttempts == 1
    assert counts(db) == (1, 6, 0, 1, 6)
    assert dialect.calls[0].endswith(" FOR SHARE") and "sms_send_budget" in dialect.calls[0]
    assert dialect.calls[1].endswith(" FOR UPDATE") and "sms_send_summary" in dialect.calls[1]
    assert any("LIMIT %s FOR UPDATE" in q for q in dialect.calls)
    assert not any(
        q.startswith(("UPDATE sms_send_budget", "DELETE FROM sms_send_budget"))
        for q in dialect.calls
    )
    assert any("LEFT JOIN sms_send_summary" in q for q in dialect.calls)


class Grants:
    def __init__(self) -> None:
        self.extra: list[str] = []
        self.excess = 0

    def execute(self, query: str, parameters: tuple[object, ...] = ()) -> int:
        raise AssertionError("permission checks must not write")

    def fetchOne(self, query: str, parameters: tuple[object, ...] = ()) -> Mapping[str, object]:
        if "AS grantee" in query:
            return {"grantee": "'resume_web'@'localhost'"}
        if "CURRENT_ROLE()" in query:
            return {
                "database_name": "resume",
                "identity": "resume_retention_sms@localhost",
                "roles": "NONE",
            }
        return {"count": self.excess}

    def fetchMany(
        self, query: str, parameters: tuple[object, ...] = (), *, maximumRows: int
    ) -> tuple[Mapping[str, object], ...]:
        assert query == "SHOW GRANTS"
        grants = [
            f"GRANT {priv} ON `resume`.`{table}` TO `resume_retention_sms`@`localhost`"
            for table, priv in [
                ("sms_send_budget", "SELECT"),
                ("sms_send_summary", "SELECT, UPDATE"),
                ("sms_send_attempts", "SELECT, DELETE"),
                ("gateway_schema_migrations", "SELECT"),
            ]
        ] + self.extra
        return tuple({"grant": g} for g in grants)


def test_dedicated_compactor_cannot_mutate_budget_and_web_cannot_mutate_summary() -> None:
    grants = Grants()
    validatePurgerPrivileges(grants, smsSummaryOnly=True)
    with pytest.raises(ValueError):
        validatePurgerPrivileges(grants, smsSummaryOnly=True, smsPhoneOnly=True)
    grants.extra = [
        "GRANT UPDATE ON `resume`.`sms_send_budget` TO `resume_retention_sms`@`localhost`"
    ]
    with pytest.raises(ValueError):
        validatePurgerPrivileges(grants, smsSummaryOnly=True)
    validateSmsSummaryWebPrivileges(grants)
    grants.excess = 1
    with pytest.raises(ValueError):
        validateSmsSummaryWebPrivileges(grants)
