from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest

from agent_gateway.account_storage import StorageUnavailableError, UnknownStorageCommitError
from agent_gateway.app import createApplication
from agent_gateway.identity import AccountService, FakePhoneOwnershipVerifier
from agent_gateway.settings import GatewaySettings
from agent_gateway.usage import UsagePolicyService, hashOperationValue
from agent_gateway.usage_storage import SqliteUsageStore, UsageTransaction
from tests.support import sendAsgiRequest
from tests.test_remote_gateway import (
    RecordingRemoteProvider,
    accountHeaders,
    basicRequestBody,
    buildRemoteApplication,
)


@pytest.mark.parametrize("lostCommit", [False, True])
def test_storage_failure_is_safe_and_never_grants_model_execution(
    tmp_path: Path, lostCommit: bool
) -> None:
    provider = RecordingRemoteProvider()
    _, database, accountId, token, _ = buildRemoteApplication(tmp_path, provider)

    class FaultStore(SqliteUsageStore):
        @contextmanager
        def transaction(self) -> Iterator[UsageTransaction]:
            if not lostCommit:
                raise StorageUnavailableError("synthetic-private-driver-detail")
            with super().transaction() as transaction:
                yield transaction
            raise UnknownStorageCommitError("synthetic-private-driver-detail")

    application = createApplication(
        settings=GatewaySettings(),
        accountService=AccountService(database, FakePhoneOwnershipVerifier()),
        usagePolicy=UsagePolicyService(FaultStore(database)),
        remoteResumeProvider=provider,
    )
    response = sendAsgiRequest(
        application,
        "POST",
        "/v1/resume-ai/requests",
        headers=accountHeaders(token),
        jsonBody=basicRequestBody(idempotencyKey="stable-storage-failure"),
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == (
        "operation_outcome_unknown" if lostCommit else "storage_unavailable"
    )
    assert response.json()["error"]["retryable"] is False
    assert "synthetic-private-driver-detail" not in response.text
    assert provider.generateCallCount == 0

    with database.readConnection() as connection:
        row = connection.execute(
            "SELECT status FROM usage_operations WHERE account_id = ? AND idempotency_key_hash = ?",
            (accountId, hashOperationValue("stable-storage-failure")),
        ).fetchone()
    assert (row is not None) is lostCommit
    if lostCommit:
        assert row is not None and row["status"] == "reserved"
        recovered = createApplication(
            settings=GatewaySettings(),
            accountService=AccountService(database, FakePhoneOwnershipVerifier()),
            usagePolicy=UsagePolicyService(database),
            remoteResumeProvider=provider,
        )
        replay = sendAsgiRequest(
            recovered,
            "POST",
            "/v1/resume-ai/requests",
            headers=accountHeaders(token),
            jsonBody=basicRequestBody(idempotencyKey="stable-storage-failure"),
        )
        assert replay.status_code == 409
        assert provider.generateCallCount == 0
