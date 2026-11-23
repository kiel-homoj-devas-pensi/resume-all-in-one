from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from functools import partial
from pathlib import Path
from sqlite3 import (
    SQLITE_DELETE,
    SQLITE_DENY,
    SQLITE_INSERT,
    SQLITE_OK,
    SQLITE_UPDATE,
    Connection,
    OperationalError,
)

import pytest

from agent_gateway import privilege_schema
from agent_gateway.account_lifecycle import AccountLifecycleService, FakeSmsSender
from agent_gateway.account_privileges import AccountPrivilegeService, PrivilegeGrantError
from agent_gateway.account_storage import SqliteAccountDatabase, StorageUnavailableError
from agent_gateway.app import createApplication
from agent_gateway.cloud_storage import CloudResumeStore, CloudSession
from agent_gateway.database import GatewayDatabase, UnsupportedDatabaseSchemaError
from agent_gateway.identity import (
    AccountService,
    AuthenticationFailedError,
    FakePhoneOwnershipVerifier,
    hashSecret,
)
from agent_gateway.privilege_schema import (
    migrateSqlitePrivilegeSchema,
    validateSqlitePrivilegeSchema,
)
from agent_gateway.settings import GatewaySettings
from agent_gateway.usage import (
    ProductCapability,
    SubscriptionPlan,
    SubscriptionService,
    UsagePolicyService,
)
from agent_gateway.usage_storage import SqliteUsageStore
from tests.support import sendAsgiRequest
from tests.test_cloud_storage import POLICY, operation, snapshot

PHONE = "+15550001234"
PASSWORD = "Private2026!"


