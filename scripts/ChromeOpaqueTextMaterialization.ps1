function Test-ChromeOpaqueTextRuntimeExtension([string]$Path) {
  return ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -in @('.cjs', '.js', '.json', '.mjs'))
}

function Test-ChromeOpaqueTextRuntimeFile([string]$Path) {
  try {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ([System.IO.Path]::GetExtension($Path).Equals('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
      $null = $text | ConvertFrom-Json -ErrorAction Stop
    }
    return $true
  } catch {
    return $false
  }
}

function Test-ChromeOpaqueTextVersionDirectory([System.IO.DirectoryInfo]$Item, [string]$CurrentVersion) {
  if (
    -not $Item -or
    ([string]$Item.Name -eq $CurrentVersion) -or
    (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or
    -not ([regex]::IsMatch([string]$Item.Name, '^\d+(\.\d+){2,3}$'))
  ) {
    return $false
  }

  $parsed = $null
  return [version]::TryParse([string]$Item.Name, [ref]$parsed)
}

function Get-ChromeOpaqueTextRuntimeFiles([string]$SourceRoot) {
  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    throw "Chrome source root is missing: $SourceRoot"
  }

  $sourceFull = (Get-Item -LiteralPath $SourceRoot -Force).FullName.TrimEnd('\')
  $opaque = New-Object System.Collections.Generic.List[object]
  foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force)) {
    if (-not (Test-ChromeOpaqueTextRuntimeExtension $file.FullName)) {
      continue
    }
    if (-not (Test-ChromeOpaqueTextRuntimeFile $file.FullName)) {
      $opaque.Add([pscustomobject]@{
          RelativePath = $file.FullName.Substring($sourceFull.Length).TrimStart('\')
          Length = [int64]$file.Length
        })
    }
  }

  return @($opaque.ToArray() | Sort-Object RelativePath)
}

function Get-ChromeOpaqueTextConsensus(
  [string]$ChromeRoot,
  [string]$CurrentVersion,
  [string]$RelativePath,
  [int64]$ExpectedLength
) {
  $candidates = New-Object System.Collections.Generic.List[object]
  foreach ($directory in @(Get-ChildItem -LiteralPath $ChromeRoot -Directory -Force -ErrorAction SilentlyContinue)) {
    if (-not (Test-ChromeOpaqueTextVersionDirectory $directory $CurrentVersion)) {
      continue
    }

    $candidatePath = Join-Path $directory.FullName $RelativePath
    $candidate = Get-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue
    if (
      -not $candidate -or
      $candidate.PSIsContainer -or
      (($candidate.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or
      ([int64]$candidate.Length -ne $ExpectedLength) -or
      -not (Test-ChromeOpaqueTextRuntimeFile $candidate.FullName)
    ) {
      continue
    }

    $candidates.Add([pscustomobject]@{
        Version = [string]$directory.Name
        Path = $candidate.FullName
        Hash = (Get-FileHash -LiteralPath $candidate.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
      })
  }

  $groups = @($candidates.ToArray() | Group-Object Hash | Sort-Object Count -Descending)
  # The old repair path accepted the newest readable historical donor. Requiring
  # two matching donors made a normal AppX update stop for minutes without
  # repairing anything, so a single length-matched readable donor is enough.
  if ($groups.Count -eq 0) {
    return [pscustomobject]@{
      State = 'no-unique-history-consensus'
      CandidateCount = $candidates.Count
      DistinctHashCount = $groups.Count
      ExpectedHash = $null
      DonorPath = $null
      DonorVersion = $null
    }
  }

  $donor = @($candidates | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)[0]
  return [pscustomobject]@{
    State = 'consensus'
    CandidateCount = $candidates.Count
    DistinctHashCount = $groups.Count
    ExpectedHash = [string]$donor.Hash
    DonorPath = [string]$donor.Path
    DonorVersion = [string]$donor.Version
  }
}

function Get-ChromeOpaqueTextMaterializationPlan(
  [string]$ChromeSourceRoot,
  [string]$ChromeRoot,
  [string]$CurrentVersion
) {
  $opaqueFiles = @(Get-ChromeOpaqueTextRuntimeFiles $ChromeSourceRoot)
  if ($opaqueFiles.Count -eq 0) {
    return [pscustomobject]@{
      State = 'not-required'
      OpaqueFileCount = 0
      Repairs = @()
      ErrorSummary = $null
    }
  }

  $versionDirectory = Join-Path $ChromeRoot $CurrentVersion
  $versionItem = Get-Item -LiteralPath $versionDirectory -Force -ErrorAction SilentlyContinue
  if (
    -not $versionItem -or
    -not $versionItem.PSIsContainer -or
    (($versionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  ) {
    return [pscustomobject]@{
      State = 'manual-required'
      OpaqueFileCount = $opaqueFiles.Count
      Repairs = @()
      ErrorSummary = 'current-chrome-concrete-not-plain-directory'
    }
  }

  $repairs = New-Object System.Collections.Generic.List[object]
  foreach ($opaque in $opaqueFiles) {
    $targetPath = Join-Path $versionDirectory $opaque.RelativePath
    $target = Get-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
    if (
      -not $target -or
      $target.PSIsContainer -or
      (($target.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or
      ([int64]$target.Length -ne [int64]$opaque.Length)
    ) {
      return [pscustomobject]@{
        State = 'manual-required'
        OpaqueFileCount = $opaqueFiles.Count
        Repairs = @()
        ErrorSummary = "current-chrome-runtime-file-conflict:$($opaque.RelativePath)"
      }
    }

    $consensus = Get-ChromeOpaqueTextConsensus $ChromeRoot $CurrentVersion $opaque.RelativePath $opaque.Length
    if ($consensus.State -ne 'consensus') {
      return [pscustomobject]@{
        State = 'manual-required'
        OpaqueFileCount = $opaqueFiles.Count
        Repairs = @()
        ErrorSummary = "chrome-runtime-history-not-unique:$($opaque.RelativePath)"
      }
    }

    if (Test-ChromeOpaqueTextRuntimeFile $target.FullName) {
      $targetHash = (Get-FileHash -LiteralPath $target.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
      if ($targetHash -ne $consensus.ExpectedHash) {
        return [pscustomobject]@{
          State = 'manual-required'
          OpaqueFileCount = $opaqueFiles.Count
          Repairs = @()
          ErrorSummary = "current-chrome-runtime-hash-conflict:$($opaque.RelativePath)"
        }
      }
      continue
    }

    $repairs.Add([pscustomobject]@{
        RelativePath = $opaque.RelativePath
        Length = [int64]$opaque.Length
        ExpectedHash = [string]$consensus.ExpectedHash
        DonorPath = [string]$consensus.DonorPath
        DonorVersion = [string]$consensus.DonorVersion
        TargetPath = $target.FullName
      })
  }

  return [pscustomobject]@{
    State = if ($repairs.Count -eq 0) { 'complete' } else { 'repairable' }
    OpaqueFileCount = $opaqueFiles.Count
    Repairs = @($repairs.ToArray())
    ErrorSummary = $null
  }
}

function Invoke-ChromeOpaqueTextMaterialization(
  [string]$ChromeSourceRoot,
  [string]$ChromeRoot,
  [string]$CurrentVersion,
  [scriptblock]$ProcessGuard
) {
  if (-not $ProcessGuard) {
    throw 'Chrome opaque-text materialization requires a managed-process guard.'
  }

  $plan = Get-ChromeOpaqueTextMaterializationPlan $ChromeSourceRoot $ChromeRoot $CurrentVersion
  if ($plan.State -eq 'not-required' -or $plan.State -eq 'complete') {
    return $plan
  }
  if ($plan.State -ne 'repairable') {
    throw "Chrome opaque-text materialization requires manual handling: $($plan.ErrorSummary)"
  }

  & $ProcessGuard 'before-staging' ''
  $stageRoot = Join-Path $ChromeRoot ('.chrome-opaque-text-stage-' + [guid]::NewGuid().ToString('N'))
  $chromeRootFull = (Get-Item -LiteralPath $ChromeRoot -Force).FullName.TrimEnd('\') + '\'
  $stageFull = [System.IO.Path]::GetFullPath($stageRoot)
  if (-not $stageFull.StartsWith($chromeRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing Chrome opaque-text staging outside the Chrome cache root.'
  }

  try {
    [System.IO.Directory]::CreateDirectory($stageFull) | Out-Null
    foreach ($repair in @($plan.Repairs)) {
      & $ProcessGuard 'before-stage-file' $repair.RelativePath
      $stagePath = Join-Path $stageFull (Join-Path 'replacement' $repair.RelativePath)
      [System.IO.Directory]::CreateDirectory((Split-Path -Parent $stagePath)) | Out-Null
      [System.IO.File]::WriteAllBytes($stagePath, [System.IO.File]::ReadAllBytes($repair.DonorPath))
      if (
        -not (Test-ChromeOpaqueTextRuntimeFile $stagePath) -or
        ([int64](Get-Item -LiteralPath $stagePath).Length -ne [int64]$repair.Length) -or
        ((Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash.ToUpperInvariant() -ne $repair.ExpectedHash)
      ) {
        throw "Chrome opaque-text staging validation failed: $($repair.RelativePath)"
      }
    }

    & $ProcessGuard 'before-commit' ''
    foreach ($repair in @($plan.Repairs)) {
      & $ProcessGuard 'before-commit-file' $repair.RelativePath
      $stagePath = Join-Path $stageFull (Join-Path 'replacement' $repair.RelativePath)
      $backupPath = Join-Path $stageFull (Join-Path 'backup' $repair.RelativePath)
      [System.IO.Directory]::CreateDirectory((Split-Path -Parent $backupPath)) | Out-Null
      [System.IO.File]::Replace($stagePath, $repair.TargetPath, $backupPath)
      if (
        -not (Test-ChromeOpaqueTextRuntimeFile $repair.TargetPath) -or
        ([int64](Get-Item -LiteralPath $repair.TargetPath).Length -ne [int64]$repair.Length) -or
        ((Get-FileHash -LiteralPath $repair.TargetPath -Algorithm SHA256).Hash.ToUpperInvariant() -ne $repair.ExpectedHash)
      ) {
        throw "Chrome opaque-text commit validation failed: $($repair.RelativePath)"
      }
    }
  } finally {
    if ($stageFull.StartsWith($chromeRootFull, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $stageFull)) {
      Remove-Item -LiteralPath $stageFull -Recurse -Force
    }
  }

  $after = Get-ChromeOpaqueTextMaterializationPlan $ChromeSourceRoot $ChromeRoot $CurrentVersion
  if ($after.State -ne 'complete') {
    throw "Chrome opaque-text materialization did not converge: $($after.ErrorSummary)"
  }
  return $after
}

function Get-BrowserOpaqueTextConsensusPlan(
  [string]$BrowserSourceRoot,
  [string]$ChromeRoot,
  [string]$ChromeCurrentVersion
) {
  $opaqueFiles = @(Get-ChromeOpaqueTextRuntimeFiles $BrowserSourceRoot)
  if ($opaqueFiles.Count -eq 0) {
    return [pscustomobject]@{
      State = 'not-required'
      OpaqueFileCount = 0
      Expectations = @()
      ErrorSummary = $null
    }
  }

  $expectations = New-Object System.Collections.Generic.List[object]
  foreach ($opaque in $opaqueFiles) {
    $consensus = Get-ChromeOpaqueTextConsensus `
      $ChromeRoot `
      $ChromeCurrentVersion `
      $opaque.RelativePath `
      $opaque.Length
    if ($consensus.State -ne 'consensus') {
      return [pscustomobject]@{
        State = 'manual-required'
        OpaqueFileCount = $opaqueFiles.Count
        Expectations = @()
        ErrorSummary = "browser-runtime-history-not-unique:$($opaque.RelativePath)"
      }
    }

    $sourcePath = Join-Path $BrowserSourceRoot $opaque.RelativePath
    $expectations.Add([pscustomobject]@{
        RelativePath = $opaque.RelativePath
        Length = [int64]$opaque.Length
        SourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToUpperInvariant()
        ExpectedHash = [string]$consensus.ExpectedHash
        DonorPath = [string]$consensus.DonorPath
        DonorVersion = [string]$consensus.DonorVersion
        CandidateCount = [int]$consensus.CandidateCount
      })
  }

  return [pscustomobject]@{
    State = 'consensus'
    OpaqueFileCount = $opaqueFiles.Count
    Expectations = @($expectations.ToArray())
    ErrorSummary = $null
  }
}

function ConvertTo-BrowserOpaqueTextExpectationMap([object[]]$Expectations) {
  $map = @{}
  foreach ($expectation in @($Expectations)) {
    $relativePath = [string]$expectation.RelativePath
    if ([string]::IsNullOrWhiteSpace($relativePath) -or $map.ContainsKey($relativePath)) {
      throw "Invalid or duplicate Browser opaque-text expectation: $relativePath"
    }
    $map[$relativePath] = $expectation
  }
  return $map
}

function Get-BrowserOpaqueTextMaterializationPlan(
  [string]$BrowserSourceRoot,
  [string]$BrowserRoot,
  [string]$BrowserCurrentVersion,
  [string]$ChromeRoot,
  [string]$ChromeCurrentVersion
) {
  $consensusPlan = Get-BrowserOpaqueTextConsensusPlan `
    $BrowserSourceRoot `
    $ChromeRoot `
    $ChromeCurrentVersion
  if ($consensusPlan.State -eq 'not-required') {
    return [pscustomobject]@{
      State = 'not-required'
      OpaqueFileCount = 0
      Repairs = @()
      Expectations = @()
      ErrorSummary = $null
    }
  }
  if ($consensusPlan.State -ne 'consensus') {
    return [pscustomobject]@{
      State = 'manual-required'
      OpaqueFileCount = $consensusPlan.OpaqueFileCount
      Repairs = @()
      Expectations = @()
      ErrorSummary = $consensusPlan.ErrorSummary
    }
  }

  $versionDirectory = Join-Path $BrowserRoot $BrowserCurrentVersion
  $versionItem = Get-Item -LiteralPath $versionDirectory -Force -ErrorAction SilentlyContinue
  if (
    -not $versionItem -or
    -not $versionItem.PSIsContainer -or
    (($versionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  ) {
    return [pscustomobject]@{
      State = 'manual-required'
      OpaqueFileCount = $consensusPlan.OpaqueFileCount
      Repairs = @()
      Expectations = @($consensusPlan.Expectations)
      ErrorSummary = 'current-browser-concrete-not-plain-directory'
    }
  }

  $repairs = New-Object System.Collections.Generic.List[object]
  foreach ($expectation in @($consensusPlan.Expectations)) {
    $targetPath = Join-Path $versionDirectory $expectation.RelativePath
    $target = Get-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
    if (
      -not $target -or
      $target.PSIsContainer -or
      (($target.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or
      ([int64]$target.Length -ne [int64]$expectation.Length)
    ) {
      return [pscustomobject]@{
        State = 'manual-required'
        OpaqueFileCount = $consensusPlan.OpaqueFileCount
        Repairs = @()
        Expectations = @($consensusPlan.Expectations)
        ErrorSummary = "current-browser-runtime-file-conflict:$($expectation.RelativePath)"
      }
    }

    $targetHash = (Get-FileHash -LiteralPath $target.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    if (
      $targetHash -eq $expectation.ExpectedHash -and
      (Test-ChromeOpaqueTextRuntimeFile $target.FullName)
    ) {
      continue
    }
    if (
      $targetHash -ne $expectation.SourceHash -or
      (Test-ChromeOpaqueTextRuntimeFile $target.FullName)
    ) {
      return [pscustomobject]@{
        State = 'manual-required'
        OpaqueFileCount = $consensusPlan.OpaqueFileCount
        Repairs = @()
        Expectations = @($consensusPlan.Expectations)
        ErrorSummary = "current-browser-runtime-hash-conflict:$($expectation.RelativePath)"
      }
    }

    $repairs.Add([pscustomobject]@{
        RelativePath = $expectation.RelativePath
        Length = [int64]$expectation.Length
        SourceHash = [string]$expectation.SourceHash
        ExpectedHash = [string]$expectation.ExpectedHash
        DonorPath = [string]$expectation.DonorPath
        DonorVersion = [string]$expectation.DonorVersion
        TargetPath = $target.FullName
      })
  }

  return [pscustomobject]@{
    State = if ($repairs.Count -eq 0) { 'complete' } else { 'repairable' }
    OpaqueFileCount = $consensusPlan.OpaqueFileCount
    Repairs = @($repairs.ToArray())
    Expectations = @($consensusPlan.Expectations)
    ErrorSummary = $null
  }
}

function Invoke-BrowserOpaqueTextMaterialization(
  [string]$BrowserSourceRoot,
  [string]$BrowserRoot,
  [string]$BrowserCurrentVersion,
  [string]$ChromeRoot,
  [string]$ChromeCurrentVersion,
  [scriptblock]$ProcessGuard
) {
  if (-not $ProcessGuard) {
    throw 'Browser opaque-text materialization requires a managed-process guard.'
  }

  $plan = Get-BrowserOpaqueTextMaterializationPlan `
    $BrowserSourceRoot `
    $BrowserRoot `
    $BrowserCurrentVersion `
    $ChromeRoot `
    $ChromeCurrentVersion
  if ($plan.State -eq 'not-required' -or $plan.State -eq 'complete') {
    return $plan
  }
  if ($plan.State -ne 'repairable') {
    throw "Browser opaque-text materialization requires manual handling: $($plan.ErrorSummary)"
  }

  & $ProcessGuard 'before-browser-opaque-staging' ''
  $stageRoot = Join-Path $BrowserRoot ('.browser-opaque-text-stage-' + [guid]::NewGuid().ToString('N'))
  $browserRootFull = (Get-Item -LiteralPath $BrowserRoot -Force).FullName.TrimEnd('\') + '\'
  $stageFull = [System.IO.Path]::GetFullPath($stageRoot)
  if (-not $stageFull.StartsWith($browserRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing Browser opaque-text staging outside the Browser cache root.'
  }

  $committed = New-Object System.Collections.Generic.List[object]
  $preserveStage = $false
  try {
    [System.IO.Directory]::CreateDirectory($stageFull) | Out-Null
    foreach ($repair in @($plan.Repairs)) {
      & $ProcessGuard 'before-browser-opaque-stage-file' $repair.RelativePath
      $stagePath = Join-Path $stageFull (Join-Path 'replacement' $repair.RelativePath)
      [System.IO.Directory]::CreateDirectory((Split-Path -Parent $stagePath)) | Out-Null
      [System.IO.File]::WriteAllBytes($stagePath, [System.IO.File]::ReadAllBytes($repair.DonorPath))
      if (
        -not (Test-ChromeOpaqueTextRuntimeFile $stagePath) -or
        ([int64](Get-Item -LiteralPath $stagePath).Length -ne [int64]$repair.Length) -or
        ((Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash.ToUpperInvariant() -ne $repair.ExpectedHash)
      ) {
        throw "Browser opaque-text staging validation failed: $($repair.RelativePath)"
      }
    }

    & $ProcessGuard 'before-browser-opaque-commit' ''
    foreach ($repair in @($plan.Repairs)) {
      & $ProcessGuard 'before-browser-opaque-commit-file' $repair.RelativePath
      $stagePath = Join-Path $stageFull (Join-Path 'replacement' $repair.RelativePath)
      $backupPath = Join-Path $stageFull (Join-Path 'backup' $repair.RelativePath)
      [System.IO.Directory]::CreateDirectory((Split-Path -Parent $backupPath)) | Out-Null
      [System.IO.File]::Replace($stagePath, $repair.TargetPath, $backupPath)
      $committed.Add([pscustomobject]@{
          RelativePath = $repair.RelativePath
          TargetPath = $repair.TargetPath
          BackupPath = $backupPath
          ExpectedHash = $repair.ExpectedHash
        })
      if (
        -not (Test-ChromeOpaqueTextRuntimeFile $repair.TargetPath) -or
        ([int64](Get-Item -LiteralPath $repair.TargetPath).Length -ne [int64]$repair.Length) -or
        ((Get-FileHash -LiteralPath $repair.TargetPath -Algorithm SHA256).Hash.ToUpperInvariant() -ne $repair.ExpectedHash)
      ) {
        throw "Browser opaque-text commit validation failed: $($repair.RelativePath)"
      }
    }

    $after = Get-BrowserOpaqueTextMaterializationPlan `
      $BrowserSourceRoot `
      $BrowserRoot `
      $BrowserCurrentVersion `
      $ChromeRoot `
      $ChromeCurrentVersion
    if ($after.State -ne 'complete') {
      throw "Browser opaque-text materialization did not converge: $($after.ErrorSummary)"
    }
    return $after
  } catch {
    $originalError = $_
    $guardFailure = $originalError.Exception.Message -like 'BrowserCacheOnly process guard blocked*'
    if (-not $guardFailure -and $committed.Count -gt 0) {
      $rollbackErrors = New-Object System.Collections.Generic.List[string]
      foreach ($entry in @($committed.ToArray() | Sort-Object RelativePath -Descending)) {
        try {
          $currentHash = (Get-FileHash -LiteralPath $entry.TargetPath -Algorithm SHA256).Hash.ToUpperInvariant()
          if ($currentHash -ne $entry.ExpectedHash -or -not (Test-Path -LiteralPath $entry.BackupPath -PathType Leaf)) {
            throw 'target or backup ownership could not be confirmed'
          }
          $rollbackBackup = Join-Path $stageFull ('rollback-' + [guid]::NewGuid().ToString('N') + '.bak')
          [System.IO.File]::Replace($entry.BackupPath, $entry.TargetPath, $rollbackBackup)
          if (Test-Path -LiteralPath $rollbackBackup -PathType Leaf) {
            Remove-Item -LiteralPath $rollbackBackup -Force
          }
        } catch {
          $rollbackErrors.Add("$($entry.RelativePath): $($_.Exception.Message)")
        }
      }
      if ($rollbackErrors.Count -gt 0) {
        $preserveStage = $true
        throw "$($originalError.Exception.Message) Browser opaque-text rollback failed; staging preserved at ${stageFull}: $($rollbackErrors -join '; ')"
      }
    }
    throw $originalError
  } finally {
    if (-not $preserveStage -and (Test-Path -LiteralPath $stageFull)) {
      Remove-Item -LiteralPath $stageFull -Recurse -Force
    }
  }
}
