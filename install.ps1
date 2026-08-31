<#
.SYNOPSIS
Installs the eve-map-assistant-dsh bundle into a DSH profile.

.DESCRIPTION
Default: installs straight from the GitHub repository
  https://github.com/zx0003147/EVE-Map-Assistant-DSH
using DSH's official plugin mechanism (dsh plugin --profile <profile> add
git+https://...). Pass -FromCheckout to pack the local checkout into a
tarball and install from that instead. After installing, copies the
eve-map-assistant skill into the DSH home so any session can use it.

.PARAMETER Profile
DSH profile to install into (default: web).

.PARAMETER FromCheckout
Pack this local checkout (pnpm pack) and install the resulting tarball
instead of using the GitHub URL.

.PARAMETER DryRun
Check prerequisites and print the plan without changing anything.

.PARAMETER DshHome
Override DSH home (default: $env:DSH_HOME, else ~/.dsh).
#>
[CmdletBinding()]
param(
    [string]$Profile = "web",
    [switch]$FromCheckout,
    [switch]$DryRun,
    [string]$DshHome = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoUrl = "https://github.com/zx0003147/EVE-Map-Assistant-DSH.git"

function Test-Command([string]$name) {
    return ($null -ne (Get-Command $name -ErrorAction SilentlyContinue))
}

function Invoke-Native([string]$cmd, [string[]]$args, [string]$outFile, [string]$errFile) {
    $quoted = @($cmd) + $args | ForEach-Object { '"' + $_.Replace('"', '""') + '"' }
    $redirect = "> `"$outFile`" 2> `"$errFile`""
    & cmd /c (($quoted -join ' ') + " " + $redirect)
    if ($LASTEXITCODE -ne 0) {
        $err = if (Test-Path $errFile) { (Get-Content $errFile -Raw) } else { "" }
        throw "Command failed ($LASTEXITCODE): $cmd $($args -join ' ')`n$err"
    }
}

# ── prerequisites ───────────────────────────────────────────────────────────
if (-not (Test-Command dsh)) { throw "dsh launcher not found on PATH." }
if (-not (Test-Command pnpm)) { throw "pnpm not found on PATH (npm install -g pnpm)." }
if (-not (Test-Command git)) { throw "git not found on PATH (required to install from GitHub)." }

if (-not $DshHome) { $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME ".dsh" } }
$profileDir = Join-Path $DshHome "profiles\$Profile"
if (-not (Test-Path $profileDir)) { throw "Profile '$Profile' not found under $DshHome/profiles." }

Write-Host "Profile: $Profile ($profileDir)"
if ($FromCheckout) {
    $pkg = Get-Content (Join-Path $root "package.json") -Raw | ConvertFrom-Json
    $tgz = Join-Path $root ("{0}-{1}.tgz" -f $pkg.name, $pkg.version)
    Write-Host "Source: local checkout -> $tgz"
} else {
    Write-Host "Source: $repoUrl"
}

if ($DryRun) {
    Write-Host "[dry-run] would install the bundle and copy the skill; nothing changed."
    exit 0
}

# ── install the bundle ──────────────────────────────────────────────────────
$out = Join-Path $env:TEMP ("dsh-eve-out-" + [guid]::NewGuid().ToString("N") + ".txt")
$err = Join-Path $env:TEMP ("dsh-eve-err-" + [guid]::NewGuid().ToString("N") + ".txt")
try {
    if ($FromCheckout) {
        $packOut = Join-Path $env:TEMP ("dsh-eve-pack-" + [guid]::NewGuid().ToString("N") + ".txt")
        $packErr = Join-Path $env:TEMP ("dsh-eve-pack-" + [guid]::NewGuid().ToString("N") + ".txt")
        Invoke-Native "pnpm" @("pack", "--pack-destination", $root) $packOut $packErr
        Remove-Item $packOut, $packErr -ErrorAction SilentlyContinue
        Invoke-Native "dsh" @("plugin", "--profile", $Profile, "add", ("file:" + $tgz)) $out $err
    } else {
        Invoke-Native "dsh" @("plugin", "--profile", $Profile, "add", ("git+" + $repoUrl)) $out $err
    }
} finally {
    Remove-Item $out, $err -ErrorAction SilentlyContinue
}
Write-Host "Bundle installed into profile '$Profile'."

# ── install the skill (global, any session can use it) ─────────────────────
$skillSrc = Join-Path $root ".dsh\skills\eve-map-assistant\SKILL.md"
$skillDst = Join-Path $DshHome "skills\eve-map-assistant\SKILL.md"
if (Test-Path $skillSrc) {
    New-Item -ItemType Directory -Path (Split-Path $skillDst -Parent) -Force | Out-Null
    Copy-Item -Force $skillSrc $skillDst
    Write-Host "Skill copied to $skillDst"
} else {
    Write-Host "WARN: skill source not found next to this script ($skillSrc); skill not installed."
}

# ── verify ──────────────────────────────────────────────────────────────────
$verify = Join-Path $root "verify.ps1"
if (Test-Path $verify) { & $verify -Profile $Profile } else { Write-Host "verify.ps1 not present; skipping." }
Write-Host "Done. Restart DSH (and open a new conversation) for the MCP tools to appear."
