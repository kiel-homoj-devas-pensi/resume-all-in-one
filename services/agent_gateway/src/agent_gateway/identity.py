from __future__ import annotations

import hashlib
import re
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from types import MappingProxyType
from typing import Protocol
from uuid import uuid4

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
from argon2.low_level import Type

from .account_storage import AccountAlreadyExistsError, AccountStore, SqliteAccountStore
from .database import GatewayDatabase
from .password_policy import validateNewPassword

PHONE_PATTERN = re.compile(r"^\+[1-9][0-9]{7,14}$")
SESSION_LIFETIME = timedelta(days=30)
IDENTITY_RATE_LIMITS = MappingProxyType(
    {
        "issue": (3, 900),
        "verify": (20, 900),
        "register": (5, 3600),
        "login": (10, 60),
        "manage": (10, 60),
    }
)


class InvalidAccountInputError(ValueError):
    pass


class PhoneVerificationRequiredError(RuntimeError):
    pass


class AccountRegistrationUnavailableError(RuntimeError):
    pass


class AuthenticationFailedError(RuntimeError):
    pass


class PhoneOwnershipVerifier(Protocol):
    def verify(self, phoneE164: str, verificationProof: str) -> bool: ...


class FakePhoneOwnershipVerifier:
    syntheticPhonePrefix = "+1555000"
    developmentProof = "task018-fake-phone-proof"

    def verify(self, phoneE164: str, verificationProof: str) -> bool:
        return phoneE164.startswith(self.syntheticPhonePrefix) and secrets.compare_digest(
            verificationProof,
            self.developmentProof,
        )


class AccountPasswordHasher:
    def __init__(self) -> None:
        self._passwordHasher = PasswordHasher(
            time_cost=2,
            memory_cost=19_456,
            parallelism=1,
            hash_len=32,
            salt_len=16,
            type=Type.ID,
        )
        # 缺失账号也执行同类哈希校验，缩小通过耗时判断手机号是否存在的差异。
        self._dummyPasswordHash = self._passwordHasher.hash(
            "task018-dummy-password-never-authenticates"
        )

    def hashPassword(self, password: str) -> str:
        validatePassword(password)
        return self._passwordHasher.hash(password)

    def verifyPassword(self, passwordHash: str, password: str) -> bool:
        try:
            validateNewPassword(password)
        except ValueError:
            return False
        try:
            return self._passwordHasher.verify(passwordHash, password)
        except InvalidHashError, VerificationError, VerifyMismatchError:
            return False

    def performDummyVerification(self, password: str) -> None:
        self.verifyPassword(self._dummyPasswordHash, password)

    def needsRehash(self, passwordHash: str) -> bool:
        return self._passwordHasher.check_needs_rehash(passwordHash)


@dataclass(frozen=True, slots=True)
class AccountSession:
    accountId: str
    sessionToken: str
    expiresAtUtc: datetime


@dataclass(frozen=True, slots=True)
class AuthenticatedSubject:
    accountId: str


class AccountService:
    def __init__(
        self,
        database: GatewayDatabase | AccountStore,
        phoneVerifier: PhoneOwnershipVerifier | None,
        passwordHasher: AccountPasswordHasher | None = None,
    ) -> None:
        self._database = database if isinstance(database, GatewayDatabase) else None
        self._store: AccountStore = (
            SqliteAccountStore(database) if isinstance(database, GatewayDatabase) else database
        )
        self._phoneVerifier = phoneVerifier
        self._passwordHasher = passwordHasher or AccountPasswordHasher()

    @property
    def database(self) -> GatewayDatabase:
        # 未迁移的生命周期只能接收原 SQLite，不允许另开库作为回退。
        if self._database is None:
            raise RuntimeError("账户生命周期尚未适配当前存储后端")
        return self._database

    @property
    def passwordHasher(self) -> AccountPasswordHasher:
        return self._passwordHasher

    @property
    def store(self) -> AccountStore:
        return self._store

    @property
    def usesDevelopmentIdentity(self) -> bool:
        return isinstance(self._phoneVerifier, FakePhoneOwnershipVerifier)

    def registerAccount(
        self,
        *,
        phoneE164: str,
        password: str,
        verificationProof: str,
        nowUtc: datetime | None = None,
    ) -> str:
        validatePhoneE164(phoneE164)
        validatePassword(password)
        if self._phoneVerifier is None or not self._phoneVerifier.verify(
            phoneE164, verificationProof
        ):
            raise PhoneVerificationRequiredError

        accountId = f"account-{uuid4()}"
        createdAtUtc = requireUtc(nowUtc or datetime.now(UTC))
        passwordHash = self._passwordHasher.hashPassword(password)
        try:
            self._store.insertAccount(accountId, phoneE164, passwordHash, toUtcText(createdAtUtc))
        except AccountAlreadyExistsError:
            raise AccountRegistrationUnavailableError from None
        return accountId

    def createSession(
        self,
        *,
        phoneE164: str,
        password: str,
        nowUtc: datetime | None = None,
    ) -> AccountSession:
        authenticatedAtUtc = requireUtc(nowUtc or datetime.now(UTC))
        account = self._store.findAccount(phoneE164)
        if account is None:
            self._passwordHasher.performDummyVerification(password)
            raise AuthenticationFailedError
        if not account.active or not self._passwordHasher.verifyPassword(
            account.passwordHash, password
        ):
            raise AuthenticationFailedError

        sessionToken = secrets.token_urlsafe(32)
        expiresAtUtc = authenticatedAtUtc + SESSION_LIFETIME
        issued = self._store.issueSession(
            account.accountId,
            account.passwordHash,
            f"session-{uuid4()}",
            hashSecret(sessionToken),
            toUtcText(expiresAtUtc),
            toUtcText(authenticatedAtUtc),
        )
        if not issued:
            raise AuthenticationFailedError
        return AccountSession(
            accountId=account.accountId,
            sessionToken=sessionToken,
            expiresAtUtc=expiresAtUtc,
        )

    def authenticateSession(
        self,
        sessionToken: str,
        *,
        nowUtc: datetime | None = None,
    ) -> AuthenticatedSubject:
        checkedAtUtc = requireUtc(nowUtc or datetime.now(UTC))
        accountId = self._store.authenticate(hashSecret(sessionToken), toUtcText(checkedAtUtc))
        if accountId is None:
            raise AuthenticationFailedError
        return AuthenticatedSubject(accountId=accountId)

    def revokeAllSessions(
        self,
        accountId: str,
        *,
        nowUtc: datetime | None = None,
    ) -> None:
        revokedAtUtc = requireUtc(nowUtc or datetime.now(UTC))
        self._store.revokeSessions(accountId, toUtcText(revokedAtUtc))


def validatePhoneE164(phoneE164: str) -> None:
    if PHONE_PATTERN.fullmatch(phoneE164) is None:
        raise InvalidAccountInputError("手机号必须是明确的 E.164 格式")


def validatePassword(password: str) -> None:
    try:
        validateNewPassword(password)
    except ValueError as error:
        raise InvalidAccountInputError(str(error)) from None


def hashSecret(secretValue: str) -> str:
    return hashlib.sha256(secretValue.encode("utf-8")).hexdigest()


def requireUtc(timestamp: datetime) -> datetime:
    if timestamp.tzinfo is None or timestamp.utcoffset() != timedelta(0):
        raise ValueError("时间必须包含 UTC 时区")
    return timestamp.astimezone(UTC)


def toUtcText(timestamp: datetime) -> str:
    return requireUtc(timestamp).isoformat(timespec="microseconds").replace("+00:00", "Z")
