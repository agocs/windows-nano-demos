<#
.SYNOPSIS
Smoke tests a built windows-nano-go image: the tools, the Go version it was built with (issue #20), a hello world module,
and a real project (issue #18).
It clones and builds algernon (https://github.com/xyproto/algernon) inside the image, runs it, and checks it over HTTP with
curl from inside the container. algernon's go.mod needs a minimum Go, and the image sets GOTOOLCHAIN=local, so images with
an older Go skip that part and say so rather than downloading a newer toolchain.
.EXAMPLE
./nano-server/nano-server-go/smoke-test.ps1 -Image windows-nano-go:2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image,
    [string]$AlgernonVersion = 'v1.17.12',
    # The `go` line in algernon's go.mod at $AlgernonVersion
    [version]$AlgernonMinimumGo = '1.27.3'
)
$ErrorActionPreference = 'Stop'

# The GO_VERSION the image was built with, from its environment
$goVersion = (docker image inspect $Image --format '{{range .Config.Env}}{{println .}}{{end}}' | Select-String '^GO_VERSION=(.+)$').Matches.Groups[1].Value
if (-not $goVersion) { throw "$Image has no GO_VERSION in its environment" }

$suffix = [guid]::NewGuid().ToString('n').Substring(0, 8)
$helloImage = "go-smoke-hello:$suffix"
$algernonImage = "go-smoke-algernon:$suffix"
$algernonContainer = "go-smoke-algernon-$suffix"

# Builds a throwaway image FROM the image under test. The runner is itself a container, so there are no bind mounts.
function Build-Derived([string]$Tag, [string]$Dockerfile) {
    $Dockerfile.Replace('__IMAGE__', $Image) | docker build --memory 4g -t $Tag -
    if ($LASTEXITCODE) { throw "building $Tag failed: $LASTEXITCODE" }
}

try {
    # nanoserver has no where.exe, so run each tool to prove it is on PATH
    docker run --rm $Image "go version && go env GOPATH CGO_ENABLED GOTOOLCHAIN && git --version && micro -version"
    if ($LASTEXITCODE) { throw "tool check failed: $LASTEXITCODE" }
    $reported = docker run --rm $Image "go version"
    if ($reported -notmatch "go$([regex]::Escape($goVersion)) windows/amd64") { throw "expected Go $goVersion, image reports: $reported" }

    Build-Derived $helloImage @'
FROM __IMAGE__
WORKDIR C:/users/containeruser/hello
RUN echo package main> main.go && echo import "fmt">> main.go && echo func main() { fmt.Println("hello from go") }>> main.go && go mod init hello && go build -o hello.exe .
'@
    $out = docker run --rm $helloImage "hello.exe"
    if ($LASTEXITCODE -or $out -notmatch 'hello from go') { throw "hello world failed ($LASTEXITCODE): $out" }
    Write-Host $out

    if ([version]$goVersion -lt $AlgernonMinimumGo) {
        Write-Host "SKIP algernon ${AlgernonVersion}: it needs Go $AlgernonMinimumGo and this image has Go $goVersion with GOTOOLCHAIN=local"
        return
    }

    # Issue #18: a real-world module with many dependencies, built with CGO disabled
    Build-Derived $algernonImage @"
FROM __IMAGE__
WORKDIR C:/users/containeruser
RUN git clone --depth 1 --branch $AlgernonVersion https://github.com/xyproto/algernon
# Modules in their own layer: the daemon reuses it on later runs while algernon's go.mod is unchanged
RUN cd algernon && go mod download
# -buildvcs=false: the clone is in an earlier layer, and git won't report VCS status there for Go's version stamp
RUN cd algernon && go build -buildvcs=false -o C:\users\containeruser\algernon.exe .
RUN mkdir C:\users\containeruser\site && echo algernon-ok> C:\users\containeruser\site\index.html
"@
    docker run -d --name $algernonContainer $algernonImage "C:\users\containeruser\algernon.exe --httponly --server --nobanner --addr :3000 C:\users\containeruser\site" | Out-Null
    if ($LASTEXITCODE) { throw "starting algernon failed: $LASTEXITCODE" }

    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 3
        if ((docker inspect -f '{{.State.Running}}' $algernonContainer) -ne 'true') {
            docker logs $algernonContainer
            throw 'algernon exited'
        }
        $body = docker exec $algernonContainer curl.exe -fsS http://localhost:3000/ 2>$null
    } until (($body -match 'algernon-ok') -or (Get-Date) -gt $deadline)

    if ($body -notmatch 'algernon-ok') {
        docker logs $algernonContainer
        throw 'algernon did not serve the test page within 2 minutes'
    }
    Write-Host "algernon $AlgernonVersion served: $body"
}
finally {
    docker rm -f $algernonContainer 2>$null | Out-Null
    # --no-prune keeps the clone, module and build layers cached for the next run
    docker rmi -f --no-prune $algernonImage $helloImage 2>$null | Out-Null
}
