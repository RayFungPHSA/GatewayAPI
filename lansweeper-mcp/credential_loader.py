"""Load the server-only Lansweeper credential from the DPAPI record.

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
HELPER_SCRIPT_ENV = "LANSWEEPER_CREDENTIAL_SCRIPT"
DEFAULT_HELPER_SCRIPT = HERE / "scripts" / "Get-LansweeperGatewayCredential.ps1"
MANAGED_NAMES = (
    "LANSWEEPER_URL",
    "LANSWEEPER_USERNAME",
    "LANSWEEPER_PASSWORD",
    "LANSWEEPER_ALLOW_INVALID_CERT",
    "LANSWEEPER_TIMEOUT_MS",
    "LANSWEEPER_ASSET_PATHS",
)
REQUIRED_NAMES = (
    "LANSWEEPER_URL",
    "LANSWEEPER_USERNAME",
    "LANSWEEPER_PASSWORD",
)
PLACEHOLDER_PREFIXES = ("${", "{env:")
ERROR_TEXT = "The protected Lansweeper credential could not be loaded."


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
        if value is None:
            continue
        if not isinstance(value, str) or not value.strip():
            raise RuntimeError(ERROR_TEXT)
        if value.strip().startswith(PLACEHOLDER_PREFIXES):
            raise RuntimeError(ERROR_TEXT)
        values[name] = value.strip()

    for name in REQUIRED_NAMES:
        if not values.get(name):
            raise RuntimeError(ERROR_TEXT)

    for name, value in values.items():
        os.environ[name] = value
