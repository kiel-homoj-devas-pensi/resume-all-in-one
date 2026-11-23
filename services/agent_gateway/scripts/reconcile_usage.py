"""受控主机上的管理员处置入口。证据核验由操作者负责，不提供公网处置 API。"""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
from pathlib import Path
from typing import Literal

from pydantic import Field

from agent_gateway.account_retention_schema import validateSqliteRetentionSchema
from agent_gateway.contracts import StrictGatewayModel
from agent_gateway.database import GatewayDatabase
from agent_gateway.privilege_schema import validateSqlitePrivilegeSchema
from agent_gateway.sms_attempt_retention_schema import validateSqliteSmsSummarySchema
from agent_gateway.usage import UsagePolicyService


class VerifiedEvidence(StrictGatewayModel):
    operationId: str = Field(min_length=1, max_length=256)
    evidenceKind: Literal["executed", "notExecuted"]
    providerReference: str = Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
    promptVersion: str | None = Field(default=None, max_length=128)
    inputTokens: int | None = Field(default=None, ge=0)
    outputTokens: int | None = Field(default=None, ge=0)


def main() -> int:
    parser = argparse.ArgumentParser(description="用已人工核对的 Provider 凭证终结待对账用量")
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--schema-version", type=int, choices=(5, 7, 9, 10, 11), default=5)
    parser.add_argument("--operator", required=True)
    parser.add_argument("--verified-evidence", type=Path, required=True)
    parser.add_argument("--confirm-verified", action="store_true")
    args = parser.parse_args()
    if not args.confirm_verified:
        parser.error("需要先核对 Provider 凭证与原 operation 的对应关系，再明确确认")
    if not args.database.is_file() or args.verified_evidence.stat().st_size > 4096:
        parser.error("数据库必须已存在且证据必须为有界元数据")
    evidenceBytes = args.verified_evidence.read_bytes()
    evidence = VerifiedEvidence.model_validate(json.loads(evidenceBytes))
    database = GatewayDatabase(args.database)
    # This maintenance action must never create or migrate a database. Explicit
    # versions preserve old installations without accepting a newer shape as old.
    if args.schema_version == 5:
        database.checkSchema()
    elif args.schema_version == 7:
        validateSqlitePrivilegeSchema(database)
    elif args.schema_version == 9:
        validateSqliteRetentionSchema(database)
    else:
        validateSqliteSmsSummarySchema(database, withUnresolved=args.schema_version == 11)
    operation = UsagePolicyService(database).reconcileUsage(
        operationId=evidence.operationId,
        operatorId=args.operator,
        evidenceSha256=hashlib.sha256(evidenceBytes).hexdigest(),
        evidenceKind=evidence.evidenceKind,
        promptVersion=evidence.promptVersion,
        inputTokens=evidence.inputTokens,
        outputTokens=evidence.outputTokens,
    )
    print(f"reconciliation status={operation.status.value}")
    return 0


if __name__ == "__main__":
    try:
        exitCode = main()
    except OSError, ValueError, RuntimeError, sqlite3.Error:
        # 校验器的异常可能携带输入值；管理入口也不能把证据正文打印进日志。
        print("reconciliation failed: 核对证据格式、原操作状态及数据库权限；未确认完成")
        exitCode = 2
    raise SystemExit(exitCode)
