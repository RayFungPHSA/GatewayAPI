# Caddy API Gateway setup — GitHub Copilot

## 1. Get your gateway API key

Retrieve **your own key** from Secret Server:

- Folder: `Secrets > PHSA > TSStorage Services > PHSA > GatewayAPI`
- Link: [Secret Server GatewayAPI folder](https://phsa.secretservercloud.ca/app/#/secrets/view/folder/4058)

Do not share your key or paste it into chat, tickets, documents, or source control.

## 2. Set the environment variable

Open a normal **PowerShell** window (not Administrator) and run:

```powershell
$env:CADDY_GATEWAY_TOKEN = '<key from Secret Server>'
setx CADDY_GATEWAY_TOKEN '<key from Secret Server>'
```

GitHub Copilot reads environment variables at startup. If Copilot is already running, quit it and its background processes in **Task Manager**, then restart it.

> Already using `COHESITY_GATEWAY_TOKEN`? It still works. To migrate without retyping the key, run `& 'C:\caddy-gateway\Set-GatewayTokenAlias.ps1'`, then restart Copilot. See [GATEWAY-TOKEN-VARIABLE.md](GATEWAY-TOKEN-VARIABLE.md) for rollback.

## 3. Install and sign in to GitHub Copilot

1. Install [GitHub Copilot](https://github.com/features/copilot).
2. Sign in with your **PHSA corporate account**.
3. If needed, sign up for the **GitHub Copilot Free** plan.

## 4. Paste the AI setup prompt

Open [GATEWAY-ONE-PROMPT.md](GATEWAY-ONE-PROMPT.md), copy the full prompt, and paste it into a new GitHub Copilot chat.

Do **not** paste your key into the chat. The prompt uses `CADDY_GATEWAY_TOKEN` from your environment.

## 5. Start using Copilot

Begin a natural-language chat with GitHub Copilot. The gateway MCP tools are now available through your assigned role.
