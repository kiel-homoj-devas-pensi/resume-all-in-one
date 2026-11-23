from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Literal, Never, cast

from agent_gateway.sqlite_backup import SqliteBackupError, backupSqlite


class _SafeParser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        del message
        raise SqliteBackupError("backup_arguments_invalid")


def main() -> int:
    parser = _SafeParser(
        description="显式备份既有 SQLite v7/v9/v10/v11；不恢复、不迁移、不重置预算。"
    )
    parser.add_argument("--destination", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=60.0)
    parser.add_argument(
        "--schema-version",
        type=int,
        choices=(7, 9, 10, 11),
        default=7,
        help="默认旧v7；账号留存9、原短信汇总10、含未确定汇总11；不猜测或迁移。",
    )
    parser.add_argument("--apply", action="store_true")
    try:
        args = parser.parse_args()
        source = os.environ.get("AGENT_GATEWAY_TASK018_DATABASE_PATH")
        if os.environ.get("GATEWAY_DATABASE_BACKEND", "sqlite") != "sqlite" or not source:
            raise SqliteBackupError("backup_source_unavailable")
        if not args.apply:
            raise SqliteBackupError("backup_apply_required")
        result = backupSqlite(
            Path(source),
            Path(args.destination),
            timeoutSeconds=args.timeout_seconds,
            schemaVersion=cast(Literal[7, 9, 10, 11], args.schema_version),
        )
    except SqliteBackupError as error:
        print(json.dumps({"status": str(error), "retryable": False}))
        return 1
    except KeyboardInterrupt:
        print(json.dumps({"status": "backup_cancelled", "retryable": False}))
        return 1
    except Exception:
        print(json.dumps({"status": "backup_failed", "retryable": False}))
        return 1
    print(
        json.dumps(
            {"status": "backup_verified", "sha256": result.sha256, "sizeBytes": result.sizeBytes}
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
