from __future__ import annotations

from typing import Annotated, Any, Literal

from pydantic import Field, StringConstraints

from .canonical_snapshot import MAXIMUM_SNAPSHOT_BYTES
from .cloud_pages import CURSOR_SECONDS, CloudDocumentMetadata, CloudVersionMetadata
from .cloud_storage import CloudOperationResult, CloudSyncPolicy
from .contracts import StrictGatewayModel

CloudProtocol = Literal["0.1.0"]
CloudOperationId = Annotated[
    str,
    StringConstraints(
        strict=True,
        pattern=r"^sync-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    ),
]
PolicyFingerprint = Annotated[str, StringConstraints(strict=True, pattern=r"^[0-9a-f]{64}$")]


class CloudActionRequest(StrictGatewayModel):
    protocolVersion: CloudProtocol
    clientOperationId: CloudOperationId


class CloudConsentRequest(CloudActionRequest):
    policyFingerprint: PolicyFingerprint


class CloudOptionsResponse(StrictGatewayModel):
    protocolVersion: CloudProtocol = "0.1.0"
    enabled: bool
    developmentOnly: Literal[True] = True
    scope: Literal["canonicalDocument"] = "canonicalDocument"
    policy: CloudSyncPolicy | None = None
    policyFingerprint: str | None = None
    maximumSnapshotBytes: int = MAXIMUM_SNAPSHOT_BYTES
    maximumRequestBytes: int
    maximumResponseBytes: int = 65_536
    maximumPageSize: int = 50
    cursorLifetimeSeconds: int = CURSOR_SECONDS


class CloudOperationResponse(StrictGatewayModel):
    protocolVersion: CloudProtocol = "0.1.0"
    result: CloudOperationResult


class CloudDocumentPageResponse(StrictGatewayModel):
    protocolVersion: CloudProtocol = "0.1.0"
    items: tuple[CloudDocumentMetadata, ...]
    nextCursor: str | None
    highWatermark: int


class CloudVersionPageResponse(StrictGatewayModel):
    protocolVersion: CloudProtocol = "0.1.0"
    items: tuple[CloudVersionMetadata, ...]
    nextCursor: str | None
    highWatermark: int


class CloudSnapshotResponse(StrictGatewayModel):
    protocolVersion: CloudProtocol = "0.1.0"
    snapshot: dict[str, Any] = Field(
        description="完整已校验 Canonical document/version，保留扩展字段"
    )
