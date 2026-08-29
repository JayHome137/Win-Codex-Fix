param(
  [switch]$CliMirrorOnly,
  [switch]$RuntimeOnly,
  [switch]$BrowserDiscoveryOnly,
  [switch]$BrowserCacheOnly,
  [switch]$BrowserNativeHostOnly,
  [switch]$TmpRuntimeMarketplaceOnly,
  [switch]$AutomaticPostUpdate,
  [string]$ExpectedPackageFullName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepairRoot = Split-Path -Parent $PSScriptRoot

$ChromeOpaqueTextLibrary = Join-Path $PSScriptRoot 'ChromeOpaqueTextMaterialization.ps1'
if (-not (Test-Path -LiteralPath $ChromeOpaqueTextLibrary -PathType Leaf)) {
  throw "Missing Chrome opaque-text materialization library: $ChromeOpaqueTextLibrary"
}
. $ChromeOpaqueTextLibrary

$BrowserNativeHostLibrary = Join-Path $PSScriptRoot 'BrowserNativeHost.ps1'
if (-not (Test-Path -LiteralPath $BrowserNativeHostLibrary -PathType Leaf)) {
  throw "Missing Browser native-host library: $BrowserNativeHostLibrary"
}
. $BrowserNativeHostLibrary

$selectedTargetedModes = @(
  @($CliMirrorOnly, $RuntimeOnly, $BrowserDiscoveryOnly, $BrowserCacheOnly, $BrowserNativeHostOnly, $TmpRuntimeMarketplaceOnly) | Where-Object { $_ }
)
if ($selectedTargetedModes.Count -gt 1) {
  throw 'Choose only one targeted repair mode: -CliMirrorOnly, -RuntimeOnly, -BrowserDiscoveryOnly, -BrowserCacheOnly, -BrowserNativeHostOnly, or -TmpRuntimeMarketplaceOnly.'
}
if ($AutomaticPostUpdate -and $selectedTargetedModes.Count -gt 0) {
  throw '-AutomaticPostUpdate cannot be combined with a targeted repair mode.'
}
if ($ExpectedPackageFullName -and -not $AutomaticPostUpdate) {
  throw '-ExpectedPackageFullName is supported only with -AutomaticPostUpdate.'
}

function Write-Step([string]$Message) {
  Write-Host "[codex-repair] $Message"
}

function New-Utf8NoBomFile([string]$Path, [string]$Text) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function New-Utf8NoBomFileAtomically([string]$Path, [string]$Text) {
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

function Find-BundledSource {
  $candidateRoots = New-Object System.Collections.Generic.List[string]

  $marketplaceCandidate = Join-Path $env:USERPROFILE '.codex\marketplaces\openai-bundled'
  $candidateRoots.Add($marketplaceCandidate)

  $configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
  if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw
    foreach ($match in [regex]::Matches($config, "source\s*=\s*'([^']*openai-bundled)'|source\s*=\s*`"([^`"]*openai-bundled)`"")) {
      $raw = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
      $candidateRoots.Add(($raw -replace '^\\\\\?\\', '')) | Out-Null
    }
  }

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

  $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
  $packages = Get-ChildItem -LiteralPath $windowsApps -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'OpenAI.Codex_*_x64__2p2nqsd0c76g0' } |
    Sort-Object LastWriteTime -Descending

  foreach ($package in $packages) {
    $candidate = Join-Path $package.FullName 'app\resources\plugins\openai-bundled'
    if (
      (Test-Path -LiteralPath (Join-Path $candidate '.agents\plugins\marketplace.json')) -and
      (Test-Path -LiteralPath (Join-Path $candidate 'plugins\chrome\.codex-plugin\plugin.json')) -and
      (Test-Path -LiteralPath (Join-Path $candidate 'plugins\browser\.codex-plugin\plugin.json')) -and
      (Test-Path -LiteralPath (Join-Path $candidate 'plugins\computer-use\.codex-plugin\plugin.json'))
    ) {
      return $candidate
    }
  }

  throw 'Could not find a complete Codex openai-bundled source under WindowsApps.'
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

function Find-CurrentCodexCli {
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

function Test-CodexDesktopRunning {
  $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  $candidates = @(Get-Process -Name 'ChatGPT', 'codex' -ErrorAction SilentlyContinue)

  if (-not $package) {
    return @($candidates | Where-Object { $_.ProcessName -ieq 'ChatGPT' }).Count -gt 0
  }

  $installPrefix = ([string]$package.InstallLocation).TrimEnd('\') + '\'
  return @(
    $candidates | Where-Object {
      try {
        $path = [string]$_.Path
        $path -and $path.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)
      } catch {
        $false
      }
    }
  ).Count -gt 0
}

function Find-CuaNodeSource {
  try {
    $registeredPackage = Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop |
      Sort-Object Version -Descending |
      Select-Object -First 1
    if ($registeredPackage) {
      $candidate = Join-Path $registeredPackage.InstallLocation 'app\resources\cua_node'
      if (
        (Test-Path -LiteralPath (Join-Path $candidate 'bin\node_repl.exe')) -and
        (Test-Path -LiteralPath (Join-Path $candidate 'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'))
      ) {
        return $candidate
      }
    }
  } catch {
    Write-Step "Could not read the registered Codex AppX package: $($_.Exception.Message)"
  }

  $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
  $packages = Get-ChildItem -LiteralPath $windowsApps -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'OpenAI.Codex_*_x64__2p2nqsd0c76g0' } |
    Sort-Object LastWriteTime -Descending

  foreach ($package in $packages) {
    $candidate = Join-Path $package.FullName 'app\resources\cua_node'
    if (
      (Test-Path -LiteralPath (Join-Path $candidate 'bin\node_repl.exe')) -and
      (Test-Path -LiteralPath (Join-Path $candidate 'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'))
    ) {
      return $candidate
    }
  }

  $configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
  if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw
    $match = [regex]::Match($config, "command\s*=\s*'([^']*\\cua_node\\[^']*\\bin\\node_repl\.exe)'")
    if (-not $match.Success) {
      $match = [regex]::Match($config, 'command\s*=\s*"([^"]*\\cua_node\\[^"]*\\bin\\node_repl\.exe)"')
    }
    if ($match.Success) {
      $runtimeBin = Split-Path -Parent $match.Groups[1].Value
      $runtimeRoot = Split-Path -Parent $runtimeBin
      if (
        (Test-Path -LiteralPath (Join-Path $runtimeRoot 'bin\node_repl.exe')) -and
        (Test-Path -LiteralPath (Join-Path $runtimeRoot 'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'))
      ) {
        return $runtimeRoot
      }
    }
  }

  return $null
}

function Get-PluginVersion([string]$PluginDir) {
  $pluginJson = Join-Path $PluginDir '.codex-plugin\plugin.json'
  if (-not (Test-Path -LiteralPath $pluginJson)) {
    throw "Missing plugin.json: $pluginJson"
  }

  $json = Get-Content -LiteralPath $pluginJson -Raw | ConvertFrom-Json
  if (-not $json.version) {
    throw "Missing version in plugin.json: $pluginJson"
  }

  return [string]$json.version
}

function Copy-TreeContentOnly([string]$SourceDir, [string]$DestDir) {
  if (-not (Test-Path -LiteralPath $SourceDir)) {
    throw "Source missing: $SourceDir"
  }

  if (Test-Path -LiteralPath $DestDir) {
    Remove-Item -LiteralPath $DestDir -Recurse -Force
  }

  New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
  $sourceRoot = (Get-Item -LiteralPath $SourceDir).FullName.TrimEnd('\')

  Get-ChildItem -LiteralPath $SourceDir -Force -Recurse -Directory | ForEach-Object {
    $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\')
    New-Item -ItemType Directory -Force -Path (Join-Path $DestDir $relative) | Out-Null
  }

  Get-ChildItem -LiteralPath $SourceDir -Force -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\')
    $target = Join-Path $DestDir $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    [System.IO.File]::WriteAllBytes($target, $bytes)
  }
}

function Copy-FileContentOnly([string]$SourceFile, [string]$DestFile) {
  if (-not (Test-Path -LiteralPath $SourceFile)) {
    throw "Source file missing: $SourceFile"
  }

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DestFile) | Out-Null
  $bytes = [System.IO.File]::ReadAllBytes($SourceFile)
  [System.IO.File]::WriteAllBytes($DestFile, $bytes)
}

function Assert-CurrentAppxBrowserCacheComplete(
  [string]$BrowserSource,
  [string]$BrowserRoot,
  [string]$BrowserVersion,
  [hashtable]$RuntimeTextExpectations
) {
  $browserVersionDir = Join-Path $BrowserRoot $BrowserVersion
  $comparison = Get-BrowserCacheComparison $BrowserSource $browserVersionDir $RuntimeTextExpectations
  if ($comparison.State -ne 'browser-cache-complete') {
    throw "Browser plugin cache is not complete after applying validated runtime-text expectations: $browserVersionDir ($($comparison.State))"
  }
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

function Get-BrowserCacheComparison(
  [string]$SourceDir,
  [string]$ConcreteDir,
  [hashtable]$RuntimeTextExpectations
) {
  $source = Get-BrowserCacheTreeInventory $SourceDir
  if ((-not $source.Exists) -or (-not $source.IsDirectory) -or $source.IsReparsePoint -or @($source.ReparsePaths).Count -gt 0) {
    throw "Current AppX Browser source is not a plain complete directory: $SourceDir"
  }

  $concrete = Get-BrowserCacheTreeInventory $ConcreteDir
  if (-not $concrete.Exists) {
    return [pscustomobject]@{
      State = 'browser-cache-missing-only'
      SourceFileCount = @($source.Files.Keys).Count
      ConcreteFileCount = 0
      MissingFiles = @($source.Files.Keys | Sort-Object)
      MissingDirectories = @($source.Directories.Keys | Sort-Object)
      ExtraFiles = @()
      Conflicts = @()
      RuntimeTextFiles = @()
      ConcreteExists = $false
    }
  }

  if ((-not $concrete.IsDirectory) -or $concrete.IsReparsePoint -or @($concrete.ReparsePaths).Count -gt 0) {
    return [pscustomobject]@{
      State = 'browser-cache-rebuild-required'
      SourceFileCount = @($source.Files.Keys).Count
      ConcreteFileCount = @($concrete.Files.Keys).Count
      MissingFiles = @()
      MissingDirectories = @()
      ExtraFiles = @()
      Conflicts = @('concrete directory is not a plain directory or contains a reparse point')
      RuntimeTextFiles = @()
      ConcreteExists = $true
    }
  }

  $missingFiles = New-Object System.Collections.Generic.List[string]
  $missingDirectories = New-Object System.Collections.Generic.List[string]
  $extraFiles = New-Object System.Collections.Generic.List[string]
  $conflicts = New-Object System.Collections.Generic.List[string]
  $runtimeTextFiles = New-Object System.Collections.Generic.List[string]

  foreach ($relative in @($source.Files.Keys | Sort-Object)) {
    if ($concrete.Directories.ContainsKey($relative)) {
      $conflicts.Add("$relative is a directory but AppX expects a file")
      continue
    }

    if (-not $concrete.Files.ContainsKey($relative)) {
      $missingFiles.Add($relative)
      continue
    }

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
        $conflicts.Add("$relative runtime-text expectation does not match the current AppX source")
      } elseif (
        ([int64]$actual.Length -eq [int64]$runtimeExpectation.Length) -and
        ([string]$actual.SHA256 -eq [string]$runtimeExpectation.ExpectedHash)
      ) {
        continue
      } elseif (
        ([int64]$actual.Length -eq [int64]$expected.Length) -and
        ([string]$actual.SHA256 -eq [string]$expected.SHA256)
      ) {
        $runtimeTextFiles.Add($relative)
      } else {
        $conflicts.Add("$relative length/SHA-256 differs from both AppX and validated runtime text")
      }
    } elseif (($expected.Length -ne $actual.Length) -or ($expected.SHA256 -ne $actual.SHA256)) {
      $conflicts.Add("$relative length/SHA-256 differs from current AppX")
    }
  }

  foreach ($relative in @($source.Directories.Keys | Sort-Object)) {
    if ($concrete.Files.ContainsKey($relative)) {
      $conflicts.Add("$relative is a file but AppX expects a directory")
    } elseif (-not $concrete.Directories.ContainsKey($relative)) {
      $missingDirectories.Add($relative)
    }
  }

  foreach ($relative in @($concrete.Files.Keys | Sort-Object)) {
    if (-not $source.Files.ContainsKey($relative)) {
      if ($source.Directories.ContainsKey($relative)) {
        $conflicts.Add("$relative is a file but AppX expects a directory")
      } else {
        $extraFiles.Add($relative)
      }
    }
  }

  $state = if (($extraFiles.Count -gt 0) -or ($conflicts.Count -gt 0)) {
    'browser-cache-rebuild-required'
  } elseif ($missingFiles.Count -gt 0 -and $runtimeTextFiles.Count -gt 0) {
    'browser-cache-repairable'
  } elseif ($missingFiles.Count -gt 0) {
    'browser-cache-missing-only'
  } elseif ($runtimeTextFiles.Count -gt 0) {
    'browser-cache-runtime-text-only'
  } else {
    'browser-cache-complete'
  }

  return [pscustomobject]@{
    State = $state
    SourceFileCount = @($source.Files.Keys).Count
    ConcreteFileCount = @($concrete.Files.Keys).Count
    MissingFiles = @($missingFiles | Sort-Object)
    MissingDirectories = @($missingDirectories | Sort-Object)
    ExtraFiles = @($extraFiles | Sort-Object)
    Conflicts = @($conflicts | Sort-Object -Unique)
    RuntimeTextFiles = @($runtimeTextFiles | Sort-Object)
    ConcreteExists = $true
  }
}

function Assert-BrowserCacheFileMatches([string]$ExpectedFile, [string]$ActualFile) {
  $expected = Get-Item -LiteralPath $ExpectedFile -ErrorAction Stop
  $actual = Get-Item -LiteralPath $ActualFile -ErrorAction Stop
  if ($expected.Length -ne $actual.Length) {
    throw "Staged Browser file length differs: $ActualFile"
  }

  $expectedHash = (Get-FileHash -LiteralPath $ExpectedFile -Algorithm SHA256).Hash
  $actualHash = (Get-FileHash -LiteralPath $ActualFile -Algorithm SHA256).Hash
  if ($expectedHash -ne $actualHash) {
    throw "Staged Browser file SHA-256 differs: $ActualFile"
  }
}

