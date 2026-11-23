from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from agent_gateway.account_storage import (
    SqliteAccountDatabase,
    StorageUnavailableError,
    UnknownStorageCommitError,
)
from agent_gateway.cloud_retention import CloudPurgePosition, CloudRetentionWorker
from agent_gateway.cloud_storage import CloudNotAccessible
from tests.test_cloud_pages import addDocument, pagedStore
from tests.test_cloud_storage import ONE, TWO, FaultDatabase, Storage, append, operation
from tests.test_cloud_storage import storage as storage


def test_purge_is_bounded_and_clears_document_only_after_last_history(storage: Storage) -> None:
    store = pagedStore(storage)
    addDocument(store, "deleted")
    addDocument(store, "deleted", version="v2", parent="version-one")
    addDocument(store, "deleted", version="v3", parent="v2")
    addDocument(store, "live")
    addDocument(store, "deleted", identity=TWO)
    store.deleteDocument(ONE, "deleted", operation())
    worker = CloudRetentionWorker(SqliteAccountDatabase(storage[1]))
    first = worker.runBatch(maximumVersionsPerDocument=2)
    assert first.deletedVersions == 2 and first.clearedDocuments == 0
    assert first.unfinishedDueDocuments == 1 and first.nextPosition is None
    with storage[1].readConnection() as connection:
        assert (
            connection.execute(
                "SELECT document_json FROM cloud_documents WHERE account_id=? AND document_id=?",
                (ONE.accountId, b"deleted"),
            ).fetchone()[0]
            != b"{}"
        )
        assert (
            connection.execute(
                "SELECT version_id FROM cloud_versions WHERE account_id=? AND document_id=?",
                (ONE.accountId, b"deleted"),
            ).fetchone()[0]
            == b"version-one"
        )
    second = worker.runBatch(maximumVersionsPerDocument=2)
    assert second.deletedVersions == 1 and second.clearedDocuments == 1
    assert second.unfinishedDueDocuments == 0
    assert worker.runBatch().scannedDocuments == 0
    assert store.getCurrent(ONE, "live").versionId == "version-one"
    assert store.getCurrent(TWO, "deleted").versionId == "version-one"
    with pytest.raises(CloudNotAccessible):
        store.getCurrent(ONE, "deleted")
    tombstone = store.listDocuments(ONE, includeDeleted=True).items[-1]
    assert tombstone.documentId == "deleted" and tombstone.title is None


def test_exact_retention_deadline_is_respected_to_microsecond(storage: Storage) -> None:
    clock = [datetime(2026, 10, 11, 1, 2, 3, 456789, tzinfo=UTC)]
    store = pagedStore(storage, clock)
    addDocument(store, "deleted")
    with storage[1].immediateTransaction() as connection:
        connection.execute("UPDATE cloud_documents SET content_retention_days=1")
    store.deleteDocument(ONE, "deleted", operation())
    worker = CloudRetentionWorker(SqliteAccountDatabase(storage[1]), clock=lambda: clock[0])
    clock[0] += timedelta(days=1, microseconds=-1)
    assert worker.runBatch().deletedVersions == 0
    clock[0] += timedelta(microseconds=1)
    assert worker.runBatch().clearedDocuments == 1


def test_ineligible_documents_do_not_starve_due_documents_in_later_scan_page(
    storage: Storage,
) -> None:
    clock = [datetime(2026, 10, 11, tzinfo=UTC)]
    store = pagedStore(storage, clock)
    for name in ("a-future", "z-due"):
        addDocument(store, name)
        store.deleteDocument(ONE, name, operation())
    with storage[1].immediateTransaction() as connection:
        connection.execute(
            "UPDATE cloud_documents SET content_retention_days=10 WHERE document_id=?",
            (b"a-future",),
        )
    worker = CloudRetentionWorker(SqliteAccountDatabase(storage[1]), clock=lambda: clock[0])
    first = worker.runBatch(maximumDocuments=1)
    assert first.scannedDocuments == 1 and first.deletedVersions == 0
    assert first.nextPosition is not None
    second = worker.runBatch(maximumDocuments=1, position=first.nextPosition)
    assert second.clearedDocuments == 1 and second.nextPosition is None
    clock[0] += timedelta(days=10)
    assert worker.runBatch().clearedDocuments == 1


