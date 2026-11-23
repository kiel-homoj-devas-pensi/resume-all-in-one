from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from agent_gateway.app import createApplication
from agent_gateway.guest_identity import GuestIdentityService, GuestLimitError
from agent_gateway.identity import AuthenticationFailedError
from agent_gateway.usage import (
    NO_USABLE_CANDIDATE,
    MonthlyQuotaExhaustedError,
    ProductCapability,
    UsageOperationStatus,
)
from tests.support import sendAsgiRequest
from tests.test_original_result_recovery import cache_at
from tests.test_remote_gateway import (
    RecordingRemoteProvider,
    accountHeaders,
    basicRequestBody,
    buildRemoteApplication,
)

NOW = datetime(2026, 10, 17, tzinfo=UTC)
BASIC = ProductCapability.basicResumeCompose
TARGETED = ProductCapability.targetedResumeOptimization


def test_anonymous_restart_preserves_owner_and_both_monthly_limits(tmp_path: Path) -> None:
    path = tmp_path / "guests.db"
    first = GuestIdentityService(path, maximumMonthlyCalls=20)
    session = first.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
    policy = first.usagePolicy
    for capability in (BASIC, TARGETED):
        policy.reserveUsage(
            accountId=session.guestId,
            capability=capability,
            idempotencyKey=capability.value,
            requestFingerprint="f",
            nowUtc=NOW,
        )
    reopened = GuestIdentityService(path, maximumMonthlyCalls=20)
    renewed = reopened.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
    assert renewed.guestId == session.guestId
    with pytest.raises(AuthenticationFailedError):
        reopened.authenticate(session.sessionToken, nowUtc=NOW)
    assert reopened.authenticate(renewed.sessionToken, nowUtc=NOW) == session.guestId
    for capability in (BASIC, TARGETED):
        assert not reopened.usagePolicy.evaluateAccess(
            accountId=session.guestId, capability=capability, nowUtc=NOW
        ).allowed
        with pytest.raises(MonthlyQuotaExhaustedError):
            reopened.usagePolicy.reserveUsage(
                accountId=session.guestId,
                capability=capability,
                idempotencyKey="over",
                requestFingerprint="f",
                nowUtc=NOW,
            )
    assert reopened.usagePolicy.evaluateAccess(
        accountId=session.guestId, capability=BASIC, nowUtc=datetime(2026, 10, 31, 16, tzinfo=UTC)
    ).allowed
    with pytest.raises(AuthenticationFailedError):
        reopened.authenticate(renewed.sessionToken, nowUtc=NOW + timedelta(days=1))


def test_global_dispatch_limit_is_atomic_and_no_candidate_keeps_actual_cost_slot(
    tmp_path: Path,
) -> None:
    service = GuestIdentityService(tmp_path / "guests.db", maximumMonthlyCalls=1)
    owners = [
        service.createSession(character * 64, clientAddress="synthetic", nowUtc=NOW).guestId
        for character in "abc"
    ]

    def reserve(owner: str) -> str:
        try:
            return service.usagePolicy.reserveUsage(
                accountId=owner,
                capability=BASIC,
                idempotencyKey="one",
                requestFingerprint="f",
                nowUtc=NOW,
            ).operationId
        except GuestLimitError:
            return "blocked"

    with ThreadPoolExecutor(max_workers=3) as executor:
        results = list(executor.map(reserve, owners))
    assert results.count("blocked") == 2
    operationId = next(value for value in results if value != "blocked")
    committed = service.usagePolicy.transitionUsage(
        operationId=operationId,
        targetStatus=UsageOperationStatus.committed,
        failureCode=NO_USABLE_CANDIDATE,
        promptVersion="synthetic.v1",
        inputTokens=17,
        outputTokens=29,
        nowUtc=NOW,
    )
    assert not committed.quotaOccupied
    for owner in owners:
        with pytest.raises(GuestLimitError):
            service.usagePolicy.reserveUsage(
                accountId=owner,
                capability=TARGETED,
                idempotencyKey="another",
                requestFingerprint="f",
                nowUtc=NOW,
            )


