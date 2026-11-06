<#
.SYNOPSIS
Measures what the artifact cache saves, on a private Docker network.
.DESCRIPTION
Creates its own nat network, starts the cache on it with its cache folder
bind-mounted from a temp folder, and starts a nanoserver client on the same
network. For each artifact it times direct downloads (no cache), the first
download through the cache (MISS) and repeat downloads (HIT), checks the
Cache-Status header and SHA-256 of each, and checks that HITs create or
rewrite no file in the cache folder.

Then it builds a Dockerfile whose RUN step downloads with plain curl.exe,
once without the cache and twice through it, to show a build can use the
cache. Windows' classic builder ignores --add-host, and curl.exe there uses
Schannel, so the build stage points the hosts at the cache in its own hosts
file and gives curl the CA root and --ssl-revoke-best-effort in a .curlrc.

Everything it creates is named claude-ac-measure-<random> and removed at the end.
.EXAMPLE
./nano-server/nano-server-artifact-cache/Measure-ArtifactCache.ps1 -Image windows-nano-artifact-cache:dev2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image,
    [string]$ClientImage = 'mcr.microsoft.com/windows/nanoserver:ltsc2025-amd64',
    [ValidateRange(1, 10)][int]$Runs = 3,
    [string[]]$Artifact = @(
        'https://www.7-zip.org/a/7zr.exe',
        'https://nodejs.org/dist/v26.13.0/node-v26.13.0-win-x64.zip',
        'https://go.dev/dl/go1.27.3.windows-amd64.zip'
    ),
    [string]$BuildArtifact = 'https://nodejs.org/dist/v26.13.0/node-v26.13.0-win-x64.zip'
)
$ErrorActionPreference = 'Stop'

$prefix = 'claude-ac-measure-' + [guid]::NewGuid().ToString('n').Substring(0, 8)
$network = "$prefix-net"
$cache = "$prefix-cache"
$client = "$prefix-client"
$tag = "${prefix}-build"
$dataVol = "$prefix-data"
$work = Join-Path ([IO.Path]::GetTempPath()) $prefix
$cacheDir = Join-Path $work 'cache'
$io = Join-Path $work 'io'
New-Item -ItemType Directory -Path $cacheDir, $io | Out-Null

# Every site the Caddyfile serves, so redirects (go.dev -> dl.google.com) also go through the cache.
$caddyfile = Get-Content (Join-Path $PSScriptRoot 'Caddyfile')
$cachedHosts = $caddyfile | Where-Object { $_ -match '^([a-z0-9.-]+\.[a-z]+) \{$' } | ForEach-Object { $Matches[1] }

# A simple function on purpose: an advanced one would bind docker's -d to -Debug.
function Invoke-Docker {
    docker @args | Out-Host
    if ($LASTEXITCODE) { throw "docker $($args -join ' ') failed: $LASTEXITCODE" }
}

function Wait-Healthy {
    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 2
        $health = docker exec $cache curl.exe -fsS -m 5 http://localhost:8080/healthz 2>$null
    } until ($health -eq 'ok' -or (Get-Date) -gt $deadline)
    if ($health -ne 'ok') { docker logs $cache | Out-Host; throw 'the cache did not answer /healthz within 2 minutes' }
}

function Get-CacheStatus([string]$Headers) {
    $last = @($Headers -split '(?m)^(?=HTTP/)' | Where-Object { $_.Trim() })[-1]
    if ($last -match '(?im)^X-Artifact-Cache:\s*BYPASS') { return 'BYPASS' }
    $status = [regex]::Match($last, '(?im)^Cache-Status:\s*(.+?)\s*$').Groups[1].Value
    if ($status -match ';\s*hit') { return 'HIT' }
    if ($status -match 'fwd=') { return 'MISS' }
    if (-not $status) { return 'NONE' }
    "UNKNOWN ($status)"
}

