from __future__ import annotations

import hashlib
import re
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta, timezone
from enum import StrEnum
from typing import Literal
from uuid import uuid4

from .database import GatewayDatabase
from .identity import requireUtc, toUtcText
from .open_test import OpenTestPolicy, openTestActive
from .usage_storage import SqliteUsageStore, UsageStore, UsageTransaction

FREE_MONTHLY_BASIC_LIMIT = 9
NO_USABLE_CANDIDATE = "no_usable_candidate"
INVALID_CANDIDATE_USAGE_UNKNOWN = "invalid_candidate_usage_unknown"
BEIJING = timezone(timedelta(hours=8))
AccessDecisionReason = Literal["allowed", "subscription_required", "quota_exhausted"]


class ProductCapability(StrEnum):
    basicResumeCompose = "basicResumeCompose"
    targetedResumeOptimization = "targetedResumeOptimization"
    resumeOptimizationConversation = "resumeOptimizationConversation"


class SubscriptionPlan(StrEnum):
    free = "free"
    pro = "pro"


class UsageOperationStatus(StrEnum):
    reserved = "reserved"
    committed = "committed"
    released = "released"
    pendingReconciliation = "pendingReconciliation"


class SubscriptionRequiredError(RuntimeError):
    pass


class MonthlyQuotaExhaustedError(RuntimeError):
    pass


class IdempotencyConflictError(RuntimeError):
    pass


class InvalidUsageTransitionError(RuntimeError):
    pass


class UsageOperationNotFoundError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class AccessDecision:
    capability: ProductCapability
    plan: SubscriptionPlan
    allowed: bool
    reason: AccessDecisionReason
    remainingMonthlyBasicGenerations: int | None
    monthlyLimit: int
    remainingMonthlyGenerations: int
    resetsAtUtc: datetime
    isUnlimited: bool = False


@dataclass(frozen=True, slots=True)
class UsageOperation:
    operationId: str
    accountId: str
    capability: ProductCapability
    status: UsageOperationStatus
    planAtReservation: SubscriptionPlan
    quotaWindowStartUtc: datetime
    quotaWindowEndUtc: datetime
    promptVersion: str | None
    inputTokens: int | None
    outputTokens: int | None
    failureCode: str | None = None

    @property
    def quotaOccupied(self) -> bool:
        return self.status is not UsageOperationStatus.released and self.failureCode not in {
            NO_USABLE_CANDIDATE,
            INVALID_CANDIDATE_USAGE_UNKNOWN,
        }


@dataclass(frozen=True, slots=True)
class UsageReservation:
    operation: UsageOperation
    isReplay: bool


class SubscriptionService:
    def __init__(self, database: GatewayDatabase | UsageStore) -> None:
        self._store = (
            SqliteUsageStore(database) if isinstance(database, GatewayDatabase) else database
        )

    def setFakeProSubscription(
        self,
        *,
        accountId: str,
        startsAtUtc: datetime,
        endsAtUtc: datetime,
        nowUtc: datetime | None = None,
    ) -> None:
        normalizedStart = requireUtc(startsAtUtc)
        normalizedEnd = requireUtc(endsAtUtc)
        if normalizedStart >= normalizedEnd:
            raise ValueError("订阅结束时间必须晚于开始时间")
        updatedAtUtc = requireUtc(nowUtc or datetime.now(UTC))
        with self._store.transaction() as connection:
            connection.lockAccount(accountId)
            connection.setFakeSubscription(
                accountId,
                toUtcText(normalizedStart),
                toUtcText(normalizedEnd),
                toUtcText(updatedAtUtc),
            )


