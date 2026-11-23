from __future__ import annotations

import pytest

from agent_gateway.settings import GatewaySettings


def test_环境配置只接受正数且不提供默认_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("AGENT_GATEWAY_TEST_BEARER_TOKEN", raising=False)
    monkeypatch.delenv("AGENT_GATEWAY_GLM_API_KEY", raising=False)
    monkeypatch.delenv("AGENT_GATEWAY_REMOTE_PROVIDER_MODE", raising=False)
    monkeypatch.setenv("AGENT_GATEWAY_MAX_BODY_BYTES", "1024")
    monkeypatch.setenv("AGENT_GATEWAY_PROVIDER_TIMEOUT_SECONDS", "0.5")
    monkeypatch.setenv("AGENT_GATEWAY_MAX_CONCURRENT_REQUESTS", "2")

    settings = GatewaySettings.fromEnvironment()

    assert settings.testBearerToken is None
    assert settings.maxRequestBodyBytes == 1024
    assert settings.providerTimeoutSeconds == 0.5
    assert settings.maxConcurrentRequests == 2
    assert settings.remoteProviderMode == "fake"
    assert settings.glmApiKey is None


def test_glm_模式必须显式提供当前进程密钥(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AGENT_GATEWAY_REMOTE_PROVIDER_MODE", "glm")
    monkeypatch.delenv("AGENT_GATEWAY_GLM_API_KEY", raising=False)

    with pytest.raises(ValueError):
        GatewaySettings.fromEnvironment()

    monkeypatch.setenv("AGENT_GATEWAY_GLM_API_KEY", "task019-synthetic-key-not-secret")
    settings = GatewaySettings.fromEnvironment()

    assert settings.remoteProviderMode == "glm"
    assert settings.glmApiKey is not None
    assert "task019-synthetic-key" not in repr(settings)


@pytest.mark.parametrize(
    ("environmentName", "invalidValue"),
    [
        ("AGENT_GATEWAY_MAX_BODY_BYTES", "0"),
        ("AGENT_GATEWAY_PROVIDER_TIMEOUT_SECONDS", "not-a-number"),
        ("AGENT_GATEWAY_MAX_CONCURRENT_REQUESTS", "-1"),
        ("AGENT_GATEWAY_REMOTE_PROVIDER_MODE", "other"),
        ("AGENT_GATEWAY_REMOTE_PROVIDER_MAXIMUM_QUEUED_REQUESTS", "-1"),
    ],
)
def test_非法环境配置使启动明确失败(
    monkeypatch: pytest.MonkeyPatch,
    environmentName: str,
    invalidValue: str,
) -> None:
    monkeypatch.setenv(environmentName, invalidValue)

    with pytest.raises(ValueError):
        GatewaySettings.fromEnvironment()


@pytest.mark.parametrize(
    "name",
    [
        "AGENT_GATEWAY_MAX_BODY_SECONDS",
        "AGENT_GATEWAY_PROVIDER_TIMEOUT_SECONDS",
        "AGENT_GATEWAY_REMOTE_PROVIDER_REQUEST_TIMEOUT_SECONDS",
        "AGENT_GATEWAY_REMOTE_PROVIDER_DEADLINE_SECONDS",
        "AGENT_GATEWAY_REMOTE_PROVIDER_QUEUE_WAIT_SECONDS",
    ],
)
@pytest.mark.parametrize("invalid", ["NaN", "inf", "-inf"])
def test_nonfinite_timeout_environment_is_rejected(
    monkeypatch: pytest.MonkeyPatch, name: str, invalid: str
) -> None:
    monkeypatch.setenv(name, invalid)
    with pytest.raises(ValueError):
        GatewaySettings.fromEnvironment()


@pytest.mark.parametrize("invalid", [0, -1, float("nan"), float("inf")])
def test_body_receive_deadline_requires_finite_positive_value(invalid: float) -> None:
    with pytest.raises(ValueError, match="maxRequestBodySeconds"):
        GatewaySettings(maxRequestBodySeconds=invalid)


def test_body_receive_deadline_has_explicit_environment_override(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("AGENT_GATEWAY_MAX_BODY_SECONDS", raising=False)
    assert GatewaySettings.fromEnvironment().maxRequestBodySeconds == 10
    monkeypatch.setenv("AGENT_GATEWAY_MAX_BODY_SECONDS", "1.5")
    assert GatewaySettings.fromEnvironment().maxRequestBodySeconds == 1.5


@pytest.mark.parametrize(
    "name",
    [
        "AGENT_GATEWAY_MAX_BODY_SECONDS",
        "AGENT_GATEWAY_MAX_BODY_BYTES",
        "AGENT_GATEWAY_REMOTE_PROVIDER_MAXIMUM_QUEUED_REQUESTS",
    ],
)
def test_invalid_numeric_setting_does_not_chain_private_input(
    monkeypatch: pytest.MonkeyPatch, name: str
) -> None:
    import traceback

    marker = "PRIVATE_CONFIG_INPUT"
    monkeypatch.setenv(name, marker)
    with pytest.raises(ValueError) as captured:
        GatewaySettings.fromEnvironment()
    assert marker not in "".join(traceback.format_exception(captured.value))
