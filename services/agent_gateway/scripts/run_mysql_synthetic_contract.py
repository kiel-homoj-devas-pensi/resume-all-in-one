"""显式运行专用合成库账户契约；不启动 Gateway，不发送短信或调用模型。"""

from __future__ import annotations

import argparse
import os
import secrets
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

from agent_gateway.account_lifecycle import (
    AccountLifecycleService,
    FakeSmsSender,
    IdentityActionError,
)
from agent_gateway.account_storage import StorageUnavailableError, UnknownStorageCommitError
from agent_gateway.database import UnsupportedDatabaseSchemaError
from agent_gateway.identity import (
    AccountRegistrationUnavailableError,
    AccountService,
    AuthenticationFailedError,
    FakePhoneOwnershipVerifier,
)
from agent_gateway.lifecycle_storage import MySqlLifecycleStore
from agent_gateway.mysql_cloud_schema import migrateSyntheticCloudSchema
from agent_gateway.mysql_lifecycle_schema import migrateSyntheticLifecycleSchema
from agent_gateway.mysql_sms_schema import migrateSyntheticSmsSchema, validateFullGatewaySchema
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlAccountStore, MySqlConfig
from agent_gateway.settings import GatewaySettings
from agent_gateway.usage import (
    IdempotencyConflictError,
    InvalidUsageTransitionError,
    MonthlyQuotaExhaustedError,
    ProductCapability,
    SubscriptionService,
    UsageOperationStatus,
    UsagePolicyService,
)
from agent_gateway.usage_storage import MySqlUsageStore


def configuredSyntheticDatabase() -> MySqlConfig | None:
    names = (
        "GATEWAY_DATABASE_DSN",
        "GATEWAY_DATABASE_TLS_CA_FILE",
        "GATEWAY_DATABASE_EXPIRES_AT_UTC",
    )
    # 自动测试不读这些变量；只有人显式执行本入口才读取已注入配置。
    if not any(os.environ.get(name) for name in names):
        return None
    settings = GatewaySettings.fromEnvironment()
    if (
        settings.databaseBackend != "mysql"
        or not settings.databaseDsn
        or settings.databaseTlsCaFile is None
        or not settings.databaseExpiresAtUtc
    ):
        raise ValueError("合成库需要完整 MySQL 后端、TLS 与到期配置")
    config = MySqlConfig.fromDsn(
        settings.databaseDsn,
        settings.databaseTlsCaFile,
        settings.databaseExpiresAtUtc,
    )
    if not config.database.startswith("resume_gateway_synthetic"):
        raise ValueError("入口仅接受 resume_gateway_synthetic 前缀的专用合成库")
    return config


def runAccountContract(config: MySqlConfig) -> None:
    databases = [MySqlAccountDatabase(config), MySqlAccountDatabase(config)]
    try:
        for database in databases:
            database.checkSchema()
        services = [
            AccountService(MySqlAccountStore(database), FakePhoneOwnershipVerifier())
            for database in databases
        ]
        # 随机合成号，属于 Fake 专用号段；本次记录保留供核查，不清表。
        phone = f"+1555000{secrets.randbelow(10_000_000):07d}"
        password = "T1" + secrets.token_hex(6)

        def register(service: AccountService) -> str | None:
            try:
                return service.registerAccount(
                    phoneE164=phone,
                    password=password,
                    verificationProof=FakePhoneOwnershipVerifier.developmentProof,
                )
            except AccountRegistrationUnavailableError:
                return None

        with ThreadPoolExecutor(max_workers=2) as executor:
            registrations = list(executor.map(register, services))
        if sum(value is not None for value in registrations) != 1:
            raise RuntimeError("双连接账户唯一性契约失败")
        now = datetime.now(UTC)
        session = services[0].createSession(phoneE164=phone, password=password, nowUtc=now)
        if (
            services[1].authenticateSession(session.sessionToken, nowUtc=now).accountId
            != session.accountId
        ):
            raise RuntimeError("跨连接会话认证失败")
        databases[0].close()
        restarted = MySqlAccountDatabase(config)
        databases.append(restarted)
        restored = AccountService(MySqlAccountStore(restarted), FakePhoneOwnershipVerifier())
        restored.authenticateSession(session.sessionToken, nowUtc=now)
        restored.revokeAllSessions(session.accountId, nowUtc=now + timedelta(microseconds=1))
        try:
            services[1].authenticateSession(session.sessionToken, nowUtc=now)
        except AuthenticationFailedError:
            pass
        else:
            raise RuntimeError("跨连接撤销会话失败")
        print("PASS: 合成账户唯一注册、跨连接认证、连接池重建与会话撤销；测试记录保留")
    finally:
        for database in databases:
            database.close()


