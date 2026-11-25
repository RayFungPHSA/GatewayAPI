"""Load the server-only XP Performance Advisor credential from the DPAPI record.

The Python bridge calls the restricted PowerShell helper once at startup. The
helper emits one JSON object on stdout; on failure, stdout/stderr are discarded
so no protected value can leak into MCP responses or logs.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
HELPER_SCRIPT_ENV = "HPEXP8_CREDENTIAL_SCRIPT"
DEFAULT_HELPER_SCRIPT = HERE / "scripts" / "Get-HPEXP8GatewayCredential.ps1"
ERROR_TEXT = "The protected HPEXP8 credential could not be loaded."

CREDENTIALS: dict[str, Any] = {}


def load_gateway_credentials() -> dict[str, Any]:
    """Return {'username', 'password', 'servers'} from the protected helper."""
    global CREDENTIALS

    helper = Path(os.environ.get(HELPER_SCRIPT_ENV, str(DEFAULT_HELPER_SCRIPT)))
    if not helper.is_file():
        raise RuntimeError(ERROR_TEXT)

    powershell = shutil.which("powershell") or shutil.which("powershell.exe")
    if not powershell:
        raise RuntimeError(ERROR_TEXT)

    # The DPAPI record must be the only source of truth for this process.
    for name in (
        "XPPA_USERNAME",
        "XPPA_PASSWORD",
        "XPPA_SERVER",
        "XPPA_SERVERS",
        "HPEXP8_USERNAME",
        "HPEXP8_PASSWORD",
        "HPEXP8_SERVER",
        "USERNAME",
        "PASSWORD",
    ):
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

    username = data.get("username")
    password = data.get("password")
    servers = data.get("servers")
    if (
        not isinstance(username, str)
        or not username.strip()
        or not isinstance(password, str)
        or not password
        or not isinstance(servers, list)
        or not servers
    ):
        raise RuntimeError(ERROR_TEXT)

    for server in servers:
        if not isinstance(server, dict):
            raise RuntimeError(ERROR_TEXT)
        name = server.get("name")
        url = server.get("url")
        if (
            not isinstance(name, str)
            or not name.strip()
            or not isinstance(url, str)
            or not url.startswith("http://")
        ):
            raise RuntimeError(ERROR_TEXT)

    CREDENTIALS = {
        "username": username.strip(),
        "password": password,
        "servers": [
            {"name": str(s["name"]).strip(), "url": str(s["url"]).rstrip("/")}
            for s in servers
        ],
    }
    return CREDENTIALS
