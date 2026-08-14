# Architectural Decision Log

Records the significant path choices VGS has made, so a later reader can see what
was chosen, why, and what would change the answer.

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|-----|----------|----------|-----------|--------------|--------|------|
| 2026-08-04 | D001 | — | Report the three Quickshell 0.3.0 defects upstream; do not vendor or patch | (b) is a process-global that permanently breaks locking for any client | Upstream fixes (b) and VGS pins a newer Quickshell | Active | [Full](D001-quickshell-0-3-0-upstream-defects.md) |
| 2026-08-04 | D002 | — | GitHub -> Linear intake mirroring stays manual and documented as manual | Both automated options need owner-only access; wrong docs are worse than no automation | Owner enables the Linear GitHub integration or provisions a `LINEAR_API_KEY` secret | Active | [Full](D002-github-linear-intake-sync.md) |
| 2026-08-04 | D003 | VGS-48 | Keep Quickshell's `SystemTray` as the tray's only transport | Neither proposed route fixes the ambiguous-`Id` root cause; both add surface that upstream would retire | Quickshell exposes `contextMenu()` or an item's bus name/path, or a duplicate-`Id` misfire is reported | Active | [Full](D003-system-tray-transport.md) |
| 2026-08-08 | D005 | — | `dependencies.json` declares presence only; capability probes cover the rest | One real version floor, inert on every supported distro; three of six packaging formats cannot express a constraint, and 67 `--version` shapes are a false-negative risk | A second dependency needs more than presence, or a shipped target falls below a floor VGS needs | Active | [Full](D005-dependency-version-constraints.md) |
| 2026-08-04 | D004 | — | Split `Modals/Launcher/` by consumer: overview-only files to `Modules/WorkspaceOverlays/OverviewSearch/`, the two shared panels to `Widgets/Launcher/`; core↔`vgsMenu` gets a named API surface | Deleting the tree and rebuilding the niri overview search is the better end state but unverifiable without niri hardware; niri support must stay additive | Niri hardware/VM available; the overview stops embedding search; plugins become genuinely optional; an owner disagrees | Active | [Full](D004-overview-search-ownership-and-plugin-boundary.md) |
| 2026-08-08 | D006 | VGS-86 | Keep class-based scratchpad identity; make pattern breadth visible instead of adopting a per-instance mechanism | Class never drifts (0/15 live windows) but title does (12/15); the launch-time override works yet 2 of 9 known terminals have no flag and Electron is untested | Electron `--class` gets a real answer; Hyprland gains a per-window rule handle; an app appears with neither an override nor a stable title | Active | [Full](D006-scratchpad-window-identity.md) |
| 2026-08-10 | D007 | — | One CI suite job (`ci-ok`) beside the review-gate selftest, no lanes/nightly/Go cache, 2 vCPU runner, range-scoped whitespace check | ~30s total compute, so per-job overhead dominates; caching and lanes cost more than they save | Any step crosses ~5 minutes, or the Go block gains real dependency weight | Active | [Full](D007-ci-single-job-economics.md) |
| 2026-08-14 | D008 | VGS-92 | Nested smoke sandbox is built from the repo alone; nothing copied from `~/.config/vshell` | A sandbox whose verdict depends on the machine it ran on is not a sandbox | A phase genuinely needs host state, or the helper can write theme.json without hooks | Active | [Full](D008-nested-sandbox-state-seeding.md) |

---

## Format Reference

**Log** a path choice whose conditions might change: a technology or transport
selection with real alternatives, a trade-off taken for a stated reason, or a
scope boundary a later reader would otherwise re-argue. **Do not log** bug
fixes, renames, small refactors, or a choice that had no realistic alternative
— every row here should have a Revisit When worth writing.

**Status values**: `Active`, `Active ([COMPONENTS] → [DECISION_ID])` for a
partial supersession, `Superseded by [DECISION_ID]`, and `Revisited`. Anything
starting with `Active` stays listed, so a partial supersession keeps showing up.

**Code marker**: `// REVISIT([DECISION_ID]): [reason]` ties an implementation
point back to its row, as `quickshell/vshell/Modules/Bar/Widgets/SystemTrayBar.qml`
does for D003. Repoint these when a decision is superseded.

**Row placement is append-only.** New rows go at the end of the table above,
before the separator, and existing rows are never re-sorted. The order is
therefore the order rows were added, not date order: the decider skill's row
template asks for date order, and this table already departs from it — D004,
dated 2026-08-04, sits after D005, dated 2026-08-08. Appending is the rule
here, because re-sorting a log churns rows nobody changed.

The column order is a machine contract — eight cells read positionally, and the
Link cell must name the decision document — so do not reorder or drop a column.
The full row-format and document schema are owned by the vstack decider skill,
which is agent-side tooling and is not vendored into this repo.
