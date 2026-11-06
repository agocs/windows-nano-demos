<#
.SYNOPSIS
Starts the nano server GitHub Actions runner container against the host docker daemon.
.DESCRIPTION
Gets a short-lived registration token with the gh CLI and starts the container with the
host's docker named pipe mounted. Pipe mounts need process isolation, so the image's
Windows version must be compatible with the host (ltsc2022 works on Windows 11).
#>
[CmdletBinding()]
param(
    [string]$Repo = 'zippy1981/windows-nano-demos',
    [string]$Name = "$env:COMPUTERNAME-nano",
    [string]$Image = 'windows-nano-gh-runner:2025',
    [string]$Labels = 'nanoserver,docker'
)
$ErrorActionPreference = 'Stop'

$token = gh api -X POST "repos/$Repo/actions/runners/registration-token" --jq .token
if (-not $token) { throw "Could not get a registration token for $Repo" }

docker rm -f $Name 2>$null | Out-Null
docker run -d --name $Name --restart unless-stopped `
    --isolation=process `
    -v '\\.\pipe\docker_engine:\\.\pipe\docker_engine' `
    -e "RUNNER_URL=https://github.com/$Repo" `
    -e "RUNNER_TOKEN=$token" `
    -e "RUNNER_NAME=$Name" `
    -e "RUNNER_LABELS=$Labels" `
    $Image
