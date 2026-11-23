from __future__ import annotations

import json
import logging
import os
import sqlite3
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path
from threading import Barrier, Event

import pytest
import uvicorn
from fastapi import FastAPI
from starlette.testclient import TestClient

from agent_gateway import protected_startup as startup
from agent_gateway.identity import toUtcText
from agent_gateway.network_audit import (
    AuditAvailabilityBoundary,
    NetworkAuditHandler,
    NetworkAuditStore,
    auditExpiry,
)
from agent_gateway.settings import GatewaySettings

NOW = datetime(2026, 10, 21, 8, tzinfo=UTC)


def storeAt(tmp_path: Path, now: datetime) -> NetworkAuditStore:
    store = NetworkAuditStore(tmp_path / "network-audit.sqlite3", clock=lambda: now)
    store.initialize()
    return store


@pytest.mark.parametrize(
    ("created", "expiry"),
    [
        ("2026-08-31T12:34:56+00:00", "2027-02-28T12:34:56+00:00"),
        ("2027-08-31T12:34:56+00:00", "2028-02-29T12:34:56+00:00"),
        ("2026-10-21T08:00:00+00:00", "2027-04-21T08:00:00+00:00"),
        ("2026-08-30T20:00:00+00:00", "2027-02-27T20:00:00+00:00"),
    ],
)
def test_calendar_months_preserve_time_and_handle_month_end(created: str, expiry: str) -> None:
    assert auditExpiry(datetime.fromisoformat(created)) == datetime.fromisoformat(expiry)


def test_no_size_eviction_exact_expiry_and_repeated_purge(tmp_path: Path) -> None:
    store = storeAt(tmp_path, NOW)
    for _ in range(20):
        store.append("INFO", "synthetic " + "a" * 4000)
    assert store.inspect()["storedEvents"] == 20
    store.clock = lambda: auditExpiry(NOW) - timedelta(microseconds=1)
    assert store.purge()["removedEvents"] == 0
    store.clock = lambda: auditExpiry(NOW)
    assert store.purge(maximumEvents=7)["moreCandidates"] is True
    assert store.inspect()["storedEvents"] == 13
    assert store.purge()["removedEvents"] == 13
    assert store.purge()["removedEvents"] == 0


def test_specific_finite_hold_does_not_extend_other_records(tmp_path: Path) -> None:
    store = storeAt(tmp_path, NOW)
    store.append("INFO", "first")
    store.append("INFO", "second")
    until = toUtcText(auditExpiry(NOW) + timedelta(days=1))
    store.hold(1, until, "a" * 64)
    store.clock = lambda: auditExpiry(NOW)
    assert store.inspect()["heldEvents"] == 1
    assert store.purge()["removedEvents"] == 1
    with pytest.raises(ValueError):
        store.hold(1, toUtcText(auditExpiry(NOW) + timedelta(hours=1)), "b" * 64)
    store.clock = lambda: auditExpiry(NOW) + timedelta(days=1)
    assert store.purge()["removedEvents"] == 1


def test_purged_event_identifier_is_not_reused_for_later_hold(tmp_path: Path) -> None:
    store = storeAt(tmp_path, NOW)
    store.append("INFO", "old")
    store.clock = lambda: auditExpiry(NOW)
    assert store.purge()["removedEvents"] == 1
    store.append("INFO", "fresh")
    with pytest.raises(ValueError):
        store.hold(1, toUtcText(auditExpiry(NOW) + timedelta(days=1)), "a" * 64)
    assert store.inspect()["heldEvents"] == 0


def test_corrupt_expiry_is_reported_instead_of_early_deletion(tmp_path: Path) -> None:
    store = storeAt(tmp_path, NOW)
    store.append("INFO", "synthetic")
    with sqlite3.connect(store.path) as connection:
        connection.execute("UPDATE network_events SET expires_at_utc=?", (toUtcText(NOW),))
    assert store.purge()["invalidRecords"] == 1
    assert store.inspect()["storedEvents"] == 1


def test_maintenance_never_creates_or_migrates_wrong_database(tmp_path: Path) -> None:
    store = NetworkAuditStore(tmp_path / "missing.sqlite3")
    with pytest.raises(ValueError):
        store.inspect()
    assert not store.path.exists()
    sqlite3.connect(store.path).close()
    before = store.path.read_bytes()
    with pytest.raises(ValueError):
        store.initialize()
    assert store.path.read_bytes() == before


