from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Callable, Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal, cast
from uuid import UUID

from .account_storage import (
    AccountSqlConnection,
    AccountSqlDatabase,
    StorageUnavailableError,
    storedText,
)
from .canonical_snapshot import CanonicalSnapshot, CanonicalSnapshotError
from .cloud_pages import (
    CURSOR_SECONDS,
    PAGE_BYTES,
    CloudCursorCodec,
    CloudCursorError,
    CloudDocumentMetadata,
    CloudPage,
    CloudVersionMetadata,
    metadataObject,
    metadataSequence,
    metadataText,
    metadataTime,
    pageItemBytes,
)
from .identity import requireUtc, toUtcText

CloudAction = Literal["grantConsent", "revokeConsent", "appendVersion", "deleteDocument"]
CloudOutcome = Literal["applied", "rejected"]
_LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}")
_DIGEST = re.compile(r"[0-9a-f]{64}")


class CloudAuthenticationError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("cloud_unauthenticated")


class CloudNotAccessible(RuntimeError):
    def __init__(self) -> None:
        super().__init__("cloud_not_accessible")


class CloudIdempotencyConflict(RuntimeError):
    def __init__(self) -> None:
        super().__init__("cloud_idempotency_conflict")


@dataclass(frozen=True, slots=True, repr=False)
class CloudSession:
    accountId: str
    tokenHash: str

    def __post_init__(self) -> None:
        if _LABEL.fullmatch(self.accountId) is None or _DIGEST.fullmatch(self.tokenHash) is None:
            raise ValueError("invalid_cloud_session")


@dataclass(frozen=True, slots=True)
class CloudSyncPolicy:
    policyVersion: str
    region: str
    contentRetentionDays: int
    backupRetentionDays: int
    resourceIdentity: str

    def __post_init__(self) -> None:
        if any(
            _LABEL.fullmatch(value) is None
            for value in (
                self.policyVersion,
                self.region,
                self.resourceIdentity,
            )
        ) or any(
            type(value) is not int or not 0 <= value <= 3650
            for value in (
                self.contentRetentionDays,
                self.backupRetentionDays,
            )
        ):
            raise ValueError("invalid_cloud_policy")

    @property
    def fingerprint(self) -> str:
        return _fingerprint(
            {
                "policyVersion": self.policyVersion,
                "region": self.region,
                "contentRetentionDays": self.contentRetentionDays,
                "backupRetentionDays": self.backupRetentionDays,
                "resourceIdentity": self.resourceIdentity,
                "scope": "canonicalDocument",
            }
        )


@dataclass(frozen=True, slots=True)
class CloudOperationResult:
    operationId: str = field(repr=False)
    documentId: str = field(repr=False)
    outcome: CloudOutcome
    code: str
    sequence: int | None
    versionId: str | None = field(repr=False)
    committedAtUtc: str


def _fingerprint(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    ).hexdigest()


def _documentKey(value: str) -> bytes:
    try:
        encoded = value.encode("utf-8")
        if not value.strip() or not 1 <= len(encoded) <= 512:
            raise ValueError("invalid_cloud_identity")
        return encoded
    except UnicodeError:
        raise ValueError("invalid_cloud_identity") from None


def _operationId(value: str) -> None:
    try:
        parsed = UUID(value.removeprefix("sync-"))
        if parsed.version != 4 or value != "sync-" + str(parsed):
            raise ValueError("invalid_cloud_operation")
    except ValueError:
        raise ValueError("invalid_cloud_operation") from None


def _binary(value: object) -> bytes:
    if not isinstance(value, bytes):
        raise StorageUnavailableError("cloud_storage_inconsistent")
    return value


def _cloudSql(query: str, *, mysql: bool, lock: bool = False) -> str:
    # 只转换固定语句的方言；调用参数始终由驱动绑定。
    return query.replace("?", "%s" if mysql else "?") + (" FOR UPDATE" if mysql and lock else "")


