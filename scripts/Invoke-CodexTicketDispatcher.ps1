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
 [switch]$RetryBlocked
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $StateDirectory) { $StateDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) '.supervisor-runtime' }
$script:RuntimeFile=$null
$script:State=$null
$script:Manifest=$null
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
function Git-Root([string]$Dir){
 $r=@(& git -C $Dir rev-parse --show-toplevel 2>$null)
 if($LASTEXITCODE -ne 0 -or $r.Count -ne 1){throw "Not a single Git repository: $Dir"}
 $p=Resolve-Exact $r[0].Trim()
 if(-not (Test-Path -LiteralPath (Join-Path $p 'AGENTS.md') -PathType Leaf)){throw "Target AGENTS.md missing: $p"}
 return $p
}
function Ids([string]$Text) {
 return @([regex]::Matches($Text,'\bT-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+\b') | ForEach-Object {$_.Value.ToUpperInvariant()} | Sort-Object -Unique)
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
   if($row -notmatch '^\s*[-*]\s+\[(?<mark>[ xX])\]\s+(?<body>.+)$'){continue}
   $body=$Matches['body'];$checked=($Matches['mark'] -eq 'x' -or $Matches['mark'] -eq 'X')
   $links=@([regex]::Matches($body,'(?<p>(?:[A-Za-z]:[\\/]|\.{1,2}[\\/]|docs[\\/])?[^\s\(\)\[\]\x60"''<>]+\.md)') | ForEach-Object {$_.Groups['p'].Value})
   if($links.Count -ne 1){throw "Exactly one ticket path required at $($file):$($i+1); found $($links.Count)"}
   $rel=$links[0].Replace('/','\')
   if([IO.Path]::IsPathRooted($rel)){throw "Absolute ticket paths in tasks.md require separate authorization: $rel"}
   $base=if($rel.StartsWith('.\')){$module}else{$root}
   $location=Resolve-Exact (Join-Path $base $rel)
   if(-not (Inside $root $location)){throw "Ticket path escapes repo: $location"}
   $txt=[IO.File]::ReadAllText($location)
   $heading=[regex]::Match($txt,'(?m)^\s*#\s*Ticket:\s*(?<id>T-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+)\b')
   if(-not $heading.Success){throw "Missing Ticket heading: $location"}
   $id=$heading.Groups['id'].Value.ToUpperInvariant()
   $depMatch=[regex]::Match($txt,'(?im)^\s*(?:[-*]\s*)?(?:\*\*)?Blocked by(?:\*\*)?\s*:\s*(?<deps>[^\r\n]+)')
   $rowDep=[regex]::Match($body,'(?i)Blocked by\s*:\s*(?<deps>.+?)(?:\s*\)|\s*$)')
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
 return (Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WorkingDirectory $Cwd -RedirectStandardInput $InputFile -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru)
}
function Read-LinesShared([string]$Path){
 if(-not [IO.File]::Exists($Path)){return @()}
 $fs=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{$rd=New-Object IO.StreamReader($fs);try{$raw=$rd.ReadToEnd()}finally{$rd.Dispose()};return @($raw -split '\r?\n' | Where-Object {$_ -ne ''})}finally{$fs.Dispose()}
}
function Sync-Events([object]$Record,[object]$Attempt){
 foreach($line in @(Read-LinesShared $Attempt.Stdout)){
  try{$e=$line | ConvertFrom-Json -ErrorAction Stop}catch{continue}
  if($e.type -eq 'thread.started' -and $null -ne $e.thread_id -and $e.thread_id -match '^[a-f0-9-]{36}$'){
   if($Record.SessionId -and $Record.SessionId -cne $e.thread_id){throw "Session ID mismatch for $($Record.ID)"}
   if(-not $Record.SessionId){$Record.SessionId=$e.thread_id;Save-State}
  }
 }
}
function Process-Live([object]$Record){
 if(-not $Record.Pid -or -not $Record.ProcessStartedUtc){return $false}
 $p=Get-Process -Id ([int]$Record.Pid) -ErrorAction SilentlyContinue
 if($null -eq $p){return $false}
 try{return ([Math]::Abs(($p.StartTime.ToUniversalTime() - [datetimeoffset]::Parse($Record.ProcessStartedUtc).UtcDateTime).TotalSeconds) -lt 5)}catch{return $false}
}
function Wait-For-Attempt([object]$Record,[object]$Attempt){
 $since=[datetime]::UtcNow
 $graceUntil=$since.AddSeconds(5)
 while((Process-Live $Record) -or ((-not (Test-Path -LiteralPath $Attempt.ExitFile)) -and [datetime]::UtcNow -lt $graceUntil)){
  Sync-Events $Record $Attempt
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
 $Record.State='NEEDS_FIX'
 $Record.Reason=if($null -eq $Attempt.ExitCode){'Missing process exit receipt'}elseif($Attempt.ExitCode -ne 0){"CLI exit code $($Attempt.ExitCode)"}else{'Needs independent acceptance'}
 Save-State
 return $true
}

function Valid-Codex-Evidence([object]$Attempt){
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
    if($cmd -match '(?i)implement[\\/]+SKILL\.md'){$skill=$true}
   }
  }
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
  $proof=Valid-Codex-Evidence $last
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
    "不得扩大目标模块，不调度其它 Ticket/CLI/Agent，不绕过权限，不自动 push；回写真实验收标记并报告文件、测试命令和输出。"
  $arguments=@('exec','-C',$Ticket.Root,'--sandbox','workspace-write','--json','-m',$Model,'-c',('model_reasoning_effort="'+$Effort+'"'),'-')
 }
 [IO.File]::WriteAllText($promptPath,$prompt,(New-Object Text.UTF8Encoding($false)))
 $attempt=[pscustomobject]@{Index=$n;StartedUtc=[datetime]::UtcNow.ToString('o');Model=$Model;Effort=$Effort;Mode=$(if($continuing){'resume'}else{'new'});Stdout=(Join-Path $dir 'codex.jsonl');Stderr=(Join-Path $dir 'codex.stderr');ExitFile=(Join-Path $dir 'exit.txt');ExitCode=$null;PromptPath=$promptPath}
 $attempt | Add-Member -NotePropertyName GitBefore -NotePropertyValue (Join-Path $dir 'git-before.txt')
 $attempt | Add-Member -NotePropertyName GitAfter -NotePropertyValue (Join-Path $dir 'git-after.txt')
 [IO.File]::WriteAllLines($attempt.GitBefore,@(& git -C $Ticket.Root status --porcelain=v1 --untracked-files=all))
 $Record.Attempts=@($Record.Attempts)+@($attempt)
 $Record.State='STARTING';$Record.Reason='Written before process launch';Save-State
 try{
  $proc=Launch-Command $ResolvedCodex $arguments $Ticket.Root $promptPath $attempt.Stdout $attempt.Stderr $attempt.ExitFile
  $Record.Pid=$proc.Id
  $Record.ProcessStartedUtc=$proc.StartTime.ToUniversalTime().ToString('o')
  $Record.State='RUNNING';$Record.Reason='';Save-State
  Write-Host ("{0} #{1} PID={2} {3}" -f $Ticket.ID,$n,$proc.Id,$attempt.Mode)
  if(-not (Wait-For-Attempt $Record $attempt)){return}
 }catch{
  # STARTING without PID is ambiguous: do not issue another new session.
  $Record.State='BLOCKED';$Record.Reason="Launch/tracking failure: $($_.Exception.Message)"
  Save-State;return
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
   if($script:State.Identity -cne $identity){throw 'RunId already belongs to a different scope/manifest'}
   if($script:State.CliPath -cne $resolvedCodex -or $script:State.HostName -cne $env:COMPUTERNAME){throw 'CLI path/host changed: do not reuse sessions without an explicit migration'}
   $script:State.Model=$Model;$script:State.Effort=$Effort;Save-State
  }else{
   $script:State=[pscustomobject]@{Version=1;Identity=$identity;RunId=$RunId;CreatedUtc=[datetime]::UtcNow.ToString('o');Model=$Model;Effort=$Effort;CliPath=$resolvedCodex;HostName=$env:COMPUTERNAME;Scope=$canonical;Tickets=@()}
   foreach($t in $tickets){
    $script:State.Tickets+=([pscustomobject]@{Key=$t.Key;ID=$t.ID;Root=$t.Root;State='NOT_STARTED';Reason='';SessionId=$null;Pid=$null;ProcessStartedUtc=$null;Attempts=@();AcceptanceReceipt=$null})
   }
   Save-State
  }
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
  $retryApplied=@{}
  while($true){
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
      if(-not $finished){$r.State='DONE';$r.Reason='Verified after external repair';Save-State}
     }
     continue
    }
    if($r.State -eq 'RUNNING'){continue}
    if($t.Checked){
     $reason=Verify-Ticket $t $r ([bool](@($r.Attempts).Count -gt 0))
     if(-not $reason){$r.State='DONE';$r.Reason='Independently verified';Save-State;$progress=$true;continue}
     $r.State='NEEDS_FIX';$r.Reason=$reason;Save-State
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
   $progress=$true
  }
  foreach($t in $tickets){
   $r=Get-Record $t.Key
   if($r.State -eq 'NOT_STARTED' -or $r.State -eq 'NEEDS_FIX'){
    $unmet=@($t.Dependencies | Where-Object {
     $key=$t.Root.ToLowerInvariant()+'|'+$_
     $d=@($tickets | Where-Object {$_.Key -ceq $key})
     $d.Count -ne 1 -or (Get-Record $key).State -ne 'DONE'
    })
    if($unmet.Count -gt 0){$r.State='BLOCKED';$r.Reason='Unmet/out-of-scope dependency: '+($unmet -join ', ');Save-State}
   }
  }
  if(Print-Report $tickets){exit 0}else{exit 2}
 }finally{$lock.Dispose()}
}catch{
 [Console]::Error.WriteLine("DISPATCH ERROR: $($_.Exception.Message)")
 [Console]::Error.WriteLine($_.ScriptStackTrace)
 exit 1
}
