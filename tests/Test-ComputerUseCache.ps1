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
$quick = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\Invoke-CodexDesktopQuickRepair.ps1') -Raw
$verify = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\Verify-CodexDesktopBundled.ps1') -Raw
$afterExit = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\Start-CodexDesktopQuickRepairAfterExit.ps1') -Raw

Assert-True ($repair -match '\[switch\]\$ComputerUseCacheOnly') 'Repair route parameter is missing'
Assert-True ($repair -match 'if \(\$ComputerUseCacheOnly\)') 'Computer Use cache route is missing'
Assert-True ($repair -match 'Test-AppxBlockMapTreeComplete[\s\S]*plugins\\computer-use') 'Computer Use route lacks AppxBlockMap validation'
Assert-True ($repair -match "Repair-PluginCache 'computer-use'") 'Computer Use route does not copy the AppX plugin'
Assert-True ($quick -match "'ComputerUseCacheOnly'") 'Quick route dispatch is missing'
Assert-True ($quick -match '-ComputerUseCacheOnly') 'Quick child argument is missing'
Assert-True ($verify -match '\[switch\]\$ComputerUseCacheOnly') 'Computer Use verifier mode is missing'
Assert-True ($afterExit -match 'ComputerUseCacheOnly') 'After-exit route contract is missing'
Assert-True ($verify -notmatch 'computer-use client') 'Verifier still requires removed computer-use client artifact'
Assert-True ($verify -match 'current CLI does not register openai-bundled') 'Verifier does not recognise the AppX-owned plugin flow'

Write-Host '[PASS] ComputerUseCache focused contract passed.'
