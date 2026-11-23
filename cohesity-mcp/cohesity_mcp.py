import os
import json
import sys
import sqlite3
from contextlib import contextmanager
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

import httpx
import mcp.types as types
from mcp.server import Server
from pydantic import BaseModel


def load_env():
    # Production always supplies the key from the DPAPI record. Standalone
    # debugging can opt out of this legacy fallback with COHESITY_NO_DOTENV.
    if os.environ.get("COHESITY_NO_DOTENV") == "true":
        return

    # Helper to load .env file from the script directory, root directory, or current directory
    for path in [
        os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".env"),
        ".env"
    ]:
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("#"):
                            continue
                        if "=" in line:
                            k, v = line.split("=", 1)
                            k = k.strip()
                            v = v.strip()
                            # Strip quotes
                            if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                                v = v[1:-1]
                            if k and k not in os.environ:
                                os.environ[k] = v
            except Exception:
                pass

load_env()


class CohesityClient:
    def __init__(self, api_key: str):
        self.api_key = api_key
        self.base_url = "https://helios.cohesity.com/v2"
        self.client = httpx.Client(
            base_url=self.base_url,
            headers={
                "apiKey": api_key,
                "accept": "application/json",
                "user-agent": "cohesity-mcp-server/1.0",
            },
            timeout=60,
        )

    def request(
        self,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
        cluster_id: str | None = None,
        base_url: str | None = None,
        timeout: int | None = None,
    ) -> str:
        headers = {}
        if cluster_id:
            headers["accessClusterId"] = cluster_id

        client = self.client
        custom_client = None
        if base_url:
            custom_client = httpx.Client(
                base_url=base_url,
                headers={
                    "apiKey": self.api_key,
                    "accept": "application/json",
                    "user-agent": "cohesity-mcp-server/1.0",
                },
                timeout=60,
            )
            client = custom_client

        try:
            req_kwargs = dict(
                method=method.upper(),
                url=path.lstrip("/"),
                params=params,
                json=body,
                headers=headers or None,
            )
            if timeout is not None:
                req_kwargs["timeout"] = timeout
            resp = client.request(**req_kwargs)
            try:
                resp.raise_for_status()
            except httpx.HTTPStatusError:
                raise RuntimeError(
                    f"API error {resp.status_code}: {resp.text}"
                )
            if resp.status_code == 204:
                return "Success (no content)"
            return json.dumps(resp.json(), indent=2, default=str)
        finally:
            if custom_client:
                custom_client.close()


server = Server("cohesity-helios")
cohesity: CohesityClient | None = None


def get_client() -> CohesityClient:
    global cohesity
    if cohesity is None:
        key = os.environ.get("COHESITY_API_KEY") or os.environ.get("HELIOS_API_KEY")
        if not key:
            raise RuntimeError(
                "COHESITY_API_KEY environment variable is required"
            )
        cohesity = CohesityClient(key)
    return cohesity


ESX_CLUSTER_TYPES = {"kComputeResource", "kClusterComputeResource"}

CONSUMER_STATS_BASE_URL = "https://helios.cohesity.com/irisservices/api/v1/public"
DEFAULT_USAGE_DB = Path(__file__).with_name("data") / "protection_group_usage.sqlite3"


def _usage_db_path() -> Path:
    configured = os.environ.get("COHESITY_USAGE_DB")
    return Path(configured).expanduser() if configured else DEFAULT_USAGE_DB


@contextmanager
def _open_usage_db():
    path = _usage_db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    db.executescript("""
        CREATE TABLE IF NOT EXISTS usage_snapshots (
            id INTEGER PRIMARY KEY,
            cluster_id TEXT NOT NULL,
            cluster_name TEXT,
            captured_at TEXT NOT NULL,
            capture_date TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_usage_snapshots_lookup
            ON usage_snapshots(cluster_id, capture_date, captured_at);
        CREATE TABLE IF NOT EXISTS protection_group_usage (
            snapshot_id INTEGER NOT NULL REFERENCES usage_snapshots(id) ON DELETE CASCADE,
            protection_group_name TEXT NOT NULL,
            consumed_bytes INTEGER NOT NULL,
            data_bytes INTEGER NOT NULL,
            resiliency_bytes INTEGER NOT NULL,
            PRIMARY KEY (snapshot_id, protection_group_name)
        );
    """)
    try:
        with db:
            yield db
    finally:
        db.close()


