from __future__ import annotations

import json
import os
import runpy
import sqlite3
import subprocess
import sys
from collections.abc import Callable, Mapping
from contextlib import AbstractContextManager, nullcontext
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import cast

import pytest

from agent_gateway.account_retention import AccountRetentionWorker, recordRetentionHold
from agent_gateway.account_retention_permissions import (
    PURGE_TABLES,
    validatePurgerPrivileges,
    validateRetentionWebPrivileges,
)
from agent_gateway.account_retention_schema import (
    migrateSqliteRetentionSchema,
    validateSqliteRetentionSchema,
)
from agent_gateway.account_storage import (
    AccountSqlConnection,
    AccountSqlDatabase,
    SqliteAccountDatabase,
    StorageUnavailableError,
)
from agent_gateway.app import createApplication
from agent_gateway.database import GatewayDatabase, UnsupportedDatabaseSchemaError
from agent_gateway.identity import toUtcText
from agent_gateway.lifecycle_storage import SqliteLifecycleStore
from agent_gateway.privilege_schema import migrateSqlitePrivilegeSchema
from agent_gateway.recovery_schema import migrateSqliteRecoverySchema
from agent_gateway.settings import GatewaySettings
from agent_gateway.sms_phone_retention import SmsPhoneRetentionWorker

RETIRED = datetime(2026, 1, 1, tzinfo=UTC)
DUE = RETIRED + timedelta(days=60)


def database(tmp_path: Path) -> GatewayDatabase:
    db = GatewayDatabase(tmp_path / "synthetic.sqlite")
    db.initialize()
    migrateSqlitePrivilegeSchema(db)
    migrateSqliteRecoverySchema(db)
    migrateSqliteRetentionSchema(db)
    return db


def account(
    db: GatewayDatabase, name: str = "retired", *, active: bool = False, tracked: bool = True
) -> None:
    with db.immediateTransaction() as connection:
        connection.execute(
            "INSERT INTO accounts VALUES (?,?,?,?,?,?)",
            (name, "disabled:" + name, "", toUtcText(RETIRED), int(active), toUtcText(RETIRED)),
        )
        if tracked:
            connection.execute(
                "INSERT INTO account_retirements(account_id,deactivated_at_utc) VALUES (?,?)",
                (name, toUtcText(RETIRED)),
            )


def worker(db: GatewayDatabase, now: datetime = DUE) -> AccountRetentionWorker:
    return AccountRetentionWorker(SqliteAccountDatabase(db), clock=lambda: now)


def count(db: GatewayDatabase, table: str) -> int:
    assert table in {*PURGE_TABLES, "phone_challenges", "sms_send_attempts"}
    with db.readConnection() as connection:
        # Test-owned table names are restricted to the fixed allowlist above.
        return int(connection.execute("SELECT COUNT(*) FROM " + table).fetchone()[0])  # noqa: S608


def session(
    db: GatewayDatabase,
    name: str,
    *,
    expires: datetime,
    revoked: datetime | None = None,
) -> None:
    with db.immediateTransaction() as connection:
        connection.execute(
            "INSERT INTO account_sessions(session_id,account_id,token_hash,expires_at_utc,"
            "created_at_utc,revoked_at_utc) VALUES (?,?,?,?,?,?)",
            (
                name,
                "active",
                "digest-" + name,
                toUtcText(expires),
                toUtcText(RETIRED),
                None if revoked is None else toUtcText(revoked),
            ),
        )


def test_invalid_session_six_hour_boundary_keeps_active_account_and_usage(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db, "active", active=True, tracked=False)
    usage(db, "committed", name="active")
    boundary = DUE - timedelta(hours=6)
    session(db, "expired", expires=boundary)
    session(db, "revoked", expires=DUE + timedelta(days=1), revoked=boundary)
    session(db, "valid", expires=DUE + timedelta(days=1))
    session(db, "recent", expires=boundary + timedelta(microseconds=1))
    assert worker(db, DUE - timedelta(microseconds=1)).purgeInvalidSessions().deletedSessions == 0
    result = worker(db).purgeInvalidSessions()
    assert result.deletedSessions == 2
    assert count(db, "account_sessions") == 2
    assert count(db, "accounts") == 1 and count(db, "usage_operations") == 1
    assert worker(db).purgeInvalidSessions().deletedSessions == 0


