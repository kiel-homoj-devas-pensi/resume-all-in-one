from __future__ import annotations

import json
import sqlite3
from collections.abc import Iterator, Mapping
from concurrent.futures import ThreadPoolExecutor
from contextlib import AbstractContextManager, contextmanager
from datetime import UTC, datetime
from pathlib import Path
from threading import Barrier, Event
from uuid import uuid4

import pytest

from agent_gateway import sqlite_cloud_schema
from agent_gateway.account_lifecycle import AccountLifecycleService, FakeSmsSender
from agent_gateway.account_storage import (
    AccountSqlConnection,
    SqliteAccountDatabase,
    StorageUnavailableError,
    UnknownStorageCommitError,
)
from agent_gateway.canonical_snapshot import CanonicalSnapshot
from agent_gateway.cloud_storage import (
    CloudAuthenticationError,
    CloudIdempotencyConflict,
    CloudNotAccessible,
    CloudOperationResult,
    CloudResumeStore,
    CloudSession,
    CloudSyncPolicy,
)
from agent_gateway.database import GatewayDatabase, UnsupportedDatabaseSchemaError
from agent_gateway.identity import (
    AccountService,
    AuthenticationFailedError,
    FakePhoneOwnershipVerifier,
    hashSecret,
)
from agent_gateway.lifecycle_storage import RelationalLifecycleStore, SqliteLifecycleStore
from agent_gateway.sqlite_cloud_schema import migrateSqliteCloudSchema

POLICY = CloudSyncPolicy("synthetic-v1", "local-synthetic", 0, 0, "synthetic-database")
ONE = CloudSession("account-one", "a" * 64)
TWO = CloudSession("account-two", "b" * 64)
Storage = tuple[CloudResumeStore, GatewayDatabase]


def operation() -> str:
    return "sync-" + str(uuid4())


def snapshot(version: str = "version-one", parent: str | None = None) -> CanonicalSnapshot:
    root = Path(__file__).resolve().parents[3]
    content = json.loads(
        (root / "packages/resume_domain/test/fixtures/resume_v0_1.json").read_text(encoding="utf-8")
    )
    return CanonicalSnapshot(
        json.dumps(
            {
                "document": {
                    "id": "document-one",
                    "title": "合成文档",
                    "currentVersionId": version,
                    "createdAt": "2026-10-11T00:00:00Z",
                    "updatedAt": "2026-10-11T01:00:00Z",
                    "metadata": {"nested": [None, " 保留 "]},
                    "futureDocument": True,
                },
                "version": {
                    "id": version,
                    "documentId": "document-one",
                    "parentVersionId": parent,
                    "schemaVersion": "0.1.0",
                    "content": content,
                    "source": "created" if parent is None else "edited",
                    "createdAt": "2026-10-11T01:00:00Z",
                    "futureVersion": [1, 1.25],
                },
            },
            ensure_ascii=False,
        ).encode("utf-8")
    )


@pytest.fixture
def storage(tmp_path: Path) -> Storage:
    database = GatewayDatabase(tmp_path / "cloud.db")
    database.initialize()
    with database.immediateTransaction() as connection:
        for identity, phone in ((ONE, "+00000000001"), (TWO, "+00000000002")):
            connection.execute(
                "INSERT INTO accounts VALUES (?, ?, ?, ?, ?, ?)",
                (
                    identity.accountId,
                    phone,
                    "synthetic-unused-hash",
                    "2026-01-01T00:00:00.000000Z",
                    1,
                    "2026-01-01T00:00:00.000000Z",
                ),
            )
            connection.execute(
                "INSERT INTO account_sessions VALUES (?, ?, ?, ?, ?, ?)",
                (
                    "session-" + identity.accountId,
                    identity.accountId,
                    identity.tokenHash,
                    "2099-01-01T00:00:00.000000Z",
                    None,
                    "2026-01-01T00:00:00.000000Z",
                ),
            )
    migrateSqliteCloudSchema(database)
    database.checkSchema(withCloud=True)
    return CloudResumeStore(SqliteAccountDatabase(database), POLICY), database


