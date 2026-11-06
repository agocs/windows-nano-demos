<#
.SYNOPSIS
Downloads a zip, checks its SHA-256, unpacks it, and checks that the executables in it really are executables.
.DESCRIPTION
Runs in the Dockerfile's Server Core download stage. It unpacks with Expand-Archive rather than tar.exe, because
bsdtar silently extracted nano.exe from its zip as zero bytes (plans/console-editors.md). Each -Executable must
start with the "MZ" header after extraction, so an editor that "is installed" but can't start fails the build.
.PARAMETER Url
The zip to download.
.PARAMETER Sha256
The zip's expected SHA-256, as pinned in the Dockerfile.
.PARAMETER Destination
The folder to unpack into. It is created.
.PARAMETER Executable
Paths, relative to -Destination, of the executables to check.
.EXAMPLE
./Get-VerifiedZip.ps1 -Url https://example.com/tool.zip -Sha256 0123... -Destination C:\editors\tool -Executable tool.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Sha256,
    [Parameter(Mandatory)][string]$Destination,
    [string[]]$Executable = @()
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$zip = Join-Path $env:TEMP "download-$([guid]::NewGuid().ToString('n')).zip"
try {
    curl.exe -fsSLo $zip $Url
    if ($LASTEXITCODE) { throw "downloading $Url failed: $LASTEXITCODE" }
    $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
    if ($actual -ne $Sha256) { throw "$Url has SHA-256 $actual, expected $Sha256" }
    Expand-Archive -Path $zip -DestinationPath $Destination
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