def fixture(tmp_path: Path) -> tuple[GatewayDatabase, AccountService, str, AccountPrivilegeService]:
    database = GatewayDatabase(tmp_path / "synthetic.db")
    database.initialize()
    accounts = AccountService(database, FakePhoneOwnershipVerifier())
    account = accounts.registerAccount(
        phoneE164=PHONE,
        password=PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    migrateSqlitePrivilegeSchema(database)
    return database, accounts, account, AccountPrivilegeService(SqliteAccountDatabase(database))


def grant(
    service: AccountPrivilegeService, account: str, *, admin: bool = False, apply: bool = True
) -> str:
    return service.grant(
        accountId=account,
        expectedPhone=PHONE,
        grantId="owner-admin" if admin else "owner-membership",
        privilege="admin" if admin else "permanentMember",
        operatorId="synthetic-operator",
        evidenceSha256="a" * 64,
        apply=apply,
    )


def test_migration_preserves_account_and_old_definitions_and_is_idempotent(tmp_path: Path) -> None:
    database, accounts, account, service = fixture(tmp_path)
    before = database.databasePath.read_bytes()
    validateSqlitePrivilegeSchema(database)
    migrateSqlitePrivilegeSchema(database)
    assert database.databasePath.read_bytes() == before
    assert accounts.createSession(phoneE164=PHONE, password=PASSWORD).accountId == account
    assert service.read(account).membership == "none"
    with database.readConnection() as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 7
        assert connection.execute("SELECT COUNT(*) FROM subscription_snapshots").fetchone()[0] == 0


def test_dry_run_has_no_grant_then_roles_and_membership_are_independent(tmp_path: Path) -> None:
    database, _, account, service = fixture(tmp_path)
    assert grant(service, account, apply=False) == "eligible"
    assert service.read(account).membership == "none"
    assert grant(service, account, admin=True) == "granted"
    assert service.read(account).role == "admin"
    assert service.read(account).membership == "none"
    usage = UsagePolicyService(SqliteUsageStore(database, withPrivileges=True))
    assert usage.evaluateAccess(
        accountId=account,
        capability=ProductCapability.targetedResumeOptimization,
    ).allowed
    assert grant(service, account) == "granted"
    assert grant(service, account) == "already_granted"
    reloaded = AccountPrivilegeService(
        SqliteAccountDatabase(GatewayDatabase(database.databasePath))
    )
    assert reloaded.read(account).model_dump() == {
        "protocolVersion": "0.1.0",
        "accountId": account,
        "role": "admin",
        "membership": "permanent",
    }
    for capability in ProductCapability:
        access = usage.evaluateAccess(accountId=account, capability=capability)
        assert access.allowed and access.plan is SubscriptionPlan.pro
        operation = usage.reserveUsage(
            accountId=account,
            capability=capability,
            idempotencyKey="synthetic-" + capability.value,
            requestFingerprint="a" * 64,
        )
        assert operation.planAtReservation is SubscriptionPlan.pro


def test_revocation_is_audited_nonrenewing_and_does_not_revoke_other_role(tmp_path: Path) -> None:
    database, _, account, service = fixture(tmp_path)
    grant(service, account)
    grant(service, account, admin=True)
    revoke = partial(
        service.revoke,
        accountId=account,
        grantId="owner-membership",
        operatorId="synthetic-operator",
        evidenceSha256="b" * 64,
    )
    assert revoke() == "eligible"
    assert service.read(account).membership == "permanent"
    assert revoke(apply=True) == "revoked"
    assert revoke(apply=True) == "already_revoked"
    assert service.read(account).role == "admin"
    assert service.read(account).membership == "none"
    with pytest.raises(PrivilegeGrantError):
        grant(service, account)
    usage = UsagePolicyService(SqliteUsageStore(database, withPrivileges=True))
    operation = usage.reserveUsage(
        accountId=account,
        capability=ProductCapability.targetedResumeOptimization,
        idempotencyKey="after-revocation",
        requestFingerprint="a" * 64,
    )
    assert operation.planAtReservation is SubscriptionPlan.free
    assert (
        usage.evaluateAccess(
            accountId=account, capability=ProductCapability.targetedResumeOptimization
        ).monthlyLimit
        == 5
    )


@pytest.mark.parametrize("permanent", [False, True])
def test_deactivation_retains_subscription_and_phone_reregistration_never_transfers_entitlements(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, permanent: bool
) -> None:
    database, accounts, oldAccount, service = fixture(tmp_path)
    grant(service, oldAccount, admin=True)
    if permanent:
        grant(service, oldAccount)
    now = datetime.now(UTC)
    store = SqliteUsageStore(database, withPrivileges=True)
    SubscriptionService(store).setFakeProSubscription(
        accountId=oldAccount,
        startsAtUtc=now - timedelta(days=1),
        endsAtUtc=now + timedelta(days=1),
        nowUtc=now,
    )
    usage = UsagePolicyService(store)
    assert usage.evaluateAccess(
        accountId=oldAccount, capability=ProductCapability.targetedResumeOptimization
    ).allowed
    with database.readConnection() as connection:
        oldSubscription = dict(
            connection.execute(
                "SELECT * FROM subscription_snapshots WHERE account_id=?", (oldAccount,)
            ).fetchone()
        )
        oldGrants = [
            dict(row)
            for row in connection.execute(
                "SELECT * FROM account_privilege_grants WHERE account_id=? ORDER BY grant_id",
                (oldAccount,),
            )
        ]
    openConnection = database._openConnection

    def entitlementWritesDenied(
        action: int,
        table: str | None,
        _column: str | None,
        _database: str | None,
        _trigger: str | None,
    ) -> int:
        if action in {SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE} and table in {
            "subscription_snapshots",
            "account_privilege_grants",
            "schema_migrations",
        }:
            return SQLITE_DENY
        return SQLITE_OK

    def restrictedConnection() -> Connection:
        connection = openConnection()
        connection.set_authorizer(entitlementWritesDenied)
        return connection

    monkeypatch.setattr(database, "_openConnection", restrictedConnection)
    session = accounts.createSession(phoneE164=PHONE, password=PASSWORD)
    lifecycle = AccountLifecycleService(accounts, FakeSmsSender(), otpSecret=b"s" * 32)
    lifecycle.deactivate(session.sessionToken, PASSWORD)
    with pytest.raises(AuthenticationFailedError):
        accounts.authenticateSession(session.sessionToken)
    with pytest.raises(StorageUnavailableError):
        usage.reserveUsage(
            accountId=oldAccount,
            capability=ProductCapability.targetedResumeOptimization,
            idempotencyKey="retired-owner-cannot-use-membership",
            requestFingerprint="a" * 64,
        )
    newAccount = accounts.registerAccount(
        phoneE164=PHONE,
        password=PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    assert newAccount != oldAccount
    assert service.read(newAccount).membership == "none"
    assert service.read(newAccount).role == "member"
    newAccess = usage.evaluateAccess(
        accountId=newAccount, capability=ProductCapability.targetedResumeOptimization
    )
    assert newAccess.allowed and newAccess.plan is SubscriptionPlan.free
    assert newAccess.monthlyLimit == 5
    with pytest.raises(PrivilegeGrantError):
        grant(service, newAccount, admin=True)
    with pytest.raises(PrivilegeGrantError):
        service.read(oldAccount)
    with database.readConnection() as connection:
        retired = connection.execute(
            "SELECT is_active,phone_e164,password_hash FROM accounts WHERE account_id=?",
            (oldAccount,),
        ).fetchone()
        assert retired["is_active"] == 0 and retired["phone_e164"] != PHONE
        assert retired["password_hash"] == ""
        assert (
            dict(
                connection.execute(
                    "SELECT * FROM subscription_snapshots WHERE account_id=?", (oldAccount,)
                ).fetchone()
            )
            == oldSubscription
        )
        assert [
            dict(row)
            for row in connection.execute(
                "SELECT * FROM account_privilege_grants WHERE account_id=? ORDER BY grant_id",
                (oldAccount,),
            )
        ] == oldGrants
        assert (
            connection.execute(
                "SELECT COUNT(*) FROM subscription_snapshots WHERE account_id=?", (newAccount,)
            ).fetchone()[0]
            == 0
        )
    application = createApplication(
        settings=GatewaySettings(
            task018DatabasePath=database.databasePath,
            enableTask018FakeIdentity=True,
            enableAccountPrivileges=True,
        )
    )
    retiredHeaders = {"Authorization": "Bearer " + session.sessionToken}
    for endpoint in (
        "/v1/account/privileges",
        "/v1/account/access/targetedResumeOptimization",
    ):
        assert (
            sendAsgiRequest(application, "GET", endpoint, headers=retiredHeaders).status_code == 401
        )


@pytest.mark.parametrize(
    "mutation", ["wrong-phone", "missing-account", "unverified", "future", "inactive"]
)
def test_grant_requires_matching_active_verified_stable_identity(
    tmp_path: Path, mutation: str
) -> None:
    database, _, account, service = fixture(tmp_path)
    phone = "+15550004321" if mutation == "wrong-phone" else PHONE
    if mutation in {"unverified", "future", "inactive"}:
        with database.immediateTransaction() as connection:
            if mutation == "inactive":
                connection.execute(
                    "UPDATE accounts SET is_active = 0 WHERE account_id = ?", (account,)
                )
            else:
                connection.execute(
                    "UPDATE accounts SET phone_verified_at_utc = ? WHERE account_id = ?",
                    ("" if mutation == "unverified" else "2099-01-01T00:00:00.000000Z", account),
                )
    with pytest.raises(PrivilegeGrantError):
        service.grant(
            accountId="account-missing" if mutation == "missing-account" else account,
            expectedPhone=phone,
            grantId="g",
            privilege="admin",
            operatorId="op",
            evidenceSha256="a" * 64,
            apply=True,
        )


def test_two_connections_grant_once_and_cannot_change_bound_evidence(tmp_path: Path) -> None:
    database, _, account, service = fixture(tmp_path)

    def run() -> str:
        independent = AccountPrivilegeService(
            SqliteAccountDatabase(GatewayDatabase(database.databasePath))
        )
        return grant(independent, account)

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: run(), range(2)))
    assert sorted(results) == ["already_granted", "granted"]
    with pytest.raises(PrivilegeGrantError):
        service.grant(
            accountId=account,
            expectedPhone=PHONE,
            grantId="owner-membership",
            privilege="admin",
            operatorId="op",
            evidenceSha256="b" * 64,
            apply=True,
        )


