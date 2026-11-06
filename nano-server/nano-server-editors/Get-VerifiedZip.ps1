<#
.SYNOPSIS
Downloads a zip, checks its SHA-256, unpacks it, and checks that the executables in it really are executables.
.DESCRIPTION
Runs in the Dockerfile's Server Core download stage. It unpacks with 7-Zip (7za.exe), because the nano zip uses
Deflate64: Windows PowerShell's Expand-Archive can't decompress it, and tar.exe silently extracts it as zero bytes
(plans/console-editors.md). Each -Executable must start with the "MZ" header after extraction, so an editor that
"is installed" but can't start fails the build.
.PARAMETER Url
The zip to download.
.PARAMETER Sha256
The zip's expected SHA-256, as pinned in the Dockerfile.
.PARAMETER Destination
The folder to unpack into. It is created.
.PARAMETER Executable
Paths, relative to -Destination, of the executables to check.
.PARAMETER SevenZip
The 7za.exe to unpack with. The Dockerfile installs it to C:\7z\x64\7za.exe.
.EXAMPLE
./Get-VerifiedZip.ps1 -Url https://example.com/tool.zip -Sha256 0123... -Destination C:\editors\tool -Executable tool.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Sha256,
    [Parameter(Mandatory)][string]$Destination,
    [string[]]$Executable = @(),
    [string]$SevenZip = 'C:\7z\x64\7za.exe'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$zip = Join-Path $env:TEMP "download-$([guid]::NewGuid().ToString('n')).zip"
try {
    curl.exe -fsSLo $zip $Url
    if ($LASTEXITCODE) { throw "downloading $Url failed: $LASTEXITCODE" }
    $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
    if ($actual -ne $Sha256) { throw "$Url has SHA-256 $actual, expected $Sha256" }
    & $SevenZip x $zip "-o$Destination" -y | Out-Null
    if ($LASTEXITCODE) { throw "7-Zip couldn't unpack $Url (exit $LASTEXITCODE)" }
}
finally {
    Remove-Item -Path $zip -ErrorAction SilentlyContinue
}

foreach ($relative in $Executable) {
    $path = Join-Path $Destination $relative
    $header = [byte[]]::new(2)
    $stream = [IO.File]::OpenRead($path)
    try { $null = $stream.Read($header, 0, 2) } finally { $stream.Dispose() }
    if ([Text.Encoding]::ASCII.GetString($header) -ne 'MZ') { throw "$path isn't an executable after extraction" }
    Write-Output "ok: $path ($((Get-Item $path).Length) bytes)"
}
