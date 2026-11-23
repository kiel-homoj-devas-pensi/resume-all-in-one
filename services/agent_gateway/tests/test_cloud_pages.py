from __future__ import annotations

import base64
import hashlib
import hmac
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from agent_gateway.account_storage import SqliteAccountDatabase, StorageUnavailableError
from agent_gateway.canonical_snapshot import CanonicalSnapshot
from agent_gateway.cloud_pages import CloudCursorCodec, CloudCursorError, pageItemBytes
from agent_gateway.cloud_storage import (
    CloudAuthenticationError,
    CloudNotAccessible,
    CloudResumeStore,
    CloudSession,
)
from tests.test_cloud_storage import ONE, POLICY, TWO, Storage, append, operation, snapshot
from tests.test_cloud_storage import storage as storage


def addDocument(
    store: CloudResumeStore,
    name: str,
    *,
    identity: CloudSession = ONE,
    version: str = "version-one",
    parent: str | None = None,
    title: str = "合成文档",
) -> None:
    value = snapshot(version, parent).toJson()
    value["document"]["id"] = name
    value["document"]["title"] = title
    value["version"]["documentId"] = name
    if parent is None:
        store.grantConsent(identity, name, operation(), POLICY.fingerprint)
    assert (
        append(
            store, CanonicalSnapshot(json.dumps(value, ensure_ascii=False).encode()), identity
        ).outcome
        == "applied"
    )


def pagedStore(storage: Storage, clock: list[datetime] | None = None) -> CloudResumeStore:
    return CloudResumeStore(
        SqliteAccountDatabase(storage[1]),
        POLICY,
        cursorSecret=b"c" * 32,
        clock=(lambda: clock[0])
        if clock is not None
        else lambda: datetime(2026, 10, 11, tzinfo=UTC),
    )


def test_document_keyset_pages_are_private_and_return_no_body(storage: Storage) -> None:
    store = pagedStore(storage)
    for name in ("document-z", "document-a", "document-c"):
        addDocument(store, name)
    addDocument(store, "other-account", identity=TWO)
    first = store.listDocuments(ONE, pageSize=2)
    assert [item.documentId for item in first.items] == ["document-z", "document-a"]
    assert first.nextCursor is not None and first.highWatermark == 6
    second = store.listDocuments(ONE, pageSize=2, cursor=first.nextCursor)
    assert [item.documentId for item in second.items] == ["document-c"]
    assert second.nextCursor is None and second.highWatermark == first.highWatermark
    assert not hasattr(first.items[0], "content")
    assert "合成文档" not in repr(first) and "document-z" not in repr(first.items[0])
    assert store.listDocuments(TWO).items[0].documentId == "other-account"


def test_updates_after_watermark_are_seen_in_next_sync_cycle(storage: Storage) -> None:
    store = pagedStore(storage)
    for name in ("first", "second", "third"):
        addDocument(store, name)
    first = store.listDocuments(ONE, pageSize=1, includeDeleted=True)
    addDocument(store, "second", version="v2", parent="version-one")
    store.deleteDocument(ONE, "third", operation())
    addDocument(store, "new")
    assert first.nextCursor is not None
    rest = store.listDocuments(ONE, pageSize=1, includeDeleted=True, cursor=first.nextCursor)
    # 多页读取不冒充数据库快照：移出水位线的更新在下个周期取得。
    assert rest.items == () and rest.nextCursor is None
    changes = store.listDocuments(ONE, sinceSequence=first.highWatermark, includeDeleted=True)
    assert [item.documentId for item in changes.items] == ["second", "third", "new"]
    tombstone = changes.items[1]
    assert tombstone.deletedAtUtc is not None and tombstone.title is None
    assert tombstone.currentVersionId is None and tombstone.createdAt is None


def test_same_sequence_tombstones_use_document_key_as_tie_breaker(storage: Storage) -> None:
    store = pagedStore(storage)
    for name in ("z", "a", "中"):
        addDocument(store, name)
    with storage[1].immediateTransaction() as connection:
        connection.execute(
            "UPDATE cloud_documents SET last_sequence=6,deleted_at_utc=?",
            ("2026-10-11T00:00:00.000000Z",),
        )
    cursor = None
    names: list[str] = []
    while True:
        page = store.listDocuments(ONE, pageSize=1, includeDeleted=True, cursor=cursor)
        names.extend(item.documentId for item in page.items)
        cursor = page.nextCursor
        if cursor is None:
            break
    assert names == ["a", "z", "中"]


