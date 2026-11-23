"""Explicit, bounded trial admission. No credentials or resume content are stored."""

from __future__ import annotations

import json
import sqlite3
from contextlib import closing
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4

from .identity import requireUtc
from .open_test import OpenTestPolicy, openTestActive
from .sms_budget import MINIMUM_PNVS_RESERVE_CENTS, SmsBudgetPolicy


class TrialAdmissionClosedError(RuntimeError):
    """No supplier request was started by this admission attempt."""


@dataclass(frozen=True, slots=True)
class VolunteerTrialPolicy:
    enabled: bool
    expiresAtUtc: datetime
    maximumModelStarts: int
    smsMaximumAttempts: int
    smsBudgetCents: int
    smsReservePerAttemptCents: int

    def __post_init__(self) -> None:
        if (
            type(self.enabled) is not bool
            or type(self.maximumModelStarts) is not int
            or not 1 <= self.maximumModelStarts <= 1000
        ):
            raise ValueError("invalid_trial_policy")
        requireUtc(self.expiresAtUtc)
        self.smsPolicy()

    def smsPolicy(self) -> SmsBudgetPolicy:
        return SmsBudgetPolicy(
            maximumAttempts=self.smsMaximumAttempts,
            budgetCents=self.smsBudgetCents,
            reservePerAttemptCents=self.smsReservePerAttemptCents,
            expiresAtUtc=self.expiresAtUtc,
            allowedPhones=frozenset(),
            recipientScope="unregistered",
            enabled=self.enabled,
        )


def _uniqueObject(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_trial_field")
        result[key] = value
    return result


def loadVolunteerTrialPolicy(path: Path) -> VolunteerTrialPolicy:
    for candidate in (path, *path.parents):
        if candidate.is_symlink() or candidate.is_junction():
            raise ValueError("redirected_trial_path")
    if not path.is_absolute() or path.stat().st_size > 4096:
        raise ValueError("invalid_trial_policy_path")
    value = json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=_uniqueObject)
    fields = {
        "schemaVersion",
        "enabled",
        "expiresAtUtc",
        "maximumModelStarts",
        "smsMaximumAttempts",
        "smsBudgetCents",
        "smsReservePerAttemptCents",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError("invalid_trial_fields")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise ValueError("invalid_trial_schema")
    if not isinstance(value["expiresAtUtc"], str):
        raise ValueError("invalid_trial_expiry")
    policy = VolunteerTrialPolicy(
        value["enabled"],
        datetime.fromisoformat(value["expiresAtUtc"].replace("Z", "+00:00")),
        value["maximumModelStarts"],
        value["smsMaximumAttempts"],
        value["smsBudgetCents"],
        value["smsReservePerAttemptCents"],
    )
    if policy.smsReservePerAttemptCents < MINIMUM_PNVS_RESERVE_CENTS:
        raise ValueError("invalid_trial_reservation")
    return policy


class TrialModelBudget:
    """One durable shared dispatch ledger for registered and guest supplier calls."""

    def __init__(
        self,
        path: Path,
        policy: VolunteerTrialPolicy,
        *,
        initialize: bool = False,
        openTestPolicy: OpenTestPolicy | None = None,
    ) -> None:
        self._path, self._policy = path, policy
        self._openTestPolicy = openTestPolicy
        if not path.is_absolute() or not path.parent.is_dir():
            raise ValueError("invalid_trial_database")
        for candidate in (path, *path.parents):
            if candidate.is_symlink() or candidate.is_junction():
                raise ValueError("redirected_trial_database")
        for suffix in ("-journal", "-wal", "-shm"):
            sidecar = Path(str(path) + suffix)
            if sidecar.is_symlink() or sidecar.is_junction():
                raise ValueError("redirected_trial_database")
        if not path.is_file() and not initialize:
            raise ValueError("trial_database_not_provisioned")
        with closing(
            sqlite3.connect(
                path.as_uri() + ("?mode=rwc" if initialize else "?mode=rw"), uri=True, timeout=2
            )
        ) as db:
            db.execute("BEGIN IMMEDIATE")
            version = db.execute("PRAGMA user_version").fetchone()[0]
            tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if version == 0 and not tables and initialize:
                db.execute(
                    "CREATE TABLE trial_policy (id INTEGER PRIMARY KEY CHECK(id=1), "
                    "maximum_starts INTEGER NOT NULL, expires_at TEXT NOT NULL)"
                )
                db.execute(
                    "CREATE TABLE trial_dispatches (dispatch_id TEXT PRIMARY KEY, "
                    "created_at TEXT NOT NULL)"
                )
                db.execute(
                    "INSERT INTO trial_policy VALUES(1,?,?)",
                    (policy.maximumModelStarts, policy.expiresAtUtc.isoformat()),
                )
                db.execute("PRAGMA user_version=1802")
            elif version != 1802 or tables != {"trial_policy", "trial_dispatches"}:
                raise ValueError("unexpected_trial_database")
            self._validate(db)
            db.commit()

    def _validate(self, db: sqlite3.Connection) -> int:
        row = db.execute("SELECT maximum_starts,expires_at FROM trial_policy WHERE id=1").fetchone()
        if row != (self._policy.maximumModelStarts, self._policy.expiresAtUtc.isoformat()):
            raise ValueError("trial_policy_changed_without_reconciliation")
        count = db.execute("SELECT COUNT(*) FROM trial_dispatches").fetchone()[0]
        if count < 0 or (self._openTestPolicy is None and count > self._policy.maximumModelStarts):
            raise ValueError("trial_ledger_inconsistent")
        return int(count)

    def snapshot(self) -> dict[str, str | int | bool]:
        with closing(sqlite3.connect(self._path.as_uri() + "?mode=ro", uri=True, timeout=2)) as db:
            db.execute("BEGIN")
            count = self._validate(db)
            return {
                "enabled": self._policy.enabled,
                "maximumStarts": self._policy.maximumModelStarts,
                "starts": count,
                "expiresAtUtc": self._policy.expiresAtUtc.isoformat(),
            }

    def reserve(self, *, nowUtc: datetime | None = None) -> str:
        now = requireUtc(nowUtc or datetime.now(UTC))
        unlimited = openTestActive(self._openTestPolicy, now)
        if not unlimited and (not self._policy.enabled or now >= self._policy.expiresAtUtc):
            raise TrialAdmissionClosedError("trial_closed")
        try:
            with closing(
                sqlite3.connect(self._path.as_uri() + "?mode=rw", uri=True, timeout=2)
            ) as db:
                db.execute("BEGIN IMMEDIATE")
                checked = requireUtc(nowUtc or datetime.now(UTC))
                unlimited = openTestActive(self._openTestPolicy, checked)
                if not unlimited and (
                    not self._policy.enabled or checked >= self._policy.expiresAtUtc
                ):
                    raise TrialAdmissionClosedError("trial_closed")
                if self._validate(db) >= self._policy.maximumModelStarts and not unlimited:
                    raise TrialAdmissionClosedError("trial_budget_exhausted")
                dispatchId = str(uuid4())
                db.execute(
                    "INSERT INTO trial_dispatches VALUES(?,?)", (dispatchId, now.isoformat())
                )
                db.commit()
                return dispatchId
        except TrialAdmissionClosedError:
            raise
        except Exception:
            # Includes uncertain commit: do not send, replay or reclaim a slot.
            raise TrialAdmissionClosedError("trial_admission_unavailable") from None
