<#
.SYNOPSIS
Sets a Docker Hub repository's short description and overview from the image's Dockerfile header and README.md.
.DESCRIPTION
The short description is the Dockerfile's first line after "# <image>: " (the dockerfile-docs skill). Docker Hub
allows 100 characters. The overview is the image folder's README.md, with relative links and images rewritten to
GitHub URLs at -Revision (Docker Hub can't resolve relative paths), plus a footer that links the source, the
Dockerfile and the tag scheme.

With -WhatIf it only builds and checks both texts, needs no credentials, and prints a summary. CI does that on every
pull request, so broken documentation fails before anything is published. Without -WhatIf it signs in to the Docker
Hub API with DOCKERHUB_USERNAME and DOCKERHUB_TOKEN and updates the repository. Editing a repository's description
needs a personal access token with the Read, Write, Delete scope. The token is never printed.
.PARAMETER Context
The image folder, relative to the repository root, for example nano-server/nano-server-go.
.PARAMETER Repository
The Docker Hub repository, for example zippy1981/windows-nano-go.
.PARAMETER GitHubRepository
The GitHub repository that links in the overview point to.
.PARAMETER Revision
The commit or branch that links in the overview point to. CI passes the commit it published.
.PARAMETER PreviewPath
Also write the overview to this file, to review it before it is published.
.EXAMPLE
./scripts/Publish-DockerHubDocs.ps1 -Context nano-server/nano-server-go -Repository zippy1981/windows-nano-go -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Context,
    [Parameter(Mandatory)][string]$Repository,
    [string]$GitHubRepository = 'zippy1981/windows-nano-demos',
    [string]$Revision = 'main',
    [string]$PreviewPath
)
$ErrorActionPreference = 'Stop'
$MaxShort = 100
$MaxFull = 25000

$root = Split-Path -Parent $PSScriptRoot
$folder = Join-Path $root $Context
$first = Get-Content -Path (Join-Path $folder 'Dockerfile') -TotalCount 1
if ($first -notmatch '^# [\w.-]+: (?<description>\S.*)$') {
    throw "$Context/Dockerfile must start with '# <image>: <description>' (dockerfile-docs skill)"
}
$short = $Matches.description.Trim()
if ($short.Length -gt $MaxShort) {
    throw "$Context/Dockerfile's description is $($short.Length) characters; Docker Hub allows $MaxShort"
}

$readmePath = Join-Path $folder 'README.md'
if (-not (Test-Path $readmePath)) { throw "$Context/README.md is missing; it becomes the Docker Hub overview" }
$readme = Get-Content -Raw -Path $readmePath
$blob = "https://github.com/$GitHubRepository/blob/$Revision"
$raw = "https://raw.githubusercontent.com/$GitHubRepository/$Revision"
$rewritten = 0
# [text](target) and ![alt](target) with a relative target. URLs (scheme:) and #anchors stay as they are.
$overview = [regex]::Replace($readme, '(?<bang>!?)\[(?<text>[^\]]*)\]\((?<target>[^)\s]+)(?<title>\s+"[^"]*")?\)', {
        param($match)
        $target = $match.Groups['target'].Value
        if ($target -match '^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|#)') { return $match.Value }
        $path, $anchor = $target -split '#', 2
        $full = [IO.Path]::GetFullPath([IO.Path]::Combine($folder, $path))
        $relative = [IO.Path]::GetRelativePath($root, $full) -replace '\\', '/'
        $base = if ($match.Groups['bang'].Value) { $raw } else { $blob }
        $url = "$base/$relative" + $(if ($anchor) { "#$anchor" } else { '' })
        $script:rewritten++
        return "$($match.Groups['bang'].Value)[$($match.Groups['text'].Value)]($url$($match.Groups['title'].Value))"
    })
$contextPath = $Context -replace '\\', '/'
$overview = $overview.TrimEnd() + @"


---

Built from [``$contextPath``]($blob/$contextPath) ([Dockerfile]($blob/$contextPath/Dockerfile)) in [$GitHubRepository](https://github.com/$GitHubRepository). Tags follow [ADR 0005]($blob/docs/adr/0005-tagging-scheme-for-windows-images.md): ``<windows version>`` (2019, 2022, 2025), ``<version>-<os build>``, ``<version>-YYYY-MM`` and an immutable ``<version>-<os build>-<commit>``.
"@
if ($overview.Length -gt $MaxFull) {
    throw "$Context/README.md makes a $($overview.Length)-character overview; Docker Hub allows $MaxFull"
}

if ($PreviewPath) { Set-Content -Path $PreviewPath -Value $overview -Encoding utf8 -WhatIf:$false }

if (-not $PSCmdlet.ShouldProcess($Repository, 'Update the Docker Hub short description and overview')) {
    Write-Output "${Repository}: short description ($($short.Length)/$MaxShort): $short"
    Write-Output "${Repository}: overview $($overview.Length)/$MaxFull characters, $rewritten relative links rewritten"
    return
}

if (-not $env:DOCKERHUB_USERNAME -or -not $env:DOCKERHUB_TOKEN) { throw 'DOCKERHUB_USERNAME and DOCKERHUB_TOKEN must be set' }
$retry = @{ MaximumRetryCount = 3; RetryIntervalSec = 10 }
try {
    $login = @{ identifier = $env:DOCKERHUB_USERNAME; secret = $env:DOCKERHUB_TOKEN } | ConvertTo-Json
    $jwt = (Invoke-RestMethod @retry -Method Post -Uri 'https://hub.docker.com/v2/auth/token' -ContentType 'application/json' -Body $login).access_token
}
catch {
    throw "Docker Hub sign-in failed: HTTP $($_.Exception.Response.StatusCode)"
}
$body = @{ description = $short; full_description = $overview } | ConvertTo-Json
try {
    Invoke-RestMethod @retry -Method Patch -Uri "https://hub.docker.com/v2/repositories/$Repository/" `
        -Headers @{ Authorization = "Bearer $jwt" } -ContentType 'application/json' -Body $body | Out-Null
}
catch {
    $status = $_.Exception.Response.StatusCode
    $hint = if ("$status" -in 'Forbidden', 'Unauthorized') { ' (the token needs the Read, Write, Delete scope)' } else { '' }
    throw "updating the description of $Repository failed: HTTP $status$hint"
}
Write-Output "${Repository}: updated the short description and the overview ($($overview.Length) characters)"
