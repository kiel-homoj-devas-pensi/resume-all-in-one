"""Explicit empty-database preparation; never a synthetic business-data contract."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Literal

from .account_storage import AccountSqlConnection, UnknownStorageCommitError, storedText
from .database import UnsupportedDatabaseSchemaError
from .mysql_cloud_schema import CLOUD_SCHEMA_DIGEST, CLOUD_SCHEMA_STATEMENTS
from .mysql_lifecycle_schema import LIFECYCLE_SCHEMA_DIGEST, LIFECYCLE_SCHEMA_STATEMENTS
from .mysql_schema import SCHEMA_DIGEST, SCHEMA_STATEMENTS
from .mysql_sms_schema import SMS_SCHEMA_DIGEST, SMS_SCHEMA_STATEMENTS
from .mysql_storage import MySqlAccountDatabase, MySqlConfig
from .mysql_usage_schema import USAGE_SCHEMA_DIGEST, USAGE_SCHEMA_STATEMENTS
from .privilege_schema import (
    MYSQL_PRIVILEGE_DIGEST,
    MYSQL_STATEMENTS,
    _validateMySqlBase,
    _validateMySqlGrantTable,
    validateMySqlPrivilegeSchema,
)

DDL = (
    *SCHEMA_STATEMENTS,
    *USAGE_SCHEMA_STATEMENTS,
    *LIFECYCLE_SCHEMA_STATEMENTS,
    *SMS_SCHEMA_STATEMENTS,
    *CLOUD_SCHEMA_STATEMENTS,
    *MYSQL_STATEMENTS,
)
DIGESTS = (
    SCHEMA_DIGEST,
    USAGE_SCHEMA_DIGEST,
    LIFECYCLE_SCHEMA_DIGEST,
    SMS_SCHEMA_DIGEST,
    CLOUD_SCHEMA_DIGEST,
    MYSQL_PRIVILEGE_DIGEST,
)
KNOWN_TABLES = tuple(sql.split()[5] for sql in DDL)
ROW_COUNTS = {
    "gateway_schema_migrations": "SELECT COUNT(*) AS count FROM gateway_schema_migrations",
    "accounts": "SELECT COUNT(*) AS count FROM accounts",
    "account_sessions": "SELECT COUNT(*) AS count FROM account_sessions",
    "subscription_snapshots": "SELECT COUNT(*) AS count FROM subscription_snapshots",
    "usage_operations": "SELECT COUNT(*) AS count FROM usage_operations",
    "usage_reconciliations": "SELECT COUNT(*) AS count FROM usage_reconciliations",
    "phone_challenges": "SELECT COUNT(*) AS count FROM phone_challenges",
    "identity_rate_limits": "SELECT COUNT(*) AS count FROM identity_rate_limits",
    "phone_verification_guards": "SELECT COUNT(*) AS count FROM phone_verification_guards",
    "sms_send_budget": "SELECT COUNT(*) AS count FROM sms_send_budget",
    "sms_send_attempts": "SELECT COUNT(*) AS count FROM sms_send_attempts",
    "cloud_account_state": "SELECT COUNT(*) AS count FROM cloud_account_state",
    "cloud_documents": "SELECT COUNT(*) AS count FROM cloud_documents",
    "cloud_versions": "SELECT COUNT(*) AS count FROM cloud_versions",
    "cloud_operations": "SELECT COUNT(*) AS count FROM cloud_operations",
    "cloud_consents": "SELECT COUNT(*) AS count FROM cloud_consents",
    "account_privilege_grants": "SELECT COUNT(*) AS count FROM account_privilege_grants",
}


class BootstrapRejectedError(ValueError):
    """Safe reason code only; driver errors and target credentials are not exposed."""

    def __init__(self, reason: str, *, visibleTables: int | None = None) -> None:
        super().__init__(reason)
        self.visibleTables = visibleTables


@dataclass(frozen=True)
class BootstrapPlan:
    state: Literal["empty", "schema_verified"]
    tableCount: int


def _count(connection: AccountSqlConnection, sql: str) -> int:
    row = connection.fetchOne(sql)
    if row is None or type(row["count"]) is not int or row["count"] < 0:
        raise BootstrapRejectedError("inspection_failed")
    return row["count"]


def inspectSchema(connection: AccountSqlConnection) -> BootstrapPlan:
    """Only reads. Unknown/partial schemas stay untouched, including empty DDL remnants."""
    tables = _count(
        connection,
        "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema=DATABASE()",
    )
    for query in (
        "SELECT COUNT(*) AS count FROM information_schema.routines WHERE routine_schema=DATABASE()",
        "SELECT COUNT(*) AS count FROM information_schema.triggers WHERE trigger_schema=DATABASE()",
        "SELECT COUNT(*) AS count FROM information_schema.events WHERE event_schema=DATABASE()",
    ):
        if _count(connection, query):
            raise BootstrapRejectedError("unexpected_database_objects")
    if tables == 0:
        return BootstrapPlan("empty", 0)
    if tables != 17:
        for table in KNOWN_TABLES:
            exists = connection.fetchOne(
                "SELECT COUNT(*) AS count FROM information_schema.tables "
                "WHERE table_schema=DATABASE() AND table_name=%s",
                (table,),
            )
            # Names come only from fixed, versioned DDL, never configuration.
            if exists and exists["count"] and _count(connection, ROW_COUNTS[table]):
                raise BootstrapRejectedError("partial_nonempty_schema", visibleTables=tables)
        raise BootstrapRejectedError("partial_or_foreign_schema", visibleTables=tables)
    try:
        validateMySqlPrivilegeSchema(connection)
    except UnsupportedDatabaseSchemaError:
        raise BootstrapRejectedError("schema_mismatch", visibleTables=tables) from None
    return BootstrapPlan("schema_verified", tables)


def _target(config: MySqlConfig) -> tuple[str, int, str]:
    return config.host.lower(), config.port, config.database


def validateTarget(
    business: MySqlConfig,
    management: MySqlConfig,
    *,
    expectedHost: str,
    expectedPort: int,
    expectedDatabase: str,
    confirmedQuiescent: bool,
    confirmedDedicatedEmpty: bool,
) -> None:
    if not confirmedQuiescent or not confirmedDedicatedEmpty:
        raise BootstrapRejectedError("explicit_confirmations_required")
    if (
        not expectedHost
        or not expectedDatabase
        or _target(business) != (expectedHost.lower(), expectedPort, expectedDatabase)
        or _target(business) != _target(management)
        or business.user == management.user
    ):
        raise BootstrapRejectedError("target_or_identity_mismatch")


def _identity(connection: AccountSqlConnection) -> tuple[str, str, str]:
    row = connection.fetchOne(
        "SELECT DATABASE() AS selected_database, CURRENT_USER() AS effective_user, "
        "@@server_uuid AS server_identity"
    )
    if row is None or any(
        not row.get(key) for key in ("selected_database", "effective_user", "server_identity")
    ):
        raise BootstrapRejectedError("identity_unavailable")
    return (
        storedText(row["selected_database"]),
        storedText(row["effective_user"]),
        storedText(row["server_identity"]),
    )


def _requireWholeSchemaRead(connection: AccountSqlConnection) -> None:
    # Table-level grants alone hide unrelated objects from information_schema.
    # An administrator must have database-wide/global SELECT to attest emptiness.
    row = connection.fetchOne(
        "SELECT (SELECT COUNT(*) FROM information_schema.schema_privileges WHERE "
        "table_schema=DATABASE() AND privilege_type='SELECT' AND grantee=CONCAT("
        "CHAR(39),SUBSTRING_INDEX(CURRENT_USER(),'@',1),CHAR(39),'@',CHAR(39),"
        "SUBSTRING_INDEX(CURRENT_USER(),'@',-1),CHAR(39))) + "
        "(SELECT COUNT(*) FROM information_schema.user_privileges WHERE "
        "privilege_type='SELECT' AND grantee=CONCAT(CHAR(39),"
        "SUBSTRING_INDEX(CURRENT_USER(),'@',1),CHAR(39),'@',CHAR(39),"
        "SUBSTRING_INDEX(CURRENT_USER(),'@',-1),CHAR(39))) AS count"
    )
    if row is None or not row["count"]:
        raise BootstrapRejectedError("management_whole_schema_read_required")


def prepareEmptySchema(
    business: MySqlAccountDatabase,
    management: MySqlAccountDatabase,
    *,
    expectedDatabase: str,
    confirmedQuiescent: bool,
    confirmedDedicatedEmpty: bool,
) -> BootstrapPlan:
    """Caller validates explicit target/confirmations before constructing databases.

    No loops retry writes. A failed CREATE may already exist; a failed commit may
    already have recorded all digests. Inspect with check before any human decision.
    Partial schemas are deliberately refused rather than implicitly resumed.
    """
    if not confirmedQuiescent or not confirmedDedicatedEmpty:
        raise BootstrapRejectedError("explicit_confirmations_required")
    with business.readConnection() as connection:
        businessIdentity = _identity(connection)
    wrote = False
    try:
        with management.transaction() as connection:
            identity = _identity(connection)
            if (
                identity[0] != expectedDatabase
                or businessIdentity[0] != expectedDatabase
                or identity[2] != businessIdentity[2]
                or identity[1] == businessIdentity[1]
            ):
                raise BootstrapRejectedError("effective_identity_mismatch")
            _requireWholeSchemaRead(connection)
            lockName = (
                "gateway-bootstrap-" + hashlib.sha256(expectedDatabase.encode()).hexdigest()[:40]
            )
            lock = connection.fetchOne("SELECT GET_LOCK(%s, 0) AS acquired", (lockName,))
            if lock is None or lock["acquired"] != 1:
                raise BootstrapRejectedError("maintenance_lock_unavailable")
            try:
                plan = inspectSchema(connection)
                if plan.state == "schema_verified":
                    return plan
                for statement in DDL:
                    wrote = True
                    connection.execute(statement)
                _validateMySqlBase(connection, tableCount=17)
                _validateMySqlGrantTable(connection)
                for version, digest in enumerate(DIGESTS, 1):
                    connection.execute(
                        "INSERT INTO gateway_schema_migrations(version, definition_sha256) "
                        "VALUES (%s,%s)",
                        (version, digest),
                    )
                validateMySqlPrivilegeSchema(connection)
            finally:
                # Named lock is session-scoped, not transaction-scoped. On release
                # failure the database wrapper discards this connection; never retry.
                released = connection.fetchOne("SELECT RELEASE_LOCK(%s) AS released", (lockName,))
                if released is None or released["released"] != 1:
                    raise UnknownStorageCommitError("bootstrap_outcome_unknown")
        with business.readConnection() as connection:
            return inspectSchema(connection)
    except Exception:
        if wrote:
            raise UnknownStorageCommitError("bootstrap_outcome_unknown") from None
        raise
