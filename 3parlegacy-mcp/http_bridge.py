r"""
HTTP bridge for the 3PARLegacy read-only MCP server.

The 3PAR credential is server-side only. It is loaded into this process from
the DPAPI-protected C:\caddy-gateway\secrets\3parlegacy.xml by a restricted
local helper at startup and is never accepted from a client.

Clients authenticate with the same per-user gateway token used by the other
MCP servers:

    X-Gateway-Token: <token issued to that user>

The bridge maps the token SHA-256 fingerprint to a name and role in the shared
named-user ACL (C:\caddy-gateway\secrets\cohesity-gateway-acl.json). Unknown or
missing tokens are denied. Every tool is a read-only WSAPI GET fanned out
across all configured arrays by default.

The bridge listens on 127.0.0.1 only; Caddy exposes it through /3parlegacy/*.
"""

from __future__ import annotations

import asyncio
import contextvars
import hashlib
import json
import os
import re
import sys
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, AsyncIterator

import uvicorn
from mcp import types
from mcp.server.lowlevel.server import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.responses import JSONResponse
from starlette.routing import Route

import credential_loader
from threepar_client import READ_ONLY_PATHS, ThreeparClient

HERE = Path(__file__).resolve().parent
SECRETS_DIR = HERE.parent / "secrets"
DEFAULT_ACL_PATH = SECRETS_DIR / "cohesity-gateway-acl.json"
ACL_PATH = Path(os.environ.get("THREEPARLEGACY_GATEWAY_ACL", str(DEFAULT_ACL_PATH)))

credential_loader.load_gateway_credentials()
CREDENTIALS = credential_loader.CREDENTIALS

PASSWORD = CREDENTIALS["password"]
SERVERS = CREDENTIALS["servers"]
CREDENTIAL_FP = hashlib.sha256(PASSWORD.encode("utf-8")).hexdigest()[:12]

USER_VAR: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "gateway_user", default=None
)
ROLE_VAR: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "gateway_role", default=None
)
TOKEN_FP_VAR: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "gateway_token_fingerprint", default=None
)
CLIENT_IP_VAR: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "client_ip", default=None
)

USAGE_LOG = Path(
    os.environ.get("THREEPARLEGACY_USAGE_LOG", str(HERE / "usage.jsonl"))
)

_acl_cache: tuple[int, dict[str, tuple[str, str]]] | None = None

ADMIN_ROLE = "admin"
READ_ONLY_ROLE = "read-only"

# All tools are read-only. There are no admin-only 3PAR tools today. A future
# mutating tool stays hidden and denied until explicitly added to an allowlist.
ADMIN_ONLY_TOOLS: set[str] = set()

READ_ONLY_TOOLS = {
    "threepar_connection_status",
    "threepar_inventory_summary",
    *READ_ONLY_PATHS.keys(),
}

PLACEHOLDER_PREFIXES = ("${", "{env:")


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def token_fingerprint(token: str) -> str:
    return sha256_hex(token)


def short_fingerprint(fingerprint: str | None) -> str | None:
    return fingerprint[:12] if fingerprint else None


def load_acl() -> dict[str, tuple[str, str]]:
    """Return {token_sha256: (user name, role)}, reloading when the file changes."""
    global _acl_cache
    try:
        stat = ACL_PATH.stat()
    except FileNotFoundError:
        return {}

    mtime = stat.st_mtime_ns
    if _acl_cache is not None and _acl_cache[0] == mtime:
        return _acl_cache[1]

    mapping: dict[str, tuple[str, str]] = {}
    try:
        data = json.loads(ACL_PATH.read_text(encoding="utf-8-sig"))
        for entry in data.get("users", []):
            name = str(entry.get("name", "")).strip()
            fingerprint = str(entry.get("token_fp", "")).strip().lower()
            role = str(entry.get("role", READ_ONLY_ROLE)).strip().lower()
            if role not in {ADMIN_ROLE, READ_ONLY_ROLE}:
                role = READ_ONLY_ROLE
            if name and len(fingerprint) >= 12:
                mapping[fingerprint] = (name, role)
    except Exception as exc:
        print(f"Cannot read gateway ACL {ACL_PATH}: {safe_error(exc)}", file=sys.stderr)

    _acl_cache = (mtime, mapping)
    return mapping


def write_usage(event: str, **fields: Any) -> None:
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "server": "3parlegacy",
        "event": event,
        "user": USER_VAR.get() or "unauthenticated",
        "role": ROLE_VAR.get() or "none",
        "key_fp": CREDENTIAL_FP,
        "token_fp": short_fingerprint(TOKEN_FP_VAR.get()),
        "client_ip": CLIENT_IP_VAR.get(),
        **fields,
    }
    USAGE_LOG.parent.mkdir(parents=True, exist_ok=True)
    with USAGE_LOG.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, separators=(",", ":")) + "\n")