def _validate_iso_date(value: str) -> str:
    try:
        return date.fromisoformat(value).isoformat()
    except (TypeError, ValueError) as exc:
        raise ValueError("Date must use YYYY-MM-DD format") from exc


def _snapshot_payload(db: sqlite3.Connection, snapshot: sqlite3.Row) -> dict[str, Any]:
    rows = db.execute(
        """SELECT protection_group_name, consumed_bytes, data_bytes, resiliency_bytes
           FROM protection_group_usage WHERE snapshot_id = ?
           ORDER BY consumed_bytes DESC, protection_group_name""",
        (snapshot["id"],),
    ).fetchall()
    groups = [{
        "name": row["protection_group_name"],
        "consumedBytes": row["consumed_bytes"],
        "consumedTB": round(row["consumed_bytes"] / 1_000_000_000_000, 6),
        "dataBytes": row["data_bytes"],
        "resiliencyBytes": row["resiliency_bytes"],
    } for row in rows]
    return {
        "clusterId": snapshot["cluster_id"],
        "clusterName": snapshot["cluster_name"],
        "captureDate": snapshot["capture_date"],
        "capturedAt": snapshot["captured_at"],
        "totalConsumedBytes": sum(group["consumedBytes"] for group in groups),
        "totalConsumedTB": round(sum(group["consumedBytes"] for group in groups) / 1_000_000_000_000, 6),
        "protectionGroups": groups,
    }


def collect_protection_group_usage(client: CohesityClient, cluster_id: str, cluster_name: str | None = None) -> dict[str, Any]:
    raw = client.request(
        "GET", "/stats/consumers",
        params={"consumerType": "kProtectionRuns", "maxCount": 1000},
        cluster_id=cluster_id,
        base_url=CONSUMER_STATS_BASE_URL,
    )
    response = json.loads(raw)
    now = datetime.now(timezone.utc)
    local_capture_date = now.astimezone().date().isoformat()
    with _open_usage_db() as db:
        cursor = db.execute(
            "INSERT INTO usage_snapshots(cluster_id, cluster_name, captured_at, capture_date) VALUES (?, ?, ?, ?)",
            (str(cluster_id), cluster_name, now.isoformat(), local_capture_date),
        )
        snapshot_id = cursor.lastrowid
        for consumer in response.get("statsList", []):
            name = consumer.get("name")
            if not name:
                continue
            stats = consumer.get("stats") or {}
            db.execute(
                """INSERT INTO protection_group_usage
                   (snapshot_id, protection_group_name, consumed_bytes, data_bytes, resiliency_bytes)
                   VALUES (?, ?, ?, ?, ?)""",
                (snapshot_id, name, int(stats.get("storageConsumedBytes") or 0),
                 int(stats.get("dataWrittenBytes") or 0),
                 int(stats.get("localTierResiliencyImpactBytes") or 0)),
            )
        snapshot = db.execute("SELECT * FROM usage_snapshots WHERE id = ?", (snapshot_id,)).fetchone()
        return _snapshot_payload(db, snapshot)


def get_protection_group_usage_snapshot(cluster_id: str, snapshot_date: str) -> dict[str, Any]:
    snapshot_date = _validate_iso_date(snapshot_date)
    with _open_usage_db() as db:
        snapshot = db.execute(
            """SELECT * FROM usage_snapshots
               WHERE cluster_id = ? AND capture_date = ?
               ORDER BY captured_at DESC LIMIT 1""",
            (str(cluster_id), snapshot_date),
        ).fetchone()
        if snapshot is None:
            raise ValueError(f"No stored usage snapshot for cluster {cluster_id} on {snapshot_date}")
        return _snapshot_payload(db, snapshot)


