import readline from "node:readline";
import { VsphereClient } from "./src/vsphere-client.mjs";
const client = new VsphereClient();
const vmArg={vm:{type:"string",description:"VM id (vm-123), exact or short inventory name, or FQDN; searched across all configured vCenters"}};
const resourceArg={resource:{type:"string",description:"Resource id or exact name; searched across all configured vCenters"}};
const entries = [
  ["vsphere_connection_status","Confirm connectivity and product version across all configured vCenters",{},()=>client.connectionStatusAll()],
  ["vsphere_inventory_summary","Return combined inventory counts across all configured vCenters",{},()=>client.inventorySummaryAll()],
  ["vsphere_list_vms","List virtual machines from all configured vCenters",{},()=>client.listAllVms()],
  ["vsphere_get_vm","Get one virtual machine by VM id, exact or short inventory name, or FQDN; searches all configured vCenters",vmArg,({vm})=>client.getVm(vm),["vm"]],
  ["vsphere_list_hosts","List ESXi hosts from all configured vCenters",{},()=>client.listAllHosts()],
  ["vsphere_list_clusters","List clusters from all configured vCenters",{},()=>client.listAllClusters()],
  ["vsphere_list_datastores","List datastores from all configured vCenters",{},()=>client.listAllDatastores()],
  ["vsphere_list_networks","List networks from all configured vCenters",{},()=>client.listAllNetworks()],
  ["vsphere_list_datacenters","List datacenter objects from all configured vCenters",{},()=>client.listAllDatacenters()],
  ["vsphere_list_resource_pools","List resource pools from all configured vCenters",{},()=>client.listAllResourcePools()],
  ["vsphere_get_resource_pool","Get one resource pool by id or exact name; searches all configured vCenters",resourceArg,({resource})=>client.getResourcePool(resource),["resource"]],
  ["vsphere_list_folders","List inventory folders from all configured vCenters",{},()=>client.listAllFolders()],
  ["vsphere_get_vm_guest_network_interfaces","List guest-network interfaces for one VM; searches all configured vCenters",vmArg,({vm})=>client.getVmGuestNetworkInterfaces(vm),["vm"]],
  ["vsphere_get_vm_guest_identity","Get guest OS identity for one VM; searches all configured vCenters",vmArg,({vm})=>client.getVmGuestIdentity(vm),["vm"]],
  ["vsphere_get_vm_ethernet","List virtual ethernet adapters for one VM; searches all configured vCenters",vmArg,({vm})=>client.getVmEthernet(vm),["vm"]],
  ["vsphere_get_vm_storage_policy","Get storage-policy association for one VM; searches all configured vCenters",vmArg,({vm})=>client.getVmStoragePolicy(vm),["vm"]],
  ["vsphere_get_datastore_default_policy","Get the default storage policy of one datastore by id or exact name; searches all configured vCenters",resourceArg,({resource})=>client.getDatastoreDefaultPolicy(resource),["resource"]],
  ["vsphere_list_content_libraries","List content libraries from all configured vCenters",{},()=>client.listAllContentLibraries()],
  ["vsphere_list_tag_categories","List tagging categories from all configured vCenters",{},()=>client.listAllTagCategories()],
  ["vsphere_list_tags","List tags from all configured vCenters",{},()=>client.listAllTags()]
];
const handlers=new Map(entries.map(([name,,,fn])=>[name,fn]));
const definitions=entries.map(([name,description,properties,,,required])=>({name,description,inputSchema:{type:"object",properties,additionalProperties:false,required:required??[]},annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:false}}));
const send=value=>process.stdout.write(`${JSON.stringify(value)}\n`);
readline.createInterface({input:process.stdin,crlfDelay:Infinity}).on("line",async line=>{let m;try{m=JSON.parse(line)}catch{return}if(!Object.hasOwn(m,"id"))return;try{if(m.method==="initialize")return send({jsonrpc:"2.0",id:m.id,result:{protocolVersion:"2025-03-26",capabilities:{tools:{}},serverInfo:{name:"cstorage-vsphere-readonly",version:"1.0.0"}}});if(m.method==="tools/list")return send({jsonrpc:"2.0",id:m.id,result:{tools:definitions}});if(m.method==="tools/call"){const fn=handlers.get(m.params?.name);if(!fn)throw new Error("Unknown tool");const value=await fn(m.params?.arguments??{});const structuredContent=(value&&typeof value==="object"&&!Array.isArray(value))?value:{result:value};return send({jsonrpc:"2.0",id:m.id,result:{content:[{type:"text",text:JSON.stringify(value)}],structuredContent}})}send({jsonrpc:"2.0",id:m.id,error:{code:-32601,message:"Method not found"}})}catch(error){send({jsonrpc:"2.0",id:m.id,result:{isError:true,content:[{type:"text",text:error.message}]}})}});
