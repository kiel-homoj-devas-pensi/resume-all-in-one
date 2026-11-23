from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from agent_gateway.database import GatewayDatabase, UnsupportedDatabaseSchemaError
from agent_gateway.identity import (
    AccountPasswordHasher,
    AccountRegistrationUnavailableError,
    AccountService,
    AuthenticationFailedError,
    FakePhoneOwnershipVerifier,
    InvalidAccountInputError,
    PhoneVerificationRequiredError,
)

SYNTHETIC_PHONE = "+15550001234"
VALID_PASSWORD = "TestPass2026!"


def buildAccountService(temporaryDirectory: Path) -> tuple[GatewayDatabase, AccountService]:
    database = GatewayDatabase(temporaryDirectory / "gateway.db")
    database.initialize()
    return database, AccountService(database, FakePhoneOwnershipVerifier())


def test_注册只接受明确_e164_合成号码和_fake_证明(tmp_path: Path) -> None:
    _, accountService = buildAccountService(tmp_path)

    with pytest.raises(InvalidAccountInputError):
        accountService.registerAccount(
            phoneE164="15550001234",
            password=VALID_PASSWORD,
            verificationProof=FakePhoneOwnershipVerifier.developmentProof,
        )
    with pytest.raises(PhoneVerificationRequiredError):
        accountService.registerAccount(
            phoneE164="+8613800138000",
            password=VALID_PASSWORD,
            verificationProof=FakePhoneOwnershipVerifier.developmentProof,
        )


def test_密码只保存_argon2id_哈希且重复注册不泄露数据库错误(tmp_path: Path) -> None:
    database, accountService = buildAccountService(tmp_path)
    accountService.registerAccount(
        phoneE164=SYNTHETIC_PHONE,
        password=VALID_PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )

    with database.readConnection() as databaseConnection:
        accountRow = databaseConnection.execute(
            "SELECT password_hash FROM accounts WHERE phone_e164 = ?",
            (SYNTHETIC_PHONE,),
        ).fetchone()
    assert accountRow is not None
    storedPasswordHash = str(accountRow["password_hash"])
    assert storedPasswordHash.startswith("$argon2id$v=19$m=19456,t=2,p=1$")
    assert VALID_PASSWORD not in storedPasswordHash
    assert AccountPasswordHasher().verifyPassword(storedPasswordHash, VALID_PASSWORD)

    with pytest.raises(AccountRegistrationUnavailableError):
        accountService.registerAccount(
            phoneE164=SYNTHETIC_PHONE,
            password=VALID_PASSWORD,
            verificationProof=FakePhoneOwnershipVerifier.developmentProof,
        )


def test_登录返回一次性令牌而数据库只保存哈希(tmp_path: Path) -> None:
    database, accountService = buildAccountService(tmp_path)
    accountId = accountService.registerAccount(
        phoneE164=SYNTHETIC_PHONE,
        password=VALID_PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    loginAtUtc = datetime(2026, 10, 3, 8, 0, tzinfo=UTC)

    accountSession = accountService.createSession(
        phoneE164=SYNTHETIC_PHONE,
        password=VALID_PASSWORD,
        nowUtc=loginAtUtc,
    )
    authenticatedSubject = accountService.authenticateSession(
        accountSession.sessionToken,
        nowUtc=loginAtUtc + timedelta(days=1),
    )

    assert authenticatedSubject.accountId == accountId
    with database.readConnection() as databaseConnection:
        sessionRow = databaseConnection.execute(
            "SELECT token_hash FROM account_sessions WHERE account_id = ?",
            (accountId,),
        ).fetchone()
    assert sessionRow is not None
    assert accountSession.sessionToken not in str(sessionRow["token_hash"])


def test_错误密码_未知手机号_过期和撤销会话均返回统一认证失败(tmp_path: Path) -> None:
    _, accountService = buildAccountService(tmp_path)
    accountId = accountService.registerAccount(
        phoneE164=SYNTHETIC_PHONE,
        password=VALID_PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    loginAtUtc = datetime(2026, 10, 3, 8, 0, tzinfo=UTC)

    for phoneE164, password in (
        (SYNTHETIC_PHONE, "错误但长度无关"),
        ("+15550009999", VALID_PASSWORD),
    ):
        with pytest.raises(AuthenticationFailedError):
            accountService.createSession(
                phoneE164=phoneE164,
                password=password,
                nowUtc=loginAtUtc,
            )

    expiredSession = accountService.createSession(
        phoneE164=SYNTHETIC_PHONE,
        password=VALID_PASSWORD,
        nowUtc=loginAtUtc,
    )
    with pytest.raises(AuthenticationFailedError):
        accountService.authenticateSession(
            expiredSession.sessionToken,
            nowUtc=loginAtUtc + timedelta(days=30),
        )

    activeSession = accountService.createSession(
        phoneE164=SYNTHETIC_PHONE,
        password=VALID_PASSWORD,
        nowUtc=loginAtUtc,
    )
    accountService.revokeAllSessions(accountId, nowUtc=loginAtUtc + timedelta(hours=1))
    with pytest.raises(AuthenticationFailedError):
        accountService.authenticateSession(
            activeSession.sessionToken,
            nowUtc=loginAtUtc + timedelta(hours=2),
        )


def test_当前schema_可重复初始化且拒绝未知版本(tmp_path: Path) -> None:
    database = GatewayDatabase(tmp_path / "gateway.db")
    database.initialize()
    database.initialize()

    with database.readConnection() as databaseConnection:
        migrationCount = databaseConnection.execute(
            "SELECT COUNT(*) FROM schema_migrations"
        ).fetchone()[0]
        databaseConnection.execute("PRAGMA user_version = 99")
    assert migrationCount == 5

    with pytest.raises(UnsupportedDatabaseSchemaError):
        database.initialize()
