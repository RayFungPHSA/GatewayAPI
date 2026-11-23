import { loadVsphereCredentials } from "../src/credentials.mjs";
import { VsphereClient } from "../src/vsphere-client.mjs";

const credentials = await loadVsphereCredentials();

async function collectServer(server) {
  const hostname = new URL(server).hostname.toLowerCase();
  const apiCalls = [];
  const client = new VsphereClient({
    credentials: async () => ({ ...credentials, server }),
    observer: (event) => apiCalls.push({ ...event, endpoint: `${hostname} ${event.endpoint}`, at: new Date().toISOString() })
  });
  const [version, vms, hosts, clusters, datastores, networks, datacenters] = await Promise.all([
    client.connectionStatus(), client.listVms(), client.listHosts(), client.listClusters(), client.listDatastores(), client.listNetworks(), client.listDatacenters()
  ]);
  const vmDatacenters = {};
  const hostDatacenters = {};
  const hostClusters = {};
  for (const datacenter of datacenters ?? []) {
    const [datacenterVms, datacenterHosts] = await Promise.all([client.listVmsForDatacenter(datacenter.datacenter), client.listHostsForDatacenter(datacenter.datacenter)]);
    for (const vm of datacenterVms) {
      vmDatacenters[vm.vm] = { id: datacenter.datacenter, name: datacenter.name };
    }
    for (const host of datacenterHosts) hostDatacenters[host.host] = { id: datacenter.datacenter, name: datacenter.name };
  }
  for (const cluster of clusters ?? []) {
    for (const host of await client.listHostsForCluster(cluster.cluster)) hostClusters[host.host] = { id: cluster.cluster, name: cluster.name };
  }
  return {
    hostname, version, apiCalls, clusters, datastores, networks, datacenters,
    hosts: (hosts ?? []).map((host) => ({ ...host, vcenterServer: hostname, datacenter: hostDatacenters[host.host], cluster: hostClusters[host.host] })),
    vms: (vms ?? []).map((vm) => ({ ...vm, vcenterServer: hostname, datacenter: vmDatacenters[vm.vm] }))
  };
}

try {
  const servers = await Promise.all(credentials.servers.map(collectServer));
  process.stdout.write(JSON.stringify({
    collectedAt: new Date().toISOString(),
    servers,
    vms: servers.flatMap((server) => server.vms),
    apiCalls: servers.flatMap((server) => server.apiCalls),
    hosts: servers.flatMap((server) => server.hosts),
    clusters: servers.flatMap((server) => server.clusters.map((cluster) => ({ ...cluster, vcenterServer: server.hostname }))),
    datastores: servers.flatMap((server) => server.datastores.map((datastore) => ({ ...datastore, vcenterServer: server.hostname }))),
    networks: servers.flatMap((server) => server.networks.map((network) => ({ ...network, vcenterServer: server.hostname }))),
    datacenters: servers.flatMap((server) => server.datacenters.map((datacenter) => ({ ...datacenter, vcenterServer: server.hostname })))
  }));
} catch (error) {
  process.stderr.write(error.message);
  process.exitCode = 1;
}
