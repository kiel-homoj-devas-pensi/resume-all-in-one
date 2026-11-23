"""Read-only by default; explicit local/maintenance migrations and bounded purges."""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import asdict
from datetime import UTC, datetime, timedelta
from pathlib import Path

from agent_gateway.account_retention import (
    CHALLENGE_RETENTION_HOURS,
    SESSION_RETENTION_HOURS,
    THROTTLE_HOURS_FROM_WINDOW_START,
    AccountRetentionWorker,
)
from agent_gateway.account_retention_permissions import validatePurgerPrivileges
from agent_gateway.account_retention_schema import (
    migrateMySqlRetentionSchema,
    migrateSqliteRetentionSchema,
    validateMySqlRetentionSchema,
    validateSqliteRetentionSchema,
)
from agent_gateway.account_storage import (
    AccountSqlDatabase,
    SqliteAccountDatabase,
    UnknownStorageCommitError,
    storedText,
)
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import toUtcText
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig
from agent_gateway.sms_attempt_retention import SMS_DETAIL_RETENTION_DAYS, SmsAttemptSummaryWorker
from agent_gateway.sms_attempt_retention_schema import (
    migrateMySqlSmsSummarySchema,
    migrateSqliteSmsSummarySchema,
    validateMySqlSmsSummarySchema,
    validateSqliteSmsSummarySchema,
)
from agent_gateway.sms_phone_retention import (
    PHONE_DIGEST_CLEARED_MARKER,
    SMS_PHONE_RETENTION_DAYS,
    SmsPhoneRetentionWorker,
)


def configuredDatabase(*, role: str) -> AccountSqlDatabase:
    backend = os.environ.get("GATEWAY_DATABASE_BACKEND", "sqlite")
    if backend == "sqlite":
        value = os.environ.get("AGENT_GATEWAY_TASK018_DATABASE_PATH", "")
        path = Path(value)
        if not path.is_absolute() or not path.is_file() or path.is_symlink():
            raise ValueError("retention_database_required")
        return SqliteAccountDatabase(GatewayDatabase(path))
    if backend != "mysql":
        raise ValueError("retention_database_required")
    dsn = os.environ.get("GATEWAY_DATABASE_DSN")
    ca = os.environ.get("GATEWAY_DATABASE_TLS_CA_FILE")
    expiry = os.environ.get("GATEWAY_DATABASE_EXPIRES_AT_UTC")
    if not dsn or not ca or not expiry:
        raise ValueError("retention_database_required")
    business = MySqlConfig.fromDsn(dsn, Path(ca), expiry)
    if role == "business":
        return MySqlAccountDatabase(business)
    field = (
        "GATEWAY_DATABASE_MIGRATION_DSN"
        if role == "migration"
        else "GATEWAY_DATABASE_RETENTION_DSN"
    )
    privateDsn = os.environ.get(field)
    if not privateDsn:
        raise ValueError("separate_retention_identity_required")
    private = MySqlConfig.fromDsn(privateDsn, Path(ca), expiry)
    if (private.host.lower(), private.port, private.database) != (
        business.host.lower(),
        business.port,
        business.database,
    ) or private.user == business.user:
        raise ValueError("retention_identity_or_target_mismatch")
    return MySqlAccountDatabase(private)


def checkSchema(database: AccountSqlDatabase, *, withSmsSummary: bool = False) -> None:
    if isinstance(database, MySqlAccountDatabase):
        with database.readConnection() as connection:
            (validateMySqlSmsSummarySchema if withSmsSummary else validateMySqlRetentionSchema)(
                connection
            )
    else:
        (validateSqliteSmsSummarySchema if withSmsSummary else validateSqliteRetentionSchema)(
            GatewayDatabase(Path(database.authorityKey[1]))
        )


def _serverIdentity(database: AccountSqlDatabase) -> tuple[str, str]:
    with database.readConnection() as connection:
        row = connection.fetchOne("SELECT @@server_uuid AS server_id,DATABASE() AS database_name")
    if row is None:
        raise ValueError("retention_identity_unavailable")
    return storedText(row["server_id"]), storedText(row["database_name"])


