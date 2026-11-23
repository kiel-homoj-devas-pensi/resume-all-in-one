from __future__ import annotations

import math
import re
from collections.abc import Callable, Iterator, Mapping
from contextlib import AbstractContextManager, contextmanager
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from queue import Empty, SimpleQueue
from threading import BoundedSemaphore, Lock
from typing import Protocol, cast
from urllib.parse import unquote, urlsplit

import pymysql

from .account_storage import (
    AccountAlreadyExistsError,
    AccountSqlConnection,
    RelationalAccountStore,
    StorageUnavailableError,
    UnknownStorageCommitError,
)
from .database import UnsupportedDatabaseSchemaError


@dataclass(frozen=True, repr=False)
class MySqlConfig:
    host: str
    port: int
    database: str
    user: str = field(repr=False)
    password: str = field(repr=False)
    caFile: Path
    expiresAtUtc: datetime | None = None
    poolSize: int = 4
    poolWaitSeconds: float = 5.0
    ioTimeoutSeconds: int = 5

    def __repr__(self) -> str:
        return "MySqlConfig(<redacted>)"

    def __post_init__(self) -> None:
        if (
            not 1 <= self.poolSize <= 4
            or not math.isfinite(self.poolWaitSeconds)
            or self.poolWaitSeconds <= 0
            or not 1 <= self.ioTimeoutSeconds <= 30
        ):
            raise ValueError("MySQL 连接池或超时配置无效")
        if not self.caFile.is_file():
            raise ValueError("MySQL TLS CA 文件不可用")
        if self.expiresAtUtc is not None and (
            self.expiresAtUtc.tzinfo is None or self.expiresAtUtc.utcoffset() != UTC.utcoffset(None)
        ):
            raise ValueError("MySQL 到期时间必须为 UTC")
        self.checkExpiry()

    def checkExpiry(self) -> None:
        if self.expiresAtUtc is not None and self.expiresAtUtc <= datetime.now(UTC):
            raise StorageUnavailableError("合成数据库已到期")

    @classmethod
    def fromDsn(cls, dsn: str, caFile: Path, expiresAtUtc: str | None = None) -> MySqlConfig:
        try:
            parsed = urlsplit(dsn)
            database = unquote(parsed.path.removeprefix("/"))
            user, password = unquote(parsed.username or ""), unquote(parsed.password or "")
            port = parsed.port or 3306
            if (
                parsed.scheme != "mysql"
                or not parsed.hostname
                or not user
                or not password
                or parsed.query
                or parsed.fragment
                or not 1 <= port <= 65535
                or re.fullmatch(r"[A-Za-z0-9_]{1,64}", database) is None
            ):
                raise ValueError
            expiry = (
                None if expiresAtUtc is None
                else datetime.fromisoformat(expiresAtUtc.replace("Z", "+00:00"))
            )
        except ValueError:
            raise ValueError("MySQL DSN 或到期配置无效") from None
        return cls(parsed.hostname, port, database, user, password, caFile, expiry)


class DriverCursor(Protocol):
    def execute(self, sql: str, parameters: tuple[object, ...]) -> int: ...
    def fetchone(self) -> Mapping[str, object] | None: ...
    def fetchmany(self, size: int) -> tuple[Mapping[str, object], ...]: ...
    def close(self) -> None: ...


class DriverConnection(Protocol):
    def cursor(self) -> DriverCursor: ...
    def begin(self) -> None: ...
    def commit(self) -> None: ...
    def rollback(self) -> None: ...
    def close(self) -> None: ...


def connectMySql(config: MySqlConfig) -> DriverConnection:
    try:
        return cast(
            DriverConnection,
            pymysql.connect(
                host=config.host,
                port=config.port,
                user=config.user,
                password=config.password,
                database=config.database,
                charset="utf8mb4",
                cursorclass=pymysql.cursors.DictCursor,
                autocommit=False,
                connect_timeout=config.ioTimeoutSeconds,
                read_timeout=config.ioTimeoutSeconds,
                write_timeout=config.ioTimeoutSeconds,
                ssl_ca=str(config.caFile),
                ssl_verify_cert=True,
                ssl_verify_identity=True,
                local_infile=False,
                init_command="SET SESSION sql_mode = 'STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION'",
            ),
        )
    except Exception:
        raise StorageUnavailableError("MySQL 连接不可用") from None


