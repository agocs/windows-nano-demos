<#
.SYNOPSIS
Stops and removes the artifact cache container. The cached files and Caddy data on the host are kept.
.EXAMPLE
./nano-server-artifact-cache/Stop-ArtifactCache.ps1
#>
[CmdletBinding()]
param(
    [string]$Name = 'windows-nano-artifact-cache'
)
$ErrorActionPreference = 'Stop'

if (docker ps -a --filter "name=^$Name$" -q) {
    docker rm -f $Name | Out-Null
    if ($LASTEXITCODE) { throw "docker rm failed: $LASTEXITCODE" }
    Write-Host "Removed $Name"
}
else {
    Write-Host "$Name is not running"
}
