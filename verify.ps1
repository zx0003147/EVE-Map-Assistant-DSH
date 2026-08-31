<#
.SYNOPSIS
Verifies the eve-map-assistant-dsh bundle installation in a DSH profile.

.DESCRIPTION
Non-destructive. Checks that:
- the composed profile contains exactly one mcp-eve-map row
- that row uses serverName=eve-static-map, transport=streamable-http,
  url=http://127.0.0.1:27892/mcp
- no absolute path, user name, or credential appears in the row config

.PARAMETER Profile
DSH profile to verify (default: web).

.PARAMETER DumpFile
Skip invoking dsh and verify against a previously captured dump file instead.
#>
[CmdletBinding()]
param(
    [string]$Profile = "web",
    [string]$DumpFile = ""
)

$ErrorActionPreference = "Stop"

function Test-Command([string]$name) {
    return ($null -ne (Get-Command $name -ErrorAction SilentlyContinue))
}

if (-not $DumpFile) {
    if (-not (Test-Command dsh)) { throw "dsh launcher not found on PATH." }
    $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME ".dsh" }
    $profileDir = Join-Path $DshHome "profiles\$Profile"
    if (-not (Test-Path $profileDir)) { throw "Profile '$Profile' not found under $DshHome/profiles." }
    $DumpFile = Join-Path $env:TEMP ("dsh-dump-" + [guid]::NewGuid().ToString("N") + ".txt")
    & cmd /c "dsh --profile `"$Profile`" --dump-config > `"$DumpFile`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        $err = if (Test-Path $DumpFile) { Get-Content $DumpFile -Raw } else { "(no output)" }
        throw "dsh --dump-config failed ($LASTEXITCODE): $err"
    }
}

$dump = Get-Content $DumpFile -Raw

# The dump is a tree of plugin rows; find the mcp-eve-map row and its block.
# Rows render as `- id: <id>` list items followed by indented name/config.
$mcpRows = [regex]::Matches($dump, '(?ms)^\s*-\s*id:\s*mcp-eve-map.*?(?=^\S|\z)')
if ($mcpRows.Count -eq 0) { throw "FAIL: no mcp-eve-map row found in composed config." }
if ($mcpRows.Count -gt 1) { throw "FAIL: more than one mcp-eve-map row ($($mcpRows.Count))." }

$row = $mcpRows[0].Value
$checks = @(
    @{ name = "serverName = eve-static-map"; ok = $row -match 'serverName:\s*eve-static-map' },
    @{ name = "transport = streamable-http"; ok = $row -match 'transport:\s*streamable-http' },
    @{ name = "url = http://127.0.0.1:27892/mcp"; ok = $row -match 'url:\s*http://127\.0\.0\.1:27892/mcp' },
    @{ name = "no absolute executable path"; ok = $row -notmatch 'command:\s*[A-Za-z]:\\|command:\s*[A-Za-z]:/' },
    @{ name = "no credentials/tokens"; ok = $row -notmatch 'token|secret|password|api[_-]?key' }
)

$failed = @($checks | Where-Object { -not $_.ok })
foreach ($c in $checks) {
    Write-Host ("{0} {1}" -f $(if ($c.ok) { "[ok]" } else { "[FAIL]" }), $c.name)
}
if ($failed.Count -gt 0) {
    throw "FAIL: $($failed.Count) check(s) failed. Row was:`n$row"
}
Write-Host "OK: composed profile has exactly one mcp-eve-map row with the HTTP configuration."
