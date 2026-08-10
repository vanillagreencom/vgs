# D007: One-suite-job CI — lanes, caching, runner tier, and whitespace scope

[← Decision Index](INDEX.md)

**Date**: 2026-08-10
**Status**: Active
**Research**: —

## Summary

VGS CI is one suite job (`ci-ok`) plus the structurally separate review-gate
selftest: no lanes, no change-detection gate, no nightly split, no Go build
caching, the 2 vCPU runner tier, and a range-scoped (never whole-tree)
whitespace check. Every one of those is an economics decision driven by
measured timings. AGENTS.md § "What CI covers, and what it cannot" states the
posture, `.github/workflows/ci.yml` implements it, and this record holds the
numbers and the commands that re-derive them.

## Measurements (2026-08-09, this repo)

| What | Figure |
|------|--------|
| Static suite (the § Validation list minus the Go block) | ~16s of work |
| Go block warm | ~6s |
| Go block cold | ~16s (build 4.4s, vet 0.8s, `test -race` 11.0s) |
| Total compute | ~30s |
| Go module download (cold) | 13 MB |
| `GOCACHE` left by one cold run | ~284 MB |

Re-measure the timings by running each § Validation entry under `time` for the
static figure, and in `backend/` `time go build ./...`, `time go vet ./...`,
`time go test -race ./...` for the Go block — warm as-is, cold by pointing
`GOCACHE` at a throwaway directory. For the size figures, `go mod download`
into a fresh `GOMODCACHE` and `du -sh` it for the module figure; run the Go
block once with a throwaway `GOCACHE` and `du -sh` that for the cache figure.

## Decision

- **One suite job.** At ~30s of total compute, per-job overhead — runner
  acquisition, checkout, toolchain setup — dominates, so splitting into lanes
  would multiply billed minutes to save seconds, and a change-detection job to
  gate those lanes would cost more than the work it could skip. The sibling
  repos (hyprtrade, memsira, drovr) split because their lanes run for minutes;
  that economics does not transfer. There is no `ci-nightly.yml` for the same
  reason: nothing is slow enough to be worth deferring to a schedule.
- **The job is named `ci-ok`** — for the required context rather than for what
  it does, which is the indirection a separate aggregator job would have
  bought. There are no conditional lanes that could leave a required context
  permanently skipped, so there is nothing to aggregate; if lanes are ever
  added, the work moves to new jobs and `ci-ok` becomes the aggregator over
  them, and branch protection never has to change.
- **Go caching is off.** A cold Go run downloads 13 MB of modules but leaves a
  ~284 MB `GOCACHE`; saving and restoring that to skip ~10s of compute is a
  net loss on a 2 vCPU runner, and it burns Actions cache storage the rest of
  the repo could use. Re-measure (commands above) before enabling it.
- **2 vCPU runner.** Resolved through the shared `CI_RUNNER_2V` repository
  variable (Blacksmith when set, `ubuntu-latest` when unset — that fallback is
  supported and must keep working). Nothing in the suite is CPU-bound or
  disk-hungry, so the 4V/8V tiers buy VGS nothing.
- **The whitespace check stays range-scoped; a whole-tree check is
  deliberately not used.** The tree carries ~1,000 pre-existing findings,
  every one in content VGS ships verbatim — curated theme packages under
  `themes/` and the vendored `config/vshell/nvim/colorschemes/` and
  `config/vshell/icons/` trees — so a whole-tree check would be red from day
  one and would need an exclusion list covering all of that to maintain.
  Measure with
  `git diff --check $(git hash-object -t tree /dev/null) HEAD | wc -l`
  (~2,000 lines, since trailing-whitespace findings also echo the offending
  line).

## Revisit When

- Any single CI step crosses ~5 minutes — lanes start earning their per-job
  overhead.
- The Go block gains real dependency weight — re-measure before enabling the
  toolchain cache.
- The shipped-verbatim trees stop dominating the whole-tree whitespace
  findings — an exclusion list could become maintainable.

## References

- AGENTS.md § "What CI covers, and what it cannot" — the working posture.
- `.github/workflows/ci.yml` — the implementation, with structural comments
  pointing back here for figures.
