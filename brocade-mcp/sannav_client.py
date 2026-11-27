"""Read-only Brocade SANnav REST API client for the Brocade MCP.

All operational requests are HTTP GETs against the fixed, server-configured
SANnav endpoint. Authentication uses documented session-less HTTP Basic auth on
the official ``/external-api/v1`` API; there is no login POST and no session to
refresh.

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
from urllib.parse import parse_qsl, urlencode, urlsplit

import httpx

API_ROOT = "/external-api/v1"
PAGE_SIZE = 5000
MAX_PAGES = 100
TIMEOUT_SECONDS = 120


def contains(value: Any, needle: str) -> bool:
    return needle.lower() in str(value or "").lower()


class SanNavClient:
    def __init__(self, credentials: dict[str, Any]):
        self.username = credentials["username"]
        self.password = credentials["password"]
        self.server = credentials["server"]
        self.base_url = self.server["url"]
        self._auth = httpx.BasicAuth(self.username, self.password)
        self._client = httpx.Client(
            timeout=httpx.Timeout(TIMEOUT_SECONDS),
            headers={
                "accept": "application/json",
                "content-type": "application/json",
            },
            follow_redirects=False,
            verify=False,
        )

    def close(self) -> None:
        self._client.close()

    def redact(self, text: str) -> str:
        result = str(text)
        if self.password:
            result = result.replace(self.password, "[REDACTED]")
        result = re.sub(r'(\b(?:sessionId|sessionID|auth)\b\s*[:=]\s*)(\S+)', r"\1[REDACTED]", result, flags=re.IGNORECASE)
        result = re.sub(r'(\b(?:password|username)\b\s*[:=]\s*)(\S+)', r"\1[REDACTED]", result, flags=re.IGNORECASE)
        result = re.sub(r"Basic\s+\S+", "Basic [REDACTED]", result, flags=re.IGNORECASE)
        return result[:400]

    @staticmethod
    def _validate_path(path: str) -> str:
        parts = urlsplit(path)
        if (
            parts.scheme
            or parts.netloc
            or not parts.path.startswith(API_ROOT + "/")
            or ".." in parts.path
            or "//" in parts.path
        ):
            raise ValueError("Only allowlisted SANnav external API GET paths are supported.")
        return parts.path

    def _get(self, path: str) -> Any:
        self._validate_path(path)
        response = self._client.get(self.base_url + path, auth=self._auth)
        if not response.is_success:
            raise RuntimeError(f"SANnav GET {path} failed (HTTP {response.status_code}).")
        text = response.text
        if not text:
            return None
        try:
            return response.json()
        except Exception:
            return text[:10000]

    def _paged_rows(self, path: str, key: str) -> list[dict[str, Any]]:
        """Fetch every page of a documented SANnav collection endpoint."""
        parts = urlsplit(path)
        params = dict(parse_qsl(parts.query, keep_blank_values=True))
        params.setdefault("numOfRecords", str(PAGE_SIZE))
        start_index = int(params.get("startIndex") or 0)
        rows: list[dict[str, Any]] = []

        for _ in range(MAX_PAGES):
            page_params = dict(params)
            page_params["startIndex"] = str(start_index)
            page_path = parts.path + "?" + urlencode(page_params)
            data = self._get(page_path)
            rows.extend(self._rows(data, key))
            if not isinstance(data, dict):
                break
            if not data.get("numOfEntitiesNotReturned"):
                break
            try:
                next_index = int(data.get("startIndexToUse"))
            except (TypeError, ValueError):
                break
            if next_index <= start_index:
                break
            start_index = next_index
        return rows

    def connection_status(self) -> dict[str, Any]:
        try:
            response = self._client.get(
                self.base_url + API_ROOT + "/about/",
                auth=self._auth,
            )
            reachable = response.is_success or response.status_code in (301, 302, 401, 403, 405)
            status: dict[str, Any] = {
                "reachable": reachable,
                "httpStatus": response.status_code,
                "host": self.server["host"],
                "port": self.server["port"],
                "transportEncrypted": True,
            }
            if response.is_success:
                try:
                    status["apiVersion"] = response.json().get("version")
                except Exception:
                    pass
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

    @staticmethod
    def _port_name(row: dict[str, Any]) -> str:
        for key in ("fdmiHostName", "autoEnclosureName", "deviceEnclosureName", "zoneAlias", "wwn"):
            value = str(row.get(key) or "").strip()
            if value:
                return value
        return ""

    @staticmethod
    def _normalize_port(row: dict[str, Any], kind: str) -> dict[str, Any]:
        normalized = dict(row)
        name = SanNavClient._port_name(row)
        normalized["name"] = row.get("switchPortName") or row.get("wwn") or row.get("id")
        normalized["hostName"] = name if kind == "host" else row.get("fdmiHostName")
        normalized["storageName"] = name if kind == "storage" else row.get("fdmiHostName")
        normalized["wwn"] = row.get("wwn") or row.get("physicalPortWwn")
        normalized["connectedSwitchName"] = row.get("switchName")
        normalized["connectedSwitchPortName"] = row.get("switchPortName")
        normalized["connectedPortNumber"] = row.get("portNumber")
        normalized["portRole"] = row.get("portRole")
        normalized["activeFC4Types"] = row.get("activeFC4Types") or row.get("type")
        normalized["health"] = row.get("health")
        normalized["status"] = row.get("status")
        return normalized

    def _entities_from_ports(self, rows: list[dict[str, Any]], kind: str) -> list[dict[str, Any]]:
        name_key = "hostName" if kind == "host" else "storageName"
        grouped: dict[str, dict[str, Any]] = {}
        for row in rows:
            name = str(row.get(name_key) or "").strip()
            if not name:
                continue
            entry = grouped.setdefault(
                name,
                {
                    "id": row.get("deviceNodeWwn") or row.get("wwn"),
                    "name": name,
                    "health": row.get("health"),
                    "type": kind,
                    "portCount": 0,
                    "guid": row.get("deviceNodeWwn") or row.get("wwn"),
                    "fabrics": set(),
                },
            )
            entry["portCount"] += 1
            fabric = row.get("fabricName")
            if fabric:
                entry["fabrics"].add(str(fabric))
        return [
            {
                "id": entry["id"],
                "name": entry["name"],
                "health": entry["health"],
                "type": entry["type"],
                "portCount": entry["portCount"],
                "guid": entry["guid"],
                "fabrics": sorted(entry["fabrics"]),
            }
            for entry in grouped.values()
        ]

    # -- Raw read-only endpoints -------------------------------------------------

    def _fabrics(self) -> list[dict[str, Any]]:
        return self._paged_rows(API_ROOT + "/inventory/fabrics/?basicOnly=0", "fabrics")

    def _switches(self) -> list[dict[str, Any]]:
        switches = self._paged_rows(API_ROOT + "/inventory/switches/?basicOnly=0", "switches")
        for switch in switches:
            if not switch.get("fabrics"):
                fabric = switch.get("fabricName")
                switch["fabrics"] = [fabric] if fabric else []
            switch["switchName"] = switch.get("name") or switch.get("physicalSwitchName")
            switch["model"] = switch.get("manufacturerModel") or switch.get("modelNumber")
            switch["switchWwn"] = switch.get("physicalSwitchWwn") or switch.get("wwn")
        return switches

    def _device_ports(self, kind: str) -> list[dict[str, Any]]:
        rows = self._paged_rows(
            API_ROOT + f"/inventory/deviceports/?type={kind}&basicOnly=0",
            "DevicePorts",
        )
        return [self._normalize_port(row, kind) for row in rows]

    def _host_ports(self) -> list[dict[str, Any]]:
        return self._device_ports("host")

    def _storage_ports(self) -> list[dict[str, Any]]:
        return self._device_ports("storage")

    def _hosts(self) -> list[dict[str, Any]]:
        return self._entities_from_ports(self._host_ports(), "host")

    def _storages(self) -> list[dict[str, Any]]:
        return self._entities_from_ports(self._storage_ports(), "storage")

    # -- Named tools -------------------------------------------------------------

    def auth_status(self, refresh: bool = False) -> dict[str, Any]:
        del refresh
        response = self._client.get(self.base_url + API_ROOT + "/about/", auth=self._auth)
        if not response.is_success:
            raise RuntimeError(f"SANnav authentication check failed (HTTP {response.status_code}).")
        return self.wrap(
            {
                "authenticated": True,
                "authMode": "session-less basic",
                "transportEncrypted": True,
            }
        )

    def list_fabrics(self) -> dict[str, Any]:
        def summary(f: dict[str, Any]) -> dict[str, Any]:
            last = f.get("lastFabricChanged") or f.get("lastDiscovery")
            try:
                last = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(last) / 1000)) if last else None
            except (TypeError, ValueError):
                pass
            return {
                "id": f.get("id"),
                "name": f.get("name"),
                "health": f.get("health"),
                "status": f.get("status"),
                "seedSwitchIP": f.get("seedSwitchIpAddress") or f.get("seedSwitchIP"),
                "seedSwitchName": f.get("seedSwitchName"),
                "firmwareVersion": f.get("seedSwitchFirmwareVersion"),
                "switchCount": f.get("switchCount"),
                "agCount": f.get("agCount"),
                "activeZone": f.get("activeZonesetName") or f.get("activeZone"),
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
                "truFOSStatus": s.get("truFosStatus"),
            }
            for s in switches
        ]
        return self.wrap({"total": len(result), "switches": result})

    def list_hosts(self, fabric: str = "", health: str = "", search: str = "") -> dict[str, Any]:
        hosts = self._hosts()
        if fabric:
            hosts = [h for h in hosts if any(contains(f, fabric) for f in (h.get("fabrics") or []))]
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
        host_ports = self._host_ports()
        storage_ports = self._storage_ports()
        hosts = self._entities_from_ports(host_ports, "host")
        storages = self._entities_from_ports(storage_ports, "storage")
        return self.wrap(
            {
                "fabrics": {"total": len(fabrics), "health": dict(Counter(str(f.get("health") or "Unknown") for f in fabrics))},
                "switches": {
                    "total": len(switches),
                    "firmwareVersions": dict(Counter(str(s.get("firmwareVersion") or "Unknown") for s in switches)),
                },
                "hosts": {"total": len(hosts), "health": dict(Counter(str(h.get("health") or "Unknown") for h in hosts))},
                "storages": {"total": len(storages), "health": dict(Counter(str(s.get("health") or "Unknown") for s in storages))},
                "totalHostPorts": len(host_ports),
                "totalStoragePorts": len(storage_ports),
            }
        )