def approve(store: CloudResumeStore, identity: CloudSession = ONE) -> None:
    assert (
        store.grantConsent(identity, "document-one", operation(), POLICY.fingerprint).outcome
        == "applied"
    )


def append(
    store: CloudResumeStore,
    value: CanonicalSnapshot,
    identity: CloudSession = ONE,
    *,
    op: str | None = None,
) -> CloudOperationResult:
    return store.appendVersion(
        identity, op or operation(), value, value.parentVersionId, POLICY.fingerprint
    )


def test_validated_bytes_versions_and_operation_survive_restart(storage: Storage) -> None:
    store, database = storage
    approve(store)
    original = snapshot()
    op = operation()
    result = append(store, original, op=op)
    assert result.outcome == "applied" and result.sequence == 2
    reopened = CloudResumeStore(
        SqliteAccountDatabase(GatewayDatabase(database.databasePath)), POLICY
    )
    assert reopened.getVersion(ONE, "document-one", "version-one").payload == original.payload
    assert reopened.lookupOperation(ONE, op) == result
    assert append(reopened, original, op=op) == result
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 1
        assert (
            connection.execute("SELECT last_sequence FROM cloud_account_state").fetchone()[0] == 2
        )


def test_conflict_is_persisted_without_advancing_pointer_or_accepting_changed_replay(
    storage: Storage,
) -> None:
    store, database = storage
    approve(store)
    append(store, snapshot())
    first = append(store, snapshot("version-two", "version-one"))
    stale = snapshot("version-three", "version-one")
    op = operation()
    conflict = append(store, stale, op=op)
    assert conflict.outcome == "rejected" and conflict.code == "cloud_write_conflict"
    assert conflict.sequence is None
    assert append(store, stale, op=op) == conflict
    with pytest.raises(CloudIdempotencyConflict):
        append(store, snapshot("version-four", "version-two"), op=op)
    assert store.getCurrent(ONE, "document-one").versionId == first.versionId == "version-two"
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 2
        assert (
            connection.execute("SELECT last_sequence FROM cloud_account_state").fetchone()[0] == 3
        )


def test_consent_scope_policy_and_revocation_are_checked_inside_transaction(
    storage: Storage,
) -> None:
    store, _ = storage
    missing = append(store, snapshot())
    assert missing.code == "cloud_consent_required"
    wrong = store.grantConsent(ONE, "document-one", operation(), "0" * 64)
    assert wrong.code == "cloud_policy_changed"
    approve(store)
    append(store, snapshot())
    revoke = store.revokeConsent(ONE, "document-one", operation())
    assert revoke.outcome == "applied"
    assert append(store, snapshot("version-two", "version-one")).code == "cloud_consent_required"
    assert store.getCurrent(ONE, "document-one").versionId == "version-one"
    approve(store)
    assert append(store, snapshot("version-two", "version-one")).outcome == "applied"


def test_another_account_cannot_read_versions_operations_or_delete_documents(
    storage: Storage,
) -> None:
    store, _ = storage
    approve(store)
    op = operation()
    append(store, snapshot(), op=op)
    with pytest.raises(CloudNotAccessible):
        store.getVersion(TWO, "document-one", "version-one")
    assert store.lookupOperation(TWO, op) is None
    assert store.deleteDocument(TWO, "document-one", operation()).code == "cloud_not_accessible"
    # 相同文档 ID 属于不同账号各自的命名空间，不抢占别人的稳定 ID。
    approve(store, TWO)
    assert append(store, snapshot(), TWO).outcome == "applied"
    assert store.getVersion(ONE, "document-one", "version-one").payload == snapshot().payload


