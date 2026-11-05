# PowerShell lint

## Goal

Every PowerShell file in the repo passes PSScriptAnalyzer in CI, and every `.ps1` script is an advanced script with comment-based help. No Pester tests are added.

## Context

- The repo has 13 PowerShell scripts: the image smoke tests, the runner's `start.ps1` and `run-runner.ps1`, the SSH image's `test.ps1`, PowerShell's in-container `tests/smoke.ps1` and `scripts/Remove-DockerArtifacts.ps1`. Before this change only `Remove-DockerArtifacts.ps1` had `[CmdletBinding()]`, and two scripts had no help.
- Nothing analyzed them in CI. The `powershell-author` agent is told to keep code clean under PSScriptAnalyzer, but nothing checked.
- PSScriptAnalyzer's built-in `PSProvideCommentHelp` only checks functions, and no built-in rule checks a script's own `[CmdletBinding()]`.

## Decisions

1. **Custom rules in PSScriptAnalyzer, not a separate checker.** `tools/psscriptanalyzer/RepoRules.psm1` adds:
   - `PSRepoScriptCmdletBinding`: the script's param block has `[CmdletBinding()]`
   - `PSRepoScriptCommentHelp`: the script has comment-based help with a `.SYNOPSIS` that `Get-Help` can find

   Both apply only to a `.ps1` file's top-level script block, and both are errors. `PSScriptAnalyzerSettings.psd1` at the repo root loads them with the default rules, at Error and Warning severity.
2. **One exclusion:** `PSAvoidUsingWriteHost`. Smoke tests and CI helpers write progress to the CI log on purpose. Any other finding is fixed, or suppressed in the code with `SuppressMessageAttribute` and a justification. The MySQL smoke test's generated throwaway passwords are the only suppression.
3. **Only files tracked by git are analyzed** (`scripts/Invoke-RepoScriptAnalyzer.ps1`), so `.venv`, worktrees and downloads are skipped. When git isn't usable, for example a worktree mounted into a container, it walks the folder and skips dot-folders.
4. **CI on `ubuntu-latest`** (`.github/workflows/powershell-lint.yml`), with PSScriptAnalyzer pinned to 1.25.0, the version in the `windows-nano-powershell` image. It runs when any `.ps1`, `.psm1` or `.psd1` file, the rules or the workflow change. Findings show as annotations on the PR.
5. **No Pester tests**, as requested. The rules are checked by running them over the repo's own scripts.

## Plan

- [x] **powershell-author**: Custom rules, settings, and `scripts/Invoke-RepoScriptAnalyzer.ps1`. Accept: running it in `windows-nano-powershell:2025` lists the missing attributes and help.
- [x] **powershell-author**: Fix the findings in every script:
  - add `[CmdletBinding()]` to each script
  - add help to `start.ps1` and `tests/smoke.ps1`, keeping `smoke.ps1`'s help short because it's sent with `-EncodedCommand`
  - move `#Requires` below the help in `ssh/test.ps1`, so `Get-Help` finds it
  - use `$Image` at the top level of the PHP smoke test
  - suppress the MySQL test-password rules with a justification

  Accept: "no findings".
- [x] **workflow-author**: `powershell-lint.yml`. Accept: the workflow passes on its PR, and the image workflows still pass with the changed scripts.
- [x] **container-author**: Document the rules and the local run in `DEVELOPER.md`. Accept: markdownlint passes.

## Risks

- **`[CmdletBinding()]` changes how a script binds arguments.** An unknown argument is now an error instead of being ignored. Mitigation: every image workflow runs its smoke test on this PR. The runner's `start.ps1` takes no arguments.
- **The `smoke.ps1` command line grows.** It is sent as `-EncodedCommand`, which is limited to 8191 characters through cmd. Mitigation: the help is one line, and the file stays under 2,500 characters (about 6,700 encoded).
