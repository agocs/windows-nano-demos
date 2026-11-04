# 0007. Separate tool-version bumps from base-image refreshes

- Status: Proposed
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [Patch Tuesday plan](../../plans/patch-tuesday-image-refresh.md), [`.claude/agents/windows-deps-updater.md`](../../.claude/agents/windows-deps-updater.md), [0004](0004-rebuild-all-images-on-base-image-digest-change.md)

## Context

Images change for two independent reasons: Microsoft's base image (monthly, automatic per [0004](0004-rebuild-all-images-on-base-image-digest-change.md)) and the pinned tool versions in each Dockerfile's `ENV` block (PHP, Node.js, micro, PowerShell, MinGit, the Actions runner, docker). Tool releases can break things in ways unrelated to Windows patches, such as PHP moving a build to the `/archives/` path or changing its Visual Studio toolset.

## Decision

We will keep the two apart:

- Base refreshes change no files. They rebuild the current `main` against the new base digest.
- Tool bumps are PRs that change `ENV` pins, prepared by `windows-deps-updater` from a monthly pin report (on the 20th, away from Patch Tuesday week), one PR per image, tested by the per-image workflows, and published by the next refresh run after merge.
- The refresh run records why each leg was rebuilt (`base-changed`, `source-changed`, `missing`, or `forced`).

## Consequences

- When a build breaks, it has one cause: either a new base on unchanged source, or a reviewed source change on a known base.
- Base refreshes never wait on review, so security patches ship quickly.
- Tool updates need a human or agent to merge them, so they can lag. The monthly pin report keeps the lag visible.

## Alternatives considered

- **Bump tools automatically in the refresh run.** That is faster, but it mixes causes and ships unreviewed upstream changes.
- **Pin base digests in Dockerfiles and bump them by PR too.** That unifies the flow, but needs a reviewed PR per version every month for security patches, and it slows them down.
