from __future__ import annotations

import hashlib
import importlib.util
import json
import multiprocessing
import os
import sqlite3
import sys
import time
from contextlib import closing
from multiprocessing.connection import Connection
from pathlib import Path
from typing import Literal

import pytest

from agent_gateway import sqlite_backup
from agent_gateway.account_privileges import AccountPrivilegeService
from agent_gateway.account_retention_schema import (
    migrateSqliteRetentionSchema,
    validateSqliteRetentionSchema,
)
from agent_gateway.account_storage import SqliteAccountDatabase
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.privilege_schema import (
    migrateSqlitePrivilegeSchema,
    validateSqlitePrivilegeSchema,
)
from agent_gateway.recovery_schema import migrateSqliteRecoverySchema
from agent_gateway.sqlite_backup import SqliteBackupError, backupSqlite


def syntheticDatabase(path: Path) -> GatewayDatabase:
    database = GatewayDatabase(path)
    database.initialize()
    migrateSqlitePrivilegeSchema(database)
    return database


def assertNoStaging(parent: Path) -> None:
    assert not list(parent.glob(".gateway-backup-*"))


def test_online_backup_includes_committed_wal_and_restores_account_and_privilege(
    tmp_path: Path,
) -> None:
    database = syntheticDatabase(tmp_path / "live.db")
    destination = tmp_path / "verified.db"
    # Keep a reader open so the writer's last close cannot checkpoint/remove its WAL.
    with closing(sqlite3.connect(database.databasePath)) as keeper:
        keeper.execute("PRAGMA wal_autocheckpoint=0")
        keeper.execute("SELECT COUNT(*) FROM accounts").fetchone()
        accounts = AccountService(database, FakePhoneOwnershipVerifier())
        account = accounts.registerAccount(
            phoneE164="+15550005555",
            password="TestPass2026!",
            verificationProof=FakePhoneOwnershipVerifier.developmentProof,
        )
        privileges = AccountPrivilegeService(SqliteAccountDatabase(database))
        privileges.grant(
            accountId=account,
            expectedPhone="+15550005555",
            grantId="backup-synthetic-grant",
            privilege="permanentMember",
            operatorId="synthetic-operator",
            evidenceSha256="a" * 64,
            apply=True,
        )
        assert Path(str(database.databasePath) + "-wal").stat().st_size > 0
        # Ignoring WAL demonstrates that the new account exists only in the live journal.
        with closing(
            sqlite3.connect(database.databasePath.as_uri() + "?immutable=1", uri=True)
        ) as mainFile:
            assert mainFile.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
        before = tuple(keeper.iterdump())
        result = backupSqlite(database.databasePath, destination)
        assert tuple(keeper.iterdump()) == before
    assert result.sha256 == hashlib.sha256(destination.read_bytes()).hexdigest()
    assert result.sizeBytes == destination.stat().st_size
    assert not Path(str(destination) + "-wal").exists()
    assert not Path(str(destination) + "-shm").exists()
    restored = GatewayDatabase(destination)
    validateSqlitePrivilegeSchema(restored)
    with closing(sqlite3.connect(destination)) as copy:
        assert tuple(copy.iterdump()) == before
        assert copy.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
    assert AccountPrivilegeService(SqliteAccountDatabase(restored)).read(account).membership == (
        "permanent"
    )
    assertNoStaging(tmp_path)


def test_missing_source_is_not_created_and_existing_destination_is_never_overwritten(
    tmp_path: Path,
) -> None:
    source, destination = tmp_path / "missing.db", tmp_path / "protected.db"
    with pytest.raises(SqliteBackupError, match="source_unavailable"):
        backupSqlite(source, destination)
    assert not source.exists() and not destination.exists()
    syntheticDatabase(source)
    destination.write_bytes(b"keep this exact existing file")
    with pytest.raises(SqliteBackupError, match="destination_exists"):
        backupSqlite(source, destination)
    assert destination.read_bytes() == b"keep this exact existing file"
    with pytest.raises(SqliteBackupError, match="destination_exists"):
        backupSqlite(source, source)
    assertNoStaging(tmp_path)


