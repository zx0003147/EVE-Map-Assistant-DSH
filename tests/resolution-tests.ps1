<#
.SYNOPSIS
Static resolution tests for both supported DSH launcher modes:

  1. global `dsh` on PATH
  2. npx-only DSH (no `dsh` on PATH; the package lives in npm's npx cache)

Read-only: never modifies profiles, never installs anything, never touches the
live DSH home. It exercises the shared toolkit (tools/dsh-toolkit.ps1) against
the real environment layout and asserts that the DSH package directory and
js-yaml are discovered in both modes without hardcoding usernames, cache
hashes, or machine paths.

Scenario 2 simulates the npx-only environment by temporarily restricting PATH
to only the directories that provide node/npm/npx (which excludes any `dsh`
shim), then restoring it.

.EXAMPLE
.\tests\resolution-tests.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'tools\dsh-toolkit.ps1')

$script:Failures = @()
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "PASS  $Name" -ForegroundColor Green
    } catch {
        Write-Host "FAIL  $Name - $($_.Exception.Message)" -ForegroundColor Red
        $script:Failures += $Name
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-DshPackageDir {
    $dir = Resolve-DshPackageDir
    Assert-True (-not [string]::IsNullOrWhiteSpace($dir)) 'no DSH package directory found'
    $m = Get-Content (Join-Path $dir 'package.json') -Raw | ConvertFrom-Json
    Assert-True ($m.name -eq '@deepseek-ai/dsh') "unexpected package name '$($m.name)'"
    return $dir
}

function Assert-JsYamlDir {
    $dir = Resolve-JsYamlDir
    Assert-True (-not [string]::IsNullOrWhiteSpace($dir)) 'js-yaml could not be resolved'
    Assert-True (Test-Path (Join-Path $dir 'index.js')) "js-yaml index.js missing at $dir"
    return $dir
}

# ------------------------------------------------------ scenario 1: global dsh
Write-Host '== Scenario 1: global dsh on PATH ==' -ForegroundColor Cyan
$realDsh = Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1
if ($realDsh) {
    Test-Case 'dsh-mode: launcher detection prefers dsh' {
        $l = Resolve-DshLauncher
        Assert-True ($l.Label -eq 'dsh') "expected launcher 'dsh', got '$($l.Label)'"
    }
    Test-Case 'dsh-mode: DSH package dir discovered from the dsh shim' {
        $dir = Assert-DshPackageDir
        Write-Host "        (package dir: $dir)" -ForegroundColor DarkGray
    }
    Test-Case 'dsh-mode: js-yaml resolved from the DSH install' {
        $dir = Assert-JsYamlDir
        Write-Host "        (js-yaml: $dir)" -ForegroundColor DarkGray
    }
} else {
    Write-Host 'NOTE  dsh is not on PATH on this machine - scenario 1 skipped (expected for npx-only environments)' -ForegroundColor Yellow
}

# ------------------------------------------------------ scenario 2: npx only
Write-Host '== Scenario 2: npx-only DSH (dsh hidden from PATH) ==' -ForegroundColor Cyan
$nodeExe = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
$npxCmd = Get-Command npx -ErrorAction SilentlyContinue | Select-Object -First 1
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
Assert-True ($null -ne $nodeExe) 'node not found (required for the npx-only scenario)'
Assert-True ($null -ne $npxCmd) 'npx not found (required for the npx-only scenario)'
Assert-True ($null -ne $npmCmd) 'npm not found (required to locate the npx cache)'

$keepDirs = @{}
foreach ($cmd in @($nodeExe, $npxCmd, $npmCmd)) {
    if ($null -ne $cmd) { $keepDirs[(Split-Path $cmd.Source -Parent)] = $true }
}
$realPath = $env:PATH
$env:PATH = ($keepDirs.Keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
try {
    Test-Case 'npx-mode: dsh is not visible on PATH (scenario is valid)' {
        $d = Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1
        Assert-True ($null -eq $d) 'dsh is still visible on PATH - npx-only scenario not simulated'
    }
    Test-Case 'npx-mode: launcher detection falls back to npx' {
        $l = Resolve-DshLauncher
        Assert-True ($l.Label -eq 'npx @deepseek-ai/dsh') "expected npx launcher, got '$($l.Label)'"
    }
    Test-Case 'npx-mode: DSH package dir discovered via npm npx cache' {
        $dir = Assert-DshPackageDir
        Write-Host "        (package dir: $dir)" -ForegroundColor DarkGray
    }
    Test-Case 'npx-mode: js-yaml resolved from the npx-cached DSH install' {
        $dir = Assert-JsYamlDir
        Write-Host "        (js-yaml: $dir)" -ForegroundColor DarkGray
    }
} finally {
    $env:PATH = $realPath
}

# ---------------------------------------------------------------- summary
Write-Host '== Summary ==' -ForegroundColor Cyan
if ($script:Failures.Count -gt 0) {
    Write-Host "RESOLUTION TESTS FAILED: $($script:Failures -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL RESOLUTION TESTS PASSED (both launcher modes discover DSH and js-yaml)' -ForegroundColor Green
exit 0