def reserveInProcess(arguments: tuple[MySqlConfig, str, str, datetime]) -> tuple[str, bool]:
    config, accountId, key, now = arguments
    database = MySqlAccountDatabase(config)
    try:
        policy = UsagePolicyService(MySqlUsageStore(database))
        try:
            result = policy.reserveUsageForExecution(
                accountId=accountId,
                capability=ProductCapability.basicResumeCompose,
                idempotencyKey=key,
                requestFingerprint="fixed-synthetic-fingerprint",
                nowUtc=now,
            )
            return result.operation.operationId, result.isReplay
        except MonthlyQuotaExhaustedError:
            return "quota_exhausted", False
    finally:
        database.close()


def runUsageContract(config: MySqlConfig) -> None:
    databases = [MySqlAccountDatabase(config), MySqlAccountDatabase(config)]
    try:
        for database in databases:
            with database.transaction() as connection:
                validateFullGatewaySchema(connection)
        accounts = AccountService(MySqlAccountStore(databases[0]), FakePhoneOwnershipVerifier())
        now = datetime.now(UTC)

        def newAccount() -> str:
            return accounts.registerAccount(
                phoneE164=f"+1555000{secrets.randbelow(10_000_000):07d}",
                password=secrets.token_urlsafe(24),
                verificationProof=FakePhoneOwnershipVerifier.developmentProof,
                nowUtc=now,
            )

        accountId = newAccount()
        policy = UsagePolicyService(MySqlUsageStore(databases[0]))
        independent = UsagePolicyService(MySqlUsageStore(databases[1]))
        for index in range(9):
            reserveInProcess((config, accountId, f"seed-{index}", now))
        with ProcessPoolExecutor(max_workers=2) as executor:
            results = list(
                executor.map(
                    reserveInProcess,
                    [
                        (config, accountId, "tenth-a", now),
                        (config, accountId, "tenth-b", now),
                    ],
                )
            )
        if sum(item[0] == "quota_exhausted" for item in results) != 1:
            raise RuntimeError("跨进程第十槽位竞争失败")
        if (
            independent.evaluateAccess(
                accountId=accountId, capability=ProductCapability.basicResumeCompose, nowUtc=now
            ).remainingMonthlyBasicGenerations
            != 0
        ):
            raise RuntimeError("跨连接月额度计数失败")
        replayAccount = newAccount()
        argument = (config, replayAccount, "stable-synthetic-action", now)
        with ProcessPoolExecutor(max_workers=2) as executor:
            replays = list(executor.map(reserveInProcess, [argument, argument]))
        if replays[0][0] != replays[1][0] or sorted(item[1] for item in replays) != [False, True]:
            raise RuntimeError("跨进程幂等执行资格失败")
        try:
            policy.reserveUsage(
                accountId=replayAccount,
                capability=ProductCapability.basicResumeCompose,
                idempotencyKey=argument[2],
                requestFingerprint="different",
                nowUtc=now,
            )
        except IdempotencyConflictError:
            pass
        else:
            raise RuntimeError("同键异内容未拒绝")
        operationId = replays[0][0]
        policy.transitionUsage(
            operationId=operationId,
            targetStatus=UsageOperationStatus.pendingReconciliation,
            nowUtc=now,
        )

        def reconcile(executed: bool) -> str:
            selected = policy if executed else independent
            try:
                return selected.reconcileUsage(
                    operationId=operationId,
                    operatorId="synthetic-reviewer",
                    evidenceSha256=("a" if executed else "b") * 64,
                    evidenceKind="executed" if executed else "notExecuted",
                    promptVersion="synthetic-v1" if executed else None,
                    inputTokens=2 if executed else None,
                    outputTokens=3 if executed else None,
                    nowUtc=now,
                ).status.value
            except InvalidUsageTransitionError:
                return "conflict"

        with ThreadPoolExecutor(max_workers=2) as reconciliationExecutor:
            reconciliations = list(reconciliationExecutor.map(reconcile, [False, True]))
        if reconciliations.count("conflict") != 1:
            raise RuntimeError("对账竞争未保持一个终态")
        SubscriptionService(MySqlUsageStore(databases[0])).setFakeProSubscription(
            accountId=replayAccount, startsAtUtc=now, endsAtUtc=now + timedelta(days=1), nowUtc=now
        )
        if not independent.evaluateAccess(
            accountId=replayAccount,
            capability=ProductCapability.targetedResumeOptimization,
            nowUtc=now,
        ).allowed:
            raise RuntimeError("跨连接权益查询失败")
        if independent.evaluateAccess(
            accountId=replayAccount,
            capability=ProductCapability.targetedResumeOptimization,
            nowUtc=now + timedelta(days=1),
        ).allowed:
            raise RuntimeError("到期权益未失效")
        print("PASS: 合成权益窗口、跨进程第十槽与幂等资格、同键异内容及对账终态竞争；记录保留")
    finally:
        for database in databases:
            database.close()


