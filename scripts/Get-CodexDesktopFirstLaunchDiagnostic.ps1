param(
  [ValidateRange(250, 5000)]
  [int]$SampleMilliseconds = 1500,
  [string]$LogPath = '',
  [switch]$Json,
  [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestRegexIndex([string]$Text, [string]$Pattern) {
  if ([string]::IsNullOrEmpty($Text)) { return -1 }
  $matches = [regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($matches.Count -eq 0) { return -1 }
  return $matches[$matches.Count - 1].Index
}

function Get-UpdatePolicyPendingFromText([string]$Text) {
  $waitIndex = Get-LatestRegexIndex $Text 'in_app_updates_policy_wait_started'
  if ($waitIndex -lt 0) { return $false }
  $terminalIndex = Get-LatestRegexIndex $Text '(in_app_updates_policy_timeout|window ready-to-show|startup critical-path phases completed|rendererWindowVisible\s*=\s*true)'
  return $waitIndex -gt $terminalIndex
}

function Get-FirstLaunchClassification(
  [bool]$PackageAvailable,
  [int]$MainProcessCount,
  [int]$RendererCount,
  [int]$WindowCount,
  [int]$MainAgeSeconds,
  [bool]$StagingChanged,
  [bool]$StagingRecent,
  [bool]$UpdatePolicyPending
) {
  if (-not $PackageAvailable) {
    return [pscustomobject]@{ Classification = 'appx-missing'; Action = 'manual-required' }
  }
  if ($MainProcessCount -eq 0) {
    return [pscustomobject]@{ Classification = 'not-running'; Action = 'launch-once' }
  }
  if ($WindowCount -gt 0) {
    return [pscustomobject]@{ Classification = 'window-ready'; Action = 'none' }
  }
  if ($RendererCount -gt 0) {
    return [pscustomobject]@{ Classification = 'renderer-ready'; Action = 'not-first-launch-gate' }
  }
  if ($StagingChanged -or $StagingRecent) {
    return [pscustomobject]@{ Classification = 'runtime-materializing'; Action = 'leave-current-launch-running' }
  }
  if ($UpdatePolicyPending) {
    return [pscustomobject]@{ Classification = 'update-policy-wait'; Action = 'leave-current-launch-running' }
  }
  if ($MainAgeSeconds -ge 0 -and $MainAgeSeconds -lt 15) {
    return [pscustomobject]@{ Classification = 'starting'; Action = 'leave-current-launch-running' }
  }
  return [pscustomobject]@{ Classification = 'headless-unknown'; Action = 'manual-required' }
}

function Get-StagingSnapshot([string]$RuntimeRoot) {
  $directories = @(
    Get-ChildItem -LiteralPath $RuntimeRoot -Directory -Filter '.staging-*' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTimeUtc -Descending
  )
  if ($directories.Count -eq 0) {
    return [pscustomobject]@{ Count = 0; FileCount = 0; Bytes = [int64]0; LatestWriteUtc = $null }
  }

  $latest = $directories[0]
  $files = @(Get-ChildItem -LiteralPath $latest.FullName -File -Recurse -ErrorAction SilentlyContinue)
  $bytes = [int64]0
  $latestWriteUtc = $latest.LastWriteTimeUtc
  foreach ($file in $files) {
    $bytes += [int64]$file.Length
    if ($file.LastWriteTimeUtc -gt $latestWriteUtc) { $latestWriteUtc = $file.LastWriteTimeUtc }
  }
  return [pscustomobject]@{
    Count = $directories.Count
    FileCount = $files.Count
    Bytes = $bytes
    LatestWriteUtc = $latestWriteUtc
  }
}

function Read-FileTail([string]$Path, [int]$MaximumBytes = 524288) {
  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
  try {
    if ($stream.Length -gt $MaximumBytes) { $stream.Seek(-$MaximumBytes, [System.IO.SeekOrigin]::End) | Out-Null }
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
  } finally {
    $stream.Dispose()
  }
}

function Get-DesktopLogSignal([string]$ExplicitPath, [object[]]$ProcessRows) {
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($ExplicitPath) { $candidates.Add($ExplicitPath) }
  foreach ($candidate in @(
      (Join-Path $env:APPDATA 'Codex\logs'),
      (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\logs'),
      (Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalState\logs')
    )) {
    if (-not $candidates.Contains($candidate)) { $candidates.Add($candidate) }
  }

  foreach ($row in @($ProcessRows)) {
    $commandLine = [string]$row.CommandLine
    $match = [regex]::Match($commandLine, '--user-data-dir=(?:"([^"]+)"|(\S+))', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
      $userDataRoot = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
      foreach ($candidate in @((Join-Path $userDataRoot 'logs'), (Join-Path (Split-Path -Parent $userDataRoot) 'logs'))) {
        if (-not $candidates.Contains($candidate)) { $candidates.Add($candidate) }
      }
    }
  }

  $files = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $files.Add((Get-Item -LiteralPath $candidate))
    } elseif (Test-Path -LiteralPath $candidate -PathType Container) {
      foreach ($file in @(Get-ChildItem -LiteralPath $candidate -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.log', '.jsonl', '.txt') })) {
        $files.Add($file)
      }
    }
  }

  $text = ''
  foreach ($file in @($files.ToArray() | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3)) {
    try { $text += "`n" + (Read-FileTail $file.FullName) } catch { }
  }
  return [pscustomobject]@{
    Found = $files.Count -gt 0
    UpdatePolicyPending = Get-UpdatePolicyPendingFromText $text
  }
}

if ($LibraryOnly) { return }

try {
  $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if (-not $package) {
    $classification = Get-FirstLaunchClassification $false 0 0 0 -1 $false $false $false
    $result = [pscustomobject]@{
      classification = $classification.Classification
      action = $classification.Action
      packageVersion = $null
      mainProcesses = 0
      renderers = 0
      windows = 0
      stagingDirectories = 0
      stagingChanged = $false
      updatePolicyPending = $false
      logSignalAvailable = $false
      sampledMilliseconds = 0
      writes = 0
      processesTouched = 0
    }
  } else {
    $packageAppRoot = [System.IO.Path]::GetFullPath((Join-Path ([string]$package.InstallLocation) 'app')).TrimEnd('\') + '\'
    $chatGptRows = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and [System.IO.Path]::GetFullPath([string]$_.ExecutablePath).StartsWith($packageAppRoot, [System.StringComparison]::OrdinalIgnoreCase)
      })
    $mainRows = @($chatGptRows | Where-Object { [string]$_.CommandLine -notmatch '(?i)(^|\s)--type=' })
    $rendererRows = @($chatGptRows | Where-Object { [string]$_.CommandLine -match '(?i)(^|\s)--type=renderer(?:\s|$)' })
    $processHandles = @{}
    foreach ($process in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)) {
      $processHandles[[int]$process.Id] = [int64]$process.MainWindowHandle
    }
    $windowCount = @($chatGptRows | Where-Object { $processHandles.ContainsKey([int]$_.ProcessId) -and $processHandles[[int]$_.ProcessId] -ne 0 }).Count
    $mainAgeSeconds = -1
    if ($mainRows.Count -gt 0) {
      $mainStart = @(Get-Process -Id @($mainRows.ProcessId) -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1).StartTime
      if ($mainStart) { $mainAgeSeconds = [int][Math]::Floor(((Get-Date) - $mainStart).TotalSeconds) }
    }

    $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
    $before = Get-StagingSnapshot $runtimeRoot
    if ($mainRows.Count -gt 0 -and $rendererRows.Count -eq 0 -and $before.Count -gt 0) {
      Start-Sleep -Milliseconds $SampleMilliseconds
    }
    $after = Get-StagingSnapshot $runtimeRoot
    $stagingChanged = ($before.Bytes -ne $after.Bytes) -or ($before.FileCount -ne $after.FileCount)
    $stagingRecent = $false
    if ($after.LatestWriteUtc) { $stagingRecent = (([datetime]::UtcNow - [datetime]$after.LatestWriteUtc).TotalSeconds -le 60) }
    $logSignal = Get-DesktopLogSignal $LogPath $chatGptRows
    $classification = Get-FirstLaunchClassification `
      $true `
      $mainRows.Count `
      $rendererRows.Count `
      $windowCount `
      $mainAgeSeconds `
      $stagingChanged `
      $stagingRecent `
      ([bool]$logSignal.UpdatePolicyPending)
    $result = [pscustomobject]@{
      classification = $classification.Classification
      action = $classification.Action
      packageVersion = [string]$package.Version
      mainProcesses = $mainRows.Count
      renderers = $rendererRows.Count
      windows = $windowCount
      stagingDirectories = $after.Count
      stagingChanged = $stagingChanged
      updatePolicyPending = [bool]$logSignal.UpdatePolicyPending
      logSignalAvailable = [bool]$logSignal.Found
      sampledMilliseconds = if ($mainRows.Count -gt 0 -and $rendererRows.Count -eq 0 -and $before.Count -gt 0) { $SampleMilliseconds } else { 0 }
      writes = 0
      processesTouched = 0
    }
  }

  if ($Json) {
    $result | ConvertTo-Json -Compress
  } else {
    Write-Host "[codex-first-launch] classification=$($result.classification); action=$($result.action)"
    Write-Host "[codex-first-launch] package=$($result.packageVersion); main=$($result.mainProcesses); renderers=$($result.renderers); windows=$($result.windows)"
    Write-Host "[codex-first-launch] staging=$($result.stagingDirectories); stagingChanged=$($result.stagingChanged); updatePolicyPending=$($result.updatePolicyPending); logSignalAvailable=$($result.logSignalAvailable)"
    Write-Host '[codex-first-launch] read-only diagnostic complete; writes=0; processesTouched=0.'
  }
  exit 0
} catch {
  Write-Error "First-launch diagnostic failed without changing state: $($_.Exception.Message)"
  exit 1
}