@pytest.mark.parametrize(
    "statement", ["DELETE FROM cloud_versions", "UPDATE cloud_documents SET document_json"]
)
def test_failure_rolls_back_purge_chunk_and_keeps_tombstone(
    storage: Storage, statement: str
) -> None:
    store = pagedStore(storage)
    addDocument(store, "deleted")
    store.deleteDocument(ONE, "deleted", operation())
    failed = FaultDatabase(storage[1], statement)
    with pytest.raises(StorageUnavailableError, match="synthetic_write_failure"):
        CloudRetentionWorker(failed).runBatch()
    assert failed.transactions == 1
    with storage[1].readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 1
        row = connection.execute(
            "SELECT document_json,deleted_at_utc FROM cloud_documents"
        ).fetchone()
        assert row[0] != b"{}" and row[1] is not None
    assert CloudRetentionWorker(SqliteAccountDatabase(storage[1])).runBatch().clearedDocuments == 1


def test_lost_purge_commit_ack_is_not_retried_and_marker_is_authoritative(storage: Storage) -> None:
    store = pagedStore(storage)
    addDocument(store, "deleted")
    store.deleteDocument(ONE, "deleted", operation())
    failed = FaultDatabase(storage[1], None)
    with pytest.raises(UnknownStorageCommitError):
        CloudRetentionWorker(failed).runBatch()
    assert failed.transactions == 1
    with storage[1].readConnection() as connection:
        assert (
            connection.execute("SELECT document_json FROM cloud_documents").fetchone()[0] == b"{}"
        )
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 0
    assert CloudRetentionWorker(SqliteAccountDatabase(storage[1])).runBatch().scannedDocuments == 0


def test_inactive_account_content_is_cleaned_without_removing_operation_records(
    storage: Storage,
) -> None:
    store = pagedStore(storage)
    addDocument(store, "deleted")
    op = operation()
    result = store.deleteDocument(ONE, "deleted", op)
    with storage[1].immediateTransaction() as connection:
        connection.execute("UPDATE accounts SET is_active=0 WHERE account_id=?", (ONE.accountId,))
    assert CloudRetentionWorker(SqliteAccountDatabase(storage[1])).runBatch().clearedDocuments == 1
    with storage[1].readConnection() as connection:
        assert (
            connection.execute("SELECT last_sequence FROM cloud_account_state").fetchone()[0]
            == result.sequence
        )
        assert connection.execute("SELECT COUNT(*) FROM cloud_operations").fetchone()[0] == 3
        assert connection.execute("SELECT COUNT(*) FROM cloud_consents").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM cloud_documents").fetchone()[0] == 1


def test_purge_rejects_bad_bounds_and_cross_database_scan_position(storage: Storage) -> None:
    database = SqliteAccountDatabase(storage[1])
    worker = CloudRetentionWorker(database)
    for bound in (True, 0, 21):
        with pytest.raises(ValueError, match="invalid_cloud_purge_bound"):
            worker.runBatch(maximumDocuments=bound)
    for bound in (True, 0, 201):
        with pytest.raises(ValueError, match="invalid_cloud_purge_bound"):
            worker.runBatch(maximumVersionsPerDocument=bound)
    with pytest.raises(ValueError, match="invalid_cloud_purge_position"):
        worker.runBatch(position=CloudPurgePosition(("sqlite", "other"), "", "", b""))


def test_successful_upload_replay_after_purge_cannot_recreate_body(storage: Storage) -> None:
    store = pagedStore(storage)
    addDocument(store, "deleted")
    original = store.getCurrent(ONE, "deleted")
    with storage[1].readConnection() as connection:
        op = connection.execute(
            "SELECT operation_id FROM cloud_operations WHERE action='appendVersion'"
        ).fetchone()[0]
    previous = store.lookupOperation(ONE, op)
    store.deleteDocument(ONE, "deleted", operation())
    assert CloudRetentionWorker(SqliteAccountDatabase(storage[1])).runBatch().clearedDocuments == 1
    assert append(store, original, op=op) == previous
    with pytest.raises(CloudNotAccessible):
        store.getCurrent(ONE, "deleted")
    with storage[1].readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 0
        assert (
            connection.execute("SELECT document_json FROM cloud_documents").fetchone()[0] == b"{}"
        )
