param(
  [switch]$Quick,
  [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepairRoot = Split-Path -Parent $PSScriptRoot

$ChromeOpaqueTextLibrary = Join-Path $PSScriptRoot 'ChromeOpaqueTextMaterialization.ps1'
if (-not (Test-Path -LiteralPath $ChromeOpaqueTextLibrary -PathType Leaf)) {
  throw "Missing Chrome opaque-text materialization library: $ChromeOpaqueTextLibrary"
}
. $ChromeOpaqueTextLibrary

function Write-Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) {
    Write-Host "[OK] $Name $Detail"
  } else {
    Write-Host "[FAIL] $Name $Detail"
    $script:Failed = $true
  }
}

function Test-PluginEnabled([string]$Text, [string]$PluginName) {
  $header = [regex]::Escape("[plugins.`"$PluginName@openai-bundled`"]")
  $match = [regex]::Match($Text, "(?ms)^$header\s*$\r?\n(?<body>.*?)(?=^\[|\z)")
  return (
    $match.Success -and
    $match.Groups['body'].Value -match '(?m)^\s*enabled\s*=\s*true\s*(?:#.*)?$'
  )
}

function Find-BundledSource {
  $candidateRoots = New-Object System.Collections.Generic.List[string]

  # Prioritize the configured marketplace source from config.toml (this is what
  # Codex Desktop actually uses). Then check AppX WindowsApps as the canonical
  # source, then the user-profile marketplace junction (which should point to
  # AppX), then managed project cache as last fallback.
  $configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
  if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw
    foreach ($match in [regex]::Matches($config, "source\s*=\s*'([^']*openai-bundled)'|source\s*=\s*`"([^`"]*openai-bundled)`"")) {
      $raw = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
      $candidateRoots.Add(($raw -replace '^\\\\\?\\', '')) | Out-Null
    }
  }

  # Add AppX WindowsApps source
  $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
  $packages = Get-ChildItem -LiteralPath $windowsApps -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'OpenAI.Codex_*_x64__2p2nqsd0c76g0' } |
    Sort-Object LastWriteTime -Descending
  foreach ($package in $packages) {
    $candidate = Join-Path $package.FullName 'app\resources\plugins\openai-bundled'
    $candidateRoots.Add($candidate) | Out-Null
  }

  $candidateRoots.Add((Join-Path $env:USERPROFILE '.codex\marketplaces\openai-bundled'))
  $candidateRoots.Add((Join-Path $RepairRoot 'state\openai-bundled-marketplace'))

  foreach ($root in @($candidateRoots)) {
    if (
      $root -and
      (Test-Path -LiteralPath (Join-Path $root '.agents\plugins\marketplace.json')) -and
      (Test-Path -LiteralPath (Join-Path $root 'plugins\chrome\.codex-plugin\plugin.json')) -and
      (Test-Path -LiteralPath (Join-Path $root 'plugins\browser\.codex-plugin\plugin.json')) -and
      (Test-Path -LiteralPath (Join-Path $root 'plugins\computer-use\.codex-plugin\plugin.json'))
    ) {
      return $root
    }
  }

  return $null
}

function Get-PluginVersion([string]$PluginDir) {
  $pluginJson = Join-Path $PluginDir '.codex-plugin\plugin.json'
  if (-not (Test-Path -LiteralPath $pluginJson)) {
    return $null
  }
  $json = Get-Content -LiteralPath $pluginJson -Raw | ConvertFrom-Json
  return [string]$json.version
}

function Test-Json([string]$Path) {
  try {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Test-ChromeNativeHostV2Manifest(
  [string]$Path,
  [string]$ExtensionId,
  [string]$ExtensionHostPath,
  [string]$BrowserClientPath,
  [string]$PluginVersion,
  [string]$AppVersion,
  [string]$ResourcesPath
) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $false
  }

  try {
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $entry = @($document.entries) |
      Where-Object {
        @($_.nativeHostNames) -contains 'com.openai.codexextension' -and
        @($_.extensionIds) -contains $ExtensionId
      } |
      Select-Object -First 1
    if (-not $entry) {
      return $false
    }

    return (
      [int]$document.schemaVersion -eq 2 -and
      [int]$entry.appServerProtocolVersion -eq 2 -and
      [int]$entry.nativeHostProtocolVersion -eq 2 -and
      [int]$entry.proxyPort -eq 0 -and
      [string]$entry.channel -eq 'prod' -and
       [string]$entry.appVersion -eq $AppVersion -and
       [string]$entry.cliVersion -eq $AppVersion -and
       [string]$entry.nativeHostVersion -eq $PluginVersion -and
       [string]$entry.paths.browserClientPath -ieq $BrowserClientPath -and
       [string]$entry.paths.extensionHostPath -ieq $ExtensionHostPath -and
       [string]$entry.paths.resourcesPath -ieq $ResourcesPath -and
       (Test-Path -LiteralPath $entry.paths.browserClientPath) -and
       (Test-Path -LiteralPath $entry.paths.extensionHostPath) -and
       (Test-Path -LiteralPath $entry.paths.codexCliPath) -and
       (Test-Path -LiteralPath $entry.paths.nodePath) -and
       (Test-Path -LiteralPath $entry.paths.nodeReplPath) -and
       (Test-Path -LiteralPath $entry.paths.resourcesPath) -and
       @($entry.paths.nodeModuleDirs | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -eq 0
    )
  } catch {
    return $false
  }
}

function Test-CompleteBundledSource([string]$Root) {
  return (
    $Root -and
    (Test-Path -LiteralPath (Join-Path $Root '.agents\plugins\marketplace.json')) -and
    (Test-Path -LiteralPath (Join-Path $Root 'plugins\chrome\.codex-plugin\plugin.json')) -and
    (Test-Path -LiteralPath (Join-Path $Root 'plugins\browser\.codex-plugin\plugin.json')) -and
    (Test-Path -LiteralPath (Join-Path $Root 'plugins\computer-use\.codex-plugin\plugin.json'))
  )
}

function Test-CompleteRegisteredAppxBrowserSource([string]$InstallLocation, [string]$BundledRoot) {
  if (-not $InstallLocation -or -not (Test-CompleteBundledSource $BundledRoot)) {
    return $false
  }

  $browserRoot = Join-Path $BundledRoot 'plugins\browser'
  $blockMapPath = Join-Path $InstallLocation 'AppxBlockMap.xml'
  if (
    -not (Test-Path -LiteralPath $browserRoot -PathType Container) -or
    -not (Test-Path -LiteralPath $blockMapPath -PathType Leaf)
  ) {
    return $false
  }

  try {
    $pluginManifest = Get-Content -LiteralPath (Join-Path $browserRoot '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
    if (-not [string]$pluginManifest.version) {
      return $false
    }

    [xml]$blockMap = Get-Content -LiteralPath $blockMapPath -Raw
    $browserPrefix = 'app\resources\plugins\openai-bundled\plugins\browser\'
    $expectedFiles = @($blockMap.BlockMap.File | Where-Object {
        ([string]$_.Name).StartsWith($browserPrefix, [System.StringComparison]::OrdinalIgnoreCase)
      })
    if ($expectedFiles.Count -eq 0) {
      return $false
    }

    $expectedByRelativePath = @{}
    foreach ($expected in $expectedFiles) {
      $relativePath = ([string]$expected.Name).Substring($browserPrefix.Length).Replace('/', '\')
      if (-not $relativePath -or $expectedByRelativePath.ContainsKey($relativePath)) {
        return $false
      }
      $expectedByRelativePath[$relativePath] = [int64]$expected.Size
    }

    $browserRootFull = (Get-Item -LiteralPath $browserRoot -Force).FullName.TrimEnd('\')
    $actualFiles = @(Get-ChildItem -LiteralPath $browserRoot -File -Recurse -Force)
    if ($actualFiles.Count -ne $expectedByRelativePath.Count) {
      return $false
    }

    foreach ($actual in $actualFiles) {
      $relativePath = $actual.FullName.Substring($browserRootFull.Length).TrimStart('\').Replace('/', '\')
      if (-not $expectedByRelativePath.ContainsKey($relativePath) -or $actual.Length -ne $expectedByRelativePath[$relativePath]) {
        return $false
      }
    }

    return $true
  } catch {
    return $false
  }
}

function Test-AppxBlockMapTreeComplete(
  [string]$InstallLocation,
  [string]$TreeRoot,
  [string]$AppxPrefix
) {
  if (
    [string]::IsNullOrWhiteSpace($InstallLocation) -or
    [string]::IsNullOrWhiteSpace($TreeRoot) -or
    [string]::IsNullOrWhiteSpace($AppxPrefix)
  ) {
    return $false
  }

  $rootItem = Get-Item -LiteralPath $TreeRoot -Force -ErrorAction SilentlyContinue
  $blockMapPath = Join-Path $InstallLocation 'AppxBlockMap.xml'
  if (
    (-not $rootItem) -or
    (-not $rootItem.PSIsContainer) -or
    (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or
    (-not (Test-Path -LiteralPath $blockMapPath -PathType Leaf))
  ) {
    return $false
  }

  try {
    $prefix = $AppxPrefix.Replace('/', '\').TrimStart('\')
    if (-not $prefix.EndsWith('\')) {
      $prefix += '\'
    }

    [xml]$blockMap = Get-Content -LiteralPath $blockMapPath -Raw -ErrorAction Stop
    $expected = @{}
    foreach ($entry in @($blockMap.SelectNodes("//*[local-name()='File']"))) {
      $name = ([string]$entry.GetAttribute('Name')).Replace('/', '\')
      if (-not $name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
      }

      $relative = $name.Substring($prefix.Length).TrimStart('\')
      [int64]$size = 0
      if (
        [string]::IsNullOrWhiteSpace($relative) -or
        [System.IO.Path]::IsPathRooted($relative) -or
        @($relative.Split([char[]]'\') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or
        $expected.ContainsKey($relative) -or
        -not [int64]::TryParse([string]$entry.GetAttribute('Size'), [ref]$size)
      ) {
        return $false
      }
      $expected[$relative] = $size
    }

    if ($expected.Count -eq 0) {
      return $false
    }

    $rootFull = $rootItem.FullName.TrimEnd('\')
    $items = @(Get-ChildItem -LiteralPath $TreeRoot -Force -Recurse -ErrorAction Stop)
    if (@($items | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
      return $false
    }
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    if ($files.Count -ne $expected.Count) {
      return $false
    }

    foreach ($file in $files) {
      $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\').Replace('/', '\')
      if (-not $expected.ContainsKey($relative) -or [int64]$file.Length -ne [int64]$expected[$relative]) {
        return $false
      }
    }
    return $true
  } catch {
    return $false
  }
}

function Get-DirectoryContentDigest([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return $null
  }

  $rootFull = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\')
  $files = @(Get-ChildItem -LiteralPath $Root -Force -Recurse -File | Sort-Object FullName)
  $entries = @(foreach ($file in $files) {
      $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\')
      $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
      "$relative|$($file.Length)|$hash"
    })

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($entries -join "`n")
    $digest = [System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', ''
  } finally {
    $sha.Dispose()
  }

  return [pscustomobject]@{
    FileCount = $files.Count
    Digest = $digest
  }
}