function Assert-BrowserDiscoveryJunctionReplaceable([string]$Name, [string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item) {
    return
  }

  if (
    (-not $item.PSIsContainer) -or
    (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -or
    ([string]$item.LinkType -ne 'Junction')
  ) {
    throw "Refusing BrowserCacheOnly because $Name is not a replaceable junction: $Path"
  }
}

function Test-BrowserDiscoveryJunction([string]$Path, [string]$ExpectedTarget) {
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

function Set-BrowserDiscoveryJunction([string]$LinkPath, [string]$TargetPath) {
  Assert-BrowserDiscoveryJunctionReplaceable 'Browser discovery path' $LinkPath
  if (Test-BrowserDiscoveryJunction $LinkPath $TargetPath) {
    return $false
  }

  $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
  if ($existing) {
    cmd /c "rmdir `"$LinkPath`"" | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue)) {
      throw "Failed to remove Browser discovery junction: $LinkPath"
    }
  }

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LinkPath) | Out-Null
  cmd /c "mklink /J `"$LinkPath`" `"$TargetPath`"" | Out-Null
  if (-not (Test-BrowserDiscoveryJunction $LinkPath $TargetPath)) {
    throw "Failed to create Browser discovery junction: $LinkPath -> $TargetPath"
  }

  return $true
}

function Get-BrowserDiscoveryLinkSnapshot([string]$Path) {
  Assert-BrowserDiscoveryJunctionReplaceable 'Browser discovery path' $Path
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item) {
    return [pscustomobject]@{ Path = $Path; Exists = $false; Target = $null }
  }

  return [pscustomobject]@{
    Path = $Path
    Exists = $true
    Target = [string](@($item.Target) | Select-Object -First 1)
  }
}

function Restore-BrowserDiscoveryLinkSnapshot($Snapshot) {
  Assert-BrowserDiscoveryJunctionReplaceable 'Browser discovery path' $Snapshot.Path
  $current = Get-Item -LiteralPath $Snapshot.Path -Force -ErrorAction SilentlyContinue
  if ($current) {
    cmd /c "rmdir `"$($Snapshot.Path)`"" | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Get-Item -LiteralPath $Snapshot.Path -Force -ErrorAction SilentlyContinue)) {
      throw "Failed to remove Browser discovery junction during rollback: $($Snapshot.Path)"
    }
  }

  if ($Snapshot.Exists) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Snapshot.Path) | Out-Null
    cmd /c "mklink /J `"$($Snapshot.Path)`" `"$($Snapshot.Target)`"" | Out-Null
    if (-not (Test-BrowserDiscoveryJunction $Snapshot.Path $Snapshot.Target)) {
      throw "Failed to restore Browser discovery junction: $($Snapshot.Path)"
    }
  }
}

function Remove-EmptyBrowserCacheDirectories([string[]]$Directories) {
  foreach ($directory in @($Directories | Sort-Object { $_.Length } -Descending)) {
    $item = Get-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
    if ($item -and $item.PSIsContainer -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
      if (@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -eq 0) {
        Remove-Item -LiteralPath $directory -Force -ErrorAction Stop
      }
    }
  }
}

function Get-BrowserCacheFileFingerprint([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (
    (-not $item) -or
    $item.PSIsContainer -or
    (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  ) {
    return $null
  }

  return [pscustomobject]@{
    Path = $item.FullName
    Length = $item.Length
    SHA256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    LastWriteTimeUtcTicks = $item.LastWriteTimeUtc.Ticks
  }
}

function Test-BrowserCacheFileFingerprint($Expected) {
  $actual = Get-BrowserCacheFileFingerprint $Expected.Path
  return (
    $actual -and
    $actual.Length -eq $Expected.Length -and
    $actual.SHA256 -eq $Expected.SHA256 -and
    $actual.LastWriteTimeUtcTicks -eq $Expected.LastWriteTimeUtcTicks
  )
}

function Remove-BrowserCacheFileIfOwned($Expected) {
  $actual = Get-BrowserCacheFileFingerprint $Expected.Path
  if (-not $actual) {
    return [pscustomobject]@{ Removed = $false; Confirmed = $true }
  }

  if (-not (Test-BrowserCacheFileFingerprint $Expected)) {
    return [pscustomobject]@{ Removed = $false; Confirmed = $false }
  }

  Remove-Item -LiteralPath $Expected.Path -Force -ErrorAction Stop
  return [pscustomobject]@{ Removed = $true; Confirmed = $true }
}

function Test-BrowserCacheOnlyProcessGuardFailure($ErrorRecord) {
  return $ErrorRecord.Exception.Message -like 'BrowserCacheOnly process guard blocked*'
}

function Assert-FullRepairBrowserCacheEligible(
  [string]$BrowserSource,
  [string]$BrowserRoot,
  [string]$BrowserVersion,
  [hashtable]$RuntimeTextExpectations
) {
  $comparison = Get-BrowserCacheComparison `
    $BrowserSource `
    (Join-Path $BrowserRoot $BrowserVersion) `
    $RuntimeTextExpectations
  if ($comparison.State -eq 'browser-cache-complete') {
    return
  }

  if ($comparison.State -in @('browser-cache-missing-only', 'browser-cache-runtime-text-only', 'browser-cache-repairable')) {
    throw "$($comparison.State): Full repair will not modify the Browser concrete directory. Exit Codex Desktop and run -BrowserCacheOnly."
  }

  $detail = @(
    @($comparison.ExtraFiles | ForEach-Object { "extra=$_" }) +
    @($comparison.Conflicts | ForEach-Object { "conflict=$_" })
  ) -join '; '
  throw "browser-cache-rebuild-required: Full repair will not replace the Browser concrete directory automatically. $detail"
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

function Assert-AutomaticPostUpdateJunction([string]$Name, [string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item) {
    return
  }

  if (
    (-not $item.PSIsContainer) -or
    (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) -or
    ([string]$item.LinkType -ne 'Junction')
  ) {
    throw "automatic-post-update-manual-required: $Name is not a replaceable Junction: $Path"
  }
}

function Assert-AutomaticPostUpdateRegularFile([string]$Name, [string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item) {
    return
  }

  if ($item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw "automatic-post-update-manual-required: $Name is not a regular file: $Path"
  }
}

function Assert-AutomaticPostUpdateCacheState(
  [string]$Name,
  [string]$Source,
  [string]$Concrete,
  [switch]$RequireComplete,
  [hashtable]$RuntimeTextExpectations
) {
  $comparison = Get-BrowserCacheComparison $Source $Concrete $RuntimeTextExpectations
  $allowed = if ($RequireComplete) {
    $comparison.State -eq 'browser-cache-complete'
  } else {
    $comparison.State -in @('browser-cache-complete', 'browser-cache-missing-only')
  }

  if (-not $allowed) {
    throw "automatic-post-update-manual-required: $Name concrete contains an extra, hash, length, type, or reparse conflict: $Concrete"
  }
}

function Assert-AutomaticPostUpdatePreflight(
  $Package,
  [string]$BundledSource,
  [string]$PluginCacheRoot,
  [string]$CodexHome,
  [string]$CuaNodeSource,
  [string]$RuntimeBaseRoot,
  [string]$PersistentMarketplaceRoot,
  [string]$ConfigPath,
  [string]$GlobalStatePath,
  [string]$ExtensionManifest,
  [string]$ChromeNativeHostV2Manifest
) {
  if (-not $Package -or [string]::IsNullOrWhiteSpace([string]$Package.InstallLocation)) {
    throw 'automatic-post-update-manual-required: the current registered AppX package is unavailable.'
  }
  if (-not (Test-AppxBlockMapTreeComplete ([string]$Package.InstallLocation) $BundledSource 'app\resources\plugins\openai-bundled\')) {
    throw 'automatic-post-update-manual-required: the current AppX bundled source does not match AppxBlockMap.'
  }

  $linkNames = @{
    browser = @('latest', '.codex-plugin')
    chrome = @('latest', '.codex-plugin', 'assets', 'docs', 'extension-host', 'scripts', 'skills')
    'computer-use' = @('latest', '.codex-plugin', 'assets', 'scripts', 'skills')
  }
  $browserSource = Join-Path $BundledSource 'plugins\browser'
  $chromeSource = Join-Path $BundledSource 'plugins\chrome'
  $browserVersion = Get-PluginVersion $browserSource
  $chromeVersion = Get-PluginVersion $chromeSource
  $browserOpaqueConsensus = Get-BrowserOpaqueTextConsensusPlan `
    $browserSource `
    (Join-Path $PluginCacheRoot 'chrome') `
    $chromeVersion
  if ($browserOpaqueConsensus.State -eq 'manual-required') {
    throw "automatic-post-update-manual-required: $($browserOpaqueConsensus.ErrorSummary)"
  }
  $browserRuntimeTextExpectations = ConvertTo-BrowserOpaqueTextExpectationMap $browserOpaqueConsensus.Expectations
  foreach ($name in @('browser', 'chrome', 'computer-use')) {
    $source = Join-Path $BundledSource "plugins\$name"
    $version = Get-PluginVersion $source
    $root = Join-Path $PluginCacheRoot $name
    $concrete = Join-Path $root $version
    $runtimeTextExpectations = if ($name -eq 'browser') { $browserRuntimeTextExpectations } else { $null }
    Assert-AutomaticPostUpdateCacheState `
      $name `
      $source `
      $concrete `
      -RequireComplete:($name -eq 'browser') `
      -RuntimeTextExpectations $runtimeTextExpectations
    foreach ($linkName in $linkNames[$name]) {
      Assert-AutomaticPostUpdateJunction "$name $linkName" (Join-Path $root $linkName)
    }
  }

  $persistentItem = Get-Item -LiteralPath $PersistentMarketplaceRoot -Force -ErrorAction SilentlyContinue
  if (
    $persistentItem -and
    ((-not $persistentItem.PSIsContainer) -or (($persistentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))
  ) {
    throw "automatic-post-update-manual-required: the persistent marketplace mirror is not a plain directory: $PersistentMarketplaceRoot"
  }

  $marketplaceLink = Join-Path $CodexHome 'marketplaces\openai-bundled'
  Assert-AutomaticPostUpdateJunction 'openai-bundled marketplace' $marketplaceLink

  $tmpRuntimeMarketplace = Join-Path $CodexHome '.tmp\bundled-marketplaces\openai-bundled'
  $tmpItem = Get-Item -LiteralPath $tmpRuntimeMarketplace -Force -ErrorAction SilentlyContinue
  if ($tmpItem) {
    if (-not $tmpItem.PSIsContainer) {
      throw "automatic-post-update-manual-required: the host-owned runtime marketplace is not a directory: $tmpRuntimeMarketplace"
    }
    if (($tmpItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      $target = @($tmpItem.Target) | Select-Object -First 1
      if ([string]$tmpItem.LinkType -ne 'Junction' -or -not $target -or $target.TrimEnd('\') -ine $PersistentMarketplaceRoot.TrimEnd('\')) {
        throw "automatic-post-update-manual-required: the host-owned runtime marketplace has an unknown reparse target: $tmpRuntimeMarketplace"
      }
    }
  }

  foreach ($entry in @(
    @{ Name = 'config'; Path = $ConfigPath },
    @{ Name = 'global state'; Path = $GlobalStatePath },
    @{ Name = 'legacy native-host manifest'; Path = $ExtensionManifest },
    @{ Name = 'v2 native-host manifest'; Path = $ChromeNativeHostV2Manifest }
  )) {
    Assert-AutomaticPostUpdateRegularFile $entry.Name $entry.Path
  }

  if (
    -not (Test-AppxBlockMapTreeComplete ([string]$Package.InstallLocation) $CuaNodeSource 'app\resources\cua_node\') -or
    -not (Test-CuaRuntime (Join-Path $CuaNodeSource 'bin'))
  ) {
    throw 'automatic-post-update-manual-required: the current AppX cua_node source does not match AppxBlockMap.'
  }

  $runtimeHash = Get-CuaRuntimeHash $CuaNodeSource
  $runtimeRoot = Join-Path $RuntimeBaseRoot $runtimeHash
  if (Test-Path -LiteralPath $runtimeRoot) {
    if (-not ((Test-CuaRuntime (Join-Path $runtimeRoot 'bin')) -and (Test-CuaRuntimeIdentity $runtimeRoot $CuaNodeSource))) {
      Assert-AutomaticPostUpdateCacheState 'cua_node runtime' $CuaNodeSource $runtimeRoot
    }
  }
}

function Get-BrowserCacheOnlyBlockers(
  [string]$BrowserRoot,
  [string]$CodexCliMirror,
  [scriptblock]$PackageProvider,
  [scriptblock]$ProcessProvider
) {
  $blockers = New-Object System.Collections.Generic.List[object]
  $registeredLookupFailed = $false
  $package = $null
  try {
    $packages = if ($PackageProvider) {
      @(& $PackageProvider)
    } else {
      @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
    }
    $package = @($packages | Sort-Object Version -Descending | Select-Object -First 1)[0]
  } catch {
    $registeredLookupFailed = $true
  }

  $appxPrefix = if ($package -and [string]$package.InstallLocation) {
    ([string]$package.InstallLocation).TrimEnd('\') + '\'
  } else {
    $null
  }
  $browserPrefix = $BrowserRoot.TrimEnd('\') + '\'

  try {
    $processes = if ($ProcessProvider) {
      @(& $ProcessProvider)
    } else {
      @(Get-CimInstance Win32_Process -ErrorAction Stop)
    }
  } catch {
    $blockers.Add([pscustomobject]@{
        ProcessId = $null
        Name = 'process-inventory'
        Reason = 'process inventory unavailable (fail closed)'
      })
    return @($blockers.ToArray())
  }

  if ($registeredLookupFailed) {
    $blockers.Add([pscustomobject]@{
        ProcessId = $null
        Name = 'Get-AppxPackage'
        Reason = 'registered AppX lookup failed (fail closed)'
      })
  }

  foreach ($process in $processes) {
    $name = [string]$process.Name
    $path = [string]$process.ExecutablePath
    $commandLine = [string]$process.CommandLine
    $reasons = New-Object System.Collections.Generic.List[string]

    if ($name -ieq 'codex.exe') {
      if (-not $path) {
        $reasons.Add('codex executable path unavailable (fail closed)')
      } elseif ($CodexCliMirror -and [string]::Equals($path, $CodexCliMirror, [System.StringComparison]::OrdinalIgnoreCase)) {
        $reasons.Add('managed Codex app-server or CLI mirror')
      } elseif ($appxPrefix -and $path.StartsWith($appxPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $reasons.Add('registered Codex AppX process')
      } else {
        $reasons.Add('unrecognized codex executable (fail closed)')
      }
    }

    if (($name -iin @('node.exe', 'node_repl.exe')) -and -not $path) {
      $reasons.Add('potential Browser host executable path unavailable (fail closed)')
    }

    if (
      ($path -and $path.StartsWith($browserPrefix, [System.StringComparison]::OrdinalIgnoreCase)) -or
      ($commandLine -and
       ($name -iin @('node.exe', 'node_repl.exe', 'codex.exe')) -and
       $commandLine -match '(?i)browser-client\.mjs')
    ) {
      $reasons.Add('Browser host')
    }

    if ($reasons.Count -gt 0) {
      $blockers.Add([pscustomobject]@{
          ProcessId = $process.ProcessId
          Name = $name
          Reason = ($reasons -join '; ')
        })
    }
  }

  return @($blockers.ToArray())
}

function Get-AutomaticPostUpdateBlockers(
  [string]$PluginCacheRoot,
  [string]$CodexCliMirror,
  [string]$RuntimeBaseRoot,
  [scriptblock]$PackageProvider,
  [scriptblock]$ProcessProvider
) {
  $blockers = New-Object System.Collections.Generic.List[object]
  $browserRoot = Join-Path $PluginCacheRoot 'browser'
  foreach ($blocker in @(Get-BrowserCacheOnlyBlockers $browserRoot $CodexCliMirror $PackageProvider $ProcessProvider)) {
    $blockers.Add($blocker)
  }

  try {
    $processes = if ($ProcessProvider) {
      @(& $ProcessProvider)
    } else {
      @(Get-CimInstance Win32_Process -ErrorAction Stop)
    }
  } catch {
    if (-not @($blockers | Where-Object { [string]$_.Name -eq 'process-inventory' }).Count) {
      $blockers.Add([pscustomobject]@{
          ProcessId = $null
          Name = 'process-inventory'
          Reason = 'process inventory unavailable (fail closed)'
        })
    }
    return @($blockers.ToArray())
  }

  $pluginPrefix = $PluginCacheRoot.TrimEnd('\') + '\'
  $chromePrefix = (Join-Path $PluginCacheRoot 'chrome').TrimEnd('\') + '\'
  $runtimePrefix = $RuntimeBaseRoot.TrimEnd('\') + '\'
  $seen = @{}
  foreach ($blocker in $blockers.ToArray()) {
    $seen[('{0}|{1}' -f $blocker.ProcessId, $blocker.Name)] = $true
  }

  foreach ($process in $processes) {
    $name = [string]$process.Name
    $path = [string]$process.ExecutablePath
    $commandLine = [string]$process.CommandLine
    $reason = $null

    if ($name -ieq 'extension-host.exe') {
      if (-not $path) {
        $reason = 'Chrome extension-host path unavailable (fail closed)'
      } elseif ($path.StartsWith($chromePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $reason = 'bundled Chrome extension host'
      }
    } elseif ($name -iin @('node.exe', 'node_repl.exe', 'codex-computer-use.exe')) {
      if (-not $path) {
        $reason = 'bundled runtime path unavailable (fail closed)'
      } elseif (
        $path.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($pluginPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        ($commandLine -and $commandLine -match '(?i)browser-client\.mjs')
      ) {
        $reason = 'bundled Browser or Computer Use runtime'
      }
    }

    $key = '{0}|{1}' -f $process.ProcessId, $name
    if ($reason -and -not $seen.ContainsKey($key)) {
      $blockers.Add([pscustomobject]@{
          ProcessId = $process.ProcessId
          Name = $name
          Reason = $reason
        })
      $seen[$key] = $true
    }
  }

  return @($blockers.ToArray())
}

function Test-AutomaticPostUpdateProcessQuiescence(
  [string]$PluginCacheRoot,
  [string]$CodexCliMirror,
  [string]$RuntimeBaseRoot
) {
  $blockers = @(Get-AutomaticPostUpdateBlockers $PluginCacheRoot $CodexCliMirror $RuntimeBaseRoot)
  if ($blockers.Count -gt 0) {
    return $false
  }

  Start-Sleep -Seconds 5
  return @(Get-AutomaticPostUpdateBlockers $PluginCacheRoot $CodexCliMirror $RuntimeBaseRoot).Count -eq 0
}

function Assert-BrowserCacheOnlyNoBlockers([string]$BrowserRoot, [string]$CodexCliMirror) {
  $blockers = @(Get-BrowserCacheOnlyBlockers $BrowserRoot $CodexCliMirror)
  if ($blockers.Count -gt 0) {
    $detail = @($blockers | ForEach-Object { "$($_.Name)#$($_.ProcessId): $($_.Reason)" }) -join '; '
    throw "BrowserCacheOnly process guard blocked cache modification: $detail"
  }
}

function Assert-BrowserCacheOnlyProcessQuiescence([string]$BrowserRoot, [string]$CodexCliMirror) {
  Assert-BrowserCacheOnlyNoBlockers $BrowserRoot $CodexCliMirror
  Start-Sleep -Seconds 5
  try {
    Assert-BrowserCacheOnlyNoBlockers $BrowserRoot $CodexCliMirror
  } catch {
    throw "BrowserCacheOnly requires a stable five-second Codex exit window before modifying the cache: $($_.Exception.Message)"
  }
}

function New-BrowserCacheOnlyProcessGuard([string]$BrowserRoot, [string]$CodexCliMirror) {
  return {
    param([string]$Phase, [string]$RelativePath)
    Assert-BrowserCacheOnlyNoBlockers $BrowserRoot $CodexCliMirror
  }.GetNewClosure()
}

function Invoke-BrowserCacheOnlyProcessGuard([scriptblock]$ProcessGuard, [string]$Phase, [string]$RelativePath = '') {
  if (-not $ProcessGuard) {
    throw 'BrowserCacheOnly requires a process guard before modifying the real cache.'
  }
  & $ProcessGuard $Phase $RelativePath
}

function Invoke-BrowserCacheOnlyRepair(
  [string]$BrowserSource,
  [string]$BrowserRoot,
  [scriptblock]$ProcessGuard,
  [scriptblock]$BeforeStagingValidation,
  [scriptblock]$BeforeCommitFile,
  [scriptblock]$BeforeMetadataJunction,
  [hashtable]$RuntimeTextExpectations,
  [scriptblock]$RuntimeTextMaterializer
) {
  if (-not $ProcessGuard) {
    throw 'BrowserCacheOnly requires a process guard before modifying the real cache.'
  }

  $browserVersion = Get-PluginVersion $BrowserSource
  $browserVersionDir = Join-Path $BrowserRoot $browserVersion
  $comparison = Get-BrowserCacheComparison $BrowserSource $browserVersionDir $RuntimeTextExpectations
  $latestPath = Join-Path $BrowserRoot 'latest'
  $metadataPath = Join-Path $BrowserRoot '.codex-plugin'
  $metadataTarget = Join-Path $browserVersionDir '.codex-plugin'

  $browserRootItem = Get-Item -LiteralPath $BrowserRoot -Force -ErrorAction SilentlyContinue
  if (
    $browserRootItem -and
    ((-not $browserRootItem.PSIsContainer) -or (($browserRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))
  ) {
    throw "Refusing BrowserCacheOnly because the Browser cache root is not a plain directory: $BrowserRoot"
  }

  Assert-BrowserDiscoveryJunctionReplaceable 'Browser latest' $latestPath
  Assert-BrowserDiscoveryJunctionReplaceable 'Browser metadata' $metadataPath
  $latestSnapshot = Get-BrowserDiscoveryLinkSnapshot $latestPath
  $metadataSnapshot = Get-BrowserDiscoveryLinkSnapshot $metadataPath

  if ($comparison.State -eq 'browser-cache-complete') {
    if (
      (-not (Test-BrowserDiscoveryJunction $latestPath $browserVersionDir)) -or
      (-not (Test-BrowserDiscoveryJunction $metadataPath $metadataTarget))
    ) {
      throw "browser-discovery-only-drift: Browser concrete is complete; run -BrowserDiscoveryOnly instead of -BrowserCacheOnly."
    }

    Write-Step "Browser cache already complete for the current AppX version: $browserVersion"
    return [pscustomobject]@{ State = 'browser-cache-complete'; Version = $browserVersion; AddedFiles = 0 }
  }

  if ($comparison.State -notin @('browser-cache-missing-only', 'browser-cache-runtime-text-only', 'browser-cache-repairable')) {
    $detail = @(
      @($comparison.ExtraFiles | ForEach-Object { "extra=$_" }) +
      @($comparison.Conflicts | ForEach-Object { "conflict=$_" })
    ) -join '; '
    throw "browser-cache-rebuild-required: Browser concrete is not a strict current-AppX missing-file subset. $detail"
  }

  $browserRootCreated = $false
  if (-not (Test-Path -LiteralPath $BrowserRoot)) {
    Invoke-BrowserCacheOnlyProcessGuard $ProcessGuard 'before-staging-root'
    New-Item -ItemType Directory -Force -Path $BrowserRoot | Out-Null
    $browserRootCreated = $true
  }

  $nonce = '{0}.{1}' -f $PID, ([guid]::NewGuid().ToString('N'))
  $stagingPath = Join-Path $BrowserRoot ".browser-cache-staging.$nonce"
  $journalPath = Join-Path $BrowserRoot ".browser-cache-journal.$nonce.json"
  $createdFiles = New-Object System.Collections.Generic.List[object]
  $createdDirectories = New-Object System.Collections.Generic.List[string]
  $temporaryFiles = New-Object System.Collections.Generic.List[object]
  $linksMayHaveChanged = $false

  try {
    Copy-TreeContentOnly $BrowserSource $stagingPath
    if ($BeforeStagingValidation) {
      & $BeforeStagingValidation $stagingPath
    }

    $stagingComparison = Get-BrowserCacheComparison $BrowserSource $stagingPath
    if ($stagingComparison.State -ne 'browser-cache-complete') {
      throw "BrowserCacheOnly staging is not byte-identical to the current AppX Browser source: $stagingPath"
    }
    Invoke-BrowserCacheOnlyProcessGuard $ProcessGuard 'after-staging-validation'

    # The journal describes this process only; in-memory fingerprints decide rollback ownership.
    $journal = [ordered]@{
      browserVersion = $browserVersion
      missingFiles = @($comparison.MissingFiles)
      missingDirectories = @($comparison.MissingDirectories)
      runtimeTextFiles = @($comparison.RuntimeTextFiles)
      recoveryScope = 'current-process-only'
    } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($journalPath, $journal, [System.Text.UTF8Encoding]::new($false))

    if (-not $comparison.ConcreteExists) {
      Invoke-BrowserCacheOnlyProcessGuard $ProcessGuard 'before-concrete-directory'
      if (Test-Path -LiteralPath $browserVersionDir) {
        throw "Browser concrete appeared while staging: $browserVersionDir"
      }
      New-Item -ItemType Directory -Path $browserVersionDir -ErrorAction Stop | Out-Null
      $createdDirectories.Add($browserVersionDir)
      Invoke-BrowserCacheOnlyProcessGuard $ProcessGuard 'after-concrete-directory'
    }

    foreach ($relative in @($comparison.MissingDirectories | Sort-Object { $_.Length })) {
      $directory = Join-Path $browserVersionDir $relative
      if (-not (Test-Path -LiteralPath $directory)) {
        Invoke-BrowserCacheOnlyProcessGuard $ProcessGuard 'before-directory' $relative
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        $createdDirectories.Add($directory)
        Invoke-BrowserCacheOnlyProcessGuard $ProcessGuard 'after-directory' $relative
      }
    }

    $writeCount = 0
    foreach ($relative in @($comparison.MissingFiles | Sort-Object)) {
      $destination = Join-Path $browserVersionDir $relative
      Invoke-BrowserCacheOnlyProcessGuard $ProcessGuard 'before-file' $relative
      if (Test-Path -LiteralPath $destination) {
        throw "Browser concrete file appeared while restoring missing files: $destination"
      }

      $writeCount += 1
      if ($BeforeCommitFile) {
        & $BeforeCommitFile $relative $writeCount
      }

      $temporary = Join-Path (Split-Path -Parent $destination) ('.{0}.browser-cache-temp.{1}' -f (Split-Path -Leaf $destination), ([guid]::NewGuid().ToString('N')))
      [System.IO.File]::WriteAllBytes($temporary, [System.IO.File]::ReadAllBytes((Join-Path $stagingPath $relative)))
      Assert-BrowserCacheFileMatches (Join-Path $stagingPath $relative) $temporary
      $temporaryFingerprint = Get-BrowserCacheFileFingerprint $temporary
      if (-not $temporaryFingerprint) {
        throw "Could not fingerprint BrowserCacheOnly temporary file: $temporary"
      }
      $temporaryFiles.Add($temporaryFingerprint)
      [System.IO.File]::Move($temporary, $destination)
      [void]$temporaryFiles.Remove($temporaryFingerprint)
      $committedFingerprint = Get-BrowserCacheFileFingerprint $destination
      if (-not $committedFingerprint) {
        throw "Could not fingerprint BrowserCacheOnly committed file: $destination"
      }
      $createdFiles.Add($committedFingerprint)
      Invoke-BrowserCacheOnlyProcessGuard $ProcessGuard 'after-file' $relative
    }

    $completed = Get-BrowserCacheComparison $BrowserSource $browserVersionDir $RuntimeTextExpectations
    if ($completed.State -eq 'browser-cache-runtime-text-only') {
      if (-not $RuntimeTextMaterializer) {
        throw 'BrowserCacheOnly requires a runtime-text materializer for the current AppX Browser source.'
      }
      & $RuntimeTextMaterializer | Out-Null
      $completed = Get-BrowserCacheComparison $BrowserSource $browserVersionDir $RuntimeTextExpectations
    }
    if ($completed.State -ne 'browser-cache-complete') {
      throw "BrowserCacheOnly did not produce a complete Browser concrete directory after runtime-text materialization: $browserVersionDir ($($completed.State))"
    }

    Invoke-BrowserCacheOnlyProcessGuard $ProcessGuard 'before-latest-junction'
    $linksMayHaveChanged = $true
    Set-BrowserDiscoveryJunction $latestPath $browserVersionDir | Out-Null
    Invoke-BrowserCacheOnlyProcessGuard $ProcessGuard 'before-metadata-junction'
    if ($BeforeMetadataJunction) {
      & $BeforeMetadataJunction
    }
    Set-BrowserDiscoveryJunction $metadataPath $metadataTarget | Out-Null

    if (
      (-not (Test-Path -LiteralPath (Join-Path $latestPath 'scripts\browser-client.mjs'))) -or
      (-not (Test-Path -LiteralPath (Join-Path $latestPath '.codex-plugin\plugin.json')))
    ) {
      throw 'BrowserCacheOnly restored the concrete directory but Browser discovery paths are not readable.'
    }

    Write-Step "Browser cache restored and runtime text validated for the current AppX source: $browserVersion"
    return [pscustomobject]@{
      State = 'browser-cache-complete'
      Version = $browserVersion
      AddedFiles = @($comparison.MissingFiles).Count
    }
  } catch {
    $originalError = $_
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    $preservedPaths = New-Object System.Collections.Generic.List[string]
    $preserveCommitted = Test-BrowserCacheOnlyProcessGuardFailure $originalError
    if ($linksMayHaveChanged -and -not $preserveCommitted) {
      foreach ($snapshot in @($metadataSnapshot, $latestSnapshot)) {
        try {
          Restore-BrowserDiscoveryLinkSnapshot $snapshot
        } catch {
          $rollbackErrors.Add($_.Exception.Message)
        }
      }
    }

    if ($preserveCommitted) {
      Write-Step 'BrowserCacheOnly process guard reappeared; preserving already committed current-AppX files for a later safe resume.'
    } else {
      foreach ($file in @($createdFiles | Sort-Object Path -Descending)) {
        try {
          $removal = Remove-BrowserCacheFileIfOwned $file
          if (-not $removal.Confirmed) {
            $preservedPaths.Add($file.Path)
          }
        } catch {
          $rollbackErrors.Add($_.Exception.Message)
        }
      }
      try {
        Remove-EmptyBrowserCacheDirectories @($createdDirectories)
      } catch {
        $rollbackErrors.Add($_.Exception.Message)
      }
    }

    if ($rollbackErrors.Count -gt 0 -or $preservedPaths.Count -gt 0) {
      $detail = @(
        if ($rollbackErrors.Count -gt 0) { "rollback failed: $($rollbackErrors -join '; ')" }
        if ($preservedPaths.Count -gt 0) { "preserved unconfirmed files: $($preservedPaths -join '; ')" }
      ) -join '; '
      throw "$($originalError.Exception.Message) BrowserCacheOnly rollback report: $detail"
    }
    throw $originalError
  } finally {
    foreach ($temporary in $temporaryFiles.ToArray()) {
      try {
        $removal = Remove-BrowserCacheFileIfOwned $temporary
        if (-not $removal.Confirmed) {
          Write-Step "Preserving unconfirmed BrowserCacheOnly temporary file: $($temporary.Path)"
        }
      } catch {
        Write-Step "Could not clean BrowserCacheOnly temporary file: $($temporary.Path) ($($_.Exception.Message))"
      }
    }
    if ($stagingPath) {
      Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue
    if ($browserRootCreated) {
      try {
        Remove-EmptyBrowserCacheDirectories @($BrowserRoot)
      } catch {
        Write-Step "Could not remove empty Browser cache root after BrowserCacheOnly cleanup: $($_.Exception.Message)"
      }
    }
  }
}

function Test-CodexCliFilesMatch([string]$SourceFile, [string]$DestFile) {
  if (
    (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) -or
    (-not (Test-Path -LiteralPath $DestFile -PathType Leaf))
  ) {
    return $false
  }

  $sourceInfo = Get-Item -LiteralPath $SourceFile
  $destInfo = Get-Item -LiteralPath $DestFile
  if ($sourceInfo.Length -ne $destInfo.Length) {
    return $false
  }

  return (
    (Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $DestFile -Algorithm SHA256).Hash
  )
}

function Get-CodexCliMirrorUsers([string]$MirrorPath) {
  try {
    return @(
      Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object {
          $_.ExecutablePath -and
          [string]::Equals([string]$_.ExecutablePath, $MirrorPath, [StringComparison]::OrdinalIgnoreCase)
        }
    )
  } catch {
    throw "Could not inspect processes using the managed Codex CLI mirror: $($_.Exception.Message)"
  }
}

function Test-CodexCliExecutable([string]$Path) {
  try {
    & $Path --version *> $null
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
  }
}

function Ensure-CodexCliMirror(
  [string]$SourceFile,
  [string]$DestFile,
  [switch]$ReturnPendingWhenInUse
) {
  if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
    throw "Current Codex CLI source is missing: $SourceFile"
  }

  if (Test-CodexCliFilesMatch $SourceFile $DestFile) {
    Write-Step 'Current Codex CLI managed project mirror already matches the AppX binary; no refresh is needed.'
    return [pscustomobject]@{ Status = 'Current'; InUseCount = 0 }
  }

  $mirrorUsers = @(Get-CodexCliMirrorUsers $DestFile)
  if ($mirrorUsers.Count -gt 0) {
    if ($ReturnPendingWhenInUse) {
      Write-Step "managed Codex CLI mirror refresh is pending because $($mirrorUsers.Count) process(es) are using it. No process was stopped."
      return [pscustomobject]@{ Status = 'Pending'; InUseCount = $mirrorUsers.Count }
    }
    throw "The current AppX CLI differs but $($mirrorUsers.Count) process(es) are using the managed project mirror. No process was stopped; retry after those processes exit."
  }

  $destDirectory = Split-Path -Parent $DestFile
  New-Item -ItemType Directory -Force -Path $destDirectory | Out-Null
  $unique = '{0}.{1}' -f $PID, ([guid]::NewGuid().ToString('N'))
  $stagingPath = "$DestFile.staging.$unique.exe"
  $replacementPath = "$DestFile.replacement.$unique.exe"
  $backupPath = "$DestFile.backup.$unique.exe"
  $replacementCompleted = $false

  try {
    Copy-FileContentOnly $SourceFile $stagingPath
    Assert-CodexCliMirrorMatchesCurrent $SourceFile $stagingPath
    if (-not (Test-CodexCliExecutable $stagingPath)) {
      throw 'Staged Codex CLI failed the --version execution check.'
    }

    # Windows can keep the executable validation image mapped briefly after
    # --version exits. Replace from a byte-identical file that was never run.
    Copy-FileContentOnly $stagingPath $replacementPath
    Assert-CodexCliMirrorMatchesCurrent $SourceFile $replacementPath

    if (Test-Path -LiteralPath $DestFile -PathType Leaf) {
      [System.IO.File]::Replace($replacementPath, $DestFile, $backupPath, $true)
      $replacementCompleted = $true
    } else {
      [System.IO.File]::Move($replacementPath, $DestFile)
    }

    Assert-CodexCliMirrorMatchesCurrent $SourceFile $DestFile
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
      Remove-Item -LiteralPath $backupPath -Force
    }
    Write-Step 'Refreshed the managed Codex CLI mirror through a validated atomic replacement.'
    return [pscustomobject]@{ Status = 'Refreshed'; InUseCount = 0 }
  } catch {
    $refreshError = $_.Exception.Message
    if ($replacementCompleted -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
      try {
        [System.IO.File]::Replace($backupPath, $DestFile, $null, $true)
      } catch {
        throw "CLI mirror refresh failed and the validated old mirror could not be restored from $backupPath. Detail: $refreshError; rollback: $($_.Exception.Message)"
      }
    }
    throw "CLI mirror refresh failed; the existing mirror was preserved. Detail: $refreshError"
  } finally {
    foreach ($temporaryPath in @($stagingPath, $replacementPath)) {
      for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf); $attempt++) {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
          Start-Sleep -Milliseconds 100
        }
      }
    }
  }
}

function Assert-CodexCliMirrorMatchesCurrent([string]$SourceFile, [string]$DestFile) {
  if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
    throw "Current Codex CLI source is missing: $SourceFile"
  }
  if (-not (Test-Path -LiteralPath $DestFile -PathType Leaf)) {
    throw "Current Codex CLI managed project mirror is missing: $DestFile"
  }

  $sourceInfo = Get-Item -LiteralPath $SourceFile
  $destInfo = Get-Item -LiteralPath $DestFile
  if ($sourceInfo.Length -ne $destInfo.Length) {
    throw "Current AppX CLI and managed project mirror lengths differ: source=$($sourceInfo.Length), mirror=$($destInfo.Length)"
  }

  $sourceHash = (Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash
  $destHash = (Get-FileHash -LiteralPath $DestFile -Algorithm SHA256).Hash
  if ($sourceHash -ne $destHash) {
    throw 'Current AppX CLI and managed project mirror SHA-256 values differ.'
  }
}

function Get-CodexCliMirrorRefreshState([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Write-CodexCliMirrorRefreshState(
  [string]$Path,
  [string]$SourceFile,
  [string]$MirrorPath,
  [string]$Phase,
  [bool]$DesktopUsedStaleMirror,
  [int]$InUseCount
) {
  $state = [ordered]@{
    schemaVersion = 1
    phase = $Phase
    appxCliPath = $SourceFile
    appxCliLength = (Get-Item -LiteralPath $SourceFile).Length
    appxCliSha256 = (Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash
    mirrorPath = $MirrorPath
    desktopUsedStaleMirror = $DesktopUsedStaleMirror
    inUseCount = $InUseCount
    recordedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  }
  New-Utf8NoBomFile $Path ($state | ConvertTo-Json -Depth 4)
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

function Ensure-UserCodexCliPath([string]$ExpectedPath) {
  $state = Get-CodexCliEnvironmentState $ExpectedPath
  if ($state.MachineConflicts) {
    throw 'Machine-level CODEX_CLI_PATH conflicts with the verified managed CLI mirror. Refusing to overwrite Machine scope.'
  }
  if ($state.UserMatches) {
    Write-Step 'User-level CODEX_CLI_PATH already matches the verified managed CLI mirror.'
    return $false
  }

  [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $ExpectedPath, [EnvironmentVariableTarget]::User)
  $updatedState = Get-CodexCliEnvironmentState $ExpectedPath
  if (-not $updatedState.UserMatches) {
    throw 'Failed to persist User-level CODEX_CLI_PATH.'
  }

  Write-Step 'Updated User-level CODEX_CLI_PATH. Fully exit and reopen Codex Desktop to start a new process; no hot reload is attempted.'
  return $true
}

function Reset-Junction([string]$LinkPath, [string]$TargetPath) {
  $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
  if ($existing) {
    if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      cmd /c "rmdir `"$LinkPath`"" | Out-Null
      if ($LASTEXITCODE -ne 0 -or (Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue)) {
        throw "Failed to remove junction: $LinkPath"
      }
    } else {
      Remove-Item -LiteralPath $LinkPath -Recurse -Force
    }
  }

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LinkPath) | Out-Null
  cmd /c "mklink /J `"$LinkPath`" `"$TargetPath`"" | Out-Null
  if (-not (Test-Path -LiteralPath $LinkPath)) {
    throw "Failed to create junction: $LinkPath -> $TargetPath"
  }
}

function Remove-JunctionOnly([string]$LinkPath) {
  if (-not (Test-Path -LiteralPath $LinkPath)) {
    return
  }

  $item = Get-Item -LiteralPath $LinkPath -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
    throw "Refusing to replace non-reparse marketplace directory: $LinkPath"
  }

  cmd /c "rmdir `"$LinkPath`"" | Out-Null
  if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $LinkPath)) {
    throw "Failed to remove marketplace junction: $LinkPath"
  }
}

function Remove-TmpRuntimeMarketplaceJunction([string]$RuntimePath, [string]$ExpectedLegacyTarget) {
  $item = Get-Item -LiteralPath $RuntimePath -Force -ErrorAction SilentlyContinue
  if (-not $item) {
    Write-Step "Tmp runtime marketplace is already absent: $RuntimePath"
    return
  }

  if (-not $item.PSIsContainer) {
    throw "Refusing to change non-directory tmp runtime marketplace: $RuntimePath"
  }

  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
    Write-Step "Preserving host-owned physical tmp runtime marketplace: $RuntimePath"
    return
  }

  $target = @($item.Target) | Select-Object -First 1
  if ((-not $target) -or ($target.TrimEnd('\') -ine $ExpectedLegacyTarget.TrimEnd('\'))) {
    throw "Refusing to remove unexpected tmp runtime marketplace reparse point: $RuntimePath -> $target"
  }

  Write-Step "Removing legacy tmp runtime marketplace junction: $RuntimePath"
  cmd /c "rmdir `"$RuntimePath`"" | Out-Null
  if ($LASTEXITCODE -ne 0 -or (Get-Item -LiteralPath $RuntimePath -Force -ErrorAction SilentlyContinue)) {
    throw "Failed to remove legacy tmp runtime marketplace junction: $RuntimePath"
  }
}

function Invoke-CodexCliJson([string]$CodexCliPath, [string[]]$Arguments, [string]$Label) {
  $raw = (& $CodexCliPath @Arguments 2>&1 | Out-String).Trim()
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw "$Label failed with exit=${exitCode}: $raw"
  }

  try {
    return ($raw | ConvertFrom-Json)
  } catch {
    throw "$Label returned invalid JSON: $($_.Exception.Message)"
  }
}

