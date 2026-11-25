import fs from "node:fs";
import https from "node:https";
import { loadVsphereCredentials } from "./credentials.mjs";

const encodeBasic = (username, password) => Buffer.from(`${username}:${password}`, "utf8").toString("base64");
const unwrap = (body) => body?.value ?? body;

export class VsphereClient {
  constructor({ credentials = loadVsphereCredentials, caFile = process.env.VSPHERE_CA_FILE, observer = () => {}, config = null } = {}) {
    this.credentialsProvider = credentials;
    this.caFile = caFile;
    this.ca = caFile ? fs.readFileSync(caFile) : undefined;
    this.sessionId = null;
    this.loginPromise = null;
    this.config = config;
    this.observer = observer;
  }

  async ensureConfig() {
    if (!this.config) this.config = await this.credentialsProvider();
    return this.config;
  }

  async serverList() {
    const config = await this.ensureConfig();
    const servers = Array.isArray(config.servers) && config.servers.length
      ? config.servers
      : [config.server];
    return [...new Set(servers)];
  }

  clientFor(server) {
    return new VsphereClient({
      credentials: async () => ({ ...(await this.ensureConfig()), server }),
      caFile: this.caFile,
      observer: this.observer
    });
  }

  async request(pathname, { method = "GET", headers = {}, retry = true } = {}) {
    const started = Date.now();
    if (!this.config) this.config = await this.credentialsProvider();
    const url = new URL(pathname, `${this.config.server.replace(/\/$/, "")}/`);
    if (url.origin !== new URL(this.config.server).origin) throw new Error("Blocked vSphere request outside the configured vCenter origin.");
    try {
    const body = await new Promise((resolve, reject) => {
      const req = https.request(url, {
        method, ca: this.ca, rejectUnauthorized: true,
        headers: { accept: "application/json", ...headers },
        timeout: 60_000
      }, (res) => {
        let text = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => { text += chunk; });
        res.on("end", () => {
          let parsed = null;
          try { parsed = text ? JSON.parse(text) : null; } catch { parsed = null; }
          if ((res.statusCode ?? 500) >= 400) {
            const error = new Error(`vSphere API returned HTTP ${res.statusCode} for ${method} ${pathname}.`);
            error.statusCode = res.statusCode;
            return reject(error);
          }
          resolve(parsed);
        });
      });
      req.on("timeout", () => req.destroy(new Error("vSphere API request timed out.")));
      req.on("error", reject);
      req.end();
    });
    this.observer({ endpoint: `${method} ${pathname}`, ok: true, durationMs: Date.now() - started });
    return body;
    } catch (error) {
      this.observer({ endpoint: `${method} ${pathname}`, ok: false, durationMs: Date.now() - started });
      throw error;
    }
  }

  async login() {
    this.config = await this.credentialsProvider();
    const response = await this.request("/rest/com/vmware/cis/session", {
      method: "POST", retry: false,
      headers: { authorization: `Basic ${encodeBasic(this.config.username, this.config.password)}` }
    });
    this.sessionId = unwrap(response);
    if (!this.sessionId) throw new Error("vSphere authentication returned no session.");
    return true;
  }

  async ensureLogin() {
    if (this.sessionId) return;
    this.loginPromise ??= this.login().finally(() => { this.loginPromise = null; });
    await this.loginPromise;
  }

  async get(pathname, retry = true) {
    await this.ensureLogin();
    try {
      return unwrap(await this.request(pathname, { headers: { "vmware-api-session-id": this.sessionId } }));
    } catch (error) {
      if (retry && error.statusCode === 401) {
        this.sessionId = null;
        await this.login();
        return this.get(pathname, false);
      }
      throw error;
    }
  }

  async acrossServers(operation) {
    const config = await this.ensureConfig();
    const servers = await this.serverList();
    const primary = config.server;
    const settled = await Promise.all(servers.map(async (server) => {
      try {
        const client = server === primary ? this : this.clientFor(server);
        return { server, value: await operation(client, server), ok: true };
      } catch (error) {
        return { server, error: error.message, ok: false };
      }
    }));
    return {
      results: settled.filter((entry) => entry.ok).map(({ server, value }) => ({ server, value })),
      failures: settled.filter((entry) => !entry.ok).map(({ server, error }) => ({ server, error })),
      servers
    };
  }

  connectionStatus() { return this.get("/rest/appliance/system/version"); }
  listVms() { return this.get("/rest/vcenter/vm"); }

  async connectionStatusAll() {
    const { results, failures, servers } = await this.acrossServers((client) => client.connectionStatus());
    const primary = results[0]?.value ?? {};
    return {
      ...primary,
      configuredVCenters: servers.length,
      onlineVCenters: results.length,
      vCenters: results.map(({ server, value }) => ({ vCenter: server, ...value })),
      failures
    };
  }

  async listAll(resource) {
    const { results, failures } = await this.acrossServers((client) => client[resource]());
    const items = results.flatMap(({ server, value }) =>
      Array.isArray(value) ? value.map((item) => ({ ...item, vCenter: server })) : []);
    if (!items.length && failures.length) {
      const detail = failures.map(({ server, error }) => `${server}: ${error}`).join("; ");
      throw new Error(`No vSphere data was returned. Failed vCenters: ${detail}`);
    }
    return items;
  }

  listAllVms() { return this.listAll("listVms"); }
  listAllHosts() { return this.listAll("listHosts"); }
  listAllClusters() { return this.listAll("listClusters"); }
  listAllDatastores() { return this.listAll("listDatastores"); }
  listAllNetworks() { return this.listAll("listNetworks"); }
  listAllDatacenters() { return this.listAll("listDatacenters"); }

  async inventorySummaryAll() {
    const resources = [
      ["virtualMachines", "listVms"],
      ["hosts", "listHosts"],
      ["clusters", "listClusters"],
      ["datastores", "listDatastores"],
      ["networks", "listNetworks"],
      ["datacenters", "listDatacenters"]
    ];
    const { results, failures, servers } = await this.acrossServers(async (client) => {
      const counts = {};
      await Promise.all(resources.map(async ([key, method]) => {
        const value = await client[method]();
        counts[key] = Array.isArray(value) ? value.length : 0;
      }));
      return counts;
    });
    const total = Object.fromEntries(resources.map(([key]) => [
      key,
      results.reduce((sum, { value }) => sum + (value[key] || 0), 0)
    ]));
    return {
      ...total,
      configuredVCenters: servers.length,
      onlineVCenters: results.length,
      vCenters: results.map(({ server, value }) => ({ vCenter: server, ...value })),
      failures
    };
  }

  async resolveVmId(identifier) {
    const raw = String(identifier ?? "").trim();
    if (!raw) throw new Error("A VM identifier is required.");

    const config = await this.ensureConfig();
    const servers = await this.serverList();
    const primary = config.server;
    const needle = raw.toLowerCase().replace(/\.$/, "");
    const shortNeedle = String(needle).split(".")[0];
    const shortName = (name) => String(name ?? "").split(".")[0].toLowerCase();

    const idHits = [];
    const exactHits = [];
    const shortHits = [];
    const suggestions = [];

    const { results, failures } = await this.acrossServers((client) => client.listVms());
    for (const { server, value: vms } of results) {
      const list = Array.isArray(vms) ? vms : [];
      for (const vm of list) {
        const entry = { server, vm };
        const name = String(vm.name ?? "").toLowerCase();
        if (/^vm-\d+$/.test(raw) && String(vm.vm) === raw) idHits.push(entry);
        if (name === needle) exactHits.push(entry);
        if (shortName(vm.name) === shortNeedle) shortHits.push(entry);
        if (name.includes(shortNeedle)) suggestions.push(entry);
      }
    }

    const unique = (items) => {
      const seen = new Set();
      return items.filter(({ server, vm }) => {
        const key = `${server}|${vm?.vm}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      });
    };
    const preferPrimary = (items) => {
      const onPrimary = items.filter((item) => item.server === primary);
      return onPrimary.length ? onPrimary : items;
    };
    const describe = (items) => items.slice(0, 5)
      .map(({ server, vm }) => `${vm.name} (${vm.vm}, ${server})`)
      .join(", ");
    const ambiguous = (items) => {
      throw new Error(`Multiple vSphere VMs match '${raw}': ${describe(items)}. Use the VM id instead.`);
    };

    const ids = preferPrimary(unique(idHits));
    if (ids.length === 1) return ids[0];
    if (ids.length > 1) ambiguous(ids);

    const exact = preferPrimary(unique(exactHits));
    if (exact.length === 1) return exact[0];
    if (exact.length > 1) ambiguous(exact);

    const shorts = preferPrimary(unique(shortHits));
    if (shorts.length === 1) return shorts[0];
    if (shorts.length > 1) ambiguous(shorts);

    const similar = unique(suggestions).slice(0, 5);
    let hint = similar.length ? ` Similar names: ${describe(similar)}.` : "";
    if (failures.length) {
      const detail = failures.slice(0, 3)
        .map(({ server, error }) => `${server}: ${error}`)
        .join("; ");
      hint += ` Some vCenters were unavailable: ${detail}.`;
    }
    throw new Error(`No vSphere VM found for '${raw}' across ${servers.length} configured vCenter(s). Check the name or provide the VM id from the owning vCenter.${hint}`);
  }

  async getVm(identifier) {
    const { server, vm } = await this.resolveVmId(identifier);
    const id = String(vm?.vm ?? vm ?? "");
    if (!/^[A-Za-z0-9_-]+$/.test(id)) throw new Error("Invalid VM identifier.");
    const config = await this.ensureConfig();
    const client = server && server !== config.server ? this.clientFor(server) : this;
    const detail = await client.get(`/rest/vcenter/vm/${encodeURIComponent(id)}`);
    return { ...detail, vCenter: server ?? config.server, vmId: id };
  }
  getVmGuestNetworking(id) {
    if (!/^[A-Za-z0-9_-]+$/.test(String(id))) throw new Error("Invalid VM identifier.");
    return this.get(`/api/vcenter/vm/${encodeURIComponent(id)}/guest/networking/interfaces`);
  }

  // ---- Additional official read-only inventory operations -----------------
  // All operations fan out across every configured vCenter and attach the
  // owning vCenter to each result. No mutating endpoint is used here.
  async listAllFrom(path, label) {
    const { results, failures, servers } = await this.acrossServers((client) => client.get(path));
    const items = results.flatMap(({ server, value }) => {
      const values = Array.isArray(value) ? value : [value];
      return values
        .filter((item) => item !== null && item !== undefined)
        .map((item) => (item && typeof item === "object" ? { ...item, vCenter: server } : { value: item, vCenter: server }));
    });
    if (!items.length && failures.length) {
      const detail = failures.map(({ server, error }) => `${server}: ${error}`).join("; ");
      throw new Error(`No ${label} data was returned. Failed vCenters: ${detail}`);
    }
    return {
      items,
      configuredVCenters: servers.length,
      onlineVCenters: results.length,
      failures
    };
  }

  async resolveInventory(identifier, listPath, idKey, label) {
    const raw = String(identifier ?? "").trim();
    if (!raw) throw new Error(`A ${label} identifier is required.`);
    const config = await this.ensureConfig();
    const { results, failures } = await this.acrossServers((client) => client.get(listPath));
    const hits = [];
    for (const { server, value } of results) {
      for (const item of (Array.isArray(value) ? value : [])) {
        const id = String(item?.[idKey] ?? "");
        const name = String(item?.name ?? "");
        if (id === raw || name.toLowerCase() === raw.toLowerCase()) hits.push({ server, item });
      }
    }
    const unique = [...new Map(hits.map((hit) => [`${hit.server}|${hit.item?.[idKey]}`, hit])).values()];
    if (!unique.length) {
      const detail = failures.slice(0, 3).map(({ server, error }) => `${server}: ${error}`).join("; ");
      throw new Error(`No ${label} found for '${raw}' across ${(await this.serverList()).length} configured vCenter(s).${detail ? ` Errors: ${detail}` : ""}`);
    }
    const onPrimary = unique.filter((hit) => hit.server === config.server);
    const candidates = onPrimary.length ? onPrimary : unique;
    if (candidates.length > 1) {
      const names = candidates.map((hit) => `${hit.item?.[idKey]} (${hit.server})`).join(", ");
      throw new Error(`Multiple ${label} entries match '${raw}': ${names}. Use the exact id instead.`);
    }
    return { server: candidates[0].server, id: String(candidates[0].item[idKey]), item: candidates[0].item };
  }

  async inventoryDetail(identifier, listPath, idKey, detailPath, label) {
    const found = await this.resolveInventory(identifier, listPath, idKey, label);
    const config = await this.ensureConfig();
    const client = found.server === config.server ? this : this.clientFor(found.server);
    const value = await client.get(detailPath(found.id));
    const payload = value && typeof value === "object" && !Array.isArray(value) ? value : { value };
    return { ...payload, vCenter: found.server, id: found.id };
  }

  async vmDetail(identifier, suffix, label) {
    const { server, vm } = await this.resolveVmId(identifier);
    const id = String(vm?.vm ?? vm ?? "");
    if (!/^[A-Za-z0-9_-]+$/.test(id)) throw new Error("Invalid VM identifier.");
    const config = await this.ensureConfig();
    const client = server && server !== config.server ? this.clientFor(server) : this;
    const value = await client.get(`/api/vcenter/vm/${encodeURIComponent(id)}/${suffix}`);
    const payload = value && typeof value === "object" && !Array.isArray(value) ? value : { value };
    return { ...payload, vCenter: server ?? config.server, vmId: id, vmName: vm.name, detail: label };
  }

  listAllResourcePools() { return this.listAllFrom("/api/vcenter/resource-pool", "resource pools"); }
  getResourcePool(id) {
    return this.inventoryDetail(id, "/api/vcenter/resource-pool", "resource_pool",
      (found) => `/api/vcenter/resource-pool/${encodeURIComponent(found)}`, "resource pool");
  }
  listAllFolders() { return this.listAllFrom("/api/vcenter/folder", "folders"); }
  listAllContentLibraries() { return this.listAllFrom("/api/content/library", "content libraries"); }
  listAllTagCategories() { return this.listAllFrom("/api/cis/tagging/category", "tag categories"); }
  listAllTags() { return this.listAllFrom("/api/cis/tagging/tag", "tags"); }
  getVmGuestNetworkInterfaces(vm) { return this.vmDetail(vm, "guest/networking/interfaces", "guest network interfaces"); }
  getVmGuestIdentity(vm) { return this.vmDetail(vm, "guest/identity", "guest identity"); }
  getVmEthernet(vm) { return this.vmDetail(vm, "hardware/ethernet", "ethernet adapters"); }
  getVmStoragePolicy(vm) { return this.vmDetail(vm, "storage/policy", "storage policy"); }
  getDatastoreDefaultPolicy(datastore) {
    return this.inventoryDetail(datastore, "/rest/vcenter/datastore", "datastore",
      (found) => `/api/vcenter/datastore/${encodeURIComponent(found)}/default-policy`, "datastore");
  }

  listHosts() { return this.get("/rest/vcenter/host"); }
  listClusters() { return this.get("/rest/vcenter/cluster"); }
  listDatastores() { return this.get("/rest/vcenter/datastore"); }
  listNetworks() { return this.get("/rest/vcenter/network"); }
  listDatacenters() { return this.get("/rest/vcenter/datacenter"); }
  listVmsForDatacenter(id) {
    if (!/^[A-Za-z0-9_-]+$/.test(String(id))) throw new Error("Invalid datacenter identifier.");
    return this.get(`/rest/vcenter/vm?filter.datacenters=${encodeURIComponent(id)}`);
  }
  listHostsForDatacenter(id) {
    if (!/^[A-Za-z0-9_-]+$/.test(String(id))) throw new Error("Invalid datacenter identifier.");
    return this.get(`/rest/vcenter/host?filter.datacenters=${encodeURIComponent(id)}`);
  }
  listHostsForCluster(id) {
    if (!/^[A-Za-z0-9_-]+$/.test(String(id))) throw new Error("Invalid cluster identifier.");
    return this.get(`/rest/vcenter/host?filter.clusters=${encodeURIComponent(id)}`);
  }
}
