# Custom PSScriptAnalyzer rules for this repo, loaded through CustomRulePath in PSScriptAnalyzerSettings.psd1.
# Every .ps1 script is an advanced script with comment-based help, so `Get-Help ./x.ps1` works and common
# parameters such as -Verbose and -ErrorAction behave the same everywhere.

function Get-ScriptFileAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst)
    # PSScriptAnalyzer calls the rule for every script block; only the file's own top-level block counts, and only
    # for scripts (.psm1 modules and .psd1 data files have no script-level param block)
    if ($null -eq $ScriptBlockAst.Parent -and $ScriptBlockAst.Extent.File -like '*.ps1') { $ScriptBlockAst }
}

function ConvertTo-RepoDiagnostic {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord])]
    param([string]$Message, [System.Management.Automation.Language.IScriptExtent]$Extent, [string]$RuleName)
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
        Message  = $Message
        Extent   = $Extent
        RuleName = $RuleName
        Severity = 'Error'
    }
}

<#
.SYNOPSIS
Every script declares [CmdletBinding()] on its param block.
.DESCRIPTION
Advanced scripts get the common parameters and reject misspelled parameters instead of silently ignoring them.
A script without parameters still needs `[CmdletBinding()]` followed by `param()`.
#>
function Measure-ScriptCmdletBinding {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst
    )
    process {
        $script = Get-ScriptFileAst $ScriptBlockAst
        if (-not $script) { return }
        $names = @($script.ParamBlock.Attributes | ForEach-Object { $_.TypeName.Name })
        if ($names -match '^(System\.Management\.Automation\.)?CmdletBinding(Attribute)?$') { return }
        ConvertTo-RepoDiagnostic -RuleName 'PSRepoScriptCmdletBinding' -Extent ($script.ParamBlock ?? $script).Extent `
            -Message 'Scripts must be advanced scripts: put [CmdletBinding()] before param() (add an empty param() if there are no parameters).'
    }
}

<#
.SYNOPSIS
Every script starts with comment-based help that has a .SYNOPSIS.
.DESCRIPTION
The help block goes at the top of the file, before [CmdletBinding()], so `Get-Help ./script.ps1` shows it.
#>
function Measure-ScriptCommentHelp {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst
    )
    process {
        $script = Get-ScriptFileAst $ScriptBlockAst
        if (-not $script) { return }
        $help = $script.GetHelpContent()
        if ($help -and -not [string]::IsNullOrWhiteSpace($help.Synopsis)) { return }
        ConvertTo-RepoDiagnostic -RuleName 'PSRepoScriptCommentHelp' -Extent ($script.ParamBlock ?? $script).Extent `
            -Message 'Scripts must start with comment-based help (<# .SYNOPSIS ... #>) before [CmdletBinding()] and param().'
    }
}

Export-ModuleMember -Function Measure-*
