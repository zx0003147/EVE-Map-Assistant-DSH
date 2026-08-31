<#
.SYNOPSIS
Removes the eve-map-assistant-dsh bundle from a DSH profile.

.DESCRIPTION
Uses the official removal mechanism (dsh plugin --profile <profile> remove
eve-map-assistant-dsh). Removes only this bundle; EVE Static Map Planner, map
data, DSH sessions, other plugins, and unrelated profile configuration are
never touched. Leaves the skill in the DSH home (delete
$DshHome/skills/eve-map-assistant by hand if you want it gone too).

.PARAMETER Profile
DSH profile to remove from (default: web).

.PARAMETER DshHome
Override DSH home (default: $env:DSH_HOME, else ~/.dsh).
#>
[CmdletBinding()]
param(
    [string]$Profile = "web",
    [string]$DshHome = ""
)

$ErrorActionPreference = "Stop"

if (-not $DshHome) { $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME ".dsh" } }
$profileDir = Join-Path $DshHome "profiles\$Profile"
if (-not (Test-Path $profileDir)) { throw "Profile '$Profile' not found under $DshHome/profiles." }

& dsh plugin --profile $Profile remove eve-map-assistant-dsh
if ($LASTEXITCODE -ne 0) { throw "dsh plugin remove failed." }

Write-Host "Removed eve-map-assistant-dsh from profile '$Profile'."
