#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$TicketId,
  [string]$Root = 'D:\2026work\work\digital-logistics'
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch {}

Write-Host "Running acceptance test for $TicketId in $Root..."

# 确保 mvn 可用
$mvnCmd = Get-Command mvn.cmd -ErrorAction SilentlyContinue
if (-not $mvnCmd) {
  $ideaMvn = 'D:\Program Files\JetBrains\IntelliJ IDEA 2026.2.1\plugins\maven-plugin\lib\maven3\bin\mvn.cmd'
  if (Test-Path -LiteralPath $ideaMvn) {
    $mvnPath = $ideaMvn
  } else {
    Write-Error "Maven executable not found"
    exit 1
  }
} else {
  $mvnPath = $mvnCmd.Source
}

$pom = Join-Path $Root 'dlplatform\dlplatform-ai-data\pom.xml'
if (-not (Test-Path -LiteralPath $pom)) {
  Write-Error "POM not found: $pom"
  exit 1
}

Write-Host "Running maven test via $mvnPath on $pom..."
& $mvnPath -f $pom test -DfailIfNoTests=false
if ($LASTEXITCODE -ne 0) {
  Write-Error "Maven test failed with exit code $LASTEXITCODE"
  exit $LASTEXITCODE
}

Write-Host "Acceptance test PASSED for $TicketId"
exit 0
