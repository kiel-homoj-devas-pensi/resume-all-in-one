from datetime import UTC, datetime
from pathlib import Path

import pytest

from agent_gateway.account_storage import StorageUnavailableError, UnknownStorageCommitError
from agent_gateway.mysql_storage import MySqlAccountDatabase, MySqlConfig
from agent_gateway.mysql_usage_schema import _normalizeCheck
from agent_gateway.usage import ProductCapability, UsageOperationStatus, UsagePolicyService
from agent_gateway.usage_storage import MySqlUsageStore
from tests.test_mysql_storage import FakeConnection, FakeDriver

NOW = datetime(2026, 10, 10, tzinfo=UTC)


def test_mysql_metadata_escaped_check_matches_only_same_case_sensitive_constraint() -> None:
    actual = "(`plan` in (_utf8mb4\\'free\\',_utf8mb4\\'pro\\'))"
    expected = "plan IN ('free', 'pro')"
    assert _normalizeCheck(actual) == _normalizeCheck(expected)
    assert _normalizeCheck("plan IN ('FREE', 'pro')") != _normalizeCheck(expected)


def operationRow() -> dict[str, object]:
    return dict(
        operation_id=b"usage-synthetic",
        account_id=b"account-synthetic",
        capability="basicResumeCompose",
        status="reserved",
        plan_at_reservation="free",
        quota_window_start_utc="2026-10-01T00:00:00.000000Z",
        quota_window_end_utc="2026-11-01T00:00:00.000000Z",
        prompt_version=None,
        input_tokens=None,
        output_tokens=None,
        failure_code=None,
    )


def policyFor(tmp_path: Path, driver: FakeDriver) -> UsagePolicyService:
    ca = tmp_path / "synthetic-ca.pem"
    ca.write_text("synthetic fake connector certificate")
    config = MySqlConfig.fromDsn(
        "mysql://synthetic:private-synthetic@db.invalid/synthetic", ca, "2099-01-01T00:00:00Z"
    )
    return UsagePolicyService(
        MySqlUsageStore(MySqlAccountDatabase(config, lambda _: FakeConnection(driver)))
    )


def test_mysql_reservation_locks_account_before_snapshot_and_returns_decoded_ids(
    tmp_path: Path,
) -> None:
    driver = FakeDriver()
    driver.rows = [
        {"account_id": b"account-synthetic", "is_active": 1},
        None,
        None,
        {"operation_count": 8},
        operationRow(),
    ]
    result = policyFor(tmp_path, driver).reserveUsageForExecution(
        accountId="account-synthetic",
        capability=ProductCapability.basicResumeCompose,
        idempotencyKey="one-action",
        requestFingerprint="same",
        nowUtc=NOW,
    )
    assert not result.isReplay
    assert result.operation.operationId == "usage-synthetic"
    assert driver.statements[0][0].endswith(" FOR UPDATE")
    assert "FROM accounts" in driver.statements[0][0]
    assert all("?" not in sql for sql, _ in driver.statements)
    assert driver.commits == 1


def test_unknown_mysql_commit_never_returns_execution_qualification_or_retries(
    tmp_path: Path,
) -> None:
    driver = FakeDriver()
    driver.rows = [
        {"account_id": b"account-synthetic", "is_active": 1},
        None,
        None,
        {"operation_count": 8},
        operationRow(),
    ]
    driver.commitError = RuntimeError("private-synthetic-driver-detail")
    with pytest.raises(UnknownStorageCommitError) as caught:
        policyFor(tmp_path, driver).reserveUsageForExecution(
            accountId="account-synthetic",
            capability=ProductCapability.basicResumeCompose,
            idempotencyKey="one-action",
            requestFingerprint="same",
            nowUtc=NOW,
        )
    assert "private-synthetic" not in str(caught.value)
    assert driver.commits == 1 and driver.rollbacks == 1 and driver.closed
    assert sum("INSERT INTO usage_operations" in sql for sql, _ in driver.statements) == 1


def test_mysql_transition_locks_operation_before_deciding_terminal_state(tmp_path: Path) -> None:
    driver = FakeDriver()
    final = operationRow() | {"status": "released"}
    driver.rows = [operationRow(), final]
    result = policyFor(tmp_path, driver).transitionUsage(
        operationId="usage-synthetic", targetStatus=UsageOperationStatus.released, nowUtc=NOW
    )
    assert result.status is UsageOperationStatus.released
    assert driver.statements[0][0].endswith(" FOR UPDATE")
    assert "FROM usage_operations" in driver.statements[0][0]


def test_missing_quota_count_fails_closed_without_creating_operation(tmp_path: Path) -> None:
    driver = FakeDriver()
    driver.rows = [{"account_id": b"account-synthetic", "is_active": 1}, None, None, None]
    with pytest.raises(StorageUnavailableError, match="用量计数不可用"):
        policyFor(tmp_path, driver).reserveUsageForExecution(
            accountId="account-synthetic",
            capability=ProductCapability.basicResumeCompose,
            idempotencyKey="one-action",
            requestFingerprint="same",
            nowUtc=NOW,
        )
    assert not any("INSERT INTO usage_operations" in sql for sql, _ in driver.statements)
    assert driver.rollbacks == 1 and driver.commits == 0
