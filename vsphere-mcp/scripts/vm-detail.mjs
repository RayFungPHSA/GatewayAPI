import { loadVsphereCredentials } from "../src/credentials.mjs";
import { VsphereClient } from "../src/vsphere-client.mjs";

const [hostname, vm] = process.argv.slice(2);
if (!/^[A-Za-z0-9.-]+$/.test(hostname ?? "") || !/^[A-Za-z0-9_-]+$/.test(vm ?? "")) throw new Error("A valid vCenter hostname and VM identifier are required.");
const credentials = await loadVsphereCredentials();
const server = credentials.servers.find((candidate) => new URL(candidate).hostname.toLowerCase() === hostname.toLowerCase());
if (!server) throw new Error("The requested vCenter is not configured.");
const client = new VsphereClient({ credentials: async () => ({ ...credentials, server }) });
const detail = await client.getVm(vm);
let guestInterfaces = [];
let guestNetworkingError = null;
try { guestInterfaces = await client.getVmGuestNetworking(vm); }
catch (error) { guestNetworkingError = error.message; }
process.stdout.write(JSON.stringify({ ...detail, guestInterfaces, guestNetworkingError }));
