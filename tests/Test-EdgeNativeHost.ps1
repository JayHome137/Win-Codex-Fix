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

Assert-True ($repair -match '\[switch\]\$EdgeNativeHostOnly') 'Repair route parameter is missing'
Assert-True ($repair -match 'if \(\$EdgeNativeHostOnly\)') 'Edge native-host route is missing'
Assert-True ($repair -match 'Software\\Microsoft\\Edge\\NativeMessagingHosts') 'Edge registry root is missing'
Assert-True ($repair -match 'New-BrowserNativeHostRollbackBackup[\s\S]*\$registryPath') 'Edge route lacks registry rollback backup'
Assert-True ($repair -match 'Test-ChromiumNativeHostManifest') 'Edge route does not validate the shared manifest'
Assert-True ($repair -notmatch 'EdgeNativeHostOnly[\s\S]*Stop-Process|EdgeNativeHostOnly[\s\S]*Restart-Computer|EdgeNativeHostOnly[\s\S]*Restart-Service') 'Edge route must not control processes'
Assert-True ($quick -match "'EdgeNativeHostOnly'") 'Quick route dispatch is missing'
Assert-True ($quick -match '-EdgeNativeHostOnly') 'Quick child argument is missing'
Assert-True ($verify -match '\[switch\]\$EdgeNativeHostOnly') 'Edge verifier mode is missing'
Assert-True ($afterExit -match 'EdgeNativeHostOnly') 'After-exit route contract is missing'
Assert-True ($verify -match 'Test-EdgeExtensionInstalled') 'Edge verifier does not scope checks to installed Edge extensions'
Assert-True ($verify -match 'edge native host HKCU registry') 'Edge verifier check is missing'

Write-Host '[PASS] EdgeNativeHost focused contract passed.'
