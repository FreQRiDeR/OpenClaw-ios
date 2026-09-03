# OpenClaw iOS - server-side one-shot installer (Windows). Mirrors install.sh.
#
# Installs the stats server the iOS app depends on, starts it, wires up Tailscale
# and verifies every endpoint the app uses.
#
# Run in PowerShell on the machine that hosts your OpenClaw gateway:
#
#   From a clone:     powershell -ExecutionPolicy Bypass -File .\install.ps1
#   Without a clone:  irm https://raw.githubusercontent.com/FreQRiDeR/OpenClaw-ios/main/install.ps1 | iex
#
# Options:
#   -NoTailscale     install + start the server only
#   -Dest DIR        install location (default: ~\.openclaw\openclaw-stats-server)
#   -Force           overwrite an existing install without asking
#
# Env overrides: OPENCLAW_GATEWAY_PORT (18789), STATS_SERVER_PORT (8765)
param(
    [switch]$NoTailscale,
    [string]$Dest = (Join-Path $HOME '.openclaw\openclaw-stats-server'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$RepoRaw = 'https://raw.githubusercontent.com/FreQRiDeR/OpenClaw-ios/main'

function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]    $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Die($m)  { Bad $m; exit 1 }
function Step($m) { Write-Host "`n== $m" }

# When piped through `irm | iex` there is no script file / directory.
$ScriptDir = $null
if ($MyInvocation.MyCommand.Path) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---------------------------------------------------------------------------
Step '1. Prerequisites'
$Python = $null
foreach ($cand in @('python', 'python3')) {
    $p = Get-Command $cand -ErrorAction SilentlyContinue
    if ($p) { $v = & $p.Source --version 2>&1; if ("$v" -match 'Python (3\.\d+)') { $Python = $p.Source; Ok "python $($Matches[1]) ($($p.Source))"; break } }
}
if (-not $Python) { Die 'Python 3 not found in PATH - install from https://www.python.org/downloads/windows/ and tick "Add to PATH"' }
if (Get-Command openclaw -ErrorAction SilentlyContinue) { Ok 'openclaw CLI' } else { Die 'openclaw CLI not found in PATH - install OpenClaw first' }
$Config = Join-Path $HOME '.openclaw\openclaw.json'
if (Test-Path $Config) { Ok "config: $Config" } else { Die "no $Config - run 'openclaw' once to create it" }
$cfg = Get-Content $Config -Raw | ConvertFrom-Json
$Token = $cfg.gateway.auth.token
if ($Token) { Ok "gateway token found ($($Token.Length) chars)" } else { Die "gateway.auth.token missing in $Config" }

$DoTailscale = -not $NoTailscale
if ($DoTailscale) {
    $ts = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $ts -and (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) { $ts = $true }
    if ($ts) { Ok 'tailscale CLI' } else { Warn 'tailscale CLI not found - will install + start the server, but skip proxy setup'; $DoTailscale = $false }
}

# ---------------------------------------------------------------------------
Step '2. Gateway config the app needs'
# Warn-only: we never edit openclaw.json for you.
if ($cfg.gateway.http.endpoints.chatCompletions.enabled -eq $true) { Ok 'gateway.http.endpoints.chatCompletions.enabled = true' }
else { Warn 'Chat will not work: set gateway.http.endpoints.chatCompletions = {"enabled": true}' }
if ($cfg.tools.sessions.visibility -eq 'all') { Ok 'tools.sessions.visibility = all' }
else { Warn 'Sessions tab will be empty: set tools.sessions.visibility = "all"' }
$need = @('exec', 'cron', 'gateway', 'sessions_list', 'sessions_history', 'memory_get')
$allow = $cfg.tools.allow
if (-not $allow -and ($null -eq $cfg.tools.profile -or $cfg.tools.profile -eq 'full')) { Ok 'tools.allow not set - full profile, all tools available' }
else {
    $missing = $need | Where-Object { $allow -notcontains $_ }
    if ($missing) { Warn "tools.allow is missing: $($missing -join ', ')  (Automations / Sessions / Memory cards need these)" }
    else { Ok 'tools.allow includes everything the app uses' }
}

# ---------------------------------------------------------------------------
Step '3. Locate stats server files'
$SrcDir = $null; $SrcZip = $null; $TmpDl = $null
if ($ScriptDir -and (Test-Path (Join-Path $ScriptDir 'openclaw-stats-server\scripts\dashboard\stats_server.py'))) {
    $SrcDir = Join-Path $ScriptDir 'openclaw-stats-server'; Ok "using repo checkout: $SrcDir"
} elseif ($ScriptDir -and (Test-Path (Join-Path $ScriptDir 'docs\openclaw-stats-server.zip'))) {
    $SrcZip = Join-Path $ScriptDir 'docs\openclaw-stats-server.zip'; Ok "using bundled zip: $SrcZip"
} else {
    $TmpDl = Join-Path $env:TEMP ("ocss-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $TmpDl | Out-Null
    $SrcZip = Join-Path $TmpDl 'openclaw-stats-server.zip'
    Write-Host "  downloading $RepoRaw/docs/openclaw-stats-server.zip ..."
    try { Invoke-WebRequest -Uri "$RepoRaw/docs/openclaw-stats-server.zip" -OutFile $SrcZip -UseBasicParsing } catch { Die "download failed: $($_.Exception.Message)" }
    Ok ("downloaded {0:N0} KB" -f ((Get-Item $SrcZip).Length / 1KB))
}

# ---------------------------------------------------------------------------
Step "4. Install to $Dest"
if ((Test-Path $Dest) -and -not $Force) {
    if ([Environment]::UserInteractive -and $Host.Name -ne 'ServerRemoteHost') {
        $ans = Read-Host "  $Dest already exists. Overwrite? [y/N]"
        if ($ans -notmatch '^[yY]') { Write-Host '  aborted'; exit 1 }
    } else { Warn "$Dest exists - overwriting (non-interactive; pass -Force to silence)" }
}
# Stop a running instance so we don't replace files under it
$running = Get-CimInstance Win32_Process -Filter "Name LIKE 'python%'" | Where-Object { $_.CommandLine -like '*stats_server.py*' }
if ($running) { $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Start-Sleep 1; Ok 'stopped running stats server' }

New-Item -ItemType Directory -Path (Split-Path -Parent $Dest) -Force | Out-Null
if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
if ($SrcDir) {
    Copy-Item $SrcDir $Dest -Recurse
} else {
    $Ex = Join-Path $env:TEMP ("ocss-x-" + [guid]::NewGuid().ToString('N'))
    Expand-Archive -Path $SrcZip -DestinationPath $Ex -Force
    # zip contains a top-level openclaw-stats-server/ folder (+ macOS __MACOSX junk)
    $inner = Get-ChildItem $Ex -Recurse -Filter stats_server.py | Where-Object { $_.FullName -notlike '*__MACOSX*' -and $_.DirectoryName -like '*scripts?dashboard' } | Select-Object -First 1
    if (-not $inner) { Die 'stats_server.py not found inside zip' }
    $root = $inner.Directory.Parent.Parent.FullName
    Move-Item $root $Dest
    Remove-Item $Ex -Recurse -Force -ErrorAction SilentlyContinue
}
if ($TmpDl) { Remove-Item $TmpDl -Recurse -Force -ErrorAction SilentlyContinue }
Get-ChildItem $Dest -Recurse -Force -Include '.DS_Store' | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem $Dest -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
& $Python -m py_compile (Join-Path $Dest 'scripts\dashboard\stats_server.py')
if ($LASTEXITCODE -ne 0) { Die 'stats_server.py failed to compile' }
Get-ChildItem $Dest -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Ok "installed $((Get-ChildItem $Dest -Recurse -File).Count) files"

# ---------------------------------------------------------------------------
Step '5. Start stats server'
Remove-Item Env:\OPENCLAW_GATEWAY_TOKEN -ErrorAction SilentlyContinue   # let ensure script read the real token from the config file
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'scripts\dashboard\ensure_stats_server.ps1') -Force
if ($LASTEXITCODE -ne 0) {
    Bad 'stats server did not come up - last log lines:'
    Get-Content (Join-Path $env:TEMP 'stats_server.log.err') -Tail 10 -ErrorAction SilentlyContinue
    exit 1
}

# ---------------------------------------------------------------------------
if ($DoTailscale) {
    Step '6. Tailscale routing + end-to-end verification'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'scripts\setup_tailscale.ps1')
    if ($LASTEXITCODE -ne 0) { exit 1 }
} else {
    Step '6. Tailscale skipped'
    Write-Host '  Expose these two ports behind ONE hostname (/stats -> 8765, everything else -> 18789).'
    Write-Host "  Then: powershell -ExecutionPolicy Bypass -File $Dest\scripts\setup_tailscale.ps1 -Verify"
}

# ---------------------------------------------------------------------------
Step 'Done'
Write-Host @"
  Installed to: $Dest

  Day-to-day:
    start/restart   powershell -ExecutionPolicy Bypass -File $Dest\scripts\dashboard\ensure_stats_server.ps1 -Force
    stop            powershell -ExecutionPolicy Bypass -File $Dest\scripts\dashboard\ensure_stats_server.ps1 -Stop
    health check    powershell -ExecutionPolicy Bypass -File $Dest\scripts\setup_tailscale.ps1 -Verify
    logs            Get-Content $env:TEMP\stats_server.log -Wait

  The server does not auto-start on reboot (by design). Re-run the start command after a restart.
"@
