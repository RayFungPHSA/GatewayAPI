import { VsphereClient } from "../src/vsphere-client.mjs";
const client = new VsphereClient();
try { const version = await client.connectionStatus(); const vms = await client.listVms(); console.log(JSON.stringify({ authenticated: true, version: version?.version, vmCount: vms?.length ?? 0 })); }
catch (error) { console.error(error.message); process.exitCode = 1; }
