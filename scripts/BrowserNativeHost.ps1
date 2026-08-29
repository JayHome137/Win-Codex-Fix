function Test-ExactStringArray([string[]]$Actual, [string[]]$Expected) {
  $actualValues = @($Actual)
  $expectedValues = @($Expected)
  if ($actualValues.Count -ne $expectedValues.Count) {
    return $false
  }
  for ($index = 0; $index -lt $expectedValues.Count; $index++) {
    if (-not [string]::Equals($actualValues[$index], $expectedValues[$index], [System.StringComparison]::Ordinal)) {
      return $false
    }
  }
  return $true
}

function Get-ChromiumNativeHostIdentity([string]$ChromeVersionRoot) {
  $scriptsRoot = Join-Path $ChromeVersionRoot 'scripts'
  $currentConfigPath = Join-Path $scriptsRoot 'extension-ids.json'
  $legacyConfigPath = Join-Path $scriptsRoot 'extension-id.json'

  if (Test-Path -LiteralPath $currentConfigPath -PathType Leaf) {
    try {
      $config = Get-Content -LiteralPath $currentConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
      throw "Could not parse current Chromium extension identity: $currentConfigPath"
    }
    $extensionIdsProperty = $config.PSObject.Properties['extensionIds']
    if (-not $extensionIdsProperty -or $extensionIdsProperty.Value -isnot [System.Array]) {
      throw "Current Chromium extensionIds must be a JSON array: $currentConfigPath"
    }
    $rawExtensionIds = @($config.extensionIds)
    $schema = 'extension-ids'
    $configPath = $currentConfigPath
  } elseif (Test-Path -LiteralPath $legacyConfigPath -PathType Leaf) {
    try {
      $config = Get-Content -LiteralPath $legacyConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
      throw "Could not parse legacy Chrome extension identity: $legacyConfigPath"
    }
    if ($config.extensionId -isnot [string]) {
      throw "Legacy Chrome extensionId must be a string: $legacyConfigPath"
    }
    $rawExtensionIds = @($config.extensionId)
    $schema = 'extension-id'
    $configPath = $legacyConfigPath
  } else {
    throw "No recognised Chromium extension identity exists under: $scriptsRoot"
  }

  $extensionIds = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  foreach ($rawExtensionId in $rawExtensionIds) {
    $extensionId = [string]$rawExtensionId
    if ($extensionId -notmatch '^[a-p]{32}$') {
      throw "Invalid Chromium extension ID in ${configPath}: $extensionId"
    }
    if (-not $seen.ContainsKey($extensionId)) {
      $seen[$extensionId] = $true
      $extensionIds.Add($extensionId)
    }
  }
  if ($extensionIds.Count -eq 0) {
    throw "Chromium extension identity has no extension IDs: $configPath"
  }

  $hostName = [string]$config.extensionHostName
  if ([string]::IsNullOrWhiteSpace($hostName) -or $hostName -notmatch '^[a-z0-9_.]+$') {
    throw "Chromium extension identity has an invalid host name: $configPath"
  }

  return [pscustomobject]@{
    ExtensionIds = @($extensionIds)
    HostName = $hostName
    Schema = $schema
    ConfigPath = $configPath
  }
}

function Get-ChromiumNativeHostExpectedOrigins($Identity) {
  return @($Identity.ExtensionIds | ForEach-Object { "chrome-extension://$_/" })
}

function Test-ChromiumNativeHostManifest(
  [string]$ManifestPath,
  $Identity,
  [string[]]$AllowedHostPaths
) {
  try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $allowedOriginsProperty = $manifest.PSObject.Properties['allowed_origins']
    if (-not $allowedOriginsProperty -or $allowedOriginsProperty.Value -isnot [System.Array]) {
      return $false
    }
    $actualOrigins = @($manifest.allowed_origins | ForEach-Object { [string]$_ })
    $expectedOrigins = @(Get-ChromiumNativeHostExpectedOrigins $Identity)
    $hostPathMatches = @($AllowedHostPaths | Where-Object {
        Test-WindowsPathEqual ([string]$manifest.path) ([string]$_)
      }).Count -gt 0
    return (
      [string]$manifest.name -eq [string]$Identity.HostName -and
      [string]$manifest.type -eq 'stdio' -and
      $hostPathMatches -and
      (Test-ExactStringArray $actualOrigins $expectedOrigins)
    )
  } catch {
    return $false
  }
}

