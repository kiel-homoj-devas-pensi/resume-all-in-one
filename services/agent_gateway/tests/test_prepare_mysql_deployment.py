from __future__ import annotations

import importlib.util
import io
import json
import re
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

from agent_gateway.mysql_cloud_schema import CLOUD_COLUMNS
from agent_gateway.mysql_lifecycle_schema import LIFECYCLE_COLUMNS
from agent_gateway.mysql_schema import COLUMNS
from agent_gateway.mysql_sms_schema import SMS_COLUMNS
from agent_gateway.mysql_usage_schema import USAGE_COLUMNS
from agent_gateway.privilege_schema import MYSQL_COLUMNS


def preparer() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "deployment_preparer",
        Path(__file__).resolve().parents[1] / "scripts/prepare_mysql_deployment.py",
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def columns() -> dict[str, set[str]]:
    return {
        table: {row[0] for row in entries}
        for mapping in (
            COLUMNS,
            USAGE_COLUMNS,
            LIFECYCLE_COLUMNS,
            SMS_COLUMNS,
            CLOUD_COLUMNS,
            MYSQL_COLUMNS,
        )
        for table, entries in mapping.items()
    }


def test_grant_columns_match_versioned_schema() -> None:
    module = preparer()
    known = columns()
    for mapping in (module.WEB_WRITES, module.MAINT_WRITES):
        for table, privileges in mapping.items():
            assert table in known
            for privilege in privileges:
                match = re.fullmatch(r"(INSERT|UPDATE)\(([a-z_0-9,]+)\)", privilege)
                assert match and set(match[2].split(",")) <= known[table]
    assert set(module.MAINT_WRITES) == {"account_privilege_grants", "sms_send_budget"}
    assert (
        set(module.MAINT_WRITES["sms_send_budget"][0][7:-1].split(",")) == known["sms_send_budget"]
    )
    assert (
        set(module.MAINT_WRITES["account_privilege_grants"][0][7:-1].split(","))
        == known["account_privilege_grants"]
    )


def test_negative_probes_change_zero_rows_and_use_real_columns() -> None:
    module = preparer()
    statements: list[str] = []

    class Denied:
        def cursor(self) -> Denied:
            return self

        def __enter__(self) -> Denied:
            return self

        def __exit__(self, *args: object) -> None:
            pass

        def execute(self, sql: str) -> None:
            statements.append(sql)
            raise module.pymysql.err.OperationalError(1143, "synthetic denial")

    assert module.verify_denials(Denied(), "synthetic") == 34
    known = columns()
    for sql in statements:
        assert sql.endswith("WHERE 1=0")
        if sql.startswith("UPDATE"):
            table, column = re.findall(r"`([^`]+)`", sql)[1:3]
            assert column in known[table]


@pytest.mark.parametrize("granted", [True, False])
def test_negative_probe_requires_permission_error(granted: bool) -> None:
    module = preparer()

    class Invalid:
        def cursor(self) -> Invalid:
            return self

        def __enter__(self) -> Invalid:
            return self

        def __exit__(self, *args: object) -> None:
            pass

        def execute(self, sql: str) -> None:
            if not granted:
                raise module.pymysql.err.OperationalError(1054, "bad column")

    with pytest.raises(ValueError):
        module.verify_denials(Invalid(), "synthetic")


