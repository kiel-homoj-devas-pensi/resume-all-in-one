from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Never

from agent_gateway.runtime_backup_retention import (
    RuntimeBackupError,
    cleanupManagedBackups,
    createManagedBackup,
    initializeRoot,
    reportDictionary,
)


class _SafeParser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        del message
        raise RuntimeBackupError("backup_arguments_invalid")


def main() -> int:
    parser = _SafeParser(description="显式受管运行库备份：7自然日清理；不扫描旧备份、不恢复数据。")
    parser.add_argument("action", choices=("initialize", "create", "cleanup"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--source")
    parser.add_argument("--role", choices=("trial", "guest", "results"))
    parser.add_argument("--look-ahead-seconds", type=int, default=0)
    parser.add_argument("--timeout-seconds", type=float, default=60.0)
    parser.add_argument("--apply", action="store_true")
    try:
        args = parser.parse_args()
        root = Path(args.root)
        if args.action in {"initialize", "create"} and not args.apply:
            raise RuntimeBackupError("backup_apply_required")
        if args.action == "initialize":
            initializeRoot(root)
            print(json.dumps({"status": "backup_root_initialized"}))
            return 0
        if args.action == "create":
            if not args.source or not args.role:
                raise RuntimeBackupError("backup_arguments_invalid")
            result = createManagedBackup(
                root, Path(args.source), role=args.role, timeoutSeconds=args.timeout_seconds
            )
            print(json.dumps({"status": "backup_verified", **reportDictionary(result)}))
            return 0
        report = cleanupManagedBackups(
            root, apply=args.apply, lookAheadSeconds=args.look_ahead_seconds
        )
        print(json.dumps({"status": "backup_cleanup_report", **reportDictionary(report)}))
        return int(report.failures > 0 or report.overdue > 0)
    except RuntimeBackupError as error:
        print(json.dumps({"status": str(error), "retryable": False}))
    except KeyboardInterrupt:
        print(json.dumps({"status": "backup_cancelled", "retryable": False}))
    except Exception:
        print(json.dumps({"status": "backup_failed", "retryable": False}))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
