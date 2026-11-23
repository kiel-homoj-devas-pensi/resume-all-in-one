from collections.abc import Iterator
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from agent_gateway.account_storage import UnknownStorageCommitError
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.usage import (
    IdempotencyConflictError,
    InvalidUsageTransitionError,
    MonthlyQuotaExhaustedError,
    ProductCapability,
    SubscriptionService,
    UsageOperationStatus,
    UsagePolicyService,
)
from agent_gateway.usage_storage import SqliteUsageStore, UsageTransaction

NOW = datetime(2026, 10, 10, tzinfo=UTC)
BASIC = ProductCapability.basicResumeCompose


def prepare(path: Path) -> str:
    database = GatewayDatabase(path)
    database.initialize()
    return AccountService(database, FakePhoneOwnershipVerifier()).registerAccount(
        phoneE164="+15550002902",
        password="Usage029a!",
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
        nowUtc=NOW,
    )


def reserveWorker(arguments: tuple[str, str, str]) -> tuple[str, bool]:
    path, account, key = arguments
    policy = UsagePolicyService(SqliteUsageStore(GatewayDatabase(Path(path))))
    try:
        reservation = policy.reserveUsageForExecution(
            accountId=account,
            capability=BASIC,
            idempotencyKey=key,
            requestFingerprint="same-synthetic-fingerprint",
            nowUtc=NOW,
        )
        return reservation.operation.operationId, reservation.isReplay
    except MonthlyQuotaExhaustedError:
        return "quota_exhausted", False


@pytest.mark.parametrize("separateProcesses", [False, True])
def test_last_monthly_slot_has_one_winner_across_independent_writers(
    tmp_path: Path,
    separateProcesses: bool,
) -> None:
    path = tmp_path / "quota.db"
    account = prepare(path)
    for index in range(8):
        reserveWorker((str(path), account, f"seed-{index}"))
    executorType = ProcessPoolExecutor if separateProcesses else ThreadPoolExecutor
    with executorType(max_workers=2) as executor:
        results = list(
            executor.map(
                reserveWorker,
                [
                    (str(path), account, "tenth-a"),
                    (str(path), account, "tenth-b"),
                ],
            )
        )
    assert sum(result[0] == "quota_exhausted" for result in results) == 1
    policy = UsagePolicyService(SqliteUsageStore(GatewayDatabase(path)))
    assert (
        policy.evaluateAccess(
            accountId=account, capability=BASIC, nowUtc=NOW
        ).remainingMonthlyBasicGenerations
        == 0
    )


def test_same_request_has_one_execution_owner_across_processes(tmp_path: Path) -> None:
    path = tmp_path / "idempotency.db"
    account = prepare(path)
    arguments = (str(path), account, "one-stable-action")
    with ProcessPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(reserveWorker, [arguments, arguments]))
    assert results[0][0] == results[1][0]
    assert sorted(result[1] for result in results) == [False, True]
    policy = UsagePolicyService(SqliteUsageStore(GatewayDatabase(path)))
    with pytest.raises(IdempotencyConflictError):
        policy.reserveUsage(
            accountId=account,
            capability=BASIC,
            idempotencyKey=arguments[2],
            requestFingerprint="different",
            nowUtc=NOW,
        )


def test_committed_reservation_with_lost_ack_is_replayed_without_execution(tmp_path: Path) -> None:
    path = tmp_path / "unknown-commit.db"
    account = prepare(path)

    class LostCommitStore(SqliteUsageStore):
        @contextmanager
        def transaction(self) -> Iterator[UsageTransaction]:
            with super().transaction() as connection:
                yield connection
            raise UnknownStorageCommitError("合成提交确认丢失")

    with pytest.raises(UnknownStorageCommitError):
        UsagePolicyService(LostCommitStore(GatewayDatabase(path))).reserveUsageForExecution(
            accountId=account,
            capability=BASIC,
            idempotencyKey="stable-before-commit",
            requestFingerprint="same",
            nowUtc=NOW,
        )
    result = UsagePolicyService(SqliteUsageStore(GatewayDatabase(path))).reserveUsageForExecution(
        accountId=account,
        capability=BASIC,
        idempotencyKey="stable-before-commit",
        requestFingerprint="same",
        nowUtc=NOW,
    )
    assert result.isReplay
    assert result.operation.status is UsageOperationStatus.reserved


def test_reconciliation_competition_keeps_one_final_evidence(tmp_path: Path) -> None:
    path = tmp_path / "reconciliation.db"
    account = prepare(path)
    policy = UsagePolicyService(SqliteUsageStore(GatewayDatabase(path)))
    operation = policy.reserveUsage(
        accountId=account,
        capability=BASIC,
        idempotencyKey="to-reconcile",
        requestFingerprint="same",
        nowUtc=NOW,
    )
    policy.transitionUsage(
        operationId=operation.operationId,
        targetStatus=UsageOperationStatus.pendingReconciliation,
        nowUtc=NOW,
    )

    def reconcile(executed: bool) -> str:
        independent = UsagePolicyService(SqliteUsageStore(GatewayDatabase(path)))
        try:
            return independent.reconcileUsage(
                operationId=operation.operationId,
                operatorId="synthetic-reviewer",
                evidenceSha256=("a" if executed else "b") * 64,
                evidenceKind="executed" if executed else "notExecuted",
                promptVersion="synthetic-v1" if executed else None,
                inputTokens=2 if executed else None,
                outputTokens=3 if executed else None,
                nowUtc=NOW,
            ).status.value
        except InvalidUsageTransitionError:
            return "conflict"

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(reconcile, [False, True]))
    assert results.count("conflict") == 1
    with GatewayDatabase(path).readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM usage_reconciliations").fetchone()[0] == 1


def test_subscription_window_and_released_slot_survive_store_rebuild(tmp_path: Path) -> None:
    path = tmp_path / "subscription.db"
    account = prepare(path)
    store = SqliteUsageStore(GatewayDatabase(path))
    SubscriptionService(store).setFakeProSubscription(
        accountId=account, startsAtUtc=NOW, endsAtUtc=NOW + timedelta(days=1), nowUtc=NOW
    )
    policy = UsagePolicyService(SqliteUsageStore(GatewayDatabase(path)))
    assert policy.evaluateAccess(
        accountId=account, capability=ProductCapability.targetedResumeOptimization, nowUtc=NOW
    ).allowed
    assert policy.evaluateAccess(
        accountId=account,
        capability=ProductCapability.targetedResumeOptimization,
        nowUtc=NOW + timedelta(days=1),
    ).allowed
    operation = policy.reserveUsage(
        accountId=account,
        capability=BASIC,
        idempotencyKey="release-one",
        requestFingerprint="same",
        nowUtc=NOW + timedelta(days=1),
    )
    policy.transitionUsage(
        operationId=operation.operationId,
        targetStatus=UsageOperationStatus.released,
        nowUtc=NOW + timedelta(days=1),
    )
    assert (
        policy.evaluateAccess(
            accountId=account, capability=BASIC, nowUtc=NOW + timedelta(days=1)
        ).remainingMonthlyBasicGenerations
        == 9
    )
