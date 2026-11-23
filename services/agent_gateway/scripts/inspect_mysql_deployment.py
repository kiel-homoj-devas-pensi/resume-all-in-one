"""Read-only deployment inspection; credentials arrive only over an anonymous stdin pipe."""

from __future__ import annotations

import argparse
import json
import re
import sys
from contextlib import suppress
from pathlib import Path
from typing import Any

import pymysql

ACCOUNTS = ("resume_owner", "resume_maint", "resume_web")


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--ca-file", type=Path, required=True)
    args = parser.parse_args(arguments)
    connections: list[Any] = []
    passwords: dict[str, str] = {}
    phase = "input"
    try:
        if (
            re.fullmatch(r"[A-Za-z0-9.-]{1,253}", args.host) is None
            or re.fullmatch(r"[A-Za-z0-9_]{1,64}", args.database) is None
            or re.fullmatch(r"[A-Za-z]:[\\/][^:]*", str(args.ca_file)) is None
            or not args.ca_file.is_file()
            or sys.stdin.isatty()
        ):
            raise ValueError
        if any(
            path.is_symlink() or path.is_junction()
            for path in (args.ca_file, *args.ca_file.parents)
        ):
            raise ValueError
        raw = sys.stdin.read(65537)
        if len(raw) > 65536:
            raise ValueError
        payload = json.loads(raw)
        if not isinstance(payload, dict) or set(payload) != set(ACCOUNTS):
            raise ValueError
        if any(
            not isinstance(value, str) or not 1 <= len(value) <= 4096 for value in payload.values()
        ):
            raise ValueError
        passwords = payload
        raw = ""
        identities = []
        for account in ACCOUNTS:
            phase = account
            # No default database: newly created ordinary accounts may have no DB grants yet.
            connection = pymysql.connect(
                host=args.host,
                port=3306,
                user=account,
                password=passwords[account],
                charset="utf8mb4",
                cursorclass=pymysql.cursors.DictCursor,
                connect_timeout=12,
                read_timeout=12,
                write_timeout=12,
                ssl_ca=str(args.ca_file),
                ssl_verify_cert=True,
                ssl_verify_identity=True,
                local_infile=False,
                autocommit=True,
            )
            connections.append(connection)
            if not connection._secure:
                raise ValueError
            with connection.cursor() as cursor:
                cursor.execute("SELECT CURRENT_USER() AS identity, CURRENT_ROLE() AS roles")
                identity = cursor.fetchone()
                if not identity or identity["identity"].split("@", 1)[0] != account:
                    raise ValueError
                cursor.execute("SHOW GRANTS")
                rows = cursor.fetchall()
                grants = [next(iter(row.values())) for row in rows]
                if len(grants) > 100 or any(
                    not isinstance(row, str) or len(row) > 4096 for row in grants
                ):
                    raise ValueError
                # Do not expose legacy authentication clauses if a server returns one.
                grants = [
                    "<authentication clause redacted>"
                    if re.search(r"\b(?:IDENTIFIED|PASSWORD)\b", row, re.IGNORECASE)
                    else row
                    for row in grants
                ]
                identities.append(
                    {
                        "account": account,
                        "effectiveIdentity": identity["identity"],
                        "roles": identity["roles"],
                        "grants": grants,
                        "certificateAndHostnameVerified": True,
                    }
                )
        phase = "owner_read_only_inventory"
        with connections[0].cursor() as cursor:
            cursor.execute(
                "SELECT DEFAULT_CHARACTER_SET_NAME AS charset, "
                "DEFAULT_COLLATION_NAME AS collation FROM information_schema.schemata "
                "WHERE SCHEMA_NAME=%s",
                (args.database,),
            )
            database = cursor.fetchone()
            if not database:
                raise ValueError
            cursor.execute(
                "SELECT TABLE_NAME AS name FROM information_schema.tables "
                "WHERE TABLE_SCHEMA=%s ORDER BY TABLE_NAME",
                (args.database,),
            )
            observed_tables = [row["name"] for row in cursor.fetchall()]
        print(
            json.dumps(
                {
                    "status": "authenticated_accounts_inspected",
                    "accounts": identities,
                    "database": args.database,
                    "databaseMetadata": database,
                    "ownerObservedTables": observed_tables,
                    "emptyDatabaseCertified": False,
                    "ddlOrDmlExecuted": False,
                    "grantsApplied": False,
                    "smsOrModelCalled": False,
                }
            )
        )
        return 0
    except Exception as error:
        code = error.args[0] if error.args and type(error.args[0]) is int else None
        print(
            json.dumps(
                {
                    "status": "inspection_failed",
                    "phase": phase,
                    "driverCode": code,
                    "retryable": False,
                    "ddlOrDmlExecuted": False,
                    "grantsApplied": False,
                }
            )
        )
        return 1
    finally:
        passwords.clear()
        for connection in connections:
            with suppress(Exception):
                connection.close()


if __name__ == "__main__":
    raise SystemExit(main())
