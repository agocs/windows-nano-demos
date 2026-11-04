<#
.SYNOPSIS
  Resolves an api-tests target (targets.json) to the base image for the probe layer.

.DESCRIPTION
  A target with base_image is used as is ({v} becomes the Windows version).
  A target with build_folder is built first from that folder of the repo, and
  is skipped (skip=true) when the folder does not exist yet.

  Writes base_image=... and skip=true|false to $env:GITHUB_OUTPUT when it is
  set, and returns the same values as an object.

.EXAMPLE
  ./api-tests/scripts/Resolve-Target.ps1 -Name nanoserver -WindowsVersion 2022
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [ValidateSet('2019', '2022', '2025')] [string] $WindowsVersion
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$targets = (Get-Content -Raw (Join-Path $PSScriptRoot '..\targets.json') | ConvertFrom-Json).targets
$t = $targets | Where-Object name -EQ $Name
if (-not $t) { throw "unknown target '$Name' (see api-tests/targets.json)" }

$skip = $false
$baseImage = ''
if ($t.build_folder) {
    $folder = Join-Path $root $t.build_folder
    if (-not (Test-Path (Join-Path $folder 'Dockerfile'))) {
        Write-Host "::notice title=api-tests::target $Name skipped: $($t.build_folder)/ does not exist yet"
        $skip = $true
    } else {
        $baseImage = $t.image -replace '\{v\}', $WindowsVersion
        Push-Location $folder
        try {
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                $log = docker build --memory 4g --build-arg "WINDOWS_VERSION=$WindowsVersion" -t $baseImage . 2>&1
                $rc = $LASTEXITCODE
                $log | Write-Host
                if ($rc -eq 0) { break }
                if ($attempt -eq 1 -and ($log -match 'hcs.*context deadline exceeded')) {
                    Write-Host 'retrying after hcs context deadline exceeded'
                    continue
                }
                throw "docker build of $($t.build_folder) failed ($rc)"
            }
        } finally { Pop-Location }
    }
} else {
    $baseImage = $t.base_image -replace '\{v\}', $WindowsVersion
}

if ($env:GITHUB_OUTPUT) {
    "base_image=$baseImage" | Add-Content $env:GITHUB_OUTPUT
    "skip=$($skip.ToString().ToLowerInvariant())" | Add-Content $env:GITHUB_OUTPUT
}
[pscustomobject]@{ Name = $Name; WindowsVersion = $WindowsVersion; BaseImage = $baseImage; Skip = $skip }