def test_later_revocation_never_extends_already_expired_session(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db, "active", active=True, tracked=False)
    session(db, "expired-first", expires=DUE - timedelta(hours=7), revoked=DUE)
    session(db, "revoked-first", expires=DUE + timedelta(days=1), revoked=DUE - timedelta(hours=7))
    assert worker(db).purgeInvalidSessions().deletedSessions == 2


def test_session_sweep_lookahead_and_invalid_timestamp_are_observable(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db, "active", active=True, tracked=False)
    session(db, "due-next-sweep", expires=DUE - timedelta(hours=6) + timedelta(minutes=5))
    session(db, "not-yet-due", expires=DUE - timedelta(hours=5))
    session(db, "invalid-time", expires=DUE)
    with db.immediateTransaction() as connection:
        connection.execute(
            "UPDATE account_sessions SET expires_at_utc='0000' WHERE session_id='invalid-time'"
        )
    result = worker(db).purgeInvalidSessions(lookAheadSeconds=300)
    assert result.deletedSessions == 1 and result.invalidRecords == 1
    assert count(db, "account_sessions") == 2


def test_invalid_session_pagination_does_not_skip_or_delete_live_credentials(
    tmp_path: Path,
) -> None:
    db = database(tmp_path)
    account(db, "active", active=True, tracked=False)
    for number in range(101):
        session(db, f"s{number:03}", expires=DUE - timedelta(hours=7))
    session(db, "valid", expires=DUE + timedelta(days=1))
    first = worker(db).purgeInvalidSessions()
    assert first.deletedSessions == 100 and first.moreCandidates
    assert first.nextSessionId == "s099"
    last = worker(db).purgeInvalidSessions(afterSessionId=first.nextSessionId)
    assert last.deletedSessions == 1 and not last.moreCandidates and last.nextSessionId is None
    assert count(db, "account_sessions") == 1


@pytest.mark.parametrize(
    ("maximum", "lookAhead", "cursor"),
    [
        (0, 0, ""),
        (101, 0, ""),
        (True, 0, ""),
        (100, -1, ""),
        (100, 301, ""),
        (100, 0, "' OR 1=1"),
    ],
)
def test_invalid_session_cleanup_bounds_are_rejected(
    tmp_path: Path, maximum: int, lookAhead: int, cursor: str
) -> None:
    db = database(tmp_path)
    with pytest.raises(ValueError, match="invalid_session_retention_bound"):
        worker(db).purgeInvalidSessions(
            maximumSessions=maximum, lookAheadSeconds=lookAhead, afterSessionId=cursor
        )


def test_session_purge_cli_requires_apply_and_explicit_target(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db, "active", active=True, tracked=False)
    session(db, "old-session", expires=DUE)
    session(db, "valid-session", expires=datetime.now(UTC) + timedelta(days=1))
    root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment.update(
        {
            "GATEWAY_DATABASE_BACKEND": "sqlite",
            "AGENT_GATEWAY_TASK018_DATABASE_PATH": str(db.databasePath),
            "PYTHONPATH": str(root / "src"),
        }
    )
    command = [sys.executable, str(root / "scripts/manage_account_retention.py"), "purge-sessions"]
    dry = subprocess.run(command, env=environment, capture_output=True, check=False)  # noqa: S603
    assert dry.returncode == 0 and json.loads(dry.stdout)["writeRequested"] is False
    assert count(db, "account_sessions") == 2
    rejected = subprocess.run(  # noqa: S603
        command + ["--apply"], env=environment, capture_output=True, check=False
    )
    assert rejected.returncode == 1 and count(db, "account_sessions") == 2
    applied = subprocess.run(  # noqa: S603
        command + ["--apply", "--confirmed-target", "--look-ahead-seconds", "300"],
        env=environment,
        capture_output=True,
        check=False,
    )
    result = json.loads(applied.stdout)
    assert applied.returncode == 0 and result["deletedSessions"] == 1
    assert result["invalidSessionMaximumHours"] == 6
    assert "old-session" not in applied.stdout.decode()
    assert count(db, "account_sessions") == 1 and count(db, "accounts") == 1


