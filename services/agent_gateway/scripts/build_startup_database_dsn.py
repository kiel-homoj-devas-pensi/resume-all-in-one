"""Encode startup credentials through private, redirected pipes only; never connect."""

from __future__ import annotations

import json
import re
import sys
from urllib.parse import quote


def buildDatabaseDsn(payload: object) -> str:
    if not isinstance(payload, dict) or set(payload) != {
        "host",
        "port",
        "database",
        "user",
        "password",
    }:
        raise ValueError("startup_database_input_invalid")
    host, port = payload["host"], payload["port"]
    database, user, password = payload["database"], payload["user"], payload["password"]
    if (
        not isinstance(host, str)
        or not 1 <= len(host) <= 253
        or any(
            re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) is None
            for label in host.split(".")
        )
        or type(port) is not int
        or not 1 <= port <= 65535
        or not isinstance(database, str)
        or re.fullmatch(r"[A-Za-z0-9_]{1,64}", database) is None
        or not isinstance(user, str)
        or re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", user) is None
        or not isinstance(password, str)
        or not 1 <= len(password) <= 4096
        or any(character in password for character in "\x00\r\n")
    ):
        raise ValueError("startup_database_input_invalid")
    # No trimming: leading/trailing spaces and URI delimiters belong to the password.
    result = f"mysql://{quote(user, safe='')}:{quote(password, safe='')}@{host}:{port}/{database}"
    if len(result) > 4096:
        raise ValueError("startup_database_input_invalid")
    return result


def _uniqueObject(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for name, value in pairs:
        if name in result:
            raise ValueError("startup_database_input_invalid")
        result[name] = value
    return result


def main() -> int:
    try:
        # A standalone interactive invocation must not print credentials to a terminal.
        if len(sys.argv) != 1 or sys.stdin.isatty() or sys.stdout.isatty():
            raise ValueError("startup_database_input_invalid")
        raw = sys.stdin.read(65_537)
        if len(raw) > 65_536:
            raise ValueError("startup_database_input_invalid")
        payload = json.loads(raw, object_pairs_hook=_uniqueObject)
        raw = ""
        dsn = buildDatabaseDsn(payload)
        # Only the parent GUI's anonymous output pipe receives this in-memory result.
        sys.stdout.write(json.dumps({"businessDatabaseDsn": dsn}, ensure_ascii=True))
        return 0
    except Exception:
        # Never forward parsing errors, input values or traceback details.
        sys.stderr.write("startup_database_input_invalid\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
