"""Read-only by default; controlled preparation of a dedicated empty MySQL database."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from agent_gateway.account_storage import UnknownStorageCommitError
from agent_gateway.mysql_bootstrap import (
    BootstrapRejectedError,
    inspectSchema,
    prepareEmptySchema,
    validateTarget,
)
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig


def _config(variable: str) -> MySqlConfig:
    dsn = os.environ.get(variable)
    ca = os.environ.get("GATEWAY_DATABASE_TLS_CA_FILE")
    expiry = os.environ.get("GATEWAY_DATABASE_EXPIRES_AT_UTC")
    if not dsn or not ca or not expiry:
        raise BootstrapRejectedError("database_configuration_required")
    return MySqlConfig.fromDsn(dsn, Path(ca), expiry)


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="默认只读；只准备专用空库v6结构，不写账号、短信预算或授予权益。"
    )
    parser.add_argument("action", nargs="?", default="plan", choices=("plan", "check"))
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--expected-host")
    parser.add_argument("--expected-port", type=int, default=3306)
    parser.add_argument("--expected-database")
    parser.add_argument("--confirmed-quiescent", action="store_true")
    parser.add_argument("--confirmed-dedicated-empty", action="store_true")
    args = parser.parse_args(arguments)
    databases: list[MySqlAccountDatabase] = []
    try:
        if args.apply and args.action != "plan":
            raise BootstrapRejectedError("check_is_read_only")
        businessConfig = _config("GATEWAY_DATABASE_DSN")
        managementConfig = None
        if args.apply:
            managementConfig = _config("GATEWAY_DATABASE_MIGRATION_DSN")
            validateTarget(
                businessConfig,
                managementConfig,
                expectedHost=args.expected_host or "",
                expectedPort=args.expected_port,
                expectedDatabase=args.expected_database or "",
                confirmedQuiescent=args.confirmed_quiescent,
                confirmedDedicatedEmpty=args.confirmed_dedicated_empty,
            )
        business = MySqlAccountDatabase(businessConfig)
        databases.append(business)
        if managementConfig is not None:
            management = MySqlAccountDatabase(managementConfig)
            databases.append(management)
            plan = prepareEmptySchema(
                business,
                management,
                expectedDatabase=args.expected_database,
                confirmedQuiescent=args.confirmed_quiescent,
                confirmedDedicatedEmpty=args.confirmed_dedicated_empty,
            )
        else:
            with business.readConnection() as connection:
                plan = inspectSchema(connection)
        if args.action == "check" and plan.state != "schema_verified":
            raise BootstrapRejectedError("schema_not_prepared")
        print(
            json.dumps(
                {
                    "status": plan.state,
                    "schemaVersion": 6 if plan.state == "schema_verified" else None,
                    "visibleTables": plan.tableCount,
                    "writeRequested": args.apply,
                    "businessRowsWritten": 0,
                    "paidExternalRequests": 0,
                    "retryable": False,
                }
            )
        )
        return 0
    except UnknownStorageCommitError:
        print(
            json.dumps(
                {
                    "status": "outcome_unknown",
                    "retryable": False,
                    "next": "read_only_check",
                }
            )
        )
        return 2
    except BootstrapRejectedError as error:
        print(
            json.dumps(
                {
                    "status": "rejected",
                    "reason": str(error),
                    "visibleTables": error.visibleTables,
                    "retryable": False,
                    "next": "read_only_schema_review",
                }
            )
        )
        return 1
    except Exception:
        print(json.dumps({"status": "preparation_failed", "retryable": False}))
        return 1
    finally:
        for database in databases:
            database.close()


if __name__ == "__main__":
    raise SystemExit(main())
