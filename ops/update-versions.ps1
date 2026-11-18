<#
.SYNOPSIS
    Maintain the version of every child repository in this workspace.

.DESCRIPTION
    Repositories that track a source project carry VERSION as "{source}+{ex}":

        source  newest source-repository tag, without the leading "v"
                (CLIProxyAPI v8.0.76 -> 8.0.76)
        ex      this fork's own semantic version, e.g. 1.0.3

    Composing them gives an identity such as "8.0.76+1.0.3": the semver build
    metadata keeps the upstream release visible while the fork's own history
    stays orderable. Self-owned repositories carry the plain own version.

    The script also refreshes the generated Go constant that ordinary
    `go build` compiles, so a source merge never leaves a stale version behind.
    Every repository guards that constant with a test.

.PARAMETER Root
    Workspace root that contains the child repositories and this ops directory.

.PARAMETER BumpEx
    Bump the own version part before composing: patch, minor or major.

.PARAMETER ExVersion
    Set the own version part explicitly, for example 1.0.3. Overrides -BumpEx.

.PARAMETER BumpChanged
    Bump only the repositories with uncommitted changes. Use this when shipping
    a change so the delivered identity always moves with the requirement.

.PARAMETER Repository
    Restrict the run to specific repository directory names.

.PARAMETER Check
    Verify every VERSION and generated constant agree, then exit non-zero on
    mismatch without writing anything.

.PARAMETER DryRun
    Report the composed versions without writing any file.

.EXAMPLE
    .\ops\update-versions.ps1
    Refresh the source part of every fork after merging upstream.

.EXAMPLE
    .\ops\update-versions.ps1 -BumpChanged
    Ship the current changes: every dirty repository moves one patch version.

.EXAMPLE
    .\ops\update-versions.ps1 -Check
    Fail if a repository forgot to refresh its version after a merge.
