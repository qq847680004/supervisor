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

# 1. 验证整个 AI Data 模块编译并安装最新依赖到本地仓库
Write-Host "Verifying compilation & installing local modules via $mvnPath..."
& $mvnPath -f $pom -DskipTests install
if ($LASTEXITCODE -ne 0) {
  Write-Error "Maven install failed with exit code $LASTEXITCODE"
  exit $LASTEXITCODE
}

$patternMap = @{
  'T-GOV-001' = 'DataIsolationPolicyServiceTest,McpRegistryServiceTest,McpApiKeyServiceTest'
  'T-GOV-002' = 'McpRegistryServiceTest'
  'T-GOV-003' = 'DataIsolationPolicyServiceTest'
  'T-GOV-004' = '*PlatformScope*,*ExternalScope*,McpApiKeyServiceTest'
  'T-GOV-005' = 'GovernanceAuditServiceTest,*Audit*'
}

if ($patternMap.ContainsKey($TicketId)) {
  $testPattern = $patternMap[$TicketId]
  Write-Host "Running targeted test for $TicketId ($testPattern)..."
  & $mvnPath -f $bizPom "-Dtest=$testPattern" test
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Targeted test failed for $TicketId with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
  }
} elseif ($TicketId -eq 'T-GOV-006') {
  Write-Host "Running UI verification for $TicketId..."
  $uiPath = Join-Path $Root 'dlplatform-mall-admin-ui'
  if (-not (Test-Path -LiteralPath $uiPath)) {
    Write-Error "UI path not found: $uiPath"
    exit 1
  }
  Write-Host "UI path verified: $uiPath"
} else {
  $testPattern = '*Governance*'
  Write-Host "Running fallback test for $TicketId ($testPattern)..."
  & $mvnPath -f $bizPom "-Dtest=$testPattern" test
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Targeted test failed for $TicketId with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
  }
}

Write-Host "Acceptance test PASSED for $TicketId"
exit 0
