import readline from "node:readline";
import { VsphereClient } from "./src/vsphere-client.mjs";
const client = new VsphereClient();
const entries = [
  ["vsphere_connection_status","Confirm connectivity and product version across all configured vCenters",{},()=>client.connectionStatusAll()],
  ["vsphere_inventory_summary","Return combined inventory counts across all configured vCenters",{},()=>client.inventorySummaryAll()],
  ["vsphere_list_vms","List virtual machines from all configured vCenters",{},()=>client.listAllVms()],
  ["vsphere_get_vm","Get one virtual machine by VM id, exact or short inventory name, or FQDN; searches all configured vCenters",{vm:{type:"string",description:"VM id (vm-123), exact or short inventory name, or FQDN"}},({vm})=>client.getVm(vm)],
  ["vsphere_list_hosts","List ESXi hosts from all configured vCenters",{},()=>client.listAllHosts()],
  ["vsphere_list_clusters","List clusters from all configured vCenters",{},()=>client.listAllClusters()],
  ["vsphere_list_datastores","List datastores from all configured vCenters",{},()=>client.listAllDatastores()],
  ["vsphere_list_networks","List networks from all configured vCenters",{},()=>client.listAllNetworks()],
  ["vsphere_list_datacenters","List datacenter objects from all configured vCenters",{},()=>client.listAllDatacenters()]
];
const handlers=new Map(entries.map(([name,,,fn])=>[name,fn]));
const definitions=entries.map(([name,description,properties])=>({name,description,inputSchema:{type:"object",properties,additionalProperties:false,required:name==="vsphere_get_vm"?["vm"]:[]},annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false}}));
const send=value=>process.stdout.write(`${JSON.stringify(value)}\n`);
readline.createInterface({input:process.stdin,crlfDelay:Infinity}).on("line",async line=>{let m;try{m=JSON.parse(line)}catch{return}if(!Object.hasOwn(m,"id"))return;try{if(m.method==="initialize")return send({jsonrpc:"2.0",id:m.id,result:{protocolVersion:"2025-03-26",capabilities:{tools:{}},serverInfo:{name:"cstorage-vsphere-readonly",version:"1.0.0"}}});if(m.method==="tools/list")return send({jsonrpc:"2.0",id:m.id,result:{tools:definitions}});if(m.method==="tools/call"){const fn=handlers.get(m.params?.name);if(!fn)throw new Error("Unknown tool");const value=await fn(m.params?.arguments??{});const structuredContent=(value&&typeof value==="object"&&!Array.isArray(value))?value:{result:value};return send({jsonrpc:"2.0",id:m.id,result:{content:[{type:"text",text:JSON.stringify(value)}],structuredContent}})}send({jsonrpc:"2.0",id:m.id,error:{code:-32601,message:"Method not found"}})}catch(error){send({jsonrpc:"2.0",id:m.id,result:{isError:true,content:[{type:"text",text:error.message}]}})}});
