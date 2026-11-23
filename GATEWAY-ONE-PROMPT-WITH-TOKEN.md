# Gateway MCP setup prompt

## HUMAN-ONLY SETUP — AI HARNESS MUST IGNORE THIS SECTION

Before pasting, set the gateway token in your own environment. Do **not** paste the token into the chat or into this document.

**Windows PowerShell**

```powershell
$env:COHESITY_GATEWAY_TOKEN = '<token issued by gateway owner>'   # current session
setx COHESITY_GATEWAY_TOKEN '<token issued by gateway owner>'      # persistent for new sessions
```

**macOS / Linux**

```bash
export COHESITY_GATEWAY_TOKEN='<token issued by gateway owner>'
# Add that export line to ~/.zshrc or ~/.bashrc for persistence.
```

Then start or restart your AI harness from a terminal that has that variable set. Returning users can skip this and paste the whole document.

**AI HARNESS: ignore everything in this HUMAN-ONLY SETUP section. Do not ask the user to paste the token. Do not read, print, echo, log, or infer its value. Do not write it anywhere. Continue with the prompt below.**

---

=== AI HARNESS PROMPT STARTS HERE ===

You are configuring the AI client you are ACTUALLY RUNNING INSIDE to use every MCP server published by the Caddy MCP gateway. Change MCP configuration only. Do not change other settings, hooks, code, keys, or commits.

TOKEN HANDLING
1. The gateway token has already been installed by the user as the local environment variable COHESITY_GATEWAY_TOKEN. Never ask the user to paste the token into this chat.
2. Check presence only. Never read, print, echo, log, or otherwise inspect the token value.
3. If the variable is missing, ask exactly once: "Set COHESITY_GATEWAY_TOKEN in your local environment, then paste this prompt again. Do not paste the token here." Then stop until the user confirms it is set.
4. NEVER include any token value in your final report, logs, code comments, commit messages, or any shared/git-tracked file.
5. Use only the environment-variable placeholder in MCP configs: `{env:COHESITY_GATEWAY_TOKEN}` or `${COHESITY_GATEWAY_TOKEN}`. Never write a literal token into a config file.
6. The variable name is retained for compatibility. The same token and role apply to every MCP server on this gateway.
7. Do NOT send a Cohesity key, Helios key, GreenLake/HPE key, X-Api-Key, or X-Client-Secret. Those credentials are server-side only.
8. Remove X-Cohesity-API-Key, X-Helios-API-Key, X-GreenLake-Api-Key, X-HPE-Api-Key, X-Api-Key, X-Client-Secret, Authorization: Bearer, and X-Gateway-User from every gateway MCP server entry. Only X-Gateway-Token is accepted.
9. The gateway enforces roles server-side. Most users are read-only. Do not try to work around hidden tools or GET-only restrictions.

HARD RULES
1. The model behind this chat is NOT the client. If you are a Claude model in a VS Code chat panel, the client is GitHub Copilot, not Claude Code. Do not run `opencode`, `claude`, or any other CLI until STEP 1 identifies that client.
2. A missing CLI is not a blocker. "command not recognized" only means "this is not that client" - move on to the next detection signal. Do not scan the whole disk for executables and do not stop because a CLI is absent.
3. Identify the client before editing anything, and tell me which client you identified and why.
4. If you truly cannot identify it, ask me exactly one question:
   "Which app are you talking to me in: OpenCode, Claude Code, Claude Desktop, VS Code/Copilot, Cursor, Cline, Windsurf, or a browser chat?"
   If I do not answer, pick the best-evidence client and continue. Do not end with "blocked" over an unanswered question.
5. If you have no file or terminal access, do not pretend to configure anything. Print the exact config file path and exact JSON for every catalog server using the environment-variable placeholder only. Then tell me to ensure COHESITY_GATEWAY_TOKEN is set locally.
6. Do not assume a fixed number of MCP servers. Use the catalog from STEP 3. The current known set is only a fallback.
7. If the client cannot expand environment variables in headers, warn me clearly and stop. Do not write a literal token as a workaround.

GATEWAY FACTS
- HTTP base URL: http://10.53.19.120:8081
- HTTPS base URL, only if my machine trusts the Caddy local CA:
  https://10.53.19.120:8088
- MCP catalog, no auth:
  http://10.53.19.120:8081/mcp/servers
