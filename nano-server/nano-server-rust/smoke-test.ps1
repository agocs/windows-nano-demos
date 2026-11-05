<#
.SYNOPSIS
Smoke tests a built windows-nano-rust image by compiling and running a hello world crate. Throws on failure.
.EXAMPLE
./nano-server/nano-server-rust/smoke-test.ps1 -Image windows-nano-rust:2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Image
)
$ErrorActionPreference = 'Stop'

$out = docker run --rm $Image "rustc --version && cargo --version && git --version && cargo new hello && cd hello && cargo run"
$code = $LASTEXITCODE
$out | Write-Host
if ($code) { throw "smoke test failed: $code" }
if (-not ($out -match 'Hello, world!')) { throw 'cargo run did not print Hello, world!' }
