param(
  [ValidateSet('Auto','CliMirrorOnly','RuntimeOnly','BrowserDiscoveryOnly','BrowserCacheOnly','BrowserNativeHostOnly','EdgeNativeHostOnly','ChromeAppxBootstrapOnly','ChromeAppServerBootstrapOnly','ComputerUseCacheOnly','TmpRuntimeMarketplaceOnly','Verify')]
  [string]$Route = 'Auto',
  [switch]$ArmAfterExit,
  [string]$ProjectRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = if ($ProjectRoot) { $ProjectRoot } else { Split-Path -Parent $PSScriptRoot }
$Root = [System.IO.Path]::GetFullPath($Root)
$Scripts = Join-Path $Root 'scripts'
$Repair = Join-Path $Scripts 'Repair-CodexDesktopBundled.ps1'
$Verify = Join-Path $Scripts 'Verify-CodexDesktopBundled.ps1'
$AfterExit = Join-Path $Scripts 'Start-CodexDesktopQuickRepairAfterExit.ps1'

function Invoke-Child([string]$Path, [string[]]$Arguments) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing repair component: $Path"
  }
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1)
  foreach ($line in $output) { Write-Host $line }
  $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  if ($code -eq 1 -and (($output -join "`n") -match '(?i)process guard blocked|requires a stable .*exit|Desktop is running')) {
    return 30
  }
  return $code
}

function Invoke-VerifyQuick {
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Verify -Quick 2>&1)
  $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  foreach ($line in $output) { Write-Host $line }
  return [pscustomobject]@{ Code = $code; Text = ($output -join "`n") }
}

function Invoke-VerifyBrowserNativeHost {
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Verify -BrowserNativeHostOnly 2>&1)
  $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  foreach ($line in $output) { Write-Host $line }
  return [pscustomobject]@{ Code = $code; Text = ($output -join "`n") }
}

function Invoke-VerifyChromeAppxBootstrap {
  param([switch]$AppServerAlias)
  $verifyArguments = if ($AppServerAlias) { @('-ChromeAppServerBootstrapOnly') } else { @('-ChromeAppxBootstrapOnly') }
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Verify @verifyArguments 2>&1)
  $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  foreach ($line in $output) { Write-Host $line }
  return [pscustomobject]@{ Code = $code; Text = ($output -join "`n") }
}

function Invoke-VerifyComputerUseCache {
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Verify -ComputerUseCacheOnly 2>&1)
  $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  foreach ($line in $output) { Write-Host $line }
  return [pscustomobject]@{ Code = $code; Text = ($output -join "`n") }
}

function Invoke-VerifyEdgeNativeHost {
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Verify -EdgeNativeHostOnly 2>&1)
  $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  foreach ($line in $output) { Write-Host $line }
  return [pscustomobject]@{ Code = $code; Text = ($output -join "`n") }
}

if ($ArmAfterExit) {
  if (-not (Test-Path -LiteralPath $AfterExit -PathType Leaf)) {
    throw "Missing one-shot after-exit helper: $AfterExit"
  }
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AfterExit -Arm -Route $Route 2>&1)
  foreach ($line in $output) { Write-Host $line }
  $armExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  exit $armExitCode
}

function Invoke-Target([string]$Target) {
  switch ($Target) {
    'CliMirrorOnly' { return Invoke-Child $Repair @('-CliMirrorOnly') }
    'RuntimeOnly' { return Invoke-Child $Repair @('-RuntimeOnly') }
    'BrowserDiscoveryOnly' { return Invoke-Child $Repair @('-BrowserDiscoveryOnly') }
    'BrowserCacheOnly' { return Invoke-Child $Repair @('-BrowserCacheOnly') }
    'BrowserNativeHostOnly' { return Invoke-Child $Repair @('-BrowserNativeHostOnly') }
    'EdgeNativeHostOnly' { return Invoke-Child $Repair @('-EdgeNativeHostOnly') }
    'ChromeAppxBootstrapOnly' { return Invoke-Child $Repair @('-ChromeAppxBootstrapOnly') }
    'ChromeAppServerBootstrapOnly' { return Invoke-Child $Repair @('-ChromeAppServerBootstrapOnly') }
    'ComputerUseCacheOnly' { return Invoke-Child $Repair @('-ComputerUseCacheOnly') }
    'TmpRuntimeMarketplaceOnly' { return Invoke-Child $Repair @('-TmpRuntimeMarketplaceOnly') }
    'Verify' { return (Invoke-VerifyQuick).Code }
    default { throw "Unsupported quick repair route: $Target" }
  }
}

