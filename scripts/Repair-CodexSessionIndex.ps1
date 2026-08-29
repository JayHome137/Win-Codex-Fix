param(
    [switch]$Check,
    [switch]$RepairIfIdle,
    [int]$WaitSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepairRoot = Split-Path -Parent $PSScriptRoot
$env:CODEX_REPAIR_ROOT = $RepairRoot
$PythonScript = Join-Path $RepairRoot 'scripts\Repair-CodexSessionIndex.py'
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
$PythonExe = if ($pythonCommand) { $pythonCommand.Source } else { $null }
$PythonPrefix = @()
if (-not $PythonExe -or -not (Test-Path -LiteralPath $PythonExe)) {
  $pythonCommand = Get-Command py.exe -ErrorAction SilentlyContinue
  $PythonExe = if ($pythonCommand) { $pythonCommand.Source } else { $null }
  $PythonPrefix = @('-3')
}
$CliMirror = Join-Path $RepairRoot 'state\codex-cli\codex.exe'

function Invoke-SessionTool([string]$Command) {
  if (-not $PythonExe -or -not (Test-Path -LiteralPath $PythonExe)) {
    throw 'python.exe is not available for the local session parity gate'
  }
  $output = @(& $PythonExe @PythonPrefix -B $PythonScript $Command 2>&1)
  $exitCode = $LASTEXITCODE
  $line = if ($output.Count -gt 0) { [string]$output[-1] } else { '{}' }
  $json = $line | ConvertFrom-Json
  return [pscustomobject]@{ ExitCode = $exitCode; Data = $json; Output = ($output -join "`n") }
}

function Get-SessionWriters {
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    if ($_.Name -eq 'ChatGPT.exe') { return $true }
    if ($_.Name -eq 'node_repl.exe') { return $true }
    # Every Codex CLI can share state_5.sqlite, including npm and protected-path
    # processes whose ExecutablePath is unavailable to this user context.
    if ($_.Name -eq 'codex.exe') { return $true }
    return $false
  })
}

if (-not $Check -and -not $RepairIfIdle) {
  $Check = $true
}

$initial = Invoke-SessionTool 'check'
if ($Check) {
  $initial.Output
  exit $initial.ExitCode
}

if ($initial.ExitCode -eq 0) {
  $initial.Output
  exit 0
}

$deadline = (Get-Date).AddSeconds([Math]::Max(0, $WaitSeconds))
do {
  $writers = @(Get-SessionWriters)
  if ($writers.Count -eq 0) {
    Start-Sleep -Seconds 5
    if (@(Get-SessionWriters).Count -eq 0) { break }
  }
  if ($WaitSeconds -le 0 -or (Get-Date) -ge $deadline) {
    $initial.Output
    Write-Output ('session-index-pending-natural-exit writers={0}' -f $writers.Count)
    exit 20
  }
  Start-Sleep -Seconds 1
} while ($true)

$repair = Invoke-SessionTool 'repair'
$repair.Output
if ($repair.ExitCode -ne 0) { exit $repair.ExitCode }

if ([bool]$repair.Data.needsBackfill) {
  $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $processInfo.FileName = $CliMirror
  $processInfo.Arguments = 'app-server --stdio'
  $processInfo.UseShellExecute = $false
  $processInfo.RedirectStandardInput = $true
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $processInfo
  if (-not $process.Start()) {
    throw 'failed to start the managed app-server for session-index backfill'
  }
  # The app-server performs the official backfill during startup and exits after stdin reaches EOF.
  $process.StandardInput.Close()
  $process.WaitForExit()
  $appServerExit = $process.ExitCode
  $process.Dispose()
  if ($appServerExit -ne 0) {
    Write-Output "session-index-app-server-exit=$appServerExit"
    exit $appServerExit
  }

  # Rollout metadata remains authoritative when the app-server assigns its launch cwd during a rebuild.
  $reconcile = Invoke-SessionTool 'reconcile'
  $reconcile.Output
  if ($reconcile.ExitCode -ne 0) { exit $reconcile.ExitCode }
}

$final = Invoke-SessionTool 'check'
$final.Output
exit $final.ExitCode
