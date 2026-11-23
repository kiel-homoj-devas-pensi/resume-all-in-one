"""SQLite v4/v5 到对应 MySQL v3/v4 的合成导入，包含既有短信预算；不发现私人数据库。"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal, cast

from .account_storage import AccountSqlConnection, AccountSqlDatabase
from .mysql_sms_schema import SMS_COLUMNS


@dataclass(frozen=True)
class ImportTable:
    name: str
    columns: tuple[str, ...]

    @property
    def primaryKey(self) -> str:
        return self.columns[0]

    def selectSql(self, *, ownedRow: bool = False) -> str:
        # 表和列仅来自下面的版本化常量；任何用户值都另行绑定。
        statement = f"SELECT {', '.join(self.columns)} FROM {self.name}"  # noqa: S608
        return statement + (f" WHERE {self.primaryKey} = %s" if ownedRow else "")

    def insertSql(self) -> str:
        placeholders = ", ".join("%s" for _ in self.columns)
        return f"INSERT INTO {self.name} ({', '.join(self.columns)}) VALUES ({placeholders})"  # noqa: S608


IMPORT_TABLES = (
    ImportTable(
        "accounts",
        (
            "account_id",
            "phone_e164",
            "password_hash",
            "phone_verified_at_utc",
            "is_active",
            "created_at_utc",
        ),
    ),
    ImportTable(
        "account_sessions",
        (
            "session_id",
            "account_id",
            "token_hash",
            "expires_at_utc",
            "revoked_at_utc",
            "created_at_utc",
        ),
    ),
    ImportTable(
        "subscription_snapshots",
        (
            "account_id",
            "plan",
            "starts_at_utc",
            "ends_at_utc",
            "source",
            "updated_at_utc",
        ),
    ),
    ImportTable(
        "usage_operations",
        (
            "operation_id",
            "account_id",
            "capability",
            "idempotency_key_hash",
            "request_fingerprint_hash",
            "status",
            "quota_window_start_utc",
            "quota_window_end_utc",
            "plan_at_reservation",
            "created_at_utc",
            "updated_at_utc",
            "failure_code",
            "prompt_version",
            "input_tokens",
            "output_tokens",
        ),
    ),
    ImportTable(
        "usage_reconciliations",
        (
            "operation_id",
            "operator_id",
            "evidence_sha256",
            "evidence_kind",
            "finalized_at_utc",
        ),
    ),
    ImportTable(
        "phone_challenges",
        (
            "challenge_id",
            "phone_hash",
            "purpose",
            "code_hash",
            "expires_at_utc",
            "attempts",
            "consumed_at_utc",
        ),
    ),
    ImportTable("identity_rate_limits", ("bucket_hash", "window_start_utc", "attempts")),
)
MAXIMUM_IMPORT_ROWS = 10_000
SMS_IMPORT_TABLES = tuple(
    ImportTable(name, tuple(column[0] for column in columns))
    for name, columns in SMS_COLUMNS.items()
)


@dataclass(frozen=True, repr=False)
class SyntheticSnapshot:
    rows: dict[str, tuple[tuple[object, ...], ...]] = field(repr=False)
    sourceVersion: Literal[4, 5] = 4

    @property
    def tables(self) -> tuple[ImportTable, ...]:
        return IMPORT_TABLES + (SMS_IMPORT_TABLES if self.sourceVersion == 5 else ())

    def summary(self) -> dict[str, dict[str, int | str]]:
        result: dict[str, dict[str, int | str]] = {}
        for table in self.tables:
            rows = sorted(self.rows[table.name], key=lambda row: str(row[0]))
            canonical = json.dumps(
                [table.columns, rows], ensure_ascii=False, separators=(",", ":"), allow_nan=False
            ).encode("utf-8")
            result[table.name] = {
                "count": len(rows),
                "sha256": hashlib.sha256(canonical).hexdigest(),
            }
        return result


def loadSyntheticSnapshot(source: Path) -> SyntheticSnapshot:
    if not source.is_file() or source.is_symlink():
        raise ValueError("合成源必须为显式指定的现有普通 SQLite 文件")
    try:
        # mode=ro 不初始化旧文件，BEGIN 保持业务表与预算来自同一读取快照。
        connection = sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)
        try:
            connection.execute("PRAGMA query_only = ON")
            connection.execute("BEGIN")
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            if version not in {4, 5}:
                raise ValueError("合成源必须为 Gateway SQLite v4/v5")
            if (
                version == 4
                and connection.execute(
                    "SELECT COUNT(*) FROM sqlite_schema WHERE name IN ('sms_send_budget', "
                    "'sms_send_attempts')"
                ).fetchone()[0]
            ):
                raise ValueError("SQLite v4 源存在后续短信账表，禁止忽略预算导入")
            if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise ValueError("合成源完整性检查失败")
            if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise ValueError("合成源存在孤立记录")
            rows: dict[str, tuple[tuple[object, ...], ...]] = {}
            remaining = MAXIMUM_IMPORT_ROWS
            for table in IMPORT_TABLES + (SMS_IMPORT_TABLES if version == 5 else ()):
                kind = connection.execute(
                    "SELECT type FROM sqlite_schema WHERE name = ?", (table.name,)
                ).fetchone()
                if kind is None or kind[0] != "table":
                    raise ValueError("合成源业务表不完整")
                columns = connection.execute(f"PRAGMA table_info({table.name})").fetchall()
                if {row[1] for row in columns} != set(table.columns):
                    raise ValueError("合成源列与对应版本契约不符")
                selected = connection.execute(table.selectSql()).fetchmany(remaining + 1)
                if len(selected) > remaining:
                    raise ValueError("合成导入超过一万行演练上限")
                remaining -= len(selected)
                for row in selected:
                    if any(
                        value is not None and not isinstance(value, (str, int)) for value in row
                    ):
                        raise ValueError("合成源包含不支持的值类型")
                    if not isinstance(row[0], str) or not row[0].isascii():
                        raise ValueError("合成源身份字段必须为 ASCII")
                rows[table.name] = tuple(selected)
            for account in rows["accounts"]:
                phone, active = str(account[1]), account[4]
                if active == 1 and not phone.startswith("+1555000"):
                    raise ValueError("合成导入拒绝真实号码")
                if active == 0 and phone != "disabled:" + str(account[0]):
                    raise ValueError("停用账户必须保留对应去标识占位")
            return SyntheticSnapshot(rows, cast(Literal[4, 5], version))
        finally:
            connection.close()
    except sqlite3.Error, OSError:
        raise ValueError("合成源无法只读校验；未修改源文件") from None


def _count(connection: AccountSqlConnection, table: ImportTable) -> int:
    row = connection.fetchOne(f"SELECT COUNT(*) AS total FROM {table.name}")  # noqa: S608
    if row is None:
        raise ValueError("目标计数缺失")
    return int(str(row["total"]))


def _normalized(value: object) -> object:
    if isinstance(value, bytes):
        return value.decode("ascii")
    return value


def _targetState(
    connection: AccountSqlConnection, snapshot: SyntheticSnapshot
) -> Literal["empty", "matching"]:
    counts = {table.name: _count(connection, table) for table in snapshot.tables}
    if not any(counts.values()):
        guardCount = connection.fetchOne("SELECT COUNT(*) AS total FROM phone_verification_guards")
        if guardCount is None or int(str(guardCount["total"])) != 0:
            raise ValueError("目标含既有验证码保护记录，不是空演练库")
        return "empty"
    if any(counts[table.name] != len(snapshot.rows[table.name]) for table in snapshot.tables):
        raise ValueError("非空目标与源计数不一致，禁止覆盖或混合导入")
    for table in snapshot.tables:
        for expected in snapshot.rows[table.name]:
            actual = connection.fetchOne(table.selectSql(ownedRow=True), (expected[0],))
            if (
                actual is None
                or tuple(_normalized(actual[column]) for column in table.columns) != expected
            ):
                raise ValueError("非空目标与源内容不一致，禁止覆盖或混合导入")
    return "matching"


def importSyntheticSnapshot(
    database: AccountSqlDatabase,
    snapshot: SyntheticSnapshot,
    *,
    apply: bool = False,
    confirmedQuiescent: bool = False,
    confirmedOtpSecretPreserved: bool = False,
) -> dict[str, object]:
    if database.authorityKey[0] != "mysql":
        raise ValueError("导入目标只能是已验证的 MySQL 专用合成库")
    if apply and not (confirmedQuiescent and confirmedOtpSecretPreserved):
        raise ValueError("应用前必须确认两端停写并保留验证码摘要密钥")
    summary = snapshot.summary()
    if not apply:
        with database.readConnection() as connection:
            state = _targetState(connection, snapshot)
        return {"status": "dryRun", "target": state, "tables": summary, "writes": False}
    # DDL 由独立入口/身份事先完成；旧 v4 写七表，新 v5 还保留短信预算/尝试。
    with database.transaction() as connection:
        state = _targetState(connection, snapshot)
        if state == "matching":
            return {"status": "alreadyImported", "tables": summary, "writes": False}
        for table in snapshot.tables:
            for row in snapshot.rows[table.name]:
                if connection.execute(table.insertSql(), row) != 1:
                    raise ValueError("合成导入受影响行数不符")
        if any(snapshot.rows.values()) and _targetState(connection, snapshot) != "matching":
            raise ValueError("合成导入校验不一致")
    # 必须等到提交确认后返回成功；提交未知由底层原样传递，绝不自动重放。
    return {"status": "imported", "tables": summary, "writes": bool(any(snapshot.rows.values()))}
