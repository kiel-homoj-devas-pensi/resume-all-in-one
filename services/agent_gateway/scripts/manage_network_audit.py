"""Inspect existing private audit storage; explicit target required for any write."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Never

from agent_gateway.network_audit import AUDIT_RETENTION_MONTHS, NetworkAuditStore


class _SafeParser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        del message
        self.exit(2, "network_audit_arguments_invalid\n")


def main() -> int:
    parser = _SafeParser(description=__doc__)
    parser.add_argument("action", choices=("check", "purge", "hold"), nargs="?", default="check")
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirmed-target", action="store_true")
    parser.add_argument("--maximum-batches", type=int, default=100)
    parser.add_argument("--event-id", type=int)
    parser.add_argument("--hold-until-utc")
    parser.add_argument("--hold-reference-sha256")
    args = parser.parse_args()
    try:
        holdValues = (args.event_id, args.hold_until_utc, args.hold_reference_sha256)
        if (
            not 1 <= args.maximum_batches <= 1000
            or (args.apply and (args.action == "check" or not args.confirmed_target))
            or (args.action == "hold" and any(value is None for value in holdValues))
            or (args.action != "hold" and any(value is not None for value in holdValues))
        ):
            raise ValueError("explicit_audit_target_required")
        store = NetworkAuditStore(args.database)
        result: dict[str, object] = {
            "status": "schema_verified",
            "writeRequested": args.apply,
            "retentionCalendarMonths": AUDIT_RETENTION_MONTHS,
            **store.inspect(),
        }
        if not args.apply:
            print(json.dumps(result))
            return 0
        if args.action == "hold":
            store.hold(args.event_id, args.hold_until_utc, args.hold_reference_sha256)
            result.update(status="hold_recorded", **store.inspect())
        else:
            removed = invalid = 0
            more = False
            for _ in range(args.maximum_batches):
                batch = store.purge()
                removed += int(batch["removedEvents"])
                invalid += int(batch["invalidRecords"])
                more = bool(batch["moreCandidates"])
                if invalid or not more:
                    break
            result.update(
                status="attention_required" if invalid or more else "batch_completed",
                removedEvents=removed,
                invalidRecords=invalid,
                scanLimitReached=more,
            )
        print(json.dumps(result))
        return 3 if result["status"] == "attention_required" else 0
    except Exception:
        print(json.dumps({"status": "network_audit_operation_failed", "retryable": False}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
