# D004: Overview search ownership and the core/vgsMenu plugin boundary

[← Decision Index](INDEX.md)

**Date**: 2026-08-04
**Status**: Active
**Research**: —
**Applies to**: `quickshell/vshell/Modules/WorkspaceOverlays/OverviewSearch/`, `quickshell/vshell/Widgets/Launcher/`, `config/vshell/plugins/vgsMenu/`

> **Made by an agent, not the owner.** VGS-20 and VGS-22 were both filed
> `owner-gated` and asked for a human call. No owner was available in the run
> that shipped VGS-45, so this record states the choice, the alternatives and
> the conditions that should reopen it. Option 1 below is the one an owner is
> most likely to want instead, and it remains open — nothing here forecloses it.

## Summary

`quickshell/vshell/Modals/Launcher/` was a 292 KB, 18-file tree named after a
surface VGS-13 deleted. After that consolidation it had exactly two consumers:
the niri overview's inline search (which uses nearly all of it) and the
`vgsMenu` plugin (which uses two files). Its name said "the launcher", its only
real owner was a single-compositor overlay, and a bundled plugin reached into
it — which is also the plugin→core half of the VGS-22 import cycle.

We split the tree by consumer rather than deleting or wholesale-moving it. The
overview-only files become overview-owned; the two genuinely shared panels move
to the plugin-facing surface. The cycle dissolves as a consequence rather than
needing a separate mechanism.

## Context

VGS-13 removed every launcher entry point except the `vgsMenu` plugin, leaving
`Modals/Launcher/` reachable only from `Modules/WorkspaceOverlays/NiriOverviewOverlay.qml:323`,
behind `active: CompositorService.isNiri && SettingsData.niriOverviewOverlayEnabled`.
On Hyprland — the reference compositor per AGENTS.md § Mission — none of the
search UI was reachable, yet it still shipped, still parsed, and still drove
settings rows.

Meanwhile `config/vshell/plugins/vgsMenu/VGSMenu.qml` imported
`qs.Modals.Launcher` for `LauncherSettingsPanel.qml` and `FilePreviewPanel.qml`,
so the tree could not move without breaking the plugin. That is what made
VGS-20 and VGS-22 one decision instead of two.

The core→plugin half of VGS-22 was already resolved before this decision and
its issue text is stale on the point: the dock button, bar widget and changelog
card do **not** call `PluginService.togglePlugin("vgsMenu")` — they call
`PluginService.toggleAppLauncher()`, and the id lives once in
`PluginService.appLauncherPluginId`. Only the plugin→core half needed work.

## Decision

**VGS-20: option 2, refined by a split.** Promote the search UI to a
niri-overview-owned component, but first separate the files that genuinely have
two consumers instead of moving the whole directory.

| Destination | Contents | Owner |
|---|---|---|
| `Modules/WorkspaceOverlays/OverviewSearch/` | `OverviewSearchContent`, `Controller`, `OverviewSearchSidebar`, `OverviewSearchContextMenu`, `ResultsList`, `ResultItem`, `GridItem`, `TileItem`, `SectionHeader`, `SourceBadge`, `ActionPanel`, `ClipboardPreview`, 4 `.js` helpers | The niri overview overlay, its only consumer |
| `Widgets/Launcher/` | `LauncherSettingsPanel`, `FilePreviewPanel` | Shared; part of the plugin-facing surface |

**VGS-22: option 3.** A named, documented API surface both sides may depend on,
rather than moving `vgsMenu` into core (option 2) or duplicating the shared
panels into it (option 1).

- Core → plugin: `PluginService.appLauncherPluginId` / `toggleAppLauncher()` /
  `appLauncherOpen`. Core shell code must not name `"vgsMenu"` directly.
- Plugin → core: `qs.Common`, `qs.Services`, `qs.Widgets`, `qs.Modules.Plugins`,
  and now `qs.Widgets.Launcher`. A bundled plugin must not import another
  feature's directory.

The refinement is not optional. VGS-20's option 2 as written would have left a
compositor-agnostic plugin importing a niri-overview-owned directory — the same
reach under a worse name, and a strictly larger cycle than the one it set out
to break.

## Rationale

| Criterion | Chosen (split + named surface) | Option 1 (delete, rebuild on vgsMenu) | Option 3 (keep + document) |
|---|---|---|---|
| Verifiable in this run | Yes — pure moves and renames; no behaviour change to verify on hardware we do not have | **No** — needs a niri overview rework and niri hardware/VM | Yes |
| Removes the duplicate search UI | No | Yes | No |
| Tree has one clear owner | Yes | Yes (none) | No |
| Name matches reality | Yes | n/a | No |
| Breaks the VGS-22 cycle | Yes, as a side effect | Yes | No |
| Hyprland ships unreachable UI | Yes, but plainly labelled and documented | No | Yes, ambiguously |

