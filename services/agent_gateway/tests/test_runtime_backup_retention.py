from __future__ import annotations

import hashlib
import json
import multiprocessing
import os
import sqlite3
import subprocess
import time
from contextlib import closing
from pathlib import Path

import pytest

from agent_gateway import runtime_backup_retention as retention
from agent_gateway.runtime_backup_retention import (
    RETENTION_SECONDS,
    RuntimeBackupError,
    cleanupManagedBackups,
    createManagedBackup,
    initializeRoot,
)

CREATED = 1_800_000_000.0


@pytest.fixture
def managed(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> tuple[Path, Path]:
    root = tmp_path / "managed"
    initializeRoot(root)
    source = tmp_path / "synthetic.sqlite3"
    with closing(sqlite3.connect(source)) as connection:
        connection.execute("CREATE TABLE synthetic (label TEXT)")
        connection.execute("INSERT INTO synthetic VALUES ('synthetic-only')")
        connection.commit()
    monkeypatch.setattr(time, "time", lambda: CREATED)
    return root, source


def test_wal_copy_and_seven_day_boundary(
    managed: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    root, source = managed
    with closing(sqlite3.connect(source)) as writer:
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute("PRAGMA wal_autocheckpoint=0")
        writer.execute("INSERT INTO synthetic VALUES ('committed-wal-row')")
        writer.commit()
        before = tuple(writer.iterdump())
        backup = createManagedBackup(root, source, role="guest")
        assert tuple(writer.iterdump()) == before
        destination = root / backup.backupId / "backup.sqlite3"
        with closing(sqlite3.connect(destination)) as copy:
            assert copy.execute("SELECT COUNT(*) FROM synthetic").fetchone() == (2,)
        assert backup.sha256 == hashlib.sha256(destination.read_bytes()).hexdigest()
        assert backup.sizeBytes == destination.stat().st_size
    assert backup.createdAtEpoch == CREATED
    assert backup.expiresAtEpoch == CREATED + RETENTION_SECONDS
    monkeypatch.setattr(time, "time", lambda: CREATED + RETENTION_SECONDS - 0.01)
    assert cleanupManagedBackups(root, apply=True).retained == 1
    monkeypatch.setattr(time, "time", lambda: CREATED + RETENTION_SECONDS)
    assert cleanupManagedBackups(root).deleted == 0  # Dry run is the default.
    assert destination.exists()
    report = cleanupManagedBackups(root, apply=True)
    assert report.deleted == 1 and report.overdue == 0 and report.failures == 0
    assert not destination.exists() and source.exists()
    assert cleanupManagedBackups(root, apply=True).scanned == 0


def test_scheduled_early_window_and_overdue_reporting(
    managed: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    root, source = managed
    createManagedBackup(root, source, role="trial")
    monkeypatch.setattr(time, "time", lambda: CREATED + RETENTION_SECONDS - 300)
    assert cleanupManagedBackups(root, apply=True, lookAheadSeconds=300).deleted == 1
    monkeypatch.setattr(time, "time", lambda: CREATED)
    createManagedBackup(root, source, role="results")
    monkeypatch.setattr(time, "time", lambda: CREATED + RETENTION_SECONDS + 1)
    assert cleanupManagedBackups(root, apply=True).overdue == 1


def test_failure_after_partial_copy_remains_registered_and_expirable(
    managed: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    root, source = managed

    def interrupted(source: Path, staged: Path, timeoutSeconds: float) -> tuple[str, int]:
        del source, timeoutSeconds
        staged.write_bytes(b"synthetic-interrupted-copy")
        Path(str(staged) + "-journal").write_bytes(b"synthetic-journal")
        raise RuntimeBackupError("backup_timeout")

    monkeypatch.setattr(retention, "_copyWithTimeout", interrupted)
    with pytest.raises(RuntimeBackupError, match="^backup_timeout$"):
        createManagedBackup(root, source, role="guest")
    entries = list(root.glob("*/entry.json"))
    assert len(entries) == 1
    assert not (entries[0].parent / "backup.sqlite3").exists()
    monkeypatch.setattr(time, "time", lambda: CREATED + RETENTION_SECONDS)
    assert cleanupManagedBackups(root, apply=True).deleted == 1
    assert not entries[0].parent.exists()


def test_unregistered_historic_backups_never_adopted_or_deleted(
    managed: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    root, source = managed
    historic = root / "historic.sqlite3"
    historic.write_bytes(b"synthetic-historic")
    os.utime(historic, (1, 1))
    unknown = root / ("a" * 32)
    unknown.mkdir()
    (unknown / "backup.sqlite3").write_bytes(b"synthetic-no-registration")
    monkeypatch.setattr(time, "time", lambda: CREATED + RETENTION_SECONDS * 2)
    report = cleanupManagedBackups(root, apply=True)
    assert report.ignored == 1 and report.failures == 1 and report.deleted == 0
    assert historic.read_bytes() == b"synthetic-historic"
    assert (unknown / "backup.sqlite3").exists()
    with pytest.raises(RuntimeBackupError, match="^backup_root_not_empty$"):
        initializeRoot(root)
    assert source.exists()


@pytest.mark.parametrize("change", ["expiry", "identity", "unknown-child", "hard-link"])
def test_tampered_entry_is_fail_closed(
    managed: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch, change: str, tmp_path: Path
) -> None:
    root, source = managed
    backup = createManagedBackup(root, source, role="trial")
    folder = root / backup.backupId
    entry = folder / "entry.json"
    if change in {"expiry", "identity"}:
        value = json.loads(entry.read_text(encoding="utf-8"))
        value["expiresAtEpoch" if change == "expiry" else "backupId"] = (
            CREATED if change == "expiry" else "../unrelated"
        )
        entry.write_text(json.dumps(value), encoding="utf-8")
    elif change == "unknown-child":
        (folder / "do-not-delete.txt").write_text("synthetic", encoding="utf-8")
    else:
        os.link(folder / "backup.sqlite3", tmp_path / "external.sqlite3")
    monkeypatch.setattr(time, "time", lambda: CREATED + RETENTION_SECONDS)
    report = cleanupManagedBackups(root, apply=True)
    assert report.deleted == 0 and report.failures == 1
    assert (folder / "backup.sqlite3").exists()


def test_symlink_root_or_registered_payload_is_never_followed(
    managed: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    root, source = managed
    alias = tmp_path / "alias"
    try:
        alias.symlink_to(root, target_is_directory=True)
    except OSError:
        pytest.skip("host does not permit creating synthetic symlinks")
    with pytest.raises(RuntimeBackupError, match="^backup_path_invalid$"):
        cleanupManagedBackups(alias, apply=True)
    backup = createManagedBackup(root, source, role="results")
    payload = root / backup.backupId / "backup.sqlite3"
    payload.unlink()
    payload.symlink_to(source)
    monkeypatch.setattr(time, "time", lambda: CREATED + RETENTION_SECONDS)
    report = cleanupManagedBackups(root, apply=True)
    assert report.failures == 1 and report.deleted == 0
    assert source.exists() and payload.is_symlink()


@pytest.mark.skipif(os.name != "nt", reason="Windows junction contract")
def test_windows_directory_junction_is_never_followed(
    managed: tuple[Path, Path], tmp_path: Path
) -> None:
    root, _ = managed
    alias = tmp_path / "junction"
    script = tmp_path / "synthetic-junction.ps1"
    script.write_text(
        "param([string]$Link, [string]$Target)\n"
        "$ErrorActionPreference = 'Stop'\n"
        "New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null\n",
        encoding="utf-8",
    )
    powershell = (
        Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    )
    result = subprocess.run(  # noqa: S603 -- fixed executable/script, isolated synthetic paths.
        [
            str(powershell), "-NoProfile", "-NonInteractive", "-File",
            str(script), str(alias), str(root),
        ],
        capture_output=True,
        timeout=15,
        check=False,
    )
    assert result.returncode == 0
    try:
        with pytest.raises(RuntimeBackupError, match="^backup_path_invalid$"):
            cleanupManagedBackups(alias, apply=True)
        assert (root / "registry.json").is_file()
    finally:
        # Remove only this known junction itself, never recurse through its target.
        alias.rmdir()


def test_exclusive_process_lock_and_source_inside_registry_rejected(
    managed: tuple[Path, Path]
) -> None:
    root, source = managed
    with retention._locked(root), pytest.raises(RuntimeBackupError, match="^backup_busy$"):
        createManagedBackup(root, source, role="guest")
    with pytest.raises(RuntimeBackupError, match="^backup_source_invalid$"):
        createManagedBackup(root, root / "registry.json", role="guest")


@pytest.mark.parametrize("timeout", [0.0, -1.0, float("nan"), float("inf"), True, 3601])
def test_invalid_timeout_never_creates_payload(
    managed: tuple[Path, Path], timeout: float
) -> None:
    root, source = managed
    with pytest.raises(RuntimeBackupError, match="^backup_timeout_invalid$"):
        createManagedBackup(root, source, role="guest", timeoutSeconds=timeout)
    assert not list(root.glob("*/entry.json"))


def test_corrupt_database_produces_safe_error_and_no_completed_backup(
    managed: tuple[Path, Path]
) -> None:
    root, source = managed
    source.write_bytes(b"not sqlite; synthetic-sensitive-value")
    with pytest.raises(RuntimeBackupError, match="^backup_failed$"):
        createManagedBackup(root, source, role="guest")
    assert not list(root.glob("*/backup.sqlite3"))


def test_real_worker_timeout_is_terminated_and_registered_partial_is_cleanable(
    managed: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    root, source = managed
    before = {child.pid for child in multiprocessing.active_children()}
    with pytest.raises(RuntimeBackupError, match="^backup_timeout$"):
        createManagedBackup(root, source, role="trial", timeoutSeconds=0.000001)
    assert {child.pid for child in multiprocessing.active_children()} <= before
    assert len(list(root.glob("*/entry.json"))) == 1
    assert not list(root.glob("*/backup.sqlite3"))
    monkeypatch.setattr(time, "time", lambda: CREATED + RETENTION_SECONDS)
    assert cleanupManagedBackups(root, apply=True).deleted == 1


def test_hard_linked_source_and_dotdot_root_are_rejected(
    managed: tuple[Path, Path], tmp_path: Path
) -> None:
    root, source = managed
    os.link(source, tmp_path / "source-alias.sqlite3")
    with pytest.raises(RuntimeBackupError, match="^backup_path_invalid$"):
        createManagedBackup(root, source, role="trial")
    with pytest.raises(RuntimeBackupError, match="^backup_path_invalid$"):
        cleanupManagedBackups(root / ".." / root.name, apply=True)
