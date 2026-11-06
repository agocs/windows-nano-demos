<#
.SYNOPSIS
Lists what the artifact cache holds, by reading its simplefs files directly.
.DESCRIPTION
Read-only listing of the Caddy/Souin artifact cache (issue #61). It does not
talk to Souin and the cache does not need to be running: it reads the payload
files and the protobuf indexes under .simplefs-index in -CachePath, and works
out each payload's URL by hashing candidate URLs and matching the hashes
against the file names, because the Caddyfile's key { hash } means the URL
itself is stored nowhere.

Validated against cache-handler v0.17.0 (Souin) and simplefs v0.0.22, the
versions pinned in this folder's Dockerfile. A test in tests/ fails when
those pins change, so the parser is re-checked before a bump is trusted.

One object is written per payload file, with Hash, IndexHash, Url (when a
candidate matched), Bytes, StoredAt, FreshUntil, StaleUntil, ETag,
VariedHeaders and State (Fresh, Stale, Expired or Orphan).

Candidates come from -Url, from the cache's access log with -FromLog, or,
when neither supplies any, from download URLs in this repo's Dockerfiles on a
best-effort basis. Nothing in the cache folder is ever written to.
.PARAMETER CachePath
The cache folder to list. On the runner host that is the bind-mounted
C:\ProgramData\windows-nano-demos\artifact-cache\cache.
.PARAMETER Url
Candidate artifact URLs to match against the entries found.
.PARAMETER FromLog
Adds candidate URLs from the running cache container's JSON access log.
.PARAMETER Container
The cache container to read the log from with -FromLog.
.PARAMETER Now
The time State is judged at. Defaults to now; tests pass a fixed time.
.EXAMPLE
./nano-server/nano-server-artifact-cache/Get-ArtifactCacheEntry.ps1 -FromLog | Format-Table Hash, Url, Bytes, State
.EXAMPLE
./nano-server/nano-server-artifact-cache/Get-ArtifactCacheEntry.ps1 -CachePath D:\cache-copy -Url 'https://www.7-zip.org/a/7zr.exe'
#>
[CmdletBinding()]
param(
    [string]$CachePath = 'C:\ProgramData\windows-nano-demos\artifact-cache\cache',
    [string[]]$Url = @(),
    [switch]$FromLog,
    [string]$Container = 'windows-nano-artifact-cache',
    [datetimeoffset]$Now = [datetimeoffset]::UtcNow
)

$script:ValidatedCacheHandlerVersion = 'v0.17.0'
$script:ValidatedSimplefsVersion = 'v0.0.22'

# Hosts whose Caddyfile site drops the query string from the cache key.
$script:BlobHost = @('release-assets.githubusercontent.com', 'objects.githubusercontent.com')

if (-not ('ArtifactCacheXxHash64' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;

// Standard xxhash64 (seed 0) over the UTF-8 bytes of a Souin cache key.
// Souin replaces each key with this hash as a decimal string (key { hash }).
public static class ArtifactCacheXxHash64
{
    private const ulong P1 = 11400714785074694791UL;
    private const ulong P2 = 14029467366897019727UL;
    private const ulong P3 = 1609587929392839161UL;
    private const ulong P4 = 9650029242287828579UL;
    private const ulong P5 = 2870177450012600261UL;

    private static ulong Rotl(ulong x, int r) { return (x << r) | (x >> (64 - r)); }

    private static ulong Round(ulong acc, ulong input)
    {
        acc += input * P2;
        acc = Rotl(acc, 31);
        return acc * P1;
    }

    private static ulong Read64(byte[] b, int i) { return BitConverter.ToUInt64(b, i); }
    private static uint Read32(byte[] b, int i) { return BitConverter.ToUInt32(b, i); }

    public static ulong Hash(string text)
    {
        byte[] b = Encoding.UTF8.GetBytes(text);
        int len = b.Length;
        int i = 0;
        ulong h;
        unchecked
        {
            if (len >= 32)
            {
                ulong v1 = P1 + P2, v2 = P2, v3 = 0, v4 = 0 - P1;
                for (; i + 32 <= len; i += 32)
                {
                    v1 = Round(v1, Read64(b, i));
                    v2 = Round(v2, Read64(b, i + 8));
                    v3 = Round(v3, Read64(b, i + 16));
                    v4 = Round(v4, Read64(b, i + 24));
                }
                h = Rotl(v1, 1) + Rotl(v2, 7) + Rotl(v3, 12) + Rotl(v4, 18);
                foreach (ulong v in new[] { v1, v2, v3, v4 })
                {
                    ulong m = Round(0, v);
                    h ^= m;
                    h = h * P1 + P4;
                }
            }
            else
            {
                h = P5;
            }
            h += (ulong)len;
            while (i + 8 <= len)
            {
                ulong k = Round(0, Read64(b, i));
                h ^= k;
                h = Rotl(h, 27) * P1 + P4;
                i += 8;
            }
            if (i + 4 <= len)
            {
                h ^= Read32(b, i) * P1;
                h = Rotl(h, 23) * P2 + P3;
                i += 4;
            }
            while (i < len)
            {
                h ^= b[i] * P5;
                h = Rotl(h, 11) * P1;
                i++;
            }
            h ^= h >> 33;
            h *= P2;
            h ^= h >> 29;
            h *= P3;
            h ^= h >> 32;
            return h;
        }
    }
}
'@
}

function Get-XxHash64 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Text)
    [ArtifactCacheXxHash64]::Hash($Text).ToString()
}

