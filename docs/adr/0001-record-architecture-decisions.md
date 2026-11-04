# 0001. Record architecture decisions

- Status: Accepted
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [`.claude/agents/adr.md`](../../.claude/agents/adr.md), [`.claude/agents/planning.md`](../../.claude/agents/planning.md)

## Context

This repo is maintained largely through Claude Code agents (`.claude/agents/`). Choices such as building for three Windows versions, running CI on self-hosted nanoserver runners with host docker access, and how images are tagged and published shape every later change. Without a record, agents and people re-derive or silently contradict them.

## Decision

We will record architecturally significant decisions as Architecture Decision Records in `docs/adr/`, in MADR style: `NNNN-kebab-case-title.md` with status, context, decision, consequences, and alternatives considered. `docs/adr/README.md` indexes them. The `adr` agent writes them. Plans in `plans/` name the ADRs they need, and the `governance` agent checks that the code still matches Accepted ADRs.

## Consequences

- Decisions have one place to look, and agents can be told to read it.
- An Accepted ADR is never rewritten. A change of mind is a new ADR that supersedes the old one, which keeps the history.
- Writing an ADR adds a small cost to significant changes. Routine changes (version bumps, doc fixes) don't need one.

## Alternatives considered

- **Decisions in PR descriptions only.** They are hard to find later and are not visible to agents working in the repo.
- **One long design document.** It goes stale as a whole, and it is hard to tell which parts still hold.
