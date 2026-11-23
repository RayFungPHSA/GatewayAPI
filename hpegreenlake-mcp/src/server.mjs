#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// Generated from the official HPE Storage Fleet OpenAPI description. It contains
// GET operations only, so every generated tool is read-only by construction.
const readOnlyManifest = JSON.parse(
  fs.readFileSync(path.join(root, "src", "greenlake-readonly-tools.json"), "utf8"),
);

// The gateway loads the shared credential from the DPAPI-protected record and
// passes it in this process environment. A local .env is only for legacy
// standalone debugging and is disabled by HPEGREENLAKE_NO_DOTENV in the gateway.
const envFile = process.env.HPEGREENLAKE_NO_DOTENV === "true"
  ? ""
  : (process.env.HPEGREENLAKE_ENV_FILE
      ? path.resolve(process.env.HPEGREENLAKE_ENV_FILE)
      : path.join(root, ".env"));
if (envFile && fs.existsSync(envFile)) {
  for (const raw of fs.readFileSync(envFile, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const index = line.indexOf("=");
    if (index < 1) continue;
    const key = line.slice(0, index).trim();
    let value = line.slice(index + 1).trim().replace(/\s+#.*$/, "");
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    process.env[key] ||= value;
  }
}

const required = (name) => {
  if (!process.env[name]) throw new Error(`Missing ${name} in GreenLake MCP configuration.`);
  return process.env[name];
};
const baseUrl = (process.env.API_BASE_URL || "https://us1.data.cloud.hpe.com").replace(/\/$/, "");
let session = null;
const safeError = (error) => String(error?.message ?? error)
  .replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]")
  .replace(/client_secret=[^&\s]+/gi, "client_secret=[REDACTED]")
  .replace(/"client_secret"\s*:\s*"[^"]+"/gi, '"client_secret":"[REDACTED]"')
  .replace(/"access_token"\s*:\s*"[^"]+"/gi, '"access_token":"[REDACTED]"')
  .replace(/"password"\s*:\s*"[^"]+"/gi, '"password":"[REDACTED]"');

async function authenticate(force = false) {
  if (!force && session && Date.now() < session.expiresAt - 30_000) return session.token;
  const form = new URLSearchParams({ grant_type: process.env.AUTH_METHOD === "password" ? "password" : "client_credentials", client_id: required("CLIENT_ID"), client_secret: required("CLIENT_SECRET") });
  if (process.env.SCOPE) form.set("scope", process.env.SCOPE);
  if (process.env.AUTH_METHOD === "password") { form.set("username", required("USERNAME")); form.set("password", required("PASSWORD")); }
  const response = await fetch(required("AUTH_URL"), { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: form, signal: AbortSignal.timeout(20_000) });
  const body = await response.json();
  if (!response.ok || !body.access_token) throw new Error(`GreenLake authentication failed (HTTP ${response.status}).`);
  session = { token: body.access_token, expiresAt: Date.now() + Number(body.expires_in || 300) * 1000 };
  return session.token;
}

async function get(requestPath) {
  let token = await authenticate();
  let response = await fetch(`${baseUrl}${requestPath}`, { headers: { authorization: `Bearer ${token}`, accept: "application/json" }, signal: AbortSignal.timeout(30_000) });
  if (response.status === 401 || response.status === 403) { token = await authenticate(true); response = await fetch(`${baseUrl}${requestPath}`, { headers: { authorization: `Bearer ${token}`, accept: "application/json" }, signal: AbortSignal.timeout(30_000) }); }
  if (!response.ok) throw new Error(`GreenLake GET ${requestPath} failed (HTTP ${response.status}).`);
  return response.json();
}

function argumentDescription(parameter) {
  const description = parameter.description || `${parameter.name} ${parameter.in} parameter`;
  const allowed = Array.isArray(parameter.enum) && parameter.enum.length
    ? ` Allowed values: ${parameter.enum.join(", ")}.`
    : "";
  return `${description}${allowed}`;
}

function zodForParameter(parameter) {
  let field;
  if (parameter.in === "path") {
    field = z.string().min(1);
  } else if (parameter.type === "integer") {
    field = z.number().int();
  } else if (parameter.type === "number") {
    field = z.number();
  } else if (parameter.type === "boolean") {
    field = z.boolean();
  } else {
    field = z.string();
  }
  field = field.describe(argumentDescription(parameter));
  return parameter.required ? field : field.optional();
}

function requestArgsShape(endpoint) {
  const shape = {};
  for (const parameter of endpoint.parameters || []) {
    shape[parameter.name] = zodForParameter(parameter);
  }
  return shape;
}

function pathSegment(name, value) {
  if (value === undefined || value === null || String(value) === "") {
    throw new Error(`Missing required path parameter: ${name}`);
  }
  const text = String(value);
  if (text === "." || text === ".." || /[\\/?#\0]/.test(text)) {
    throw new Error(`Invalid path parameter value for ${name}.`);
  }
  return encodeURIComponent(text);
}

function buildReadOnlyPath(endpoint, args) {
  let requestPath = endpoint.path.replace(/\{([^}]+)\}/g, (_match, name) =>
    pathSegment(name, args[name]),
  );
  const query = new URLSearchParams();
  for (const parameter of endpoint.parameters || []) {
    if (parameter.in !== "query") continue;
    const value = args[parameter.name];
    if (value === undefined || value === null || value === "") continue;
    if (Array.isArray(value)) {
      for (const item of value) query.append(parameter.name, String(item));
    } else {
      query.set(parameter.name, String(value));
    }
  }
  const queryString = query.toString();
  return queryString ? `${requestPath}?${queryString}` : requestPath;
}

const annotations = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
const server = new McpServer({ name: "hpegreenlake-fleet-readonly", version: "2.0.0" });
const register = (name, description, inputSchema, handler) => server.registerTool(name, { description, inputSchema, annotations }, async (input) => {
  try { const value = await handler(input); return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }] }; }
  catch (error) { return { isError: true, content: [{ type: "text", text: safeError(error) }] }; }
});