@pytest.mark.parametrize("damage", ["not_sqlite", "v5", "foreign_key", "schema"])
def test_invalid_backup_is_not_published_and_source_is_not_migrated(
    tmp_path: Path, damage: str
) -> None:
    source, destination = tmp_path / "invalid.db", tmp_path / "never.db"
    if damage == "not_sqlite":
        source.write_bytes(b"synthetic damaged file")
    elif damage == "v5":
        GatewayDatabase(source).initialize()
    else:
        syntheticDatabase(source)
        with closing(sqlite3.connect(source)) as connection:
            if damage == "schema":
                connection.execute("CREATE TABLE unexpected (value TEXT)")
            else:
                connection.execute(
                    "INSERT INTO account_privilege_grants "
                    "(grant_id,account_id,privilege,operator_id,evidence_sha256,granted_at_utc) "
                    "VALUES ('orphan','missing-account','admin','synthetic',?,?)",
                    ("a" * 64, "2026-10-13T00:00:00.000000Z"),
                )
            connection.commit()
    original = source.read_bytes()
    with pytest.raises(SqliteBackupError, match="backup_failed"):
        backupSqlite(source, destination)
    assert not destination.exists()
    assert source.read_bytes() == original
    assertNoStaging(tmp_path)


def pausedWorker(
    source: str, staged: str, result: Connection, schemaVersion: Literal[7, 9] = 7
) -> None:
    del source, result, schemaVersion
    Path(staged).write_bytes(b"incomplete synthetic copy")
    time.sleep(30)


@pytest.mark.parametrize("timeout", [0.0, -1.0, float("nan"), float("inf"), True])
def test_invalid_deadline_creates_no_backup_files(tmp_path: Path, timeout: float) -> None:
    source, destination = tmp_path / "live.db", tmp_path / "invalid-timeout.db"
    syntheticDatabase(source)
    with pytest.raises(SqliteBackupError, match="backup_timeout_invalid"):
        backupSqlite(source, destination, timeoutSeconds=timeout)
    assert not destination.exists()
    assertNoStaging(tmp_path)