function Test-ChromeNativeHostV2Manifest(
  [string]$Path,
  [string[]]$ExtensionIds,
  [string]$HostName,
  [string]$AppVersion,
  [string]$PluginVersion,
  [string]$BrowserClientPath,
  [string]$ExtensionHostPath,
  [string]$CodexCliPath,
  [string]$CodexHomePath,
  [string]$NodePath,
  [string]$NodeModuleDirs,
  [string]$NodeReplPath,
  [string]$ResourcesPath
) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $false
  }

  try {
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    $entries = @($document.entries | Where-Object {
        @($_.nativeHostNames) -contains $HostName
      })
    if ($entries.Count -ne 1) {
      return $false
    }
    $entry = $entries[0]
    $actualExtensionIds = @($entry.extensionIds | ForEach-Object { [string]$_ })
    $actualHostNames = @($entry.nativeHostNames | ForEach-Object { [string]$_ })
    $actualModuleDirs = @($entry.paths.nodeModuleDirs | ForEach-Object { [string]$_ })
    return (
      [int]$document.schemaVersion -eq 2 -and
      [int]$entry.schemaVersion -eq 2 -and
      [int]$entry.appServerProtocolVersion -eq 2 -and
      [int]$entry.nativeHostProtocolVersion -eq 2 -and
      [int]$entry.proxyPort -eq 0 -and
      [string]$entry.channel -eq 'prod' -and
      [string]$entry.appVersion -eq $AppVersion -and
      [string]$entry.cliVersion -eq $AppVersion -and
      [string]$entry.nativeHostVersion -eq $PluginVersion -and
      (Test-ExactStringArray $actualExtensionIds $ExtensionIds) -and
      (Test-ExactStringArray $actualHostNames @($HostName)) -and
      (Test-ExactStringArray @($entry.extensionBuildChannels | ForEach-Object { [string]$_ }) @('prod')) -and
      (Test-WindowsPathEqual ([string]$entry.paths.browserClientPath) $BrowserClientPath) -and
      (Test-WindowsPathEqual ([string]$entry.paths.extensionHostPath) $ExtensionHostPath) -and
      (Test-WindowsPathEqual ([string]$entry.paths.codexCliPath) $CodexCliPath) -and
      (Test-WindowsPathEqual ([string]$entry.paths.codexHome) $CodexHomePath) -and
      (Test-WindowsPathEqual ([string]$entry.paths.nodePath) $NodePath) -and
      (Test-ExactStringArray $actualModuleDirs @($NodeModuleDirs)) -and
      (Test-WindowsPathEqual ([string]$entry.paths.nodeReplPath) $NodeReplPath) -and
      (Test-WindowsPathEqual ([string]$entry.paths.resourcesPath) $ResourcesPath) -and
      (Test-Path -LiteralPath $entry.paths.browserClientPath -PathType Leaf) -and
      (Test-Path -LiteralPath $entry.paths.extensionHostPath -PathType Leaf) -and
      (Test-Path -LiteralPath $entry.paths.codexCliPath -PathType Leaf) -and
      (Test-Path -LiteralPath $entry.paths.nodePath -PathType Leaf) -and
      (Test-Path -LiteralPath $entry.paths.nodeReplPath -PathType Leaf) -and
      (Test-Path -LiteralPath $entry.paths.resourcesPath -PathType Container) -and
      @($entry.paths.nodeModuleDirs | Where-Object {
          -not (Test-Path -LiteralPath $_ -PathType Container)
        }).Count -eq 0
    )
  } catch {
    return $false
  }
}
