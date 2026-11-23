from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from agent_gateway.app import createApplication
from agent_gateway.prompt_registry import ReasoningProfile
from agent_gateway.remote_contracts import MissingInformation, RemoteResumeAiRequest
from agent_gateway.remote_provider import (
    InvalidRemoteProviderResponseError,
    RemoteProviderGeneration,
)
from agent_gateway.usage import (
    INVALID_CANDIDATE_USAGE_UNKNOWN,
    MonthlyQuotaExhaustedError,
    ProductCapability,
    UsageOperationStatus,
    UsagePolicyService,
)
from tests.support import sendAsgiRequest
from tests.test_original_result_recovery import cache_at
from tests.test_remote_gateway import (
    FailingRemoteProvider,
    RecordingRemoteProvider,
    accountHeaders,
    basicRequestBody,
    buildRemoteApplication,
)
from tests.test_usage_policy import buildServices

BASIC = ProductCapability.basicResumeCompose
TARGETED = ProductCapability.targetedResumeOptimization
NOW = datetime(2026, 10, 17, tzinfo=UTC)


def test_clarification_keeps_actual_usage_but_does_not_spend_a_candidate(
    tmp_path: Path,
) -> None:
    class ClarifyingProvider(RecordingRemoteProvider):
        async def generate(
            self, request: RemoteResumeAiRequest, *, reasoningProfile: ReasoningProfile
        ) -> RemoteProviderGeneration:
            generated = await super().generate(request, reasoningProfile=reasoningProfile)
            return RemoteProviderGeneration(
                output=generated.output.model_copy(
                    update={
                        "missingInformation": (
                            MissingInformation(path="/projects", question="请补充实际参与的工作"),
                        )
                    }
                ),
                promptVersion=generated.promptVersion,
                inputTokens=generated.inputTokens,
                outputTokens=generated.outputTokens,
                usesNetwork=True,
            )

    provider = ClarifyingProvider(usesNetwork=True)
    original, database, owner, token, _ = buildRemoteApplication(tmp_path, provider)
    application = createApplication(
        settings=original.state.settings,
        accountService=original.state.accountService,
        usagePolicy=original.state.usagePolicy,
        remoteResumeProvider=provider,
        remoteResultCache=cache_at(tmp_path / "results"),
    )
    submitted = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers={**accountHeaders(token), "X-Result-Recovery": "0.1.0"},
        jsonBody=basicRequestBody(),
    )
    assert submitted.status_code == 200
    lookup = {
        "protocolVersion": "0.4.0",
        "capability": BASIC.value,
        "idempotencyKey": "basic-generation-001",
    }
    for _ in range(2):
        recovered = sendAsgiRequest(
            application,
            "POST",
            "/v1/resume-ai/results/lookup",
            headers=accountHeaders(token),
            jsonBody=lookup,
        )
        assert recovered.json() == submitted.json()
    assert provider.generateCallCount == 1
    policy = UsagePolicyService(database)
    assert policy.evaluateAccess(accountId=owner, capability=BASIC).remainingMonthlyGenerations == 9
    operation = policy.findOwnedOperation(
        accountId=owner, capability=BASIC, idempotencyKey="basic-generation-001"
    )
    assert operation is not None
    assert operation.status is UsageOperationStatus.committed
    assert (operation.inputTokens, operation.outputTokens) == (17, 29)
    assert not operation.quotaOccupied


@pytest.mark.parametrize("capability,limit", [(BASIC, 99), (TARGETED, 60)])
def test_member_has_a_real_hard_cap(
    tmp_path: Path, capability: ProductCapability, limit: int
) -> None:
    _, owner, subscriptions, policy = buildServices(tmp_path)
    subscriptions.setFakeProSubscription(
        accountId=owner,
        startsAtUtc=NOW - timedelta(days=1),
        endsAtUtc=NOW + timedelta(days=1),
        nowUtc=NOW,
    )
    for index in range(limit):
        policy.reserveUsage(
            accountId=owner,
            capability=capability,
            idempotencyKey=f"candidate-{index}",
            requestFingerprint="f",
            nowUtc=NOW,
        )
    with pytest.raises(MonthlyQuotaExhaustedError):
        policy.reserveUsage(
            accountId=owner,
            capability=capability,
            idempotencyKey="over-cap",
            requestFingerprint="f",
            nowUtc=NOW,
        )
    assert (
        policy.evaluateAccess(
            accountId=owner, capability=capability, nowUtc=NOW
        ).remainingMonthlyGenerations
        == 0
    )


