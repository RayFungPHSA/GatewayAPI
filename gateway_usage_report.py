#!/usr/bin/env python3
"""Usage report over Caddy JSON access logs, powered by DuckDB.

Reports per-MCP request volume, daily trends, hashed-token callers, status
codes and latency. Health checks and obvious scanner probes are reported
separately so they do not distort usage numbers.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import duckdb
except ImportError:
    sys.exit("DuckDB is required. Install it with: python -m pip install duckdb")


STATUS_OK = "status < 400"
STATUS_4XX = "status >= 400 AND status < 500"
STATUS_5XX = "status >= 500"
PROBE_REGEX = r"(\$\{jndi:|struts2|cgi-bin|/broker/xml|/webtools/|/portal/info\.jsp)"
MCP_FILTER = "endpoint LIKE '%/mcp'"
DEFAULT_ACL = r"C:\caddy-gateway\secrets\cohesity-gateway-acl.json"


def sql_string(value: str) -> str:
    """Escape a value for embedding in a SQL string literal."""
    return value.replace("'", "''")


def build_views(con: duckdb.DuckDBPyConnection, pattern: str, days: int, include_health: bool) -> None:
    path = sql_string(pattern.replace("\\", "/"))
    con.execute(
        f"""
        CREATE OR REPLACE VIEW raw_log AS
        SELECT to_timestamp(ts) AS ts,
               coalesce(request.client_ip, '') AS client_ip,
               coalesce(request.uri, '') AS uri,
               split_part(coalesce(request.uri, ''), '?', 1) AS path,
               request.headers['X-Gateway-Token'][1] AS gateway_token,
               request.headers['X-Cohesity-Api-Key'][1] AS cohesity_key,
               status, duration, size
        FROM read_json_auto('{path}', format='newline_delimited', union_by_name=true)
        """
    )

    window_filter = "TRUE" if days <= 0 else f"ts >= now() - INTERVAL {days} DAY"
    health_filter = "" if include_health else "AND path NOT IN ('/health', '/api/clusters') AND path NOT LIKE '%/health'"
    con.execute(
        f"""
        CREATE OR REPLACE VIEW events AS
        SELECT *,
               CASE WHEN split_part(path, '/', 3) = 'mcp'
                    THEN split_part(path, '/', 2) || '/mcp'
                    ELSE '/' || split_part(path, '/', 2) END AS endpoint,
               regexp_matches(uri, '{sql_string(PROBE_REGEX)}') AS is_probe,
               (path IN ('/health', '/api/clusters') OR path LIKE '%/health') AS is_health,
               {window_filter} AS in_window
        FROM raw_log
        """
    )


def load_acl(con: duckdb.DuckDBPyConnection, path: str) -> int:
    """Load the gateway ACL's token fingerprint prefixes into DuckDB."""
    con.execute("CREATE OR REPLACE TABLE acl(token_prefix VARCHAR, user_name VARCHAR, role VARCHAR)")
    acl_file = Path(path)
    if not acl_file.is_file():
        print(f"Warning: ACL not found at {path}; token hashes will be unmapped")
        return 0
    try:
        acl = json.loads(acl_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Warning: could not read ACL {path}: {exc}")
        return 0

    rows = []
    for user in acl.get("users", []):
        fingerprint = str(user.get("token_fp", ""))
        if len(fingerprint) < 8:
            continue
        rows.append((fingerprint[:8].lower(), user.get("name", fingerprint[:8]), user.get("role", "")))
    con.executemany("INSERT INTO acl VALUES (?, ?, ?)", rows)
    return len(rows)


def build_resolved_view(con: duckdb.DuckDBPyConnection) -> None:
    """Attach ACL names/roles to each event using Caddy's 8-char token hash."""
    con.execute(
        """
        CREATE OR REPLACE VIEW resolved AS
        SELECT e.*,
               a.user_name,
               a.role,
               coalesce(a.user_name,
                        CASE WHEN e.gateway_token IS NULL THEN '(no token)' ELSE '(unmapped)' END) AS caller,
               coalesce(e.gateway_token, '(none)') AS token_hash
        FROM events e
        LEFT JOIN acl a ON substr(lower(e.gateway_token), 1, 8) = a.token_prefix
        """
    )


def show(con: duckdb.DuckDBPyConnection, title: str, query: str, max_rows: int = 30) -> None:
    print()
    print(title)
    print("-" * len(title))
    try:
        con.sql(query).show(max_rows=max_rows, max_width=180)
    except duckdb.Error as exc:
        print(f"(no data: {exc})")


def main() -> int:
    parser = argparse.ArgumentParser(description="Caddy gateway usage report (DuckDB)")
    parser.add_argument("--log-path", default=r"C:\caddy-gateway\logs\access*.log",
                        help="Path or glob of Caddy access logs")
    parser.add_argument("--days", type=int, default=7, help="Look back this many days (0 = all logs)")
    parser.add_argument("--top", type=int, default=15, help="Maximum caller rows")
    parser.add_argument("--csv", help="Optional CSV path for daily MCP endpoint counts")
    parser.add_argument("--acl", default=DEFAULT_ACL,
                        help="Gateway ACL JSON used to resolve token hashes to user names")
    parser.add_argument("--include-health", action="store_true",
                        help="Include /health and /api/clusters traffic in usage")
    args = parser.parse_args()

    pattern = str(args.log_path)
    if not Path(pattern.replace("*", "")).parent.exists():
        print(f"Log directory does not exist: {Path(pattern).parent}")
        return 1

    con = duckdb.connect()
    try:
        build_views(con, pattern, args.days, args.include_health)
        acl_users = load_acl(con, args.acl)
        build_resolved_view(con)
        total = con.execute("SELECT count(*) FROM raw_log").fetchall()[0][0]
    except duckdb.Error as exc:
        print(f"Could not read logs at {pattern}: {exc}")
        return 1

    if total == 0:
        print(f"No log entries found at {pattern}")
        return 0

    window = "all time" if args.days <= 0 else f"last {args.days} days"
    health_clause = "" if args.include_health else "AND NOT is_health"
    usage_where = f"WHERE in_window AND NOT is_probe {health_clause}"

    overview = con.execute(
        f"""
        SELECT count(*) FILTER ({usage_where}) AS usage_requests,
               count(*) FILTER (WHERE in_window AND is_probe) AS probes,
               count(*) FILTER (WHERE in_window AND is_health) AS health_checks,
               count(DISTINCT client_ip) FILTER ({usage_where}) AS client_ips,
               count(DISTINCT gateway_token) FILTER ({usage_where}) AS token_hashes,
               count(*) FILTER ({usage_where} AND gateway_token IS NULL) AS unauthenticated,
               count(*) FILTER ({usage_where} AND {STATUS_4XX}) AS http_4xx,
               count(*) FILTER ({usage_where} AND {STATUS_5XX}) AS http_5xx,
               min(ts) FILTER ({usage_where}) AS first_seen,
               max(ts) FILTER ({usage_where}) AS last_seen
        FROM events
        """
    ).fetchall()[0]

    print(f"Caddy gateway usage report - {window}")
    print(f"Log: {pattern}")
    print(f"Entries read: {total} | ACL users loaded: {acl_users}")
    print(f"Usage requests: {overview[0]} | probes: {overview[1]} | health checks: {overview[2]}")
    print(f"Client IPs: {overview[3]} | token hashes: {overview[4]} | unauthenticated: {overview[5]}")
    print(f"4xx: {overview[6]} | 5xx: {overview[7]}")
    if overview[8]:
        print(f"First seen: {overview[8]}  Last seen: {overview[9]}")

    show(con, "Requests by MCP endpoint", f"""
        SELECT endpoint, count(*) AS requests,
               count(DISTINCT client_ip) AS clients,
               count(DISTINCT gateway_token) AS token_hashes,
               count(*) FILTER (WHERE {STATUS_OK}) AS ok_2xx,
               count(*) FILTER (WHERE {STATUS_4XX}) AS err_4xx,
               count(*) FILTER (WHERE {STATUS_5XX}) AS err_5xx,
               round(avg(duration) * 1000, 1) AS avg_ms,
               round(quantile_cont(duration, 0.95) * 1000, 1) AS p95_ms
        FROM events {usage_where} AND {MCP_FILTER}
        GROUP BY 1 ORDER BY requests DESC
        """)

    days = [row[0] for row in con.execute(
        f"SELECT DISTINCT strftime(ts, '%Y-%m-%d') FROM events {usage_where} AND {MCP_FILTER} ORDER BY 1"
    ).fetchall()]
    if days:
        day_columns = ", ".join(
            f"count(*) FILTER (WHERE strftime(ts, '%Y-%m-%d') = '{day}') AS \"{day}\"" for day in days
        )
        show(con, "Daily MCP requests", f"""
            SELECT endpoint, {day_columns}, count(*) AS total
            FROM events {usage_where} AND {MCP_FILTER}
            GROUP BY 1 ORDER BY total DESC
            """)

    show(con, f"By resolved user (ACL names, max {args.top})", f"""
        SELECT caller AS user_name,
               coalesce(max(role), '(none)') AS role,
               count(*) AS requests,
               count(*) FILTER (WHERE {MCP_FILTER}) AS mcp_requests,
               count(DISTINCT endpoint) FILTER (WHERE {MCP_FILTER}) AS mcp_endpoints,
               count(DISTINCT client_ip) AS client_ips,
               count(*) FILTER (WHERE {STATUS_4XX}) AS err_4xx,
               count(*) FILTER (WHERE {STATUS_5XX}) AS err_5xx
        FROM resolved {usage_where} AND gateway_token IS NOT NULL
        GROUP BY 1 ORDER BY requests DESC LIMIT {args.top}
        """, max_rows=args.top)

    show(con, f"Top callers by hashed gateway token (max {args.top})", f"""
        SELECT token_hash,
               caller AS user_name,
               coalesce(max(role), '(none)') AS role,
               count(*) AS requests,
               count(DISTINCT endpoint) FILTER (WHERE {MCP_FILTER}) AS mcp_endpoints,
               count(DISTINCT client_ip) AS client_ips,
               min(ts) AS first_seen, max(ts) AS last_seen
        FROM resolved {usage_where} AND gateway_token IS NOT NULL
        GROUP BY 1, 2 ORDER BY requests DESC LIMIT {args.top}
        """, max_rows=args.top)

    show(con, "Hashed token by MCP endpoint", f"""
        SELECT token_hash,
               caller AS user_name,
               string_agg(DISTINCT endpoint, ', ') AS endpoints,
               count(*) AS requests
        FROM resolved {usage_where} AND {MCP_FILTER} AND gateway_token IS NOT NULL
        GROUP BY 1, 2 ORDER BY requests DESC LIMIT {args.top}
        """, max_rows=args.top)

    show(con, "Scanner / probe traffic (excluded from usage)", f"""
        SELECT endpoint, count(*) AS requests,
               count(*) FILTER (WHERE {STATUS_4XX}) AS err_4xx,
               count(*) FILTER (WHERE {STATUS_5XX}) AS err_5xx
        FROM events WHERE in_window AND is_probe
        GROUP BY 1 ORDER BY requests DESC
        """)

    if args.csv:
        csv_path = sql_string(str(args.csv).replace("\\", "/"))
        con.execute(
            f"""
            COPY (
                SELECT endpoint, strftime(ts, '%Y-%m-%d') AS day, count(*) AS requests
                FROM events {usage_where} AND {MCP_FILTER}
                GROUP BY 1, 2 ORDER BY 1, 2
            ) TO '{csv_path}' (HEADER, DELIMITER ',')
            """
        )
        print(f"\nDaily MCP counts written to {args.csv}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
