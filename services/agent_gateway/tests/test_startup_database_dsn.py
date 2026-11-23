from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
from pathlib import Path
from types import ModuleType
from urllib.parse import unquote, urlsplit

import pytest


def _helper() -> ModuleType:
    path = Path(__file__).resolve().parents[1] / "scripts/build_startup_database_dsn.py"
    spec = importlib.util.spec_from_file_location("startup_database_dsn", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _payload(password: str | None = None) -> dict[str, object]:
    return {
        "host": "synthetic-db.example",
        "port": 3306,
        "database": "synthetic_accounts",
        "user": "synthetic_web",
        "password": password if password is not None else "synthetic-password",
    }


@pytest.mark.parametrize("password", [" @:/?#%+ ", "中文🙂密码", "quote'\"\\", " leading "])
def test_password_uri_round_trip_preserves_all_characters(password: str) -> None:
    dsn = _helper().buildDatabaseDsn(_payload(password))
    parsed = urlsplit(dsn)
    assert unquote(parsed.password or "") == password
    assert parsed.hostname == "synthetic-db.example"
    assert parsed.port == 3306 and parsed.path == "/synthetic_accounts"
    assert not parsed.query and not parsed.fragment


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("host", "host.example/other"),
        ("host", "host@example"),
        ("host", "bad..example"),
        ("host", "-bad.example"),
        ("port", True),
        ("port", 0),
        ("port", 65536),
        ("database", "accounts?mode=test"),
        ("user", "web@other"),
        ("password", ""),
        ("password", "synthetic\x00secret"),
        ("password", "synthetic\nsecret"),
        ("password", "中" * 4096),
    ],
)
def test_invalid_target_or_password_is_rejected_without_input_in_error(
    field: str,
    value: object,
) -> None:
    payload = _payload()
    payload[field] = value
    with pytest.raises(ValueError, match="^startup_database_input_invalid$"):
        _helper().buildDatabaseDsn(payload)


@pytest.mark.parametrize(
    "raw",
    ["not-json", '{"password":"synthetic-secret","password":"duplicate"}', "x" * 65537],
    ids=["not-json", "duplicate-field", "oversized-input"],
)
def test_pipe_failures_have_only_fixed_error(
    raw: str,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    helper = _helper()
    monkeypatch.setattr(helper.sys, "stdin", io.StringIO(raw))
    monkeypatch.setattr(helper.sys, "argv", ["private-helper"])
    assert helper.main() == 1
    assert capsys.readouterr() == ("", "startup_database_input_invalid\n")


def test_unsupported_cli_cannot_echo_accidental_secret(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    helper = _helper()
    monkeypatch.setattr(helper.sys, "argv", ["private-helper", "accidental-synthetic-secret"])
    assert helper.main() == 1
    assert capsys.readouterr() == ("", "startup_database_input_invalid\n")


def test_interactive_output_is_refused(monkeypatch: pytest.MonkeyPatch) -> None:
    class Terminal(io.StringIO):
        def isatty(self) -> bool:
            return True

    helper = _helper()
    terminal = Terminal()
    errors = io.StringIO()
    monkeypatch.setattr(helper.sys, "argv", ["private-helper"])
    monkeypatch.setattr(helper.sys, "stdin", io.StringIO(json.dumps(_payload())))
    monkeypatch.setattr(helper.sys, "stdout", terminal)
    monkeypatch.setattr(helper.sys, "stderr", errors)
    assert helper.main() == 1 and terminal.getvalue() == ""
    assert errors.getvalue() == "startup_database_input_invalid\n"


def test_actual_windows_ps51_private_pipe_preserves_unicode_and_password_edges() -> None:
    if os.name != "nt":
        pytest.skip("Windows PowerShell 5.1 private pipe")
    service = Path(__file__).resolve().parents[1]
    powershell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    # Evaluate just the parsed function body, not the GUI or the entire startup script.
    # The test uses only synthetic input and never generates/decrypts real configuration.
    command = r"""
$ErrorActionPreference='Stop'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
$payload=[Console]::In.ReadToEnd()|ConvertFrom-Json
$PSScriptRoot=$payload.scriptDirectory
$DatabaseHost=$payload.host;$DatabasePort=[int]$payload.port
$DatabaseName=$payload.database;$DatabaseUser=$payload.user
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'prepare_gateway_startup.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count-ne 0){throw 'Parse failed'}
$function=$ast.Find({param($node)
  $node-is [Management.Automation.Language.FunctionDefinitionAst]-and
  $node.Name-eq 'Get-StartupDatabaseDsn'},$true)
$dsn=& $function.Body.GetScriptBlock() -Password $payload.password
[Console]::Out.Write((@{businessDatabaseDsn=$dsn}|ConvertTo-Json -Compress))
"""
    payload = _payload("  中文🙂 @:/?#%+\\'\"  ")
    payload["scriptDirectory"] = str(service / "scripts")
    environment = dict(os.environ)
    result = subprocess.run(  # noqa: S603 — fixed system PS, synthetic anonymous stdin.
        [str(powershell), "-NoProfile", "-NonInteractive", "-Command", command],
        input=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        capture_output=True,
        timeout=25,
        check=False,
        creationflags=subprocess.CREATE_NO_WINDOW,
        env=environment,
    )
    assert result.returncode == 0, "synthetic private pipe failed"
    assert result.stderr == b""
    parsed = json.loads(result.stdout)
    assert unquote(urlsplit(parsed["businessDatabaseDsn"]).password or "") == payload["password"]
    assert environment == dict(os.environ)
