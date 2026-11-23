from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.usage import (
    IdempotencyConflictError,
    InvalidUsageTransitionError,
    MonthlyQuotaExhaustedError,
    ProductCapability,
    SubscriptionPlan,
    SubscriptionService,
    UsageOperationStatus,
    UsagePolicyService,
)

VALID_PASSWORD = "TestPass2026!"


def buildServices(
    temporaryDirectory: Path,
) -> tuple[GatewayDatabase, str, SubscriptionService, UsagePolicyService]:
    database = GatewayDatabase(temporaryDirectory / "gateway.db")
    database.initialize()
    accountService = AccountService(database, FakePhoneOwnershipVerifier())
    accountId = accountService.registerAccount(
        phoneE164="+15550001234",
        password=VALID_PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    return database, accountId, SubscriptionService(database), UsagePolicyService(database)


def test_普通账号可使用岗位优化且基础和优化名额独立(tmp_path: Path) -> None:
    _, accountId, _, policy = buildServices(tmp_path)
    now = datetime(2026, 10, 3, tzinfo=UTC)
    decision = policy.evaluateAccess(
        accountId=accountId, capability=ProductCapability.targetedResumeOptimization, nowUtc=now
    )
    assert decision.allowed and decision.monthlyLimit == 5
    policy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.targetedResumeOptimization,
        idempotencyKey="advanced-001",
        requestFingerprint="f",
        nowUtc=now,
    )
    assert (
        policy.evaluateAccess(
            accountId=accountId, capability=ProductCapability.targetedResumeOptimization, nowUtc=now
        ).remainingMonthlyGenerations
        == 4
    )
    assert (
        policy.evaluateAccess(
            accountId=accountId, capability=ProductCapability.basicResumeCompose, nowUtc=now
        ).remainingMonthlyGenerations
        == 9
    )


def test_同键重放不重复占位而异指纹冲突(tmp_path: Path) -> None:
    _, accountId, _, usagePolicy = buildServices(tmp_path)
    checkedAtUtc = datetime(2026, 10, 3, tzinfo=UTC)

    firstOperation = usagePolicy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="basic-001",
        requestFingerprint="fingerprint-001",
        nowUtc=checkedAtUtc,
    )
    replayedOperation = usagePolicy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="basic-001",
        requestFingerprint="fingerprint-001",
        nowUtc=checkedAtUtc,
    )

    assert replayedOperation == firstOperation
    assert (
        usagePolicy.evaluateAccess(
            accountId=accountId,
            capability=ProductCapability.basicResumeCompose,
            nowUtc=checkedAtUtc,
        ).remainingMonthlyBasicGenerations
        == 8
    )
    with pytest.raises(IdempotencyConflictError):
        usagePolicy.reserveUsage(
            accountId=accountId,
            capability=ProductCapability.basicResumeCompose,
            idempotencyKey="basic-001",
            requestFingerprint="fingerprint-changed",
            nowUtc=checkedAtUtc,
        )


def test_执行预留区分首次请求和幂等重放(tmp_path: Path) -> None:
    _, accountId, _, usagePolicy = buildServices(tmp_path)

    firstReservation = usagePolicy.reserveUsageForExecution(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="execution-001",
        requestFingerprint="execution-fingerprint",
    )
    replayedReservation = usagePolicy.reserveUsageForExecution(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="execution-001",
        requestFingerprint="execution-fingerprint",
    )

    assert firstReservation.isReplay is False
    assert replayedReservation.isReplay is True
    assert replayedReservation.operation == firstReservation.operation


def test_并发最后一个成果占位仅一个成功(tmp_path: Path) -> None:
    _, accountId, _, usagePolicy = buildServices(tmp_path)
    checkedAtUtc = datetime(2026, 10, 3, tzinfo=UTC)

    def reserveOneSlot(slotNumber: int) -> str:
        try:
            usagePolicy.reserveUsage(
                accountId=accountId,
                capability=ProductCapability.basicResumeCompose,
                idempotencyKey=f"concurrent-{slotNumber}",
                requestFingerprint=f"fingerprint-{slotNumber}",
                nowUtc=checkedAtUtc,
            )
            return "reserved"
        except MonthlyQuotaExhaustedError:
            return "quota_exhausted"

    with ThreadPoolExecutor(max_workers=11) as threadPool:
        outcomes = list(threadPool.map(reserveOneSlot, range(11)))

    assert outcomes.count("reserved") == 9
    assert outcomes.count("quota_exhausted") == 2


def test_释放归还额度_未知结果继续占位_跨月重新计算(tmp_path: Path) -> None:
    _, accountId, _, usagePolicy = buildServices(tmp_path)
    october = datetime(2026, 10, 31, 15, 59, tzinfo=UTC)

    releasedOperation = usagePolicy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="released-001",
        requestFingerprint="released-fingerprint",
        nowUtc=october,
    )
    usagePolicy.transitionUsage(
        operationId=releasedOperation.operationId,
        targetStatus=UsageOperationStatus.released,
        failureCode="provider_unavailable",
        nowUtc=october,
    )
    pendingOperation = usagePolicy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="pending-001",
        requestFingerprint="pending-fingerprint",
        nowUtc=october,
    )
    usagePolicy.transitionUsage(
        operationId=pendingOperation.operationId,
        targetStatus=UsageOperationStatus.pendingReconciliation,
        nowUtc=october,
    )

    octoberDecision = usagePolicy.evaluateAccess(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        nowUtc=october,
    )
    novemberDecision = usagePolicy.evaluateAccess(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        nowUtc=october + timedelta(minutes=2),
    )
    assert octoberDecision.remainingMonthlyBasicGenerations == 8
    assert novemberDecision.remainingMonthlyBasicGenerations == 9