class UsagePolicyService:
    def __init__(
        self,
        database: GatewayDatabase | UsageStore,
        *,
        guest: bool = False,
        openTestPolicy: OpenTestPolicy | None = None,
    ) -> None:
        self._openTestPolicy = openTestPolicy
        self._guest = guest
        self._database = database if isinstance(database, GatewayDatabase) else None
        self._store = (
            SqliteUsageStore(database) if isinstance(database, GatewayDatabase) else database
        )

    @property
    def database(self) -> GatewayDatabase:
        if self._database is None:
            raise ValueError("独立用量存储没有 SQLite 数据库")
        return self._database

    @property
    def authorityKey(self) -> tuple[str, ...]:
        return self._store.authorityKey

    def findOwnedOperation(
        self,
        *,
        accountId: str,
        capability: ProductCapability,
        usageOperationId: str | None = None,
        idempotencyKey: str | None = None,
    ) -> UsageOperation | None:
        if (usageOperationId is None) == (idempotencyKey is None):
            raise ValueError("必须提供一个查询键")
        key = usageOperationId if usageOperationId is not None else idempotencyKey
        if key is None:
            raise ValueError("查询键缺失")
        self._validateOperationKey(key, fieldName="lookupKey")
        value = key if usageOperationId is not None else hashOperationValue(key)
        with self._store.readConnection() as connection:
            row = connection.findOwned(
                accountId, capability.value, value, usageOperationId is not None
            )
        return None if row is None else usageOperationFromRow(row)

    def markAbandonedReservations(self, *, beforeUtc: datetime) -> int:
        # 超过处理窗口只改为未知，不证明推理未发生，不释放额度。
        with self._store.transaction() as connection:
            return connection.markAbandoned(toUtcText(requireUtc(beforeUtc)))

    def reconcileUsage(
        self,
        *,
        operationId: str,
        operatorId: str,
        evidenceSha256: str,
        evidenceKind: Literal["executed", "notExecuted"],
        promptVersion: str | None = None,
        inputTokens: int | None = None,
        outputTokens: int | None = None,
        nowUtc: datetime | None = None,
    ) -> UsageOperation:
        if not re.fullmatch(r"[A-Za-z0-9._:-]{1,64}", operatorId) or not re.fullmatch(
            r"[a-f0-9]{64}", evidenceSha256
        ):
            raise ValueError("处置人标识和证据摘要无效")
        if evidenceKind not in {"executed", "notExecuted"}:
            raise ValueError("没有执行证据时必须保留未知")
        metadata = (promptVersion, inputTokens, outputTokens)
        if evidenceKind == "executed":
            if (
                promptVersion is None
                or inputTokens is None
                or outputTokens is None
                or inputTokens < 0
                or outputTokens < 0
            ):
                raise ValueError("执行凭证须包含 Prompt 版本与完整 token 用量")
        elif any(value is not None for value in metadata):
            raise ValueError("未执行证明不应包含生成用量")
        target = (
            UsageOperationStatus.committed
            if evidenceKind == "executed"
            else UsageOperationStatus.released
        )
        now = requireUtc(nowUtc or datetime.now(UTC))
        with self._store.transaction() as connection:
            row = connection.findOperation(operationId, lock=True)
            if row is None:
                raise UsageOperationNotFoundError
            previous = connection.findReconciliation(operationId)
            if previous is not None:
                if (
                    previous["evidence_sha256"] != evidenceSha256
                    or previous["evidence_kind"] != evidenceKind
                    or previous["operator_id"] != operatorId
                    or UsageOperationStatus(str(row["status"])) is not target
                    or (row["prompt_version"], row["input_tokens"], row["output_tokens"])
                    != metadata
                ):
                    raise InvalidUsageTransitionError
                return usageOperationFromRow(row)
            if row["status"] != UsageOperationStatus.pendingReconciliation.value:
                raise InvalidUsageTransitionError
            connection.insertReconciliation(
                operationId, operatorId, evidenceSha256, evidenceKind, toUtcText(now)
            )
            connection.updateOperation(
                operationId,
                target.value,
                toUtcText(now),
                # Cost evidence alone does not prove delivery of a usable result.
                NO_USABLE_CANDIDATE if evidenceKind == "executed" else "operator_reconciled",
                promptVersion,
                inputTokens,
                outputTokens,
                replaceMetadata=True,
            )
            finalRow = connection.findOperation(operationId)
            if finalRow is None:
                raise UsageOperationNotFoundError
            return usageOperationFromRow(finalRow)

    def evaluateAccess(
        self,
        *,
        accountId: str,
        capability: ProductCapability,
        nowUtc: datetime | None = None,
    ) -> AccessDecision:
        evaluatedAtUtc = requireUtc(nowUtc or datetime.now(UTC))
        monthStartUtc, nextMonthStartUtc = utcMonthWindow(evaluatedAtUtc)
        with self._store.readConnection() as databaseConnection:
            currentPlan = self._readCurrentPlan(
                databaseConnection,
                accountId=accountId,
                nowUtc=evaluatedAtUtc,
            )
            countedOperations = self._countMonthlyOperations(
                databaseConnection,
                accountId=accountId,
                capability=capability,
                monthStartUtc=monthStartUtc,
                nextMonthStartUtc=nextMonthStartUtc,
            )
        limit = monthlyCandidateLimit(currentPlan, capability, guest=self._guest)
        remainingGenerations = max(0, limit - countedOperations)
        unlimited = openTestActive(self._openTestPolicy, evaluatedAtUtc)
        return AccessDecision(
            capability=capability,
            plan=currentPlan,
            allowed=unlimited or remainingGenerations > 0,
            reason="allowed" if unlimited or remainingGenerations > 0 else "quota_exhausted",
            remainingMonthlyBasicGenerations=(
                remainingGenerations if capability is ProductCapability.basicResumeCompose else None
            ),
            monthlyLimit=limit,
            remainingMonthlyGenerations=remainingGenerations,
            resetsAtUtc=nextMonthStartUtc,
            isUnlimited=unlimited,
        )

    def reserveUsage(
        self,
        *,
        accountId: str,
        capability: ProductCapability,
        idempotencyKey: str,
        requestFingerprint: str,
        nowUtc: datetime | None = None,
    ) -> UsageOperation:
        return self.reserveUsageForExecution(
            accountId=accountId,
            capability=capability,
            idempotencyKey=idempotencyKey,
            requestFingerprint=requestFingerprint,
            nowUtc=nowUtc,
        ).operation

    def reserveUsageForExecution(
        self,
        *,
        accountId: str,
        capability: ProductCapability,
        idempotencyKey: str,
        requestFingerprint: str,
        nowUtc: datetime | None = None,
    ) -> UsageReservation:
        self._validateOperationKey(idempotencyKey, fieldName="idempotencyKey")
        self._validateOperationKey(requestFingerprint, fieldName="requestFingerprint")
        reservedAtUtc = requireUtc(nowUtc or datetime.now(UTC))
        monthStartUtc, nextMonthStartUtc = utcMonthWindow(reservedAtUtc)
        idempotencyKeyHash = hashOperationValue(idempotencyKey)
        requestFingerprintHash = hashOperationValue(requestFingerprint)

        with self._store.transaction() as databaseConnection:
            # 先锁同一账户，再建立读取快照；同键重放与最后一个成果名额检查在同一事务。
            # 不在事务内发送短信或执行 Provider，未知提交也不能返回执行资格。
            databaseConnection.lockAccount(accountId)
            existingRow = databaseConnection.findOwned(
                accountId, capability.value, idempotencyKeyHash, False
            )
            if existingRow is not None:
                if str(existingRow["request_fingerprint_hash"]) != requestFingerprintHash:
                    raise IdempotencyConflictError
                return UsageReservation(
                    operation=usageOperationFromRow(existingRow),
                    isReplay=True,
                )

            currentPlan = self._readCurrentPlan(
                databaseConnection,
                accountId=accountId,
                nowUtc=reservedAtUtc,
            )
            countedOperations = self._countMonthlyOperations(
                databaseConnection,
                accountId=accountId,
                capability=capability,
                monthStartUtc=monthStartUtc,
                nextMonthStartUtc=nextMonthStartUtc,
            )
            if not openTestActive(
                self._openTestPolicy, reservedAtUtc
            ) and countedOperations >= monthlyCandidateLimit(
                currentPlan, capability, guest=self._guest
            ):
                raise MonthlyQuotaExhaustedError

            operationId = f"usage-{uuid4()}"
            databaseConnection.insertReservation(
                operationId,
                accountId,
                capability.value,
                idempotencyKeyHash,
                requestFingerprintHash,
                toUtcText(monthStartUtc),
                toUtcText(nextMonthStartUtc),
                currentPlan.value,
                toUtcText(reservedAtUtc),
            )
            insertedRow = databaseConnection.findOperation(operationId)
            if insertedRow is None:
                raise RuntimeError("用量 operation 写入后无法读取")
            return UsageReservation(
                operation=usageOperationFromRow(insertedRow),
                isReplay=False,
            )

    def transitionUsage(
        self,
        *,
        operationId: str,
        targetStatus: UsageOperationStatus,
        failureCode: str | None = None,
        promptVersion: str | None = None,
        inputTokens: int | None = None,
        outputTokens: int | None = None,
        nowUtc: datetime | None = None,
    ) -> UsageOperation:
        if targetStatus is UsageOperationStatus.reserved:
            raise InvalidUsageTransitionError
        usageMetadata = (promptVersion, inputTokens, outputTokens)
        if failureCode == NO_USABLE_CANDIDATE and (
            targetStatus is not UsageOperationStatus.committed
            or any(value is None for value in usageMetadata)
        ):
            raise ValueError("无候选成果也必须保留完整已执行用量")
        if any(metadataValue is not None for metadataValue in usageMetadata):
            if (
                targetStatus is not UsageOperationStatus.committed
                or promptVersion is None
                or inputTokens is None
                or outputTokens is None
            ):
                raise ValueError("Prompt 版本与 token usage 只能完整写入 committed operation")
            if inputTokens < 0 or outputTokens < 0:
                raise ValueError("token usage 不能为负数")
        transitionedAtUtc = requireUtc(nowUtc or datetime.now(UTC))
        with self._store.transaction() as databaseConnection:
            operationRow = databaseConnection.findOperation(operationId, lock=True)
            if operationRow is None:
                raise UsageOperationNotFoundError
            currentStatus = UsageOperationStatus(str(operationRow["status"]))
            if currentStatus is targetStatus:
                # A retained complete receipt may prove a pre-upgrade call only
                # asked a question. Correct its result count without refunding
                # the provider call or rewriting execution/reconciliation data.
                if (
                    targetStatus is UsageOperationStatus.committed
                    and failureCode == NO_USABLE_CANDIDATE
                    and operationRow["failure_code"] is None
                ):
                    if (
                        operationRow["prompt_version"],
                        operationRow["input_tokens"],
                        operationRow["output_tokens"],
                    ) != usageMetadata:
                        raise InvalidUsageTransitionError
                    databaseConnection.updateOperation(
                        operationId,
                        targetStatus.value,
                        toUtcText(transitionedAtUtc),
                        failureCode,
                        promptVersion,
                        inputTokens,
                        outputTokens,
                    )
                    updated = databaseConnection.findOperation(operationId)
                    if updated is None:
                        raise UsageOperationNotFoundError
                    return usageOperationFromRow(updated)
                return usageOperationFromRow(operationRow)
            allowedTargets = {
                UsageOperationStatus.reserved: {
                    UsageOperationStatus.committed,
                    UsageOperationStatus.released,
                    UsageOperationStatus.pendingReconciliation,
                },
                UsageOperationStatus.pendingReconciliation: {
                    UsageOperationStatus.committed,
                    UsageOperationStatus.released,
                },
            }.get(currentStatus, set())
            if targetStatus not in allowedTargets:
                raise InvalidUsageTransitionError
            databaseConnection.updateOperation(
                operationId,
                targetStatus.value,
                toUtcText(transitionedAtUtc),
                failureCode,
                promptVersion,
                inputTokens,
                outputTokens,
            )
            updatedRow = databaseConnection.findOperation(operationId)
            if updatedRow is None:
                raise RuntimeError("用量 operation 更新后无法读取")
            return usageOperationFromRow(updatedRow)

    @staticmethod
    def _readCurrentPlan(
        databaseConnection: UsageTransaction,
        *,
        accountId: str,
        nowUtc: datetime,
    ) -> SubscriptionPlan:
        return SubscriptionPlan(databaseConnection.readPlan(accountId, toUtcText(nowUtc)))

    @staticmethod
    def _countMonthlyOperations(
        databaseConnection: UsageTransaction,
        *,
        accountId: str,
        capability: ProductCapability,
        monthStartUtc: datetime,
        nextMonthStartUtc: datetime,
    ) -> int:
        return databaseConnection.countMonthly(
            accountId,
            toUtcText(monthStartUtc),
            toUtcText(nextMonthStartUtc),
            basic=capability is ProductCapability.basicResumeCompose,
        )

    @staticmethod
    def _validateOperationKey(operationKey: str, *, fieldName: str) -> None:
        if not operationKey or len(operationKey) > 256:
            raise ValueError(f"{fieldName} 长度必须为 1-256")


