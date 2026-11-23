from __future__ import annotations

import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Literal, Protocol
from uuid import uuid4

from .identity import (
    IDENTITY_RATE_LIMITS,
    AccountService,
    AuthenticationFailedError,
    hashSecret,
    requireUtc,
    toUtcText,
    validatePassword,
    validatePhoneE164,
)
from .lifecycle_storage import LifecycleStore, LifecycleTransaction, SqliteLifecycleStore

VerificationPurpose = Literal["register", "resetPassword"]


class IdentityActionError(RuntimeError):
    def __init__(self, code: str, statusCode: int = 400) -> None:
        super().__init__(code)
        self.code = code
        self.statusCode = statusCode


class SmsSender(Protocol):
    developmentOnly: bool

    @property
    def authorityKey(self) -> tuple[str, ...] | None: ...

    def sendCode(
        self, phoneE164: str, code: str, purpose: VerificationPurpose, *, challengeId: str
    ) -> None: ...


class SmsSendRejectedError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("sms_send_rejected")


class SmsSendOutcomeUnknownError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("sms_send_outcome_unknown")


class FakeSmsSender:
    developmentOnly = True
    authorityKey = None

    def __init__(self) -> None:
        self.deliveries: list[tuple[str, str, VerificationPurpose]] = []

    def sendCode(
        self, phoneE164: str, code: str, purpose: VerificationPurpose, *, challengeId: str
    ) -> None:
        # 仅在开发进程内保留测试验证码，不向网络发送，也不写日志或数据库。
        self.deliveries.append((phoneE164, code, purpose))


@dataclass(frozen=True)
class VerificationChallenge:
    challengeId: str
    expiresAtUtc: datetime
    developmentCode: str | None


class _VerifiedPhone:
    def __init__(self, phoneE164: str, proof: str) -> None:
        self.phoneE164 = phoneE164
        self.proof = proof

    def verify(self, phoneE164: str, verificationProof: str) -> bool:
        return phoneE164 == self.phoneE164 and secrets.compare_digest(verificationProof, self.proof)


