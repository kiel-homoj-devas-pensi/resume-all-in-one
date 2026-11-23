import asyncio
import importlib.util
import json
from pathlib import Path
from types import ModuleType

import pytest

from agent_gateway.remote_provider import (
    RemoteProviderOutcomeUnknownError,
)


def smokeModule() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "synthetic_smoke", Path(__file__).parents[1] / "scripts/run_glm_synthetic_smoke.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_three_fixed_synthetic_contracts_have_unique_action_ids() -> None:
    module = smokeModule()
    first, second = module.syntheticRequests(), module.syntheticRequests()
    assert len(first) == 3
    assert len({request.capability for request in first}) == 3
    assert {request.idempotencyKey for request in first}.isdisjoint(
        {request.idempotencyKey for request in second}
    )


def test_paid_smoke_budget_never_retries_unknown_and_requires_manual_semantic_review(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = smokeModule()

    class UnknownProvider:
        calls = 0

        async def generate(self, *args: object, **kwargs: object) -> object:
            self.calls += 1
            raise RemoteProviderOutcomeUnknownError

        async def aclose(self) -> None:
            pass

    provider = UnknownProvider()
    monkeypatch.setattr(module, "GlmRemoteResumeProvider", lambda *args, **kwargs: provider)
    report = tmp_path / "synthetic.json"
    assert not asyncio.run(
        module.runSyntheticSmokeTest(
            "synthetic-test-key-long-enough", maximumCalls=3, reportPath=report
        )
    )
    assert provider.calls == 1
    evidence = json.loads(report.read_text(encoding="utf-8"))
    assert evidence["semanticReview"] == "notReviewed"
    assert evidence["results"][0]["status"] == "outcomeUnknown"
    assert "synthetic-key" not in report.read_text(encoding="utf-8")
