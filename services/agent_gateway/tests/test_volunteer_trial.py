from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import httpx
import pytest

from agent_gateway.account_lifecycle import (
    AccountLifecycleService,
    FakeSmsSender,
    IdentityActionError,
)
from agent_gateway.account_storage import SqliteAccountDatabase
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier, toUtcText
from agent_gateway.prompt_registry import ReasoningProfile
from agent_gateway.remote_contracts import RemoteResumeAiRequest
from agent_gateway.remote_provider import (
    GlmProviderConfig,
    GlmRemoteResumeProvider,
    RemoteProviderOutcomeUnknownError,
)
from agent_gateway.sms_budget import SmsBudgetExceededError, SmsBudgetLedger, SmsBudgetPolicy
from agent_gateway.volunteer_trial import (
    TrialAdmissionClosedError,
    TrialModelBudget,
    VolunteerTrialPolicy,
    loadVolunteerTrialPolicy,
)

NOW = datetime(2026, 10, 17, tzinfo=UTC)
SECRET = b"synthetic-volunteer-audit-key-32-bytes"


def policy(maximum: int = 2) -> VolunteerTrialPolicy:
    return VolunteerTrialPolicy(True, NOW + timedelta(days=10), maximum, 20, 120, 6)


def count(path: Path) -> int:
    with sqlite3.connect(path) as db:
        return int(db.execute("SELECT COUNT(*) FROM trial_dispatches").fetchone()[0])


def test_normal_startup_never_recreates_missing_dispatch_ledger(tmp_path: Path) -> None:
    path = tmp_path / "model.sqlite3"
    with pytest.raises(ValueError, match="not_provisioned"):
        TrialModelBudget(path, policy())
    assert not path.exists()


def test_restart_policy_changes_and_disabled_switch_do_not_replenish(tmp_path: Path) -> None:
    path = tmp_path / "model.sqlite3"
    TrialModelBudget(path, policy(), initialize=True).reserve(nowUtc=NOW)
    with pytest.raises(ValueError, match="changed_without_reconciliation"):
        TrialModelBudget(path, policy(3))
    disabled = TrialModelBudget(path, replace(policy(), enabled=False))
    with pytest.raises(TrialAdmissionClosedError):
        disabled.reserve(nowUtc=NOW)
    reopened = TrialModelBudget(path, policy())
    reopened.reserve(nowUtc=NOW)
    with pytest.raises(TrialAdmissionClosedError):
        reopened.reserve(nowUtc=NOW)
    assert count(path) == 2


def test_global_concurrent_dispatch_limit_is_atomic(tmp_path: Path) -> None:
    path = tmp_path / "model.sqlite3"
    budget = TrialModelBudget(path, policy(3), initialize=True)

    def attempt(_: int) -> bool:
        try:
            budget.reserve(nowUtc=NOW)
            return True
        except TrialAdmissionClosedError:
            return False

    with ThreadPoolExecutor(max_workers=8) as executor:
        assert sum(executor.map(attempt, range(20))) == 3
    assert count(path) == 3


def test_expired_policy_can_load_but_never_dispatch(tmp_path: Path) -> None:
    path = tmp_path / "model.sqlite3"
    budget = TrialModelBudget(path, policy(), initialize=True)
    with pytest.raises(TrialAdmissionClosedError):
        budget.reserve(nowUtc=NOW + timedelta(days=11))
    assert count(path) == 0


@pytest.mark.parametrize(
    "mutation",
    [
        {"enabled": 1},
        {"schemaVersion": True},
        {"maximumModelStarts": 0},
        {"smsReservePerAttemptCents": 5},
        {"unexpected": 1},
        {"smsMaximumAttempts": True},
    ],
)
def test_trial_file_rejects_unapproved_shapes(tmp_path: Path, mutation: dict[str, object]) -> None:
    values: dict[str, object] = dict(
        schemaVersion=1,
        enabled=True,
        expiresAtUtc="2026-10-24T00:00:00Z",
        maximumModelStarts=40,
        smsMaximumAttempts=20,
        smsBudgetCents=120,
        smsReservePerAttemptCents=6,
    )
    values.update(mutation)
    path = tmp_path / "policy.json"
    path.write_text(json.dumps(values), encoding="utf-8")
    with pytest.raises(ValueError):
        loadVolunteerTrialPolicy(path)


