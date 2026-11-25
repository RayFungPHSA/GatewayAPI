"""Read-only Brocade SANnav REST API client for the Brocade MCP.

All operational requests are HTTP GETs against the fixed, server-configured
SANnav endpoint. The only POST is the internal login call, which is never
exposed as an MCP tool.

SANnav uses self-signed certificates, so TLS verification is disabled only for
the configured HTTPS endpoint. Client-supplied URLs and credentials are never
accepted.

Every tool fans out against the single configured SANnav instance and returns
the same shape as the other gateway MCPs, with an owning server label.
"""

from __future__ import annotations

import re
import time
from collections import Counter
from typing import Any
from urllib.parse import quote

import httpx

LOGIN_PATH = "/auth/login"
SESSION_LIFETIME_SECONDS = 5 * 60
TIMEOUT_SECONDS = 120


def enc(value: Any) -> str:
    """URL-encode a path segment value."""
    return quote(str(value), safe="")


def contains(value: Any, needle: str) -> bool:
    return needle.lower() in str(value or "").lower()


class SanNavClient:
    def __init__(self, credentials: dict[str, Any]):
        self.username = credentials["username"]
        self.password = credentials["password"]
        self.server = credentials["server"]
        self.base_url = self.server["url"]
        self._session_id: str | None = None
        self._expires_at = 0.0
        self._client = httpx.Client(
            timeout=httpx.Timeout(TIMEOUT_SECONDS),
            headers={
                "accept": "application/json",
                "content-type": "application/json",
                "initiator": "SANNAV_UI",
            },
            follow_redirects=False,
            verify=False,
        )

    def close(self) -> None:
        self._client.close()

    def redact(self, text: str) -> str:
        result = str(text)
        for value in (self.password, self._session_id):
            if value:
                result = result.replace(value, "[REDACTED]")
        result = re.sub(r'(\b(?:sessionId|sessionID|auth)\b\s*[:=]\s*)(\S+)', r"\1[REDACTED]", result, flags=re.IGNORECASE)
        result = re.sub(r'(\b(?:password|username)\b\s*[:=]\s*)(\S+)', r"\1[REDACTED]", result, flags=re.IGNORECASE)
        result = re.sub(r"Basic\s+\S+", "Basic [REDACTED]", result, flags=re.IGNORECASE)
        return result[:400]

    def _login(self, force: bool = False) -> str:
        if not force and self._session_id and time.time() < self._expires_at:
            return self._session_id

        basic = httpx.BasicAuth(self.username, self.password)
        response = self._client.post(self.base_url + LOGIN_PATH, auth=basic)
        if not response.is_success:
            raise RuntimeError(f"SANnav login failed (HTTP {response.status_code}).")
        try:
            session_id = response.json().get("sessionId")
        except Exception:
            session_id = None
        if not isinstance(session_id, str) or not session_id:
            raise RuntimeError("SANnav login did not return a session ID.")
        self._session_id = session_id
        self._expires_at = time.time() + SESSION_LIFETIME_SECONDS - 30
        return session_id

    def _get(self, path: str, retry: bool = True) -> Any:
        if not path.startswith("/") or "//" in path:
            raise ValueError("Only allowlisted SANnav GET paths are supported.")
        session_id = self._login()
        response = self._client.get(
            self.base_url + path,
            headers={"Authorization": session_id},
        )
        if retry and response.status_code in (401, 403):
            self._login(force=True)
            return self._get(path, retry=False)
        if not response.is_success:
            raise RuntimeError(f"SANnav GET {path} failed (HTTP {response.status_code}).")
        text = response.text
        if not text:
            return None
        try:
            return response.json()
        except Exception:
            return text[:10000]

    def connection_status(self) -> dict[str, Any]:
        try:
            response = self._client.get(self.base_url + "/", follow_redirects=False)
            reachable = response.is_success or response.status_code in (301, 302, 401, 403, 405)
            status: dict[str, Any] = {
                "reachable": reachable,
                "httpStatus": response.status_code,
                "host": self.server["host"],
                "port": self.server["port"],
                "transportEncrypted": True,
            }
        except Exception as exc:
            status = {
                "reachable": False,
                "error": self.redact(str(exc)),
                "host": self.server["host"],
                "port": self.server["port"],
                "transportEncrypted": True,
            }
        return self.wrap(status)

    def wrap(self, data: Any) -> dict[str, Any]:
        """Return the standard gateway fan-out envelope."""
        return {
            "configuredServers": 1,
            "selectedServers": 1,
            "onlineServers": 1,
            "servers": [
                {
                    "server": self.server["name"],
                    "url": self.server["url"],
                    "data": data,
                }
            ],
            "failures": [],
        }

    @staticmethod
    def _rows(value: Any, key: str | None = None) -> list[dict[str, Any]]:
        if isinstance(value, list):
            return [row for row in value if isinstance(row, dict)]
        if isinstance(value, dict):
            rows = value.get(key) if key else value
            if isinstance(rows, list):
                return [row for row in rows if isinstance(row, dict)]
        return []

    # -- Raw read-only endpoints -------------------------------------------------

    def _fabrics(self) -> list[dict[str, Any]]:
        return self._rows(self._get("/inventory/fabrics"))

    def _switches(self) -> list[dict[str, Any]]:
        return self._rows(self._get("/firmwaremanagement/switches"), "switchObject")

    def _hosts(self) -> list[dict[str, Any]]:
        return self._rows(self._get("/inventory/hosts"))

    def _storages(self) -> list[dict[str, Any]]:
        return self._rows(self._get("/inventory/storages"))

    def _host_ports(self) -> list[dict[str, Any]]:
        return self._rows(self._get("/inventory/fabrics/All/hosts/All/ports"))

    def _storage_ports(self) -> list[dict[str, Any]]:
        return self._rows(self._get("/inventory/fabrics/ALL/storages/All/ports"))

    # -- Named tools -------------------------------------------------------------

    def auth_status(self, refresh: bool = False) -> dict[str, Any]:
        self._login(force=refresh)
        return self.wrap(
            {
                "authenticated": True,
                "privilegesAvailable": True,
                "transportEncrypted": True,
            }
        )

    def list_fabrics(self) -> dict[str, Any]:
        def summary(f: dict[str, Any]) -> dict[str, Any]:
            last = f.get("lastDiscovery")
            try:
                last = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(last) / 1000)) if last else None
            except (TypeError, ValueError):
                pass
            return {
                "id": f.get("id"),
                "name": f.get("name"),
                "health": f.get("health"),
                "status": f.get("status"),
                "seedSwitchIP": f.get("seedSwitchIP"),
                "seedSwitchName": f.get("seedSwitchName"),
                "firmwareVersion": f.get("seedSwitchFirmwareVersion"),
                "switchCount": f.get("switchCount"),
                "agCount": f.get("agCount"),
                "activeZone": f.get("activeZone"),
                "lastDiscovery": last,
            }

        fabrics = self._fabrics()
        return self.wrap({"total": len(fabrics), "fabrics": [summary(f) for f in fabrics]})

    def list_switches(self, fabric: str = "") -> dict[str, Any]:
        switches = self._switches()
        if fabric:
            switches = [s for s in switches if any(contains(f, fabric) for f in (s.get("fabrics") or []))]
        result = [
            {
                "name": s.get("switchName"),
                "ipAddress": s.get("ipAddress"),
                "model": s.get("model"),
                "firmwareVersion": s.get("firmwareVersion"),
                "wwn": s.get("switchWwn"),
                "fabrics": s.get("fabrics"),
                "callHomeEnabled": s.get("callHomeEnabled"),
                "truFOSStatus": s.get("truFOSStatus"),
            }
            for s in switches
        ]
        return self.wrap({"total": len(result), "switches": result})

    def list_hosts(self, fabric: str = "", health: str = "", search: str = "") -> dict[str, Any]:
        hosts = self._hosts()
        if search:
            hosts = [h for h in hosts if contains(h.get("name"), search)]
        if health:
            hosts = [h for h in hosts if contains(h.get("health"), health)]
        result = [
            {
                "id": h.get("id"),
                "name": h.get("name"),
                "health": h.get("health"),
                "type": h.get("type"),
                "portCount": h.get("portCount"),
                "guid": h.get("guid"),
            }
            for h in hosts
        ]
        return self.wrap({"total": len(result), "hosts": result})

    def list_storages(self, health: str = "", search: str = "") -> dict[str, Any]:
        storages = self._storages()
        if search:
            storages = [s for s in storages if contains(s.get("name"), search)]
        if health:
            storages = [s for s in storages if contains(s.get("health"), health)]
        result = [
            {
                "id": s.get("id"),
                "name": s.get("name"),
                "health": s.get("health"),
                "type": s.get("type"),
                "portCount": s.get("portCount"),
                "guid": s.get("guid"),
            }
            for s in storages
        ]
        return self.wrap({"total": len(result), "storages": result})

    def list_host_ports(self, fabric: str = "", host: str = "", port_role: str = "") -> dict[str, Any]:
        ports = self._host_ports()
        if fabric:
            ports = [p for p in ports if contains(p.get("fabricName"), fabric)]
        if host:
            ports = [p for p in ports if contains(p.get("hostName"), host)]
        if port_role:
            ports = [p for p in ports if contains(p.get("portRole"), port_role)]
        fields = (
            "name", "hostName", "wwn", "fabricName", "connectedSwitchName",
            "connectedSwitchPortName", "connectedPortNumber", "portRole",
            "speed", "health", "status",
        )
        result = [{field: p.get(field) for field in fields} for p in ports]
        return self.wrap({"total": len(result), "ports": result})

    def list_storage_ports(self, fabric: str = "", storage: str = "") -> dict[str, Any]:
        ports = self._storage_ports()
        if fabric:
            ports = [p for p in ports if contains(p.get("fabricName"), fabric)]
        if storage:
            ports = [p for p in ports if contains(p.get("storageName"), storage)]
        fields = (
            "name", "storageName", "wwn", "fabricName", "connectedSwitchName",
            "connectedSwitchPortName", "portRole", "type", "activeFC4Types",
            "speed", "health", "status", "zoneAlias", "activeZones",
        )
        result = [{field: p.get(field) for field in fields} for p in ports]
        return self.wrap({"total": len(result), "ports": result})

    def list_zones(self, fabric: str = "") -> dict[str, Any]:
        zones: dict[str, dict[str, Any]] = {}
        for port in self._host_ports() + self._storage_ports():
            fabric_name = str(port.get("fabricName") or "")
            if fabric and not contains(fabric_name, fabric):
                continue
            for zone in port.get("activeZones") or []:
                key = f"{fabric_name}|{zone}"
                entry = zones.setdefault(key, {"fabric": fabric_name, "members": []})
                alias = str(port.get("zoneAlias") or port.get("name") or "unknown")
                if alias not in entry["members"]:
                    entry["members"].append(alias)
        result = [
            {
                "zone": key.split("|", 1)[1],
                "fabric": entry["fabric"],
                "memberCount": len(entry["members"]),
                "members": entry["members"],
            }
            for key, entry in zones.items()
        ]
        return self.wrap({"totalZones": len(result), "zones": result})

    def get_connectivity_map(self, fabric: str = "", host: str = "", storage: str = "") -> dict[str, Any]:
        host_ports = self._host_ports()
        storage_ports = self._storage_ports()
        if fabric:
            host_ports = [p for p in host_ports if contains(p.get("fabricName"), fabric)]
            storage_ports = [p for p in storage_ports if contains(p.get("fabricName"), fabric)]
        if host:
            host_ports = [p for p in host_ports if contains(p.get("hostName"), host)]
        if storage:
            storage_ports = [p for p in storage_ports if contains(p.get("storageName"), storage)]

        connections = []
        for hp in host_ports:
            hp_zones = set(hp.get("activeZones") or [])
            for sp in storage_ports:
                if sp.get("fabricName") != hp.get("fabricName"):
                    continue
                if sp.get("connectedSwitchName") != hp.get("connectedSwitchName"):
                    continue
                if not hp_zones.intersection(sp.get("activeZones") or []):
                    continue
                connections.append(
                    {
                        "host": hp.get("hostName"),
                        "hostPort": hp.get("name"),
                        "hostWwn": hp.get("wwn"),
                        "storage": sp.get("storageName"),
                        "storagePort": sp.get("name"),
                        "switchName": hp.get("connectedSwitchName"),
                        "switchPort": hp.get("connectedSwitchPortName"),
                        "fabric": hp.get("fabricName"),
                    }
                )
        return self.wrap({"totalConnections": len(connections), "connections": connections})

    def get_overview(self) -> dict[str, Any]:
        fabrics = self._fabrics()
        switches = self._switches()
        hosts = self._hosts()
        storages = self._storages()
        return self.wrap(
            {
                "fabrics": {"total": len(fabrics), "health": dict(Counter(str(f.get("health") or "Unknown") for f in fabrics))},
                "switches": {
                    "total": len(switches),
                    "firmwareVersions": dict(Counter(str(s.get("firmwareVersion") or "Unknown") for s in switches)),
                },
                "hosts": {"total": len(hosts), "health": dict(Counter(str(h.get("health") or "Unknown") for h in hosts))},
                "storages": {"total": len(storages), "health": dict(Counter(str(s.get("health") or "Unknown") for s in storages))},
                "totalHostPorts": len(self._host_ports()),
                "totalStoragePorts": len(self._storage_ports()),
            }
        )
