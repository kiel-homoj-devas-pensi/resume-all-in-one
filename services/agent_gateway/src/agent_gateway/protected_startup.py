"""Windows-only protected startup; check mode never constructs network services."""

from __future__ import annotations

import argparse
import logging
import os
import re
import sys
from collections.abc import Sequence
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from typing import Never

import uvicorn

from .app import createApplication
from .identity import requireUtc
from .mysql_storage import MySqlConfig
from .network_audit import AuditAvailabilityBoundary, NetworkAuditHandler, NetworkAuditStore
from .open_test import loadOpenTestPolicy
from .pnvs_credentials import loadPnvsCredentials
from .pnvs_runtime import loadPnvsRuntimeSettings
from .remote_result_cache import verifyWindowsResultDirectory
from .settings import GatewaySettings
from .volunteer_trial import loadVolunteerTrialPolicy
from .windows_protected_configuration import loadProtectedPayload, parseProtectedObject

_FIELDS = {
    "schemaVersion",
    "glmApiKey",
    "businessDatabaseDsn",
    "databaseTlsCaFile",
    "pnvsCredentialsPath",
    "pnvsRuntimePath",
}
_LEGACY_FIELDS = _FIELDS | {"databaseExpiresAtUtc"}
_REPOSITORY_ROOT = Path(__file__).resolve().parents[4]


class ProtectedStartupError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("protected_startup_configuration_unavailable")


def _guestSettings(settings: GatewaySettings, dataRoot: Path) -> GatewaySettings:
    # Nonsecret bounded trial policy: the existing DPAPI bundle, credentials and
    # maintenance identities remain unchanged. Absence keeps anonymous AI closed.
    directory = dataRoot / "guest-ai"
    policyPath = directory / "policy.json"
    if not policyPath.exists():
        return settings
    verifyWindowsResultDirectory(directory)
    policyPath = _localFile(str(policyPath))
    if policyPath.stat().st_size > 4096:
        raise ProtectedStartupError()
    policy = parseProtectedObject(policyPath.read_text(encoding="utf-8-sig"))
    if (
        set(policy) != {"schemaVersion", "enabled", "maximumMonthlyCalls", "enabledUntilUtc"}
        or type(policy["schemaVersion"]) is not int
        or policy["schemaVersion"] != 1
        or type(policy["enabled"]) is not bool
        or type(policy["maximumMonthlyCalls"]) is not int
        or not 1 <= policy["maximumMonthlyCalls"] <= 100
        or not isinstance(policy["enabledUntilUtc"], str)
    ):
        raise ProtectedStartupError()
    configured = replace(
        settings,
        guestDatabasePath=directory / "guest-ai.sqlite3",
        guestMonthlyCallLimit=policy["maximumMonthlyCalls"],
        guestEnabledUntilUtc=policy["enabledUntilUtc"],
    )
    return configured if policy["enabled"] else settings


def _localFile(value: str) -> Path:
    if os.name == "nt" and (re.match(r"^[A-Za-z]:[\\/]", value) is None or ":" in value[2:]):
        raise ProtectedStartupError()
    path = Path(os.path.abspath(value))
    if not Path(value).is_absolute() or path.is_relative_to(_REPOSITORY_ROOT):
        raise ProtectedStartupError()
    for ancestor in (path, *path.parents):
        info = ancestor.stat(follow_symlinks=False)
        if ancestor.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
            raise ProtectedStartupError()
    if not path.is_file():
        raise ProtectedStartupError()
    return path


def _settingsFromPayload(payload: str) -> GatewaySettings:
    bundle = parseProtectedObject(payload)
    if (
        type(bundle.get("schemaVersion")) is not int
        or bundle["schemaVersion"] not in {1, 2}
        or set(bundle) != (_LEGACY_FIELDS if bundle["schemaVersion"] == 1 else _FIELDS)
    ):
        raise ProtectedStartupError()
    strings: dict[str, str] = {}
    for name in _FIELDS - {"schemaVersion"}:
        value = bundle[name]
        if (
            not isinstance(value, str)
            or not 1 <= len(value) <= 4096
            or value != value.strip()
            or any(ord(character) < 32 or ord(character) == 127 for character in value)
        ):
            raise ProtectedStartupError()
        strings[name] = value
    key = strings["glmApiKey"]
    if not 16 <= len(key) <= 256 or any(character.isspace() for character in key):
        raise ProtectedStartupError()
    ca = _localFile(strings["databaseTlsCaFile"])
    credentials = _localFile(strings["pnvsCredentialsPath"])
    runtime = _localFile(strings["pnvsRuntimePath"])
    # Read old encrypted bundles without rewriting credentials. Their historical
    # trial date is syntax-checked, but is not a production service expiry.
    if bundle["schemaVersion"] == 1:
        legacyExpiry = bundle["databaseExpiresAtUtc"]
        if not isinstance(legacyExpiry, str):
            raise ProtectedStartupError()
        requireUtc(datetime.fromisoformat(legacyExpiry.replace("Z", "+00:00")))
    # Parse only: fixed DSN and TLS CA; no connection or artificial service expiry.
    MySqlConfig.fromDsn(strings["businessDatabaseDsn"], ca)
    return GatewaySettings(
        databaseBackend="mysql",
        databaseDsn=strings["businessDatabaseDsn"],
        databaseTlsCaFile=ca,
        executionEnvironment="production",
        enableAccountPrivileges=True,
        enableRecoveryCodes=True,
        enableAccountRetention=True,
        enableSmsAttemptRetention=True,
        pnvsCredentialsPath=credentials,
        pnvsRuntimePath=runtime,
        remoteProviderMode="glm",
        glmApiKey=key,
    )