def usage(db: GatewayDatabase, status: str, *, name: str = "retired") -> None:
    with db.immediateTransaction() as connection:
        connection.execute(
            "INSERT INTO usage_operations(operation_id,account_id,capability,idempotency_key_hash,"
            "request_fingerprint_hash,status,quota_window_start_utc,quota_window_end_utc,"
            "plan_at_reservation,created_at_utc,updated_at_utc) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (
                "operation-" + name,
                name,
                "basicResumeCompose",
                "key",
                "fingerprint",
                status,
                toUtcText(RETIRED),
                toUtcText(DUE),
                "free",
                toUtcText(RETIRED),
                toUtcText(RETIRED),
            ),
        )


def test_boundary_active_unknown_old_and_idempotent(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db)
    account(db, "active", active=True)
    account(db, "old-unknown", tracked=False)
    assert worker(db, DUE - timedelta(microseconds=1)).runBatch().deletedAccounts == 0
    batch = worker(db).runBatch()
    assert (batch.deletedAccounts, batch.unknownDeactivationTimes) == (1, 1)
    assert count(db, "accounts") == 2
    assert worker(db).runBatch().deletedAccounts == 0
    assert count(db, "account_retirements") == 1  # active anomaly is never deleted


@pytest.mark.parametrize("status", ["reserved", "pendingReconciliation"])
def test_unsettled_is_observable_and_rerunnable_after_settlement(
    tmp_path: Path, status: str
) -> None:
    db = database(tmp_path)
    account(db)
    usage(db, status)
    first = worker(db).runBatch()
    assert first.blockedUnsettledAccounts == 1 and first.deletedAccounts == 0
    assert count(db, "usage_operations") == 1
    with db.immediateTransaction() as connection:
        connection.execute("UPDATE usage_operations SET status='released'")
    assert worker(db).runBatch().deletedAccounts == 1
    assert count(db, "usage_operations") == 0


def test_settled_associations_deleted_without_phone_or_hash_tombstones(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db)
    usage(db, "committed")
    with db.immediateTransaction() as connection:
        connection.execute(
            "INSERT INTO usage_reconciliations VALUES (?,?,?,?,?)",
            ("operation-retired", "synthetic-operator", "a" * 64, "executed", toUtcText(RETIRED)),
        )
        connection.execute(
            "INSERT INTO account_recovery_codes VALUES (?,?,?)",
            ("retired", "a" * 64, toUtcText(RETIRED)),
        )
        connection.execute(
            "INSERT INTO account_sessions VALUES (?,?,?,?,?,?)",
            (
                "session",
                "retired",
                "token-digest",
                toUtcText(DUE),
                toUtcText(RETIRED),
                toUtcText(RETIRED),
            ),
        )
        connection.execute(
            "INSERT INTO subscription_snapshots VALUES (?,?,?,?,?,?)",
            ("retired", "pro", toUtcText(RETIRED), toUtcText(DUE), "fake", toUtcText(RETIRED)),
        )
        connection.execute(
            "INSERT INTO account_privilege_grants(grant_id,account_id,privilege,operator_id,"
            "evidence_sha256,granted_at_utc) VALUES (?,?,?,?,?,?)",
            (
                "grant",
                "retired",
                "permanentMember",
                "synthetic-operator",
                "a" * 64,
                toUtcText(RETIRED),
            ),
        )
        # Unlinked security/SMS challenge data is a different retention category.
        connection.execute(
            "INSERT INTO phone_challenges VALUES (?,?,?,?,?,?,?)",
            ("challenge", "phone-digest", "register", "code-digest", toUtcText(DUE), 0, None),
        )
    assert worker(db).runBatch().deletedAccounts == 1
    assert all(count(db, table) == 0 for table in PURGE_TABLES)
    assert count(db, "phone_challenges") == 1
    with db.readConnection() as connection:
        assert connection.execute("PRAGMA foreign_key_check").fetchall() == []


def test_earlier_verified_request_does_not_wait_sixty_days(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db)
    assert (
        worker(db, RETIRED).fulfillEarlierDeletion(
            accountId="retired", verifiedRequestSha256="a" * 64
        )
        == "deleted"
    )
    assert (
        worker(db).fulfillEarlierDeletion(accountId="retired", verifiedRequestSha256="a" * 64)
        == "absent"
    )
    account(db, "active", active=True)
    assert (
        worker(db).fulfillEarlierDeletion(accountId="active", verifiedRequestSha256="a" * 64)
        == "notDue"
    )
    account(db, "old-unknown", tracked=False)
    assert (
        worker(db).fulfillEarlierDeletion(accountId="old-unknown", verifiedRequestSha256="a" * 64)
        == "deleted"
    )


