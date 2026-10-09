#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$StateDirectory = '',
    [string]$RunId = '',
    [ValidateSet('Check','ResumeIfReady','Diagnose')][string]$Action = 'Check',
    [string]$DispatcherScript = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Prop([object]$obj, [string]$prop, [object]$default = $null) {
    if ($null -eq $obj -or $null -eq $obj.PSObject) { return $default }
    $p = $obj.PSObject.Properties[$prop]
    if ($null -eq $p) { return $default }
    return $p.Value
}

if (-not $StateDirectory) {
    $StateDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) '.supervisor-runtime'
}

if (-not (Test-Path -LiteralPath $StateDirectory -PathType Container)) {
    Write-Output ([pscustomobject]@{ Status = 'NO_RUNTIME'; Message = "Runtime directory not found: $StateDirectory" })
    return
}

# 定位目标批次目录
$targetBatchDir = $null
if ($RunId) {
    $p = Join-Path $StateDirectory $RunId
    if (Test-Path -LiteralPath $p) { $targetBatchDir = $p }
} else {
    $dirs = @(Get-ChildItem -LiteralPath $StateDirectory -Directory | Sort-Object LastWriteTime -Descending)
    if ($dirs.Count -gt 0) { $targetBatchDir = $dirs[0].FullName }
}

if (-not $targetBatchDir) {
    Write-Output ([pscustomobject]@{ Status = 'NO_BATCH'; Message = 'No dispatch batch directory found.' })
    return
}

$stateFile = Join-Path $targetBatchDir 'state.json'
if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
    Write-Output ([pscustomobject]@{ Status = 'NO_STATE'; Message = "state.json missing in $targetBatchDir" })
    return
}

$state = [IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$tickets = @(Get-Prop $state 'Tickets' @())
$totalCount = $tickets.Count
$doneCount = @($tickets | Where-Object { (Get-Prop $_ 'State') -eq 'DONE' }).Count

# 检查当前是否仍有进程存活
$activePid = $null
foreach ($t in $tickets) {
    $pidVal = Get-Prop $t 'Pid'
    if ($pidVal) {
        $p = Get-Process -Id ([int]$pidVal) -ErrorAction SilentlyContinue
        if ($null -ne $p) {
            $activePid = [int]$pidVal
            break
        }
    }
}

if ($activePid) {
    $res = [pscustomobject]@{
        Status = 'ACTIVE_RUNNING'
        BatchDir = $targetBatchDir
        ActivePid = $activePid
        Progress = "$doneCount/$totalCount DONE"
        Message = "Dispatcher child process PID=$activePid is currently active."
    }
    Write-Output $res
    return
}

# 检查是否全部完成
if ($doneCount -eq $totalCount -and $totalCount -gt 0) {
    $res = [pscustomobject]@{
        Status = 'ALL_DONE'
        BatchDir = $targetBatchDir
        Progress = "$doneCount/$totalCount DONE"
        Message = 'All tickets independently verified.'
    }
    Write-Output $res
    return
}

# 检查是否因额度暂停 (PAUSED_QUOTA)
if (Get-Prop $state 'PausedQuota' $false) {
    $pausedTicketId = [string](Get-Prop $state 'QuotaPausedTicket' '')
    
    # 查找最近一次额度耗尽日志中的重置时间
    $resetTimeFound = $null
    $resetPattern = '(?i)try again at\s+([0-9]{1,2}:[0-9]{2}(?:\s*[AaPp][Mm])?)'
    
    $progLog = Join-Path $targetBatchDir 'progress.log'
    if (Test-Path -LiteralPath $progLog) {
        $recentLines = @(Get-Content -LiteralPath $progLog -Tail 100)
        foreach ($line in $recentLines) {
            if ($line -match $resetPattern) {
                $resetTimeFound = $Matches[1].Trim()
            }
        }
    }

    # 计算时间差
    $readyToResume = $true
    $remainingSeconds = 0
    if ($resetTimeFound) {
        try {
            $parsedReset = [datetime]::Parse($resetTimeFound)
            if ([datetime]::Now -lt $parsedReset) {
                $readyToResume = $false
                $remainingSeconds = [int](($parsedReset - [datetime]::Now).TotalSeconds)
            }
        } catch {}
    }

    if (-not $readyToResume) {
        $res = [pscustomobject]@{
            Status = 'WAITING_QUOTA'
            BatchDir = $targetBatchDir
            PausedTicket = $pausedTicketId
            ResetTargetTime = $resetTimeFound
            RemainingSeconds = $remainingSeconds
            Progress = "$doneCount/$totalCount DONE"
            Message = "Quota not yet reset. Target time: $resetTimeFound (remaining ~$remainingSeconds s)."
        }
        Write-Output $res
        return
    }

    # 额度重置时间已过，满足自动恢复条件
    if ($Action -eq 'ResumeIfReady') {
        $launcher = if ($DispatcherScript) { $DispatcherScript } else { Join-Path $PSScriptRoot 'Start-DispatcherHidden.ps1' }
        if (Test-Path -LiteralPath $launcher) {
            $scope = @(Get-Prop $state 'Scope' @())
            $taskPath = if ($scope.Count -gt 0) { $scope[0] } else { '' }
            $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'acceptance-manifest.json'
            $p = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher,'-TaskPaths',$taskPath,'-AcceptanceManifest',$manifest,'-ResumeAfterQuota') -PassThru
            $res = [pscustomobject]@{
                Status = 'RESUMED'
                BatchDir = $targetBatchDir
                NewPid = $p.Id
                PausedTicket = $pausedTicketId
                Progress = "$doneCount/$totalCount DONE"
                Message = "Auto-resumed dispatcher in background with PID=$($p.Id)."
            }
            Write-Output $res
            return
        }
    }

    $res = [pscustomobject]@{
        Status = 'READY_TO_RESUME'
        BatchDir = $targetBatchDir
        PausedTicket = $pausedTicketId
        Progress = "$doneCount/$totalCount DONE"
        Message = 'Quota reset window passed. Safe to resume dispatch.'
    }
    Write-Output $res
    return
}

