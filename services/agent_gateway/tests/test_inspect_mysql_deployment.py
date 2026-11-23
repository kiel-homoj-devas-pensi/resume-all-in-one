from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest


def inspector() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "deployment_inspector",
        Path(__file__).resolve().parents[1] / "scripts/inspect_mysql_deployment.py",
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def configure(
    module: ModuleType, monkeypatch: pytest.MonkeyPatch, tmp_path: Path, payload: dict[str, str]
) -> list[str]:
    ca = tmp_path / "synthetic-ca.pem"
    ca.write_text("synthetic fixture; no network")
    monkeypatch.setattr(module.sys, "stdin", io.StringIO(json.dumps(payload)))
    return ["--host", "synthetic.example", "--database", "resume_aio", "--ca-file", str(ca)]


def test_invalid_payload_never_attempts_network(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module = inspector()
    args = configure(module, monkeypatch, tmp_path, {"resume_owner": "synthetic-secret"})
    monkeypatch.setattr(module.pymysql, "connect", lambda **kw: pytest.fail("no connection"))
    assert module.main(args) == 1
    result = json.loads(capsys.readouterr().out)
    assert result["phase"] == "input"
    assert result["grantsApplied"] is False


def test_driver_error_never_prints_credentials_or_exception(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module = inspector()
    secrets = {account: account + "-synthetic-secret" for account in module.ACCOUNTS}
    args = configure(module, monkeypatch, tmp_path, secrets)

    def reject(**kwargs: object) -> None:
        raise RuntimeError(1045, str(secrets))

    monkeypatch.setattr(module.pymysql, "connect", reject)
    assert module.main(args) == 1
    output = capsys.readouterr().out
    assert all(secret not in output for secret in secrets.values())
    assert json.loads(output)["driverCode"] == 1045


def test_read_only_accounts_use_tls_and_no_default_database(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module = inspector()
    args = configure(
        module, monkeypatch, tmp_path, {account: "synthetic-secret" for account in module.ACCOUNTS}
    )
    queries: list[str] = []
    made: list[FakeConnection] = []

    class FakeConnection:
        _secure = True

        def __init__(self, account: str) -> None:
            self.account = account
            self.closed = False
            self.query = ""

        def cursor(self) -> FakeConnection:
            return self

        def __enter__(self) -> FakeConnection:
            return self

        def __exit__(self, *args: object) -> None:
            pass

        def execute(self, sql: str, params: object = None) -> None:
            self.query = sql
            queries.append(sql)

        def fetchone(self) -> dict[str, str]:
            if "CURRENT_USER" in self.query:
                return {"identity": self.account + "@synthetic-host", "roles": "NONE"}
            return {"charset": "utf8mb4", "collation": "utf8mb4_bin"}

        def fetchall(self) -> list[dict[str, str]]:
            if self.query == "SHOW GRANTS":
                return [
                    {"grant": "GRANT USAGE ON *.* TO synthetic"},
                    {"grant": "GRANT USAGE IDENTIFIED BY 'must-not-print'"},
                ]
            return []

        def close(self) -> None:
            self.closed = True

    def connect(**kwargs: Any) -> FakeConnection:
        assert "database" not in kwargs
        assert kwargs["ssl_verify_cert"] and kwargs["ssl_verify_identity"]
        assert kwargs["local_infile"] is False
        made.append(FakeConnection(kwargs["user"]))
        return made[-1]

    monkeypatch.setattr(module.pymysql, "connect", connect)
    assert module.main(args) == 0
    output = capsys.readouterr().out
    assert "must-not-print" not in output
    result = json.loads(output)
    assert result["emptyDatabaseCertified"] is False
    assert len(result["accounts"]) == 3
    assert all(query.startswith(("SELECT ", "SHOW GRANTS")) for query in queries)
    assert all(connection.closed for connection in made)
