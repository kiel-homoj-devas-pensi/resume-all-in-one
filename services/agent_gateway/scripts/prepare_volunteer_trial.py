"""Read-only SMS policy planning, then explicit local model-ledger provisioning.

Run as the original protected service user. SQL is reviewed/executed separately
using an authorized maintenance identity; this command never writes RDS policy.
"""

from __future__ import annotations

import argparse
import json
import re
from collections.abc import Sequence
from pathlib import Path

from agent_gateway.identity import toUtcText
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig
from agent_gateway.pnvs_runtime import loadPnvsRuntimeSettings
from agent_gateway.protected_startup import loadStartupSettings
from agent_gateway.remote_result_cache import verifyWindowsResultDirectory
from agent_gateway.sms_budget import SmsBudgetLedger, SmsBudgetPolicy
from agent_gateway.volunteer_trial import TrialModelBudget, loadVolunteerTrialPolicy


def replacementSql(
    old: dict[str, str | int], newPolicy: SmsBudgetPolicy, newFingerprint: str
) -> str:
    """Guard the exact prior policy and counters; retain all sends and reservations."""
    for value in (old["policyFingerprint"], newFingerprint):
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
            raise ValueError("invalid_policy_fingerprint")
    if (
        not isinstance(old["expiresAtUtc"], str)
        or re.fullmatch(r"[0-9-]{10}T[0-9:.]{15}Z", old["expiresAtUtc"]) is None
    ):
        raise ValueError("invalid_prior_policy_expiry")
    for key in (
        "maximumAttempts",
        "budgetCents",
        "reservePerAttemptCents",
        "attempts",
        "reservedCents",
    ):
        if type(old[key]) is not int or int(old[key]) < 0:
            raise ValueError("invalid_prior_policy_counters")
    if (
        int(old["attempts"]) > newPolicy.maximumAttempts
        or int(old["reservedCents"]) > newPolicy.budgetCents
        or old["reservePerAttemptCents"] != newPolicy.reservePerAttemptCents
    ):
        raise ValueError("cannot_discard_existing_reservations")
    return (
        "UPDATE sms_send_budget SET "  # noqa: S608 - all values validated above; offline review SQL
        f"policy_fingerprint='{newFingerprint}', maximum_attempts={newPolicy.maximumAttempts}, "
        f"budget_cents={newPolicy.budgetCents}, "
        f"reserve_per_attempt_cents={newPolicy.reservePerAttemptCents}, "
        f"expires_at_utc='{toUtcText(newPolicy.expiresAtUtc)}' "
        "WHERE policy_id='pnvs' "
        f"AND policy_fingerprint='{old['policyFingerprint']}' "
        f"AND maximum_attempts={old['maximumAttempts']} AND budget_cents={old['budgetCents']} "
        f"AND reserve_per_attempt_cents={old['reservePerAttemptCents']} "
        f"AND expires_at_utc='{old['expiresAtUtc']}' "
        f"AND attempts={old['attempts']} AND reserved_cents={old['reservedCents']};"
    )


def main(arguments: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", type=Path, required=True)
    parser.add_argument("--action", choices=("plan", "provision", "verify"), required=True)
    options = parser.parse_args(arguments)
    database: MySqlAccountDatabase | None = None
    stage = "local_configuration"
    try:
        settings = loadStartupSettings(options.configuration)
        directory = options.configuration.parent.parent / "volunteer-trial"
        verifyWindowsResultDirectory(directory)
        policy = loadVolunteerTrialPolicy(directory / "policy.json")
        if settings.pnvsRuntimePath is None or settings.databaseDsn is None:
            raise ValueError("missing_protected_configuration")
        if settings.databaseTlsCaFile is None or settings.databaseExpiresAtUtc is None:
            raise ValueError("missing_tls_configuration")
        runtime = loadPnvsRuntimeSettings(settings.pnvsRuntimePath)
        config = MySqlConfig.fromDsn(
            settings.databaseDsn, settings.databaseTlsCaFile, settings.databaseExpiresAtUtc
        )
        database = MySqlAccountDatabase(config)
        stage = "read_sms_policy"
        target = SmsBudgetLedger(database, policy.smsPolicy(), auditSecret=runtime.auditSecret)
        receipt: dict[str, object] = {
            "action": options.action,
            "smsRequests": 0,
            "modelRequests": 0,
            "rdsWrites": 0,
            "credentialsExported": False,
        }
        if options.action == "plan":
            current = SmsBudgetLedger(database, runtime.policy, auditSecret=runtime.auditSecret)
            old = current.approvedPolicySnapshot()
            receipt.update(
                status="review_required",
                priorPolicy=old,
                sql=replacementSql(old, policy.smsPolicy(), target.policyFingerprint),
            )
        else:
            # Provision only after the separately authorized guarded SQL succeeded.
            receipt["smsPolicy"] = target.approvedPolicySnapshot()
            stage = "local_model_ledger"
            ledger = TrialModelBudget(
                directory / "model-dispatches.sqlite3",
                policy,
                initialize=options.action == "provision",
            )
            receipt.update(status="verified", modelBudget=ledger.snapshot())
        print(json.dumps(receipt, ensure_ascii=True))
        return 0
    except Exception:
        # SDK/DPAPI/DSN exceptions must never be printed, even with a traceback.
        print(
            json.dumps({"status": "trial_maintenance_failed", "stage": stage, "retryable": False})
        )
        return 1
    finally:
        if database is not None:
            database.close()


if __name__ == "__main__":
    raise SystemExit(main())
