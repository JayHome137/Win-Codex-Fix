param(
  [string]$StageRoot = '',
  [string]$ProjectRoot = '',
  [string]$SkillSourceRoot = '',
  [string]$InstalledSkillRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packageRoot = Split-Path -Parent $PSScriptRoot
if (-not $StageRoot) { $StageRoot = $packageRoot }
if (-not $ProjectRoot) { $ProjectRoot = $packageRoot }
if (-not $SkillSourceRoot) { $SkillSourceRoot = $ProjectRoot }
if (-not $InstalledSkillRoot) {
  $InstalledSkillRoot = Join-Path $env:USERPROFILE '.codex\skills\codex-desktop-bundled-repair'
}

function Copy-StageFile([string]$RelativePath, [string]$TargetRoot) {
  $source = Join-Path $StageRoot $RelativePath
  $target = Join-Path $TargetRoot $RelativePath
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing stage file: $source" }
  if ([System.IO.Path]::GetFullPath($source) -eq [System.IO.Path]::GetFullPath($target)) {
    return
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
  try { Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop }
  catch { throw "pending-natural-exit: cannot replace $target ($($_.Exception.Message))" }
  if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
    throw "Published hash mismatch: $target"
  }
}

if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) { throw "Missing stage root: $StageRoot" }
foreach ($root in @($ProjectRoot, $SkillSourceRoot, $InstalledSkillRoot)) {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
}

# Stop only the stale repair task; Codex, Chrome and Edge are never touched.
$healthTask = Get-ScheduledTask -TaskName 'CodexDesktopBundledHealthCheck' -ErrorAction SilentlyContinue
if ($healthTask -and [string]$healthTask.State -eq 'Running') {
  Stop-ScheduledTask -TaskName 'CodexDesktopBundledHealthCheck' -ErrorAction SilentlyContinue
}

$projectFiles = @(
  '.gitignore',
  'README.md',
  'CONTRIBUTING.md',
  'LICENSE',
  'SKILL.md',
  'BUNDLE-MANIFEST.sha256',
  'deploy\Install-FastRepair.ps1',
  'agents\openai.yaml',
  'scripts\BrowserNativeHost.ps1',
  'scripts\ChromeOpaqueTextMaterialization.ps1',
  'scripts\Invoke-CodexDesktopQuickRepair.ps1',
  'scripts\Start-CodexDesktopQuickRepairAfterExit.ps1',
  'scripts\Repair-CodexDesktopBundled.ps1',
  'scripts\Repair-CodexSessionIndex.ps1',
  'scripts\Repair-CodexSessionIndex.py',
  'scripts\RunHidden-CodexDesktopBundledHealthCheck.vbs',
  'scripts\RunHidden-CodexDesktopBundledPostUpdateRepair.vbs',
  'scripts\Start-CodexDesktopOnce.ps1',
  'scripts\Verify-CodexDesktopBundled.ps1',
  'tests\Test-BrowserNativeHost.ps1',
  'tests\Test-ChromeAppxBootstrap.ps1',
  'tests\Test-ComputerUseCache.ps1',
  'tests\Test-EdgeNativeHost.ps1',
  'tests\Test-CliMirrorPair.ps1',
  'docs\quick-repair.md',
  '.github\ISSUE_TEMPLATE\bug-report.md'
)
foreach ($relative in $projectFiles) { Copy-StageFile $relative $ProjectRoot }

# The installed skill is a physical, self-contained copy of the new instructions.
foreach ($relative in @('SKILL.md','README.md','LICENSE','agents\openai.yaml','docs\quick-repair.md')) {
  Copy-StageFile $relative $SkillSourceRoot
  Copy-StageFile $relative $InstalledSkillRoot
}

# Remove only audited repair-code remnants; user data and repair state are untouched.
$obsolete = @(
  'scripts\Invoke-CodexDesktopBundledHealthCheck.ps1',
  'scripts\Invoke-CodexDesktopBundledPostUpdateRepair.ps1',
  'scripts\Start-CodexDesktopBundledHealthCheckContinuation.ps1',
  'scripts\Repair-CodexDesktopBundled.ps1.pair-candidate.ps1',
  'scripts\Verify-CodexDesktopBundled.ps1.pair-candidate.ps1',
  'scripts\Get-CodexDesktopFirstLaunchDiagnostic.ps1',
  'tests\Test-UpdateFirstLaunchDiagnostic.ps1',
  'scripts\ChromeOpaqueTextMaterialization.ps1.pre-appx-peer-anchor-20260803'
)
$obsolete += @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'scripts') -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like 'Repair-CodexDesktopBundled.ps1.pre-*' -or $_.Name -like 'Verify-CodexDesktopBundled.ps1.pre-*' -or $_.Name -like 'Start-CodexDesktopOnce.ps1.pre-*' } |
  ForEach-Object { Join-Path 'scripts' $_.Name })
foreach ($relative in $obsolete) {
  $target = Join-Path $ProjectRoot $relative
  if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
}

[pscustomobject]@{
  status = 'fast-repair-installed'
  project = $ProjectRoot
  skillSource = $SkillSourceRoot
  installedSkill = $InstalledSkillRoot
  repairTasksStopped = [bool]($healthTask -and [string]$healthTask.State -eq 'Running')
  codexChromeEdgeTouched = $false
} | ConvertTo-Json -Compress
