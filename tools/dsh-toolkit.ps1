# dsh-toolkit.ps1 - shared installer/verifier toolkit for the EVE Map
# Assistant DSH bundle. Dot-source from install.ps1 / uninstall.ps1 /
# verify.ps1 (and reuse in tests):
#
#     . (Join-Path $PSScriptRoot 'tools\dsh-toolkit.ps1')
#
# This module defines functions only; it does not execute anything at load.
# All DSH/runtime discovery here is resilient to BOTH supported DSH modes:
#
#   * a global `dsh` on PATH
#   * npx-only DSH (`npx --yes @deepseek-ai/dsh`), where the package lives in
#     npm's npx cache rather than a normal project node_modules
#
# Nothing here hardcodes user names, npm cache hashes, or absolute machine
# paths. js-yaml is resolved exactly the way dsh itself resolves its own
# dependencies (Node module resolution anchored at the discovered
# @deepseek-ai/dsh package.json), so it works for npm-global, npx-cache, and
# pnpm layouts alike.

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Ok([string]$Message)   { Write-Host "    OK  $Message" -ForegroundColor Green }
function Write-Fail([string]$Message) { Write-Host "    ERR $Message" -ForegroundColor Red }

function Assert-ProfileName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'profile name must not be empty' }
    if ($Name -eq '.' -or $Name -eq '..' -or $Name -eq 'node_modules' -or $Name.Contains('/') -or $Name.Contains('\')) {
        throw "invalid profile name '$Name'"
    }
}

function Resolve-DshHomeDir {
    param([string]$DshHome)
    if (-not [string]::IsNullOrWhiteSpace($DshHome)) { return $DshHome }
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) { return $env:DSH_HOME }
    return Join-Path $env:USERPROFILE '.dsh'
}

function Resolve-DshLauncher {
    # 1) dsh on PATH  2) npx @deepseek-ai/dsh  3) clear prerequisite error.
    $dsh = Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dsh) {
        Write-Info "DSH launcher: dsh ($($dsh.Source))"
        return @{ Command = 'dsh'; Prefix = @(); Label = 'dsh'; Source = $dsh.Source }
    }
    $npx = Get-Command npx -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($npx) {
        Write-Info "DSH launcher: npx --yes @deepseek-ai/dsh ($($npx.Source))"
        return @{ Command = 'npx'; Prefix = @('--yes', '@deepseek-ai/dsh'); Label = 'npx @deepseek-ai/dsh'; Source = $npx.Source }
    }
    throw 'no DSH launcher found: install dsh on PATH, or ensure npx is available (npm ships npx)'
}

function Invoke-Dsh {
    param(
        [object]$Launcher,
        [string[]]$DshArgs
    )
    $allArgs = @()
    if ($Launcher.Prefix.Count -gt 0) { $allArgs = @($Launcher.Prefix) }
    $allArgs += $DshArgs
    # Stream the child's stdout to the host so pnpm/dsh progress stays visible,
    # while keeping it out of this function's return value.
    & $Launcher.Command @allArgs | ForEach-Object { Write-Host $_ }
    return $LASTEXITCODE
}

function Resolve-DshPackageDir {
    # Discover the real @deepseek-ai/dsh package directory for whichever
    # launcher mode is active, without hardcoding usernames, cache hashes, or
    # machine paths. Returns the package directory or $null.
    #
    # 1) Global `dsh` on PATH: the shim lives in a node_modules-adjacent bin
    #    dir; walk up looking for node_modules\@deepseek-ai\dsh.
    $dsh = Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dsh) {
        $dir = Split-Path $dsh.Source -Parent
        for ($i = 0; $i -lt 12 -and -not [string]::IsNullOrWhiteSpace($dir); $i++) {
            foreach ($candidate in @(
                (Join-Path $dir 'node_modules\@deepseek-ai\dsh\package.json'),
                (Join-Path $dir '@deepseek-ai\dsh\package.json')
            )) {
                if (Test-Path $candidate) { return Split-Path $candidate -Parent }
            }
            $parent = Split-Path $dir -Parent
            if ($parent -eq $dir) { break }
            $dir = $parent
        }
    }
    # 2) npx-only DSH: npx materializes the package under
    #    <npm cache>\_npx\<hash>\node_modules\@deepseek-ai\dsh. Locate the npm
    #    cache via the environment first, then `npm config get cache`, then the
    #    default LOCALAPPDATA location, and scan every _npx entry.
    $npx = Get-Command npx -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($npx) {
        $cacheRoots = @()
        if (-not [string]::IsNullOrWhiteSpace($env:npm_config_cache)) { $cacheRoots += $env:npm_config_cache }
        try {
            $configured = & npm config get cache 2>$null | Select-Object -First 1
            if (-not [string]::IsNullOrWhiteSpace($configured)) { $cacheRoots += $configured }
        } catch { }
        $cacheRoots += (Join-Path $env:LOCALAPPDATA 'npm-cache')
        foreach ($cacheRoot in ($cacheRoots | Select-Object -Unique)) {
            $npxRoot = Join-Path $cacheRoot '_npx'
            if (Test-Path $npxRoot) {
                foreach ($entry in (Get-ChildItem $npxRoot -Directory -ErrorAction SilentlyContinue)) {
                    $candidate = Join-Path $entry.FullName 'node_modules\@deepseek-ai\dsh\package.json'
                    if (Test-Path $candidate) { return Split-Path $candidate -Parent }
                }
            }
        }
    }
    # 3) Global npm root fallback.
    try {
        $globalRoot = & npm root -g 2>$null | Select-Object -First 1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($globalRoot)) {
            $candidate = Join-Path $globalRoot '@deepseek-ai\dsh\package.json'
            if (Test-Path $candidate) { return Split-Path $candidate -Parent }
        }
    } catch { }
    return $null
}

