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

function Test-ChromeExtensionHostSidecar(
  [string]$Path,
  [string]$BrowserClientPath,
  [string]$CodexCliPath,
  [string]$NodePath,
  [string]$NodeReplPath
) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $false
  }

  try {
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    return (
      [int]$document.schemaVersion -eq 1 -and
      [string]$document.channel -eq 'prod' -and
      [string]$document.proxyHost -eq '127.0.0.1' -and
      [int]$document.proxyPort -eq 0 -and
      (Test-WindowsPathEqual ([string]$document.browserClientPath) $BrowserClientPath) -and
      (Test-WindowsPathEqual ([string]$document.codexCliPath) $CodexCliPath) -and
      (Test-WindowsPathEqual ([string]$document.nodePath) $NodePath) -and
      (Test-WindowsPathEqual ([string]$document.nodeReplPath) $NodeReplPath) -and
      (Test-Path -LiteralPath $document.browserClientPath -PathType Leaf) -and
      (Test-Path -LiteralPath $document.codexCliPath -PathType Leaf) -and
      (Test-Path -LiteralPath $document.nodePath -PathType Leaf) -and
      (Test-Path -LiteralPath $document.nodeReplPath -PathType Leaf)
    )
  } catch {
    return $false
  }
}

function Write-BrowserNativeHostStep([string]$Message) {
  Write-Host "[codex-repair] $Message"
}

function Write-BrowserNativeHostUtf8NoBomAtomically([string]$Path, [string]$Text) {
  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $temporary = Join-Path $directory ('.{0}.atomic.{1}.tmp' -f (Split-Path -Leaf $Path), ([guid]::NewGuid().ToString('N')))
  $backup = Join-Path $directory ('.{0}.atomic.{1}.bak' -f (Split-Path -Leaf $Path), ([guid]::NewGuid().ToString('N')))
  try {
    [System.IO.File]::WriteAllText($temporary, $Text, [System.Text.UTF8Encoding]::new($false))
    if ([System.IO.File]::Exists($Path)) {
      [System.IO.File]::Replace($temporary, $Path, $backup)
    } else {
      [System.IO.File]::Move($temporary, $Path)
    }
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
  }
}

function Get-BrowserNativeHostShortSha256([string[]]$Values) {
  $joined = $Values -join [char]0
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $digest = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }
  return ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant().Substring(0, 32)
}

function Ensure-ChromeNativeHostV2Manifest(
  [string]$CodexHomePath,
  [string[]]$ExtensionIds,
  [string]$HostName,
  [string]$AppVersion,
  [string]$PluginVersion,
  [string]$BrowserClientPath,
  [string]$ExtensionHostPath,
  [string]$CodexCliPath,
  [string]$NodePath,
  [string]$NodeModuleDirs,
  [string]$NodeReplPath,
  [string]$ResourcesPath
) {
  $changedCount = 0
  $manifestPaths = @(
    (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\chrome-native-hosts-v2.json'),
    (Join-Path $CodexHomePath 'chrome-native-hosts-v2.json')
  )
  $channel = 'prod'
  $entryIdInputs = @($channel) + @($ExtensionIds) + @(
    $HostName,
    $PluginVersion,
    $ExtensionHostPath,
    $CodexCliPath,
    $CodexHomePath,
    $ResourcesPath
  )
  $entryId = 'codex-runtime-' + (Get-BrowserNativeHostShortSha256 $entryIdInputs)
  $installId = 'codex-install-' + (Get-BrowserNativeHostShortSha256 @($HostName, $ResourcesPath, $CodexHomePath))
  $resource = [ordered]@{
    schemaVersion = 2
    appServerProtocolVersion = 2
    appVersion = $AppVersion
    channel = $channel
    cliVersion = $AppVersion
    entryId = $entryId
    extensionBuildChannels = @($channel)
    extensionIds = @($ExtensionIds)
    installId = $installId
    nativeHostNames = @($HostName)
    nativeHostProtocolVersion = 2
    nativeHostVersion = $PluginVersion
    paths = [ordered]@{
      browserClientPath = $BrowserClientPath
      codexCliPath = $CodexCliPath
      codexHome = $CodexHomePath
      extensionHostPath = $ExtensionHostPath
      nodePath = $NodePath
      nodeModuleDirs = @($NodeModuleDirs)
      nodeReplPath = $NodeReplPath
      resourcesPath = $ResourcesPath
    }
    proxyHost = '127.0.0.1'
    proxyPort = 0
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
  }

  foreach ($manifestPath in $manifestPaths) {
    if (Test-ChromeNativeHostV2Manifest `
      $manifestPath `
      $ExtensionIds `
      $HostName `
      $AppVersion `
      $PluginVersion `
      $BrowserClientPath `
      $ExtensionHostPath `
      $CodexCliPath `
      $CodexHomePath `
      $NodePath `
      $NodeModuleDirs `
      $NodeReplPath `
      $ResourcesPath) {
      Write-BrowserNativeHostStep "Chrome native host v2 manifest OK: $manifestPath"
      continue
    }

    $entries = @()
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
      try {
        $existing = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $entries = @($existing.entries) | Where-Object {
          $names = @($_.nativeHostNames)
          ([string]$_.entryId -ne $entryId) -and ($names -notcontains $HostName)
        }
      } catch {
        Write-BrowserNativeHostStep "Ignoring invalid Chrome v2 manifest before rebuilding: $manifestPath"
      }
    }

    $document = [ordered]@{
      schemaVersion = 2
      entries = @($entries) + @($resource)
    }
    Write-BrowserNativeHostUtf8NoBomAtomically $manifestPath ($document | ConvertTo-Json -Depth 12)
    if (-not (Test-ChromeNativeHostV2Manifest `
        $manifestPath `
        $ExtensionIds `
        $HostName `
        $AppVersion `
        $PluginVersion `
        $BrowserClientPath `
        $ExtensionHostPath `
        $CodexCliPath `
        $CodexHomePath `
        $NodePath `
        $NodeModuleDirs `
        $NodeReplPath `
        $ResourcesPath)) {
      throw "Chrome native host v2 manifest post-write verification failed: $manifestPath"
    }
    $changedCount++
  }

  Write-BrowserNativeHostStep "Chrome native host v2 manifests verified: changed=$changedCount."
  return $changedCount
}