def test_enabled_factory_requires_prepared_schema_without_creating_or_upgrading(
    tmp_path: Path,
) -> None:
    path = tmp_path / "missing.db"
    settings = GatewaySettings(
        task018DatabasePath=path, enableTask018FakeIdentity=True, enableAccountPrivileges=True
    )
    with pytest.raises(OperationalError):
        createApplication(settings=settings)
    assert not path.exists()
    database = GatewayDatabase(path)
    database.initialize()
    before = path.read_bytes()
    with pytest.raises(UnsupportedDatabaseSchemaError):
        createApplication(settings=settings)
    assert path.read_bytes() == before


def test_http_endpoint_uses_session_owner_and_existing_access_contract(tmp_path: Path) -> None:
    database, accounts, account, service = fixture(tmp_path)
    grant(service, account)
    grant(service, account, admin=True)
    token = accounts.createSession(phoneE164=PHONE, password=PASSWORD).sessionToken
    app = createApplication(
        settings=GatewaySettings(
            task018DatabasePath=database.databasePath,
            enableTask018FakeIdentity=True,
            enableAccountPrivileges=True,
        )
    )
    assert sendAsgiRequest(app, "GET", "/v1/account/privileges").status_code == 401
    headers = {"Authorization": "Bearer " + token}
    reply = sendAsgiRequest(app, "GET", "/v1/account/privileges", headers=headers)
    assert reply.status_code == 200
    assert reply.json() == service.read(account).model_dump()
    access = sendAsgiRequest(
        app, "GET", "/v1/account/access/targetedResumeOptimization", headers=headers
    )
    assert (
        access.status_code == 200
        and access.json()["plan"] == "pro"
        and access.json()["allowed"] is True
    )
    assert access.json()["protocolVersion"] == "0.2.0"
    assert (
        sendAsgiRequest(
            app, "POST", "/v1/account/privileges", headers=headers, jsonBody={"role": "admin"}
        ).status_code
        == 405
    )
    accounts.revokeAllSessions(account)
    assert sendAsgiRequest(app, "GET", "/v1/account/privileges", headers=headers).status_code == 401


