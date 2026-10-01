# Design quality

Covers: shell/Commons/Tokens.js, shell/Ui/**, scripts/sandbox-shots.sh, scripts/test-sandbox-shots.sh, scripts/smoke/fixtures/updates-status.json

The standard every surface is judged against, and the evidence that proves a surface meets it. The reference products are Vercel's Geist, Linear and Radix Themes 3.3.0. A rule names the token that owns its number. The tokens and the tiers are in [design-system.md](design-system.md), the container contract is in [design-layout.md](design-layout.md), and each component's guarantee is in [components.md](components.md).

## Grid

- Every layout dimension is a multiple of 4 px: a gap, a padding, an inset, a control's height and a row's height. The shipped scale moved onto this grid in [D063](../decisions/D063-design-scale-on-the-4-px-grid.md).
- Inside one component a 2 px step is allowed: a segment's inset (`segmented.padding`), a switch knob's inset (`toggle.inset`), a focus ring's offset (`focusRing.offset`), a scroll bar's inset (`scrollArea.barInset`) and the gap between a title and its underline (`titleButton.underlineGap`). Inside a chip or a key cap, a 6 px side padding, `space.sm`, is allowed: `badge.size.sm.paddingX` and `kbd.paddingX`.
- The grid does not govern type, strokes, icon and indicator drawing sizes (`icon.size`, `slider.handle`, `radio.dot`), motion distances or computed corner clearance. A font size and its line box follow § Type. An icon's painted bounds follow the glyph (`IconBounds.js`). A stroke is `border.thin` or `border.thick`. A corner clearance is `Inset.clearing` by `inset.cornerStep`.
- The theme browser's card geometry follows the grid: the `carousel` card is Omarchy's 768 by 475 at 476 tall, and its slices overlap by the card's 28 pixel lean where Omarchy's overlap by 30 ([components-media.md](components-media.md)). The desktop preview's reference display, 1600 by 900, is a length and on the grid; a share or a scale, such as `desktopPreview.terminalWidthShare` or `carousel.minScale`, is no length.
- `scripts/test-theme-logic.js` walks every length token of the shipped table and fails on a value off the grid outside these named classes, with a control that moves `row.height` off it and one that puts the carousel back on Omarchy's 475 and 30.
- A value off this grid is a defect in its token, never in the surface that reads it.

## Type

| Role | Size / line box / weight | Use |
|---|---|---|
| `text.h3` | 16 / 24 / 600 | the title of every window, panel, popover and dialog |
| `text.bodyStrong` | 15 / 24 / 600 | a card's or toast's title |
| `text.body` | 15 / 24 / 400 | reading text of more than one line: a description, a dialog message |
| `text.item` | 15 / line 1 / 400 | one line inside a control or row |
| `text.hint`, `text.itemHint` | 13 / 20, 13 / line 1 | a secondary line, a field hint, a timestamp |
| `text.value` | 13 / line 1 | a read-only value beside its label |
| `text.label`, `text.eyebrow`, `text.button`, `text.kbd` | 12 / line 1, mono; all but `kbd` uppercase | a field label, a section heading, a button, a badge, a key cap |
| `text.tooltip` | 12 / 16 / 500 | a tooltip line |

- A surface uses `h3` for its title. `h1` and `h2` are for documents. The full-screen theme and wallpaper browsers name their selected card in `text.display`, as Omarchy's picker does, and the lock screen draws its clock in it.
- The roles use seven sizes: 12, 13, 15, 16, 20, 24 and 34 px. `scripts/qml-tests/tst_label.qml` pins the set, so a role at a new size fails.
- A key/value row pairs `text.label` with `text.value`. Their capitals differ by less than a pixel, and on the row their baselines are within a pixel, so the pair reads as one line. At the defaults, `FontMetrics` under `scripts/qml-unit.sh` reads capitals of 8.77 and 9.45 px. The 11 px label and the 15 px `item` value they replace read 8.03 and 10.91. The hierarchy has three levels: the value in the `text` colour, the hint under it in `hint` and a fainter colour, and the label, a badge and a button in 12 px chrome. The label column, `row.labelWidth`, is 140 px: the label "SINGLE-WORKSPACE" measures 129.3 px at 12 px against 118.6 px at 11 px in the same run, so the column grew from 128 px to keep such a word on one line.
- Reading text is at least 13 px and chrome at least 12 px. Reading text is a description, a message, a card's body and a list row's detail line; chrome is a label, a count, a button's text and a menu entry. A plugin that owns its look ([appearance.md](appearance.md)) meets the same floor.
- A control's label, a checkbox's, a radio's and a switch's, draws in `item`, so its line centres on the control. An indicator centres on the label's capital centre on a whole pixel.

## Controls

| Size | Height | Padding X | Icon | Gap | Tokens |
|---|---|---|---|---|---|
| `sm` | 24 | 8 | 14 | 4 | `size.control.sm`, `control.sm`, `icon.size.sm` |
| `md` | 32 | 12 | 16 | 8 | `size.control.md`, `control.paddingX`, `control.gap`, `icon.size.md` |
| `lg` | 40 | 16 | 16 | 12 | `size.control.lg`, `control.lg`, `icon.size.md` |

The heights, paddings and gaps are Radix Themes 3.3.0 button sizes 1, 2 and 3. `button.size` maps each size to its padding, gap and icon.

- A button, an icon button, a text field, a select, a segmented control, a tab row and a menu entry of one size share the height, the padding and the content icon. A disclosure indicator, such as a select's chevron, is one icon step smaller than the content icon.
- The controls of one row share one size. A badge beside an `sm` button is `Badge` `md`, 24 px.
- Every interactive control draws rest, hover, pressed, focus, disabled and, where it has one, checked, each from its own token. Hover and pressed differ from each other and from rest. A checked checkbox, radio or switch still shows hover and press, each its own token. An item a click cannot change in its current state, the chosen segment of a `SegmentedControl` and an `active` `BarItem` such as the focused workspace, keeps its selected fill and draws no hover or press. A row under a `ListCursor` shows its press through the cursor's `pressedColor`.
- A control's input area is at least `size.control.sm` tall, whatever its drawn size: a small switch, a checkbox and a slider take a press over that height.
- The focus ring is `focusRing.width` 2 at `focusRing.offset` 2 and follows the control's own radius. A text field draws focus as its outline at offset 0, in the error colour while it is in error. A container leaves the ring room inside its clip.
- Disabled is `opacity.disabled` on the whole control.
- An enabled control's boundary and a selected indicator reach 3:1 against the surfaces they sit on, in both modes. `ThemeLogic.readabilityShortfalls` judges it.
- A text field and the list its select opens start their text at the same x.

## Containers

| Class | Inset | Title row | Header to body | Fit |
|---|---|---|---|---|
| window | `inset.window` 16 | `h3` in a `size.control.md` row | `stack.group` 12 | the window host sizes it |
| dialog | `inset.dialog` 16 | `h3` | `dialog.gap` 12 | content, to `dialog.maxHeightShare` |
| panel (a summoned flyout) | `inset.panel` 12, on a `Surface` | `h3` | `stack.group` 12 | content, to `size.panel.maxHeight` and the output's room; refits when content changes |
| popover (`qs.Ui` `Popover`) | `inset.popover` 12 | `h3` | `stack.group` 12, `popover.gap` 4 from its anchor | content, to `popover.maxHeightShare` |
| overlay (a full-screen browser over a `Scrim`) | `inset.overlay` 32, no corner to clear | its tabs | `stack.group` 12 | content, centred, to the output's height |
| menu | the border; a row's fill meets it | none | none | entries, to `menu.maxHeight`, 160 to `menu.maxWidth` wide |
| select list | the border; a row's fill meets it | none | none | entries, to `menu.maxHeight`, the field's width |
| tooltip | `tooltip.paddingX` 8 | none | none | wraps at `tooltip.maxWidth` 280 |

- Every window, panel, popover, dialog and overlay composes `Pane` ([D050](../decisions/D050-container-layout-contract.md), [design-layout.md](design-layout.md)). Left and right insets are equal, and the scroll bar sits inside the right inset.
- A menu and a select list have no inset box: their rows fill the list inside the border, each row insets its own text, and the scroll bar draws over a strip each row keeps clear ([design-layout.md § Lists in a popover](design-layout.md#lists-in-a-popover)).
- A header row's height is its control size. Every item in it centres on the row, and a title centres by its capital height.
- A back or close `IconButton` at the start or end of a header puts its glyph's painted bounds, not its box, on the content edge ([design-layout.md § Headers](design-layout.md#headers)).
- A title that opens a menu draws its caret at rest and its underline on hover, on focus and while the menu is open.
- A footer is a `Pane` footer. It stays in view while the body scrolls, and its controls share one size.
- A summoned panel, a menu, a select list and a tooltip are at most their output's room, the output less `size.window.gutter` a side (`OverlayState.room`), and the compositor slides each inside its output, so none extends past it.

## Rows and groups

- Rows of one group sit `stack.row` 4 apart. Blocks of one body, such as a description, a line of badges, a key/value grid and a code block, sit `stack.group` 12 apart. A section sits `stack.section` 24 after the block before it. Two controls in one line sit `stack.inline` 8 apart.
- A row with lines of its own, such as a hint, an action or a command, is a group. Its lines sit `field.gap` 4 apart, and groups sit `groupList.gap` 12 apart with a `groupList.divider` hairline centred between them: `GroupList` ([design-layout.md § Groups](design-layout.md#groups)).
- An editable key/value row is `row.height` 36. A read-only key/value row, such as a version or a source, is `row.compactHeight` 28 (`Field.compact`), with no hint slot.
- A label is `text.label` in the `row.labelWidth` column and centres on its value's first line by capital height. A read-only text value is `text.value`.
- A row whose actions take more than half its text's room moves them under the text.
- A disclosure's content starts at its row's text column.
- A section heading sits on the content edge.
- An empty list shows an icon, one `hint` line and a recovery action, such as Clear search, centred in a box `3 × row.twoLineHeight` tall: `EmptyState` in `qs.Ui`.
- A long diagnostic shows one elided line and a control that shows it whole in a `CodeLine` to copy. A tooltip never holds the only copy.

## Bar

- Every widget is one `BarItem`: `bar.item.height` tall, `bar.item.paddingX` 8 a side, a `bar.item.icon` 16 px icon, `bar.gap` from the next widget. An icon-only item is square.
- A count beside an icon draws the same way in every widget.

## Evidence

- `scripts/sandbox-shots.sh` captures every surface class in dark, light and rounded, at scale 1 and 2, on the default monitor and on a 480 × 720 one; the theme and wallpaper browsers only when named. A hover shot waits until its item reports the pointer. A change to a surface lands with before and after shots of it.
- A defect class that can be measured has a geometry row under `scripts/smoke/rows/` or a `qs.Ui` unit test under `scripts/qml-tests/`, each with a must-fail control ([validation.md](validation.md)). A geometry row checks containment and minimums, so a theme with a larger font still passes.
