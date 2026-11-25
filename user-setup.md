# GitHub Copilot & Caddy API Gateway Setup

## 1. Set the Environment Variable

Open a standard **PowerShell** terminal (do **not** run as Administrator) and run both commands to set the token for your current session and persist it for future sessions:

```powershell
$env:CADDY_GATEWAY_TOKEN = '<token issued by gateway owner>'
setx CADDY_GATEWAY_TOKEN '<token issued by gateway owner>'
```

> **Already using `COHESITY_GATEWAY_TOKEN`?** It is still accepted. Run `& 'C:\caddy-gateway\Set-GatewayTokenAlias.ps1'` to migrate without retyping your token. See [GATEWAY-TOKEN-VARIABLE.md](GATEWAY-TOKEN-VARIABLE.md) for rollback.

> **Why this matters:** GitHub Copilot reads environment variables at startup, so the token must be set before launching it. If GitHub Copilot is already running, completely quit the app and end any remaining background processes in **Task Manager** before continuing.

> **Keep your key private:** This token is your personal credential. **Do not share it with anyone**, do not paste it into chat, email, tickets, or documents, and do not commit it to source control. Only use a token that was issued to you by the gateway owner. If you believe your token has been exposed, contact the gateway owner immediately so it can be revoked and replaced.

## 2. Install and Sign In to GitHub Copilot

1. Download and install **GitHub Copilot** from [github.com/features/copilot](https://github.com/features/copilot).
2. Sign in using your **PHSA corporate account**.
3. If you don't already have access, sign up for the **GitHub Copilot Free** plan.