def test_pro_基础99和优化60独立硬上限(tmp_path: Path) -> None:
    _, accountId, subscriptionService, usagePolicy = buildServices(tmp_path)
    checkedAtUtc = datetime(2026, 10, 3, tzinfo=UTC)
    subscriptionService.setFakeProSubscription(
        accountId=accountId,
        startsAtUtc=checkedAtUtc - timedelta(days=1),
        endsAtUtc=checkedAtUtc + timedelta(days=29),
        nowUtc=checkedAtUtc,
    )

    for operationNumber in range(12):
        usagePolicy.reserveUsage(
            accountId=accountId,
            capability=ProductCapability.basicResumeCompose,
            idempotencyKey=f"pro-basic-{operationNumber}",
            requestFingerprint=f"pro-fingerprint-{operationNumber}",
            nowUtc=checkedAtUtc,
        )
    advancedOperation = usagePolicy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.resumeOptimizationConversation,
        idempotencyKey="pro-conversation-001",
        requestFingerprint="pro-conversation-fingerprint",
        nowUtc=checkedAtUtc,
    )

    assert advancedOperation.planAtReservation is SubscriptionPlan.pro
    assert (
        usagePolicy.evaluateAccess(
            accountId=accountId,
            capability=ProductCapability.basicResumeCompose,
            nowUtc=checkedAtUtc,
        ).remainingMonthlyBasicGenerations
        == 87
    )


def test_状态机支持待对账结算并拒绝终态反转(tmp_path: Path) -> None:
    _, accountId, _, usagePolicy = buildServices(tmp_path)
    checkedAtUtc = datetime(2026, 10, 3, tzinfo=UTC)
    operation = usagePolicy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="transition-001",
        requestFingerprint="transition-fingerprint",
        nowUtc=checkedAtUtc,
    )

    pendingOperation = usagePolicy.transitionUsage(
        operationId=operation.operationId,
        targetStatus=UsageOperationStatus.pendingReconciliation,
        nowUtc=checkedAtUtc,
    )
    committedOperation = usagePolicy.transitionUsage(
        operationId=operation.operationId,
        targetStatus=UsageOperationStatus.committed,
        nowUtc=checkedAtUtc,
    )

    assert pendingOperation.status is UsageOperationStatus.pendingReconciliation
    assert committedOperation.status is UsageOperationStatus.committed
    with pytest.raises(InvalidUsageTransitionError):
        usagePolicy.transitionUsage(
            operationId=operation.operationId,
            targetStatus=UsageOperationStatus.released,
            nowUtc=checkedAtUtc,
        )


def test_提交只保存_prompt_版本和整数_usage_而不保存正文(tmp_path: Path) -> None:
    database, accountId, _, usagePolicy = buildServices(tmp_path)
    operation = usagePolicy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="usage-metadata-001",
        requestFingerprint="usage-metadata-fingerprint",
    )

    committedOperation = usagePolicy.transitionUsage(
        operationId=operation.operationId,
        targetStatus=UsageOperationStatus.committed,
        promptVersion="basic-resume-compose.v1",
        inputTokens=321,
        outputTokens=654,
    )

    assert committedOperation.promptVersion == "basic-resume-compose.v1"
    assert committedOperation.inputTokens == 321
    assert committedOperation.outputTokens == 654
    with database.readConnection() as databaseConnection:
        columnNames = {
            str(column["name"])
            for column in databaseConnection.execute("PRAGMA table_info(usage_operations)")
        }
    assert {"prompt_version", "input_tokens", "output_tokens"} <= columnNames
    assert "provider_response" not in columnNames
    assert "resume_content" not in columnNames


def test_关闭并重开数据库后保留账号订阅和_operation(tmp_path: Path) -> None:
    database, accountId, subscriptionService, usagePolicy = buildServices(tmp_path)
    checkedAtUtc = datetime(2026, 10, 3, tzinfo=UTC)
    subscriptionService.setFakeProSubscription(
        accountId=accountId,
        startsAtUtc=checkedAtUtc - timedelta(days=1),
        endsAtUtc=checkedAtUtc + timedelta(days=29),
        nowUtc=checkedAtUtc,
    )
    originalOperation = usagePolicy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="restart-001",
        requestFingerprint="restart-fingerprint",
        nowUtc=checkedAtUtc,
    )

    reopenedDatabase = GatewayDatabase(database.databasePath)
    reopenedDatabase.initialize()
    reopenedUsagePolicy = UsagePolicyService(reopenedDatabase)
    recoveredOperation = reopenedUsagePolicy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="restart-001",
        requestFingerprint="restart-fingerprint",
        nowUtc=checkedAtUtc,
    )

    assert recoveredOperation == originalOperation
    assert (
        reopenedUsagePolicy.evaluateAccess(
            accountId=accountId,
            capability=ProductCapability.targetedResumeOptimization,
            nowUtc=checkedAtUtc,
        ).allowed
        is True
    )
