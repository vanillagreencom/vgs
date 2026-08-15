---
applyTo: "scripts/**"
---

# Validation scripts

These scripts **are** this repo's test suite; there is no test framework. Judge
them as tests: a check whose failure path cannot be reached is vacuous. Look
specifically for

- a suppressed exit status (`|| true` swallowing a tool that failed to run),
- an empty result treated as a clean result,
- a snapshot or diff comparison that silently passes when collection failed.

Those exact bugs shipped here and had to be fixed; a linter that could not run
was reporting "passed", and a failed baseline snapshot was discarding damage
the after-snapshot plainly showed.

`scripts/validate [AREA]` is the suite's entry point: it carries the manifest of
every check in this directory, selects the subset for one of the <!-- validate-areas -->areas `go`,
`qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->, and is what
`scripts/check-validation-inventory.py` parses — including the anchored area
list above, which is compared against the runner's own. The anchor, not the
wording, is what the guard reads: prose inside it is free, but every
backticked lowercase word in there is read as an area name, so put nothing else
in backticks between the markers. Moving or deleting the anchor, opening or
closing it twice, or leaving it empty all fail the guard rather than turning the
comparison off. Adding or renaming a check
means editing that manifest, not a doc. `scripts/test-validate.sh` covers the
runner itself.

Its exit status is four-valued, and **77 is not a pass**: `0` everything
selected ran and passed; `77` what ran passed but something did not run (the
summary names each skipped command — report it as "passed, N skipped", naming
them, not as a bare pass); `1` a real failure; `2` a broken invocation where nothing ran, which
is neither a pass nor a validation failure. A check that can be forced not to
degrade carries the flag that forces it (`--require-static`,
`--require-nested`); the skip channel exists only for `smoke-surfaces.sh`, whose
refusal cannot be flag-forced.

Never suggest validating this repo with `qs -c vshell` or
`qs -p quickshell/vshell` — see `AGENTS.md` § Never launch a second shell into
the live session. Never suggest `pkill quickshell`; signal by pid or process
group.

## What CI covers, and what it cannot

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
| `scripts/smoke-surfaces.sh` | Needs a **live** Hyprland VGS session and reads `hyprctl layers`. Anywhere else it prints a skip and exits 77 — "nothing was checked", distinct from both its pass and its failures — so CI could only ever go red on it, never green. `scripts/validate` maps that 77 to a named skip in its summary; a foreign checkout is still a hard failure. |

**Reached indirectly — CI runs these through another entry, not by name:**

| Check | How CI reaches it |
|-------|-------------------|
| `scripts/qml-smoke.sh` | `scripts/check-validation-safety.sh --require-static` forwards the flag to the smoke, so the **static** half runs in CI. Only `--nested` is local-only: its sandbox needs both Hyprland and `quickshell` on PATH, neither reasonably installable on a runner. |

`scripts/check-aur-sync.py` runs only its offline half on a PR (PKGBUILD against
`.SRCINFO`); comparing against what the AUR actually publishes needs network and
is owned by `.github/workflows/publish-aur.yml`. Run
`scripts/check-aur-sync.py --remote` by hand when you want that answer now.

So a green PR proves the static suite and the Go block. It does **not** prove
the shell starts or that its surfaces are sane. Run `scripts/validate qml`
locally before finishing QML work — that area runs the nested smoke with
`--require-nested`, so a missing sandbox fails rather than quietly downgrading
to the static half. `scripts/smoke-surfaces.sh` only works from
the checkout owning the live session, and reports which case it hit: a named
skip when no VGS shell is live, a failure naming the owning checkout when one is
live but foreign — even when this checkout's own shell is also live, since
`hyprctl layers` aggregates every Quickshell instance on the seat. Run it from
the owning checkout; do not read its refusal as a pass (VGS-69).

`.github/instructions/ci.instructions.md` holds the rest of the CI posture — the
required checks, and why the whitespace check is range-scoped there.
