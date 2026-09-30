# D051: The list motion is one cursor in qs.Ui, and a plugin that owns its look hands it its own timings

[← Decision Index](INDEX.md)

**Date**: 2026-09-29
**Status**: Active
**Research**: VGS-579
**Refines**: [D023](D023-plugin-owned-appearance.md)

**Context**: The launcher's list motion, a plate that glides between rows and rows that rise in staggered, lived in the launcher's own files, so no other list had it and each new list would draw its own hover and highlight fills. The launcher owns its look under D023, which takes only the theme's mode, accent and motion scale. D023 names this case as its trigger: a component of `qs.Ui` gains a parameterized form that plugins with their own look share.

**Decision**: `qs.Ui` holds the list motion: `ListCursor`, one plate per list that travels to the row holding the selection and follows the list's one selection, which keyboard and pointer both write, with the pointer taking it only after it moves; and `ListEntrance`, a row's staggered entrance. Their timings are the `motion.list` tokens by default. `ListItem`, `MenuItem` and `Select` wire their rows to a cursor. A plugin that owns its look hands both components its own `motion`, in the shape of `motion.list`, where a step may be `Easing.BezierSpline` with its own curve, and its own `background` for the plate; the components then read no theme value the plugin did not pass. The launcher does so: its timings, curves, glass plate, side slide, freshness rule and edge light stay its own.

**Rationale**:
- One mechanism for every list removes the second highlight a hover fill drew beside a keyboard highlight, and a list gets the motion by naming its cursor.
- A parameterized component keeps D023's promise: every value the launcher's list draws with still comes from its own table, which the theme reaches through the motion scale alone.
- Omarchy's `CursorSurface` shows the one-selection rule works across a shell's panels. It fades each row's fill in place, and VGS draws a travelling plate, the owner's launcher design, with every timing a token.
- A ListView `highlight` was rejected: its built-in follow animation takes no easing, and menus lay their entries out in a `Column`, not a view.

**Revisit When**: A list needs its selection drawn by more than one plate, such as a multi-select, or Qt Quick gains a view highlight that takes an easing curve.

**Verification**: `scripts/qml-tests/tst_listcursor.qml` and `scripts/qml-tests/tst_overlays.qml`, with one mutation per guarantee in `scripts/test-qml-unit.sh`; `scripts/test-list-cursor-logic.js`; `scripts/smoke/rows/list-motion.sh` reads the Settings list and the launcher travel under a slowed scale and land at once at `motion.scale` 0.

**References**: [D023](D023-plugin-owned-appearance.md), [D015](D015-tokens-are-a-judged-table.md), [D017](D017-templates-and-path-icons.md), [motion.md](../architecture/motion.md)
