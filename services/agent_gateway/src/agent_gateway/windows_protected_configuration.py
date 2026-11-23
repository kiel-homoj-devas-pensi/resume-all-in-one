from __future__ import annotations

import ctypes
import json
import os
import re
import subprocess
from collections.abc import Iterator
from contextlib import contextmanager
from ctypes import wintypes
from pathlib import Path
from typing import BinaryIO, Literal, cast

ProtectionKind = Literal["pnvsCredentials", "pnvsRuntime", "cloudRuntime", "gatewayStartup"]
_MAXIMUM_BYTES = 65_536
_SERVICE_ROOT = Path(__file__).resolve().parents[2]
_REPOSITORY_ROOT = _SERVICE_ROOT.parents[1]
_VALIDATORS = {
    "pnvsCredentials": ("prepare_pnvs_credentials.ps1", "-EncryptedCredentialsPath"),
    "pnvsRuntime": ("prepare_pnvs_runtime.ps1", "-EncryptedRuntimePath"),
    "cloudRuntime": ("prepare_cloud_runtime.ps1", "-EncryptedRuntimePath"),
    "gatewayStartup": ("prepare_gateway_startup.ps1", "-EncryptedStartupPath"),
}


class ProtectedConfigurationError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("protected_configuration_unavailable")


class _DataBlob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(wintypes.BYTE))]


def _systemLibrary(name: str) -> ctypes.CDLL:
    # DLL 只从 Windows 系统目录加载，不搜索当前工作目录。
    return ctypes.WinDLL(name, use_last_error=True, winmode=0x800)


def _configurationPath(value: str | Path) -> Path:
    raw = str(value)
    if not re.match(r"^[A-Za-z]:[\\/]", raw) or ":" in raw[2:]:
        raise ProtectedConfigurationError()
    path = Path(os.path.abspath(raw))
    if path.is_relative_to(_REPOSITORY_ROOT):
        raise ProtectedConfigurationError()
    for candidate in (path, *path.parents):
        attributes = candidate.stat(follow_symlinks=False).st_file_attributes
        if attributes & 0x400:  # 包括符号链接、目录 junction 和其他重解析点。
            raise ProtectedConfigurationError()
    if not path.is_file() or not 0 < path.stat().st_size <= _MAXIMUM_BYTES:
        raise ProtectedConfigurationError()
    return path


@contextmanager
def _lockedFile(path: Path) -> Iterator[BinaryIO]:
    import msvcrt

    kernel = _systemLibrary("kernel32.dll")
    createFile = kernel.CreateFileW
    createFile.argtypes = [
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.c_void_p,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    ]
    createFile.restype = wintypes.HANDLE
    closeHandle = kernel.CloseHandle
    closeHandle.argtypes = [wintypes.HANDLE]
    closeHandle.restype = wintypes.BOOL
    # 只读共享：检查和解密期间不能写入、替换或删除这个文件。
    handle = createFile(str(path), 0x80000000, 1, None, 3, 0x200000, None)
    if handle is None or handle == ctypes.c_void_p(-1).value:
        raise ProtectedConfigurationError()
    try:
        descriptor = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
    except Exception:
        closeHandle(handle)
        raise
    # open_osfhandle 成功后，文件对象拥有句柄，关闭时只释放一次。
    with os.fdopen(descriptor, "rb") as stream:
        yield stream


