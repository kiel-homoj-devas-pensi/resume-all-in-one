from __future__ import annotations

import json
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import pytest

from agent_gateway.account_storage import SqliteAccountDatabase
from agent_gateway.app import createApplication
from agent_gateway.guest_identity import GuestIdentityService, GuestLimitError
from agent_gateway.open_test import OpenTestPolicy, loadOpenTestPolicy
from agent_gateway.settings import GatewaySettings
from agent_gateway.sms_attempt_retention import SmsAttemptSummaryWorker
from agent_gateway.sms_budget import SmsAttemptReplayError, SmsBudgetExceededError, SmsBudgetLedger
from agent_gateway.usage import (
    IdempotencyConflictError,
    MonthlyQuotaExhaustedError,
    ProductCapability,
    UsageOperationStatus,
    UsagePolicyService,
)
from agent_gateway.volunteer_trial import TrialAdmissionClosedError, TrialModelBudget
from tests.support import sendAsgiRequest
from tests.test_original_result_recovery import cache_at
from tests.test_remote_gateway import RecordingRemoteProvider, accountHeaders
from tests.test_sms_attempt_retention import PHONE, SECRET, counts, make, seed
from tests.test_usage_policy import buildServices
from tests.test_volunteer_trial import count, policy

NOW = datetime(2026, 10, 22, 4, tzinfo=UTC)
BASIC = ProductCapability.basicResumeCompose
OPEN = OpenTestPolicy(True)
LEGACY_END = datetime(2026, 12, 31, 16, tzinfo=UTC)


def test_persistent_access_has_no_publication_or_year_end_deadline() -> None:
    assert GatewaySettings().openTestPolicy is None
    assert not OpenTestPolicy().isActive(NOW)
    assert OPEN.enabledUntilUtc is None
    for future in (LEGACY_END, datetime(2035, 1, 1, tzinfo=UTC), datetime(2100, 1, 1, tzinfo=UTC)):
        assert OPEN.isActive(future)
    assert not replace(OPEN, enabled=False).isActive(NOW)
    limited = OpenTestPolicy(True, LEGACY_END)
    assert limited.isActive(LEGACY_END - timedelta(microseconds=1))
    assert not limited.isActive(LEGACY_END)
    with pytest.raises(ValueError):
        OpenTestPolicy(True, datetime(2027, 1, 1))


@pytest.mark.parametrize(
    "mutation",
    [
        {"enabled": 1},
        {"schemaVersion": True},
        {"until": "2027"},
        {"enabledUntilUtc": "2027-01-01T00:00:00"},
    ],
)
def test_configuration_rejects_ambiguous_or_unapproved_values(
    tmp_path: Path, mutation: dict[str, object]
) -> None:
    path = tmp_path / "policy.json"
    values = dict(schemaVersion=1, enabled=True, enabledUntilUtc="2026-12-31T16:00:00Z")
    path.write_text(json.dumps(values | mutation), encoding="utf-8")
    with pytest.raises(ValueError):
        loadOpenTestPolicy(path)


