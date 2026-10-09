#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tempDir = Join-Path $env:TEMP ("autowake-smoke-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempDir -Force)

try {
    $runtimeDir = Join-Path $tempDir 'runtime'
    $batchDir = Join-Path $runtimeDir 'mockbatch'
    [void](New-Item -ItemType Directory -Path $batchDir -Force)
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Invoke-AutoWakeSupervisor.ps1'

    # Case 1: 全部完成 ALL_DONE
    $stateDone = @{
        Version = 1
        PausedQuota = $false
        Scope = @('mock\tasks.md')
        Tickets = @(
            @{ ID = 'T-001'; State = 'DONE'; Pid = $null },
            @{ ID = 'T-002'; State = 'DONE'; Pid = $null }
        )
    }
    [IO.File]::WriteAllText((Join-Path $batchDir 'state.json'), ($stateDone | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
    $res1 = & $scriptPath -StateDirectory $runtimeDir -RunId 'mockbatch' -Action Check
    if ($res1.Status -ne 'ALL_DONE') { throw "Case 1 failed: expected ALL_DONE, got $($res1.Status)" }

    # Case 2: 需要介入 ACTION_REQUIRED
    $stateBlocked = @{
        Version = 1
        PausedQuota = $false
        Scope = @('mock\tasks.md')
        Tickets = @(
            @{ ID = 'T-001'; State = 'DONE'; Pid = $null },
            @{ ID = 'T-002'; State = 'BLOCKED'; Reason = 'Compiler error'; Pid = $null }
        )
    }
    [IO.File]::WriteAllText((Join-Path $batchDir 'state.json'), ($stateBlocked | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
    $res2 = & $scriptPath -StateDirectory $runtimeDir -RunId 'mockbatch' -Action Check
    if ($res2.Status -ne 'ACTION_REQUIRED') { throw "Case 2 failed: expected ACTION_REQUIRED, got $($res2.Status)" }

    # Case 3: 额度等待 WAITING_QUOTA
    $futureTime = (Get-Date).AddHours(2).ToString('hh:mm tt')
    [IO.File]::WriteAllText((Join-Path $batchDir 'progress.log'), "[LOG] try again at $futureTime`r`n", [System.Text.Encoding]::UTF8)
    $stateQuota = @{
        Version = 1
        PausedQuota = $true
        QuotaPausedTicket = 'T-003'
        Scope = @('mock\tasks.md')
        Tickets = @(
            @{ ID = 'T-003'; State = 'PAUSED_QUOTA'; Pid = $null }
        )
    }
    [IO.File]::WriteAllText((Join-Path $batchDir 'state.json'), ($stateQuota | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
    $res3 = & $scriptPath -StateDirectory $runtimeDir -RunId 'mockbatch' -Action Check
    if ($res3.Status -ne 'WAITING_QUOTA') { throw "Case 3 failed: expected WAITING_QUOTA, got $($res3.Status)" }

    # Case 4: 额度时间已过 READY_TO_RESUME
    $pastTime = (Get-Date).AddHours(-2).ToString('hh:mm tt')
    [IO.File]::WriteAllText((Join-Path $batchDir 'progress.log'), "[LOG] try again at $pastTime`r`n", [System.Text.Encoding]::UTF8)
    $res4 = & $scriptPath -StateDirectory $runtimeDir -RunId 'mockbatch' -Action Check
    if ($res4.Status -ne 'READY_TO_RESUME') { throw "Case 4 failed: expected READY_TO_RESUME, got $($res4.Status)" }

    Write-Host "PASS: Smoke-AutoWake all test cases verified successfully."
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
