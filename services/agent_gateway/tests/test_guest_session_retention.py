from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path
from threading import Barrier

import pytest

from agent_gateway.database import GatewayDatabase, UnsupportedDatabaseSchemaError
from agent_gateway.guest_identity import GuestIdentityService, GuestLimitError
from agent_gateway.guest_session_retention import GuestSessionRetentionWorker
from agent_gateway.identity import AuthenticationFailedError
from agent_gateway.usage import MonthlyQuotaExhaustedError, ProductCapability

NOW = datetime(2026, 10, 21, 8, tzinfo=UTC)
OLD = NOW - timedelta(hours=30)
BASIC = ProductCapability.basicResumeCompose
TARGETED = ProductCapability.targetedResumeOptimization


def service(tmp_path: Path, *, maximumCalls: int = 20) -> GuestIdentityService:
    return GuestIdentityService(tmp_path / "guests.sqlite3", maximumMonthlyCalls=maximumCalls)


def test_expiry_six_hour_boundary_repeated_sweep_and_active_token_preservation(
    tmp_path: Path,
) -> None:
    guests = service(tmp_path)
    expired = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    near = guests.createSession(
        "b" * 64, clientAddress="synthetic", nowUtc=OLD + timedelta(microseconds=1)
    )
    active = guests.createSession("c" * 64, clientAddress="synthetic", nowUtc=NOW)
    worker = GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
    assert worker.inspect()["dueSessionTokens"] == 1
    first = worker.clearExpiredSessions()
    assert first.clearedSessions == 1 and first.invalidRecords == 0
    assert worker.clearExpiredSessions().clearedSessions == 0
    with guests.database.readConnection() as connection:
        row = connection.execute(
            "SELECT token_hash,session_expires_at_utc FROM guest_identities WHERE guest_id=?",
            (expired.guestId,),
        ).fetchone()
        assert tuple(row) == (None, None)
        assert connection.execute("SELECT COUNT(*) FROM guest_identities").fetchone()[0] == 3
    assert guests.authenticate(active.sessionToken, nowUtc=NOW) == active.guestId
    with pytest.raises(AuthenticationFailedError):
        guests.authenticate(expired.sessionToken, nowUtc=NOW)
    assert worker.clearExpiredSessions(lookAheadSeconds=300).clearedSessions == 1
    with pytest.raises(AuthenticationFailedError):
        guests.authenticate(near.sessionToken, nowUtc=NOW)
    assert guests.authenticate(active.sessionToken, nowUtc=NOW) == active.guestId


def test_reentry_keeps_identity_installation_issuance_pending_usage_and_global_cost_bound(
    tmp_path: Path,
) -> None:
    guests = service(tmp_path, maximumCalls=2)
    issued = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    for capability in (BASIC, TARGETED):
        guests.usagePolicy.reserveUsage(
            accountId=issued.guestId,
            capability=capability,
            idempotencyKey=capability.value,
            requestFingerprint="synthetic",
            nowUtc=OLD,
        )
    queries = (
        "SELECT guest_id,credential_hash,created_at_utc,last_seen_at_utc "
        "FROM guest_identities ORDER BY guest_id",
        "SELECT * FROM guest_issuance ORDER BY bucket_hash",
        "SELECT * FROM usage_operations ORDER BY operation_id",
        "SELECT * FROM usage_reconciliations ORDER BY operation_id",
    )
    with guests.database.readConnection() as connection:
        before = [connection.execute(query).fetchall() for query in queries]
    assert (
        GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
        .clearExpiredSessions()
        .clearedSessions
        == 1
    )
    with guests.database.readConnection() as connection:
        assert [connection.execute(query).fetchall() for query in queries] == before
    reopened = GuestIdentityService(guests.database.databasePath, maximumMonthlyCalls=2)
    renewed = reopened.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
    assert renewed.guestId == issued.guestId
    assert reopened.authenticate(renewed.sessionToken, nowUtc=NOW) == issued.guestId
    for capability in (BASIC, TARGETED):
        with pytest.raises(MonthlyQuotaExhaustedError):
            reopened.usagePolicy.reserveUsage(
                accountId=issued.guestId,
                capability=capability,
                idempotencyKey="new-attempt",
                requestFingerprint="synthetic",
                nowUtc=NOW,
            )
    another = reopened.createSession("b" * 64, clientAddress="synthetic", nowUtc=NOW)
    with pytest.raises(GuestLimitError):
        reopened.usagePolicy.reserveUsage(
            accountId=another.guestId,
            capability=BASIC,
            idempotencyKey="another-owner",
            requestFingerprint="synthetic",
            nowUtc=NOW,
        )


