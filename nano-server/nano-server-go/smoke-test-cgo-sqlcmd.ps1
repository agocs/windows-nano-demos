<#
.SYNOPSIS
Large cgo smoke test for a windows-nano-go image that has a C toolchain (see plans/go-cgo.md).
It builds sqlcmd (https://github.com/microsoft/go-sqlcmd) with CGO_ENABLED=1 and runs `sqlcmd --version`.
Clone, `go mod download` and build are separate RUN steps so the module download is its own cached layer.
go-sqlcmd's go.mod needs a minimum Go, and the image sets GOTOOLCHAIN=local, so images with an older Go skip and say so.
.EXAMPLE
./nano-server/nano-server-go/smoke-test-cgo-sqlcmd.ps1 -Image windows-nano-go:1.27.3-cgo-2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image,
    [string]$SqlcmdVersion = 'v1.10.0',
    # The `go` line in go-sqlcmd's go.mod at $SqlcmdVersion
    [version]$SqlcmdMinimumGo = '1.25.7'
)
$ErrorActionPreference = 'Stop'

$goVersion = (docker image inspect $Image --format '{{range .Config.Env}}{{println .}}{{end}}' | Select-String '^GO_VERSION=(.+)$').Matches.Groups[1].Value
if (-not $goVersion) { throw "$Image has no GO_VERSION in its environment" }
if ([version]$goVersion -lt $SqlcmdMinimumGo) {
    Write-Host "SKIP sqlcmd ${SqlcmdVersion}: it needs Go $SqlcmdMinimumGo and this image has Go $goVersion with GOTOOLCHAIN=local"
    return
}

$suffix = [guid]::NewGuid().ToString('n').Substring(0, 8)
$sqlcmdImage = "go-smoke-sqlcmd:$suffix"

try {
    $cgo = (docker run --rm $Image "go env CGO_ENABLED").Trim()
    if ($LASTEXITCODE -or $cgo -ne '1') { throw "expected CGO_ENABLED=1 in $Image, got '$cgo'" }

    # The runner is itself a container, so there are no bind mounts.
    @"
FROM __IMAGE__
WORKDIR C:/users/containeruser
RUN git clone --depth 1 --branch $SqlcmdVersion https://github.com/microsoft/go-sqlcmd
WORKDIR C:/users/containeruser/go-sqlcmd
RUN go mod download
RUN set CGO_ENABLED=1&& go build -buildvcs=false -o C:\users\containeruser\sqlcmd.exe ./cmd/modern
"@.Replace('__IMAGE__', $Image) | docker build --memory 4g -t $sqlcmdImage -
    if ($LASTEXITCODE) { throw "building sqlcmd failed: $LASTEXITCODE" }

    $out = docker run --rm $sqlcmdImage "C:\users\containeruser\sqlcmd.exe --version"
    if ($LASTEXITCODE -or -not $out) { throw "sqlcmd --version failed ($LASTEXITCODE): $out" }
    Write-Host "sqlcmd $SqlcmdVersion built with cgo: $out"
}
finally {
    docker rmi --no-prune $sqlcmdImage 2>$null | Out-Null
}