def test_cli_default_read_only_and_explicit_confirmed_purge(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db)
    root = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment.update(
        {
            "GATEWAY_DATABASE_BACKEND": "sqlite",
            "AGENT_GATEWAY_TASK018_DATABASE_PATH": str(db.databasePath),
            "PYTHONPATH": str(root / "src"),
        }
    )
    command = [sys.executable, str(root / "scripts/manage_account_retention.py"), "purge"]
    # Explicit local synthetic SQLite path overrides any inherited cloud config.
    dry = subprocess.run(command, env=environment, capture_output=True, check=False)  # noqa: S603
    assert dry.returncode == 0 and json.loads(dry.stdout)["writeRequested"] is False
    assert count(db, "accounts") == 1
    rejected = subprocess.run(  # noqa: S603
        command + ["--apply"], env=environment, capture_output=True, check=False
    )
    assert rejected.returncode == 1 and count(db, "accounts") == 1
    applied = subprocess.run(  # noqa: S603
        command + ["--apply", "--confirmed-target"],
        env=environment,
        capture_output=True,
        check=False,
    )  # noqa: S603
    result = json.loads(applied.stdout)
    assert applied.returncode == 0 and result["deletedAccounts"] == 1
    assert "retired" not in result and count(db, "accounts") == 0


def test_evidenced_hold_has_an_end_and_cannot_be_implicit(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db)
    with SqliteAccountDatabase(db).transaction() as connection:
        recordRetentionHold(
            connection,
            mysql=False,
            accountId="retired",
            kind="actualDispute",
            untilUtc=DUE + timedelta(days=1),
            evidenceSha256="a" * 64,
        )
    assert worker(db).runBatch().heldAccounts == 1
    assert worker(db, DUE + timedelta(days=1)).runBatch().deletedAccounts == 1


def test_cloud_versions_purge_newest_first_and_resume_bounded_batch(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db)
    with db.immediateTransaction() as connection:
        connection.execute("INSERT INTO cloud_account_state VALUES (?,?)", ("retired", 3))
        connection.execute(
            "INSERT INTO cloud_documents VALUES (?,?,?,?,?,?,?)",
            ("retired", b"document", b"v2", b"{}", 3, 0, toUtcText(RETIRED)),
        )
        # Read fixed schema column order explicitly to keep synthetic data clear.
        for number in range(3):
            connection.execute(
                "INSERT INTO cloud_versions(account_id,document_id,version_id,parent_version_id,"
                "snapshot_payload,snapshot_sha256,commit_sequence,committed_at_utc) "
                "VALUES (?,?,?,?,?,?,?,?)",
                (
                    "retired",
                    b"document",
                    ("v" + str(number)).encode(),
                    None if number == 0 else ("v" + str(number - 1)).encode(),
                    b"{}",
                    "a" * 64,
                    number + 1,
                    toUtcText(RETIRED),
                ),
            )
    batch = worker(db).runBatch(maximumCloudVersionsPerAccount=1)
    assert batch.unfinishedCloudAccounts == 1 and count(db, "cloud_versions") == 2
    assert worker(db).runBatch(maximumCloudVersionsPerAccount=2).deletedAccounts == 1
    assert all(count(db, table) == 0 for table in PURGE_TABLES)


def test_deactivation_timestamp_same_transaction_and_missing_journal_rolls_back(
    tmp_path: Path,
) -> None:
    db = database(tmp_path)
    account(db, active=True, tracked=False)
    store = SqliteLifecycleStore(db, withRetention=True, withCloud=True)
    with store.transaction() as connection:
        connection.deactivate("retired", "disabled:retired", toUtcText(RETIRED))
    with db.readConnection() as connection:
        assert connection.execute("SELECT deactivated_at_utc FROM account_retirements").fetchone()[
            0
        ] == toUtcText(RETIRED)
    account(db, "next", active=True, tracked=False)
    with db.immediateTransaction() as connection:
        connection.execute("DROP TABLE account_retirements")
    with pytest.raises(sqlite3.OperationalError):
        with store.transaction() as connection:
            connection.deactivate("next", "disabled:next", toUtcText(RETIRED))
    with db.readConnection() as connection:
        assert (
            connection.execute("SELECT is_active FROM accounts WHERE account_id='next'").fetchone()[
                0
            ]
            == 1
        )