def safe_error(error: Exception) -> str:
    text = str(error).replace(PASSWORD, "[REDACTED]")
    text = re.sub(r'("?key"?\s*:\s*")[^"]+', r"\1[REDACTED]", text, flags=re.IGNORECASE)
    text = re.sub(r"Bearer\s+\S+", "Bearer [REDACTED]", text, flags=re.IGNORECASE)
    return text[:300]


def _decode(value: bytes | str) -> str:
    return value.decode("latin-1") if isinstance(value, bytes) else value


def extract_gateway_token(headers: dict[bytes, bytes]) -> str | None:
    value = headers.get(b"x-gateway-token")
    if not value:
        return None
    token = _decode(value).strip()
    return token or None


def extract_client_credential(headers: dict[bytes, bytes]) -> str | None:
    """Detect client-supplied array credentials so they can be rejected."""
    for name in (
        b"x-3par-password",
        b"x-3par-username",
        b"x-hp3par-password",
        b"x-hp3par-username",
        b"x-hp3par-wsapi-sessionkey",
        b"x-sessionkey",
        b"x-cohesity-api-key",
        b"x-helios-api-key",
        b"x-api-key",
    ):
        value = headers.get(name)
        if value and _decode(value).strip():
            return _decode(name)
    auth = headers.get(b"authorization")
    if auth:
        parts = _decode(auth).strip().split(None, 1)
        if len(parts) == 2 and parts[0].lower() in {"basic", "bearer", "apikey", "token"}:
            return "authorization: " + parts[0].lower()
    return None


class RequireGatewayTokenMiddleware:
    """Authenticate the caller with the shared gateway token, never with 3PAR keys."""

    def __init__(self, app: Any):
        self.app = app

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope.get("type") != "http" or scope.get("path") == "/health":
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers", []))
        token = extract_gateway_token(headers)
        fingerprint = token_fingerprint(token) if token else None
        client = scope.get("client")
        client_ip = client[0] if client else None

        ip_token = CLIENT_IP_VAR.set(client_ip)
        fp_token = TOKEN_FP_VAR.set(fingerprint)
        user_token = USER_VAR.set(None)
        role_token = ROLE_VAR.set(None)

        async def deny(status: int, message: str, event: str, reason: str) -> None:
            write_usage(event, reason=reason, http_status=status)
            response = JSONResponse({"error": message}, status_code=status)
            await response(scope, receive, send)

        try:
            supplied = extract_client_credential(headers)
            if supplied:
                await deny(
                    400,
                    "Client-supplied 3PAR credentials are not accepted. "
                    "Use X-Gateway-Token; the 3PAR credential is configured on the server.",
                    "auth_rejected",
                    f"client_credential:{supplied}",
                )
                return

            if not token:
                await deny(
                    401,
                    "A gateway token is required. Send X-Gateway-Token: <token>.",
                    "auth_denied",
                    "missing_token",
                )
                return

            if token.startswith(PLACEHOLDER_PREFIXES):
                await deny(
                    401,
                    "The X-Gateway-Token header contains an unexpanded placeholder. "
                    "Use {env:COHESITY_GATEWAY_TOKEN} in OpenCode, or set the token "
                    "in the client environment and restart the client.",
                    "auth_denied",
                    "placeholder_token",
                )
                return

            acl_entry = load_acl().get(fingerprint or "")
            if not acl_entry:
                await deny(
                    403,
                    "This gateway token is not authorized for 3PARLegacy MCP.",
                    "auth_denied",
                    "unknown_token",
                )
                return

            user, role = acl_entry
            auth_user_token = USER_VAR.set(user)
            auth_role_token = ROLE_VAR.set(role)
            try:
                await self.app(scope, receive, send)
            finally:
                USER_VAR.reset(auth_user_token)
                ROLE_VAR.reset(auth_role_token)
        finally:
            ROLE_VAR.reset(role_token)
            USER_VAR.reset(user_token)
            TOKEN_FP_VAR.reset(fp_token)
            CLIENT_IP_VAR.reset(ip_token)


def role_is_admin() -> bool:
    return ROLE_VAR.get() == ADMIN_ROLE


def forbidden_call_reason(name: str, arguments: dict[str, Any]) -> str | None:
    if role_is_admin():
        return None
    if name in ADMIN_ONLY_TOOLS:
        return "This tool is admin-only and is not available to your account."
    if name not in READ_ONLY_TOOLS:
        return "This tool is not available to read-only users."
    return None


def denied_tool_result(message: str) -> types.CallToolResult:
    return types.CallToolResult(
        content=[types.TextContent(type="text", text=message)],
        isError=True,
    )


