"""Bounded, short-lived original-result recovery; never starts a model request."""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import sqlite3
import subprocess
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from ctypes import wintypes
from pathlib import Path


class ResultCacheUnavailable(RuntimeError):
    def __init__(self) -> None:
        super().__init__("original_result_cache_unavailable")


class _Blob(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(wintypes.BYTE))]


def _dpapi(value: bytes, *, decrypt: bool) -> bytes:
    """CurrentUser DPAPI with fixed application entropy; no new password or key."""
    if os.name != "nt" or not 0 < len(value) <= 524_288:
        raise ResultCacheUnavailable()
    source = (wintypes.BYTE * len(value)).from_buffer_copy(value)
    blob = _Blob(len(value), source)
    entropy_bytes = b"resume-original-ai-result.v1"
    entropy_buffer = (wintypes.BYTE * len(entropy_bytes)).from_buffer_copy(entropy_bytes)
    entropy = _Blob(len(entropy_bytes), entropy_buffer)
    output = _Blob()
    crypt = ctypes.WinDLL("crypt32.dll", use_last_error=True, winmode=0x800)
    kernel = ctypes.WinDLL("kernel32.dll", use_last_error=True, winmode=0x800)
    function = crypt.CryptUnprotectData if decrypt else crypt.CryptProtectData
    function.argtypes = [
        ctypes.POINTER(_Blob),
        ctypes.c_void_p,
        ctypes.POINTER(_Blob),
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(_Blob),
    ]
    function.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    try:
        if not function(
            ctypes.byref(blob), None, ctypes.byref(entropy), None, None, 1, ctypes.byref(output)
        ):
            raise ResultCacheUnavailable()
        if not output.data or not 0 < output.size <= 524_288:
            raise ResultCacheUnavailable()
        return ctypes.string_at(output.data, output.size)
    finally:
        if output.data:
            ctypes.memset(output.data, 0, output.size)
            kernel.LocalFree(ctypes.cast(output.data, ctypes.c_void_p))


