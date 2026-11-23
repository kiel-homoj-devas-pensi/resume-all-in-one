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
from agent_gateway.usage import ProductCapability

NOW = datetime(2026, 10, 21, 6, tzinfo=UTC)


def bucket(day: str, source: str = "synthetic") -> str:
    return day + ":" + hashlib.sha256((day + source).encode()).hexdigest()


def rows(guests: GuestIdentityService, table: str) -> list[tuple[object, ...]]:
    query = {
        "guest_issuance": "SELECT * FROM guest_issuance ORDER BY 1",
        "guest_identities": "SELECT * FROM guest_identities ORDER BY 1",
        "usage_operations": "SELECT * FROM usage_operations ORDER BY 1",
    }[table]
    with guests.database.readConnection() as connection:
        return [tuple(row) for row in connection.execute(query)]


@pytest.mark.parametrize(
    ("now", "removed"),
    [(NOW - timedelta(microseconds=1), 0), (NOW, 1), (NOW + timedelta(days=1), 2)],
)
def test_utc_day_end_plus_six_hours_preserves_current_and_future(
    tmp_path: Path, now: datetime, removed: int
) -> None:
    guests = GuestIdentityService(tmp_path / "guests.sqlite3", maximumMonthlyCalls=1)
    with guests.database.immediateTransaction() as connection:
        connection.executemany(
            "INSERT INTO guest_issuance VALUES (?,?)",
            [(bucket(day), 1) for day in ["2026-10-20", "2026-10-21", "2026-10-23"]],
        )
    worker = GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: now)
    assert worker.inspect()["dueIssuanceBuckets"] == removed
    assert worker.purgeExpiredIssuance().purgedBuckets == removed
    assert worker.purgeExpiredIssuance().purgedBuckets == 0
    assert len(rows(guests, "guest_issuance")) == 3 - removed


def test_current_limit_history_and_usage_are_unchanged(tmp_path: Path) -> None:
    guests = GuestIdentityService(
        tmp_path / "guests.sqlite3", maximumMonthlyCalls=1, maximumDailyIssuancePerIp=1
    )
    session = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
    guests.usagePolicy.reserveUsage(
        accountId=session.guestId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="pending",
        requestFingerprint="synthetic",
        nowUtc=NOW,
    )
    with guests.database.immediateTransaction() as connection:
        connection.execute("INSERT INTO guest_issuance VALUES (?,9)", (bucket("2026-10-20"),))
    identities, usage = rows(guests, "guest_identities"), rows(guests, "usage_operations")
    worker = GuestSessionRetentionWorker(guests.database.databasePath, clock=lambda: NOW)
    assert worker.purgeExpiredIssuance().purgedBuckets == 1
    assert rows(guests, "guest_identities") == identities
    assert rows(guests, "usage_operations") == usage
    with pytest.raises(GuestLimitError):
        guests.createSession("b" * 64, clientAddress="synthetic", nowUtc=NOW)
    assert rows(guests, "guest_issuance") == [(bucket("2026-10-21"), 1)]


def test_request_path_uses_same_cutoff_without_requiring_maintenance(tmp_path: Path) -> None:
    guests = GuestIdentityService(tmp_path / "guests.sqlite3", maximumMonthlyCalls=1)
    guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW - timedelta(days=1))
    guests.createSession("b" * 64, clientAddress="synthetic", nowUtc=NOW - timedelta(seconds=1))
    assert len(rows(guests, "guest_issuance")) == 2
    guests.createSession("c" * 64, clientAddress="synthetic", nowUtc=NOW)
    assert rows(guests, "guest_issuance") == [(bucket("2026-10-21"), 2)]


def test_bounded_paging_invalid_records_and_safe_schedule_allowance(tmp_path: Path) -> None:
    guests = GuestIdentityService(tmp_path / "guests.sqlite3", maximumMonthlyCalls=1)
    with guests.database.immediateTransaction() as connection:
        connection.executemany(
            "INSERT INTO guest_issuance VALUES (?,1)",
            [(bucket("2026-10-20", str(i)),) for i in range(101)],
        )
        connection.execute("INSERT INTO guest_issuance VALUES ('0000-invalid',1)")
    worker = GuestSessionRetentionWorker(
        guests.database.databasePath, clock=lambda: NOW - timedelta(seconds=300)
    )
    assert worker.purgeExpiredIssuance().purgedBuckets == 0
    first = worker.purgeExpiredIssuance(lookAheadSeconds=300)
    assert first.invalidRecords == 1 and first.purgedBuckets == 99 and first.moreCandidates
    assert first.nextBucket is not None
    second = worker.purgeExpiredIssuance(afterBucket=first.nextBucket, lookAheadSeconds=300)
    assert second.purgedBuckets == 2 and not second.moreCandidates
    assert rows(guests, "guest_issuance") == [("0000-invalid", 1)]


def test_concurrent_new_issuance_keeps_new_daily_counter(tmp_path: Path) -> None:
    guests = GuestIdentityService(
        tmp_path / "guests.sqlite3", maximumMonthlyCalls=1, maximumDailyIssuancePerIp=1
    )
    guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW - timedelta(days=1))
    barrier = Barrier(2)

    def purge() -> None:
        barrier.wait()
        GuestSessionRetentionWorker(
            guests.database.databasePath, clock=lambda: NOW
        ).purgeExpiredIssuance()

    def enter() -> None:
        barrier.wait()
        guests.createSession("b" * 64, clientAddress="synthetic", nowUtc=NOW)

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(purge), pool.submit(enter)]
        for future in futures:
            future.result(timeout=10)
    assert rows(guests, "guest_issuance") == [(bucket("2026-10-21"), 1)]
    with pytest.raises(GuestLimitError):
        guests.createSession("c" * 64, clientAddress="synthetic", nowUtc=NOW)


def test_cli_default_dry_and_target_required_then_apply(tmp_path: Path) -> None:
    guests = GuestIdentityService(tmp_path / "guests.sqlite3", maximumMonthlyCalls=1)
    old = (datetime.now(UTC) - timedelta(days=3)).date().isoformat()
    with guests.database.immediateTransaction() as connection:
        connection.execute("INSERT INTO guest_issuance VALUES (?,1)", (bucket(old),))
    root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(root / "src")
    command = [
        sys.executable,
        str(root / "scripts/manage_guest_sessions.py"),
        "purge-expired-issuance",
        "--database",
        str(guests.database.databasePath),
    ]
    dry = subprocess.run(command, env=environment, capture_output=True, check=False)  # noqa: S603
    assert dry.returncode == 0 and json.loads(dry.stdout)["dueIssuanceBuckets"] == 1
    assert len(rows(guests, "guest_issuance")) == 1
    denied = subprocess.run(  # noqa: S603
        command + ["--apply"], env=environment, capture_output=True, check=False
    )
    assert denied.returncode == 1 and len(rows(guests, "guest_issuance")) == 1
    applied = subprocess.run(  # noqa: S603
        command + ["--apply", "--confirmed-target"],
        env=environment,
        capture_output=True,
        check=False,
    )
    result = json.loads(applied.stdout)
    assert applied.returncode == 0 and result["purgedIssuanceBuckets"] == 1
    assert result["maximumHoursAfterWindowEnd"] == 6 and result["supplierRequests"] == 0