# Downloads one URL in the client, directly or through the cache, into the shared folder as <Label>.bin,
# and returns its timing and cache status. The client's C:\io is $io on the host: docker cp cannot
# reach a running Hyper-V isolated container.
function Get-Download([string]$Url, [string]$Label, [switch]$ViaCache) {
    $curl = @('-sSfL', '-D', "C:\io\$Label.txt", '-o', "C:\io\$Label.bin", '-w', '@C:\io\fmt.txt')
    if ($ViaCache) {
        $curl += @('--cacert', 'C:\io\root.crt', '--ssl-revoke-best-effort')
        foreach ($h in $cachedHosts) { $curl += @('--resolve', "${h}:443:$ip") }
    }
    $out = docker exec $client curl.exe @curl $Url
    if ($LASTEXITCODE) { throw "download of $Url failed: $LASTEXITCODE" }
    $code, $size, $seconds = "$out".Trim() -split ' '
    $headers = Get-Content -Raw (Join-Path $io "$Label.txt")
    [pscustomobject]@{ Code = $code; Bytes = [long]$size; Seconds = [double]$seconds; Status = Get-CacheStatus $headers }
}

function Get-CacheFile {
    Get-ChildItem -Recurse -File $cacheDir | Sort-Object FullName | ForEach-Object {
        '{0}|{1}|{2:o}|{3:o}' -f $_.FullName.Substring($cacheDir.Length), $_.Length, $_.CreationTimeUtc, $_.LastWriteTimeUtc
    }
}

function Get-Median([double[]]$Value) {
    $sorted = $Value | Sort-Object
    $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
}