def test_policy_loader_duplicate_fields_and_environment_opt_in(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = tmp_path / "policy.json"
    path.write_text('{"enabled":true,"enabled":false}', encoding="utf-8")
    with pytest.raises(ValueError, match="duplicate"):
        loadOpenTestPolicy(path)
    path.write_text(
        '{"schemaVersion":2,"enabled":true}',
        encoding="utf-8",
    )
    monkeypatch.setenv("AGENT_GATEWAY_OPEN_TEST_POLICY_PATH", str(path))
    assert GatewaySettings.fromEnvironment().openTestPolicy == OPEN


@pytest.mark.parametrize("guest", [False, True])
def test_unlimited_candidates_keep_real_counts_idempotency_and_restore_finite_rule(
    tmp_path: Path, guest: bool
) -> None:
    db, owner, _, _ = buildServices(tmp_path)
    usage = UsagePolicyService(db, guest=guest, openTestPolicy=OPEN)
    finite = 1 if guest else 9
    for index in range(finite + 3):
        operation = usage.reserveUsage(
            accountId=owner,
            capability=BASIC,
            idempotencyKey=f"op-{index}",
            requestFingerprint="same",
            nowUtc=NOW,
        )
        assert (
            usage.reserveUsage(
                accountId=owner,
                capability=BASIC,
                idempotencyKey=f"op-{index}",
                requestFingerprint="same",
                nowUtc=NOW,
            ).operationId
            == operation.operationId
        )
    decision = usage.evaluateAccess(accountId=owner, capability=BASIC, nowUtc=NOW)
    assert decision.isUnlimited and decision.allowed and decision.reason == "allowed"
    assert decision.remainingMonthlyGenerations == 0 and decision.monthlyLimit == finite
    with pytest.raises(IdempotencyConflictError):
        usage.reserveUsage(
            accountId=owner,
            capability=BASIC,
            idempotencyKey="op-0",
            requestFingerprint="different",
            nowUtc=NOW,
        )
    disabled = UsagePolicyService(db, guest=guest, openTestPolicy=replace(OPEN, enabled=False))
    assert not disabled.evaluateAccess(accountId=owner, capability=BASIC, nowUtc=NOW).allowed
    with pytest.raises(MonthlyQuotaExhaustedError):
        disabled.reserveUsage(
            accountId=owner,
            capability=BASIC,
            idempotencyKey="after-disable",
            requestFingerprint="same",
            nowUtc=NOW,
        )
    with db.readConnection() as c:
        assert c.execute("SELECT COUNT(*) FROM usage_operations").fetchone()[0] == finite + 3
    assert usage.evaluateAccess(
        accountId=owner, capability=BASIC, nowUtc=LEGACY_END
    ).isUnlimited


def test_guest_global_limit_and_old_expiry_bypassed_but_owner_survives_restart(
    tmp_path: Path,
) -> None:
    path = tmp_path / "guests.db"
    oldEnd = NOW - timedelta(days=1)
    guests = GuestIdentityService(
        path, maximumMonthlyCalls=1, enabledUntilUtc=oldEnd, openTestPolicy=OPEN
    )
    first = guests.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
    for index in range(5):
        guests.usagePolicy.reserveUsage(
            accountId=first.guestId,
            capability=BASIC,
            idempotencyKey=f"guest-{index}",
            requestFingerprint="same",
            nowUtc=NOW,
        )
    reopened = GuestIdentityService(
        path,
        maximumMonthlyCalls=1,
        enabledUntilUtc=oldEnd,
        openTestPolicy=replace(OPEN, enabled=False),
    )
    restored = reopened.createSession("a" * 64, clientAddress="synthetic", nowUtc=NOW)
    assert restored.guestId == first.guestId
    assert reopened.authenticate(restored.sessionToken, nowUtc=NOW) == first.guestId
    with pytest.raises(GuestLimitError):
        reopened.createSession("b" * 64, clientAddress="synthetic", nowUtc=NOW)
    assert not reopened.usagePolicy.evaluateAccess(
        accountId=first.guestId, capability=BASIC, nowUtc=NOW
    ).allowed


def test_dispatch_ledger_can_exceed_old_budget_across_old_expiry_without_reset(
    tmp_path: Path,
) -> None:
    path = tmp_path / "model.db"
    old = replace(policy(1), expiresAtUtc=NOW - timedelta(days=1))
    budget = TrialModelBudget(path, old, initialize=True, openTestPolicy=OPEN)
    with ThreadPoolExecutor(max_workers=6) as executor:
        ids = list(executor.map(lambda _: budget.reserve(nowUtc=NOW), range(12)))
    assert len(set(ids)) == count(path) == 12
    closed = TrialModelBudget(path, old, openTestPolicy=replace(OPEN, enabled=False))
    assert closed.snapshot()["starts"] == 12
    with pytest.raises(TrialAdmissionClosedError):
        closed.reserve(nowUtc=NOW)
    budget.reserve(nowUtc=LEGACY_END)
    assert count(path) == 13


def test_sqlite11_sms_exact_ceiling_summary_and_disable_preserve_money(tmp_path: Path) -> None:
    db, initial, finite = make(tmp_path)
    # The approved source policy remains finite; only storage capacity grows.
    finite = replace(finite, maximumAttempts=1, budgetCents=6)
    ledger = SmsBudgetLedger(
        SqliteAccountDatabase(db), finite, auditSecret=SECRET, withSummary=True, openTestPolicy=OPEN
    )
    with db.immediateTransaction() as c:
        c.execute(
            "UPDATE sms_send_budget SET maximum_attempts=1,budget_cents=6,policy_fingerprint=?",
            (ledger.policyFingerprint,),
        )
    for outcome in ("accepted", "unknown", "reserved", "rejected"):
        seed(db, ledger, NOW, outcome)
    assert counts(db) == (4, 24, 4, 0, 0)
    with db.readConnection() as c:
        assert tuple(
            c.execute("SELECT maximum_attempts,budget_cents FROM sms_send_budget").fetchone()
        ) == (4, 24)
    # 90-day cleanup overlaps the open window, retains unknown/reserved subset.
    future = NOW + timedelta(days=90)
    result = SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: future).summarize()
    assert result.summarizedAttempts == 4
    assert counts(db) == (4, 24, 0, 4, 24)
    closed = SmsBudgetLedger(
        SqliteAccountDatabase(db),
        finite,
        auditSecret=SECRET,
        withSummary=True,
        openTestPolicy=replace(OPEN, enabled=False),
    )
    assert closed.approvedPolicySnapshot()["reservedCents"] == 24
    fresh = "challenge-" + str(uuid4())
    from agent_gateway.identity import toUtcText

    with db.immediateTransaction() as c:
        c.execute(
            "INSERT INTO phone_challenges(challenge_id,phone_hash,purpose,code_hash,"
            "expires_at_utc) "
            "VALUES(?,?,'register',?,?)",
            (fresh, "a" * 64, "b" * 64, toUtcText(NOW + timedelta(minutes=5))),
        )
    with pytest.raises(SmsBudgetExceededError):
        closed.reserve(fresh, PHONE, "register", nowUtc=NOW)
    with db.immediateTransaction() as c:
        c.execute(
            "UPDATE phone_challenges SET expires_at_utc=? WHERE challenge_id=?",
            (toUtcText(LEGACY_END + timedelta(minutes=5)), fresh),
        )
    limited = SmsBudgetLedger(
        SqliteAccountDatabase(db), finite, auditSecret=SECRET, withSummary=True,
        openTestPolicy=OpenTestPolicy(True, LEGACY_END),
    )
    with pytest.raises(SmsBudgetExceededError):
        limited.reserve(fresh, PHONE, "register", nowUtc=LEGACY_END)
    assert counts(db) == (4, 24, 0, 4, 24)


