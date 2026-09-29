# D050: Containers use one inset box, an inner scroll gutter and fitted popup height

[← Decision Index](INDEX.md)

**Date**: 2026-09-29
**Status**: Active
**Research**: VGS-578

**Context**: Settings, dialogs and popovers placed headings, fields, rows and scroll bars with separate arithmetic. Their left and right edges drifted, a scroll bar could sit outside the content inset, and popup height had no single rule. VGS-582 moves the Settings window's outer size and border to a Hyprland toplevel, so this decision covers the inner Settings pages and the reusable qs.Ui containers, not the Settings window's outer size.

**Decision**: A qs.Ui container uses one token-driven inset box. Boxed children put their box on that edge. Unboxed text puts its text on that edge. A scroll bar sits inside the right inset strip, while the scroll content ends on the inset box. A rounded container clears the drawn corner by one spacing step through `Inset.clearing`. Dialog and popover containers fit their content until a max-height share is reached, then the body scrolls.

**Rationale**:
- One inset owner removes per-surface padding arithmetic.
- Keeping the scroll bar inside the right inset gives equal left and right visual insets whether content overflows or not.
- The shared corner-clearing rule keeps themes with rounded containers from placing text or highlight fill into the corner.
- Omarchy's `PopupCard.fittedContentHeight` uses the same content-plus-insets, capped-by-available-height rule. VGS applies that rule to qs.Ui `Dialog` and `Popover`, while VGS-582 owns the Settings window's outer size.

**Revisit When**: A container needs a child to bleed outside the inset box, or Quickshell adds a container primitive that owns inset, scroll gutter and fitted height together.

**Verification**: `scripts/qml-tests/tst_pane.qml` pins the inset edge, right-inset scroll bar, height cap and rounded-corner clearing through `Inset.clearing`. `scripts/qml-tests/tst_scroll.qml` pins a scroll area's right inset. `scripts/smoke/rows/manager.sh` reads the Settings list page and plugin page geometry in the nested sandbox.

**References**: [D015](D015-tokens-are-a-judged-table.md), [D017](D017-templates-and-path-icons.md), [D018](D018-overlays-are-quickshell-popups.md), [D032](D032-settings-plugin-and-manifest-settings-convention.md)
