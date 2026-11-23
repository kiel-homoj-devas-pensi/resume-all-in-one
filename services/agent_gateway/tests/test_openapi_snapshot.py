from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from agent_gateway.app import createApplication
from agent_gateway.settings import GatewaySettings


def test_openapi_与冻结快照一致且不包含凭据() -> None:
    serviceRoot = Path(__file__).resolve().parents[1]
    snapshotPath = serviceRoot / "openapi" / "v0.13.json"
    placeholderToken = "OPENAPI_TOKEN_MUST_NOT_APPEAR"
    application = createApplication(
        settings=GatewaySettings(testBearerToken=placeholderToken),
    )

    storedSchema: dict[str, Any] = json.loads(snapshotPath.read_text(encoding="utf-8"))
    generatedSchema = application.openapi()

    assert storedSchema == generatedSchema
    assert generatedSchema["info"]["version"] == "0.13.0"
    for methods in generatedSchema["paths"].values():
        if "post" in methods:
            assert {"400", "408", "413", "415", "429"} <= methods["post"]["responses"].keys()
            assert "request_timeout" in methods["post"]["responses"]["408"]["description"]
    assert placeholderToken not in snapshotPath.read_text(encoding="utf-8")
    assert set(generatedSchema["paths"]) == {
        "/v2/account/options",
        "/v2/account-verifications",
        "/v2/accounts",
        "/v2/account-sessions",
        "/v2/account-sessions/revoke",
        "/v2/account/password",
        "/v2/account/password-reset",
        "/v2/account/recovery-code",
        "/v2/account/deactivate",
        "/v2/account/rights-request-receipt",
        "/health/live",
        "/health/ready",
        "/v1/agent/requests",
        "/v1/resume-ai/requests",
        "/v1/accounts",
        "/v1/account-sessions",
        "/v1/account/access/{capability}",
        "/v1/account/quota/{capability}",
        "/v1/guest/sessions",
        "/v1/guest/identity",
        "/v1/account/identity",
        "/v1/account/privileges",
        "/v1/resume-ai/operations/lookup",
        "/v1/resume-ai/recovery-options",
        "/v1/resume-ai/results/lookup",
        "/v1/cloud-resumes/options",
        "/v1/cloud-resumes/documents",
        "/v1/cloud-resumes/documents/{documentKey}/versions",
        "/v1/cloud-resumes/documents/{documentKey}/current",
        "/v1/cloud-resumes/documents/{documentKey}/versions/{versionKey}",
        "/v1/cloud-resumes/documents/{documentKey}/consents",
        "/v1/cloud-resumes/documents/{documentKey}/consents/revoke",
        "/v1/cloud-resumes/documents/{documentKey}/delete",
        "/v1/cloud-resumes/operations/{clientOperationId}",
    }


def test_unlimited_field_is_additive_and_previous_snapshot_stays_immutable() -> None:
    from copy import deepcopy

    serviceRoot = Path(__file__).resolve().parents[1]
    prior = json.loads((serviceRoot / "openapi" / "v0.12.json").read_text(encoding="utf-8"))
    current = deepcopy(createApplication().openapi())
    assert current["components"]["schemas"]["AccountQuotaResponse"]["properties"].pop(
        "isUnlimited"
    ) == {"type": "boolean", "title": "Isunlimited", "default": False}
    current["info"]["version"] = prior["info"]["version"]
    assert current == prior
