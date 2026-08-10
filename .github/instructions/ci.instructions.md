---
applyTo: ".github/workflows/**"
---

# CI

Four workflows live here. `ci.yml` runs the `AGENTS.md` § Validation suite on
every pull request, merge-queue entry, and `main` push; its one suite job is
deliberate — see the workflow's own header. `review-gate-writer.yml` is the
only writer of the `Review gate` commit status. `publish-aur.yml` pushes
`packaging/arch/` to the AUR and re-checks the published result.
`release.yml` builds releases on version tags. CodeQL runs from GitHub's
default org-level setup rather than a workflow here, and its per-language
lanes (rust, ruby, c-cpp) report "skipping" because the repo has little or no
code in those languages — by design, not a broken pipeline.

Before reporting a CI coverage gap, read `AGENTS.md` § "What CI covers, and
what it cannot": a few checks are local-only or reached indirectly there, each
with a documented reason, and the rest of the suite runs on every PR.
