#!/usr/bin/env python3
"""Streamlit web dashboard for Caddy gateway usage.

Reads the hourly DuckDB snapshot so history survives access-log rotation.
Falls back to the raw access logs if the snapshot is not available yet.
"""

from __future__ import annotations

from pathlib import Path
import sys

import duckdb
import pandas as pd
import streamlit as st

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from gateway_usage_report import (  # noqa: E402
    DEFAULT_ACL,
    build_resolved_view,
    build_views,
    load_acl,
)

SNAPSHOT_DB = str(ROOT / "analytics" / "usage.duckdb")
LOG_PATTERN = str(ROOT / "logs" / "access*.log")

st.set_page_config(page_title="Gateway Usage", page_icon="📈", layout="wide")
st.title("Caddy Gateway Usage")


@st.cache_data(ttl=60, show_spinner="Reading usage snapshot...")
def load_snapshot(db_path: str) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Return events and build metadata from the scheduled DuckDB snapshot."""
    con = duckdb.connect(db_path, read_only=True)
    try:
        events = con.sql(
            """
            SELECT ts, endpoint, path, caller, role, token_hash, client_ip,
                   status, duration, size, is_probe, is_health,
                   token_hash IS NOT NULL AS has_token
            FROM events
            """
        ).df()
        meta = con.sql("SELECT built_utc, total_rows, acl_users FROM meta").df()
        return events, meta
    finally:
        con.close()


@st.cache_data(ttl=60, show_spinner="Reading access logs...")
def load_events(log_pattern: str, acl_path: str) -> pd.DataFrame:
    """Fallback: return one row per logged request with ACL-resolved names."""
    con = duckdb.connect()
    try:
        build_views(con, log_pattern, 0, True)
        load_acl(con, acl_path)
        build_resolved_view(con)
        return con.sql(
            """
            SELECT ts, endpoint, path, caller, role, token_hash, client_ip,
                   status, duration, size, is_probe, is_health,
                   gateway_token IS NOT NULL AS has_token
            FROM resolved
            """
        ).df()
    finally:
        con.close()


st.sidebar.header("Filters")
period = st.sidebar.selectbox(
    "Period",
    options=[1, 7, 30, 0],
    index=1,
    format_func=lambda d: "All time" if d == 0 else f"Last {d} day(s)",
)
include_health = st.sidebar.checkbox("Include health checks", value=False)
include_probes = st.sidebar.checkbox("Include scanner probes", value=False)
if st.sidebar.button("Refresh data"):
    st.cache_data.clear()

meta = None
if Path(SNAPSHOT_DB).is_file():
    try:
        raw, meta = load_snapshot(SNAPSHOT_DB)
    except duckdb.Error as exc:
        st.warning(f"Could not read snapshot ({exc}); using raw logs for this view.")
        raw = None
else:
    st.warning(
        "Snapshot not found. Run `python build_usage_snapshot.py` or wait for the "
        "scheduled task; using raw logs for this view."
    )
    raw = None

if raw is None:
    raw = load_events(LOG_PATTERN, DEFAULT_ACL)

if period:
    cutoff = pd.Timestamp.now(tz="UTC") - pd.Timedelta(days=period)
    raw = raw[raw["ts"] >= cutoff]
if not include_health:
    raw = raw[~raw["is_health"]]
if not include_probes:
    raw = raw[~raw["is_probe"]]

endpoints = sorted(raw["endpoint"].unique().tolist())
users = sorted(raw["caller"].unique().tolist())
chosen_endpoints = st.sidebar.multiselect("Endpoint", endpoints, default=endpoints)
chosen_users = st.sidebar.multiselect("User", users, default=users)
df = raw[raw["endpoint"].isin(chosen_endpoints) & raw["caller"].isin(chosen_users)].copy()

if meta is not None and not meta.empty:
    built = pd.to_datetime(meta.loc[0, "built_utc"], utc=True)
    age = pd.Timestamp.now(tz="UTC") - built
    source = (
        f"Snapshot: {SNAPSHOT_DB} · built {built:%Y-%m-%d %H:%M:%S UTC} "
        f"({age.total_seconds() / 60:.0f} min ago) · {int(meta.loc[0, 'total_rows']):,} events"
    )
else:
    source = f"Live logs: {LOG_PATTERN}"

if meta is not None and not meta.empty:
    age = pd.Timestamp.now(tz="UTC") - pd.to_datetime(meta.loc[0, "built_utc"], utc=True)
    if age > pd.Timedelta(hours=2):
        st.warning(f"Snapshot is {age.total_seconds() / 3600:.1f} hours old. Check the scheduled task.")

st.caption(
    source + " · Names come from the gateway ACL; `(unmapped)` means the token hash is not in the ACL."
)

if df.empty:
    st.info("No requests match the current filters.")
    st.stop()

mcp = df[df["endpoint"].str.contains("/mcp", regex=False)]
errors = df[df["status"] >= 400]

col1, col2, col3, col4, col5 = st.columns(5)
col1.metric("Requests", f"{len(df):,}")
col2.metric("ACL users", df.loc[df["has_token"] & (df["caller"] != "(unmapped)"), "caller"].nunique())
col3.metric("MCP endpoints", mcp["endpoint"].nunique())
col4.metric("4xx / 5xx", f"{len(errors):,}")
col5.metric("p95 latency", f"{df['duration'].quantile(0.95) * 1000:.0f} ms")

st.subheader("Daily requests by MCP endpoint")
daily = (
    mcp.groupby([pd.Grouper(key="ts", freq="D"), "endpoint"])
    .size()
    .unstack(fill_value=0)
)
if daily.empty:
    st.info("No MCP requests in this window.")
else:
    st.line_chart(daily)

left, right = st.columns(2)

with left:
    st.subheader("Requests by endpoint")
    st.bar_chart(df["endpoint"].value_counts())

with right:
    st.subheader("Requests by user")
    st.bar_chart(df.loc[df["has_token"], "caller"].value_counts())

st.subheader("MCP endpoint detail")
endpoint_stats = (
    mcp.groupby("endpoint")
    .agg(
        requests=("status", "size"),
        clients=("client_ip", "nunique"),
        token_hashes=("token_hash", "nunique"),
        ok_2xx=("status", lambda s: int((s < 400).sum())),
        err_4xx=("status", lambda s: int(((s >= 400) & (s < 500)).sum())),
        err_5xx=("status", lambda s: int((s >= 500).sum())),
        avg_ms=("duration", lambda s: round(s.mean() * 1000, 1)),
        p95_ms=("duration", lambda s: round(s.quantile(0.95) * 1000, 1)),
    )
    .sort_values("requests", ascending=False)
)
st.dataframe(endpoint_stats, width="stretch")

st.subheader("User detail")
user_stats = (
    df[df["has_token"]]
    .groupby(["caller", "role"])
    .agg(
        requests=("status", "size"),
        mcp_requests=("endpoint", lambda s: int(s.str.contains("/mcp", regex=False).sum())),
        mcp_endpoints=("endpoint", lambda s: int(s.str.contains("/mcp", regex=False).nunique())),
        client_ips=("client_ip", "nunique"),
        err_4xx=("status", lambda s: int(((s >= 400) & (s < 500)).sum())),
        err_5xx=("status", lambda s: int((s >= 500).sum())),
        last_seen=("ts", "max"),
    )
    .reset_index()
    .sort_values("requests", ascending=False)
)
st.dataframe(user_stats, width="stretch", hide_index=True)

with st.expander("Most recent requests"):
    st.dataframe(
        df[["ts", "endpoint", "caller", "client_ip", "status", "duration"]]
        .sort_values("ts", ascending=False)
        .head(100),
        width="stretch",
        hide_index=True,
    )