def _verifyProtectedFile(path: Path, kind: ProtectionKind) -> None:
    kernel = _systemLibrary("kernel32.dll")
    getDirectory = kernel.GetSystemDirectoryW
    getDirectory.argtypes = [wintypes.LPWSTR, wintypes.UINT]
    getDirectory.restype = wintypes.UINT
    buffer = ctypes.create_unicode_buffer(32_768)
    size = getDirectory(buffer, len(buffer))
    if not 0 < size < len(buffer):
        raise ProtectedConfigurationError()
    powershell = Path(buffer.value) / "WindowsPowerShell/v1.0/powershell.exe"
    entry, parameter = _VALIDATORS[kind]
    validator = _SERVICE_ROOT / "scripts" / entry
    # 复用录入端的精确 ACL / 字段 / 当前用户检查。子进程不返回明文，
    # 成功和失败输出均丢弃；命令参数只有脚本与加密文件路径。
    result = subprocess.run(  # noqa: S603 — 固定系统程序、参数列表、无 shell。
        [
            str(powershell),
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(validator),
            parameter,
            str(path),
            "-VerifyOnly",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=15,
        check=False,
        creationflags=subprocess.CREATE_NO_WINDOW,
        # pwsh 启动的 Python 可能继承不兼容的模块路径；权限检查只能
        # 使用 Windows PowerShell 自带安全模块，不能加载用户同名模块。
        env={**os.environ, "PSModulePath": str(powershell.parent / "Modules")},
    )
    if result.returncode != 0:
        raise ProtectedConfigurationError()


def _unprotect(ciphertext: bytes) -> str:
    # 无 -Key 的 ConvertFrom-SecureString 使用 CurrentUser DPAPI，外层是
    # 十六进制，原内容为 UTF-16LE。不能把 AES -Key 格式当作这个格式。
    if not ciphertext or len(ciphertext) > _MAXIMUM_BYTES:
        raise ProtectedConfigurationError()
    encoded = ciphertext.decode("ascii").strip()
    if not re.fullmatch(r"(?:[0-9a-fA-F]{2})+", encoded):
        raise ProtectedConfigurationError()
    encrypted = bytes.fromhex(encoded)
    source = (wintypes.BYTE * len(encrypted)).from_buffer_copy(encrypted)
    inputBlob = _DataBlob(len(encrypted), source)
    outputBlob = _DataBlob()
    crypt = _systemLibrary("crypt32.dll")
    kernel = _systemLibrary("kernel32.dll")
    unprotect = crypt.CryptUnprotectData
    unprotect.argtypes = [
        ctypes.POINTER(_DataBlob),
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(_DataBlob),
    ]
    unprotect.restype = wintypes.BOOL
    localFree = kernel.LocalFree
    localFree.argtypes = [ctypes.c_void_p]
    localFree.restype = ctypes.c_void_p
    try:
        # UI_FORBIDDEN：后台服务不得弹出凭据窗口或请求交互。
        if not unprotect(
            ctypes.byref(inputBlob), None, None, None, None, 1, ctypes.byref(outputBlob)
        ):
            raise ProtectedConfigurationError()
        if not outputBlob.pbData or not 0 < outputBlob.cbData <= _MAXIMUM_BYTES:
            raise ProtectedConfigurationError()
        return ctypes.string_at(outputBlob.pbData, outputBlob.cbData).decode("utf-16-le")
    finally:
        if outputBlob.pbData:
            # 释放前清除 Windows 分配的明文。Python/SDK 中的不可变字符串
            # 无法保证物理擦除，不能据此宣称全进程内存已经清零。
            ctypes.memset(outputBlob.pbData, 0, outputBlob.cbData)
            localFree(ctypes.cast(outputBlob.pbData, ctypes.c_void_p))


def _uniqueObject(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for name, value in pairs:
        if name in result:
            raise ProtectedConfigurationError()
        result[name] = value
    return result


def parseProtectedObject(payload: str) -> dict[str, object]:
    try:
        value: object = json.loads(payload, object_pairs_hook=_uniqueObject)
        if not isinstance(value, dict):
            raise ProtectedConfigurationError()
        return cast(dict[str, object], value)
    except Exception:
        raise ProtectedConfigurationError() from None


def loadProtectedPayload(path: str | Path, *, kind: ProtectionKind) -> str:
    """只在持有现有 DPAPI 文件的 Windows 用户下加载；失败不给出文件内容。"""
    try:
        if os.name != "nt" or kind not in _VALIDATORS:
            raise ProtectedConfigurationError()
        candidate = _configurationPath(path)
        with _lockedFile(candidate) as stream:
            _verifyProtectedFile(candidate, kind)
            # 复核路径，避免检查期间目录被替换为重解析点。
            if _configurationPath(candidate) != candidate:
                raise ProtectedConfigurationError()
            ciphertext = stream.read(_MAXIMUM_BYTES + 1)
            return _unprotect(ciphertext)
    except Exception:
        # 异常链也可能含第三方数据或 JSON 明文；不让其进入 API/日志。
        raise ProtectedConfigurationError() from None
