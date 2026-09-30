# Design quality

Covers: shell/Commons/Tokens.js, shell/Ui/**, scripts/sandbox-shots.sh, scripts/test-sandbox-shots.sh, scripts/smoke/fixtures/updates-status.json

The standard every surface is judged against, and the evidence that proves a surface meets it. The reference products are Vercel's Geist, Linear and Radix Themes 3.3.0. A rule names the token that owns its number. A **Now** value differs from its **Target** where the token does not meet the rule yet. The tokens and the tiers are in [design-system.md](design-system.md), the container contract is in [design-layout.md](design-layout.md), and each component's guarantee is in [components.md](components.md).

## Grid

- Every gap, padding, inset and fixed size is a multiple of 4 px. A 2 px step sits only inside one component: a segment's inset, a focus ring's offset, the gap between a title and its underline, the gap between the two lines of one row. A 6 px half step sits only inside a chip, a key cap or a tooltip. A 1 px value is a stroke.
- A value off this grid is a defect in its token, never in the surface that reads it.

| Token | Now | Target | Reason |
|---|---|---|---|
| `control.gap` | 7 | 8 | the icon-to-text gap of an `md` control, Radix button size 2 |
| `control.paddingX` | 9 | 12 | the side padding of an `md` control, Radix button size 2 |
| `size.control.md` | 30 | 32 | Radix size 2, Geist small; `textField.height`, `menu.item.height`, `tabs.height` and `segmented.height` follow it |
| `size.control.lg` | 36 | 40 | Radix size 3 |
| `listItem.twoLineHeight` | 54 | 56 | the grid step above it |
| `row.labelWidth` | 130 | 128 | the label column |
| `bar.height` | 26 | 28 | the bar's box; a bar item stays `size.control.sm` |
| `badge.gap` | 7 | 4 | icon-to-label gap inside a chip |
| `toast.gap`, `dialog.actionGap` | 6 | 8 | a gap between two components is a full step |
| `kbd.paddingY`, `kbd` height | 2, line + 4 | a 20 px box | the height of `Badge` `sm` |
| `tooltip.paddingY`, `tooltip.paddingX` | 2, 6 | 4, 8 | a 24 px box for one line, Radix Tooltip |

## Type

| Role | Size / line box / weight | Use |
|---|---|---|
| `text.h3` | 16 / 24 / 600 | the title of every window, panel, popover and dialog |
| `text.bodyStrong` | 15 / 24 / 600 | a card's or toast's title |
| `text.body` | 15 / 24 / 400 | reading text of more than one line: a description, a dialog message |
| `text.item` | 15 / line 1 / 400 | one line inside a control or row |
| `text.hint`, `text.itemHint` | 13 / 20, 13 / line 1 | a secondary line, a field hint, a timestamp |
| `text.label`, `text.eyebrow`, `text.button` | 11 / line 1, mono, uppercase | a field label, a section heading, a button |
| `text.tooltip` | 12 / 16 / 500 | a tooltip line |

- Every multi-line role's line box is a multiple of 4. **Now:** `body` and `bodyStrong` are 1.55 (23 px), `h3` is 1.3 (21 px), `h2` is 1.25 (25 px), `h1` is 1.2 (29 px), `display` is 1.15 (39 px) and `tooltip` is 11 px mono 600 at 1.3. **Target:** 1.6, 1.5, 1.4 (28 px), 1.333 (32 px), 40 px, and 12 px at line box 16, Radix Tooltip's size.
- A surface uses one title role per class. **Now:** Settings titles are `h2`, the Gallery's is `h1`, every other window, panel and dialog is `h3`. **Target:** `h3` everywhere; `h1` and `h2` stay for documents.
- Reading text is at least 13 px and chrome at least 11 px. A plugin that owns its look ([appearance.md](appearance.md)) meets the same floor.
- A control's label, a checkbox's, a radio's and a switch's, draws in `item`, not `body`, so its line centres on the control.

## Controls

| Size | Height | Padding X | Icon | Gap | Tokens |
|---|---|---|---|---|---|
| `sm` | 24 | 8 | 14 | 4 | `size.control.sm`, `icon.size.sm`; padding and gap are new `control.sm` tokens |
| `md` | 32 | 12 | 16 | 8 | `size.control.md`, `icon.size.md`, `control.paddingX`, `control.gap` |
| `lg` | 40 | 16 | 16 | 12 | `size.control.lg`, `icon.size.md`; padding and gap are new `control.lg` tokens |

The heights, paddings and gaps are Radix Themes 3.3.0 button sizes 1, 2 and 3.


- A button, a text field, a select, a segmented control, a tab row and a menu entry of one size share the height, the padding and the icon. **Now:** `Button` draws a 14 px icon at every size and `IconButton` a 16 px icon at every size.
- The controls of one row share one size. A badge beside a button takes the button's height: `Badge` `md` beside an `sm` button is 24 px.
- Every interactive control draws six states from its own tokens: rest, hover, pressed, focus, disabled and, where it has one, checked. Hover and pressed differ from each other and from rest. A checked control still shows hover and press. **Now:** `ListItem`, `MenuItem`, `Tabs`, `SegmentedControl`, `Checkbox`, `Radio` and `Switch` draw no pressed state, and a checked `ToggleButton` shows neither hover nor press.
- The focus ring is `focusRing.width` 2 at `focusRing.offset` 2, following the control's own radius. A text field draws focus as its outline at offset 0.
- Disabled is `opacity.disabled` on the whole control, `SegmentedControl` and `Tabs` included.
- A text field and the list its select opens start their text at the same x.

## Containers

| Class | Inset | Title row | Header to body | Fit |
|---|---|---|---|---|
| window | `inset.window`, 12 → 16 | `h3` in a `size.control.md` row | `stack.group` 12 | the window host sizes it |
| dialog | `inset.dialog`, 12 → 16 | `h3` | `dialog.gap` 8 → `stack.group` 12 | content, to `dialog.maxHeightShare` |
| panel, popover | `inset.panel` 12, `inset.popover` 8 → 12 | `h3` | `stack.group` 12 | content, to `popover.maxHeightShare`; refits when content changes |
| menu, select list | `menu.padding` 2 → 4 | none | none | entries, to `menu.maxHeight` |
| tooltip | `tooltip.paddingX` 8 | none | none | one line, then wraps at `size.panel.sm` |

- Every window, panel, popover and dialog composes `Pane` ([D050](../decisions/D050-container-layout-contract.md)). Left and right insets are equal; the scroll bar sits inside the right inset.
- A header row's height is its control size, and every item in it centres on it. A back or close `IconButton` at the start or end of a row puts its glyph, not its box, on the content edge; its hover box reaches into the inset.
- A title that opens a menu draws its caret at rest and its underline on hover, focus and while the menu is open.
- A footer is a `Pane` footer row: its controls share one size and centre on the row, with a divider that spans the inset box.
- A container never extends past its output: it keeps `size.window.gutter` from each screen edge on a narrow monitor.

## Rows and groups

- Rows of one group sit `stack.row` 4 apart. Blocks of one body, such as a description, a line of badges, a key/value grid and a code block, sit `stack.group` 12 apart. A section sits `stack.section` 24 after the block before it. `Pane.bodySpacing` defaults to `stack.group`. **Now:** it is `pane.gap` 8.
- An editable key/value row is `row.height` 36. A read-only key/value row, such as a version or a source, is `row.compactHeight` 28 (new), with no hint slot. **Now:** Settings draws Author, Version, License and Source as 36 px rows 12 apart.
- A label is `text.label` in the `row.labelWidth` column and centres on its value's first line by capital height.
- A disclosure's content starts at its row's text column.
- A section heading sits on the content edge: `Section.headerInset` defaults to 0. **Now:** it defaults to `row.paddingX`, and every caller sets it back to 0.
- An empty list shows one `hint` line and an optional action, centred in the space three rows take.

## Bar

- Every widget is one bar item: `size.control.sm` tall, `bar.item.paddingX` a side, a 16 px icon at full opacity, `bar.gap` from the next widget.
- A count beside an icon draws the same way in every widget.

## Evidence

- `scripts/sandbox-shots.sh` captures every surface class in dark and light at scale 1 and 2, on the default and on a 480 × 720 monitor. A change to a surface lands with before and after shots of it.
- A defect class that can be measured has a geometry row under `scripts/smoke/rows/` or a `qs.Ui` unit test under `scripts/qml-tests/`, each with a must-fail control ([validation.md](validation.md)).
