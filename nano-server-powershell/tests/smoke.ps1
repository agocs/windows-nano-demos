# Smoke test for the windows-nano-powershell image. Runs inside the container.
# Kept small: CI passes it to pwsh with -EncodedCommand, and cmd.exe limits the command line to 8191 chars.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PSVersionTable | Format-Table -AutoSize | Out-String | Write-Output
if ($PSVersionTable.PSVersion.Major -ne 7) { throw "Expected PowerShell 7, got $($PSVersionTable.PSVersion)" }

git --version
if ($LASTEXITCODE -ne 0) { throw 'git --version failed' }
micro -version
if ($LASTEXITCODE -ne 0) { throw 'micro -version failed' }

Get-Module -ListAvailable Pester, PSScriptAnalyzer, Microsoft.PowerShell.PlatyPS, PSReadLine, Microsoft.PowerShell.PSResourceGet |
    Sort-Object Name, Version -Descending | Format-Table Name, Version -AutoSize | Out-String | Write-Output

$dir = Join-Path ([IO.Path]::GetTempPath()) "smoke-$PID"
New-Item -ItemType Directory -Path $dir | Out-Null
Set-Content -Path (Join-Path $dir 'Add.ps1') -Value 'function Add-Number { param([int]$A, [int]$B) $A + $B }'
Set-Content -Path (Join-Path $dir 'Add.Tests.ps1') -Value @'
BeforeAll { . (Join-Path $PSScriptRoot 'Add.ps1') }
Describe 'Add-Number' {
    It 'adds two numbers' { Add-Number -A 2 -B 3 | Should -Be 5 }
}
'@
$result = Invoke-Pester -Path (Join-Path $dir 'Add.Tests.ps1') -PassThru -Output Detailed
if ($result.FailedCount -ne 0 -or $result.PassedCount -ne 1) { throw 'Pester smoke test failed' }

# gci is an alias, so PSAvoidUsingCmdletAliases must fire
Set-Content -Path (Join-Path $dir 'Sample.ps1') -Value 'gci C:\ | Out-Null'
$findings = Invoke-ScriptAnalyzer -Path (Join-Path $dir 'Sample.ps1')
$findings | Format-Table RuleName, Severity, Line, Message -AutoSize | Out-String -Width 200 | Write-Output
if ($findings.RuleName -notcontains 'PSAvoidUsingCmdletAliases') { throw 'PSScriptAnalyzer did not report PSAvoidUsingCmdletAliases' }

Import-Module Microsoft.PowerShell.PlatyPS
Get-Command New-MarkdownCommandHelp | Format-Table Name, Source -AutoSize | Out-String | Write-Output

# Best effort: ContainerUser's TEMP is C:\Windows\TEMP and deleting there can be denied. The container is --rm anyway.
try { Remove-Item -Recurse -Force $dir } catch { Write-Warning "Cleanup of $dir failed: $_" }
'SMOKE TEST PASSED'
