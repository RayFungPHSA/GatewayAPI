#!/usr/bin/env node

import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const currentFile = fileURLToPath(import.meta.url);
const projectDir = path.resolve(path.dirname(currentFile), "..");

function loadEnvFile(file) {
  if (!fs.existsSync(file)) return;
  for (const raw of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const at = line.indexOf("=");
    if (at < 1) continue;
    const key = line.slice(0, at).trim();
    let value = line.slice(at + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}

// Credentials are supplied by the bridge process environment from the
// DPAPI-protected C:\caddy-gateway\secrets\lansweeper-gateway.xml. Loading a
// local file is optional and intended only for direct debugging; the copied
// gateway folder must never contain lansweeper.env or .env.
if (process.env.LANSWEEPER_ENV_FILE) loadEnvFile(process.env.LANSWEEPER_ENV_FILE);

const config = {
  baseUrl: (process.env.LANSWEEPER_URL ?? "https://ls.healthbc.org").replace(/\/+$/, ""),
  username: process.env.LANSWEEPER_USERNAME ?? "",
  password: process.env.LANSWEEPER_PASSWORD ?? "",
  allowInvalidCertificate:
    (process.env.LANSWEEPER_ALLOW_INVALID_CERT ?? "false").toLowerCase() === "true",
  timeoutMs: Number.parseInt(process.env.LANSWEEPER_TIMEOUT_MS ?? "20000", 10),
};

const readOnlyAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
};

function safeError(error) {
  const message = error instanceof Error ? error.message : String(error);
  let redacted = message
    .replace(/NameTextBox=[^&]*/gi, "NameTextBox=[REDACTED]")
    .replace(/PasswordTextBox=[^&]*/gi, "PasswordTextBox=[REDACTED]")
    .replace(/"password"\s*:\s*"[^"]*"/gi, '"password":"[REDACTED]"');
  for (const name of ["LANSWEEPER_PASSWORD", "LANSWEEPER_USERNAME"]) {
    const value = process.env[name];
    if (value && value.length >= 3) redacted = redacted.split(value).join("[REDACTED]");
  }
  return redacted;
}

// ---- cookie jar -----------------------------------------------------------
class CookieJar {
  constructor() {
    this.cookies = new Map();
  }
  absorb(headers) {
    const raw = headers["set-cookie"];
    const list = Array.isArray(raw) ? raw : raw ? [raw] : [];
    for (const header of list) {
      const pair = header.split(";")[0];
      const eq = pair.indexOf("=");
      if (eq < 1) continue;
      this.cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
  }
  header() {
    return [...this.cookies].map(([k, v]) => `${k}=${v}`).join("; ");
  }
  get size() {
    return this.cookies.size;
  }
}

let session = null;

// The authenticated console cookie must never be sent to another origin.
// Caller-supplied paths in fetch_page/discover_endpoints are resolved against
// the configured console, but an absolute or protocol-relative URL could
// otherwise redirect that authenticated request elsewhere.
const consoleOrigin = new URL(config.baseUrl).origin;
function assertConsoleOrigin(url) {
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("Blocked Lansweeper request with an unsupported URL scheme.");
  }
  if (url.username || url.password) {
    throw new Error("Blocked Lansweeper request with URL credentials.");
  }
  if (url.origin !== consoleOrigin) {
    throw new Error("Blocked Lansweeper request outside the configured console origin.");
  }
  return url;
}

function request(method, urlString, options = {}) {
  return new Promise((resolve, reject) => {
    let url;
    try {
      url = assertConsoleOrigin(new URL(urlString));
    } catch (error) {
      reject(error);
      return;
    }
    const isHttps = url.protocol === "https:";
    const body = options.form !== undefined ? options.form.toString() : options.body;
    const headers = {
      "User-Agent": "lansweeper-web-mcp/0.1.0",
      Accept: options.accept ?? "text/html,application/xhtml+xml,*/*",
      ...(options.headers ?? {}),
    };
    if (options.jar?.header()) headers.Cookie = options.jar.header();
    if (body !== undefined) {
      headers["Content-Type"] = "application/x-www-form-urlencoded";
      headers["Content-Length"] = Buffer.byteLength(body);
    }

    const requestOptions = {
      method,
      headers,
      timeout: config.timeoutMs,
      ...(isHttps ? { rejectUnauthorized: !config.allowInvalidCertificate } : {}),
    };

    const client = isHttps ? https : http;
    const req = client.request(url, requestOptions, (response) => {
      options.jar?.absorb(response.headers);
      let text = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => {
        text += chunk;
      });
      response.on("end", () => {
        resolve({
          status: response.statusCode ?? 0,
          headers: response.headers,
          body: text,
          location: response.headers.location ?? null,
        });
      });
    });
    req.on("timeout", () => {
      req.destroy(new Error(`Request timed out after ${config.timeoutMs} ms.`));
    });
    req.on("error", reject);
    req.end(body ?? undefined);
  });
}

