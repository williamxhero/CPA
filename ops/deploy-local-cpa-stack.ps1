[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CoreBinary,
    [Parameter(Mandatory=$true)][string]$ManagerBinary,
    [string]$PanelSource = '',
    [string]$Root = 'D:\WILL\AGENT\CPA'
)
$ErrorActionPreference = 'Stop'
$opsRoot = Join-Path $Root 'ops\local-stack-redeploy'
$coreRoot = Join-Path $Root 'runtime\CPA-Core'
$managerRoot = Join-Path $Root 'runtime\CPA-Manager-Plus'
$liveCore = Join-Path $coreRoot 'app\cli-proxy-api.exe'
$liveManager = Join-Path $managerRoot 'app\cpa-manager-plus.exe'
# CPAMP serves the panel from this file when config.json sets panelPath; the
# embedded copy inside the Manager binary is then ignored.
$livePanel = Join-Path $managerRoot 'panel\management.html'
$serviceRoot = Join-Path $Root 'ops\cpa-windows-services\runtime'
$backupRoot = Join-Path $opsRoot ('backup-' + (Get-Date -Format 'yyyyMMddTHHmmss'))
$logPath = Join-Path $opsRoot 'deploy.log'
$resultPath = Join-Path $opsRoot 'deploy-result.json'
$services = [ordered]@{
    LocalCPA = Join-Path $serviceRoot 'LocalCPA.exe'
    CPAUsageKeeper = Join-Path $Root 'runtime\CPA-Usage-Keeper\CPAUsageKeeperService.exe'
    LocalCPAManagerPlus = Join-Path $serviceRoot 'LocalCPAManagerPlus.exe'
}
# Usage Keeper must come up with Core before Manager: incomplete restarts that
# leave it stopped make OpenCode/common quota refresh surface as
# common_refresh_unavailable in the panel.
$startOrder = @('LocalCPA','CPAUsageKeeper','LocalCPAManagerPlus')
$stopOrder = @('LocalCPAManagerPlus','CPAUsageKeeper','LocalCPA')
$replaced = @()
$success = $false
$rollback = 'not-required'
New-Item -ItemType Directory -Force -Path $opsRoot | Out-Null
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $logPath -Value (('{0} {1}' -f (Get-Date -Format o), $Message)) -Encoding UTF8
}
function Invoke-Service([string]$Name, [ValidateSet('start','stop')][string]$Action) {
    $wrapper = $services[$Name]
    if (-not (Test-Path -LiteralPath $wrapper)) { throw "Missing service wrapper: $wrapper" }
    & $wrapper $Action 2>&1 | ForEach-Object { Write-Log ("$Name ${Action}: $_") }
    if ($LASTEXITCODE -ne 0) {
        # The dependency-aware LocalCPA wrapper can report 1061 after the
        # dependent Manager service was already stopped by Stop-CPAStack.
        if ($Action -eq 'stop' -and $LASTEXITCODE -eq 1061) {
            Write-Log "$Name stop: service already stopped (exit 1061)"
            return
        }
        throw "Service wrapper failed: $Name $Action (exit $LASTEXITCODE)"
    }
}
function Stop-CPAStack {
    foreach ($name in $stopOrder) { Invoke-Service $name stop }
    Start-Sleep -Seconds 2
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 8317,8318,18317 })
    if ($listeners.Count -gt 0) { throw 'CPA listeners remained after stop' }
}
function Start-CPAStack {
    foreach ($name in $startOrder) { Invoke-Service $name start }
    $checks = @(
        @{ Name='LocalCPA'; Url='http://127.0.0.1:8317/management.html' },
        @{ Name='LocalCPAManagerPlus'; Url='http://127.0.0.1:18317/health' },
        @{ Name='CPAUsageKeeper'; Url='http://127.0.0.1:8318/readyz' }
    )
    foreach ($check in $checks) {
        $ready = $false
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
            try {
                $response = Invoke-WebRequest -Uri $check.Url -UseBasicParsing -TimeoutSec 5
                if ($response.StatusCode -eq 200) { $ready = $true; break }
            } catch { }
            Start-Sleep -Seconds 2
        }
        if (-not $ready) { throw "Readiness failed: $($check.Name) $($check.Url)" }
        Write-Log "Ready: $($check.Name)"
    }
}
function Restore-Binaries {
    foreach ($item in @(
            @{ Live = $liveCore; Backup = (Join-Path $backupRoot 'cli-proxy-api.exe') },
            @{ Live = $liveManager; Backup = (Join-Path $backupRoot 'cpa-manager-plus.exe') },
            @{ Live = $livePanel; Backup = (Join-Path $backupRoot 'management.html') }
        )) {
        if (Test-Path -LiteralPath $item.Backup) {
            Copy-Item -LiteralPath $item.Backup -Destination $item.Live -Force
            Write-Log ('restored ' + $item.Live + ' sha256=' + (Get-FileHash -LiteralPath $item.Live -Algorithm SHA256).Hash)
        }
    }
}
try {
    $sources = [ordered]@{
        $liveCore = [IO.Path]::GetFullPath($CoreBinary)
        $liveManager = [IO.Path]::GetFullPath($ManagerBinary)
    }
    $hashes = @{}
    foreach ($pair in $sources.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $pair.Value -PathType Leaf)) { throw "Source binary missing: $($pair.Value)" }
        if (-not (Test-Path -LiteralPath $pair.Key -PathType Leaf)) { throw "Live binary missing: $($pair.Key)" }
        $sourceHash = (Get-FileHash -LiteralPath $pair.Value -Algorithm SHA256).Hash
        $liveHash = (Get-FileHash -LiteralPath $pair.Key -Algorithm SHA256).Hash
        if ($sourceHash -eq $liveHash) {
            # Partial rollouts (e.g. panel-only) deploy one binary at a time.
            Write-Log ('unchanged ' + $pair.Key + '; skipped')
            $hashes[$pair.Key] = $null
            continue
        }
        $hashes[$pair.Key] = $sourceHash
    }
    # Partial rollouts (e.g. panel-only) deploy one artifact at a time; only
    # require that something actually changes.
    if (-not (@($hashes.Values | Where-Object { $_ }).Count) -and -not $PanelSource) {
        throw 'No artifact differs from the live deployment'
    }
    Copy-Item -LiteralPath $liveCore -Destination (Join-Path $backupRoot 'cli-proxy-api.exe') -Force
    Copy-Item -LiteralPath $liveManager -Destination (Join-Path $backupRoot 'cpa-manager-plus.exe') -Force
    Write-Log "Backup created: $backupRoot"
    Stop-CPAStack
    if ($PanelSource) {
        $panelFull = [IO.Path]::GetFullPath($PanelSource)
        if (-not (Test-Path -LiteralPath $panelFull -PathType Leaf)) { throw "Panel source missing: $panelFull" }
        if (-not (Test-Path -LiteralPath $livePanel -PathType Leaf)) { throw "Live panel missing: $livePanel" }
        $panelSourceHash = (Get-FileHash -LiteralPath $panelFull -Algorithm SHA256).Hash
        if ($panelSourceHash -ne (Get-FileHash -LiteralPath $livePanel -Algorithm SHA256).Hash) {
            Copy-Item -LiteralPath $livePanel -Destination (Join-Path $backupRoot 'management.html') -Force
            Copy-Item -LiteralPath $panelFull -Destination $livePanel -Force
            $deployedPanelHash = (Get-FileHash -LiteralPath $livePanel -Algorithm SHA256).Hash
            if ($deployedPanelHash -ne $panelSourceHash) { throw 'Deployed panel hash mismatch' }
            $replaced += $livePanel
            Write-Log ('replaced ' + $livePanel + ' sha256=' + $deployedPanelHash)
        } else {
            Write-Log 'panel already current; skipped'
        }
    }
    foreach ($pair in $sources.GetEnumerator()) {
        if (-not $hashes[$pair.Key]) {
            Write-Log ('skipped ' + $pair.Key + ' (already current)')
            continue
        }
        Copy-Item -LiteralPath $pair.Value -Destination $pair.Key -Force
        $replaced += $pair.Key
        $deployedHash = (Get-FileHash -LiteralPath $pair.Key -Algorithm SHA256).Hash
        if ($deployedHash -ne $hashes[$pair.Key]) { throw "Deployed hash mismatch: $($pair.Key)" }
        Write-Log ('replaced ' + $pair.Key + ' sha256=' + $deployedHash)
    }
    Start-CPAStack
    $success = $true
    Write-Log 'SUCCESS: local CPA stack deployed'
    [pscustomobject]@{
        Success = $true
        Core = [pscustomobject]@{ Source = $sources[$liveCore]; Live = $liveCore; Hash = $hashes[$liveCore] }
        Manager = [pscustomobject]@{ Source = $sources[$liveManager]; Live = $liveManager; Hash = $hashes[$liveManager] }
        Panel = if ($PanelSource) { [pscustomobject]@{ Source = [IO.Path]::GetFullPath($PanelSource); Live = $livePanel } } else { $null }
        Backup = $backupRoot
        Services = $startOrder
        Time = (Get-Date -Format o)
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
} catch {
    $failure = $_.Exception.Message
    Write-Log "FAILED: $failure"
    try {
        Stop-CPAStack
        if ($replaced.Count -gt 0) {
            Restore-Binaries
            $rollback = 'restored-from-backup'
        } else {
            $rollback = 'service-restored-no-binary-change'
        }
        Start-CPAStack
        Write-Log "ROLLBACK: $rollback"
    } catch {
        $rollback = 'FAILED: ' + $_.Exception.Message
        Write-Log "ROLLBACK FAILED: $rollback"
    }
    [pscustomobject]@{ Success = $false; Error = $failure; Rollback = $rollback; Backup = $backupRoot; Time = (Get-Date -Format o) } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    throw
}
