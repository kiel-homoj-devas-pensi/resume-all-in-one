from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Literal, cast

from agent_gateway.account_privileges import AccountPrivilegeService
from agent_gateway.account_storage import (
    AccountSqlDatabase,
    SqliteAccountDatabase,
    UnknownStorageCommitError,
)
from agent_gateway.database import GatewayDatabase
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig
from agent_gateway.privilege_schema import (
    migrateMySqlPrivilegeSchema,
    migrateSqlitePrivilegeSchema,
    validateMySqlPrivilegeSchema,
    validateSqlitePrivilegeSchema,
)


def configuredDatabase(*, write: bool) -> AccountSqlDatabase:
    backend = os.environ.get("GATEWAY_DATABASE_BACKEND", "sqlite")
    if backend == "sqlite":
        configured = os.environ.get("AGENT_GATEWAY_TASK018_DATABASE_PATH")
        if not configured or not Path(configured).is_absolute() or not Path(configured).is_file():
            raise ValueError("privilege_database_required")
        return SqliteAccountDatabase(GatewayDatabase(Path(configured)))
    if backend != "mysql":
        raise ValueError("privilege_database_required")
    dsn = os.environ.get("GATEWAY_DATABASE_DSN")
    ca = os.environ.get("GATEWAY_DATABASE_TLS_CA_FILE")
    expiry = os.environ.get("GATEWAY_DATABASE_EXPIRES_AT_UTC")
    if not dsn or not ca or not expiry:
        raise ValueError("privilege_database_required")
    config = MySqlConfig.fromDsn(dsn, Path(ca), expiry)
    if write:
        migrationDsn = os.environ.get("GATEWAY_DATABASE_MIGRATION_DSN")
        if not migrationDsn:
            raise ValueError("privilege_management_identity_required")
        management = MySqlConfig.fromDsn(migrationDsn, Path(ca), expiry)
        if (management.host.lower(), management.port, management.database) != (
            config.host.lower(),
            config.port,
            config.database,
        ) or management.user == config.user:
            raise ValueError("privilege_management_identity_mismatch")
        config = management
    return MySqlAccountDatabase(config)


def checkSchema(database: AccountSqlDatabase) -> None:
    if isinstance(database, MySqlAccountDatabase):
        with database.readConnection() as connection:
            validateMySqlPrivilegeSchema(connection)
    else:
        validateSqlitePrivilegeSchema(GatewayDatabase(Path(database.authorityKey[1])))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="默认只读核对。显式迁移/授予由受控离线管理身份执行；不发送短信或调用模型。"
    )
    parser.add_argument("action", choices=("check", "migrate", "grant", "revoke"))
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirmed-quiescent", action="store_true")
    parser.add_argument("--account-id")
    parser.add_argument("--grant-id")
    parser.add_argument("--privilege", choices=("admin", "permanentMember"))
    parser.add_argument("--operator-id")
    parser.add_argument("--evidence-sha256")
    args = parser.parse_args()
    database: AccountSqlDatabase | None = None
    try:
        if args.apply and args.action == "check":
            raise ValueError("invalid_write_request")
        if args.action == "migrate" and args.apply and not args.confirmed_quiescent:
            raise ValueError("quiescent_confirmation_required")
        database = configuredDatabase(write=args.apply)
        if args.action == "migrate" and args.apply:
            if isinstance(database, MySqlAccountDatabase):
                migrateMySqlPrivilegeSchema(database)
            else:
                migrateSqlitePrivilegeSchema(GatewayDatabase(Path(database.authorityKey[1])))
        checkSchema(database)
        status = "schema_verified"
        if args.action in {"grant", "revoke"}:
            if not all((args.account_id, args.grant_id, args.operator_id, args.evidence_sha256)):
                raise ValueError("management_plan_required")
            service = AccountPrivilegeService(database)
            if args.action == "grant":
                expectedPhone = os.environ.get("AGENT_GATEWAY_PRIVILEGE_TARGET_PHONE")
                if expectedPhone is None or args.privilege is None:
                    raise ValueError("management_plan_required")
                status = service.grant(
                    accountId=args.account_id,
                    expectedPhone=expectedPhone,
                    grantId=args.grant_id,
                    privilege=cast(Literal["admin", "permanentMember"], args.privilege),
                    operatorId=args.operator_id,
                    evidenceSha256=args.evidence_sha256,
                    apply=args.apply,
                )
            else:
                status = service.revoke(
                    accountId=args.account_id,
                    grantId=args.grant_id,
                    operatorId=args.operator_id,
                    evidenceSha256=args.evidence_sha256,
                    apply=args.apply,
                )
        print(json.dumps({"status": status, "writeRequested": args.apply, "externalRequests": 0}))
        return 0
    except UnknownStorageCommitError:
        print(
            json.dumps({"status": "outcome_unknown", "retryable": False, "next": "read_only_check"})
        )
        return 2
    except Exception:
        print(json.dumps({"status": "privilege_management_failed", "retryable": False}))
        return 1
    finally:
        if isinstance(database, MySqlAccountDatabase):
            database.close()


if __name__ == "__main__":
    raise SystemExit(main())
