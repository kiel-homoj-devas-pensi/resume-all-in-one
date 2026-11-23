from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import uuid4

import pytest
from darabonba.core import DaraCore
from darabonba.response import DaraResponse
from fastapi.testclient import TestClient

from agent_gateway.account_lifecycle import (
    AccountLifecycleService,
    IdentityActionError,
    SmsSendOutcomeUnknownError,
    SmsSendRejectedError,
    VerificationPurpose,
)
from agent_gateway.account_storage import SqliteAccountDatabase, UnknownStorageCommitError
from agent_gateway.app import createApplication
from agent_gateway.database import GatewayDatabase
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.pnvs_sender import PnvsSmsSender
from agent_gateway.pnvs_transport import PnvsCredentials, PnvsSmsTransport, SmsAcceptance
from agent_gateway.settings import GatewaySettings
from agent_gateway.sms_budget import SmsAttemptReplayError, SmsBudgetLedger, SmsBudgetPolicy
from agent_gateway.usage import UsagePolicyService

PHONE = "+8613800000000"
SECRET = b"synthetic-sms-audit-secret-32-bytes"


class TransportProbe(PnvsSmsTransport):
    """仅替代供应商边界，观察持久预算与生命周期；不创建 SDK 客户端。"""

    def __init__(self) -> None:
        self.calls: list[tuple[str, str, VerificationPurpose, str]] = []
        self.failure: Exception | None = None
        self.beforeRequest: Callable[[], None] | None = None

    def sendVerification(
        self, phoneE164: str, code: str, purpose: VerificationPurpose, *, challengeId: str
    ) -> SmsAcceptance:
        if self.beforeRequest is not None:
            self.beforeRequest()
        self.calls.append((phoneE164, code, purpose, challengeId))
        if self.failure is not None:
            raise self.failure
        return SmsAcceptance("a" * 64, "b" * 64)


def fixture(path: Path, *, approved: bool = True) -> tuple[GatewayDatabase, SmsBudgetLedger]:
    database = GatewayDatabase(path)
    database.initialize()
    policy = SmsBudgetPolicy(2, 12, 6, datetime.now(UTC) + timedelta(days=1), frozenset({PHONE}))
    ledger = SmsBudgetLedger(SqliteAccountDatabase(database), policy, auditSecret=SECRET)
    if approved:
        ledger.createApprovedPolicy()
    return database, ledger


def attempt() -> str:
    return "challenge-" + str(uuid4())


def assertState(database: GatewayDatabase, outcome: str, *, count: int = 1) -> None:
    with database.readConnection() as connection:
        budget = connection.execute(
            "SELECT attempts, reserved_cents FROM sms_send_budget"
        ).fetchone()
        assert tuple(budget) == (count, count * 6)
        rows = connection.execute("SELECT * FROM sms_send_attempts").fetchall()
        assert len(rows) == count
        assert rows[-1]["outcome"] == outcome
        assert PHONE not in rows[-1]["phone_hash"]
        assert (rows[-1]["finalized_at_utc"] is None) == (outcome == "reserved")


def test_constructor_never_approves_missing_policy(tmp_path: Path) -> None:
    database, ledger = fixture(tmp_path / "unapproved.db", approved=False)
    transport = TransportProbe()
    with pytest.raises(ValueError, match="not_approved"):
        PnvsSmsSender(ledger, transport)
    with database.readConnection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM sms_send_budget").fetchone()[0] == 0
    assert not transport.calls


def test_committed_budget_is_visible_and_writable_from_other_connection_before_network(
    tmp_path: Path,
) -> None:
    database, ledger = fixture(tmp_path / "sender.db")
    transport = TransportProbe()

    def checkNoHeldLock() -> None:
        assertState(database, "reserved")
        # 另一个真实写事务能立即取得锁，证明网络回调不在预算事务中。
        with database.immediateTransaction() as connection:
            connection.execute(
                "UPDATE sms_send_budget SET attempts = attempts WHERE policy_id='pnvs'"
            )

    transport.beforeRequest = checkNoHeldLock
    sender = PnvsSmsSender(ledger, transport)
    challengeId = attempt()
    sender.sendCode(PHONE, "019234", "register", challengeId=challengeId)
    assert len(transport.calls) == 1
    assertState(database, "accepted")
    with database.readConnection() as connection:
        row = connection.execute("SELECT * FROM sms_send_attempts").fetchone()
        assert row["request_id_digest"] == "a" * 64
        assert row["biz_id_digest"] == "b" * 64
    with pytest.raises(SmsAttemptReplayError):
        PnvsSmsSender(ledger, transport).sendCode(
            PHONE, "019234", "register", challengeId=challengeId
        )
    assert len(transport.calls) == 1