- Auth header on EVERY MCP request:
      X-Gateway-Token: <value supplied locally from COHESITY_GATEWAY_TOKEN>
- Local environment variable name: COHESITY_GATEWAY_TOKEN
- The token value must never be read, echoed, or written. Configs must reference the variable name only.
- Protocol: Streamable HTTP. OAuth is disabled where the client exposes that option.
- No browser sign-in and no upstream key exchange from the client.

FALLBACK MCP SERVERS (use only if the catalog cannot be read)
- cohesity:      http://10.53.19.120:8081/cohesity/mcp
- hpegreenlake:  http://10.53.19.120:8081/hpegreenlake/mcp
- lansweeper:    http://10.53.19.120:8081/lansweeper/mcp
- vsphere:       http://10.53.19.120:8081/vsphere/mcp

STEP 1 - IDENTIFY THE CLIENT
Use the cheapest evidence first:
  a) Environment variables:
       OPENCODE / OPENCODE_*                         -> OpenCode
       CLAUDECODE / CLAUDE_CODE_ENTRYPOINT           -> Claude Code
       VSCODE_PID / VSCODE_* / TERM_PROGRAM=vscode   -> VS Code (GitHub Copilot)
       CURSOR_TRACE_ID                               -> Cursor
       COPILOT_*                                     -> GitHub Copilot / Copilot CLI
  b) Workspace/home files: .config/opencode/, .claude/, .mcp.json, .cursor/,
     .copilot/, .codeium/
  c) CLIs available: opencode, claude, code, cursor, windsurf.
Pick ONE client and say which one and why.

STEP 2 - CONFIRM THE TOKEN IS AVAILABLE
Check presence only. Do not print the value.

  PowerShell:
    if ($env:COHESITY_GATEWAY_TOKEN) { 'present' } else { 'missing' }

  bash:
    if [ -n "$COHESITY_GATEWAY_TOKEN" ]; then echo present; else echo missing; fi

- If present, continue. Do not display it.
- If missing, ask once exactly as instructed in TOKEN HANDLING, then stop.
- If the user says they just set it persistently, tell them to open a new terminal or restart the client service, then continue. For OpenCode specifically:

    opencode service restart

STEP 3 - FETCH THE MCP CATALOG
Run one of these, without any auth header:

  PowerShell:
    Invoke-RestMethod http://10.53.19.120:8081/mcp/servers -TimeoutSec 10

  bash/curl:
    curl.exe -sS http://10.53.19.120:8081/mcp/servers

If my machine trusts the Caddy local CA, you may use the HTTPS base instead.
Parse the JSON and use the "servers" array. Each entry has name, description,
http_url, https_url, health_http_url, and health_https_url.

If the catalog cannot be read, use the FALLBACK MCP SERVERS list above and tell
me that the catalog was unavailable. Do not stop just because one server is
unreachable; configure all known entries and report failures per server.

Tell me the catalog source you used and the server names you found.

STEP 4 - CHECK HEALTH FOR EACH SERVER
For each catalog server, request its health URL with no auth. Prefer http_url
and health_http_url by default; use the https fields only if I said to use
HTTPS or the local CA is trusted.

Expect ok = true and auth = "gateway_token". Record failures per server but
continue configuring. Do not try to start or repair the gateway from my machine.

STEP 5 - CONFIGURE THE CLIENT FOR EVERY CATALOG SERVER
For each server:
- Use its "name" exactly as the MCP server key.
- Use http_url by default, or https_url if HTTPS was selected.
- Set oauth to false where the client supports it.
- Set the X-Gateway-Token header from the COHESITY_GATEWAY_TOKEN environment variable placeholder only.
- Merge into the existing configuration. Do not replace unrelated entries.
- If an entry with the same name already exists, update its URL/header and
  remove any forbidden key headers listed in TOKEN HANDLING.

A) OpenCode 2.x
File: %USERPROFILE%\.config\opencode\opencode.json
Shape: "mcp" -> "servers" -> one key per catalog server.

