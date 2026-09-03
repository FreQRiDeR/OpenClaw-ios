# One-shot setup + verification for exposing OpenClaw + the stats server over Tailscale (Windows).
# Mirrors setup_tailscale.sh.
#
#   https://<host>.<tailnet>.ts.net/        -> gateway   (127.0.0.1:18789)
#   https://<host>.<tailnet>.ts.net/stats/* -> stats srv (127.0.0.1:8765)
#   https://<host>.<tailnet>.ts.net/wa/*    -> stats srv (WhatsApp webhook, optional)
#
# Usage:  powershell -ExecutionPolicy Bypass -File setup_tailscale.ps1            # configure + verify
#         powershell -ExecutionPolicy Bypass -File setup_tailscale.ps1 -Verify    # verify only
param([switch]$Verify)
$ErrorActionPreference = 'Continue'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$GatewayPort = if ($env:OPENCLAW_GATEWAY_PORT) { [int]$env:OPENCLAW_GATEWAY_PORT } else { 18789 }
$StatsPort   = if ($env:STATS_SERVER_PORT)     { [int]$env:STATS_SERVER_PORT }     else { 8765 }
$script:Fail = $false

function Ok($m)  { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail = $true }
function Step($m){ Write-Host "`n== $m" }

# --- tailscale CLI
$TS = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
if (-not $TS) { foreach ($c in @("$env:ProgramFiles\Tailscale\tailscale.exe", "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) { if (Test-Path $c) { $TS = $c; break } } }
if (-not $TS) { Write-Error 'tailscale CLI not found'; exit 1 }

# --- token (from file; `openclaw config get` may return __OPENCLAW_REDACTED__)
$Token = $env:OPENCLAW_GATEWAY_TOKEN
if (-not $Token -or $Token -eq '__OPENCLAW_REDACTED__') {
    try { $Token = (Get-Content (Join-Path $HOME '.openclaw\openclaw.json') -Raw | ConvertFrom-Json).gateway.auth.token } catch { $Token = $null }
}
if (-not $Token) { Write-Error 'Could not read gateway token from ~\.openclaw\openclaw.json'; exit 1 }
$env:OPENCLAW_GATEWAY_TOKEN = $Token

function Test-Listening($port) {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
}

Step '1. Local services'
if (Test-Listening $GatewayPort) { Ok "gateway listening on :$GatewayPort" } else { Bad "gateway NOT listening on :$GatewayPort (run: openclaw gateway start)" }
if (-not (Test-Listening $StatsPort)) {
    if ($Verify) { Bad "stats server NOT listening on :$StatsPort" }
    else {
        Write-Host '  starting stats server...'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'dashboard\ensure_stats_server.ps1') | Out-Null
        if ($LASTEXITCODE -ne 0) { Bad "stats server failed to start (see $env:TEMP\stats_server.log)" }
    }
}
if (Test-Listening $StatsPort) { Ok "stats server listening on :$StatsPort" }

Step '2. Tailscale serve routing'
if (-not $Verify) {
    & $TS serve --bg --set-path /      "http://127.0.0.1:$GatewayPort"          2>&1 | Out-Null
    & $TS serve --bg --set-path /stats "http://127.0.0.1:$StatsPort/stats"      2>&1 | Out-Null
    & $TS serve --bg --set-path /wa    "http://127.0.0.1:$StatsPort/wa"         2>&1 | Out-Null
}
$Status = (& $TS serve status 2>&1) -join "`n"
if ($Status -match "(?m)^\|-- /\s+proxy http://127\.0\.0\.1:$GatewayPort") { Ok "/       -> :$GatewayPort" } else { Bad "/ is not proxied to :$GatewayPort" }
if ($Status -match "(?m)^\|-- /stats\s+proxy http://127\.0\.0\.1:$StatsPort") { Ok "/stats  -> :$StatsPort" } else { Bad "/stats is not proxied to :$StatsPort" }
$Host_ = if ($Status -match 'https://[^\s]+') { $Matches[0] } else { $null }
if (-not $Host_) { Bad 'tailscale serve is not enabled'; exit 1 }

Step "3. End-to-end through $Host_"
function Probe($label, $method, $path, $body, $expect) {
    $code = 0; $text = ''
    try {
        $params = @{ Uri = "$Host_$path"; Method = $method; TimeoutSec = 60; UseBasicParsing = $true
                     Headers = @{ Authorization = "Bearer $Token" } }
        if ($method -eq 'POST') { $params.ContentType = 'application/json'; $params.Body = $body }
        $r = Invoke-WebRequest @params
        $code = [int]$r.StatusCode; $text = [string]$r.Content
    } catch {
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            try { $text = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { $text = '' }
        } else { $text = $_.Exception.Message }
    }
    if ($code -eq 200 -and $text -like "*$expect*") { Ok $label; return }
    $snippet = ($text -replace '\s+', ' ')
    if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 120) }
    Bad "$label -> HTTP $code`: $snippet"
    if ($text -match '(?i)<!doctype html') { Write-Host "      -> got the gateway web UI: /stats is being routed to the gateway, not :$StatsPort" }
}
Probe 'GET  /stats/health'            GET  '/stats/health' $null '"ok": true'
Probe 'GET  /stats/system'            GET  '/stats/system' $null 'cpu_percent'
Probe 'GET  /stats/tokens'            GET  '/stats/tokens?period=today' $null 'totals'
Probe 'POST /stats/exec skills-list'  POST '/stats/exec' '{"command":"skills-list"}' '"exit_code": 0'
Probe 'POST /stats/exec memory-list'  POST '/stats/exec' '{"command":"memory-list"}' '"exit_code": 0'
Probe 'POST /stats/exec mcp-list'     POST '/stats/exec' '{"command":"mcp-list"}' '"exit_code"'
Probe 'POST /tools/invoke sessions'   POST '/tools/invoke' '{"tool":"sessions_list","args":{"limit":1}}' '"ok":true'
# OpenClaw >= 8.x renamed the CLI to `automations`; the tool may be `cron` or `automations`. Accept either.
$cronOk = $false
foreach ($t in @('cron', 'automations')) {
    try {
        $r = Invoke-WebRequest -Uri "$Host_/tools/invoke" -Method POST -ContentType 'application/json' -UseBasicParsing -TimeoutSec 60 `
             -Headers @{ Authorization = "Bearer $Token" } -Body "{`"tool`":`"$t`",`"args`":{`"action`":`"list`"}}"
        if ($r.Content -like '*"ok":true*') { Ok "POST /tools/invoke $t (automations tool name = '$t')"; $cronOk = $true; break }
    } catch { }
}
if (-not $cronOk) { Bad 'POST /tools/invoke cron/automations -> neither tool name works (Automations card will be empty)' }

Step '4. Agent ID for the iOS app'
$Agent = $null
try {
    $agentsOut = (& openclaw agents list 2>&1) -join "`n"
    if ($agentsOut -match '(?m)^- ([A-Za-z0-9_-]+) \(default\)') { $Agent = $Matches[1] }
} catch { }
if ($Agent) {
    Ok "default agent is '$Agent' - set AGENT ID = $Agent in the app (chat history uses agent:${Agent}:main)"
    Probe "POST /tools/invoke history agent:${Agent}:main" POST '/tools/invoke' "{`"tool`":`"sessions_history`",`"args`":{`"sessionKey`":`"agent:${Agent}:main`",`"limit`":1}}" '"ok":true'
} else {
    Write-Host '  (could not detect default agent; run: openclaw agents list)'
}

Write-Host ''
if (-not $script:Fail) {
    Write-Host "All good. In the iOS app use:  Gateway URL = $Host_   Agent ID = $(if ($Agent) { $Agent } else { 'main' })"
    exit 0
} else {
    Write-Host 'Some checks failed - see [FAIL] lines above.'
    exit 1
}
