r"""
HTTP bridge for the Cohesity stdio MCP server.

The Cohesity/Helios API key is server-side only. It is loaded into this
process from the DPAPI-protected C:\caddy-gateway\secrets\cohesity-gateway.xml
by a restricted local helper at startup and is never accepted from a client.

Clients authenticate with a per-user gateway token:

    X-Gateway-Token: <token issued to that user>

The bridge maps the token SHA-256 fingerprint to a name and role in
C:\caddy-gateway\secrets\cohesity-gateway-acl.json. Unknown or missing tokens
are denied. `admin` tokens get the full tool set; `read-only` tokens get GET/
read tools only and cannot call mutating tools or api_request with non-GET
methods. Each request starts a short-lived `cohesity_mcp.py` process using the
shared server-side key. Stateless mode is deliberate: after earlier anyio
task-affinity failures, the stdio session lives entirely inside one HTTP
request.

The bridge listens on 127.0.0.1 only; Caddy exposes it through /cohesity/*.
"""

from __future__ import annotations

import contextvars
import hashlib
import json
import os
import sys
import time
from contextlib import AsyncExitStack, asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, AsyncIterator

import uvicorn
from mcp import types
from mcp.client.session import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client
from mcp.server.lowlevel.server import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.responses import JSONResponse
from starlette.routing import Route

from credential_loader import load_gateway_credentials

HERE = Path(__file__).resolve().parent
UPSTREAM_SCRIPT = HERE / "cohesity_mcp.py"
SECRETS_DIR = HERE.parent / "secrets"
DEFAULT_ACL_PATH = SECRETS_DIR / "cohesity-gateway-acl.json"
ACL_PATH = Path(os.environ.get("COHESITY_GATEWAY_ACL", str(DEFAULT_ACL_PATH)))

load_gateway_credentials()

SHARED_API_KEY = os.environ.get("COHESITY_API_KEY", "").strip()
if not SHARED_API_KEY or SHARED_API_KEY.startswith(("${", "{env:")):
    raise RuntimeError(
        "The protected Cohesity credential could not be loaded. "
        "Run Set-CohesityGatewayCredential.ps1 and Start-CohesityMcpBridge.ps1."
    )

API_KEY_VAR: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "cohesity_api_key", default=None
)
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
    os.environ.get("COHESITY_USAGE_LOG", str(HERE / "usage.jsonl"))
)

_acl_cache: tuple[int, dict[str, tuple[str, str]]] | None = None

ADMIN_ROLE = "admin"
READ_ONLY_ROLE = "read-only"

# Tools hidden from and denied to read-only users. These either mutate Cohesity
# or persist a local usage snapshot.
ADMIN_ONLY_TOOLS = {
    "run_backup",
    "collect_protection_group_usage",
}

# Explicit allowlist for read-only users. If a new tool is added upstream it is
# admin-only until added here. All of these are GET/read operations.
READ_ONLY_TOOLS = {
    "list_clusters",
    "get_cluster_info",
    "list_protection_groups",
    "get_protection_group",
    "list_protection_group_runs",
    "list_policies",
    "list_alerts",
    "get_protection_summary",
    "list_protected_objects",
    "search_objects",
    "list_recoveries",
    "list_audit_logs",
    "list_sources",
    "list_tenants",
    "get_encryption_summary",
    "api_request",  # GET only, no body, enforced below
    "list_esx_clusters",
    "get_cluster_nodes",
    "get_cluster_upgrade_info",
    "list_source_registrations",
    "get_cluster_config",
    "get_protection_group_usage",
    "compare_protection_group_usage",
    "list_protection_group_usage_dates",
    "get_data_protect_usage",
    "get_alert_summary",
    "get_alert_types",
    "get_cluster_storage_stats",
    "get_protection_group_run",
    "get_protection_run_stats",
    "get_object_snapshots",
    "get_object_runs",
    "list_storage_domains",
    "list_file_views",
    "list_external_targets",
    "list_users",
    "list_roles",
}


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def token_fingerprint(token: str) -> str:
    return sha256_hex(token)


def short_fingerprint(fingerprint: str | None) -> str | None:
    return fingerprint[:12] if fingerprint else None


def key_fingerprint(api_key: str) -> str:
    """Stable, non-reversible identifier for the shared server-side key."""
    return short_fingerprint(sha256_hex(api_key)) or "none"


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
                role = READ_ONLY_ROLE  # fail closed on unknown roles
            if name and len(fingerprint) >= 12:
                mapping[fingerprint] = (name, role)
    except Exception as exc:
        print(f"Cannot read gateway ACL {ACL_PATH}: {safe_error(exc)}", file=sys.stderr)

    _acl_cache = (mtime, mapping)
    return mapping


