"""Explicit server-side open access; independent of supplier renewal and balances."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .account_storage import AccountSqlConnection, storedText
from .identity import requireUtc


@dataclass(frozen=True, slots=True)
class OpenTestPolicy:
    enabled: bool = False
    # Only legacy, explicitly bounded policy files carry an end date.
    enabledUntilUtc: datetime | None = None

    def __post_init__(self) -> None:
        if type(self.enabled) is not bool:
            raise ValueError("invalid_open_test_enabled")
        if self.enabledUntilUtc is not None:
            requireUtc(self.enabledUntilUtc)

    def isActive(self, nowUtc: datetime | None = None) -> bool:
        now = requireUtc(nowUtc or datetime.now(UTC))
        return self.enabled and (self.enabledUntilUtc is None or now < self.enabledUntilUtc)


def openTestActive(policy: OpenTestPolicy | None, nowUtc: datetime | None = None) -> bool:
    return policy is not None and policy.isActive(nowUtc)


def loadOpenTestPolicy(path: Path) -> OpenTestPolicy:
    if not path.is_absolute():
        raise ValueError("open_test_absolute_path_required")
    for candidate in (path, *path.parents):
        if candidate.is_symlink() or candidate.is_junction():
            raise ValueError("redirected_open_test_policy")
    if path.stat().st_size > 4096:
        raise ValueError("open_test_policy_too_large")

    def unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate_open_test_field")
            result[key] = value
        return result

    value = json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=unique)
    if (
        not isinstance(value, dict)
        or not {"schemaVersion", "enabled"}.issubset(value)
        or type(value["schemaVersion"]) is not int
        or type(value["enabled"]) is not bool
    ):
        raise ValueError("invalid_open_test_policy")
    if value["schemaVersion"] == 2 and set(value) == {"schemaVersion", "enabled"}:
        return OpenTestPolicy(value["enabled"])
    if (
        value["schemaVersion"] != 1
        or set(value) != {"schemaVersion", "enabled", "enabledUntilUtc"}
        or not isinstance(value["enabledUntilUtc"], str)
    ):
        raise ValueError("invalid_open_test_policy")
    return OpenTestPolicy(
        value["enabled"], datetime.fromisoformat(value["enabledUntilUtc"].replace("Z", "+00:00"))
    )


def validateOpenTestSmsPrivileges(connection: AccountSqlConnection) -> None:
    """Only the two exact storage ceilings may supplement existing counter writes."""
    rows = connection.fetchMany(
        "SELECT column_name FROM information_schema.column_privileges "
        "WHERE table_schema=DATABASE() AND table_name='sms_send_budget' "
        "AND privilege_type='UPDATE' AND grantee=CONCAT(CHAR(39),"
        "SUBSTRING_INDEX(CURRENT_USER(),'@',1),CHAR(39),'@',CHAR(39),"
        "SUBSTRING_INDEX(CURRENT_USER(),'@',-1),CHAR(39))",
        maximumRows=100,
    )
    if {storedText(row["column_name"]) for row in rows} != {
        "attempts",
        "reserved_cents",
        "maximum_attempts",
        "budget_cents",
    }:
        raise ValueError("open_test_sms_counter_privileges_required")
    grantee = (
        "CONCAT(CHAR(39),SUBSTRING_INDEX(CURRENT_USER(),'@',1),CHAR(39),'@',CHAR(39),"
        "SUBSTRING_INDEX(CURRENT_USER(),'@',-1),CHAR(39))"
    )
    for source, disallowed in (
        ("table_privileges", "privilege_type<>'SELECT'"),
        ("column_privileges", "privilege_type NOT IN ('SELECT','UPDATE')"),
    ):
        result = connection.fetchOne(
            "SELECT COUNT(*) AS count FROM information_schema."  # noqa: S608 - fixed metadata fragments
            + source
            + " WHERE table_schema=DATABASE() AND table_name='sms_send_budget' AND grantee="
            + grantee
            + " AND ("
            + disallowed
            + " OR is_grantable='YES')"
        )
        if result is None or result["count"] != 0:
            raise ValueError("open_test_sms_privileges_excessive")