def test_deleted_document_never_revives_and_old_success_can_only_be_looked_up(
    storage: Storage,
) -> None:
    store, database = storage
    approve(store)
    op = operation()
    original = append(store, snapshot(), op=op)
    deletion = operation()
    deleted = store.deleteDocument(ONE, "document-one", deletion)
    assert deleted.outcome == "applied"
    assert store.deleteDocument(ONE, "document-one", deletion) == deleted
    assert store.deleteDocument(ONE, "document-one", operation()).sequence == deleted.sequence
    assert append(store, snapshot(), op=op) == original
    assert append(store, snapshot("version-two", "version-one")).code == "cloud_not_accessible"
    assert (
        store.grantConsent(ONE, "document-one", operation(), POLICY.fingerprint).code
        == "cloud_not_accessible"
    )
    with pytest.raises(CloudNotAccessible):
        store.getCurrent(ONE, "document-one")
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 1


def test_revoked_expired_or_deactivated_session_cannot_write_after_prior_authentication(
    storage: Storage,
) -> None:
    store, database = storage
    approve(store)
    with database.immediateTransaction() as connection:
        connection.execute(
            "UPDATE account_sessions SET revoked_at_utc='2026-10-11T00:00:00.000000Z' "
            "WHERE account_id=?",
            (ONE.accountId,),
        )
    with pytest.raises(CloudAuthenticationError):
        append(store, snapshot())
    with database.immediateTransaction() as connection:
        connection.execute(
            "UPDATE account_sessions SET revoked_at_utc=NULL, "
            "expires_at_utc='2020-01-01T00:00:00.000000Z' WHERE account_id=?",
            (ONE.accountId,),
        )
    with pytest.raises(CloudAuthenticationError):
        append(store, snapshot())
    with database.immediateTransaction() as connection:
        connection.execute(
            "UPDATE account_sessions SET expires_at_utc='2099-01-01T00:00:00.000000Z' "
            "WHERE account_id=?",
            (ONE.accountId,),
        )
        connection.execute("UPDATE accounts SET is_active=0 WHERE account_id=?", (ONE.accountId,))
    with pytest.raises(CloudAuthenticationError):
        store.grantConsent(ONE, "document-one", operation(), POLICY.fingerprint)


def test_creation_time_and_monotonic_author_time_match_local_repository(storage: Storage) -> None:
    store, _ = storage
    approve(store)
    append(store, snapshot())
    value = snapshot("version-two", "version-one").toJson()
    value["document"]["createdAt"] = "2026-10-10T23:59:59Z"
    assert (
        append(store, CanonicalSnapshot(json.dumps(value).encode())).code
        == "cloud_document_time_changed"
    )
    value["document"]["createdAt"] = "2026-10-11T08:00:00+08:00"
    value["document"]["updatedAt"] = "2026-10-11T00:59:59Z"
    assert (
        append(store, CanonicalSnapshot(json.dumps(value).encode())).code
        == "cloud_document_time_changed"
    )
    value["document"]["updatedAt"] = "2026-10-11T01:00:00Z"
    assert append(store, CanonicalSnapshot(json.dumps(value).encode())).outcome == "applied"


class FailingConnection:
    def __init__(self, connection: AccountSqlConnection, statement: str) -> None:
        self.connection = connection
        self.statement = statement

    def execute(self, sql: str, parameters: tuple[object, ...] = ()) -> int:
        if sql.startswith(self.statement):
            raise StorageUnavailableError("synthetic_write_failure")
        return self.connection.execute(sql, parameters)

    def fetchOne(
        self, sql: str, parameters: tuple[object, ...] = ()
    ) -> Mapping[str, object] | None:
        return self.connection.fetchOne(sql, parameters)

    def fetchMany(
        self, sql: str, parameters: tuple[object, ...] = (), *, maximumRows: int
    ) -> tuple[Mapping[str, object], ...]:
        return self.connection.fetchMany(sql, parameters, maximumRows=maximumRows)


class FaultDatabase:
    def __init__(self, database: GatewayDatabase, statement: str | None) -> None:
        self.database = SqliteAccountDatabase(database)
        self.statement = statement
        self.transactions = 0

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return self.database.authorityKey

    def readConnection(self) -> AbstractContextManager[AccountSqlConnection]:
        return self.database.readConnection()

    @contextmanager
    def transaction(self) -> Iterator[AccountSqlConnection]:
        self.transactions += 1
        with self.database.transaction() as connection:
            yield (
                connection
                if self.statement is None
                else FailingConnection(connection, self.statement)
            )
        if self.statement is None:
            # 数据库确实已提交，再丢失确认；业务层必须保留未知语义。
            raise UnknownStorageCommitError("synthetic_commit_ack_lost")


