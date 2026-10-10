$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$driver = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Invoke-CodexTicketDispatcher.ps1'
$base = Join-Path $env:TEMP ('cap-smoke-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $base 'project'
$mod = Join-Path $repo 'docs\scratch\demo'
New-Item $mod -ItemType Directory -Force | Out-Null

try {
    & git -C $repo init -q
    [IO.File]::WriteAllText((Join-Path $repo 'AGENTS.md'), '# Test')
    $tasks = Join-Path $mod 'tasks.md'
    $t1 = Join-Path $mod 'ticket-001.md'
    [IO.File]::WriteAllLines($tasks, @('- [ ] docs/scratch/demo/ticket-001.md (Blocked by: None)'))
    [IO.File]::WriteAllLines($t1, @('# Ticket: T-DEMO-001', 'Blocked by: None', '- [ ] TC-DEMO-001 test'))
    
    $checker = Join-Path $repo 'check.ps1'
    [IO.File]::WriteAllLines($checker, @('param([string]$Id)', 'if(-not(Test-Path (Join-Path $PSScriptRoot ("out\"+$Id+".txt")))){exit 1}', 'exit 0'))
    
    $mock = Join-Path $base 'mock.ps1'
    $mockCode = @'
$msg = [Console]::In.ReadToEnd()
$root = $env:SUP_TEST_REPO
$counter = Join-Path $root 'count'
$count = if(Test-Path $counter){[int][IO.File]::ReadAllText($counter)}else{0}
$count++
[IO.File]::WriteAllText($counter, [string]$count)

if ($count -le 3) {
    Write-Output ((@{type="turn.failed";error=@{message="Selected model is at capacity. Please try a different model"}}|ConvertTo-Json -Compress))
    return
}

$session = "11111111-1111-1111-1111-111111111111"
Write-Output ((@{type="thread.started";thread_id=$session}|ConvertTo-Json -Compress))
Write-Output ((@{type="item.completed";item=@{type="command_execution";command="type AGENTS.md";exit_code=0}}|ConvertTo-Json -Compress))
Write-Output ((@{type="item.completed";item=@{type="command_execution";command="type implement/SKILL.md";exit_code=0}}|ConvertTo-Json -Compress))

$ticket = Join-Path $root "docs\scratch\demo\ticket-001.md"
$tasks = Join-Path $root "docs\scratch\demo\tasks.md"
[IO.File]::WriteAllText($ticket, ([IO.File]::ReadAllText($ticket)).Replace("- [ ] TC-", "- [x] TC-"))
[IO.File]::WriteAllText($tasks, ([IO.File]::ReadAllText($tasks)).Replace("- [ ] docs/scratch/demo/ticket-001.md", "- [x] docs/scratch/demo/ticket-001.md"))
$out = Join-Path $root "out"; New-Item $out -ItemType Directory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $out "T-DEMO-001.txt"), "ok")

Write-Output ((@{type="turn.completed"}|ConvertTo-Json -Compress))
'@
    [IO.File]::WriteAllText($mock, $mockCode, [Text.Encoding]::ASCII)

    $mf = Join-Path $base 'manifest.json'
    $data = @{tickets = @{
        'T-DEMO-001' = @{deliverables = @('out/T-DEMO-001.txt'); tests = @(@{file = 'powershell.exe'; args = @('-NoProfile', '-File', $checker, '-Id', 'T-DEMO-001')})}
    }}
    [IO.File]::WriteAllText($mf, ($data | ConvertTo-Json -Depth 10))
    $env:SUP_TEST_REPO = $repo
    $state = Join-Path $base 'runtime'

    & powershell.exe -NoProfile -File $driver -TaskPaths $mod -AcceptanceManifest $mf -StateDirectory $state -CodexPath $mock -Effort high
    if ($LASTEXITCODE -ne 0) { throw "Capacity dispatch failed with exit code $LASTEXITCODE" }

    $batch = @(Get-ChildItem $state -Directory)[0]
    $progress = [IO.File]::ReadAllText((Join-Path $batch.FullName 'progress.log'), [Text.Encoding]::UTF8)
    
    if ($progress -notmatch '\[CAPACITY_RETRY\]') { throw 'Missing [CAPACITY_RETRY] in progress.log' }
    if ($progress -notmatch '\[ROTATE_MODEL\]') { throw 'Missing [ROTATE_MODEL] in progress.log' }
    if ($progress -notmatch 'ROTATE_MODEL.*gpt-6-sol\s*/\s*high') { throw 'Missing rotation to gpt-6-sol / high' }

    $stateObj = [IO.File]::ReadAllText((Join-Path $batch.FullName 'state.json')) | ConvertFrom-Json
    $ticketRecord = @($stateObj.Tickets | Where-Object { $_.ID -eq 'T-DEMO-001' })[0]
    if (@($ticketRecord.Attempts).Count -ne 4) { throw "Expected 4 attempts, got $(@($ticketRecord.Attempts).Count)" }

    for ($i = 0; $i -lt 3; $i++) {
        $att = $ticketRecord.Attempts[$i]
        if ($att.Model -ne 'gpt-6.1-sol') { throw "Attempt $($i+1) model should be gpt-6.1-sol, got $($att.Model)" }
        if ($att.Effort -ne 'high') { throw "Attempt $($i+1) effort should be high, got $($att.Effort)" }
    }
    $att4 = $ticketRecord.Attempts[3]
    if ($att4.Model -ne 'gpt-6-sol') { throw "Attempt 4 model should be gpt-6-sol, got $($att4.Model)" }
    if ($att4.Effort -ne 'high') { throw "Attempt 4 effort should be high, got $($att4.Effort)" }

    Write-Host 'PASS: Capacity retry, backoff, and model rotation with High effort verified!'
    exit 0
} finally {
    Remove-Item Env:SUP_TEST_REPO -ErrorAction SilentlyContinue
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}