class _MySqlConnection:
    def __init__(self, connection: DriverConnection) -> None:
        self._connection = connection

    def execute(self, sql: str, parameters: tuple[object, ...] = ()) -> int:
        cursor = self._connection.cursor()
        try:
            return cursor.execute(sql, parameters)
        except pymysql.IntegrityError as error:
            if error.args and error.args[0] == 1062:
                raise AccountAlreadyExistsError("账户唯一键冲突") from None
            raise StorageUnavailableError("MySQL 约束失败") from None
        except pymysql.MySQLError:
            raise StorageUnavailableError("MySQL 写入不可用") from None
        finally:
            cursor.close()

    def fetchOne(
        self,
        sql: str,
        parameters: tuple[object, ...] = (),
    ) -> Mapping[str, object] | None:
        cursor = self._connection.cursor()
        try:
            cursor.execute(sql, parameters)
            return cursor.fetchone()
        except pymysql.MySQLError:
            raise StorageUnavailableError("MySQL 读取不可用") from None
        finally:
            cursor.close()

    def fetchMany(
        self, sql: str, parameters: tuple[object, ...] = (), *, maximumRows: int
    ) -> tuple[Mapping[str, object], ...]:
        if type(maximumRows) is not int or not 1 <= maximumRows <= 201:
            raise ValueError("invalid_storage_row_bound")
        cursor = self._connection.cursor()
        try:
            # 调用处固定 LIMIT；驱动不做无界 fetchall，并拒绝超过约定的结果。
            cursor.execute(sql, parameters)
            rows = cursor.fetchmany(maximumRows + 1)
            if len(rows) > maximumRows:
                raise StorageUnavailableError("storage_row_bound_exceeded")
            return tuple(rows)
        except pymysql.MySQLError:
            raise StorageUnavailableError("storage_read_unavailable") from None
        finally:
            cursor.close()


def _closeQuietly(connection: DriverConnection) -> None:
    try:
        connection.close()
    except Exception:
        # 清理失败不能覆盖已知业务失败或未知提交，也不输出驱动原始异常。
        return


class MySqlAccountDatabase:
    """有界租借，每次失败丢弃连接；不重放事务，不携带备用 SQLite。"""

    def __init__(
        self,
        config: MySqlConfig,
        connect: Callable[[MySqlConfig], DriverConnection] = connectMySql,
    ) -> None:
        self._config = config
        self._connect = connect
        self._slots = BoundedSemaphore(config.poolSize)
        self._idle: SimpleQueue[DriverConnection] = SimpleQueue()
        self._stateLock = Lock()
        self._closed = False

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return ("mysql", self._config.host.lower(), str(self._config.port), self._config.database)

    @contextmanager
    def transaction(self) -> Iterator[AccountSqlConnection]:
        self._config.checkExpiry()
        if not self._slots.acquire(timeout=self._config.poolWaitSeconds):
            raise StorageUnavailableError("MySQL 连接池等待超时")
        connection: DriverConnection | None = None
        reusable = False
        try:
            with self._stateLock:
                if self._closed:
                    raise StorageUnavailableError("MySQL 连接池已关闭")
                try:
                    connection = self._idle.get_nowait()
                except Empty:
                    pass
            if connection is None:
                connection = self._connect(self._config)
            connection.begin()
            yield _MySqlConnection(connection)
            try:
                connection.commit()
            except Exception:
                raise UnknownStorageCommitError("MySQL 提交结果未知，禁止自动重试") from None
            reusable = True
        except pymysql.MySQLError:
            raise StorageUnavailableError("MySQL 事务不可用") from None
        finally:
            if connection is not None:
                if not reusable:
                    try:
                        connection.rollback()
                    except Exception:
                        reusable = False
                with self._stateLock:
                    if reusable and not self._closed:
                        self._idle.put(connection)
                    else:
                        _closeQuietly(connection)
            self._slots.release()

    def readConnection(self) -> AbstractContextManager[AccountSqlConnection]:
        return self.transaction()

    def close(self) -> None:
        with self._stateLock:
            self._closed = True
            while True:
                try:
                    _closeQuietly(self._idle.get_nowait())
                except Empty:
                    return

    def checkSchema(self, *, withCloud: bool = False) -> None:
        with self.transaction() as connection:
            if withCloud:
                from .mysql_cloud_schema import validateCloudSchema

                validateCloudSchema(connection)
                return
            row = connection.fetchOne(
                "SELECT MAX(version) AS version FROM gateway_schema_migrations"
            )
            if row is None or row["version"] not in {1, 2, 3, 4}:
                raise UnsupportedDatabaseSchemaError("不支持 MySQL 账户 schema；请使用独立迁移入口")
            from .mysql_schema import validateAccountSchema

            if row["version"] == 1:
                validateAccountSchema(connection)
            elif row["version"] == 2:
                from .mysql_usage_schema import validateUsageSchema

                validateUsageSchema(connection)
            elif row["version"] == 3:
                from .mysql_lifecycle_schema import validateLifecycleSchema

                validateLifecycleSchema(connection)
            else:
                from .mysql_sms_schema import validateSmsSchema

                validateSmsSchema(connection)


class MySqlAccountStore(RelationalAccountStore):
    def __init__(self, database: MySqlAccountDatabase) -> None:
        super().__init__(database, parameter="%s", accountLock=" FOR UPDATE")
