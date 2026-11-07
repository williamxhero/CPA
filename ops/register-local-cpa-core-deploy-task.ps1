[CmdletBinding()]
param(
    [string]$Root = 'D:\WILL\AGENT\CPA',
    [string]$TaskName = 'CPA-Local-Core-Deploy'
)

$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($Root)
$runner = Join-Path $rootPath 'ops\run-local-cpa-core-deploy-task.ps1'
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this registration script from an elevated PowerShell.'
}
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Task runner missing: $runner"
}

$action = New-ScheduledTaskAction -Execute $powerShell -Argument (
    '-NoProfile -ExecutionPolicy Bypass -File "' + $runner + '" -Root "' + $rootPath + '"'
)
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType InteractiveToken -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
$definition = New-ScheduledTask -Action $action -Principal $taskPrincipal -Settings $settings -Description 'Deploy the local CPA-Core build with automatic rollback and health verification.'
Register-ScheduledTask -TaskName $TaskName -InputObject $definition -Force | Out-Null

$registered = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
[pscustomobject]@{
    taskName = $registered.TaskName
    state = [string]$registered.State
    runLevel = [string]$registered.Principal.RunLevel
    user = [string]$registered.Principal.UserId
    runner = $runner
}