def inspect(database: AccountSqlDatabase) -> dict[str, int]:
    # Counts only; never dump account IDs, phone hashes, evidence or user content.
    with database.readConnection() as connection:
        result = {}
        for field, query in (
            ("inactiveAccounts", "SELECT COUNT(*) AS count FROM accounts WHERE is_active=0"),
            (
                "unknownDeactivationTimes",
                "SELECT COUNT(*) AS count FROM accounts a "
                "LEFT JOIN account_retirements r ON r.account_id=a.account_id "
                "WHERE a.is_active=0 AND r.account_id IS NULL",
            ),
            ("recordedDeactivations", "SELECT COUNT(*) AS count FROM account_retirements"),
            (
                "invalidSessions",
                "SELECT COUNT(*) AS count FROM account_sessions "
                "WHERE expires_at_utc<=? OR revoked_at_utc IS NOT NULL",
            ),
            (
                "invalidChallenges",
                "SELECT COUNT(*) AS count FROM phone_challenges "
                "WHERE expires_at_utc<=? OR consumed_at_utc IS NOT NULL",
            ),
            (
                "dueThrottleBuckets",
                "SELECT COUNT(*) AS count FROM identity_rate_limits WHERE window_start_utc<=?",
            ),
            (
                "dueSmsPhoneDigests",
                "SELECT COUNT(*) AS count FROM sms_send_attempts "
                "WHERE phone_hash<>? AND created_at_utc<=?",
            ),
        ):
            if field in {
                "invalidSessions",
                "invalidChallenges",
                "dueThrottleBuckets",
                "dueSmsPhoneDigests",
            }:
                now = datetime.now(UTC)
                if field == "dueThrottleBuckets":
                    now -= timedelta(hours=THROTTLE_HOURS_FROM_WINDOW_START)
                elif field == "dueSmsPhoneDigests":
                    now -= timedelta(days=SMS_PHONE_RETENTION_DAYS)
                row = connection.fetchOne(
                    query.replace("?", "%s" if database.authorityKey[0] == "mysql" else "?"),
                    (PHONE_DIGEST_CLEARED_MARKER, toUtcText(now))
                    if field == "dueSmsPhoneDigests"
                    else (toUtcText(now),),
                )
            else:
                row = connection.fetchOne(query)
            if row is None or type(row["count"]) is not int:
                raise ValueError("retention_inspection_unavailable")
            result[field] = row["count"]
        return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=(
            "check",
            "migrate",
            "purge",
            "purge-sessions",
            "purge-challenges",
            "purge-throttles",
            "clear-sms-phone-digests",
            "migrate-sms-summary",
            "summarize-sms-attempts",
        ),
    )
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirmed-target", action="store_true")
    parser.add_argument("--confirmed-quiescent", action="store_true")
    parser.add_argument("--maximum-batches", type=int, default=100)
    parser.add_argument("--look-ahead-seconds", type=int, default=0)
    parser.add_argument("--with-sms-summary", action="store_true")
    args = parser.parse_args()
    databases: list[AccountSqlDatabase] = []
    try:
        if not 1 <= args.maximum_batches <= 1000:
            raise ValueError("invalid_retention_scan_bound")
        if not 0 <= args.look_ahead_seconds <= 300 or (
            args.look_ahead_seconds
            and args.action
            not in {
                "purge-sessions",
                "purge-challenges",
                "purge-throttles",
                "clear-sms-phone-digests",
                "summarize-sms-attempts",
            }
        ):
            raise ValueError("invalid_session_retention_bound")
        if args.apply and (args.action == "check" or not args.confirmed_target):
            raise ValueError("explicit_retention_target_required")
        if (
            args.action in {"migrate", "migrate-sms-summary"}
            and args.apply
            and not args.confirmed_quiescent
        ):
            raise ValueError("quiescent_migration_required")
        business = configuredDatabase(role="business")
        databases.append(business)
        withSummary = (
            args.with_sms_summary
            or args.action == "summarize-sms-attempts"
            or (args.action == "migrate-sms-summary" and args.apply)
        )
        if args.action in {"migrate", "migrate-sms-summary"} and args.apply:
            management = configuredDatabase(role="migration")
            databases.append(management)
            if isinstance(management, MySqlAccountDatabase):
                if _serverIdentity(management) != _serverIdentity(business):
                    raise ValueError("retention_server_mismatch")
                (
                    migrateMySqlSmsSummarySchema
                    if args.action == "migrate-sms-summary"
                    else migrateMySqlRetentionSchema
                )(management)
            else:
                (
                    migrateSqliteSmsSummarySchema
                    if args.action == "migrate-sms-summary"
                    else migrateSqliteRetentionSchema
                )(GatewayDatabase(Path(management.authorityKey[1])))
        checkSchema(business, withSmsSummary=withSummary)
        result: dict[str, object] = {
            "status": "schema_verified",
            "writeRequested": args.apply,
            "supplierRequests": 0,
            **inspect(business),
        }
        if withSummary:
            with business.readConnection() as c:
                row = c.fetchOne(
                    (
                        "SELECT COUNT(*) AS count FROM sms_send_attempts "
                        "WHERE outcome IN ('accepted','rejected','unknown','reserved') "
                        "AND created_at_utc<=?"
                    ).replace("?", "%s" if business.authorityKey[0] == "mysql" else "?"),
                    (toUtcText(datetime.now(UTC) - timedelta(days=SMS_DETAIL_RETENTION_DAYS)),),
                )
                if row is None:
                    raise ValueError("sms_summary_inspection_unavailable")
                result["dueSmsAttempts"] = row["count"]
        if (
            args.action
            in {
                "purge",
                "purge-sessions",
                "purge-challenges",
                "purge-throttles",
                "clear-sms-phone-digests",
                "summarize-sms-attempts",
            }
            and args.apply
        ):
            purger = configuredDatabase(role="purger")
            databases.append(purger)
            if purger.authorityKey != business.authorityKey:
                raise ValueError("retention_target_mismatch")
            if isinstance(purger, MySqlAccountDatabase):
                if _serverIdentity(purger) != _serverIdentity(business):
                    raise ValueError("retention_server_mismatch")
                with purger.readConnection() as connection:
                    validatePurgerPrivileges(
                        connection,
                        challengesOnly=args.action == "purge-challenges",
                        throttlesOnly=args.action == "purge-throttles",
                        smsPhoneOnly=args.action == "clear-sms-phone-digests",
                        smsSummaryOnly=args.action == "summarize-sms-attempts",
                    )
            if args.action == "summarize-sms-attempts":
                summaryWorker = SmsAttemptSummaryWorker(purger)
                cursor = ""
                scanned = summarized = invalid = 0
                more = False
                for _ in range(args.maximum_batches):
                    summaryBatch = summaryWorker.summarize(
                        afterAttemptId=cursor, lookAheadSeconds=args.look_ahead_seconds
                    )
                    scanned += summaryBatch.scannedAttempts
                    summarized += summaryBatch.summarizedAttempts
                    invalid += summaryBatch.invalidRecords
                    more = summaryBatch.moreCandidates
                    if summaryBatch.nextAttemptId is None:
                        break
                    cursor = summaryBatch.nextAttemptId
                unfinished = more or invalid != 0
                result.update(
                    status="attention_required" if unfinished else "batch_completed",
                    scannedAttempts=scanned,
                    summarizedAttempts=summarized,
                    invalidRecords=invalid,
                    scanLimitReached=more,
                    detailMaximumNaturalDays=SMS_DETAIL_RETENTION_DAYS,
                    lookAheadSeconds=args.look_ahead_seconds,
                )
                print(json.dumps(result))
                return 3 if unfinished else 0
            if args.action == "clear-sms-phone-digests":
                smsWorker = SmsPhoneRetentionWorker(purger)
                cursor = ""
                scanned = cleared = invalid = 0
                more = False
                for _ in range(args.maximum_batches):
                    smsBatch = smsWorker.clearOldPhoneDigests(
                        afterAttemptId=cursor, lookAheadSeconds=args.look_ahead_seconds
                    )
                    scanned += smsBatch.scannedAttempts
                    cleared += smsBatch.clearedPhoneDigests
                    invalid += smsBatch.invalidRecords
                    more = smsBatch.moreCandidates
                    if smsBatch.nextAttemptId is None:
                        break
                    cursor = smsBatch.nextAttemptId
                unfinished = more or invalid != 0
                result.update(
                    status="attention_required" if unfinished else "batch_completed",
                    scannedAttempts=scanned,
                    clearedPhoneDigests=cleared,
                    invalidRecords=invalid,
                    scanLimitReached=more,
                    phoneDigestMaximumNaturalDays=SMS_PHONE_RETENTION_DAYS,
                    lookAheadSeconds=args.look_ahead_seconds,
                )
                print(json.dumps(result))
                return 3 if unfinished else 0
            worker = AccountRetentionWorker(purger)
            if args.action == "purge-throttles":
                cursor = ""
                scanned = deleted = invalid = 0
                more = False
                for _ in range(args.maximum_batches):
                    throttleBatch = worker.purgeExpiredThrottles(
                        afterBucketHash=cursor, lookAheadSeconds=args.look_ahead_seconds
                    )
                    scanned += throttleBatch.scannedRecords
                    deleted += throttleBatch.deletedRecords
                    invalid += throttleBatch.invalidRecords
                    more = throttleBatch.moreCandidates
                    if throttleBatch.nextRecordId is None:
                        break
                    cursor = throttleBatch.nextRecordId
                unfinished = more or invalid != 0
                result.update(
                    status="attention_required" if unfinished else "batch_completed",
                    scannedThrottleBuckets=scanned,
                    deletedThrottleBuckets=deleted,
                    invalidThrottleRecords=invalid,
                    scanLimitReached=more,
                    maximumHoursFromWindowStart=THROTTLE_HOURS_FROM_WINDOW_START,
                    lookAheadSeconds=args.look_ahead_seconds,
                )
                print(json.dumps(result))
                return 3 if unfinished else 0
            if args.action == "purge-challenges":
                cursor = ""
                scanned = deleted = invalid = 0
                more = False
                for _ in range(args.maximum_batches):
                    challengeBatch = worker.purgeInvalidChallenges(
                        afterChallengeId=cursor, lookAheadSeconds=args.look_ahead_seconds
                    )
                    scanned += challengeBatch.scannedRecords
                    deleted += challengeBatch.deletedRecords
                    invalid += challengeBatch.invalidRecords
                    more = challengeBatch.moreCandidates
                    if challengeBatch.nextRecordId is None:
                        break
                    cursor = challengeBatch.nextRecordId
                unfinished = more or invalid != 0
                result.update(
                    status="attention_required" if unfinished else "batch_completed",
                    scannedChallenges=scanned,
                    deletedChallenges=deleted,
                    invalidChallengeRecords=invalid,
                    scanLimitReached=more,
                    invalidChallengeMaximumHours=CHALLENGE_RETENTION_HOURS,
                    lookAheadSeconds=args.look_ahead_seconds,
                )
                print(json.dumps(result))
                return 3 if unfinished else 0
            if args.action == "purge-sessions":
                cursor = ""
                scanned = deleted = invalid = 0
                more = False
                for _ in range(args.maximum_batches):
                    sessionBatch = worker.purgeInvalidSessions(
                        afterSessionId=cursor, lookAheadSeconds=args.look_ahead_seconds
                    )
                    scanned += sessionBatch.scannedSessions
                    deleted += sessionBatch.deletedSessions
                    invalid += sessionBatch.invalidRecords
                    more = sessionBatch.moreCandidates
                    if sessionBatch.nextSessionId is None:
                        break
                    cursor = sessionBatch.nextSessionId
                unfinished = more or invalid != 0
                result.update(
                    status="attention_required" if unfinished else "batch_completed",
                    scannedSessions=scanned,
                    deletedSessions=deleted,
                    invalidSessionRecords=invalid,
                    scanLimitReached=more,
                    invalidSessionMaximumHours=SESSION_RETENTION_HOURS,
                    lookAheadSeconds=args.look_ahead_seconds,
                )
                print(json.dumps(result))
                return 3 if unfinished else 0
            after = ""
            totals: dict[str, int] = {}
            more = False
            for _ in range(args.maximum_batches):
                batch = worker.runBatch(afterAccountId=after)
                values = asdict(batch)
                for name in (
                    "scannedAccounts",
                    "deletedAccounts",
                    "blockedUnsettledAccounts",
                    "heldAccounts",
                    "unfinishedCloudAccounts",
                    "invalidRecords",
                ):
                    totals[name] = totals.get(name, 0) + int(values[name])
                more = batch.moreCandidates
                if batch.nextAccountId is None:
                    break
                after = batch.nextAccountId
            result.update(totals)
            result["scanLimitReached"] = more
            unfinished = (
                more
                or result["unknownDeactivationTimes"] != 0
                or any(
                    totals[name]
                    for name in (
                        "blockedUnsettledAccounts",
                        "heldAccounts",
                        "unfinishedCloudAccounts",
                        "invalidRecords",
                    )
                )
            )
            result["status"] = "attention_required" if unfinished else "batch_completed"
            print(json.dumps(result))
            return 3 if unfinished else 0
        print(json.dumps(result))
        return 0
    except UnknownStorageCommitError:
        print(
            json.dumps({"status": "outcome_unknown", "retryable": False, "next": "read_only_check"})
        )
        return 2
    except Exception:
        print(json.dumps({"status": "retention_management_failed", "retryable": False}))
        return 1
    finally:
        for database in databases:
            if isinstance(database, MySqlAccountDatabase):
                database.close()


if __name__ == "__main__":
    raise SystemExit(main())
