param(
  [string]$ProjectRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ([string]$Actual -cne [string]$Expected) { throw "$Message (actual=$Actual expected=$Expected)" }
}

. (Join-Path $ProjectRoot 'scripts\Get-CodexDesktopFirstLaunchDiagnostic.ps1') -LibraryOnly

Assert-Equal (Get-UpdatePolicyPendingFromText "in_app_updates_policy_wait_started timeoutMs=300000") $true 'pending update-policy signal was missed'
Assert-Equal (Get-UpdatePolicyPendingFromText "in_app_updates_policy_wait_started`nwindow ready-to-show") $false 'completed update-policy signal stayed pending'
Assert-Equal (Get-UpdatePolicyPendingFromText "window ready-to-show`nin_app_updates_policy_wait_started") $true 'latest launch ordering was ignored'

Assert-Equal (Get-FirstLaunchClassification $false 0 0 0 -1 $false $false $false).Classification 'appx-missing' 'AppX missing classification failed'
Assert-Equal (Get-FirstLaunchClassification $true 0 0 0 -1 $false $false $false).Classification 'not-running' 'not-running classification failed'
Assert-Equal (Get-FirstLaunchClassification $true 1 1 0 120 $true $true $true).Classification 'renderer-ready' 'renderer state did not win precedence'
Assert-Equal (Get-FirstLaunchClassification $true 1 0 1 120 $true $true $true).Classification 'window-ready' 'window state did not win precedence'
Assert-Equal (Get-FirstLaunchClassification $true 1 0 0 120 $true $false $true).Classification 'runtime-materializing' 'growing staging classification failed'
Assert-Equal (Get-FirstLaunchClassification $true 1 0 0 120 $false $true $true).Classification 'runtime-materializing' 'recent staging classification failed'
Assert-Equal (Get-FirstLaunchClassification $true 1 0 0 120 $false $false $true).Classification 'update-policy-wait' 'update-policy classification failed'
Assert-Equal (Get-FirstLaunchClassification $true 1 0 0 5 $false $false $false).Classification 'starting' 'fresh launch classification failed'
Assert-Equal (Get-FirstLaunchClassification $true 1 0 0 120 $false $false $false).Classification 'headless-unknown' 'unknown headless classification failed'

Write-Host '[PASS] UpdateFirstLaunchDiagnostic focused fixtures passed.'
