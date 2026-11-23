from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest

from agent_gateway.account_storage import StorageUnavailableError
from agent_gateway.app import createApplication
from agent_gateway.identity import FakePhoneOwnershipVerifier
from agent_gateway.prompt_registry import ReasoningProfile
from agent_gateway.remote_contracts import RemoteResumeAiRequest
from agent_gateway.remote_provider import RemoteProviderGeneration
from agent_gateway.remote_result_cache import RemoteResultCache
from agent_gateway.usage import ProductCapability, UsageOperationStatus
from tests.support import sendAsgiRequest
from tests.test_remote_gateway import (
    VALID_PASSWORD,
    RecordingRemoteProvider,
    accountHeaders,
    basicRequestBody,
    buildRemoteApplication,
)


def cache_at(directory: Path) -> RemoteResultCache:
    directory.mkdir(exist_ok=True)
    return RemoteResultCache(
        directory,
        protect=lambda value: b"test:" + value[::-1],
        unprotect=lambda value: value.removeprefix(b"test:")[::-1],
    )


def test_finished_original_is_recovered_after_restart_without_a_second_generation(
    tmp_path: Path,
) -> None:
    provider = RecordingRemoteProvider(usesNetwork=True)
    original, database, owner, token, _ = buildRemoteApplication(tmp_path, provider)
    cache = cache_at(tmp_path / "results")
    application = createApplication(
        settings=original.state.settings,
        accountService=original.state.accountService,
        usagePolicy=original.state.usagePolicy,
        remoteResumeProvider=provider,
        remoteResultCache=cache,
    )
    submitted = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers={
            **accountHeaders(token),
            "X-Result-Recovery": "0.1.0",
        },
        jsonBody=basicRequestBody(),
    )
    assert submitted.status_code == 200
    assert provider.generateCallCount == 1
    restarted_provider = RecordingRemoteProvider()
    restarted = createApplication(
        settings=original.state.settings,
        accountService=original.state.accountService,
        usagePolicy=original.state.usagePolicy,
        remoteResumeProvider=restarted_provider,
        remoteResultCache=cache_at(tmp_path / "results"),
    )
    lookup = {
        "protocolVersion": "0.4.0",
        "capability": "basicResumeCompose",
        "idempotencyKey": "basic-generation-001",
    }
    for _ in range(2):
        recovered = sendAsgiRequest(
            restarted,
            "POST",
            "/v1/resume-ai/results/lookup",
            headers=accountHeaders(token),
            jsonBody=lookup,
        )
        assert recovered.status_code == 200
        assert recovered.json() == submitted.json()
    assert restarted_provider.generateCallCount == 0
    with database.readConnection() as db:
        assert (
            db.execute("SELECT COUNT(*) FROM usage_operations WHERE status='committed'").fetchone()[
                0
            ]
            == 1
        )
    assert cache.read("another-owner", submitted.json()["operationId"]) is None
    unauthenticated = sendAsgiRequest(
        restarted, "POST", "/v1/resume-ai/results/lookup", jsonBody=lookup
    )
    assert unauthenticated.status_code == 401


def test_frontend_cancellation_does_not_cancel_original_paid_execution(tmp_path: Path) -> None:
    async def scenario() -> None:
        started, finish = asyncio.Event(), asyncio.Event()

        class GatedProvider(RecordingRemoteProvider):
            async def generate(
                self, request: RemoteResumeAiRequest, *, reasoningProfile: ReasoningProfile
            ) -> RemoteProviderGeneration:
                started.set()
                await finish.wait()
                return await super().generate(request, reasoningProfile=reasoningProfile)

        provider = GatedProvider(usesNetwork=True)
        original, _, _, token, _ = buildRemoteApplication(tmp_path, provider)
        application = createApplication(
            settings=original.state.settings,
            accountService=original.state.accountService,
            usagePolicy=original.state.usagePolicy,
            remoteResumeProvider=provider,
            remoteResultCache=cache_at(tmp_path / "results"),
        )
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=application), base_url="http://gateway.test"
        ) as client:
            posted = asyncio.create_task(
                client.post(
                    "/v1/resume-ai/requests",
                    headers={
                        **accountHeaders(token),
                        "X-Result-Recovery": "0.1.0",
                    },
                    json=basicRequestBody(),
                )
            )
            await asyncio.wait_for(started.wait(), timeout=2)
            posted.cancel()
            with pytest.raises(asyncio.CancelledError):
                await posted
            finish.set()
            for _ in range(30):
                recovered = await client.post(
                    "/v1/resume-ai/results/lookup",
                    headers=accountHeaders(token),
                    json={
                        "protocolVersion": "0.4.0",
                        "capability": "basicResumeCompose",
                        "idempotencyKey": "basic-generation-001",
                    },
                )
                if recovered.status_code == 200:
                    break
                await asyncio.sleep(0.02)
            assert recovered.status_code == 200
            assert provider.generateCallCount == 1

    asyncio.run(scenario())


