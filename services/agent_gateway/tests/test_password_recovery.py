from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from argon2 import PasswordHasher
from fastapi.testclient import TestClient

from agent_gateway.account_lifecycle import (
    AccountLifecycleService,
    FakeSmsSender,
    IdentityActionError,
)
from agent_gateway.app import createApplication
from agent_gateway.database import GatewayDatabase, UnsupportedDatabaseSchemaError
from agent_gateway.identity import (
    AccountService,
    AuthenticationFailedError,
    FakePhoneOwnershipVerifier,
)
from agent_gateway.password_policy import validateNewPassword
from agent_gateway.privilege_schema import migrateSqlitePrivilegeSchema
from agent_gateway.recovery_schema import migrateSqliteRecoverySchema
from agent_gateway.settings import GatewaySettings
from agent_gateway.usage import UsagePolicyService

PHONE = "+15550001234"
PASSWORD = "TestPass2026!"
NEW_PASSWORD = "NewPass2026@"


@pytest.mark.parametrize("value", ["Ab1234", "A12345678901234", "Ab12@!", "test12"])
def test_new_password_accepts_requested_formats(value: str) -> None:
    assert validateNewPassword(value) == value


@pytest.mark.parametrize(
    "value",
    [
        "Ab123",
        "A123456789012345",
        "abcdef",
        "123456",
        "Ab12 3",
        "Ab123\n",
        "Ab12\t3",
        "Ab12#3",
        "Ab12_3",
        "密码Ab12",
        "Ａb1234",
        "Ab12\u00a03",
    ],
)
def test_new_password_rejects_invalid_formats_without_normalization(value: str) -> None:
    with pytest.raises(ValueError):
        validateNewPassword(value)


def service(tmp_path: Path) -> tuple[GatewayDatabase, AccountLifecycleService, str, str]:
    database = GatewayDatabase(tmp_path / "recovery.sqlite")
    database.initialize()
    migrateSqlitePrivilegeSchema(database)
    migrateSqliteRecoverySchema(database)
    accounts = AccountService(database, FakePhoneOwnershipVerifier())
    accountId = accounts.registerAccount(
        phoneE164=PHONE,
        password=PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    identity = AccountLifecycleService(
        accounts,
        FakeSmsSender(),
        otpSecret=b"synthetic-recovery-secret-32-bytes",
        enableRecoveryCodes=True,
    )
    token = accounts.createSession(phoneE164=PHONE, password=PASSWORD).sessionToken
    return database, identity, accountId, token


def test_recovery_stores_digest_rotates_consumes_once_and_revokes_sessions(tmp_path: Path) -> None:
    database, identity, accountId, token = service(tmp_path)
    first = identity.createRecoveryCode(token, PASSWORD)
    second = identity.createRecoveryCode(token, PASSWORD)
    assert first != second
    with database.readConnection() as c:
        stored = c.execute("SELECT code_hash FROM account_recovery_codes").fetchone()[0]
    assert len(stored) == 64 and second not in stored
    for phone, code in [(PHONE, first), ("+15550009999", second)]:
        with pytest.raises(IdentityActionError):
            identity.resetWithRecoveryCode(phone, NEW_PASSWORD, code)
    identity.resetWithRecoveryCode(PHONE, NEW_PASSWORD, second)
    with pytest.raises(IdentityActionError):
        identity.resetWithRecoveryCode(PHONE, PASSWORD, second)
    with pytest.raises(AuthenticationFailedError):
        identity.accounts.authenticateSession(token)
    session = identity.accounts.createSession(phoneE164=PHONE, password=NEW_PASSWORD)
    assert identity.accounts.authenticateSession(session.sessionToken).accountId == accountId
    assert isinstance(identity.smsSender, FakeSmsSender)
    assert identity.smsSender.deliveries == []


def test_concurrent_recovery_code_use_succeeds_only_once(tmp_path: Path) -> None:
    _, identity, _, token = service(tmp_path)
    code = identity.createRecoveryCode(token, PASSWORD)

    def attempt() -> bool:
        try:
            identity.resetWithRecoveryCode(PHONE, NEW_PASSWORD, code)
            return True
        except IdentityActionError:
            return False

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(lambda _: attempt(), range(2))) == [False, True]


def test_legacy_long_password_cannot_authenticate_even_if_a_hash_is_present(tmp_path: Path) -> None:
    database, identity, accountId, _ = service(tmp_path)
    legacy = "原有长密码 with spaces / symbols 2026"
    with database.immediateTransaction() as c:
        c.execute(
            "UPDATE accounts SET password_hash=? WHERE account_id=?",
            (
                PasswordHasher().hash(legacy),
                accountId,
            ),
        )
    with pytest.raises(AuthenticationFailedError):
        identity.accounts.createSession(phoneE164=PHONE, password=legacy)
    assert not identity.accounts.passwordHasher.verifyPassword(
        PasswordHasher().hash(legacy), legacy
    )


def test_http_recovery_checks_identity_rejects_sms_and_redacts_secrets(tmp_path: Path) -> None:
    _, identity, _, token = service(tmp_path)
    app = createApplication(
        settings=GatewaySettings(),
        accountService=identity.accounts,
        usagePolicy=UsagePolicyService(identity.accounts.database),
        accountLifecycle=identity,
    )
    with TestClient(app) as client:
        assert "recoveryCodes" not in client.get("/v2/account/options").json()
        options = client.get("/v2/account/options?features=recoveryCodes").json()
        assert options["recoveryCodes"] is True
        body = {"protocolVersion": "0.5.0", "currentPassword": PASSWORD}
        assert client.post("/v2/account/recovery-code", json=body).status_code == 401
        response = client.post(
            "/v2/account/recovery-code",
            json=body,
            headers={
                "Authorization": f"Bearer {token}",
            },
        )
        assert response.status_code == 200
        code = response.json()["recoveryCode"]
        for phone, purpose in [(PHONE, "register"), (PHONE, "resetPassword")]:
            assert (
                client.post(
                    "/v2/account-verifications",
                    json={
                        "protocolVersion": "0.5.0",
                        "phoneE164": phone,
                        "purpose": purpose,
                    },
                ).status_code
                == 403
            )
        invalid = client.post(
            "/v2/account/password-reset",
            json={
                "protocolVersion": "0.5.0",
                "phoneE164": PHONE,
                "newPassword": "bad password",
                "recoveryCode": code,
            },
        )
        assert invalid.status_code == 400
        assert code not in invalid.text and "bad password" not in invalid.text
        result = client.post(
            "/v2/account/password-reset",
            json={
                "protocolVersion": "0.5.0",
                "phoneE164": PHONE,
                "newPassword": NEW_PASSWORD,
                "recoveryCode": code,
            },
        )
        assert result.status_code == 200


def test_recovery_migration_is_idempotent_preserves_accounts_and_detects_tampering(
    tmp_path: Path,
) -> None:
    database, identity, accountId, token = service(tmp_path)
    code = identity.createRecoveryCode(token, PASSWORD)
    migrateSqliteRecoverySchema(database)
    identity.resetWithRecoveryCode(PHONE, NEW_PASSWORD, code)
    session = identity.accounts.createSession(phoneE164=PHONE, password=NEW_PASSWORD)
    assert identity.accounts.authenticateSession(session.sessionToken).accountId == accountId
    with database.immediateTransaction() as c:
        c.execute("ALTER TABLE account_recovery_codes ADD COLUMN unexpected TEXT")
    with pytest.raises(UnsupportedDatabaseSchemaError):
        migrateSqliteRecoverySchema(database)
