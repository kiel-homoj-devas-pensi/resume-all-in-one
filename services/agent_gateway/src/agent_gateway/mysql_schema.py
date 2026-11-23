from __future__ import annotations

import hashlib
import re

from .account_storage import AccountSqlConnection, storedText
from .database import UnsupportedDatabaseSchemaError
from .mysql_storage import MySqlAccountDatabase

SCHEMA_VERSION = 1
SCHEMA_STATEMENTS = (
    """CREATE TABLE IF NOT EXISTS gateway_schema_migrations (
        version INT NOT NULL PRIMARY KEY,
        definition_sha256 CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS accounts (
        account_id VARBINARY(64) NOT NULL PRIMARY KEY,
        phone_e164 VARBINARY(96) NOT NULL UNIQUE,
        password_hash VARCHAR(255) NOT NULL,
        phone_verified_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        is_active TINYINT NOT NULL CHECK (is_active IN (0, 1)),
        created_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS account_sessions (
        session_id VARBINARY(64) NOT NULL PRIMARY KEY,
        account_id VARBINARY(64) NOT NULL,
        token_hash VARBINARY(64) NOT NULL UNIQUE,
        expires_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        revoked_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NULL,
        created_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        INDEX account_sessions_account_id (account_id),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
)
SCHEMA_DIGEST = hashlib.sha256("\n".join(SCHEMA_STATEMENTS).encode()).hexdigest()

# 类型、字符排序、空值、键与外键均需吻合；不能对同名旧表补一个版本号冒充迁移。
COLUMNS = {
    "gateway_schema_migrations": (
        ("version", "int", None, "NO"),
        ("definition_sha256", "char(64)", "ascii_bin", "NO"),
    ),
    "accounts": (
        ("account_id", "varbinary(64)", None, "NO"),
        ("phone_e164", "varbinary(96)", None, "NO"),
        ("password_hash", "varchar(255)", "utf8mb4_bin", "NO"),
        ("phone_verified_at_utc", "char(27)", "ascii_bin", "NO"),
        ("is_active", "tinyint", None, "NO"),
        ("created_at_utc", "char(27)", "ascii_bin", "NO"),
    ),
    "account_sessions": (
        ("session_id", "varbinary(64)", None, "NO"),
        ("account_id", "varbinary(64)", None, "NO"),
        ("token_hash", "varbinary(64)", None, "NO"),
        ("expires_at_utc", "char(27)", "ascii_bin", "NO"),
        ("revoked_at_utc", "char(27)", "ascii_bin", "YES"),
        ("created_at_utc", "char(27)", "ascii_bin", "NO"),
    ),
}


def _require(condition: bool) -> None:
    if not condition:
        raise UnsupportedDatabaseSchemaError("MySQL 合成库结构不符，禁止标记迁移成功")


def _validateStructure(connection: AccountSqlConnection, *, tableCount: int = 3) -> None:
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema = DATABASE()"
    )
    _require(row is not None and row["count"] == tableCount)
    for table, columns in COLUMNS.items():
        row = connection.fetchOne(
            "SELECT engine AS storage_engine, table_collation AS storage_collation "
            "FROM information_schema.tables "
            "WHERE table_schema = DATABASE() AND table_name = %s",
            (table,),
        )
        _require(
            row is not None
            and row["storage_engine"] == "InnoDB"
            and row["storage_collation"] == "utf8mb4_bin"
        )
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.columns "
            "WHERE table_schema = DATABASE() AND table_name = %s",
            (table,),
        )
        _require(row is not None and row["count"] == len(columns))
        for name, columnType, collation, nullable in columns:
            row = connection.fetchOne(
                "SELECT column_type AS storage_type, collation_name AS storage_collation, "
                "is_nullable AS storage_nullable FROM information_schema.columns "
                "WHERE table_schema = DATABASE() AND table_name = %s AND column_name = %s",
                (table, name),
            )
            # MySQL 5/8 对整数显示宽度不同，宽度不是取值范围；其余类型严格匹配。
            actualType = storedText(row["storage_type"]) if row else ""
            if columnType in {"int", "tinyint"}:
                actualType = re.sub(r"\([0-9]+\)", "", actualType)
            _require(
                row is not None
                and actualType == columnType
                and row["storage_collation"] == collation
                and row["storage_nullable"] == nullable
            )
    for table, column in (
        ("gateway_schema_migrations", "version"),
        ("accounts", "account_id"),
        ("accounts", "phone_e164"),
        ("account_sessions", "session_id"),
        ("account_sessions", "token_hash"),
    ):
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM (SELECT index_name FROM information_schema.statistics "
            "WHERE table_schema = DATABASE() AND table_name = %s AND non_unique = 0 "
            "GROUP BY index_name HAVING COUNT(*) = 1 AND MAX(column_name) = %s "
            "AND MAX(sub_part) IS NULL) AS required_unique_key",
            (table, column),
        )
        _require(row is not None and row["count"] == 1)
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.referential_constraints "
        "WHERE constraint_schema = DATABASE() AND table_name = 'account_sessions' "
        "AND referenced_table_name = 'accounts' AND delete_rule = 'CASCADE'"
    )
    _require(row is not None and row["count"] == 1)
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.key_column_usage "
        "WHERE constraint_schema = DATABASE() AND table_name = 'account_sessions' "
        "AND column_name = 'account_id' AND referenced_table_name = 'accounts' "
        "AND referenced_column_name = 'account_id'"
    )
    _require(row is not None and row["count"] == 1)
    row = connection.fetchOne(
        "SELECT COUNT(*) AS count FROM information_schema.table_constraints "
        "WHERE constraint_schema = DATABASE() AND table_name = 'accounts' "
        "AND constraint_type = 'CHECK'"
    )
    _require(row is not None and row["count"] == 1)
    row = connection.fetchOne(
        "SELECT c.check_clause AS clause, t.enforced AS enforced "
        "FROM information_schema.check_constraints c "
        "JOIN information_schema.table_constraints t "
        "ON t.constraint_schema = c.constraint_schema AND t.constraint_name = c.constraint_name "
        "WHERE t.constraint_schema = DATABASE() AND t.table_name = 'accounts' "
        "AND t.constraint_type = 'CHECK'"
    )
    clause = re.sub(r"[\s`()]+", "", storedText(row["clause"]).lower()) if row else ""
    _require(row is not None and row["enforced"] == "YES" and clause == "is_activein0,1")


def migrateSyntheticSchema(database: MySqlAccountDatabase) -> None:
    with database.transaction() as connection:
        # MySQL DDL 隐式提交。先拒绝无关表，失败只留下可检查的空表，版本最后落库。
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables "
            "WHERE table_schema = DATABASE() "
            "AND table_name NOT IN ('gateway_schema_migrations', 'accounts', 'account_sessions')"
        )
        _require(row is not None and row["count"] == 0)
        connection.execute(SCHEMA_STATEMENTS[0])
        row = connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
        _require(row is not None and row["version"] in {None, SCHEMA_VERSION})
        version = row["version"] if row else None
        if version is None:
            for statement in SCHEMA_STATEMENTS[1:]:
                connection.execute(statement)
            _validateStructure(connection)
            for query in (
                "SELECT COUNT(*) AS count FROM accounts",
                "SELECT COUNT(*) AS count FROM account_sessions",
            ):
                # 表名只来自固定白名单，无配置或用户输入。
                row = connection.fetchOne(query)
                _require(row is not None and row["count"] == 0)
            connection.execute(
                "INSERT INTO gateway_schema_migrations(version, definition_sha256) VALUES (%s, %s)",
                (SCHEMA_VERSION, SCHEMA_DIGEST),
            )
        else:
            validateAccountSchema(connection)


def validateAccountSchema(connection: AccountSqlConnection) -> None:
    row = connection.fetchOne("SELECT COUNT(*) AS count FROM gateway_schema_migrations")
    _require(row is not None and row["count"] == 1)
    row = connection.fetchOne(
        "SELECT definition_sha256 FROM gateway_schema_migrations WHERE version = %s",
        (SCHEMA_VERSION,),
    )
    _require(row is not None and row["definition_sha256"] == SCHEMA_DIGEST)
    _validateStructure(connection)
