from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from agent_gateway.account_lifecycle import (
    AccountLifecycleService,
    FakeSmsSender,
    IdentityActionError,
)
from agent_gateway.app import createApplication
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import (
    AccountService,
    AuthenticationFailedError,
    FakePhoneOwnershipVerifier,
)
from agent_gateway.settings import GatewaySettings

PHONE = "+8613800000000"
PASSWORD = "TestPass026!"
NEW_PASSWORD = "NewPass026!"


def service(tmp_path: Path) -> AccountLifecycleService:
    database = GatewayDatabase(tmp_path / "identity.sqlite")
    database.initialize()
    return AccountLifecycleService(
        AccountService(database, FakePhoneOwnershipVerifier()),
        FakeSmsSender(),
        otpSecret=b"synthetic-test-otp-secret-32-bytes",
    )


def registered(identity: AccountLifecycleService) -> tuple[str, str]:
    code = identity.issueCode(PHONE, "register", "peer")
    assert code.developmentCode is not None
    account = identity.register(PHONE, PASSWORD, code.challengeId, code.developmentCode, "peer")
    token = identity.accounts.createSession(phoneE164=PHONE, password=PASSWORD).sessionToken
    return account, token


def test_otp_is_one_time_purpose_bound_expiring_and_guess_attempts_survive_restart(
    tmp_path: Path,
) -> None:
    identity = service(tmp_path)
    now = datetime.now(UTC)
    challenge = identity.issueCode(PHONE, "register", "peer", nowUtc=now)
    assert challenge.developmentCode is not None
    with pytest.raises(IdentityActionError):
        identity.consumeCode(
            PHONE,
            "resetPassword",
            challenge.challengeId,
            challenge.developmentCode,
            "peer",
            nowUtc=now,
        )
    reopened = AccountLifecycleService(
        identity.accounts, FakeSmsSender(), otpSecret=b"synthetic-test-otp-secret-32-bytes"
    )
    reopened.consumeCode(
        PHONE, "register", challenge.challengeId, challenge.developmentCode, "peer", nowUtc=now
    )
    with pytest.raises(IdentityActionError):
        reopened.consumeCode(
            PHONE, "register", challenge.challengeId, challenge.developmentCode, "peer", nowUtc=now
        )
    expired = identity.issueCode(PHONE, "register", "peer", nowUtc=now)
    with pytest.raises(IdentityActionError):
        identity.consumeCode(
            PHONE,
            "register",
            expired.challengeId,
            expired.developmentCode or "",
            "peer",
            nowUtc=now + timedelta(minutes=5),
        )
    guessed = identity.issueCode(PHONE, "register", "peer", nowUtc=now)
    wrong = "000000" if guessed.developmentCode != "000000" else "111111"
    for _ in range(5):
        with pytest.raises(IdentityActionError):
            identity.consumeCode(PHONE, "register", guessed.challengeId, wrong, "peer", nowUtc=now)
    with pytest.raises(IdentityActionError):
        identity.consumeCode(
            PHONE,
            "register",
            guessed.challengeId,
            guessed.developmentCode or "",
            "peer",
            nowUtc=now,
        )
    with identity.accounts.database.readConnection() as connection:
        assert (
            connection.execute(
                "SELECT attempts FROM phone_challenges WHERE challenge_id = ?",
                (guessed.challengeId,),
            ).fetchone()[0]
            == 5
        )
        assert (
            connection.execute(
                "SELECT code_hash FROM phone_challenges WHERE challenge_id = ?",
                (guessed.challengeId,),
            ).fetchone()[0]
            != guessed.developmentCode
        )


def test_current_and_all_session_revocation_password_reset_and_deactivation(tmp_path: Path) -> None:
    identity = service(tmp_path)
    account, first = registered(identity)
    second = identity.accounts.createSession(phoneE164=PHONE, password=PASSWORD).sessionToken
    identity.revoke(first, allDevices=False)
    with pytest.raises(AuthenticationFailedError):
        identity.accounts.authenticateSession(first)
    assert identity.accounts.authenticateSession(second).accountId == account
    identity.changePassword(second, PASSWORD, NEW_PASSWORD)
    with pytest.raises(AuthenticationFailedError):
        identity.accounts.authenticateSession(second)
    with pytest.raises(AuthenticationFailedError):
        identity.accounts.createSession(phoneE164=PHONE, password=PASSWORD)
    third = identity.accounts.createSession(phoneE164=PHONE, password=NEW_PASSWORD).sessionToken
    reset = identity.issueCode(PHONE, "resetPassword", "peer")
    identity.resetPassword(PHONE, PASSWORD, reset.challengeId, reset.developmentCode or "", "peer")
    with pytest.raises(AuthenticationFailedError):
        identity.accounts.authenticateSession(third)
    fourth = identity.accounts.createSession(phoneE164=PHONE, password=PASSWORD).sessionToken
    fifth = identity.accounts.createSession(phoneE164=PHONE, password=PASSWORD).sessionToken
    identity.revoke(fourth, allDevices=True)
    for token in (fourth, fifth):
        with pytest.raises(AuthenticationFailedError):
            identity.accounts.authenticateSession(token)
    sixth = identity.accounts.createSession(phoneE164=PHONE, password=PASSWORD).sessionToken
    identity.deactivate(sixth, PASSWORD)
    with pytest.raises(AuthenticationFailedError):
        identity.accounts.authenticateSession(sixth)
    with identity.accounts.database.readConnection() as connection:
        row = connection.execute(
            "SELECT * FROM accounts WHERE account_id = ?", (account,)
        ).fetchone()
        assert (
            row["is_active"] == 0 and row["password_hash"] == "" and PHONE not in row["phone_e164"]
        )


