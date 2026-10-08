#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$dispatcher=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Invoke-CodexTicketDispatcher.ps1'
$base=Join-Path $env:TEMP ('quota-pause-smoke-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $base 'repo'
$module=Join-Path $repo 'docs\scratch\demo'
$runtime=Join-Path $base 'runtime'
New-Item -ItemType Directory -Force $module | Out-Null
try {
 & git -C $repo init -q
 [IO.File]::WriteAllText((Join-Path $repo 'AGENTS.md'),'# Target project rules')
 $tasks=Join-Path $module 'tasks.md'
 [IO.File]::WriteAllLines($tasks,@(
  '- [ ] docs/scratch/demo/ticket-001.md (Blocked by: None)',
  '- [ ] docs/scratch/demo/ticket-002.md (Blocked by: T-QUOTA-001)'
 ))
 [IO.File]::WriteAllLines((Join-Path $module 'ticket-001.md'),@('# Ticket: T-QUOTA-001','Blocked by: None','- [ ] TC-QUOTA-001 acceptance'))
 [IO.File]::WriteAllLines((Join-Path $module 'ticket-002.md'),@('# Ticket: T-QUOTA-002','Blocked by: T-QUOTA-001','- [ ] TC-QUOTA-002 acceptance'))
 $checker=Join-Path $repo 'check.ps1'
 [IO.File]::WriteAllLines($checker,@(
  'param([string]$Id)',
  'if(Test-Path -LiteralPath (Join-Path $PSScriptRoot ("out\"+$Id+".txt"))){exit 0}',
  'exit 1'
 ))
 $mock=Join-Path $base 'fake-codex.ps1'
 [IO.File]::WriteAllText($mock,'
 $prompt=[Console]::In.ReadToEnd()
 $root=$env:QUOTA_TEST_REPO
 $num=if($prompt -match "T-QUOTA-002"){"002"}else{"001"}
 $id="T-QUOTA-"+$num
 $counter=Join-Path $root ("calls-"+$num+".txt")
 $n=if(Test-Path $counter){[int][IO.File]::ReadAllText($counter)}else{0}
 $n++;[IO.File]::WriteAllText($counter,[string]$n)
 $session=if($num -eq "001"){"11111111-1111-1111-1111-111111111111"}else{"22222222-2222-2222-2222-222222222222"}
 Write-Output ((@{type="thread.started";thread_id=$session}|ConvertTo-Json -Compress))
 if($env:QUOTA_TEST_RESTORED -ne "1"){
  Write-Output ((@{type="error";message="You have hit your usage limit. Try again after your quota resets."}|ConvertTo-Json -Compress))
  exit 1
 }
 Write-Output ((@{type="item.completed";item=@{type="command_execution";command="type AGENTS.md";exit_code=0}}|ConvertTo-Json -Compress))
 Write-Output ((@{type="item.completed";item=@{type="command_execution";command="type implement/SKILL.md";exit_code=0}}|ConvertTo-Json -Compress))
 $ticket=Join-Path $root ("docs\scratch\demo\ticket-"+$num+".md")
 $tasks=Join-Path $root "docs\scratch\demo\tasks.md"
 [IO.File]::WriteAllText($ticket,([IO.File]::ReadAllText($ticket)).Replace("- [ ] TC-","- [x] TC-"))
 [IO.File]::WriteAllText($tasks,([IO.File]::ReadAllText($tasks)).Replace("- [ ] docs/scratch/demo/ticket-"+$num+".md","- [x] docs/scratch/demo/ticket-"+$num+".md"))
 $out=Join-Path $root "out"; New-Item -ItemType Directory -Path $out -Force | Out-Null
 [IO.File]::WriteAllText((Join-Path $out ($id+".txt")),"ok")
 Write-Output ((@{type="turn.completed"}|ConvertTo-Json -Compress))
 ')
 $mf=Join-Path $base 'acceptance.json'
 $data=@{tickets=@{
  'T-QUOTA-001'=@{deliverables=@('out/T-QUOTA-001.txt');tests=@(@{file='powershell.exe';args=@('-NoProfile','-File',$checker,'-Id','T-QUOTA-001')})}
  'T-QUOTA-002'=@{deliverables=@('out/T-QUOTA-002.txt');tests=@(@{file='powershell.exe';args=@('-NoProfile','-File',$checker,'-Id','T-QUOTA-002')})}
 }}
 [IO.File]::WriteAllText($mf,($data | ConvertTo-Json -Depth 12))
 $env:QUOTA_TEST_REPO=$repo
 Remove-Item Env:QUOTA_TEST_RESTORED -ErrorAction SilentlyContinue
 $params=@('-NoProfile','-File',$dispatcher,'-TaskPaths',$module,'-AcceptanceManifest',$mf,'-StateDirectory',$runtime,'-CodexPath',$mock)
 & powershell.exe @params
 if($LASTEXITCODE -ne 3){throw "Quota must pause with exit code 3, got $LASTEXITCODE"}
 $batch=@(Get-ChildItem -LiteralPath $runtime -Directory)[0].FullName
 $state=[IO.File]::ReadAllText((Join-Path $batch 'state.json')) | ConvertFrom-Json
 if(-not $state.PausedQuota -or $state.QuotaPausedTicket -ne 'T-QUOTA-001'){throw 'No persisted quota pause'}
 if(@($state.Tickets | Where-Object {$_.ID -eq 'T-QUOTA-001'})[0].State -ne 'PAUSED_QUOTA'){throw 'Missing paused Ticket state'}
 if((Get-Content (Join-Path $repo 'calls-001.txt')) -ne '1' -or (Test-Path (Join-Path $repo 'calls-002.txt'))){throw 'Dispatcher continued after quota error'}
 $progress=[IO.File]::ReadAllText((Join-Path $batch 'progress.log'))
 if(-not $progress.Contains('[PAUSED_QUOTA]')){throw 'No visible pause status'}
 & powershell.exe @params -RetryBlocked
 if($LASTEXITCODE -ne 3){throw 'Rerun or -RetryBlocked must not bypass quota pause'}
 if((Get-Content (Join-Path $repo 'calls-001.txt')) -ne '1'){throw 'Pause rerun retried automatically'}
 $env:QUOTA_TEST_RESTORED='1'
 & powershell.exe @params -ResumeAfterQuota
 if($LASTEXITCODE -ne 0){throw 'Manual resume failed'}
 $state=[IO.File]::ReadAllText((Join-Path $batch 'state.json')) | ConvertFrom-Json
 if($state.PausedQuota -or @($state.Tickets|Where-Object {$_.State -eq 'DONE'}).Count -ne 2){throw 'Resume did not complete all tickets'}
 $a=@($state.Tickets|Where-Object {$_.ID -eq 'T-QUOTA-001'})[0]
 $b=@($state.Tickets|Where-Object {$_.ID -eq 'T-QUOTA-002'})[0]
 if($a.Attempts.Count -ne 2 -or $a.Attempts[1].Mode -ne 'resume' -or $b.Attempts.Count -ne 1 -or $b.Attempts[0].Mode -ne 'new'){throw 'Session continuity broken'}
 if((Get-Content (Join-Path $repo 'calls-001.txt')) -ne '2' -or (Get-Content (Join-Path $repo 'calls-002.txt')) -ne '1'){throw 'Unexpected call count'}
 Write-Host 'PASS: quota pause, no next Ticket, persistent pause, no implicit retry, explicit same-session resume'
 exit 0
} finally {
 Remove-Item Env:QUOTA_TEST_REPO -ErrorAction SilentlyContinue
 Remove-Item Env:QUOTA_TEST_RESTORED -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
