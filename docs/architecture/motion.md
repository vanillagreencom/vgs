# Motion

Covers: shell/Ui/layout/ListCursor.qml, shell/Ui/layout/ListCursorLogic.js, shell/Ui/layout/ListCursorRow.qml, shell/Ui/layout/ListEntrance.qml, shell/Ui/layout/ListAnimation.qml, scripts/test-list-cursor-logic.js, scripts/qml-tests/tst_listcursor.qml, scripts/smoke/rows/list-motion.sh, shell/plugins/vgs.launcher/Motion.js

The list motion every list of rows shares: one cursor that travels between the rows, and rows that rise in as they arrive. Its timings are the `motion.list` tokens, so `motion.scale` stills it as it stills every duration ([design-system.md § Tiers](design-system.md#tiers)).

## The list motion

- `ListCursor` draws a list's highlight as one plate under the row that holds the list's selection. It travels to the next row over `motion.list.travel` and takes that row's height over `motion.list.resize`, rather than lighting each row. It fades in and out over `motion.list.fade`. It lands at once after `snap()`, which a rebuilt list, a jump or a wrap calls, and while it is hidden, so it appears where it lands.
- `ListEntrance` is a row's entrance: the row rises `motion.list.rise` into place over `motion.list.enter`. Each of the first `motion.list.staggerRows` rows that arrive in one turn waits one `motion.list.stagger` more than the row before it. A `ListItem` that names a cursor enters as it is created; a view that creates rows as they scroll into view sets `enters: false`.
- At `motion.scale` 0 every step is 0: the cursor lands and shows at once, and a row stands in place as it is created.
- The cursor sits in the item that holds the rows, or in any item above them that is not a positioner, such as a view's `contentItem`. It sums the positions of the items between, so it follows a row whose container moves and ignores a row's transform, such as its entrance. `follow` refuses a row outside that item with an error, and the cursor stays where it was.
- The cursor draws at z -1, under the rows. Qt draws a child at a negative z under its parent's own paint, so the cursor's parent must draw nothing: a list on a surface that paints a fill, such as the launcher's glass flyout, holds its rows and cursor in a plain item inside it. The cursor logs an error for a parent that paints a fill.

## One selection

- A list has one selection, and the keyboard and the pointer both write it. The cursor draws it, and a row under a cursor draws no fill of its own, so a hover fill never shows beside a keyboard highlight.
- A keyboard step, a rebuilt list and a filter that changes the rows call `disarm()`, and an opening or a rebuild calls `snap()` before it sets the selection, so the cursor lands on it rather than travelling from where the list last left it. After that, a hover moves the selection only once the pointer has moved, compared in half steps of `wl_fixed_t` ([runtime-pointer.md](runtime-pointer.md)). A pointer resting over a list that scrolls or animates under it never takes the selection from the keyboard. `arm()` lets the next hover take it at once, as after the launcher's click into a submenu.
- `ListItem`, `MenuItem` and the entries of `Select` wire their rows to a cursor through the module's internal `ListCursorRow`: `highlighted` hands the cursor the row, and a hover the cursor lets through emits `pointed`, for the list to select the row. The keyboard rules a list follows beyond this, such as which keys move it, are the list's own.

## Where it runs

- A list whose rows each take one selection uses the motion: a `Menu`, the list of `Select`, the Settings plugin list, the launcher's results and its file flyout, and the gallery's example.
- A list whose highlight marks a state rather than a selection, or whose rows are rows of controls, has no cursor. These are the Themes panel, whose highlight marks the displayed theme, and the Dev Tools rows, which hold buttons and channel selects. The Updates rows are disclosures with their own buttons, and the Agent Warden rows are read-only.

## A plugin that owns its look

- The launcher owns its look ([appearance.md](appearance.md)). It hands `ListCursor` and `ListEntrance` its own `motion`, in the shape of `motion.list`, and its own glass plate as the cursor's `background`. Each step there is `Easing.BezierSpline` with the launcher's curve, which `ListAnimation` reads, and every duration comes from the launcher's table, so the theme reaches it through `motion.scale` alone ([D054](../decisions/D054-list-motion-is-one-cursor-in-qs-ui.md)).
- The launcher keeps four parts of its own. These are its timings and curves, the slide in from the side a menu change came from (`shift`), and which rows count as new: a row that stays across a rebuild shows at once. The fourth is the edge light, which lights the card, not a row.

## Omarchy

Omarchy (`basecamp/omarchy`, branch `quattro` at `8b4eae6`, read 2026-09-29) keeps one cursor per panel. Hover and keys write the panel's `selectedIndex`, each row draws its fill from `hasCursor` through `CursorSurface`, and that fill changes colour over 60 ms, which reduced motion sets to 0. No fill travels, and rows show at once. VGS keeps its one-selection rule and its motion switch. It draws one plate that travels, the owner's launcher design, and names every timing as a token.

## Invariants

1. At `motion.scale` 0 the list motion lands at once. Enforced by `scripts/smoke/rows/list-motion.sh`, which reads the Settings list's and the launcher's cursor land on the next row with no reading between. Under a slowed scale the same reader catches the cursor between the rows, which proves the reader sees motion. `scripts/qml-tests/tst_listcursor.qml` holds the same offline.
2. Each guarantee above holds. Enforced by `scripts/qml-tests/tst_listcursor.qml` and, for `Menu` and `Select`, `scripts/qml-tests/tst_overlays.qml`, each with one mutation in `scripts/test-qml-unit.sh`, and by `scripts/test-list-cursor-logic.js` with its controls for the pointer comparison and the stagger.
3. No list motion value is a literal. Enforced by the `literal-duration` rule of `scripts/check-design-tokens.py`, and the defaults are pinned in `scripts/test-theme-logic.js`.

## Decisions

- The list motion is one cursor in `qs.Ui`, and a plugin that owns its look hands it its own timings: [D054](../decisions/D054-list-motion-is-one-cursor-in-qs-ui.md).