function Ensure-OfficialBundledMarketplace([string]$WindowsAppsSource) {
  $persistentRoot = Join-Path $RepairRoot 'state\openai-bundled-marketplace'
  $codexCliMirror = Join-Path $RepairRoot 'state\codex-cli\codex.exe'
  $marketplaceLink = Join-Path $CodexHome 'marketplaces\openai-bundled'
  $tmpRuntimeMarketplace = Join-Path $CodexHome '.tmp\bundled-marketplaces\openai-bundled'

  if (-not (Test-CompleteBundledSource $WindowsAppsSource)) {
    throw "Current WindowsApps bundled marketplace is incomplete: $WindowsAppsSource"
  }

  Write-Step "Refreshing persistent bundled marketplace mirror: $persistentRoot"
  Remove-JunctionOnly $marketplaceLink
  Remove-TmpRuntimeMarketplaceJunction $tmpRuntimeMarketplace $persistentRoot
  Copy-TreeContentOnly $WindowsAppsSource $persistentRoot
  if (-not (Test-CompleteBundledSource $persistentRoot)) {
    throw "Persistent bundled marketplace mirror is incomplete: $persistentRoot"
  }

  Reset-Junction $marketplaceLink $persistentRoot

  $codexCliSource = Find-CurrentCodexCli
  if (-not $codexCliSource) {
    throw 'The current Codex AppX CLI was not found.'
  }
  Ensure-CodexCliMirror $codexCliSource $codexCliMirror
  Assert-CodexCliMirrorMatchesCurrent $codexCliSource $codexCliMirror
  Ensure-UserCodexCliPath $codexCliMirror | Out-Null
  $codexCli = $codexCliMirror
  Write-Step "Using the current Codex CLI managed project mirror: $codexCli"

  $marketplaces = Invoke-CodexCliJson $codexCli @('plugin', 'marketplace', 'list', '--json') 'codex plugin marketplace list'
  $registered = @($marketplaces.marketplaces) |
    Where-Object { [string]$_.name -eq 'openai-bundled' } |
    Select-Object -First 1
  $registeredRoot = if ($registered) { ([string]$registered.root -replace '^\\\\\?\\', '').TrimEnd('\') } else { $null }
  $needsRegistration = (-not $registered) -or ($registeredRoot -ine $persistentRoot.TrimEnd('\'))

  if ($needsRegistration) {
    if ($registered) {
      Write-Step 'Removing the stale official openai-bundled marketplace registration.'
      & $codexCli plugin marketplace remove openai-bundled --json 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove the stale openai-bundled marketplace registration: exit=$LASTEXITCODE"
      }
    }

    Write-Step "Registering official openai-bundled marketplace from the persistent managed project mirror."
    & $codexCli plugin marketplace add $persistentRoot --json 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to register the persistent openai-bundled marketplace: exit=$LASTEXITCODE"
    }
  } else {
    Write-Step 'Official openai-bundled marketplace registration already points to the persistent mirror.'
  }

  $plugins = Invoke-CodexCliJson $codexCli @('plugin', 'list', '--json') 'codex plugin list'
  $browser = @($plugins.installed) |
    Where-Object { [string]$_.pluginId -eq 'browser@openai-bundled' } |
    Select-Object -First 1

  if (-not $browser -or -not [bool]$browser.installed) {
    Write-Step 'Browser is absent from the official installed-plugin record. Running the official Browser install flow.'
    & $codexCli plugin add 'browser@openai-bundled' --json 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Official Browser plugin installation failed: exit=$LASTEXITCODE"
    }
  } else {
    Write-Step 'Browser is already present in the official installed-plugin record.'
  }

  $pluginsAfter = Invoke-CodexCliJson $codexCli @('plugin', 'list', '--json') 'codex plugin list after Browser install'
  $browserAfter = @($pluginsAfter.installed) |
    Where-Object { [string]$_.pluginId -eq 'browser@openai-bundled' } |
    Select-Object -First 1
  if (-not $browserAfter -or -not [bool]$browserAfter.installed -or -not [bool]$browserAfter.enabled) {
    throw 'Browser is not installed and enabled in the official plugin record after repair.'
  }

  Write-Step "Official Browser install record OK: $($browserAfter.version)"
  return $persistentRoot
}

function Test-LatestIsStable([string]$LatestPath, [string]$VersionDir) {
  if (-not (Test-Path -LiteralPath $LatestPath)) {
    return $false
  }

  $item = Get-Item -LiteralPath $LatestPath -Force
  if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    $targets = @($item.Target)
    if ($targets.Count -eq 0) {
      return $false
    }
    if ($targets[0] -like '*\.tmp\bundled-marketplaces\*') {
      return $false
    }
    return ($targets[0].TrimEnd('\') -ieq $VersionDir.TrimEnd('\'))
  }

  return $false
}

function Ensure-PluginLatestLink([string]$Name, [string]$Root, [string]$Version) {
  $versionDir = Join-Path $Root $Version
  if (-not (Test-Path -LiteralPath $versionDir -PathType Container)) {
    return $false
  }

  $latest = Join-Path $Root 'latest'
  if (Test-LatestIsStable $latest $versionDir) {
    Write-Step "$Name plugin latest link OK."
    return $false
  }

  Write-Step "Repairing $Name plugin latest link: $latest -> $versionDir"
  Reset-Junction $latest $versionDir
  return $true
}

function Assert-DiscoveryLinkReplaceable([string]$Name, [string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item) {
    return
  }

  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
    throw "Refusing discovery-link-only repair because $Name is a physical path: $Path"
  }
}

function Test-PluginCache([string]$Root, [string]$Version, [string[]]$RequiredRelativeFiles) {
  $versionDir = Join-Path $Root $Version
  if (-not (Test-Path -LiteralPath $versionDir)) {
    return $false
  }

  if (-not (Test-LatestIsStable (Join-Path $Root 'latest') $versionDir)) {
    return $false
  }

  foreach ($relative in $RequiredRelativeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $versionDir $relative))) {
      return $false
    }
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $Root 'latest') $relative))) {
      return $false
    }
  }

  return $true
}

