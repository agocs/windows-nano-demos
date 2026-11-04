<#
.SYNOPSIS
Writes the cmd commands a nanoserver container or build stage runs to use the artifact cache.

.DESCRIPTION
Nanoserver has neither certoc.exe nor certutil.exe, and docker ignores --add-host for Windows
containers, so a client opts in with two kinds of commands that only need cmd and reg:

- `reg add` of the cache's root CA into the machine Root store, in the serialized form the
  Windows certificate store keeps under HKLM\SOFTWARE\Microsoft\SystemCertificates\ROOT.
  Schannel (curl.exe), Go, .NET and PowerShell all trust it from there.
- `ssl-revoke-best-effort` in the .curlrc of ContainerAdministrator and ContainerUser, because
  the internal CA's certificates have no revocation endpoints and Schannel otherwise rejects them.
- one `echo <ip> <host>>>hosts` line per cached host, so those names resolve to the cache.

Both need ContainerAdministrator. The output is one command per line, or with -SingleLine one
line joined with &&, suitable for `docker run ... cmd /S /C "<line>"` or a Dockerfile RUN.

.EXAMPLE
./New-ArtifactCacheClientSetup.ps1 -RootCertificate C:\ProgramData\windows-nano-demos\artifact-cache\root.crt -CacheAddress 172.20.80.5
#>
[CmdletBinding()]
param(
    # PEM or DER root certificate from http://<cache>:8080/root.crt
    [Parameter(Mandatory)][string]$RootCertificate,
    # IP address of the cache container on the nat network
    [Parameter(Mandatory)][string]$CacheAddress,
    # Hosts to send to the cache. Defaults to every site in the Caddyfile next to this script.
    [string[]]$HostName,
    [switch]$SingleLine
)
$ErrorActionPreference = 'Stop'

if (-not $HostName) {
    $caddyfile = Get-Content -Raw (Join-Path $PSScriptRoot 'Caddyfile')
    $HostName = [regex]::Matches($caddyfile, '(?m)^([a-z0-9.-]+\.[a-z]+) \{') | ForEach-Object { $_.Groups[1].Value }
}

$text = (Get-Content -Raw $RootCertificate).Trim()
if ($text -match '-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----') {
    $der = [Convert]::FromBase64String(($Matches[1] -replace '\s', ''))
}
else {
    $der = [IO.File]::ReadAllBytes((Resolve-Path $RootCertificate))
}
$thumbprint = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($der))

# A serialized store element: property id 32 (CERT_CERT_PROP_ID), reserved 1, length, DER bytes
$blob = [byte[]]::new(12 + $der.Length)
[BitConverter]::GetBytes([uint32]32).CopyTo($blob, 0)
[BitConverter]::GetBytes([uint32]1).CopyTo($blob, 4)
[BitConverter]::GetBytes([uint32]$der.Length).CopyTo($blob, 8)
$der.CopyTo($blob, 12)

$commands = @(
    "reg add HKLM\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\$thumbprint /v Blob /t REG_BINARY /d $([Convert]::ToHexString($blob)) /f"
)
# Certificates from Caddy's internal CA have no revocation endpoints, and curl.exe's Schannel
# backend fails such a chain with CRYPT_E_NO_REVOCATION_CHECK. ssl-revoke-best-effort still
# checks revocation where a certificate names an endpoint, so real upstream certificates are unaffected.
foreach ($user in 'ContainerAdministrator', 'ContainerUser') {
    $commands += "echo ssl-revoke-best-effort>>C:\Users\$user\.curlrc"
}
foreach ($name in $HostName) {
    $commands += "echo $CacheAddress $name>>C:\Windows\System32\drivers\etc\hosts"
}

if ($SingleLine) { $commands -join ' && ' } else { $commands }
