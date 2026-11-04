<#
.SYNOPSIS
Starts the artifact cache container on the host, with its cache and Caddy data on host folders.

.DESCRIPTION
Creates the host folders if they are missing, starts the container detached with
--restart unless-stopped, waits for /healthz, then writes the root CA certificate and a
client setup script (see New-ArtifactCacheClientSetup.ps1) next to the data folders and
prints the container's IP address.

The caddy-data folder holds the internal CA's private key. Anyone who can read it can mint
certificates that every client of the cache trusts, so keep it readable only by administrators.

If a container with the same name is already running, it is left alone and its details are printed.

.EXAMPLE
./nano-server-artifact-cache/Start-ArtifactCache.ps1
.EXAMPLE
./nano-server-artifact-cache/Start-ArtifactCache.ps1 -Image zippy1981/windows-nano-artifact-cache:2025 -Isolation hyperv
#>
[CmdletBinding()]
param(
    [string]$Image = 'windows-nano-artifact-cache:2025',
    [string]$Name = 'windows-nano-artifact-cache',
    [string]$Root = 'C:\ProgramData\windows-nano-demos\artifact-cache',
    [string]$CachePath = (Join-Path $Root 'cache'),
    [string]$DataPath = (Join-Path $Root 'caddy-data'),
    [ValidateSet('process', 'hyperv')][string]$Isolation = 'process',
    [int]$HealthTimeoutSeconds = 60
)
$ErrorActionPreference = 'Stop'

foreach ($path in $Root, $CachePath, $DataPath) {
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}
# ProgramData lets every user read new folders. caddy-data holds the CA private key, so limit it
# to Administrators and SYSTEM (the docker daemon), replacing the inherited entries.
icacls $DataPath /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE) { throw "icacls on $DataPath failed: $LASTEXITCODE" }

$state = docker inspect -f '{{.State.Running}}' $Name 2>$null
if ($state -eq 'true') {
    Write-Host "$Name is already running"
}
else {
    if ($state) {
        # A stopped container from an earlier run: replace it so the current image and settings apply
        docker rm -f $Name | Out-Null
    }
    docker run -d --name $Name --restart unless-stopped --isolation=$Isolation `
        -v "${CachePath}:C:\cache" -v "${DataPath}:C:\caddy-data" $Image | Out-Null
    if ($LASTEXITCODE) { throw "docker run failed: $LASTEXITCODE" }
}

$ip = docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $Name
if (-not $ip) { throw "$Name has no IP address" }

$deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
do {
    Start-Sleep -Seconds 2
    $health = curl.exe -fsS -m 5 "http://${ip}:8080/healthz" 2>$null
} until ($health -eq 'ok' -or (Get-Date) -gt $deadline)
if ($health -ne 'ok') {
    docker logs --tail 50 $Name
    throw "$Name did not answer http://${ip}:8080/healthz within $HealthTimeoutSeconds seconds"
}

$rootCert = Join-Path $Root 'root.crt'
curl.exe -fsS -m 10 -o $rootCert "http://${ip}:8080/root.crt"
if ($LASTEXITCODE) { throw "fetching root.crt failed: $LASTEXITCODE" }

$setup = Join-Path $Root 'use-artifact-cache.cmd'
@('@echo off', 'rem Run as ContainerAdministrator in a nanoserver container or build stage to use the artifact cache') +
(& "$PSScriptRoot/New-ArtifactCacheClientSetup.ps1" -RootCertificate $rootCert -CacheAddress $ip | ForEach-Object { "$_ || exit /b 1" }) |
    Set-Content -Path $setup -Encoding ascii

[pscustomobject]@{
    Name            = $Name
    IPAddress       = $ip
    RootCertificate = $rootCert
    ClientSetup     = $setup
    CachePath       = $CachePath
    DataPath        = $DataPath
}
