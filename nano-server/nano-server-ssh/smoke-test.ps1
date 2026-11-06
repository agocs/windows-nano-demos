<#
.SYNOPSIS
Smoke tests a built windows-nano-ssh image: a normal user with password and key auth, then an administrator with key auth only.
.EXAMPLE
./nano-server/nano-server-ssh/smoke-test.ps1 -Image windows-nano-ssh:2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image
)
$ErrorActionPreference = 'Stop'

# test.ps1 starts the server and a second container of the same image as the client, reached over the nat network by IP
& "$PSScriptRoot/test.ps1" -Image $Image
& "$PSScriptRoot/test.ps1" -Image $Image -Admin -KeyOnly
