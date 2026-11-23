#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
HELPER="${SCRIPT_DIR}/scripts/Get-CohesityGatewayCredential.ps1"

if command -v powershell.exe >/dev/null 2>&1; then
  PS="powershell.exe"
elif command -v powershell >/dev/null 2>&1; then
  PS="powershell"
else
  echo "Windows PowerShell is required to load the protected Cohesity credential." >&2
  exit 1
fi

JSON="$("$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$HELPER")" || {
  echo "The protected Cohesity credential could not be loaded." >&2
  exit 1
}

export COHESITY_API_KEY="$(printf '%s' "$JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["COHESITY_API_KEY"])' 2>/dev/null)" || {
  echo "The protected Cohesity credential could not be loaded." >&2
  exit 1
}
export COHESITY_NO_DOTENV=1
unset JSON

exec python3 "${SCRIPT_DIR}/cohesity_mcp.py"