def test_sms_concurrency_replay_unknown_and_source_caps_remain_authoritative(
    tmp_path: Path,
) -> None:
    from tests.test_sms_budget import fixture

    db, original = fixture(tmp_path / "sms.db")
    finite = original._policy
    opened = SmsBudgetLedger(
        SqliteAccountDatabase(db), finite, auditSecret=SECRET, openTestPolicy=OPEN
    )
    # fixture uses a different audit key; this explicitly models approved config.
    with db.immediateTransaction() as c:
        c.execute("UPDATE sms_send_budget SET policy_fingerprint=?", (opened.policyFingerprint,))
    challenge = "challenge-" + str(uuid4())
    opened.reserve(challenge, PHONE, "register", nowUtc=NOW)
    opened.finalize(challenge, "unknown", nowUtc=NOW)
    with pytest.raises(SmsAttemptReplayError):
        opened.reserve(challenge, PHONE, "register", nowUtc=NOW)
    with ThreadPoolExecutor(max_workers=5) as executor:
        list(
            executor.map(
                lambda _: opened.reserve(
                    "challenge-" + str(uuid4()), PHONE, "register", nowUtc=NOW
                ),
                range(10),
            )
        )
    assert opened.approvedPolicySnapshot()["attempts"] == 11
    closed = SmsBudgetLedger(SqliteAccountDatabase(db), finite, auditSecret=SECRET)
    assert closed.approvedPolicySnapshot()["attempts"] == 11
    with pytest.raises(SmsBudgetExceededError):
        closed.reserve("challenge-" + str(uuid4()), PHONE, "register", nowUtc=NOW)
    with db.immediateTransaction() as c:
        c.execute("UPDATE sms_send_budget SET maximum_attempts=maximum_attempts+1")
    with pytest.raises(ValueError, match="mismatch"):
        opened.assertApprovedPolicy()