def compare_protection_group_usage_snapshots(cluster_id: str, start_date: str, end_date: str) -> dict[str, Any]:
    start = get_protection_group_usage_snapshot(cluster_id, start_date)
    end = get_protection_group_usage_snapshot(cluster_id, end_date)
    start_groups = {group["name"]: group for group in start["protectionGroups"]}
    end_groups = {group["name"]: group for group in end["protectionGroups"]}
    changes = []
    for name in set(start_groups) | set(end_groups):
        before = start_groups.get(name, {}).get("consumedBytes", 0)
        after = end_groups.get(name, {}).get("consumedBytes", 0)
        delta = after - before
        changes.append({
            "name": name,
            "startConsumedTB": round(before / 1_000_000_000_000, 6),
            "endConsumedTB": round(after / 1_000_000_000_000, 6),
            "changeTB": round(delta / 1_000_000_000_000, 6),
            "changePercent": round((delta / before) * 100, 2) if before else (None if after == 0 else "new"),
        })
    changes.sort(key=lambda item: item["changeTB"], reverse=True)
    total_delta = end["totalConsumedBytes"] - start["totalConsumedBytes"]
    return {
        "clusterId": str(cluster_id),
        "start": {"date": start["captureDate"], "capturedAt": start["capturedAt"], "totalConsumedTB": start["totalConsumedTB"]},
        "end": {"date": end["captureDate"], "capturedAt": end["capturedAt"], "totalConsumedTB": end["totalConsumedTB"]},
        "totalChangeTB": round(total_delta / 1_000_000_000_000, 6),
        "totalChangePercent": round((total_delta / start["totalConsumedBytes"]) * 100, 2) if start["totalConsumedBytes"] else None,
        "protectionGroups": changes,
    }


def list_protection_group_usage_dates(cluster_id: str) -> dict[str, Any]:
    with _open_usage_db() as db:
        rows = db.execute(
            """SELECT capture_date, COUNT(*) AS snapshot_count, MAX(captured_at) AS latest_capture
               FROM usage_snapshots WHERE cluster_id = ? GROUP BY capture_date
               ORDER BY capture_date""",
            (str(cluster_id),),
        ).fetchall()
    return {"clusterId": str(cluster_id), "dates": [dict(row) for row in rows]}


def _has_usage_snapshot_today(cluster_id: str) -> bool:
    today = datetime.now(timezone.utc).astimezone().date().isoformat()
    with _open_usage_db() as db:
        row = db.execute(
            "SELECT 1 FROM usage_snapshots WHERE cluster_id = ? AND capture_date = ? LIMIT 1",
            (str(cluster_id), today),
        ).fetchone()
    return row is not None


def collect_daily_usage_for_all_clusters() -> None:
    client = get_client()
    raw = client.request("GET", "/mcm/clusters/info", base_url=CONSUMER_STATS_BASE_URL)
    clusters = json.loads(raw).get("upgradeInfo", [])
    for cluster in clusters:
        cluster_id = cluster.get("clusterId")
        if cluster_id is None or _has_usage_snapshot_today(str(cluster_id)):
            continue
        cluster_name = cluster.get("clusterName") or cluster.get("name")
        try:
            collect_protection_group_usage(client, str(cluster_id), cluster_name)
        except Exception as exc:
            print(f"Usage collection failed for cluster {cluster_id}: {exc}", file=sys.stderr)