SYNTHETIC_OTP_SECRET = b"task029-synthetic-only-otp-secret-32-bytes"


def rateInProcess(arguments: tuple[MySqlConfig, str, str, datetime]) -> str:
    config, phone, peer, now = arguments
    database = MySqlAccountDatabase(config)
    try:
        lifecycle = AccountLifecycleService(
            AccountService(MySqlAccountStore(database), FakePhoneOwnershipVerifier()),
            FakeSmsSender(),
            otpSecret=SYNTHETIC_OTP_SECRET,
            store=MySqlLifecycleStore(database),
        )
        try:
            lifecycle.chargeRate("login", phone, peer, nowUtc=now)
            return "accepted"
        except IdentityActionError:
            return "rejected"
    finally:
        database.close()


def runLifecycleContract(config: MySqlConfig) -> None:
    databases = [MySqlAccountDatabase(config), MySqlAccountDatabase(config)]
    try:
        services = [
            AccountLifecycleService(
                AccountService(MySqlAccountStore(database), FakePhoneOwnershipVerifier()),
                FakeSmsSender(),
                otpSecret=SYNTHETIC_OTP_SECRET,
                store=MySqlLifecycleStore(database),
            )
            for database in databases
        ]
        now = datetime.now(UTC)
        phone = f"+1555000{secrets.randbelow(10_000_000):07d}"
        peer = f"synthetic-{secrets.token_hex(12)}"
        password, replacement = "T1" + secrets.token_hex(6), "N2" + secrets.token_hex(6)
        challenge = services[0].issueCode(phone, "register", peer, nowUtc=now)
        code = challenge.developmentCode
        if code is None:
            raise RuntimeError("合成入口缺少 Fake 验证码")
        services[0].register(phone, password, challenge.challengeId, code, peer)
        session = services[1].accounts.createSession(phoneE164=phone, password=password)
        services[0].changePassword(session.sessionToken, password, replacement)
        try:
            services[1].accounts.authenticateSession(session.sessionToken)
        except AuthenticationFailedError:
            pass
        else:
            raise RuntimeError("改密未撤销跨连接会话")
        nextSession = services[1].accounts.createSession(phoneE164=phone, password=replacement)
        reset = services[0].issueCode(phone, "resetPassword", peer)
        if reset.developmentCode is None:
            raise RuntimeError("合成重置入口缺少验证码")
        services[1].resetPassword(phone, password, reset.challengeId, reset.developmentCode, peer)
        try:
            services[0].accounts.authenticateSession(nextSession.sessionToken)
        except AuthenticationFailedError:
            pass
        else:
            raise RuntimeError("重置密码未撤销旧会话")
        restored = services[0].accounts.createSession(phoneE164=phone, password=password)
        services[1].deactivate(restored.sessionToken, password)
        try:
            services[0].accounts.createSession(phoneE164=phone, password=password)
        except AuthenticationFailedError:
            pass
        else:
            raise RuntimeError("停用账户仍可登录")
        verificationPhone = f"+1555000{secrets.randbelow(10_000_000):07d}"
        verification = services[0].issueCode(verificationPhone, "register", peer, nowUtc=now)
        verificationCode = verification.developmentCode
        if verificationCode is None:
            raise RuntimeError("合成并发入口缺少验证码")

        def consume(service: AccountLifecycleService) -> str:
            try:
                service.consumeCode(
                    verificationPhone,
                    "register",
                    verification.challengeId,
                    verificationCode,
                    peer,
                    nowUtc=now,
                )
                return "accepted"
            except IdentityActionError:
                return "rejected"

        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(consume, services))
        if sorted(results) != ["accepted", "rejected"]:
            raise RuntimeError("双连接验证码消费竞争失败")
        ratePhone = f"+1555000{secrets.randbelow(10_000_000):07d}"
        rateArgument = (config, ratePhone, peer, now)
        with ProcessPoolExecutor(max_workers=2) as rateExecutor:
            admissions = list(rateExecutor.map(rateInProcess, [rateArgument] * 12))
        if admissions.count("accepted") != 10 or admissions.count("rejected") != 2:
            raise RuntimeError("跨进程登录限流失败")
        print("PASS: MySQL Fake 注册、改密/重置撤销、停用、OTP 单次消费与跨进程限流；记录保留")
        print("未验证：真实数据迁移、PolarDB-X 和生产准入；未发送短信或模型请求")
    finally:
        for database in databases:
            database.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--synthetic-only", action="store_true", required=True)
    parser.add_argument("--migrate", action="store_true", help="用独立身份迁移空专用合成库")
    parser.add_argument("--dry-run", action="store_true", help="只检查现有 schema，不写合成账号")
    parser.add_argument(
        "--with-sms-budget", action="store_true", help="migrate 时追加 MySQL v4 账表，不批准短信"
    )
    parser.add_argument(
        "--with-cloud", action="store_true", help="显式迁移或只读检查 MySQL v5 云表，不开放云同步"
    )
    parser.add_argument(
        "--confirmed-quiescent", action="store_true", help="确认单个管理者操作且业务已停写"
    )
    args = parser.parse_args()
    try:
        if args.dry_run and args.migrate:
            raise ValueError("dry-run 不能与 migrate 同时使用")
        if args.with_sms_budget and not args.migrate:
            raise ValueError("with-sms-budget 必须与 migrate 一起显式选择")
        if args.with_cloud and (
            args.with_sms_budget
            or not (args.migrate or args.dry_run)
            or (args.migrate and not args.confirmed_quiescent)
        ):
            raise ValueError("云迁移需确认停写及单个管理者；只读检查不迁移")
        if args.confirmed_quiescent and not (args.with_cloud and args.migrate):
            raise ValueError("停写确认只用于显式云迁移")
        config = configuredSyntheticDatabase()
        if config is None:
            print("SKIP: 未配置专用 PolarDB-X 合成库；真实数据库验收未执行")
            return 0
        if args.migrate:
            migrationDsn = os.environ.get("GATEWAY_DATABASE_MIGRATION_DSN")
            if not migrationDsn or config.expiresAtUtc is None:
                raise ValueError("迁移需要独立 GATEWAY_DATABASE_MIGRATION_DSN")
            migration = MySqlConfig.fromDsn(
                migrationDsn, config.caFile, config.expiresAtUtc.isoformat()
            )
            if (migration.host, migration.port, migration.database) != (
                config.host,
                config.port,
                config.database,
            ) or migration.user == config.user:
                raise ValueError("迁移身份必须不同，目标必须与业务库一致")
            database = MySqlAccountDatabase(migration)
            try:
                if args.with_cloud:
                    migrateSyntheticCloudSchema(database)
                elif args.with_sms_budget:
                    migrateSyntheticSmsSchema(database)
                else:
                    migrateSyntheticLifecycleSchema(database)
            finally:
                database.close()
        if args.dry_run or args.with_cloud:
            database = MySqlAccountDatabase(config)
            try:
                database.checkSchema(withCloud=args.with_cloud)
                if not args.with_cloud:
                    with database.transaction() as connection:
                        validateFullGatewaySchema(connection)
            finally:
                database.close()
            if args.with_cloud:
                print("PASS: MySQL 云 schema v5 核验；未开放云同步、未批准短信或上传资料")
            else:
                print("PASS: MySQL 账户/用量 schema 只读检查；未迁移或写入业务数据")
        else:
            runAccountContract(config)
            runUsageContract(config)
            runLifecycleContract(config)
        return 0
    except UnknownStorageCommitError:
        print("UNKNOWN: 迁移提交确认丢失；保留现状，先执行相同目标的只读核验，禁止自动重放")
        return 2
    except ValueError, StorageUnavailableError, UnsupportedDatabaseSchemaError:
        print("FAIL: MySQL 配置、权限、TLS、迁移或存储契约未通过；无 SQLite 回退")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