def test_complete_receipt_repairs_only_original_usage_after_commit_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    provider = RecordingRemoteProvider(usesNetwork=True)
    original, database, _, token, _ = buildRemoteApplication(tmp_path, provider)
    policy = original.state.usagePolicy
    transition = policy.transitionUsage

    def fail_commit(**kwargs: object) -> object:
        if kwargs["targetStatus"] is UsageOperationStatus.committed:
            raise StorageUnavailableError("synthetic commit fault")
        return transition(**kwargs)

    monkeypatch.setattr(policy, "transitionUsage", fail_commit)
    application = createApplication(
        settings=original.state.settings,
        accountService=original.state.accountService,
        usagePolicy=policy,
        remoteResumeProvider=provider,
        remoteResultCache=cache_at(tmp_path / "results"),
    )
    failed = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers={
            **accountHeaders(token),
            "X-Result-Recovery": "0.1.0",
        },
        jsonBody=basicRequestBody(),
        raiseAppExceptions=False,
    )
    assert failed.status_code >= 500
    monkeypatch.setattr(policy, "transitionUsage", transition)
    recovered = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/results/lookup",
        headers=accountHeaders(token),
        jsonBody={
            "protocolVersion": "0.4.0",
            "capability": "basicResumeCompose",
            "idempotencyKey": "basic-generation-001",
        },
    )
    assert recovered.status_code == 200
    assert provider.generateCallCount == 1
    with database.readConnection() as db:
        row = db.execute(
            "SELECT status,input_tokens,output_tokens FROM usage_operations"
        ).fetchone()
        assert tuple(row) == ("committed", 17, 29)


def test_unavailable_result_capacity_releases_reservation_before_model_call(tmp_path: Path) -> None:
    provider = RecordingRemoteProvider(usesNetwork=True)
    original, database, _, token, _ = buildRemoteApplication(tmp_path, provider)
    cache = cache_at(tmp_path / "results")
    cache.maximumEntries = 0
    application = createApplication(
        settings=original.state.settings,
        accountService=original.state.accountService,
        usagePolicy=original.state.usagePolicy,
        remoteResumeProvider=provider,
        remoteResultCache=cache,
    )
    failed = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers={
            **accountHeaders(token),
            "X-Result-Recovery": "0.1.0",
        },
        jsonBody=basicRequestBody(),
    )
    assert failed.status_code == 503
    assert provider.generateCallCount == 0
    with database.readConnection() as db:
        assert db.execute("SELECT status FROM usage_operations").fetchone()[0] == "released"


def test_restart_during_execution_preserves_unknown_without_repeating_or_releasing(
    tmp_path: Path,
) -> None:
    provider = RecordingRemoteProvider(usesNetwork=True)
    original, database, owner, token, _ = buildRemoteApplication(tmp_path, provider)
    policy = original.state.usagePolicy
    operation = policy.reserveUsageForExecution(
        accountId=owner,
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="interrupted-original",
        requestFingerprint="synthetic-fingerprint",
    ).operation
    cache = cache_at(tmp_path / "results")
    cache.reserve(owner, operation.operationId)
    restarted = createApplication(
        settings=original.state.settings,
        accountService=original.state.accountService,
        usagePolicy=policy,
        remoteResumeProvider=provider,
        remoteResultCache=cache_at(tmp_path / "results"),
    )
    for _ in range(2):
        recovered = sendAsgiRequest(
            restarted,
            "POST",
            "/v1/resume-ai/results/lookup",
            headers=accountHeaders(token),
            jsonBody={
                "protocolVersion": "0.4.0",
                "capability": "basicResumeCompose",
                "idempotencyKey": "interrupted-original",
            },
        )
        assert recovered.status_code == 409
    assert provider.generateCallCount == 0
    with database.readConnection() as db:
        assert tuple(db.execute("SELECT status,failure_code FROM usage_operations").fetchone()) == (
            "pendingReconciliation",
            "worker_interrupted",
        )


