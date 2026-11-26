# Caddy MCP Gateway — team overview

The Caddy MCP Gateway lets your AI tool safely query our infrastructure using ordinary language. It connects GitHub Copilot or another MCP-capable client to seven platforms: **Cohesity, HPE GreenLake, Lansweeper, vSphere, legacy HPE 3PAR, HPE XP Performance Advisor, and Brocade SANnav**.

You use **one personal gateway key from Secret Server** via `CADDY_GATEWAY_TOKEN`. Vendor usernames and passwords stay server-side in DPAPI-protected storage, so users never handle those credentials. Most users are read-only; admins have additional Cohesity actions.

To start, follow [user-setup.md](user-setup.md), then paste the prompt from [GATEWAY-ONE-PROMPT.md](GATEWAY-ONE-PROMPT.md) into a new AI chat. Never paste your gateway key into the chat.

## Example prompts

### 1. Cross-system VM investigation

> Find all vSphere VMs with low disk space, show which datastores they are on, and summarize any recent Cohesity protection runs for those VMs.

### 2. Server-to-storage path check

> For server SQL01, use Lansweeper to confirm its OS and owner, then use Brocade SANnav to show its host ports, active zones, and connected storage ports.

### 3. Backup and recovery summary

> List Cohesity alerts and recoveries from the last 24 hours, then highlight anything that needs follow-up.

### 4. Storage capacity review

> Compare capacity and health information from HPE GreenLake, 3PAR, and XP Performance Advisor, and flag any arrays approaching a threshold.
