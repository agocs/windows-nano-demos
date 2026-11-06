<#
.SYNOPSIS
Runs PSScriptAnalyzer with the repo's settings over every PowerShell file tracked by git.
.DESCRIPTION
Uses PSScriptAnalyzerSettings.psd1, including the custom rules that require [CmdletBinding()] and comment-based help
on every script. Only files tracked by git are analyzed, so .venv and worktrees are skipped. Prints one line per
finding (a GitHub annotation when run in Actions) and fails if there are any.
.PARAMETER Path
The repository root. Defaults to the parent of this script's folder.
.EXAMPLE
./scripts/Invoke-RepoScriptAnalyzer.ps1
.EXAMPLE
docker run --rm -v "${PWD}:C:\src" -w C:\src windows-nano-powershell:2025 pwsh -File scripts/Invoke-RepoScriptAnalyzer.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -MinimumVersion 1.25.0

Push-Location $Path
try {
    $files = @(git ls-files -- '*.ps1' '*.psm1' '*.psd1' 2>$null)
    if ($LASTEXITCODE) {
        # Not a usable git checkout (for example a worktree mounted into a container): walk the folder instead,
        # skipping dot-folders such as .git, .venv and .claude
        $files = @(Get-ChildItem -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
                ForEach-Object { [IO.Path]::GetRelativePath($PWD, $_.FullName) } |
                Where-Object { $_ -notmatch '(^|[\\/])\.' })
    }
    $results = @(foreach ($file in $files) {
            Invoke-ScriptAnalyzer -Path $file -Settings ./PSScriptAnalyzerSettings.psd1
        })
}
finally {
    Pop-Location
}

foreach ($result in $results) {
    $file = [IO.Path]::GetRelativePath($Path, $result.ScriptPath) -replace '\\', '/'
    if ($env:GITHUB_ACTIONS) {
        Write-Output "::error file=$file,line=$($result.Line),col=$($result.Column),title=$($result.RuleName)::$($result.Message)"
    }
    else {
        Write-Output "${file}:$($result.Line): $($result.RuleName): $($result.Message)"
    }
}
if ($results.Count) { throw "PSScriptAnalyzer: $($results.Count) finding(s) in $($files.Count) files" }
Write-Output "PSScriptAnalyzer: no findings in $($files.Count) files"
