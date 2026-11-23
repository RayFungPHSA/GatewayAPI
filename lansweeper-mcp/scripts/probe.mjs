#!/usr/bin/env node
// Standalone login + endpoint discovery for on-prem Lansweeper (user/password).
// Usage (gateway server only):
//   load LANSWEEPER_URL, LANSWEEPER_USERNAME, LANSWEEPER_PASSWORD from the
//   DPAPI-protected secrets\lansweeper-gateway.xml (run-lansweeper-mcp.ps1), then:
//   node scripts/probe.mjs [/Assets.aspx /reporting.aspx ...]
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function loadEnvFile(file) {
  if (!fs.existsSync(file)) return;
  for (const raw of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const at = line.indexOf("=");
    if (at < 1) continue;
    const key = line.slice(0, at).trim();
    let value = line.slice(at + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}
// The gateway copy never reads a local lansweeper.env. Credentials come only
// from the process environment set by Start-LansweeperBridge.ps1.
if (process.env.LANSWEEPER_ENV_FILE) loadEnvFile(process.env.LANSWEEPER_ENV_FILE);

const baseUrl = (process.env.LANSWEEPER_URL ?? "https://ls.healthbc.org").replace(/\/+$/, "");
const username = process.env.LANSWEEPER_USERNAME ?? "";
const password = process.env.LANSWEEPER_PASSWORD ?? "";
const allowInvalidCert = (process.env.LANSWEEPER_ALLOW_INVALID_CERT ?? "false").toLowerCase() === "true";
const cookieJar = new Map();

function request(method, urlString, { form, redirect = true } = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    const isHttps = url.protocol === "https:";
    const body = form ? form.toString() : undefined;
    const headers = { "User-Agent": "lansweeper-probe/0.1.0" };
    if (cookieJar.size) headers.Cookie = [...cookieJar].map(([k, v]) => `${k}=${v}`).join("; ");
    if (body !== undefined) {
      headers["Content-Type"] = "application/x-www-form-urlencoded";
      headers["Content-Length"] = Buffer.byteLength(body);
    }
    const client = isHttps ? https : http;
    const req = client.request(
      url,
      {
        method,
        headers,
        timeout: 20000,
        ...(isHttps ? { rejectUnauthorized: !allowInvalidCert } : {}),
      },
      (res) => {
        for (const header of res.headers["set-cookie"] ?? []) {
          const pair = header.split(";")[0];
          const eq = pair.indexOf("=");
          if (eq > 0) cookieJar.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
        }
        if (redirect && [301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
          res.resume();
          request("GET", new URL(res.headers.location, url).href, { redirect }).then(resolve, reject);
          return;
        }
        let text = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => (text += chunk));
        res.on("end", () => resolve({ status: res.statusCode ?? 0, headers: res.headers, text }));
      },
    );
    req.on("timeout", () => req.destroy(new Error("Request timed out.")));
    req.on("error", reject);
    req.end(body);
  });
}

const isLoginPage = (html) => /NameTextBox/i.test(html) && /PasswordTextBox/i.test(html);

async function main() {
  if (!username || !password) {
    console.error("Set LANSWEEPER_USERNAME and LANSWEEPER_PASSWORD in the bridge process environment first.");
    process.exit(1);
  }

  const loginHtml = (await request("GET", `${baseUrl}/login.aspx`)).text;
  const hidden = {};
  for (const m of loginHtml.matchAll(/<input\b[^>]*>/gi)) {
    const tag = m[0];
    const name = /\bname="([^"]*)"/i.exec(tag)?.[1];
    const type = (/\btype="([^"]*)"/i.exec(tag)?.[1] ?? "").toLowerCase();
    const value = /\bvalue="([^"]*)"/i.exec(tag)?.[1] ?? "";
    if (name && type === "hidden") hidden[name] = value.replace(/&amp;/g, "&");
  }
  const bareUsername = username.includes("\\") ? username.split("\\").pop() : username;
  const form = new URLSearchParams({
    ...hidden,
    NameTextBox: bareUsername,
    PasswordTextBox: password,
    LoginButton: "WINDOWS LOGIN",
    __EVENTTARGET: "LoginButton",
    __EVENTARGUMENT: "",
  });
  const post = await request("POST", `${baseUrl}/login.aspx`, { form });
  const loggedOut = isLoginPage(post.text);
  console.log(`login POST -> HTTP ${post.status}, cookies=${cookieJar.size}, looksLoggedOut=${loggedOut}`);
  if (loggedOut) {
    console.error("Login appears to have failed. Check AD username format (DOMAIN\\user) and password.");
    process.exit(1);
  }
  console.log("Login OK. Probing paths...\n");

  const paths = process.argv.slice(2);
  const candidates = paths.length ? paths : ["/", "/Assets.aspx", "/reporting.aspx", "/Reports.aspx", "/AssetDetail.aspx"];
  for (const p of candidates) {
    try {
      const res = await request("GET", `${baseUrl}${p}`);
      const tables = (res.text.match(/<table\b/gi) ?? []).length;
      const rows = (res.text.match(/<tr\b/gi) ?? []).length;
      console.log(`${p} -> HTTP ${res.status} bytes=${res.text.length} tables=${tables} rows=${rows} login=${isLoginPage(res.text)}`);
    } catch (e) {
      console.log(`${p} -> ERROR ${e.message}`);
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