def build_tools() -> list[types.Tool]:
    annotations = types.ToolAnnotations(
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    )
    array_property = {
        "type": "string",
        "description": (
            "Optional array name: "
            + ", ".join(server["name"] for server in SERVERS)
            + ". Default: all configured arrays."
        ),
    }
    definitions = [
        (
            "threepar_connection_status",
            "Check WSAPI connectivity and system version on all 3PAR arrays by default.",
        ),
        (
            "threepar_inventory_summary",
            "Return per-array counts of CPGs, volumes, volume sets, hosts, host sets, and ports.",
        ),
        ("threepar_list_cpgs", "List common provisioning groups from all 3PAR arrays."),
        ("threepar_list_volumes", "List storage volumes from all 3PAR arrays."),
        ("threepar_list_volume_sets", "List volume sets from all 3PAR arrays."),
        ("threepar_list_hosts", "List hosts and their FC/iSCSI paths from all 3PAR arrays."),
        ("threepar_list_host_sets", "List host sets from all 3PAR arrays."),
        ("threepar_list_ports", "List array ports and link state from all 3PAR arrays."),
        ("threepar_list_users", "List WSAPI users and privileges from all 3PAR arrays."),
        ("threepar_capacity_summary", "Return system capacity totals from all 3PAR arrays."),
    ]
    return [
        types.Tool(
            name=name,
            description=description
            + " Every result carries its owning array; unreachable arrays are reported in failures.",
            inputSchema={
                "type": "object",
                "properties": {"array": array_property},
                "additionalProperties": False,
            },
            annotations=annotations,
        )
        for name, description in definitions
    ]


TOOLS = build_tools()
TOOLS_BY_NAME = {tool.name: tool for tool in TOOLS}

_client = ThreeparClient(CREDENTIALS)


def run_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    array = arguments.get("array")
    if name == "threepar_connection_status":
        return _client.connection_status(array)
    if name == "threepar_inventory_summary":
        return _client.inventory_summary(array)
    if name in READ_ONLY_PATHS:
        return _client.across_arrays(READ_ONLY_PATHS[name], array)
    raise ValueError(f"Unknown 3PARLegacy tool: {name}")


mcp_server = Server("3parlegacy-http-bridge", version="1.0.0")


@mcp_server.list_tools()
async def list_tools() -> types.ListToolsResult:
    started = time.monotonic()
    try:
        tools = list(TOOLS)
        if not role_is_admin():
            tools = [tool for tool in tools if tool.name in READ_ONLY_TOOLS]
        write_usage(
            "tools/list",
            ok=True,
            tool_count=len(tools),
            duration_ms=round((time.monotonic() - started) * 1000, 1),
        )
        return types.ListToolsResult(tools=tools)
    except Exception as exc:
        write_usage(
            "tools/list",
            ok=False,
            error=safe_error(exc),
            duration_ms=round((time.monotonic() - started) * 1000, 1),
        )
        raise


@mcp_server.call_tool(validate_input=False)
async def call_tool(name: str, arguments: dict[str, Any]) -> types.CallToolResult:
    args = arguments or {}
    reason = forbidden_call_reason(name, args)
    if reason:
        write_usage("tool_denied", ok=False, tool=name, reason=reason)
        return denied_tool_result(reason)

    started = time.monotonic()
    try:
        payload = await asyncio.to_thread(run_tool, name, args)
        result = types.CallToolResult(
            content=[
                types.TextContent(
                    type="text",
                    text=json.dumps(payload, indent=2, default=str),
                )
            ],
            structuredContent=payload,
        )
        write_usage(
            "tools/call",
            ok=not bool(result.isError),
            tool=name,
            duration_ms=round((time.monotonic() - started) * 1000, 1),
        )
        return result
    except Exception as exc:
        message = safe_error(exc)
        write_usage(
            "tools/call",
            ok=False,
            tool=name,
            error=message,
            duration_ms=round((time.monotonic() - started) * 1000, 1),
        )
        return denied_tool_result(message)


session_manager = StreamableHTTPSessionManager(
    app=mcp_server,
    json_response=True,
    stateless=True,
)


class McpAsgiApp:
    def __init__(self, manager: StreamableHTTPSessionManager):
        self.manager = manager

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        await self.manager.handle_request(scope, receive, send)


async def health(_request: Any) -> JSONResponse:
    return JSONResponse(
        {
            "ok": True,
            "server": "3parlegacy",
            "mode": "stateless",
            "auth": "gateway_token",
            "credential_store": "dpapi",
            "arrays": [server["name"] for server in SERVERS],
            "tool_count": len(READ_ONLY_TOOLS),
            "acl_users": len(load_acl()),
            "acl_file": str(ACL_PATH),
        }
    )


@asynccontextmanager
async def lifespan(_app: Starlette):
    async with session_manager.run():
        yield
    _client.close()


app = Starlette(
    routes=[
        Route("/health", health, methods=["GET"]),
        Route("/mcp", McpAsgiApp(session_manager), methods=["GET", "POST", "DELETE"]),
    ],
    lifespan=lifespan,
    middleware=[Middleware(RequireGatewayTokenMiddleware)],
)


if __name__ == "__main__":
    host = os.environ.get("THREEPARLEGACY_BRIDGE_HOST", "127.0.0.1")
    port = int(os.environ.get("THREEPARLEGACY_BRIDGE_PORT", "8404"))
    uvicorn.run(app, host=host, port=port, log_level="info")
