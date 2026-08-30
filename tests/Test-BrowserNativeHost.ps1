param(
  [string]$ProjectRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ProjectRoot) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Test-WindowsPathEqual([string]$Left, [string]$Right) {
  if (-not $Left -or -not $Right) { return $false }
  return [string]::Equals(
    [System.IO.Path]::GetFullPath($Left),
    [System.IO.Path]::GetFullPath($Right),
    [System.StringComparison]::OrdinalIgnoreCase
  )
}

. (Join-Path $ProjectRoot 'scripts\BrowserNativeHost.ps1')

$testRoot = Join-Path $env:TEMP ('Win-Codex-Fix-BrowserNativeHost-' + [guid]::NewGuid().ToString('N'))
$registryPath = 'Registry::HKEY_CURRENT_USER\Software\WinCodexFix\Tests\' + [guid]::NewGuid().ToString('N')
$originalLocalAppData = $env:LOCALAPPDATA

try {
  $chromeRoot = Join-Path $testRoot 'chrome'
  $scriptsRoot = Join-Path $chromeRoot 'scripts'
  New-Item -ItemType Directory -Force -Path $scriptsRoot | Out-Null
  $firstId = 'a' * 32
  $secondId = 'b' * 32
  $pluralPath = Join-Path $scriptsRoot 'extension-ids.json'
  $singularPath = Join-Path $scriptsRoot 'extension-id.json'

  [System.IO.File]::WriteAllText(
    $pluralPath,
    ([ordered]@{ extensionIds = @($firstId, $secondId, $firstId); extensionHostName = 'com.openai.codexextension' } | ConvertTo-Json),
    [System.Text.UTF8Encoding]::new($false)
  )
  [System.IO.File]::WriteAllText(
    $singularPath,
    ([ordered]@{ extensionId = 'c' * 32; extensionHostName = 'com.openai.legacy' } | ConvertTo-Json),
    [System.Text.UTF8Encoding]::new($false)
  )

  $identity = Get-ChromiumNativeHostIdentity $chromeRoot
  Assert-True ($identity.Schema -eq 'extension-ids') 'plural identity did not take precedence'
  Assert-True (Test-ExactStringArray @($identity.ExtensionIds) @($firstId, $secondId)) 'plural identity deduplication/order failed'
  Assert-True ($identity.HostName -eq 'com.openai.codexextension') 'plural host name was not selected'

  Remove-Item -LiteralPath $pluralPath -Force
  $legacyIdentity = Get-ChromiumNativeHostIdentity $chromeRoot
  Assert-True ($legacyIdentity.Schema -eq 'extension-id') 'singular fallback was not selected'
  Assert-True (Test-ExactStringArray @($legacyIdentity.ExtensionIds) @(('c' * 32))) 'singular fallback ID mismatch'

  [System.IO.File]::WriteAllText(
    $pluralPath,
    ([ordered]@{ extensionIds = @('q' * 32); extensionHostName = 'com.openai.codexextension' } | ConvertTo-Json),
    [System.Text.UTF8Encoding]::new($false)
  )
  $invalidRejected = $false
  try { Get-ChromiumNativeHostIdentity $chromeRoot | Out-Null } catch { $invalidRejected = $true }
  Assert-True $invalidRejected 'invalid plural extension ID was accepted'

  [System.IO.File]::WriteAllText(
    $pluralPath,
    ([ordered]@{ extensionIds = @($firstId, $secondId); extensionHostName = 'com.openai.codexextension' } | ConvertTo-Json),
    [System.Text.UTF8Encoding]::new($false)
  )
  $identity = Get-ChromiumNativeHostIdentity $chromeRoot
  $hostPath = Join-Path $chromeRoot 'extension-host.exe'
  [System.IO.File]::WriteAllText($hostPath, 'host')
  $legacyManifest = Join-Path $testRoot 'legacy.json'
  $validLegacy = [ordered]@{
    allowed_origins = @(Get-ChromiumNativeHostExpectedOrigins $identity)
    name = $identity.HostName
    path = $hostPath
    type = 'stdio'
  }
  [System.IO.File]::WriteAllText($legacyManifest, ($validLegacy | ConvertTo-Json -Depth 5))
  Assert-True (Test-ChromiumNativeHostManifest $legacyManifest $identity @($hostPath)) 'valid legacy manifest was rejected'

  $validLegacy.allowed_origins = @($validLegacy.allowed_origins) + @('chrome-extension://' + ('d' * 32) + '/')
  [System.IO.File]::WriteAllText($legacyManifest, ($validLegacy | ConvertTo-Json -Depth 5))
  Assert-True (-not (Test-ChromiumNativeHostManifest $legacyManifest $identity @($hostPath))) 'foreign legacy origin was accepted'
  $validLegacy.allowed_origins = [string](Get-ChromiumNativeHostExpectedOrigins $identity)[0]
  [System.IO.File]::WriteAllText($legacyManifest, ($validLegacy | ConvertTo-Json -Depth 5))
  Assert-True (-not (Test-ChromiumNativeHostManifest $legacyManifest $identity @($hostPath))) 'scalar legacy origin was accepted'

  $pathsRoot = Join-Path $testRoot 'paths'
  $browserClient = Join-Path $pathsRoot 'browser-client.mjs'
  $extensionHost = Join-Path $pathsRoot 'extension-host.exe'
  $codexCli = Join-Path $pathsRoot 'codex.exe'
  $node = Join-Path $pathsRoot 'node.exe'
  $nodeModules = Join-Path $pathsRoot 'node_modules'
  $nodeRepl = Join-Path $pathsRoot 'node_repl.exe'
  $resources = Join-Path $pathsRoot 'resources'
  New-Item -ItemType Directory -Force -Path $nodeModules, $resources | Out-Null
  foreach ($path in @($browserClient, $extensionHost, $codexCli, $node, $nodeRepl)) {
    [System.IO.File]::WriteAllText($path, 'fixture')
  }
  $v2Path = Join-Path $testRoot 'v2.json'
  $entry = [ordered]@{
    schemaVersion = 2
    appServerProtocolVersion = 2
    nativeHostProtocolVersion = 2
    proxyPort = 0
    channel = 'prod'
    appVersion = '1.2.3.4'
    cliVersion = '1.2.3.4'
    nativeHostVersion = '9.8.7'
    extensionIds = @($firstId, $secondId)
    nativeHostNames = @($identity.HostName)
    extensionBuildChannels = @('prod')
    paths = [ordered]@{
      browserClientPath = $browserClient
      extensionHostPath = $extensionHost
      codexCliPath = $codexCli
      codexHome = $testRoot
      nodePath = $node
      nodeModuleDirs = @($nodeModules)
      nodeReplPath = $nodeRepl
      resourcesPath = $resources
    }
  }
  [System.IO.File]::WriteAllText($v2Path, ([ordered]@{ schemaVersion = 2; entries = @($entry) } | ConvertTo-Json -Depth 12))
  Assert-True (Test-ChromeNativeHostV2Manifest $v2Path @($identity.ExtensionIds) $identity.HostName '1.2.3.4' '9.8.7' $browserClient $extensionHost $codexCli $testRoot $node $nodeModules $nodeRepl $resources) 'valid v2 manifest was rejected'
  $entry.extensionIds = @($secondId, $firstId)
  [System.IO.File]::WriteAllText($v2Path, ([ordered]@{ schemaVersion = 2; entries = @($entry) } | ConvertTo-Json -Depth 12))
  Assert-True (-not (Test-ChromeNativeHostV2Manifest $v2Path @($identity.ExtensionIds) $identity.HostName '1.2.3.4' '9.8.7' $browserClient $extensionHost $codexCli $testRoot $node $nodeModules $nodeRepl $resources)) 'v2 extension ID order drift was accepted'

  $sidecarPath = Join-Path $pathsRoot 'extension-host-config.json'
  $sidecar = [ordered]@{
    schemaVersion = 1
    channel = 'prod'
    browserClientPath = $browserClient
    codexCliPath = $codexCli
    nodePath = $node
    nodeReplPath = $nodeRepl
    proxyHost = '127.0.0.1'
    proxyPort = 0
  }
  [System.IO.File]::WriteAllText($sidecarPath, ($sidecar | ConvertTo-Json -Depth 5))
  Assert-True (Test-ChromeExtensionHostSidecar $sidecarPath $browserClient $codexCli $node $nodeRepl) 'valid Chrome sidecar was rejected'
  $sidecar.proxyPort = 43123
  [System.IO.File]::WriteAllText($sidecarPath, ($sidecar | ConvertTo-Json -Depth 5))
  Assert-True (-not (Test-ChromeExtensionHostSidecar $sidecarPath $browserClient $codexCli $node $nodeRepl)) 'non-zero sidecar proxy port was accepted'

  $env:LOCALAPPDATA = Join-Path $testRoot 'local-app-data'
  $fixtureCodexHome = Join-Path $testRoot 'codex-home'
  $firstWriteCount = Ensure-ChromeNativeHostV2Manifest $fixtureCodexHome @($identity.ExtensionIds) $identity.HostName '1.2.3.4' '9.8.7' $browserClient $extensionHost $codexCli $node $nodeModules $nodeRepl $resources
  Assert-True ($firstWriteCount -eq 2) 'v2 writer did not create both fixture manifests'
  $fixtureV2Paths = @(
    (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\chrome-native-hosts-v2.json'),
    (Join-Path $fixtureCodexHome 'chrome-native-hosts-v2.json')
  )
  $beforeNoOpHashes = @($fixtureV2Paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
  $secondWriteCount = Ensure-ChromeNativeHostV2Manifest $fixtureCodexHome @($identity.ExtensionIds) $identity.HostName '1.2.3.4' '9.8.7' $browserClient $extensionHost $codexCli $node $nodeModules $nodeRepl $resources
  $afterNoOpHashes = @($fixtureV2Paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
  Assert-True ($secondWriteCount -eq 0) 'healthy v2 state was rewritten'
  Assert-True (Test-ExactStringArray $beforeNoOpHashes $afterNoOpHashes) 'healthy v2 hashes changed during no-op verification'

  $existingFile = Join-Path $testRoot 'existing.json'
  $newFile = Join-Path $testRoot 'new.json'
  [System.IO.File]::WriteAllText($existingFile, 'original')
  New-Item -Path $registryPath -Force | Out-Null
  Set-Item -LiteralPath $registryPath -Value 'original-registry'
  $snapshot = New-BrowserNativeHostRollbackBackup (Join-Path $testRoot 'backups') @($existingFile, $newFile) $registryPath
  [System.IO.File]::WriteAllText($existingFile, 'changed')
  [System.IO.File]::WriteAllText($newFile, 'created')
  Set-Item -LiteralPath $registryPath -Value 'changed-registry'
  Restore-BrowserNativeHostRollbackBackup $snapshot
  Assert-True ((Get-Content -LiteralPath $existingFile -Raw) -eq 'original') 'existing file rollback failed'
  Assert-True (-not (Test-Path -LiteralPath $newFile)) 'new file rollback failed'
  Assert-True (((Get-ItemProperty -LiteralPath $registryPath -Name '(default)').'(default)') -eq 'original-registry') 'registry rollback failed'

  Write-Host '[PASS] BrowserNativeHost focused fixtures passed.'
} finally {
  $env:LOCALAPPDATA = $originalLocalAppData
  Remove-Item -LiteralPath $registryPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
