from __future__ import annotations

import math
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Literal

from .open_test import OpenTestPolicy, loadOpenTestPolicy

RemoteProviderMode = Literal["fake", "glm"]


@dataclass(frozen=True, slots=True)
class GatewaySettings:
    databaseBackend: Literal["sqlite", "mysql"] = "sqlite"
    databaseDsn: str | None = field(default=None, repr=False)
    databaseTlsCaFile: Path | None = field(default=None, repr=False)
    databaseExpiresAtUtc: str | None = None
    executionEnvironment: Literal["development", "production"] = "development"
    testBearerToken: str | None = None
    maxRequestBodyBytes: int = 65_536
    maxRequestBodySeconds: float = 10.0
    providerTimeoutSeconds: float = 2.0
    maxConcurrentRequests: int = 4
    task018DatabasePath: Path | None = None
    enableTask018FakeIdentity: bool = False
    enableAccountPrivileges: bool = False
    enableRecoveryCodes: bool = False
    enableAccountRetention: bool = False
    enableSmsAttemptRetention: bool = False
    pnvsCredentialsPath: Path | None = field(default=None, repr=False)
    pnvsRuntimePath: Path | None = field(default=None, repr=False)
    cloudRuntimePath: Path | None = field(default=None, repr=False)
    remoteResultDirectory: Path | None = None
    guestDatabasePath: Path | None = None
    guestMonthlyCallLimit: int = 0
    guestEnabledUntilUtc: str | None = None
    volunteerTrialPolicyPath: Path | None = None
    openTestPolicy: OpenTestPolicy | None = None
    remoteProviderMode: RemoteProviderMode = "fake"
    glmApiKey: str | None = field(default=None, repr=False)
    remoteProviderRequestTimeoutSeconds: float = 120.0
    remoteProviderDeadlineSeconds: float = 125.0
    remoteProviderMaximumActiveRequests: int = 2
    remoteProviderMaximumQueuedRequests: int = 2
    remoteProviderQueueWaitSeconds: float = 1.0

    def __post_init__(self) -> None:
        if self.openTestPolicy is not None and not isinstance(self.openTestPolicy, OpenTestPolicy):
            raise ValueError("invalid_open_test_settings")
        if self.volunteerTrialPolicyPath is not None and (
            not isinstance(self.volunteerTrialPolicyPath, Path)
            or not self.volunteerTrialPolicyPath.is_absolute()
        ):
            raise ValueError("志愿者试用策略必须使用独立绝对路径")
        if self.guestDatabasePath is None:
            if self.guestMonthlyCallLimit != 0 or self.guestEnabledUntilUtc is not None:
                raise ValueError("游客额度必须与独立存储同时配置")
        elif (
            not isinstance(self.guestDatabasePath, Path)
            or not self.guestDatabasePath.is_absolute()
            or type(self.guestMonthlyCallLimit) is not int
            or self.guestMonthlyCallLimit < 1
        ):
            raise ValueError("游客体验需要独立绝对路径和明确的总调用上限")
        if self.guestDatabasePath is not None:
            if self.guestEnabledUntilUtc is None:
                raise ValueError("游客开放必须给出本轮截止时间")
            deadline = datetime.fromisoformat(self.guestEnabledUntilUtc)
            if deadline.tzinfo is None:
                raise ValueError("游客截止时间必须包含时区")
        if type(self.enableAccountPrivileges) is not bool:
            raise ValueError("enableAccountPrivileges 必须为布尔值")
        if type(self.enableRecoveryCodes) is not bool or (
            self.enableRecoveryCodes and not self.enableAccountPrivileges
        ):
            raise ValueError("恢复码要求同库账号权益结构及显式布尔开关")
        if type(self.enableAccountRetention) is not bool or (
            self.enableAccountRetention and not self.enableRecoveryCodes
        ):
            raise ValueError("账号留存要求显式启用同库恢复码和完整退休登记结构")
        if type(self.enableSmsAttemptRetention) is not bool or (
            self.enableSmsAttemptRetention and not self.enableAccountRetention
        ):
            raise ValueError("短信明细汇总要求显式启用同库账号留存结构")
        if self.cloudRuntimePath is not None and (
            self.executionEnvironment != "development"
            or not isinstance(self.cloudRuntimePath, Path)
        ):
            raise ValueError("云运行配置仅限显式合成开发，生产云同步尚未开放")
        if (self.pnvsCredentialsPath is None) != (self.pnvsRuntimePath is None):
            raise ValueError("PNVS 必须同时配置凭据与运行文件路径")
        if self.usesPnvs and (
            self.enableTask018FakeIdentity
            or not isinstance(self.pnvsCredentialsPath, Path)
            or not isinstance(self.pnvsRuntimePath, Path)
        ):
            raise ValueError("PNVS 配置不能使用 Fake 身份或无效路径类型")
        if self.cloudRuntimePath is not None and not (
            self.enableTask018FakeIdentity or self.usesPnvs
        ):
            raise ValueError("云运行配置要求明确启用同库账户身份服务")
        if self.databaseBackend not in {"sqlite", "mysql"}:
            raise ValueError("GATEWAY_DATABASE_BACKEND 必须是 sqlite 或 mysql")
        if self.databaseBackend == "mysql":
            if self.task018DatabasePath is not None:
                raise ValueError("MySQL 后端不能同时配置 SQLite 路径")
            if not self.databaseDsn or self.databaseTlsCaFile is None:
                raise ValueError("MySQL 后端需要 DSN 与 TLS CA")
        elif any(
            value is not None
            for value in (
                self.databaseDsn,
                self.databaseTlsCaFile,
                self.databaseExpiresAtUtc,
            )
        ):
            raise ValueError("SQLite 后端不能配置 MySQL 参数")
        if self.executionEnvironment not in {"development", "production"}:
            raise ValueError("无效执行环境")
        if self.executionEnvironment == "production" and (
            self.enableTask018FakeIdentity
            or self.testBearerToken is not None
            or self.remoteProviderMode == "fake"
        ):
            raise ValueError("生产启动拒绝 Fake 身份、Fake Provider 和开发 Bearer")
        if self.testBearerToken is not None and len(self.testBearerToken) < 16:
            raise ValueError("开发期 Bearer token 至少需要 16 个字符")
        if self.maxRequestBodyBytes <= 0:
            raise ValueError("maxRequestBodyBytes 必须大于 0")
        if not math.isfinite(self.maxRequestBodySeconds) or self.maxRequestBodySeconds <= 0:
            raise ValueError("maxRequestBodySeconds 必须为有限正数")
        if not math.isfinite(self.providerTimeoutSeconds) or self.providerTimeoutSeconds <= 0:
            raise ValueError("providerTimeoutSeconds 必须大于 0")
        if self.maxConcurrentRequests <= 0:
            raise ValueError("maxConcurrentRequests 必须大于 0")
        if (
            (self.enableTask018FakeIdentity or self.usesPnvs)
            and self.databaseBackend == "sqlite"
            and self.task018DatabasePath is None
        ):
            raise ValueError("启用 SQLite 身份时必须配置数据库路径")
        if self.remoteProviderMode not in {"fake", "glm"}:
            raise ValueError("remoteProviderMode 必须是 fake 或 glm")
        if self.remoteProviderMode == "glm" and not self.glmApiKey:
            raise ValueError("启用 GLM Provider 时必须通过环境变量配置 API Key")
        if (
            not math.isfinite(self.remoteProviderRequestTimeoutSeconds)
            or self.remoteProviderRequestTimeoutSeconds <= 0
        ):
            raise ValueError("remoteProviderRequestTimeoutSeconds 必须大于 0")
        if (
            not math.isfinite(self.remoteProviderDeadlineSeconds)
            or self.remoteProviderDeadlineSeconds <= 0
        ):
            raise ValueError("remoteProviderDeadlineSeconds 必须大于 0")
        if self.remoteProviderMaximumActiveRequests <= 0:
            raise ValueError("remoteProviderMaximumActiveRequests 必须大于 0")
        if self.remoteProviderMaximumQueuedRequests < 0:
            raise ValueError("remoteProviderMaximumQueuedRequests 不能为负数")
        if (
            not math.isfinite(self.remoteProviderQueueWaitSeconds)
            or self.remoteProviderQueueWaitSeconds <= 0
        ):
            raise ValueError("remoteProviderQueueWaitSeconds 必须大于 0")

    @property
    def usesPnvs(self) -> bool:
        return self.pnvsCredentialsPath is not None

    @classmethod
    def fromEnvironment(cls) -> GatewaySettings:
        configuredToken = os.environ.get("AGENT_GATEWAY_TEST_BEARER_TOKEN")
        configuredDatabasePath = os.environ.get("AGENT_GATEWAY_TASK018_DATABASE_PATH")
        remoteProviderMode = _readRemoteProviderMode()
        return cls(
            openTestPolicy=(
                loadOpenTestPolicy(Path(os.environ["AGENT_GATEWAY_OPEN_TEST_POLICY_PATH"]))
                if os.environ.get("AGENT_GATEWAY_OPEN_TEST_POLICY_PATH")
                else None
            ),
            guestDatabasePath=(
                Path(os.environ["GATEWAY_GUEST_DATABASE_PATH"])
                if os.environ.get("GATEWAY_GUEST_DATABASE_PATH")
                else None
            ),
            guestMonthlyCallLimit=int(os.environ.get("GATEWAY_GUEST_MONTHLY_CALL_LIMIT", "0")),
            guestEnabledUntilUtc=os.environ.get("GATEWAY_GUEST_ENABLED_UNTIL_UTC"),
            databaseBackend=_readDatabaseBackend(),
            databaseDsn=os.environ.get("GATEWAY_DATABASE_DSN"),
            databaseTlsCaFile=(
                Path(os.environ["GATEWAY_DATABASE_TLS_CA_FILE"])
                if "GATEWAY_DATABASE_TLS_CA_FILE" in os.environ
                else None
            ),
            databaseExpiresAtUtc=os.environ.get("GATEWAY_DATABASE_EXPIRES_AT_UTC"),
            executionEnvironment=_readExecutionEnvironment(),
            testBearerToken=configuredToken,
            maxRequestBodyBytes=_readPositiveInteger(
                "AGENT_GATEWAY_MAX_BODY_BYTES",
                65_536,
            ),
            maxRequestBodySeconds=_readPositiveFloat("AGENT_GATEWAY_MAX_BODY_SECONDS", 10.0),
            providerTimeoutSeconds=_readPositiveFloat(
                "AGENT_GATEWAY_PROVIDER_TIMEOUT_SECONDS",
                2.0,
            ),
            maxConcurrentRequests=_readPositiveInteger(
                "AGENT_GATEWAY_MAX_CONCURRENT_REQUESTS",
                4,
            ),
            task018DatabasePath=(
                None if configuredDatabasePath is None else Path(configuredDatabasePath)
            ),
            enableTask018FakeIdentity=_readBoolean(
                "AGENT_GATEWAY_ENABLE_TASK018_FAKE_IDENTITY",
                False,
            ),
            enableAccountPrivileges=_readBoolean("AGENT_GATEWAY_ENABLE_ACCOUNT_PRIVILEGES", False),
            enableRecoveryCodes=_readBoolean("AGENT_GATEWAY_ENABLE_RECOVERY_CODES", False),
            enableAccountRetention=_readBoolean("AGENT_GATEWAY_ENABLE_ACCOUNT_RETENTION", False),
            enableSmsAttemptRetention=_readBoolean(
                "AGENT_GATEWAY_ENABLE_SMS_ATTEMPT_RETENTION", False
            ),
            pnvsCredentialsPath=(
                Path(os.environ["AGENT_GATEWAY_PNVS_CREDENTIALS_PATH"])
                if "AGENT_GATEWAY_PNVS_CREDENTIALS_PATH" in os.environ
                else None
            ),
            pnvsRuntimePath=(
                Path(os.environ["AGENT_GATEWAY_PNVS_RUNTIME_PATH"])
                if "AGENT_GATEWAY_PNVS_RUNTIME_PATH" in os.environ
                else None
            ),
            cloudRuntimePath=(
                Path(os.environ["AGENT_GATEWAY_CLOUD_RUNTIME_PATH"])
                if "AGENT_GATEWAY_CLOUD_RUNTIME_PATH" in os.environ
                else None
            ),
            remoteProviderMode=remoteProviderMode,
            glmApiKey=os.environ.get("AGENT_GATEWAY_GLM_API_KEY"),
            remoteProviderRequestTimeoutSeconds=_readPositiveFloat(
                "AGENT_GATEWAY_REMOTE_PROVIDER_REQUEST_TIMEOUT_SECONDS",
                120.0,
            ),
            remoteProviderDeadlineSeconds=_readPositiveFloat(
                "AGENT_GATEWAY_REMOTE_PROVIDER_DEADLINE_SECONDS",
                125.0,
            ),
            remoteProviderMaximumActiveRequests=_readPositiveInteger(
                "AGENT_GATEWAY_REMOTE_PROVIDER_MAXIMUM_ACTIVE_REQUESTS",
                2,
            ),
            remoteProviderMaximumQueuedRequests=_readNonNegativeInteger(
                "AGENT_GATEWAY_REMOTE_PROVIDER_MAXIMUM_QUEUED_REQUESTS",
                2,
            ),
            remoteProviderQueueWaitSeconds=_readPositiveFloat(
                "AGENT_GATEWAY_REMOTE_PROVIDER_QUEUE_WAIT_SECONDS",
                1.0,
            ),
        )


