from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import re
from dataclasses import asdict, dataclass
from datetime import datetime

from pydantic import TypeAdapter

from .account_storage import StorageUnavailableError, storedText
from .canonical_snapshot import Timestamp

PAGE_BYTES = 60_000
CURSOR_SECONDS = 900
_TIMESTAMP = TypeAdapter(Timestamp)


class CloudCursorError(ValueError):
    def __init__(self, code: str = "cloud_cursor_invalid") -> None:
        super().__init__(code)


@dataclass(frozen=True, slots=True, repr=False)
class CloudDocumentMetadata:
    documentId: str
    title: str | None
    currentVersionId: str | None
    createdAt: str | None
    updatedAt: str | None
    lastSequence: int
    deletedAtUtc: str | None


@dataclass(frozen=True, slots=True, repr=False)
class CloudVersionMetadata:
    documentId: str
    versionId: str
    parentVersionId: str | None
    source: str
    createdAt: str
    committedAtUtc: str
    sequence: int


@dataclass(frozen=True, slots=True, repr=False)
class CloudPage[Item]:
    items: tuple[Item, ...]
    nextCursor: str | None
    highWatermark: int


def compactJson(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def pageItemBytes(value: CloudDocumentMetadata | CloudVersionMetadata) -> int:
    return len(compactJson(asdict(value))) + 1


def _uniqueObject(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def metadataObject(value: object, fields: set[str]) -> dict[str, object]:
    try:
        result: object = json.loads(storedText(value), object_pairs_hook=_uniqueObject)
        if not isinstance(result, dict) or result.keys() != fields:
            raise ValueError("invalid_metadata")
        return result
    except ValueError, TypeError, UnicodeError:
        raise StorageUnavailableError("cloud_storage_inconsistent") from None


def metadataText(value: object) -> str:
    if not isinstance(value, str) or not value.strip():
        raise StorageUnavailableError("cloud_storage_inconsistent")
    return value


def metadataTime(value: object) -> str:
    try:
        return _TIMESTAMP.validate_python(metadataText(value))
    except ValueError:
        raise StorageUnavailableError("cloud_storage_inconsistent") from None


def metadataSequence(value: object) -> int:
    if type(value) is not int or not 1 <= value < 2**63:
        raise StorageUnavailableError("cloud_storage_inconsistent")
    return value


class CloudCursorCodec:
    def __init__(self, secret: bytes, authorityKey: tuple[str, ...]) -> None:
        if not isinstance(secret, bytes) or len(secret) != 32:
            raise ValueError("invalid_cloud_cursor_secret")
        self._secret = secret
        self.authorityDigest = hashlib.sha256(compactJson(authorityKey)).hexdigest()

    def encode(self, fields: dict[str, object]) -> str:
        body = base64.urlsafe_b64encode(compactJson(fields)).rstrip(b"=").decode("ascii")
        signature = hmac.new(self._secret, body.encode("ascii"), hashlib.sha256).hexdigest()
        token = "c1." + body + "." + signature
        if len(token) > 2048:
            raise CloudCursorError()
        return token

    def decode(self, token: str, scope: dict[str, object], now: str) -> tuple[int, int, str, int]:
        try:
            if not isinstance(token, str) or len(token) > 2048:
                raise ValueError("invalid_cursor")
            parts = token.split(".")
            if (
                len(parts) != 3
                or parts[0] != "c1"
                or re.fullmatch(r"[0-9a-f]{64}", parts[2]) is None
            ):
                raise ValueError("invalid_cursor")
            body = parts[1]
            if not body or re.fullmatch(r"[A-Za-z0-9_-]+", body) is None:
                raise ValueError("invalid_cursor")
            expected = hmac.new(self._secret, body.encode(), hashlib.sha256).hexdigest()
            if not hmac.compare_digest(parts[2], expected):
                raise ValueError("invalid_cursor")
            raw = base64.b64decode(body + "=" * (-len(body) % 4), altchars=b"-_", validate=True)
            if base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii") != body:
                raise ValueError("invalid_cursor")
            result = json.loads(raw, object_pairs_hook=_uniqueObject)
            if (
                not isinstance(result, dict)
                or set(result)
                != set(scope) | {"watermark", "lastSequence", "lastDocument", "expires"}
                or any(
                    type(result[key]) is not type(value) or result[key] != value
                    for key, value in scope.items()
                )
            ):
                raise ValueError("invalid_cursor")
            if compactJson(result) != raw:
                raise ValueError("invalid_cursor")
            watermark, last, document, expires = (
                result["watermark"],
                result["lastSequence"],
                result["lastDocument"],
                result["expires"],
            )
            if (
                type(watermark) is not int
                or type(last) is not int
                or not 0 < last <= watermark < 2**63
            ):
                raise ValueError("invalid_cursor")
            if not isinstance(document, str) or len(document.encode()) > 512:
                raise ValueError("invalid_cursor")
            seconds = int(datetime.fromisoformat(now).timestamp())
            if type(expires) is not int or expires > seconds + CURSOR_SECONDS:
                raise ValueError("invalid_cursor")
            if expires <= seconds:
                raise CloudCursorError("cloud_cursor_expired")
            return watermark, last, document, expires
        except CloudCursorError:
            raise
        except ValueError, TypeError, KeyError, UnicodeError, binascii.Error:
            raise CloudCursorError() from None