function Resolve-JsYamlDir {
    # Resolve js-yaml exactly the way dsh itself resolves its dependencies:
    # Node's module resolution anchored at the discovered @deepseek-ai/dsh
    # package.json (js-yaml is a direct dependency of @deepseek-ai/dsh in
    # every installation layout: npm-global hoisting, the npx cache, pnpm).
    $pkgDir = Resolve-DshPackageDir
    if (-not $pkgDir) { return $null }
    $pkgJson = Join-Path $pkgDir 'package.json'
    $probe = @'
const { createRequire } = require('module');
const { dirname } = require('path');
try {
  const r = createRequire(process.argv[1]);
  process.stdout.write(dirname(r.resolve('js-yaml/package.json')));
} catch (e) { process.exit(1); }
'@
    $raw = & node -e $probe $pkgJson 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { return $null }
    $line = $raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    if (Test-Path (Join-Path $line 'package.json')) { return $line }
    return $null
}

function Invoke-Helper {
    param(
        [string]$Mode,
        [string[]]$Positionals,
        [string]$JsYamlDir,
        [string]$Helper
    )
    $args = @($Mode) + $Positionals
    if ($JsYamlDir) { $args += @('--jsyaml', $JsYamlDir) }
    $json = & node $Helper @args 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { throw "patch-file helper failed: $json" }
    return ($json | ConvertFrom-Json)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Manifest([string]$Path) {
    $raw = [System.IO.File]::ReadAllText($Path)
    try { return ($raw | ConvertFrom-Json) } catch { throw "profile manifest $Path is not valid JSON: $($_.Exception.Message)" }
}

function Write-Manifest([string]$Path, [object]$Manifest) {
    $json = $Manifest | ConvertTo-Json -Depth 100
    Write-Utf8NoBom $Path ($json + "`n")
}

function Get-Prop([object]$Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-NestedProp([object]$Obj, [string[]]$Names) {
    $current = $Obj
    foreach ($name in $Names) {
        if ($null -eq $current) { return $null }
        $prop = $current.PSObject.Properties[$name]
        if ($null -eq $prop) { return $null }
        $current = $prop.Value
    }
    return $current
}

function Get-DepSpec([object]$Manifest, [string]$PackageName) {
    $deps = Get-NestedProp $Manifest @('dependencies')
    if ($null -eq $deps) { return $null }
    return (Get-Prop $deps $PackageName)
}

function Get-Timestamp { return (Get-Date -Format 'yyyyMMddHHmmss') }

function Backup-IfNeeded([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $backup = "$Path.bak-$(Get-Timestamp)"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    return $backup
}

function Remove-LegacyBundlesFromManifest([object]$Manifest, [string[]]$LegacyBundleNames) {
    # Returns $true when something was removed, mutating $Manifest in place.
    $changed = $false
    $deps = Get-NestedProp $Manifest @('dependencies')
    if ($null -ne $deps) {
        $props = @($deps.PSObject.Properties.Name)
        foreach ($name in $props) {
            if ($LegacyBundleNames -contains $name) {
                $null = $deps.PSObject.Properties.Remove($name)
                $changed = $true
            }
        }
    }
    $bundlesValue = Get-NestedProp $Manifest @('dsh', 'profile', 'bundles')
    if ($null -ne $bundlesValue) {
        $bundles = @($bundlesValue)
        $filtered = @($bundles | Where-Object { $LegacyBundleNames -notcontains $_ })
        if ($filtered.Count -ne $bundles.Count) {
            $Manifest.dsh.profile.bundles = $filtered
            $changed = $true
        }
    }
    return $changed
}