async function requestFollowing(method, urlString, options = {}, maxHops = 6) {
  let currentUrl = urlString;
  let currentMethod = method;
  let currentOptions = options;
  for (let hop = 0; hop <= maxHops; hop += 1) {
    const result = await request(currentMethod, currentUrl, currentOptions);
    if ([301, 302, 303, 307, 308].includes(result.status) && result.location) {
      currentUrl = new URL(result.location, currentUrl).href;
      if (result.status === 303 || (result.status === 302 && currentMethod !== "GET")) {
        currentMethod = "GET";
        currentOptions = { ...options, form: undefined, body: undefined };
      }
      continue;
    }
    return result;
  }
  throw new Error("Too many redirects while contacting the Lansweeper console.");
}

function parseHiddenFields(html) {
  const fields = {};
  const inputRe = /<input\b[^>]*>/gi;
  let match;
  while ((match = inputRe.exec(html)) !== null) {
    const tag = match[0];
    const name = /\bname="([^"]*)"/i.exec(tag)?.[1];
    if (!name) continue;
    const type = (/\btype="([^"]*)"/i.exec(tag)?.[1] ?? "text").toLowerCase();
    const value = /\bvalue="([^"]*)"/i.exec(tag)?.[1] ?? "";
    if (type === "hidden") fields[name] = decodeHtml(value);
  }
  return fields;
}

function decodeHtml(value) {
  return String(value)
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ");
}

const isLoginPage = (html) => /NameTextBox/i.test(html) && /PasswordTextBox/i.test(html);

async function login({ force = false } = {}) {
  if (!force && session && Date.now() < session.expiresAt) return session;
  if (!config.username || !config.password) {
    throw new Error(
      "LANSWEEPER_USERNAME / LANSWEEPER_PASSWORD are not set. Configure secrets\\lansweeper-gateway.xml on the gateway server.",
    );
  }

  const jar = new CookieJar();
  const loginUrl = `${config.baseUrl}/login.aspx`;
  const page = await request("GET", loginUrl, { jar });
  if (page.status >= 400) {
    throw new Error(`Login page returned HTTP ${page.status}.`);
  }

  const hidden = parseHiddenFields(page.body);
  // The console fixes the domain (e.g. "Domain: HEALTHBC") and expects a bare
  // username, so strip any DOMAIN\ prefix the user may have configured.
  const username = config.username.includes("\\")
    ? config.username.split("\\").pop()
    : config.username;
  const form = new URLSearchParams({
    ...hidden,
    NameTextBox: username,
    PasswordTextBox: config.password,
    LoginButton: "WINDOWS LOGIN",
    __EVENTTARGET: "LoginButton",
    __EVENTARGUMENT: "",
  });

  const post = await requestFollowing("POST", loginUrl, { jar, form });

  if (post.status >= 400) {
    throw new Error(`Login request returned HTTP ${post.status}.`);
  }
  if (isLoginPage(post.body)) {
    throw new Error(
      "Login failed: the console returned the login form again. Check the username/password (AD accounts may need DOMAIN\\user).",
    );
  }

  session = {
    jar,
    authenticatedAt: new Date().toISOString(),
    expiresAt: Date.now() + 15 * 60_000,
  };
  return session;
}