def test_quota_api_explicit_unlimited_and_legacy_exact_keys(tmp_path: Path) -> None:
    db, owner, _, _ = buildServices(tmp_path)
    usage = UsagePolicyService(db, openTestPolicy=OPEN)
    from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier

    accounts = AccountService(db, FakePhoneOwnershipVerifier())
    session = accounts.createSession(phoneE164="+15550001234", password="TestPass2026!")
    app = createApplication(
        settings=GatewaySettings(),
        accountService=accounts,
        usagePolicy=usage,
        remoteResumeProvider=RecordingRemoteProvider(),
    )
    for index in range(10):
        op = usage.reserveUsage(
            accountId=owner, capability=BASIC, idempotencyKey=str(index), requestFingerprint="same"
        )
        usage.transitionUsage(
            operationId=op.operationId, targetStatus=UsageOperationStatus.pendingReconciliation
        )
    response = sendAsgiRequest(
        app,
        "GET",
        "/v1/account/quota/basicResumeCompose",
        headers=accountHeaders(session.sessionToken),
    )
    assert response.status_code == 200
    body = response.json()
    assert body["isUnlimited"] and body["allowed"] and body["remainingMonthlyGenerations"] == 0
    assert body["monthlyLimit"] == 9
    old = sendAsgiRequest(
        app,
        "GET",
        "/v1/account/access/basicResumeCompose",
        headers=accountHeaders(session.sessionToken),
    ).json()
    assert "isUnlimited" not in old and "monthlyLimit" not in old


def test_factory_threads_policy_into_registered_and_configured_guest_services(
    tmp_path: Path,
) -> None:
    settings = GatewaySettings(
        enableTask018FakeIdentity=True,
        task018DatabasePath=tmp_path / "users.db",
        guestDatabasePath=tmp_path / "guests.db",
        guestMonthlyCallLimit=1,
        guestEnabledUntilUtc="2020-01-01T00:00:00Z",
        openTestPolicy=OPEN,
    )
    application = createApplication(
        settings=settings, remoteResultCache=cache_at(tmp_path / "cache")
    )
    guest = sendAsgiRequest(
        application, "POST", "/v1/guest/sessions", jsonBody={"installationSecret": "a" * 64}
    )
    assert guest.status_code == 200
    quota = sendAsgiRequest(
        application,
        "GET",
        "/v1/account/quota/basicResumeCompose",
        headers=accountHeaders(guest.json()["sessionToken"]),
    )
    assert quota.json()["isUnlimited"] is True


def test_sms_compaction_and_new_reservation_keep_one_atomic_lifetime_total(tmp_path: Path) -> None:
    db, _, finite = make(tmp_path)
    finite = replace(finite, maximumAttempts=1, budgetCents=6)
    ledger = SmsBudgetLedger(
        SqliteAccountDatabase(db),
        finite,
        auditSecret=SECRET,
        withSummary=True,
        openTestPolicy=OPEN,
    )
    with db.immediateTransaction() as c:
        c.execute(
            "UPDATE sms_send_budget SET maximum_attempts=1,budget_cents=6,policy_fingerprint=?",
            (ledger.policyFingerprint,),
        )
    for _ in range(4):
        seed(db, ledger, NOW - timedelta(days=90), "unknown")
    worker = SmsAttemptSummaryWorker(SqliteAccountDatabase(db), clock=lambda: NOW)

    def run(index: int) -> None:
        if index % 2:
            worker.summarize()
        else:
            seed(db, ledger, NOW)

    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(run, range(8)))
    assert counts(db) == (8, 48, 4, 4, 24)
    assert ledger.approvedPolicySnapshot()["reservedCents"] == 48


