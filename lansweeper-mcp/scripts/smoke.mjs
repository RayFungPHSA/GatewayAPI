import path from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [path.join(projectDir, "src", "server.js")],
  cwd: projectDir,
  env: { ...process.env },
  stderr: "pipe",
});

const client = new Client({ name: "lansweeper-smoke", version: "0.0.1" });

try {
  await client.connect(transport);
  const { tools } = await client.listTools();
  console.log("TOOLS:", tools.map((t) => t.name).join(", "));
  const status = await client.callTool({
    name: "lansweeper_connection_status",
    arguments: {},
  });
  console.log("STATUS:", status.content?.[0]?.text);
} finally {
  await client.close();
}
