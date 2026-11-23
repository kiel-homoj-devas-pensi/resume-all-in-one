"""Read-only local open-test plan. No cloud, SQL, balance query or supplier call."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from agent_gateway.identity import toUtcText
from agent_gateway.open_test import loadOpenTestPolicy


def privilegeSql(database: str, webUser: str, webHost: str) -> str:
    if any(
        re.fullmatch(r"[A-Za-z0-9_.:%-]{1,64}", part) is None
        for part in (database, webUser, webHost)
    ):
        raise ValueError("invalid_open_test_sql_identifiers")
    return (
        "GRANT UPDATE (maximum_attempts,budget_cents) "
        f"ON `{database}`.`sms_send_budget` TO '{webUser}'@'{webHost}';"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--database", default="resume_aio")
    parser.add_argument("--web-user", default="resume_web")
    parser.add_argument("--web-host", default="%")
    options = parser.parse_args()
    try:
        policy = loadOpenTestPolicy(options.policy)
        print(
            json.dumps(
                {
                    "status": "local_plan_only",
                    "enabled": policy.enabled,
                    "activeNow": policy.isActive(),
                    "enabledUntilUtc": (
                        None
                        if policy.enabledUntilUtc is None
                        else toUtcText(policy.enabledUntilUtc)
                    ),
                    "scope": "registered_and_guest",
                    "userCandidateLimit": None,
                    "modelDispatchLimit": None,
                    "smsAttemptLimit": None,
                    "supplierBalanceVerified": False,
                    "supplierRequests": 0,
                    "databaseWrites": 0,
                    "grantSqlForOwnerReview": privilegeSql(
                        options.database, options.web_user, options.web_host
                    ),
                },
                ensure_ascii=True,
            )
        )
        return 0
    except Exception:
        print('{"status":"open_test_plan_failed","supplierRequests":0,"databaseWrites":0}')
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
