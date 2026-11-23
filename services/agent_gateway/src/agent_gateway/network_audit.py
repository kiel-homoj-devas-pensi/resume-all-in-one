"""Private, per-event calendar retention; no size-based eviction of network logs."""

from __future__ import annotations

import calendar
import logging
import re
import sqlite3
import sys
from collections.abc import Callable, Iterator
from contextlib import closing, contextmanager
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path
from threading import Event, Thread
from uuid import uuid4

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from .contracts import GatewayError, GatewayErrorResponse
from .database import GatewayDatabase
from .identity import requireUtc, toUtcText

AUDIT_SCHEMA_VERSION = 1901
AUDIT_RETENTION_MONTHS = 6
_SCHEMA = (
    "CREATE TABLE network_events (event_id INTEGER PRIMARY KEY AUTOINCREMENT, "
    "created_at_utc TEXT NOT NULL, "
    "expires_at_utc TEXT NOT NULL, level TEXT NOT NULL, message TEXT NOT NULL, "
    "hold_until_utc TEXT, hold_reference_sha256 TEXT, "
    "CHECK((hold_until_utc IS NULL)=(hold_reference_sha256 IS NULL)))",
    "CREATE INDEX network_events_expiry ON network_events(expires_at_utc,event_id)",
)


def auditExpiry(created: datetime) -> datetime:
    # Mainland service uses Beijing calendar months; persist normalized UTC.
    created = requireUtc(created).astimezone(timezone(timedelta(hours=8)))
    monthIndex = created.year * 12 + created.month - 1 + AUDIT_RETENTION_MONTHS
    year, month = divmod(monthIndex, 12)
    month += 1
    return created.replace(
        year=year, month=month, day=min(created.day, calendar.monthrange(year, month)[1])
    ).astimezone(UTC)


def _utc(value: str) -> datetime:
    result = requireUtc(datetime.fromisoformat(value))
    if toUtcText(result) != value:
        raise ValueError("audit_timestamp_invalid")
    return result


def _path(path: Path, *, allowMissing: bool = False) -> Path:
    if (
        not path.is_absolute()
        or not path.parent.is_dir()
        or any(p.is_symlink() or p.is_junction() for p in (path, *path.parents))
        or (not allowMissing and not path.is_file())
        or (path.exists() and (not path.is_file() or path.stat().st_nlink != 1))
        or any(Path(str(path) + suffix).is_symlink() for suffix in ("-wal", "-shm", "-journal"))
    ):
        raise ValueError("private_existing_audit_target_required")
    if str(path).startswith(("\\\\", "//")) or (":" in path.name):
        raise ValueError("local_audit_target_required")
    return path.resolve(strict=not allowMissing)


def _schema(connection: sqlite3.Connection) -> None:
    if connection.execute("PRAGMA user_version").fetchone()[0] != AUDIT_SCHEMA_VERSION:
        raise ValueError("audit_schema_mismatch")
    with closing(sqlite3.connect(":memory:")) as expected:
        for statement in _SCHEMA:
            expected.execute(statement)
        if GatewayDatabase._schemaStatements(connection) != GatewayDatabase._schemaStatements(
            expected
        ):
            raise ValueError("audit_schema_mismatch")