def test_history_pages_ignore_later_append_and_recheck_deletion(storage: Storage) -> None:
    store = pagedStore(storage)
    addDocument(store, "history")
    addDocument(store, "history", version="v2", parent="version-one")
    addDocument(store, "history", version="v3", parent="v2")
    first = store.listVersions(ONE, "history", pageSize=1)
    assert first.nextCursor is not None
    addDocument(store, "history", version="v4", parent="v3")
    second = store.listVersions(ONE, "history", pageSize=1, cursor=first.nextCursor)
    assert second.items[0].versionId == "v2" and second.nextCursor is not None
    third = store.listVersions(ONE, "history", pageSize=1, cursor=second.nextCursor)
    assert third.items[0].versionId == "v3" and third.nextCursor is None
    assert third.highWatermark == first.highWatermark
    assert [item.versionId for item in store.listVersions(ONE, "history").items] == [
        "version-one",
        "v2",
        "v3",
        "v4",
    ]
    with pytest.raises(CloudNotAccessible):
        store.listVersions(TWO, "history", cursor=first.nextCursor, pageSize=1)
    store.deleteDocument(ONE, "history", operation())
    with pytest.raises(CloudNotAccessible):
        store.listVersions(ONE, "history", cursor=first.nextCursor, pageSize=1)


def test_cursor_binds_account_scope_filters_size_authority_and_secret(
    storage: Storage, tmp_path: Path
) -> None:
    store = pagedStore(storage)
    addDocument(store, "first")
    addDocument(store, "second")
    cursor = store.listDocuments(ONE, pageSize=1).nextCursor
    assert cursor is not None
    for identity, arguments in (
        (TWO, {"pageSize": 1}),
        (ONE, {"pageSize": 2}),
        (ONE, {"pageSize": 1, "includeDeleted": True}),
        (ONE, {"pageSize": 1, "sinceSequence": 1}),
    ):
        with pytest.raises(CloudCursorError, match="cloud_cursor_invalid"):
            store.listDocuments(identity, cursor=cursor, **arguments)  # type: ignore[arg-type]
    with pytest.raises(CloudCursorError):
        store.listVersions(ONE, "first", pageSize=1, cursor=cursor)
    otherKey = CloudResumeStore(SqliteAccountDatabase(storage[1]), POLICY, cursorSecret=b"d" * 32)
    with pytest.raises(CloudCursorError):
        otherKey.listDocuments(ONE, pageSize=1, cursor=cursor)
    codec = CloudCursorCodec(b"c" * 32, ("sqlite", str(tmp_path / "other.db")))
    fields = json.loads(
        base64.urlsafe_b64decode(cursor.split(".")[1] + "=" * (-len(cursor.split(".")[1]) % 4))
    )
    fields["authority"] = codec.authorityDigest
    with pytest.raises(CloudCursorError):
        store.listDocuments(ONE, pageSize=1, cursor=codec.encode(fields))


def test_cursor_expiry_does_not_extend_on_next_page_and_restart_keeps_scope(
    storage: Storage,
) -> None:
    clock = [datetime(2026, 10, 11, tzinfo=UTC)]
    store = pagedStore(storage, clock)
    for name in ("first", "second", "third"):
        addDocument(store, name)
    cursor = store.listDocuments(ONE, pageSize=1).nextCursor
    assert cursor is not None
    clock[0] += timedelta(seconds=899)
    second = pagedStore(storage, clock).listDocuments(ONE, pageSize=1, cursor=cursor)
    assert second.nextCursor is not None
    clock[0] += timedelta(seconds=1)
    with pytest.raises(CloudCursorError, match="cloud_cursor_expired"):
        store.listDocuments(ONE, pageSize=1, cursor=second.nextCursor)


@pytest.mark.parametrize("corrupt", ["", "c1.a.x", "c1.." + "a" * 64, "x" * 2049])
def test_bad_cursor_has_fixed_error(storage: Storage, corrupt: str) -> None:
    with pytest.raises(CloudCursorError, match="^cloud_cursor_invalid$"):
        pagedStore(storage).listDocuments(ONE, cursor=corrupt)


