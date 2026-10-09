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

# 1. 验证整个 AI Data 模块编译
Write-Host "Verifying compilation via $mvnPath..."
& $mvnPath -f $pom -DskipTests compile
if ($LASTEXITCODE -ne 0) {
  Write-Error "Maven compile failed with exit code $LASTEXITCODE"
  exit $LASTEXITCODE
}

# 2. 定向运行当前 Ticket 的验收测试，隔离历史无关测试
$testPattern = switch -Wildcard ($TicketId) {
  'T-GOV-001' { '*RuntimeConfig*' }
  'T-GOV-002' { '*Registry*' }
  'T-GOV-003' { '*Metadata*' }
  'T-GOV-004' { '*ApiKey*' }
  'T-GOV-005' { '*DataIsolationPolicy*' }
  'T-GOV-006' { '*Policy*' }
  'T-GOV-007' { '*PlatformScope*' }
  'T-GOV-008' { '*ExternalScope*' }
  'T-GOV-009' { '*Audit*' }
  Default { '*Governance*' }
}

Write-Host "Running targeted test for $TicketId ($testPattern)..."
& $mvnPath -f $pom "-Dtest=$testPattern" "-Dsurefire.failIfNoSpecifiedTests=false" "-DfailIfNoTests=false" test
if ($LASTEXITCODE -ne 0) {
  Write-Error "Targeted test failed for $TicketId with exit code $LASTEXITCODE"
  exit $LASTEXITCODE
}

Write-Host "Acceptance test PASSED for $TicketId"
exit 0