def test_disabled_feature_is_explicit_not_fake_free_membership() -> None:
    app = createApplication(settings=GatewaySettings())
    result = sendAsgiRequest(app, "GET", "/v1/account/privileges")
    assert result.status_code == 503
    assert result.json()["error"]["code"] == "account_privileges_unavailable"


def test_schema_tampering_rejected_and_old_baseline_still_strict(tmp_path: Path) -> None:
    database, _, _, _ = fixture(tmp_path)
    with pytest.raises(UnsupportedDatabaseSchemaError):
        database.checkSchema(withCloud=True)
    with database.immediateTransaction() as connection:
        connection.execute("CREATE TABLE foreign_table (value TEXT)")
    with pytest.raises(UnsupportedDatabaseSchemaError):
        validateSqlitePrivilegeSchema(database)


def test_environment_flag_opt_in_and_invalid_bool_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AGENT_GATEWAY_ENABLE_ACCOUNT_PRIVILEGES", "true")
    assert GatewaySettings.fromEnvironment().enableAccountPrivileges
    monkeypatch.setenv("AGENT_GATEWAY_ENABLE_ACCOUNT_PRIVILEGES", "yes")
    with pytest.raises(ValueError):
        GatewaySettings.fromEnvironment()


def test_privilege_schema_deactivation_retires_earlier_cloud_documents_even_when_cloud_routes_off(
    tmp_path: Path,
) -> None:
    database, accounts, account, service = fixture(tmp_path)
    grant(service, account)
    token = accounts.createSession(phoneE164=PHONE, password=PASSWORD).sessionToken
    identity = CloudSession(account, hashSecret(token))
    cloud = CloudResumeStore(SqliteAccountDatabase(database), POLICY)
    assert (
        cloud.grantConsent(identity, "document-one", operation(), POLICY.fingerprint).outcome
        == "applied"
    )
    assert (
        cloud.appendVersion(identity, operation(), snapshot(), None, POLICY.fingerprint).outcome
        == "applied"
    )
    application = createApplication(
        settings=GatewaySettings(
            task018DatabasePath=database.databasePath,
            enableTask018FakeIdentity=True,
            enableAccountPrivileges=True,
        )
    )
    headers = {"Authorization": "Bearer " + token}
    disabled = sendAsgiRequest(application, "GET", "/v1/cloud-resumes/options")
    assert disabled.status_code == 200 and disabled.json()["enabled"] is False
    result = sendAsgiRequest(
        application,
        "POST",
        "/v2/account/deactivate",
        headers=headers,
        jsonBody={
            "protocolVersion": "0.5.0",
            "currentPassword": PASSWORD,
            "confirmation": "DEACTIVATE",
        },
    )
    assert result.status_code == 200
    with database.readConnection() as connection:
        assert (
            connection.execute("SELECT deleted_at_utc FROM cloud_documents").fetchone()[0]
            is not None
        )
        assert (
            connection.execute("SELECT revoked_at_utc FROM cloud_consents").fetchone()[0]
            is not None
        )
        assert (
            connection.execute("SELECT account_id FROM account_privilege_grants").fetchone()[0]
            == account
        )
    assert (
        sendAsgiRequest(application, "GET", "/v1/account/privileges", headers=headers).status_code
        == 401
    )


def test_sqlite_interrupted_privilege_migration_rolls_back_its_step_and_preserves_old_data(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    database = GatewayDatabase(tmp_path / "interrupted.db")
    database.initialize()
    accounts = AccountService(database, FakePhoneOwnershipVerifier())
    owner = accounts.registerAccount(
        phoneE164=PHONE,
        password=PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    implementation = privilege_schema.applySqlitePrivilegeSchema

    def interrupted(connection: Connection) -> None:
        implementation(connection)
        raise RuntimeError("synthetic_interruption")

    monkeypatch.setattr(privilege_schema, "applySqlitePrivilegeSchema", interrupted)
    with pytest.raises(RuntimeError, match="synthetic_interruption"):
        migrateSqlitePrivilegeSchema(database)
    with database.readConnection() as connection:
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 6
        assert (
            connection.execute(
                "SELECT COUNT(*) FROM sqlite_schema WHERE name='account_privilege_grants'"
            ).fetchone()[0]
            == 0
        )
    assert accounts.createSession(phoneE164=PHONE, password=PASSWORD).accountId == owner
    monkeypatch.setattr(privilege_schema, "applySqlitePrivilegeSchema", implementation)
    migrateSqlitePrivilegeSchema(database)
    validateSqlitePrivilegeSchema(database)
