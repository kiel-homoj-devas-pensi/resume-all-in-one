"""Read-only by default. Maintain guest credentials while preserving history and quotas."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from agent_gateway.guest_identity import (
    GUEST_INSTALLATION_IDLE_DAYS,
    GUEST_ISSUANCE_RETENTION_HOURS,
)
from agent_gateway.guest_session_retention import (
    GUEST_TOKEN_RETENTION_HOURS,
    GuestSessionRetentionWorker,
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=("check", "clear-expired", "clear-idle-installations", "purge-expired-issuance"),
        nargs="?",
        default="check",
    )
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirmed-target", action="store_true")
    parser.add_argument("--maximum-batches", type=int, default=100)
    parser.add_argument("--look-ahead-seconds", type=int, default=0)
    args = parser.parse_args()
    try:
        if (
            not 1 <= args.maximum_batches <= 1000
            or not 0 <= args.look_ahead_seconds <= 300
            or (args.apply and (args.action == "check" or not args.confirmed_target))
            or (
                args.look_ahead_seconds
                and args.action not in {"clear-expired", "purge-expired-issuance"}
            )
        ):
            raise ValueError("explicit_guest_retention_target_required")
        worker = GuestSessionRetentionWorker(args.database)
        result: dict[str, object] = {
            "status": "schema_verified",
            "writeRequested": args.apply,
            **worker.inspect(),
        }
        if not args.apply:
            if result["inconsistentSessionPairs"] != 0:
                result["status"] = "attention_required"
            print(json.dumps(result))
            return 3 if result["status"] == "attention_required" else 0
        cursor = ""
        scanned = cleared = invalid = 0
        more = False
        if args.action == "purge-expired-issuance":
            for _ in range(args.maximum_batches):
                issuanceBatch = worker.purgeExpiredIssuance(
                    afterBucket=cursor, lookAheadSeconds=args.look_ahead_seconds
                )
                scanned += issuanceBatch.scannedBuckets
                cleared += issuanceBatch.purgedBuckets
                invalid += issuanceBatch.invalidRecords
                more = issuanceBatch.moreCandidates
                if issuanceBatch.nextBucket is None:
                    break
                cursor = issuanceBatch.nextBucket
            unfinished = more or invalid != 0 or result["inconsistentSessionPairs"] != 0
            result.update(
                status="attention_required" if unfinished else "batch_completed",
                scannedIssuanceBuckets=scanned,
                purgedIssuanceBuckets=cleared,
                invalidRecords=invalid,
                scanLimitReached=more,
                maximumHoursAfterWindowEnd=GUEST_ISSUANCE_RETENTION_HOURS,
                lookAheadSeconds=args.look_ahead_seconds,
                supplierRequests=0,
            )
            print(json.dumps(result))
            return 3 if unfinished else 0
        if args.action == "clear-idle-installations":
            for _ in range(args.maximum_batches):
                installationBatch = worker.clearIdleInstallations(afterGuestId=cursor)
                scanned += installationBatch.scannedInstallations
                cleared += installationBatch.clearedInstallations
                invalid += installationBatch.invalidRecords
                more = installationBatch.moreCandidates
                if installationBatch.nextGuestId is None:
                    break
                cursor = installationBatch.nextGuestId
            unfinished = more or invalid != 0 or result["inconsistentSessionPairs"] != 0
            result.update(
                status="attention_required" if unfinished else "batch_completed",
                scannedInstallations=scanned,
                clearedInstallations=cleared,
                invalidRecords=invalid,
                scanLimitReached=more,
                idleNaturalDays=GUEST_INSTALLATION_IDLE_DAYS,
                supplierRequests=0,
            )
            print(json.dumps(result))
            return 3 if unfinished else 0
        for _ in range(args.maximum_batches):
            batch = worker.clearExpiredSessions(
                afterGuestId=cursor, lookAheadSeconds=args.look_ahead_seconds
            )
            scanned += batch.scannedSessions
            cleared += batch.clearedSessions
            invalid += batch.invalidRecords
            more = batch.moreCandidates
            if batch.nextGuestId is None:
                break
            cursor = batch.nextGuestId
        unfinished = more or invalid != 0 or result["inconsistentSessionPairs"] != 0
        result.update(
            status="attention_required" if unfinished else "batch_completed",
            scannedSessions=scanned,
            clearedSessions=cleared,
            invalidRecords=invalid,
            scanLimitReached=more,
            maximumHoursAfterExpiry=GUEST_TOKEN_RETENTION_HOURS,
            lookAheadSeconds=args.look_ahead_seconds,
            supplierRequests=0,
        )
        print(json.dumps(result))
        return 3 if unfinished else 0
    except Exception:
        # No IDs, installation/token hashes, database paths or user content in errors.
        print(json.dumps({"status": "guest_session_retention_failed", "retryable": False}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
