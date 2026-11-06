<#
.SYNOPSIS
Smoke tests a built windows-nano-editors image: each editor loads and reports its version, and Helix finds its runtime.
.DESCRIPTION
CI has no console to give the editors (docker run -it needs a TTY), so these are the non-interactive checks from
plans/console-editors.md, phase 1. Each check runs in its own throwaway container. Throws on the first failure.
.PARAMETER Image
The image to test.
.EXAMPLE
./nano-server/nano-server-editors/smoke-test.ps1 -Image windows-nano-editors:2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image
)
$ErrorActionPreference = 'Stop'
Write-Host "Smoke testing $Image"

# Runs one command in a fresh container and returns its output; throws if it exits non-zero
function Invoke-Image {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Command)
    $out = docker run --rm $Image @Command 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Host "> $($Command -join ' ')"
    Write-Host $out.TrimEnd()
    if ($code) { throw "'$($Command -join ' ')' exited with $code" }
    return $out
}

$checks = [ordered]@{
    # The v2.0.0 release's edit.exe reports 1.2.1; the SHA-256 pinned in the Dockerfile identifies the build
    'edit --version' = 'edit version \d+\.\d+\.\d+'
    'nano --version' = 'GNU nano for Windows 64 bits, v7\.2-22\.1'
    'hx --version'   = 'helix 25\.07\.1'
}
foreach ($check in $checks.GetEnumerator()) {
    $out = Invoke-Image @($check.Key -split ' ')
    if ($out -notmatch $check.Value) { throw "'$($check.Key)' didn't print /$($check.Value)/" }
    Write-Host "ok: $($check.Key)"
}

# hx --health reads the runtime folder and lists every language. It must work with no language servers installed.
$health = Invoke-Image hx --health
if ($health -notmatch '(?m)^\s*rust\b') { throw "hx --health didn't list the rust language: is HELIX_RUNTIME set?" }
# The per-user runtime folder under AppData is optional and missing; the image's own one, from HELIX_RUNTIME, must be found
if ($health -notmatch 'Runtime directories: .*C:\\Program Files\\helix\\runtime') { throw "hx --health doesn't use HELIX_RUNTIME" }
if ($health -match 'Runtime directory does not exist: C:\\Program Files\\helix') { throw 'hx --health says the image runtime is missing' }
Write-Host 'ok: hx --health lists the languages from its runtime'
