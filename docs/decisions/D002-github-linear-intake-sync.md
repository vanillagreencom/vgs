# D002: GitHub → Linear intake mirroring stays manual

[← Decision Index](INDEX.md)

**Date**: 2026-08-04
**Status**: Active
**Research**: —

## Context

`AGENTS.md` § Conventions and the linear skill's project instructions both stated
that "a one-way GitHub → Linear sync mirrors" anything filed on GitHub Issues.
No such sync runs.

Verified 2026-08-04:

- `.github/` contains `ci.yml` and `release.yml` and no other workflow; nothing
  under `.github/` references Linear at all.
- GitHub issue #45 was filed 2026-08-04 and had no Linear counterpart. It was
  mirrored by hand, becoming VGS-61.
- The same happened earlier with #2, filed 2026-08-01, which had no Linear
  counterpart as of 2026-08-03 and stayed open for two days after the bug had
  already been fixed, because nothing connected the two trackers.

The documented workflow tells agents and humans to work from Linear. A GitHub-filed
report that never reaches Linear is therefore invisible, indefinitely.

## Decision

**Mirroring GitHub intake into Linear is a manual triage step, and the docs now
say so.** `AGENTS.md` § Conventions carries the actual commands, and the linear
skill's project instructions (generated from `vstack.toml`) no longer claim a
sync exists.

Neither automated option is taken:

- **Linear's GitHub integration** for `vanillagreencom/vgs` requires Linear
  workspace admin access — owner-only.
- **A repo-side workflow calling the Linear API** on `issues.opened` requires a
  `LINEAR_API_KEY` repository secret that only the owner can set. A workflow that
  fails on every issue for lack of a secret is worse than no workflow: it looks
  like coverage while providing none, which is the same defect being fixed here.

## Rationale

- A doc that describes automation which does not run is worse than a doc that
  describes a chore, because it stops anyone from doing the chore.
- The manual step is small — one `gh issue list`, one Linear cache list, and a
  create per unmirrored issue — and it is already what actually happens.
- Both automated options are blocked on owner-only credentials, so shipping
  either from an agent would produce a broken mechanism, not a working one.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Enable the Linear GitHub integration | Needs Linear workspace admin; owner action |
| Repo workflow calling the Linear API on `issues.opened` | Needs a `LINEAR_API_KEY` repo secret only the owner can set; a secretless workflow fails on every issue and manufactures false confidence |
| Disable GitHub Issues entirely | Removes the intake path outside contributors would use, to fix a docs problem |
| Leave the docs as they were | The claim is false and demonstrably caused issues to be missed |

## Verification

```bash
# No sync workflow, and nothing under .github references Linear:
find .github -type f -name '*.yml'
grep -ril linear .github/ || echo "no Linear reference"

# The triage pass the docs now prescribe:
gh issue list --state open --limit 50 --json number,title,createdAt
.agents/skills/linear/scripts/linear.sh cache issues list --all-projects
```

## Revisit When

- The owner enables the Linear GitHub integration for `vanillagreencom/vgs`, or
  provisions a `LINEAR_API_KEY` repository secret. Either makes an automated path
  viable, and the docs must then be corrected again — in the other direction.
- The manual pass is shown to be skipped in practice, which would raise the value
  of automation enough to be worth chasing the owner for credentials.

## References

- VGS-16 — the issue this decision resolves
- `AGENTS.md` § Conventions — the manual triage step
- `vstack.toml` `[skills.instructions] linear` — generated into
  `.claude/skills/linear/SKILL.md`; never hand-edit the generated file