function Test-BundledSourceMatches([string]$ActualRoot, [string]$ExpectedRoot) {
  $actualDigest = Get-DirectoryContentDigest $ActualRoot
  $expectedDigest = Get-DirectoryContentDigest $ExpectedRoot
  return (
    $null -ne $actualDigest -and
    $null -ne $expectedDigest -and
    $actualDigest.FileCount -eq $expectedDigest.FileCount -and
    $actualDigest.Digest -eq $expectedDigest.Digest
  )
}

function Get-BrowserCacheTreeInventory([string]$Root) {
  $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue
  if (-not $rootItem) {
    return [pscustomobject]@{
      Exists = $false
      IsDirectory = $false
      IsReparsePoint = $false
      Files = @{}
      Directories = @{}
      ReparsePaths = @()
    }
  }

  $isReparsePoint = (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  if ((-not $rootItem.PSIsContainer) -or $isReparsePoint) {
    return [pscustomobject]@{
      Exists = $true
      IsDirectory = [bool]$rootItem.PSIsContainer
      IsReparsePoint = $isReparsePoint
      Files = @{}
      Directories = @{}
      ReparsePaths = @()
    }
  }

  $rootFull = $rootItem.FullName.TrimEnd('\')
  $files = @{}
  $directories = @{}
  $reparsePaths = New-Object System.Collections.Generic.List[string]
  foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop)) {
    $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\').Replace('/', '\')
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      $reparsePaths.Add($relative)
      continue
    }
    if ($item.PSIsContainer) {
      $directories[$relative] = $true
      continue
    }
    $files[$relative] = [pscustomobject]@{
      Length = $item.Length
      SHA256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }
  }

  return [pscustomobject]@{
    Exists = $true
    IsDirectory = $true
    IsReparsePoint = $false
    Files = $files
    Directories = $directories
    ReparsePaths = @($reparsePaths | Sort-Object)
  }
}