def advanceCloudSequence(connection: AccountSqlConnection, accountId: str, *, mysql: bool) -> int:
    # 调用者必须已经持有账户锁，缺少计数行也不能并发建立两条。
    row = connection.fetchOne(
        _cloudSql(
            "SELECT last_sequence FROM cloud_account_state WHERE account_id=?",
            mysql=mysql,
            lock=True,
        ),
        (accountId,),
    )
    current = 0 if row is None else int(str(row["last_sequence"]))
    if not 0 <= current < 2**63 - 1:
        raise StorageUnavailableError("cloud_sequence_unavailable")
    if row is None:
        connection.execute(
            _cloudSql("INSERT INTO cloud_account_state VALUES (?,0)", mysql=mysql), (accountId,)
        )
    connection.execute(
        _cloudSql("UPDATE cloud_account_state SET last_sequence=? WHERE account_id=?", mysql=mysql),
        (current + 1, accountId),
    )
    return current + 1


def retireAccountCloudDocuments(
    connection: AccountSqlConnection, accountId: str, now: str, *, mysql: bool
) -> None:
    # 使用停用事务和它已持有的账户锁；不能另开连接后尽力删除。
    live = connection.fetchOne(
        _cloudSql(
            "SELECT document_id FROM cloud_documents WHERE account_id=? "
            "AND deleted_at_utc IS NULL LIMIT 1",
            mysql=mysql,
        ),
        (accountId,),
    )
    if live is not None:
        sequence = advanceCloudSequence(connection, accountId, mysql=mysql)
        connection.execute(
            _cloudSql(
                "UPDATE cloud_documents SET deleted_at_utc=?,last_sequence=? "
                "WHERE account_id=? AND deleted_at_utc IS NULL",
                mysql=mysql,
            ),
            (now, sequence, accountId),
        )
    connection.execute(
        _cloudSql(
            "UPDATE cloud_consents SET revoked_at_utc=? WHERE account_id=? "
            "AND revoked_at_utc IS NULL",
            mysql=mysql,
        ),
        (now, accountId),
    )