def test_guest_token_is_only_for_ai_and_original_result_is_owner_isolated(tmp_path: Path) -> None:
    provider = RecordingRemoteProvider(usesNetwork=True)
    base, accountDatabase, _, _, _ = buildRemoteApplication(tmp_path, provider)
    guests = GuestIdentityService(tmp_path / "guests.db", maximumMonthlyCalls=4)
    application = createApplication(
        settings=base.state.settings,
        accountService=base.state.accountService,
        usagePolicy=base.state.usagePolicy,
        remoteResumeProvider=provider,
        remoteResultCache=cache_at(tmp_path / "results"),
        guestService=guests,
    )
    issued = sendAsgiRequest(
        application, "POST", "/v1/guest/sessions", jsonBody={"installationSecret": "a" * 64}
    )
    assert issued.status_code == 200
    token = issued.json()["sessionToken"]
    headers = {**accountHeaders(token), "X-Result-Recovery": "0.1.0"}
    for path in ("/v1/account/identity",):
        assert sendAsgiRequest(application, "GET", path, headers=headers).status_code == 401
    assert sendAsgiRequest(
        application, "GET", "/v1/account/privileges", headers=headers
    ).status_code in (401, 503)
    quota = sendAsgiRequest(application, "GET", f"/v1/account/quota/{BASIC.value}", headers=headers)
    assert quota.json()["monthlyLimit"] == quota.json()["remainingMonthlyGenerations"] == 1
    generated = sendAsgiRequest(
        application, "POST", "/v1/resume-ai/requests", headers=headers, jsonBody=basicRequestBody()
    )
    assert generated.status_code == 200
    lookup = {
        "protocolVersion": "0.4.0",
        "capability": BASIC.value,
        "idempotencyKey": "basic-generation-001",
    }
    assert (
        sendAsgiRequest(
            application, "POST", "/v1/resume-ai/results/lookup", headers=headers, jsonBody=lookup
        ).json()
        == generated.json()
    )
    other = guests.createSession("b" * 64, clientAddress="synthetic")
    assert (
        sendAsgiRequest(
            application,
            "POST",
            "/v1/resume-ai/results/lookup",
            headers=accountHeaders(other.sessionToken),
            jsonBody=lookup,
        ).status_code
        == 404
    )
    second = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=headers,
        jsonBody=basicRequestBody(idempotencyKey="second"),
    )
    assert second.status_code == 429
    assert provider.generateCallCount == 1
    with accountDatabase.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM usage_operations").fetchone()[0] == 0


def test_guest_issuance_is_bounded_and_is_disabled_without_explicit_configuration(
    tmp_path: Path,
) -> None:
    guests = GuestIdentityService(
        tmp_path / "guests.db", maximumMonthlyCalls=2, maximumDailyIssuancePerIp=1
    )
    first = guests.createSession("a" * 64, clientAddress="one", nowUtc=NOW)
    assert guests.createSession("a" * 64, clientAddress="one", nowUtc=NOW).guestId == first.guestId
    with pytest.raises(GuestLimitError):
        guests.createSession("b" * 64, clientAddress="one", nowUtc=NOW)
    application, _, _, _, _ = buildRemoteApplication(
        tmp_path / "disabled", RecordingRemoteProvider()
    )
    assert (
        sendAsgiRequest(
            application, "POST", "/v1/guest/sessions", jsonBody={"installationSecret": "a" * 64}
        ).status_code
        == 503
    )


def test_guest_deadline_stops_new_calls_but_keeps_existing_identity_for_recovery(
    tmp_path: Path,
) -> None:
    guests = GuestIdentityService(
        tmp_path / "guests.db", maximumMonthlyCalls=2, enabledUntilUtc=NOW + timedelta(hours=1)
    )
    first = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
    after = NOW + timedelta(hours=2)
    renewed = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=after)
    assert renewed.guestId == first.guestId
    with pytest.raises(GuestLimitError):
        guests.usagePolicy.reserveUsage(
            accountId=first.guestId,
            capability=BASIC,
            idempotencyKey="after-deadline",
            requestFingerprint="f",
            nowUtc=after,
        )
    with pytest.raises(GuestLimitError):
        guests.createSession("b" * 64, clientAddress="synthetic", nowUtc=after)
