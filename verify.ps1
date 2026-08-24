<#
.SYNOPSIS
Verify the EVE Map Assistant DSH bundle installation in a DSH profile.

.DESCRIPTION
Runs a battery of non-destructive checks:

  * eve-map-mcp.exe resolves on PATH
  * a DSH launcher is resolvable (dsh on PATH, else npx @deepseek-ai/dsh)
  * pnpm is available
  * the requested profile exists
  * the bundle package is installed (profile node_modules + dependencies)
  * the profile's dsh.profile.bundles includes the bundle
  * the installed bundle patch declares exactly one mcp-eve-map row with
      serverName = evemap, transport = stdio, command = eve-map-mcp.exe
  * no absolute path, user name, HTTP URL, or shell wrapper anywhere in the
    bundle's configuration
  * the effective (dumped) profile configuration contains mcp-eve-map exactly
    once, owned by the bundle layer - unless -DumpFile is given, this invokes
    `dsh --profile <profile> --dump-config` (boot-free, never launches the map)

DSH/runtime discovery (js-yaml for patch inspection) uses the shared toolkit
(tools/dsh-toolkit.ps1) and therefore works with a global `dsh` on PATH AND
with npx-only DSH (npx --yes @deepseek-ai/dsh, package in npm's npx cache).

Never launches GUI automation and never modifies anything.

.PARAMETER Profile
The DSH profile to verify. Defaults to 'web'.

.PARAMETER DshHome
Override the DSH home directory (default: $env:DSH_HOME, else ~/.dsh).

.PARAMETER DumpFile
Path to a previously captured `dsh --dump-config` output to inspect instead
of invoking dsh (useful offline or for testing).

.EXAMPLE
.\verify.ps1 -Profile web

.EXAMPLE
.\verify.ps1 -Profile web -DumpFile .\dump.txt
#>
[CmdletBinding()]
param(
    [string]$Profile = 'web',
    [string]$DshHome,
    [string]$DumpFile
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$PackageName = 'eve-map-assistant-dsh'
$ProjectRoot = $PSScriptRoot
$Helper = Join-Path $ProjectRoot 'tools\patch-file.mjs'
$Forbidden = @('C:\', 'C:/', 'Users\', '/users/', 'http://', 'https://', '.ps1', 'powershell', 'pwsh', 'shell', 'cmd.exe')
# Raw patch-text scan uses $ForbiddenRaw (no 'shell'): the bundle's own comment
# legitimately says "no shell wrapper", so 'shell' must not trip the text scan.
# Config-value portability (which also checks 'shell') lives in Assert-RowConfig.
$ForbiddenRaw = @('C:\', 'C:/', 'Users\', '/users/', 'http://', 'https://', '.ps1', 'powershell', 'pwsh', 'cmd.exe')

. (Join-Path $ProjectRoot 'tools\dsh-toolkit.ps1')

$script:Failures = @()
function Add-Failure([string]$Message) { $script:Failures += $Message }
function Write-Pass([string]$Message) { Write-Host "    PASS $Message" -ForegroundColor Green }

function Assert-RowConfig([object]$Row, [string]$Where) {
    $bad = @()
    if ((Get-Prop $Row 'id') -ne 'mcp-eve-map') { $bad += "${Where}: id is '$(Get-Prop $Row 'id')'" }
    if ((Get-Prop $Row 'name') -ne '@deepseek-ai/dsh-mcp-client') { $bad += "${Where}: name is '$(Get-Prop $Row 'name')'" }
    $cfg = Get-Prop $Row 'config'
    if ($null -eq $cfg) { $bad += "${Where}: missing config" }
    else {
        if ((Get-Prop $cfg 'serverName') -ne 'evemap')   { $bad += "${Where}: serverName is '$(Get-Prop $cfg 'serverName')' (expected 'evemap')" }
        if ((Get-Prop $cfg 'transport') -ne 'stdio')     { $bad += "${Where}: transport is '$(Get-Prop $cfg 'transport')' (expected 'stdio')" }
        if ((Get-Prop $cfg 'command') -ne 'eve-map-mcp.exe') { $bad += "${Where}: command is '$(Get-Prop $cfg 'command')' (expected 'eve-map-mcp.exe')" }
        if ($null -ne (Get-Prop $cfg 'url')) { $bad += "${Where}: config uses an HTTP url transport (not allowed)" }
        $dump = $cfg | ConvertTo-Json -Depth 20 -Compress
        foreach ($token in $Forbidden) {
            if ($dump.ToLowerInvariant().Contains($token.ToLowerInvariant())) { $bad += "${Where}: config contains '$token'" }
        }
    }
    return $bad
}

# ------------------------------------------------------------------ checks

Write-Step "EVE Map Assistant DSH bundle - verification (profile '$Profile')"
$DshHomeDir = Resolve-DshHomeDir -DshHome $DshHome
$ProfileDir = Join-Path $DshHomeDir (Join-Path 'profiles' $Profile)
$ManifestPath = Join-Path $ProfileDir 'package.json'
$PatchPath = Join-Path $ProfileDir 'cordis.patch.yml'
$InstalledPatch = Join-Path $ProfileDir (Join-Path 'node_modules' (Join-Path $PackageName 'cordis.patch.yml'))
$InstalledManifest = Join-Path $ProfileDir (Join-Path 'node_modules' (Join-Path $PackageName 'package.json'))
Write-Info "DSH home: $DshHomeDir"
Write-Info "Profile directory: $ProfileDir"

# Make a `dsh --dump-config` child process use the same home we resolved.
if (-not [string]::IsNullOrWhiteSpace($DshHome)) {
    $env:DSH_HOME = $DshHomeDir
}

# 1. eve-map-mcp.exe on PATH
$mcpExe = Get-Command eve-map-mcp.exe -ErrorAction SilentlyContinue
if ($mcpExe) { Write-Pass "eve-map-mcp.exe -> $($mcpExe.Source)" }
else { Write-Fail 'eve-map-mcp.exe not resolvable from PATH'; Add-Failure 'eve-map-mcp.exe not on PATH' }

# 2. DSH launcher
$Launcher = Resolve-DshLauncher
if ($Launcher) { Write-Pass "DSH launcher resolvable ($($Launcher.Label) @ $($Launcher.Source))" }
else { Write-Fail 'no DSH launcher (dsh on PATH, or npx)'; Add-Failure 'DSH launcher not resolvable' }

# 3. pnpm
$pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
if ($pnpm) { Write-Pass "pnpm -> $($pnpm.Source)" }
else { Write-Fail 'pnpm not available (required by DSH plugin management)'; Add-Failure 'pnpm not available' }

# 4. profile exists
if (Test-Path $ManifestPath) { Write-Pass "profile '$Profile' exists" }
else { Write-Fail "profile '$Profile' missing (no $ManifestPath)"; Add-Failure "profile '$Profile' missing" }

# 5. bundle installed
$JsYamlDir = Resolve-JsYamlDir
if (Test-Path $InstalledManifest) {
    Write-Pass "bundle installed at node_modules\$PackageName"
} else {
    Write-Fail "bundle not installed (no $InstalledManifest)"; Add-Failure 'bundle not installed in profile node_modules'
}

if (Test-Path $ManifestPath) {
    $manifest = Read-Manifest $ManifestPath
    $depPresent = $null -ne (Get-DepSpec $manifest $PackageName)
    $manifestBundles = @()
    $manifestBundlesValue = Get-NestedProp $manifest @('dsh', 'profile', 'bundles')
    if ($null -ne $manifestBundlesValue) { $manifestBundles = @($manifestBundlesValue) }
    $bundleListed = $manifestBundles -contains $PackageName
    if ($depPresent)  { Write-Pass "bundle in profile dependencies ($(Get-DepSpec $manifest $PackageName))" }
    else { Write-Fail 'bundle missing from profile dependencies'; Add-Failure 'bundle not in dependencies' }
    if ($bundleListed) { Write-Pass 'bundle in dsh.profile.bundles (layer stack)' }
    else { Write-Fail 'bundle missing from dsh.profile.bundles'; Add-Failure 'bundle not in dsh.profile.bundles' }
}

# 6. installed bundle patch content
if ((Test-Path $InstalledPatch) -and $JsYamlDir) {
    try {
        $validated = Invoke-Helper 'validate-patch' @($InstalledPatch) $JsYamlDir $Helper
        $rows = @($validated.rows | Where-Object { $_.id -eq 'mcp-eve-map' })
        if ($rows.Count -eq 1) {
            $issues = @(Assert-RowConfig $rows[0] 'installed bundle patch')
            if ($issues.Count -eq 0) { Write-Pass 'installed bundle patch declares exactly one correct mcp-eve-map row' }
            else { foreach ($i in $issues) { Write-Fail $i; Add-Failure $i } }
        } else {
            Write-Fail "installed bundle patch declares $($rows.Count) mcp-eve-map rows (expected 1)"
            Add-Failure 'installed bundle patch mcp-eve-map row count != 1'
        }
        $rawPatch = [System.IO.File]::ReadAllText($InstalledPatch)
        foreach ($token in $ForbiddenRaw) {
            if ($rawPatch.ToLowerInvariant().Contains($token.ToLowerInvariant())) {
                Write-Fail "installed bundle patch contains '$token'"
                Add-Failure "installed bundle patch contains '$token'"
            }
        }
    } catch {
        Write-Fail "installed bundle patch validation error: $($_.Exception.Message)"
        Add-Failure "installed bundle patch validation: $($_.Exception.Message)"
    }
} elseif (-not $JsYamlDir) {
    Write-Fail 'js-yaml could not be resolved from the DSH installation (via dsh or the npx cache); skipping patch-content checks'
    Add-Failure 'js-yaml not resolvable (needed for patch inspection)'
} else {
    Write-Fail "installed bundle patch missing ($InstalledPatch)"
    Add-Failure 'installed bundle patch file missing'
}

# 7. no manual duplicate in the profile patch layer
if ((Test-Path $PatchPath) -and $JsYamlDir) {
    $detect = Invoke-Helper 'detect' @($PatchPath) $JsYamlDir $Helper
    if ($detect.found) {
        Write-Fail 'manual mcp-eve-map insert still present in profile cordis.patch.yml (duplicate ownership)'
        Add-Failure 'manual mcp-eve-map insert in cordis.patch.yml'
    } else {
        Write-Pass 'no manual mcp-eve-map insert in profile cordis.patch.yml (single ownership)'
    }
}

# 8. effective (dumped) configuration
$dumpText = $null
$tempDump = $null
if (-not [string]::IsNullOrWhiteSpace($DumpFile)) {
    if (Test-Path $DumpFile) {
        Write-Info "using pre-captured dump: $DumpFile"
        $dumpText = [System.IO.File]::ReadAllText($DumpFile)
    } else {
        Write-Fail "-DumpFile not found: $DumpFile"; Add-Failure "-DumpFile missing: $DumpFile"
    }
} elseif ($Launcher) {
    $tempDump = Join-Path $env:TEMP "dsh-dump-$Profile-$([guid]::NewGuid().ToString('N')).txt"
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    try {
        $dumpArgs = @('--profile', $Profile, '--dump-config')
        if ($Launcher.Prefix.Count -gt 0) { $dumpArgs = @($Launcher.Prefix) + $dumpArgs }
        $captured = & $Launcher.Command @dumpArgs 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Fail "dsh --dump-config failed with exit code $LASTEXITCODE"; Add-Failure 'dsh --dump-config failed' }
        else { Write-Utf8NoBom $tempDump $captured; $dumpText = $captured }
    } finally {
        [Console]::OutputEncoding = $prevEncoding
    }
} else {
    Write-Info 'no DSH launcher - skipping effective-config dump check'
}

if ($null -ne $dumpText -and $JsYamlDir) {
    try {
        $dumpFileForParse = $tempDump
        if ([string]::IsNullOrWhiteSpace($dumpFileForParse)) {
            $dumpFileForParse = Join-Path $env:TEMP "dsh-dump-$Profile-$([guid]::NewGuid().ToString('N')).txt"
            Write-Utf8NoBom $dumpFileForParse $dumpText
        }
        $parsed = Invoke-Helper 'dump-parse' @($dumpFileForParse) $JsYamlDir $Helper
        $allRows = @()
        foreach ($group in $parsed.groups) { $allRows += @($group.rows) }
        $mcpRows = @($allRows | Where-Object { $_.id -eq 'mcp-eve-map' })
        if ($mcpRows.Count -eq 1) {
            $groupLabel = ($parsed.groups | Where-Object { @($_.rows | Where-Object { $_.id -eq 'mcp-eve-map' }).Count -gt 0 } | Select-Object -First 1).label
            $issues = @(Assert-RowConfig $mcpRows[0] 'effective config')
            if ($issues.Count -eq 0) {
                Write-Pass "mcp-eve-map exists exactly once in the effective config (owned by: $groupLabel)"
            } else {
                foreach ($i in $issues) { Write-Fail $i; Add-Failure $i }
            }
            if ($groupLabel -notlike "$PackageName*") {
                Write-Fail "mcp-eve-map is not owned by the '$PackageName' bundle layer (found in: $groupLabel)"
                Add-Failure "mcp-eve-map ownership is '$groupLabel', expected '$PackageName'"
            }
        } else {
            Write-Fail "mcp-eve-map must exist exactly once in the effective config, found $($mcpRows.Count)"
            Add-Failure "mcp-eve-map effective count is $($mcpRows.Count), expected 1"
        }
    } catch {
        Write-Fail "dump inspection error: $($_.Exception.Message)"
        Add-Failure "dump inspection: $($_.Exception.Message)"
    }
} elseif ($null -ne $dumpText) {
    Write-Info 'js-yaml not resolvable - skipped effective-config inspection'
}

if ($tempDump) { Remove-Item -LiteralPath $tempDump -Force -ErrorAction SilentlyContinue }

# ------------------------------------------------------------------ summary

Write-Step 'Summary'
if ($script:Failures.Count -eq 0) {
    Write-Host 'ALL CHECKS PASSED - EVE Map Assistant DSH bundle is correctly installed for profile' $Profile -ForegroundColor Green
    exit 0
} else {
    Write-Host "VERIFICATION FAILED - $($script:Failures.Count) problem(s):" -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