function Get-BrowserCacheVerificationState(
  [string]$SourceDir,
  [string]$ConcreteDir,
  [hashtable]$RuntimeTextExpectations
) {
  if (-not $SourceDir) {
    return [pscustomobject]@{
      State = 'browser-cache-rebuild-required'
      SourceFileCount = 0
      ConcreteFileCount = 0
      MissingFileCount = 0
      ExtraFileCount = 0
      ConflictCount = 1
      RuntimeTextFileCount = 0
      Detail = 'current AppX Browser source is unavailable'
    }
  }

  $source = Get-BrowserCacheTreeInventory $SourceDir
  if ((-not $source.Exists) -or (-not $source.IsDirectory) -or $source.IsReparsePoint -or @($source.ReparsePaths).Count -gt 0) {
    return [pscustomobject]@{
      State = 'browser-cache-rebuild-required'
      SourceFileCount = 0
      ConcreteFileCount = 0
      MissingFileCount = 0
      ExtraFileCount = 0
      ConflictCount = 1
      RuntimeTextFileCount = 0
      Detail = "current AppX Browser source is not a plain complete directory: $SourceDir"
    }
  }

  $concrete = Get-BrowserCacheTreeInventory $ConcreteDir
  if (-not $concrete.Exists) {
    return [pscustomobject]@{
      State = 'browser-cache-missing-only'
      SourceFileCount = @($source.Files.Keys).Count
      ConcreteFileCount = 0
      MissingFileCount = @($source.Files.Keys).Count
      ExtraFileCount = 0
      ConflictCount = 0
      RuntimeTextFileCount = 0
      Detail = 'current Browser concrete directory is absent'
    }
  }

  if ((-not $concrete.IsDirectory) -or $concrete.IsReparsePoint -or @($concrete.ReparsePaths).Count -gt 0) {
    return [pscustomobject]@{
      State = 'browser-cache-rebuild-required'
      SourceFileCount = @($source.Files.Keys).Count
      ConcreteFileCount = @($concrete.Files.Keys).Count
      MissingFileCount = 0
      ExtraFileCount = 0
      ConflictCount = 1
      RuntimeTextFileCount = 0
      Detail = 'current Browser concrete is not a plain directory or contains a reparse point'
    }
  }

  $missing = 0
  $extra = 0
  $conflicts = 0
  $runtimeText = 0
  foreach ($relative in @($source.Files.Keys)) {
    if ($concrete.Directories.ContainsKey($relative)) {
      $conflicts += 1
    } elseif (-not $concrete.Files.ContainsKey($relative)) {
      $missing += 1
    } else {
      $expected = $source.Files[$relative]
      $actual = $concrete.Files[$relative]
      $runtimeExpectation = if ($RuntimeTextExpectations -and $RuntimeTextExpectations.ContainsKey($relative)) {
        $RuntimeTextExpectations[$relative]
      } else {
        $null
      }
      if ($runtimeExpectation) {
        if (
          ([int64]$runtimeExpectation.Length -ne [int64]$expected.Length) -or
          ([string]$runtimeExpectation.SourceHash -ne [string]$expected.SHA256)
        ) {
          $conflicts += 1
        } elseif (
          ([int64]$actual.Length -eq [int64]$runtimeExpectation.Length) -and
          ([string]$actual.SHA256 -eq [string]$runtimeExpectation.ExpectedHash)
        ) {
          continue
        } elseif (
          ([int64]$actual.Length -eq [int64]$expected.Length) -and
          ([string]$actual.SHA256 -eq [string]$expected.SHA256)
        ) {
          $runtimeText += 1
        } else {
          $conflicts += 1
        }
      } elseif (($expected.Length -ne $actual.Length) -or ($expected.SHA256 -ne $actual.SHA256)) {
        $conflicts += 1
      }
    }
  }
  foreach ($relative in @($source.Directories.Keys)) {
    if ($concrete.Files.ContainsKey($relative)) {
      $conflicts += 1
    }
  }
  foreach ($relative in @($concrete.Files.Keys)) {
    if (-not $source.Files.ContainsKey($relative)) {
      if ($source.Directories.ContainsKey($relative)) {
        $conflicts += 1
      } else {
        $extra += 1
      }
    }
  }

  $state = if (($extra -gt 0) -or ($conflicts -gt 0)) {
    'browser-cache-rebuild-required'
  } elseif ($missing -gt 0 -and $runtimeText -gt 0) {
    'browser-cache-repairable'
  } elseif ($missing -gt 0) {
    'browser-cache-missing-only'
  } elseif ($runtimeText -gt 0) {
    'browser-cache-runtime-text-only'
  } else {
    'browser-cache-complete'
  }
  return [pscustomobject]@{
    State = $state
    SourceFileCount = @($source.Files.Keys).Count
    ConcreteFileCount = @($concrete.Files.Keys).Count
    MissingFileCount = $missing
    ExtraFileCount = $extra
    ConflictCount = $conflicts
    RuntimeTextFileCount = $runtimeText
    Detail = "source=$(@($source.Files.Keys).Count), concrete=$(@($concrete.Files.Keys).Count), missing=$missing, runtimeText=$runtimeText, extra=$extra, conflicts=$conflicts"
  }
}

function Test-BrowserJunctionTarget([string]$Path, [string]$ExpectedTarget) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (
    (-not $item) -or
    (-not $item.PSIsContainer) -or
    (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -or
    ([string]$item.LinkType -ne 'Junction')
  ) {
    return $false
  }
  $target = @($item.Target) | Select-Object -First 1
  return $target -and ($target.TrimEnd('\') -ieq $ExpectedTarget.TrimEnd('\'))
}

function Get-BrowserVerificationState(
  [string]$BrowserSource,
  [string]$BrowserRoot,
  [string]$BrowserVersion,
  [hashtable]$RuntimeTextExpectations
) {
  $browserVersionDir = if ($BrowserVersion) { Join-Path $BrowserRoot $BrowserVersion } else { $null }
  $cacheState = Get-BrowserCacheVerificationState $BrowserSource $browserVersionDir $RuntimeTextExpectations
  $latestPath = Join-Path $BrowserRoot 'latest'
  $metadataPath = Join-Path $BrowserRoot '.codex-plugin'
  $metadataTarget = if ($browserVersionDir) { Join-Path $browserVersionDir '.codex-plugin' } else { $null }
  $latestOk = $browserVersionDir -and (Test-BrowserJunctionTarget $latestPath $browserVersionDir)
  $metadataOk = $metadataTarget -and (Test-BrowserJunctionTarget $metadataPath $metadataTarget)
  $state = if ($cacheState.State -eq 'browser-cache-complete' -and (-not $latestOk -or -not $metadataOk)) {
    'browser-discovery-only-drift'
  } else {
    $cacheState.State
  }

  return [pscustomobject]@{
    State = $state
    CacheState = $cacheState
    VersionDir = $browserVersionDir
    LatestPath = $latestPath
    MetadataPath = $metadataPath
    MetadataTarget = $metadataTarget
    LatestOk = [bool]$latestOk
    MetadataOk = [bool]$metadataOk
  }
}

function Test-TmpRuntimeMarketplaceCompatible([string]$ActualRoot, [string]$ExpectedRoot) {
  try {
    $actualManifestPath = Join-Path $ActualRoot '.agents\plugins\marketplace.json'
    $expectedManifestPath = Join-Path $ExpectedRoot '.agents\plugins\marketplace.json'
    if ((-not (Test-Json $actualManifestPath)) -or (-not (Test-Json $expectedManifestPath))) {
      return $false
    }

    $actualManifest = Get-Content -LiteralPath $actualManifestPath -Raw | ConvertFrom-Json
    $expectedManifest = Get-Content -LiteralPath $expectedManifestPath -Raw | ConvertFrom-Json
    if ([string]$actualManifest.name -ne [string]$expectedManifest.name) {
      return $false
    }

    $expectedVersions = @{}
    foreach ($plugin in @($expectedManifest.plugins)) {
      $name = [string]$plugin.name
      $pluginJson = Join-Path $ExpectedRoot "plugins\$name\.codex-plugin\plugin.json"
      if ((-not $name) -or (-not (Test-Json $pluginJson))) {
        return $false
      }
      $metadata = Get-Content -LiteralPath $pluginJson -Raw | ConvertFrom-Json
      $expectedVersions[$name] = [string]$metadata.version
    }

    $seen = @{}
    foreach ($plugin in @($actualManifest.plugins)) {
      $name = [string]$plugin.name
      $sourceType = [string]$plugin.source.source
      $sourcePath = ([string]$plugin.source.path).Replace('\', '/')
      if (
        (-not $name) -or
        $seen.ContainsKey($name) -or
        (-not $expectedVersions.ContainsKey($name)) -or
        $sourceType -ne 'local' -or
        $sourcePath -ne "./plugins/$name"
      ) {
        return $false
      }

      $pluginJson = Join-Path $ActualRoot "plugins\$name\.codex-plugin\plugin.json"
      if (-not (Test-Json $pluginJson)) {
        return $false
      }
      $metadata = Get-Content -LiteralPath $pluginJson -Raw | ConvertFrom-Json
      if ([string]$metadata.version -ne [string]$expectedVersions[$name]) {
        return $false
      }
      $seen[$name] = $true
    }

    return $true
  } catch {
    return $false
  }
}

function Find-LatestWindowsAppsBundledSource([scriptblock]$PackageProvider) {
  try {
    $appxPackages = if ($PackageProvider) {
      @(& $PackageProvider)
    } else {
      @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
    }
  } catch {
    return $null
  }

  $packages = @($appxPackages | Sort-Object Version -Descending)
  if ($packages.Count -eq 0) {
    return $null
  }
  $package = $packages[0]

  $installLocation = [string]$package.InstallLocation
  if (-not $installLocation) {
    return $null
  }

  $candidate = Join-Path $installLocation 'app\resources\plugins\openai-bundled'
  if (Test-CompleteRegisteredAppxBrowserSource $installLocation $candidate) {
    return $candidate
  }

  return $null
}

function Find-LatestWindowsAppsCuaNodeSource([scriptblock]$PackageProvider) {
  try {
    $appxPackages = if ($PackageProvider) {
      @(& $PackageProvider)
    } else {
      @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
    }
  } catch {
    return $null
  }

  $package = @($appxPackages | Sort-Object Version -Descending | Select-Object -First 1)[0]
  if (-not $package -or [string]::IsNullOrWhiteSpace([string]$package.InstallLocation)) {
    return $null
  }

  $candidate = Join-Path ([string]$package.InstallLocation) 'app\resources\cua_node'
  if (
    (Test-Path -LiteralPath (Join-Path $candidate 'manifest.json')) -and
    (Test-Path -LiteralPath (Join-Path $candidate 'bin\node.exe')) -and
    (Test-Path -LiteralPath (Join-Path $candidate 'bin\node_repl.exe'))
  ) {
    return $candidate
  }

  return $null
}

function Get-CuaRuntimeHash([string]$RuntimeRoot) {
  $payload = New-Object System.Text.StringBuilder
  foreach ($relativePath in @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')) {
    $filePath = Join-Path $RuntimeRoot ($relativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $filePath)) {
      return $null
    }

    $digest = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$payload.Append($relativePath)
    [void]$payload.Append([char]0)
    [void]$payload.Append($digest)
    [void]$payload.Append([char]0)
  }

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload.ToString())
    $hashBytes = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }

  return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant().Substring(0, 16)
}

