from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path
from threading import Barrier

import pytest

from agent_gateway.guest_identity import GuestIdentityService, GuestLimitError
from agent_gateway.guest_session_retention import GuestSessionRetentionWorker
from agent_gateway.identity import AuthenticationFailedError
from agent_gateway.usage import MonthlyQuotaExhaustedError, ProductCapability

NOW = datetime(2026, 10, 21, 8, tzinfo=UTC)
OLD = NOW - timedelta(days=60)
BASIC = ProductCapability.basicResumeCompose
TARGETED = ProductCapability.targetedResumeOptimization


def service(tmp_path: Path) -> GuestIdentityService:
    return GuestIdentityService(tmp_path / "guests.sqlite3", maximumMonthlyCalls=1)


def test_sixty_day_boundary_unique_markers_and_repeated_clear(tmp_path: Path) -> None:
    guests = service(tmp_path)
    expired = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    near = guests.createSession(
        "b" * 64, clientAddress="synthetic", nowUtc=OLD + timedelta(microseconds=1)
    )
    worker = GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
    first = worker.clearIdleInstallations()
    assert first.clearedInstallations == 1 and first.invalidRecords == 0
    assert worker.clearIdleInstallations().clearedInstallations == 0
    with guests.database.readConnection() as connection:
        assert (
            connection.execute(
                "SELECT credential_hash FROM guest_identities WHERE guest_id=?", (expired.guestId,)
            ).fetchone()[0]
            == "cleared:" + expired.guestId
        )
        assert (
            connection.execute(
                "SELECT credential_hash FROM guest_identities WHERE guest_id=?", (near.guestId,)
            ).fetchone()[0]
            == hashlib.sha256(("b" * 64).encode()).hexdigest()
        )
    later = GuestSessionRetentionWorker(
        guests.database.databasePath, clock=lambda: NOW + timedelta(microseconds=1)
    )
    assert later.clearIdleInstallations().clearedInstallations == 1
    with guests.database.readConnection() as connection:
        assert (
            connection.execute(
                "SELECT COUNT(DISTINCT credential_hash) FROM guest_identities"
            ).fetchone()[0]
            == 2
        )


def test_expired_entry_is_new_identity_even_without_running_maintenance(tmp_path: Path) -> None:
    guests = service(tmp_path)
    old = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    fresh = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
    assert fresh.guestId != old.guestId
    assert (
        guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW).guestId
        == fresh.guestId
    )
    with pytest.raises(AuthenticationFailedError):
        guests.authenticate(old.sessionToken, nowUtc=NOW)
    with guests.database.readConnection() as connection:
        assert (
            connection.execute(
                "SELECT credential_hash FROM guest_identities WHERE guest_id=?", (old.guestId,)
            ).fetchone()[0]
            == "cleared:" + old.guestId
        )
        assert connection.execute("SELECT COUNT(*) FROM guest_identities").fetchone()[0] == 2


def test_last_entry_not_creation_controls_idle_age_and_keeps_current_quota(tmp_path: Path) -> None:
    guests = service(tmp_path)
    old = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    recent = guests.createSession(
        "a" * 64, clientAddress="synthetic", nowUtc=NOW - timedelta(hours=1)
    )
    assert recent.guestId == old.guestId
    guests.usagePolicy.reserveUsage(
        accountId=recent.guestId,
        capability=BASIC,
        idempotencyKey="current",
        requestFingerprint="synthetic",
        nowUtc=NOW,
    )
    assert (
        GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
        .clearIdleInstallations()
        .clearedInstallations
        == 0
    )
    assert guests.authenticate(recent.sessionToken, nowUtc=NOW) == old.guestId
    assert (
        guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW).guestId == old.guestId
    )
    with pytest.raises(MonthlyQuotaExhaustedError):
        guests.usagePolicy.reserveUsage(
            accountId=old.guestId,
            capability=BASIC,
            idempotencyKey="not-reset",
            requestFingerprint="synthetic",
            nowUtc=NOW,
        )


def test_historical_pending_usage_and_current_global_cost_bound_remain_unchanged(
    tmp_path: Path,
) -> None:
    guests = service(tmp_path)
    idle = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    guests.usagePolicy.reserveUsage(
        accountId=idle.guestId,
        capability=BASIC,
        idempotencyKey="historical-pending",
        requestFingerprint="synthetic",
        nowUtc=OLD,
    )
    current = guests.createSession("b" * 64, clientAddress="synthetic", nowUtc=NOW)
    guests.usagePolicy.reserveUsage(
        accountId=current.guestId,
        capability=TARGETED,
        idempotencyKey="current-pending",
        requestFingerprint="synthetic",
        nowUtc=NOW,
    )
    queries = (
        "SELECT guest_id,token_hash,session_expires_at_utc,created_at_utc,last_seen_at_utc "
        "FROM guest_identities ORDER BY guest_id",
        "SELECT * FROM guest_issuance ORDER BY bucket_hash",
        "SELECT * FROM usage_operations ORDER BY operation_id",
        "SELECT * FROM usage_reconciliations ORDER BY operation_id",
    )
    with guests.database.readConnection() as connection:
        before = [connection.execute(query).fetchall() for query in queries]
    assert (
        GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
        .clearIdleInstallations()
        .clearedInstallations
        == 1
    )
    with guests.database.readConnection() as connection:
        assert [connection.execute(query).fetchall() for query in queries] == before
    returned = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
    assert returned.guestId != idle.guestId
    with pytest.raises(GuestLimitError):
        guests.usagePolicy.reserveUsage(
            accountId=returned.guestId,
            capability=BASIC,
            idempotencyKey="no-free-cost-slot",
            requestFingerprint="synthetic",
            nowUtc=NOW,
        )


