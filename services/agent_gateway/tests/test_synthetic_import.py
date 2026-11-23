import os
import sqlite3
import subprocess
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

import pytest

from agent_gateway.account_storage import (
    AccountSqlConnection,
    SqliteAccountDatabase,
    StorageUnavailableError,
    UnknownStorageCommitError,
    _SqliteConnection,
)
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.sms_budget import SmsBudgetExceededError, SmsBudgetLedger, SmsBudgetPolicy
from agent_gateway.synthetic_import import importSyntheticSnapshot, loadSyntheticSnapshot
from agent_gateway.usage import ProductCapability, UsageOperationStatus, UsagePolicyService

NOW = datetime(2026, 10, 11, tzinfo=UTC)


class SqliteMirrorConnection(_SqliteConnection):
    """只验证真实数据事务/内容；此替身不声称 MySQL 方言与锁已验证。"""

    def execute(self, sql: str, parameters: tuple[object, ...] = ()) -> int:
        return super().execute(sql.replace("%s", "?"), parameters)

    def fetchOne(self, sql: str, parameters: tuple[object, ...] = ()) -> dict[str, object] | None:
        row = self._connection.execute(sql.replace("%s", "?"), parameters).fetchone()
        return None if row is None else dict(row)


class ImportMirror:
    def __init__(self, path: Path, *, lostCommit: bool = False) -> None:
        self.database = GatewayDatabase(path)
        self.database.initialize()
        self.lostCommit = lostCommit
        with self.database.immediateTransaction() as connection:
            connection.execute(
                "CREATE TABLE phone_verification_guards(phone_hash TEXT, purpose TEXT)"
            )

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return ("mysql", "synthetic-mirror")

    @contextmanager
    def transaction(self) -> Iterator[AccountSqlConnection]:
        with self.database.immediateTransaction() as connection:
            yield SqliteMirrorConnection(connection)
        if self.lostCommit:
            raise UnknownStorageCommitError("合成提交确认丢失")

    @contextmanager
    def readConnection(self) -> Iterator[AccountSqlConnection]:
        with self.database.readConnection() as connection:
            yield SqliteMirrorConnection(connection)


def sourceFixture(path: Path) -> GatewayDatabase:
    database = GatewayDatabase(path)
    database.initialize()
    accounts = AccountService(database, FakePhoneOwnershipVerifier())
    account = accounts.registerAccount(
        phoneE164="+15550002903",
        password="Import2026!",
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
        nowUtc=NOW,
    )
    accounts.createSession(phoneE164="+15550002903", password="Import2026!", nowUtc=NOW)
    policy = UsagePolicyService(database)
    for key, status in [
        ("committed", UsageOperationStatus.committed),
        ("pending", UsageOperationStatus.pendingReconciliation),
    ]:
        operation = policy.reserveUsage(
            accountId=account,
            capability=ProductCapability.basicResumeCompose,
            idempotencyKey=key,
            requestFingerprint="synthetic-fingerprint",
            nowUtc=NOW,
        )
        policy.transitionUsage(
            operationId=operation.operationId,
            targetStatus=status,
            nowUtc=NOW,
            promptVersion="synthetic-v1" if key == "committed" else None,
            inputTokens=2 if key == "committed" else None,
            outputTokens=3 if key == "committed" else None,
        )
    return database


def test_dry_run_and_import_preserve_source_and_repeat_without_new_rows(tmp_path: Path) -> None:
    source = sourceFixture(tmp_path / "gateway_synthetic_source.db")
    snapshot = loadSyntheticSnapshot(source.databasePath)
    mirror = ImportMirror(tmp_path / "target.db")
    assert importSyntheticSnapshot(mirror, snapshot)["writes"] is False
    with mirror.database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
    result = importSyntheticSnapshot(
        mirror, snapshot, apply=True, confirmedQuiescent=True, confirmedOtpSecretPreserved=True
    )
    assert result["status"] == "imported"
    assert loadSyntheticSnapshot(mirror.database.databasePath).summary() == snapshot.summary()
    assert loadSyntheticSnapshot(source.databasePath).summary() == snapshot.summary()
    repeated = importSyntheticSnapshot(
        mirror, snapshot, apply=True, confirmedQuiescent=True, confirmedOtpSecretPreserved=True
    )
    assert repeated["status"] == "alreadyImported" and repeated["writes"] is False