class NetworkAuditStore:
    def __init__(
        self, path: Path, *, clock: Callable[[], datetime] = lambda: datetime.now(UTC)
    ) -> None:
        self.path = _path(path, allowMissing=True)
        self.clock = clock

    def initialize(self) -> None:
        # Exclusive file creation prevents initializing an unrelated empty file.
        if not self.path.exists():
            with self.path.open("xb"):
                pass
            with closing(sqlite3.connect(self.path)) as connection:
                connection.execute("PRAGMA secure_delete=ON")
                for statement in _SCHEMA:
                    connection.execute(statement)
                connection.execute(f"PRAGMA user_version={AUDIT_SCHEMA_VERSION}")
                connection.commit()
        with self._connection(write=False) as connection:
            _schema(connection)

    @contextmanager
    def _connection(self, *, write: bool) -> Iterator[sqlite3.Connection]:
        target = _path(self.path)
        with closing(
            sqlite3.connect(
                target.as_uri() + ("?mode=rw" if write else "?mode=ro"),
                uri=True,
                isolation_level=None,
                timeout=5,
            )
        ) as connection:
            if write:
                connection.execute("PRAGMA secure_delete=ON")
                connection.execute("BEGIN IMMEDIATE")
            try:
                yield connection
                if write:
                    connection.commit()
            except Exception:
                if write:
                    connection.rollback()
                raise

    def append(self, level: str, message: str) -> None:
        if (
            level not in {"INFO", "WARNING", "ERROR", "CRITICAL"}
            or not 1 <= len(message.encode("utf-8")) <= 4096
            or any(ord(c) < 32 or ord(c) == 127 for c in message)
        ):
            raise ValueError("audit_event_invalid")
        created = requireUtc(self.clock())
        with self._connection(write=True) as connection:
            connection.execute(
                "INSERT INTO network_events(created_at_utc,expires_at_utc,level,message) "
                "VALUES (?,?,?,?)",
                (toUtcText(created), toUtcText(auditExpiry(created)), level, message),
            )

    def inspect(self) -> dict[str, int]:
        now = toUtcText(requireUtc(self.clock()))
        with self._connection(write=False) as connection:
            _schema(connection)
            row = connection.execute(
                "SELECT COUNT(*),COALESCE(SUM(expires_at_utc<=? AND "
                "(hold_until_utc IS NULL OR hold_until_utc<=?)),0),"
                "COALESCE(SUM(hold_until_utc>?),0) FROM network_events",
                (now, now, now),
            ).fetchone()
            if row is None:
                raise ValueError("audit_inspection_failed")
            return dict(
                zip(("storedEvents", "dueEvents", "heldEvents"), map(int, row), strict=True)
            )

    def purge(self, *, maximumEvents: int = 1000) -> dict[str, int | bool]:
        if type(maximumEvents) is not int or not 1 <= maximumEvents <= 1000:
            raise ValueError("audit_bound_invalid")
        now = requireUtc(self.clock())
        nowText = toUtcText(now)
        with self._connection(write=True) as connection:
            _schema(connection)
            rows = connection.execute(
                "SELECT event_id,created_at_utc,expires_at_utc,"
                "hold_until_utc,hold_reference_sha256 "
                "FROM network_events WHERE expires_at_utc<=? AND "
                "(hold_until_utc IS NULL OR hold_until_utc<=?) "
                "ORDER BY expires_at_utc,event_id LIMIT ?",
                (nowText, nowText, maximumEvents + 1),
            ).fetchall()
            removed = invalid = 0
            for eventId, created, expiry, hold, reference in rows[:maximumEvents]:
                try:
                    if (
                        auditExpiry(_utc(created)) != _utc(expiry)
                        or _utc(expiry) > now
                        or (hold is None) != (reference is None)
                        or (
                            hold is not None
                            and (
                                _utc(hold) > now or re.fullmatch(r"[a-f0-9]{64}", reference) is None
                            )
                        )
                    ):
                        raise ValueError("audit_record_invalid")
                except TypeError, ValueError:
                    invalid += 1
                    continue
                removed += connection.execute(
                    "DELETE FROM network_events WHERE event_id=?", (eventId,)
                ).rowcount
        return {
            "removedEvents": removed,
            "invalidRecords": invalid,
            "moreCandidates": len(rows) > maximumEvents,
        }

    def hold(self, eventId: int, untilText: str, reference: str) -> None:
        if (
            type(eventId) is not int
            or eventId < 1
            or _utc(untilText) <= requireUtc(self.clock())
            or re.fullmatch(r"[a-f0-9]{64}", reference) is None
        ):
            raise ValueError("audit_hold_invalid")
        with self._connection(write=True) as connection:
            _schema(connection)
            changed = connection.execute(
                "UPDATE network_events SET hold_until_utc=?,hold_reference_sha256=? "
                "WHERE event_id=? AND (hold_until_utc IS NULL OR hold_until_utc<=?)",
                (untilText, reference, eventId, untilText),
            ).rowcount
            if changed != 1:
                raise ValueError("audit_hold_target_unavailable")


class NetworkAuditHandler(logging.Handler):
    def __init__(self, store: NetworkAuditStore, *, sweepSeconds: float = 300) -> None:
        super().__init__()
        if not 0.01 <= sweepSeconds <= 300:
            raise ValueError("audit_sweep_interval_invalid")
        self.store = store
        self.writeFailed = Event()
        self.maintenanceFailed = Event()
        self._stop = Event()
        self._sweepSeconds = sweepSeconds
        store.initialize()
        self.sweep()
        self._thread = Thread(target=self._maintain, name="network-audit-retention", daemon=True)
        self._thread.start()

    @property
    def healthy(self) -> bool:
        return not self.writeFailed.is_set() and not self.maintenanceFailed.is_set()

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self.store.append(record.levelname, record.getMessage())
        except Exception:
            self.writeFailed.set()
            print("network_audit_write_failed; new_requests_paused", file=sys.stderr)

    def sweep(self) -> None:
        try:
            for _ in range(100):
                if self._stop.is_set():
                    return
                batch = self.store.purge()
                if batch["invalidRecords"]:
                    raise ValueError("audit_invalid_records")
                if not batch["moreCandidates"]:
                    self.maintenanceFailed.clear()
                    return
            raise ValueError("audit_scan_limit")
        except Exception:
            self.maintenanceFailed.set()
            print("network_audit_retention_failed; new_requests_paused", file=sys.stderr)

    def _maintain(self) -> None:
        while not self._stop.wait(self._sweepSeconds):
            self.sweep()

    def close(self) -> None:
        if hasattr(self, "_stop"):
            self._stop.set()
        if hasattr(self, "_thread"):
            self._thread.join(timeout=10)
        super().close()


class AuditAvailabilityBoundary:
    def __init__(self, app: ASGIApp, handler: NetworkAuditHandler) -> None:
        self._app = app
        self._handler = handler

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if (
            scope["type"] == "http"
            and scope.get("path") != "/health/live"
            and not self._handler.healthy
        ):
            error = GatewayErrorResponse(
                error=GatewayError(
                    code="audit_unavailable",
                    message="服务暂不可用，请稍后查看原请求状态",
                    operationId=f"operation-{uuid4()}",
                    retryable=False,
                )
            )
            await JSONResponse(error.model_dump(mode="json", exclude_none=True), status_code=503)(
                scope, receive, send
            )
            return
        await self._app(scope, receive, send)
