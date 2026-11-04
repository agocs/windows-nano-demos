<#
.SYNOPSIS
    Extracts the Wine x86_64 PE programs listed in tools.txt into wine-pe\ for a local build.

.DESCRIPTION
    The Windows equivalent of extract-wine.sh (option B in plans/wine-binaries.md). Downloads the
    pinned WineHQ wine-stable .deb, checks its SHA-256, and extracts only the listed members with the
    built-in tar.exe (bsdtar 3.8 on Windows 11 reads ar, zstd and xz). A full extract fails on a
    Linux-only path under usr/share/doc, so only the listed paths are extracted.
    Refuses Wine core modules and anything that has a unixlib, the same as extract-wine.sh.
    Needs pwsh 7 and a tar.exe with zstd support (Windows 11; Windows Server 2022's tar is too old).
#>
[CmdletBinding()]
param(
    [string] $OutDir = (Join-Path $PSScriptRoot 'wine-pe')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$debUrl = 'https://dl.winehq.org/wine-builds/ubuntu/pool/main/w/wine/wine-stable-amd64_11.0.0.0~noble-1_amd64.deb'
$debSha256 = '6cb835e2171b5572b17f1c06729735c2c7e40178239d7fa6c29ef14bd9b40d16'
$peDir = './opt/wine-stable/lib/wine/x86_64-windows'
$unixDir = './opt/wine-stable/lib/wine/x86_64-unix'
$deny = 'ntdll', 'win32u', 'kernel32', 'kernelbase', 'user32', 'gdi32', 'advapi32', 'ws2_32', 'msvcrt', 'ucrtbase', 'combase', 'ole32', 'rpcrt4', 'sechost'

$tools = Get-Content (Join-Path $PSScriptRoot 'tools.txt') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
foreach ($t in $tools) {
    if ($t -match '[\\/]') { throw "refusing ${t}: not a plain file name" }
    if ([IO.Path]::GetFileNameWithoutExtension($t).ToLowerInvariant() -in $deny) { throw "refusing ${t}: Wine core module" }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("wine-fetch-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $deb = Join-Path $work 'wine.deb'
    Write-Host "Downloading $debUrl"
    & curl.exe -fsSL --retry 5 --retry-delay 5 -o $deb $debUrl
    if ($LASTEXITCODE -ne 0) { throw "download failed ($LASTEXITCODE)" }
    $hash = (Get-FileHash -Algorithm SHA256 $deb).Hash.ToLowerInvariant()
    if ($hash -ne $debSha256) { throw "SHA-256 mismatch: got $hash, expected $debSha256" }

    & tar.exe -xf $deb -C $work data.tar.zst
    if ($LASTEXITCODE -ne 0) { throw "tar could not read the .deb ($LASTEXITCODE)" }
    $data = Join-Path $work 'data.tar.zst'

    # One listing pass for the unixlib check
    $listing = & tar.exe -tf $data
    if ($LASTEXITCODE -ne 0) { throw "tar could not list data.tar.zst ($LASTEXITCODE)" }
    $unixlibs = @($listing | Where-Object { $_.StartsWith("$unixDir/") } | ForEach-Object { $_.Substring($unixDir.Length + 1) })
    foreach ($t in $tools) {
        $so = [IO.Path]::GetFileNameWithoutExtension($t) + '.so'
        if ($so -in $unixlibs) { throw "refusing ${t}: has a unixlib ($so)" }
    }

    $members = $tools | ForEach-Object { "$peDir/$_" }
    & tar.exe -xf $data -C $work @members
    if ($LASTEXITCODE -ne 0) { throw "tar could not extract the tools ($LASTEXITCODE)" }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    foreach ($t in $tools) { Copy-Item -LiteralPath (Join-Path $work "opt/wine-stable/lib/wine/x86_64-windows/$t") -Destination $OutDir -Force }
    Get-ChildItem $OutDir | Format-Table Name, Length -AutoSize
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
