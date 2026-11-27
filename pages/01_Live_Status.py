#!/usr/bin/env python3
"""Live status page for the Caddy gateway and its seven MCP servers.

All probes are token-free. They verify listener health, gateway routes, MCP
health payloads, Windows service/Scheduled Task state, and the usage snapshot.
Authenticated ``tools/list`` checks are intentionally left to Test-McpDiscovery.
"""

from __future__ import annotations

from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from typing import Any, Callable

import duckdb
import httpx
import pandas as pd
import streamlit as st

ROOT = Path(__file__).resolve().parents[1]
GATEWAY_HTTP = os.environ.get("GATEWAY_HTTP_URL", "http://10.53.19.120:8081").rstrip("/")
GATEWAY_HTTPS = os.environ.get("GATEWAY_HTTPS_URL", "https://10.53.19.120:8088").rstrip("/")
DASHBOARD_URL = os.environ.get("GATEWAY_DASHBOARD_URL", "http://127.0.0.1:8501").rstrip("/")
METRICS_URL = os.environ.get("GATEWAY_METRICS_URL", "http://127.0.0.1:9180/metrics")
SNAPSHOT_DB = ROOT / "analytics" / "usage.duckdb"
SERVICE_NAME = "CaddyGateway"
TASK_NAME = "Caddy Gateway Usage Snapshot"
CHECK_TIMEOUT = float(os.environ.get("GATEWAY_STATUS_TIMEOUT", "5"))
REFRESH_SECONDS = 15
BRIDGE_PORTS = {
    "cohesity": 8400,
    "hpegreenlake": 8401,
    "lansweeper": 8402,
    "vsphere": 8403,
    "3parlegacy": 8404,
    "hpexp8": 8405,
    "brocade": 8406,
}

st.set_page_config(page_title="Gateway Live Status", page_icon="🟢", layout="wide")
st.title("Gateway Live Status")
st.caption(
    "Token-free probes of the gateway, seven MCP bridges, scheduled jobs, and "
    "other routes. Never stores or displays gateway tokens."
)


@dataclass
class Check:
    category: str
    name: str
    status: str
    detail: str
    latency_ms: int | None = None


def _short_error(value: Any, limit: int = 160) -> str:
    text = " ".join(str(value).split())
    return text[:limit] + ("..." if len(text) > limit else "")


def _json(response: httpx.Response) -> dict[str, Any] | None:
    try:
        data = response.json()
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _compact(value: Any, limit: int = 140) -> str:
    if isinstance(value, dict):
        safe = {
            key: item
            for key, item in value.items()
            if key.lower() not in {"password", "username", "token", "secret", "api_key"}
        }
        text = ", ".join(f"{key}={_compact(item, 60)}" for key, item in safe.items())
    elif isinstance(value, (list, tuple, set)):
        text = ", ".join(str(item) for item in value)
    else:
        text = str(value)
    text = " ".join(text.split())
    return text[:limit] + ("..." if len(text) > limit else "")


Validator = Callable[[httpx.Response], tuple[str, str] | str]


def probe_http(
    category: str,
    name: str,
    url: str,
    *,
    verify: bool = True,
    validate: Validator | None = None,
) -> Check:
    started = time.perf_counter()
    try:
        with httpx.Client(timeout=CHECK_TIMEOUT, verify=verify, follow_redirects=False) as client:
            response = client.get(url)
        latency = int((time.perf_counter() - started) * 1000)
        if response.status_code != 200:
            return Check(category, name, "DOWN", f"HTTP {response.status_code}: {_short_error(response.text[:100])}", latency)
        if validate is None:
            return Check(category, name, "UP", "HTTP 200", latency)
        result = validate(response)
        if isinstance(result, tuple):
            status, detail = result
        else:
            status, detail = "UP", str(result)
        return Check(category, name, status, detail, latency)
    except Exception as exc:
        latency = int((time.perf_counter() - started) * 1000)
        return Check(category, name, "DOWN", _short_error(exc), latency)


def validate_catalog(response: httpx.Response) -> tuple[str, str]:
    data = _json(response)
    if not data:
        return "DEGRADED", "catalog response is not a JSON object"
    servers = data.get("servers")
    count = len(servers) if isinstance(servers, list) else 0
    detail = f"version {data.get('version')} · {count} MCP servers"
    return ("UP" if count >= len(BRIDGE_PORTS) else "DEGRADED"), detail


def validate_metrics(response: httpx.Response) -> tuple[str, str]:
    body = response.text
    if "caddy_" not in body:
        return "DEGRADED", "metrics body has no caddy_ samples"
    return "UP", "Prometheus samples present"