def test_metadata_page_has_utf8_byte_bound_without_truncating_title(storage: Storage) -> None:
    store = pagedStore(storage)
    title = "中" * 12000
    addDocument(store, "first", title=title)
    addDocument(store, "second", title=title)
    page = store.listDocuments(ONE, pageSize=50)
    assert len(page.items) == 1 and page.items[0].title == title
    assert sum(pageItemBytes(item) for item in page.items) <= 60000
    assert page.nextCursor is not None
    second = store.listDocuments(ONE, pageSize=50, cursor=page.nextCursor)
    assert len(second.items) == 1 and second.items[0].documentId == "second"


def test_metadata_corruption_fails_without_echoing_value(storage: Storage) -> None:
    store = pagedStore(storage)
    addDocument(store, "first")
    with storage[1].immediateTransaction() as connection:
        connection.execute(
            "UPDATE cloud_documents SET document_json=?",
            (
                b'{"id":"first","title":123,"currentVersionId":"version-one","createdAt":"bad","updatedAt":"bad"}',
            ),
        )
    with pytest.raises(StorageUnavailableError, match="^cloud_storage_inconsistent$"):
        store.listDocuments(ONE)


def test_valid_cursor_does_not_bypass_session_revocation(storage: Storage) -> None:
    store = pagedStore(storage)
    addDocument(store, "first")
    addDocument(store, "second")
    cursor = store.listDocuments(ONE, pageSize=1).nextCursor
    with storage[1].immediateTransaction() as connection:
        connection.execute(
            "UPDATE account_sessions SET revoked_at_utc=? WHERE account_id=?",
            ("2026-10-11T00:00:00.000000Z", ONE.accountId),
        )
    with pytest.raises(CloudAuthenticationError):
        store.listDocuments(ONE, pageSize=1, cursor=cursor)


def test_page_configuration_and_sequence_are_not_silently_normalized(storage: Storage) -> None:
    store = pagedStore(storage)
    for size in (True, 0, 51):
        with pytest.raises(ValueError, match="invalid_cloud_page_size"):
            store.listDocuments(ONE, pageSize=size)
    for sequence in (True, -1, 2**63):
        with pytest.raises(ValueError, match="invalid_cloud_sequence"):
            store.listDocuments(ONE, sinceSequence=sequence)
    with pytest.raises(CloudCursorError, match="cloud_sequence_ahead"):
        store.listDocuments(ONE, sinceSequence=1)
    with pytest.raises(ValueError, match="cloud_cursor_secret_required"):
        storage[0].listDocuments(ONE)
    with pytest.raises(ValueError, match="invalid_cloud_cursor_secret"):
        CloudResumeStore(SqliteAccountDatabase(storage[1]), POLICY, cursorSecret=b"short")


def test_empty_account_with_valid_zero_counter_has_empty_page(storage: Storage) -> None:
    with storage[1].immediateTransaction() as connection:
        connection.execute("INSERT INTO cloud_account_state VALUES (?,0)", (ONE.accountId,))
    page = pagedStore(storage).listDocuments(ONE)
    assert page.items == () and page.nextCursor is None and page.highWatermark == 0


@pytest.mark.parametrize(
    "mutation",
    [
        "tamper",
        "duplicate",
        "boolSequence",
        "tooFar",
        "futureExpiry",
        "oversizeDocument",
        "unknownField",
    ],
)
def test_cursor_parser_rejects_malformed_signed_state(storage: Storage, mutation: str) -> None:
    store = pagedStore(storage)
    addDocument(store, "first")
    addDocument(store, "second")
    cursor = store.listDocuments(ONE, pageSize=1).nextCursor
    assert cursor is not None
    fields = json.loads(
        base64.urlsafe_b64decode(cursor.split(".")[1] + "=" * (-len(cursor.split(".")[1]) % 4))
    )
    if mutation == "tamper":
        invalid = cursor[:-1] + ("0" if cursor[-1] != "0" else "1")
    else:
        if mutation == "boolSequence":
            fields["lastSequence"] = True
        elif mutation == "tooFar":
            fields["watermark"] = 999
        elif mutation == "futureExpiry":
            fields["expires"] += 1
        elif mutation == "oversizeDocument":
            fields["lastDocument"] = "中" * 171
        elif mutation == "unknownField":
            fields["extra"] = "private"
        raw = json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        if mutation == "duplicate":
            raw = raw[:-1] + b',"lastSequence":2}'
        body = base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
        signature = hmac.new(b"c" * 32, body.encode(), hashlib.sha256).hexdigest()
        invalid = "c1." + body + "." + signature
    with pytest.raises(CloudCursorError, match="^cloud_cursor_invalid$"):
        store.listDocuments(ONE, pageSize=1, cursor=invalid)