def test_two_simultaneous_redemptions_have_only_one_success(tmp_path: Path) -> None:
    identity = service(tmp_path)
    challenge = identity.issueCode(PHONE, "register", "peer")

    def redeem() -> bool:
        try:
            identity.consumeCode(
                PHONE, "register", challenge.challengeId, challenge.developmentCode or "", "peer"
            )
            return True
        except IdentityActionError:
            return False

    with ThreadPoolExecutor(max_workers=2) as workers:
        assert sorted(workers.map(lambda _: redeem(), range(2))) == [False, True]


def test_http_contract_normal_phone_rate_limits_enumeration_and_revoke(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    app = createApplication(
        settings=GatewaySettings(
            task018DatabasePath=tmp_path / "http.sqlite", enableTask018FakeIdentity=True
        )
    )
    with TestClient(app) as client:
        assert client.get("/v2/account/options").json()["developmentSms"] is True
        challenge = client.post(
            "/v2/account-verifications",
            json={"protocolVersion": "0.5.0", "phoneE164": PHONE, "purpose": "register"},
        ).json()
        registration = client.post(
            "/v2/accounts",
            json={
                "protocolVersion": "0.5.0",
                "phoneE164": PHONE,
                "password": PASSWORD,
                "challengeId": challenge["challengeId"],
                "code": challenge["developmentCode"],
            },
        )
        assert registration.status_code == 201

        def login(phone: str, password: str) -> object:
            return client.post(
                "/v2/account-sessions",
                json={"protocolVersion": "0.5.0", "phoneE164": phone, "password": password},
            )

        wrong = client.post(
            "/v2/account-sessions",
            json={"protocolVersion": "0.5.0", "phoneE164": PHONE, "password": NEW_PASSWORD},
        )
        missing = client.post(
            "/v2/account-sessions",
            json={
                "protocolVersion": "0.5.0",
                "phoneE164": "+8613800000001",
                "password": NEW_PASSWORD,
            },
        )
        assert wrong.status_code == missing.status_code == 401
        assert wrong.json()["error"]["code"] == missing.json()["error"]["code"]
        signed = client.post(
            "/v2/account-sessions",
            json={"protocolVersion": "0.5.0", "phoneE164": PHONE, "password": PASSWORD},
        ).json()
        token = signed["sessionToken"]
        assert (
            client.post(
                "/v2/account-sessions/revoke",
                headers={"Authorization": "Bearer " + token},
                json={"protocolVersion": "0.5.0", "allDevices": False},
            ).status_code
            == 200
        )
        assert (
            client.get(
                "/v1/account/identity", headers={"Authorization": "Bearer " + token}
            ).status_code
            == 401
        )
        for _ in range(7):
            client.post(
                "/v2/account-sessions",
                json={"protocolVersion": "0.5.0", "phoneE164": PHONE, "password": NEW_PASSWORD},
            )
        assert (
            client.post(
                "/v2/account-sessions",
                json={"protocolVersion": "0.5.0", "phoneE164": PHONE, "password": PASSWORD},
            ).status_code
            == 429
        )
        for _ in range(2):
            assert (
                client.post(
                    "/v2/account-verifications",
                    json={"protocolVersion": "0.5.0", "phoneE164": PHONE, "purpose": "register"},
                ).status_code
                == 200
            )
        assert (
            client.post(
                "/v2/account-verifications",
                json={
                    "protocolVersion": "0.5.0",
                    "phoneE164": "+8613800000002",
                    "purpose": "register",
                },
            ).status_code
            == 429
        )
        for secret in (PHONE, PASSWORD, NEW_PASSWORD, token, challenge["developmentCode"]):
            assert secret not in caplog.text


def test_production_rejects_fake_configuration_and_fake_service_injection(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        GatewaySettings(executionEnvironment="production")
    with pytest.raises(ValueError):
        GatewaySettings(
            executionEnvironment="production",
            remoteProviderMode="glm",
            glmApiKey="synthetic",
            testBearerToken="synthetic-bearer-026",
        )
    identity = service(tmp_path)
    from agent_gateway.usage import UsagePolicyService

    with pytest.raises(ValueError):
        createApplication(
            settings=GatewaySettings(
                executionEnvironment="production", remoteProviderMode="glm", glmApiKey="synthetic"
            ),
            accountService=identity.accounts,
            usagePolicy=UsagePolicyService(identity.accounts.database),
            accountLifecycle=identity,
        )


def test_mismatched_login_and_verification_services_fail_before_startup(tmp_path: Path) -> None:
    from agent_gateway.usage import UsagePolicyService

    identity = service(tmp_path)
    otherAccounts = AccountService(identity.accounts.database, FakePhoneOwnershipVerifier())
    with pytest.raises(ValueError, match="同一个账户服务"):
        createApplication(
            accountService=otherAccounts,
            usagePolicy=UsagePolicyService(identity.accounts.database),
            accountLifecycle=identity,
        )