def validate_bridge(response: httpx.Response, name: str) -> tuple[str, str]:
    data = _json(response)
    if not data:
        return "DEGRADED", "health response is not a JSON object"
    if data.get("ok") is not True:
        return "DOWN", f"ok={data.get('ok')}"
    bits = [f"auth={data.get('auth')}"]
    if data.get("credential_store") == "dpapi":
        bits.append("DPAPI")
    if data.get("tool_count") is not None:
        bits.append(f"{data['tool_count']} tools")
    if data.get("acl_users") is not None:
        bits.append(f"{data['acl_users']} ACL users")
    upstream = next(
        (data[key] for key in ("upstream", "server", "san", "arrays", "servers") if data.get(key)),
        None,
    )
    if isinstance(upstream, str):
        # Avoid exposing local filesystem paths from bridge internals.
        upstream_text = Path(upstream).name if (":\\" in upstream or upstream.startswith("/")) else upstream
        bits.append("upstream=" + _compact(upstream_text))
    elif upstream is not None:
        bits.append("upstream=" + _compact(upstream))
    return "UP", " · ".join(bits)


def validate_vsmonitoring(response: httpx.Response) -> tuple[str, str]:
    data = _json(response)
    if not data:
        return "DEGRADED", "health response is not a JSON object"
    database = data.get("database")
    detail = f"database={database} · version={data.get('version')} · commit={data.get('commit')}"
    return ("UP" if database == "ok" else "DEGRADED"), detail


def validate_json(response: httpx.Response) -> tuple[str, str]:
    if not _json(response):
        return "DEGRADED", "response is not a JSON object"
    return "UP", "JSON 200"