def test_missing_apply_confirmation_never_connects(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module = preparer()
    ca = tmp_path / "synthetic-ca.pem"
    ca.write_text("synthetic fixture")
    secrets = {account: "synthetic-secret" for account in module.ACCOUNTS}
    monkeypatch.setattr(module.sys, "stdin", io.StringIO(json.dumps(secrets)))
    monkeypatch.setattr(module.pymysql, "connect", lambda **kw: pytest.fail("no connection"))
    assert (
        module.main(
            [
                "--host",
                "synthetic.example",
                "--database",
                "synthetic",
                "--ca-file",
                str(ca),
                "--expires-at-utc",
                "2099-01-01T00:00:00Z",
                "--apply",
            ]
        )
        == 1
    )
    result = json.loads(capsys.readouterr().out)
    assert result["writeRequested"] is False


def test_unknown_write_result_is_redacted_and_never_retried(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    module = preparer()
    ca = tmp_path / "synthetic-ca.pem"
    ca.write_text("synthetic fixture")
    secrets = {account: account + "-synthetic-secret" for account in module.ACCOUNTS}
    monkeypatch.setattr(module.sys, "stdin", io.StringIO(json.dumps(secrets)))
    calls = []

    def fail(args: Any, passwords: dict[str, str], journal: dict[str, Any]) -> None:
        calls.append(True)
        journal["writeRequested"] = True
        raise RuntimeError(2013, str(passwords))

    monkeypatch.setattr(module, "initialize", fail)
    assert (
        module.main(
            [
                "--host",
                "synthetic.example",
                "--database",
                "synthetic",
                "--ca-file",
                str(ca),
                "--expires-at-utc",
                "2099-01-01T00:00:00Z",
                "--apply",
                "--confirmed-quiescent-dedicated-empty",
            ]
        )
        == 2
    )
    output = capsys.readouterr().out
    result = json.loads(output)
    assert result["status"] == "outcome_requires_read_only_review"
    assert result["driverCode"] == 2013 and result["retryable"] is False
    assert len(calls) == 1 and all(secret not in output for secret in secrets.values())


def default_rds_grants(account: str) -> list[str]:
    recipient = f"`{account}`@`%`"
    return [
        f"GRANT PROCESS, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO {recipient}",
        f"GRANT XA_RECOVER_ADMIN ON *.* TO {recipient}",
        *(
            f"GRANT SELECT ON `mysql`.`{table}` TO {recipient}"
            for table in (
                "func",
                "general_log",
                "help_category",
                "help_keyword",
                "help_relation",
                "help_topic",
                "slow_log",
                "time_zone",
                "time_zone_name",
                "time_zone_transition",
                "time_zone_transition_type",
                "time_zone_leap_second",
            )
        ),
    ]


@pytest.mark.parametrize("account", ["resume_maint", "resume_web"])
def test_real_rds_default_grants_are_only_accepted_before_normalization(
    account: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = preparer()
    statements = default_rds_grants(account)
    monkeypatch.setattr(module, "grants", lambda connection: statements)
    module.require_initial_default_grants(object())
    # Neither blank normalization nor final application permissions may retain these defaults.
    for blank in (True, False):
        with pytest.raises(ValueError):
            module.scoped_grants(object(), "synthetic", account, blank=blank)


@pytest.mark.parametrize(
    "unexpected",
    [
        "GRANT SELECT ON `mysql`.`user` TO `resume_maint`@`%`",
        "GRANT SELECT ON `mysql`.* TO `resume_maint`@`%`",
        "GRANT SELECT ON `mysql`.`general_log_backup` TO `resume_maint`@`%`",
        "GRANT SELECT ON `synthetic`.`accounts` TO `resume_maint`@`%`",
        "GRANT SELECT ON `synthetic`.* TO `resume_maint`@`%`",
        "GRANT SELECT ON `mysql`.`general_log` TO `resume_maint`@`%` WITH GRANT OPTION",
        "GRANT CREATE ON `mysql`.`general_log` TO `resume_maint`@`%`",
        "GRANT SELECT, UPDATE ON `mysql`.`general_log` TO `resume_maint`@`%`",
        "GRANT `unexpected_role`@`%` TO `resume_maint`@`%`",
    ],
)
def test_unreviewed_grants_still_rejected_before_normalization(
    unexpected: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = preparer()
    statements = [*default_rds_grants("resume_maint"), unexpected]
    monkeypatch.setattr(module, "grants", lambda connection: statements)
    with pytest.raises(ValueError):
        module.require_initial_default_grants(object())
