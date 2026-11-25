"""Load the server-only Brocade SANnav credential from the DPAPI record.

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
HELPER_SCRIPT_ENV = "BROCADE_CREDENTIAL_SCRIPT"
DEFAULT_HELPER_SCRIPT = HERE / "scripts" / "Get-BrocadeGatewayCredential.ps1"
ERROR_TEXT = "The protected Brocade credential could not be loaded."

CREDENTIALS: dict[str, Any] = {}


def load_gateway_credentials() -> dict[str, Any]:
    """Return {'username', 'password', 'server'} from the protected helper."""
    global CREDENTIALS

    helper = Path(os.environ.get(HELPER_SCRIPT_ENV, str(DEFAULT_HELPER_SCRIPT)))
    if not helper.is_file():
        raise RuntimeError(ERROR_TEXT)

    powershell = shutil.which("powershell") or shutil.which("powershell.exe")
    if not powershell:
        raise RuntimeError(ERROR_TEXT)

    # The DPAPI record must be the only source of truth for this process.
    for name in (
        "SANNAV_USER",
        "SANNAV_PASS",
        "SANNAV_HOST",
        "SANNAV_PORT",
        "BROCADE_USERNAME",
        "BROCADE_PASSWORD",
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
    server = data.get("server")
    if (
        not isinstance(username, str)
        or not username.strip()
        or not isinstance(password, str)
        or not password
        or not isinstance(server, dict)
    ):
        raise RuntimeError(ERROR_TEXT)

    host = str(server.get("host", "")).strip()
    try:
        port = int(server.get("port"))
    except (TypeError, ValueError):
        raise RuntimeError(ERROR_TEXT) from None
    if not host or not 1 <= port <= 65535:
        raise RuntimeError(ERROR_TEXT)

    CREDENTIALS = {
        "username": username.strip(),
        "password": password,
        "server": {
            "name": str(server.get("name") or host).strip(),
            "host": host,
            "port": port,
            "url": f"https://{host}:{port}",
        },
    }
    return CREDENTIALS
