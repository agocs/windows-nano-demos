<#
.SYNOPSIS
Smoke tests a built windows-nano-php image. Throws on the first failure.
.EXAMPLE
./nano-server/nano-server-php/smoke-test.ps1 -Image windows-nano-php:2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image
)
$ErrorActionPreference = 'Stop'
Write-Host "Smoke testing $Image"

# The image's entrypoint is cmd /S /C, so each call runs through cmd with the user's PATH
function Invoke-Image {
    $out = docker run --rm $Image @args
    $code = $LASTEXITCODE
    Write-Host "> $args"
    $out | Write-Host
    if ($code) { throw "'$args' failed: $code" }
    return $out
}

Invoke-Image php -v | Out-Null
$modules = Invoke-Image php -m
foreach ($m in 'curl', 'fileinfo', 'openssl', 'zip') {
    if ($modules -notcontains $m) { throw "PHP extension $m is not loaded" }
}
$len = Invoke-Image php -r "echo strlen(file_get_contents('https://example.com'));"
if ([int]($len | Select-Object -Last 1) -le 0) { throw 'TLS fetch returned nothing' }
Invoke-Image node -v | Out-Null
Invoke-Image npm -v | Out-Null
Invoke-Image composer --version | Out-Null
Invoke-Image laravel --version | Out-Null
Invoke-Image where micro | Out-Null