def test_legacy_conversation_results_share_targeted_pool_and_history_is_not_reset(
    tmp_path: Path,
) -> None:
    database, owner, _, policy = buildServices(tmp_path)
    for index in range(5):
        operation = policy.reserveUsage(
            accountId=owner,
            capability=TARGETED if index % 2 else ProductCapability.resumeOptimizationConversation,
            idempotencyKey=f"legacy-{index}",
            requestFingerprint="f",
            nowUtc=NOW,
        )
        policy.transitionUsage(
            operationId=operation.operationId, targetStatus=UsageOperationStatus.committed
        )
    # Previous versions used UTC windows. Counting by creation date retains these rows.
    with database.immediateTransaction() as connection:
        connection.execute(
            "UPDATE usage_operations SET quota_window_start_utc = ?, quota_window_end_utc = ?",
            ("2026-10-01T00:00:00.000000Z", "2026-11-01T00:00:00.000000Z"),
        )
    assert not policy.evaluateAccess(accountId=owner, capability=TARGETED, nowUtc=NOW).allowed
    assert (
        policy.evaluateAccess(
            accountId=owner, capability=BASIC, nowUtc=NOW
        ).remainingMonthlyGenerations
        == 9
    )
    # Midnight Beijing starts the next calendar month, even before UTC midnight.
    assert (
        policy.evaluateAccess(
            accountId=owner, capability=TARGETED, nowUtc=datetime(2026, 10, 31, 16, tzinfo=UTC)
        ).remainingMonthlyGenerations
        == 5
    )


def test_new_quota_endpoint_and_exact_legacy_contract_coexist(tmp_path: Path) -> None:
    application, _, _, token, _ = buildRemoteApplication(tmp_path, RecordingRemoteProvider())
    legacy = sendAsgiRequest(
        application, "GET", f"/v1/account/access/{TARGETED.value}", headers=accountHeaders(token)
    )
    assert set(legacy.json()) == {
        "protocolVersion",
        "capability",
        "plan",
        "allowed",
        "reason",
        "remainingMonthlyBasicGenerations",
    }
    assert legacy.json()["allowed"] is True
    new = sendAsgiRequest(
        application, "GET", f"/v1/account/quota/{TARGETED.value}", headers=accountHeaders(token)
    )
    assert new.json()["monthlyLimit"] == new.json()["remainingMonthlyGenerations"] == 5
    assert new.json()["countingUnit"] == "usableCandidate"
    assert datetime.fromisoformat(new.json()["resetsAtUtc"]).hour == 16


def test_known_rejection_stays_zero_candidates_after_cost_reconciliation(tmp_path: Path) -> None:
    _, owner, _, policy = buildServices(tmp_path)
    operation = policy.reserveUsage(
        accountId=owner,
        capability=BASIC,
        idempotencyKey="invalid-output",
        requestFingerprint="f",
        nowUtc=NOW,
    )
    pending = policy.transitionUsage(
        operationId=operation.operationId,
        targetStatus=UsageOperationStatus.pendingReconciliation,
        failureCode=INVALID_CANDIDATE_USAGE_UNKNOWN,
        nowUtc=NOW,
    )
    assert not pending.quotaOccupied
    reconciled = policy.reconcileUsage(
        operationId=operation.operationId,
        operatorId="synthetic",
        evidenceSha256="a" * 64,
        evidenceKind="executed",
        promptVersion="synthetic.v1",
        inputTokens=12,
        outputTokens=34,
        nowUtc=NOW,
    )
    assert reconciled.status is UsageOperationStatus.committed
    assert not reconciled.quotaOccupied
    assert (reconciled.inputTokens, reconciled.outputTokens) == (12, 34)
    assert (
        policy.evaluateAccess(
            accountId=owner, capability=BASIC, nowUtc=NOW
        ).remainingMonthlyGenerations
        == 9
    )


@pytest.mark.parametrize("usageKnown", [False, True])
def test_rejected_candidate_charges_zero_but_retains_execution_cost_state(
    tmp_path: Path,
    usageKnown: bool,
) -> None:
    error = InvalidRemoteProviderResponseError(
        promptVersion="synthetic.v1" if usageKnown else None,
        inputTokens=17 if usageKnown else None,
        outputTokens=29 if usageKnown else None,
    )
    application, _, owner, token, _ = buildRemoteApplication(tmp_path, FailingRemoteProvider(error))
    response = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(token),
        jsonBody=basicRequestBody(),
    )
    assert response.status_code == 502
    policy = application.state.usagePolicy
    operation = policy.findOwnedOperation(
        accountId=owner, capability=BASIC, idempotencyKey="basic-generation-001"
    )
    assert operation is not None and not operation.quotaOccupied
    assert operation.status == (
        UsageOperationStatus.committed if usageKnown else UsageOperationStatus.pendingReconciliation
    )
    assert policy.evaluateAccess(accountId=owner, capability=BASIC).remainingMonthlyGenerations == 9
    lookup = {
        "protocolVersion": "0.4.0",
        "capability": BASIC.value,
        "idempotencyKey": "basic-generation-001",
    }
    legacy = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/operations/lookup",
        headers=accountHeaders(token),
        jsonBody=lookup,
    )
    assert legacy.json()["quotaOccupied"] is True
    new = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/operations/lookup",
        headers={**accountHeaders(token), "X-Quota-Contract": "usableCandidate.v1"},
        jsonBody=lookup,
    )
    assert new.json()["quotaOccupied"] is False
    if not usageKnown:
        assert new.json()["nextAction"] == "explicitNewRequest"
