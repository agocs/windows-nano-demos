# Claude Code agents

This folder holds the [Claude Code subagents](https://docs.claude.com/en/docs/claude-code/sub-agents) for this repo. Each file's YAML front matter sets the agent's `name`, `description`, `tools`, and `model`. The body is its system prompt.

## Agents

| Agent | Purpose | Model | Tools |
| --- | --- | --- | --- |
| `planning` | Writes plans in `plans/` and names the agent that owns each step. Writes only under `plans/`. | haiku | Read, Glob, Grep, Write, Edit, Agent |
| `adr` | Writes MADR-style decision records in `docs/adr/` and keeps the index. Writes only under `docs/adr/`. | sonnet | Read, Glob, Grep, Write, Edit |
| `governance` | Read-only audit of agents, images, workflows, plans, ADRs, and docs. Returns a ranked gap report. | opus | Read, Glob, Grep |
| `cicd-engineer` | Designs the CI/CD system: runner fleet and image, matrices, schedules, publishing, cleanup, secrets. | opus | Read, Glob, Grep, Write, Edit, Bash, PowerShell, WebFetch |
| `workflow-author` | Writes GitHub Actions YAML to the repo's conventions and checks it with actionlint. | sonnet | Read, Glob, Grep, Write, Edit, Bash |
| `container-author` | Writes and edits Dockerfiles and `build.cmd` for existing image folders. | sonnet | Read, Glob, Grep, Write, Edit, WebFetch |
| `windows-demo-scaffolder` | Creates a whole new `nano-server/nano-server-<stack>/` (or `server-core/server-core-<stack>/`) demo folder and wires it into the root README. | sonnet | Read, Write, Edit, Glob, Grep, Bash, WebFetch |
| `powershell-author` | Writes PowerShell 7 scripts and modules with Pester tests, clean under PSScriptAnalyzer. | sonnet | Read, Glob, Grep, Write, Edit, PowerShell |
| `python-author` | Writes Python tools and the convention tests under `tests/` with uv (Python version from `UV_PYTHON`), PyYAML and pytest. Hands formatting to `python-fixer`. | sonnet | Read, Glob, Grep, Write, Edit, Bash, Agent |
| `python-fixer` | Runs ruff format and ruff check --fix, fixes what's left by hand without changing behaviour, then re-runs the tests. | haiku | Bash, Read, Edit, Glob, Grep |
| `windows-container-builder` | Builds and tags images for ltsc2019, ltsc2022, and ltsc2025. | sonnet | PowerShell, Read, Glob, Grep |
| `windows-container-tester` | Smoke-tests built images by running their tools. | sonnet | PowerShell, Read, Glob, Grep |
| `windows-deps-updater` | Finds and applies newer tool versions pinned in Dockerfiles. | sonnet | Read, Edit, Glob, Grep, Bash, WebFetch |
| `windows-dockerfile-reviewer` | Read-only review of Dockerfiles and build scripts for nanoserver pitfalls. | opus | Read, Glob, Grep |
| `windows-host-doctor` | Diagnoses the host's container setup when builds fail for environmental reasons. | haiku | PowerShell, Read, Glob, Grep |
| `windows-image-publisher` | Pushes images to Docker Hub, only when explicitly asked. | haiku | PowerShell, Read |
| `markdown-reviewer` | Read-only review of Markdown against the lint config. Hands fixes to `markdown-fixer`. | haiku | Bash, Read, Glob, Grep, Agent |
| `markdown-fixer` | Fixes markdownlint errors by editing content. | haiku | Bash, Read, Edit, Glob, Grep |
| `ci-watcher` | Waits for a run or a PR's checks to finish, then reports the outcome and, for failures, `scripts/ci_triage.py`'s compact output. | haiku | Bash, Read |

## How models were chosen

Model choice is the biggest lever on cost. Most tokens in this repo go on waiting for and reading CI, not on writing code, so that work goes to haiku.

- **haiku** for cheap, mechanical, or read-mostly work with a fixed procedure: watching CI (`ci-watcher`), running lint or ruff and fixing what it says, host diagnostics, a guarded `docker push`, and `planning`. Planning is haiku because it fills in a fixed template and hands real work to other agents. If its plans come out thin for a large design, ask `cicd-engineer` to draft the design and have `planning` turn it into a checklist.
- **sonnet** for authoring and building: writing Dockerfiles, workflows, scripts, ADRs, and running builds and tests, where correctness matters but each task is bounded.
- **opus** for deep review and design, where missing something is expensive: `governance` (cross-cutting audit), `windows-dockerfile-reviewer` (subtle nanoserver failures), and `cicd-engineer` (security of self-hosted runners and the shape of the whole pipeline).

## How tools were chosen

- Reviewers and auditors (`governance`, `windows-dockerfile-reviewer`) have no shell and no write tools, so they can't change anything. `markdown-reviewer` keeps Bash only to run markdownlint, and has no Edit tool: it changes files only through `markdown-fixer`.
- The fixers (`markdown-fixer`, `python-fixer`) are haiku with Edit and Bash. They run the formatter or linter and make mechanical fixes, and never change behaviour.
- Agents that drive docker on Windows get PowerShell only, not both shells.
- `planning` and `adr` can write, but their prompts restrict them to `plans/` and `docs/adr/`. That is enforced by the prompt, not by Claude Code, so `governance` checks it.

## Container work: who does what

`windows-demo-scaffolder` creates a new demo folder end to end, including its first Dockerfile. After that, `container-author` owns Dockerfile changes, `workflow-author` owns the folder's workflow, and `windows-dockerfile-reviewer` reviews. They stay separate because scaffolding (folder layout, README, root README entry) is a one-time job, while Dockerfile edits happen every month.

## Delegation

```text
planning ──► container-author, windows-demo-scaffolder, workflow-author, cicd-engineer,
             powershell-author, python-author, windows-deps-updater, adr, ...
cicd-engineer ──► design for workflow-author; scripts for powershell-author
windows-demo-scaffolder / container-author / windows-deps-updater
             ──► windows-dockerfile-reviewer ──► windows-container-builder ──► windows-container-tester
                 ──► windows-image-publisher (only when the user asks)
markdown-reviewer ──► markdown-fixer
python-author ──► python-fixer (ruff)
governance ──► report only (the caller dispatches fixes)
```

`planning`, `markdown-reviewer` and `python-author` have the Agent tool, so they can start the agents they hand off to. Claude Code subagents can't start other subagents, though, so this only works when they run as the main agent. Running as a subagent, `planning` returns the plan with an owner on every task, `markdown-reviewer` ends its report by naming the files for `markdown-fixer`, and `python-author` runs ruff itself. Every other hand-off is a recommendation in the agent's report.