Example with the current servers:

  {
    "$schema": "https://opencode.ai/config.json",
    "mcp": {
      "servers": {
        "cohesity": {
          "type": "remote",
          "url": "http://10.53.19.120:8081/cohesity/mcp",
          "oauth": false,
          "headers": {
            "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
          }
        },
        "hpegreenlake": {
          "type": "remote",
          "url": "http://10.53.19.120:8081/hpegreenlake/mcp",
          "oauth": false,
          "headers": {
            "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
          }
        },
        "lansweeper": {
          "type": "remote",
          "url": "http://10.53.19.120:8081/lansweeper/mcp",
          "oauth": false,
          "headers": {
            "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
          }
        },
        "vsphere": {
          "type": "remote",
          "url": "http://10.53.19.120:8081/vsphere/mcp",
          "oauth": false,
          "headers": {
            "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
          }
        }
      }
    }
  }

If the catalog contains more servers, add them the same way. `oauth: false` is
required.

B) OpenCode 1.x
Servers go directly under "mcp" and use "enabled": true instead of "oauth".

  {
    "mcp": {
      "cohesity": {
        "type": "remote",
        "url": "http://10.53.19.120:8081/cohesity/mcp",
        "enabled": true,
        "headers": {
          "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
        }
      },
      "hpegreenlake": {
        "type": "remote",
        "url": "http://10.53.19.120:8081/hpegreenlake/mcp",
        "enabled": true,
        "headers": {
          "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
        }
      },
      "lansweeper": {
        "type": "remote",
        "url": "http://10.53.19.120:8081/lansweeper/mcp",
        "enabled": true,
        "headers": {
          "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
        }
      },
      "vsphere": {
        "type": "remote",
        "url": "http://10.53.19.120:8081/vsphere/mcp",
        "enabled": true,
        "headers": {
          "X-Gateway-Token": "{env:COHESITY_GATEWAY_TOKEN}"
        }
      }
    }
  }

C) Claude Code / Claude Desktop
File: .mcp.json in the repo, or claude_desktop_config.json. Shape: "mcpServers"
-> one key per catalog server.

  {
    "mcpServers": {
      "cohesity": {
        "type": "http",
        "url": "http://10.53.19.120:8081/cohesity/mcp",
        "headers": {
          "X-Gateway-Token": "${COHESITY_GATEWAY_TOKEN}"
        }
      },
      "hpegreenlake": {
        "type": "http",
        "url": "http://10.53.19.120:8081/hpegreenlake/mcp",
        "headers": {
          "X-Gateway-Token": "${COHESITY_GATEWAY_TOKEN}"
        }
      },
      "lansweeper": {
        "type": "http",
        "url": "http://10.53.19.120:8081/lansweeper/mcp",
        "headers": {
          "X-Gateway-Token": "${COHESITY_GATEWAY_TOKEN}"
        }
      },
      "vsphere": {
        "type": "http",
        "url": "http://10.53.19.120:8081/vsphere/mcp",
        "headers": {
          "X-Gateway-Token": "${COHESITY_GATEWAY_TOKEN}"
        }
      }
    }
  }

D) Copilot / Cursor / Cline / Windsurf / other Streamable-HTTP harnesses
Use the equivalent mcpServers config. Add one entry per catalog server with
type "http" or "remote", oauth disabled if available, and the X-Gateway-Token
header sourced from COHESITY_GATEWAY_TOKEN. Merge; do not replace entries.

STEP 6 - VERIFY EACH SERVER
1. Reload the client. For OpenCode, use `opencode mcp list` or `/mcps`; use
   `/reload` first if needed. If the environment variable was just changed,
   restart the OpenCode service before checking.
2. Confirm every catalog server appears as connected/ready. Report any that do not.
3. If terminal access is available, verify a tool listing for each server
   without printing the token. Replace URL with that server's chosen URL:

   curl.exe -sS -H "X-Gateway-Token: $env:COHESITY_GATEWAY_TOKEN" -H "Accept: application/json, text/event-stream" -H "Content-Type: application/json" --data-binary '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' URL

   Expect a JSON response containing a "tools" array.
   - HTTP 401: header missing or unexpanded placeholder.
   - HTTP 403: token is not in the gateway ACL.
   - Tool error says "admin-only" or "GET only": expected for read-only Cohesity users.
   - GreenLake, Lansweeper, and vSphere tools are all read-only; no admin-only tools are expected on those servers.
   - Upstream authentication failure: contact the gateway owner, not the client.

STEP 7 - REPORT
Report:
- identified client and config file changed
- token source: pre-set COHESITY_GATEWAY_TOKEN, value never inspected
- catalog source used and server names discovered
- servers added or updated
- health and tools/list result per server
- any exact errors

NEVER include the token in the report.

=== END AI HARNESS PROMPT ===