async function fetchPage(requestPath, query) {
  const current = await login();
  const url = assertConsoleOrigin(new URL(requestPath, `${config.baseUrl}/`));
  for (const [key, value] of Object.entries(query ?? {})) {
    if (value !== undefined && value !== null && value !== "") {
      url.searchParams.set(key, String(value));
    }
  }
  const headers =
    url.pathname.toLowerCase().includes("assetactions")
      ? {
          Accept: "application/json, text/javascript, */*; q=0.01",
          "X-Requested-With": "XMLHttpRequest",
          Referer: `${config.baseUrl}/Assets.aspx`,
        }
      : undefined;
  let result = await requestFollowing("GET", url.href, { jar: current.jar, headers });
  if (result.status === 401 || isLoginPage(result.body)) {
    session = null;
    const fresh = await login({ force: true });
    result = await requestFollowing("GET", url.href, { jar: fresh.jar, headers });
  }
  return { ...result, text: result.body, url: url.href, isLoginPage: isLoginPage(result.body) };
}

async function fetchReportJson({
  det = "all",
  page = 1,
  top = 100,
  order,
  orderby,
  filters = {},
  cache = 0,
} = {}) {
  const current = await login();
  const url = new URL("/ReportJson.aspx", `${config.baseUrl}/`);
  url.searchParams.set("det", det);
  url.searchParams.set("top", String(top));
  url.searchParams.set("page", String(page));
  if (order && orderby) {
    url.searchParams.set("order", order);
    url.searchParams.set("orderby", orderby);
  }
  url.searchParams.set("cache", String(cache));

  const form = new URLSearchParams();
  for (const [key, value] of Object.entries(filters ?? {})) {
    if (value !== undefined && value !== null) form.set(`search[${key}]`, String(value));
  }
  const headers = {
    Accept: "application/json, text/javascript, */*; q=0.01",
    "X-Requested-With": "XMLHttpRequest",
    Referer: `${config.baseUrl}/Report/report.aspx?det=${encodeURIComponent(det)}`,
  };

  let result = await requestFollowing("POST", url.href, {
    jar: current.jar,
    form,
    headers,
  });
  if (result.status === 401 || isLoginPage(result.body)) {
    session = null;
    const fresh = await login({ force: true });
    result = await requestFollowing("POST", url.href, {
      jar: fresh.jar,
      form,
      headers,
    });
  }
  if (result.status < 200 || result.status >= 300) {
    throw new Error(`ReportJson "${det}" failed with HTTP ${result.status}.`);
  }
  let data;
  try {
    data = JSON.parse(result.body);
  } catch {
    throw new Error(`ReportJson "${det}" returned non-JSON content.`);
  }
  if (data?.Error) {
    throw new Error(data.Emsg ?? data.Message ?? `ReportJson "${det}" returned an error.`);
  }
  return data;
}

function cellText(value) {
  if (value === null || value === undefined) return "";
  const text = decodeHtml(
    String(value)
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
      .trim(),
  );
  return text;
}

function rowsToRecords(data) {
  const columns = Array.isArray(data?.Columns) ? data.Columns.map(cellText) : [];
  const rows = data?.AddedRows ?? data?.Rows ?? data?.Data ?? data?.rows ?? data?.data ?? [];
  if (!Array.isArray(rows)) return { columns, records: [] };
  const records = rows.map((row) => {
    if (!Array.isArray(row)) return row;
    const record = {};
    columns.forEach((column, index) => {
      record[column || `col${index}`] = cellText(row[index]);
    });
    return record;
  });
  return { columns, records };
}

