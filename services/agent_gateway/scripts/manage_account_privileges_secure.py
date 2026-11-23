"""Private-stdin management of one verified account privilege; no migration or supplier calls."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Never, cast
from urllib.parse import quote
from uuid import UUID

import pymysql

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from agent_gateway.account_privileges import AccountPrivilegeService, Privilege  # noqa: E402
from agent_gateway.account_storage import UnknownStorageCommitError, storedText  # noqa: E402
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig  # noqa: E402
from agent_gateway.privilege_schema import validateMySqlPrivilegeSchema  # noqa: E402


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        del message
        print(json.dumps({"status": "privilege_arguments_invalid", "retryable": False}))
        self.exit(2)


def _uniqueObject(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for name, value in pairs:
        if name in result:
            raise ValueError("invalid_input")
        result[name] = value
    return result


def _credentials(apply: bool) -> dict[str, str]:
    if sys.stdin.isatty():
        raise ValueError("private_input_required")
    raw = sys.stdin.read(65_537)
    if len(raw) > 65_536:
        raise ValueError("invalid_input")
    payload = json.loads(raw, object_pairs_hook=_uniqueObject)
    required = {"phone", "resume_web"} | ({"resume_maint"} if apply else set())
    if (
        not isinstance(payload, dict)
        or set(payload) != required
        or any(
            not isinstance(value, str)
            or not 1 <= len(value) <= 4096
            or any(ord(character) < 32 or ord(character) == 127 for character in value)
            for value in payload.values()
        )
    ):
        raise ValueError("invalid_input")
    return cast(dict[str, str], payload)


def _identity(database: MySqlAccountDatabase, account: str, schema: str) -> str:
    with database.readConnection() as connection:
        validateMySqlPrivilegeSchema(connection)
        row = connection.fetchOne(
            "SELECT @@server_uuid AS server_uuid, CURRENT_USER() AS identity, "
            "DATABASE() AS database_name"
        )
        if (
            row is None
            or storedText(row["identity"]).split("@", 1)[0] != account
            or storedText(row["database_name"]) != schema
        ):
            raise ValueError("identity_mismatch")
        return str(UUID(storedText(row["server_uuid"])))


def _failure_category(error: Exception) -> str:
    """Inspect only bounded driver codes, including wrapped storage failures."""
    current: BaseException | None = error
    for _ in range(6):
        if isinstance(current, pymysql.MySQLError) and current.args:
            if type(current.args[0]) is not int:
                return "database_rejected"
            return {
                1045: "credentials_rejected",
                1044: "database_access_denied",
                1142: "query_not_permitted",
                1143: "column_not_permitted",
                1205: "lock_wait_timeout",
                1213: "transaction_deadlock",
                2003: "connection_unavailable",
                2013: "connection_interrupted",
                2026: "tls_unavailable",
            }.get(current.args[0], "database_rejected")
        current = current.__context__ if current is not None else None
        if current is None:
            break
    return "check_rejected"


def main(arguments: list[str] | None = None) -> int:
    parser = _Parser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=3306)
    parser.add_argument("--database", required=True)
    parser.add_argument("--ca-file", type=Path, required=True)
    parser.add_argument("--expires-at-utc", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--grant-id", required=True)
    parser.add_argument("--privilege", choices=("admin", "permanentMember"), required=True)
    parser.add_argument("--operator-id", required=True)
    parser.add_argument("--evidence-sha256", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirmed-grant", action="store_true")
    args = parser.parse_args(arguments)
    databases: list[MySqlAccountDatabase] = []
    payload: dict[str, str] = {}
    common = {"writeRequested": args.apply, "externalRequests": 0, "retryable": False}
    stage = "validate_arguments"
    try:
        if (
            args.apply != args.confirmed_grant
            or not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", args.host)
            or not 1 <= args.port <= 65535
            or not re.fullmatch(r"[A-Za-z0-9_]{1,64}", args.database)
        ):
            raise ValueError("invalid_target")
        for identifier in (args.account_id, args.grant_id, args.operator_id):
            if not re.fullmatch(r"[A-Za-z0-9._:-]{1,64}", identifier):
                raise ValueError("invalid_plan")
        if not re.fullmatch(r"[a-f0-9]{64}", args.evidence_sha256):
            raise ValueError("invalid_plan")
        ca = args.ca_file
        if (
            not ca.is_absolute()
            or not ca.is_file()
            or any(p.is_symlink() or p.is_junction() for p in (ca, *ca.parents))
        ):
            raise ValueError("invalid_ca")
        if sys.platform == "win32" and not re.fullmatch(r"[A-Za-z]:[\\/][^:]*", str(ca)):
            raise ValueError("invalid_ca")
        stage = "private_input"
        payload = _credentials(args.apply)

        def config(account: str) -> MySqlConfig:
            return MySqlConfig.fromDsn(
                f"mysql://{account}:{quote(payload[account], safe='')}"
                f"@{args.host}:{args.port}/{args.database}",
                ca,
                args.expires_at_utc,
            )

        stage = "business_configuration"
        business_config = config("resume_web")
        business = MySqlAccountDatabase(business_config)
        databases.append(business)
        stage = "business_identity_and_schema"
        server = _identity(business, "resume_web", args.database)
        plan = dict(
            accountId=args.account_id,
            expectedPhone=payload["phone"],
            grantId=args.grant_id,
            privilege=cast(Privilege, args.privilege),
            operatorId=args.operator_id,
            evidenceSha256=args.evidence_sha256,
        )
        stage = "read_only_grant_plan"
        status = AccountPrivilegeService(business).grant(**plan, apply=False)
        if args.apply:
            stage = "maintenance_configuration"
            maintenance = MySqlAccountDatabase(config("resume_maint"))
            databases.append(maintenance)
            stage = "maintenance_identity_and_schema"
            if (
                business.authorityKey != maintenance.authorityKey
                or _identity(maintenance, "resume_maint", args.database) != server
            ):
                raise ValueError("identity_mismatch")
            # Exactly one domain grant. A commit with unknown outcome is never retried here.
            stage = "maintenance_grant_transaction"
            AccountPrivilegeService(maintenance).grant(**plan, apply=True)
            maintenance.close()
            business.close()
            business = MySqlAccountDatabase(business_config)
            databases.append(business)
            stage = "fresh_business_identity_and_schema"
            if _identity(business, "resume_web", args.database) != server:
                raise ValueError("fresh_identity_mismatch")
            stage = "fresh_same_grant_readback"
            status = AccountPrivilegeService(business).grant(**plan, apply=False)
            if status != "already_granted":
                raise ValueError("grant_readback_failed")
        stage = "current_privileges_readback"
        privileges = AccountPrivilegeService(business).read(args.account_id)
        if args.apply and (
            (args.privilege == "admin" and privileges.role != "admin")
            or (args.privilege == "permanentMember" and privileges.membership != "permanent")
        ):
            raise ValueError("privilege_readback_changed")
        print(
            json.dumps(
                {
                    **common,
                    "status": "privilege_verified" if args.apply else "privilege_plan",
                    "matchingGrantVerified": status == "already_granted",
                    "role": privileges.role,
                    "membership": privileges.membership,
                }
            )
        )
        return 0
    except UnknownStorageCommitError:
        print(
            json.dumps(
                {
                    **common,
                    "status": "outcome_unknown",
                    "failureStage": stage,
                    "next": "read_only_same_grant_check",
                }
            )
        )
        return 2
    except Exception as error:
        print(
            json.dumps(
                {
                    **common,
                    "status": "privilege_check_failed",
                    "failureStage": stage,
                    "failureCategory": _failure_category(error),
                    "next": "read_only_same_grant_check",
                }
            )
        )
        return 1
    finally:
        payload.clear()
        for database in databases:
            try:
                database.close()
            except Exception:  # noqa: S110 -- never expose driver exceptions or credentials.
                pass


if __name__ == "__main__":
    raise SystemExit(main())
