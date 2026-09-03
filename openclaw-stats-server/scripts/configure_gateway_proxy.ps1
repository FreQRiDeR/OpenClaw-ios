# Configure OpenClaw for an externally-managed Tailscale Serve reverse proxy.
# Safely edits structured JSON (avoids Windows PowerShell -> native CLI quote loss).
# Creates a timestamped backup and restores it if `openclaw config validate` fails.
param([switch]$NoRestart)
$ErrorActionPreference = 'Stop'

$ConfigPath = Join-Path $HOME '.openclaw\openclaw.json'
if (-not (Test-Path $ConfigPath)) { Write-Error "Config not found: $ConfigPath"; exit 1 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupPath = "$ConfigPath.proxy-backup-$stamp"
$TempPath = "$ConfigPath.proxy-temp-$PID"
Copy-Item $ConfigPath $BackupPath -Force
Write-Host "Backup: $BackupPath"

try {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not $cfg.gateway) { throw 'gateway section is missing' }

    # The external Tailscale Serve targets 127.0.0.1:18789, so trust only that
    # immediate proxy hop. Keep token auth; disable OpenClaw-owned Tailscale Serve.
    $cfg.gateway | Add-Member -NotePropertyName trustedProxies -NotePropertyValue @('127.0.0.1') -Force
    $cfg.gateway | Add-Member -NotePropertyName bind -NotePropertyValue 'loopback' -Force
    if (-not $cfg.gateway.auth) {
        $cfg.gateway | Add-Member -NotePropertyName auth -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $cfg.gateway.auth | Add-Member -NotePropertyName mode -NotePropertyValue 'token' -Force
    $cfg.gateway.auth | Add-Member -NotePropertyName allowTailscale -NotePropertyValue $false -Force
    if (-not $cfg.gateway.tailscale) {
        $cfg.gateway | Add-Member -NotePropertyName tailscale -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $cfg.gateway.tailscale | Add-Member -NotePropertyName mode -NotePropertyValue 'off' -Force
    $json = $cfg | ConvertTo-Json -Depth 100
    # UTF-8 without BOM; write a temp file then replace the config.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($TempPath, $json + [Environment]::NewLine, $utf8)
    Move-Item $TempPath $ConfigPath -Force
    $validation = (& openclaw config validate 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "OpenClaw rejected the updated config:`n$validation" }

    $check = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $trusted = @($check.gateway.trustedProxies)
    if ($trusted.Count -ne 1 -or $trusted[0] -ne '127.0.0.1') { throw 'trustedProxies was not written as the expected one-element array' }

    Write-Host '[OK] gateway.trustedProxies = ["127.0.0.1"]' -ForegroundColor Green
    Write-Host '[OK] gateway.auth.mode = token' -ForegroundColor Green
    Write-Host '[OK] gateway.auth.allowTailscale = false' -ForegroundColor Green
    Write-Host '[OK] gateway.tailscale.mode = off' -ForegroundColor Green
    Write-Host '[OK] gateway.bind = loopback' -ForegroundColor Green
    # Configuration transaction is complete. A later process-control failure must
    # NOT roll back this validated config — restart and config validity are separate.
    Write-Host "Configuration saved and validated. Backup retained at: $BackupPath"
} catch {
    Write-Host "CONFIGURATION FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path $TempPath) { Remove-Item $TempPath -Force -ErrorAction SilentlyContinue }
    Copy-Item $BackupPath $ConfigPath -Force
    Write-Host "Restored original config from: $BackupPath" -ForegroundColor Yellow
    exit 1
}

if (-not $NoRestart) {
    Write-Host 'Restarting gateway...'
    & openclaw gateway restart
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'CONFIG IS VALID AND WAS RETAINED, but automatic gateway restart failed.' -ForegroundColor Yellow
        Write-Host 'Port 18789 is owned by a gateway process that OpenClaw could not verify/control.' -ForegroundColor Yellow
        Write-Host 'Close the terminal running the gateway, or identify the listener with:'
        Write-Host '  Get-NetTCPConnection -State Listen -LocalPort 18789 | Select-Object LocalAddress,LocalPort,OwningProcess'
        Write-Host '  Get-Process -Id <OwningProcess>'
        Write-Host 'Then start it again with: openclaw gateway start'
        exit 2
    }
}
Write-Host 'Done.'
exit 0
