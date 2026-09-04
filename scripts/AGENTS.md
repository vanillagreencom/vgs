# scripts/

These scripts are this repository's test suite; there is no test framework. Judge them as tests: a check whose failure path cannot be reached is vacuous. Look specifically for a suppressed exit status, an empty result treated as a clean result, and a snapshot or diff comparison that silently passes when collection failed. Each of those shipped here and had to be fixed.

**A collection-based check asserts it collected something before evaluating the collection.** A test over a filtered list, or a loop whose body holds the assertions, is vacuously clean when the match finds nothing: empty means it did not run, never that it is clean. Assert non-empty and fail on it; `scripts/lib/collected.py` owns that invariant and its call-site registry names every collection point.

`scripts/validate [AREA]` is the suite's entry point and carries the manifest of every check here, one row per command, selecting the subset for one area. Adding or renaming a check means editing that manifest, not a document; `scripts/check-validation-inventory.py` parses it and enforces in both directions, and `scripts/test-validate.sh` covers the runner itself. Run `scripts/validate --list [AREA]` for the commands and `--dump-grammar` for the tag grammar.

The areas are <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, and `all`<!-- /validate-areas -->. That list is machine-read here and in the root instruction file and the `vshell-dev` skill, each wrapped in the same comment markers; reword inside them freely, but every backticked lowercase word between them is read as an area name, exactly one marker pair per file is allowed, and an empty or fenced region is refused. Dropping the enumeration from a file is a recorded decision: remove that file from `AREA_ENUMERATING_DOCS` in the same edit.

Exit status is four-valued and **77 is not a pass**: `0` everything selected ran and passed, `77` what ran passed but something did not run, `1` a real failure, `2` a broken invocation where nothing ran. A check that can be forced not to degrade carries the flag that forces it — `--require-static`, `--require-nested`; the skip channel exists only for the surface smoke, whose refusal cannot be flag-forced.

Never suggest validating this repository with `qs -c vshell` or `qs -p quickshell/vshell`; the rule and its recovery are in the root instruction file. Never suggest killing Quickshell by name either — signal by process id or process group.

## What continuous integration covers, and what it cannot

Some checks cannot run in continuous integration at all, and one runs there only through another entry. Both categories are deliberate, and `scripts/check-validation-inventory.py` cross-compares the tables below against its own maps, so the prose and the code cannot disagree silently.

**Local-only — CI cannot run these at all:**

| Check | Why it is local-only |
|-------|----------------------|
| `scripts/check-label-taxonomy.py` | Compares the settings label taxonomy against the live tracker; the runner has no credentials and no local cache. It fails rather than skipping when the inventory is unreachable, and its allow-missing flag is the explicit acceptance that the sweep did not happen. |
| `scripts/smoke-surfaces.sh` | Needs a live Hyprland VGS session and reads compositor layer state. Anywhere else it prints a skip and exits 77 — nothing was checked, distinct from both its pass and its failures — so the runner could only ever go red on it. A foreign checkout is still a hard failure. |

**Reached indirectly — CI runs these through another entry, not by name:**

| Check | How CI reaches it |
|-------|-------------------|
| `scripts/qml-smoke.sh` | `scripts/check-validation-safety.sh --require-static` forwards the flag, so the static half runs. Only the nested mode is local-only: its sandbox needs both Hyprland and Quickshell on the path, neither reasonably installable on a runner. |

`scripts/check-aur-sync.py` runs only its offline half on a pull request; comparing against what the package repository actually publishes needs network and is owned by the publish workflow.

So a green pull request proves the static suite and the Go block. It does not prove the shell starts or that its surfaces are sane.
