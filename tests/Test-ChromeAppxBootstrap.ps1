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

Assert-True ($repair -match '\[switch\]\$ChromeAppxBootstrapOnly') 'Repair route parameter is missing'
Assert-True ($repair -match '\[switch\]\$ChromeAppServerBootstrapOnly') 'App-server bootstrap compatibility route parameter is missing'
Assert-True ($quick -match "'ChromeAppxBootstrapOnly'") 'Quick route dispatch is missing'
Assert-True ($quick -match "'ChromeAppServerBootstrapOnly'") 'App-server bootstrap quick route dispatch is missing'
Assert-True ($quick -match "-ChromeAppxBootstrapOnly") 'Quick child argument is missing'
Assert-True ($quick -match "-ChromeAppServerBootstrapOnly") 'App-server bootstrap quick child argument is missing'
Assert-True ($verify -match '\[switch\]\$ChromeAppxBootstrapOnly') 'Chrome bootstrap verifier mode is missing'
Assert-True ($verify -match '\[switch\]\$ChromeAppServerBootstrapOnly') 'App-server bootstrap verifier compatibility mode is missing'
Assert-True ($quick -match "resourcesPath\|nodePath\|nodeModuleDirs\|nodeReplPath\|node_repl\|cua_node") 'Auto route does not classify app-server path errors'

$start = $repair.IndexOf('if ($chromeBootstrapOnly)')
$end = $repair.IndexOf('if ($BrowserNativeHostOnly)', $start)
Assert-True ($start -ge 0 -and $end -gt $start) 'Chrome bootstrap route boundaries are missing'
$route = $repair.Substring($start, $end - $start)
Assert-True ($route -match 'installManifest\.mjs') 'Chrome bootstrap does not call the AppX installer'
Assert-True ($route -match 'Test-AppxBlockMapTreeComplete') 'Chrome bootstrap does not validate AppxBlockMap'
Assert-True ($route -match 'Test-ChromeExtensionHostSidecar') 'Chrome bootstrap has no sidecar acceptance'
Assert-True ($route -notmatch 'plugin marketplace (add|remove)|marketplace add|marketplace remove') 'Chrome bootstrap must not use marketplace registration'
Assert-True ($route -notmatch 'Stop-Process|Restart-Computer|Restart-Service') 'Chrome bootstrap must not control processes'
Assert-True ($repair -match 'Get-ChildItem -LiteralPath \$Path -Force -ErrorAction Stop') 'Discovery junction checks must probe real traversal'
Assert-True ($repair -match 'function Test-LatestIsStable[\s\S]*Get-ChildItem -LiteralPath \$LatestPath -Force -ErrorAction Stop') 'Latest-link stability must include a traversal probe'

Write-Host '[PASS] ChromeAppxBootstrap focused contract passed.'