def test_duplicate_trial_keys_are_rejected(tmp_path: Path) -> None:
    path = tmp_path / "policy.json"
    path.write_text('{"enabled":true,"enabled":false}', encoding="utf-8")
    with pytest.raises(ValueError, match="duplicate"):
        loadVolunteerTrialPolicy(path)


def test_legacy_sms_fingerprint_is_unchanged(tmp_path: Path) -> None:
    db = GatewayDatabase(tmp_path / "sms.sqlite3")
    db.initialize()
    old = SmsBudgetPolicy(2, 12, 6, NOW + timedelta(days=1), frozenset({"+8613800000000"}))
    store = SqliteAccountDatabase(db)
    ledger = SmsBudgetLedger(store, old, auditSecret=SECRET)
    ledger.createApprovedPolicy(nowUtc=NOW)
    canonical = json.dumps(
        dict(
            maximumAttempts=2,
            budgetCents=12,
            reservePerAttemptCents=6,
            expiresAtUtc=toUtcText(old.expiresAtUtc),
            allowedPhones=sorted(old.allowedPhones),
        ),
        separators=(",", ":"),
    )
    expected = hmac.new(SECRET, ("policy:" + canonical).encode(), hashlib.sha256).hexdigest()
    with db.readConnection() as connection:
        assert (
            connection.execute("SELECT policy_fingerprint FROM sms_send_budget").fetchone()[0]
            == expected
        )
    with pytest.raises(ValueError, match="mismatch"):
        SmsBudgetLedger(store, policy().smsPolicy(), auditSecret=SECRET).assertApprovedPolicy()


def test_public_sms_remains_register_only_and_preserves_budget(tmp_path: Path) -> None:
    db = GatewayDatabase(tmp_path / "sms.sqlite3")
    db.initialize()
    public = replace(policy().smsPolicy(), maximumAttempts=2, budgetCents=12)
    ledger = SmsBudgetLedger(SqliteAccountDatabase(db), public, auditSecret=SECRET)
    ledger.createApprovedPolicy(nowUtc=NOW)
    for phone in ("+8613800000000", "+8613900000001"):
        ledger.reserve("challenge-" + str(uuid4()), phone, "register", nowUtc=NOW)
    with pytest.raises(SmsBudgetExceededError):
        ledger.reserve("challenge-" + str(uuid4()), "+8613900000002", "register", nowUtc=NOW)
    with pytest.raises(ValueError, match="not_allowed"):
        ledger.reserve("challenge-" + str(uuid4()), "+8613800000000", "resetPassword", nowUtc=NOW)
    disabled = SmsBudgetLedger(
        SqliteAccountDatabase(db), replace(public, enabled=False), auditSecret=SECRET
    )
    disabled.assertApprovedPolicy()
    with pytest.raises(SmsBudgetExceededError):
        disabled.reserve("challenge-" + str(uuid4()), "+8613900000003", "register", nowUtc=NOW)
    with db.readConnection() as connection:
        assert tuple(
            connection.execute("SELECT attempts,reserved_cents FROM sms_send_budget").fetchone()
        ) == (2, 12)


def test_ten_distinct_phones_can_register_on_shared_peer_but_phone_limit_stays(
    tmp_path: Path,
) -> None:
    now = datetime.now(UTC)
    db = GatewayDatabase(tmp_path / "identity.sqlite3")
    db.initialize()
    identity = AccountLifecycleService(
        AccountService(db, FakePhoneOwnershipVerifier()),
        FakeSmsSender(),
        otpSecret=SECRET,
        enableRecoveryCodes=True,
        trialPeerMaximum=20,
    )
    for index in range(10):
        phone = f"+86138{index:08d}"
        challenge = identity.issueCode(phone, "register", "shared-peer", nowUtc=now)
        assert challenge.developmentCode is not None
        identity.register(
            phone, "TestPass17!", challenge.challengeId, challenge.developmentCode, "shared-peer"
        )
        with pytest.raises(IdentityActionError):
            identity.issueCode(phone, "register", "other-peer", nowUtc=now)
    for _ in range(3):
        identity.issueCode("+8613900000000", "register", "shared-peer", nowUtc=now)
    with pytest.raises(IdentityActionError, match="identity_rate_limited"):
        identity.issueCode("+8613900000000", "register", "new-peer", nowUtc=now)


