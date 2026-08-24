<#
.SYNOPSIS
Install the EVE Map Assistant DSH bundle into a DSH profile.

.DESCRIPTION
Installs this local bundle (eve-map-assistant-dsh) into the selected DSH
profile through the official `dsh plugin` mechanism:

    dsh plugin --profile <profile> add file:<local tarball>

which forwards to pnpm inside the profile directory and automatically appends
the package to the profile's `dsh.profile.bundles` layer stack (any dependency
whose manifest declares `dsh.bundle` joins the layer stack).

DSH launcher resolution (shared toolkit, tools/dsh-toolkit.ps1):
  1. `dsh` on PATH, else
  2. `npx --yes @deepseek-ai/dsh` (DSH lives in npm's npx cache - no global
     install of @deepseek-ai/dsh is required), else
  3. a clear prerequisite error.

Pre-flight checks (all must pass before anything is modified):
  * eve-map-mcp.exe is resolvable from PATH
  * a DSH launcher is resolvable (dsh or npx)
  * pnpm is available (DSH plugin management invokes pnpm)
  * the requested profile exists under $DSH_HOME/profiles

Fail-safe migration: before installing, the script snapshots the profile's
package.json and cordis.patch.yml. If a manual `mcp-eve-map` insert exists in
the profile's cordis.patch.yml, or a legacy EVE Map Assistant bundle from an
earlier prototype install is present (e.g. the broken
@eve-map-assistant/dsh-eve-map-bundle entry), those are only cleaned up AFTER
the new bundle installs and verifies successfully. On any failure the backups
are restored, so a previously working manual configuration is never destroyed.

.PARAMETER Profile
The DSH profile to install into. Defaults to 'web'.

.PARAMETER DryRun
Run all checks and print exactly what would be done, without modifying the
profile or installing anything.

.PARAMETER DshHome
Override the DSH home directory (default: $env:DSH_HOME, else ~/.dsh).

.EXAMPLE
.\install.ps1 -Profile web

