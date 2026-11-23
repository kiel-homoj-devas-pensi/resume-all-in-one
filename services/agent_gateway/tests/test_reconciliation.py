from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from agent_gateway.account_storage import StorageUnavailableError
from agent_gateway.usage import (
    InvalidUsageTransitionError,
    ProductCapability,
    UsageOperationStatus,
    UsagePolicyService,
)
from tests.test_remote_gateway import RecordingRemoteProvider, buildRemoteApplication


@pytest.mark.parametrize("outcome", ["executed", "notExecuted"])
def test_中断只转未知且有证据处置与审计原子幂等(tmp_path: Path, outcome: str) -> None:
    _, database, accountId, _, _ = buildRemoteApplication(tmp_path, RecordingRemoteProvider())
    policy = UsagePolicyService(database)
    now = datetime.now(UTC)
    operation = policy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="interrupted-key",
        requestFingerprint="fingerprint",
        nowUtc=now - timedelta(minutes=10),
    )
    assert policy.markAbandonedReservations(beforeUtc=now - timedelta(minutes=5)) == 1
    unknown = policy.findOwnedOperation(
        accountId=accountId, capability=operation.capability, usageOperationId=operation.operationId
    )
    assert unknown is not None and unknown.status is UsageOperationStatus.pendingReconciliation
    assert (
        policy.evaluateAccess(
            accountId=accountId, capability=operation.capability
        ).remainingMonthlyBasicGenerations
        == 8
    )
    metadata = (
        {"promptVersion": "synthetic.v1", "inputTokens": 7, "outputTokens": 11}
        if outcome == "executed"
        else {}
    )
    arguments = dict(
        operationId=operation.operationId,
        operatorId="test-operator",
        evidenceSha256="a" * 64,
        evidenceKind=outcome,
        **metadata,
    )
    result = policy.reconcileUsage(**arguments)  # type: ignore[arg-type]
    assert result.status.value == ("committed" if outcome == "executed" else "released")
    assert not result.quotaOccupied
    assert (
        policy.evaluateAccess(
            accountId=accountId, capability=operation.capability
        ).remainingMonthlyGenerations
        == 9
    )
    if outcome == "executed":
        assert (result.inputTokens, result.outputTokens) == (7, 11)
    assert policy.reconcileUsage(**arguments) == result  # type: ignore[arg-type]
    with pytest.raises(InvalidUsageTransitionError):
        policy.reconcileUsage(**(arguments | {"evidenceSha256": "b" * 64}))  # type: ignore[arg-type]
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM usage_reconciliations").fetchone()[0] == 1


def test_审计写入失败回滚终结且无证据不能释放(tmp_path: Path) -> None:
    _, database, accountId, _, _ = buildRemoteApplication(tmp_path, RecordingRemoteProvider())
    policy = UsagePolicyService(database)
    operation = policy.reserveUsage(
        accountId=accountId,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="audit-key",
        requestFingerprint="fingerprint",
    )
    policy.transitionUsage(
        operationId=operation.operationId, targetStatus=UsageOperationStatus.pendingReconciliation
    )
    with database.immediateTransaction() as connection:
        connection.execute(
            "CREATE TRIGGER reject_audit BEFORE INSERT ON usage_reconciliations "
            "BEGIN SELECT RAISE(ABORT, 'test fault'); END;"
        )
    with pytest.raises(StorageUnavailableError, match="存储约束失败"):
        policy.reconcileUsage(
            operationId=operation.operationId,
            operatorId="operator",
            evidenceSha256="c" * 64,
            evidenceKind="notExecuted",
        )
    with pytest.raises(ValueError):
        policy.reconcileUsage(
            operationId=operation.operationId,
            operatorId="operator",
            evidenceSha256="c" * 64,
            evidenceKind="executed",
        )
    current = policy.findOwnedOperation(
        accountId=accountId, capability=operation.capability, usageOperationId=operation.operationId
    )
    assert current is not None and current.status is UsageOperationStatus.pendingReconciliation