class RemoteResultCache:
    """Small local SQLite receipt cache, separate from RDS and resume cloud sync.

    Production uses DPAPI, in a pre-provisioned directory restricted to the
    service identity, SYSTEM and Administrators. Tests may inject a cipher.
    Only generated results/receipts are retained, never submitted source text,
    photos, bearer tokens, API keys, passwords or SMS codes.
    """

    retentionSeconds = 86_400
    maximumEntries = 128
    maximumPlaintextBytes = 262_144

    def __init__(
        self,
        directory: Path,
        *,
        protect: Callable[[bytes], bytes] | None = None,
        unprotect: Callable[[bytes], bytes] | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.productionProtected = protect is None and unprotect is None and os.name == "nt"
        self._protect = protect or (lambda value: _dpapi(value, decrypt=False))
        self._unprotect = unprotect or (lambda value: _dpapi(value, decrypt=True))
        self._clock = clock
        if not directory.is_absolute() or not directory.is_dir():
            raise ResultCacheUnavailable()
        for parent in (directory, *directory.parents):
            info = parent.stat(follow_symlinks=False)
            if parent.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
                raise ResultCacheUnavailable()
        self._path = directory / "original_results.sqlite3"
        if self._path.is_symlink() or (
            self._path.exists()
            and getattr(self._path.stat(follow_symlinks=False), "st_file_attributes", 0) & 0x400
        ):
            raise ResultCacheUnavailable()
        try:
            probe = b"original-result-local-protection-check"
            if self._unprotect(self._protect(probe)) != probe:
                raise ResultCacheUnavailable()
            with self._connect() as db:
                db.execute(
                    "CREATE TABLE IF NOT EXISTS results (key_hash TEXT PRIMARY KEY, "
                    "expires REAL NOT NULL, payload BLOB NOT NULL)"
                )
            self.purgeExpired()
        except Exception:
            raise ResultCacheUnavailable() from None

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self._path, timeout=2)
        try:
            db.execute("PRAGMA synchronous=FULL")
            db.execute("PRAGMA journal_mode=DELETE")
            with db:
                yield db
        finally:
            db.close()

    @staticmethod
    def _key(accountId: str, operationId: str) -> str:
        if not accountId or not operationId or len(accountId) > 128 or len(operationId) > 128:
            raise ResultCacheUnavailable()
        return hashlib.sha256(json.dumps([accountId, operationId]).encode()).hexdigest()

    def purgeExpired(self) -> int:
        try:
            with self._connect() as db:
                return db.execute(
                    "DELETE FROM results WHERE expires <= ?", (self._clock(),)
                ).rowcount
        except Exception:
            raise ResultCacheUnavailable() from None

    @property
    def isReady(self) -> bool:
        try:
            self.purgeExpired()
            with self._connect() as db:
                return bool(
                    db.execute("SELECT COUNT(*) FROM results").fetchone()[0] < self.maximumEntries
                )
        except ResultCacheUnavailable:
            return False

    def reserve(self, accountId: str, operationId: str) -> None:
        self._write(accountId, operationId, {"state": "running"}, reserve=True)

    def save(self, accountId: str, operationId: str, value: dict[str, object]) -> None:
        self._write(accountId, operationId, value, reserve=False)

    def _write(
        self, accountId: str, operationId: str, value: dict[str, object], *, reserve: bool
    ) -> None:
        key = self._key(accountId, operationId)
        envelope = {"accountId": accountId, "operationId": operationId, "value": value}
        try:
            raw = json.dumps(envelope, ensure_ascii=False, separators=(",", ":")).encode()
            if len(raw) > self.maximumPlaintextBytes:
                raise ResultCacheUnavailable()
            protected = self._protect(raw)
            if not 0 < len(protected) <= 524_288:
                raise ResultCacheUnavailable()
            with self._connect() as db:
                db.execute("BEGIN IMMEDIATE")
                db.execute("DELETE FROM results WHERE expires <= ?", (self._clock(),))
                row = db.execute(
                    "SELECT expires FROM results WHERE key_hash = ?", (key,)
                ).fetchone()
                if reserve:
                    if row is not None:
                        raise ResultCacheUnavailable()
                    if (
                        db.execute("SELECT COUNT(*) FROM results").fetchone()[0]
                        >= self.maximumEntries
                    ):
                        raise ResultCacheUnavailable()
                    db.execute(
                        "INSERT INTO results VALUES (?,?,?)",
                        (
                            key,
                            self._clock() + self.retentionSeconds,
                            protected,
                        ),
                    )
                else:
                    if row is None:
                        raise ResultCacheUnavailable()
                    # Reading/updating an original task never extends retention.
                    db.execute(
                        "UPDATE results SET payload = ? WHERE key_hash = ?", (protected, key)
                    )
        except Exception:
            raise ResultCacheUnavailable() from None

    def read(self, accountId: str, operationId: str) -> dict[str, object] | None:
        try:
            with self._connect() as db:
                row = db.execute(
                    "SELECT expires,payload FROM results WHERE key_hash = ?",
                    (self._key(accountId, operationId),),
                ).fetchone()
            if row is None or row[0] <= self._clock():
                return None
            if not 0 < len(row[1]) <= 524_288:
                raise ResultCacheUnavailable()
            raw = self._unprotect(row[1])
            if len(raw) > self.maximumPlaintextBytes:
                raise ResultCacheUnavailable()
            envelope = json.loads(raw)
            if (
                envelope["accountId"] != accountId
                or envelope["operationId"] != operationId
                or not isinstance(envelope["value"], dict)
            ):
                raise ResultCacheUnavailable()
            return dict(envelope["value"])
        except Exception:
            raise ResultCacheUnavailable() from None


def verifyWindowsResultDirectory(directory: Path) -> None:
    """Read-only exact ACL check under the existing runtime identity."""
    try:
        if os.name != "nt":
            raise ResultCacheUnavailable()
        kernel = ctypes.WinDLL("kernel32.dll", use_last_error=True, winmode=0x800)
        getDirectory = kernel.GetSystemDirectoryW
        getDirectory.argtypes = [wintypes.LPWSTR, wintypes.UINT]
        getDirectory.restype = wintypes.UINT
        buffer = ctypes.create_unicode_buffer(32768)
        size = getDirectory(buffer, len(buffer))
        if not 0 < size < len(buffer):
            raise ResultCacheUnavailable()
        powershell = Path(buffer.value) / "WindowsPowerShell/v1.0/powershell.exe"
        script = Path(__file__).resolve().parents[2] / "scripts/prepare_remote_result_cache.ps1"
        result = subprocess.run(  # noqa: S603 — fixed system program, no shell or secret arguments.
            [
                str(powershell),
                "-NoProfile",
                "-NonInteractive",
                "-File",
                str(script),
                "-ResultDirectory",
                str(directory),
                "-VerifyOnly",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
            check=False,
            creationflags=subprocess.CREATE_NO_WINDOW,
            env={**os.environ, "PSModulePath": str(powershell.parent / "Modules")},
        )
        if result.returncode != 0:
            raise ResultCacheUnavailable()
    except Exception:
        raise ResultCacheUnavailable() from None