def write_usage(event: str, **fields: Any) -> None:
    api_key = API_KEY_VAR.get()
    token_fp = TOKEN_FP_VAR.get()
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "user": USER_VAR.get() or "unauthenticated",
        "role": ROLE_VAR.get() or "none",
        "key_fp": key_fingerprint(api_key) if api_key else "none",
        "token_fp": short_fingerprint(token_fp),
        "client_ip": CLIENT_IP_VAR.get(),
        **fields,
    }
    USAGE_LOG.parent.mkdir(parents=True, exist_ok=True)
    with USAGE_LOG.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, separators=(",", ":")) + "\n")


def safe_error(error: Exception, api_key: str | None = None) -> str:
    text = str(error)
    if api_key:
        text = text.replace(api_key, "[REDACTED]")
    return text[:300]


def _decode(value: bytes | str) -> str:
    return value.decode("latin-1") if isinstance(value, bytes) else value


def extract_gateway_token(headers: dict[bytes, bytes]) -> str | None:
    value = headers.get(b"x-gateway-token")
    if not value:
        return None
    token = _decode(value).strip()
    return token or None


def extract_client_api_key(headers: dict[bytes, bytes]) -> str | None:
    """Detect legacy client-supplied keys so they can be rejected, not logged."""
    for name in (b"x-cohesity-api-key", b"x-helios-api-key"):
        value = headers.get(name)
        if value and _decode(value).strip():
            return _decode(value).strip()

    auth = headers.get(b"authorization")
    if auth:
        parts = _decode(auth).strip().split(None, 1)
        if len(parts) == 2 and parts[0].lower() in {"bearer", "apikey", "token"}:
            return parts[1].strip()
    return None


class RequireGatewayTokenMiddleware:
    """Authenticate the caller with a gateway token, never with a Cohesity key."""

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
        api_token = API_KEY_VAR.set(None)
        user_token = USER_VAR.set(None)
        role_token = ROLE_VAR.set(None)

        async def deny(status: int, message: str, event: str, reason: str) -> None:
            write_usage(event, reason=reason, http_status=status)
            response = JSONResponse({"error": message}, status_code=status)
            await response(scope, receive, send)

        try:
            if extract_client_api_key(headers):
                await deny(
                    400,
                    "Client-supplied Cohesity API keys are not accepted. "
                    "Use X-Gateway-Token; the Cohesity key is configured on the server.",
                    "auth_rejected",
                    "legacy_api_key_header",
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

            if token.startswith(("${", "{env:")):
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
                    "This gateway token is not authorized for Cohesity MCP.",
                    "auth_denied",
                    "unknown_token",
                )
                return

            user, role = acl_entry
            auth_user_token = USER_VAR.set(user)
            auth_role_token = ROLE_VAR.set(role)
            auth_api_token = API_KEY_VAR.set(SHARED_API_KEY)
            try:
                await self.app(scope, receive, send)
            finally:
                API_KEY_VAR.reset(auth_api_token)
                ROLE_VAR.reset(auth_role_token)
                USER_VAR.reset(auth_user_token)
        finally:
            ROLE_VAR.reset(role_token)
            USER_VAR.reset(user_token)
            API_KEY_VAR.reset(api_token)
            TOKEN_FP_VAR.reset(fp_token)
            CLIENT_IP_VAR.reset(ip_token)


@asynccontextmanager
async def upstream_session(api_key: str) -> AsyncIterator[ClientSession]:
    env = os.environ.copy()
    env["COHESITY_API_KEY"] = api_key
    env.pop("HELIOS_API_KEY", None)
    env["COHESITY_NO_DOTENV"] = "true"
    # The shared usage cache is queried by tools; don't let every request run
    # its own daily collector.
    env["COHESITY_USAGE_AUTO_COLLECT"] = "false"

    params = StdioServerParameters(
        command=sys.executable,
        args=[str(UPSTREAM_SCRIPT)],
        cwd=str(HERE),
        env=env,
    )
    async with AsyncExitStack() as stack:
        read_stream, write_stream = await stack.enter_async_context(
            stdio_client(params, errlog=sys.stderr)
        )
        session = await stack.enter_async_context(
            ClientSession(read_stream, write_stream)
        )
        await session.initialize()
        yield session


def require_key() -> str:
    key = API_KEY_VAR.get()
    if not key:
        raise RuntimeError("The shared server-side Cohesity key is not available")
    return key


def role_is_admin() -> bool:
    return ROLE_VAR.get() == ADMIN_ROLE


def clone_tool(tool: types.Tool, **updates: Any) -> types.Tool:
    if hasattr(tool, "model_copy"):
        return tool.model_copy(deep=True, update=updates)
    copied = tool.copy(deep=True)
    return copied.copy(update=updates)


