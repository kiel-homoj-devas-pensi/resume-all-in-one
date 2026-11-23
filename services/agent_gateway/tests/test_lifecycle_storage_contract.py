from concurrent.futures import ProcessPoolExecutor
from datetime import UTC, datetime
from pathlib import Path

import pytest

from agent_gateway.account_lifecycle import (
    AccountLifecycleService,
    FakeSmsSender,
    IdentityActionError,
)
from agent_gateway.account_storage import SqliteAccountStore
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import (
    AccountPasswordHasher,
    AccountService,
    AuthenticationFailedError,
    FakePhoneOwnershipVerifier,
)
from agent_gateway.lifecycle_storage import SqliteLifecycleStore

PHONE = "+155500029066"
PASSWORD = "Lifecycle029!"
NEW_PASSWORD = "NewLife029!"
OTP_SECRET = b"synthetic-lifecycle-only-secret-32-bytes"
NOW = datetime(2026, 10, 10, tzinfo=UTC)


def lifecycle(path: Path) -> AccountLifecycleService:
    database = GatewayDatabase(path)
    return AccountLifecycleService(
        AccountService(SqliteAccountStore(database), FakePhoneOwnershipVerifier()),
        FakeSmsSender(),
        otpSecret=OTP_SECRET,
        store=SqliteLifecycleStore(database),
    )


def consumeWorker(arguments: tuple[str, str, str]) -> str:
    path, challenge, code = arguments
    try:
        lifecycle(Path(path)).consumeCode(
            PHONE, "register", challenge, code, "same-peer", nowUtc=NOW
        )
        return "accepted"
    except IdentityActionError:
        return "rejected"


def rateWorker(path: str) -> str:
    try:
        lifecycle(Path(path)).chargeRate("login", PHONE, "same-peer", nowUtc=NOW)
        return "accepted"
    except IdentityActionError:
        return "rejected"


def test_independent_lifecycle_store_registers_without_legacy_sqlite_property(
    tmp_path: Path,
) -> None:
    path = tmp_path / "independent.db"
    GatewayDatabase(path).initialize()
    identity = lifecycle(path)
    challenge = identity.issueCode(PHONE, "register", "peer")
    assert challenge.developmentCode is not None
    account = identity.register(
        PHONE, PASSWORD, challenge.challengeId, challenge.developmentCode, "peer"
    )
    session = identity.accounts.createSession(phoneE164=PHONE, password=PASSWORD)
    assert session.accountId == account
    identity.changePassword(session.sessionToken, PASSWORD, NEW_PASSWORD)
    with pytest.raises(AuthenticationFailedError):
        identity.accounts.authenticateSession(session.sessionToken)
    replacement = identity.accounts.createSession(phoneE164=PHONE, password=NEW_PASSWORD)
    identity.deactivate(replacement.sessionToken, NEW_PASSWORD)
    with pytest.raises(AuthenticationFailedError):
        identity.accounts.createSession(phoneE164=PHONE, password=NEW_PASSWORD)


def test_cross_process_otp_consumption_has_one_winner(tmp_path: Path) -> None:
    path = tmp_path / "otp.db"
    GatewayDatabase(path).initialize()
    challenge = lifecycle(path).issueCode(PHONE, "register", "same-peer", nowUtc=NOW)
    assert challenge.developmentCode is not None
    arguments = (str(path), challenge.challengeId, challenge.developmentCode)
    with ProcessPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(consumeWorker, [arguments, arguments]))
    assert sorted(results) == ["accepted", "rejected"]


def test_cross_process_login_rate_limit_counts_denied_attempts(tmp_path: Path) -> None:
    path = tmp_path / "rates.db"
    GatewayDatabase(path).initialize()
    with ProcessPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(rateWorker, [str(path)] * 12))
    assert results.count("accepted") == 10
    assert results.count("rejected") == 2
    with GatewayDatabase(path).readConnection() as connection:
        assert {
            row[0] for row in connection.execute("SELECT attempts FROM identity_rate_limits")
        } == {12}


def test_session_revoked_during_password_verification_cannot_mutate_password(
    tmp_path: Path,
) -> None:
    path = tmp_path / "credential-race.db"
    GatewayDatabase(path).initialize()

    class RevokingHasher(AccountPasswordHasher):
        def __init__(self) -> None:
            super().__init__()
            self.armed = False
            self.accountId = ""
            self.accounts: AccountService | None = None

        def verifyPassword(self, passwordHash: str, password: str) -> bool:
            accepted = super().verifyPassword(passwordHash, password)
            if accepted and self.armed and self.accounts is not None:
                self.armed = False
                self.accounts.revokeAllSessions(self.accountId)
            return accepted

    hasher = RevokingHasher()
    database = GatewayDatabase(path)
    accounts = AccountService(SqliteAccountStore(database), FakePhoneOwnershipVerifier(), hasher)
    account = accounts.registerAccount(
        phoneE164=PHONE,
        password=PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    session = accounts.createSession(phoneE164=PHONE, password=PASSWORD)
    hasher.accounts = accounts
    hasher.accountId = account
    hasher.armed = True
    identity = AccountLifecycleService(
        accounts, FakeSmsSender(), otpSecret=OTP_SECRET, store=SqliteLifecycleStore(database)
    )
    with pytest.raises(AuthenticationFailedError):
        identity.changePassword(session.sessionToken, PASSWORD, NEW_PASSWORD)
    assert accounts.createSession(phoneE164=PHONE, password=PASSWORD).accountId == account
    with pytest.raises(AuthenticationFailedError):
        accounts.createSession(phoneE164=PHONE, password=NEW_PASSWORD)


def test_lifecycle_rejects_different_account_authority_before_any_write(tmp_path: Path) -> None:
    first = GatewayDatabase(tmp_path / "first.db")
    second = GatewayDatabase(tmp_path / "second.db")
    first.initialize()
    second.initialize()
    with pytest.raises(ValueError, match="同一个权威数据库"):
        AccountLifecycleService(
            AccountService(first, FakePhoneOwnershipVerifier()),
            FakeSmsSender(),
            otpSecret=OTP_SECRET,
            store=SqliteLifecycleStore(second),
        )
