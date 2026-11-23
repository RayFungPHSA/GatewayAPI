#!/usr/bin/env node
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const transport = new StdioClientTransport({ command: process.execPath, args: [path.join(root, "src", "server.mjs")] });
const client = new Client({ name: "greenlake-capacity-audit", version: "1.0.0" });

function parsed(result) {
  const value = result.content?.find((item) => item.type === "text")?.text;
  return value ? JSON.parse(value) : {};
}

function headline(payload) {
  const record = payload.items?.[0] ?? payload;
  const summary = record.capacitySummary ?? record;
  const total = summary.total ?? summary.totalCapacity;
  const free = summary.free ?? summary.totalFree ?? summary.availableCapacity;
  return {
    total,
    used: Number.isFinite(total) && Number.isFinite(free) ? total - free : summary.used ?? summary.usedCapacity,
    free,
    freePercentage: summary.freePercentage
  };
}

try {
  await client.connect(transport);
  const tools = await client.listTools();
  const auth = parsed(await client.callTool({ name: "greenlake_auth_status", arguments: {} }));
  const inventory = parsed(await client.callTool({ name: "greenlake_list_storage_systems", arguments: {} }));
  const systems = inventory.systems ?? inventory.items ?? inventory.data ?? [];
  const rows = [];
  for (const system of systems) {
    const productFamily = system.productFamily ?? system.deviceType ?? system.device_type;
    if (!["deviceType1", "deviceType4"].includes(productFamily)) continue;
    const id = system.id ?? system.storageSystemId ?? system.resourceId;
    const capacity = parsed(await client.callTool({ name: "greenlake_capacity_summary", arguments: { systemId: id, productFamily } }));
    const ports = parsed(await client.callTool({ name: "greenlake_port_summary", arguments: { systemId: id, productFamily } }));
    rows.push({ name: system.name ?? system.displayName, serial: system.serialNumber ?? system.serial, productFamily, id, capacity: headline(capacity), ports });
  }
  process.stdout.write(JSON.stringify({ toolCount: tools.tools.length, tools: tools.tools.map(({ name }) => name), authenticated: Boolean(auth.authenticated), rows }, null, 2));
} finally {
  await client.close();
}