function Find-CurrentCodexCli {
  $mirror = Join-Path $RepairRoot 'state\codex-cli\codex.exe'
  if (Test-Path -LiteralPath $mirror) {
    return $mirror
  }

  $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1

  if (-not $package) {
    return $null
  }

  $candidate = Join-Path $package.InstallLocation 'app\resources\codex.exe'
  if (Test-Path -LiteralPath $candidate) {
    return $candidate
  }

  return $null
}

function Find-CurrentAppxCodexCli {
  $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1

  if (-not $package) {
    return $null
  }

  $candidate = Join-Path $package.InstallLocation 'app\resources\codex.exe'
  if (Test-Path -LiteralPath $candidate) {
    return $candidate
  }

  return $null
}

function Get-CodexCliEnvironmentState([string]$ExpectedPath) {
  $userValue = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', [EnvironmentVariableTarget]::User)
  $machineValue = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', [EnvironmentVariableTarget]::Machine)
  $userMatches = [string]::Equals([string]$userValue, $ExpectedPath, [StringComparison]::Ordinal)
  $machineConflicts = (
    -not [string]::IsNullOrWhiteSpace($machineValue) -and
    -not [string]::Equals([string]$machineValue, $ExpectedPath, [StringComparison]::OrdinalIgnoreCase)
  )

  return [pscustomobject]@{
    UserValue = $userValue
    MachineValue = $machineValue
    UserMatches = $userMatches
    MachineConflicts = $machineConflicts
  }
}