function New-BrowserNativeHostRollbackBackup(
  [string]$BackupRoot,
  [string[]]$FilePaths,
  [string]$RegistryPath
) {
  $backupDirectory = Join-Path $BackupRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null

  $fileSnapshots = New-Object System.Collections.Generic.List[object]
  $index = 0
  foreach ($filePath in @($FilePaths)) {
    $exists = Test-Path -LiteralPath $filePath -PathType Leaf
    $backupPath = if ($exists) {
      Join-Path $backupDirectory ('file-{0:D2}.bin' -f $index)
    } else {
      $null
    }
    if ($exists) {
      Copy-Item -LiteralPath $filePath -Destination $backupPath -Force
      if ((Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash) {
        throw "Browser native-host rollback backup hash mismatch: $filePath"
      }
    }
    $fileSnapshots.Add([pscustomobject]@{
        TargetPath = $filePath
        Existed = [bool]$exists
        BackupPath = $backupPath
      })
    $index++
  }

  $registryKeyExisted = Test-Path -LiteralPath $RegistryPath
  $registryDefaultExisted = $false
  $registryDefaultValue = $null
  if ($registryKeyExisted) {
    try {
      $registryDefaultValue = (Get-ItemProperty -LiteralPath $RegistryPath -Name '(default)' -ErrorAction Stop).'(default)'
      $registryDefaultExisted = $true
    } catch {
      $registryDefaultValue = $null
    }
  }

  $snapshot = [pscustomobject]@{
    BackupDirectory = $backupDirectory
    Files = $fileSnapshots.ToArray()
    RegistryPath = $RegistryPath
    RegistryKeyExisted = [bool]$registryKeyExisted
    RegistryDefaultExisted = [bool]$registryDefaultExisted
    RegistryDefaultValue = $registryDefaultValue
  }
  $metadataPath = Join-Path $backupDirectory 'rollback.json'
  [System.IO.File]::WriteAllText(
    $metadataPath,
    ($snapshot | ConvertTo-Json -Depth 8),
    [System.Text.UTF8Encoding]::new($false)
  )
  return $snapshot
}

function Restore-BrowserNativeHostRollbackBackup($Snapshot) {
  foreach ($fileSnapshot in @($Snapshot.Files)) {
    $targetPath = [string]$fileSnapshot.TargetPath
    if ([bool]$fileSnapshot.Existed) {
      $targetDirectory = Split-Path -Parent $targetPath
      New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
      $temporary = Join-Path $targetDirectory ('.{0}.restore.{1}.tmp' -f (Split-Path -Leaf $targetPath), ([guid]::NewGuid().ToString('N')))
      $superseded = Join-Path $targetDirectory ('.{0}.restore.{1}.bak' -f (Split-Path -Leaf $targetPath), ([guid]::NewGuid().ToString('N')))
      try {
        Copy-Item -LiteralPath ([string]$fileSnapshot.BackupPath) -Destination $temporary -Force
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
          [System.IO.File]::Replace($temporary, $targetPath, $superseded)
        } else {
          [System.IO.File]::Move($temporary, $targetPath)
        }
      } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $superseded -Force -ErrorAction SilentlyContinue
      }
      if ((Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath ([string]$fileSnapshot.BackupPath) -Algorithm SHA256).Hash) {
        throw "Browser native-host rollback restore hash mismatch: $targetPath"
      }
    } elseif (Test-Path -LiteralPath $targetPath -PathType Leaf) {
      Remove-Item -LiteralPath $targetPath -Force
    }
  }

  $registryPath = [string]$Snapshot.RegistryPath
  if ([bool]$Snapshot.RegistryKeyExisted) {
    New-Item -Path $registryPath -Force | Out-Null
    if ([bool]$Snapshot.RegistryDefaultExisted) {
      Set-Item -LiteralPath $registryPath -Value $Snapshot.RegistryDefaultValue
    } else {
      Remove-ItemProperty -LiteralPath $registryPath -Name '(default)' -Force -ErrorAction SilentlyContinue
    }
  } elseif (Test-Path -LiteralPath $registryPath) {
    Remove-Item -LiteralPath $registryPath -Force
  }
}