if ($Route -ne 'Auto') {
  $targetResult = Invoke-Target $Route
  if ($Route -in @('CliMirrorOnly','RuntimeOnly','BrowserDiscoveryOnly','BrowserCacheOnly','BrowserNativeHostOnly','EdgeNativeHostOnly','ChromeAppxBootstrapOnly','ChromeAppServerBootstrapOnly','ComputerUseCacheOnly','TmpRuntimeMarketplaceOnly')) {
    if ($targetResult -eq 0) {
      $targetResult = if ($Route -eq 'BrowserNativeHostOnly') {
        (Invoke-VerifyBrowserNativeHost).Code
      } elseif ($Route -eq 'EdgeNativeHostOnly') {
        (Invoke-VerifyEdgeNativeHost).Code
      } elseif ($Route -in @('ChromeAppxBootstrapOnly','ChromeAppServerBootstrapOnly')) {
        (Invoke-VerifyChromeAppxBootstrap -AppServerAlias:($Route -eq 'ChromeAppServerBootstrapOnly')).Code
      } elseif ($Route -eq 'ComputerUseCacheOnly') {
        (Invoke-VerifyComputerUseCache).Code
      } else {
        (Invoke-VerifyQuick).Code
      }
    }
  }
  exit $targetResult
}

Write-Host '[codex-quick] one pass: mirror -> quick verifier -> one matching repair route -> route acceptance'
$mirrorResult = Invoke-Target 'CliMirrorOnly'
if ($mirrorResult -eq 30) {
  Write-Host '[codex-quick] pending-natural-exit: managed CLI mirror is in use; no process was stopped.'
  exit 30
}
if ($mirrorResult -ne 0) {
  Write-Host "[codex-quick] source/mirror-failed exit=$mirrorResult"
  exit $mirrorResult
}

$quick = Invoke-VerifyQuick
if ($quick.Code -eq 0) {
  Write-Host '[codex-quick] current state is already healthy; no repair needed.'
  exit 0
}

$failureText = (($quick.Text -split "`n") | Where-Object { $_ -match '^\[FAIL\]' }) -join "`n"
$selectedRoute = $null
if ($failureText -match '(?i)code-mode-host|CLI mirror|codex-cli') {
  $selectedRoute = 'CliMirrorOnly'
} elseif ($failureText -match '(?i)resourcesPath|nodePath|nodeModuleDirs|nodeReplPath|node_repl|cua_node') {
  $selectedRoute = 'ChromeAppServerBootstrapOnly'
} elseif ($failureText -match '(?i)chrome latest|chrome metadata|chrome native|native host v2|extension-host-config') {
  $selectedRoute = 'ChromeAppxBootstrapOnly'
} elseif ($failureText -match '(?i)computer-use (?:plugin metadata|latest|metadata)|Computer Use plugin-cache') {
  $selectedRoute = 'ComputerUseCacheOnly'
} elseif ($failureText -match '(?i)browser|plugin discovery|browser-client') {
  $selectedRoute = 'BrowserCacheOnly'
} elseif ($failureText -match '(?i)edge native host|Microsoft\\Edge\\NativeMessagingHosts') {
  $selectedRoute = 'EdgeNativeHostOnly'
} elseif ($failureText -match '(?i)native host|native-host|allowed_origins|NativeMessagingHosts') {
  $selectedRoute = 'BrowserNativeHostOnly'
}

if (-not $selectedRoute) {
  Write-Host '[codex-quick] manual-required: the verifier did not identify a single established hot-repair owner.'
  exit $quick.Code
}

Write-Host "[codex-quick] selected route=$selectedRoute"
$repairResult = Invoke-Target $selectedRoute
if ($repairResult -eq 30 -or $repairResult -eq 20) {
  Write-Host "[codex-quick] 当前路由无法热修 / hot-repair unavailable for route=${selectedRoute}: the selected file owner is active. Close only the reported owner after authorization, then rerun this same route."
  Write-Host '[codex-quick] pending-natural-exit: no process was stopped and no fallback route will run.'
  exit $repairResult
}
if ($repairResult -ne 0) {
  Write-Host "[codex-quick] selected route failed exit=$repairResult; no fallback route was started."
  exit $repairResult
}

$final = if ($selectedRoute -eq 'BrowserNativeHostOnly') {
  Invoke-VerifyBrowserNativeHost
} elseif ($selectedRoute -eq 'EdgeNativeHostOnly') {
  Invoke-VerifyEdgeNativeHost
} elseif ($selectedRoute -in @('ChromeAppxBootstrapOnly','ChromeAppServerBootstrapOnly')) {
  Invoke-VerifyChromeAppxBootstrap -AppServerAlias:($selectedRoute -eq 'ChromeAppServerBootstrapOnly')
} elseif ($selectedRoute -eq 'ComputerUseCacheOnly') {
  Invoke-VerifyComputerUseCache
} else {
  Invoke-VerifyQuick
}
if ($final.Code -eq 0) {
  Write-Host '[codex-quick] repair and quick verification passed.'
} else {
  Write-Host "[codex-quick] manual-required: selected route did not restore the verifier (exit=$($final.Code))."
}
exit $final.Code