#>
[CmdletBinding()]
param(
    [string]$Root = 'D:\WILL\AGENT\CPA',
    [ValidateSet('none', 'patch', 'minor', 'major')][string]$BumpEx = 'none',
    [string]$ExVersion = '',
    [switch]$BumpChanged,
    [string[]]$Repository = @(),
    [switch]$Check,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($Root)
$semverPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
$composedPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\+(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
$defaultExVersion = '1.0.0'

# Composed repositories follow an upstream source tag; standalone repositories
# own their whole version. Generated/Constant point at the file a test guards.
$definitions = @(
    [ordered]@{ Name = 'CPA-Core-ex'; Kind = 'composed'; Source = 'origin/main'; Generated = 'cmd\server\version_generated.go'; Package = 'main' }
    [ordered]@{ Name = 'CPA-Manager-Plus-ex'; Kind = 'composed'; Source = 'origin/main'; Generated = 'apps\manager-server\internal\buildinfo\version_generated.go'; Package = 'buildinfo' }
    [ordered]@{ Name = 'CPA-OpenCode-ex'; Kind = 'composed'; Source = 'origin/main'; Generated = 'internal\plugin\version_generated.go'; Package = 'plugin' }
    [ordered]@{ Name = 'CPA-Usage-Keeper-ex'; Kind = 'composed'; Source = 'upstream/main'; Generated = 'internal\version\version_generated.go'; Package = 'version' }
    [ordered]@{ Name = 'CPA-Aliyun-Quota'; Kind = 'standalone'; Source = ''; Generated = 'internal\plugin\version_generated.go'; Package = 'plugin' }
    [ordered]@{ Name = 'CPA-Qwen'; Kind = 'standalone'; Source = ''; Generated = 'internal\plugin\version_generated.go'; Package = 'plugin' }
)

if ($Repository.Count -gt 0) {
    $unknown = @($Repository | Where-Object { $candidate = $_; -not ($definitions | Where-Object { $_.Name -eq $candidate }) })
    if ($unknown.Count -gt 0) {
        throw "Unknown child repository: $($unknown -join ', ')"
    }
    $definitions = @($definitions | Where-Object { $Repository -contains $_.Name })
}

if ($ExVersion -and $ExVersion -notmatch $semverPattern) {
    throw "ExVersion must be major.minor.patch, got '$ExVersion'"
}

function Read-Version([string]$Path, [string]$Name, [string]$Kind) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $value = ([IO.File]::ReadAllText($Path)).Trim()
    $pattern = if ($Kind -eq 'composed') { $composedPattern } else { $semverPattern }
    if ($value -notmatch $pattern) {
        $expected = if ($Kind -eq 'composed') { 'major.minor.patch+major.minor.patch' } else { 'major.minor.patch' }
        throw "$Name VERSION must be $expected, got '$value'"
    }
    return $value
}

function Get-SourceVersion([string]$RepositoryPath, [string]$Name, [string]$SourceRef) {
    $tag = (& git -C $RepositoryPath describe --tags --abbrev=0 $SourceRef 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $tag) {
        throw "$Name has no source tag reachable from $SourceRef; fetch the source remote first"
    }
    $version = $tag.Trim() -replace '^v', ''
    if ($version -notmatch $semverPattern) {
        throw "$Name source tag '$($tag.Trim())' is not a semantic version"
    }
    return $version
}

function Get-OwnVersion([string]$Composed, [string]$Kind) {
    if ($Kind -eq 'composed') {
        return $Composed.Split('+')[1]
    }
    return $Composed
}

function Step-Version([string]$Current, [string]$Bump) {
    if ($Bump -eq 'none' -or -not $Current) {
        return $Current
    }
    $parts = @($Current.Split('.') | ForEach-Object { [int]$_ })
    switch ($Bump) {
        'major' { return ('{0}.0.0' -f ($parts[0] + 1)) }
        'minor' { return ('{0}.{1}.0' -f $parts[0], ($parts[1] + 1)) }
        'patch' { return ('{0}.{1}.{2}' -f $parts[0], $parts[1], ($parts[2] + 1)) }
    }
    throw "Unsupported bump: $Bump"
}

function Test-RepositoryDirty([string]$RepositoryPath) {
    $status = & git -C $RepositoryPath status --porcelain=v1 -uall 2>$null
    return [bool]($status | Where-Object { $_ -and -not ($_ -match '^\?\? VERSION$') })
}

function Write-GeneratedVersion([string]$Path, [string]$Package, [string]$Composed, [string]$SourceRef, [string]$Kind) {
    $lines = @(
        '// Code generated by ops/update-versions.ps1; DO NOT EDIT.'
        '//'
        "// Identity: $Composed"
        '//'
    )
    if ($Kind -eq 'composed') {
        $lines += @(
            '// The part before "+" is the newest tag reachable from ' + $SourceRef + '; the'
            '// part after it is this fork''s own maintained version.'
        )
    }
    else {
        $lines += '// This repository owns the whole version.'
    }
    $lines += @(
        '//'
        '// Re-run the script after merging a source repository or after shipping'
        '// a change, and commit both files.'
        ''
        "package $Package"
        ''
        '// generatedVersion is the version compiled into ordinary builds.'
        "const generatedVersion = `"$Composed`""
        ''
    )
    $content = $lines -join "`n"
    [IO.File]::WriteAllText($Path, $content, (New-Object Text.UTF8Encoding($false)))
}

$rows = @()
$failures = 0
foreach ($definition in $definitions) {
    $repositoryPath = Join-Path $rootPath $definition.Name
    if (-not (Test-Path -LiteralPath $repositoryPath -PathType Container)) {
        throw "Missing repository: $repositoryPath"
    }
    $versionPath = Join-Path $repositoryPath 'VERSION'
    $generatedPath = Join-Path $repositoryPath $definition.Generated
    if (-not (Test-Path -LiteralPath $generatedPath -PathType Leaf)) {
        throw "$($definition.Name) is missing the generated source $($definition.Generated); wire the constant before composing versions"
    }

    $current = Read-Version -Path $versionPath -Name $definition.Name -Kind $definition.Kind
    $own = if ($current) { Get-OwnVersion -Composed $current -Kind $definition.Kind } else { '' }

    if ($ExVersion) {
        $own = $ExVersion
    }
    elseif ($BumpChanged -and (Test-RepositoryDirty -RepositoryPath $repositoryPath)) {
        $own = Step-Version -Current $own -Bump 'patch'
        if (-not $own) { $own = $defaultExVersion }
    }
    elseif ($BumpEx -ne 'none') {
        $own = Step-Version -Current $own -Bump $BumpEx
        if (-not $own) { $own = $defaultExVersion }
    }
    if (-not $own) {
        $own = $defaultExVersion
    }

    $previousSource = ''
    if ($definition.Kind -eq 'composed') {
        $source = Get-SourceVersion -RepositoryPath $repositoryPath -Name $definition.Name -SourceRef $definition.Source
        if ($current -and $current -match $composedPattern) { $previousSource = $current.Split('+')[0] }
        $composed = "$source+$own"
    }
    else {
        $source = ''
        $composed = $own
    }

    if ($Check) {
        $generated = ([IO.File]::ReadAllText($generatedPath))
        $matchesGenerated = $generated -match [regex]::Escape("const generatedVersion = `"$composed`"")
        $state = if ($current -eq $composed -and $matchesGenerated) { 'ok' } else { 'MISMATCH' }
        if ($state -ne 'ok') { $failures++ }
        $rows += [pscustomobject]@{ Repository = $definition.Name; Version = $composed; Change = $state; Written = $false }
        continue
    }

    $note = if (-not $current) { 'initialized' }
    elseif ($previousSource -and $previousSource -ne $source) { "source $previousSource -> $source" }
    elseif ($current -ne $composed) { "own -> $own" }
    else { 'unchanged' }

    if (-not $DryRun) {
        [IO.File]::WriteAllText($versionPath, "$composed`n", (New-Object Text.UTF8Encoding($false)))
        Write-GeneratedVersion -Path $generatedPath -Package $definition.Package -Composed $composed -SourceRef $definition.Source -Kind $definition.Kind
    }

    $rows += [pscustomobject]@{ Repository = $definition.Name; Version = $composed; Change = $note; Written = (-not $DryRun) }
}

$rows | Format-Table -AutoSize
if ($Check) {
    if ($failures -gt 0) {
        Write-Output "Version check failed for $failures repository(ies). Run ops/update-versions.ps1 and commit the result."
        exit 1
    }
    Write-Output 'Version check passed.'
    exit 0
}
if ($DryRun) {
    Write-Output 'Dry run: no file was written.'
}
