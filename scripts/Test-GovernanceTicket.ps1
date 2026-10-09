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

$bizPom = Join-Path $Root 'dlplatform\dlplatform-ai-data\dlplatform-ai-data-biz\pom.xml'
if (-not (Test-Path -LiteralPath $bizPom)) {
  Write-Error "Biz POM not found: $bizPom"
  exit 1
}

# 1. 验证整个 AI Data 模块编译
Write-Host "Verifying compilation via $mvnPath..."
& $mvnPath -f $pom -DskipTests compile
if ($LASTEXITCODE -ne 0) {
  Write-Error "Maven compile failed with exit code $LASTEXITCODE"
  exit $LASTEXITCODE
}

$patternMap = @{
  'T-GOV-001' = 'RuntimeConfigValueValidatorTest'
  'T-GOV-002' = 'McpRegistryServiceTest'
  'T-GOV-003' = '*MetadataBrowser*'
  'T-GOV-004' = 'McpApiKeyServiceTest'
  'T-GOV-005' = 'DataIsolationPolicyServiceTest'
  'T-GOV-006' = '*PolicyLifecycle*'
  'T-GOV-007' = '*PlatformScope*'
  'T-GOV-008' = '*ExternalScope*'
  'T-GOV-009' = '*GovernanceAudit*'
}
$testPattern = if ($patternMap.ContainsKey($TicketId)) { $patternMap[$TicketId] } else { '*Governance*' }

Write-Host "Running targeted test for $TicketId ($testPattern)..."
& $mvnPath -f $bizPom "-Dtest=$testPattern" test
if ($LASTEXITCODE -ne 0) {
  Write-Error "Targeted test failed for $TicketId with exit code $LASTEXITCODE"
  exit $LASTEXITCODE
}

Write-Host "Acceptance test PASSED for $TicketId"
exit 0