def test_open_sms_failed_capacity_update_rolls_back_attempt_and_counters(tmp_path: Path) -> None:
    from agent_gateway.account_storage import StorageUnavailableError
    from tests.test_sms_budget import counters, fixture

    db, old = fixture(tmp_path / "sms.db")
    ledger = SmsBudgetLedger(
        SqliteAccountDatabase(db), old._policy, auditSecret=SECRET, openTestPolicy=OPEN
    )
    with db.immediateTransaction() as c:
        c.execute("UPDATE sms_send_budget SET policy_fingerprint=?", (ledger.policyFingerprint,))
    for _ in range(2):
        ledger.reserve("challenge-" + str(uuid4()), PHONE, "register", nowUtc=NOW)
    with db.immediateTransaction() as c:
        c.execute(
            "CREATE TRIGGER fail_capacity BEFORE UPDATE OF maximum_attempts "
            "ON sms_send_budget BEGIN SELECT RAISE(ABORT,'synthetic'); END"
        )
    with pytest.raises(StorageUnavailableError):
        ledger.reserve("challenge-" + str(uuid4()), PHONE, "register", nowUtc=NOW)
    assert counters(db) == (2, 12, 2)


def test_startup_loads_private_sidecar_without_network_or_new_database(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from agent_gateway import protected_startup as startup

    private = tmp_path / "secrets"
    private.mkdir()
    folder = tmp_path / "open-test"
    folder.mkdir()
    path = folder / "policy.json"
    path.write_text(
        '{"schemaVersion":2,"enabled":true}',
        encoding="utf-8",
    )
    settings = GatewaySettings(
        pnvsCredentialsPath=private / "credential.dpapi",
        pnvsRuntimePath=private / "runtime.dpapi",
        task018DatabasePath=tmp_path / "accounts.db",
    )
    monkeypatch.setattr(startup, "loadProtectedPayload", lambda *a, **kw: "{}")
    monkeypatch.setattr(startup, "_settingsFromPayload", lambda payload: settings)
    monkeypatch.setattr(startup, "loadPnvsCredentials", lambda path: None)
    monkeypatch.setattr(startup, "loadPnvsRuntimeSettings", lambda *a, **kw: None)
    inspected = []
    monkeypatch.setattr(startup, "verifyWindowsResultDirectory", inspected.append)
    configured = startup.loadStartupSettings(private / "startup.dpapi")
    assert configured.openTestPolicy == OPEN and folder in inspected
    assert not (tmp_path / "accounts.db").exists()


def test_local_maintenance_plan_never_executes_sql_or_calls_supplier(tmp_path: Path) -> None:
    import os
    import subprocess
    import sys

    path = tmp_path / "policy.json"
    path.write_text(
        '{"schemaVersion":1,"enabled":false,"enabledUntilUtc":"2026-12-31T16:00:00Z"}',
        encoding="utf-8",
    )
    result = subprocess.run(  # noqa: S603 - fixed interpreter/module and synthetic pytest path
        [sys.executable, "-m", "scripts.prepare_open_test", "--policy", str(path)],
        cwd=Path(__file__).resolve().parents[1],
        env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "src")},
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0
    receipt = json.loads(result.stdout)
    assert receipt["supplierRequests"] == receipt["databaseWrites"] == 0
    assert receipt["modelDispatchLimit"] is None and not receipt["enabled"]
    assert "UPDATE (maximum_attempts,budget_cents)" in receipt["grantSqlForOwnerReview"]
