# PSScriptAnalyzer settings for every PowerShell file in this repo. CI runs them through
# scripts/Invoke-RepoScriptAnalyzer.ps1 (.github/workflows/powershell-lint.yml). VS Code's PowerShell extension also
# picks this file up from the repo root.
@{
    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true
    # Every script has [CmdletBinding()] and comment-based help (plans/powershell-lint.md)
    CustomRulePath      = @('./tools/psscriptanalyzer/RepoRules.psm1')
    ExcludeRules        = @(
        # Smoke tests and CI helpers write progress to the CI log on purpose
        'PSAvoidUsingWriteHost'
    )
}
