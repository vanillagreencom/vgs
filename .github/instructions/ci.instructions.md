---
applyTo: ".github/workflows/**"
---

# CI

Four workflows live here. `ci.yml` runs the `scripts/validate` suite on
every pull request targeting `main`, every merge-queue entry, and every `main`
push; its one suite job is deliberate — see the workflow's own header. `review-gate-writer.yml` is the
only writer of the `Review gate` commit status. `publish-aur.yml` pushes
`packaging/arch/` to the AUR and re-checks the published result.
`release.yml` builds releases on version tags. CodeQL runs from GitHub's
default org-level setup rather than a workflow here, and its per-language
lanes (rust, ruby, c-cpp) report "skipping" because the repo has little or no
code in those languages — by design, not a broken pipeline.

Before reporting a CI coverage gap, read § "What CI covers, and what it
cannot" below: a few checks are local-only or reached indirectly, each with a
documented reason, and the rest of the suite runs on every PR.

## What CI covers, and what it cannot

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

The gate's own architecture and trust posture are in `AGENTS.md` § Review gate.

Some checks in `scripts/validate` **cannot run in CI**, and one runs there only
through another entry. Both categories are deliberate, and
`scripts/check-validation-inventory.py` cross-compares the two tables below
against its own `LOCAL_ONLY` and `INDIRECT_IN_CI` maps, so the prose and the
code cannot disagree silently.

**Local-only — CI cannot run these at all:**

| Check | Why it is local-only |
|-------|----------------------|
| `scripts/check-label-taxonomy.py` | Compares `vstack.toml`'s label taxonomy against live Linear; CI has no Linear credentials and no local cache. It FAILS rather than skipping when the inventory is unreachable — `--allow-missing-inventory` is the explicit "I accept the sweep did not happen". |
| `scripts/check-review-gate-vendor.sh` | Compares the tracked engine at `third_party/review-gate/` against the `vstack refresh`-managed copy under `.agents/`, which a CI checkout does not have. |
| `scripts/check-size-ratchet-vendor.sh` | Same two-copy situation for the size-ratchet engine at `third_party/size-ratchet/`; CI runs the vendored engine, this check keeps it matching the `.agents/` copy. |
| `scripts/smoke-surfaces.sh` | Needs a **live** Hyprland VGS session and reads `hyprctl layers`. Anywhere else it prints a skip and exits 0, so running it in CI would manufacture a false green. |

**Reached indirectly — CI runs these through another entry, not by name:**

| Check | How CI reaches it |
|-------|-------------------|
| `scripts/qml-smoke.sh` | `scripts/check-validation-safety.sh --require-static` forwards the flag to the smoke, so the **static** half runs in CI. Only `--nested` is local-only: its sandbox needs both Hyprland and `quickshell` on PATH, neither reasonably installable on a runner. |

`scripts/check-aur-sync.py` runs only its offline half on a PR (PKGBUILD against
`.SRCINFO`); comparing against what the AUR actually publishes needs network and
is owned by `publish-aur.yml`. Run `scripts/check-aur-sync.py --remote` by hand
when you want that answer now.

So a green PR proves the static suite and the Go block. It does **not** prove
the shell starts or that its surfaces are sane. Run `scripts/validate qml`
locally before finishing QML work. `scripts/smoke-surfaces.sh` only works from
the checkout owning the live session, and reports which case it hit: a named
skip when no VGS shell is live, a failure naming the owning checkout when one is
live but foreign — even when this checkout's own shell is also live, since
`hyprctl layers` aggregates every Quickshell instance on the seat. Run it from
the owning checkout; do not read its refusal as a pass (VGS-69).

One other local/CI difference: `scripts/validate` lists a bare
`git diff --check`, which is a working-tree check, so on a clean CI checkout it
would inspect nothing. CI diffs a range instead — on **every** event, with
exactly one defined base per event, documented and enforced in the workflow's
whitespace step. **There is no fallback base, deliberately**: if the base cannot
be resolved the step fails rather than substituting a narrower range, which
would pass while claiming coverage it does not have. A whole-tree check is
deliberately not used — the tree's ~1,000 pre-existing findings all sit in
content VGS ships verbatim; figures and derivation in
`docs/decisions/D007-ci-single-job-economics.md`.
