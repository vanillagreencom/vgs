---
applyTo: ".github/workflows/**"
---

# CI

The only workflow in this repo is `release.yml`. CodeQL runs from GitHub's
default org-level setup rather than a workflow here, and its per-language lanes
(rust, ruby, c-cpp) report "skipping" because the repo has little or no code in
those languages — by design, not a broken pipeline.

The validation suite in `AGENTS.md` § Validation is run locally, so "this
change has no CI coverage" is not a useful finding.