function Test-PluginMetadataLink([string]$Root, [string]$Version) {
  $metadataLink = Join-Path $Root '.codex-plugin'
  $expected = Join-Path (Join-Path $Root $Version) '.codex-plugin'

  if (-not (Test-Path -LiteralPath $metadataLink)) {
    return $false
  }

  $item = Get-Item -LiteralPath $metadataLink -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
    return $false
  }

  $target = @($item.Target) | Select-Object -First 1
  return (
    $target -and
    $target.TrimEnd('\') -ieq $expected.TrimEnd('\') -and
    (Test-Path -LiteralPath (Join-Path $metadataLink 'plugin.json'))
  )
}

function Ensure-PluginMetadataLink([string]$Name, [string]$Root, [string]$Version) {
  if (Test-PluginMetadataLink $Root $Version) {
    Write-Step "$Name plugin metadata link OK."
    return
  }

  $target = Join-Path (Join-Path $Root $Version) '.codex-plugin'
  if (-not (Test-Path -LiteralPath (Join-Path $target 'plugin.json'))) {
    throw "Missing plugin metadata source: $target"
  }

  Write-Step "Repairing $Name plugin metadata link: $Root\.codex-plugin -> $target"
  Reset-Junction (Join-Path $Root '.codex-plugin') $target
}