# 检查是否有失败/阻塞的 Ticket
$blocked = @($tickets | Where-Object { 
    $st = Get-Prop $_ 'State'
    $st -eq 'BLOCKED' -or $st -eq 'NEEDS_FIX' 
})

if ($blocked.Count -gt 0) {
    $firstBlocked = $blocked[0]
    $diagnosis = 'Unknown failure'
    $receipt = [string](Get-Prop $firstBlocked 'AcceptanceReceipt' '')
    if ($receipt -and (Test-Path -LiteralPath $receipt)) {
        try {
            $rcJson = [IO.File]::ReadAllText($receipt, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if (-not (Get-Prop $rcJson 'Okay' $true)) {
                $diagnosis = "Acceptance test failed: $(Get-Prop $rcJson 'Reason' '')"
            }
        } catch {}
    }

    $bid = [string](Get-Prop $firstBlocked 'ID' 'UNKNOWN')
    $bst = [string](Get-Prop $firstBlocked 'State' '')
    $brs = [string](Get-Prop $firstBlocked 'Reason' '')

    $res = [pscustomobject]@{
        Status = 'ACTION_REQUIRED'
        BatchDir = $targetBatchDir
        Ticket = $bid
        TicketState = $bst
        Reason = $brs
        Diagnosis = $diagnosis
        Progress = "$doneCount/$totalCount DONE"
        Message = "Ticket $bid is $($bst): $diagnosis"
    }
    Write-Output $res
    return
}

# 其它空闲状态
Write-Output ([pscustomobject]@{
    Status = 'IDLE'
    BatchDir = $targetBatchDir
    Progress = "$doneCount/$totalCount DONE"
    Message = 'Dispatcher is currently idle.'
})
