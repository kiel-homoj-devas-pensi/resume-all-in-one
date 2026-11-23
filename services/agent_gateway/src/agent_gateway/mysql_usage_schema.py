from __future__ import annotations

import hashlib
import re
from collections.abc import Mapping

from .account_storage import AccountSqlConnection, storedText
from .database import UnsupportedDatabaseSchemaError
from .mysql_schema import (
    SCHEMA_DIGEST as ACCOUNT_SCHEMA_DIGEST,
)
from .mysql_schema import (
    _require,
    _validateStructure,
    migrateSyntheticSchema,
)
from .mysql_storage import MySqlAccountDatabase

USAGE_SCHEMA_VERSION = 2
USAGE_SCHEMA_STATEMENTS = (
    """CREATE TABLE IF NOT EXISTS subscription_snapshots (
        account_id VARBINARY(64) NOT NULL PRIMARY KEY,
        plan VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        starts_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        ends_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        source VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        updated_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        CONSTRAINT sub_plan CHECK (plan IN ('free', 'pro')),
        CONSTRAINT sub_source CHECK (source = 'fake'),
        CONSTRAINT sub_window CHECK (starts_at_utc < ends_at_utc),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS usage_operations (
        operation_id VARBINARY(64) NOT NULL PRIMARY KEY,
        account_id VARBINARY(64) NOT NULL,
        capability VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        idempotency_key_hash VARBINARY(64) NOT NULL,
        request_fingerprint_hash VARBINARY(64) NOT NULL,
        status VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        quota_window_start_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        quota_window_end_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        plan_at_reservation VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        created_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        updated_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        failure_code TEXT NULL,
        prompt_version TEXT NULL,
        input_tokens BIGINT NULL,
        output_tokens BIGINT NULL,
        UNIQUE KEY usage_idempotency (account_id, capability, idempotency_key_hash),
        INDEX usage_monthly_quota (account_id, capability, quota_window_start_utc,
            quota_window_end_utc, status),
        CONSTRAINT usage_capability CHECK (capability IN ('basicResumeCompose',
            'targetedResumeOptimization', 'resumeOptimizationConversation')),
        CONSTRAINT usage_status CHECK (status IN ('reserved', 'committed',
            'released', 'pendingReconciliation')),
        CONSTRAINT usage_plan CHECK (plan_at_reservation IN ('free', 'pro')),
        CONSTRAINT usage_input CHECK (input_tokens IS NULL OR input_tokens >= 0),
        CONSTRAINT usage_output CHECK (output_tokens IS NULL OR output_tokens >= 0),
        FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
    """CREATE TABLE IF NOT EXISTS usage_reconciliations (
        operation_id VARBINARY(64) NOT NULL PRIMARY KEY,
        operator_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        evidence_sha256 VARBINARY(64) NOT NULL,
        evidence_kind VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        finalized_at_utc CHAR(27) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        CONSTRAINT reconciliation_kind CHECK (evidence_kind IN ('executed', 'notExecuted')),
        FOREIGN KEY (operation_id) REFERENCES usage_operations(operation_id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin""",
)
USAGE_SCHEMA_DIGEST = hashlib.sha256("\n".join(USAGE_SCHEMA_STATEMENTS).encode()).hexdigest()
USAGE_COLUMNS = {
    "subscription_snapshots": (
        ("account_id", "varbinary(64)", None, "NO"),
        ("plan", "varchar(16)", "ascii_bin", "NO"),
        ("starts_at_utc", "char(27)", "ascii_bin", "NO"),
        ("ends_at_utc", "char(27)", "ascii_bin", "NO"),
        ("source", "varchar(16)", "ascii_bin", "NO"),
        ("updated_at_utc", "char(27)", "ascii_bin", "NO"),
    ),
    "usage_operations": (
        ("operation_id", "varbinary(64)", None, "NO"),
        ("account_id", "varbinary(64)", None, "NO"),
        ("capability", "varchar(64)", "ascii_bin", "NO"),
        ("idempotency_key_hash", "varbinary(64)", None, "NO"),
        ("request_fingerprint_hash", "varbinary(64)", None, "NO"),
        ("status", "varchar(32)", "ascii_bin", "NO"),
        ("quota_window_start_utc", "char(27)", "ascii_bin", "NO"),
        ("quota_window_end_utc", "char(27)", "ascii_bin", "NO"),
        ("plan_at_reservation", "varchar(16)", "ascii_bin", "NO"),
        ("created_at_utc", "char(27)", "ascii_bin", "NO"),
        ("updated_at_utc", "char(27)", "ascii_bin", "NO"),
        ("failure_code", "text", "utf8mb4_bin", "YES"),
        ("prompt_version", "text", "utf8mb4_bin", "YES"),
        ("input_tokens", "bigint", None, "YES"),
        ("output_tokens", "bigint", None, "YES"),
    ),
    "usage_reconciliations": (
        ("operation_id", "varbinary(64)", None, "NO"),
        ("operator_id", "varchar(64)", "ascii_bin", "NO"),
        ("evidence_sha256", "varbinary(64)", None, "NO"),
        ("evidence_kind", "varchar(16)", "ascii_bin", "NO"),
        ("finalized_at_utc", "char(27)", "ascii_bin", "NO"),
    ),
}
CHECKS = {
    "subscription_snapshots": {
        "sub_plan": "plan IN ('free', 'pro')",
        "sub_source": "source = 'fake'",
        "sub_window": "starts_at_utc < ends_at_utc",
    },
    "usage_operations": {
        "usage_capability": (
            "capability IN ('basicResumeCompose', "
            "'targetedResumeOptimization', 'resumeOptimizationConversation')"
        ),
        "usage_status": "status IN ('reserved', 'committed', 'released', 'pendingReconciliation')",
        "usage_plan": "plan_at_reservation IN ('free', 'pro')",
        "usage_input": "input_tokens IS NULL OR input_tokens >= 0",
        "usage_output": "output_tokens IS NULL OR output_tokens >= 0",
    },
    "usage_reconciliations": {
        "reconciliation_kind": "evidence_kind IN ('executed', 'notExecuted')",
    },
}


_CHECK_TOKEN = re.compile(
    r"(?P<escaped>(?:_(?:ascii|utf8mb4|utf8mb3))?\\'(?:\\\\|\\[^']|[^'\\])*\\')"
    r"|(?P<string>(?:_(?:ascii|utf8mb4|utf8mb3))?'(?:''|\\.|[^'\\])*')"
    r"|(?P<quoted>`[A-Za-z_][A-Za-z0-9_]*`)"
    r"|(?P<word>[A-Za-z_][A-Za-z0-9_]*)|(?P<number>[0-9]+)"
    r"|(?P<operator><>|!=|<=|>=|[=<>(),])|(?P<space>\s+)"
)


class _CheckExpression:
    # 仅解析本项目 CHECK 使用的 SQL 子集；保留 AND/OR 分组，绝不执行表达式。
    def __init__(self, clause: str) -> None:
        self.tokens: list[tuple[str, str]] = []
        self.position = 0
        offset = 0
        if len(clause) > 8192:
            raise ValueError
        while offset < len(clause):
            match = _CHECK_TOKEN.match(clause, offset)
            if match is None:
                raise ValueError
            kind = match.lastgroup
            text = match[0]
            offset = match.end()
            if kind == "space":
                continue
            if kind == "escaped":
                kind, text = "string", text[text.index("\\'") + 2 : -2]
            elif kind == "string":
                text = text[text.index("'") + 1 : -1].replace("''", "'")
                text = re.sub(r"\\(['\\])", lambda found: found[1], text)
            elif kind == "quoted":
                kind, text = "word", text[1:-1]
            elif kind == "word" and text.upper() in {"AND", "OR", "NOT", "IN", "IS", "NULL"}:
                kind, text = "keyword", text.lower()
            self.tokens.append((str(kind), text))

    def _take(self, text: str) -> bool:
        kind = "operator" if text in {"(", ")", ","} else "keyword"
        if self.position < len(self.tokens) and self.tokens[self.position] == (kind, text):
            self.position += 1
            return True
        return False

    def _expect(self, text: str) -> None:
        if not self._take(text):
            raise ValueError

    def _boolean(self, operation: str) -> tuple[object, ...]:
        parse = self._predicate if operation == "and" else lambda: self._boolean("and")
        children = [parse()]
        while self._take(operation):
            children.append(parse())
        if len(children) == 1:
            return children[0]
        flattened: list[object] = [operation]
        for child in children:
            flattened.extend(child[1:] if child[0] == operation else (child,))
        return tuple(flattened)

    def _predicate(self) -> tuple[object, ...]:
        if self._take("not"):
            return ("not", self._predicate())
        left = self._atom()
        if self._take("is"):
            negated = self._take("not")
            self._expect("null")
            return ("isNotNull" if negated else "isNull", left)
        negated = self._take("not")
        if self._take("in"):
            self._expect("(")
            values = [self._atom()]
            while self._take(","):
                values.append(self._atom())
            self._expect(")")
            return ("notIn" if negated else "in", left, tuple(values))
        if negated:
            raise ValueError
        if self.position < len(self.tokens):
            kind, operator = self.tokens[self.position]
            if kind == "operator" and operator in {"=", "!=", "<>", ">", "<", ">=", "<="}:
                self.position += 1
                return ("compare", "<>" if operator == "!=" else operator, left, self._atom())
        return left

    def _atom(self) -> tuple[object, ...]:
        if self._take("("):
            expression = self._boolean("or")
            self._expect(")")
            return expression
        if self.position >= len(self.tokens):
            raise ValueError
        kind, value = self.tokens[self.position]
        self.position += 1
        if kind == "word":
            if value.lower() == "length" and self._take("("):
                argument = self._atom()
                self._expect(")")
                return ("length", argument)
            return ("column", value)
        if kind == "number":
            return ("integer", int(value))
        if kind == "string":
            return ("literal", value)
        if kind == "keyword" and value == "null":
            return ("null",)
        raise ValueError

    def normalized(self) -> str:
        expression = self._boolean("or")
        if self.position != len(self.tokens):
            raise ValueError
        return repr(expression)


def _normalizeCheck(clause: str) -> str:
    try:
        return _CheckExpression(clause).normalized()
    except ValueError, RecursionError:
        raise UnsupportedDatabaseSchemaError("mysql_check_expression_invalid") from None


def _validateTables(
    connection: AccountSqlConnection,
    columnsByTable: Mapping[str, tuple[tuple[str, str, str | None, str], ...]],
    checksByTable: Mapping[str, Mapping[str, str]],
) -> None:
    for table, columns in columnsByTable.items():
        row = connection.fetchOne(
            "SELECT engine AS engine_name, table_collation AS collation_name "
            "FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = %s",
            (table,),
        )
        _require(
            row is not None
            and row["engine_name"] == "InnoDB"
            and row["collation_name"] == "utf8mb4_bin"
        )
        row = connection.fetchOne(
            (
                "SELECT COUNT(*) AS count FROM information_schema.columns WHERE "
                "table_schema = DATABASE() AND table_name = %s"
            ),
            (table,),
        )
        _require(row is not None and row["count"] == len(columns))
        for name, kind, collation, nullable in columns:
            row = connection.fetchOne(
                (
                    "SELECT column_type AS kind, collation_name AS collation_name, "
                    "is_nullable AS nullable FROM information_schema.columns WHERE "
                    "table_schema = DATABASE() AND table_name = %s AND column_name = "
                    "%s"
                ),
                (table, name),
            )
            actual = storedText(row["kind"]) if row else ""
            if kind in {"bigint", "int"}:
                actual = re.sub(r"\([0-9]+\)", "", actual)
            _require(
                row is not None
                and actual == kind
                and row["collation_name"] == collation
                and row["nullable"] == nullable
            )
        row = connection.fetchOne(
            (
                "SELECT COUNT(*) AS count FROM "
                "information_schema.table_constraints WHERE constraint_schema = "
                "DATABASE() AND table_name = %s AND constraint_type = 'CHECK'"
            ),
            (table,),
        )
        _require(row is not None and row["count"] == len(checksByTable[table]))
        for name, expected in checksByTable[table].items():
            row = connection.fetchOne(
                (
                    "SELECT c.check_clause AS clause, t.enforced AS enforced FROM "
                    "information_schema.check_constraints c JOIN "
                    "information_schema.table_constraints t ON t.constraint_schema = "
                    "c.constraint_schema AND t.constraint_name = c.constraint_name "
                    "WHERE t.constraint_schema = DATABASE() AND t.table_name = %s AND "
                    "t.constraint_name = %s"
                ),
                (table, name),
            )
            _require(
                row is not None
                and row["enforced"] == "YES"
                and _normalizeCheck(storedText(row["clause"])) == _normalizeCheck(expected)
            )


def _validateUsageStructure(connection: AccountSqlConnection, *, tableCount: int = 6) -> None:
    _validateStructure(connection, tableCount=tableCount)
    _validateTables(connection, USAGE_COLUMNS, CHECKS)
    for table, indexedColumns, unique in (
        ("subscription_snapshots", "account_id", 0),
        ("usage_operations", "operation_id", 0),
        ("usage_operations", "account_id,capability,idempotency_key_hash", 0),
        (
            "usage_operations",
            ("account_id,capability,quota_window_start_utc,quota_window_end_utc,status"),
            1,
        ),
        ("usage_reconciliations", "operation_id", 0),
    ):
        row = connection.fetchOne(
            (
                "SELECT COUNT(*) AS count FROM (SELECT index_name FROM "
                "information_schema.statistics WHERE table_schema = DATABASE() "
                "AND table_name = %s AND non_unique = %s GROUP BY index_name "
                "HAVING GROUP_CONCAT(column_name ORDER BY seq_in_index SEPARATOR "
                "',') = %s AND MAX(sub_part) IS NULL) AS required_index"
            ),
            (table, unique, indexedColumns),
        )
        _require(row is not None and row["count"] == 1)
    for table, column, target, targetColumn in (
        ("subscription_snapshots", "account_id", "accounts", "account_id"),
        ("usage_operations", "account_id", "accounts", "account_id"),
        ("usage_reconciliations", "operation_id", "usage_operations", "operation_id"),
    ):
        row = connection.fetchOne(
            (
                "SELECT COUNT(*) AS count FROM "
                "information_schema.key_column_usage k JOIN "
                "information_schema.referential_constraints r ON "
                "r.constraint_schema = k.constraint_schema AND r.constraint_name "
                "= k.constraint_name WHERE k.constraint_schema = DATABASE() AND "
                "k.table_name = %s AND k.column_name = %s AND "
                "k.referenced_table_name = %s AND k.referenced_column_name = %s "
                "AND r.delete_rule = 'CASCADE'"
            ),
            (table, column, target, targetColumn),
        )
        _require(row is not None and row["count"] == 1)


def validateUsageSchema(
    connection: AccountSqlConnection, *, includesLifecycle: bool = False
) -> None:
    row = connection.fetchOne("SELECT COUNT(*) AS count FROM gateway_schema_migrations")
    _require(row is not None and row["count"] == (3 if includesLifecycle else 2))
    for version, digest in ((1, ACCOUNT_SCHEMA_DIGEST), (2, USAGE_SCHEMA_DIGEST)):
        row = connection.fetchOne(
            ("SELECT definition_sha256 FROM gateway_schema_migrations WHERE version = %s"),
            (version,),
        )
        _require(row is not None and row["definition_sha256"] == digest)
    _validateUsageStructure(connection, tableCount=9 if includesLifecycle else 6)


def migrateSyntheticUsageSchema(database: MySqlAccountDatabase) -> None:
    with database.transaction() as connection:
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables WHERE "
            "table_schema = DATABASE() AND table_name = "
            "'gateway_schema_migrations'"
        )
        initialized = row is not None and row["count"] == 1
        versionRow = (
            connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
            if initialized
            else None
        )
        version = versionRow["version"] if versionRow else None
    if version is None:
        migrateSyntheticSchema(database)
    with database.transaction() as connection:
        # 保留 v1 摘要与账户记录；未记录 v2 的部分 DDL 可检查后重跑，不清表。
        row = connection.fetchOne("SELECT MAX(version) AS version FROM gateway_schema_migrations")
        _require(row is not None and row["version"] in {1, 2})
        if row and row["version"] == 2:
            validateUsageSchema(connection)
            return
        row = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema.tables WHERE "
            "table_schema = DATABASE() AND table_name NOT IN "
            "('gateway_schema_migrations', 'accounts', 'account_sessions', "
            "'subscription_snapshots', 'usage_operations', "
            "'usage_reconciliations')"
        )
        _require(row is not None and row["count"] == 0)
        row = connection.fetchOne("SELECT COUNT(*) AS count FROM gateway_schema_migrations")
        _require(row is not None and row["count"] == 1)
        row = connection.fetchOne(
            "SELECT definition_sha256 FROM gateway_schema_migrations WHERE version = 1"
        )
        _require(row is not None and row["definition_sha256"] == ACCOUNT_SCHEMA_DIGEST)
        for statement in USAGE_SCHEMA_STATEMENTS:
            connection.execute(statement)
        _validateUsageStructure(connection)
        for query in (
            "SELECT COUNT(*) AS count FROM subscription_snapshots",
            "SELECT COUNT(*) AS count FROM usage_operations",
            "SELECT COUNT(*) AS count FROM usage_reconciliations",
        ):
            row = connection.fetchOne(query)
            _require(row is not None and row["count"] == 0)
        connection.execute(
            ("INSERT INTO gateway_schema_migrations(version, definition_sha256) VALUES (%s, %s)"),
            (2, USAGE_SCHEMA_DIGEST),
        )
