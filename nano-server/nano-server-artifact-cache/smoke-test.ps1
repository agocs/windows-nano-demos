<#
.SYNOPSIS
Smoke tests a built windows-nano-artifact-cache image end to end.
.DESCRIPTION
Starts the cache with throwaway Docker volumes, then downloads an artifact
through it twice from a nanoserver client container. The first download must
be a cache MISS and the second a HIT with the same SHA-256. A page that is
not an artifact must bypass the cache, and the artifact must still be a HIT
after the cache container restarts.
.EXAMPLE
./nano-server/nano-server-artifact-cache/smoke-test.ps1 -Image windows-nano-artifact-cache:2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image,
    [string]$ClientImage = 'mcr.microsoft.com/windows/nanoserver:ltsc2025-amd64'
)
$ErrorActionPreference = 'Stop'

$suffix = [guid]::NewGuid().ToString('n').Substring(0, 8)
$cache = "muse-artifact-cache-smoke-$suffix"
$cacheVol = "$cache-cache"
$dataVol = "$cache-data"
$clients = [Collections.Generic.List[string]]::new()
$work = Join-Path ([IO.Path]::GetTempPath()) $cache
New-Item -ItemType Directory -Path $work | Out-Null

$artifact = 'https://www.7-zip.org/a/7zr.exe'
$page = 'https://www.7-zip.org/download.html'

function Wait-Healthy {
    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 2
        if ((docker inspect -f '{{.State.Running}}' $cache) -ne 'true') {
            docker logs $cache | Out-Host
            throw 'the cache container exited'
        }
        $health = docker exec $cache curl.exe -fsS -m 5 http://localhost:8080/healthz 2>$null
    } until ($health -eq 'ok' -or (Get-Date) -gt $deadline)
    if ($health -ne 'ok') { throw 'the cache did not answer /healthz within 2 minutes' }
}

# Downloads each URL in one client container and copies C:\out back to a host folder.
# The client trusts the cache CA with curl --cacert and resolves the host to the cache IP.
# Schannel fails with "the revocation status is unknown" unless --ssl-revoke-best-effort: the internal CA has no CRL or OCSP.
function Invoke-Client([string]$Label, [string]$CacheIp, [string[]]$Url, [string]$Client) {
    $name = "$cache-$Label"
    $clients.Add($name)
    $commands = @("curl.exe -fsS -o C:\\root.crt http://${CacheIp}:8080/root.crt", 'mkdir C:\out')
    for ($i = 0; $i -lt $Url.Count; $i++) {
        $uri = [uri]$Url[$i]
        $commands += "curl.exe -fsSL --resolve $($uri.Host):443:$CacheIp --cacert C:\\root.crt --ssl-revoke-best-effort -D C:\\out\\$i.txt -o C:\\out\\$i.bin $($Url[$i])"
    }
    docker run --name $name $Client cmd /S /C ($commands -join ' && ') | Out-Host
    if ($LASTEXITCODE) { throw "client $Label failed: $LASTEXITCODE" }
    $dir = Join-Path $work $Label
    docker cp "${name}:C:\out" $dir | Out-Host
    if ($LASTEXITCODE) { throw "docker cp from $name failed: $LASTEXITCODE" }
    $dir
}

function Get-CacheStatus([string]$HeaderFile) {
    $text = Get-Content -Raw $HeaderFile
    $last = @($text -split '(?m)^(?=HTTP/)' | Where-Object { $_.Trim() })[-1]
    if ($last -match '(?im)^X-Artifact-Cache:\s*BYPASS') { return 'BYPASS' }
    $status = [regex]::Match($last, '(?im)^Cache-Status:\s*(.+?)\s*$').Groups[1].Value
    if ($status -match ';\s*hit') { return 'HIT' }
    if ($status -match 'fwd=') { return 'MISS' }
    "UNKNOWN ($status)"
}

function Assert-Status([string]$Dir, [string]$Expected, [string]$What) {
    $actual = Get-CacheStatus (Join-Path $Dir '0.txt')
    if ($actual -ne $Expected) {
        Get-Content (Join-Path $Dir '0.txt') | Out-Host
        throw "$What should be $Expected, was $actual"
    }
    "$What -> $actual" | Out-Host
}

try {
    docker volume create $cacheVol | Out-Null
    docker volume create $dataVol | Out-Null
    docker run -d --name $cache -v "${cacheVol}:C:\cache" -v "${dataVol}:C:\caddy-data" $Image | Out-Null
    if ($LASTEXITCODE) { throw 'starting the cache failed' }
    Wait-Healthy
    '/healthz -> ok' | Out-Host

    $ip = (docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $cache).Trim()
    if (-not $ip) { throw 'the cache container has no IP address' }

    $first = Invoke-Client 'first' $ip @($artifact) $ClientImage
    Assert-Status $first 'MISS' 'first artifact download'
    $second = Invoke-Client 'second' $ip @($artifact) $ClientImage
    Assert-Status $second 'HIT' 'second artifact download'

    $hash1 = (Get-FileHash (Join-Path $first '0.bin') -Algorithm SHA256).Hash
    $hash2 = (Get-FileHash (Join-Path $second '0.bin') -Algorithm SHA256).Hash
    if ($hash1 -ne $hash2) { throw 'cached artifact SHA-256 differs from the first download' }
    'artifact SHA-256 stable across MISS and HIT' | Out-Host

    $pageDir = Invoke-Client 'page' $ip @($page) $ClientImage
    Assert-Status $pageDir 'BYPASS' 'non-artifact page'

    docker restart $cache | Out-Null
    Wait-Healthy
    # Windows nat hands the restarted container a new IP address.
    $ip = (docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $cache).Trim()
    $third = Invoke-Client 'third' $ip @($artifact) $ClientImage
    Assert-Status $third 'HIT' 'artifact download after cache restart'

    $logs = docker logs $cache 2>&1 | Out-String
    if ($logs -notmatch 'Cache-Status|cache') { throw 'cache access log has no cache status entries' }
    'cache smoke test passed' | Out-Host
}
finally {
    foreach ($client in $clients) { docker rm -f $client 2>$null | Out-Null }
    docker rm -f $cache 2>$null | Out-Null
    docker volume rm $cacheVol $dataVol 2>$null | Out-Null
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
