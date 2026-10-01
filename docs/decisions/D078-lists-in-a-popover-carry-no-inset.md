# D078: Lists in a popover carry no inset; the row fill meets the border and the row owns its text inset

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: VGS-688
**Refines**: [D050](D050-container-layout-contract.md), [D063](D063-design-scale-on-the-4-px-grid.md)

**Context**: A menu and the list of a `Select` kept `menu.padding`, 8 px, on every side of their entries, as [D063](D063-design-scale-on-the-4-px-grid.md) set ("menus 8"). The owner's screenshot of the Settings plugin switcher (VGS-688, 2026-09-30) showed the hovered first row with a band of the menu's background above it and to its left: the hover fill never reached the list's top or side edge, and the whole list read as indented. The owner asked that a hover row fill to the edge, with no gutter above or beside it, fixed at the design-system level for every list built on the `menu` tokens.

**Decision**: A list in a popover, a `Menu` and the list of a `Select`, has no inset box. `menu.padding` is removed. A row's hover, pressed and selected fill reaches the list's inner edge, the border, at the top and on both sides. The row's own side padding (`menu.item.paddingX`, or the field's padding less the border for a select entry) owns the text inset, so a select entry's text still starts where the field's does, and the select list opens on the field's edges at its width. `menu.item.radius` follows `menu.radius`, so the fill's corner fits the list's inner corner; under a corner rounder than a row's, the list starts lower (`Inset.listInset`). While the entries overflow, the scroll bar overlays a `scrollArea.gutter` strip that each row keeps clear at its end, and the fill still spans the strip. Under a rounded corner the list is cut to the window's rounded interior by a `MultiEffect` mask (`ListMask`), so a row scrolled part way past an edge, its highlight, a chosen fill and the bar's thumb stay inside the curve; a square list draws no layer. This replaces D063's menu inset only; D063's other insets stand.

**Rationale**:
- A gap of any width between a row's fill and the border reads as the gutter the owner asked to remove.
- The row already pads its own text for a rounded corner (`Theme.controlPadding`), so an outer gutter duplicated the text inset.
- A reserved strip under an overlaid bar keeps the layout fixed when an overflow starts, as the old right inset did, without indenting the fill.
- The mask keeps the rounded-corner guarantee at every scroll position, which a rectangular clip inside a 1 px border cannot.
- Omarchy's `Dropdown` (`shell/Ui/Dropdown.qml`, `basecamp/omarchy` default branch) fills its rows edge to edge and insets the text by the row's own `controlPaddingX`. VGS puts the fill on the border itself, where Omarchy keeps a 1 px hairline, for the reason above.

**Revisit When**: A theme or surface needs a list inset inside a popover again, a list in a popover gains a header or footer that needs the container's inset box, or the mask's layer cost shows in a GPU measurement.

**Verification**: `scripts/qml-tests/tst_overlays.qml` holds the first menu and select entry's fill on the border under a square and a rounded theme, the corner inside the curve, the text start, the bar strip, a highlighted row and a chosen fill half scrolled past the top and the thumb at the top inside a rounded interior, and no layer under a square corner; `scripts/test-qml-unit.sh` turns each red with a mutation. `scripts/test-inset.js` holds `Inset.listInset`. `scripts/sandbox-shots.sh` takes the Settings menu with its first entry hovered and half scrolled, in dark and rounded.

**References**: [D050](D050-container-layout-contract.md), [D063](D063-design-scale-on-the-4-px-grid.md), [D018](D018-overlays-are-quickshell-popups.md), [design-layout.md § Lists in a popover](../architecture/design-layout.md#lists-in-a-popover), [components-overlays.md](../architecture/components-overlays.md)