@pytest.mark.parametrize(
    ("failure", "outcome", "error"),
    [
        (SmsSendRejectedError(), "rejected", SmsSendRejectedError),
        (SmsSendOutcomeUnknownError(), "unknown", SmsSendOutcomeUnknownError),
        (RuntimeError("synthetic-provider-secret"), "unknown", SmsSendOutcomeUnknownError),
    ],
)
def test_failure_never_refunds_retries_or_discloses_provider_exception(
    tmp_path: Path, failure: Exception, outcome: str, error: type[RuntimeError]
) -> None:
    database, ledger = fixture(tmp_path / "failure.db")
    transport = TransportProbe()
    transport.failure = failure
    sender = PnvsSmsSender(ledger, transport)
    challengeId = attempt()
    with pytest.raises(error) as raised:
        sender.sendCode(PHONE, "019234", "register", challengeId=challengeId)
    assert "synthetic-provider-secret" not in str(raised.value)
    assert raised.value.__suppress_context__
    assertState(database, outcome)
    with pytest.raises(SmsAttemptReplayError):
        sender.sendCode(PHONE, "019234", "register", challengeId=challengeId)
    assert len(transport.calls) == 1


def test_unknown_reservation_commit_never_calls_transport(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database, ledger = fixture(tmp_path / "lost-reservation.db")
    transport = TransportProbe()
    sender = PnvsSmsSender(ledger, transport)
    original = ledger.reserve

    def lostAck(
        challengeId: str,
        phone: str,
        purpose: VerificationPurpose,
        *,
        nowUtc: datetime | None = None,
    ) -> None:
        original(challengeId, phone, purpose, nowUtc=nowUtc)
        raise UnknownStorageCommitError("synthetic lost acknowledgement")

    monkeypatch.setattr(ledger, "reserve", lostAck)
    with pytest.raises(UnknownStorageCommitError):
        sender.sendCode(PHONE, "019234", "register", challengeId=attempt())
    assert not transport.calls
    assertState(database, "reserved")


@pytest.mark.parametrize(
    "transportFailure", [None, SmsSendRejectedError(), SmsSendOutcomeUnknownError()]
)
def test_terminal_write_failure_keeps_reserved_slot_and_reports_unknown(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, transportFailure: Exception | None
) -> None:
    database, ledger = fixture(tmp_path / "lost-terminal.db")
    transport = TransportProbe()
    transport.failure = transportFailure
    sender = PnvsSmsSender(ledger, transport)

    def fail(*args: object, **kwargs: object) -> None:
        raise RuntimeError("synthetic-database-secret")

    monkeypatch.setattr(ledger, "finalize", fail)
    challengeId = attempt()
    with pytest.raises(SmsSendOutcomeUnknownError) as raised:
        sender.sendCode(PHONE, "019234", "register", challengeId=challengeId)
    assert str(raised.value) == "sms_send_outcome_unknown"
    assertState(database, "reserved")
    with pytest.raises(SmsAttemptReplayError):
        sender.sendCode(PHONE, "019234", "register", challengeId=challengeId)
    assert len(transport.calls) == 1


def test_sender_rejects_invalid_code_or_recipient_before_spending_budget(tmp_path: Path) -> None:
    database, ledger = fixture(tmp_path / "invalid.db")
    transport = TransportProbe()
    sender = PnvsSmsSender(ledger, transport)
    for phone, code in [(PHONE, "123"), ("+8613900000000", "019234")]:
        with pytest.raises(ValueError):
            sender.sendCode(phone, code, "register", challengeId=attempt())
    with database.readConnection() as connection:
        assert tuple(
            connection.execute("SELECT attempts, reserved_cents FROM sms_send_budget").fetchone()
        ) == (0, 0)
    assert not transport.calls


def lifecycle(database: GatewayDatabase, sender: PnvsSmsSender) -> AccountLifecycleService:
    return AccountLifecycleService(
        AccountService(database, FakePhoneOwnershipVerifier()),
        sender,
        otpSecret=b"synthetic-otp-server-secret-32-bytes",
    )


def test_success_never_exposes_development_code_and_otp_is_single_use(tmp_path: Path) -> None:
    database, ledger = fixture(tmp_path / "lifecycle.db")
    transport = TransportProbe()
    identity = lifecycle(database, PnvsSmsSender(ledger, transport))
    challenge = identity.issueCode(PHONE, "register", "synthetic-peer")
    assert challenge.developmentCode is None
    assert transport.calls[0][3] == challenge.challengeId
    code = transport.calls[0][1]
    identity.consumeCode(PHONE, "register", challenge.challengeId, code, "synthetic-peer")
    with pytest.raises(IdentityActionError, match="verification_invalid"):
        identity.consumeCode(PHONE, "register", challenge.challengeId, code, "synthetic-peer")
    assertState(database, "accepted")


@pytest.mark.parametrize(
    ("failure", "errorCode"),
    [
        (SmsSendRejectedError(), "verification_delivery_unavailable"),
        (SmsSendOutcomeUnknownError(), "verification_delivery_unknown"),
    ],
)
def test_failed_delivery_invalidates_code_and_http_does_not_return_challenge(
    tmp_path: Path, failure: Exception, errorCode: str
) -> None:
    database, ledger = fixture(tmp_path / "http.db")
    transport = TransportProbe()
    transport.failure = failure
    identity = lifecycle(database, PnvsSmsSender(ledger, transport))
    app = createApplication(
        settings=GatewaySettings(
            enableTask018FakeIdentity=True, task018DatabasePath=database.databasePath
        ),
        accountService=identity.accounts,
        usagePolicy=UsagePolicyService(database),
        accountLifecycle=identity,
    )
    with TestClient(app) as client:
        response = client.post(
            "/v2/account-verifications",
            json={"protocolVersion": "0.5.0", "phoneE164": PHONE, "purpose": "register"},
        )
        assert response.status_code == 503
        body = response.json()
        assert body["error"]["code"] == errorCode
        assert body["error"]["retryable"] is False
        assert "challengeId" not in body
        assert PHONE not in response.text
    phone, code, purpose, challengeId = transport.calls[0]
    with pytest.raises(IdentityActionError, match="verification_invalid"):
        identity.consumeCode(phone, purpose, challengeId, code, "synthetic-peer")
    assert len(transport.calls) == 1


def test_lifecycle_rejects_budget_from_different_database(tmp_path: Path) -> None:
    database, _ = fixture(tmp_path / "identity.db")
    _, otherLedger = fixture(tmp_path / "other-budget.db")
    with pytest.raises(ValueError, match="同一个权威数据库"):
        lifecycle(database, PnvsSmsSender(otherLedger, TransportProbe()))


def test_accepted_terminal_commit_with_lost_ack_never_repeats_network(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database, ledger = fixture(tmp_path / "terminal-lost-ack.db")
    transport = TransportProbe()
    sender = PnvsSmsSender(ledger, transport)
    original = ledger.finalize

    def lostAck(challengeId: str, outcome: str, **kwargs: Any) -> None:
        assert outcome == "accepted"
        original(challengeId, "accepted", **kwargs)
        raise UnknownStorageCommitError("synthetic terminal acknowledgement lost")

    monkeypatch.setattr(ledger, "finalize", lostAck)
    challengeId = attempt()
    with pytest.raises(SmsSendOutcomeUnknownError):
        sender.sendCode(PHONE, "019234", "register", challengeId=challengeId)
    assertState(database, "accepted")
    with pytest.raises(SmsAttemptReplayError):
        sender.sendCode(PHONE, "019234", "register", challengeId=challengeId)
    assert len(transport.calls) == 1


def test_lifecycle_and_real_sdk_share_challenge_after_budget_commit_without_http_network(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database, ledger = fixture(tmp_path / "sdk-lifecycle.db")
    calls: list[dict[str, Any]] = []

    def httpBoundary(request: Any, runtime: dict[str, Any]) -> DaraResponse:
        import json

        assertState(database, "reserved")
        calls.append(request.query)
        with database.immediateTransaction() as connection:
            connection.execute("UPDATE sms_send_budget SET attempts = attempts")
        response = DaraResponse()
        response.status_code = 200
        response.headers = {"content-type": "application/json"}
        response.body = json.dumps(
            {
                "Code": "OK",
                "Success": True,
                "Model": {"OutId": request.query["OutId"], "BizId": "synthetic-biz-id"},
            }
        ).encode("utf-8")
        return response

    monkeypatch.delenv("DEBUG", raising=False)
    monkeypatch.setattr(DaraCore, "do_action", httpBoundary)
    transport = PnvsSmsTransport(
        PnvsCredentials(
            "synthetic-access-key-id", "synthetic-access-key-secret", "恒创联众", "100001"
        )
    )
    identity = lifecycle(database, PnvsSmsSender(ledger, transport))
    challenge = identity.issueCode(PHONE, "resetPassword", "synthetic-peer")
    assert challenge.developmentCode is None
    assert len(calls) == 1
    assert calls[0]["OutId"] == challenge.challengeId
    assert calls[0]["TemplateCode"] == "100003"
    assert calls[0]["AutoRetry"] == "0"
    assertState(database, "accepted")