# Reads one protobuf varint from the stream. Returns $null at the end of the stream.
function Read-PbVarint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)
    [uint64]$result = 0
    $shift = 0
    while ($true) {
        $byte = $Stream.ReadByte()
        if ($byte -lt 0) {
            if ($shift -eq 0) { return $null }
            throw 'truncated protobuf varint'
        }
        $result = $result -bor ([uint64]($byte -band 0x7F) -shl $shift)
        if (($byte -band 0x80) -eq 0) { return $result }
        $shift += 7
        if ($shift -gt 63) { throw 'protobuf varint is too long' }
    }
}

# Splits protobuf bytes into fields: Number, WireType, Varint (wire type 0) and Bytes (wire type 2).
function Read-PbField {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $stream = [System.IO.MemoryStream]::new($Bytes)
    try {
        while ($stream.Position -lt $stream.Length) {
            [uint64]$tag = Read-PbVarint $stream
            $wire = [int]($tag -band 7)
            $field = [pscustomobject]@{ Number = [int]($tag -shr 3); WireType = $wire; Varint = $null; Bytes = $null }
            switch ($wire) {
                0 { $field.Varint = Read-PbVarint $stream }
                1 { $field.Bytes = [byte[]]::new(8); [void]$stream.Read($field.Bytes, 0, 8) }
                2 {
                    [uint64]$length = Read-PbVarint $stream
                    $field.Bytes = [byte[]]::new([int]$length)
                    [void]$stream.Read($field.Bytes, 0, [int]$length)
                }
                5 { $field.Bytes = [byte[]]::new(4); [void]$stream.Read($field.Bytes, 0, 4) }
                default { throw "unsupported protobuf wire type $wire" }
            }
            $field
        }
    }
    finally {
        $stream.Dispose()
    }
}

# Converts a protobuf Timestamp message (field 1 seconds, field 2 nanos) to a DateTimeOffset.
function ConvertFrom-PbTimestamp {
    [CmdletBinding()]
    [OutputType([datetimeoffset])]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    [long]$seconds = 0
    [long]$nanos = 0
    foreach ($field in (Read-PbField $Bytes)) {
        if ($field.Number -eq 1) { $seconds = [long]$field.Varint }
        if ($field.Number -eq 2) { $nanos = [long]$field.Varint }
    }
    [datetimeoffset]::FromUnixTimeSeconds($seconds).AddTicks([long]($nanos / 100))
}

