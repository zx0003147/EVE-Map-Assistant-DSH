<#
.SYNOPSIS
Uninstall the EVE Map Assistant DSH bundle from a DSH profile.

.DESCRIPTION
Removes only the EVE Map Assistant DSH bundle (eve-map-assistant-dsh) through
the official DSH plugin mechanism:

    dsh plugin --profile <profile> remove eve-map-assistant-dsh

which forwards `pnpm remove` inside the profile directory and reconciles the
profile's `dsh.profile.bundles` layer list. The DSH launcher is resolved by
the shared toolkit (dsh on PATH, else npx --yes @deepseek-ai/dsh).

This script never:
  * uninstalls EVE Static Map Planner
  * deletes user map data or DSH sessions
  * removes unrelated DSH plugins
  * modifies unrelated profile configuration

Backups created by install.ps1 (package.json.bak-*, cordis.patch.yml.bak-*)
are left in place and their locations are reported, so a previously manual
mcp-eve-map configuration can be restored by hand if desired.

.PARAMETER Profile
The DSH profile to uninstall from. Defaults to 'web'.

.PARAMETER DryRun
Print what would be done without modifying the profile.

.PARAMETER DshHome
Override the DSH home directory (default: $env:DSH_HOME, else ~/.dsh).

.EXAMPLE
.\uninstall.ps1 -Profile web
#>
[CmdletBinding()]
param(
    [string]$Profile = 'web',
    [switch]$DryRun,
    [string]$DshHome
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$PackageName = 'eve-map-assistant-dsh'
$ProjectRoot = $PSScriptRoot

. (Join-Path $ProjectRoot 'tools\dsh-toolkit.ps1')

# ---------------------------------------------------------------- pre-flight

Assert-ProfileName $Profile
$DshHomeDir = Resolve-DshHomeDir -DshHome $DshHome
$ProfileDir = Join-Path $DshHomeDir (Join-Path 'profiles' $Profile)
$ManifestPath = Join-Path $ProfileDir 'package.json'

# Make every `dsh` child process use the same home we resolved (explicit
# -DshHome overrides the environment for the whole run).
if (-not [string]::IsNullOrWhiteSpace($DshHome)) {
    $env:DSH_HOME = $DshHomeDir
}

Write-Step "Pre-flight (profile '$Profile')"
Write-Info "DSH home: $DshHomeDir"
Write-Info "Profile directory: $ProfileDir"

$pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
if (-not $pnpm) {
    throw 'pnpm is not available - DSH plugin management invokes pnpm inside the profile directory. Install pnpm (npm install -g pnpm) and re-run.'
}
Write-Ok "pnpm -> $($pnpm.Source)"

$Launcher = Resolve-DshLauncher
Write-Ok "DSH launcher resolvable ($($Launcher.Label))"

if (-not (Test-Path $ManifestPath)) {
    throw "profile '$Profile' does not exist at $ProfileDir (no package.json)"
}
Write-Ok "profile '$Profile' exists"

$manifest = Read-Manifest $ManifestPath
$depPresent = $null -ne (Get-DepSpec $manifest $PackageName)
$manifestBundles = @()
$manifestBundlesValue = Get-NestedProp $manifest @('dsh', 'profile', 'bundles')
if ($null -ne $manifestBundlesValue) { $manifestBundles = @($manifestBundlesValue) }
$bundleListed = $manifestBundles -contains $PackageName

if (-not $depPresent -and -not $bundleListed) {
    Write-Info "The EVE Map Assistant DSH bundle ($PackageName) is not installed in profile '$Profile'."
    $backups = @(Get-ChildItem $ProfileDir -Filter "$PackageName*" -ErrorAction SilentlyContinue)
    if ($backups.Count -gt 0) { foreach ($b in $backups) { Write-Info "related file: $($b.FullName)" } }
    exit 0
}

if ($DryRun) {
    Write-Step "Dry run - no changes made"
    Write-Info "Would run: $($Launcher.Label) plugin --profile $Profile remove $PackageName"
    exit 0
}

# ------------------------------------------------------------ official remove

Write-Step "Remove bundle via official DSH plugin mechanism"
Write-Info "command: $($Launcher.Label) plugin --profile $Profile remove $PackageName"
$exitCode = Invoke-Dsh $Launcher @('plugin', '--profile', $Profile, 'remove', $PackageName)
if ($exitCode -ne 0) { throw "dsh plugin remove failed with exit code $exitCode (see output above)" }
Write-Ok 'dsh plugin remove exited 0'

# ----------------------------------------------------------------- verify

Write-Step "Verify removal"
$after = Read-Manifest $ManifestPath
$depStill = $null -ne (Get-DepSpec $after $PackageName)
$afterBundles = @()
$afterBundlesValue = Get-NestedProp $after @('dsh', 'profile', 'bundles')
if ($null -ne $afterBundlesValue) { $afterBundles = @($afterBundlesValue) }
$bundleStill = $afterBundles -contains $PackageName
$installedPath = Join-Path $ProfileDir (Join-Path 'node_modules' $PackageName)
$nodeModulesGone = -not (Test-Path (Join-Path $installedPath 'package.json'))

if ($depStill)   { throw "verification failed: '$PackageName' still in profile dependencies" }
if ($bundleStill) { throw "verification failed: '$PackageName' still in dsh.profile.bundles" }
if (-not $nodeModulesGone) { Write-Info "note: node_modules\$PackageName directory still present (pnpm may keep empty dirs); not an error." }
Write-Ok "bundle removed from dependencies and dsh.profile.bundles"

$backups = @(Get-ChildItem $ProfileDir -Filter 'cordis.patch.yml.bak-*' -File -ErrorAction SilentlyContinue) +
           @(Get-ChildItem $ProfileDir -Filter 'package.json.bak-*' -File -ErrorAction SilentlyContinue)
if ($backups.Count -gt 0) {
    Write-Step "Backups kept (restore a previous manual mcp-eve-map config manually if desired)"
    foreach ($b in $backups) { Write-Info "  $($b.Name)" }
}

Write-Step "Uninstall complete"
Write-Info 'EVE Static Map Planner, map data, sessions, and other DSH plugins were not touched.'