class CloudResumeStore:
    def __init__(
        self,
        database: AccountSqlDatabase,
        policy: CloudSyncPolicy,
        *,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
        cursorSecret: bytes | None = None,
    ) -> None:
        if database.authorityKey[0] not in {"sqlite", "mysql"}:
            raise ValueError("invalid_cloud_storage")
        self._database = database
        self._mysql = database.authorityKey[0] == "mysql"
        self._policy = policy
        self._clock = clock
        self._cursor = (
            None if cursorSecret is None else CloudCursorCodec(cursorSecret, database.authorityKey)
        )

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return self._database.authorityKey

    @property
    def policy(self) -> CloudSyncPolicy:
        return self._policy

    @property
    def hasCursorSecret(self) -> bool:
        return self._cursor is not None

    def checkSchema(self) -> None:
        # HTTP 启用只核对现有完整结构，不执行迁移或创建缺失数据库。
        if self._mysql:
            from .mysql_cloud_schema import validateCloudSchema

            with self._database.transaction() as connection:
                validateCloudSchema(connection)
        else:
            from .database import GatewayDatabase

            GatewayDatabase(Path(self.authorityKey[1])).checkSchema(withCloud=True)

    def _sql(self, query: str, *, lock: bool = False) -> str:
        if self._mysql:
            query = query.replace(
                "CAST(document_json AS TEXT)", "CONVERT(document_json USING utf8mb4)"
            )
            query = query.replace(
                "CAST(snapshot_payload AS TEXT)", "CONVERT(snapshot_payload USING utf8mb4)"
            )
        return _cloudSql(query, mysql=self._mysql, lock=lock)

    def _pageStart(
        self,
        connection: AccountSqlConnection,
        scope: dict[str, object],
        cursor: str | None,
        now: str,
        sinceSequence: int,
    ) -> tuple[int, int, str, int]:
        if self._cursor is None:
            raise ValueError("cloud_cursor_secret_required")
        row = connection.fetchOne(
            self._sql("SELECT last_sequence FROM cloud_account_state WHERE account_id=?"),
            (scope["account"],),
        )
        current = 0 if row is None else row["last_sequence"]
        if type(current) is not int or not 0 <= current < 2**63:
            raise StorageUnavailableError("cloud_storage_inconsistent")
        if sinceSequence > current:
            raise CloudCursorError("cloud_sequence_ahead")
        if cursor is None:
            return (
                current,
                sinceSequence,
                "",
                int(datetime.fromisoformat(now).timestamp()) + CURSOR_SECONDS,
            )
        result = self._cursor.decode(cursor, scope, now)
        if result[0] > current or result[1] <= sinceSequence:
            raise CloudCursorError()
        try:
            _documentKey(result[2])
        except ValueError:
            raise CloudCursorError() from None
        return result

    def _pageScope(
        self,
        identity: CloudSession,
        kind: str,
        documentId: str,
        pageSize: int,
        sinceSequence: int,
        includeDeleted: bool,
    ) -> dict[str, object]:
        if type(pageSize) is not int or not 1 <= pageSize <= 50:
            raise ValueError("invalid_cloud_page_size")
        if type(sinceSequence) is not int or not 0 <= sinceSequence < 2**63:
            raise ValueError("invalid_cloud_sequence")
        if type(includeDeleted) is not bool:
            raise ValueError("invalid_cloud_delete_filter")
        if self._cursor is None:
            raise ValueError("cloud_cursor_secret_required")
        return {
            "account": identity.accountId,
            "kind": kind,
            "document": documentId,
            "size": pageSize,
            "since": sinceSequence,
            "deleted": includeDeleted,
            "authority": self._cursor.authorityDigest,
        }

    def _nextCursor(
        self, scope: dict[str, object], watermark: int, last: int, document: str, expires: int
    ) -> str:
        if self._cursor is None:
            raise ValueError("cloud_cursor_secret_required")
        return self._cursor.encode(
            {
                **scope,
                "watermark": watermark,
                "lastSequence": last,
                "lastDocument": document,
                "expires": expires,
            }
        )

    def listDocuments(
        self,
        identity: CloudSession,
        *,
        pageSize: int = 20,
        sinceSequence: int = 0,
        includeDeleted: bool = False,
        cursor: str | None = None,
    ) -> CloudPage[CloudDocumentMetadata]:
        scope = self._pageScope(identity, "documents", "", pageSize, sinceSequence, includeDeleted)
        with self._authorizedTransaction(identity) as (connection, now):
            watermark, last, lastDocument, expires = self._pageStart(
                connection, scope, cursor, now, sinceSequence
            )
            rows = connection.fetchMany(
                self._sql(
                    "SELECT document_id,current_version_id,last_sequence,deleted_at_utc,"
                    "CASE WHEN deleted_at_utc IS NULL THEN JSON_OBJECT("
                    "'id',JSON_EXTRACT(CAST(document_json AS TEXT),'$.id'),"
                    "'title',JSON_EXTRACT(CAST(document_json AS TEXT),'$.title'),"
                    "'currentVersionId',"
                    "JSON_EXTRACT(CAST(document_json AS TEXT),'$.currentVersionId'),"
                    "'createdAt',JSON_EXTRACT(CAST(document_json AS TEXT),'$.createdAt'),"
                    "'updatedAt',JSON_EXTRACT(CAST(document_json AS TEXT),'$.updatedAt')) "
                    "ELSE NULL END AS metadata FROM cloud_documents WHERE account_id=? "
                    "AND last_sequence>? AND last_sequence<=? AND "
                    "(last_sequence>? OR (last_sequence=? AND document_id>?)) "
                    "AND (?=1 OR deleted_at_utc IS NULL) ORDER BY last_sequence,document_id LIMIT ?"
                ),
                (
                    identity.accountId,
                    sinceSequence,
                    watermark,
                    last,
                    last,
                    lastDocument.encode(),
                    int(includeDeleted),
                    pageSize + 1,
                ),
                maximumRows=pageSize + 1,
            )
            items: list[CloudDocumentMetadata] = []
            byteCount = 0
            for row in rows[:pageSize]:
                try:
                    documentId = _binary(row["document_id"]).decode("utf-8")
                    _documentKey(documentId)
                    sequence = metadataSequence(row["last_sequence"])
                    if row["deleted_at_utc"] is not None:
                        item = CloudDocumentMetadata(
                            documentId,
                            None,
                            None,
                            None,
                            None,
                            sequence,
                            metadataTime(storedText(row["deleted_at_utc"])),
                        )
                    else:
                        data = metadataObject(
                            row["metadata"],
                            {"id", "title", "currentVersionId", "createdAt", "updatedAt"},
                        )
                        versionId = _binary(row["current_version_id"]).decode("utf-8")
                        _documentKey(versionId)
                        if data["id"] != documentId or data["currentVersionId"] != versionId:
                            raise StorageUnavailableError("cloud_storage_inconsistent")
                        item = CloudDocumentMetadata(
                            documentId,
                            metadataText(data["title"]),
                            versionId,
                            metadataTime(data["createdAt"]),
                            metadataTime(data["updatedAt"]),
                            sequence,
                            None,
                        )
                except ValueError, UnicodeError:
                    raise StorageUnavailableError("cloud_storage_inconsistent") from None
                size = pageItemBytes(item)
                if size > PAGE_BYTES:
                    raise StorageUnavailableError("cloud_storage_inconsistent")
                if byteCount + size > PAGE_BYTES:
                    break
                items.append(item)
                byteCount += size
            nextCursor = None
            if items and len(rows) > len(items):
                tail = items[-1]
                nextCursor = self._nextCursor(
                    scope, watermark, tail.lastSequence, tail.documentId, expires
                )
            return CloudPage(tuple(items), nextCursor, watermark)

    def listVersions(
        self,
        identity: CloudSession,
        documentId: str,
        *,
        pageSize: int = 20,
        cursor: str | None = None,
    ) -> CloudPage[CloudVersionMetadata]:
        key = _documentKey(documentId)
        scope = self._pageScope(identity, "versions", documentId, pageSize, 0, False)
        with self._authorizedTransaction(identity) as (connection, now):
            live = connection.fetchOne(
                self._sql(
                    "SELECT document_id FROM cloud_documents WHERE account_id=? "
                    "AND document_id=? AND deleted_at_utc IS NULL"
                ),
                (identity.accountId, key),
            )
            if live is None:
                raise CloudNotAccessible()
            watermark, last, lastDocument, expires = self._pageStart(
                connection, scope, cursor, now, 0
            )
            if lastDocument not in {"", documentId}:
                raise CloudCursorError()
            rows = connection.fetchMany(
                self._sql(
                    "SELECT version_id,parent_version_id,commit_sequence,committed_at_utc,"
                    "JSON_OBJECT('id',JSON_EXTRACT(CAST(snapshot_payload AS TEXT),'$.version.id'),"
                    "'documentId',"
                    "JSON_EXTRACT(CAST(snapshot_payload AS TEXT),'$.version.documentId'),"
                    "'parentVersionId',"
                    "JSON_EXTRACT(CAST(snapshot_payload AS TEXT),'$.version.parentVersionId'),"
                    "'source',JSON_EXTRACT(CAST(snapshot_payload AS TEXT),'$.version.source'),"
                    "'createdAt',"
                    "JSON_EXTRACT(CAST(snapshot_payload AS TEXT),'$.version.createdAt')) "
                    "AS metadata "
                    "FROM cloud_versions WHERE account_id=? AND document_id=? "
                    "AND commit_sequence>? "
                    "AND commit_sequence<=? ORDER BY commit_sequence LIMIT ?"
                ),
                (identity.accountId, key, last, watermark, pageSize + 1),
                maximumRows=pageSize + 1,
            )
            items: list[CloudVersionMetadata] = []
            byteCount = 0
            for row in rows[:pageSize]:
                try:
                    versionId = _binary(row["version_id"]).decode("utf-8")
                    _documentKey(versionId)
                    parent = (
                        None
                        if row["parent_version_id"] is None
                        else _binary(row["parent_version_id"]).decode("utf-8")
                    )
                    if parent is not None:
                        _documentKey(parent)
                    data = metadataObject(
                        row["metadata"],
                        {"id", "documentId", "parentVersionId", "source", "createdAt"},
                    )
                    if (
                        data["id"] != versionId
                        or data["documentId"] != documentId
                        or data["parentVersionId"] != parent
                        or metadataText(data["source"])
                        not in {
                            "created",
                            "edited",
                            "imported",
                            "aiConfirmed",
                            "restored",
                            "migrated",
                        }
                    ):
                        raise StorageUnavailableError("cloud_storage_inconsistent")
                    item = CloudVersionMetadata(
                        documentId,
                        versionId,
                        parent,
                        metadataText(data["source"]),
                        metadataTime(data["createdAt"]),
                        metadataTime(storedText(row["committed_at_utc"])),
                        metadataSequence(row["commit_sequence"]),
                    )
                except ValueError, UnicodeError:
                    raise StorageUnavailableError("cloud_storage_inconsistent") from None
                size = pageItemBytes(item)
                if size > PAGE_BYTES:
                    raise StorageUnavailableError("cloud_storage_inconsistent")
                if byteCount + size > PAGE_BYTES:
                    break
                items.append(item)
                byteCount += size
            nextCursor = None
            if items and len(rows) > len(items):
                nextCursor = self._nextCursor(
                    scope, watermark, items[-1].sequence, documentId, expires
                )
            return CloudPage(tuple(items), nextCursor, watermark)

    def _authorize(
        self, connection: AccountSqlConnection, identity: CloudSession, *, lock: bool
    ) -> str:
        account = connection.fetchOne(
            self._sql("SELECT is_active FROM accounts WHERE account_id=?", lock=lock),
            (identity.accountId,),
        )
        # 等到账户锁后再取时间，不能用锁等待前的旧时间延长已过期会话。
        now = toUtcText(requireUtc(self._clock()))
        session = connection.fetchOne(
            self._sql(
                "SELECT session_id FROM account_sessions WHERE account_id=? AND token_hash=? "
                "AND revoked_at_utc IS NULL AND expires_at_utc>?"
            ),
            (identity.accountId, identity.tokenHash, now),
        )
        if account is None or account["is_active"] != 1 or session is None:
            raise CloudAuthenticationError()
        return now

    @contextmanager
    def _authorizedTransaction(
        self, identity: CloudSession
    ) -> Iterator[tuple[AccountSqlConnection, str]]:
        with self._database.transaction() as connection:
            yield connection, self._authorize(connection, identity, lock=True)

    def _sequence(self, connection: AccountSqlConnection, accountId: str) -> int:
        return advanceCloudSequence(connection, accountId, mysql=self._mysql)

    def _result(self, row: Mapping[str, object]) -> CloudOperationResult:
        return CloudOperationResult(
            storedText(row["operation_id"]),
            _binary(row["document_id"]).decode("utf-8"),
            cast(CloudOutcome, storedText(row["outcome"])),
            storedText(row["result_code"]),
            None if row["result_sequence"] is None else int(str(row["result_sequence"])),
            None if row["version_id"] is None else _binary(row["version_id"]).decode("utf-8"),
            storedText(row["committed_at_utc"]),
        )

    def _prior(
        self, connection: AccountSqlConnection, accountId: str, operationId: str, fingerprint: str
    ) -> CloudOperationResult | None:
        row = connection.fetchOne(
            self._sql("SELECT * FROM cloud_operations WHERE account_id=? AND operation_id=?"),
            (accountId, operationId),
        )
        if row is None:
            return None
        if storedText(row["request_fingerprint"]) != fingerprint:
            raise CloudIdempotencyConflict()
        return self._result(row)

    def _record(
        self,
        connection: AccountSqlConnection,
        identity: CloudSession,
        operationId: str,
        action: CloudAction,
        documentId: str,
        fingerprint: str,
        now: str,
        *,
        code: str = "ok",
        sequence: int | None = None,
        versionId: str | None = None,
    ) -> CloudOperationResult:
        outcome: CloudOutcome = "applied" if code == "ok" else "rejected"
        connection.execute(
            self._sql("INSERT INTO cloud_operations VALUES (?,?,?,?,?,?,?,?,?,?)"),
            (
                identity.accountId,
                operationId,
                action,
                _documentKey(documentId),
                fingerprint,
                outcome,
                code,
                None if versionId is None else _documentKey(versionId),
                sequence,
                now,
            ),
        )
        return CloudOperationResult(
            operationId, documentId, outcome, code, sequence, versionId, now
        )

    def _request(
        self, action: CloudAction, documentId: str, operationId: str, details: object
    ) -> str:
        _documentKey(documentId)
        _operationId(operationId)
        return _fingerprint({"action": action, "documentId": documentId, "details": details})

    def grantConsent(
        self, identity: CloudSession, documentId: str, operationId: str, policyFingerprint: str
    ) -> CloudOperationResult:
        if not isinstance(policyFingerprint, str) or _DIGEST.fullmatch(policyFingerprint) is None:
            raise ValueError("invalid_cloud_policy_fingerprint")
        fingerprint = self._request("grantConsent", documentId, operationId, policyFingerprint)
        with self._authorizedTransaction(identity) as (connection, now):
            prior = self._prior(connection, identity.accountId, operationId, fingerprint)
            if prior is not None:
                return prior
            document = connection.fetchOne(
                self._sql(
                    "SELECT deleted_at_utc FROM cloud_documents "
                    "WHERE account_id=? AND document_id=?"
                ),
                (identity.accountId, _documentKey(documentId)),
            )
            if document is not None and document["deleted_at_utc"] is not None:
                return self._record(
                    connection,
                    identity,
                    operationId,
                    "grantConsent",
                    documentId,
                    fingerprint,
                    now,
                    code="cloud_not_accessible",
                )
            if policyFingerprint != self._policy.fingerprint:
                return self._record(
                    connection,
                    identity,
                    operationId,
                    "grantConsent",
                    documentId,
                    fingerprint,
                    now,
                    code="cloud_policy_changed",
                )
            sequence = self._sequence(connection, identity.accountId)
            result = self._record(
                connection,
                identity,
                operationId,
                "grantConsent",
                documentId,
                fingerprint,
                now,
                sequence=sequence,
            )
            connection.execute(
                self._sql("INSERT INTO cloud_consents VALUES (?,?,?,?,?,?,NULL)"),
                (
                    identity.accountId,
                    _documentKey(documentId),
                    operationId,
                    self._policy.policyVersion,
                    self._policy.fingerprint,
                    now,
                ),
            )
            return result

    def revokeConsent(
        self, identity: CloudSession, documentId: str, operationId: str
    ) -> CloudOperationResult:
        fingerprint = self._request("revokeConsent", documentId, operationId, None)
        with self._authorizedTransaction(identity) as (connection, now):
            prior = self._prior(connection, identity.accountId, operationId, fingerprint)
            if prior is not None:
                return prior
            sequence = self._sequence(connection, identity.accountId)
            connection.execute(
                self._sql(
                    "UPDATE cloud_consents SET revoked_at_utc=? WHERE account_id=? AND "
                    "document_id=? AND revoked_at_utc IS NULL"
                ),
                (now, identity.accountId, _documentKey(documentId)),
            )
            return self._record(
                connection,
                identity,
                operationId,
                "revokeConsent",
                documentId,
                fingerprint,
                now,
                sequence=sequence,
            )

    def appendVersion(
        self,
        identity: CloudSession,
        operationId: str,
        snapshot: CanonicalSnapshot,
        expectedBaseVersionId: str | None,
        policyFingerprint: str,
    ) -> CloudOperationResult:
        documentId = snapshot.documentId
        if not isinstance(policyFingerprint, str) or _DIGEST.fullmatch(policyFingerprint) is None:
            raise ValueError("invalid_cloud_policy_fingerprint")
        _documentKey(snapshot.versionId)
        if expectedBaseVersionId is not None:
            _documentKey(expectedBaseVersionId)
        fingerprint = self._request(
            "appendVersion",
            documentId,
            operationId,
            {
                "snapshot": snapshot.fingerprint,
                "expectedBaseVersionId": expectedBaseVersionId,
                "policyFingerprint": policyFingerprint,
            },
        )
        with self._authorizedTransaction(identity) as (connection, now):
            prior = self._prior(connection, identity.accountId, operationId, fingerprint)
            if prior is not None:
                return prior
            key = (identity.accountId, _documentKey(documentId))
            row = connection.fetchOne(
                self._sql("SELECT * FROM cloud_documents WHERE account_id=? AND document_id=?"), key
            )
            code = "ok"
            if row is not None and row["deleted_at_utc"] is not None:
                code = "cloud_not_accessible"
            elif policyFingerprint != self._policy.fingerprint:
                code = "cloud_policy_changed"
            elif (
                connection.fetchOne(
                    self._sql(
                        "SELECT consent_id FROM cloud_consents WHERE account_id=? AND "
                        "document_id=? "
                        "AND policy_version=? AND policy_fingerprint=? AND revoked_at_utc "
                        "IS NULL LIMIT 1"
                    ),
                    (*key, self._policy.policyVersion, self._policy.fingerprint),
                )
                is None
            ):
                code = "cloud_consent_required"
            elif snapshot.parentVersionId != expectedBaseVersionId or (
                (None if row is None else _binary(row["current_version_id"]).decode("utf-8"))
                != expectedBaseVersionId
            ):
                code = "cloud_write_conflict"
            elif (
                connection.fetchOne(
                    self._sql(
                        "SELECT version_id FROM cloud_versions WHERE account_id=? AND "
                        "document_id=? AND version_id=?"
                    ),
                    (*key, _documentKey(snapshot.versionId)),
                )
                is not None
            ):
                code = "cloud_version_exists"
            value = snapshot.toJson()
            document = value["document"]
            if code == "ok" and row is not None:
                previous = json.loads(_binary(row["document_json"]))
                if datetime.fromisoformat(document["createdAt"]) != datetime.fromisoformat(
                    previous["createdAt"]
                ) or (
                    datetime.fromisoformat(document["updatedAt"])
                    < datetime.fromisoformat(previous["updatedAt"])
                ):
                    code = "cloud_document_time_changed"
            if code != "ok":
                # 拒绝也提交动作指纹，不写版本或推进文档/账户序号。
                return self._record(
                    connection,
                    identity,
                    operationId,
                    "appendVersion",
                    documentId,
                    fingerprint,
                    now,
                    code=code,
                )
            sequence = self._sequence(connection, identity.accountId)
            documentJson = json.dumps(
                document, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            if row is None:
                connection.execute(
                    self._sql("INSERT INTO cloud_documents VALUES (?,?,?,?,?,?,NULL)"),
                    (
                        *key,
                        _documentKey(snapshot.versionId),
                        documentJson,
                        sequence,
                        self._policy.contentRetentionDays,
                    ),
                )
            connection.execute(
                self._sql("INSERT INTO cloud_versions VALUES (?,?,?,?,?,?,?,?)"),
                (
                    *key,
                    _documentKey(snapshot.versionId),
                    None
                    if snapshot.parentVersionId is None
                    else _documentKey(snapshot.parentVersionId),
                    snapshot.payload,
                    snapshot.fingerprint,
                    sequence,
                    now,
                ),
            )
            if row is not None:
                connection.execute(
                    self._sql(
                        "UPDATE cloud_documents SET current_version_id=?, document_json=?, "
                        "last_sequence=?, content_retention_days=? "
                        "WHERE account_id=? AND document_id=?"
                    ),
                    (
                        _documentKey(snapshot.versionId),
                        documentJson,
                        sequence,
                        self._policy.contentRetentionDays,
                        *key,
                    ),
                )
            return self._record(
                connection,
                identity,
                operationId,
                "appendVersion",
                documentId,
                fingerprint,
                now,
                sequence=sequence,
                versionId=snapshot.versionId,
            )

    def deleteDocument(
        self, identity: CloudSession, documentId: str, operationId: str
    ) -> CloudOperationResult:
        fingerprint = self._request("deleteDocument", documentId, operationId, None)
        with self._authorizedTransaction(identity) as (connection, now):
            prior = self._prior(connection, identity.accountId, operationId, fingerprint)
            if prior is not None:
                return prior
            key = (identity.accountId, _documentKey(documentId))
            row = connection.fetchOne(
                self._sql(
                    "SELECT deleted_at_utc,last_sequence FROM cloud_documents WHERE "
                    "account_id=? AND document_id=?"
                ),
                key,
            )
            if row is None:
                return self._record(
                    connection,
                    identity,
                    operationId,
                    "deleteDocument",
                    documentId,
                    fingerprint,
                    now,
                    code="cloud_not_accessible",
                )
            sequence = (
                int(str(row["last_sequence"]))
                if row["deleted_at_utc"] is not None
                else self._sequence(connection, identity.accountId)
            )
            connection.execute(
                self._sql(
                    "UPDATE cloud_documents SET deleted_at_utc=?,last_sequence=? WHERE "
                    "account_id=? AND document_id=? AND deleted_at_utc IS NULL"
                ),
                (now, sequence, *key),
            )
            connection.execute(
                self._sql(
                    "UPDATE cloud_consents SET revoked_at_utc=? WHERE account_id=? AND "
                    "document_id=? AND revoked_at_utc IS NULL"
                ),
                (now, *key),
            )
            return self._record(
                connection,
                identity,
                operationId,
                "deleteDocument",
                documentId,
                fingerprint,
                now,
                sequence=sequence,
            )

    def lookupOperation(
        self, identity: CloudSession, operationId: str
    ) -> CloudOperationResult | None:
        _operationId(operationId)
        with self._authorizedTransaction(identity) as (connection, _):
            row = connection.fetchOne(
                self._sql("SELECT * FROM cloud_operations WHERE account_id=? AND operation_id=?"),
                (identity.accountId, operationId),
            )
            return None if row is None else self._result(row)

    def _snapshot(
        self, row: Mapping[str, object], documentId: str, versionId: str
    ) -> CanonicalSnapshot:
        try:
            raw = _binary(row["snapshot_payload"])
            snapshot = CanonicalSnapshot(raw)
            if (
                snapshot.documentId != documentId
                or snapshot.versionId != versionId
                or snapshot.parentVersionId
                != (
                    None
                    if row["parent_version_id"] is None
                    else _binary(row["parent_version_id"]).decode("utf-8")
                )
                or (
                    snapshot.fingerprint != storedText(row["snapshot_sha256"])
                    or snapshot.payload != raw
                )
            ):
                raise StorageUnavailableError("cloud_storage_inconsistent")
            return snapshot
        except CanonicalSnapshotError, UnicodeError:
            raise StorageUnavailableError("cloud_storage_inconsistent") from None

    def getVersion(
        self, identity: CloudSession, documentId: str, versionId: str
    ) -> CanonicalSnapshot:
        with self._authorizedTransaction(identity) as (connection, _):
            row = connection.fetchOne(
                self._sql(
                    "SELECT v.snapshot_payload,v.snapshot_sha256,v.parent_version_id "
                    "FROM cloud_versions v "
                    "JOIN cloud_documents d ON d.account_id=v.account_id AND "
                    "d.document_id=v.document_id "
                    "WHERE v.account_id=? AND v.document_id=? AND v.version_id=? AND "
                    "d.deleted_at_utc IS NULL"
                ),
                (identity.accountId, _documentKey(documentId), _documentKey(versionId)),
            )
            if row is None:
                raise CloudNotAccessible()
            return self._snapshot(row, documentId, versionId)

    def getCurrent(self, identity: CloudSession, documentId: str) -> CanonicalSnapshot:
        with self._authorizedTransaction(identity) as (connection, _):
            row = connection.fetchOne(
                self._sql(
                    "SELECT v.snapshot_payload,v.snapshot_sha256,v.parent_version_id,"
                    "d.current_version_id,d.document_json FROM "
                    "cloud_documents d "
                    "JOIN cloud_versions v ON v.account_id=d.account_id AND "
                    "v.document_id=d.document_id "
                    "AND v.version_id=d.current_version_id WHERE d.account_id=? AND "
                    "d.document_id=? AND d.deleted_at_utc IS NULL"
                ),
                (identity.accountId, _documentKey(documentId)),
            )
            if row is None:
                raise CloudNotAccessible()
            snapshot = self._snapshot(
                row, documentId, _binary(row["current_version_id"]).decode("utf-8")
            )
            expectedDocument = json.dumps(
                snapshot.toJson()["document"],
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            ).encode("utf-8")
            if _binary(row["document_json"]) != expectedDocument:
                raise StorageUnavailableError("cloud_storage_inconsistent")
            return snapshot