def test_known_completed_result_expiry_is_terminal_without_releasing_original_quota(
    tmp_path: Path,
) -> None:
    provider = RecordingRemoteProvider(usesNetwork=True)
    original, database, _, token, _ = buildRemoteApplication(tmp_path, provider)
    directory = tmp_path / "results"
    directory.mkdir()
    now = [1000.0]
    cache = RemoteResultCache(
        directory, protect=lambda b: b, unprotect=lambda b: b, clock=lambda: now[0]
    )
    application = createApplication(
        settings=original.state.settings,
        accountService=original.state.accountService,
        usagePolicy=original.state.usagePolicy,
        remoteResumeProvider=provider,
        remoteResultCache=cache,
    )
    assert (
        sendAsgiRequest(
            application,
            "POST",
            "/v1/resume-ai/requests",
            headers={**accountHeaders(token), "X-Result-Recovery": "0.1.0"},
            jsonBody=basicRequestBody(),
        ).status_code
        == 200
    )
    now[0] += cache.retentionSeconds
    recovered = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/results/lookup",
        headers=accountHeaders(token),
        jsonBody={
            "protocolVersion": "0.4.0",
            "capability": "basicResumeCompose",
            "idempotencyKey": "basic-generation-001",
        },
    )
    assert recovered.status_code == 410
    assert recovered.json()["error"]["code"] == "original_result_expired"
    assert provider.generateCallCount == 1
    with database.readConnection() as db:
        assert db.execute("SELECT status FROM usage_operations").fetchone()[0] == "committed"


def test_authenticated_other_account_cannot_lookup_original_by_operation_id(tmp_path: Path) -> None:
    provider = RecordingRemoteProvider(usesNetwork=True)
    original, _, _, token, _ = buildRemoteApplication(tmp_path, provider)
    service = original.state.accountService
    service.registerAccount(
        phoneE164="+15550005678",
        password=VALID_PASSWORD,
        verificationProof=FakePhoneOwnershipVerifier.developmentProof,
    )
    other = service.createSession(phoneE164="+15550005678", password=VALID_PASSWORD)
    application = createApplication(
        settings=original.state.settings,
        accountService=service,
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
    denied = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/results/lookup",
        headers=accountHeaders(other.sessionToken),
        jsonBody={
            "protocolVersion": "0.4.0",
            "capability": "basicResumeCompose",
            "usageOperationId": submitted.json()["operationId"],
        },
    )
    assert denied.status_code == 404
    assert "三年后端" not in denied.text
    assert provider.generateCallCount == 1


def test_basic_extraction_is_fast_also_for_paid_owner(tmp_path: Path) -> None:
    provider = RecordingRemoteProvider()
    application, _, owner, token, subscriptions = buildRemoteApplication(tmp_path, provider)
    now = datetime.now(UTC)
    subscriptions.setFakeProSubscription(
        accountId=owner, startsAtUtc=now - timedelta(days=1), endsAtUtc=now + timedelta(days=29)
    )
    assert (
        sendAsgiRequest(
            application,
            "POST",
            "/v1/resume-ai/requests",
            headers=accountHeaders(token),
            jsonBody=basicRequestBody(),
        ).status_code
        == 200
    )
    assert provider.reasoningProfiles == [ReasoningProfile.fast]


def test_result_lookup_keeps_existing_json_body_boundary_before_parsing(tmp_path: Path) -> None:
    provider = RecordingRemoteProvider()
    application, _, _, token, _ = buildRemoteApplication(tmp_path, provider)
    malformed = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/results/lookup",
        headers={**accountHeaders(token), "Content-Type": "text/plain"},
        content="{}",
    )
    assert malformed.status_code == 415
    oversized = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/results/lookup",
        headers={**accountHeaders(token), "Content-Type": "application/json"},
        content='{"padding":"' + "x" * 65536 + '"}',
    )
    assert oversized.status_code == 413
    assert provider.generateCallCount == 0
