<#
.SYNOPSIS
Smoke tests a built windows-nano-gh-runner image: pwsh, the powershell.exe stand-in, git (including submodule, which needs sh), the docker CLI and the runner.
.EXAMPLE
./nano-server/nano-server-gh-runner/smoke-test.ps1 -Image windows-nano-gh-runner:2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image
)
$ErrorActionPreference = 'Stop'

$script = @'
$ErrorActionPreference = 'Stop'
"pwsh $($PSVersionTable.PSVersion)"
& powershell.exe -NoProfile -Command '"powershell.exe shim ok"'
git --version
git init -q C:\t
git -C C:\t submodule foreach --recursive 'sh -c "true"'
if ($LASTEXITCODE) { throw "git submodule failed: $LASTEXITCODE" }
docker --version
& C:\actions-runner\bin\Runner.Listener.exe --version
'@
# Encoded so quotes survive the trip through docker's command line
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
$out = docker run --rm --entrypoint 'C:\Program Files\PowerShell\7\pwsh.exe' $Image -NoProfile -OutputFormat Text -EncodedCommand $encoded
$code = $LASTEXITCODE
$out | Write-Host
if ($code) { throw "smoke test failed: $code" }
if (-not ($out -match 'powershell.exe shim ok')) { throw 'powershell.exe shim missing' }