register("greenlake_connection_status", "Check read-only access to the configured GreenLake endpoint.", {}, async () => {
  const response = await fetch(`${baseUrl}/storage-fleet/v1alpha1/storage-systems`, { headers: { authorization: `Bearer ${await authenticate()}`, accept: "application/json" }, signal: AbortSignal.timeout(30_000) });
  return { reachable: response.ok, httpStatus: response.status, baseUrl };
});
register("greenlake_auth_status", "Verify GreenLake OAuth without exposing credentials or tokens.", { refresh: z.boolean().optional() }, async ({ refresh }) => { await authenticate(refresh === true); return { authenticated: true, expiresAt: new Date(session.expiresAt).toISOString() }; });
register("greenlake_list_storage_systems", "List GreenLake storage systems using the read-only Storage Fleet API.", {}, async () => get("/storage-fleet/v1alpha1/storage-systems"));
register("greenlake_capacity_summary", "Get the read-only capacity summary for one GreenLake storage system.", {
  systemId: z.string().min(1), productFamily: z.enum(["deviceType1", "deviceType4"])
}, async ({ systemId, productFamily }) => get(`/storage-fleet/v1alpha1/${productFamily.replace("device", "dev").toLowerCase()}-storage-systems/${encodeURIComponent(systemId)}/capacity-summary`));
register("greenlake_list_ports", "List frontend and backend ports for one GreenLake storage system using a read-only GET.", {
  systemId: z.string().min(1), productFamily: z.enum(["deviceType1", "deviceType4"])
}, async ({ systemId, productFamily }) => get(`/storage-fleet/v1alpha1/${productFamily.replace("device", "dev").toLowerCase()}-storage-systems/${encodeURIComponent(systemId)}/ports`));
register("greenlake_port_summary", "Summarize host-facing Fibre Channel and disk-facing backend ports without changing the array.", {
  systemId: z.string().min(1), productFamily: z.enum(["deviceType1", "deviceType4"])
}, async ({ systemId, productFamily }) => {
  const payload = await get(`/storage-fleet/v1alpha1/${productFamily.replace("device", "dev").toLowerCase()}-storage-systems/${encodeURIComponent(systemId)}/ports`);
  const ports = payload.items ?? payload.data ?? [];
  const role = (port) => String(port.portType ?? port.configMode ?? port.connectionType ?? port.role ?? "").toUpperCase();
  const protocol = (port) => String(port.protocol ?? port.type ?? "").toUpperCase();
  const frontendFc = ports.filter((port) => protocol(port) === "FC" && role(port) !== "DISK");
  const backend = ports.filter((port) => ["DISK", "BACKEND", "DRIVE"].includes(role(port)));
  return {
    systemId,
    frontendFc: { total: frontendFc.length, assigned: frontendFc.filter((port) => role(port) === "HOST").length, free: frontendFc.filter((port) => role(port) === "FREE").length },
    backend: { total: backend.length, protocols: [...new Set(backend.map(protocol).filter(Boolean))] },
    collectedAt: new Date().toISOString()
  };
});

for (const endpoint of readOnlyManifest.endpoints) {
  register(
    endpoint.name,
    `${endpoint.description} (Read-only GET; HPE Storage Fleet API ${readOnlyManifest.source.version}.)`,
    requestArgsShape(endpoint),
    async (input) => get(buildReadOnlyPath(endpoint, input)),
  );
}

await server.connect(new StdioServerTransport());