def _powershell(command: str) -> str:
    executable = shutil.which("powershell") or "powershell.exe"
    result = subprocess.run(
        [executable, "-NoProfile", "-NonInteractive", "-Command", command],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(_short_error(result.stderr or result.stdout or "PowerShell failed"))
    return result.stdout.strip()


def probe_service() -> Check:
    started = time.perf_counter()
    try:
        state = _powershell(f"(Get-Service -Name {SERVICE_NAME} -ErrorAction Stop).Status.ToString()")
        state = state.splitlines()[-1].strip() if state else ""
        status = "UP" if state == "Running" else "DEGRADED"
        return Check("Gateway core", "Windows service", status, f"{SERVICE_NAME}: {state or 'unknown'}", int((time.perf_counter() - started) * 1000))
    except Exception as exc:
        return Check("Gateway core", "Windows service", "DOWN", _short_error(exc), int((time.perf_counter() - started) * 1000))


def probe_scheduled_task() -> Check:
    started = time.perf_counter()
    command = (
        "$t=Get-ScheduledTask -TaskName 'Caddy Gateway Usage Snapshot' -ErrorAction Stop; "
        "$i=Get-ScheduledTaskInfo -TaskName 'Caddy Gateway Usage Snapshot' -ErrorAction Stop; "
        "[pscustomobject]@{State=[string]$t.State; LastRunTime=[string]$i.LastRunTime; "
        "LastResult=$i.LastTaskResult} | ConvertTo-Json -Compress"
    )
    try:
        payload = json.loads(_powershell(command))
        state = str(payload.get("State", "unknown"))
        last_run = str(payload.get("LastRunTime", "unknown"))
        result = payload.get("LastResult")
        status = "UP" if state == "Ready" and result in (0, "0") else "DEGRADED"
        detail = f"{TASK_NAME}: {state} · last run {last_run} · result {result}"
        return Check("Jobs & data", "Usage snapshot task", status, detail, int((time.perf_counter() - started) * 1000))
    except Exception as exc:
        return Check("Jobs & data", "Usage snapshot task", "DOWN", _short_error(exc), int((time.perf_counter() - started) * 1000))


def probe_snapshot() -> Check:
    started = time.perf_counter()
    try:
        if not SNAPSHOT_DB.is_file():
            return Check("Jobs & data", "Usage snapshot", "DOWN", "analytics/usage.duckdb is missing")
        with duckdb.connect(str(SNAPSHOT_DB), read_only=True) as con:
            row = con.execute(
                "SELECT built_utc, total_rows, acl_users FROM meta LIMIT 1"
            ).fetchone()
        if not row:
            return Check("Jobs & data", "Usage snapshot", "DEGRADED", "meta table is empty")
        built = row[0]
        if built.tzinfo is None:
            built = built.replace(tzinfo=timezone.utc)
        age = datetime.now(timezone.utc) - built.astimezone(timezone.utc)
        status = "UP" if age <= timedelta(hours=2) else "DEGRADED"
        detail = f"built {built:%Y-%m-%d %H:%M:%S %Z} · {age.total_seconds() / 60:.0f} min old · {int(row[1]):,} events"
        return Check("Jobs & data", "Usage snapshot", status, detail, int((time.perf_counter() - started) * 1000))
    except Exception as exc:
        return Check("Jobs & data", "Usage snapshot", "DOWN", _short_error(exc), int((time.perf_counter() - started) * 1000))


def collect_checks() -> list[Check]:
    jobs = [
        ("service", probe_service),
        ("task", probe_scheduled_task),
        ("snapshot", probe_snapshot),
        (
            "http-catalog",
            lambda: probe_http(
                "Gateway core",
                "HTTP catalog",
                f"{GATEWAY_HTTP}/mcp/servers",
                validate=validate_catalog,
            ),
        ),
        (
            "http-catalog-tls",
            lambda: probe_http(
                "Gateway core",
                "HTTPS catalog",
                f"{GATEWAY_HTTPS}/mcp/servers",
                verify=False,
                validate=validate_catalog,
            ),
        ),
        (
            "http-metrics",
            lambda: probe_http("Gateway core", "Prometheus metrics", METRICS_URL, validate=validate_metrics),
        ),
        (
            "http-dashboard",
            lambda: probe_http("Gateway core", "Streamlit health", f"{DASHBOARD_URL}/_stcore/health"),
        ),
        (
            "http-vsmonitoring",
            lambda: probe_http(
                "Other routes",
                "VS Monitoring health",
                f"{GATEWAY_HTTP}/vsmonitoring/api/health",
                validate=validate_vsmonitoring,
            ),
        ),
        (
            "http-todos",
            lambda: probe_http("Other routes", "JSONPlaceholder /todos", f"{GATEWAY_HTTP}/todos/1", validate=validate_json),
        ),
        (
            "http-bin",
            lambda: probe_http("Other routes", "httpbin /get", f"{GATEWAY_HTTP}/httpbin/get", validate=validate_json),
        ),
    ]

    for name, port in BRIDGE_PORTS.items():
        jobs.append(
            (
                f"bridge-{name}",
                lambda n=name: probe_http(
                    "MCP via gateway",
                    n,
                    f"{GATEWAY_HTTP}/{n}/health",
                    validate=lambda response, server=n: validate_bridge(response, server),
                ),
            )
        )
        jobs.append(
            (
                f"loopback-{name}",
                lambda n=name, p=port: probe_http(
                    "MCP loopback",
                    f"{n} :{p}",
                    f"http://127.0.0.1:{p}/health",
                    validate=lambda response, server=n: validate_bridge(response, server),
                ),
            )
        )

    with ThreadPoolExecutor(max_workers=16) as pool:
        futures = [pool.submit(job) for _, job in jobs]
        checks = [future.result() for future in futures]
    return checks


@st.fragment(run_every=f"{REFRESH_SECONDS}s")
def render_live_status() -> None:
    started = time.perf_counter()
    checks = collect_checks()
    elapsed = int((time.perf_counter() - started) * 1000)
    counts = Counter(check.status for check in checks)
    mcp_up = sum(
        1
        for check in checks
        if check.category == "MCP via gateway" and check.status == "UP"
    )

    col1, col2, col3, col4, col5 = st.columns(5)
    col1.metric("Checks", len(checks))
    col2.metric("Healthy", counts["UP"])
    col3.metric("Degraded", counts["DEGRADED"])
    col4.metric("Down", counts["DOWN"])
    col5.metric("MCP servers up", f"{mcp_up}/{len(BRIDGE_PORTS)}")

    if counts["DOWN"]:
        st.error(f"{counts['DOWN']} check(s) are down. See the rows below.")
    elif counts["DEGRADED"]:
        st.warning(f"{counts['DEGRADED']} check(s) are degraded. See the rows below.")
    else:
        st.success("All monitored services are available.")

    st.caption(
        f"Last checked {datetime.now().astimezone():%Y-%m-%d %H:%M:%S %Z %z} "
        f"· completed in {elapsed} ms · auto-refresh every {REFRESH_SECONDS}s"
    )
    if st.button("Refresh now"):
        st.rerun(scope="fragment")

    frame = pd.DataFrame([asdict(check) for check in checks])
    order = {label: index for index, label in enumerate(
        ["Gateway core", "MCP via gateway", "MCP loopback", "Other routes", "Jobs & data"]
    )}
    frame["_order"] = frame["category"].map(order).fillna(99)
    frame = frame.sort_values(["_order", "name"]).drop(columns="_order")
    st.dataframe(frame, width="stretch", hide_index=True)

    with st.expander("What these checks mean"):
        st.markdown(
            "- **Healthy** — HTTP 200 and the expected payload was returned.\n"
            "- **Degraded** — reachable, but payload/content or task state is unexpected.\n"
            "- **Down** — connection failed, timed out, or returned a non-200 status.\n"
            "- **MCP via gateway** uses the token-free `/<name>/health` route through Caddy.\n"
            "- **MCP loopback** probes the bridge directly on ports 8400-8406 to separate "
            "bridge failures from gateway routing failures.\n"
            "- Authenticated `tools/list` checks are not performed here; no token is read "
            "or displayed. Run `Test-McpDiscovery.ps1` for that deeper check.\n"
            "- The HTTPS catalog probe skips certificate verification because the gateway "
            "uses Caddy's local CA, which is not in Python's trust store."
        )


render_live_status()