def basicRequest(text: str = "I built Flutter screens and REST APIs.") -> RemoteResumeAiRequest:
    return RemoteResumeAiRequest.model_validate(
        dict(
            protocolVersion="0.3.0",
            clientRequestId="trial-request",
            idempotencyKey="trial-idempotency",
            capability="basicResumeCompose",
            input=dict(
                inputType="basicResumeCompose",
                sourceFragments=[dict(fragmentId="fragment-1", category="work", text=text)],
            ),
        )
    )


def test_shared_provider_budget_stops_before_http_and_unknown_is_not_refunded(
    tmp_path: Path,
) -> None:
    path = tmp_path / "model.sqlite3"
    budget = TrialModelBudget(path, policy(1), initialize=True)
    networkCalls: list[str] = []

    async def transport(request: httpx.Request) -> httpx.Response:
        networkCalls.append(str(request.url))
        raise httpx.ReadTimeout("synthetic timeout")

    async def run() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig("synthetic-glm-key-for-tests"),
                httpClient=client,
                trialBudget=budget,
            )
            with pytest.raises(RemoteProviderOutcomeUnknownError):
                await provider.generate(basicRequest(), reasoningProfile=ReasoningProfile.fast)
            with pytest.raises(TrialAdmissionClosedError):
                await provider.generate(basicRequest(), reasoningProfile=ReasoningProfile.fast)

    asyncio.run(run())
    assert len(networkCalls) == count(path) == 1


def test_local_clarification_does_not_consume_model_budget(tmp_path: Path) -> None:
    path = tmp_path / "model.sqlite3"
    budget = TrialModelBudget(path, policy(1), initialize=True)

    async def forbidden(request: httpx.Request) -> httpx.Response:
        pytest.fail("Local clarification must not dispatch")

    async def run() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(forbidden)) as client:
            provider = GlmRemoteResumeProvider(
                GlmProviderConfig("synthetic-glm-key-for-tests"),
                httpClient=client,
                trialBudget=budget,
            )
            result = await provider.generate(
                basicRequest("帮我写简历"), reasoningProfile=ReasoningProfile.fast
            )
            assert not result.usesNetwork

    asyncio.run(run())
    assert budget.snapshot()["starts"] == 0