@pytest.mark.parametrize("existing", [False, True])
def test_operation_write_failure_rolls_back_version_pointer_and_sequence(
    storage: Storage, existing: bool
) -> None:
    store, database = storage
    approve(store)
    if existing:
        append(store, snapshot())
    fault = FaultDatabase(database, "INSERT INTO cloud_operations")
    broken = CloudResumeStore(fault, POLICY)
    attempted = snapshot("version-two", "version-one") if existing else snapshot()
    op = operation()
    with pytest.raises(StorageUnavailableError, match="synthetic_write_failure"):
        append(broken, attempted, op=op)
    assert fault.transactions == 1
    assert store.lookupOperation(ONE, op) is None
    if existing:
        assert store.getCurrent(ONE, "document-one").versionId == "version-one"
    else:
        with pytest.raises(CloudNotAccessible):
            store.getCurrent(ONE, "document-one")
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == int(
            existing
        )
        assert connection.execute("SELECT last_sequence FROM cloud_account_state").fetchone()[
            0
        ] == 1 + int(existing)
    assert append(store, attempted, op=op).outcome == "applied"


def test_lost_commit_ack_is_not_retried_and_original_operation_can_be_queried(
    storage: Storage,
) -> None:
    store, database = storage
    approve(store)
    fault = FaultDatabase(database, None)
    broken = CloudResumeStore(fault, POLICY)
    op = operation()
    with pytest.raises(UnknownStorageCommitError):
        append(broken, snapshot(), op=op)
    assert fault.transactions == 1
    reopened = CloudResumeStore(
        SqliteAccountDatabase(GatewayDatabase(database.databasePath)), POLICY
    )
    result = reopened.lookupOperation(ONE, op)
    assert result is not None and result.outcome == "applied" and result.sequence == 2
    assert append(reopened, snapshot(), op=op) == result
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 1


def test_two_independent_connections_from_same_base_have_one_winner(storage: Storage) -> None:
    store, database = storage
    approve(store)
    append(store, snapshot())
    barrier = Barrier(2)

    def write(version: str) -> CloudOperationResult:
        separate = CloudResumeStore(
            SqliteAccountDatabase(GatewayDatabase(database.databasePath)), POLICY
        )
        barrier.wait(timeout=10)
        return append(separate, snapshot(version, "version-one"))

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(write, ("version-two", "version-three")))
    assert sorted(result.code for result in results) == ["cloud_write_conflict", "ok"]
    winner = next(result for result in results if result.outcome == "applied")
    assert store.getCurrent(ONE, "document-one").versionId == winner.versionId
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 2
        assert (
            connection.execute("SELECT last_sequence FROM cloud_account_state").fetchone()[0] == 3
        )


@pytest.mark.parametrize("field", ["snapshot_sha256", "document_json", "parent_version_id"])
def test_corrupted_snapshot_or_metadata_is_never_returned(storage: Storage, field: str) -> None:
    store, database = storage
    approve(store)
    append(store, snapshot())
    with database.immediateTransaction() as connection:
        if field == "snapshot_sha256":
            connection.execute("UPDATE cloud_versions SET snapshot_sha256=?", ("0" * 64,))
        elif field == "document_json":
            connection.execute("UPDATE cloud_documents SET document_json=?", (b"{}",))
        else:
            # Same-document FK remains valid; the payload's declared parent still must agree.
            connection.execute("UPDATE cloud_versions SET parent_version_id=version_id")
    with pytest.raises(StorageUnavailableError, match="cloud_storage_inconsistent"):
        store.getCurrent(ONE, "document-one")


