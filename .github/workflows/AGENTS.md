# Workflow changes

Read [../../AGENTS.md](../../AGENTS.md#code-review-rules) for review policy and [../../docs/decisions/D007-ci-single-job-economics.md](../../docs/decisions/D007-ci-single-job-economics.md) before changing CI structure.

- Keep CI coverage consistent with `scripts/validate`; `scripts/check-validation-inventory.py` owns exceptions.
- Whitespace validation must cover the event's full change range. An unresolved base must fail instead of selecting a narrower range.
- Configure kendex-owned gate and harness behavior through `kendex.settings.toml`; use their installed skills for changes.
