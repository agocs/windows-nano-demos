<#
.SYNOPSIS
Smoke tests a built windows-nano-artifact-cache image end to end.

.DESCRIPTION
Starts the cache with throwaway named volumes (the CI runner is itself a container, so there
are no host bind mounts), then runs nanoserver client containers that trust the cache's root CA
and resolve the cached hosts to it, the way New-ArtifactCacheClientSetup.ps1 sets up a build.
It checks that:

- /healthz answers and /root.crt serves the CA certificate
- a GitHub release download (github.com redirect, then release-assets.githubusercontent.com)
  is a MISS the first time and a HIT the second, with the same SHA-256
- a file on an artifact host (www.7-zip.org) is a MISS, then a HIT
- an HTML page is not cached (X-Artifact-Cache: BYPASS)
- cached entries survive a restart of the cache container
- the cache's access log records the cache status per request

Only the containers and volumes this script created are removed.

.EXAMPLE
./nano-server-artifact-cache/smoke-test.ps1 -Image windows-nano-artifact-cache:2025
#>
param(
    [Parameter(Mandatory)][string]$Image,
    # The client image. The cache is ltsc2025 only, so its clients are too.
    [string]$ClientImage = 'mcr.microsoft.com/windows/nanoserver:ltsc2025-amd64'
)
$ErrorActionPreference = 'Stop'

$suffix = [guid]::NewGuid().ToString('n').Substring(0, 8)
$cache = "artifact-cache-smoke-$suffix"
$volumes = @("$cache-cache", "$cache-data")
$clients = [Collections.Generic.List[string]]::new()
$work = Join-Path ([IO.Path]::GetTempPath()) $cache
New-Item -ItemType Directory -Path $work | Out-Null

$release = 'https://github.com/micro-editor/micro/releases/download/v2.0.15/micro-2.0.15-win64.zip'
$artifact = 'https://www.7-zip.org/a/7zr.exe'
$page = 'https://www.7-zip.org/download.html'

function Wait-Healthy {
    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 2
        if ((docker inspect -f '{{.State.Running}}' $cache) -ne 'true') {
            docker logs $cache
            throw 'the cache container exited'
        }
        $health = docker exec $cache curl.exe -fsS -m 5 http://localhost:8080/healthz 2>$null
    } until ($health -eq 'ok' -or (Get-Date) -gt $deadline)
    if ($health -ne 'ok') {
        docker logs $cache
        throw 'the cache did not answer /healthz within 2 minutes'
    }
}

# Runs one client container: trust the CA, point the hosts at the cache, then download each URL
# to C:\out\<n>.bin with its headers in C:\out\<n>.txt. Returns the folder they were copied to.
function Invoke-Client([string]$Label, [string[]]$Url) {
    $name = "$cache-$Label"
    $clients.Add($name)
    $commands = @($setup, 'mkdir C:\out')
    for ($i = 0; $i -lt $Url.Count; $i++) {
        $commands += "curl.exe -fsSL -D C:\out\$i.txt -o C:\out\$i.bin $($Url[$i])"
    }
    docker run --name $name -u ContainerAdministrator $ClientImage cmd /S /C ($commands -join ' && ') | Out-Host
    if ($LASTEXITCODE) { throw "client $Label failed: $LASTEXITCODE" }
    $dir = Join-Path $work $Label
    # docker cp works on a stopped container under either isolation mode
    docker cp "${name}:C:\out" $dir | Out-Host
    if ($LASTEXITCODE) { throw "docker cp from $name failed: $LASTEXITCODE" }
    $dir
}