# Parses one KeyIndex message from a StorageMapper (core/storage.proto in darkweak/storages).
function Read-KeyIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)][string]$IndexHash)
    $entry = [pscustomobject]@{
        IndexHash     = $IndexHash
        StoredAt      = $null
        FreshUntil    = $null
        StaleUntil    = $null
        VariedHeaders = @{}
        ETag          = $null
        RealKey       = $null
    }
    foreach ($field in (Read-PbField $Bytes)) {
        switch ($field.Number) {
            1 { $entry.StoredAt = ConvertFrom-PbTimestamp $field.Bytes }
            2 { $entry.FreshUntil = ConvertFrom-PbTimestamp $field.Bytes }
            3 { $entry.StaleUntil = ConvertFrom-PbTimestamp $field.Bytes }
            4 {
                $name = $null
                $values = @()
                foreach ($part in (Read-PbField $field.Bytes)) {
                    if ($part.Number -eq 1) { $name = [Text.Encoding]::UTF8.GetString($part.Bytes) }
                    if ($part.Number -eq 2) {
                        foreach ($item in (Read-PbField $part.Bytes)) {
                            if ($item.Number -eq 1) { $values += [Text.Encoding]::UTF8.GetString($item.Bytes) }
                        }
                    }
                }
                if ($null -ne $name) { $entry.VariedHeaders[$name] = $values }
            }
            5 { $entry.ETag = [Text.Encoding]::UTF8.GetString($field.Bytes) }
            6 { $entry.RealKey = [Text.Encoding]::UTF8.GetString($field.Bytes) }
        }
    }
    $entry
}

# Reads every .simplefs-index file into one map: varied key hash -> its KeyIndex entry.
function Read-StorageIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IndexPath)
    $entries = @{}
    if (-not (Test-Path $IndexPath)) { return $entries }
    foreach ($file in (Get-ChildItem -Path $IndexPath -File)) {
        foreach ($field in (Read-PbField ([IO.File]::ReadAllBytes($file.FullName)))) {
            if ($field.Number -ne 1) { continue }
            $variedHash = $null
            $indexBytes = $null
            foreach ($part in (Read-PbField $field.Bytes)) {
                if ($part.Number -eq 1) { $variedHash = [Text.Encoding]::UTF8.GetString($part.Bytes) }
                if ($part.Number -eq 2) { $indexBytes = $part.Bytes }
            }
            if ($null -ne $variedHash -and $null -ne $indexBytes) {
                $entries[$variedHash] = Read-KeyIndex -Bytes $indexBytes -IndexHash $file.Name
            }
        }
    }
    $entries
}

# The Souin base key for a URL: GET-<scheme>-<host>-<path>[?query]. The blobs sites drop the query.
function Get-CacheKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][uri]$Uri, [Parameter(Mandatory)][bool]$DropQuery)
    $path = $Uri.AbsolutePath
    if (-not $DropQuery -and $Uri.Query) { $path += $Uri.Query }
    "GET-$($Uri.Scheme)-$($Uri.Host)-$path"
}

# Candidate URLs from the running cache container JSON access log (docker logs).
function Get-LogUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ContainerName)
    $lines = docker logs $ContainerName 2>&1
    if ($LASTEXITCODE) { throw "docker logs $ContainerName failed: $LASTEXITCODE" }
    foreach ($line in $lines) {
        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }
        if ($entry.request.host -and $entry.request.uri) {
            "https://$($entry.request.host)$($entry.request.uri)"
        }
    }
}

# Best-effort candidate URLs from download URLs in this repo's Dockerfiles.
# ENV and ARG defaults in the same file expand %VAR% and $env:VAR; anything still unresolved is skipped.
function Get-DockerfileUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    foreach ($folder in @('nano-server', 'server-core')) {
        $base = Join-Path $RepoRoot $folder
        if (-not (Test-Path $base)) { continue }
        foreach ($file in (Get-ChildItem -Path $base -Recurse -Filter Dockerfile -File)) {
            $text = Get-Content -Raw $file.FullName
            $vars = @{}
            foreach ($match in [regex]::Matches($text, '(?m)^\s*(?:ENV|ARG)\s+([A-Za-z_][A-Za-z0-9_]*)=([^\s\\]+)')) {
                $vars[$match.Groups[1].Value] = $match.Groups[2].Value.Trim('"', "'")
            }
            foreach ($match in [regex]::Matches($text, 'https://[^\s"'')\\]+')) {
                $candidate = $match.Value.TrimEnd('.', ',', ';')
                foreach ($name in @($vars.Keys)) {
                    $candidate = $candidate.Replace("%$name%", $vars[$name])
                    $candidate = $candidate.Replace("`$env:$name", $vars[$name])
                    $candidate = $candidate.Replace("`$$name", $vars[$name])
                }
                if ($candidate -notmatch '[%$]') { $candidate }
            }
        }
    }
}

