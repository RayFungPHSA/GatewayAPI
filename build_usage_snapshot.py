#!/usr/bin/env python3
"""Incrementally snapshot Caddy gateway access logs into a DuckDB file.

The snapshot keeps history after Caddy rotates out access.log, and is what the
Streamlit dashboard reads. Re-running is safe: existing event IDs are skipped.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from gateway_usage_report import DEFAULT_ACL, PROBE_REGEX, sql_string  # noqa: E402

DEFAULT_DB = r"C:\caddy-gateway\analytics\usage.duckdb"
DEFAULT_LOG = r"C:\caddy-gateway\logs\access*.log"


def load_acl_rows(path: str) -> list[tuple[str, str, str]]:
    acl_file = Path(path)
    if not acl_file.is_file():
        print(f"Warning: ACL not found at {path}; users will be unmapped")
        return []
    try:
        acl = json.loads(acl_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Warning: could not read ACL {path}: {exc}")
        return []

    rows = []
    for user in acl.get("users", []):
        fingerprint = str(user.get("token_fp", ""))
        if len(fingerprint) < 8:
            continue
        rows.append((fingerprint[:8].lower(), user.get("name", fingerprint[:8]), user.get("role", "")))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the gateway usage snapshot")
    parser.add_argument("--log-path", default=DEFAULT_LOG, help="Access log path or glob")
    parser.add_argument("--acl", default=DEFAULT_ACL, help="Gateway ACL JSON")
    parser.add_argument("--db", default=DEFAULT_DB, help="Destination DuckDB file")
    args = parser.parse_args()

    db_path = Path(args.db)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = db_path.with_name(db_path.stem + ".building.duckdb")
    backup_path = db_path.with_name(db_path.stem + ".backup.duckdb")
    if tmp_path.exists():
        tmp_path.unlink()

    con = duckdb.connect(str(tmp_path))
    try:
        con.execute(
            """
            CREATE TABLE events (
                event_id VARCHAR, ts TIMESTAMPTZ, client_ip VARCHAR, remote_port VARCHAR,
                method VARCHAR, uri VARCHAR, path VARCHAR, endpoint VARCHAR,
                token_hash VARCHAR, caller VARCHAR, role VARCHAR,
                status BIGINT, duration DOUBLE, size BIGINT,
                is_probe BOOLEAN, is_health BOOLEAN
            )
            """
        )

        # Carry forward history from the previous snapshot before merging new logs.
        if db_path.exists():
            previous = sql_string(str(db_path).replace("\\", "/"))
            con.execute(f"ATTACH '{previous}' AS prev (READ_ONLY)")
            con.execute("INSERT INTO events BY NAME SELECT * FROM prev.events")
            con.execute("DETACH prev")

        acl_rows = load_acl_rows(args.acl)
        con.execute("CREATE TABLE acl(token_prefix VARCHAR, user_name VARCHAR, role VARCHAR)")
        con.executemany("INSERT INTO acl VALUES (?, ?, ?)", acl_rows)

        log_glob = sql_string(args.log_path.replace("\\", "/"))
        if not glob.glob(args.log_path):
            con.execute(
                """
                CREATE TABLE staged (
                    event_id VARCHAR, ts TIMESTAMPTZ, client_ip VARCHAR, remote_port VARCHAR,
                    method VARCHAR, uri VARCHAR, path VARCHAR, token_hash VARCHAR,
                    status BIGINT, duration DOUBLE, size BIGINT
                )
                """
            )
        else:
            con.execute(
                f"""
                CREATE TABLE staged AS
                SELECT md5(concat_ws('|',
                       CAST(ts AS VARCHAR), request.client_ip, request.remote_port,
                       request.method, request.uri, CAST(status AS VARCHAR),
                       CAST(size AS VARCHAR), CAST(duration AS VARCHAR))) AS event_id,
                       to_timestamp(ts) AS ts,
                       coalesce(request.client_ip, '') AS client_ip,
                       coalesce(request.remote_port, '') AS remote_port,
                       coalesce(request.method, '') AS method,
                       coalesce(request.uri, '') AS uri,
                       split_part(coalesce(request.uri, ''), '?', 1) AS path,
                       request.headers['X-Gateway-Token'][1] AS token_hash,
                       status, duration, size
                FROM read_json_auto('{log_glob}', format='newline_delimited', union_by_name=true)
                """
            )

        rows_added = con.execute(
            """
            SELECT count(*) FROM staged s
            LEFT JOIN events e ON e.event_id = s.event_id
            WHERE e.event_id IS NULL
            """
        ).fetchall()[0][0]

        con.execute(
            f"""
            INSERT INTO events
            SELECT s.event_id, s.ts, s.client_ip, s.remote_port, s.method, s.uri, s.path,
                   CASE WHEN split_part(s.path, '/', 3) = 'mcp'
                        THEN split_part(s.path, '/', 2) || '/mcp'
                        ELSE '/' || split_part(s.path, '/', 2) END AS endpoint,
                   s.token_hash,
                   coalesce(a.user_name,
                            CASE WHEN s.token_hash IS NULL THEN '(no token)' ELSE '(unmapped)' END) AS caller,
                   coalesce(a.role, '') AS role,
                   s.status, s.duration, s.size,
                   regexp_matches(s.uri, '{sql_string(PROBE_REGEX)}') AS is_probe,
                   (s.path IN ('/health', '/api/clusters') OR s.path LIKE '%/health') AS is_health
            FROM staged s
            LEFT JOIN events e ON e.event_id = s.event_id
            LEFT JOIN acl a ON substr(lower(s.token_hash), 1, 8) = a.token_prefix
            WHERE e.event_id IS NULL
            """
        )

        con.execute(
            """
            CREATE OR REPLACE TABLE daily_endpoint AS
            SELECT CAST(ts AS DATE) AS day, endpoint,
                   count(*) AS requests,
                   count(DISTINCT client_ip) AS clients,
                   count(DISTINCT token_hash) AS token_hashes,
                   count(*) FILTER (WHERE status < 400) AS ok_2xx,
                   count(*) FILTER (WHERE status >= 400 AND status < 500) AS err_4xx,
                   count(*) FILTER (WHERE status >= 500) AS err_5xx,
                   round(avg(duration) * 1000, 1) AS avg_ms,
                   round(quantile_cont(duration, 0.95) * 1000, 1) AS p95_ms
            FROM events GROUP BY 1, 2
            """
        )
        con.execute(
            """
            CREATE OR REPLACE TABLE daily_user AS
            SELECT CAST(ts AS DATE) AS day, caller, role,
                   count(*) AS requests,
                   count(DISTINCT endpoint) AS endpoints,
                   count(DISTINCT client_ip) AS client_ips,
                   count(*) FILTER (WHERE status >= 400) AS errors
            FROM events WHERE token_hash IS NOT NULL GROUP BY 1, 2, 3
            """
        )
        con.execute(
            f"""
            CREATE OR REPLACE TABLE meta AS
            SELECT now() AS built_utc,
                   {rows_added}::BIGINT AS rows_added,
                   (SELECT count(*) FROM events) AS total_rows,
                   '{sql_string(args.log_path)}' AS source_log,
                   {len(acl_rows)}::BIGINT AS acl_users
            """
        )
        total = con.execute("SELECT count(*) FROM events").fetchall()[0][0]
    finally:
        con.close()

    # Swap into place atomically so a dashboard reader never sees a partial file.
    for attempt in range(3):
        try:
            if db_path.exists():
                if backup_path.exists():
                    backup_path.unlink()
                os.replace(db_path, backup_path)
            os.replace(tmp_path, db_path)
            break
        except OSError as exc:
            if db_path.exists() is False and backup_path.exists():
                os.replace(backup_path, db_path)
            if attempt == 2:
                print(f"Could not replace {db_path}: {exc}")
                return 1
            time.sleep(2)

    print(f"Snapshot: {db_path}")
    print(f"Rows added: {rows_added} | Total rows: {total} | ACL users: {len(acl_rows)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
