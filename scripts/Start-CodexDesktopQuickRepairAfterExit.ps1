param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Auto','CliMirrorOnly','RuntimeOnly','BrowserDiscoveryOnly','BrowserCacheOnly','BrowserNativeHostOnly','EdgeNativeHostOnly','ChromeAppxBootstrapOnly','ChromeAppServerBootstrapOnly','ComputerUseCacheOnly','TmpRuntimeMarketplaceOnly','Verify')]
  [string]$Route,
  [switch]$Arm,
  [switch]$Run,
  [int]$ProcessId = 0,
  [int64]$ProcessStartTimeUtcTicks = 0,
  [string]$TaskName = 'CodexDesktopQuickRepairAfterExit'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Arm -eq $Run) {
  throw 'Choose exactly one mode: -Arm or -Run.'
}

$RepairRoot = Split-Path -Parent $PSScriptRoot
$QuickRepair = Join-Path $PSScriptRoot 'Invoke-CodexDesktopQuickRepair.ps1'

function Get-MatchingProcess([int]$Id, [int64]$StartTicks) {
  if ($Id -le 0) { return $null }
  $process = Get-Process -Id $Id -ErrorAction SilentlyContinue
  if (-not $process) {
    # A scheduled task can lack a process handle in its logon context even
    # though the owner is visible system-wide through CIM. Keep the same PID
    # binding instead of interpreting that visibility gap as an exit.
    try {
      $process = Get-CimInstance Win32_Process -Filter "ProcessId = $Id" -ErrorAction SilentlyContinue
    } catch {
      $process = $null
    }
    if (-not $process) { return $null }
  }
  if ($StartTicks -le 0) { return $process }
  try {
    if ([int64]$process.StartTime.ToUniversalTime().Ticks -eq $StartTicks) {
      return $process
    }
  } catch {
    return $process
  }
  # Scheduled-task PowerShell can expose a rounded or otherwise different
  # StartTime than the interactive arm pass. The PID was captured from the
  # live owner immediately before registration, so keep waiting on that PID
  # instead of treating a timestamp mismatch as an early exit.
  return $process
}

function Find-RepairOwner {
  $codexCliMirror = Join-Path $RepairRoot 'state\codex-cli\codex.exe'
  $pluginRoot = Join-Path $env:USERPROFILE '.codex\plugins\cache\openai-bundled'
  $browserPrefix = (Join-Path $pluginRoot 'browser').TrimEnd('\') + '\'
  $chromePrefix = (Join-Path $pluginRoot 'chrome').TrimEnd('\') + '\'
  $runtimePrefix = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node').TrimEnd('\') + '\'
  $candidates = New-Object System.Collections.Generic.List[object]

  foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
    $name = [string]$process.Name
    $path = [string]$process.ExecutablePath
    $commandLine = [string]$process.CommandLine
    $priority = $null
    $reason = $null

    if ($name -ieq 'codex.exe') {
      if ($path -and [string]::Equals($path, $codexCliMirror, [System.StringComparison]::OrdinalIgnoreCase)) {
        $priority = 0
        $reason = 'managed Codex app-server or CLI mirror'
      } elseif ($path -and $path -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\') {
        $priority = 1
        $reason = 'registered Codex AppX process'
      }
    } elseif ($name -ieq 'extension-host.exe' -and $path -and $path.StartsWith($chromePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $priority = 2
      $reason = 'bundled Chrome extension host'
    } elseif ($name -iin @('node.exe', 'node_repl.exe')) {
      if ($path -and $path.StartsWith($browserPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $priority = 3
        $reason = 'Browser runtime'
      } elseif ($commandLine -and $commandLine -match '(?i)browser-client\.mjs') {
        $priority = 3
        $reason = 'Browser client runtime'
      }
    } elseif ($name -ieq 'codex-computer-use.exe' -and $path -and $path.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $priority = 4
      $reason = 'Computer Use runtime'
    }

    if ($null -ne $priority) {
      $candidates.Add([pscustomobject]@{
          ProcessId = [int]$process.ProcessId
          Name = $name
          Path = $path
          Priority = $priority
          Reason = $reason
        })
    }
  }

  return @($candidates | Sort-Object Priority, ProcessId | Select-Object -First 1)
}

if ($Arm) {
  if (-not (Test-Path -LiteralPath $QuickRepair -PathType Leaf)) {
    throw "Missing QuickRepair entry: $QuickRepair"
  }

  $owner = Find-RepairOwner
  if (-not $owner) {
    throw 'arm-failed: no known repair target process is active.'
  }

  $ownerProcess = Get-Process -Id $owner.ProcessId -ErrorAction Stop
  $ownerStartTicks = 0
  try {
    $ownerStartTicks = [int64]$ownerProcess.StartTime.ToUniversalTime().Ticks
  } catch {
  }

  $helperPath = $PSCommandPath
  $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Run -ProcessId {1} -ProcessStartTimeUtcTicks {2} -Route {3} -TaskName "{4}"' -f $helperPath, $owner.ProcessId, $ownerStartTicks, $Route, $TaskName
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

  Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'One-shot Codex repair armed only after explicit user authorization; runs after the recorded owner exits.' -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName

  [pscustomobject]@{
    status = 'armed'
    task = $TaskName
    route = $Route
    processId = $owner.ProcessId
    processName = $owner.Name
    reason = $owner.Reason
  } | ConvertTo-Json -Compress
  exit 0
}

if (-not (Test-Path -LiteralPath $QuickRepair -PathType Leaf)) {
  throw "Missing QuickRepair entry: $QuickRepair"
}

$watcher = $null
try {
  $query = New-Object System.Management.WqlEventQuery ("SELECT * FROM Win32_ProcessStopTrace WHERE ProcessID = $ProcessId")
  $watcher = New-Object System.Management.ManagementEventWatcher
  $watcher.Query = $query
  $watcher.Start()

  # ProcessStopTrace can deliver an empty/unrelated event in a scheduled-task
  # context. Stay event-driven, but re-check the recorded owner after every
  # event and continue waiting until that exact PID is actually gone.
  while (Get-MatchingProcess $ProcessId $ProcessStartTimeUtcTicks) {
    $null = $watcher.WaitForNextEvent()
  }

  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $QuickRepair -Route $Route
  $repairExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  exit $repairExitCode
} finally {
  if ($watcher) {
    try { $watcher.Stop() } catch { }
    $watcher.Dispose()
  }
  Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
}
