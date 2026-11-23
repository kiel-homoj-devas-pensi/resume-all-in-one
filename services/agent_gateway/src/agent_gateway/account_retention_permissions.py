"""Least-privilege contracts for the new Web journal and separate purger role."""

from __future__ import annotations

import re

from .account_storage import AccountSqlConnection, storedText

PURGE_TABLES = (
    "accounts",
    "account_sessions",
    "subscription_snapshots",
    "usage_operations",
    "usage_reconciliations",
    "cloud_account_state",
    "cloud_documents",
    "cloud_versions",
    "cloud_operations",
    "cloud_consents",
    "account_privilege_grants",
    "account_recovery_codes",
    "account_retirements",
)


def validateRetentionWebPrivileges(connection: AccountSqlConnection) -> None:
    """Requires only the two journal INSERT columns, never DELETE or journal UPDATE."""
    identity = connection.fetchOne(
        "SELECT CONCAT(CHAR(39),SUBSTRING_INDEX(CURRENT_USER(),'@',1),CHAR(39),'@',CHAR(39),"
        "SUBSTRING_INDEX(CURRENT_USER(),'@',-1),CHAR(39)) AS grantee"
    )
    if identity is None:
        raise ValueError("retirement_web_identity_required")
    grantee = storedText(identity["grantee"])
    rows = connection.fetchMany(
        "SELECT column_name FROM information_schema.column_privileges WHERE "
        "table_schema=DATABASE() AND table_name='account_retirements' AND privilege_type='INSERT' "
        "AND grantee=%s",
        (grantee,),
        maximumRows=201,
    )
    if {storedText(row["column_name"]) for row in rows} != {"account_id", "deactivated_at_utc"}:
        raise ValueError("retirement_web_insert_privileges_required")
    for query in (
        "SELECT COUNT(*) AS count FROM information_schema.table_privileges WHERE "
        "table_schema=DATABASE() AND table_name='account_retirements' AND "
        "(privilege_type<>'SELECT' OR is_grantable='YES') "
        "AND grantee=",
        "SELECT COUNT(*) AS count FROM information_schema.column_privileges WHERE "
        "table_schema=DATABASE() AND table_name='account_retirements' "
        "AND (privilege_type NOT IN ('SELECT','INSERT') OR is_grantable='YES') "
        "AND grantee=",
        "SELECT COUNT(*) AS count FROM information_schema.schema_privileges WHERE "
        "table_schema=DATABASE() AND (privilege_type<>'SELECT' OR is_grantable='YES') AND grantee=",
        "SELECT COUNT(*) AS count FROM information_schema.user_privileges WHERE "
        "(privilege_type NOT IN ('USAGE','SELECT') OR is_grantable='YES') AND grantee=",
    ):
        count = connection.fetchOne(query + "%s", (grantee,))
        if count is None or count["count"] != 0:
            raise ValueError("retirement_web_privileges_excessive")


def validatePurgerPrivileges(
    connection: AccountSqlConnection,
    *,
    challengesOnly: bool = False,
    throttlesOnly: bool = False,
    smsPhoneOnly: bool = False,
    smsSummaryOnly: bool = False,
) -> None:
    """Exact role grant allowlist; provisioning remains a separate owner action."""
    if sum((challengesOnly, throttlesOnly, smsPhoneOnly, smsSummaryOnly)) > 1:
        raise ValueError("one_retention_category_required")
    identity = connection.fetchOne(
        "SELECT DATABASE() AS database_name,CURRENT_USER() AS identity,CURRENT_ROLE() AS roles"
    )
    if identity is None or storedText(identity["roles"]) != "NONE":
        raise ValueError("retention_purger_identity_required")
    database = storedText(identity["database_name"])
    user = storedText(identity["identity"])
    if re.fullmatch(r"[A-Za-z0-9_]{1,64}", database) is None or "@" not in user:
        raise ValueError("retention_purger_identity_required")
    name, host = user.rsplit("@", 1)
    if not name.startswith("resume_retention") or any("`" in value for value in (name, host)):
        raise ValueError("dedicated_retention_purger_required")
    tables = (
        ("identity_rate_limits",)
        if throttlesOnly
        else ("phone_challenges",)
        if challengesOnly
        else PURGE_TABLES
    )
    expected = {f"`{database}`.`{table}`": {"SELECT", "DELETE"} for table in tables}
    expected[f"`{database}`.`gateway_schema_migrations`"] = {"SELECT"}
    if smsPhoneOnly:
        expected = {
            f"`{database}`.`sms_send_attempts`": {"SELECT", "UPDATE_PHONE_HASH"},
            f"`{database}`.`gateway_schema_migrations`": {"SELECT"},
        }
    if smsSummaryOnly:
        expected = {
            f"`{database}`.`sms_send_budget`": {"SELECT"},
            f"`{database}`.`sms_send_summary`": {"SELECT", "UPDATE"},
            f"`{database}`.`sms_send_attempts`": {"SELECT", "DELETE"},
            f"`{database}`.`gateway_schema_migrations`": {"SELECT"},
        }
    actual: dict[str, set[str]] = {}
    rows = connection.fetchMany("SHOW GRANTS", maximumRows=201)
    for row in rows:
        statement = storedText(next(iter(row.values())))
        if (
            len(statement) > 4096
            or re.search(r"\b(?:IDENTIFIED|PASSWORD)\b", statement, re.I)
            or "WITH GRANT OPTION" in statement
            or not statement.startswith("GRANT ")
            or " ON " not in statement
            or " TO " not in statement
        ):
            raise ValueError("retention_purger_privileges_excessive")
        privileges, rest = statement.removeprefix("GRANT ").split(" ON ", 1)
        scope, recipient = rest.split(" TO ", 1)
        if recipient != f"`{name}`@`{host}`":
            raise ValueError("retention_purger_identity_mismatch")
        if privileges == "USAGE" and scope == "*.*":
            continue
        if scope not in expected:
            raise ValueError("retention_purger_privileges_excessive")
        parts = privileges.split(", ")
        if smsPhoneOnly:
            parts = [
                "UPDATE_PHONE_HASH"
                if re.fullmatch(r"UPDATE\s*\(\s*`phone_hash`\s*\)", item)
                else item
                for item in parts
            ]
        actual.setdefault(scope, set()).update(parts)
    if actual != expected:
        raise ValueError("retention_purger_privileges_mismatch")


def validateSmsSummaryWebPrivileges(connection: AccountSqlConnection) -> None:
    """Existing retirement checks reject global/schema writes; add summary scope."""
    identity = connection.fetchOne(
        "SELECT CONCAT(CHAR(39),SUBSTRING_INDEX(CURRENT_USER(),'@',1),CHAR(39),'@',CHAR(39),"
        "SUBSTRING_INDEX(CURRENT_USER(),'@',-1),CHAR(39)) AS grantee"
    )
    if identity is None:
        raise ValueError("sms_summary_web_identity_required")
    for query in (
        "SELECT COUNT(*) AS count FROM information_schema.table_privileges "
        "WHERE table_schema=DATABASE() AND table_name='sms_send_summary' "
        "AND (privilege_type<>'SELECT' OR is_grantable='YES') AND grantee=%s",
        "SELECT COUNT(*) AS count FROM information_schema.column_privileges "
        "WHERE table_schema=DATABASE() AND table_name='sms_send_summary' "
        "AND (privilege_type<>'SELECT' OR is_grantable='YES') AND grantee=%s",
    ):
        count = connection.fetchOne(query, (storedText(identity["grantee"]),))
        if count is None or count["count"] != 0:
            raise ValueError("sms_summary_web_privileges_excessive")
