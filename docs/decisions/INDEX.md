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

---

## Format Reference

### What to Log
- Technology selections with alternatives considered
- Performance trade-offs (chose X over Y for reason Z)
- Significant path choices where conditions might change
- Research-informed decisions (reference research ID in rationale)

### What NOT to Log
- Variable names, small refactors, bug fixes
- Obvious choices with no realistic alternatives
- Standard pattern applications

### Status Values
- **Active**: Current decision in effect
- **Superseded by [DECISION_ID]**: Replaced by newer decision
- **Revisited**: Re-evaluated, with outcome noted

### Code Comments
Use `// REVISIT([DECISION_ID]):` in code to mark implementation points tied to decisions.