def loadStartupSettings(path: Path) -> GatewaySettings:
    try:
        if any(
            name in os.environ
            for name in ("GATEWAY_DATABASE_MIGRATION_DSN", "GATEWAY_DATABASE_MANAGEMENT_DSN")
        ):
            raise ProtectedStartupError()
        settings = _settingsFromPayload(loadProtectedPayload(path, kind="gatewayStartup"))
        openTestDirectory = path.parent.parent / "open-test"
        if openTestDirectory.exists() or openTestDirectory.is_symlink():
            verifyWindowsResultDirectory(openTestDirectory)
            openTestPath = _localFile(str(openTestDirectory / "policy.json"))
            settings = replace(settings, openTestPolicy=loadOpenTestPolicy(openTestPath))
        # Local format / exact ACL / CurrentUser DPAPI only, never SDK calls.
        if settings.pnvsCredentialsPath is None or settings.pnvsRuntimePath is None:
            raise ProtectedStartupError()
        runtimePath = settings.pnvsRuntimePath
        loadPnvsCredentials(settings.pnvsCredentialsPath)
        trialDirectory = path.parent.parent / "volunteer-trial"
        trialPath = trialDirectory / "policy.json"
        if trialDirectory.exists() or trialDirectory.is_symlink():
            verifyWindowsResultDirectory(trialDirectory)
            trialPolicy = loadVolunteerTrialPolicy(trialPath)
            loadPnvsRuntimeSettings(runtimePath, trialPolicy=trialPolicy)
            settings = replace(settings, volunteerTrialPolicyPath=trialPath)
        else:
            loadPnvsRuntimeSettings(runtimePath)
        # Nonsecret sibling of the configured secrets directory; no re-encryption
        # or new credentials are needed. CheckOnly validates ACL without creating a DB.
        resultDirectory = path.parent.parent / "ai-results"
        verifyWindowsResultDirectory(resultDirectory)
        return _guestSettings(
            replace(settings, remoteResultDirectory=resultDirectory), path.parent.parent
        )
    except Exception:
        raise ProtectedStartupError() from None


class _StartupArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        del message
        # Avoid echoing accidental credentials supplied as unsupported arguments.
        self.exit(2, "protected_startup_arguments_invalid; use encrypted configuration path only\n")


def main(arguments: Sequence[str] | None = None) -> int:
    parser = _StartupArgumentParser(description="Protected Windows Gateway startup")
    parser.add_argument("--configuration", type=Path, required=True)
    parser.add_argument("--check-only", action="store_true")
    options = parser.parse_args(arguments)
    auditHandler: NetworkAuditHandler | None = None
    auditLogger = logging.getLogger("agent_gateway.audit")
    try:
        settings = loadStartupSettings(options.configuration)
        if options.check_only:
            print("protected_startup_local_check_passed; no network or database access")
            return 0
        if settings.remoteResultDirectory is not None:
            auditHandler = NetworkAuditHandler(
                NetworkAuditStore(settings.remoteResultDirectory / "network-audit.sqlite3")
            )
            auditLogger.setLevel(logging.INFO)
            auditLogger.addHandler(auditHandler)
        application = createApplication(settings=settings)
        # A single in-process application: no factory/reload/worker CLI override,
        # no configuration secrets written into environment or process arguments.
        uvicorn.run(
            AuditAvailabilityBoundary(application, auditHandler) if auditHandler else application,
            host="127.0.0.1",
            port=8000,
            workers=1,
            access_log=False,
            log_level="warning",
        )
        return 0
    except Exception:
        # Raw SDK / DB exceptions may contain DSNs or API credentials.
        print(
            "protected_startup_failed; verify identity, configuration and database", file=sys.stderr
        )
        return 1
    finally:
        if auditHandler is not None:
            auditLogger.removeHandler(auditHandler)
            auditHandler.close()


if __name__ == "__main__":
    raise SystemExit(main())