def _extract_esx_clusters(data: Any) -> list[dict]:
    results = []
    if isinstance(data, dict):
        obj_type = data.get("objectType") or data.get("type")
        if obj_type in ESX_CLUSTER_TYPES:
            results.append({
                "name": data.get("name", "unknown"),
                "id": data.get("id"),
                "type": obj_type,
            })
        for v in data.values():
            if isinstance(v, (list, dict)):
                results.extend(_extract_esx_clusters(v))
    elif isinstance(data, list):
        for item in data:
            results.extend(_extract_esx_clusters(item))
    return results


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="list_clusters",
            description="List all clusters visible to the Helios user",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        types.Tool(
            name="get_cluster_info",
            description="Get detailed cluster configuration and metadata",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {
                        "type": "string",
                        "description": "Cluster ID to get info for (optional, returns summary if omitted)",
                    }
                },
            },
        ),
        types.Tool(
            name="list_protection_groups",
            description="List protection groups (backup jobs)",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {
                        "type": "string",
                        "description": "Optional cluster ID to scope the query",
                    },
                    "environment": {
                        "type": "string",
                        "description": "Filter by environment (kPhysical, kVMware, kSQL, kExchange, kNAS, kPaaS, kO365, etc.)",
                    },
                },
            },
        ),
        types.Tool(
            name="get_protection_group",
            description="Get details of a specific protection group",
            inputSchema={
                "type": "object",
                "properties": {
                    "group_id": {
                        "type": "string",
                        "description": "Protection group ID",
                    },
                },
                "required": ["group_id"],
            },
        ),
        types.Tool(
            name="run_backup",
            description="Trigger an on-demand backup run for a protection group",
            inputSchema={
                "type": "object",
                "properties": {
                    "group_id": {
                        "type": "string",
                        "description": "Protection group ID to run",
                    },
                    "cluster_id": {
                        "type": "string",
                        "description": "Optional cluster ID",
                    },
                    "run_type": {
                        "type": "string",
                        "description": "kRegular, kFull, kLog, kSystem",
                        "default": "kRegular",
                    },
                },
                "required": ["group_id"],
            },
        ),
        types.Tool(
            name="list_protection_group_runs",
            description="List runs for a protection group",
            inputSchema={
                "type": "object",
                "properties": {
                    "group_id": {
                        "type": "string",
                        "description": "Protection group ID",
                    },
                    "start_time_usecs": {
                        "type": "number",
                        "description": "Start time filter (epoch microseconds)",
                    },
                    "end_time_usecs": {
                        "type": "number",
                        "description": "End time filter (epoch microseconds)",
                    },
                    "num_runs": {
                        "type": "number",
                        "description": "Max number of runs to return",
                    },
                },
                "required": ["group_id"],
            },
        ),
        types.Tool(
            name="list_policies",
            description="List protection policies",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {
                        "type": "string",
                        "description": "Optional cluster ID",
                    },
                },
            },
        ),
        types.Tool(
            name="list_alerts",
            description="List Helios alerts",
            inputSchema={
                "type": "object",
                "properties": {
                    "start_time_usecs": {
                        "type": "number",
                        "description": "Start time (epoch microseconds)",
                    },
                    "end_time_usecs": {
                        "type": "number",
                        "description": "End time (epoch microseconds)",
                    },
                    "alert_type": {
                        "type": "string",
                        "description": "Filter by alert type (kSecurity, kSystem, kBackup, kRestore, kCompliance, etc.)",
                    },
                    "alert_state": {
                        "type": "string",
                        "description": "Filter by state (kOpen, kResolved, kSuppressed)",
                    },
                    "severity": {
                        "type": "string",
                        "description": "Filter by severity (kCritical, kWarning, kInfo)",
                    },
                    "cluster_id": {
                        "type": "string",
                        "description": "Optional cluster ID",
                    },
                },
            },
        ),
        types.Tool(
            name="get_protection_summary",
            description="Get protection summary statistics across clusters",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        types.Tool(
            name="list_protected_objects",
            description="List protected objects",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {
                        "type": "string",
                        "description": "Optional cluster ID",
                    },
                    "environment": {
                        "type": "string",
                        "description": "Filter by environment",
                    },
                    "object_type": {
                        "type": "string",
                        "description": "Filter by object type",
                    },
                },
            },
        ),
        types.Tool(
            name="search_objects",
            description="Search for objects across the Helios environment",
            inputSchema={
                "type": "object",
                "properties": {
                    "search_string": {
                        "type": "string",
                        "description": "Search string to match against object names",
                    },
                    "environment": {
                        "type": "string",
                        "description": "Filter by environment",
                    },
                    "cluster_id": {
                        "type": "string",
                        "description": "Optional cluster ID",
                    },
                },
            },
        ),
        types.Tool(
            name="list_recoveries",
            description="List recoveries (restore jobs)",
            inputSchema={
                "type": "object",
                "properties": {
                    "start_time_usecs": {
                        "type": "number",
                        "description": "Start time filter (epoch microseconds)",
                    },
                    "end_time_usecs": {
                        "type": "number",
                        "description": "End time filter (epoch microseconds)",
                    },
                    "cluster_id": {
                        "type": "string",
                        "description": "Optional cluster ID",
                    },
                    "status": {
                        "type": "string",
                        "description": "Filter by status (kRunning, kSucceeded, kFailed, kCanceled, etc.)",
                    },
                },
            },
        ),
        types.Tool(
            name="list_audit_logs",
            description="Get Helios audit logs",
            inputSchema={
                "type": "object",
                "properties": {
                    "start_time_usecs": {
                        "type": "number",
                        "description": "Start time (epoch microseconds)",
                    },
                    "end_time_usecs": {
                        "type": "number",
                        "description": "End time (epoch microseconds)",
                    },
                    "cluster_id": {
                        "type": "string",
                        "description": "Optional cluster ID",
                    },
                },
            },
        ),
        types.Tool(
            name="list_sources",
            description="List protection sources (registered data sources)",
            inputSchema={
                "type": "object",
                "properties": {
                    "environment": {
                        "type": "string",
                        "description": "Filter by environment",
                    },
                    "cluster_id": {
                        "type": "string",
                        "description": "Optional cluster ID",
                    },
                },
            },
        ),
        types.Tool(
            name="list_tenants",
            description="List tenants on Helios (multi-tenancy)",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        types.Tool(
            name="get_encryption_summary",
            description="Get encryption summary across clusters",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        types.Tool(
            name="api_request",
            description="Make a generic API request to any Helios endpoint",
            inputSchema={
                "type": "object",
                "properties": {
                    "method": {
                        "type": "string",
                        "description": "HTTP method (GET, POST, PUT, DELETE, PATCH)",
                    },
                    "path": {
                        "type": "string",
                        "description": "API path (e.g. /data-protect/protection-groups)",
                    },
                    "body": {
                        "type": "object",
                        "description": "JSON request body (for POST/PUT/PATCH)",
                    },
                    "params": {
                        "type": "object",
                        "description": "Query parameters",
                    },
                    "cluster_id": {
                        "type": "string",
                        "description": "Optional accessClusterId header value",
                    },
                },
                "required": ["method", "path"],
            },
        ),
        types.Tool(
            name="list_esx_clusters",
            description="List ESX/vSphere clusters registered as protection sources on a Cohesity cluster. Walks the VMware source tree (vCenter → Datacenter → Cluster) and returns ESX cluster names, IDs, and their parent path.",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {
                        "type": "string",
                        "description": "Cohesity cluster ID (int64). Use list_clusters first to find cluster IDs.",
                    },
                },
            },
        ),
        types.Tool(
            name="get_cluster_nodes",
            description="List all nodes in a Cohesity cluster with IPs, roles, and software versions.",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {
                        "type": "string",
                        "description": "Cohesity cluster ID (int64). Required.",
                    },
                },
                "required": ["cluster_id"],
            },
        ),
        types.Tool(
            name="get_cluster_upgrade_info",
            description="Get upgrade/patch availability and health info for all clusters visible to Helios.",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        types.Tool(
            name="list_source_registrations",
            description="List all registered protection sources on a cluster. Returns both VM and physical host registrations. API does not support server-side filtering — use the summary flag to get environment counts without loading all records.",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {
                        "type": "string",
                        "description": "Cohesity cluster ID (int64). Required.",
                    },
                    "summary": {
                        "type": "boolean",
                        "description": "If true, return only environment counts instead of the full registration list",
                    },
                },
                "required": ["cluster_id"],
            },
        ),
        types.Tool(
            name="get_cluster_config",
            description="Get detailed cluster configuration including deployment type, network config, and software version.",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {
                        "type": "string",
                        "description": "Cohesity cluster ID (int64). Required.",
                    },
                },
                "required": ["cluster_id"],
            },
        ),
        types.Tool(
            name="collect_protection_group_usage",
            description="Collect and permanently store the current accumulated physical consumption of every protection group, including retained data and resiliency overhead. This is not daily backup write volume.",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {"type": "string", "description": "Cohesity cluster ID (required)."},
                    "cluster_name": {"type": "string", "description": "Optional friendly cluster name."},
                },
                "required": ["cluster_id"],
            },
        ),
        types.Tool(
            name="get_protection_group_usage",
            description="Return the latest stored accumulated protection-group usage snapshot for an exact calendar date.",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {"type": "string"},
                    "date": {"type": "string", "description": "Exact snapshot date in YYYY-MM-DD format."},
                },
                "required": ["cluster_id", "date"],
            },
        ),
        types.Tool(
            name="compare_protection_group_usage",
            description="Compare accumulated protection-group consumption between two stored dates, with per-group TB and percentage changes.",
            inputSchema={
                "type": "object",
                "properties": {
                    "cluster_id": {"type": "string"},
                    "start_date": {"type": "string", "description": "Start date in YYYY-MM-DD format."},
                    "end_date": {"type": "string", "description": "End date in YYYY-MM-DD format."},
                },
                "required": ["cluster_id", "start_date", "end_date"],
            },
        ),
        types.Tool(
            name="list_protection_group_usage_dates",
            description="List dates for which accumulated protection-group usage snapshots are stored locally.",
            inputSchema={
                "type": "object",
                "properties": {"cluster_id": {"type": "string"}},
                "required": ["cluster_id"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    client = get_client()

    try:
        if name == "list_clusters":
            result = client.request(
                "GET", "/mcm/clusters/info",
                base_url="https://helios.cohesity.com/irisservices/api/v1/public",
            )

        elif name == "get_cluster_info":
            cid = arguments.get("cluster_id")
            raw = client.request(
                "GET", "/mcm/clusters/info",
                base_url="https://helios.cohesity.com/irisservices/api/v1/public",
            )
            parsed = json.loads(raw)
            items = parsed.get("upgradeInfo", [])
            if cid:
                cid = int(cid)
                matches = [c for c in items if c.get("clusterId") == cid]
                result = json.dumps(matches[0], indent=2, default=str) if matches else f"No cluster with id {cid}"
            else:
                result = json.dumps(items, indent=2, default=str) if items else raw

        elif name == "list_protection_groups":
            params = {}
            if arguments.get("environment"):
                params["environment"] = arguments["environment"]
            cluster_id = arguments.get("cluster_id")
            result = client.request("GET", "/data-protect/protection-groups", params=params, cluster_id=cluster_id)

        elif name == "get_protection_group":
            gid = arguments["group_id"]
            result = client.request("GET", f"/data-protect/protection-groups/{gid}")

        elif name == "run_backup":
            gid = arguments["group_id"]
            body = {"runType": arguments.get("run_type", "kRegular")}
            cluster_id = arguments.get("cluster_id")
            result = client.request("POST", f"/data-protect/protection-groups/{gid}/runs", body=body, cluster_id=cluster_id)

        elif name == "list_protection_group_runs":
            gid = arguments["group_id"]
            params = {}
            if arguments.get("start_time_usecs"):
                params["startTimeUsecs"] = arguments["start_time_usecs"]
            if arguments.get("end_time_usecs"):
                params["endTimeUsecs"] = arguments["end_time_usecs"]
            if arguments.get("num_runs"):
                params["numRuns"] = arguments["num_runs"]
            result = client.request("GET", f"/data-protect/protection-groups/{gid}/runs", params=params)

        elif name == "list_policies":
            cluster_id = arguments.get("cluster_id")
            result = client.request("GET", "/data-protect/policies", cluster_id=cluster_id)

        elif name == "list_alerts":
            params = {}
            for k in ("start_time_usecs", "end_time_usecs"):
                if arguments.get(k):
                    params[k] = arguments[k]
            if arguments.get("alert_type"):
                params["alertType"] = arguments["alert_type"]
            if arguments.get("alert_state"):
                params["alertState"] = arguments["alert_state"]
            if arguments.get("severity"):
                params["severity"] = arguments["severity"]
            cluster_id = arguments.get("cluster_id")
            result = client.request("GET", "/mcm/alerts", params=params, cluster_id=cluster_id)

        elif name == "get_protection_summary":
            result = client.request("GET", "/mcm/stats/protectionSummary")

        elif name == "list_protected_objects":
            params = {}
            if arguments.get("environment"):
                params["environment"] = arguments["environment"]
            if arguments.get("object_type"):
                params["objectType"] = arguments["object_type"]
            cluster_id = arguments.get("cluster_id")
            result = client.request("GET", "/data-protect/protected-objects", params=params, cluster_id=cluster_id)

        elif name == "search_objects":
            params = {}
            if arguments.get("search_string"):
                params["searchString"] = arguments["search_string"]
            if arguments.get("environment"):
                params["environment"] = arguments["environment"]
            cluster_id = arguments.get("cluster_id")
            result = client.request("GET", "/data-protect/search/objects", params=params, cluster_id=cluster_id)

        elif name == "list_recoveries":
            params = {}
            for k in ("start_time_usecs", "end_time_usecs"):
                if arguments.get(k):
                    params[k.replace("_time_usecs", "TimeUsecs")] = arguments[k]
            if arguments.get("status"):
                params["status"] = arguments["status"]
            cluster_id = arguments.get("cluster_id")
            result = client.request("GET", "/data-protect/recoveries", params=params, cluster_id=cluster_id)

        elif name == "list_audit_logs":
            params = {}
            for k in ("start_time_usecs", "end_time_usecs"):
                if arguments.get(k):
                    params[k.replace("_time_usecs", "TimeUsecs")] = arguments[k]
            cluster_id = arguments.get("cluster_id")
            result = client.request("GET", "/mcm/audit-logs", params=params, cluster_id=cluster_id)

        elif name == "list_sources":
            params = {}
            if arguments.get("environment"):
                params["environments"] = arguments["environment"]
            cluster_id = arguments.get("cluster_id")
            result = client.request("GET", "/mcm/data-protect/sources", params=params, cluster_id=cluster_id)

        elif name == "list_tenants":
            result = client.request("GET", "/mcm/tenants")

        elif name == "get_encryption_summary":
            result = client.request("GET", "/mcm/encryption/summary")

        elif name == "list_esx_clusters":
            cluster_id = arguments.get("cluster_id")
            raw = client.request(
                "GET", "/mcm/data-protect/sources",
                params={"environments": "kVMware"},
                cluster_id=cluster_id,
            )
            vcenters = json.loads(raw).get("sources", [])

            all_clusters = []
            for vc in vcenters:
                vc_name = vc.get("name", "unknown")
                for si in vc.get("sourceInfoList", []):
                    sid = si.get("sourceId")
                    if not sid:
                        continue
                    try:
                        objs_raw = client.request(
                            "GET", f"/data-protect/sources/{sid}/objects",
                            cluster_id=cluster_id,
                        )
                        objs = json.loads(objs_raw).get("objects", [])
                        for obj in objs:
                            ot = obj.get("objectType")
                            if ot in ESX_CLUSTER_TYPES:
                                all_clusters.append({
                                    "name": obj.get("name"),
                                    "id": obj.get("id"),
                                    "type": ot,
                                    "vcenter": vc_name,
                                })
                    except RuntimeError as e:
                        err = str(e)
                        if "ResourceExhausted" in err:
                            # Try to get VM count from search/objects endpoint
                            try:
                                search_raw = client.request(
                                    "GET", "/data-protect/search/objects",
                                    params={"searchString": "*", "environments": "kVMware"},
                                    cluster_id=cluster_id,
                                )
                                search_data = json.loads(search_raw)
                                vc_uuid = si.get("uuid", "")
                                vm_count = 0
                                for obj in search_data.get("objects", []):
                                    gid = obj.get("globalId", "")
                                    if gid.startswith(vc_uuid):
                                        vm_count += 1
                                # Paginate to count all VMs for this vCenter
                                cookie = search_data.get("paginationCookie")
                                while cookie:
                                    more_raw = client.request(
                                        "GET", "/data-protect/search/objects",
                                        params={"searchString": "*", "environments": "kVMware", "paginationCookie": str(cookie)},
                                        cluster_id=cluster_id,
                                    )
                                    more_data = json.loads(more_raw)
                                    for obj in more_data.get("objects", []):
                                        gid = obj.get("globalId", "")
                                        if gid.startswith(vc_uuid):
                                            vm_count += 1
                                    cookie = more_data.get("paginationCookie")
                                all_clusters.append({
                                    "name": f"<gRPC limit: tree walk unavailable; {vm_count} VMs found via search>",
                                    "id": None,
                                    "type": "resource_exhausted",
                                    "vcenter": vc_name,
                                    "vm_count": vm_count,
                                })
                            except Exception:
                                all_clusters.append({
                                    "name": f"<gRPC limit: tree walk unavailable for {vc_name}>",
                                    "id": None,
                                    "type": "resource_exhausted",
                                    "vcenter": vc_name,
                                })
                        else:
                            all_clusters.append({
                                "name": f"<error querying {vc_name}: {err[:100]}>",
                                "id": None,
                                "type": "error",
                                "vcenter": vc_name,
                            })

            if all_clusters:
                result = json.dumps(all_clusters, indent=2, default=str)
            else:
                result = "No ESX clusters found"

        elif name == "get_cluster_nodes":
            cid = arguments["cluster_id"]
            result = client.request("GET", "/clusters/nodes", cluster_id=cid)

        elif name == "get_cluster_upgrade_info":
            result = client.request("GET", "/mcm/cluster-mgmt/info")

        elif name == "list_source_registrations":
            cid = arguments["cluster_id"]
            raw = client.request("GET", "/data-protect/sources/registrations", cluster_id=cid)
            if arguments.get("summary"):
                d = json.loads(raw)
                regs = d.get("registrations", [])
                counts = {}
                for r in regs:
                    env = r.get("environment", "unknown")
                    counts[env] = counts.get(env, 0) + 1
                result = json.dumps({"total": len(regs), "by_environment": counts}, indent=2)
            else:
                result = raw

        elif name == "get_cluster_config":
            cid = arguments["cluster_id"]
            result = client.request("GET", "/clusters", cluster_id=cid)

        elif name == "collect_protection_group_usage":
            result = json.dumps(collect_protection_group_usage(
                client, arguments["cluster_id"], arguments.get("cluster_name")
            ), indent=2)

        elif name == "get_protection_group_usage":
            result = json.dumps(get_protection_group_usage_snapshot(
                arguments["cluster_id"], arguments["date"]
            ), indent=2)

        elif name == "compare_protection_group_usage":
            result = json.dumps(compare_protection_group_usage_snapshots(
                arguments["cluster_id"], arguments["start_date"], arguments["end_date"]
            ), indent=2)

        elif name == "list_protection_group_usage_dates":
            result = json.dumps(list_protection_group_usage_dates(arguments["cluster_id"]), indent=2)

        elif name == "api_request":
            result = client.request(
                method=arguments["method"],
                path=arguments["path"],
                params=arguments.get("params"),
                body=arguments.get("body"),
                cluster_id=arguments.get("cluster_id"),
            )

        else:
            raise ValueError(f"Unknown tool: {name}")

        return [types.TextContent(type="text", text=result)]

    except Exception as e:
        return [types.TextContent(type="text", text=f"Error: {e}")]


import asyncio
import anyio
from mcp.server.stdio import stdio_server


async def daily_usage_collector() -> None:
    interval_hours = max(float(os.environ.get("COHESITY_USAGE_COLLECTION_HOURS", "24")), 1.0)
    while True:
        try:
            await anyio.to_thread.run_sync(collect_daily_usage_for_all_clusters)
        except Exception as exc:
            print(f"Daily protection-group usage collection failed: {exc}", file=sys.stderr)
        await anyio.sleep(interval_hours * 3600)


async def main():
    api_key = os.environ.get("COHESITY_API_KEY") or os.environ.get("HELIOS_API_KEY")
    if not api_key:
        print("ERROR: COHESITY_API_KEY environment variable is required", file=sys.stderr)
        sys.exit(1)

    async with stdio_server() as (read_stream, write_stream):
        async with anyio.create_task_group() as tasks:
            if os.environ.get("COHESITY_USAGE_AUTO_COLLECT", "true").lower() not in {"0", "false", "no"}:
                tasks.start_soon(daily_usage_collector)
            await server.run(
                read_stream,
                write_stream,
                server.create_initialization_options(),
            )
            tasks.cancel_scope.cancel()


if __name__ == "__main__":
    asyncio.run(main())