def test_concurrent_entry_and_clear_retire_old_association_exactly_once(tmp_path: Path) -> None:
    guests = service(tmp_path)
    old = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    barrier = Barrier(2)

    def clear() -> int:
        barrier.wait(timeout=10)
        return (
            GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
            .clearIdleInstallations()
            .clearedInstallations
        )

    def enter() -> str:
        barrier.wait(timeout=10)
        return guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW).guestId

    with ThreadPoolExecutor(max_workers=2) as executor:
        swept, entered = executor.submit(clear), executor.submit(enter)
        assert swept.result(timeout=15) in (0, 1)
        identity = entered.result(timeout=15)
    assert identity != old.guestId
    assert guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW).guestId == identity
    with guests.database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM guest_identities").fetchone()[0] == 2
        assert (
            connection.execute(
                "SELECT credential_hash FROM guest_identities WHERE guest_id=?", (old.guestId,)
            ).fetchone()[0]
            == "cleared:" + old.guestId
        )


def test_pagination_101_unique_retired_credentials(tmp_path: Path) -> None:
    guests = GuestIdentityService(
        tmp_path / "guests.sqlite3", maximumMonthlyCalls=1, maximumDailyIssuancePerIp=200
    )
    for i in range(101):
        guests.createSession(f"{i:064x}", clientAddress="synthetic", nowUtc=OLD)
    worker = GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
    first = worker.clearIdleInstallations()
    assert (
        first.clearedInstallations == 100 and first.moreCandidates and first.nextGuestId is not None
    )
    assert worker.clearIdleInstallations(afterGuestId=first.nextGuestId).clearedInstallations == 1
    assert worker.inspect()["storedInstallationCredentials"] == 0
    with guests.database.readConnection() as connection:
        assert (
            connection.execute(
                "SELECT COUNT(DISTINCT credential_hash) FROM guest_identities"
            ).fetchone()[0]
            == 101
        )


def test_bad_timestamp_is_visible_not_cleared(tmp_path: Path) -> None:
    guests = service(tmp_path)
    first = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    with guests.database.immediateTransaction() as connection:
        connection.execute(
            "UPDATE guest_identities SET created_at_utc='0000' WHERE guest_id=?", (first.guestId,)
        )
    worker = GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
    result = worker.clearIdleInstallations()
    assert result.invalidRecords == 1 and result.clearedInstallations == 0
    assert worker.inspect()["storedInstallationCredentials"] == 1


def test_retired_credential_cannot_bypass_closed_new_guest_admission(tmp_path: Path) -> None:
    guests = GuestIdentityService(
        tmp_path / "guests.sqlite3", maximumMonthlyCalls=1, enabledUntilUtc=OLD + timedelta(days=1)
    )
    guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=OLD)
    with pytest.raises(GuestLimitError):
        guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
    assert (
        GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
        .clearIdleInstallations()
        .clearedInstallations
        == 1
    )


def test_cli_dry_target_required_no_early_clear_and_explicit_apply(tmp_path: Path) -> None:
    guests = service(tmp_path)
    guests.createSession(
        "a" * 64, clientAddress="synthetic", nowUtc=datetime.now(UTC) - timedelta(days=61)
    )
    root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(root / "src")
    command = [
        sys.executable,
        str(root / "scripts/manage_guest_sessions.py"),
        "clear-idle-installations",
        "--database",
        str(guests.database.databasePath),
    ]
    dry = subprocess.run(command, env=environment, capture_output=True, check=False)  # noqa: S603
    assert dry.returncode == 0 and json.loads(dry.stdout)["dueIdleInstallations"] == 1
    denied = subprocess.run(  # noqa: S603
        command + ["--apply"], env=environment, capture_output=True, check=False
    )
    assert denied.returncode == 1
    early = subprocess.run(  # noqa: S603
        command + ["--look-ahead-seconds", "300"], env=environment, capture_output=True, check=False
    )
    assert early.returncode == 1
    applied = subprocess.run(  # noqa: S603
        command + ["--apply", "--confirmed-target"],
        env=environment,
        capture_output=True,
        check=False,
    )
    result = json.loads(applied.stdout)
    assert applied.returncode == 0 and result["clearedInstallations"] == 1
    assert result["idleNaturalDays"] == 60
