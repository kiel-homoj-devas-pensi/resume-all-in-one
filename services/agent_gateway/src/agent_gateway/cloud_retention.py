from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from .account_storage import AccountSqlDatabase, StorageUnavailableError, storedText
from .cloud_storage import _binary, _cloudSql
from .identity import requireUtc, toUtcText


@dataclass(frozen=True, slots=True, repr=False)
class CloudPurgePosition:
    # 只用于管理员清理循环，不是客户端可传入的公开游标。
    authorityKey: tuple[str, ...]
    deletedAtUtc: str
    accountId: str
    documentId: bytes


@dataclass(frozen=True, slots=True)
class CloudPurgeBatch:
    scannedDocuments: int
    deletedVersions: int
    clearedDocuments: int
    unfinishedDueDocuments: int
    nextPosition: CloudPurgePosition | None


class CloudRetentionWorker:
    """管理员使用独立最小权限连接；不进入用户接口或生产默认启动。"""

    def __init__(
        self,
        database: AccountSqlDatabase,
        *,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        if database.authorityKey[0] not in {"sqlite", "mysql"}:
            raise ValueError("invalid_cloud_storage")
        self._database = database
        self._mysql = database.authorityKey[0] == "mysql"
        self._clock = clock

    def runBatch(
        self,
        *,
        maximumDocuments: int = 20,
        maximumVersionsPerDocument: int = 200,
        position: CloudPurgePosition | None = None,
    ) -> CloudPurgeBatch:
        if type(maximumDocuments) is not int or not 1 <= maximumDocuments <= 20:
            raise ValueError("invalid_cloud_purge_bound")
        if (
            type(maximumVersionsPerDocument) is not int
            or not 1 <= maximumVersionsPerDocument <= 200
        ):
            raise ValueError("invalid_cloud_purge_bound")
        if position is not None and position.authorityKey != self._database.authorityKey:
            raise ValueError("invalid_cloud_purge_position")
        scanNow = toUtcText(requireUtc(self._clock()))
        after = (
            ("", "", b"")
            if position is None
            else (position.deletedAtUtc, position.accountId, position.documentId)
        )
        with self._database.readConnection() as connection:
            rows = connection.fetchMany(
                _cloudSql(
                    "SELECT account_id,document_id,deleted_at_utc FROM cloud_documents "
                    "WHERE deleted_at_utc IS NOT NULL AND deleted_at_utc<=? AND document_json<>? "
                    "AND (deleted_at_utc>? OR (deleted_at_utc=? AND account_id>?) OR "
                    "(deleted_at_utc=? AND account_id=? AND document_id>?)) "
                    "ORDER BY deleted_at_utc,account_id,document_id LIMIT ?",
                    mysql=self._mysql,
                ),
                (
                    scanNow,
                    b"{}",
                    after[0],
                    after[0],
                    after[1],
                    after[0],
                    after[1],
                    after[2],
                    maximumDocuments + 1,
                ),
                maximumRows=maximumDocuments + 1,
            )
        deleted = cleared = unfinished = 0
        for row in rows[:maximumDocuments]:
            accountId = storedText(row["account_id"])
            key = _binary(row["document_id"])
            with self._database.transaction() as connection:
                # 先账户再文档；共享账户锁阻止业务排他锁，但不给清理者修改身份的权限。
                # MySQL 8.0.22+ FOR SHARE 只需 SELECT；生产兼容库须实测，不能降为普通读。
                accountQuery = "SELECT account_id FROM accounts WHERE account_id=?"
                if self._mysql:
                    accountQuery += " FOR SHARE"
                account = connection.fetchOne(
                    _cloudSql(
                        accountQuery,
                        mysql=self._mysql,
                    ),
                    (accountId,),
                )
                document = connection.fetchOne(
                    _cloudSql(
                        "SELECT deleted_at_utc,content_retention_days,"
                        "(document_json=?) AS content_cleared "
                        "FROM cloud_documents "
                        "WHERE account_id=? AND document_id=?",
                        mysql=self._mysql,
                        lock=True,
                    ),
                    (b"{}", accountId, key),
                )
                if account is None:
                    raise StorageUnavailableError("cloud_storage_inconsistent")
                if (
                    document is None
                    or document["deleted_at_utc"] is None
                    or document["content_cleared"] == 1
                ):
                    continue
                now = requireUtc(self._clock())
                try:
                    deletion = datetime.fromisoformat(storedText(document["deleted_at_utc"]))
                    days = document["content_retention_days"]
                    if type(days) is not int or not 0 <= days <= 3650:
                        raise ValueError("invalid_retention")
                    deadline = requireUtc(deletion) + timedelta(days=days)
                except ValueError, OverflowError:
                    raise StorageUnavailableError("cloud_storage_inconsistent") from None
                if deadline > now:
                    continue
                versions = connection.fetchMany(
                    _cloudSql(
                        "SELECT version_id FROM cloud_versions WHERE account_id=? "
                        "AND document_id=? "
                        "ORDER BY commit_sequence DESC LIMIT ?",
                        mysql=self._mysql,
                    ),
                    (accountId, key, maximumVersionsPerDocument + 1),
                    maximumRows=maximumVersionsPerDocument + 1,
                )
                for version in versions[:maximumVersionsPerDocument]:
                    # 从新到旧删除，使自引用的父版本外键始终成立。
                    changed = connection.execute(
                        _cloudSql(
                            "DELETE FROM cloud_versions WHERE account_id=? "
                            "AND document_id=? AND version_id=?",
                            mysql=self._mysql,
                        ),
                        (accountId, key, _binary(version["version_id"])),
                    )
                    if changed != 1:
                        raise StorageUnavailableError("cloud_storage_inconsistent")
                deleted += min(len(versions), maximumVersionsPerDocument)
                if len(versions) > maximumVersionsPerDocument:
                    unfinished += 1
                else:
                    # 最后一个版本删除后才清正文；保留身份、删除时间、序号及幂等结果。
                    connection.execute(
                        _cloudSql(
                            "UPDATE cloud_documents SET document_json=? "
                            "WHERE account_id=? AND document_id=?",
                            mysql=self._mysql,
                        ),
                        (b"{}", accountId, key),
                    )
                    cleared += 1
        nextPosition = None
        consumed = rows[:maximumDocuments]
        if consumed and len(rows) > len(consumed):
            tail = consumed[-1]
            nextPosition = CloudPurgePosition(
                self._database.authorityKey,
                storedText(tail["deleted_at_utc"]),
                storedText(tail["account_id"]),
                _binary(tail["document_id"]),
            )
        # nextPosition=None 只代表扫描结束；分批未清完的文档在下一轮从头扫描。
        return CloudPurgeBatch(len(consumed), deleted, cleared, unfinished, nextPosition)