@pytest.mark.parametrize("guest", [False, True])
@pytest.mark.parametrize("recoverable", [False, True])
def test_closed_trial_releases_user_quota_for_both_identities(
    tmp_path: Path, guest: bool, recoverable: bool
) -> None:
    from agent_gateway.app import createApplication
    from agent_gateway.guest_identity import GuestIdentityService
    from tests.support import sendAsgiRequest
    from tests.test_original_result_recovery import cache_at
    from tests.test_remote_gateway import (
        FailingRemoteProvider,
        accountHeaders,
        basicRequestBody,
        buildRemoteApplication,
    )

    provider = FailingRemoteProvider(TrialAdmissionClosedError("trial_budget_exhausted"))
    base, _, accountId, token, _ = buildRemoteApplication(tmp_path, provider)
    guests = GuestIdentityService(tmp_path / "guests.db", maximumMonthlyCalls=4)
    application = createApplication(
        settings=base.state.settings,
        accountService=base.state.accountService,
        usagePolicy=base.state.usagePolicy,
        remoteResumeProvider=provider,
        remoteResultCache=cache_at(tmp_path / "results"),
        guestService=guests,
    )
    activePolicy = base.state.usagePolicy
    if guest:
        session = guests.createSession("a" * 64, clientAddress="synthetic")
        accountId, token = session.guestId, session.sessionToken
        activePolicy = guests.usagePolicy
    headers = accountHeaders(token)
    if recoverable:
        headers["X-Result-Recovery"] = "0.1.0"
    response = sendAsgiRequest(
        application, "POST", "/v1/resume-ai/requests", headers=headers, jsonBody=basicRequestBody()
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "trial_admission_closed"
    assert response.json()["error"]["retryable"] is False
    operation = activePolicy.findOwnedOperation(
        accountId=accountId,
        capability=basicRequest().capability,
        idempotencyKey="basic-generation-001",
    )
    assert operation is not None
    assert operation.status.value == "released" and not operation.quotaOccupied


def test_guarded_sms_plan_preserves_existing_attempts_and_cannot_replay(tmp_path: Path) -> None:
    from scripts.prepare_volunteer_trial import replacementSql

    db = GatewayDatabase(tmp_path / "sms.sqlite3")
    db.initialize()
    store = SqliteAccountDatabase(db)
    old = SmsBudgetPolicy(6, 36, 6, NOW + timedelta(days=1), frozenset({"+8613800000000"}))
    oldLedger = SmsBudgetLedger(store, old, auditSecret=SECRET)
    oldLedger.createApprovedPolicy(nowUtc=NOW)
    oldLedger.reserve("challenge-" + str(uuid4()), "+8613800000000", "register", nowUtc=NOW)
    target = SmsBudgetLedger(store, policy().smsPolicy(), auditSecret=SECRET)
    sql = replacementSql(
        oldLedger.approvedPolicySnapshot(), policy().smsPolicy(), target.policyFingerprint
    )
    with db.immediateTransaction() as connection:
        assert connection.execute(sql).rowcount == 1
        assert connection.execute(sql).rowcount == 0
    snapshot = target.approvedPolicySnapshot()
    assert snapshot["attempts"] == 1 and snapshot["reservedCents"] == 6
    assert snapshot["maximumAttempts"] == 20
    with db.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM sms_send_attempts").fetchone()[0] == 1


def test_pnvs_override_preserves_protected_secrets_without_changing_bundle(
    pnvsRuntimeFiles: Path,
) -> None:
    from agent_gateway.pnvs_runtime import loadPnvsRuntimeSettings

    path = pnvsRuntimeFiles / "runtime.dpapi"
    original = path.read_bytes()
    old = loadPnvsRuntimeSettings(path)
    new = loadPnvsRuntimeSettings(path, trialPolicy=policy())
    assert old.otpSecret == new.otpSecret and old.auditSecret == new.auditSecret
    assert new.policy.recipientScope == "unregistered" and not new.policy.allowedPhones
    assert path.read_bytes() == original


def test_trial_startup_check_only_never_creates_model_database(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from agent_gateway import protected_startup as startup
    from agent_gateway.settings import GatewaySettings

    secretDirectory = tmp_path / "secrets"
    secretDirectory.mkdir()
    trialDirectory = tmp_path / "volunteer-trial"
    trialDirectory.mkdir()
    settings = GatewaySettings(
        task018DatabasePath=tmp_path / "accounts.sqlite3",
        pnvsRuntimePath=secretDirectory / "runtime.dpapi",
        pnvsCredentialsPath=secretDirectory / "credentials.dpapi",
    )
    monkeypatch.setattr(startup, "loadProtectedPayload", lambda *args, **kwargs: "{}")
    monkeypatch.setattr(startup, "_settingsFromPayload", lambda payload: settings)
    monkeypatch.setattr(startup, "loadPnvsCredentials", lambda path: None)
    monkeypatch.setattr(startup, "loadPnvsRuntimeSettings", lambda *args, **kwargs: None)
    verified: list[Path] = []
    monkeypatch.setattr(startup, "verifyWindowsResultDirectory", verified.append)
    startupPath = secretDirectory / "startup.dpapi"
    with pytest.raises(startup.ProtectedStartupError):
        startup.loadStartupSettings(startupPath)
    (trialDirectory / "policy.json").write_text(
        json.dumps(
            dict(
                schemaVersion=1,
                enabled=True,
                expiresAtUtc="2000-01-01T00:00:00Z",
                maximumModelStarts=40,
                smsMaximumAttempts=20,
                smsBudgetCents=120,
                smsReservePerAttemptCents=6,
            )
        ),
        encoding="utf-8",
    )
    configured = startup.loadStartupSettings(startupPath)
    assert configured.volunteerTrialPolicyPath == trialDirectory / "policy.json"
    assert trialDirectory in verified
    assert not (trialDirectory / "model-dispatches.sqlite3").exists()
