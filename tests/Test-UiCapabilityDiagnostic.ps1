param(
  [string]$ProjectRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Invoke-Probe([string]$Probe, [string]$Config) {
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Probe -ConfigPath $Config 2>&1)
  $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  if ($output.Count -eq 0) { throw "UI capability probe returned no output: $Config" }
  $result = ($output -join "`n") | ConvertFrom-Json
  return [pscustomobject]@{ Code = $code; Result = $result }
}

$probe = Join-Path $ProjectRoot 'scripts\Diagnose-CodexDesktopUiCapability.ps1'
$gatedFixture = Join-Path $ProjectRoot 'tests\fixtures\ui-capability-gated.config.toml'
$readyFixture = Join-Path $ProjectRoot 'tests\fixtures\ui-capability-ready.config.toml'

$gated = Invoke-Probe $probe $gatedFixture
Assert-True ($gated.Code -eq 10) 'Gated fixture must return the feature-gate diagnostic exit code.'
Assert-True ($gated.Result.state -eq 'feature-gate-or-policy') 'Gated fixture was not classified as feature-gate-or-policy.'
Assert-True ($gated.Result.iabConfigured -eq $true) 'Gated fixture lost the iab backend signal.'
Assert-True ($gated.Result.safeLocalRepair -eq $false) 'Feature-gate state must never claim a safe local repair.'

$ready = Invoke-Probe $probe $readyFixture
Assert-True ($ready.Code -eq 0) 'Ready fixture must return success.'
Assert-True ($ready.Result.state -eq 'local-capability-ready') 'Ready fixture was not classified as local-capability-ready.'
Assert-True ($ready.Result.browserPluginEnabled -and $ready.Result.computerUsePluginEnabled) 'Ready fixture lost enabled plugin state.'

Write-Host '[PASS] UI capability diagnostic fixture passed.'
