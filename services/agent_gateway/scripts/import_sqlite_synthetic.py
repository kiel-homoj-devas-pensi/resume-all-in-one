"""显式演练 SQLite v4/v5→对应 MySQL v3/v4；默认只读，不发送短信或调用模型。"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from agent_gateway.account_storage import (
    AccountAlreadyExistsError,
    StorageUnavailableError,
    UnknownStorageCommitError,
)
from agent_gateway.database import UnsupportedDatabaseSchemaError
from agent_gateway.mysql_lifecycle_schema import validateLifecycleSchema
from agent_gateway.mysql_sms_schema import validateSmsSchema
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig
from agent_gateway.synthetic_import import importSyntheticSnapshot, loadSyntheticSnapshot


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--synthetic-only", action="store_true", required=True)
    parser.add_argument(
        "--source", type=Path, required=True, help="仅指定自己准备的合成 SQLite v4/v5"
    )
    parser.add_argument("--apply", action="store_true", help="显式执行，否则默认只读 dry-run")
    parser.add_argument(
        "--confirmed-quiescent", action="store_true", help="确认源/目标业务写入已停止"
    )
    parser.add_argument(
        "--confirmed-otp-secret-preserved",
        action="store_true",
        help="确认源/目标使用相同验证码摘要密钥；不要求输出密钥",
    )
    args = parser.parse_args()
    database: MySqlAccountDatabase | None = None
    try:
        names = (
            "GATEWAY_DATABASE_DSN",
            "GATEWAY_DATABASE_TLS_CA_FILE",
            "GATEWAY_DATABASE_EXPIRES_AT_UTC",
        )
        values = [os.environ.get(name) for name in names]
        if not any(values):
            print("SKIP: 未配置专用 MySQL 合成目标；未读取源文件、未迁移")
            return 0
        dsn, ca, expiry = values
        if not dsn or not ca or not expiry or os.environ.get("GATEWAY_DATABASE_BACKEND") != "mysql":
            raise ValueError("合成导入需要完整后端、DSN、TLS 与到期配置")
        config = MySqlConfig.fromDsn(dsn, Path(ca), expiry)
        if not config.database.startswith("resume_gateway_synthetic"):
            raise ValueError("只接受专用合成目标库")
        if args.apply:
            if not (args.confirmed_quiescent and args.confirmed_otp_secret_preserved):
                raise ValueError("导入需要停写和验证码密钥保留确认")
            migrationDsn = os.environ.get("GATEWAY_DATABASE_MIGRATION_DSN")
            if not migrationDsn:
                raise ValueError("应用导入需要独立迁移身份")
            writer = MySqlConfig.fromDsn(
                migrationDsn, config.caFile, expiry
            )
            if (writer.host, writer.port, writer.database) != (
                config.host,
                config.port,
                config.database,
            ) or writer.user == config.user:
                raise ValueError("迁移身份必须不同且目标一致")
            config = writer
        snapshot = loadSyntheticSnapshot(args.source)
        database = MySqlAccountDatabase(config)
        with database.readConnection() as connection:
            if snapshot.sourceVersion == 5:
                validateSmsSchema(connection)
            else:
                validateLifecycleSchema(connection)
        report = importSyntheticSnapshot(
            database,
            snapshot,
            apply=args.apply,
            confirmedQuiescent=args.confirmed_quiescent,
            confirmedOtpSecretPreserved=args.confirmed_otp_secret_preserved,
        )
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
        print("仅合成演练；未发送短信/模型请求；真实数据迁移与云实例验收未执行")
        return 0
    except UnknownStorageCommitError:
        print("UNKNOWN: 提交结果未知；保留源和目标，先用相同源执行只读 dry-run 核对，禁止自动重试")
        return 2
    except (
        ValueError,
        StorageUnavailableError,
        AccountAlreadyExistsError,
        UnsupportedDatabaseSchemaError,
    ):
        print("FAIL: 合成源、配置、结构、权限或目标核对未通过；未清表、无回退、未自动重试")
        return 1
    finally:
        if database is not None:
            database.close()


if __name__ == "__main__":
    raise SystemExit(main())
