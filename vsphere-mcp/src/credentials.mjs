import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Gateway copy: never resolve back to the source project. Credentials come from
// the restricted PowerShell helper under this MCP folder, which reads the
// DPAPI-protected files in C:\caddy-gateway\secrets.
const bridgeDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const defaultScript = path.join(bridgeDir, "scripts", "Get-VsphereGatewayCredential.ps1");

export function loadVsphereCredentials() {
  return new Promise((resolve, reject) => {
    const script = process.env.VSPHERE_CREDENTIAL_SCRIPT || defaultScript;
    const child = spawn(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script],
      {
        cwd: bridgeDir,
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env }
      }
    );
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        return reject(new Error("The protected vSphere credential record could not be loaded."));
      }
      try {
        const value = JSON.parse(stdout);
        value.servers = Array.isArray(value.servers) && value.servers.length
          ? value.servers
          : [value.server];
        if (!value.server || !value.username || !value.password || !value.servers.length) {
          throw new Error("Incomplete credential record");
        }
        resolve(value);
      } catch {
        // Never echo stdout/stderr: either may contain sensitive material.
        reject(new Error("The protected vSphere credential record could not be loaded."));
      }
    });
  });
}
