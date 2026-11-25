"""Read-only HPE 3PAR / Alletra WSAPI client for the 3PARLegacy MCP.

All upstream calls are HTTPS GETs. The only POST is the session-key request,
which uses the server-side DPAPI credential and is never exposed as an MCP
tool. Every operation fans out across all configured arrays by default.
"""

from __future__ import annotations

import re
from typing import Any

import httpx

SESSION_HEADER = "X-HP3PAR-WSAPI-SessionKey"
CREDENTIALS_PATH = "/api/v1/credentials"
TIMEOUT_SECONDS = 12


class ThreeparClient:
    def __init__(self, credentials: dict[str, Any]):
        self.username = credentials["username"]
        self.password = credentials["password"]
        self.servers = credentials["servers"]
        self._sessions: dict[str, str] = {}
        self._client = httpx.Client(
            verify=False,
            timeout=httpx.Timeout(TIMEOUT_SECONDS),
            headers={"Accept": "application/json"},
        )

    def close(self) -> None:
        self._client.close()

    def redact(self, text: str) -> str:
        """Remove credential and session values from error text."""
        result = str(text)
        for value in (self.password, *self._sessions.values()):
            if value:
                result = result.replace(value, "[REDACTED]")
        result = re.sub(r'("?key"?\s*:\s*")[^"]+', r"\1[REDACTED]", result, flags=re.IGNORECASE)
        return result[:300]

    def _array(self, name: str | None) -> tuple[str, str]:
        for server in self.servers:
            if name is None or server["name"].lower() == str(name).lower():
                return server["name"], server["url"]
        available = ", ".join(s["name"] for s in self.servers)
        raise ValueError(f"Unknown 3PAR array '{name}'. Available arrays: {available}.")

    def _session_key(self, name: str, base_url: str) -> str:
        cached = self._sessions.get(name)
        if cached:
            return cached
        response = self._client.post(
            base_url + CREDENTIALS_PATH,
            json={"user": self.username, "password": self.password},
            headers={"Content-Type": "application/json"},
        )
        if response.status_code not in (200, 201):
            raise RuntimeError(
                f"Session creation failed with HTTP {response.status_code}: "
                + self.redact(response.text)
            )
        try:
            key = response.json().get("key")
        except Exception:
            key = None
        if not isinstance(key, str) or not key:
            raise RuntimeError("Session creation did not return a session key.")
        self._sessions[name] = key
        return key

    def _get(self, name: str, base_url: str, path: str, *, retry_auth: bool = True) -> Any:
        key = self._session_key(name, base_url)
        if not path.startswith("/api/v1/"):
            raise ValueError("Only /api/v1/ GET paths are supported.")
        response = self._client.get(
            base_url + path,
            headers={SESSION_HEADER: key},
        )
        # WSAPI session keys expire. A long-running bridge must discard the
        # cached key and authenticate once more rather than failing forever.
        if (
            retry_auth
            and response.status_code == 403
            and "invalid session key" in response.text.lower()
        ):
            self._sessions.pop(name, None)
            return self._get(name, base_url, path, retry_auth=False)
        if response.status_code != 200:
            raise RuntimeError(
                f"GET {path} failed with HTTP {response.status_code}: "
                + self.redact(response.text)
            )
        try:
            return response.json()
        except Exception:
            return {"raw": response.text[:2000]}

    def across_arrays(self, path: str, array: str | None = None) -> dict[str, Any]:
        """Run one GET for each selected array and collect per-array results."""
        if array is None:
            selected = list(self.servers)
        else:
            name, url = self._array(array)
            selected = [{"name": name, "url": url}]

        results: list[dict[str, Any]] = []
        failures: list[dict[str, str]] = []
        for server in selected:
            name, url = server["name"], server["url"]
            try:
                key = self._session_key(name, url)
                data = self._get(name, url, path)
                results.append(
                    {
                        "array": name,
                        "url": url,
                        "sessionKeyFingerprint": self._fingerprint(key),
                        "data": data,
                    }
                )
            except Exception as exc:
                failures.append({"array": name, "error": self.redact(str(exc))})

        # Return a structured result even when every array is unreachable so
        # firewall-pending arrays are reported instead of surfacing as tool errors.
        return {
            "path": path,
            "configuredArrays": len(self.servers),
            "selectedArrays": len(selected),
            "onlineArrays": len(results),
            "arrays": results,
            "failures": failures,
        }

    @staticmethod
    def _fingerprint(value: str) -> str:
        import hashlib

        return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]

    def connection_status(self, array: str | None = None) -> dict[str, Any]:
        payload = self.across_arrays("/api/v1/system", array)
        summaries = []
        keep = (
            "id",
            "name",
            "systemVersion",
            "IPv4Addr",
            "model",
            "serialNumber",
            "totalNodes",
            "clusterNodes",
            "location",
            "owner",
            "contact",
            "comment",
        )
        for entry in payload["arrays"]:
            data = entry["data"]
            if isinstance(data, dict):
                system = {key: data.get(key) for key in keep if key in data}
            else:
                system = {"value": data}
            summaries.append(
                {
                    "array": entry["array"],
                    "url": entry["url"],
                    "sessionKeyFingerprint": entry["sessionKeyFingerprint"],
                    "system": system,
                }
            )
        return {
            "configuredArrays": payload["configuredArrays"],
            "selectedArrays": payload["selectedArrays"],
            "onlineArrays": payload["onlineArrays"],
            "arrays": summaries,
            "failures": payload["failures"],
        }

    def inventory_summary(self, array: str | None = None) -> dict[str, Any]:
        paths = {
            "cpgs": "/api/v1/cpgs",
            "volumes": "/api/v1/volumes",
            "volumeSets": "/api/v1/volumesets",
            "hosts": "/api/v1/hosts",
            "hostSets": "/api/v1/hostsets",
            "ports": "/api/v1/ports",
        }
        summary: dict[str, Any] = {
            "configuredArrays": len(self.servers),
            "arrays": [],
            "failures": [],
        }
        selected = [s for s in self.servers if array is None or s["name"].lower() == str(array).lower()]
        if not selected:
            self._array(array)
        for server in selected:
            name, url = server["name"], server["url"]
            counts: dict[str, Any] = {"array": name}
            array_failures: list[str] = []
            for label, path in paths.items():
                try:
                    data = self._get(name, url, path)
                    if isinstance(data, dict) and "total" in data:
                        counts[label] = data["total"]
                    elif isinstance(data, list):
                        counts[label] = len(data)
                    else:
                        counts[label] = None
                except Exception as exc:
                    array_failures.append(f"{label}: {self.redact(str(exc))}")
            if array_failures:
                summary["failures"].append({"array": name, "error": "; ".join(array_failures)})
            summary["arrays"].append(counts)
        if not summary["arrays"]:
            raise RuntimeError("No 3PAR array was selected for inventory summary.")
        return summary


READ_ONLY_PATHS = {
    "threepar_list_cpgs": "/api/v1/cpgs",
    "threepar_list_volumes": "/api/v1/volumes",
    "threepar_list_volume_sets": "/api/v1/volumesets",
    "threepar_list_hosts": "/api/v1/hosts",
    "threepar_list_host_sets": "/api/v1/hostsets",
    "threepar_list_ports": "/api/v1/ports",
    "threepar_list_users": "/api/v1/users",
    "threepar_capacity_summary": "/api/v1/capacity",
}
