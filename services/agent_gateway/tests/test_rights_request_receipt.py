from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from agent_gateway.app import createApplication
from agent_gateway.rights_request_receipt import (
    InvalidRightsReceipt,
    issueReceipt,
    verifyReceipt,
)
from agent_gateway.settings import GatewaySettings

SECRET = b"synthetic-rights-receipt-secret-32bytes"


def test_receipt_is_purpose_bound_tamper_evident_and_expires_at_boundary() -> None:
    now = datetime(2026, 10, 20, tzinfo=UTC)
    issued = issueReceipt(SECRET, "account-synthetic", now)
    receipt = str(issued["receipt"])
    claims = verifyReceipt(SECRET, receipt, nowUtc=now)
    assert claims["accountId"] == "account-synthetic"
    assert claims["purpose"] == "personal-information-request"
    assert set(claims) == {"accountId", "purpose", "requestId", "issuedAtUtc", "expiresAtUtc"}
    assert verifyReceipt(SECRET, receipt, nowUtc=now + timedelta(days=30, microseconds=-1))
    for token in (receipt + "x", receipt.replace("rights-v1", "session-v1"), "x" * 3000):
        with pytest.raises(InvalidRightsReceipt):
            verifyReceipt(SECRET, token, nowUtc=now)
    for at in (now - timedelta(microseconds=1), now + timedelta(days=30)):
        with pytest.raises(InvalidRightsReceipt):
            verifyReceipt(SECRET, receipt, nowUtc=at)
    with pytest.raises(InvalidRightsReceipt):
        verifyReceipt(b"another-synthetic-receipt-secret-32bytes", receipt, nowUtc=now)


def test_http_requires_active_account_session_and_current_password(tmp_path: Path) -> None:
    app = createApplication(
        settings=GatewaySettings(
            task018DatabasePath=tmp_path / "rights.sqlite",
            enableTask018FakeIdentity=True,
        )
    )
    with TestClient(app) as client:
        path = "/v2/account/rights-request-receipt"
        body = {"protocolVersion": "0.5.0", "currentPassword": "TestPass026!"}
        assert client.post(path, json=body).status_code == 401
        challenge = client.post(
            "/v2/account-verifications",
            json={
                "protocolVersion": "0.5.0",
                "phoneE164": "+8613800000000",
                "purpose": "register",
            },
        ).json()
        registered = client.post(
            "/v2/accounts",
            json={
                "protocolVersion": "0.5.0",
                "phoneE164": "+8613800000000",
                "password": "TestPass026!",
                "challengeId": challenge["challengeId"],
                "code": challenge["developmentCode"],
            },
        )
        assert registered.status_code == 201
        login = client.post(
            "/v2/account-sessions",
            json={
                "protocolVersion": "0.5.0",
                "phoneE164": "+8613800000000",
                "password": "TestPass026!",
            },
        ).json()
        headers = {"Authorization": "Bearer " + login["sessionToken"]}
        wrong = client.post(
            path, headers=headers, json={**body, "currentPassword": "WrongPass026!"}
        )
        assert wrong.status_code == 401
        response = client.post(path, headers=headers, json=body)
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-store"
        result = response.json()
        claims = verifyReceipt(
            b"task026-development-only-otp-secret-never-production", result["receipt"]
        )
        assert claims["accountId"] == registered.json()["accountId"]
        assert "password" not in response.text.lower()
        assert "+8613800000000" not in response.text
        assert "sessionToken" not in response.text
        # It is deliberately not an authentication token.
        forgedAuth = {"Authorization": "Bearer " + result["receipt"]}
        assert client.post(path, headers=forgedAuth, json=body).status_code == 401
        revoked = client.post(
            "/v2/account-sessions/revoke",
            headers=headers,
            json={
                "protocolVersion": "0.5.0",
                "allDevices": False,
            },
        )
        assert revoked.status_code == 200
        assert client.post(path, headers=headers, json=body).status_code == 401
