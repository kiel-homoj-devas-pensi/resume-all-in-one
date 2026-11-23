from __future__ import annotations

import json
from pathlib import Path

from agent_gateway.app import createApplication
from agent_gateway.settings import GatewaySettings


def main() -> None:
    serviceRoot = Path(__file__).resolve().parents[1]
    snapshotPath = serviceRoot / "openapi" / "v0.13.json"
    snapshotPath.parent.mkdir(parents=True, exist_ok=True)

    # OpenAPI 只依赖契约；占位 token 不读取环境，也不会出现在 schema 中。
    application = createApplication(
        settings=GatewaySettings(testBearerToken="openapi-placeholder-token"),
    )
    serializedSchema = json.dumps(
        application.openapi(),
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    )
    snapshotPath.write_text(f"{serializedSchema}\n", encoding="utf-8")


if __name__ == "__main__":
    main()