def as_read_only_tool(tool: types.Tool) -> types.Tool:
    """Advertise MCP read-only annotations for tools in the read-only allowlist."""
    annotations = getattr(tool, "annotations", None)
    annotation_data: dict[str, Any] = {}
    if annotations is not None and hasattr(annotations, "model_dump"):
        annotation_data = annotations.model_dump()
    annotation_data.update(
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    )
    description = str(getattr(tool, "description", "") or "").strip()
    return clone_tool(
        tool,
        annotations=types.ToolAnnotations(**annotation_data),
        description=(description + " (Gateway-enforced read-only tool.)").strip(),
    )


def read_only_api_schema(schema: Any) -> dict[str, Any]:
    """Constrain api_request to GET in the advertised tool schema."""
    result = json.loads(json.dumps(schema or {}))
    properties = result.setdefault("properties", {})
    method = properties.setdefault("method", {})
    method["enum"] = ["GET"]
    method["description"] = "Read-only users may use GET only."
    properties.pop("body", None)
    required = result.get("required", [])
    result["required"] = [item for item in required if item != "body"]
    return result


def forbidden_call_reason(name: str, arguments: dict[str, Any]) -> str | None:
    if role_is_admin():
        return None
    if name in ADMIN_ONLY_TOOLS:
        return "This tool is admin-only and is not available to your account."
    if name not in READ_ONLY_TOOLS:
        return "This tool is not available to read-only users."
    if name == "api_request":
        method = str(arguments.get("method", "") or "").strip().upper()
        if method != "GET":
            return "Read-only users may use api_request with GET only."
        if arguments.get("body") not in (None, {}, ""):
            return "Read-only users cannot send a request body with api_request."
    return None


def denied_tool_result(message: str) -> types.CallToolResult:
    return types.CallToolResult(
        content=[types.TextContent(type="text", text=message)],
        isError=True,
    )


mcp_server = Server("cohesity-http-bridge", version="2.1.0")


@mcp_server.list_tools()
async def list_tools() -> types.ListToolsResult:
    api_key = require_key()
    started = time.monotonic()
    try:
        async with upstream_session(api_key) as session:
            result = await session.list_tools()
            tools = list(result.tools)

        if not role_is_admin():
            visible = []
            for tool in tools:
                if tool.name not in READ_ONLY_TOOLS:
                    continue
                if tool.name == "api_request":
                    tool = clone_tool(
                        tool,
                        description=(
                            "Make a read-only GET request to any Helios endpoint. "
                            "Mutating methods are blocked for this account."
                        ),
                        inputSchema=read_only_api_schema(tool.inputSchema),
                    )
                tool = as_read_only_tool(tool)
                visible.append(tool)
            tools = visible

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
            error=safe_error(exc, api_key),
            duration_ms=round((time.monotonic() - started) * 1000, 1),
        )
        raise


@mcp_server.call_tool(validate_input=False)
async def call_tool(name: str, arguments: dict[str, Any]) -> types.CallToolResult:
    args = arguments or {}
    reason = forbidden_call_reason(name, args)
    if reason:
        write_usage(
            "tool_denied",
            ok=False,
            tool=name,
            reason=reason,
        )
        return denied_tool_result(reason)

    api_key = require_key()
    started = time.monotonic()
    try:
        async with upstream_session(api_key) as session:
            result = await session.call_tool(name, args)
        write_usage(
            "tools/call",
            ok=not bool(result.isError),
            tool=name,
            duration_ms=round((time.monotonic() - started) * 1000, 1),
        )
        return result
    except Exception as exc:
        write_usage(
            "tools/call",
            ok=False,
            tool=name,
            error=safe_error(exc, api_key),
            duration_ms=round((time.monotonic() - started) * 1000, 1),
        )
        raise


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
            "upstream": str(UPSTREAM_SCRIPT),
            "mode": "stateless",
            "auth": "gateway_token",
            "credential_store": "dpapi",
            "acl_users": len(load_acl()),
        }
    )


@asynccontextmanager
async def lifespan(_app: Starlette):
    async with session_manager.run():
        yield


app = Starlette(
    routes=[
        Route("/health", health, methods=["GET"]),
        Route("/mcp", McpAsgiApp(session_manager), methods=["GET", "POST", "DELETE"]),
    ],
    lifespan=lifespan,
    middleware=[Middleware(RequireGatewayTokenMiddleware)],
)


if __name__ == "__main__":
    host = os.environ.get("COHESITY_BRIDGE_HOST", "127.0.0.1")
    port = int(os.environ.get("COHESITY_BRIDGE_PORT", "8400"))
    uvicorn.run(app, host=host, port=port, log_level="info")
