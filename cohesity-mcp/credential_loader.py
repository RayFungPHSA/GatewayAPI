"""Load the server-only Cohesity credential from the DPAPI-protected record.

The Python bridge calls the restricted PowerShell helper once at startup. The
helper emits one JSON line on stdout; on failure, stdout/stderr are discarded so
no protected value can leak into MCP responses or logs.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
HELPER_SCRIPT_ENV = "COHESITY_CREDENTIAL_SCRIPT"
DEFAULT_HELPER_SCRIPT = HERE / "scripts" / "Get-CohesityGatewayCredential.ps1"
MANAGED_NAMES = ("COHESITY_API_KEY",)
PLACEHOLDER_PREFIXES = ("${", "{env:")
ERROR_TEXT = "The protected Cohesity credential could not be loaded."


def load_gateway_credentials() -> None:
    helper = Path(os.environ.get(HELPER_SCRIPT_ENV, str(DEFAULT_HELPER_SCRIPT)))
    if not helper.is_file():
        raise RuntimeError(ERROR_TEXT)

    powershell = shutil.which("powershell") or shutil.which("powershell.exe")
    if not powershell:
        raise RuntimeError(ERROR_TEXT)

    # The DPAPI record must be the only source of truth for this process.
    for name in MANAGED_NAMES:
        os.environ.pop(name, None)

    try:
        completed = subprocess.run(
            [
                powershell,
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(helper),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
            check=False,
        )
    except Exception:
        raise RuntimeError(ERROR_TEXT) from None

    if completed.returncode != 0:
        raise RuntimeError(ERROR_TEXT)

    try:
        data = json.loads(completed.stdout.strip())
    except Exception:
        raise RuntimeError(ERROR_TEXT) from None

    if not isinstance(data, dict):
        raise RuntimeError(ERROR_TEXT)

    values: dict[str, str] = {}
    for name in MANAGED_NAMES:
        value = data.get(name)
        if not isinstance(value, str) or not value.strip():
            raise RuntimeError(ERROR_TEXT)
        if value.strip().startswith(PLACEHOLDER_PREFIXES):
            raise RuntimeError(ERROR_TEXT)
        values[name] = value.strip()

    for name, value in values.items():
        os.environ[name] = value
