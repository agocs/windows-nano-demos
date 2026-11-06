<#
.SYNOPSIS
Smoke tests a built windows-servercore-far image: Far loads with no missing DLLs, then runs a macro and a command and quits.
.EXAMPLE
./server-core/server-core-far/smoke-test.ps1 -Image windows-servercore-far:2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image
)
$ErrorActionPreference = 'Stop'

$out = docker run --rm --memory 2g $Image "far.exe -?" 2>&1 | Out-String
$code = $LASTEXITCODE
Write-Host $out
# 0xC0000135 (-1073741515) is STATUS_DLL_NOT_FOUND
if ($code) { throw "far.exe -? exited with $code" }
if ($out -match '0xc0000135|unable to start correctly') { throw 'missing DLL' }
if ($out -notmatch 'Far Manager') { throw 'help text not found' }

# The runner is itself a container, so instead of bind-mounting, docker cp the test profile into a created
# (not yet started) container. -t gives Far a console.
$container = "far-smoke-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
try {
    docker create -t --memory 2g --name $container $Image "C:\Users\ContainerUser\far-test\run-test.cmd" | Out-Null
    if ($LASTEXITCODE) { throw "docker create failed: $LASTEXITCODE" }
    docker cp "$PSScriptRoot/test" "$($container):C:\Users\ContainerUser\far-test"
    if ($LASTEXITCODE) { throw "docker cp failed: $LASTEXITCODE" }
    docker start $container | Out-Null
    if ($LASTEXITCODE) { throw "docker start failed: $LASTEXITCODE" }

    # Far is interactive, so if the macro doesn't quit it the container would hang forever
    $deadline = (Get-Date).AddMinutes(5)
    while ((docker inspect -f '{{.State.Running}}' $container) -eq 'true') {
        if ((Get-Date) -gt $deadline) { docker logs $container; throw 'Far did not exit within 5 minutes' }
        Start-Sleep -Seconds 2
    }
    $log = docker logs $container 2>&1 | Out-String
    $exit = [int](docker inspect -f '{{.State.ExitCode}}' $container)
    # Far's screen output is full of console escape sequences. The results block is printed after Far exits.
    $results = $log.Substring([Math]::Max(0, $log.IndexOf('===== far-test results =====')))
    Write-Host ($results -replace "`e\[[0-9;?]*[A-Za-z]", '')
    if ($exit) { throw "run-test.cmd exited with $exit" }
    if ($log -notmatch 'PASS') { throw 'PASS marker not found' }
}
finally {
    docker rm -f $container 2>$null | Out-Null
}