def monthlyCandidateLimit(
    plan: SubscriptionPlan, capability: ProductCapability, *, guest: bool = False
) -> int:
    if guest:
        return 1
    basic = capability is ProductCapability.basicResumeCompose
    return (
        (99 if basic else 60)
        if plan is SubscriptionPlan.pro
        else (FREE_MONTHLY_BASIC_LIMIT if basic else 5)
    )


def utcMonthWindow(timestamp: datetime) -> tuple[datetime, datetime]:
    """Beijing calendar month, expressed in UTC; old rows remain counted by creation time."""
    local = requireUtc(timestamp).astimezone(BEIJING)
    start = datetime(local.year, local.month, 1, tzinfo=BEIJING)
    end = datetime(local.year + (local.month == 12), local.month % 12 + 1, 1, tzinfo=BEIJING)
    return start.astimezone(UTC), end.astimezone(UTC)


def hashOperationValue(operationValue: str) -> str:
    return hashlib.sha256(operationValue.encode("utf-8")).hexdigest()


def usageOperationFromRow(operationRow: Mapping[str, object]) -> UsageOperation:
    return UsageOperation(
        operationId=str(operationRow["operation_id"]),
        accountId=str(operationRow["account_id"]),
        capability=ProductCapability(str(operationRow["capability"])),
        status=UsageOperationStatus(str(operationRow["status"])),
        planAtReservation=SubscriptionPlan(str(operationRow["plan_at_reservation"])),
        quotaWindowStartUtc=parseUtcText(str(operationRow["quota_window_start_utc"])),
        quotaWindowEndUtc=parseUtcText(str(operationRow["quota_window_end_utc"])),
        promptVersion=(
            None if operationRow["prompt_version"] is None else str(operationRow["prompt_version"])
        ),
        inputTokens=(
            None if operationRow["input_tokens"] is None else int(str(operationRow["input_tokens"]))
        ),
        failureCode=None
        if operationRow["failure_code"] is None
        else str(operationRow["failure_code"]),
        outputTokens=(
            None
            if operationRow["output_tokens"] is None
            else int(str(operationRow["output_tokens"]))
        ),
    )


def parseUtcText(timestampText: str) -> datetime:
    return datetime.fromisoformat(timestampText.replace("Z", "+00:00")).astimezone(UTC)
