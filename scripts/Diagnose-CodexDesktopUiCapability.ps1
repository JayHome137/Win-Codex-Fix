param(
  [string]$ConfigPath = '',
  [string]$BrowserServicePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not $ConfigPath) {
  $ConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'
}
if (-not $BrowserServicePath) {
  $BrowserServicePath = Join-Path $env:USERPROFILE '.codex\plugins\cache\openai-bundled\chrome\latest\scripts\browser-service.mjs'
}

function Get-NodeReplEnvSection([string]$Text) {
  $match = [regex]::Match(
    $Text,
    '(?ms)^\[mcp_servers\.node_repl\.env\]\s*$.*?(?=^\[|\z)'
  )
  if (-not $match.Success) { return '' }
  return $match.Value
}

function Get-TomlString([string]$Text, [string]$Key) {
  $pattern = '(?m)^\s*{0}\s*=\s*(?:"([^"]*)"|''([^'']*)'')\s*$' -f [regex]::Escape($Key)
  $match = [regex]::Match($Text, $pattern)
  if (-not $match.Success) { return $null }
  if ($match.Groups[1].Success) { return $match.Groups[1].Value }
  return $match.Groups[2].Value
}

function Test-PluginEnabled([string]$Text, [string]$Plugin) {
  $section = [regex]::Match(
    $Text,
    ('(?ms)^\[plugins\."{0}@openai-bundled"\]\s*$.*?(?=^\[|\z)' -f [regex]::Escape($Plugin))
  )
  return $section.Success -and ($section.Value -match '(?m)^\s*enabled\s*=\s*true\s*(?:#.*)?$')
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
  [pscustomobject]@{
    schemaVersion = 1
    state = 'missing-config'
    safeLocalRepair = $false
    browserPluginEnabled = $false
    chromePluginEnabled = $false
    computerUsePluginEnabled = $false
    availableBackends = @()
    iabConfigured = $false
    tinySkyOverride = $null
    disabledCapabilityFlags = @()
    browserServiceRecognized = $false
    errorSummary = 'Codex config.toml is missing; UI capability cannot be classified.'
  } | ConvertTo-Json -Depth 5
  exit 2
}

$config = Get-Content -LiteralPath $ConfigPath -Raw
$envSection = Get-NodeReplEnvSection $config
$availableBackends = @()
$backendsValue = Get-TomlString $envSection 'BROWSER_USE_AVAILABLE_BACKENDS'
if ($backendsValue) {
  $availableBackends = @($backendsValue -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
}

$tinySky = Get-TomlString $envSection 'BROWSER_USE_TINYSKY_ENABLED'
$disabledKeys = @(
  'BROWSER_USE_DISABLE_API_MEMBERS',
  'BROWSER_USE_DISABLE_BROWSER_CAPABILITIES',
  'BROWSER_USE_DISABLE_TAB_CAPABILITIES'
)
$disabledCapabilityFlags = @(
  foreach ($key in $disabledKeys) {
    $value = Get-TomlString $envSection $key
    if ($value -and $value -ne '0') { $key }
  }
)

$serviceRecognized = $false
if ($BrowserServicePath -and (Test-Path -LiteralPath $BrowserServicePath -PathType Leaf)) {
  $serviceText = Get-Content -LiteralPath $BrowserServicePath -Raw
  $serviceRecognized = $serviceText -match 'codex-browser-use-tinysky' -and $serviceText -match 'BROWSER_USE_TINYSKY_ENABLED'
}

$browserEnabled = Test-PluginEnabled $config 'browser'
$chromeEnabled = Test-PluginEnabled $config 'chrome'
$computerUseEnabled = Test-PluginEnabled $config 'computer-use'
$iabConfigured = $availableBackends -contains 'iab'

$state = 'runtime-gate-unresolved'
$errorSummary = 'Local plugin/config state is insufficient to prove UI capability; use the live browser capability probe.'
if (-not $browserEnabled -or -not $chromeEnabled -or -not $computerUseEnabled) {
  $state = 'local-plugin-disabled'
  $errorSummary = 'One or more bundled UI plugins are disabled in config.toml.'
} elseif (-not $iabConfigured) {
  $state = 'iab-backend-not-configured'
  $errorSummary = 'The in-app browser backend is not listed in BROWSER_USE_AVAILABLE_BACKENDS.'
} elseif ($disabledCapabilityFlags.Count -gt 0) {
  $state = 'local-capability-disabled'
  $errorSummary = 'A browser capability disable flag is active in node_repl.env.'
} elseif ($tinySky -eq '0') {
  $state = 'feature-gate-or-policy'
  $errorSummary = 'BROWSER_USE_TINYSKY_ENABLED=0 forces the local TinySky override off; the remaining UI gate is service/account controlled and is not safely repairable by cache changes.'
} elseif ($tinySky -eq '1') {
  $state = 'local-capability-ready'
  $errorSummary = 'Local plugin/config flags allow the in-app browser; live backend discovery is still required for UI acceptance.'
}

[pscustomobject]@{
  schemaVersion = 1
  state = $state
  safeLocalRepair = $false
  browserPluginEnabled = [bool]$browserEnabled
  chromePluginEnabled = [bool]$chromeEnabled
  computerUsePluginEnabled = [bool]$computerUseEnabled
  availableBackends = $availableBackends
  iabConfigured = [bool]$iabConfigured
  tinySkyOverride = $tinySky
  disabledCapabilityFlags = $disabledCapabilityFlags
  browserServiceRecognized = [bool]$serviceRecognized
  errorSummary = $errorSummary
} | ConvertTo-Json -Depth 5

if ($state -in @('feature-gate-or-policy', 'runtime-gate-unresolved')) { exit 10 }
if ($state -ne 'local-capability-ready') { exit 2 }
exit 0