def test_concurrent_append_and_expired_purge_preserve_fresh_event(tmp_path: Path) -> None:
    store = storeAt(tmp_path, NOW)
    store.append("INFO", "old")
    fresh = NetworkAuditStore(store.path, clock=lambda: auditExpiry(NOW))
    barrier = Barrier(2)

    def append() -> None:
        barrier.wait()
        fresh.append("INFO", "fresh")

    def purge() -> None:
        barrier.wait()
        fresh.purge()

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(append), pool.submit(purge)]
        for future in futures:
            future.result(timeout=10)
    assert fresh.inspect()["storedEvents"] == 1
    with sqlite3.connect(store.path) as connection:
        assert connection.execute("SELECT message FROM network_events").fetchall() == [("fresh",)]


def test_idle_sweep_and_failure_redaction_gate_new_requests(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    store = storeAt(tmp_path, NOW)
    store.append("INFO", "old")
    handler = NetworkAuditHandler(store, sweepSeconds=0.02)
    observed = Event()
    original = store.purge

    def purge(*, maximumEvents: int = 1000) -> dict[str, int | bool]:
        result = original(maximumEvents=maximumEvents)
        if result["removedEvents"]:
            observed.set()
        return result

    monkeypatch.setattr(store, "purge", purge)
    store.clock = lambda: auditExpiry(NOW)
    try:
        assert observed.wait(timeout=2)

        def fail(level: str, message: str) -> None:
            raise RuntimeError("SYNTHETIC_SECRET_MUST_NOT_LEAK")

        monkeypatch.setattr(store, "append", fail)
        handler.handle(logging.LogRecord("audit", logging.INFO, "", 0, "safe", (), None))
        app = FastAPI()
        with TestClient(AuditAvailabilityBoundary(app, handler)) as client:
            response = client.post("/v2/account-sessions", json={})
            assert response.status_code == 503 and response.json()["error"]["retryable"] is False
            assert client.get("/health/ready").status_code == 503
            assert client.get("/health/live").status_code == 404  # Reached underlying app.
        assert "SYNTHETIC_SECRET" not in capsys.readouterr().err
    finally:
        handler.close()
    assert not handler._thread.is_alive()


def test_protected_startup_uses_new_store_preserves_legacy_log_and_closes_thread(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    legacy = tmp_path / "operations.log"
    legacy.write_text("legacy synthetic", encoding="utf-8")
    settings = GatewaySettings(remoteResultDirectory=tmp_path)
    monkeypatch.setattr(startup, "loadStartupSettings", lambda path: settings)
    monkeypatch.setattr(startup, "createApplication", lambda **kwargs: FastAPI())
    handlers: list[NetworkAuditHandler] = []

    def run(app: AuditAvailabilityBoundary, **kwargs: object) -> None:
        assert isinstance(app, AuditAvailabilityBoundary)
        handlers.append(app._handler)
        logging.getLogger("agent_gateway.audit").info("original_result_retention_unavailable")

    monkeypatch.setattr(uvicorn, "run", run)
    assert startup.main(["--configuration", str(tmp_path / "unused")]) == 0
    assert legacy.read_text(encoding="utf-8") == "legacy synthetic"
    assert NetworkAuditStore(tmp_path / "network-audit.sqlite3").inspect()["storedEvents"] == 1
    assert len(handlers) == 1 and not handlers[0]._thread.is_alive()


def test_cli_readonly_confirmation_and_hold_then_purge(tmp_path: Path) -> None:
    store = storeAt(tmp_path, NOW - timedelta(days=400))
    store.append("INFO", "synthetic")
    root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(root / "src")
    command = [sys.executable, str(root / "scripts/manage_network_audit.py")]
    target = ["--database", str(store.path)]
    dry = subprocess.run(command + ["purge"] + target, env=environment, capture_output=True)  # noqa: S603
    assert dry.returncode == 0 and json.loads(dry.stdout)["dueEvents"] == 1
    denied = subprocess.run(  # noqa: S603
        command + ["purge"] + target + ["--apply"], env=environment, capture_output=True
    )  # noqa: S603
    assert denied.returncode == 1
    held = subprocess.run(  # noqa: S603
        command
        + ["hold"]
        + target
        + [
            "--apply",
            "--confirmed-target",
            "--event-id",
            "1",
            "--hold-until-utc",
            toUtcText(datetime.now(UTC) + timedelta(days=1)),
            "--hold-reference-sha256",
            "a" * 64,
        ],
        env=environment,
        capture_output=True,
    )
    assert held.returncode == 0 and json.loads(held.stdout)["heldEvents"] == 1
    applied = subprocess.run(  # noqa: S603
        command + ["purge"] + target + ["--apply", "--confirmed-target"],
        env=environment,
        capture_output=True,
    )  # noqa: S603
    assert applied.returncode == 0 and json.loads(applied.stdout)["removedEvents"] == 0