function Repair-MissingPluginFiles([string]$Name, [string]$SourceRoot, [string]$CacheRoot, [string]$Version, [string[]]$RequiredRelativeFiles) {
  $source = Join-Path $SourceRoot "plugins\$Name"
  $versionDir = Join-Path (Join-Path $CacheRoot $Name) $Version
  if (-not (Test-Path -LiteralPath $versionDir)) {
    return $false
  }

  $changed = $false
  foreach ($relative in $RequiredRelativeFiles) {
    $dest = Join-Path $versionDir $relative
    if (-not (Test-Path -LiteralPath $dest)) {
      Copy-FileContentOnly (Join-Path $source $relative) $dest
      $changed = $true
    }
  }

  return $changed
}

function Repair-PluginCache([string]$Name, [string]$SourceRoot, [string]$CacheRoot, [string[]]$LinkNames) {
  $source = Join-Path $SourceRoot "plugins\$Name"
  $version = Get-PluginVersion $source
  $root = Join-Path $CacheRoot $Name
  $versionDir = Join-Path $root $version

  New-Item -ItemType Directory -Force -Path $root | Out-Null
  Copy-TreeContentOnly $source $versionDir
  Reset-Junction (Join-Path $root 'latest') $versionDir

  foreach ($linkName in $LinkNames) {
    $target = Join-Path $versionDir $linkName
    if (Test-Path -LiteralPath $target) {
      Reset-Junction (Join-Path $root $linkName) $target
    }
  }

  return @{
    Name = $Name
    Version = $version
    Root = $root
    VersionDir = $versionDir
  }
}

function Ensure-PluginEnabled([string]$ConfigPath, [string]$PluginName) {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    New-Utf8NoBomFile $ConfigPath ''
  }

  $text = Get-Content -LiteralPath $ConfigPath -Raw
  $sectionHeader = "[plugins.`"$PluginName@openai-bundled`"]"
  $escaped = [regex]::Escape($sectionHeader)

  if ($text -notmatch "(?m)^$escaped\s*$") {
    $text = $text.TrimEnd() + "`r`n`r`n$sectionHeader`r`nenabled = true`r`n"
    New-Utf8NoBomFile $ConfigPath $text
    return
  }

  $start = $text.IndexOf($sectionHeader)
  $next = $text.IndexOf("`n[", $start + 1)
  if ($next -lt 0) {
    $next = $text.Length
  }

  $section = $text.Substring($start, $next - $start)
  if ($section -match '(?m)^enabled\s*=\s*false\s*$') {
    $newSection = [regex]::Replace($section, '(?m)^enabled\s*=\s*false\s*$', 'enabled = true', 1)
    $text = $text.Substring(0, $start) + $newSection + $text.Substring($next)
    New-Utf8NoBomFile $ConfigPath $text
  } elseif ($section -notmatch '(?m)^enabled\s*=') {
    $newSection = $section.TrimEnd() + "`r`nenabled = true`r`n"
    $text = $text.Substring(0, $start) + $newSection + $text.Substring($next)
    New-Utf8NoBomFile $ConfigPath $text
  }
}

function Get-CurrentCuaRuntimeBin([string]$ConfigPath) {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    return $null
  }

  $text = Get-Content -LiteralPath $ConfigPath -Raw
  $match = [regex]::Match($text, "(?m)^command\s*=\s*'([^']*\\cua_node\\[^']*\\bin\\node_repl\.exe)'\s*$")
  if ($match.Success) {
    return Split-Path -Parent $match.Groups[1].Value
  }

  $match = [regex]::Match($text, '(?m)^command\s*=\s*"([^"]*\\cua_node\\[^"]*\\bin\\node_repl\.exe)"\s*$')
  if ($match.Success) {
    return Split-Path -Parent $match.Groups[1].Value
  }

  return $null
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

function Test-CuaRuntime([string]$RuntimeBin) {
  if (-not $RuntimeBin) {
    return $false
  }

  return (
    (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $RuntimeBin) 'manifest.json')) -and
    (Test-Path -LiteralPath (Join-Path $RuntimeBin 'node_repl.exe')) -and
    (Test-Path -LiteralPath (Join-Path $RuntimeBin 'node.exe')) -and
    (Test-Path -LiteralPath (Join-Path $RuntimeBin 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe')) -and
    (Test-Path -LiteralPath (Join-Path $RuntimeBin 'node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'))
  )
}

