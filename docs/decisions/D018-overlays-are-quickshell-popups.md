# D018: Overlays are Quickshell popup windows anchored to their item

[← Decision Index](INDEX.md)

**Date**: 2026-09-26

**Status**: Active

**Research**: —

**Context**: A popover, a tooltip, a menu and a select list must open outside the surface they are declared in, since a bar is 26 pixels tall, follow the item they opened from, take keys, and close on a press outside. The design plan chose Qt popups with `popupType: Popup.Window`, whose templates keep their selection, navigation and dismissal, with the revisit condition that a Qt popup fails a smoke row a Quickshell popup passes.

**Decision**: Every overlay in `qs.Ui` is a Quickshell `PopupWindow` anchored to the item that declares it, with the edges, gravity and adjustment the summon host uses and a negative bottom anchor margin as the gap. `Menu` and `Select` hold their own keys and highlight, and `Select` extends `T.AbstractButton` rather than `T.ComboBox`, whose list must be a Qt popup. One internal `AnchorTracker` watches the anchor and its ancestors, updates the anchor on a move and closes the popup on a hide; one `OverlayState` singleton counts open overlays for the tooltip policy. The unit runner supplies a stand-in `PopupWindow` that positions nothing; the nested sandbox proves placement, keys and dismissal.

**Rationale**:

- Measured on host cachy with Quickshell 0.3.1 and Qt 6.11.2 on 2026-09-26: a Qt window popup declared in a bar widget landed at the anchor's right edge four pixels below the bar's top whatever `x` and `y` it asked for, since Qt leaves repositioning to the Wayland server and never sends one, and its one placement follows the parent window's bounds. A Quickshell popup anchored to the same item landed under the item's bottom edge and moved with it.
- The revisit condition of the plan's decision held, so the alternative it named applies.
- Templates still supply what they can: `MenuItem` is a `T.MenuItem`, a select entry a `T.ItemDelegate`, the select control a `T.AbstractButton`.

**Revisit When**: Qt sends `xdg_popup.reposition` for a window popup and bounds it by the screen, or Quickshell offers a popup type Qt's templates accept as their `popup`.

**Verification**: `scripts/smoke/rows/overlays.sh` reads a popover's rectangle under its anchor, the popover following a moved anchor and closing on a hidden one, keys typed into it, Escape and a press outside closing it, the tooltip's hover and its silence under an open popover, a menu triggered by keys, a select chosen by pointer and by keys, and a select list nested in a summoned panel; `scripts/qml-tests/tst_overlays.qml` pins the open state, the keys and the theme change through the stand-in.

**References**: [D002](D002-quickshell-0-3-1-baseline.md), [D017](D017-templates-and-path-icons.md)
