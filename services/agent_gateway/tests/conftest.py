from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest


def _syntheticProtectedFiles(factory: pytest.TempPathFactory, script: str, folder: str) -> Path:
    if os.name != "nt":
        pytest.skip("Windows CurrentUser DPAPI integration")
    target = factory.mktemp(folder) / "synthetic"
    scriptPath = Path(__file__).resolve().parents[1] / "scripts" / script
    powershell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    result = subprocess.run(  # noqa: S603 — 固定系统程序和合成脚本，无明文参数。
        [
            str(powershell),
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(scriptPath),
            "-TestDirectory",
            str(target),
        ],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=30,
        creationflags=subprocess.CREATE_NO_WINDOW,
        env={**os.environ, "PSModulePath": str(powershell.parent / "Modules")},
    )
    assert result.returncode == 0
    return target


@pytest.fixture(scope="session")
def encryptedFiles(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return _syntheticProtectedFiles(
        tmp_path_factory, "test_pnvs_credentials.ps1", "pnvs-credentials"
    )


@pytest.fixture(scope="session")
def pnvsRuntimeFiles(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return _syntheticProtectedFiles(tmp_path_factory, "test_pnvs_runtime.ps1", "pnvs-runtime")


@pytest.fixture(scope="session")
def cloudRuntimeFiles(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return _syntheticProtectedFiles(tmp_path_factory, "test_cloud_runtime.ps1", "cloud-runtime")
