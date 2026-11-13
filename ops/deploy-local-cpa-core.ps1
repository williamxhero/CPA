[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceBinary,
    [string]$Root = 'D:\WILL\AGENT\CPA'
)
$ErrorActionPreference = 'Stop'
$opsRoot = Join-Path $Root 'ops\local-core-redeploy-20261107'
$runtimeRoot = Join-Path $Root 'runtime\CPA-Core'
$liveBinary = Join-Path $runtimeRoot 'app\cli-proxy-api.exe'
$serviceRoot = Join-Path $Root 'ops\cpa-windows-services\runtime'
$backupRoot = Join-Path $runtimeRoot ('deploy-backups\local-core-' + (Get-Date -Format 'yyyyMMddTHHmmss'))
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
$started = $false
$replaced = $false
$success = $false
$rollback = 'not-required'
New-Item -ItemType Directory -Force -Path $opsRoot | Out-Null
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
        # Stopping an already stopped service is idempotent and safe.
        if ($Action -eq 'stop' -and $LASTEXITCODE -eq 1061) {
            Write-Log "$Name stop: service already stopped (exit 1061)"
            return
        }
        throw "Service wrapper failed: $Name $Action (exit $LASTEXITCODE)"
    }
}
function Stop-CPAStack {
    foreach ($name in $stopOrder) {
        Invoke-Service $name stop
    }
    Start-Sleep -Seconds 2
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 8317,8318,18317 })
    if ($listeners.Count -gt 0) { throw 'CPA listeners remained after stop' }
}
function Start-CPAStack {
    foreach ($name in $startOrder) {
        Invoke-Service $name start
    }
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
try {
    $source = [IO.Path]::GetFullPath($SourceBinary)
    $live = [IO.Path]::GetFullPath($liveBinary)
    if (-not (Test-Path -LiteralPath $source)) { throw "Source binary missing: $source" }
    if (-not (Test-Path -LiteralPath $live)) { throw "Live binary missing: $live" }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash) { throw 'Source and live binaries are identical' }
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    Copy-Item -LiteralPath $live -Destination (Join-Path $backupRoot 'cli-proxy-api.exe') -Force
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $oldHash = (Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash
    Write-Log "Backup created: $backupRoot old=$oldHash source=$sourceHash"
    Stop-CPAStack
    Copy-Item -LiteralPath $source -Destination $live -Force
    $replaced = $true
    $deployedHash = (Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash
    if ($deployedHash -ne $sourceHash) { throw "Deployed hash mismatch: $deployedHash" }
    Start-CPAStack
    $started = $true
    $success = $true
    Write-Log "SUCCESS: CPA-Core deployed source=$source hash=$deployedHash"
    [pscustomobject]@{ Success=$true; Source=$source; Live=$live; Hash=$deployedHash; Backup=$backupRoot; Services=$startOrder; Time=(Get-Date -Format o) } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
} catch {
    $failure = $_.Exception.Message
    Write-Log "FAILED: $failure"
    try {
        Stop-CPAStack
        if ($replaced -and (Test-Path -LiteralPath (Join-Path $backupRoot 'cli-proxy-api.exe'))) {
            Copy-Item -LiteralPath (Join-Path $backupRoot 'cli-proxy-api.exe') -Destination $liveBinary -Force
            $rollbackHash = (Get-FileHash -LiteralPath $liveBinary -Algorithm SHA256).Hash
            Start-CPAStack
            $rollback = "restored:$rollbackHash"
            Write-Log "ROLLBACK SUCCESS: $rollback"
        } else {
            Start-CPAStack
            $rollback = 'service-restored-no-binary-change'
        }
    } catch {
        $rollback = 'FAILED: ' + $_.Exception.Message
        Write-Log "ROLLBACK FAILED: $rollback"
    }
    [pscustomobject]@{ Success=$false; Error=$failure; Rollback=$rollback; Backup=$backupRoot; Time=(Get-Date -Format o) } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    throw
}
