<#
.SYNOPSIS
    Smoke test for the Streamlit gateway dashboard and Live Status page.

.DESCRIPTION
    Verifies the dashboard files exist, Python modules compile, the Live Status
    probe helpers behave safely, and the local Streamlit health endpoint responds.
    This test is token-free and does not call authenticated MCP tools.
#>
[CmdletBinding()]
param(
    [string]$DashboardUrl = 'http://127.0.0.1:8501'
)

$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DashboardUrl = $DashboardUrl.TrimEnd('/')
$script:Passed = 0
$script:Failed = 0

function Write-Pass([string]$Name) {
    Write-Host "  PASS: $Name"
    $script:Passed++
}

function Write-Fail([string]$Name, [string]$Detail) {
    Write-Host "  FAIL: $Name - $Detail"
    $script:Failed++
}

Write-Host '=== Gateway Usage Dashboard Smoke Test ==='

foreach ($rel in @(
    'usage_dashboard.py',
    'pages\01_Live_Status.py',
    'Start-GatewayUsageDashboard.ps1',
    'Refresh-GatewayUsageDashboard.ps1'
)) {
    $path = Join-Path $RootDir $rel
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Write-Pass "File exists: $rel"
    }
    else {
        Write-Fail "File exists: $rel" 'missing'
    }
}

$pyFiles = @(
    (Join-Path $RootDir 'usage_dashboard.py'),
    (Join-Path $RootDir 'pages\01_Live_Status.py')
)
$compile = & python -m py_compile @pyFiles 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Pass 'Python compile: dashboard modules'
}
else {
    Write-Fail 'Python compile: dashboard modules' (($compile | Out-String).Trim())
}

$probeScript = @'
import json, types, sys
st = types.ModuleType('streamlit')
class _Ctx:
    def __enter__(self): return self
    def __exit__(self, *a): pass
    def metric(self,*a,**k): pass
    def markdown(self,*a,**k): pass
def noop(*a, **k): return None
st.set_page_config=noop; st.title=noop; st.caption=noop; st.error=noop; st.warning=noop; st.success=noop
st.dataframe=noop; st.button=lambda *a,**k: False; st.rerun=noop
st.columns=lambda n: [_Ctx() for _ in range(n)]
st.expander=lambda *a,**k: _Ctx()
st.fragment=lambda *a,**k: (lambda fn: fn)
sys.modules['streamlit'] = st
path = r'__LIVE_STATUS__'
code = open(path, encoding='utf-8').read().replace('\nrender_live_status()\n','\n')
mod = types.ModuleType('live_status_test')
mod.__file__ = path
sys.modules['live_status_test'] = mod
exec(compile(code, path, 'exec'), mod.__dict__)

class R:
    def __init__(self, status_code=200, text='{}', payload=None):
        self.status_code = status_code
        self.text = text
        self._payload = payload
    def json(self):
        if self._payload is None:
            raise ValueError('no json')
        return self._payload

ok, msg = mod.validate_bridge(R(payload={'ok': True, 'auth': 'gateway_token', 'credential_store': 'dpapi', 'tool_count': 9, 'acl_users': 15, 'upstream': r'C:\caddy-gateway\brocade-mcp\http_bridge.py'}), 'brocade')
assert ok == 'UP'
assert 'DPAPI' in msg
assert 'http_bridge.py' in msg
assert 'C:\\caddy-gateway' not in msg

ok, msg = mod.validate_catalog(R(payload={'version': 1, 'servers': [1,2,3,4,5,6,7]}))
assert ok == 'UP' and '7 MCP servers' in msg

ok, msg = mod.validate_vsmonitoring(R(payload={'database': 'ok', 'version': '1', 'commit': 'abc'}))
assert ok == 'UP'

checks = mod.collect_checks()
names = {(c.category, c.name) for c in checks}
required = {
    ('Gateway core', 'HTTP catalog'),
    ('Gateway core', 'HTTPS catalog'),
    ('Gateway core', 'Prometheus metrics'),
    ('Gateway core', 'Streamlit health'),
    ('Gateway core', 'Windows service'),
    ('Jobs & data', 'Usage snapshot task'),
    ('Jobs & data', 'Usage snapshot'),
    ('Other routes', 'VS Monitoring health'),
}
for n in ['cohesity','hpegreenlake','lansweeper','vsphere','3parlegacy','hpexp8','brocade']:
    required.add(('MCP via gateway', n))
    required.add(('MCP loopback', f'{n} :{8400+["cohesity","hpegreenlake","lansweeper","vsphere","3parlegacy","hpexp8","brocade"].index(n)}'))
missing = sorted(required - names)
assert not missing, missing
assert all(c.status in {'UP','DEGRADED','DOWN'} for c in checks)
print(json.dumps({'ok': True, 'checks': len(checks)}))
'@
$probeScript = $probeScript.Replace('__LIVE_STATUS__', (Join-Path $RootDir 'pages\01_Live_Status.py').Replace('\', '\\'))
$probeOutput = $probeScript | & python - 2>&1
if ($LASTEXITCODE -eq 0 -and ($probeOutput | Out-String) -match '"ok": true') {
    Write-Pass 'Live Status probe helpers'
}
else {
    Write-Fail 'Live Status probe helpers' (($probeOutput | Select-Object -Last 5 | Out-String).Trim())
}

try {
    $resp = Invoke-WebRequest -Uri "$DashboardUrl/_stcore/health" -UseBasicParsing -TimeoutSec 10
    if ($resp.StatusCode -eq 200) {
        Write-Pass "Streamlit health endpoint: $DashboardUrl/_stcore/health"
    }
    else {
        Write-Fail "Streamlit health endpoint: $DashboardUrl/_stcore/health" "HTTP $($resp.StatusCode)"
    }
}
catch {
    Write-Fail "Streamlit health endpoint: $DashboardUrl/_stcore/health" $_.Exception.Message
}

Write-Host ''
Write-Host "Result: $($script:Passed) passed, $($script:Failed) failed"
if ($script:Failed -gt 0) { exit 1 }