def _readPositiveInteger(environmentName: str, defaultValue: int) -> int:
    configuredValue = os.environ.get(environmentName)
    if configuredValue is None:
        return defaultValue
    try:
        parsedValue = int(configuredValue)
    except ValueError:
        raise ValueError(f"{environmentName} 必须是整数") from None
    if parsedValue <= 0:
        raise ValueError(f"{environmentName} 必须大于 0")
    return parsedValue


def _readExecutionEnvironment() -> Literal["development", "production"]:
    value = os.environ.get("AGENT_GATEWAY_EXECUTION_ENVIRONMENT", "development")
    if value == "development":
        return "development"
    if value == "production":
        return "production"
    raise ValueError("无效执行环境")


def _readDatabaseBackend() -> Literal["sqlite", "mysql"]:
    value = os.environ.get("GATEWAY_DATABASE_BACKEND", "sqlite")
    if value == "sqlite":
        return "sqlite"
    if value == "mysql":
        return "mysql"
    raise ValueError("GATEWAY_DATABASE_BACKEND 必须是 sqlite 或 mysql")


def _readPositiveFloat(environmentName: str, defaultValue: float) -> float:
    configuredValue = os.environ.get(environmentName)
    if configuredValue is None:
        return defaultValue
    try:
        parsedValue = float(configuredValue)
    except ValueError:
        raise ValueError(f"{environmentName} 必须是数字") from None
    if not math.isfinite(parsedValue) or parsedValue <= 0:
        raise ValueError(f"{environmentName} 必须大于 0")
    return parsedValue


def _readNonNegativeInteger(environmentName: str, defaultValue: int) -> int:
    configuredValue = os.environ.get(environmentName)
    if configuredValue is None:
        return defaultValue
    try:
        parsedValue = int(configuredValue)
    except ValueError:
        raise ValueError(f"{environmentName} 必须是整数") from None
    if parsedValue < 0:
        raise ValueError(f"{environmentName} 不能为负数")
    return parsedValue


def _readRemoteProviderMode() -> RemoteProviderMode:
    configuredValue = os.environ.get("AGENT_GATEWAY_REMOTE_PROVIDER_MODE", "fake")
    if configuredValue == "fake":
        return "fake"
    if configuredValue == "glm":
        return "glm"
    raise ValueError("AGENT_GATEWAY_REMOTE_PROVIDER_MODE 必须是 fake 或 glm")


def _readBoolean(environmentName: str, defaultValue: bool) -> bool:
    configuredValue = os.environ.get(environmentName)
    if configuredValue is None:
        return defaultValue
    normalizedValue = configuredValue.strip().lower()
    if normalizedValue == "true":
        return True
    if normalizedValue == "false":
        return False
    raise ValueError(f"{environmentName} 必须是 true 或 false")
