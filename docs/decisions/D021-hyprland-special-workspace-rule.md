# D021: A Hyprland workspace is special by its name, not by its negative id

[← Decision Index](INDEX.md)

**Date**: 2026-09-17 **Status**: Active **Research**: —

**Context**: The bar answered two different questions about which Hyprland workspaces count. `BarContent.getRealWorkspaces`, the list the background scroll steps through, kept every workspace with `id > -1`. `WorkspaceSwitcher.getHyprlandWorkspaces`, the list the row draws, dropped a workspace named `special` or carrying a `special:` prefix. Hyprland gives an ordinary named workspace a negative id, so the two rules answer differently for it: the row drew it and the scroll skipped it. `Services/CompositorService.qml` now owns one list for both, which forces one rule.

**Decision**: `CompositorService._hyprlandWorkspaceIsSpecial` drops a workspace whose name is `special` or starts with `special:`. A negative id keeps its workspace in the list.

**Rationale**:

- The name is what Hyprland assigns a special workspace; the negative id is shared with ordinary named workspaces.
- The row already applied the name rule, so the drawn bar keeps the workspaces users see today.
- `CompositorService.hyprlandWorkspaceSelector` already dispatches a negative-id workspace by `name:`, so a scroll can reach one.

**Revisit When**: Hyprland stops naming special workspaces with the `special` prefix, or gives an ordinary named workspace a positive id.

**Verification**: `node --test scripts/test-bar-workspace-filter.js` runs both call sites over a world holding a named workspace with a negative id and a `special:` workspace on the same screen.

**References**: [shell runtime boundaries](../architecture/shell.md)