function Get-CuaRuntimeHash([string]$RuntimeRoot) {
  $payload = New-Object System.Text.StringBuilder
  foreach ($relativePath in @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')) {
    $filePath = Join-Path $RuntimeRoot ($relativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $filePath)) {
      throw "Computer Use runtime hash input is missing: $filePath"
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

function Test-CuaRuntimeIdentity([string]$RuntimeRoot, [string]$SourceRoot) {
  try {
    foreach ($relativePath in @('manifest.json', 'bin\node.exe', 'bin\node_repl.exe')) {
      $runtimeFile = Join-Path $RuntimeRoot $relativePath
      $sourceFile = Join-Path $SourceRoot $relativePath
      if (
        (-not (Test-Path -LiteralPath $runtimeFile)) -or
        (-not (Test-Path -LiteralPath $sourceFile)) -or
        ((Get-FileHash -LiteralPath $runtimeFile -Algorithm SHA256).Hash -ne
          (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash)
      ) {
        return $false
      }
    }
    return $true
  } catch {
    return $false
  }
}

function Repair-CuaRuntimeIfMissing(
  [string]$ConfigPath,
  [string]$SourceCuaNode,
  [switch]$DeferConfigPathValidation
) {
  $runtimeBin = Get-CurrentCuaRuntimeBin $ConfigPath
  if (-not $SourceCuaNode) {
    if (Test-CuaRuntime $runtimeBin) {
      Write-Step "Computer Use runtime OK, but no packaged source was found for Electron relocation validation: $runtimeBin"
      return $runtimeBin
    }
    Write-Step 'Computer Use runtime is missing but no packaged cua_node source was found. Leaving config unchanged.'
    return $runtimeBin
  }

  $hash = Get-CuaRuntimeHash $SourceCuaNode
  $destRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\runtimes\cua_node\$hash"
  $destBin = Join-Path $destRoot 'bin'

  if ((-not (Test-CuaRuntime $destBin)) -or (-not (Test-CuaRuntimeIdentity $destRoot $SourceCuaNode))) {
    Write-Step "Repairing missing Computer Use runtime: $destRoot"
    Copy-TreeContentOnly $SourceCuaNode $destRoot
  }

  if ((Test-CuaRuntime $destBin) -and (Test-CuaRuntimeIdentity $destRoot $SourceCuaNode)) {
    $text = Get-Content -LiteralPath $ConfigPath -Raw
    $originalText = $text
    $nodeRepl = Join-Path $destBin 'node_repl.exe'
    $node = Join-Path $destBin 'node.exe'
    $nodeModules = Join-Path $destBin 'node_modules'
    $computerUseExe = Join-Path $destBin 'node_modules\@oai\sky\bin\windows\codex-computer-use.exe'

    $pathsAlreadyCurrent = (
      (Test-WindowsPathEqual $runtimeBin $destBin) -and
      (Test-WindowsPathEqual (Get-TomlPathValue $text 'NODE_REPL_NODE_PATH') $node) -and
      (Test-WindowsPathEqual (Get-TomlPathValue $text 'NODE_REPL_NODE_MODULE_DIRS') $nodeModules) -and
      (Test-WindowsPathEqual (Get-ConfiguredNotifyExecutable $text) $computerUseExe)
    )

    if (-not $pathsAlreadyCurrent) {
      $text = [regex]::Replace($text, '(?m)^command\s*=\s*(?:"[^"]*\\node_repl\.exe"|''[^'']*\\node_repl\.exe'')[ \t]*\r?$', "command = '$nodeRepl'", 1)
      $text = [regex]::Replace($text, '(?m)^NODE_REPL_NODE_PATH\s*=\s*(?:"[^"]*\\node\.exe"|''[^'']*\\node\.exe'')[ \t]*\r?$', "NODE_REPL_NODE_PATH = '$node'", 1)
      $text = [regex]::Replace($text, '(?m)^NODE_REPL_NODE_MODULE_DIRS\s*=\s*(?:"[^"]*\\node_modules"|''[^'']*\\node_modules'')[ \t]*\r?$', "NODE_REPL_NODE_MODULE_DIRS = '$nodeModules'", 1)
      $text = [regex]::Replace(
        $text,
        '(?m)^notify\s*=\s*\[\s*(?:"[^"]*"|''[^'']*'')\s*,\s*"turn-ended"\s*\][ \t]*\r?$',
        "notify = [ '$computerUseExe', `"turn-ended`" ]",
        1
      )
    }
    if ($text -cne $originalText) {
      New-Utf8NoBomFile $ConfigPath $text
      Write-Step 'Computer Use runtime paths updated in config.toml.'
    } elseif ($pathsAlreadyCurrent) {
      Write-Step 'Computer Use runtime paths in config.toml already match the current aggregate runtime.'
    }

    $verifiedText = Get-Content -LiteralPath $ConfigPath -Raw
    $verifiedRuntimeBin = Get-CurrentCuaRuntimeBin $ConfigPath
    $configPathsValid = (
      (Test-WindowsPathEqual $verifiedRuntimeBin $destBin) -and
      (Test-WindowsPathEqual (Get-TomlPathValue $verifiedText 'NODE_REPL_NODE_PATH') $node) -and
      (Test-WindowsPathEqual (Get-TomlPathValue $verifiedText 'NODE_REPL_NODE_MODULE_DIRS') $nodeModules) -and
      (Test-WindowsPathEqual (Get-ConfiguredNotifyExecutable $verifiedText) $computerUseExe)
    )
    if ((-not $configPathsValid) -and $DeferConfigPathValidation) {
      Write-Step 'Deferring Computer Use config-path validation until Node REPL configuration is restored.'
    } elseif (-not $configPathsValid) {
      throw 'Computer Use runtime files are valid, but the four node_repl/notify config paths could not be updated safely.'
    }
  } else {
    throw "Computer Use runtime relocation did not produce a valid Electron runtime: $destRoot"
  }

  return $destBin
}

function Ensure-NodeReplConfiguration(
  [string]$ConfigPath,
  [string]$RuntimeBin,
  [string]$BrowserRoot,
  [string]$BrowserVersion,
  [string]$ChromeRoot,
  [string]$ChromeVersion
) {
  if (-not (Test-CuaRuntime $RuntimeBin)) {
    Write-Step 'Node REPL configuration not restored because the Computer Use runtime is unavailable.'
    return
  }

  $browserClient = Join-Path $BrowserRoot "$BrowserVersion\scripts\browser-client.mjs"
  $chromeClient = Join-Path $ChromeRoot "$ChromeVersion\scripts\browser-client.mjs"
  if ((-not (Test-Path -LiteralPath $browserClient)) -or (-not (Test-Path -LiteralPath $chromeClient))) {
    throw 'Cannot restore node_repl configuration because current Browser or Chrome client files are missing.'
  }

  $nodeRepl = Join-Path $RuntimeBin 'node_repl.exe'
  $node = Join-Path $RuntimeBin 'node.exe'
  $nodeModules = Join-Path $RuntimeBin 'node_modules'
  $computerUseExe = Join-Path $nodeModules '@oai\sky\bin\windows\codex-computer-use.exe'
  $browserHash = (Get-FileHash -LiteralPath $browserClient -Algorithm SHA256).Hash.ToLowerInvariant()
  $chromeHash = (Get-FileHash -LiteralPath $chromeClient -Algorithm SHA256).Hash.ToLowerInvariant()
  $trustedHashes = "$browserHash,$chromeHash"
  $nodeReplSection = @"
[mcp_servers.node_repl]
command = '$nodeRepl'
args = []
startup_timeout_sec = 120

[mcp_servers.node_repl.env]
NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS = "1000"
NODE_REPL_NODE_MODULE_DIRS = '$nodeModules'
NODE_REPL_NODE_PATH = '$node'
NODE_REPL_TRUSTED_CODE_PATHS = '$CodexHome'
CODEX_HOME = '$CodexHome'
NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S = "$trustedHashes"
NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = "Control the in-app browser in conjunction with the Browser Plugin."
NODE_REPL_INSTRUCTIONS_USE_CASE_CHROME = "Control the Chrome browser in conjunction with the Chrome Plugin. Prefer this method of controlling Chrome over alternatives (such as Computer Use) unless the user explicitly mentions an alternative."
"@

  $text = Get-Content -LiteralPath $ConfigPath -Raw
  $text = [regex]::Replace(
    $text,
    '(?ms)^\[mcp_servers\.node_repl\]\s*$.*?(?=^\[(?!mcp_servers\.node_repl(?:\.env)?\])|\z)',
    ''
  )
  $text = [regex]::Replace(
    $text,
    '(?m)^notify\s*=\s*\[\s*"[^"]*codex-computer-use\.exe",\s*"turn-ended"\s*\]',
    "notify = [ '$computerUseExe', `"turn-ended`" ]",
    1
  )
  $text = $text.TrimEnd() + "`r`n`r`n" + $nodeReplSection.Trim() + "`r`n"
  New-Utf8NoBomFile $ConfigPath $text
  Write-Step 'Node REPL configuration restored for the current Computer Use runtime.'
}

function Ensure-BundledHealthCheckTask {
  $taskName = 'CodexDesktopBundledHealthCheck'
  $taskPath = '\'
  $description = 'Verify and conservatively repair Codex Desktop bundled Browser/Chrome/Computer Use state after Windows login and during active sessions.'
  $startBoundary = (Get-Date).AddMinutes(1).ToString('s')
  $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  $needsRegister = $true
  $backupXmlPath = Join-Path $BackupDir 'CodexDesktopBundledHealthCheck.task.xml'
  $taskXmlPath = Join-Path $BackupDir 'CodexDesktopBundledHealthCheck.register.xml'

  if ($existing) {
    try {
      $xml = [xml](Export-ScheduledTask -TaskName $taskName)
      New-Utf8NoBomFile $backupXmlPath ($xml.OuterXml)
      $existingTriggers = @($xml.Task.Triggers.ChildNodes | ForEach-Object { $_.LocalName })
      $hasLogon = $existingTriggers -contains 'LogonTrigger'
      $hasCalendar = $existingTriggers -contains 'CalendarTrigger'
      $existingDelay = [string]$xml.Task.Triggers.LogonTrigger.Delay
      $existingRepetitionInterval = [string]$xml.Task.Triggers.CalendarTrigger.Repetition.Interval
      $existingRepetitionDuration = [string]$xml.Task.Triggers.CalendarTrigger.Repetition.Duration
      $existingDaysInterval = [string]$xml.Task.Triggers.CalendarTrigger.ScheduleByDay.DaysInterval
      $existingCommand = [string]$xml.Task.Actions.Exec.Command
      $existingArguments = [string]$xml.Task.Actions.Exec.Arguments
      $existingDescription = [string]$xml.Task.RegistrationInfo.Description
      $existingHidden = [string]$xml.Task.Settings.Hidden
      $needsRegister = -not (
        $hasLogon -and
        $hasCalendar -and
        $existingDelay -eq 'PT5S' -and
        $existingRepetitionInterval -eq 'PT12H' -and
        $existingRepetitionDuration -eq 'P1D' -and
        $existingDaysInterval -eq '1' -and
        $existingCommand -eq 'wscript.exe' -and
        $existingArguments -like '*RunHidden-CodexDesktopBundledHealthCheck.vbs*' -and
        $existingHidden -eq 'true' -and
        $existingDescription -eq $description
      )
    } catch {
      $needsRegister = $true
    }
  }

  if ($needsRegister) {
    Write-Step "Registering persistent health check task: $taskName"
    if ($existing) {
      Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop | Out-Null
    }
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$description</Description>
    <URI>\$taskName</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$env:USERDOMAIN\$env:USERNAME</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Hidden>true</Hidden>
    <IdleSettings>
      <Duration>PT10M</Duration>
      <WaitTimeout>PT1H</WaitTimeout>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
  </Settings>
  <Triggers>
    <LogonTrigger>
      <Delay>PT5S</Delay>
      <UserId>$env:USERDOMAIN\$env:USERNAME</UserId>
    </LogonTrigger>
    <CalendarTrigger>
      <Repetition>
        <Interval>PT12H</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>"$RepairRoot\scripts\RunHidden-CodexDesktopBundledHealthCheck.vbs"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    New-Utf8NoBomFile $taskXmlPath $taskXml
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Xml $taskXml -Force | Out-Null
  } else {
    Write-Step "Persistent health check task OK: $taskName"
  }
}

function Remove-LegacyBundledRepairTasks {
  foreach ($taskName in @('Codex Refresh OpenAI Bundled Marketplace', 'CodexBundledPluginRepairWatcher')) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
      Write-Step "Legacy repair task absent: $taskName"
      continue
    }

    $backupPath = Join-Path $BackupDir (($taskName -replace '[^A-Za-z0-9_.-]', '_') + '.task.xml')
    try {
      $xml = [xml](Export-ScheduledTask -TaskName $taskName)
      New-Utf8NoBomFile $backupPath ($xml.OuterXml)
    } catch {
      Write-Step "Could not export legacy repair task before disabling: $taskName ($($_.Exception.Message))"
    }

    Write-Step "Removing legacy repair task that can race Codex plugin loading: $taskName"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }
}

$CodexHome = Join-Path $env:USERPROFILE '.codex'
$BackupRoot = if ($env:CODEX_REPAIR_BACKUP_ROOT) {
  $env:CODEX_REPAIR_BACKUP_ROOT
} else {
  Join-Path $RepairRoot 'archives\codex-plugin-backups'
}
$OpenAILocal = Join-Path $env:LOCALAPPDATA 'OpenAI'
$PluginCacheRoot = Join-Path $CodexHome 'plugins\cache\openai-bundled'
$ConfigPath = Join-Path $CodexHome 'config.toml'
$GlobalStatePath = Join-Path $CodexHome '.codex-global-state.json'
$ExtensionManifest = Join-Path $OpenAILocal 'extension\com.openai.codexextension.json'
$ChromeNativeHostV2Manifest = Join-Path $OpenAILocal 'Codex\chrome-native-hosts-v2.json'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDir = Join-Path $BackupRoot "post-update-bundled-repair-$Stamp"
$PersistentBundledMarketplaceRoot = Join-Path $RepairRoot 'state\openai-bundled-marketplace'

if ($CliMirrorOnly) {
  $codexCliSource = Find-CurrentCodexCli
  if (-not $codexCliSource) {
    throw 'The current registered Codex AppX CLI was not found.'
  }

  $codexCliMirror = Join-Path $RepairRoot 'state\codex-cli\codex.exe'
  $mirrorStatePath = Join-Path $RepairRoot 'state\codex-cli\mirror-refresh-state.json'
  $sourceHash = (Get-FileHash -LiteralPath $codexCliSource -Algorithm SHA256).Hash
  $previousState = Get-CodexCliMirrorRefreshState $mirrorStatePath
  $previousStateMatches = $previousState -and [string]$previousState.appxCliSha256 -eq $sourceHash
  $desktopUsedStaleMirror = (Test-CodexDesktopRunning) -or (
    $previousStateMatches -and [bool]$previousState.desktopUsedStaleMirror
  )

  $result = Ensure-CodexCliMirror $codexCliSource $codexCliMirror -ReturnPendingWhenInUse
  if ($result.Status -eq 'Pending') {
    Write-CodexCliMirrorRefreshState `
      $mirrorStatePath $codexCliSource $codexCliMirror 'pending-cli-mirror-refresh' `
      $desktopUsedStaleMirror $result.InUseCount
    exit 30
  }

  if ($result.Status -eq 'Refreshed' -or ($previousStateMatches -and [string]$previousState.phase -eq 'pending-cli-mirror-refresh')) {
    if ($desktopUsedStaleMirror) {
      Write-CodexCliMirrorRefreshState `
        $mirrorStatePath $codexCliSource $codexCliMirror 'cli-mirror-refreshed-pending-desktop-restart' `
        $true 0
    } else {
      Remove-Item -LiteralPath $mirrorStatePath -Force -ErrorAction SilentlyContinue
    }
  }

  Write-Step "CLI-mirror-only synchronization complete: $($result.Status)"
  exit 0
}

if ($BrowserNativeHostOnly) {
  Write-Step 'Starting targeted Browser native-host repair; Codex, Chrome, Edge, caches, junctions, runtime, config, marketplace, CLI mirror, and tasks remain untouched.'

  $currentPackage = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if (-not $currentPackage) {
    throw 'BrowserNativeHostOnly could not resolve the current registered Codex AppX package.'
  }

  $bundledSource = Find-LatestWindowsAppsBundledSource
  if (-not $bundledSource) {
    throw 'BrowserNativeHostOnly could not resolve the current registered AppX bundled source.'
  }
  $chromeSource = Join-Path $bundledSource 'plugins\chrome'
  $chromeVersion = Get-PluginVersion $chromeSource
  $chromeRoot = Join-Path $PluginCacheRoot 'chrome'
  $chromeVersionRoot = Join-Path $chromeRoot $chromeVersion
  $identity = Get-ChromiumNativeHostIdentity $chromeSource
  $identityRelativePath = 'scripts\' + (Split-Path -Leaf ([string]$identity.ConfigPath))
  if (-not (Test-PluginCache $chromeRoot $chromeVersion @(
        $identityRelativePath,
        'scripts\browser-client.mjs',
        'extension-host\windows\x64\extension-host.exe',
        '.codex-plugin\plugin.json'
      ))) {
    throw 'BrowserNativeHostOnly requires the current Chrome cache and latest link; repair that owner first.'
  }

  $chromeLatestRoot = Join-Path $chromeRoot 'latest'
  $concreteHostPath = Join-Path $chromeVersionRoot 'extension-host\windows\x64\extension-host.exe'
  $latestHostPath = Join-Path $chromeLatestRoot 'extension-host\windows\x64\extension-host.exe'
  $browserClientPath = Join-Path $chromeVersionRoot 'scripts\browser-client.mjs'
  $codexCliPath = Join-Path $RepairRoot 'state\codex-cli\codex.exe'
  if (-not (Test-Path -LiteralPath $codexCliPath -PathType Leaf)) {
    throw 'BrowserNativeHostOnly requires the existing healthy CLI mirror; run CliMirrorOnly for that owner.'
  }

  $runtimeBin = Get-CurrentCuaRuntimeBin $ConfigPath
  if (-not (Test-CuaRuntime $runtimeBin)) {
    throw 'BrowserNativeHostOnly requires the existing healthy cua_node runtime; run RuntimeOnly for that owner.'
  }

  $resourcesPath = Join-Path ([string]$currentPackage.InstallLocation) 'app\resources'
  if (-not (Test-Path -LiteralPath $resourcesPath -PathType Container)) {
    throw 'BrowserNativeHostOnly could not resolve the current AppX resources path.'
  }

  $allowedHostPaths = @($concreteHostPath, $latestHostPath)
  $registryPath = "Registry::HKEY_CURRENT_USER\Software\Google\Chrome\NativeMessagingHosts\$($identity.HostName)"
  try {
    $registryManifestPath = (Get-ItemProperty -LiteralPath $registryPath -Name '(default)' -ErrorAction Stop).'(default)'
  } catch {
    $registryManifestPath = $null
  }
  $legacyNeedsRepair = -not (Test-ChromiumNativeHostManifest $ExtensionManifest $identity $allowedHostPaths)
  $registryNeedsRepair = -not (Test-WindowsPathEqual ([string]$registryManifestPath) $ExtensionManifest)
  $v2ManifestPaths = @(
    (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\chrome-native-hosts-v2.json'),
    (Join-Path $CodexHome 'chrome-native-hosts-v2.json')
  )
  $v2NeedsRepair = @($v2ManifestPaths | Where-Object {
      -not (Test-ChromeNativeHostV2Manifest `
        $_ `
        @($identity.ExtensionIds) `
        ([string]$identity.HostName) `
        ([string]$currentPackage.Version) `
        $chromeVersion `
        $browserClientPath `
        $concreteHostPath `
        $codexCliPath `
        $CodexHome `
        (Join-Path $runtimeBin 'node.exe') `
        (Join-Path $runtimeBin 'node_modules') `
        (Join-Path $runtimeBin 'node_repl.exe') `
        $resourcesPath)
    }).Count -gt 0

  $changed = 0
  $rollback = $null
  try {
    if ($legacyNeedsRepair -or $registryNeedsRepair -or $v2NeedsRepair) {
      $rollback = New-BrowserNativeHostRollbackBackup `
        (Join-Path $RepairRoot 'archives\browser-native-host-backups') `
        (@($ExtensionManifest) + @($v2ManifestPaths)) `
        $registryPath
    }

    if ($legacyNeedsRepair) {
      $manifestObject = [ordered]@{
        allowed_origins = @(Get-ChromiumNativeHostExpectedOrigins $identity)
        description = 'Codex chrome native messaging host'
        name = [string]$identity.HostName
        path = $latestHostPath
        type = 'stdio'
      }
      Write-BrowserNativeHostUtf8NoBomAtomically $ExtensionManifest ($manifestObject | ConvertTo-Json -Depth 10)
      $changed++
    }

    if ($registryNeedsRepair) {
      New-Item -Path $registryPath -Force | Out-Null
      Set-Item -LiteralPath $registryPath -Value $ExtensionManifest
      $changed++
    }

    if ($v2NeedsRepair) {
      $changed += [int](Ensure-ChromeNativeHostV2Manifest `
        $CodexHome `
        @($identity.ExtensionIds) `
        ([string]$identity.HostName) `
        ([string]$currentPackage.Version) `
        $chromeVersion `
        $browserClientPath `
        $concreteHostPath `
        $codexCliPath `
        (Join-Path $runtimeBin 'node.exe') `
        (Join-Path $runtimeBin 'node_modules') `
        (Join-Path $runtimeBin 'node_repl.exe') `
        $resourcesPath)
    }

    if (-not (Test-ChromiumNativeHostManifest $ExtensionManifest $identity $allowedHostPaths)) {
      throw 'BrowserNativeHostOnly legacy manifest post-write verification failed.'
    }
    $registryManifestPath = (Get-ItemProperty -LiteralPath $registryPath -Name '(default)' -ErrorAction Stop).'(default)'
    if (-not (Test-WindowsPathEqual ([string]$registryManifestPath) $ExtensionManifest)) {
      throw 'BrowserNativeHostOnly registry post-write verification failed.'
    }
    foreach ($v2ManifestPath in $v2ManifestPaths) {
      if (-not (Test-ChromeNativeHostV2Manifest `
          $v2ManifestPath `
          @($identity.ExtensionIds) `
          ([string]$identity.HostName) `
          ([string]$currentPackage.Version) `
          $chromeVersion `
          $browserClientPath `
          $concreteHostPath `
          $codexCliPath `
          $CodexHome `
          (Join-Path $runtimeBin 'node.exe') `
          (Join-Path $runtimeBin 'node_modules') `
          (Join-Path $runtimeBin 'node_repl.exe') `
          $resourcesPath)) {
        throw "BrowserNativeHostOnly v2 manifest post-write verification failed: $v2ManifestPath"
      }
    }
  } catch {
    $repairError = $_
    if ($rollback) {
      try {
        Restore-BrowserNativeHostRollbackBackup $rollback
      } catch {
        throw "$($repairError.Exception.Message) BrowserNativeHostOnly rollback failed: $($_.Exception.Message); backup=$($rollback.BackupDirectory)"
      }
      throw "$($repairError.Exception.Message) BrowserNativeHostOnly restored the original state from $($rollback.BackupDirectory)."
    }
    throw
  }

  $backupDetail = if ($rollback) { "; rollbackBackup=$($rollback.BackupDirectory)" } else { '' }
  Write-Step "Targeted Browser native-host repair complete: schema=$($identity.Schema), extensionIds=$(@($identity.ExtensionIds).Count), directChanges=$changed$backupDetail. No process was stopped or restarted."
  exit 0
}

if ($RuntimeOnly) {
  Write-Step 'Starting targeted Computer Use aggregate runtime repair.'
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Codex config is missing: $ConfigPath"
  }

  $CuaNodeSource = Find-CuaNodeSource
  if (-not $CuaNodeSource) {
    throw 'Could not find the current AppX cua_node source.'
  }

  $runtimeBin = Repair-CuaRuntimeIfMissing $ConfigPath $CuaNodeSource
  $runtimeRoot = Split-Path -Parent $runtimeBin
  $expectedHash = Get-CuaRuntimeHash $CuaNodeSource
  if (
    (-not (Test-CuaRuntime $runtimeBin)) -or
    (-not (Test-CuaRuntimeIdentity $runtimeRoot $CuaNodeSource)) -or
    ((Split-Path -Leaf $runtimeRoot) -ne $expectedHash)
  ) {
    throw "Targeted Computer Use runtime repair did not produce the current AppX aggregate runtime: $expectedHash"
  }

  Write-Step "Targeted Computer Use runtime repair complete: $runtimeRoot"
  exit 0
}

if ($BrowserCacheOnly) {
  Write-Step 'Starting targeted Browser cache restoration and runtime-text materialization.'
  $BundledSource = Find-LatestWindowsAppsBundledSource
  if (-not $BundledSource) {
    throw 'Could not find the current registered WindowsApps bundled marketplace.'
  }

  $browserSource = Join-Path $BundledSource 'plugins\browser'
  $browserRoot = Join-Path $PluginCacheRoot 'browser'
  $chromeSource = Join-Path $BundledSource 'plugins\chrome'
  $chromeVersion = Get-PluginVersion $chromeSource
  $chromeRoot = Join-Path $PluginCacheRoot 'chrome'
  $browserOpaqueConsensus = Get-BrowserOpaqueTextConsensusPlan $browserSource $chromeRoot $chromeVersion
  if ($browserOpaqueConsensus.State -eq 'manual-required') {
    throw "Browser runtime-text materialization requires manual handling: $($browserOpaqueConsensus.ErrorSummary)"
  }
  $browserRuntimeTextExpectations = ConvertTo-BrowserOpaqueTextExpectationMap $browserOpaqueConsensus.Expectations
  $codexCliMirror = Join-Path $RepairRoot 'state\codex-cli\codex.exe'
  Assert-BrowserCacheOnlyProcessQuiescence $browserRoot $codexCliMirror
  $processGuard = New-BrowserCacheOnlyProcessGuard $browserRoot $codexCliMirror
  $browserRuntimeTextMaterializer = {
    Invoke-BrowserOpaqueTextMaterialization `
      $browserSource `
      $browserRoot `
      (Get-PluginVersion $browserSource) `
      $chromeRoot `
      $chromeVersion `
      $processGuard
  }.GetNewClosure()
  Invoke-BrowserCacheOnlyRepair `
    $browserSource `
    $browserRoot `
    -ProcessGuard $processGuard `
    -RuntimeTextExpectations $browserRuntimeTextExpectations `
    -RuntimeTextMaterializer $browserRuntimeTextMaterializer | Out-Null
  exit 0
}

if ($BrowserDiscoveryOnly) {
  Write-Step 'Starting targeted Browser discovery-link repair.'
  $BundledSource = Find-LatestWindowsAppsBundledSource
  if (-not $BundledSource) {
    throw 'Could not find the current WindowsApps bundled marketplace.'
  }

  $browserSource = Join-Path $BundledSource 'plugins\browser'
  $browserVersion = Get-PluginVersion $browserSource
  $browserRoot = Join-Path $PluginCacheRoot 'browser'
  $browserVersionDir = Join-Path $browserRoot $browserVersion
  $chromeVersion = Get-PluginVersion (Join-Path $BundledSource 'plugins\chrome')
  $browserOpaqueConsensus = Get-BrowserOpaqueTextConsensusPlan `
    $browserSource `
    (Join-Path $PluginCacheRoot 'chrome') `
    $chromeVersion
  if ($browserOpaqueConsensus.State -eq 'manual-required') {
    throw "Refusing discovery-link-only repair because Browser runtime text cannot be validated: $($browserOpaqueConsensus.ErrorSummary)"
  }
  $browserRuntimeTextExpectations = ConvertTo-BrowserOpaqueTextExpectationMap $browserOpaqueConsensus.Expectations
  $comparison = Get-BrowserCacheComparison $browserSource $browserVersionDir $browserRuntimeTextExpectations
  if ($comparison.State -ne 'browser-cache-complete') {
    throw "Refusing discovery-link-only repair because the Browser cache is not complete after runtime-text normalization: $browserVersionDir ($($comparison.State))"
  }

  Assert-DiscoveryLinkReplaceable 'Browser latest' (Join-Path $browserRoot 'latest')
  Assert-DiscoveryLinkReplaceable 'Browser metadata' (Join-Path $browserRoot '.codex-plugin')
  Ensure-PluginLatestLink 'Browser' $browserRoot $browserVersion | Out-Null
  Ensure-PluginMetadataLink 'Browser' $browserRoot $browserVersion
  if (-not (Test-PluginCache $browserRoot $browserVersion @('scripts\browser-client.mjs', 'assets\browser.png', '.codex-plugin\plugin.json'))) {
    throw 'Browser discovery links are still invalid after targeted repair.'
  }

  Write-Step "Targeted Browser discovery-link repair complete: $browserVersion"
  exit 0
}

if ($TmpRuntimeMarketplaceOnly) {
  if (Test-CodexDesktopRunning) {
    throw 'Codex Desktop is running. The tmp runtime marketplace junction can be changed only after a stable Desktop exit.'
  }

  $tmpRuntimeMarketplace = Join-Path $CodexHome '.tmp\bundled-marketplaces\openai-bundled'
  Remove-TmpRuntimeMarketplaceJunction $tmpRuntimeMarketplace $PersistentBundledMarketplaceRoot
  Write-Step 'Targeted tmp runtime marketplace ownership repair complete.'
  exit 0
}

if (Test-CodexDesktopRunning) {
  if ($AutomaticPostUpdate) {
    Write-Step 'Automatic post-update repair remains pending because Codex Desktop is active.'
    exit 30
  }
  throw 'Codex Desktop is running. Full bundled repair must wait for a stable Desktop exit so it cannot race the host-owned runtime marketplace.'
}

$automaticPackage = $null
if ($AutomaticPostUpdate) {
  $automaticPackage = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if (-not $automaticPackage) {
    throw 'automatic-post-update-manual-required: the current registered AppX package was not found.'
  }
  if ($ExpectedPackageFullName -and [string]$automaticPackage.PackageFullName -ne $ExpectedPackageFullName) {
    throw "automatic-post-update-version-changed: expected $ExpectedPackageFullName but found $($automaticPackage.PackageFullName)."
  }

  $automaticCodexCliMirror = Join-Path $RepairRoot 'state\codex-cli\codex.exe'
  $automaticRuntimeBaseRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
  if (-not (Test-AutomaticPostUpdateProcessQuiescence $PluginCacheRoot $automaticCodexCliMirror $automaticRuntimeBaseRoot)) {
    Write-Step 'Automatic post-update repair remains pending until all managed hosts have exited naturally and stayed absent for five seconds.'
    exit 30
  }
}

$managedCodexCliMirror = Join-Path $RepairRoot 'state\codex-cli\codex.exe'
$managedRuntimeBaseRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
if (-not $AutomaticPostUpdate -and -not (Test-AutomaticPostUpdateProcessQuiescence $PluginCacheRoot $managedCodexCliMirror $managedRuntimeBaseRoot)) {
  throw 'Full bundled repair must wait for all managed Browser, Chrome, and Computer Use hosts to exit naturally and stay absent for five seconds.'
}

$browserPreflightBundledSource = Find-LatestWindowsAppsBundledSource
if (-not $browserPreflightBundledSource) {
  throw 'Could not find a complete current registered AppX Browser source for full-repair preflight.'
}
$browserPreflightSource = Join-Path $browserPreflightBundledSource 'plugins\browser'
$browserPreflightVersion = Get-PluginVersion $browserPreflightSource
if (-not $browserPreflightVersion) {
  throw 'Could not determine the current registered AppX Browser version for full-repair preflight.'
}
$browserPreflightRoot = Join-Path $PluginCacheRoot 'browser'
$browserPreflightChromeVersion = Get-PluginVersion (Join-Path $browserPreflightBundledSource 'plugins\chrome')
$browserPreflightOpaqueConsensus = Get-BrowserOpaqueTextConsensusPlan `
  $browserPreflightSource `
  (Join-Path $PluginCacheRoot 'chrome') `
  $browserPreflightChromeVersion
if ($browserPreflightOpaqueConsensus.State -eq 'manual-required') {
  throw "browser-runtime-history-not-unique: $($browserPreflightOpaqueConsensus.ErrorSummary)"
}
$browserPreflightRuntimeTextExpectations = ConvertTo-BrowserOpaqueTextExpectationMap $browserPreflightOpaqueConsensus.Expectations
Assert-FullRepairBrowserCacheEligible `
  $browserPreflightSource `
  $browserPreflightRoot `
  $browserPreflightVersion `
  $browserPreflightRuntimeTextExpectations

$automaticCuaNodeSource = $null
if ($AutomaticPostUpdate) {
  $automaticCuaNodeSource = Join-Path ([string]$automaticPackage.InstallLocation) 'app\resources\cua_node'
  Assert-AutomaticPostUpdatePreflight `
    $automaticPackage `
    $browserPreflightBundledSource `
    $PluginCacheRoot `
    $CodexHome `
    $automaticCuaNodeSource `
    (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node') `
    $PersistentBundledMarketplaceRoot `
    $ConfigPath `
    $GlobalStatePath `
    $ExtensionManifest `
    $ChromeNativeHostV2Manifest
  Write-Step "Automatic post-update preflight passed for $($automaticPackage.PackageFullName)."
}

Write-Step 'Starting conservative bundled plugin repair.'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

foreach ($path in @($ConfigPath, $GlobalStatePath, $ExtensionManifest, $ChromeNativeHostV2Manifest)) {
  if (Test-Path -LiteralPath $path) {
    Copy-Item -LiteralPath $path -Destination (Join-Path $BackupDir (Split-Path -Leaf $path)) -Force
  }
}

cmd /c "reg export HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension `"$BackupDir\hkcu-native-host.reg`" /y > `"$BackupDir\hkcu-native-host-export.txt`" 2>&1"
if ($LASTEXITCODE -ne 0) {
  Add-Content -LiteralPath (Join-Path $BackupDir 'hkcu-native-host-export.txt') -Value 'HKCU native host key missing before repair.'
}

$LatestWindowsAppsBundledSource = Find-LatestWindowsAppsBundledSource
if ($LatestWindowsAppsBundledSource) {
  Ensure-OfficialBundledMarketplace $LatestWindowsAppsBundledSource | Out-Null
} else {
  throw 'Could not find the current WindowsApps bundled marketplace to refresh the persistent mirror.'
}

$BundledSource = Find-BundledSource
$CuaNodeSource = if ($AutomaticPostUpdate) { $automaticCuaNodeSource } else { Find-CuaNodeSource }
Write-Step "Bundled source: $BundledSource"
if ($CuaNodeSource) {
  Write-Step "Packaged cua_node source: $CuaNodeSource"
}

$browserAppxSource = Join-Path $LatestWindowsAppsBundledSource 'plugins\browser'
$currentChromePackage = if ($automaticPackage) {
  $automaticPackage
} else {
  Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
}
if (-not $currentChromePackage) {
  throw 'Could not resolve the current registered AppX version for the Chrome native-host runtime.'
}
$currentChromeAppVersion = [string]$currentChromePackage.Version
$browserVersion = Get-PluginVersion $browserAppxSource
$chromeVersion = Get-PluginVersion (Join-Path $BundledSource 'plugins\chrome')
$computerUseVersion = Get-PluginVersion (Join-Path $BundledSource 'plugins\computer-use')

$browserRoot = Join-Path $PluginCacheRoot 'browser'
$chromeRoot = Join-Path $PluginCacheRoot 'chrome'
$computerUseRoot = Join-Path $PluginCacheRoot 'computer-use'

$browserOpaqueConsensus = Get-BrowserOpaqueTextConsensusPlan $browserAppxSource $chromeRoot $chromeVersion
if ($browserOpaqueConsensus.State -eq 'manual-required') {
  throw "Browser runtime-text verification requires manual handling: $($browserOpaqueConsensus.ErrorSummary)"
}
$browserRuntimeTextExpectations = ConvertTo-BrowserOpaqueTextExpectationMap $browserOpaqueConsensus.Expectations
Assert-FullRepairBrowserCacheEligible `
  $browserAppxSource `
  $browserRoot `
  $browserVersion `
  $browserRuntimeTextExpectations
Ensure-PluginLatestLink 'Browser' $browserRoot $browserVersion | Out-Null
Ensure-PluginMetadataLink 'Browser' $browserRoot $browserVersion
if (
  -not (Test-PluginCache $browserRoot $browserVersion @('scripts\browser-client.mjs', 'assets\browser.png', '.codex-plugin\plugin.json'))
) {
  throw "Browser plugin discovery paths are invalid after full repair: $(Join-Path $browserRoot $browserVersion)"
}
Assert-CurrentAppxBrowserCacheComplete `
  $browserAppxSource `
  $browserRoot `
  $browserVersion `
  $browserRuntimeTextExpectations
Write-Step "Browser plugin cache complete with validated runtime text: $browserVersion"

Ensure-PluginLatestLink 'Chrome' $chromeRoot $chromeVersion | Out-Null
if (Test-PluginCache $chromeRoot $chromeVersion @('scripts\browser-client.mjs', 'extension-host\windows\x64\extension-host.exe', 'assets\google-chrome.png', '.codex-plugin\plugin.json')) {
  Write-Step "Chrome plugin cache OK: $chromeVersion"
} else {
  if (Repair-MissingPluginFiles 'chrome' $BundledSource $PluginCacheRoot $chromeVersion @('scripts\browser-client.mjs', 'extension-host\windows\x64\extension-host.exe', 'assets\google-chrome.png', '.codex-plugin\plugin.json')) {
    Write-Step "Repaired missing Chrome plugin files in place: $chromeVersion"
  }
  if (Test-PluginCache $chromeRoot $chromeVersion @('scripts\browser-client.mjs', 'extension-host\windows\x64\extension-host.exe', 'assets\google-chrome.png', '.codex-plugin\plugin.json')) {
    Write-Step "Chrome plugin cache OK after in-place repair: $chromeVersion"
  } else {
    Write-Step "Repairing Chrome plugin cache: $chromeVersion"
    Repair-PluginCache 'chrome' $BundledSource $PluginCacheRoot @('.codex-plugin', 'assets', 'docs', 'extension-host', 'scripts', 'skills') | Out-Null
  }
}
Ensure-PluginMetadataLink 'Chrome' $chromeRoot $chromeVersion

$chromeOpaqueProcessGuard = {
  param([string]$Phase, [string]$RelativePath)
  $blockers = @(Get-AutomaticPostUpdateBlockers $PluginCacheRoot $managedCodexCliMirror $managedRuntimeBaseRoot)
  if ($blockers.Count -gt 0) {
    $detail = @($blockers | ForEach-Object { "$($_.Name)#$($_.ProcessId)" }) -join '; '
    throw "Chrome opaque-text materialization process guard blocked $Phase ($RelativePath): $detail"
  }
}.GetNewClosure()
$chromeOpaqueText = Invoke-ChromeOpaqueTextMaterialization `
  (Join-Path $BundledSource 'plugins\chrome') `
  $chromeRoot `
  $chromeVersion `
  $chromeOpaqueProcessGuard
Write-Step "Chrome opaque-text runtime materialization: state=$($chromeOpaqueText.State), opaqueFiles=$($chromeOpaqueText.OpaqueFileCount)"

Ensure-PluginLatestLink 'Computer Use' $computerUseRoot $computerUseVersion | Out-Null
if (Test-PluginCache $computerUseRoot $computerUseVersion @('scripts\computer-use-client.mjs', '.codex-plugin\plugin.json')) {
  Write-Step "Computer Use plugin cache OK: $computerUseVersion"
} else {
  Write-Step "Computer Use plugin cache key files missing; repairing plugin cache only."
  Repair-PluginCache 'computer-use' $BundledSource $PluginCacheRoot @('.codex-plugin', 'assets', 'scripts', 'skills') | Out-Null
}
Ensure-PluginMetadataLink 'Computer Use' $computerUseRoot $computerUseVersion

$runtimeBin = Repair-CuaRuntimeIfMissing $ConfigPath $CuaNodeSource -DeferConfigPathValidation
Ensure-NodeReplConfiguration $ConfigPath $runtimeBin $browserRoot $browserVersion $chromeRoot $chromeVersion
$runtimeBin = Repair-CuaRuntimeIfMissing $ConfigPath $CuaNodeSource

$extensionIdentity = Get-ChromiumNativeHostIdentity $chromeSource
$extensionIds = @($extensionIdentity.ExtensionIds)
$hostName = [string]$extensionIdentity.HostName

$extensionHostExe = Join-Path $chromeRoot "$chromeVersion\extension-host\windows\x64\extension-host.exe"
$extensionHostLatest = Join-Path $chromeRoot 'latest\extension-host\windows\x64\extension-host.exe'
if (-not (Test-Path -LiteralPath $extensionHostExe)) {
  throw "Missing extension-host.exe: $extensionHostExe"
}

$manifestNeedsRepair = $true
if (Test-Path -LiteralPath $ExtensionManifest) {
  try {
    $manifest = Get-Content -LiteralPath $ExtensionManifest -Raw | ConvertFrom-Json
    $manifestNeedsRepair = -not (
      $manifest.name -eq $hostName -and
      $manifest.type -eq 'stdio' -and
      (@($extensionHostExe, $extensionHostLatest) -contains [string]$manifest.path) -and
      (Test-ExactStringArray `
        @($manifest.allowed_origins | ForEach-Object { [string]$_ }) `
        @(Get-ChromiumNativeHostExpectedOrigins $extensionIdentity))
    )
  } catch {
    $manifestNeedsRepair = $true
  }
}

if ($manifestNeedsRepair) {
  Write-Step 'Repairing Chrome native host manifest.'
  $manifestObject = [ordered]@{
    allowed_origins = @(Get-ChromiumNativeHostExpectedOrigins $extensionIdentity)
    description = 'Codex chrome native messaging host'
    name = $hostName
    path = $extensionHostLatest
    type = 'stdio'
  }
  New-Utf8NoBomFile $ExtensionManifest ($manifestObject | ConvertTo-Json -Depth 10)
} else {
  Write-Step 'Chrome native host manifest OK.'
}

$regValue = $null
try {
  $regValue = (Get-ItemProperty -LiteralPath "Registry::HKEY_CURRENT_USER\Software\Google\Chrome\NativeMessagingHosts\$hostName" -Name '(default)' -ErrorAction Stop).'(default)'
} catch {
  $regValue = $null
}

if ($regValue -ne $ExtensionManifest) {
  Write-Step 'Repairing Chrome native host HKCU registry mapping.'
  cmd /c "reg add HKCU\Software\Google\Chrome\NativeMessagingHosts\$hostName /ve /t REG_SZ /d `"$ExtensionManifest`" /f" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to add Chrome native host registry key.'
  }
} else {
  Write-Step 'Chrome native host HKCU registry mapping OK.'
}

$currentCodexCliSource = Find-CurrentCodexCli
$codexCliForChrome = Join-Path $RepairRoot 'state\codex-cli\codex.exe'
$resourcesPathForChrome = if ($currentCodexCliSource) {
  Split-Path -Parent $currentCodexCliSource
} else {
  Split-Path -Parent $CuaNodeSource
}
Ensure-ChromeNativeHostV2Manifest `
  $CodexHome `
  $extensionIds `
  $hostName `
  $currentChromeAppVersion `
  $chromeVersion `
  (Join-Path $chromeRoot "$chromeVersion\scripts\browser-client.mjs") `
  $extensionHostExe `
  $codexCliForChrome `
  (Join-Path $runtimeBin 'node.exe') `
  (Join-Path $runtimeBin 'node_modules') `
  (Join-Path $runtimeBin 'node_repl.exe') `
  $resourcesPathForChrome | Out-Null

foreach ($plugin in @('browser', 'chrome', 'computer-use')) {
  Ensure-PluginEnabled $ConfigPath $plugin
}
Write-Step 'Plugin enablement sections are present.'

Remove-LegacyBundledRepairTasks
Ensure-BundledHealthCheckTask

if ($AutomaticPostUpdate) {
  $packageAfterRepair = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if (-not $packageAfterRepair -or [string]$packageAfterRepair.PackageFullName -ne [string]$automaticPackage.PackageFullName) {
    throw 'automatic-post-update-version-changed: the registered AppX package changed during repair; verification and state promotion were refused.'
  }
}

$stateLines = @(
  "BackupDir=$BackupDir",
  "BundledSource=$BundledSource",
  "CuaNodeSource=$CuaNodeSource",
  "BrowserVersion=$browserVersion",
  "ChromeVersion=$chromeVersion",
  "ComputerUseVersion=$computerUseVersion",
  "RuntimeBin=$runtimeBin",
  "ExtensionManifest=$ExtensionManifest",
  "ExtensionHostExe=$extensionHostExe",
  "HealthCheckTask=CodexDesktopBundledHealthCheck",
  "PostUpdateTask=CodexDesktopBundledPostUpdateRepair"
)
New-Utf8NoBomFile (Join-Path $BackupDir 'repair-summary.txt') ($stateLines -join "`r`n")
Write-Step "Backup: $BackupDir"
Write-Step 'Repair pass complete. Run Verify-CodexDesktopBundled.ps1 next; restart is not part of the default path.'