function Get-ArtifactCacheEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$CandidateUrl = @(),
        [bool]$UseLog = $false,
        [string]$ContainerName = 'windows-nano-artifact-cache',
        [Parameter(Mandatory)][datetimeoffset]$At,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    if (-not (Test-Path $Path)) { throw "cache folder not found: $Path" }

    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($item in $CandidateUrl) { if ($item) { $candidates.Add($item) } }
    if ($UseLog) {
        foreach ($item in (Get-LogUrl -ContainerName $ContainerName)) { $candidates.Add($item) }
    }
    if ($candidates.Count -eq 0) {
        foreach ($item in (Get-DockerfileUrl -RepoRoot $RepoRoot)) { $candidates.Add($item) }
    }

    $entries = Read-StorageIndex -IndexPath (Join-Path $Path '.simplefs-index')

    # Map payload hash -> URL. A candidate matches a payload directly (no Vary),
    # through its base-key index (every varied payload under that index), or through
    # the varied key rebuilt from the varied headers the index itself recorded.
    $urlByHash = @{}
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        $uri = $candidate -as [uri]
        if ($null -eq $uri -or -not $uri.Host) { continue }
        $baseKey = Get-CacheKey -Uri $uri -DropQuery ($script:BlobHost -contains $uri.Host)
        $baseHash = Get-XxHash64 $baseKey
        $urlByHash[$baseHash] = $candidate
        foreach ($variedHash in $entries.Keys) {
            $entry = $entries[$variedHash]
            if ($entry.IndexHash -eq $baseHash) { $urlByHash[$variedHash] = $candidate }
            if ($entry.VariedHeaders.Count -gt 0) {
                $parts = foreach ($name in $entry.VariedHeaders.Keys) {
                    foreach ($value in $entry.VariedHeaders[$name]) { "${name}:$value" }
                }
                $variedKey = "$baseKey{-VARY-}" + ($parts -join ';')
                $urlByHash[(Get-XxHash64 $variedKey)] = $candidate
            }
        }
    }

    foreach ($file in (Get-ChildItem -Path $Path -File)) {
        $entry = $entries[$file.Name]
        $state = 'Orphan'
        if ($null -ne $entry) {
            if ($At -lt $entry.FreshUntil) { $state = 'Fresh' }
            elseif ($At -lt $entry.StaleUntil) { $state = 'Stale' }
            else { $state = 'Expired' }
        }
        [pscustomobject]@{
            Hash          = $file.Name
            IndexHash     = if ($null -ne $entry) { $entry.IndexHash } else { $null }
            Url           = $urlByHash[$file.Name]
            Bytes         = $file.Length
            StoredAt      = if ($null -ne $entry) { $entry.StoredAt } else { $null }
            FreshUntil    = if ($null -ne $entry) { $entry.FreshUntil } else { $null }
            StaleUntil    = if ($null -ne $entry) { $entry.StaleUntil } else { $null }
            ETag          = if ($null -ne $entry) { $entry.ETag } else { $null }
            VariedHeaders = if ($null -ne $entry) { $entry.VariedHeaders } else { @{} }
            State         = $state
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-ArtifactCacheEntry -Path $CachePath -CandidateUrl $Url -UseLog $FromLog.IsPresent -ContainerName $Container -At $Now -RepoRoot (Join-Path $PSScriptRoot '..\..')
}