def test_replacement_and_cleanup_race_keep_fresh_session_and_no_old_token_history(
    tmp_path: Path,
) -> None:
    guests = service(tmp_path)
    old = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    barrier = Barrier(2)

    def sweep() -> int:
        barrier.wait(timeout=10)
        return (
            GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
            .clearExpiredSessions()
            .clearedSessions
        )

    def renew() -> str:
        barrier.wait(timeout=10)
        session = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
        assert session.guestId == old.guestId
        return session.sessionToken

    with ThreadPoolExecutor(max_workers=2) as executor:
        cleared, renewed = executor.submit(sweep), executor.submit(renew)
        assert cleared.result(timeout=15) in (0, 1)
        freshToken = renewed.result(timeout=15)
    assert guests.authenticate(freshToken, nowUtc=NOW) == old.guestId
    with pytest.raises(AuthenticationFailedError):
        guests.authenticate(old.sessionToken, nowUtc=NOW)
    with guests.database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM guest_identities").fetchone()[0] == 1
        assert (
            connection.execute(
                "SELECT COUNT(*) FROM guest_identities WHERE token_hash=?",
                (hashlib.sha256(old.sessionToken.encode()).hexdigest(),),
            ).fetchone()[0]
            == 0
        )


def test_pagination_clears_all_101_and_reports_inconsistent_expired_pair(tmp_path: Path) -> None:
    guests = GuestIdentityService(
        tmp_path / "guests.sqlite3", maximumMonthlyCalls=20, maximumDailyIssuancePerIp=200
    )
    for i in range(101):
        guests.createSession(f"{i:064x}", clientAddress="synthetic", nowUtc=OLD)
    worker = GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
    first = worker.clearExpiredSessions()
    assert first.clearedSessions == 100 and first.moreCandidates and first.nextGuestId is not None
    assert worker.clearExpiredSessions(afterGuestId=first.nextGuestId).clearedSessions == 1
    broken = guests.createSession("f" * 64, clientAddress="synthetic", nowUtc=OLD)
    with guests.database.immediateTransaction() as connection:
        connection.execute(
            "UPDATE guest_identities SET token_hash=NULL WHERE guest_id=?", (broken.guestId,)
        )
    assert worker.inspect()["inconsistentSessionPairs"] == 1
    result = worker.clearExpiredSessions()
    assert result.invalidRecords == 1 and result.clearedSessions == 0


@pytest.mark.parametrize("kind", ["missing", "account", "wrong_guest_schema"])
def test_refuses_missing_or_wrong_database_without_initializing_or_migrating(
    tmp_path: Path, kind: str
) -> None:
    path = tmp_path / "target.sqlite3"
    if kind == "missing":
        with pytest.raises(ValueError, match="existing_private_guest_database_required"):
            GuestSessionRetentionWorker(path)
        assert not path.exists()
        return
    if kind == "account":
        GatewayDatabase(path).initialize()
    else:
        guests = service(tmp_path)
        path = guests.database.databasePath
        with guests.database.immediateTransaction() as connection:
            connection.execute("PRAGMA user_version=1802")
    before = path.read_bytes()
    worker = GuestSessionRetentionWorker(path, clock=lambda: NOW)
    with pytest.raises(UnsupportedDatabaseSchemaError):
        worker.inspect()
    with pytest.raises(UnsupportedDatabaseSchemaError):
        worker.clearExpiredSessions()
    assert path.read_bytes() == before


def test_rejects_changed_schema_with_same_version_and_preserves_data(tmp_path: Path) -> None:
    guests = service(tmp_path)
    guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    with guests.database.immediateTransaction() as connection:
        connection.execute("CREATE TABLE unrelated_private_data(value TEXT)")
    with pytest.raises(UnsupportedDatabaseSchemaError):
        GuestSessionRetentionWorker(
            guests.database.databasePath, clock=lambda: NOW
        ).clearExpiredSessions()
    with guests.database.readConnection() as connection:
        assert (
            connection.execute("SELECT COUNT(token_hash) FROM guest_identities").fetchone()[0] == 1
        )


def test_cli_defaults_read_only_requires_explicit_target_and_only_reports_counts(
    tmp_path: Path,
) -> None:
    guests = service(tmp_path)
    guests.createSession(
        "a" * 64, clientAddress="synthetic", nowUtc=datetime.now(UTC) - timedelta(hours=31)
    )
    root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(root / "src")
    command = [
        sys.executable,
        str(root / "scripts/manage_guest_sessions.py"),
        "clear-expired",
        "--database",
        str(guests.database.databasePath),
    ]
    dry = subprocess.run(command, env=environment, capture_output=True, check=False)  # noqa: S603
    assert dry.returncode == 0 and json.loads(dry.stdout)["dueSessionTokens"] == 1
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
    assert applied.returncode == 0 and result["clearedSessions"] == 1
    assert result["maximumHoursAfterExpiry"] == 6
    assert b"guest-" not in applied.stdout and b"token_hash" not in applied.stdout
    with sqlite3.connect(guests.database.databasePath) as connection:
        assert connection.execute("SELECT COUNT(*) FROM guest_identities").fetchone()[0] == 1
        assert (
            connection.execute("SELECT COUNT(token_hash) FROM guest_identities").fetchone()[0] == 0
        )


def test_invalid_bounds_do_not_clear_anything(tmp_path: Path) -> None:
    guests = service(tmp_path)
    guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    worker = GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
    with pytest.raises(ValueError, match="invalid_guest_retention_bound"):
        worker.clearExpiredSessions(maximumSessions=0)
    with pytest.raises(ValueError, match="invalid_guest_retention_bound"):
        worker.clearExpiredSessions(lookAheadSeconds=301)
    assert worker.inspect()["storedSessionTokens"] == 1