.EXAMPLE
.\install.ps1 -Profile web -DryRun
#>
[CmdletBinding()]
param(
    [string]$Profile = 'web',
    [switch]$DryRun,
    [string]$DshHome
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$ProjectRoot = $PSScriptRoot
$Helper = Join-Path $ProjectRoot 'tools\patch-file.mjs'
$LegacyBundleNames = @('@eve-map-assistant/dsh-eve-map-bundle')

. (Join-Path $ProjectRoot 'tools\dsh-toolkit.ps1')

function Assert-McpEveMapRow([object]$Row, [string]$Where) {
    if ((Get-Prop $Row 'id') -ne 'mcp-eve-map') { throw "internal: ${Where} row id is '$(Get-Prop $Row 'id')'" }
    if ((Get-Prop $Row 'name') -ne '@deepseek-ai/dsh-mcp-client') { throw "${Where}: name must be '@deepseek-ai/dsh-mcp-client', got '$(Get-Prop $Row 'name')'" }
    $cfg = Get-Prop $Row 'config'
    if ($null -eq $cfg) { throw "${Where}: missing config" }
    if ((Get-Prop $cfg 'serverName') -ne 'evemap') { throw "${Where}: serverName must be 'evemap', got '$(Get-Prop $cfg 'serverName')'" }
    if ((Get-Prop $cfg 'transport') -ne 'stdio') { throw "${Where}: transport must be 'stdio', got '$(Get-Prop $cfg 'transport')'" }
    if ((Get-Prop $cfg 'command') -ne 'eve-map-mcp.exe') { throw "${Where}: command must be 'eve-map-mcp.exe', got '$(Get-Prop $cfg 'command')'" }
}

function Assert-PortableConfig([object]$Row, [string]$Where) {
    $cfg = Get-Prop $Row 'config'
    if ($null -ne $cfg) {
        $dump = $cfg | ConvertTo-Json -Depth 20 -Compress
        foreach ($bad in @('C:\', 'C:/', 'Users\', '/users/', 'http://', 'https://', '.ps1', 'powershell', 'pwsh', 'shell')) {
            if ($dump.ToLowerInvariant().Contains($bad.ToLowerInvariant())) {
                throw "${Where}: config is not portable (contains '$bad')"
            }
        }
        if ($null -ne (Get-Prop $cfg 'url')) { throw "${Where}: config must not use an HTTP URL transport" }
    }
}

# ---------------------------------------------------------------- pre-flight

Assert-ProfileName $Profile
$DshHomeDir = Resolve-DshHomeDir -DshHome $DshHome
$ProfileDir = Join-Path $DshHomeDir (Join-Path 'profiles' $Profile)
$ManifestPath = Join-Path $ProfileDir 'package.json'
$PatchPath = Join-Path $ProfileDir 'cordis.patch.yml'

# Make every `dsh` child process use the same home we resolved (explicit
# -DshHome overrides the environment for the whole run).
if (-not [string]::IsNullOrWhiteSpace($DshHome)) {
    $env:DSH_HOME = $DshHomeDir
}

Write-Step "Pre-flight checks (profile '$Profile')"
Write-Info "DSH home: $DshHomeDir"
Write-Info "Profile directory: $ProfileDir"

$mcpExe = Get-Command eve-map-mcp.exe -ErrorAction SilentlyContinue
if (-not $mcpExe) {
    throw 'eve-map-mcp.exe is not resolvable from PATH - install EVE Static Map Planner (it registers its installation directory on the user PATH)'
}
Write-Ok "eve-map-mcp.exe -> $($mcpExe.Source)"

$pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
if (-not $pnpm) {
    throw 'pnpm is not available - DSH plugin management invokes pnpm inside the profile directory. Install pnpm (npm install -g pnpm) and re-run.'
}
Write-Ok "pnpm -> $($pnpm.Source)"

$Launcher = Resolve-DshLauncher
Write-Ok "DSH launcher resolvable ($($Launcher.Label))"

if (-not (Test-Path $ManifestPath)) {
    throw "profile '$Profile' does not exist at $ProfileDir (no package.json). Boot the profile once (dsh --profile $Profile) or run 'dsh plugin --profile $Profile add <package>' to initialize it."
}
Write-Ok "profile '$Profile' exists"

if ($DryRun) {
    Write-Step "Dry run - no changes made"
    Write-Info "Would pack the bundle (pnpm pack) and run:"
    Write-Info "  $($Launcher.Label) plugin --profile $Profile add file:<project>\eve-map-assistant-dsh-<version>.tgz"
    Write-Info "Then verify and clean up any manual mcp-eve-map / legacy bundle entries (backups kept)."
    exit 0
}

# ------------------------------------------------------------ build tarball

Write-Step "Build local bundle tarball"
$Manifest = Read-Manifest (Join-Path $ProjectRoot 'package.json')
$PackageName = $Manifest.name
$Version = $Manifest.version
if ($PackageName -ne 'eve-map-assistant-dsh') { throw "unexpected project package name '$PackageName' (expected 'eve-map-assistant-dsh')" }
$ExpectedTgz = Join-Path $ProjectRoot "$PackageName-$Version.tgz"
Get-ChildItem $ProjectRoot -Filter "$PackageName-*.tgz" -File -ErrorAction SilentlyContinue | Remove-Item -Force
Write-Info "pnpm pack in $ProjectRoot"
Push-Location $ProjectRoot
try {
    & pnpm pack 2>&1 | ForEach-Object { Write-Info $_ }
    if ($LASTEXITCODE -ne 0) { throw 'pnpm pack failed' }
} finally {
    Pop-Location
}
if (-not (Test-Path $ExpectedTgz)) {
    $found = Get-ChildItem $ProjectRoot -Filter "$PackageName-*.tgz" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { throw 'pnpm pack did not produce a tarball' }
    $ExpectedTgz = $found.FullName
}
Write-Ok "tarball: $ExpectedTgz"

# ---------------------------------------------------------- migration state

Write-Step "Migration state (fail-safe)"
$JsYamlDir = Resolve-JsYamlDir
if (-not $JsYamlDir) {
    throw 'js-yaml could not be resolved from the DSH installation (discovered via dsh or the npx cache). Make sure DSH has been run at least once through "npx --yes @deepseek-ai/dsh" (or is on PATH as "dsh"), then re-run.'
}
Write-Info "js-yaml: $JsYamlDir"

$profileManifest = Read-Manifest $ManifestPath
$manualDetect = Invoke-Helper 'detect' @($PatchPath) $JsYamlDir $Helper
$hasManualEntry = [bool]$manualDetect.found
$legacyDeps = @()
$profileDeps = Get-NestedProp $profileManifest @('dependencies')
if ($null -ne $profileDeps) {
    $legacyDeps = @($profileDeps.PSObject.Properties.Name | Where-Object { $LegacyBundleNames -contains $_ })
}
$legacyBundles = @()
$profileBundlesValue = Get-NestedProp $profileManifest @('dsh', 'profile', 'bundles')
if ($null -ne $profileBundlesValue) {
    $legacyBundles = @($profileBundlesValue | Where-Object { $LegacyBundleNames -contains $_ })
}
$legacyChanged = Remove-LegacyBundlesFromManifest $profileManifest $LegacyBundleNames

if ($hasManualEntry)  { Write-Info "manual mcp-eve-map insert detected in $PatchPath (will be backed up, replaced by the bundle, then removed only after verification)" }
else                  { Write-Ok  'no manual mcp-eve-map insert in the profile patch layer' }
if ($legacyChanged)   { Write-Info "legacy EVE Map Assistant bundle entries found (deps: $($legacyDeps -join ', ') ; bundles: $($legacyBundles -join ', ')) - will be backed up and removed" }
else                  { Write-Ok  'no legacy EVE Map Assistant bundle entries in the profile manifest' }

$restore = @()
if ($hasManualEntry -or $legacyChanged) {
    $patchBackup = Backup-IfNeeded $PatchPath
    $manifestBackup = Backup-IfNeeded $ManifestPath
    if ($patchBackup)   { Write-Info "backup: $patchBackup"; $restore += @{ Path = $PatchPath; Backup = $patchBackup } }
    if ($manifestBackup) { Write-Info "backup: $manifestBackup"; $restore += @{ Path = $ManifestPath; Backup = $manifestBackup } }
}

try {
    if ($legacyChanged) {
        Write-Step "Remove legacy EVE Map Assistant bundle entries (backup taken)"
        Write-Manifest $ManifestPath $profileManifest
        Write-Ok 'profile manifest updated (legacy entries removed)'
    }

    # -------------------------------------------------------- official install
    Write-Step "Install via official DSH plugin mechanism"
    $tarballSpec = 'file:' + ($ExpectedTgz -replace '\\', '/')
    Write-Info "command: $($Launcher.Label) plugin --profile $Profile add $tarballSpec"
    $exitCode = Invoke-Dsh $Launcher @('plugin', '--profile', $Profile, 'add', $tarballSpec)
    if ($exitCode -ne 0) { throw "dsh plugin add failed with exit code $exitCode (see output above)" }
    Write-Ok "dsh plugin add exited 0"

    # ------------------------------------------------------------- verify
    Write-Step "Verify bundle ownership of mcp-eve-map"
    $afterManifest = Read-Manifest $ManifestPath
    $depPresent = $null -ne (Get-DepSpec $afterManifest $PackageName)
    $afterBundles = @()
    $afterBundlesValue = Get-NestedProp $afterManifest @('dsh', 'profile', 'bundles')
    if ($null -ne $afterBundlesValue) { $afterBundles = @($afterBundlesValue) }
    $bundleListed = $afterBundles -contains $PackageName
    if (-not $depPresent)  { throw "verification failed: '$PackageName' not found in profile dependencies" }
    if (-not $bundleListed) { throw "verification failed: '$PackageName' not in dsh.profile.bundles (bundle declaration not recognized)" }
    $stillLegacy = @($afterBundles | Where-Object { $LegacyBundleNames -contains $_ })
    if ($stillLegacy.Count -gt 0) { throw "verification failed: legacy bundle(s) still listed: $($stillLegacy -join ', ')" }
    Write-Ok "bundle in profile dependencies and dsh.profile.bundles"

    $dumpFile = Join-Path $env:TEMP "dsh-dump-$Profile-$([guid]::NewGuid().ToString('N')).txt"
    try {
        $prevEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        try {
            $dumpArgs = @('--profile', $Profile, '--dump-config')
            if ($Launcher.Prefix.Count -gt 0) { $dumpArgs = @($Launcher.Prefix) + $dumpArgs }
            $dumpText = & $Launcher.Command @dumpArgs 2>$null | Out-String
            if ($LASTEXITCODE -ne 0) { throw "dsh --dump-config failed with exit code $LASTEXITCODE" }
        } finally {
            [Console]::OutputEncoding = $prevEncoding
        }
        Write-Utf8NoBom $dumpFile $dumpText
        $parsed = Invoke-Helper 'dump-parse' @($dumpFile) $JsYamlDir $Helper
        $bundleGroup = $parsed.groups | Where-Object { $_.label -like "$PackageName*" }
        if (-not $bundleGroup) { throw "verification failed: no composed rows attributed to layer '$PackageName'" }
        $rowsInBundle = @($bundleGroup.rows | Where-Object { $_.id -eq 'mcp-eve-map' })
        if ($rowsInBundle.Count -ne 1) { throw "verification failed: expected exactly one mcp-eve-map row from '$PackageName', found $($rowsInBundle.Count)" }
        Assert-McpEveMapRow $rowsInBundle[0] "bundle row"
        Assert-PortableConfig $rowsInBundle[0] "bundle row"
        Write-Ok "mcp-eve-map row owned by '$PackageName' with correct portable config"

        $allRows = @()
        foreach ($group in $parsed.groups) { $allRows += @($group.rows) }
        $total = @($allRows | Where-Object { $_.id -eq 'mcp-eve-map' }).Count
        if ($hasManualEntry) {
            # The manual duplicate is still in the user patch layer at this
            # point (it is removed only after verification, per the fail-safe
            # order), so the composed profile correctly shows 2 rows for now.
            if ($total -ne 2) { throw "verification failed: expected the bundle row plus the pending manual duplicate (2 mcp-eve-map rows), found $total" }
            Write-Ok 'mcp-eve-map provided by the bundle layer (manual duplicate pending removal)'
        } else {
            if ($total -ne 1) { throw "verification failed: mcp-eve-map must exist exactly once in the composed profile, found $total" }
            Write-Ok 'mcp-eve-map exists exactly once in the composed profile'
        }
    } finally {
        Remove-Item -LiteralPath $dumpFile -Force -ErrorAction SilentlyContinue
    }

    # ------------------------------------------ post-verify cleanup (manual)
    if ($hasManualEntry) {
        Write-Step "Remove old manual mcp-eve-map duplicate (bundle verified; backup kept)"
        $remove = Invoke-Helper 'remove' @($PatchPath, 'mcp-eve-map') $JsYamlDir $Helper
        Write-Ok "manual duplicate removed (rows: $($remove.removedRows), entries: $($remove.removedEntries))"

        # Re-verify the composed state after cleanup: exactly one row, owned by the bundle.
        $dumpFile2 = Join-Path $env:TEMP "dsh-dump-$Profile-$([guid]::NewGuid().ToString('N')).txt"
        try {
            $prevEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            try {
                $dumpArgs = @('--profile', $Profile, '--dump-config')
                if ($Launcher.Prefix.Count -gt 0) { $dumpArgs = @($Launcher.Prefix) + $dumpArgs }
                $dumpText2 = & $Launcher.Command @dumpArgs 2>$null | Out-String
                if ($LASTEXITCODE -ne 0) { throw "dsh --dump-config failed with exit code $LASTEXITCODE" }
            } finally {
                [Console]::OutputEncoding = $prevEncoding
            }
            Write-Utf8NoBom $dumpFile2 $dumpText2
            $parsed2 = Invoke-Helper 'dump-parse' @($dumpFile2) $JsYamlDir $Helper
            $allRows2 = @()
            foreach ($group in $parsed2.groups) { $allRows2 += @($group.rows) }
            $total2 = @($allRows2 | Where-Object { $_.id -eq 'mcp-eve-map' }).Count
            if ($total2 -ne 1) { throw "verification failed: after manual cleanup, mcp-eve-map must exist exactly once, found $total2" }
            $bundleGroup2 = $parsed2.groups | Where-Object { $_.label -like "$PackageName*" }
            if (-not $bundleGroup2) { throw 'verification failed: bundle layer missing after manual cleanup' }
            Write-Ok 'post-cleanup: mcp-eve-map exists exactly once, owned by the bundle'
        } finally {
            Remove-Item -LiteralPath $dumpFile2 -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Step "Install complete"
    Write-Info "  bundle:        $PackageName@$Version"
    Write-Info "  profile:       $Profile"
    Write-Info "  restart DSH, then open a new conversation - mcp__evemap__* tools will be available"
} catch {
    Write-Fail "Install failed: $($_.Exception.Message)"
    foreach ($item in $restore) {
        if (Test-Path $item.Backup) {
            Copy-Item -LiteralPath $item.Backup -Destination $item.Path -Force
            Write-Info "restored $($item.Path) from $($item.Backup)"
        }
    }
    Write-Info 'No working configuration was destroyed; backups are listed above.'
    throw
}
