# D017: Controls extend QtQuick.Templates; icons are Lucide path data drawn with Shapes

[← Decision Index](INDEX.md)

**Date**: 2026-09-26

**Status**: Active

**Research**: —

**Context**: The component library needs press, hover, focus, keyboard activation, checked state, exclusive groups, slider arithmetic, list navigation and popup dismissal for every control, and one icon set whose line weight a theme sets. Writing each behaviour with `MouseArea` and `Keys` per control repeats Qt's work and misses the keyboard and accessibility paths; an icon font fixes the stroke to the glyph size.

**Decision**: Every control in `qs.Ui` extends a `QtQuick.Templates` type, which supplies the behaviour and draws nothing, and supplies its `background`, `contentItem`, `indicator`, `handle` or `delegate` from tokens. Icons are Lucide path data, written by `scripts/vendor-lucide` from the pinned `lucide-static` package into `shell/Ui/icons/Lucide.js` with every primitive converted to path commands, and drawn by `Icon` with `QtQuick.Shapes` and the curve renderer. The shape is drawn in the data's box and scaled as an item, so `icon.stroke` is an absolute pixel width at every size. `qs.Ui` imports no Quickshell module, so every component runs under `qmltestrunner` offscreen.

**Rationale**:

- Templates give keyboard, focus, checked and exclusive behaviour from Qt, measured at 3,004 KiB of resident size over a plain scene on host cachy on 2026-09-26.
- Path data lets the stroke be a token; the Lucide font ties the stroke to the size. A `ShapePath` scaled through its own `scale` loses a stroke under one path unit, so the item is scaled instead.
- A module free of Quickshell imports runs under the offscreen test runner, so each component's guarantees are unit tests with mutation controls rather than sandbox rows alone.

**Revisit When**: A Qt popup fails a smoke row a Quickshell popup passes, the pixel tests show a drawing defect the icon font does not have, or the resident size budget is felt.

**Verification**: `scripts/qml-unit.sh` with `scripts/qml-tests/tst_*.qml` and its control `scripts/test-qml-unit.sh`; `scripts/test-lucide-data.js` pins the data's version, count, conversions and required names; `scripts/check-design-tokens.py` keeps the components free of literals.

**References**: [D002](D002-quickshell-0-3-1-baseline.md), [D015](D015-tokens-are-a-judged-table.md), [D016](D016-bundled-variable-font.md)
