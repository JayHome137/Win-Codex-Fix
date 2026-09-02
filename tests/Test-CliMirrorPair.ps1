param(
  [string]$ProjectRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

$repair = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\Repair-CodexDesktopBundled.ps1') -Raw
$verify = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\Verify-CodexDesktopBundled.ps1') -Raw
$skill = Get-Content -LiteralPath (Join-Path $ProjectRoot 'SKILL.md') -Raw

Assert-True ($repair -match 'function Find-CurrentCodexCodeModeHost') 'code-mode host source resolver is missing'
Assert-True ($repair -match '\[string\]\$CompanionSourceFile') 'CLI mirror companion source parameter is missing'
Assert-True ($repair -match '\[string\]\$CompanionDestFile') 'CLI mirror companion destination parameter is missing'
Assert-True ($repair -match 'Get-CodexCliMirrorUsers \$DestFile \$CompanionDestFile') 'pair process ownership check is missing'
Assert-True ($repair -match 'Assert-CodexCliPairMatchesCurrent') 'pair post-write assertion is missing'
Assert-True ($repair -match 'appxCodeModeHostSha256') 'pair refresh state does not record code-mode host hash'
Assert-True ($verify -match 'Find-CurrentAppxCodexCodeModeHost') 'verifier does not resolve AppX code-mode host'
Assert-True ($verify -match 'managed code-mode host mirror SHA-256 matches current AppX') 'verifier does not check code-mode host hash'
Assert-True ($skill -match 'codex-code-mode-host\.exe') 'Skill does not document the CLI/code-mode host pair'

Write-Host '[PASS] CLI/code-mode host pair focused contract passed.'