def test_expiry_is_checked_after_waiting_for_the_account_lock(storage: Storage) -> None:
    _, database = storage
    now = datetime(2026, 10, 11, tzinfo=UTC)
    store = CloudResumeStore(
        SqliteAccountDatabase(database),
        POLICY,
        clock=lambda: now,
    )
    started = Event()

    def write() -> CloudOperationResult:
        started.set()
        return store.grantConsent(ONE, "document-one", operation(), POLICY.fingerprint)

    with ThreadPoolExecutor(max_workers=1) as executor:
        # 先持有实际 SQLite 写锁；等待中的请求不能用开始时的有效时间通过。
        with database.immediateTransaction():
            future = executor.submit(write)
            assert started.wait(timeout=10)
            now = datetime(2100, 1, 1, tzinfo=UTC)
        with pytest.raises(CloudAuthenticationError):
            future.result(timeout=10)


def test_real_account_deactivation_and_cloud_retirement_commit_together(tmp_path: Path) -> None:
    database = GatewayDatabase(tmp_path / "lifecycle.db")
    database.initialize()
    accounts = AccountService(database, FakePhoneOwnershipVerifier())
    phone, password = "+15550000001", "Cloud2026!"
    accountId = accounts.registerAccount(
        phoneE164=phone,
        password=password,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    token = accounts.createSession(phoneE164=phone, password=password).sessionToken
    migrateSqliteCloudSchema(database)
    cloud = CloudResumeStore(SqliteAccountDatabase(database), POLICY)
    identity = CloudSession(accountId, hashSecret(token))
    approve(cloud, identity)
    append(cloud, snapshot(), identity)
    lifecycle = AccountLifecycleService(
        accounts,
        FakeSmsSender(),
        otpSecret=b"synthetic-only-otp-secret-32-bytes",
        store=SqliteLifecycleStore(database, withCloud=True),
    )
    lifecycle.deactivate(token, password)
    with pytest.raises(AuthenticationFailedError):
        accounts.authenticateSession(token)
    with pytest.raises(CloudAuthenticationError):
        cloud.getCurrent(identity, "document-one")
    with database.readConnection() as connection:
        document = connection.execute(
            "SELECT deleted_at_utc,last_sequence FROM cloud_documents"
        ).fetchone()
        assert document[0] is not None and document[1] == 3
        assert (
            connection.execute("SELECT revoked_at_utc FROM cloud_consents").fetchone()[0]
            is not None
        )
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 1


def test_account_mutation_failure_rolls_back_cloud_retirement_and_revocation(
    storage: Storage,
) -> None:
    store, database = storage
    approve(store)
    append(store, snapshot())
    fault = FaultDatabase(database, "UPDATE accounts SET is_active")
    lifecycle = RelationalLifecycleStore(fault, mysql=False, withCloud=True)
    with pytest.raises(StorageUnavailableError):
        with lifecycle.transaction() as connection:
            connection.findAccount(ONE.accountId, lock=True)
            connection.deactivate(
                ONE.accountId, "disabled:synthetic", "2026-10-11T03:00:00.000000Z"
            )
    assert store.getCurrent(ONE, "document-one").versionId == "version-one"
    assert append(store, snapshot("version-two", "version-one")).outcome == "applied"
    with database.readConnection() as connection:
        assert (
            connection.execute("SELECT deleted_at_utc FROM cloud_documents").fetchone()[0] is None
        )
        assert connection.execute("SELECT revoked_at_utc FROM cloud_consents").fetchone()[0] is None


def test_same_operation_concurrently_submitted_has_one_version_and_one_result(
    storage: Storage,
) -> None:
    store, database = storage
    approve(store)
    op, original = operation(), snapshot()
    barrier = Barrier(2)

    def write(_: int) -> CloudOperationResult:
        separate = CloudResumeStore(SqliteAccountDatabase(database), POLICY)
        barrier.wait(timeout=10)
        return append(separate, original, op=op)

    with ThreadPoolExecutor(max_workers=2) as executor:
        first, second = executor.map(write, (1, 2))
    assert first == second and first.sequence == 2
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_versions").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM cloud_operations").fetchone()[0] == 2


