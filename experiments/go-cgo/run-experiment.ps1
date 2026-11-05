# EXPERIMENTAL - not wired into CI. Part of plans/go-cgo.md.
# Builds each toolchain layer on a windows-nano-go image, then checks `cc --version` and a cgo hello world on nanoserver.
# Everything it creates is named cgo-exp-*. Usage: ./run-experiment.ps1 -GoImage windows-nano-go:2025 -Version 2025 -Toolchain llvm-mingw,zig
param(
    [Parameter(Mandatory)][string]$GoImage,
    [Parameter(Mandatory)][string]$Version,
    [string[]]$Toolchain = @('llvm-mingw', 'zig', 'winlibs'),
    [string]$LogDir = $env:TEMP
)
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

$hello = @'
FROM __IMAGE__
WORKDIR C:/users/containeruser/hello
RUN echo package main> main.go && echo /*>> main.go && echo static int add(int a, int b) { return a * 6 + b; }>> main.go && echo */>> main.go && echo import "C">> main.go && echo import "fmt">> main.go && echo func main() { fmt.Println("cgo says", C.add(7, 0)) }>> main.go && go mod init hello && go build -o hello.exe .
'@

foreach ($t in $Toolchain) {
    $tag = "cgo-exp-${t}:$Version"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    docker build --memory 4g --build-arg GO_IMAGE=$GoImage -f "Dockerfile.$t" -t $tag . *> "$LogDir\cgo-exp-$t-$Version.build.log"
    $buildRc = $LASTEXITCODE
    "$t $Version build rc=$buildRc secs=$([int]$sw.Elapsed.TotalSeconds) size=$(docker image inspect $tag --format '{{.Size}}' 2>$null)"
    if ($buildRc) { continue }
    $ccv = docker run --rm $tag "%CC% --version" 2>&1
    "$t $Version cc --version rc=$LASTEXITCODE : $($ccv | Select-Object -First 2)"
    $sw.Restart()
    $hello.Replace('__IMAGE__', $tag) | docker build --memory 4g -t "cgo-exp-hello-${t}:$Version" - *> "$LogDir\cgo-exp-$t-$Version.hello.log"
    $helloRc = $LASTEXITCODE
    "$t $Version hello build rc=$helloRc secs=$([int]$sw.Elapsed.TotalSeconds)"
    if (-not $helloRc) {
        $out = docker run --rm "cgo-exp-hello-${t}:$Version" "hello.exe" 2>&1
        "$t $Version hello run rc=$LASTEXITCODE : $out"
    }
}