try {
    Invoke-Docker network create -d nat $network
    Invoke-Docker volume create $dataVol
    Invoke-Docker run -d --name $cache --network $network -v "${cacheDir}:C:\cache" -v "${dataVol}:C:\caddy-data" $Image
    Wait-Healthy
    $ip = (docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $cache).Trim()
    if (-not $ip) { throw 'the cache container has no IP address' }
    "cache $cache on $network at $ip" | Out-Host

    [IO.File]::WriteAllText((Join-Path $io 'fmt.txt'), '%{http_code} %{size_download} %{time_total}')
    [IO.File]::WriteAllText((Join-Path $work 'build-fmt.txt'), 'BUILD-TIMING %{http_code} %{size_download} %{time_total}\n')
    Invoke-Docker run -d --name $client --network $network -v "${io}:C:\io" $ClientImage ping -t localhost
    Invoke-Docker exec $client curl.exe -fsS -o C:\io\root.crt "http://${ip}:8080/root.crt"

    $results = foreach ($url in $Artifact) {
        $name = ([uri]$url).Segments[-1]
        $direct = 1..$Runs | ForEach-Object { Get-Download $url 'direct' }
        $miss = Get-Download $url 'miss' -ViaCache
        if ($miss.Status -ne 'MISS') { throw "first cached download of $name should be MISS, was $($miss.Status)" }
        Start-Sleep -Seconds 2
        $before = Get-CacheFile
        if (-not $before) { throw "the cache folder is empty after the MISS for $name" }
        $hits = 1..$Runs | ForEach-Object { Get-Download $url 'hit' -ViaCache }
        $bad = $hits | Where-Object Status -NE 'HIT'
        if ($bad) { throw "repeat cached downloads of $name should all be HIT, got $($hits.Status -join ', ')" }
        $after = Get-CacheFile
        if (Compare-Object $before $after) {
            Compare-Object $before $after | Out-Host
            throw "the cache folder changed during HITs for $name"
        }
        $hashes = 'direct', 'miss', 'hit' | ForEach-Object { (Get-FileHash (Join-Path $io "$_.bin") -Algorithm SHA256).Hash }
        if (@($hashes | Select-Object -Unique).Count -ne 1) { throw "SHA-256 of $name differs: $($hashes -join ' ')" }
        $directMedian = Get-Median $direct.Seconds
        $hitMedian = Get-Median $hits.Seconds
        [pscustomobject]@{
            Artifact      = $name
            MB            = [math]::Round($miss.Bytes / 1MB, 1)
            DirectMedianS = [math]::Round($directMedian, 2)
            MissS         = [math]::Round($miss.Seconds, 2)
            HitMedianS    = [math]::Round($hitMedian, 2)
            SavedS        = [math]::Round($directMedian - $hitMedian, 2)
            Speedup       = '{0:0.0}x' -f ($directMedian / [math]::Max($hitMedian, 0.001))
            CacheFiles    = "$($before.Count) unchanged"
            Sha256        = $hashes[0].Substring(0, 12)
        }
    }
    $results | Format-Table -AutoSize | Out-Host

    # simplefs keeps one lz4 frame per response, named by the xxhash64 of its cache key, and a
    # protobuf index of the same name under .simplefs-index (see the README).
    $layout = Get-ChildItem -Recurse -File $cacheDir | ForEach-Object {
        $stream = [IO.File]::OpenRead($_.FullName)
        try { $magic = [byte[]]::new(4); [void]$stream.Read($magic, 0, 4) } finally { $stream.Dispose() }
        [pscustomobject]@{
            Path       = $_.FullName.Substring($cacheDir.Length + 1)
            Bytes      = $_.Length
            CreatedUtc = $_.CreationTimeUtc.ToString('HH:mm:ss.fff')
            Lz4        = [BitConverter]::ToString($magic) -eq '04-22-4D-18'
        }
    }
    $layout | Format-Table -AutoSize | Out-Host
    $payloads = $layout | Where-Object { $_.Path -notlike '.simplefs-index*' }
    if ($payloads | Where-Object { -not $_.Lz4 }) { throw 'a cached response is not an lz4 frame' }

    # A Dockerfile build stage that downloads with plain curl.exe. With CACHE_IP set it sends the
    # cached hosts to the cache; without it the same RUN line downloads directly.
    $ctx = Join-Path $work 'build'
    New-Item -ItemType Directory -Path $ctx | Out-Null
    Copy-Item (Join-Path $work 'build-fmt.txt') (Join-Path $ctx 'fmt.txt')
    $hostLines = ($cachedHosts | ForEach-Object { "echo %CACHE_IP% $_" }) -join '& '
    [IO.File]::WriteAllText((Join-Path $ctx 'Dockerfile'), @"
FROM $ClientImage AS download
ARG CACHE_IP
USER ContainerAdministrator
COPY fmt.txt C:/curl/fmt.txt
RUN if defined CACHE_IP ( curl.exe -fsS -o C:\curl\cache-root.crt http://%CACHE_IP%:8080/root.crt && ($hostLines)>> C:\Windows\System32\drivers\etc\hosts && (echo cacert = "C:/curl/cache-root.crt"& echo ssl-revoke-best-effort)> C:\curl\.curlrc )
ENV CURL_HOME=C:\\curl
RUN curl.exe -fsSL -D C:\h.txt -w @C:\curl\fmt.txt -o C:\artifact.bin $BuildArtifact && type C:\h.txt

FROM $ClientImage
COPY --from=download C:/artifact.bin C:/artifact.bin
"@.Replace("`r`n", "`n"))

    # The first cached build is a MISS unless the measurements above already fetched the artifact.
    $cached = $Artifact -contains $BuildArtifact
    $builds = foreach ($mode in 'direct', 'cache', 'cache') {
        $buildArgs = @('build', '--memory', '4g', '--no-cache', '--network', $network, '-t', $tag)
        if ($mode -eq 'cache') { $buildArgs += @('--build-arg', "CACHE_IP=$ip") }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $log = docker @buildArgs $ctx 2>&1 | Out-String
        $watch.Stop()
        if ($LASTEXITCODE) { $log | Out-Host; throw "docker build ($mode) failed: $LASTEXITCODE" }
        $download = (($log -split 'BUILD-TIMING', 2)[-1] -split '(?m)^Step ', 2)[0]
        $status = Get-CacheStatus $download
        $expected = if ($mode -eq 'direct') { 'NONE' } elseif ($cached) { 'HIT' } else { 'MISS' }
        if ($mode -eq 'cache') { $cached = $true }
        if ($status -ne $expected) { $log | Out-Host; throw "docker build ($mode) download should be $expected, was $status" }
        $curlSeconds = [regex]::Match($log, 'BUILD-TIMING \S+ \S+ (\S+)').Groups[1].Value
        [pscustomobject]@{ Build = $mode; CacheStatus = $status; CurlS = [double]$curlSeconds; BuildS = [math]::Round($watch.Elapsed.TotalSeconds, 1) }
    }
    $builds | Format-Table -AutoSize | Out-Host
    'artifact cache measurement passed' | Out-Host
}
finally {
    docker rm -f $client $cache 2>$null | Out-Null
    docker rmi -f $tag 2>$null | Out-Null
    docker volume rm $dataVol 2>$null | Out-Null
    docker network rm $network 2>$null | Out-Null
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
