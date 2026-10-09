#requires -Version 5.1
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string[]]$TaskPaths,
 [string]$AcceptanceManifest,
 [string]$StateDirectory='',
 [string]$RunId,
 [string]$CodexPath='codex.cmd',
 [string]$Model='gpt-6.1-sol',
 [ValidateSet('low','medium','high','xhigh')][string]$Effort='medium',
 [ValidateRange(1,10)][int]$MaxAttemptsPerTicket=3,
 [ValidateRange(0,86400)][int]$ProcessTimeoutSeconds=0,
 [switch]$DryRun,
 [switch]$RetryBlocked,
 [switch]$ResumeAfterQuota
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# Windows PowerShell 5.1: use UTF-8 for readable multilingual terminal progress.
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch {}
try {
 $mPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
 $uPath = [Environment]::GetEnvironmentVariable('Path', 'User')
 if($mPath -or $uPath) {
  $parts = @(($mPath + ';' + $uPath) -split ';' | Where-Object {$_} | Select-Object -Unique)
  $env:Path = ($parts -join ';')
 }
} catch {}
if (-not $StateDirectory) { $StateDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) '.supervisor-runtime' }
$script:RuntimeFile=$null
$script:State=$null
$script:Manifest=$null
$script:ProgressPath=$null
function Resolve-Exact([string]$Path) {
 if(-not [IO.Path]::IsPathRooted($Path)){throw "Absolute path required: $Path"}
 return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
}
function Inside([string]$Root,[string]$Path) {
 $r=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
 $p=[IO.Path]::GetFullPath($Path)
 return $p.Equals($r,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
function SHA([string]$Text) {
 $h=[Security.Cryptography.SHA256]::Create()
 try {return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()} finally {$h.Dispose()}
}
function Atomically-Save([string]$Path,[object]$Value) {
 $tmp="$Path.$([guid]::NewGuid().ToString('N')).tmp"
 try {
  [IO.File]::WriteAllText($tmp,($Value | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
  if([IO.File]::Exists($Path)){[IO.File]::Replace($tmp,$Path,($Path+'.bak'))}else{[IO.File]::Move($tmp,$Path)}
 } finally {if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
function Save-State {Atomically-Save $script:RuntimeFile $script:State}
function Write-DispatchProgress([string]$Phase,[string]$TicketId,[string]$Detail) {
 $count=0;$total=0
 if($null -ne $script:State){
  $total=@($script:State.Tickets).Count
  $count=@($script:State.Tickets | Where-Object {$_.State -eq 'DONE'}).Count
 }
 $at=[datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
 $line="[$at] [$Phase] [$count/$total DONE] [$TicketId] $Detail"
 Write-Host $line
 if($script:ProgressPath){[IO.File]::AppendAllText($script:ProgressPath,$line+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))}
}
function Git-Root([string]$Dir){
 $cur=Resolve-Exact $Dir
 $candidate=$null
 while($cur){
  if(Test-Path -LiteralPath (Join-Path $cur '.git')){
   if(Test-Path -LiteralPath (Join-Path $cur 'AGENTS.md') -PathType Leaf){
    $candidate=$cur
   }
  }
  $parent=Split-Path $cur -Parent
  if(-not $parent -or $parent -eq $cur){break}
  $cur=$parent
 }
 if($candidate){return $candidate}
 try {
  $r=@(& git -C $Dir rev-parse --show-toplevel 2>$null)
  if($LASTEXITCODE -eq 0 -and $r.Count -eq 1){
   $p=Resolve-Exact $r[0].Trim()
   if(Test-Path -LiteralPath (Join-Path $p 'AGENTS.md') -PathType Leaf){return $p}
  }
 } catch {}
 throw "Target AGENTS.md missing or not a Git repo: $Dir"
}
function Ids([string]$Text) {
 return @([regex]::Matches($Text,'(?<![A-Za-z0-9])T-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+(?![A-Za-z0-9-])') | ForEach-Object {$_.Value.ToUpperInvariant()} | Sort-Object -Unique)
}
function Read-Tickets([string[]]$Inputs) {
 $tickets=New-Object Collections.Generic.List[object]
 $seenTasks=@{};$seenIDs=@{};$seenPaths=@{}
 foreach($given in $Inputs) {
  $abs=Resolve-Exact $given
  $file=if(Test-Path -LiteralPath $abs -PathType Container){Join-Path $abs 'tasks.md'}else{$abs}
  $file=Resolve-Exact $file
  if([IO.Path]::GetFileName($file) -cne 'tasks.md'){throw "Expected tasks.md: $given"}
  if($seenTasks.ContainsKey($file.ToLowerInvariant())){continue}
  $seenTasks[$file.ToLowerInvariant()]=$true
  $module=Split-Path $file -Parent
  $root=Git-Root $module
  $rows=[IO.File]::ReadAllLines($file)
  for($i=0;$i -lt $rows.Length;$i++){
   $row=$rows[$i]
   if($row -notmatch '^\s*(?:[-*]|\d+\.)\s+\[(?<mark>[ xX])\]\s+(?<body>.+)$'){continue}
   $body=$Matches['body'];$checked=($Matches['mark'] -eq 'x' -or $Matches['mark'] -eq 'X')
   $links=@([regex]::Matches($body,'(?<p>(?:[A-Za-z]:[\\/]|\.{1,2}[\\/]|docs[\\/])?[^\s\(\)\[\]\x60"''<>]+\.md)') | ForEach-Object {$_.Groups['p'].Value})
   if($links.Count -ne 1){throw "Exactly one ticket path required at $($file):$($i+1); found $($links.Count)"}
   $rel=$links[0].Replace('/','\')
   if([IO.Path]::IsPathRooted($rel)){throw "Absolute ticket paths in tasks.md require separate authorization: $rel"}
   $base=if($rel.StartsWith('.\')){$module}else{$root}
   $location=Resolve-Exact (Join-Path $base $rel)
   if(-not (Inside $root $location)){throw "Ticket path escapes repo: $location"}
   $txt=[IO.File]::ReadAllText($location)
   $heading=[regex]::Match($txt,'(?m)^\s*#\s*Ticket:\s*\[?(?<id>T-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+)\]?\b')
   if(-not $heading.Success){throw "Missing Ticket heading: $location"}
   $id=$heading.Groups['id'].Value.ToUpperInvariant()
   $depMatch=[regex]::Match($txt,'(?im)^\s*(?:[-*]\s*)?(?:\*\*)?Blocked by(?:\*\*)?\s*:\s*(?<deps>[^\r\n]+)')
   $rowDep=[regex]::Match($body,'(?i)Blocked by\s*:\s*(?<deps>[^\r\n\)]+)')
   $fileDeps=if($depMatch.Success){@(Ids $depMatch.Groups['deps'].Value)}else{@()}
   $rowDeps=if($rowDep.Success){@(Ids $rowDep.Groups['deps'].Value)}else{@()}
   if($depMatch.Success -and $rowDep.Success -and ($fileDeps -join '|') -cne ($rowDeps -join '|')){throw "Conflicting dependencies: $id"}
   $deps=if($depMatch.Success){$fileDeps}else{$rowDeps}
   $key=$root.ToLowerInvariant()+'|'+$id
   if($seenIDs.ContainsKey($key) -or $seenPaths.ContainsKey($location.ToLowerInvariant())){throw "Duplicate Ticket ID/path: $location"}
   $seenIDs[$key]=$true;$seenPaths[$location.ToLowerInvariant()]=$true
   $tickets.Add([pscustomobject]@{Key=$key;ID=$id;Root=$root;TasksPath=$file;TicketPath=$location;Module=$module;Line=$i+1;Checked=$checked;Dependencies=@($deps);Text=$txt})
  }
 }
 if($tickets.Count -eq 0){throw "No Tickets found in selected tasks.md"}
 return @($tickets.ToArray())
}
function Check-Graph([object[]]$Tickets) {
 $map=@{};foreach($t in $Tickets){$map[$t.Key]=$t}
 $done=@{};$visiting=@{}
 function Visit([object]$t){
  if($visiting.ContainsKey($t.Key)){throw "Dependency cycle at $($t.ID)"}
  if($done.ContainsKey($t.Key)){return}
  $visiting[$t.Key]=$true
  foreach($id in $t.Dependencies){
   $key=$t.Root.ToLowerInvariant()+'|'+$id
   if($map.ContainsKey($key)){Visit $map[$key]}
  }
  $visiting.Remove($t.Key);$done[$t.Key]=$true
 }
 foreach($t in $Tickets){Visit $t}
}
function Get-Record([string]$Key){
 foreach($r in @($script:State.Tickets)){if($r.Key -ceq $Key){return $r}}
 throw "Missing persisted Ticket $Key"
}
function Ticket-Checks([string]$Text){
 $checks=@([regex]::Matches($Text,'(?im)^\s*[-*]\s+\[(?<mark>[ xX])\]\s+.*?\b(?<id>TC-[A-Za-z0-9-]+)\b'))
 if($checks.Count -eq 0){return [pscustomobject]@{All=$false;Reason='No TC-* checkboxes'}}
 $pending=@($checks | Where-Object {$_.Groups['mark'].Value -notmatch '[xX]'} | ForEach-Object {$_.Groups['id'].Value})
 $unique=@($checks | ForEach-Object {$_.Groups['id'].Value} | Sort-Object -Unique)
 if($unique.Count -ne $checks.Count){return [pscustomobject]@{All=$false;Reason='Duplicate TC identifiers'}}
 return [pscustomobject]@{All=($pending.Count -eq 0);Reason=($pending -join ', ')}
}
function Manifest-Entry([string]$Id){
 $p=$script:Manifest.tickets.PSObject.Properties[$Id]
 if($null -eq $p){throw "Acceptance manifest missing Ticket $Id"}
 $entry=$p.Value
 if($null -eq $entry.deliverables -or @($entry.deliverables).Count -eq 0 -or $null -eq $entry.tests -or @($entry.tests).Count -eq 0){throw "Ticket $Id needs deliverables and tests"}
 return $entry
}
function Safe-Delivery([string]$Root,[string]$Relative){
 if([IO.Path]::IsPathRooted($Relative)){throw "Deliverables must be repo relative: $Relative"}
 $p=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
 if(-not (Inside $Root $p)){throw "Path escapes repo: $Relative"}
 return $p
}
function PS-Literal([string]$s){return "'"+$s.Replace("'","''")+"'"}
function Encoded-Launcher([string]$Exe,[string[]]$Argv,[string]$ExitFile) {
 $parts=@($Argv | ForEach-Object {PS-Literal $_})
 $code='$ErrorActionPreference=''Stop''; $ProgressPreference=''SilentlyContinue''; $rc=99; try { & '+(PS-Literal $Exe)+' @('+($parts -join ',')+'); $ok=$?; $rc=$LASTEXITCODE; if($null -eq $rc){if($ok){$rc=0}else{$rc=99}} } catch {[Console]::Error.WriteLine($_.Exception.Message);$rc=99} finally {[IO.File]::WriteAllText('+(PS-Literal $ExitFile)+',[string]$rc)};exit $rc'
 return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
}
function Launch-Command([string]$Exe,[string[]]$Argv,[string]$Cwd,[string]$InputFile,[string]$Stdout,[string]$Stderr,[string]$ExitFile){
 $encoded=Encoded-Launcher $Exe $Argv $ExitFile
 return (Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WorkingDirectory $Cwd -RedirectStandardInput $InputFile -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru)
}
function Read-LinesShared([string]$Path){
 if(-not [IO.File]::Exists($Path)){return @()}
 $fs=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{$rd=New-Object IO.StreamReader($fs);try{$raw=$rd.ReadToEnd()}finally{$rd.Dispose()};return @($raw -split '\r?\n' | Where-Object {$_ -ne ''})}finally{$fs.Dispose()}
}
function Sync-Events([object]$Record,[object]$Attempt){
 if($null -eq $Attempt.PSObject.Properties['ProgressOffset']) {
  $Attempt | Add-Member -NotePropertyName ProgressOffset -NotePropertyValue 0
  $Attempt | Add-Member -NotePropertyName ProgressCommands -NotePropertyValue 0
  $Attempt | Add-Member -NotePropertyName LastEventUtc -NotePropertyValue $null
 }
 $lines=@(Read-LinesShared $Attempt.Stdout)
 $index=[int]$Attempt.ProgressOffset
 $changed=$false
 while($index -lt $lines.Count){
  try{$e=$lines[$index] | ConvertFrom-Json -ErrorAction Stop}catch{break}
  $index++
  $changed=$true
  $Attempt.LastEventUtc=[datetime]::UtcNow.ToString('o')
  if($e.type -eq 'thread.started' -and $null -ne $e.thread_id -and $e.thread_id -match '^[a-f0-9-]{36}$'){
   if($Record.SessionId -and $Record.SessionId -cne $e.thread_id){throw "Session ID mismatch for $($Record.ID)"}
   if(-not $Record.SessionId) {
    $Record.SessionId=$e.thread_id
    Save-State
    Write-DispatchProgress 'SESSION' $Record.ID ("已收到真实 Session ID=$($e.thread_id)")
   }
  }elseif($e.type -eq 'item.completed' -and $null -ne $e.item){
   if($e.item.type -eq 'command_execution'){
    $Attempt.ProgressCommands=[int]$Attempt.ProgressCommands+1
    if($Attempt.ProgressCommands -eq 1 -or $Attempt.ProgressCommands % 5 -eq 0){
     Write-DispatchProgress 'RUNNING' $Record.ID ("收到工具执行事件 $($Attempt.ProgressCommands) 项；仅表示有活动，非完成率")
    }
   }elseif($e.item.type -eq 'file_change'){
    Write-DispatchProgress 'RUNNING' $Record.ID '收到文件变更事件，等待独立验收'
   }
  }elseif($e.type -eq 'turn.completed'){
   Write-DispatchProgress 'VERIFY' $Record.ID '模型回合结束；等待进程退出及独立 TC/测试验收'
  }elseif($e.type -eq 'turn.failed' -or $e.type -eq 'error'){
   Write-DispatchProgress 'NEEDS_FIX' $Record.ID 'CLI 报告错误；保留原始 JSONL/stderr 供排查'
  }
 }
 if($changed){$Attempt.ProgressOffset=$index;Save-State}
}
function Test-QuotaExhausted([object]$Attempt) {
 # Only explicit usage/quota exhaustion, not a bare HTTP 429 or transient rate limit.
 $pattern='(?i)(insufficient[_\s-]?quota|quota[_\s-]?(?:exceeded|exhausted|depleted)|(?:hit|reached|exceeded)\s+(?:your\s+|the\s+)?(?:usage|plan|subscription|monthly|weekly|daily)\s+limit|(?:usage|spending)\s+(?:cap|limit)\s+(?:reached|exceeded)|credits?\s+(?:exhausted|depleted)|(?:out of|no more)\s+(?:credits?|quota)|(?:quota|usage)\s+(?:resets?\s+at|will\s+reset)|额度(?:已)?(?:用完|耗尽|不足)|配额(?:已)?(?:用完|耗尽)|(?:达到|超出).{0,8}(?:使用|额度|配额).{0,6}(?:上限|限制))'
 foreach($line in @(Read-LinesShared $Attempt.Stderr)) {
  if($line -match $pattern){return $true}
 }
 foreach($line in @(Read-LinesShared $Attempt.Stdout)) {
  try{$ev=$line | ConvertFrom-Json -ErrorAction Stop}catch{continue}
  if($ev.type -eq 'error' -or $ev.type -eq 'turn.failed') {
   if(($ev | ConvertTo-Json -Depth 15 -Compress) -match $pattern){return $true}
  }
 }
 return $false
}
function Process-Live([object]$Record){
 if(-not $Record.Pid -or -not $Record.ProcessStartedUtc){return $false}
 $p=Get-Process -Id ([int]$Record.Pid) -ErrorAction SilentlyContinue
 if($null -eq $p){return $false}
 try{return ([Math]::Abs(($p.StartTime.ToUniversalTime() - [datetimeoffset]::Parse($Record.ProcessStartedUtc).UtcDateTime).TotalSeconds) -lt 5)}catch{return $false}
}
function Wait-For-Attempt([object]$Record,[object]$Attempt){
 $since=[datetime]::UtcNow
 $lastHeartbeat=$since
 $graceUntil=$since.AddSeconds(5)
 while((Process-Live $Record) -or ((-not (Test-Path -LiteralPath $Attempt.ExitFile)) -and [datetime]::UtcNow -lt $graceUntil)){
  Sync-Events $Record $Attempt
  if(([datetime]::UtcNow-$lastHeartbeat).TotalSeconds -ge 30){
   $lastHeartbeat=[datetime]::UtcNow
   Write-DispatchProgress 'RUNNING' $Record.ID ("进程仍在运行，PID=$($Record.Pid)；最后事件=$($Attempt.LastEventUtc)；等待新的真实进度")
  }
  if($ProcessTimeoutSeconds -gt 0 -and ([datetime]::UtcNow-$since).TotalSeconds -ge $ProcessTimeoutSeconds){
   $Record.State='BLOCKED';$Record.Reason="PID $($Record.Pid) still alive on timeout; do not relaunch"
   Save-State;return $false
  }
  Start-Sleep -Milliseconds 350
 }
 Sync-Events $Record $Attempt
 $Attempt.ExitCode=if(Test-Path -LiteralPath $Attempt.ExitFile -PathType Leaf){[int]([IO.File]::ReadAllText($Attempt.ExitFile).Trim())}else{$null}
 if($null -ne $Attempt.PSObject.Properties['GitAfter']) {
  [IO.File]::WriteAllLines($Attempt.GitAfter,@(& git -C $Record.Root status --porcelain=v1 --untracked-files=all))
 }
 $Record.Pid=$null;$Record.ProcessStartedUtc=$null
 if(Test-QuotaExhausted $Attempt){
  $Record.State='PAUSED_QUOTA'
  $Record.Reason='Selected CLI model usage/quota exhausted; manual resume required'
  $script:State.PausedQuota=$true
  $script:State.QuotaPausedUtc=[datetime]::UtcNow.ToString('o')
  $script:State.QuotaPausedTicket=$Record.ID
  Save-State
  Write-DispatchProgress 'PAUSED_QUOTA' $Record.ID ("模型额度已用完，开发已暂停；CLI=Codex；模型=$($Attempt.Model) / $($Attempt.Effort)；Session=$($Record.SessionId)；stderr=$($Attempt.Stderr)；JSONL=$($Attempt.Stdout)；不自动重试或切换模型")
  return $true
 }
 $Record.State='NEEDS_FIX'
 Write-DispatchProgress 'VERIFY' $Record.ID ("CLI 进程已退出，真实退出码=$($Attempt.ExitCode)；开始独立检查")
 $Record.Reason=if($null -eq $Attempt.ExitCode){'Missing process exit receipt'}elseif($Attempt.ExitCode -ne 0){"CLI exit code $($Attempt.ExitCode)"}else{'Needs independent acceptance'}
 Save-State
 return $true
}

function Valid-Codex-Evidence([object]$Attempt,[string]$Root=''){
 $events=New-Object Collections.Generic.List[object]
 foreach($line in @(Read-LinesShared $Attempt.Stdout)){
  try{$events.Add(($line | ConvertFrom-Json -ErrorAction Stop))}catch{}
 }
 $ended=$false;$ran=$false;$rule=$false;$skill=$false;$bad=$false
 foreach($e in $events){
  if($e.type -eq 'turn.completed'){$ended=$true}
  if($e.type -eq 'turn.failed' -or $e.type -eq 'error'){$bad=$true}
  if($null -ne $e.item -and $e.item.type -eq 'command_execution'){
   $ran=$true
   $cmd=[string]$e.item.command
   if($null -ne $e.item.exit_code -and [int]$e.item.exit_code -eq 0) {
    if($cmd -match '(?i)AGENTS\.md'){$rule=$true}
    if($cmd -match '(?i)(?:implement[\\/]+SKILL\.md|\.cursor[\\/]rules|\.agents|SKILL\.md|personal-.*\.mdc)'){$skill=$true}
   }
  }
 }
 if($Root -and -not (Test-Path -LiteralPath (Join-Path $Root 'implement/SKILL.md')) -and -not (Test-Path -LiteralPath (Join-Path $Root '.agents/skills/implement/SKILL.md'))){
  if($rule){$skill=$true}
 }
 if($bad -or -not $ended -or -not $ran -or -not $rule -or -not $skill){
  return "Missing/failed Codex event proof: completed=$ended command=$ran AGENTS=$rule implementSkill=$skill error=$bad"
 }
 return ''
}
function Run-Independent-Tests([object]$Ticket,[object]$Entry,[string]$EvidenceDir){
 $runs=New-Object Collections.Generic.List[object]
 $i=0
 foreach($spec in @($Entry.tests)){
  $i++
  Write-DispatchProgress 'TEST' $Ticket.ID ("开始执行独立验收测试 $i/$(@($Entry.tests).Count)")
  if(-not $spec.file){throw "Missing test executable for $($Ticket.ID)"}
  $exe=[string]$spec.file
  $resolved=Get-Command $exe -ErrorAction Stop
  $filePath=$resolved.Source
  if(-not $filePath){$filePath=$resolved.Path}
  $args=@();if($null -ne $spec.args){$args=@($spec.args | ForEach-Object {[string]$_})}
  $prefix=Join-Path $EvidenceDir ("accept-$i")
  $stdin=$prefix+'.in';$out=$prefix+'.stdout';$err=$prefix+'.stderr';$exit=$prefix+'.exit'
  [IO.File]::WriteAllText($stdin,'')
  $test=Launch-Command $filePath $args $Ticket.Root $stdin $out $err $exit
  $test.WaitForExit()
  $code=if(Test-Path -LiteralPath $exit){[int]([IO.File]::ReadAllText($exit).Trim())}else{999}
  $runs.Add([pscustomobject]@{Executable=$exe;Args=$args;ExitCode=$code;Stdout=$out;Stderr=$err})
  Write-DispatchProgress 'TEST' $Ticket.ID ("独立测试 $i/$(@($Entry.tests).Count) 退出码=$code；证据=$out")
  if($code -ne 0){return [pscustomobject]@{Okay=$false;Reason="Independent test #$i failed ($code): $err";Runs=@($runs.ToArray())}}
 }
 return [pscustomobject]@{Okay=$true;Reason='';Runs=@($runs.ToArray())}
}
function Verify-Ticket([object]$Ticket,[object]$Record,[switch]$WithCodexProof){
 $fresh=@(Read-Tickets @($Ticket.TasksPath) | Where-Object {$_.Key -eq $Ticket.Key})
 if($fresh.Count -ne 1 -or $fresh[0].TicketPath -cne $Ticket.TicketPath){return 'Ticket mapping was changed on disk'}
 $live=$fresh[0]
 if(-not $live.Checked){return 'tasks.md is unchecked'}
 $tc=Ticket-Checks $live.Text
 if(-not $tc.All){return "Ticket TC checkboxes incomplete: $($tc.Reason)"}
 $entry=Manifest-Entry $Ticket.ID
 foreach($relative in @($entry.deliverables)){
  $p=Safe-Delivery $Ticket.Root ([string]$relative)
  if(-not (Test-Path -LiteralPath $p)){return "Missing expected deliverable: $relative"}
 }
 if($WithCodexProof){
  if(-not $Record.SessionId){return 'No persisted thread.started thread_id'}
  $last=@($Record.Attempts)[-1]
  if($null -eq $last.ExitCode -or $last.ExitCode -ne 0){return "CLI failed or has no verified exit code"}
  $proof=Valid-Codex-Evidence $last $Ticket.Root
  if($proof){return $proof}
 }
 $evidenceDir=Join-Path $script:BatchDir 'acceptance'
 if(-not (Test-Path -LiteralPath $evidenceDir)){[void](New-Item -ItemType Directory -Path $evidenceDir)}
 $folder=Join-Path $evidenceDir ((SHA $Ticket.Key).Substring(0,16))
 if(-not (Test-Path -LiteralPath $folder)){[void](New-Item -ItemType Directory -Path $folder)}
 $test=Run-Independent-Tests $Ticket $entry $folder
 $receipt=[pscustomobject]@{Ticket=$Ticket.ID;VerifiedUtc=[datetime]::UtcNow.ToString('o');Checks=$tc;Deliverables=@($entry.deliverables);Tests=$test.Runs;Okay=$test.Okay;Reason=$test.Reason}
 Atomically-Save (Join-Path $folder 'receipt.json') $receipt
 $Record.AcceptanceReceipt=Join-Path $folder 'receipt.json'
 Save-State
 if(-not $test.Okay){return $test.Reason}
 # Re-read after tests in case an external actor or test modified the task.
 $post=@(Read-Tickets @($Ticket.TasksPath) | Where-Object {$_.Key -eq $Ticket.Key})
 if($post.Count -ne 1 -or -not $post[0].Checked -or -not (Ticket-Checks $post[0].Text).All){return 'Ticket state changed during acceptance'}
 return ''
}
function Invoke-Ticket([object]$Ticket,[object]$Record,[string]$ResolvedCodex){
 $continuing=[bool]$Record.SessionId
 if(@($Record.Attempts).Count -ge $MaxAttemptsPerTicket){
  $Record.State='BLOCKED';$Record.Reason='Attempt limit reached; inspect original session and logs'
  Save-State;return
 }
 if(@($Record.Attempts).Count -gt 0 -and -not $continuing){
  $Record.State='BLOCKED';$Record.Reason='Previous launch has no recoverable thread ID; manual recovery required'
  Save-State;return
 }
 $n=@($Record.Attempts).Count+1
 $dir=Join-Path $script:BatchDir ('attempt-'+(SHA $Ticket.Key).Substring(0,16)+'-'+$n)
 [void](New-Item -ItemType Directory -Path $dir -Force)
 $promptPath=Join-Path $dir 'prompt.txt'
 if($continuing){
  $prompt='$implement' + [Environment]::NewLine +
    "只继续原 Ticket $($Ticket.ID)，路径 $($Ticket.TicketPath)。上一轮验收不通过：$($Record.Reason)。" + [Environment]::NewLine +
    "在 $($Ticket.Root) 复读 AGENTS.md、命中规则、implement/SKILL.md 和 Spec 锚点，修复未通过 TC 并实际运行测试；只修改此 Ticket；不启动其它 CLI/Agent，不自动 push。"
  $arguments=@('exec','resume','--json','-m',$Model,'-c',('model_reasoning_effort="'+$Effort+'"'),$Record.SessionId,'-')
 }else{
  $prompt='$implement' + [Environment]::NewLine +
    "仅开发当前 Ticket $($Ticket.ID)：$($Ticket.TicketPath)。目标仓根目录：$($Ticket.Root)。任务清单：$($Ticket.TasksPath)。" + [Environment]::NewLine +
    "先读本仓 AGENTS.md、命中规则、implement/SKILL.md 及当前 Ticket Spec 锚点，按目标规则实现交付、TC 与测试。" + [Environment]::NewLine +
    "不得扩大目标模块，不调度其它 Ticket/CLI/Agent，不绕过权限，不自动 push；回写真实验收标记并报告文件、测试命令和输出；更新 tasks.md 与 Ticket 文件时必须使用 UTF-8 编码读写，严禁破坏破折号或中文。"
  $arguments=@('exec','-C',$Ticket.Root,'--sandbox','workspace-write','--json','-m',$Model,'-c',('model_reasoning_effort="'+$Effort+'"'),'-')
 }
 [IO.File]::WriteAllText($promptPath,$prompt,(New-Object Text.UTF8Encoding($false)))
 $attempt=[pscustomobject]@{Index=$n;StartedUtc=[datetime]::UtcNow.ToString('o');Model=$Model;Effort=$Effort;Mode=$(if($continuing){'resume'}else{'new'});Stdout=(Join-Path $dir 'codex.jsonl');Stderr=(Join-Path $dir 'codex.stderr');ExitFile=(Join-Path $dir 'exit.txt');ExitCode=$null;PromptPath=$promptPath}
 $attempt | Add-Member -NotePropertyName GitBefore -NotePropertyValue (Join-Path $dir 'git-before.txt')
 $attempt | Add-Member -NotePropertyName GitAfter -NotePropertyValue (Join-Path $dir 'git-after.txt')
 [IO.File]::WriteAllLines($attempt.GitBefore,@(& git -C $Ticket.Root status --porcelain=v1 --untracked-files=all))
 $previousReason=$Record.Reason
 $Record.Attempts=@($Record.Attempts)+@($attempt)
 $Record.State='STARTING';$Record.Reason='Written before process launch';Save-State
 Write-DispatchProgress 'STARTING' $Ticket.ID ("任务文件=$($Ticket.TicketPath)；模块=$($Ticket.Module)；目标仓=$($Ticket.Root)；CLI=Codex；模型=$Model / $Effort；会话模式=$($attempt.Mode)；上次原因=$previousReason；尝试=$n/$MaxAttemptsPerTicket；日志=$($attempt.Stdout)")
 try{
  $proc=Launch-Command $ResolvedCodex $arguments $Ticket.Root $promptPath $attempt.Stdout $attempt.Stderr $attempt.ExitFile
  $Record.Pid=$proc.Id
  $Record.ProcessStartedUtc=$proc.StartTime.ToUniversalTime().ToString('o')
  $Record.State='RUNNING';$Record.Reason='';Save-State
  Write-DispatchProgress 'RUNNING' $Ticket.ID ("已启动独立 Codex 进程 PID=$($proc.Id)；模型=$Model / $Effort；等待 thread.started；日志=$($attempt.Stdout)")
  if(-not (Wait-For-Attempt $Record $attempt)){return}
 }catch{
  # STARTING without PID is ambiguous: do not issue another new session.
  $Record.State='BLOCKED';$Record.Reason="Launch/tracking failure: $($_.Exception.Message)"
  Save-State
  Write-DispatchProgress 'BLOCKED' $Ticket.ID ("启动或追踪失败，需检查日志与原进程；$($Record.Reason)")
  return
 }
}
function Print-Report([object[]]$Tickets) {
 $done=0
 foreach($t in $Tickets){
  $r=Get-Record $t.Key
  if($r.State -eq 'DONE'){$done++}
  Write-Host ("{0}: {1}  {2}  session={3}" -f $t.ID,$r.State,$r.Reason,$r.SessionId)
 }
 Write-Host ("SUMMARY: {0}/{1} DONE; batch={2}" -f $done,$Tickets.Count,$script:BatchDir)
 return ($done -eq $Tickets.Count)
}
try{
 $tickets=@(Read-Tickets $TaskPaths)
 Check-Graph $tickets
 $canonical=@($tickets | ForEach-Object {$_.TasksPath} | Sort-Object -Unique)
 if($DryRun){
  foreach($t in $tickets){Write-Host ("DRY RUN: {0} checked={1} deps=[{2}] root={3} file={4}" -f $t.ID,$t.Checked,($t.Dependencies -join ','),$t.Root,$t.TicketPath)}
  exit 0
 }
 if(-not $AcceptanceManifest){throw 'AcceptanceManifest is required for safe dispatch (use -DryRun to inspect only)'}
 $manifestPath=Resolve-Exact $AcceptanceManifest
 $script:Manifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
 if($null -eq $script:Manifest.tickets){throw 'Manifest requires tickets object'}
 foreach($t in $tickets){[void](Manifest-Entry $t.ID)}
 $cmd=Get-Command $CodexPath -ErrorAction Stop
 $resolvedCodex=if($cmd.Source){$cmd.Source}else{$cmd.Path}
 if(-not $resolvedCodex){throw "Cannot resolve Codex executable $CodexPath"}
 $runtime=[IO.Path]::GetFullPath($StateDirectory)
 if(-not (Test-Path -LiteralPath $runtime)){[void](New-Item -ItemType Directory -Path $runtime -Force)}
 $lockPath=Join-Path $runtime '.dispatch.lock'
 $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $identity=($canonical -join '|')+'|'+$manifestPath+'|codex'
  if(-not $RunId){$RunId=(SHA $identity).Substring(0,20)}
  if($RunId -notmatch '^[A-Za-z0-9_-]{1,64}$'){throw 'Unsafe RunId'}
  $script:BatchDir=Join-Path $runtime $RunId
  [void](New-Item -ItemType Directory -Path $script:BatchDir -Force)
  $script:RuntimeFile=Join-Path $script:BatchDir 'state.json'
  $script:ProgressPath=Join-Path $script:BatchDir 'progress.log'
  foreach($other in @(Get-ChildItem -LiteralPath $runtime -Directory)){
   if($other.FullName -eq $script:BatchDir){continue}
   $otherState=Join-Path $other.FullName 'state.json'
   if(-not (Test-Path -LiteralPath $otherState)){continue}
   $history=[IO.File]::ReadAllText($otherState) | ConvertFrom-Json
   foreach($h in @($history.Tickets)){
    if(@($h.Attempts).Count -eq 0){continue}
    if(@($tickets | Where-Object {$_.Key -ceq $h.Key}).Count -gt 0){
     throw "Existing Ticket session in different batch '$($other.Name)' for $($h.ID); resume original batch, do not duplicate dispatch"
    }
   }
  }
  if(Test-Path -LiteralPath $script:RuntimeFile){
   $script:State=[IO.File]::ReadAllText($script:RuntimeFile) | ConvertFrom-Json
   if($null -eq $script:State.PSObject.Properties['PausedQuota']){$script:State | Add-Member -NotePropertyName PausedQuota -NotePropertyValue $false}
   if($null -eq $script:State.PSObject.Properties['QuotaPausedUtc']){$script:State | Add-Member -NotePropertyName QuotaPausedUtc -NotePropertyValue $null}
   if($null -eq $script:State.PSObject.Properties['QuotaPausedTicket']){$script:State | Add-Member -NotePropertyName QuotaPausedTicket -NotePropertyValue $null}
   if($script:State.Identity -cne $identity){throw 'RunId already belongs to a different scope/manifest'}
   if($script:State.CliPath -cne $resolvedCodex -or $script:State.HostName -cne $env:COMPUTERNAME){throw 'CLI path/host changed: do not reuse sessions without an explicit migration'}
   $script:State.Model=$Model;$script:State.Effort=$Effort;Save-State
  }else{
   $script:State=[pscustomobject]@{Version=1;Identity=$identity;RunId=$RunId;CreatedUtc=[datetime]::UtcNow.ToString('o');PausedQuota=$false;QuotaPausedUtc=$null;QuotaPausedTicket=$null;Model=$Model;Effort=$Effort;CliPath=$resolvedCodex;HostName=$env:COMPUTERNAME;Scope=$canonical;Tickets=@()}
   foreach($t in $tickets){
    $script:State.Tickets+=([pscustomobject]@{Key=$t.Key;ID=$t.ID;Root=$t.Root;State='NOT_STARTED';Reason='';SessionId=$null;Pid=$null;ProcessStartedUtc=$null;Attempts=@();AcceptanceReceipt=$null})
   }
   Save-State
  }
  Write-DispatchProgress 'PLAN' 'BATCH' ("已核验调度范围，盘点/恢复：范围=$($canonical -join '; ')；CLI=Codex；模型=$Model / $Effort；共 $(@($tickets).Count) 张 Ticket；日志=$script:ProgressPath")
  foreach($t in $tickets){
   $r=Get-Record $t.Key
   if($r.State -eq 'STARTING' -and -not $r.Pid){
    if(@($r.Attempts).Count -gt 0){Sync-Events $r (@($r.Attempts)[-1])}
    $r.State='BLOCKED';$r.Reason='Interrupted launch with unknown PID; session recovered from logs if present. Inspect active processes before manual resume';Save-State
   }elseif($r.State -eq 'RUNNING' -or ($r.State -eq 'BLOCKED' -and $r.Pid)){
    $attempt=@($r.Attempts)[-1]
    if(Process-Live $r){Write-Host "Recovering running process PID=$($r.Pid) for $($t.ID)"}
    [void](Wait-For-Attempt $r $attempt)
   }
  }
  if($script:State.PausedQuota) {
   if(-not $ResumeAfterQuota) {
    Write-DispatchProgress 'PAUSED_QUOTA' $script:State.QuotaPausedTicket ("模型额度已用完，开发仍暂停；原 Session/日志保留；需用户确认额度恢复后显式恢复，暂停于 $($script:State.QuotaPausedUtc)")
    [void](Print-Report $tickets)
    exit 3
   }
   $paused=@($script:State.Tickets | Where-Object {$_.State -eq 'PAUSED_QUOTA'})
   if($paused.Count -ne 1 -or -not $paused[0].SessionId -or $paused[0].Pid){
    Write-DispatchProgress 'PAUSED_QUOTA' $script:State.QuotaPausedTicket '无法安全恢复：会话 ID 缺失、PID 未确认或状态冲突；必须人工核验'
    [void](Print-Report $tickets)
    exit 3
   }
   $paused[0].State='NEEDS_FIX'
   $paused[0].Reason='User authorized resume after model quota was restored; continue original session'
   $script:State.PausedQuota=$false
   $script:State.QuotaPausedUtc=$null
   $script:State.QuotaPausedTicket=$null
   Save-State
   Write-DispatchProgress 'RESUMING' $paused[0].ID ("用户授权额度恢复后继续原 Session=$($paused[0].SessionId)；模型=$Model / $Effort")
  }
  $retryApplied=@{}
  while($true){
   if($script:State.PausedQuota){break}
   $tickets=@(Read-Tickets $TaskPaths);Check-Graph $tickets
   foreach($t in $tickets){
    $r=Get-Record $t.Key
    if($r.State -eq 'BLOCKED' -and $r.Reason -like 'Unmet/out-of-scope dependency:*' -and @($r.Attempts).Count -eq 0){
     $r.State='NOT_STARTED';$r.Reason='Rechecking dependencies';Save-State
    }
    if($RetryBlocked -and -not $retryApplied.ContainsKey($r.Key) -and $r.State -eq 'BLOCKED' -and $r.SessionId -and -not $r.Pid -and @($r.Attempts).Count -lt $MaxAttemptsPerTicket){
     $retryApplied[$r.Key]=$true
     $r.State='NEEDS_FIX';$r.Reason='Operator requested retry after resolving the blocker';Save-State
    }
   }
   $progress=$false
   foreach($t in $tickets){
    $r=Get-Record $t.Key
    if($r.State -eq 'BLOCKED'){
     if($t.Checked -and -not ($r.Pid -and (Process-Live $r))){
      $finished=Verify-Ticket $t $r ([bool](@($r.Attempts).Count -gt 0))
      if(-not $finished){$r.State='DONE';$r.Reason='Verified after external repair';Save-State;Write-DispatchProgress 'DONE' $t.ID '外部修复完成；独立验收通过'}
     }
     continue
    }
    if($r.State -eq 'RUNNING'){continue}
    if($t.Checked){
     if($r.State -eq 'DONE'){continue}
     $reason=Verify-Ticket $t $r ([bool](@($r.Attempts).Count -gt 0))
     if(-not $reason){
      $r.State='DONE';$r.Reason='Independently verified';Save-State
      Write-DispatchProgress 'DONE' $t.ID '全部 TC/交付物/独立测试通过，允许选下一 Ticket'
      $progress=$true;continue
     }
     $reasonChanged=($r.Reason -cne $reason -or $r.State -ne 'NEEDS_FIX')
     $r.State='NEEDS_FIX';$r.Reason=$reason;Save-State
     if($reasonChanged){Write-DispatchProgress 'NEEDS_FIX' $t.ID ("验收未通过；将仅续接原 Ticket，会话=$($r.SessionId)；原因=$reason")}
    }elseif($r.State -eq 'DONE'){
     $r.State='NEEDS_FIX';$r.Reason='tasks.md reverted';Save-State
    }
   }
   $active=@($script:State.Tickets | Where-Object {$_.Pid -and (Process-Live $_)})
   if($active.Count -gt 0){Write-Host 'Live Codex process remains; refusing to start another Ticket';break}
   $waiting=$false;$selected=$null
   foreach($t in $tickets){
    $r=Get-Record $t.Key
    if($r.State -eq 'DONE' -or $r.State -eq 'BLOCKED'){continue}
    $unmet=@()
    foreach($dep in $t.Dependencies){
     $key=$t.Root.ToLowerInvariant()+'|'+$dep
     $d=@($tickets | Where-Object {$_.Key -ceq $key})
     if($d.Count -ne 1 -or (Get-Record $key).State -ne 'DONE'){$unmet+= $dep}
    }
    if($unmet.Count -gt 0){$waiting=$true;continue}
    $selected=$t;break
   }
   if($null -eq $selected){break}
   $r=Get-Record $selected.Key
   if($r.State -eq 'STARTING' -or $r.State -eq 'RUNNING'){
    $r.State='BLOCKED';$r.Reason='Unresolved in-flight process';Save-State;continue
   }
   Invoke-Ticket $selected $r $resolvedCodex
   if($script:State.PausedQuota){break}
   $progress=$true
  }
  if($script:State.PausedQuota){
   [void](Print-Report $tickets)
   Write-DispatchProgress 'PAUSED_QUOTA' $script:State.QuotaPausedTicket '额度耗尽，批次暂停；未验收 Ticket 保持未完成；不启动下一个 Ticket'
   exit 3
  }
  foreach($t in $tickets){
   $r=Get-Record $t.Key
   if($r.State -eq 'NOT_STARTED' -or $r.State -eq 'NEEDS_FIX'){
    $unmet=@($t.Dependencies | Where-Object {
     $key=$t.Root.ToLowerInvariant()+'|'+$_
     $d=@($tickets | Where-Object {$_.Key -ceq $key})
     $d.Count -ne 1 -or (Get-Record $key).State -ne 'DONE'
    })
    if($unmet.Count -gt 0){$r.State='BLOCKED';$r.Reason='Unmet/out-of-scope dependency: '+($unmet -join ', ');Save-State;Write-DispatchProgress 'BLOCKED' $t.ID $r.Reason}
   }
  }
  if(Print-Report $tickets){Write-DispatchProgress 'ALL_DONE' 'BATCH' '全部 Ticket 独立验收完成';exit 0}else{Write-DispatchProgress 'PARTIAL/BLOCKED' 'BATCH' '未全部完成；请查看各 Ticket 状态及日志';exit 2}
 }finally{$lock.Dispose()}
}catch{
 [Console]::Error.WriteLine("DISPATCH ERROR: $($_.Exception.Message)")
 [Console]::Error.WriteLine($_.ScriptStackTrace)
 exit 1
}