The decisive constraint is verifiability. Option 1 is the only choice that
finishes what VGS-13 started, and it is genuinely the better end state — but it
requires rewriting the sole niri-specific surface in the shell with no way to
run it. AGENTS.md requires niri support to stay **additive**; shipping a blind
rewrite of the one niri surface is subtractive risk taken on the users least
able to absorb it. Deferring it costs one more release of duplicated search UI.
Getting it wrong costs niri users their overview search.

Option 3 was rejected because the ambiguity is not free: it is the direct cause
of VGS-20, VGS-21 and VGS-22 existing at all. A directory named `Modals/Launcher`
that is not the launcher, whose settings silently do nothing on the reference
compositor, is what made this hard to reason about.

## Pattern

```text
quickshell/vshell/
  Widgets/Launcher/                          # >1 consumer only
    LauncherSettingsPanel.qml                #   overview search + vgsMenu
    FilePreviewPanel.qml                     #   overview search + vgsMenu
  Modules/WorkspaceOverlays/
    NiriOverviewOverlay.qml                  # imports ...OverviewSearch
    OverviewSearch/                          # one consumer: the overlay above
config/vshell/plugins/vgsMenu/
    VGSMenu.qml                              # imports qs.Widgets.Launcher only
```

A component earns a place in `Widgets/Launcher/` by having two consumers. One
used solely by `vgsMenu` belongs inside the plugin; one used solely by the
overview search belongs in `OverviewSearch/`.

## Consequences

- Hyprland still ships the overview search UI unreachable. It is now named for
  what it is and documented as niri-only, which is VGS-20's stated fallback
  acceptance ("or the docs state plainly that it is niri-only") rather than its
  preferred one.
- Two search/result implementations remain to maintain. This decision does not
  claim otherwise; it makes the split legible instead of hiding it behind a
  shared-looking name.
- `Widgets/Launcher/LauncherSettingsPanel.qml` still imports
  `qs.Modules.Settings.Widgets` for `SettingsCard`. That is a shared-widget
  directory reaching into a feature directory — a pre-existing wart, carried
  over unchanged rather than fixed here, and not part of the plugin→core cycle.
- The `launcher*` settings keys stay as they are. They are shared by both
  surfaces, so they are not misnamed; only the two `spotlight*` keys named after
  a deleted surface were renamed (VGS-21, settings migration v20).

## Verification

```bash
# No plugin reaches into a feature directory, and the old path is gone.
grep -rn "qs\.Modals\.Launcher" quickshell/ config/     # expect no hits
grep -rn '"vgsMenu"' quickshell/                        # expect only PluginService

scripts/check-naming.sh
node scripts/check-settings-migration.js
scripts/qml-smoke.sh --nested --require-static
```

The nested smoke loads the real shell, so a broken import or a renamed
component that lost a reference fails there rather than at runtime. It does
**not** exercise the niri overview: that path needs a niri session.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| VGS-20 option 1 — delete the tree, rebuild the overview search on `vgsMenu`/`AppSearchService` | The right end state, but unverifiable without niri hardware. Held open as the primary revisit condition. |
| VGS-20 option 2 verbatim — move the whole directory under `WorkspaceOverlays/` | Would leave `vgsMenu` importing a niri-overview-owned directory: same reach, worse name, larger cycle. |
| VGS-20 option 3 — keep and document | Preserves the ambiguity that produced this issue set. |
| VGS-22 option 1 — move the shared panels into the plugin | The overview search also uses both; core would then import from a plugin, reversing the cycle rather than breaking it. |
| VGS-22 option 2 — promote `vgsMenu` into core | Defensible (the launcher must always exist) but a far larger change, and it forecloses VGS-20 option 1 by fusing the launcher into core before the duplication question is settled. |

## Revisit When

- Niri hardware or a VM becomes available for verification — then take VGS-20
  option 1, delete `Modules/WorkspaceOverlays/OverviewSearch/` and rebuild the
  overview's inline search on `vgsMenu` or `AppSearchService`. This decision
  exists to make that move cheaper, not to prevent it.
- The niri overview overlay is removed or stops embedding a search field, which
  leaves `OverviewSearch/` with no consumer at all.
- A third consumer appears for anything in `OverviewSearch/`, invalidating the
  single-owner premise.
- Plugins become genuinely optional, sandboxed or independently versioned —
  then the `qs.Widgets.Launcher` surface needs a real compatibility contract
  rather than a documented convention.
- An owner reviews this and disagrees. It was recorded to unblock VGS-45, not
  to settle the question by default.

## References

- Linear: VGS-45 (bundle), VGS-20, VGS-22, VGS-21, VGS-23
- VGS-13 / PR #30 — the launcher consolidation this is the aftermath of
- `docs/architecture/shell-architecture.md` § Core and the vgsMenu plugin
