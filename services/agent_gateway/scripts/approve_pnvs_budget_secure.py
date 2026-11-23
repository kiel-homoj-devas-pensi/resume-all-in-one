"""Explicit PNVS policy approval with private stdin credentials and no supplier calls."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Never
from urllib.parse import quote
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from agent_gateway.account_storage import UnknownStorageCommitError, storedText  # noqa: E402
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig  # noqa: E402
from agent_gateway.pnvs_runtime import PnvsRuntimeSettings, loadPnvsRuntimeSettings  # noqa: E402
from agent_gateway.privilege_schema import validateMySqlPrivilegeSchema  # noqa: E402
from agent_gateway.sms_attempt_retention_schema import validateMySqlSmsSummarySchema  # noqa: E402
from agent_gateway.sms_budget import SmsBudgetLedger  # noqa: E402

BUSINESS_ACCOUNT = "resume_web"
MAINTENANCE_ACCOUNT = "resume_maint"


class UnsupportedMySqlVersionError(RuntimeError):
    pass


def _requireSharedLockVersion(value: object) -> None:
    version = storedText(value)
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-+][A-Za-z0-9._-]+)?", version)
    if (
        match is None
        or any(vendor in version.lower() for vendor in ("mariadb", "tidb"))
        or tuple(int(part) for part in match.group(1, 2, 3)) < (8, 0, 22)
    ):
        raise UnsupportedMySqlVersionError("unsupported_mysql_version")


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        del message
        print(json.dumps({"status": "budget_arguments_invalid", "retryable": False}))
        self.exit(2)


def _uniqueObject(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for name, value in pairs:
        if name in result:
            raise ValueError("budget_input_invalid")
        result[name] = value
    return result


def _localFile(path: Path) -> Path:
    if not path.is_absolute() or not path.is_file():
        raise ValueError("budget_path_invalid")
    if sys.platform == "win32" and re.fullmatch(r"[A-Za-z]:[\\/][^:]*", str(path)) is None:
        raise ValueError("budget_path_invalid")
    if any(
        candidate.is_symlink() or candidate.is_junction() for candidate in (path, *path.parents)
    ):
        raise ValueError("budget_path_invalid")
    return path


def _identity(
    database: MySqlAccountDatabase, account: str, schema: str, *, withSmsSummary: bool = False
) -> tuple[str, str]:
    with database.readConnection() as connection:
        versionRow = connection.fetchOne("SELECT VERSION() AS mysql_version")
        if versionRow is None:
            raise UnsupportedMySqlVersionError("unsupported_mysql_version")
        _requireSharedLockVersion(versionRow["mysql_version"])
        (validateMySqlSmsSummarySchema if withSmsSummary else validateMySqlPrivilegeSchema)(
            connection
        )
        row = connection.fetchOne(
            "SELECT @@server_uuid AS server_uuid, CURRENT_USER() AS identity, "
            "DATABASE() AS database_name"
        )
        if row is None:
            raise ValueError("budget_identity_invalid")
        server, identity, actualSchema = (
            storedText(row[key]) for key in ("server_uuid", "identity", "database_name")
        )
        if identity.split("@", 1)[0] != account or actualSchema != schema:
            raise ValueError("budget_identity_invalid")
        server = str(UUID(server))
        return server, identity


def _status(
    database: MySqlAccountDatabase, runtime: PnvsRuntimeSettings, *, withSmsSummary: bool = False
) -> dict[str, object]:
    policy = runtime.policy
    expired = policy.expiresAtUtc <= datetime.now(UTC)
    base: dict[str, object] = {
        "status": "policy_not_approved",
        "expired": expired,
        "expiresAtUtc": policy.expiresAtUtc.isoformat().replace("+00:00", "Z"),
        "maximumAttempts": policy.maximumAttempts,
        "budgetCents": policy.budgetCents,
        "reservePerAttemptCents": policy.reservePerAttemptCents,
        "attemptsUsed": None,
        "reservedCents": None,
        "attemptsRemaining": None,
        "budgetRemainingCents": None,
    }
    ledger = SmsBudgetLedger(
        database, policy, auditSecret=runtime.auditSecret, withSummary=withSmsSummary
    )
    try:
        ledger.assertApprovedPolicy()
    except ValueError as error:
        if str(error) == "sms_budget_not_approved":
            return base
        raise
    # Public ledger validation above includes fingerprint, policy and aggregate consistency.
    # These counters are a subsequent read snapshot; concurrent valid reservations may advance them.
    with database.readConnection() as connection:
        row = connection.fetchOne(
            "SELECT attempts, reserved_cents FROM sms_send_budget WHERE policy_id = %s", ("pnvs",)
        )
        if row is None:
            raise ValueError("budget_snapshot_invalid")
        count, cents = int(str(row["attempts"])), int(str(row["reserved_cents"]))
        if not 0 <= count <= policy.maximumAttempts or not 0 <= cents <= policy.budgetCents:
            raise ValueError("budget_snapshot_invalid")
    base.update(
        status="approved_policy_verified",
        attemptsUsed=count,
        reservedCents=cents,
        attemptsRemaining=policy.maximumAttempts - count,
        budgetRemainingCents=policy.budgetCents - cents,
    )
    return base


def main(arguments: list[str] | None = None) -> int:
    parser = _Parser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=3306)
    parser.add_argument("--database", required=True)
    parser.add_argument("--ca-file", type=Path, required=True)
    parser.add_argument("--expires-at-utc", required=True)
    parser.add_argument("--encrypted-runtime-path", type=Path, required=True)
    parser.add_argument("--apply-approved-budget", action="store_true")
    parser.add_argument("--confirmed-policy-approval", action="store_true")
    parser.add_argument("--with-sms-summary", action="store_true")
    args = parser.parse_args(arguments)
    databases: list[MySqlAccountDatabase] = []
    passwords: dict[str, str] = {}
    common: dict[str, object] = {
        "writeRequested": args.apply_approved_budget,
        "smsRequests": 0,
        "modelRequests": 0,
        "accessKeyRead": False,
        "retryable": False,
    }
    try:
        if (
            args.apply_approved_budget != args.confirmed_policy_approval
            or re.fullmatch(r"[A-Za-z0-9.-]{1,253}", args.host) is None
            or not 1 <= args.port <= 65535
            or re.fullmatch(r"[A-Za-z0-9_]{1,64}", args.database) is None
            or re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", args.expires_at_utc) is None
            or sys.stdin.isatty()
        ):
            raise ValueError("budget_input_invalid")
        ca = _localFile(args.ca_file)
        runtime = loadPnvsRuntimeSettings(_localFile(args.encrypted_runtime_path))
        raw = sys.stdin.read(65_537)
        if len(raw) > 65_536:
            raise ValueError("budget_input_invalid")
        payload = json.loads(raw, object_pairs_hook=_uniqueObject)
        raw = ""
        required = (
            {BUSINESS_ACCOUNT, MAINTENANCE_ACCOUNT}
            if args.apply_approved_budget
            else {BUSINESS_ACCOUNT}
        )
        if (
            not isinstance(payload, dict)
            or set(payload) != required
            or any(
                not isinstance(value, str) or not 1 <= len(value) <= 4096
                for value in payload.values()
            )
        ):
            raise ValueError("budget_input_invalid")
        passwords = payload

        def config(account: str) -> MySqlConfig:
            return MySqlConfig.fromDsn(
                f"mysql://{quote(account, safe='')}:{quote(passwords[account], safe='')}"
                f"@{args.host}:{args.port}/{args.database}",
                ca,
                args.expires_at_utc,
            )

        businessConfig = config(BUSINESS_ACCOUNT)
        business = MySqlAccountDatabase(businessConfig)
        databases.append(business)
        businessIdentity = _identity(
            business, BUSINESS_ACCOUNT, args.database, withSmsSummary=args.with_sms_summary
        )
        if args.apply_approved_budget:
            maintenance = MySqlAccountDatabase(config(MAINTENANCE_ACCOUNT))
            databases.append(maintenance)
            maintenanceIdentity = _identity(
                maintenance,
                MAINTENANCE_ACCOUNT,
                args.database,
                withSmsSummary=args.with_sms_summary,
            )
            if (
                business.authorityKey != maintenance.authorityKey
                or businessIdentity[0] != maintenanceIdentity[0]
                or businessIdentity[1] == maintenanceIdentity[1]
            ):
                raise ValueError("budget_identity_mismatch")
            # Existing domain approval cannot refill a matching policy or replace a mismatch.
            business.close()
            SmsBudgetLedger(
                maintenance,
                runtime.policy,
                auditSecret=runtime.auditSecret,
                withSummary=args.with_sms_summary,
            ).createApprovedPolicy()
            maintenance.close()
            business = MySqlAccountDatabase(businessConfig)
            databases.append(business)
            if (
                _identity(
                    business, BUSINESS_ACCOUNT, args.database, withSmsSummary=args.with_sms_summary
                )
                != businessIdentity
            ):
                raise ValueError("budget_fresh_identity_mismatch")
        status = _status(business, runtime, withSmsSummary=args.with_sms_summary)
        print(json.dumps({**common, **status}))
        return 0 if status["status"] == "approved_policy_verified" else 1
    except UnknownStorageCommitError:
        print(json.dumps({**common, "status": "outcome_unknown", "next": "read_only_check"}))
        return 2
    except UnsupportedMySqlVersionError:
        print(
            json.dumps({**common, "status": "unsupported_mysql_version", "next": "read_only_check"})
        )
        return 1
    except Exception:
        print(json.dumps({**common, "status": "budget_check_failed", "next": "read_only_check"}))
        return 1
    finally:
        passwords.clear()
        for database in databases:
            try:
                database.close()
            except Exception:  # noqa: S110 — never log a credential-bearing driver exception.
                pass


if __name__ == "__main__":
    raise SystemExit(main())