def test_failed_consent_record_rolls_back_its_operation_and_counter(storage: Storage) -> None:
    store, database = storage
    op = operation()
    broken = CloudResumeStore(FaultDatabase(database, "INSERT INTO cloud_consents"), POLICY)
    with pytest.raises(StorageUnavailableError):
        broken.grantConsent(ONE, "document-one", op, POLICY.fingerprint)
    assert store.lookupOperation(ONE, op) is None
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM cloud_account_state").fetchone()[0] == 0
        assert connection.execute("SELECT COUNT(*) FROM cloud_consents").fetchone()[0] == 0


def test_failed_delete_keeps_body_pointer_sequence_and_upload_consent(storage: Storage) -> None:
    store, database = storage
    approve(store)
    append(store, snapshot())
    op = operation()
    broken = CloudResumeStore(FaultDatabase(database, "INSERT INTO cloud_operations"), POLICY)
    with pytest.raises(StorageUnavailableError):
        broken.deleteDocument(ONE, "document-one", op)
    assert store.lookupOperation(ONE, op) is None
    assert store.getCurrent(ONE, "document-one").versionId == "version-one"
    assert append(store, snapshot("version-two", "version-one")).sequence == 3


def test_explicit_migration_preserves_accounts_and_repeat_does_not_reset_cloud(
    storage: Storage,
) -> None:
    store, database = storage
    approve(store)
    op = operation()
    result = append(store, snapshot(), op=op)
    migrateSqliteCloudSchema(database)
    database.checkSchema(withCloud=True)
    assert store.lookupOperation(ONE, op) == result
    assert store.getCurrent(ONE, "document-one").payload == snapshot().payload
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 2
        assert connection.execute("SELECT COUNT(*) FROM schema_migrations").fetchone()[0] == 6
    with pytest.raises(UnsupportedDatabaseSchemaError):
        database.checkSchema()


def test_missing_database_is_not_created_by_cloud_migration(tmp_path: Path) -> None:
    path = tmp_path / "absent.db"
    with pytest.raises(sqlite3.OperationalError):
        migrateSqliteCloudSchema(GatewayDatabase(path))
    assert not path.exists()


def test_cloud_migration_failure_rolls_back_tables_version_and_migration_record(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = GatewayDatabase(tmp_path / "migration.db")
    database.initialize()
    apply = sqlite_cloud_schema.applyCloudSchema

    def failAfterTables(connection: sqlite3.Connection) -> None:
        apply(connection)
        raise StorageUnavailableError("synthetic_migration_failure")

    monkeypatch.setattr(sqlite_cloud_schema, "applyCloudSchema", failAfterTables)
    with pytest.raises(StorageUnavailableError):
        migrateSqliteCloudSchema(database)
    database.checkSchema()
    with database.readConnection() as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 5
        assert connection.execute("SELECT COUNT(*) FROM schema_migrations").fetchone()[0] == 5
        assert (
            connection.execute(
                "SELECT COUNT(*) FROM sqlite_schema WHERE name LIKE 'cloud_%'"
            ).fetchone()[0]
            == 0
        )


def test_unknown_tables_cannot_be_adopted_as_an_approved_cloud_schema(tmp_path: Path) -> None:
    database = GatewayDatabase(tmp_path / "unexpected.db")
    database.initialize()
    with database.immediateTransaction() as connection:
        connection.execute("CREATE TABLE cloud_documents(unapproved TEXT)")
    with pytest.raises(UnsupportedDatabaseSchemaError):
        migrateSqliteCloudSchema(database)
    with database.readConnection() as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 5


def test_success_result_requires_a_committed_sequence(storage: Storage) -> None:
    _, database = storage
    with pytest.raises(sqlite3.IntegrityError):
        with database.immediateTransaction() as connection:
            connection.execute(
                "INSERT INTO cloud_operations VALUES (?,?,?,?,?,?,?,?,?,?)",
                (
                    ONE.accountId,
                    operation(),
                    "deleteDocument",
                    b"document-one",
                    "0" * 64,
                    "applied",
                    "ok",
                    None,
                    None,
                    "2026-10-11T00:00:00.000000Z",
                ),
            )
