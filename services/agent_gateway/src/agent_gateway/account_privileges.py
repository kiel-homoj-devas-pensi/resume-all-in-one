from __future__ import annotations

import re
from datetime import UTC, datetime
from typing import Literal

from .account_storage import AccountSqlConnection, AccountSqlDatabase, storedText
from .contracts import StrictGatewayModel
from .identity import requireUtc, toUtcText, validatePhoneE164

Privilege = Literal["admin", "permanentMember"]


class AccountPrivilegesResponse(StrictGatewayModel):
    protocolVersion: Literal["0.1.0"] = "0.1.0"
    accountId: str
    role: Literal["member", "admin"]
    membership: Literal["none", "permanent"]


class PrivilegeGrantError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("account_privilege_change_rejected")


def _identifier(value: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9._:-]{1,64}", value):
        raise PrivilegeGrantError()


class AccountPrivilegeService:
    """Read-only HTTP access; mutations are called only by an offline administrator.

    A grant ID stays bound to an account even after revocation/deactivation. There
    is deliberately no phone-based login hook and no public mutation endpoint.
    """

    def __init__(self, database: AccountSqlDatabase) -> None:
        self._database = database
        self._mysql = database.authorityKey[0] == "mysql"

    def _sql(self, statement: str, *, lock: bool = False) -> str:
        return statement.replace("?", "%s" if self._mysql else "?") + (
            " FOR UPDATE" if self._mysql and lock else ""
        )

    def read(self, accountId: str) -> AccountPrivilegesResponse:
        with self._database.readConnection() as connection:
            account = connection.fetchOne(
                self._sql("SELECT is_active FROM accounts WHERE account_id = ?"), (accountId,)
            )
            if account is None or account["is_active"] != 1:
                raise PrivilegeGrantError()
            rows = connection.fetchMany(
                self._sql(
                    "SELECT privilege FROM account_privilege_grants WHERE account_id = ? "
                    "AND revoked_at_utc IS NULL"
                ),
                (accountId,),
                maximumRows=2,
            )
        privileges = {storedText(row["privilege"]) for row in rows}
        if not privileges <= {"admin", "permanentMember"}:
            raise PrivilegeGrantError()
        return AccountPrivilegesResponse(
            accountId=accountId,
            role="admin" if "admin" in privileges else "member",
            membership="permanent" if "permanentMember" in privileges else "none",
        )

    def grant(
        self,
        *,
        accountId: str,
        expectedPhone: str,
        grantId: str,
        privilege: Privilege,
        operatorId: str,
        evidenceSha256: str,
        apply: bool = False,
        nowUtc: datetime | None = None,
    ) -> Literal["eligible", "granted", "already_granted"]:
        for value in (accountId, grantId, operatorId):
            _identifier(value)
        validatePhoneE164(expectedPhone)
        if privilege not in {"admin", "permanentMember"} or not re.fullmatch(
            r"[a-f0-9]{64}", evidenceSha256
        ):
            raise PrivilegeGrantError()
        now = toUtcText(requireUtc(nowUtc or datetime.now(UTC)))
        # Read-only dry-run does not create transaction/lock/write state.
        context = self._database.transaction if apply else self._database.readConnection
        with context() as connection:
            account = connection.fetchOne(
                self._sql(
                    "SELECT phone_e164, phone_verified_at_utc, is_active FROM accounts "
                    "WHERE account_id = ?",
                    lock=apply,
                ),
                (accountId,),
            )
            if (
                account is None
                or account["is_active"] != 1
                or storedText(account["phone_e164"]) != expectedPhone
                or not account["phone_verified_at_utc"]
                or storedText(account["phone_verified_at_utc"]) > now
            ):
                raise PrivilegeGrantError()
            try:
                verified = requireUtc(
                    datetime.fromisoformat(storedText(account["phone_verified_at_utc"]))
                )
                if toUtcText(verified) != storedText(account["phone_verified_at_utc"]):
                    raise ValueError
            except ValueError:
                raise PrivilegeGrantError() from None
            existing = connection.fetchOne(
                self._sql("SELECT * FROM account_privilege_grants WHERE grant_id = ?"),
                (grantId,),
            )
            if existing is not None:
                if (
                    storedText(existing["account_id"]) != accountId
                    or storedText(existing["privilege"]) != privilege
                    or storedText(existing["operator_id"]) != operatorId
                    or storedText(existing["evidence_sha256"]) != evidenceSha256
                    or existing["revoked_at_utc"] is not None
                ):
                    raise PrivilegeGrantError()
                return "already_granted"
            previous = connection.fetchOne(
                self._sql(
                    "SELECT grant_id FROM account_privilege_grants "
                    "WHERE account_id = ? AND privilege = ?"
                ),
                (accountId, privilege),
            )
            if previous is not None:
                raise PrivilegeGrantError()
            if not apply:
                return "eligible"
            connection.execute(
                self._sql(
                    "INSERT INTO account_privilege_grants(grant_id, account_id, privilege, "
                    "operator_id, evidence_sha256, granted_at_utc, revoked_at_utc, "
                    "revoked_by, revocation_evidence_sha256) "
                    "VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL)"
                ),
                (grantId, accountId, privilege, operatorId, evidenceSha256, now),
            )
        return "granted"

    def revoke(
        self,
        *,
        accountId: str,
        grantId: str,
        operatorId: str,
        evidenceSha256: str,
        apply: bool = False,
        nowUtc: datetime | None = None,
    ) -> Literal["eligible", "revoked", "already_revoked"]:
        for value in (accountId, grantId, operatorId):
            _identifier(value)
        if not re.fullmatch(r"[a-f0-9]{64}", evidenceSha256):
            raise PrivilegeGrantError()
        now = toUtcText(requireUtc(nowUtc or datetime.now(UTC)))
        context = self._database.transaction if apply else self._database.readConnection
        with context() as connection:
            # Same account-row lock as usage reservation and deactivation.
            if (
                connection.fetchOne(
                    self._sql("SELECT account_id FROM accounts WHERE account_id = ?", lock=apply),
                    (accountId,),
                )
                is None
            ):
                raise PrivilegeGrantError()
            row = connection.fetchOne(
                self._sql("SELECT * FROM account_privilege_grants WHERE grant_id = ?"),
                (grantId,),
            )
            if row is None or storedText(row["account_id"]) != accountId:
                raise PrivilegeGrantError()
            if row["revoked_at_utc"] is not None:
                if (
                    storedText(row["revoked_by"]) != operatorId
                    or storedText(row["revocation_evidence_sha256"]) != evidenceSha256
                ):
                    raise PrivilegeGrantError()
                return "already_revoked"
            if not apply:
                return "eligible"
            connection.execute(
                self._sql(
                    "UPDATE account_privilege_grants SET revoked_at_utc = ?, revoked_by = ?, "
                    "revocation_evidence_sha256 = ? WHERE grant_id = ?"
                ),
                (now, operatorId, evidenceSha256, grantId),
            )
        return "revoked"


def hasPermanentMembership(
    connection: AccountSqlConnection, accountId: str, *, mysql: bool
) -> bool:
    statement = (
        "SELECT g.grant_id FROM account_privilege_grants g JOIN accounts a "
        "ON a.account_id = g.account_id WHERE g.account_id = ? "
        "AND g.privilege = 'permanentMember' AND g.revoked_at_utc IS NULL AND a.is_active = 1"
    )
    row = connection.fetchOne(statement.replace("?", "%s" if mysql else "?"), (accountId,))
    return row is not None
