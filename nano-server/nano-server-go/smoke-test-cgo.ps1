<#
.SYNOPSIS
Small cgo smoke test for a windows-nano-go image that has a C toolchain (see plans/go-cgo.md).
It checks CGO_ENABLED=1 and that CC runs, then builds and runs a Go program that calls a C function through import "C".
The program prints a value computed in C, so a build that silently fell back to pure Go cannot pass.
.EXAMPLE
./nano-server/nano-server-go/smoke-test-cgo.ps1 -Image windows-nano-go:1.27.3-cgo-2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image
)
$ErrorActionPreference = 'Stop'

$suffix = [guid]::NewGuid().ToString('n').Substring(0, 8)
$helloImage = "go-smoke-cgo:$suffix"

try {
    $cgo = (docker run --rm $Image "go env CGO_ENABLED").Trim()
    if ($LASTEXITCODE -or $cgo -ne '1') { throw "expected CGO_ENABLED=1 in $Image, got '$cgo'" }

    # nanoserver has no where.exe, so run the compiler to prove it is on PATH
    # CC is set with `go env -w` in the image, so ask go for it
    $ccName = (docker run --rm $Image "go env CC").Trim()
    if ($LASTEXITCODE -or -not $ccName) { throw "go env CC is empty in $Image" }
    $cc = docker run --rm $Image "$ccName --version"
    if ($LASTEXITCODE) { throw "the C compiler (CC=$ccName) did not run: $LASTEXITCODE $cc" }
    Write-Host ($cc | Select-Object -First 1)

    # The runner is itself a container, so there are no bind mounts: the source is written by RUN steps.
    # add() is computed in C: 7 * 6 + 0 = 42. Go would print the same only if cgo really compiled it.
    @'
FROM __IMAGE__
WORKDIR C:/users/containeruser/hello
RUN echo package main> main.go && echo /*>> main.go && echo static int add(int a, int b) { return a * 6 + b; }>> main.go && echo */>> main.go && echo import "C">> main.go && echo import "fmt">> main.go && echo func main() { fmt.Println("cgo says", C.add(7, 0)) }>> main.go && go mod init hello && go build -o hello.exe .
'@.Replace('__IMAGE__', $Image) | docker build --memory 4g -t $helloImage -
    if ($LASTEXITCODE) { throw "building the cgo hello world failed: $LASTEXITCODE" }

    $out = docker run --rm $helloImage "hello.exe"
    if ($LASTEXITCODE -or $out -notmatch 'cgo says 42') { throw "cgo hello world failed ($LASTEXITCODE): $out" }
    Write-Host $out
}
finally {
    docker rmi --no-prune $helloImage 2>$null | Out-Null
}