def test_failed_final_delete_rolls_back_every_association(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db)
    usage(db, "released")
    with db.immediateTransaction() as connection:
        connection.execute(
            "CREATE TRIGGER synthetic_abort BEFORE DELETE ON accounts "
            "BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
        )
    with pytest.raises(StorageUnavailableError):
        worker(db).runBatch()
    assert (
        count(db, "accounts")
        == count(db, "usage_operations")
        == count(db, "account_retirements")
        == 1
    )
    with db.immediateTransaction() as connection:
        connection.execute("DROP TRIGGER synthetic_abort")
    assert worker(db).runBatch().deletedAccounts == 1


def test_position_advances_past_blocked_accounts_without_skipping_due_work(tmp_path: Path) -> None:
    db = database(tmp_path)
    account(db, "a")
    usage(db, "reserved", name="a")
    account(db, "b")
    first = worker(db).runBatch(maximumAccounts=1)
    assert first.moreCandidates and first.nextAccountId == "a"
    assert worker(db).runBatch(afterAccountId=first.nextAccountId).deletedAccounts == 1


def test_schema_migration_is_idempotent_preserves_old_records_and_startup_requires_it(
    tmp_path: Path,
) -> None:
    db = GatewayDatabase(tmp_path / "old.sqlite")
    db.initialize()
    migrateSqlitePrivilegeSchema(db)
    migrateSqliteRecoverySchema(db)
    account(db, tracked=False)
    settings = GatewaySettings(
        task018DatabasePath=db.databasePath,
        enableTask018FakeIdentity=True,
        enableAccountPrivileges=True,
        enableRecoveryCodes=True,
        enableAccountRetention=True,
    )
    with pytest.raises(UnsupportedDatabaseSchemaError):
        createApplication(settings=settings)
    migrateSqliteRetentionSchema(db)
    migrateSqliteRetentionSchema(db)
    validateSqliteRetentionSchema(db)
    assert worker(db).runBatch().unknownDeactivationTimes == 1
    createApplication(settings=settings)
    with db.readConnection() as connection:
        assert connection.execute(
            "SELECT version FROM schema_migrations ORDER BY version"
        ).fetchall() == [(number,) for number in range(1, 10)] or [
            row[0]
            for row in connection.execute("SELECT version FROM schema_migrations ORDER BY version")
        ] == list(range(1, 10))