// ---- HTML table parsing ---------------------------------------------------
function extractTables(html) {
  const tables = [];
  const tableRe = /<table\b[^>]*>([\s\S]*?)<\/table>/gi;
  let tableMatch;
  while ((tableMatch = tableRe.exec(html)) !== null) {
    const inner = tableMatch[1];
    const rows = [];
    const rowRe = /<tr\b[^>]*>([\s\S]*?)<\/tr>/gi;
    let rowMatch;
    while ((rowMatch = rowRe.exec(inner)) !== null) {
      const cells = [];
      const cellRe = /<t[hd]\b[^>]*>([\s\S]*?)<\/t[hd]>/gi;
      let cellMatch;
      while ((cellMatch = cellRe.exec(rowMatch[1])) !== null) {
        cells.push(
          decodeHtml(cellMatch[1].replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim()),
        );
      }
      if (cells.length) rows.push(cells);
    }
    if (rows.length) tables.push(rows);
  }
  return tables;
}

function tablesToObjects(tables) {
  const results = [];
  for (const rows of tables) {
    const headerIndex = rows.findIndex(
      (row) =>
        row.length > 1 &&
        row.some((cell) => /name|asset|ip|os|model|manufacturer|serial/i.test(cell)),
    );
    if (headerIndex < 0) continue;
    const headers = rows[headerIndex].map((h) => h || `col${results.length}`);
    for (const row of rows.slice(headerIndex + 1)) {
      if (row.length !== headers.length) continue;
      const record = {};
      headers.forEach((header, index) => {
        record[header || `col${index}`] = row[index];
      });
      results.push(record);
    }
  }
  return results;
}

// ---- tools ----------------------------------------------------------------
function toolResult(value) {
  return {
    content: [
      {
        type: "text",
        text: typeof value === "string" ? value : JSON.stringify(value, null, 2),
      },
    ],
  };
}

function toolError(error) {
  return { isError: true, content: [{ type: "text", text: safeError(error) }] };
}

function registerReadOnlyTool(server, name, definition, handler) {
  server.registerTool(
    name,
    { ...definition, annotations: readOnlyAnnotations },
    async (input) => {
      try {
        return toolResult(await handler(input));
      } catch (error) {
        return toolError(error);
      }
    },
  );
}

const server = new McpServer({ name: "lansweeper-web-readonly", version: "0.1.0" });

registerReadOnlyTool(
  server,
  "lansweeper_connection_status",
  {
    description:
      "Check network/TLS reach to the configured on-prem Lansweeper web console without logging in.",
    inputSchema: {},
  },
  async () => {
    const page = await request("GET", `${config.baseUrl}/login.aspx`, {});
    return {
      baseUrl: config.baseUrl,
      reachable: page.status >= 200 && page.status < 500,
      httpStatus: page.status,
      contentType: page.headers["content-type"] ?? null,
      certValidationDisabled: config.allowInvalidCertificate,
    };
  },
);

registerReadOnlyTool(
  server,
  "lansweeper_auth_status",
  {
    description:
      "Log in with the configured user/password and report whether authentication succeeded (never returns the password).",
    inputSchema: {
      refresh: z.boolean().optional().describe("Force a fresh login session."),
    },
  },
  async ({ refresh }) => {
    const current = await login({ force: refresh ?? false });
    return {
      authenticated: true,
      baseUrl: config.baseUrl,
      username: config.username ? '[configured]' : null,
      cookieCount: current.jar.size,
      authenticatedAt: current.authenticatedAt,
      expiresAt: new Date(current.expiresAt).toISOString(),
    };
  },
);

const DEFAULT_PROBE_PATHS = [
  "/",
  "/Assets.aspx",
  "/reporting.aspx",
  "/Reports.aspx",
  "/AssetDetail.aspx",
];