def test_failed_mid_import_rolls_back_all_tables(tmp_path: Path) -> None:
    snapshot = loadSyntheticSnapshot(sourceFixture(tmp_path / "source.db").databasePath)
    mirror = ImportMirror(tmp_path / "target.db")
    with mirror.database.immediateTransaction() as connection:
        connection.execute(
            "CREATE TRIGGER deny_import BEFORE INSERT ON usage_operations "
            "BEGIN SELECT RAISE(ABORT, 'synthetic import fault'); END"
        )
    with pytest.raises(StorageUnavailableError):
        importSyntheticSnapshot(
            mirror, snapshot, apply=True, confirmedQuiescent=True, confirmedOtpSecretPreserved=True
        )
    with mirror.database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
        assert connection.execute("SELECT COUNT(*) FROM account_sessions").fetchone()[0] == 0


def test_lost_commit_is_confirmed_by_readonly_check_without_replaying_writes(
    tmp_path: Path,
) -> None:
    snapshot = loadSyntheticSnapshot(sourceFixture(tmp_path / "source.db").databasePath)
    mirror = ImportMirror(tmp_path / "target.db", lostCommit=True)
    with pytest.raises(UnknownStorageCommitError):
        importSyntheticSnapshot(
            mirror, snapshot, apply=True, confirmedQuiescent=True, confirmedOtpSecretPreserved=True
        )
    assert importSyntheticSnapshot(mirror, snapshot)["target"] == "matching"
    mirror.lostCommit = False
    assert (
        importSyntheticSnapshot(
            mirror, snapshot, apply=True, confirmedQuiescent=True, confirmedOtpSecretPreserved=True
        )["writes"]
        is False
    )


def test_existing_different_target_is_rejected_without_overwriting(tmp_path: Path) -> None:
    source = sourceFixture(tmp_path / "source.db")
    snapshot = loadSyntheticSnapshot(source.databasePath)
    mirror = ImportMirror(tmp_path / "target.db")
    importSyntheticSnapshot(
        mirror, snapshot, apply=True, confirmedQuiescent=True, confirmedOtpSecretPreserved=True
    )
    with mirror.database.immediateTransaction() as connection:
        connection.execute("UPDATE accounts SET password_hash = 'synthetic-changed'")
    with pytest.raises(ValueError, match="内容不一致"):
        importSyntheticSnapshot(
            mirror, snapshot, apply=True, confirmedQuiescent=True, confirmedOtpSecretPreserved=True
        )
    with mirror.database.readConnection() as connection:
        assert (
            connection.execute("SELECT password_hash FROM accounts").fetchone()[0]
            == "synthetic-changed"
        )


def test_apply_requires_stop_writes_and_same_otp_secret(tmp_path: Path) -> None:
    snapshot = loadSyntheticSnapshot(sourceFixture(tmp_path / "source.db").databasePath)
    mirror = ImportMirror(tmp_path / "target.db")
    with pytest.raises(ValueError, match="停写"):
        importSyntheticSnapshot(mirror, snapshot, apply=True, confirmedQuiescent=True)


