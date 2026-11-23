"""Explicit dedicated-empty MySQL initialization with separate owner, maint and Web identities."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from contextlib import suppress
from pathlib import Path
from typing import Any
from urllib.parse import quote

import pymysql

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from agent_gateway.account_storage import storedText  # noqa: E402
from agent_gateway.mysql_bootstrap import (  # noqa: E402
    DIGESTS,
    KNOWN_TABLES,
    prepareEmptySchema,
    validateTarget,
)
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig  # noqa: E402

ACCOUNTS = ("resume_owner", "resume_maint", "resume_web")
WEB_WRITES = {
    "accounts": (
        "INSERT(account_id,phone_e164,password_hash,phone_verified_at_utc,created_at_utc,is_active)",
        "UPDATE(phone_e164,password_hash,is_active)",
    ),
    "account_sessions": (
        "INSERT(session_id,account_id,token_hash,expires_at_utc,created_at_utc,revoked_at_utc)",
        "UPDATE(revoked_at_utc)",
    ),
    "usage_operations": (
        "INSERT(operation_id,account_id,capability,idempotency_key_hash,request_fingerprint_hash,status,quota_window_start_utc,quota_window_end_utc,plan_at_reservation,created_at_utc,updated_at_utc,failure_code)",
        "UPDATE(status,updated_at_utc,failure_code,prompt_version,input_tokens,output_tokens)",
    ),
    "phone_challenges": (
        "INSERT(challenge_id,phone_hash,purpose,code_hash,expires_at_utc)",
        "UPDATE(attempts,consumed_at_utc)",
    ),
    "identity_rate_limits": (
        "INSERT(bucket_hash,window_start_utc,attempts)",
        "UPDATE(bucket_hash,window_start_utc,attempts)",
    ),
    "phone_verification_guards": ("INSERT(phone_hash,purpose)", "UPDATE(purpose)"),
    "sms_send_budget": ("UPDATE(attempts,reserved_cents)",),
    "sms_send_attempts": (
        "INSERT(challenge_id,policy_id,phone_hash,purpose,outcome,reserved_cents,created_at_utc)",
        "UPDATE(outcome,finalized_at_utc,request_id_digest,biz_id_digest)",
    ),
    "cloud_account_state": ("INSERT(account_id,last_sequence)", "UPDATE(last_sequence)"),
    "cloud_documents": ("UPDATE(deleted_at_utc,last_sequence)",),
    "cloud_consents": ("UPDATE(revoked_at_utc)",),
}
MAINT_WRITES = {
    "account_privilege_grants": (
        "INSERT(grant_id,account_id,privilege,operator_id,evidence_sha256,granted_at_utc,revoked_at_utc,revoked_by,revocation_evidence_sha256)",
        "UPDATE(revoked_at_utc,revoked_by,revocation_evidence_sha256)",
    ),
    "sms_send_budget": (
        "INSERT(policy_id,policy_fingerprint,maximum_attempts,budget_cents,reserve_per_attempt_cents,attempts,reserved_cents,expires_at_utc,created_at_utc)",
    ),
}


def grants(connection: Any) -> list[str]:
    with connection.cursor() as cursor:
        cursor.execute("SHOW GRANTS")
        result = [next(iter(row.values())) for row in cursor.fetchall()]
    if any(
        not isinstance(row, str)
        or len(row) > 4096
        or re.search(r"\b(?:IDENTIFIED|PASSWORD)\b", row, re.I)
        for row in result
    ):
        raise ValueError("unexpected_grant_output")
    return result


def identity(connection: Any, account: str) -> None:
    with connection.cursor() as cursor:
        cursor.execute("SELECT CURRENT_USER() AS identity, CURRENT_ROLE() AS roles")
        row = cursor.fetchone()
    if not connection._secure or row != {"identity": account + "@%", "roles": "NONE"}:
        raise ValueError("effective_identity_or_role_mismatch")
    if any(" ON " not in row for row in grants(connection)):
        raise ValueError("assigned_roles_not_reviewed")


def connect(args: argparse.Namespace, passwords: dict[str, str], account: str) -> Any:
    connection = pymysql.connect(
        host=args.host,
        port=args.port,
        user=account,
        password=passwords[account],
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
        connect_timeout=12,
        read_timeout=12,
        write_timeout=12,
        ssl_ca=str(args.ca_file),
        ssl_verify_cert=True,
        ssl_verify_identity=True,
        local_infile=False,
    )
    try:
        identity(connection, account)
    except Exception:
        connection.close()
        raise
    return connection


def privilege_set(value: str) -> set[str]:
    value = value.replace("`", "").replace(" ", "")
    entries = re.findall(r"SELECT|(?:INSERT|UPDATE)\([a-z_0-9,]+\)", value)
    if ",".join(entries) != value:
        raise ValueError("unexpected_final_privilege")
    result = set()
    for entry in entries:
        if entry == "SELECT":
            result.add(entry)
        else:
            kind, columns = entry[:-1].split("(", 1)
            result.update(kind + ":" + column for column in columns.split(","))
    return result


def scoped_grants(connection: Any, database: str, account: str, *, blank: bool = False) -> None:
    actual: dict[str, set[str]] = {}
    for statement in grants(connection):
        if "WITH GRANT OPTION" in statement or " ON " not in statement:
            raise ValueError("unexpected_role_or_grant_option")
        privilege, scope = statement.removeprefix("GRANT ").split(" ON ", 1)
        scope, recipient = scope.split(" TO ", 1)
        if recipient != f"`{account}`@`%`":
            raise ValueError("unexpected_grant_recipient")
        if scope == "*.*" and privilege == "USAGE":
            continue
        if blank or scope not in {f"`{database}`.`{table}`" for table in KNOWN_TABLES}:
            raise ValueError("non_application_or_database_wide_grant")
        if any(
            token in privilege
            for token in ("DELETE", "CREATE", "DROP", "ALTER", "REFERENCES", "INDEX")
        ):
            raise ValueError("unexpected_final_ddl_or_delete")
        actual.setdefault(scope, set()).update(privilege_set(privilege))
    writes = WEB_WRITES if account == "resume_web" else MAINT_WRITES
    expected = (
        {}
        if blank
        else {
            f"`{database}`.`{table}`": set().union(
                {"SELECT"}, *(privilege_set(value) for value in writes.get(table, ()))
            )
            for table in KNOWN_TABLES
        }
    )
    if actual != expected:
        raise ValueError("final_privilege_matrix_mismatch")


def owner_inventory(owner: Any, database: str) -> dict[str, object]:
    statements = grants(owner)
    global_grants = [row for row in statements if " ON *.* " in row and "WITH GRANT OPTION" in row]
    if not any(
        all(
            re.search(r"\b" + privilege + r"\b", row)
            for privilege in ("SELECT", "EVENT", "TRIGGER", "CREATE USER")
        )
        for row in global_grants
    ):
        raise ValueError("owner_whole_object_visibility_required")
    with owner.cursor() as cursor:
        cursor.execute("SELECT @@server_uuid AS serverUuid, @@mandatory_roles AS mandatoryRoles")
        server = cursor.fetchone()
        if not server or server["mandatoryRoles"]:
            raise ValueError("mandatory_roles_not_reviewed")
        cursor.execute(
            "SELECT DEFAULT_CHARACTER_SET_NAME AS charset, "
            "DEFAULT_COLLATION_NAME AS collation FROM information_schema.schemata "
            "WHERE SCHEMA_NAME=%s",
            (database,),
        )
        if cursor.fetchone() != {"charset": "utf8mb4", "collation": "utf8mb4_bin"}:
            raise ValueError("target_database_metadata_mismatch")
        counts = {}
        for kind, table, column in (
            ("tables", "tables", "table_schema"),
            ("routines", "routines", "routine_schema"),
            ("triggers", "triggers", "trigger_schema"),
            ("events", "events", "event_schema"),
        ):
            cursor.execute(
                f"SELECT COUNT(*) AS count FROM information_schema.{table} WHERE {column}=%s",  # noqa: S608
                (database,),
            )
            counts[kind] = cursor.fetchone()["count"]
    if any(counts.values()):
        raise ValueError("target_not_dedicated_empty")
    return {"serverUuid": server["serverUuid"], "objects": counts, "ownerVisibilityVerified": True}


def require_initial_default_grants(connection: Any) -> None:
    for statement in grants(connection):
        privilege, scope = statement.removeprefix("GRANT ").split(" ON ", 1)
        scope = scope.split(" TO ", 1)[0]
        if "WITH GRANT OPTION" in statement:
            raise ValueError("unexpected_existing_grant_option")
        if scope == "*.*" and set(privilege.split(", ")) <= {
            "USAGE",
            "PROCESS",
            "REPLICATION SLAVE",
            "REPLICATION CLIENT",
            "XA_RECOVER_ADMIN",
        }:
            continue
        if privilege == "SELECT" and re.fullmatch(
            r"`mysql`\.`(?:func|general_log|help_category|help_keyword|help_relation|help_topic|"
            r"slow_log|time_zone(?:_name|_transition|_transition_type|_leap_second)?)`",
            scope,
        ):
            continue
        raise ValueError("unexpected_existing_account_grants")


def execute(owner: Any, sql: str) -> None:
    with owner.cursor() as cursor:
        cursor.execute(sql)


def verify_denials(web: Any, database: str) -> int:
    statements = [
        f"DELETE FROM `{database}`.`{table}` WHERE 1=0"  # noqa: S608
        for table in KNOWN_TABLES
    ]
    for table in (
        "gateway_schema_migrations",
        "account_privilege_grants",
        "subscription_snapshots",
        "usage_reconciliations",
        "cloud_versions",
        "cloud_operations",
        "cloud_documents",
        "cloud_consents",
        "sms_send_budget",
    ):
        statements.append(
            f"INSERT INTO `{database}`.`{table}` SELECT * FROM `{database}`.`{table}` WHERE 1=0"  # noqa: S608
        )
    for table, column in (
        ("gateway_schema_migrations", "definition_sha256"),
        ("account_privilege_grants", "privilege"),
        ("subscription_snapshots", "plan"),
        ("usage_reconciliations", "evidence_kind"),
        ("sms_send_budget", "budget_cents"),
        ("cloud_documents", "current_version_id"),
        ("accounts", "phone_verified_at_utc"),
        ("account_sessions", "account_id"),
    ):
        statements.append(
            f"UPDATE `{database}`.`{table}` SET `{column}`=`{column}` WHERE 1=0"  # noqa: S608
        )
    for sql in statements:
        with web.cursor() as cursor:
            try:
                cursor.execute(sql)
            except pymysql.err.OperationalError as error:
                if error.args[0] not in (1044, 1142, 1143):
                    raise ValueError("negative_probe_not_permission_denied") from None
            else:
                raise ValueError("unexpected_web_write_permission")
    return len(statements)


def initialize(
    args: argparse.Namespace, passwords: dict[str, str], journal: dict[str, Any]
) -> None:
    connections: list[Any] = []
    databases: list[MySqlAccountDatabase] = []
    try:
        owner = connect(args, passwords, "resume_owner")
        connections.append(owner)
        lock_name = "gateway-deployment-" + hashlib.sha256(args.database.encode()).hexdigest()[:40]
        with owner.cursor() as cursor:
            cursor.execute("SELECT GET_LOCK(%s, 0) AS acquired", (lock_name,))
            if cursor.fetchone() != {"acquired": 1}:
                raise ValueError("deployment_lock_unavailable")
        journal["inventory"] = owner_inventory(owner, args.database)
        journal["beforeGrants"] = {}
        for account in ACCOUNTS[1:]:
            connection = connect(args, passwords, account)
            try:
                require_initial_default_grants(connection)
                journal["beforeGrants"][account] = grants(connection)
            finally:
                connection.close()
        owner_grants = grants(owner)
        if not args.apply:
            journal["status"] = "dedicated_empty_plan_verified"
            return
        journal["phase"] = "normalize_new_dedicated_accounts"
        journal["writeRequested"] = True
        execute(
            owner, "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'resume_maint'@'%', 'resume_web'@'%'"
        )
        for account in ACCOUNTS[1:]:
            connection = connect(args, passwords, account)
            try:
                scoped_grants(connection, args.database, account, blank=True)
            finally:
                connection.close()
        journal["normalizationVerified"] = True
        journal["phase"] = "temporary_initialization_grants"
        db = "`" + args.database + "`"
        execute(owner, f"GRANT SELECT ON {db}.* TO 'resume_web'@'%'")
        execute(
            owner,
            "GRANT SELECT, INSERT, CREATE, ALTER, INDEX, REFERENCES "
            f"ON {db}.* TO 'resume_maint'@'%'",
        )
        configs = {
            account: MySqlConfig.fromDsn(
                f"mysql://{account}:{quote(passwords[account], safe='')}"
                f"@{args.host}:{args.port}/{args.database}",
                args.ca_file,
                args.expires_at_utc,
            )
            for account in ACCOUNTS[1:]
        }
        validateTarget(
            configs["resume_web"],
            configs["resume_maint"],
            expectedHost=args.host,
            expectedPort=args.port,
            expectedDatabase=args.database,
            confirmedQuiescent=True,
            confirmedDedicatedEmpty=True,
        )
        business = MySqlAccountDatabase(configs["resume_web"])
        management = MySqlAccountDatabase(configs["resume_maint"])
        databases.extend((business, management))
        journal["phase"] = "single_schema_initialization"
        if owner_inventory(owner, args.database) != journal["inventory"]:
            raise ValueError("owner_inventory_changed")
        for database in databases:
            with database.readConnection() as connection:
                server = connection.fetchOne("SELECT @@server_uuid AS serverUuid")
                if not server or server["serverUuid"] != journal["inventory"]["serverUuid"]:
                    raise ValueError("server_identity_changed")
        plan = prepareEmptySchema(
            business,
            management,
            expectedDatabase=args.database,
            confirmedQuiescent=True,
            confirmedDedicatedEmpty=True,
        )
        if plan.state != "schema_verified" or plan.tableCount != 17:
            raise ValueError("schema_not_verified")
        for database in databases:
            database.close()
        databases.clear()
        journal["schemaVerified"] = True
        journal["phase"] = "final_table_and_column_grants"
        execute(
            owner, "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'resume_maint'@'%', 'resume_web'@'%'"
        )
        for account, writes in (("resume_web", WEB_WRITES), ("resume_maint", MAINT_WRITES)):
            for table in KNOWN_TABLES:
                privileges = ("SELECT", *writes.get(table, ()))
                execute(
                    owner, f"GRANT {', '.join(privileges)} ON {db}.`{table}` TO '{account}'@'%'"
                )
            connection = connect(args, passwords, account)
            connections.append(connection)
            scoped_grants(connection, args.database, account)
            with connection.cursor() as cursor:
                cursor.execute("SELECT @@server_uuid AS serverUuid")
                if cursor.fetchone()["serverUuid"] != journal["inventory"]["serverUuid"]:
                    raise ValueError("server_identity_changed")
        web = connections[-2]
        journal["phase"] = "fresh_web_permission_and_schema_verification"
        journal["permissionDenialsVerified"] = verify_denials(web, args.database)
        with web.cursor() as cursor:
            cursor.execute(
                f"SELECT version, definition_sha256 FROM {db}.gateway_schema_migrations "  # noqa: S608
                "ORDER BY version"
            )
            rows = cursor.fetchall()
            if [(row["version"], storedText(row["definition_sha256"])) for row in rows] != list(
                enumerate(DIGESTS, 1)
            ):
                raise ValueError("schema_digest_mismatch")
            for table in KNOWN_TABLES:
                cursor.execute(f"SELECT COUNT(*) AS count FROM {db}.`{table}`")  # noqa: S608
                if cursor.fetchone()["count"] != (6 if table == "gateway_schema_migrations" else 0):
                    raise ValueError("unexpected_business_rows")
        if grants(owner) != owner_grants:
            raise ValueError("owner_grants_changed")
        journal.update(
            status="dedicated_database_prepared",
            phase="verified",
            schemaVersion=6,
            tables=17,
            migrationDigests=6,
            businessRows=0,
            finalGrants={
                account: grants(connection)
                for account, connection in zip(
                    ("resume_web", "resume_maint"), connections[-2:], strict=True
                )
            },
        )
    finally:
        for database in databases:
            database.close()
        for connection in connections:
            with suppress(Exception):
                connection.close()


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=3306)
    parser.add_argument("--database", required=True)
    parser.add_argument("--ca-file", type=Path, required=True)
    parser.add_argument("--expires-at-utc", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirmed-quiescent-dedicated-empty", action="store_true")
    args = parser.parse_args(arguments)
    journal: dict[str, Any] = {
        "phase": "input",
        "writeRequested": False,
        "retryable": False,
        "credentialsSaved": False,
        "smsOrModelCalled": False,
    }
    passwords = {}
    try:
        if (
            args.apply
            and not args.confirmed_quiescent_dedicated_empty
            or re.fullmatch(r"[A-Za-z0-9.-]{1,253}", args.host) is None
            or not 1 <= args.port <= 65535
            or re.fullmatch(r"[A-Za-z0-9_]{1,64}", args.database) is None
            or re.fullmatch(r"[A-Za-z]:[\\/][^:]*", str(args.ca_file)) is None
            or not args.ca_file.is_file()
            or any(
                path.is_symlink() or path.is_junction()
                for path in (args.ca_file, *args.ca_file.parents)
            )
            or sys.stdin.isatty()
        ):
            raise ValueError("explicit_input_required")
        raw = sys.stdin.read(65537)
        if len(raw) > 65536:
            raise ValueError("input_bound")
        passwords = json.loads(raw)
        raw = ""
        if (
            not isinstance(passwords, dict)
            or set(passwords) != set(ACCOUNTS)
            or any(
                not isinstance(value, str) or not 1 <= len(value) <= 4096
                for value in passwords.values()
            )
        ):
            raise ValueError("password_input_required")
        # Validate expiry before any owner DCL, rather than failing after granting temporary rights.
        MySqlConfig.fromDsn(
            f"mysql://resume_web:{quote(passwords['resume_web'], safe='')}"
            f"@{args.host}:{args.port}/{args.database}",
            args.ca_file,
            args.expires_at_utc,
        )
        journal["phase"] = "owner_complete_inventory"
        initialize(args, passwords, journal)
        print(json.dumps(journal))
        return 0
    except Exception as error:
        journal["status"] = (
            "outcome_requires_read_only_review" if journal["writeRequested"] else "preflight_failed"
        )
        journal["driverCode"] = error.args[0] if error.args and type(error.args[0]) is int else None
        print(json.dumps(journal))
        return 2 if journal["writeRequested"] else 1
    finally:
        if isinstance(passwords, dict):
            passwords.clear()


if __name__ == "__main__":
    raise SystemExit(main())
