from __future__ import annotations

import argparse
import json
import os
from datetime import UTC, datetime
from pathlib import Path

from agent_gateway.account_storage import (
    AccountSqlDatabase,
    SqliteAccountDatabase,
    UnknownStorageCommitError,
)
from agent_gateway.database import GatewayDatabase
from agent_gateway.mysql_sms_schema import validateSmsSchema
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig
from agent_gateway.pnvs_runtime import loadPnvsRuntimeSettings
from agent_gateway.privilege_schema import (
    validateMySqlPrivilegeSchema,
    validateSqlitePrivilegeSchema,
)
from agent_gateway.sms_attempt_retention_schema import (
    validateMySqlSmsSummarySchema,
    validateSqliteSmsSummarySchema,
)
from agent_gateway.sms_budget import SmsBudgetLedger


def _database(apply: bool, *, withSmsSummary: bool = False) -> AccountSqlDatabase:
    configuredPrivileges = (
        os.environ.get("AGENT_GATEWAY_ENABLE_ACCOUNT_PRIVILEGES", "false").strip().lower()
    )
    if configuredPrivileges not in {"false", "true"}:
        raise ValueError("invalid_account_privileges_flag")
    withPrivileges = configuredPrivileges == "true"
    backend = os.environ.get("GATEWAY_DATABASE_BACKEND", "sqlite")
    if backend == "sqlite":
        configuredPath = os.environ.get("AGENT_GATEWAY_TASK018_DATABASE_PATH")
        if not configuredPath:
            raise ValueError("sms_budget_storage_not_configured")
        sqliteDatabase = GatewayDatabase(Path(configuredPath))
        if withSmsSummary:
            validateSqliteSmsSummarySchema(sqliteDatabase)
        elif withPrivileges:
            validateSqlitePrivilegeSchema(sqliteDatabase)
        else:
            sqliteDatabase.checkSchema()
        return SqliteAccountDatabase(sqliteDatabase)
    if backend != "mysql":
        raise ValueError("sms_budget_storage_not_configured")
    businessDsn = os.environ.get("GATEWAY_DATABASE_DSN")
    ca = os.environ.get("GATEWAY_DATABASE_TLS_CA_FILE")
    expiry = os.environ.get("GATEWAY_DATABASE_EXPIRES_AT_UTC")
    if not businessDsn or not ca or not expiry:
        raise ValueError("sms_budget_storage_not_configured")
    config = MySqlConfig.fromDsn(businessDsn, Path(ca), expiry)
    if apply:
        approvalDsn = os.environ.get("GATEWAY_DATABASE_MIGRATION_DSN")
        if not approvalDsn:
            raise ValueError("sms_budget_approval_identity_required")
        approver = MySqlConfig.fromDsn(approvalDsn, Path(ca), expiry)
        if (approver.host.lower(), approver.port, approver.database) != (
            config.host.lower(),
            config.port,
            config.database,
        ) or approver.user == config.user:
            raise ValueError("sms_budget_approval_target_or_identity_mismatch")
        config = approver
    mysqlDatabase = MySqlAccountDatabase(config)
    try:
        # 默认完整 v4，权益开关显式选择完整 v6；没有 DDL 或缺失结构回退。
        with mysqlDatabase.readConnection() as connection:
            if withSmsSummary:
                validateMySqlSmsSummarySchema(connection)
            elif withPrivileges:
                validateMySqlPrivilegeSchema(connection)
            else:
                validateSmsSchema(connection)
        return mysqlDatabase
    except Exception:
        mysqlDatabase.close()
        raise


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "默认核对 PNVS 预算；显式管理身份首次建立已批准政策，不读 AccessKey、不发短信。"
        )
    )
    parser.add_argument("--encrypted-runtime-path", type=Path, required=True)
    parser.add_argument("--apply-approved-budget", action="store_true")
    parser.add_argument("--with-sms-summary", action="store_true")
    args = parser.parse_args()
    database: AccountSqlDatabase | None = None
    try:
        database = _database(args.apply_approved_budget, withSmsSummary=args.with_sms_summary)
        runtime = loadPnvsRuntimeSettings(args.encrypted_runtime_path)
        ledger = SmsBudgetLedger(
            database,
            runtime.policy,
            auditSecret=runtime.auditSecret,
            withSummary=args.with_sms_summary,
        )
        if args.apply_approved_budget:
            ledger.createApprovedPolicy()
        else:
            ledger.assertApprovedPolicy()
        print(
            json.dumps(
                {
                    "status": "approved_policy_verified",
                    "writeRequested": args.apply_approved_budget,
                    "smsRequests": 0,
                    "accessKeyRead": False,
                    "expired": runtime.policy.expiresAtUtc <= datetime.now(UTC),
                }
            )
        )
        return 0
    except UnknownStorageCommitError:
        print(
            json.dumps({"status": "outcome_unknown", "retryable": False, "next": "read_only_check"})
        )
        return 2
    except Exception:
        # 配置/解密/数据库异常均可能携带敏感上下文，只返回固定状态。
        print(json.dumps({"status": "check_failed", "retryable": False}))
        return 1
    finally:
        if isinstance(database, MySqlAccountDatabase):
            database.close()


if __name__ == "__main__":
    raise SystemExit(main())