def test_v5_import_preserves_used_sms_budget_and_unknown_attempt_without_refund(
    tmp_path: Path,
) -> None:
    source = sourceFixture(tmp_path / "source.db")
    policy = SmsBudgetPolicy(
        1, 6, 6, datetime(2027, 1, 1, tzinfo=UTC), frozenset({"+8613800000000"})
    )
    secret = b"synthetic-import-sms-secret-32-bytes"
    ledger = SmsBudgetLedger(SqliteAccountDatabase(source), policy, auditSecret=secret)
    ledger.createApprovedPolicy(nowUtc=NOW)
    attempt = "challenge-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    ledger.reserve(attempt, "+8613800000000", "register", nowUtc=NOW)
    ledger.finalize(attempt, "unknown", nowUtc=NOW)
    snapshot = loadSyntheticSnapshot(source.databasePath)
    assert snapshot.sourceVersion == 5
    assert snapshot.summary()["sms_send_attempts"]["count"] == 1
    mirror = ImportMirror(tmp_path / "target.db")
    importSyntheticSnapshot(
        mirror, snapshot, apply=True, confirmedQuiescent=True, confirmedOtpSecretPreserved=True
    )
    recovered = SmsBudgetLedger(SqliteAccountDatabase(mirror.database), policy, auditSecret=secret)
    recovered.assertApprovedPolicy()
    with pytest.raises(SmsBudgetExceededError):
        recovered.reserve(
            "challenge-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "+8613800000000",
            "register",
            nowUtc=NOW,
        )
    assert loadSyntheticSnapshot(mirror.database.databasePath).summary() == snapshot.summary()
    assert importSyntheticSnapshot(mirror, snapshot)["target"] == "matching"


def test_legacy_v4_source_still_imports_seven_tables_and_mislabelled_v5_is_refused(
    tmp_path: Path,
) -> None:
    source = sourceFixture(tmp_path / "source.db")
    with source.immediateTransaction() as connection:
        connection.execute("PRAGMA user_version = 4")
    with pytest.raises(ValueError, match="禁止忽略预算"):
        loadSyntheticSnapshot(source.databasePath)
    with source.immediateTransaction() as connection:
        connection.execute("DROP TABLE sms_send_attempts")
        connection.execute("DROP TABLE sms_send_budget")
        connection.execute("DELETE FROM schema_migrations WHERE version = 5")
    snapshot = loadSyntheticSnapshot(source.databasePath)
    assert snapshot.sourceVersion == 4 and len(snapshot.tables) == 7
    mirror = ImportMirror(tmp_path / "target.db")
    result = importSyntheticSnapshot(
        mirror, snapshot, apply=True, confirmedQuiescent=True, confirmedOtpSecretPreserved=True
    )
    assert result["status"] == "imported" and result["tables"] == snapshot.summary()
    assert importSyntheticSnapshot(mirror, snapshot)["target"] == "matching"


def test_private_phone_and_unknown_source_schema_are_rejected(tmp_path: Path) -> None:
    source = sourceFixture(tmp_path / "source.db")
    with source.immediateTransaction() as connection:
        connection.execute("UPDATE accounts SET phone_e164 = '+8613800000000'")
    with pytest.raises(ValueError, match="真实号码"):
        loadSyntheticSnapshot(source.databasePath)
    with sqlite3.connect(source.databasePath) as connection:
        connection.execute("PRAGMA user_version = 6")
    with pytest.raises(ValueError, match="SQLite v4/v5"):
        loadSyntheticSnapshot(source.databasePath)
    missing = tmp_path / "must_not_create.db"
    with pytest.raises(ValueError):
        loadSyntheticSnapshot(missing)
    assert not missing.exists()


def test_import_cli_without_target_skips_before_opening_source(tmp_path: Path) -> None:
    environment = {
        key: value for key, value in os.environ.items() if not key.startswith("GATEWAY_")
    }
    environment.update(PYTHONPATH="src", PYTHONIOENCODING="utf-8")
    source = tmp_path / "must-not-open.db"
    # 当前测试解释器和仓库固定 CLI；临时路径是数据参数，未使用 shell。
    result = subprocess.run(  # noqa: S603
        [
            sys.executable,
            "scripts/import_sqlite_synthetic.py",
            "--synthetic-only",
            "--source",
            str(source),
        ],
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    assert result.returncode == 0 and "SKIP:" in result.stdout
    assert "未读取源文件" in result.stdout and not source.exists()