registerReadOnlyTool(
  server,
  "lansweeper_discover_endpoints",
  {
    description:
      "Log in and probe candidate web-console paths to find which returns asset/tabular data. Use this first to identify the correct asset path for this instance.",
    inputSchema: {
      paths: z
        .array(z.string())
        .optional()
        .describe("Override the candidate paths to probe (e.g. ['/Assets.aspx'])."),
    },
  },
  async ({ paths }) => {
    const candidates =
      paths?.length
        ? paths
        : process.env.LANSWEEPER_ASSET_PATHS?.split(",").map((p) => p.trim()).filter(Boolean) ??
          DEFAULT_PROBE_PATHS;
    const results = [];
    for (const candidate of candidates) {
      try {
        const page = await fetchPage(candidate);
        const tables = extractTables(page.text);
        const objects = tablesToObjects(tables);
        results.push({
          path: candidate,
          httpStatus: page.status,
          redirectedToLogin: page.isLoginPage,
          contentType: page.headers["content-type"] ?? null,
          tableCount: tables.length,
          assetLikeRows: objects.length,
          sampleRow: objects[0] ?? null,
          bytes: page.text.length,
        });
      } catch (error) {
        results.push({ path: candidate, error: safeError(error) });
      }
    }
    return { baseUrl: config.baseUrl, probes: results };
  },
);

registerReadOnlyTool(
  server,
  "lansweeper_list_assets",
  {
    description:
      "List assets as JSON records from the Lansweeper 'Assets' report (default 'web50repassetsmenu'). Returns columns plus asset rows; use page/top to paginate.",
    inputSchema: {
      report: z
        .string()
        .optional()
        .describe("Report det key (default 'web50repassetsmenu')."),
      page: z.number().int().positive().optional().describe("Page number (default 1)."),
      top: z
        .number()
        .int()
        .positive()
        .max(5000)
        .optional()
        .describe("Rows per page (default 100; console allows 100/250/500/1000)."),
      order: z.enum(["asc", "desc"]).optional().describe("Sort direction."),
      orderby: z.string().optional().describe("Column title to sort by, e.g. 'AssetName'."),
      filters: z
        .record(z.string())
        .optional()
        .describe("Optional search-field filters keyed by console field id, e.g. { s1: 'esx' }."),
      limit: z
        .number()
        .int()
        .positive()
        .max(5000)
        .optional()
        .describe("Trim the returned records to this many."),
    },
  },
  async ({ report = "web50repassetsmenu", page = 1, top = 100, order, orderby, filters, limit }) => {
    const data = await fetchReportJson({ det: report, page, top, order, orderby, filters });
    const { columns, records } = rowsToRecords(data);
    const candidates = [data?.Total, data?.Count, data?.total, data?.CountTotal, data?.Emsg];
    const reportedTotal = candidates.map(Number).find((value) => Number.isFinite(value) && value > 0);
    const total = reportedTotal ?? records.length;
    const limited = typeof limit === "number" ? records.slice(0, limit) : records;
    return {
      report,
      page,
      top,
      total,
      returnedRows: limited.length,
      columns,
      assets: limited,
    };
  },
);

registerReadOnlyTool(
  server,
  "lansweeper_fetch_page",
  {
    description:
      "Fetch any web-console page as an authenticated user and return a trimmed text or parsed-table view. Useful for exploring report pages.",
    inputSchema: {
      path: z.string().min(1).describe("Path such as /reporting.aspx or /report.aspx?id=..."),
      mode: z.enum(["tables", "text", "html"]).optional().describe("How to shape the response."),
      query: z.record(z.string()).optional().describe("Optional query-string parameters."),
      maxChars: z.number().int().positive().max(200000).optional(),
    },
  },
  async ({ path: requestPath, mode, query, maxChars }) => {
    const page = await fetchPage(requestPath, query);
    const cap = maxChars ?? 20000;
    if (page.isLoginPage) {
      throw new Error(`Request to ${page.url} returned the login page.`);
    }
    if (mode === "html") {
      return { url: page.url, httpStatus: page.status, html: page.text.slice(0, cap) };
    }
    if (mode === "text") {
      const text = decodeHtml(page.text.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim());
      return { url: page.url, httpStatus: page.status, text: text.slice(0, cap) };
    }
    const tables = tablesToObjects(extractTables(page.text));
    return {
      url: page.url,
      httpStatus: page.status,
      totalRows: tables.length,
      rows: tables.slice(0, 500),
    };
  },
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(
    `Lansweeper web read-only MCP server connected to stdio (${config.baseUrl}).`,
  );
}

main().catch((error) => {
  console.error(`MCP server failed: ${safeError(error)}`);
  process.exit(1);
});
