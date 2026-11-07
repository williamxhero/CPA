[CmdletBinding()]
param(
    [string]$Root = 'D:\WILL\AGENT\CPA',
    [string]$TaskName = 'CPA-Local-Core-Deploy',
    [ValidateRange(10, 1800)][int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($Root)
$resultPath = Join-Path $rootPath 'ops\local-cpa-core-deploy-task-result.json'
$beforeWrite = if (Test-Path -LiteralPath $resultPath) { (Get-Item -LiteralPath $resultPath).LastWriteTimeUtc } else { [DateTime]::MinValue }

& schtasks.exe /Run /TN $TaskName | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not start scheduled task: $TaskName"
}

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $resultPath) {
        $item = Get-Item -LiteralPath $resultPath
        if ($item.LastWriteTimeUtc -gt $beforeWrite) {
            $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            $result
            if ($result.success -eq $true) { exit 0 }
            exit 1
        }
    }
} while ([DateTime]::UtcNow -lt $deadline)

throw "Scheduled task did not write a result within $TimeoutSeconds seconds: $resultPath"
