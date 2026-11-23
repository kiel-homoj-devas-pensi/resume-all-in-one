"""Account-ownership receipts for manual rights requests; never login credentials."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from .identity import requireUtc, toUtcText

_DOMAIN = b"rights-request-receipt-v1"
_FIELDS = {"accountId", "requestId", "issuedAtUtc", "expiresAtUtc", "purpose"}


class InvalidRightsReceipt(ValueError):
    def __init__(self) -> None:
        super().__init__("rights_receipt_invalid_or_expired")


def _key(secret: bytes) -> bytes:
    if not isinstance(secret, bytes) or len(secret) < 32:
        raise InvalidRightsReceipt()
    return hmac.digest(secret, _DOMAIN, "sha256")


def issueReceipt(secret: bytes, accountId: str, nowUtc: datetime) -> dict[str, object]:
    """Caller must freshly authenticate password, active account and session."""
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", accountId) is None:
        raise InvalidRightsReceipt()
    now = requireUtc(nowUtc)
    expiry = now + timedelta(days=30)
    payload = {
        "purpose": "personal-information-request",
        "accountId": accountId,
        "requestId": f"rights-{uuid4()}",
        "issuedAtUtc": toUtcText(now),
        "expiresAtUtc": toUtcText(expiry),
    }
    encoded = (
        base64.urlsafe_b64encode(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("ascii")
        )
        .decode("ascii")
        .rstrip("=")
    )
    signature = hmac.new(_key(secret), encoded.encode("ascii"), hashlib.sha256).hexdigest()
    return {"receipt": f"rights-v1.{encoded}.{signature}", "expiresAtUtc": expiry}


def verifyReceipt(secret: bytes, receipt: str, *, nowUtc: datetime | None = None) -> dict[str, str]:
    """Only validates account control at issue time, not request merits or identity."""
    try:
        now = requireUtc(nowUtc or datetime.now(UTC))
        if not isinstance(receipt, str) or not 1 <= len(receipt) <= 2048:
            raise InvalidRightsReceipt()
        version, encoded, signature = receipt.split(".")
        if version != "rights-v1" or re.fullmatch(r"[A-Za-z0-9_-]+", encoded) is None:
            raise InvalidRightsReceipt()
        expected = hmac.new(_key(secret), encoded.encode("ascii"), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, signature):
            raise InvalidRightsReceipt()
        raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        value = json.loads(raw)
        if (
            not isinstance(value, dict)
            or set(value) != _FIELDS
            or any(not isinstance(item, str) for item in value.values())
            or value["purpose"] != "personal-information-request"
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", value["accountId"]) is None
            or re.fullmatch(r"rights-[0-9a-f-]{36}", value["requestId"]) is None
        ):
            raise InvalidRightsReceipt()
        issued = requireUtc(datetime.fromisoformat(value["issuedAtUtc"]))
        expiry = requireUtc(datetime.fromisoformat(value["expiresAtUtc"]))
        if issued > now or expiry != issued + timedelta(days=30) or expiry <= now:
            raise InvalidRightsReceipt()
        return value
    except Exception:
        raise InvalidRightsReceipt() from None
