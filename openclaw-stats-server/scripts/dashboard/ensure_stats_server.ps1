# Ensure the stats server is running (Windows). Mirrors ensure_stats_server.sh.
#   powershell -ExecutionPolicy Bypass -File ensure_stats_server.ps1          # start if not running
#   powershell -ExecutionPolicy Bypass -File ensure_stats_server.ps1 -Force   # kill + restart
#   powershell -ExecutionPolicy Bypass -File ensure_stats_server.ps1 -Stop    # stop only
param(
    [switch]$Force,
    [switch]$Stop
)
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerPy  = Join-Path $ScriptDir 'stats_server.py'
$Port      = if ($env:STATS_SERVER_PORT) { [int]$env:STATS_SERVER_PORT } else { 8765 }
$LogPath   = Join-Path $env:TEMP 'stats_server.log'

function Get-StatsProcess {
    # Match on command line, like `pgrep -f stats_server.py`
    Get-CimInstance Win32_Process -Filter "Name LIKE 'python%'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*stats_server.py*' }
}

$running = @(Get-StatsProcess)
if ($running.Count -gt 0) {
    if ($Stop -or $Force) {
        Write-Host "Stopping stats server (PID: $($running.ProcessId -join ', '))..."
        $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
        if ($Stop) { exit 0 }
    } else {
        Write-Host "Stats server already running (PID: $($running.ProcessId -join ', '))"
        exit 0
    }
} elseif ($Stop) {
    Write-Host "Stats server is not running"; exit 0
}

# --- token: read from the config file. `openclaw config get gateway.auth.token`
#     returns __OPENCLAW_REDACTED__ on some builds, so never rely on it.
$Token = $env:OPENCLAW_GATEWAY_TOKEN
if (-not $Token -or $Token -eq '__OPENCLAW_REDACTED__') {
    $cfgPath = Join-Path $HOME '.openclaw\openclaw.json'
    if (Test-Path $cfgPath) {
        try { $Token = (Get-Content $cfgPath -Raw | ConvertFrom-Json).gateway.auth.token } catch { $Token = $null }
    }
}
if (-not $Token) { Write-Error 'OPENCLAW_GATEWAY_TOKEN is not set and could not be read from ~\.openclaw\openclaw.json'; exit 1 }
if ($Token -eq '__OPENCLAW_REDACTED__') { Write-Error 'token is the redacted placeholder - unset OPENCLAW_GATEWAY_TOKEN'; exit 1 }

# --- python: prefer `python`, fall back to `python3` / `py -3`
$Python = $null
foreach ($cand in @('python', 'python3')) {
    $p = Get-Command $cand -ErrorAction SilentlyContinue
    if ($p) {
        $v = & $p.Source --version 2>&1
        if ("$v" -match 'Python 3') { $Python = $p.Source; break }
    }
}
if (-not $Python) {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) { $Python = $py.Source; $PyArgs = @('-3') } else { Write-Error 'Python 3 not found in PATH'; exit 1 }
}

Write-Host 'Starting stats server...'
$env:OPENCLAW_GATEWAY_TOKEN = $Token
$argList = @()
if ($PyArgs) { $argList += $PyArgs }
$argList += "`"$ServerPy`""
$proc = Start-Process -FilePath $Python -ArgumentList $argList -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $LogPath -RedirectStandardError "$LogPath.err"

# Startup runs `openclaw config get` to resolve the workspace, which can take a few
# seconds - poll /stats/health instead of a fixed sleep.
$code = 0
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) {
        Write-Error "Stats server exited during startup - last log lines:"
        Get-Content "$LogPath.err" -Tail 10 -ErrorAction SilentlyContinue
        exit 1
    }
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/stats/health" -Headers @{ Authorization = "Bearer $Token" } `
             -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        $code = [int]$r.StatusCode
        if ($code -eq 200) { break }
    } catch { $code = 0 }
}
if ($code -eq 200) {
    Write-Host "Stats server started OK (PID: $($proc.Id), http://127.0.0.1:$Port/stats/health -> 200)"
    exit 0
}
Write-Error "process is running but /stats/health returned HTTP $code - check $LogPath and $LogPath.err"
exit 1