class AccountLifecycleService:
    def __init__(
        self,
        accounts: AccountService,
        smsSender: SmsSender,
        *,
        otpSecret: bytes,
        store: LifecycleStore | None = None,
        enableRecoveryCodes: bool = False,
        trialPeerMaximum: int | None = None,
    ) -> None:
        if len(otpSecret) < 32:
            raise ValueError("OTP 服务端秘密至少需要 32 字节")
        self.accounts = accounts
        self.smsSender = smsSender
        self._secret = otpSecret
        self._store = store or SqliteLifecycleStore(accounts.database)
        self.enableRecoveryCodes = enableRecoveryCodes
        if trialPeerMaximum is not None and (
            type(trialPeerMaximum) is not int or not 1 <= trialPeerMaximum <= 20
        ):
            raise ValueError("invalid_trial_peer_limit")
        self._trialPeerMaximum = trialPeerMaximum
        if self._store.authorityKey != accounts.store.authorityKey:
            raise ValueError("验证码、限流与账户必须使用同一个权威数据库")
        if (
            smsSender.authorityKey is not None
            and smsSender.authorityKey != self._store.authorityKey
        ):
            raise ValueError("短信预算与验证码必须使用同一个权威数据库")

    @property
    def retiresCloudDocuments(self) -> bool:
        return self._store.retiresCloudDocuments

    def _digest(self, value: str) -> str:
        return hmac.new(self._secret, value.encode("utf-8"), hashlib.sha256).hexdigest()

    def chargeRate(
        self, action: str, phone: str, peer: str, *, nowUtc: datetime | None = None
    ) -> None:
        maximum, seconds = IDENTITY_RATE_LIMITS[action]
        now = requireUtc(nowUtc or datetime.now(UTC))
        blocked = False
        # 电话和来源各有桶，失败也计次；这些提交独立于后面的身份事务。
        with self._store.transaction() as connection:
            for subject in ("phone:" + phone, "peer:" + peer):
                bucket = self._digest(action + ":" + subject)
                count = connection.chargeRate(
                    bucket, toUtcText(now), toUtcText(now - timedelta(seconds=seconds))
                )
                limit = (
                    self._trialPeerMaximum
                    if self._trialPeerMaximum is not None
                    and subject.startswith("peer:")
                    and action in {"issue", "register"}
                    else maximum
                )
                blocked = blocked or count > limit
        if blocked:
            raise IdentityActionError("identity_rate_limited", 429)

    def issueCode(
        self, phone: str, purpose: VerificationPurpose, peer: str, *, nowUtc: datetime | None = None
    ) -> VerificationChallenge:
        validatePhoneE164(phone)
        if purpose not in {"register", "resetPassword"}:
            raise IdentityActionError("invalid_request")
        if self.enableRecoveryCodes and (
            purpose != "register" or self.accounts.store.findAccount(phone) is not None
        ):
            # A registered phone cannot spend SMS budget through the registration endpoint.
            raise IdentityActionError("verification_unavailable", 403)
        now = requireUtc(nowUtc or datetime.now(UTC))
        self.chargeRate("issue", phone, peer, nowUtc=now)
        challengeId = f"challenge-{uuid4()}"
        code = f"{secrets.randbelow(1_000_000):06d}"
        expiry = now + timedelta(minutes=5)
        with self._store.transaction() as connection:
            # 新验证码使同目的旧码失效，不能积累多个可猜测的有效码。
            connection.lockPhonePurpose(self._digest(phone), purpose)
            connection.replaceChallenge(
                challengeId,
                self._digest(phone),
                purpose,
                self._digest(challengeId + ":" + code),
                toUtcText(expiry),
                toUtcText(now),
            )
        deliveryFailure: str | None = None
        try:
            self.smsSender.sendCode(phone, code, purpose, challengeId=challengeId)
        except SmsSendOutcomeUnknownError:
            deliveryFailure = "verification_delivery_unknown"
        except Exception:
            deliveryFailure = "verification_delivery_unavailable"
        if deliveryFailure is not None:
            with self._store.transaction() as connection:
                connection.invalidateChallenge(challengeId, toUtcText(now))
            # 不返回无法确认的挑战，也不让收到但已作废的码用于注册。
            # 预算不会撤销；上游异常不进入 API 异常链。
            raise IdentityActionError(deliveryFailure, 503) from None
        return VerificationChallenge(
            challengeId, expiry, code if self.smsSender.developmentOnly else None
        )

    def consumeCode(
        self,
        phone: str,
        purpose: VerificationPurpose,
        challengeId: str,
        code: str,
        peer: str,
        *,
        nowUtc: datetime | None = None,
    ) -> None:
        now = requireUtc(nowUtc or datetime.now(UTC))
        self.chargeRate("verify", phone, peer, nowUtc=now)
        accepted = False
        with self._store.transaction() as connection:
            connection.lockPhonePurpose(self._digest(phone), purpose)
            row = connection.findChallenge(challengeId)
            if row is not None and row["consumed_at_utc"] is None:
                attempts = int(str(row["attempts"])) + 1
                accepted = (
                    attempts <= 5
                    and row["purpose"] == purpose
                    and secrets.compare_digest(str(row["phone_hash"]), self._digest(phone))
                    and str(row["expires_at_utc"]) > toUtcText(now)
                    and secrets.compare_digest(
                        str(row["code_hash"]), self._digest(challengeId + ":" + code)
                    )
                )
                connection.setChallengeAttempt(
                    challengeId, attempts, toUtcText(now) if accepted or attempts >= 5 else None
                )
        # 在事务提交后抛出；否则错误验证码的尝试次数会因回滚而消失。
        if not accepted:
            raise IdentityActionError("verification_invalid", 403)

    def register(self, phone: str, password: str, challengeId: str, code: str, peer: str) -> str:
        validatePhoneE164(phone)
        validatePassword(password)
        self.chargeRate("register", phone, peer)
        self.consumeCode(phone, "register", challengeId, code, peer)
        proof = secrets.token_urlsafe(32)
        verified = AccountService(
            self.accounts.store, _VerifiedPhone(phone, proof), self.accounts.passwordHasher
        )
        return verified.registerAccount(phoneE164=phone, password=password, verificationProof=proof)

    def revoke(self, token: str, *, allDevices: bool) -> None:
        subject = self.accounts.authenticateSession(token)
        with self._store.transaction() as connection:
            connection.findAccount(subject.accountId, lock=True)
            connection.revokeSessions(
                subject.accountId,
                toUtcText(datetime.now(UTC)),
                None if allDevices else hashSecret(token),
            )

    def changePassword(self, token: str, currentPassword: str, newPassword: str) -> None:
        subject = self.accounts.authenticateSession(token)
        validatePassword(newPassword)
        expectedHash = self._verifyCurrentPassword(subject.accountId, currentPassword)
        newHash = self.accounts.passwordHasher.hashPassword(newPassword)
        with self._store.transaction() as connection:
            self._checkAccountForMutation(connection, subject.accountId, token, expectedHash)
            connection.replacePassword(subject.accountId, newHash, toUtcText(datetime.now(UTC)))

    def _verifyCurrentPassword(self, accountId: str, currentPassword: str) -> str:
        with self._store.readConnection() as connection:
            row = connection.findAccount(accountId)
            if (
                row is None
                or not row["is_active"]
                or not self.accounts.passwordHasher.verifyPassword(
                    str(row["password_hash"]), currentPassword
                )
            ):
                raise AuthenticationFailedError
            return str(row["password_hash"])

    @staticmethod
    def _checkAccountForMutation(
        connection: LifecycleTransaction, accountId: str, token: str, expectedHash: str
    ) -> None:
        # 密码计算不持有行锁。取得账户锁后复核摘要及当前会话，堵住改密/撤销竞争。
        row = connection.findAccount(accountId, lock=True)
        if (
            row is None
            or row["is_active"] != 1
            or row["password_hash"] != expectedHash
            or not connection.activeSession(
                accountId, hashSecret(token), toUtcText(datetime.now(UTC))
            )
        ):
            raise AuthenticationFailedError

    def resetPassword(
        self, phone: str, newPassword: str, challengeId: str, code: str, peer: str
    ) -> None:
        if self.enableRecoveryCodes:
            raise IdentityActionError("recovery_code_required", 403)
        validatePassword(newPassword)
        self.consumeCode(phone, "resetPassword", challengeId, code, peer)
        newHash = self.accounts.passwordHasher.hashPassword(newPassword)
        with self._store.transaction() as connection:
            accountId = connection.findActiveAccountByPhone(phone)
            if accountId is not None:
                connection.replacePassword(accountId, newHash, toUtcText(datetime.now(UTC)))
        # 有效手机号证明后的缺失账号也返回相同结果，不通过找回接口枚举账号。

    def createRecoveryCode(self, token: str, currentPassword: str) -> str:
        if not self.enableRecoveryCodes:
            raise IdentityActionError("recovery_unavailable", 503)
        subject = self.accounts.authenticateSession(token)
        expectedHash = self._verifyCurrentPassword(subject.accountId, currentPassword)
        randomCode = secrets.token_hex(16).upper()
        code = "-".join(randomCode[index : index + 8] for index in range(0, 32, 8))
        digest = self._digest("recovery:" + subject.accountId + ":" + code)
        with self._store.transaction() as connection:
            self._checkAccountForMutation(connection, subject.accountId, token, expectedHash)
            connection.replaceRecoveryCode(subject.accountId, digest, toUtcText(datetime.now(UTC)))
        # Return plaintext once. Neither storage nor audit receives it.
        return code

    def resetWithRecoveryCode(self, phone: str, newPassword: str, recoveryCode: str) -> None:
        if not self.enableRecoveryCodes:
            raise IdentityActionError("recovery_unavailable", 503)
        validatePhoneE164(phone)
        validatePassword(newPassword)
        passwordHash = self.accounts.passwordHasher.hashPassword(newPassword)
        with self._store.transaction() as connection:
            accountId = connection.findActiveAccountByPhone(phone)
            storedHash = None if accountId is None else connection.readRecoveryCode(accountId)
            expected = self._digest("recovery:" + str(accountId) + ":" + recoveryCode)
            matches = secrets.compare_digest(storedHash or "0" * 64, expected)
            if accountId is None or not matches:
                raise IdentityActionError("recovery_invalid", 403)
            connection.replaceRecoveryCode(accountId, "", toUtcText(datetime.now(UTC)))
            connection.replacePassword(accountId, passwordHash, toUtcText(datetime.now(UTC)))

    def deactivate(self, token: str, currentPassword: str) -> None:
        subject = self.accounts.authenticateSession(token)
        expectedHash = self._verifyCurrentPassword(subject.accountId, currentPassword)
        with self._store.transaction() as connection:
            self._checkAccountForMutation(connection, subject.accountId, token, expectedHash)
            # 当场移除登录手机号/密码；启用退休登记后，普通关联记录进入60日清理流程。
            connection.deactivate(
                subject.accountId, "disabled:" + subject.accountId, toUtcText(datetime.now(UTC))
            )
            if self.enableRecoveryCodes:
                connection.replaceRecoveryCode(subject.accountId, "", toUtcText(datetime.now(UTC)))

    def issueRightsRequestReceipt(self, token: str, currentPassword: str) -> dict[str, object]:
        from .rights_request_receipt import issueReceipt

        subject = self.accounts.authenticateSession(token)
        expectedHash = self._verifyCurrentPassword(subject.accountId, currentPassword)
        with self._store.transaction() as connection:
            self._checkAccountForMutation(connection, subject.accountId, token, expectedHash)
            # Only proves this account-control check; it grants neither login
            # access nor automatic correction, cancellation or deletion.
            return issueReceipt(self._secret, subject.accountId, datetime.now(UTC))
