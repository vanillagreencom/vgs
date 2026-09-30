# D063: The design scale sits on a 4 px grid, and row heights are their own tokens

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: VGS-580
**Refines**: [D015](D015-tokens-are-a-judged-table.md), [D050](D050-container-layout-contract.md)

**Context**: The shipped component spacing was read from the Omarchy plugin stylesheet ([design-values.md](../reference/design-values.md)): 30 px controls, 7 and 9 px gaps and paddings, 54 px two-line rows, a 130 px label column, 26 px bar and 1.55 line heights. Those values sit off any common step, so the gap between two components differed from the gap inside one by a pixel or two, and line boxes such as 23 px and 21 px put text off the rhythm of the boxes around it. The owner asked for the finish of Vercel's Geist, Linear and Radix Themes. `row.height` and `listItem` read `size.control.lg`, so a larger control scale would also have grown every list row.

**Decision**: Every layout dimension of the shipped table is a multiple of 4 px, except the classes [design-quality.md § Grid](../architecture/design-quality.md#grid) names: type, strokes, indicator drawing sizes, 2 px steps inside one component, chip padding and motion distances. The theme browser's card and preview geometry is on the grid like every other group. Controls are 24, 32 and 40 px, Radix Themes 3.3.0 button sizes 1 to 3, with 8, 12 and 16 px side padding and 4, 8 and 12 px gaps. Row heights are their own tokens: `row.height` 36, `row.twoLineHeight` 56 and `row.compactHeight` 28 do not follow the control scale. Line heights put each multi-line role on a line box that is a multiple of 4. Window and dialog insets are 16 px, popover and panel insets 12, menus 8. The Omarchy stylesheet stays the reference for each role's family, weight and letter spacing, and design-values.md records where the grid departs from it.

**Rationale**:
- One step for every layout value removes the one- and two-pixel mismatches between neighbouring components that the owner's review found on every surface.
- Radix, Geist and Linear share a 4 px spacing grid and 24/32/40 control heights, so each value has a reference a reviewer can check.
- Separate row tokens let a theme move controls and rows independently, and kept list rows at 36 px while buttons grew to 32 and 40.
- Type, icon drawing, strokes and computed corner clearance stay off the grid: a font's metrics, a glyph's painted bounds and a curve's clearance are measured, not chosen.

**Revisit When**: The owner picks a denser or looser scale, a theme needs a grid other than 4 px, or the Omarchy reference changes a value VGS still follows.

**Verification**: `scripts/test-theme-logic.js` walks every length token of the shipped table and fails on a value off the grid outside the classes design-quality.md § Grid names, with a control that moves `row.height` off it; it pins the control and row values and a case that moves `size.control.lg` without moving `row.height`; `scripts/qml-tests/tst_label.qml` holds every multi-line role on a line box that is a multiple of 4, with a mutation in `scripts/test-qml-unit.sh`; `scripts/qml-tests/tst_spacing.qml` reads the rhythm back from drawn components.

**References**: [D015](D015-tokens-are-a-judged-table.md), [D050](D050-container-layout-contract.md), [D023](D023-plugin-owned-appearance.md), [design-quality.md](../architecture/design-quality.md), [design-values.md](../reference/design-values.md)
