from __future__ import annotations

import os
import sqlite3
from pathlib import Path

import pytest

from agent_gateway.remote_result_cache import RemoteResultCache, ResultCacheUnavailable


def _test_cache(path: Path, now: list[float]) -> RemoteResultCache:
    # Test framing only; never used by protected production startup.
    return RemoteResultCache(
        path,
        protect=lambda b: b"test:" + b[::-1],
        unprotect=lambda b: b.removeprefix(b"test:")[::-1],
        clock=lambda: now[0],
    )


def test_restart_recovers_original_result_without_extending_retention(tmp_path: Path) -> None:
    now = [1000.0]
    cache = _test_cache(tmp_path, now)
    cache.reserve("owner", "original")
    cache.save("owner", "original", {"state": "succeeded", "response": {"summary": "原结果"}})
    reopened = _test_cache(tmp_path, now)
    assert reopened.read("owner", "original") == {
        "state": "succeeded",
        "response": {"summary": "原结果"},
    }
    assert reopened.read("other-account", "original") is None
    now[0] += RemoteResultCache.retentionSeconds
    assert reopened.read("owner", "original") is None
    assert reopened.purgeExpired() == 1


def test_capacity_is_reserved_before_generation_and_never_overwrites_original(
    tmp_path: Path,
) -> None:
    cache = _test_cache(tmp_path, [1000.0])
    cache.maximumEntries = 1
    cache.reserve("owner", "original")
    with pytest.raises(ResultCacheUnavailable):
        cache.reserve("owner", "another")
    with pytest.raises(ResultCacheUnavailable):
        cache.reserve("owner", "original")
    assert cache.read("owner", "original") == {"state": "running"}
    with pytest.raises(ResultCacheUnavailable):
        cache.save("owner", "missing-reservation", {"state": "succeeded"})


def test_corruption_and_moved_ciphertext_cannot_return_another_owners_result(
    tmp_path: Path,
) -> None:
    cache = _test_cache(tmp_path, [1000.0])
    cache.reserve("owner", "original")
    cache.reserve("other", "another")
    with sqlite3.connect(tmp_path / "original_results.sqlite3") as db:
        source = db.execute(
            "SELECT payload FROM results WHERE key_hash=?", (cache._key("owner", "original"),)
        ).fetchone()[0]
        db.execute(
            "UPDATE results SET payload=? WHERE key_hash=?",
            (
                source,
                cache._key("other", "another"),
            ),
        )
    with pytest.raises(ResultCacheUnavailable):
        cache.read("other", "another")
    with sqlite3.connect(tmp_path / "original_results.sqlite3") as db:
        db.execute("UPDATE results SET payload=?", (b"corrupt",))
    with pytest.raises(ResultCacheUnavailable):
        cache.read("owner", "original")


@pytest.mark.skipif(os.name != "nt", reason="CurrentUser DPAPI is Windows-only")
def test_actual_windows_protection_and_restart_do_not_store_plaintext(tmp_path: Path) -> None:
    cache = RemoteResultCache(tmp_path)
    assert cache.productionProtected
    cache.reserve("synthetic-owner", "synthetic-task")
    cache.save(
        "synthetic-owner",
        "synthetic-task",
        {
            "state": "succeeded",
            "response": {"summary": "SYNTHETIC_PRIVATE_RESULT_2026"},
        },
    )
    raw = (tmp_path / "original_results.sqlite3").read_bytes()
    assert b"SYNTHETIC_PRIVATE_RESULT_2026" not in raw
    assert RemoteResultCache(tmp_path).read("synthetic-owner", "synthetic-task") == {
        "state": "succeeded",
        "response": {"summary": "SYNTHETIC_PRIVATE_RESULT_2026"},
    }
