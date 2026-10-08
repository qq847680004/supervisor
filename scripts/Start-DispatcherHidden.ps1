#requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$TaskPaths = @('D:\2026work\work\digital-logistics\docs\scratch\data-governance\tasks.md'),
    [string]$AcceptanceManifest = 'D:\2026work\work\supervisor\acceptance-manifest.json',
    [string]$Model = 'gpt-6.1-sol',
    [ValidateSet('low','medium','high','xhigh')][string]$Effort = 'medium',
    [switch]$ResumeAfterQuota
)

$dispatcher = Join-Path $PSScriptRoot 'Invoke-CodexTicketDispatcher.ps1'
if (-not (Test-Path -LiteralPath $dispatcher)) {
    throw "Dispatcher script not found: $dispatcher"
}

$taskArgs = @()
foreach ($t in $TaskPaths) {
    $taskArgs += "'$t'"
}

$cmdArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$dispatcher`" -TaskPaths $($taskArgs -join ',') -AcceptanceManifest `"$AcceptanceManifest`" -Model `"$Model`" -Effort `"$Effort`""
if ($ResumeAfterQuota) {
    $cmdArgs += " -ResumeAfterQuota"
}

$p = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $cmdArgs -PassThru
Write-Host "主调度器已在后台完全隐藏启动，PID=$($p.Id)"
return $p
