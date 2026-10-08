$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$driver=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Invoke-CodexTicketDispatcher.ps1'
$base=Join-Path $env:TEMP ('ticket-smoke-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $base 'project'
$mod=Join-Path $repo 'docs\scratch\demo'
New-Item $mod -ItemType Directory -Force | Out-Null
try {
 & git -C $repo init -q
 [IO.File]::WriteAllText((Join-Path $repo 'AGENTS.md'),'# Test')
 $tasks=Join-Path $mod 'tasks.md'
 $t1=Join-Path $mod 'ticket-001.md'
 $t2=Join-Path $mod 'ticket-002.md'
 [IO.File]::WriteAllLines($tasks,@('- [ ] docs/scratch/demo/ticket-001.md (Blocked by: None)','- [ ] docs/scratch/demo/ticket-002.md (Blocked by: T-DEMO-001)'))
 [IO.File]::WriteAllLines($t1,@('# Ticket: T-DEMO-001','Blocked by: None','- [ ] TC-DEMO-001 test'))
 [IO.File]::WriteAllLines($t2,@('# Ticket: T-DEMO-002','Blocked by: T-DEMO-001','- [ ] TC-DEMO-002 test'))
 $checker=Join-Path $repo 'check.ps1'
 [IO.File]::WriteAllLines($checker,@('param([string]$Id)','if(-not(Test-Path (Join-Path $PSScriptRoot ("out\"+$Id+".txt")))){exit 1}','exit 0'))
 $mock=Join-Path $base 'mock.ps1'
 [IO.File]::WriteAllText($mock,'
 $msg=[Console]::In.ReadToEnd()
 $root=$env:SUP_TEST_REPO
 $n=if($msg -match "T-DEMO-002"){"002"}else{"001"}
 $id="T-DEMO-"+$n
 $counter=Join-Path $root ("count-"+$n)
 $count=if(Test-Path $counter){[int][IO.File]::ReadAllText($counter)}else{0}
 $count++;[IO.File]::WriteAllText($counter,[string]$count)
 $session=if($n -eq "001"){"11111111-1111-1111-1111-111111111111"}else{"22222222-2222-2222-2222-222222222222"}
 Write-Output ((@{type="thread.started";thread_id=$session}|ConvertTo-Json -Compress))
 Write-Output ((@{type="item.completed";item=@{type="command_execution";command="type AGENTS.md";exit_code=0}}|ConvertTo-Json -Compress))
 Write-Output ((@{type="item.completed";item=@{type="command_execution";command="type implement/SKILL.md";exit_code=0}}|ConvertTo-Json -Compress))
 if($n -eq "002" -or $count -ge 2){
  $ticket=Join-Path $root ("docs\scratch\demo\ticket-"+$n+".md")
  $tasks=Join-Path $root "docs\scratch\demo\tasks.md"
  [IO.File]::WriteAllText($ticket,([IO.File]::ReadAllText($ticket)).Replace("- [ ] TC-","- [x] TC-"))
  [IO.File]::WriteAllText($tasks,([IO.File]::ReadAllText($tasks)).Replace("- [ ] docs/scratch/demo/ticket-"+$n+".md","- [x] docs/scratch/demo/ticket-"+$n+".md"))
  $out=Join-Path $root "out"; New-Item $out -ItemType Directory -Force|Out-Null
  [IO.File]::WriteAllText((Join-Path $out ($id+".txt")),"ok")
 }
 Write-Output ((@{type="turn.completed"}|ConvertTo-Json -Compress))
 ')
 $mf=Join-Path $base 'manifest.json'
 $data=@{tickets=@{
  'T-DEMO-001'=@{deliverables=@('out/T-DEMO-001.txt');tests=@(@{file='powershell.exe';args=@('-NoProfile','-File',$checker,'-Id','T-DEMO-001')})}
  'T-DEMO-002'=@{deliverables=@('out/T-DEMO-002.txt');tests=@(@{file='powershell.exe';args=@('-NoProfile','-File',$checker,'-Id','T-DEMO-002')})}
 }}
 [IO.File]::WriteAllText($mf,($data|ConvertTo-Json -Depth 10))
 $env:SUP_TEST_REPO=$repo
 & powershell.exe -NoProfile -File $driver -TaskPaths $mod -DryRun
 if($LASTEXITCODE -ne 0){throw 'dry run failed'}
 $state=Join-Path $base 'runtime'
 & powershell.exe -NoProfile -File $driver -TaskPaths $mod -AcceptanceManifest $mf -StateDirectory $state -CodexPath $mock
 if($LASTEXITCODE -ne 0){throw 'initial dispatch failed'}
 $batch=@(Get-ChildItem $state -Directory)[0]
 $obj=[IO.File]::ReadAllText((Join-Path $batch.FullName 'state.json'))|ConvertFrom-Json
 if(@($obj.Tickets|Where-Object {$_.State -eq 'DONE'}).Count -ne 2){throw 'some tickets not DONE'}
 if(@($obj.Tickets|Where-Object {$_.ID -eq 'T-DEMO-001'})[0].Attempts.Count -ne 2){throw 'original session not resumed'}
 if(@($obj.Tickets|Where-Object {$_.ID -eq 'T-DEMO-002'})[0].Attempts.Count -ne 1){throw 'new ticket did not get a new session'}
 $progress=[IO.File]::ReadAllText((Join-Path $batch.FullName 'progress.log'),[Text.Encoding]::UTF8)
 foreach($must in @('[PLAN]','[STARTING]','[RUNNING]','[SESSION]','[VERIFY]','[TEST]','[DONE]','[ALL_DONE]','gpt-6.1-sol / medium','T-DEMO-001','T-DEMO-002','[1/2 DONE]','[2/2 DONE]')) {
  if(-not $progress.Contains($must)){throw "Progress output missing: $must"}
 }

 & powershell.exe -NoProfile -File $driver -TaskPaths $mod -AcceptanceManifest $mf -StateDirectory $state -CodexPath $mock
 if($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $repo 'count-001')) -ne '2' -or (Get-Content (Join-Path $repo 'count-002')) -ne '1'){throw 'restart double-dispatched'}
 [IO.File]::WriteAllLines($t1,@('# Ticket: T-DEMO-001','Blocked by: T-DEMO-002','- [x] TC-DEMO-001'))
 [IO.File]::WriteAllLines($tasks,@('- [x] docs/scratch/demo/ticket-001.md (Blocked by: T-DEMO-002)','- [x] docs/scratch/demo/ticket-002.md (Blocked by: T-DEMO-001)'))
 $ErrorActionPreference='Continue'
 & powershell.exe -NoProfile -File $driver -TaskPaths $mod -DryRun 2>&1 | Out-Null
 $cycleExit=$LASTEXITCODE
 $ErrorActionPreference='Stop'
 if($cycleExit -eq 0){throw 'dependency cycle was not detected'}
 Write-Host 'PASS: dry run, two tickets, same-ticket resume, independent acceptance, restart and cycle detection'
 exit 0
} finally {
 Remove-Item Env:SUP_TEST_REPO -ErrorAction SilentlyContinue
 Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}