function Get-OfficialPluginList {
  $codexCli = Find-CurrentCodexCli
  if (-not $codexCli) {
    return $null
  }

  try {
    $raw = (& $codexCli plugin list --json 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
      return $null
    }
    return ($raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Test-WindowsPathEqual([string]$Left, [string]$Right) {
  if ((-not $Left) -or (-not $Right)) {
    return $false
  }

  $normalizedLeft = ($Left.Replace('/', '\') -replace '^\\\\\?\\', '').TrimEnd('\')
  $normalizedRight = ($Right.Replace('/', '\') -replace '^\\\\\?\\', '').TrimEnd('\')
  return $normalizedLeft -ieq $normalizedRight
}

function Get-TomlPathValue([string]$Text, [string]$Name) {
  if (-not $Text) {
    return $null
  }

  $escapedName = [regex]::Escape($Name)
  $singleQuoted = [regex]::Match($Text, "(?m)^$escapedName\s*=\s*'([^']*)'[ \t]*\r?$")
  if ($singleQuoted.Success) {
    return $singleQuoted.Groups[1].Value
  }

  $doublePattern = '(?m)^' + $escapedName + '\s*=\s*"((?:\\.|[^"])*)"[ \t]*\r?$'
  $doubleQuoted = [regex]::Match($Text, $doublePattern)
  if ($doubleQuoted.Success) {
    return $doubleQuoted.Groups[1].Value.Replace('\\', '\')
  }

  return $null
}

function Get-ConfiguredNotifyExecutable([string]$Text) {
  $singleQuoted = [regex]::Match($Text, "(?m)^notify\s*=\s*\[\s*'([^']*codex-computer-use\.exe)'\s*,\s*`"turn-ended`"\s*\]")
  if ($singleQuoted.Success) {
    return $singleQuoted.Groups[1].Value
  }

  $doubleQuoted = [regex]::Match($Text, '(?m)^notify\s*=\s*\[\s*"([^"]*codex-computer-use\.exe)"\s*,\s*"turn-ended"\s*\]')
  if ($doubleQuoted.Success) {
    return $doubleQuoted.Groups[1].Value.Replace('\\', '\')
  }

  return $null
}

function Get-CurrentCuaRuntimeBin([string]$ConfigPath) {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    return $null
  }

  $text = Get-Content -LiteralPath $ConfigPath -Raw
  $section = [regex]::Match(
    $text,
    '(?ms)^\[mcp_servers\.node_repl\]\s*$\r?\n(?<body>.*?)(?=^\[|\z)'
  )
  if (-not $section.Success) {
    return $null
  }

  $command = Get-TomlPathValue $section.Groups['body'].Value 'command'
  if ((-not $command) -or ($command -notmatch '(?i)[\\/]cua_node[\\/].*[\\/]bin[\\/]node_repl\.exe$')) {
    return $null
  }

  return Split-Path -Parent $command.Replace('/', '\')
}

$script:Failed = $false

if ($LibraryOnly) {
  return
}

$CodexHome = Join-Path $env:USERPROFILE '.codex'
$PluginCacheRoot = Join-Path $CodexHome 'plugins\cache\openai-bundled'
$ConfigPath = Join-Path $CodexHome 'config.toml'
$ExtensionManifest = Join-Path $env:LOCALAPPDATA 'OpenAI\extension\com.openai.codexextension.json'
$ChromeNativeHostV2Manifest = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\chrome-native-hosts-v2.json'
$CodexCliMirror = Join-Path $RepairRoot 'state\codex-cli\codex.exe'
$CurrentCodexPackage = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
  Sort-Object Version -Descending |
  Select-Object -First 1

$LatestWindowsAppsBundledSource = Find-LatestWindowsAppsBundledSource
$BundledSource = if ($LatestWindowsAppsBundledSource) {
  $LatestWindowsAppsBundledSource
} else {
  Find-BundledSource
}
$PersistentBundledMarketplaceRoot = Join-Path $RepairRoot 'state\openai-bundled-marketplace'
Write-Check 'current AppX bundled source found' ($null -ne $LatestWindowsAppsBundledSource) $LatestWindowsAppsBundledSource
Write-Check `
  'current AppX bundled source matches AppxBlockMap' `
  ($CurrentCodexPackage -and (Test-AppxBlockMapTreeComplete ([string]$CurrentCodexPackage.InstallLocation) $LatestWindowsAppsBundledSource 'app\resources\plugins\openai-bundled\')) `
  $LatestWindowsAppsBundledSource
if ($BundledSource) {
  Write-Check 'bundled source marketplace JSON parses' (Test-Json (Join-Path $BundledSource '.agents\plugins\marketplace.json'))
}

Write-Check 'persistent bundled marketplace mirror' (Test-CompleteBundledSource $PersistentBundledMarketplaceRoot) $PersistentBundledMarketplaceRoot
Write-Check `
  'persistent bundled marketplace matches current AppX' `
  (Test-BundledSourceMatches $PersistentBundledMarketplaceRoot $LatestWindowsAppsBundledSource) `
  $PersistentBundledMarketplaceRoot

$MarketplaceLink = Join-Path $CodexHome 'marketplaces\openai-bundled'
$marketplaceCurrent = $false
$marketplaceDetail = $MarketplaceLink
if (Test-Path -LiteralPath $MarketplaceLink) {
  $marketplaceItem = Get-Item -LiteralPath $MarketplaceLink -Force
  $target = @($marketplaceItem.Target) | Select-Object -First 1
  $marketplaceDetail = "$MarketplaceLink -> $target"
  $marketplaceCurrent = (
    ($marketplaceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and
    $target -and
    $target.TrimEnd('\') -ieq $PersistentBundledMarketplaceRoot.TrimEnd('\')
  )
}
Write-Check 'marketplace junction current' $marketplaceCurrent $marketplaceDetail

$TmpRuntimeMarketplace = Join-Path $CodexHome '.tmp\bundled-marketplaces\openai-bundled'
$tmpRuntimeMarketplaceCurrent = $false
$tmpRuntimeMarketplaceDetail = $TmpRuntimeMarketplace
$tmpRuntimeMarketplaceItem = Get-Item -LiteralPath $TmpRuntimeMarketplace -Force -ErrorAction SilentlyContinue
if ($tmpRuntimeMarketplaceItem) {
  if (-not $tmpRuntimeMarketplaceItem.PSIsContainer) {
    $tmpRuntimeMarketplaceDetail = "$TmpRuntimeMarketplace is not a directory"
  } elseif (($tmpRuntimeMarketplaceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    $tmpTarget = @($tmpRuntimeMarketplaceItem.Target) | Select-Object -First 1
    $tmpRuntimeMarketplaceDetail = "$TmpRuntimeMarketplace is an unexpected reparse point -> $tmpTarget"
  } else {
    $tmpRuntimeMarketplaceCurrent = Test-TmpRuntimeMarketplaceCompatible $TmpRuntimeMarketplace $LatestWindowsAppsBundledSource
    $pluginCount = 0
    try {
      $tmpManifest = Get-Content -LiteralPath (Join-Path $TmpRuntimeMarketplace '.agents\plugins\marketplace.json') -Raw | ConvertFrom-Json
      $pluginCount = @($tmpManifest.plugins).Count
    } catch {
      $pluginCount = 0
    }
    $tmpRuntimeMarketplaceDetail = "$TmpRuntimeMarketplace physical; compatible current-AppX subset=$tmpRuntimeMarketplaceCurrent; plugins=$pluginCount"
  }
} else {
  $tmpRuntimeMarketplaceCurrent = $true
  $tmpRuntimeMarketplaceDetail = "$TmpRuntimeMarketplace host scratch is not materialized"
}
Write-Check 'tmp runtime marketplace host-owned and current' $tmpRuntimeMarketplaceCurrent $tmpRuntimeMarketplaceDetail

$browserAppxSource = if ($LatestWindowsAppsBundledSource) { Join-Path $LatestWindowsAppsBundledSource 'plugins\browser' } else { $null }
$browserVersion = if ($browserAppxSource) { Get-PluginVersion $browserAppxSource } else { $null }
$chromeVersion = if ($LatestWindowsAppsBundledSource) { Get-PluginVersion (Join-Path $LatestWindowsAppsBundledSource 'plugins\chrome') } else { $null }
$computerUseVersion = if ($BundledSource) { Get-PluginVersion (Join-Path $BundledSource 'plugins\computer-use') } else { $null }

$browserRoot = Join-Path $PluginCacheRoot 'browser'
$chromeRoot = Join-Path $PluginCacheRoot 'chrome'
$computerUseRoot = Join-Path $PluginCacheRoot 'computer-use'

$browserOpaqueText = if ($LatestWindowsAppsBundledSource -and $browserVersion -and $chromeVersion) {
  Get-BrowserOpaqueTextMaterializationPlan `
    $browserAppxSource `
    $browserRoot `
    $browserVersion `
    $chromeRoot `
    $chromeVersion
} else {
  $null
}
$browserRuntimeTextExpectations = if (
  $browserOpaqueText -and
  $browserOpaqueText.State -in @('complete', 'repairable')
) {
  ConvertTo-BrowserOpaqueTextExpectationMap $browserOpaqueText.Expectations
} else {
  @{}
}
$browserVerification = Get-BrowserVerificationState `
  $browserAppxSource `
  $browserRoot `
  $browserVersion `
  $browserRuntimeTextExpectations
Write-Check 'browser current-AppX cache state' ($browserVerification.State -eq 'browser-cache-complete') "$($browserVerification.State); $($browserVerification.CacheState.Detail)"
Write-Check 'browser latest points to current AppX concrete' $browserVerification.LatestOk "$($browserVerification.LatestPath) -> $($browserVerification.VersionDir)"
Write-Check 'browser metadata points to current AppX concrete metadata' $browserVerification.MetadataOk "$($browserVerification.MetadataPath) -> $($browserVerification.MetadataTarget)"

$paths = @(
  @{ Name = 'browser client'; Path = Join-Path $browserRoot 'latest\scripts\browser-client.mjs' },
  @{ Name = 'browser icon'; Path = Join-Path $browserRoot 'latest\assets\browser.png' },
  @{ Name = 'chrome client'; Path = Join-Path $chromeRoot 'latest\scripts\browser-client.mjs' },
  @{ Name = 'chrome extension host'; Path = Join-Path $chromeRoot 'latest\extension-host\windows\x64\extension-host.exe' },
  @{ Name = 'chrome icon'; Path = Join-Path $chromeRoot 'latest\assets\google-chrome.png' },
  @{ Name = 'computer-use client'; Path = Join-Path $computerUseRoot 'latest\scripts\computer-use-client.mjs' },
  @{ Name = 'native host manifest'; Path = $ExtensionManifest }
)
foreach ($entry in $paths) {
  Write-Check $entry.Name (Test-Path -LiteralPath $entry.Path) $entry.Path
}

foreach ($pair in @(
  @{ Name = 'chrome latest'; Root = $chromeRoot; Version = $chromeVersion },
  @{ Name = 'computer-use latest'; Root = $computerUseRoot; Version = $computerUseVersion }
)) {
  $latest = Join-Path $pair.Root 'latest'
  $ok = $false
  $detail = $latest
  if (Test-Path -LiteralPath $latest) {
    $item = Get-Item -LiteralPath $latest -Force
    $target = @($item.Target) | Select-Object -First 1
    $detail = "$latest -> $target"
    if ($target -and $target -notlike '*\.tmp\bundled-marketplaces\*') {
      if ($pair.Version) {
        $ok = ($target.TrimEnd('\') -ieq (Join-Path $pair.Root $pair.Version).TrimEnd('\'))
      } else {
        $ok = $true
      }
    }
  }
  Write-Check $pair.Name $ok $detail

  $metadataLink = Join-Path $pair.Root '.codex-plugin'
  $metadataOk = $false
  $metadataDetail = $metadataLink
  if ($pair.Version -and (Test-Path -LiteralPath $metadataLink)) {
    $item = Get-Item -LiteralPath $metadataLink -Force
    $target = @($item.Target) | Select-Object -First 1
    $expected = Join-Path (Join-Path $pair.Root $pair.Version) '.codex-plugin'
    $metadataDetail = "$metadataLink -> $target"
    $metadataOk = (
      ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and
      $target -and
      $target.TrimEnd('\') -ieq $expected.TrimEnd('\') -and
      (Test-Path -LiteralPath (Join-Path $metadataLink 'plugin.json'))
    )
  }
  Write-Check ($pair.Name -replace ' latest$', ' metadata link') $metadataOk $metadataDetail
}

$browserOpaqueTextOk = $browserOpaqueText -and ($browserOpaqueText.State -in @('not-required', 'complete'))
$browserOpaqueTextDetail = if ($browserOpaqueText) {
  "$($browserOpaqueText.State); opaqueFiles=$($browserOpaqueText.OpaqueFileCount); $($browserOpaqueText.ErrorSummary)"
} else {
  'current AppX Browser/Chrome source or version unavailable'
}
Write-Check 'browser runtime opaque-text materialization' $browserOpaqueTextOk $browserOpaqueTextDetail

$chromeOpaqueText = if ($LatestWindowsAppsBundledSource -and $chromeVersion) {
  Get-ChromeOpaqueTextMaterializationPlan `
    (Join-Path $LatestWindowsAppsBundledSource 'plugins\chrome') `
    $chromeRoot `
    $chromeVersion
} else {
  $null
}
$chromeOpaqueTextOk = $chromeOpaqueText -and ($chromeOpaqueText.State -in @('not-required', 'complete'))
$chromeOpaqueTextDetail = if ($chromeOpaqueText) {
  "$($chromeOpaqueText.State); opaqueFiles=$($chromeOpaqueText.OpaqueFileCount); $($chromeOpaqueText.ErrorSummary)"
} else {
  'current AppX Chrome source or version unavailable'
}
Write-Check 'chrome runtime opaque-text materialization' $chromeOpaqueTextOk $chromeOpaqueTextDetail

if (Test-Path -LiteralPath $ExtensionManifest) {
  $manifestOk = $false
  $manifestDetail = $ExtensionManifest
  try {
    $manifest = Get-Content -LiteralPath $ExtensionManifest -Raw | ConvertFrom-Json
    $manifestDetail = $manifest.path
    $legacyConcreteHost = Join-Path $chromeRoot "$chromeVersion\extension-host\windows\x64\extension-host.exe"
    $legacyLatestHost = Join-Path $chromeRoot 'latest\extension-host\windows\x64\extension-host.exe'
    $manifestOk = (
      $manifest.name -eq 'com.openai.codexextension' -and
      $manifest.type -eq 'stdio' -and
      @($manifest.allowed_origins) -contains 'chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/' -and
      (Test-Path -LiteralPath $manifest.path) -and
      (@($legacyConcreteHost, $legacyLatestHost) -contains [string]$manifest.path) -and
      $manifest.path -notlike '*\.tmp\bundled-marketplaces\*'
    )
  } catch {
    $manifestDetail = $_.Exception.Message
  }
  Write-Check 'native host manifest content' $manifestOk $manifestDetail
}

$chromeV2Ok = Test-ChromeNativeHostV2Manifest `
  $ChromeNativeHostV2Manifest `
  'hehggadaopoacecdllhhajmbjkdcmajg' `
  (Join-Path $chromeRoot "$chromeVersion\extension-host\windows\x64\extension-host.exe") `
  (Join-Path $chromeRoot "$chromeVersion\scripts\browser-client.mjs") `
  $chromeVersion `
  ([string]$CurrentCodexPackage.Version) `
  (Join-Path ([string]$CurrentCodexPackage.InstallLocation) 'app\resources')
Write-Check 'chrome native host v2 manifest' $chromeV2Ok $ChromeNativeHostV2Manifest

$regOk = $false
$regDetail = ''
try {
  $regValue = (Get-ItemProperty -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension' -Name '(default)' -ErrorAction Stop).'(default)'
  $regDetail = $regValue
  $regOk = ($regValue -eq $ExtensionManifest)
} catch {
  $regDetail = $_.Exception.Message
}
Write-Check 'native host HKCU registry' $regOk $regDetail

$runtimeBin = Get-CurrentCuaRuntimeBin $ConfigPath
$runtimeConfigText = if (Test-Path -LiteralPath $ConfigPath) { Get-Content -LiteralPath $ConfigPath -Raw } else { $null }
Write-Check 'computer-use runtime configured' ($null -ne $runtimeBin) $runtimeBin
if ($runtimeBin) {
  Write-Check 'cua_node manifest exists' (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $runtimeBin) 'manifest.json')) (Join-Path (Split-Path -Parent $runtimeBin) 'manifest.json')
  Write-Check 'node_repl.exe exists' (Test-Path -LiteralPath (Join-Path $runtimeBin 'node_repl.exe')) (Join-Path $runtimeBin 'node_repl.exe')
  Write-Check 'node.exe exists' (Test-Path -LiteralPath (Join-Path $runtimeBin 'node.exe')) (Join-Path $runtimeBin 'node.exe')
  Write-Check 'codex-computer-use.exe exists' (Test-Path -LiteralPath (Join-Path $runtimeBin 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe')) (Join-Path $runtimeBin 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe')
  Write-Check 'Computer Use helper transport exists' (Test-Path -LiteralPath (Join-Path $runtimeBin 'node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js')) (Join-Path $runtimeBin 'node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js')
}

$node = if ($runtimeBin) { Join-Path $runtimeBin 'node.exe' } else { $null }
$chromeClientConcrete = if ($chromeVersion) { Join-Path $chromeRoot "$chromeVersion\scripts\browser-client.mjs" } else { $null }
$chromeModuleLoadOk = $false
if ($chromeOpaqueTextOk -and $node -and $chromeClientConcrete -and (Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $chromeClientConcrete)) {
  $chromeClientUrl = 'file:///' + $chromeClientConcrete.Replace('\', '/')
  & $node '--input-type=module' '-e' 'await import(process.argv[1])' $chromeClientUrl 2>$null | Out-Null
  $chromeModuleLoadOk = ($LASTEXITCODE -eq 0)
}
Write-Check 'chrome browser-client module load' $chromeModuleLoadOk $chromeClientConcrete

$cuaNodeSource = Find-LatestWindowsAppsCuaNodeSource
Write-Check 'packaged cua_node source found' ($null -ne $cuaNodeSource) $cuaNodeSource
Write-Check `
  'packaged cua_node source matches AppxBlockMap' `
  ($CurrentCodexPackage -and (Test-AppxBlockMapTreeComplete ([string]$CurrentCodexPackage.InstallLocation) $cuaNodeSource 'app\resources\cua_node\')) `
  $cuaNodeSource
if ($cuaNodeSource) {
  $cuaRuntimeHash = Get-CuaRuntimeHash $cuaNodeSource
  $electronRuntimeRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\runtimes\cua_node\$cuaRuntimeHash"
  $electronRuntimeBin = Join-Path $electronRuntimeRoot 'bin'
  Write-Check 'Electron cua_node aggregate hash resolved' ($null -ne $cuaRuntimeHash) $cuaRuntimeHash
  Write-Check 'Electron cua_node runtime root exists' (Test-Path -LiteralPath $electronRuntimeRoot) $electronRuntimeRoot
  Write-Check 'Electron cua_node runtime identity' ((Get-CuaRuntimeHash $electronRuntimeRoot) -eq $cuaRuntimeHash) $electronRuntimeRoot
  Write-Check 'Electron Computer Use helper exists' (Test-Path -LiteralPath (Join-Path $electronRuntimeBin 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe')) (Join-Path $electronRuntimeBin 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe')
  Write-Check 'Electron Computer Use transport exists' (Test-Path -LiteralPath (Join-Path $electronRuntimeBin 'node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js')) (Join-Path $electronRuntimeBin 'node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js')
  Write-Check 'node_repl command uses current AppX aggregate' (Test-WindowsPathEqual $runtimeBin $electronRuntimeBin) $electronRuntimeBin
  Write-Check 'NODE_REPL_NODE_PATH uses current AppX aggregate' (Test-WindowsPathEqual (Get-TomlPathValue $runtimeConfigText 'NODE_REPL_NODE_PATH') (Join-Path $electronRuntimeBin 'node.exe')) (Join-Path $electronRuntimeBin 'node.exe')
  Write-Check 'NODE_REPL_NODE_MODULE_DIRS uses current AppX aggregate' (Test-WindowsPathEqual (Get-TomlPathValue $runtimeConfigText 'NODE_REPL_NODE_MODULE_DIRS') (Join-Path $electronRuntimeBin 'node_modules')) (Join-Path $electronRuntimeBin 'node_modules')
  Write-Check 'notify uses current AppX Computer Use helper' (Test-WindowsPathEqual (Get-ConfiguredNotifyExecutable $runtimeConfigText) (Join-Path $electronRuntimeBin 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe')) (Join-Path $electronRuntimeBin 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe')
}

if (Test-Path -LiteralPath $ConfigPath) {
  $config = Get-Content -LiteralPath $ConfigPath -Raw
  foreach ($plugin in @('browser', 'chrome', 'computer-use')) {
    $section = "[plugins.`"$plugin@openai-bundled`"]"
    Write-Check "config enabled section $plugin" (Test-PluginEnabled $config $plugin) $section
  }
}

$CurrentAppxCodexCli = Find-CurrentAppxCodexCli
Write-Check 'current AppX Codex CLI found' ($null -ne $CurrentAppxCodexCli) $CurrentAppxCodexCli
$codexCliMirrorExists = Test-Path -LiteralPath $CodexCliMirror -PathType Leaf
Write-Check 'managed Codex CLI mirror exists' $codexCliMirrorExists $CodexCliMirror

$codexCliMirrorLengthMatches = $false
$codexCliMirrorHashMatches = $false
if (
  $CurrentAppxCodexCli -and
  $codexCliMirrorExists
) {
  try {
    $codexCliMirrorLengthMatches = (
      (Get-Item -LiteralPath $CurrentAppxCodexCli).Length -eq
      (Get-Item -LiteralPath $CodexCliMirror).Length
    )
    $codexCliMirrorHashMatches = (
      (Get-FileHash -LiteralPath $CurrentAppxCodexCli -Algorithm SHA256).Hash -eq
      (Get-FileHash -LiteralPath $CodexCliMirror -Algorithm SHA256).Hash
    )
  } catch {
    $codexCliMirrorLengthMatches = $false
    $codexCliMirrorHashMatches = $false
  }
}
Write-Check 'managed Codex CLI mirror length matches current AppX' $codexCliMirrorLengthMatches $CodexCliMirror
Write-Check 'managed Codex CLI mirror SHA-256 matches current AppX' $codexCliMirrorHashMatches $CodexCliMirror

$codexCliEnvironmentState = Get-CodexCliEnvironmentState $CodexCliMirror
Write-Check 'User-level CODEX_CLI_PATH matches managed Codex CLI mirror' $codexCliEnvironmentState.UserMatches $CodexCliMirror
Write-Check 'Machine-level CODEX_CLI_PATH has no conflicting value' (-not $codexCliEnvironmentState.MachineConflicts) 'Machine scope is empty or matches the managed project mirror'

$officialPluginList = Get-OfficialPluginList
Write-Check 'official plugin list available' ($null -ne $officialPluginList) 'current Codex CLI'
if ($officialPluginList) {
  $expectedPluginVersions = @{
    browser = $browserVersion
    chrome = $chromeVersion
    'computer-use' = $computerUseVersion
  }
  foreach ($plugin in @('browser', 'chrome', 'computer-use')) {
    $pluginId = "$plugin@openai-bundled"
    $expectedVersion = $expectedPluginVersions[$plugin]
    $entry = @($officialPluginList.installed) |
      Where-Object { [string]$_.pluginId -eq $pluginId } |
      Select-Object -First 1
    $ok = (
      $entry -and
      [bool]$entry.installed -and
      [bool]$entry.enabled -and
      $expectedVersion -and
      [string]$entry.version -eq $expectedVersion
    )
    $detail = if ($entry) {
      "version=$($entry.version), expected=$expectedVersion, installed=$($entry.installed), enabled=$($entry.enabled)"
    } else {
      $pluginId
    }
    Write-Check "official installed plugin $plugin" $ok $detail
  }
}

if (-not $Quick) {
foreach ($legacyTaskName in @('Codex Refresh OpenAI Bundled Marketplace', 'CodexBundledPluginRepairWatcher')) {
  $legacyTask = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
  if ($legacyTask) {
    Write-Check "legacy repair task disabled $legacyTaskName" (-not $legacyTask.Settings.Enabled) $legacyTaskName
  } else {
    Write-Check "legacy repair task absent $legacyTaskName" $true $legacyTaskName
  }
}

$healthTaskName = 'CodexDesktopBundledHealthCheck'
$healthTask = Get-ScheduledTask -TaskName $healthTaskName -ErrorAction SilentlyContinue
Write-Check "health check task present $healthTaskName" ($null -ne $healthTask) $healthTaskName
if ($healthTask) {
  Write-Check "health check task enabled $healthTaskName" ($healthTask.Settings.Enabled) $healthTaskName
  try {
    $healthXml = [xml](Export-ScheduledTask -TaskName $healthTaskName)
    $healthCommand = [string]$healthXml.Task.Actions.Exec.Command
    $healthArguments = [string]$healthXml.Task.Actions.Exec.Arguments
    $healthHidden = [string]$healthXml.Task.Settings.Hidden
    $healthMultipleInstances = [string]$healthXml.Task.Settings.MultipleInstancesPolicy
    $healthTriggers = @($healthXml.Task.Triggers.ChildNodes | ForEach-Object { $_.LocalName })
    $healthLogonDelay = [string]$healthXml.Task.Triggers.LogonTrigger.Delay
    $healthRepetitionInterval = [string]$healthXml.Task.Triggers.CalendarTrigger.Repetition.Interval
    $healthRepetitionDuration = [string]$healthXml.Task.Triggers.CalendarTrigger.Repetition.Duration
    $healthDaysInterval = [string]$healthXml.Task.Triggers.CalendarTrigger.ScheduleByDay.DaysInterval
    Write-Check "health check task logon trigger $healthTaskName" ($healthTriggers -contains 'LogonTrigger') ($healthTriggers -join ',')
    Write-Check "health check task calendar fallback $healthTaskName" ($healthTriggers -contains 'CalendarTrigger') ($healthTriggers -join ',')
    Write-Check "health check task logon delay $healthTaskName" ($healthLogonDelay -eq 'PT5S') $healthLogonDelay
    Write-Check "health check task fallback interval $healthTaskName" ($healthRepetitionInterval -eq 'PT12H') $healthRepetitionInterval
    Write-Check "health check task fallback duration $healthTaskName" ($healthRepetitionDuration -eq 'P1D') $healthRepetitionDuration
    Write-Check "health check task daily boundary $healthTaskName" ($healthDaysInterval -eq '1') $healthDaysInterval
    Write-Check "health check task hidden $healthTaskName" ($healthHidden -eq 'true') $healthHidden
    Write-Check "health check task single instance $healthTaskName" ($healthMultipleInstances -eq 'IgnoreNew') $healthMultipleInstances
    Write-Check "health check task command $healthTaskName" ($healthCommand -eq 'wscript.exe') $healthCommand
    Write-Check "health check task script $healthTaskName" ($healthArguments -like '*RunHidden-CodexDesktopBundledHealthCheck.vbs*') $healthArguments
    $healthLauncherPath = Join-Path $RepairRoot 'scripts\RunHidden-CodexDesktopBundledHealthCheck.vbs'
    $healthLauncherText = if (Test-Path -LiteralPath $healthLauncherPath -PathType Leaf) {
      Get-Content -LiteralPath $healthLauncherPath -Raw
    } else {
      ''
    }
    Write-Check "health check one-shot launcher $healthTaskName" ($healthLauncherText -match 'Invoke-CodexDesktopQuickRepair\.ps1.*-Route Auto') $healthLauncherPath
  } catch {
    Write-Check "health check task export $healthTaskName" $false $_.Exception.Message
  }
}

$postUpdateVbs = Join-Path $RepairRoot 'scripts\RunHidden-CodexDesktopBundledPostUpdateRepair.vbs'
$postUpdateLauncherText = if (Test-Path -LiteralPath $postUpdateVbs -PathType Leaf) {
  Get-Content -LiteralPath $postUpdateVbs -Raw
} else {
  ''
}
Write-Check 'post-update quick launcher exists' ($postUpdateLauncherText -match 'Invoke-CodexDesktopQuickRepair\.ps1.*-Route Auto') $postUpdateVbs

$postUpdateTaskName = 'CodexDesktopBundledPostUpdateRepair'
$postUpdateTask = Get-ScheduledTask -TaskName $postUpdateTaskName -ErrorAction SilentlyContinue
Write-Check "post-update task present $postUpdateTaskName" ($null -ne $postUpdateTask) $postUpdateTaskName
if ($postUpdateTask) {
  Write-Check "post-update task enabled $postUpdateTaskName" ($postUpdateTask.Settings.Enabled) $postUpdateTaskName
  try {
    $postUpdateXml = [xml](Export-ScheduledTask -TaskName $postUpdateTaskName)
    $postUpdateCommand = [string]$postUpdateXml.Task.Actions.Exec.Command
    $postUpdateArguments = [string]$postUpdateXml.Task.Actions.Exec.Arguments
    $postUpdateHidden = [string]$postUpdateXml.Task.Settings.Hidden
    $postUpdateMultipleInstances = [string]$postUpdateXml.Task.Settings.MultipleInstancesPolicy
    $postUpdateTriggers = @($postUpdateXml.Task.Triggers.ChildNodes | ForEach-Object { $_.LocalName })
    $postUpdateSubscription = [string]$postUpdateXml.Task.Triggers.EventTrigger.Subscription
    $postUpdateEventDelay = [string]$postUpdateXml.Task.Triggers.EventTrigger.Delay
    $postUpdateLogonDelay = [string]$postUpdateXml.Task.Triggers.LogonTrigger.Delay

    Write-Check "post-update task event trigger $postUpdateTaskName" ($postUpdateTriggers -contains 'EventTrigger') ($postUpdateTriggers -join ',')
    Write-Check "post-update task logon fallback $postUpdateTaskName" ($postUpdateTriggers -contains 'LogonTrigger') ($postUpdateTriggers -join ',')
    Write-Check "post-update task event log $postUpdateTaskName" ($postUpdateSubscription -like '*Microsoft-Windows-AppXDeploymentServer/Operational*') $postUpdateSubscription
    Write-Check "post-update task event provider $postUpdateTaskName" ($postUpdateSubscription -like '*Microsoft-Windows-AppXDeployment-Server*') 'Microsoft-Windows-AppXDeployment-Server'
    Write-Check "post-update task event id $postUpdateTaskName" ($postUpdateSubscription -like '*EventID=400*') 'EventID=400'
    Write-Check "post-update task Register-only filter $postUpdateTaskName" ($postUpdateSubscription -like '*DeploymentOperation*' -and $postUpdateSubscription -like "*='6'*") 'DeploymentOperation=6'
    Write-Check "post-update task ChatGPT package filter $postUpdateTaskName" ($postUpdateSubscription -like '*PackageDisplayName*' -and $postUpdateSubscription -like '*ChatGPT*') 'PackageDisplayName=ChatGPT'
    Write-Check "post-update task event delay $postUpdateTaskName" ($postUpdateEventDelay -eq 'PT5S') $postUpdateEventDelay
    Write-Check "post-update task logon delay $postUpdateTaskName" ($postUpdateLogonDelay -eq 'PT30S') $postUpdateLogonDelay
    Write-Check "post-update task hidden $postUpdateTaskName" ($postUpdateHidden -eq 'true') $postUpdateHidden
    Write-Check "post-update task single instance $postUpdateTaskName" ($postUpdateMultipleInstances -eq 'IgnoreNew') $postUpdateMultipleInstances
    Write-Check "post-update task command $postUpdateTaskName" ($postUpdateCommand -eq 'wscript.exe') $postUpdateCommand
    Write-Check "post-update task script $postUpdateTaskName" ($postUpdateArguments -like '*RunHidden-CodexDesktopBundledPostUpdateRepair.vbs*') $postUpdateArguments
  } catch {
    Write-Check "post-update task export $postUpdateTaskName" $false $_.Exception.Message
  }
}

$chromeLatest = Join-Path $chromeRoot 'latest'
if ($node -and (Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $chromeLatest)) {
  foreach ($scriptName in @('chrome-is-running.js', 'installed-browsers.js', 'check-extension-installed.js', 'check-native-host-manifest.js')) {
    $scriptPath = Join-Path $chromeLatest "scripts\$scriptName"
    if (Test-Path -LiteralPath $scriptPath) {
      & $node $scriptPath '--json' | Out-Null
      Write-Check "chrome script $scriptName" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
    } else {
      Write-Check "chrome script $scriptName" $false $scriptPath
    }
  }
}
}

if ($script:Failed) {
  Write-Host ''
  Write-Host 'Verification failed. Use the single matching quick-repair route; do not restart software unless the selected route reports a file lock.'
  exit 1
}

Write-Host ''
Write-Host 'All local Codex Desktop bundled plugin checks passed.'
