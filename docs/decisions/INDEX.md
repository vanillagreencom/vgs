# Architectural Decision Log

Records the path choices v2 has made, so a later reader can see what was chosen, why, and what would change the answer.

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|-----|----------|----------|-----------|--------------|--------|------|
| 2026-09-21 | D001 | — | Hyprland is the only compositor | Two compositors doubled the code paths and the review surface | A second compositor gains the protocols and a maintainer with hardware | Active | [Full](D001-hyprland-only.md) |
| 2026-09-21 | D002 | — | Quickshell 0.3.1 is the baseline, every API cited from its reference | Every measurement was taken on 0.3.1 | A release changes imports, IPC, FileView, Process or window types | Active | [Full](D002-quickshell-0-3-1-baseline.md) |
| 2026-09-21 | D003 | — | Everything outside the core is a plugin; the manager is core; the core names no plugin | A small privileged core fits one agent; a plugin cannot break another | A surface no host can give without a core rewrite | Active | [Full](D003-everything-is-a-plugin.md) |
| 2026-09-21 | D004 | — | The manifest is Omarchy Quattro's plus one reserved key | Two formats need a translator that drifts | Omarchy publishes schema version 2 or renames a kind | Active | [Full](D004-omarchy-manifest-plus-one-key.md) |
| 2026-09-21 | D005 | — | Kinds are surfaces; plugins declare no dependencies | No dependency graph, no refusals, no plugin naming another | A plugin cannot work without another's service and no capability can carry it | Active | [Full](D005-kinds-are-surfaces-no-dependencies.md) |
| 2026-09-21 | D006 | — | Shipped and user configuration layers merged by entry id | A default that never reaches a customised file is a regression channel | A third layer or a shipped override is needed | Active | [Full](D006-two-configuration-layers.md) |
| 2026-09-21 | D007 | — | Install runs no plugin code and lands the plugin disabled | Removes a supply-chain class for a one-line cost | A plugin needs a system package or the marketplace signs installs | Active | [Full](D007-install-runs-no-plugin-code.md) |
| 2026-09-21 | D008 | — | Every change carries its validation row; the nested sandbox is the only shell start | Per-change checks catch the regression in its change | CI gains a Wayland runner or a check needs host state | Active | [Full](D008-validation-row-per-change.md) |
| 2026-09-21 | D009 | — | One manifest judge, PluginLogic.js, shared by shell and scripts under node | A second copy is a twin; pure functions test in milliseconds | A decision needs QML types node cannot host | Active | [Full](D009-one-manifest-judge-under-node.md) |
| 2026-09-21 | D010 | — | Static import check plus scoped API object, not a process sandbox | Process per plugin multiplies resident size before any plugin justifies it | Budgets measured against process-per-plugin fit, or credentials need protection | Active | [Full](D010-facade-scope-not-sandbox.md) |

---

## Format Reference

Log a path choice whose conditions might change: a technology or transport selection with real alternatives, a trade-off taken for a stated reason, or a scope boundary a later reader would otherwise re-argue. Do not log bug fixes, renames, small refactors, or a choice that had no realistic alternative.

Status values: `Active`, `Active ([COMPONENTS] → [DECISION_ID])` for a partial supersession, `Superseded by [DECISION_ID]`, and `Revisited`. Rows are append-only and never re-sorted. The column order is a machine contract the decider skill reads positionally; the Link cell names the decision file.
