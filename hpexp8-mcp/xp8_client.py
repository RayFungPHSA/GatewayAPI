"""Read-only HPE XP Performance Advisor 8.5 client for the HPEXP8 MCP.

All operational requests are HTTP GETs against the fixed, server-configured XP
Performance Advisor base URLs. The only POST/DELETE are the internal login and
logout calls, which are never exposed as MCP tools.

XP Performance Advisor 8.5 exposes HTTP port 80 only. This client therefore does
not claim transport encryption; credentials remain DPAPI-protected at rest and
are never accepted from MCP clients.

Every operation fans out across all configured servers by default and labels
each result with its owning server.
"""

from __future__ import annotations

import re
import time
from typing import Any, Callable
from urllib.parse import quote, urlparse

import httpx

LOGIN_PATH = "/api/auth/login"
SESSION_HEADER = "auth"
SESSION_LIFETIME_SECONDS = 10 * 60
TIMEOUT_SECONDS = 25


def enc(value: Any) -> str:
    """URL-encode a path or query value without leaving delimiters raw."""
    return quote(str(value), safe="")


class Xp8Client:
    def __init__(self, credentials: dict[str, Any]):
        self.username = credentials["username"]
        self.password = credentials["password"]
        self.servers = credentials["servers"]
        self._sessions: dict[str, dict[str, Any]] = {}
        self._client = httpx.Client(
            timeout=httpx.Timeout(TIMEOUT_SECONDS),
            headers={"accept": "application/json"},
            follow_redirects=False,
        )

    def close(self) -> None:
        self._client.close()

    def redact(self, text: str) -> str:
        result = str(text)
        for value in (self.password, *[s.get("id", "") for s in self._sessions.values()]):
            if value:
                result = result.replace(value, "[REDACTED]")
        result = re.sub(r'(\b(?:sessionID|auth)\b\s*[:=]\s*)(\S+)', r"\1[REDACTED]", result, flags=re.IGNORECASE)
        result = re.sub(r'(\b(?:password|username)\b\s*[:=]\s*)(\S+)', r"\1[REDACTED]", result, flags=re.IGNORECASE)
        return result[:300]

    def _server(self, server: str | None) -> tuple[str, str]:
        for item in self.servers:
            if server is None or item["name"].lower() == str(server).lower():
                return item["name"], item["url"]
        names = ", ".join(item["name"] for item in self.servers)
        raise ValueError(f"Unknown XP Performance Advisor server '{server}'. Available servers: {names}.")

    def for_each_server(
        self,
        operation: Callable[[str, str], Any],
        server: str | None = None,
    ) -> dict[str, Any]:
        if server is None:
            selected = list(self.servers)
        else:
            name, url = self._server(server)
            selected = [{"name": name, "url": url}]

        results: list[dict[str, Any]] = []
        failures: list[dict[str, str]] = []
        for item in selected:
            name, url = item["name"], item["url"]
            try:
                data = operation(name, url)
                results.append({"server": name, "url": url, "data": data})
            except Exception as exc:
                failures.append({"server": name, "error": self.redact(str(exc))})

        return {
            "configuredServers": len(self.servers),
            "selectedServers": len(selected),
            "onlineServers": len(results),
            "servers": results,
            "failures": failures,
        }

    def _login(self, name: str, base_url: str, force: bool = False) -> str:
        cached = self._sessions.get(name)
        if (
            not force
            and cached
            and cached.get("id")
            and time.time() < float(cached.get("expiresAt", 0))
        ):
            return str(cached["id"])

        response = self._client.post(
            base_url + LOGIN_PATH,
            json={
                "username": self.username,
                "password": self.password,
                "authLoginDomain": "0",
                "loginMsgAck": False,
            },
            headers={"content-type": "application/json"},
        )
        if not response.is_success:
            raise RuntimeError(f"XP Performance Advisor login failed (HTTP {response.status_code}).")
        try:
            session_id = response.json().get("sessionID")
        except Exception:
            session_id = None
        if not isinstance(session_id, str) or not session_id:
            raise RuntimeError("XP Performance Advisor login did not return a session ID.")
        self._sessions[name] = {
            "id": session_id,
            "expiresAt": time.time() + SESSION_LIFETIME_SECONDS - 30,
        }
        return session_id

    def _get(self, name: str, base_url: str, path: str, retry: bool = True) -> Any:
        if not path.startswith("/api/"):
            raise ValueError("Only allowlisted /api/ GET paths are supported.")
        session_id = self._login(name, base_url)
        response = self._client.get(
            base_url + path,
            headers={SESSION_HEADER: session_id},
        )
        if retry and response.status_code in (401, 403):
            self._login(name, base_url, force=True)
            return self._get(name, base_url, path, retry=False)
        if not response.is_success:
            raise RuntimeError(f"XP Performance Advisor GET {path} failed (HTTP {response.status_code}).")
        text = response.text
        if not text:
            return None
        try:
            return response.json()
        except Exception:
            return text[:5000]

    @staticmethod
    def parse_array_label(label: str) -> dict[str, str]:
        text = str(label)
        match = re.match(r"^([^()]+)\(([^()]*)\)\(([^()]*)\)$", text)
        if match:
            return {
                "serial": match.group(1).strip(),
                "name": match.group(2).strip(),
                "model": match.group(3).strip(),
                "label": text,
            }
        return {"label": text}

    @staticmethod
    def normalise_arrays(values: Any) -> list[dict[str, str]]:
        rows = values if isinstance(values, list) else (values or {}).get("items", [])
        if not isinstance(rows, list):
            return []
        result = []
        for row in rows:
            if isinstance(row, dict):
                label = str(row.get("label") or row.get("name") or "")
                parsed = Xp8Client.parse_array_label(label) if label else {}
                parsed.update({k: str(row[k]) for k in ("serial", "name", "model", "label") if row.get(k) is not None})
                if parsed:
                    result.append(parsed)
            elif row:
                result.append(Xp8Client.parse_array_label(row))
        return result

    def array_filter(self, name: str, base_url: str) -> list[dict[str, str]]:
        return self.normalise_arrays(self._get(name, base_url, "/api/index/arrayfilter"))

    def resolve_array(self, name: str, base_url: str, identity: str | None) -> dict[str, str]:
        arrays = self.array_filter(name, base_url)
        if not identity:
            raise ValueError("An array identity is required for this tool.")
        wanted = str(identity).strip().lower()
        for array in arrays:
            if any(str(array.get(key, "")).lower() == wanted for key in ("label", "serial", "name")):
                return array
        raise ValueError(f"XP Performance Advisor array '{identity}' was not found on {name}.")

    def connection_status(self, server: str | None = None) -> dict[str, Any]:
        def operation(name: str, base_url: str) -> dict[str, Any]:
            response = self._client.get(base_url + "/", follow_redirects=False)
            parsed = urlparse(base_url)
            return {
                "reachable": response.is_success or response.status_code in (301, 302),
                "httpStatus": response.status_code,
                "host": parsed.netloc,
                "transportEncrypted": parsed.scheme == "https",
            }

        return self.for_each_server(operation, server)

    def auth_status(self, server: str | None = None, refresh: bool = False) -> dict[str, Any]:
        def operation(name: str, base_url: str) -> dict[str, Any]:
            self._login(name, base_url, force=refresh)
            authorization = self._get(name, base_url, "/api/auth/authz/category-actions")
            parsed = urlparse(base_url)
            return {
                "authenticated": True,
                "authorizationAvailable": bool(authorization),
                "transportEncrypted": parsed.scheme == "https",
            }

        return self.for_each_server(operation, server)

    def list_arrays(self, server: str | None = None) -> dict[str, Any]:
        return self.for_each_server(self.array_filter, server)

    def _array_operation(
        self,
        server: str | None,
        array: str | None,
        path_builder: Callable[[dict[str, str]], str],
    ) -> dict[str, Any]:
        def operation(name: str, base_url: str) -> dict[str, Any]:
            arrays = [self.resolve_array(name, base_url, array)] if array else self.array_filter(name, base_url)
            if not arrays:
                raise ValueError("No XP arrays are registered on this server.")
            results = []
            for entry in arrays:
                path = path_builder(entry)
                results.append({"array": entry, "data": self._get(name, base_url, path)})
            return {"arrays": results}

        return self.for_each_server(operation, server)

    def array_details(self, server: str | None = None, array: str | None = None) -> dict[str, Any]:
        return self._array_operation(
            server,
            array,
            lambda a: "/api/arraydashboardservice/arrayDetailedView/array/" + enc(a["label"]),
        )

    def array_capacity(self, server: str | None = None, array: str | None = None) -> dict[str, Any]:
        return self._array_operation(
            server,
            array,
            lambda a: "/api/arraydashboardservice/capacityview/array/" + enc(a["label"]),
        )

    def array_components(
        self,
        server: str | None = None,
        array: str | None = None,
        status: str = "",
        category: str = "",
    ) -> dict[str, Any]:
        def path_builder(a: dict[str, str]) -> str:
            return (
                "/api/arraydashboardservice/componentview/getcomponents"
                f"?array={enc(a['label'])}&status={enc(status)}&category={enc(category)}"
            )

        return self._array_operation(server, array, path_builder)

    def array_ldevs(
        self,
        server: str | None,
        array: str | None,
        start_time: str,
        end_time: str,
        metric: str,
        status: str,
    ) -> dict[str, Any]:
        def path_builder(a: dict[str, str]) -> str:
            params = {
                "array": a["label"],
                "starttime": start_time,
                "endtime": end_time,
                "metric": metric,
                "status": status,
            }
            encoded = httpx.QueryParams(params)
            return "/api/arraydashboardservice/metricview/getldevs?" + str(encoded)

        return self._array_operation(server, array, path_builder)

    def array_replication(self, server: str | None = None, array: str | None = None) -> dict[str, Any]:
        return self._array_operation(
            server,
            array,
            lambda a: "/api/arraydashboardservice/replicationview/array/" + enc(a["serial"]),
        )

    def database_summary(self, server: str | None = None) -> dict[str, Any]:
        return self.for_each_server(lambda name, base: self._get(name, base, "/api/database/dbsummary"), server)

    def event_history(
        self,
        server: str | None = None,
        severity: str = "",
        limit: int = 100,
    ) -> dict[str, Any]:
        def operation(name: str, base_url: str) -> dict[str, Any]:
            events = self._get(name, base_url, "/api/eventlog/getevent")
            rows = events if isinstance(events, list) else (events or {}).get("items", [])
            if not isinstance(rows, list):
                rows = []
            if severity:
                rows = [row for row in rows if str((row or {}).get("severity", "")).lower() == str(severity).lower()]
            return {
                "total": len(rows),
                "returned": min(len(rows), limit),
                "events": rows[:limit],
            }

        return self.for_each_server(operation, server)
