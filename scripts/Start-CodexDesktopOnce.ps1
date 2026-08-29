param(
  [ValidateRange(5, 120)]
  [int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
  Sort-Object Version -Descending |
  Select-Object -First 1
if (-not $package) {
  throw 'Current OpenAI.Codex AppX package was not found.'
}

function Get-CurrentDesktopProcess {
  $installPrefix = ([string]$package.InstallLocation).TrimEnd('\') + '\'
  foreach ($candidate in @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)) {
    try {
      $path = [string]$candidate.Path
      if ($path -and $path.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
          ProcessId = [int]$candidate.Id
          ExecutablePath = $path
        }
      }
    } catch {
      continue
    }
  }
  return $null
}

$existing = Get-CurrentDesktopProcess
if ($existing) {
  [pscustomobject]@{
    Action = 'already-running'
    Launched = $false
    PackageVersion = [string]$package.Version
    PackageFullName = [string]$package.PackageFullName
    ProcessId = [int]$existing.ProcessId
    ExecutablePath = [string]$existing.ExecutablePath
  } | ConvertTo-Json -Depth 4
  exit 0
}

[xml]$manifest = Get-Content -LiteralPath (Join-Path $package.InstallLocation 'AppxManifest.xml') -Raw
$namespace = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
$namespace.AddNamespace('appx', [string]$manifest.DocumentElement.NamespaceURI)
$application = $manifest.SelectSingleNode('/appx:Package/appx:Applications/appx:Application', $namespace)
if (-not $application) {
  throw 'Codex AppX application entry was not found.'
}
$appUserModelId = '{0}!{1}' -f $package.PackageFamilyName, [string]$application.Id

$taskName = 'CodexDesktopRepairLaunchOnce-{0}' -f ([guid]::NewGuid().ToString('N'))
$action = New-ScheduledTaskAction `
  -Execute (Join-Path $env:WINDIR 'explorer.exe') `
  -Argument ('shell:AppsFolder\{0}' -f $appUserModelId)
$principal = New-ScheduledTaskPrincipal `
  -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) `
  -LogonType Interactive `
  -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
  -MultipleInstances IgnoreNew `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries

$registered = $false
try {
  Register-ScheduledTask `
    -TaskName $taskName `
    -TaskPath '\' `
    -Action $action `
    -Principal $principal `
    -Settings $settings | Out-Null
  $registered = $true

  $taskXml = [xml](Export-ScheduledTask -TaskName $taskName -TaskPath '\')
  if ([string]$taskXml.Task.Principals.Principal.LogonType -ne 'InteractiveToken') {
    throw 'One-time launch task is not using InteractiveToken.'
  }

  Start-ScheduledTask -TaskName $taskName -TaskPath '\'
  $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
  $process = $null
  do {
    $process = Get-CurrentDesktopProcess
    if ($process) {
      break
    }
    Start-Sleep -Milliseconds 500
  } while ([datetime]::UtcNow -lt $deadline)

  if (-not $process) {
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\'
    throw "Current AppX ChatGPT.exe was not observed within $TimeoutSeconds seconds. LastTaskResult=$($taskInfo.LastTaskResult)"
  }

  [pscustomobject]@{
    Action = 'launched'
    Launched = $true
    PackageVersion = [string]$package.Version
    PackageFullName = [string]$package.PackageFullName
    AppUserModelId = $appUserModelId
    ProcessId = [int]$process.ProcessId
    ExecutablePath = [string]$process.ExecutablePath
  } | ConvertTo-Json -Depth 4
} finally {
  if ($registered -and (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue)) {
    Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
  }
}