def test_timeout_stops_owned_worker_and_removes_partial_copy(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source, destination = tmp_path / "live.db", tmp_path / "timeout.db"
    syntheticDatabase(source)
    monkeypatch.setattr(sqlite_backup, "_copyWorker", pausedWorker)
    start = time.monotonic()
    with pytest.raises(SqliteBackupError, match="backup_timeout"):
        backupSqlite(source, destination, timeoutSeconds=1.5)
    assert time.monotonic() - start < 15
    assert not destination.exists()
    assertNoStaging(tmp_path)


def test_publication_race_cannot_overwrite_new_destination(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source, destination = tmp_path / "live.db", tmp_path / "raced.db"
    syntheticDatabase(source)
    originalLink = os.link

    def race(staged: Path, target: Path) -> None:
        target.write_bytes(b"another operation owns this target")
        originalLink(staged, target)

    monkeypatch.setattr(os, "link", race)
    with pytest.raises(SqliteBackupError, match="destination_exists"):
        backupSqlite(source, destination)
    assert destination.read_bytes() == b"another operation owns this target"
    assertNoStaging(tmp_path)


def test_unsupported_publication_fails_without_destination(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source, destination = tmp_path / "live.db", tmp_path / "unsupported.db"
    syntheticDatabase(source)

    def fail(staged: Path, target: Path) -> None:
        del staged, target
        raise OSError("sensitive synthetic path")

    monkeypatch.setattr(os, "link", fail)
    with pytest.raises(SqliteBackupError, match="^backup_failed$"):
        backupSqlite(source, destination)
    assert not destination.exists()
    assertNoStaging(tmp_path)


def writeCommittedWalAndExit(path: str) -> None:
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA wal_autocheckpoint=0")
    connection.execute(
        "INSERT INTO identity_rate_limits(bucket_hash,window_start_utc,attempts) VALUES (?,?,?)",
        ("stale-sidecar-extra-commit", "2026-10-13T00:00:00.000000Z", 3),
    )
    connection.commit()
    # Simulate a process crash after a committed WAL transaction, before connection cleanup.
    os._exit(0)


def test_orphaned_real_wal_and_shm_are_rejected_without_modification(tmp_path: Path) -> None:
    source, destination = tmp_path / "source.db", tmp_path / "old.db"
    syntheticDatabase(source)
    syntheticDatabase(destination)
    process = multiprocessing.get_context("spawn").Process(
        target=writeCommittedWalAndExit, args=(str(destination),)
    )
    process.start()
    try:
        process.join(10)
        assert not process.is_alive() and process.exitcode == 0
    finally:
        if process.is_alive():
            process.terminate()
            process.join(5)
        process.close()
    with closing(sqlite3.connect(destination.as_uri() + "?immutable=1", uri=True)) as mainOnly:
        assert mainOnly.execute("SELECT COUNT(*) FROM identity_rate_limits").fetchone()[0] == 0
    wal, shm = Path(str(destination) + "-wal"), Path(str(destination) + "-shm")
    beforeWal, beforeShm = wal.read_bytes(), shm.read_bytes()
    assert b"stale-sidecar-extra-commit" in beforeWal
    moved = tmp_path / "old-main-moved.db"
    assert moved.parent.resolve() == destination.parent.resolve()
    destination.rename(moved)
    with pytest.raises(SqliteBackupError, match="backup_destination_exists"):
        backupSqlite(source, destination)
    assert not destination.exists()
    assert wal.read_bytes() == beforeWal and shm.read_bytes() == beforeShm
    assertNoStaging(tmp_path)


@pytest.mark.parametrize("suffix", ["-wal", "-shm", "-journal"])
def test_any_existing_destination_sidecar_is_preserved(tmp_path: Path, suffix: str) -> None:
    source, destination = tmp_path / "source.db", tmp_path / "occupied.db"
    syntheticDatabase(source)
    sidecar = Path(str(destination) + suffix)
    sidecar.write_bytes(b"existing sidecar must remain unchanged")
    with pytest.raises(SqliteBackupError, match="backup_destination_exists"):
        backupSqlite(source, destination)
    assert sidecar.read_bytes() == b"existing sidecar must remain unchanged"
    assert not destination.exists()
    assertNoStaging(tmp_path)


def sidecarAfterCopyWorker(
    source: str, staged: str, result: Connection, schemaVersion: Literal[7, 9] = 7
) -> None:
    sqlite_backup._copyWorker(source, staged, result, schemaVersion)
    (Path(staged).parent.parent / "late.db-journal").write_bytes(b"late sidecar")


def test_sidecar_created_during_backup_is_rejected_before_publication(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source, destination = tmp_path / "source.db", tmp_path / "late.db"
    syntheticDatabase(source)
    monkeypatch.setattr(sqlite_backup, "_copyWorker", sidecarAfterCopyWorker)
    with pytest.raises(SqliteBackupError, match="backup_destination_exists"):
        backupSqlite(source, destination)
    assert not destination.exists()
    assert Path(str(destination) + "-journal").read_bytes() == b"late sidecar"
    assertNoStaging(tmp_path)


@pytest.mark.parametrize("schemaVersion", [7, 9])
def test_cli_requires_explicit_apply_and_only_reports_fixed_status_and_hash(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str],
    schemaVersion: int,
) -> None:
    source, destination = tmp_path / "sensitive-source.db", tmp_path / "sensitive-copy.db"
    database = syntheticDatabase(source)
    if schemaVersion == 9:
        migrateSqliteRecoverySchema(database)
        migrateSqliteRetentionSchema(database)
    script = Path(__file__).resolve().parents[1] / "scripts/backup_sqlite.py"
    spec = importlib.util.spec_from_file_location("backup_cli_test", script)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setenv("GATEWAY_DATABASE_BACKEND", "sqlite")
    monkeypatch.setenv("AGENT_GATEWAY_TASK018_DATABASE_PATH", str(source))
    args = ["backup_sqlite", "--destination", str(destination)]
    if schemaVersion == 9:
        args += ["--schema-version", "9"]
    monkeypatch.setattr(sys, "argv", args)
    assert module.main() == 1
    assert not destination.exists()
    assert json.loads(capsys.readouterr().out)["status"] == "backup_apply_required"
    monkeypatch.setattr(sys, "argv", [*args, "--apply"])
    assert module.main() == 0
    result = json.loads(capsys.readouterr().out)
    assert result == {
        "status": "backup_verified",
        "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
        "sizeBytes": destination.stat().st_size,
    }
    monkeypatch.setattr(sys, "argv", [*args, "--secret-unknown", "sensitive-value"])
    assert module.main() == 1
    assert capsys.readouterr().out == (
        '{"status": "backup_arguments_invalid", "retryable": false}\n'
    )


def test_explicit_retention_backup_preserves_wal_and_complete_v9_schema(tmp_path: Path) -> None:
    source, destination = tmp_path / "retention.db", tmp_path / "v9-copy.db"
    database = syntheticDatabase(source)
    migrateSqliteRecoverySchema(database)
    migrateSqliteRetentionSchema(database)
    with closing(sqlite3.connect(source)) as keeper:
        keeper.execute("PRAGMA journal_mode=WAL")
        keeper.execute("PRAGMA wal_autocheckpoint=0")
        keeper.execute(
            "INSERT INTO accounts VALUES (?,?,?,?,?,?)",
            ("synthetic-retired", "disabled:synthetic", "", "2026-10-21T00:00:00Z", 0,
             "2026-10-21T00:00:00Z"),
        )
        keeper.execute(
            "INSERT INTO account_retirements(account_id,deactivated_at_utc) VALUES (?,?)",
            ("synthetic-retired", "2026-10-21T00:00:00Z"),
        )
        keeper.commit()
        before = tuple(keeper.iterdump())
        result = backupSqlite(source, destination, schemaVersion=9)
        assert tuple(keeper.iterdump()) == before
    validateSqliteRetentionSchema(GatewayDatabase(destination))
    with closing(sqlite3.connect(destination)) as restored:
        assert tuple(restored.iterdump()) == before
    assert result.sha256 == hashlib.sha256(destination.read_bytes()).hexdigest()
    assert result.sizeBytes == destination.stat().st_size
    assert not Path(str(destination) + "-wal").exists()
    assertNoStaging(tmp_path)


@pytest.mark.parametrize("case", ["default-v9", "v7-as-v9", "v8-as-v9", "damaged-v9"])
def test_backup_schema_is_explicit_and_mismatch_never_changes_source(
    tmp_path: Path, case: str
) -> None:
    source, destination = tmp_path / "source.db", tmp_path / "must-not-exist.db"
    database = syntheticDatabase(source)
    if case != "v7-as-v9":
        migrateSqliteRecoverySchema(database)
    if case in {"default-v9", "damaged-v9"}:
        migrateSqliteRetentionSchema(database)
    if case == "damaged-v9":
        with closing(sqlite3.connect(source)) as connection:
            connection.execute("DROP TABLE account_retirements")
            connection.commit()
    with closing(sqlite3.connect(source)) as connection:
        before = tuple(connection.iterdump())
    with pytest.raises(SqliteBackupError, match="^backup_failed$"):
        if case == "default-v9":
            backupSqlite(source, destination)
        else:
            backupSqlite(source, destination, schemaVersion=9)
    with closing(sqlite3.connect(source)) as connection:
        assert tuple(connection.iterdump()) == before
    assert not destination.exists()
    assertNoStaging(tmp_path)


def test_invalid_schema_selection_is_rejected_before_copy(tmp_path: Path) -> None:
    source, destination = tmp_path / "source.db", tmp_path / "never.db"
    syntheticDatabase(source)
    with pytest.raises(SqliteBackupError, match="^backup_schema_invalid$"):
        backupSqlite(source, destination, schemaVersion=8)  # type: ignore[arg-type]
    assert not destination.exists()
    assertNoStaging(tmp_path)
