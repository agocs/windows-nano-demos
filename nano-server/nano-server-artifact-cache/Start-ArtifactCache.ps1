<#
.SYNOPSIS
Starts the artifact cache container on this Windows host.
.DESCRIPTION
Creates the host cache and Caddy data folders if needed, then runs the
windows-nano-artifact-cache image detached with --restart unless-stopped.
Both folders are bind-mounted, so cached files and the internal CA survive
container replacement and host restarts.
.EXAMPLE
./nano-server/nano-server-artifact-cache/Start-ArtifactCache.ps1
#>
[CmdletBinding()]
param(
    [string]$Image = 'windows-nano-artifact-cache:2025',
    [string]$Name = 'windows-nano-artifact-cache',
    [string]$Root = 'C:\ProgramData\windows-nano-demos\artifact-cache'
)
$ErrorActionPreference = 'Stop'

$cachePath = Join-Path $Root 'cache'
$dataPath = Join-Path $Root 'caddy-data'
New-Item -ItemType Directory -Force $cachePath, $dataPath | Out-Null

docker rm -f $Name 2>$null | Out-Null
docker run -d --name $Name --restart unless-stopped --isolation=process `
    -v "${cachePath}:C:\cache" -v "${dataPath}:C:\caddy-data" $Image | Out-Null
if ($LASTEXITCODE) { throw 'starting the artifact cache failed' }

$deadline = (Get-Date).AddMinutes(2)
do {
    Start-Sleep -Seconds 2
    $health = docker exec $Name curl.exe -fsS -m 5 http://localhost:8080/healthz 2>$null
} until ($health -eq 'ok' -or (Get-Date) -gt $deadline)
if ($health -ne 'ok') { throw 'the artifact cache did not become healthy within 2 minutes' }

$ip = (docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $Name).Trim()
"Artifact cache healthy at $ip (health: http://${ip}:8080/healthz, CA: http://${ip}:8080/root.crt)" | Out-Host
