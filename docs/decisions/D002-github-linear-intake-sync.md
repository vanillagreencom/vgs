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
say so.** The linear skill's project instructions (generated from `kendex.toml`)
carry the actual commands and no longer claim a sync exists; `AGENTS.md`
§ Conventions states the manual step and points there. (`AGENTS.md` carried a
duplicate copy of the commands until the VGS-124 diet removed it.)

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

# The triage pass the docs now prescribe: list both sides...
gh issue list --state open --limit 50 --json number,title,url,createdAt \
  --jq '.[] | [.number, .createdAt, .url, .title] | @tsv'
.agents/skills/linear/scripts/linear.sh cache issues list --all-projects

# ...then, per GitHub-only issue, build the exact description to be created.
gh issue view <n> --json title,body,url > /tmp/gh-<n>.json
jq -r '(.body | sub("\\s+$"; "")) + "\n\n---\n\nMirrored from GitHub issue [" + .url + "](<" + .url + ">) (intake-only tracker)."' /tmp/gh-<n>.json > /tmp/gh-<n>-body.md

.agents/skills/linear/scripts/linear.sh issues create --title "$(jq -r .title /tmp/gh-<n>.json)" \
  --description-file /tmp/gh-<n>-body.md
```

`title`, `body` and `url` are all requested, so the description — including the
provenance line — is produced from these commands alone. Verified end to end
against GitHub #45, which had been mirrored by hand as VGS-61 before this
decision was written: the generated description is **byte-identical** to the
Linear issue's stored description.

```bash
gh issue view 45 --json title,body,url > /tmp/gh-45.json
jq -r '(.body | sub("\\s+$"; "")) + "\n\n---\n\nMirrored from GitHub issue [" + .url + "](<" + .url + ">) (intake-only tracker)."' /tmp/gh-45.json > /tmp/gh-45-body.md
.agents/skills/linear/scripts/linear.sh cache issues get VGS-61 --format=safe | jq -r .description > /tmp/vgs-61.md
diff /tmp/gh-45-body.md /tmp/vgs-61.md   # no output
```

## Revisit When

- The owner enables the Linear GitHub integration for `vanillagreencom/vgs`, or
  provisions a `LINEAR_API_KEY` repository secret. Either makes an automated path
  viable, and the docs must then be corrected again — in the other direction.
- The manual pass is shown to be skipped in practice, which would raise the value
  of automation enough to be worth chasing the owner for credentials.

## References

- VGS-16 — the issue this decision resolves
- `kendex.toml` `[skill-instructions] linear` — the manual triage step and its
  commands; `AGENTS.md` § Conventions points there. It is generated into
  `.claude/skills/linear/SKILL.md`; never hand-edit the generated file