class FakeSql:
    """Records MySQL dialect/permissions only, never pretends to test InnoDB locks."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[object, ...]]] = []
        self.row: Mapping[str, object] | None = None
        self.rows: tuple[Mapping[str, object], ...] = ()

    def execute(self, sql: str, parameters: tuple[object, ...] = ()) -> int:
        self.calls.append((sql, parameters))
        return 1

    def fetchOne(
        self, sql: str, parameters: tuple[object, ...] = ()
    ) -> Mapping[str, object] | None:
        self.calls.append((sql, parameters))
        return self.row

    def fetchMany(
        self, sql: str, parameters: tuple[object, ...] = (), *, maximumRows: int
    ) -> tuple[Mapping[str, object], ...]:
        self.calls.append((sql, parameters))
        return self.rows


class FakeMySqlDatabase:
    authorityKey: tuple[str, ...] = ("mysql", "synthetic-local", "test")

    def __init__(self, sql: FakeSql) -> None:
        self.sql = sql

    def readConnection(self) -> AbstractContextManager[AccountSqlConnection]:
        return nullcontext(self.sql)

    def transaction(self) -> AbstractContextManager[AccountSqlConnection]:
        return nullcontext(self.sql)


def test_mysql_session_cleanup_and_cli_inspection_bind_parameters() -> None:
    sql = FakeSql()
    sql.row = {"count": 0}
    sql.rows = (
        {"record_id": "expired", "eligible_at_utc": toUtcText(RETIRED), "invalidated_at_utc": None},
    )
    db = FakeMySqlDatabase(sql)
    assert AccountRetentionWorker(db, clock=lambda: DUE).purgeInvalidSessions().deletedSessions == 1
    assert any(query.endswith("FOR UPDATE") for query, _ in sql.calls)
    script = Path(__file__).resolve().parents[1] / "scripts/manage_account_retention.py"
    inspectFunction = cast(
        Callable[[AccountSqlDatabase], dict[str, int]], runpy.run_path(str(script))["inspect"]
    )
    assert inspectFunction(db)["invalidSessions"] == 0
    assert all("?" not in query for query, _ in sql.calls)
    assert any("expires_at_utc<=%s" in query and values for query, values in sql.calls)


def test_mysql_lifecycle_uses_bound_journal_insert() -> None:
    from agent_gateway.lifecycle_storage import RelationalLifecycleTransaction

    sql = FakeSql()
    transaction = RelationalLifecycleTransaction(sql, mysql=True, withRetention=True)
    transaction.deactivate("retired", "disabled:retired", toUtcText(RETIRED))
    assert sql.calls[0] == (
        "INSERT INTO account_retirements(account_id,deactivated_at_utc) VALUES (%s,%s)",
        ("retired", toUtcText(RETIRED)),
    )
    assert all("?" not in query for query, _ in sql.calls)


def test_web_insert_only_and_purger_separate_exact_allowlist() -> None:
    sql = FakeSql()
    sql.rows = ({"column_name": "account_id"}, {"column_name": "deactivated_at_utc"})
    sql.row = {"count": 0, "grantee": "'resume_web'@'%'"}
    validateRetentionWebPrivileges(sql)
    sql.row = {"count": 1, "grantee": "'resume_web'@'%'"}
    with pytest.raises(ValueError, match="excessive"):
        validateRetentionWebPrivileges(sql)
    sql.row = {"database_name": "synthetic", "identity": "resume_retention@%", "roles": "NONE"}
    grants = ["GRANT USAGE ON *.* TO `resume_retention`@`%`"]
    grants += [
        f"GRANT SELECT, DELETE ON `synthetic`.`{table}` TO `resume_retention`@`%`"
        for table in PURGE_TABLES
    ]
    grants += ["GRANT SELECT ON `synthetic`.`gateway_schema_migrations` TO `resume_retention`@`%`"]
    sql.rows = tuple({"Grants": value} for value in grants)
    validatePurgerPrivileges(sql)
    sql.rows += ({"Grants": "GRANT DELETE ON `synthetic`.* TO `resume_retention`@`%`"},)
    with pytest.raises(ValueError, match="excessive"):
        validatePurgerPrivileges(sql)


def test_mysql_challenge_purge_uses_only_fixed_bound_challenge_queries() -> None:
    sql = FakeSql()
    sql.rows = (
        {
            "record_id": "challenge-expired",
            "eligible_at_utc": toUtcText(RETIRED),
            "invalidated_at_utc": None,
        },
    )
    result = AccountRetentionWorker(
        FakeMySqlDatabase(sql), clock=lambda: DUE
    ).purgeInvalidChallenges()
    assert result.deletedRecords == 1
    assert any(query.endswith("FOR UPDATE") for query, _ in sql.calls)
    assert all("?" not in query and "phone_challenges" in query for query, _ in sql.calls)
    assert any("consumed_at_utc<=%s" in query for query, _ in sql.calls)


def test_otp_purger_has_no_throttle_or_budget_delete_grants() -> None:
    sql = FakeSql()
    sql.row = {"database_name": "synthetic", "identity": "resume_retention_otp@%", "roles": "NONE"}
    sql.rows = tuple(
        {"Grants": grant}
        for grant in [
            "GRANT USAGE ON *.* TO `resume_retention_otp`@`%`",
            "GRANT SELECT, DELETE ON `synthetic`.`phone_challenges` TO `resume_retention_otp`@`%`",
            "GRANT SELECT ON `synthetic`.`gateway_schema_migrations` TO `resume_retention_otp`@`%`",
        ]
    )
    validatePurgerPrivileges(sql, challengesOnly=True)
    with pytest.raises(ValueError, match="excessive"):
        validatePurgerPrivileges(sql)
    sql.rows += (
        {"Grants": "GRANT DELETE ON `synthetic`.`sms_send_attempts` TO `resume_retention_otp`@`%`"},
    )
    with pytest.raises(ValueError, match="excessive"):
        validatePurgerPrivileges(sql, challengesOnly=True)


def test_throttle_mysql_queries_and_dedicated_permissions_preserve_phone_guards() -> None:
    sql = FakeSql()
    sql.row = {"count": 0}
    sql.rows = (
        {"record_id": "a" * 64, "eligible_at_utc": toUtcText(RETIRED), "invalidated_at_utc": None},
    )
    worker = AccountRetentionWorker(FakeMySqlDatabase(sql), clock=lambda: DUE)
    assert worker.purgeExpiredThrottles().deletedRecords == 1
    assert any("FROM identity_rate_limits" in q and q.endswith("FOR UPDATE") for q, _ in sql.calls)
    assert any(
        q.startswith("DELETE FROM identity_rate_limits") and len(v) == 2 for q, v in sql.calls
    )
    assert all("?" not in q and "phone_verification_guards" not in q for q, _ in sql.calls)
    sql.row = {"database_name": "synthetic", "identity": "resume_retention_rate@%", "roles": "NONE"}
    sql.rows = tuple(
        {"Grants": grant}
        for grant in [
            "GRANT USAGE ON *.* TO `resume_retention_rate`@`%`",
            "GRANT SELECT, DELETE ON `synthetic`.`identity_rate_limits` "
            "TO `resume_retention_rate`@`%`",
            "GRANT SELECT ON `synthetic`.`gateway_schema_migrations` "
            "TO `resume_retention_rate`@`%`",
        ]
    )
    validatePurgerPrivileges(sql, throttlesOnly=True)
    with pytest.raises(ValueError, match="one_retention_category_required"):
        validatePurgerPrivileges(sql, throttlesOnly=True, challengesOnly=True)
    sql.rows += (
        {
            "Grants": "GRANT DELETE ON `synthetic`.`phone_verification_guards` "
            "TO `resume_retention_rate`@`%`"
        },
    )
    with pytest.raises(ValueError, match="excessive"):
        validatePurgerPrivileges(sql, throttlesOnly=True)


def test_mysql_sms_phone_clear_updates_only_phone_and_never_locks_budget() -> None:
    sql = FakeSql()
    sql.rows = (
        {
            "challenge_id": b"challenge-00000000-0000-4000-8000-000000000001",
            "phone_hash": b"a" * 64,
            "created_at_utc": toUtcText(RETIRED),
        },
    )
    result = SmsPhoneRetentionWorker(
        FakeMySqlDatabase(sql), clock=lambda: RETIRED + timedelta(days=90)
    ).clearOldPhoneDigests()
    assert result.clearedPhoneDigests == 1
    assert all("FOR UPDATE" not in q for q, _ in sql.calls)
    assert any(q.startswith("UPDATE sms_send_attempts SET phone_hash=%s") for q, _ in sql.calls)
    assert all(
        "?" not in q and "sms_send_budget" not in q and "DELETE" not in q for q, _ in sql.calls
    )


def test_sms_phone_role_is_column_update_only_and_rejects_extra_scope() -> None:
    sql = FakeSql()
    sql.row = {
        "database_name": "synthetic",
        "identity": "resume_retention_phone@%",
        "roles": "NONE",
    }
    grants = [
        "GRANT USAGE ON *.* TO `resume_retention_phone`@`%`",
        "GRANT SELECT, UPDATE (`phone_hash`) ON `synthetic`.`sms_send_attempts` "
        "TO `resume_retention_phone`@`%`",
        "GRANT SELECT ON `synthetic`.`gateway_schema_migrations` TO `resume_retention_phone`@`%`",
    ]
    sql.rows = tuple({"Grants": q} for q in grants)
    validatePurgerPrivileges(sql, smsPhoneOnly=True)
    with pytest.raises(ValueError, match="one_retention_category_required"):
        validatePurgerPrivileges(sql, smsPhoneOnly=True, challengesOnly=True)
    for wrong in ["UPDATE", "UPDATE (`phone_hash`, `outcome`)", "DELETE"]:
        sql.rows = tuple({"Grants": q.replace("UPDATE (`phone_hash`)", wrong)} for q in grants)
        with pytest.raises(ValueError, match="mismatch"):
            validatePurgerPrivileges(sql, smsPhoneOnly=True)
