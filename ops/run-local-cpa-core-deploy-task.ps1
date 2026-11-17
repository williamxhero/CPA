[CmdletBinding()]
param(
    [string]$Root = 'D:\WILL\AGENT\CPA'
)

$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($Root)
$taskResultPath = Join-Path $rootPath 'ops\local-cpa-core-deploy-task-result.json'
$deployScript = Join-Path $rootPath 'ops\deploy-local-cpa-core.ps1'
$stackDeployScript = Join-Path $rootPath 'ops\deploy-local-cpa-stack.ps1'
$sourceRoot = Join-Path $rootPath 'CPA-Core-ex'
$managerSource = Join-Path $rootPath 'local-deploy-artifacts\manager\cpa-manager-plus.exe'
$panelSource = Join-Path $rootPath 'local-deploy-artifacts\manager\management.html'
$liveManager = Join-Path $rootPath 'runtime\CPA-Manager-Plus\app\cpa-manager-plus.exe'
$livePanel = Join-Path $rootPath 'runtime\CPA-Manager-Plus\panel\management.html'
$startedAt = [DateTime]::UtcNow

function Write-TaskResult($Value) {
    $directory = Split-Path -Parent $taskResultPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = $taskResultPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $Value | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $taskResultPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $deployScript -PathType Leaf)) {
        throw 'deploy_script_missing'
    }
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw 'core_source_root_missing'
    }

    $source = Get-ChildItem -LiteralPath $sourceRoot -Directory -Filter 'local-deploy-output-*' |
        ForEach-Object { Join-Path $_.FullName 'cli-proxy-api.exe' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending |
        Select-Object -First 1
    if (-not $source) {
        throw 'core_source_binary_missing'
    }

    $sourceFull = [IO.Path]::GetFullPath($source)
    $sourcePrefix = $sourceRoot.TrimEnd('\') + '\'
    if (-not $sourceFull.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'core_source_outside_repository'
    }

    # When a Manager build is staged next to the workspace, deploy both binaries in
    # one stack restart so Core and the embedded panel cannot drift apart.
    $managerStaged = ((Test-Path -LiteralPath $managerSource -PathType Leaf) -and
        (Test-Path -LiteralPath $liveManager -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $managerSource -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $liveManager -Algorithm SHA256).Hash)) -or
        ((Test-Path -LiteralPath $panelSource -PathType Leaf) -and
            (Test-Path -LiteralPath $livePanel -PathType Leaf) -and
            ((Get-FileHash -LiteralPath $panelSource -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $livePanel -Algorithm SHA256).Hash))
    if ($managerStaged) {
        if (-not (Test-Path -LiteralPath $stackDeployScript -PathType Leaf)) { throw 'stack_deploy_script_missing' }
        $managerFull = [IO.Path]::GetFullPath($managerSource)
        $panelArgument = @{}
        if ((Test-Path -LiteralPath $panelSource -PathType Leaf) -and (Test-Path -LiteralPath $livePanel -PathType Leaf) -and
            ((Get-FileHash -LiteralPath $panelSource -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $livePanel -Algorithm SHA256).Hash)) {
            $panelArgument = @{ PanelSource = [IO.Path]::GetFullPath($panelSource) }
        }
        & $stackDeployScript -CoreBinary $sourceFull -ManagerBinary $managerFull -Root $rootPath @panelArgument
        $stackExit = $LASTEXITCODE
        if ($stackExit -and $stackExit -ne 0) {
            throw "stack_deploy_exit_$stackExit"
        }
        Write-TaskResult ([ordered]@{
                success = $true
                mode = 'core-and-manager'
                source = $sourceFull
                managerSource = $managerFull
                startedAt = $startedAt.ToString('o')
                finishedAt = [DateTime]::UtcNow.ToString('o')
                deployResult = (Join-Path $rootPath 'ops\local-stack-redeploy\deploy-result.json')
            })
        exit 0
    }

    & $deployScript -SourceBinary $sourceFull -Root $rootPath
    $deployExit = $LASTEXITCODE
    if ($deployExit -and $deployExit -ne 0) {
        throw "core_deploy_exit_$deployExit"
    }

    Write-TaskResult ([ordered]@{
            success = $true
            mode = 'core-only'
            source = $sourceFull
            startedAt = $startedAt.ToString('o')
            finishedAt = [DateTime]::UtcNow.ToString('o')
            deployResult = (Join-Path $rootPath 'ops\local-core-redeploy-20261107\deploy-result.json')
        })
    exit 0
} catch {
    Write-TaskResult ([ordered]@{
            success = $false
            error = $_.Exception.Message
            startedAt = $startedAt.ToString('o')
            finishedAt = [DateTime]::UtcNow.ToString('o')
        })
    exit 1
}
