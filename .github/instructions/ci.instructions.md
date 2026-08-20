---
applyTo: ".github/workflows/**"
---

# CI

Five workflows live here. `ci.yml` runs the `scripts/validate` manifest as
individual named steps on every pull request targeting `main`, every
merge-queue entry, and every `main` push; its one suite job is deliberate — see
the workflow's own header. It never invokes the runner itself; the runner's own
behavior is covered by `scripts/test-validate.sh`, which CI does run.
`review-gate-writer.yml` is the
only writer of the `Review gate` commit status. `publish-aur.yml` pushes
`packaging/arch/` to the AUR and re-checks the published result;
`publish-gentoo.yml` does the same for `packaging/gentoo/` and the VanillaGreen
overlay. Both publish on packaging changes, again after a tag, and run a weekly
drift check, because a stale package builds and installs perfectly well — the
failure is silent by construction, so something has to look. Both FAIL rather
than skip when their credential is absent.
`release.yml` builds releases on version tags. CodeQL runs from GitHub's
default org-level setup rather than a workflow here, and its per-language
lanes (rust, ruby, c-cpp) report "skipping" because the repo has little or no
code in those languages — by design, not a broken pipeline.

Before reporting a CI coverage gap, read
`.github/instructions/validation-scripts.instructions.md` § "What CI covers,
and what it cannot": a few checks are local-only or reached indirectly, each
with a documented reason, and the rest of the suite runs on every PR. Those
tables live with the checks they describe rather than here, because judging a
check is `scripts/**` work and lands on PRs that touch no workflow file.

## Required checks

The merge queue requires `CI / ci-ok`, the workflow's one *suite* job — one job
is deliberate: at ~30s of total compute, per-job overhead dominates, so there
are no lanes, no nightly, no Go caching, and the 2 vCPU runner tier. The
measured economics behind that shape, and the commands to re-measure them, live
in `docs/decisions/D007-ci-single-job-economics.md`.

`Review gate` **is** the second required check: `main merge queue` requires
`ci-ok` and `Review gate`. They differ in kind — `ci-ok` is the check run from
`ci.yml`'s job of that name; `Review gate` is a commit status the writer posts.
Require the writer's STATUS, never its job name: the writer job on PR heads is
the relay (`Request a gate convergence pass`), so a required `Evaluate and write
the review gate` would block every PR. Live list:

```bash
gh api repos/vanillagreencom/vgs/rulesets/20260238 \
  --jq '.rules[]|select(.type=="required_status_checks").parameters.required_status_checks[].context'
```

The gate's own architecture is in `review-gate-writer.yml`'s header (the
relay/converge shape and why the PR-attached legs run no engine) and its trust
posture in `vstack.settings.toml`'s `REVIEW_GATE_*` comments. Because the writer
always runs the DEFAULT-BRANCH engine, a PR that repairs the gate machinery can
never open its own gate: merging one is the ruleset bypass actor's job, stated
in the merge commit.

## The whitespace check is range-scoped here

`scripts/validate` lists a bare `git diff --check`, which is a working-tree
check, so on a clean CI checkout it would inspect nothing. CI diffs a range
instead — on **every** event, with exactly one defined base per event,
documented and enforced in the workflow's whitespace step. **There is no
fallback base, deliberately**: if the base cannot be resolved the step fails
rather than substituting a narrower range, which would pass while claiming
coverage it does not have. A whole-tree check is deliberately not used — the
tree's ~1,000 pre-existing findings all sit in content VGS ships verbatim;
figures and derivation in `docs/decisions/D007-ci-single-job-economics.md`.