# The cache status of the final response (after redirects) in a curl -D header file
function Get-CacheStatus([string]$HeaderFile) {
    $text = Get-Content -Raw $HeaderFile
    $last = @($text -split '(?m)^(?=HTTP/)' | Where-Object { $_.Trim() })[-1]
    $status = [regex]::Match($last, '(?im)^Cache-Status:\s*(.+?)\s*$').Groups[1].Value
    $bypass = [regex]::Match($last, '(?im)^X-Artifact-Cache:\s*(.+?)\s*$').Groups[1].Value
    if ($bypass) { return 'BYPASS' }
    if ($status -match ';\s*hit') { return 'HIT' }
    if ($status -match 'fwd=') { return 'MISS' }
    "UNKNOWN ($status)"
}

function Assert-Status([string]$Dir, [int]$Index, [string]$Expected, [string]$What) {
    $actual = Get-CacheStatus (Join-Path $Dir "$Index.txt")
    if ($actual -ne $Expected) {
        Get-Content (Join-Path $Dir "$Index.txt")
        throw "$What should be $Expected, was $actual"
    }
    Write-Host "$What -> $actual"
}

try {
    foreach ($volume in $volumes) { docker volume create $volume | Out-Null }
    docker run -d --name $cache -v "$($volumes[0]):C:\cache" -v "$($volumes[1]):C:\caddy-data" $Image | Out-Null
    if ($LASTEXITCODE) { throw "starting the cache failed: $LASTEXITCODE" }
    Wait-Healthy
    Write-Host '/healthz -> ok'

    $ip = docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $cache
    $rootCert = Join-Path $work 'root.crt'
    docker exec $cache curl.exe -fsS http://localhost:8080/root.crt | Set-Content -Path $rootCert -Encoding ascii
    if ($LASTEXITCODE -or -not ((Get-Content -Raw $rootCert) -match 'BEGIN CERTIFICATE')) {
        throw '/root.crt did not return a PEM certificate'
    }
    Write-Host "/root.crt -> $(([Security.Cryptography.X509Certificates.X509Certificate2]::new($rootCert)).Subject)"
    $setup = & "$PSScriptRoot/New-ArtifactCacheClientSetup.ps1" -RootCertificate $rootCert -CacheAddress $ip -SingleLine

    $first = Invoke-Client 'first' $release, $artifact, $page
    Assert-Status $first 0 'MISS' 'first release download'
    Assert-Status $first 1 'MISS' 'first 7zr.exe download'
    Assert-Status $first 2 'BYPASS' 'HTML page'

    $second = Invoke-Client 'second' $release, $artifact
    Assert-Status $second 0 'HIT' 'second release download'
    Assert-Status $second 1 'HIT' 'second 7zr.exe download'

    foreach ($i in 0, 1) {
        $a = (Get-FileHash (Join-Path $first "$i.bin") -Algorithm SHA256).Hash
        $b = (Get-FileHash (Join-Path $second "$i.bin") -Algorithm SHA256).Hash
        if ($a -ne $b) { throw "download $i differs between MISS ($a) and HIT ($b)" }
        Write-Host "download $i SHA-256 $a matches"
    }

    # The simplefs index is on the cache volume, so entries outlive the process
    docker restart $cache | Out-Null
    Wait-Healthy
    $ip = docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $cache
    $setup = & "$PSScriptRoot/New-ArtifactCacheClientSetup.ps1" -RootCertificate $rootCert -CacheAddress $ip -SingleLine
    $third = Invoke-Client 'restarted' $release
    Assert-Status $third 0 'HIT' 'release download after a cache restart'

    $log = docker logs $cache 2>&1 | Out-String
    if ($log -notmatch '"Cache-Status":\["ArtifactCache; hit' -or $log -notmatch '"Cache-Status":\["ArtifactCache; fwd=uri-miss') {
        Write-Host $log
        throw 'the access log does not record the cache status'
    }
    Write-Host 'access log records MISS and HIT'
}
finally {
    foreach ($name in $clients) { docker rm -f $name 2>$null | Out-Null }
    docker rm -f $cache 2>$null | Out-Null
    foreach ($volume in $volumes) { docker volume rm $volume 2>$null | Out-Null }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
