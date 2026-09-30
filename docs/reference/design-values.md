# Design reference values

The rule of the reference stylesheet each typography role and each component's spacing is read from, and where the shell departs from it. The stylesheet is plugins.omarchy.org `assets/css/style.css?v=20260923-01`, fetched with curl on 2026-09-29. Radix Themes 3.3.0 component sources supply switch and badge sizes. Omarchy default branch commit b421b1b adds no smaller content-row rule than the plugin stylesheet. The rules these values follow are [design-system.md § Text stack](../architecture/design-system.md#text-stack) and [design-layout.md § Component spacing](../architecture/design-layout.md#component-spacing). Every layout value sits on the 4 px grid of [D058](../decisions/D058-design-scale-on-the-4-px-grid.md), so a reference value off that grid is the nearest grid step here; the rubric is [design-quality.md](../architecture/design-quality.md).

## Text roles

Each role is read from one rule of the stylesheet. A value the rule does not set is the inherited one: `body` sets 15 px and line height 1.55, and an unstyled heading is bold. The last column names where the role departs from its rule.

| Role | Reference rule | Reference value | Departs |
|---|---|---|---|
| `text.display` | `.page-header h1` | sans, 34 px, 700, -.02em, line height 1.15 | line height 1.3, a 44 px line box |
| `text.h1` | `.market-contribute h2` | mono, 24 px, bold, line height 1.55 | sans, -.01em, line height 1.333, a 32 px line box |
| `text.h2` | `.detail-section h2` | sans, 20 px, bold, line height 1.55 | 600, line height 1.4, a 28 px line box |
| `text.h3` | `.plugin-title-line h3` | sans, 16 px, bold, line height 1.55 | 600, line height 1.5, a 24 px line box |
| `text.subheading` | `.intro` | sans, 16 px, 400, line height 1.75 | |
| `text.body` | `body` | sans, 15 px, 400, line height 1.55 | line height 1.6, a 24 px line box |
| `text.bodyStrong` | `.check-list strong` | sans, 15 px, 650, line height 1.55 | 600, line height 1.6 |
| `text.item` | `.aside-link` | the inherited `body`: sans, 15 px, 400, line height 1.55 | line height 1, so a one-line entry centres its glyphs |
| `text.itemHint` | `.check-list small` | sans, 13 px, 400, line height 1.55 | line height 1, for a list item's secondary line |
| `text.itemCode` | `.code-block pre` | mono, 13 px, 500, line height 1.65 | line height 1, for one line of code beside an inline label |
| `text.hint` | `.check-list small` | sans, 13 px, 400, line height 1.55 | |
| `text.eyebrow` | `.page-eyebrow` | mono, 11 px, 700, .18em, uppercase, line height 1.55 | line height 1 |
| `text.label` | `.code-head` | mono, 11 px, 500, .08em, uppercase, line height 1.55 | line height 1 |
| `text.button` | `.button` | mono, 11 px, 400, .08em, uppercase, line height 1.55 | 500, line height 1; `Button` draws the variant's weight |
| `text.kbd` | `.sidebar-search kbd` | mono, 11 px, 600, .02em, line height 1 | |
| `text.code` | `.code-block pre` | mono, 13 px, 500, line height 1.65 | line height 1.5, after owner review of wrapped commands |
| `text.tooltip` | `.control-tooltip` | sans, 11 px, 600, 0em, line height 1.3 | 12 px, 500, line height 1.333, a 16 px line box: Radix Tooltip |
| `text.bar` | `.sidebar-brand`, `.button` | mono, 12 px, 700, .04em, uppercase; `.button` .08em | 500, .08em, line height 1 |

## Component spacing

Each value is read from one rule of the stylesheet. A measured value is the resolved default in pixels, as `ThemeLogic.accept` answers it for an empty document; "line" is the text's own line box. The reference draws square corners, so every radius is 0 except a round indicator's. The last column names where a component departs from its rule.

| Component | Height | Padding X | Gap | Radius | Token | Reference rule | Reference value | Departs |
|---|---|---|---|---|---|---|---|---|
| `Button` md, `ToggleButton` | 32 | 12 | 8 | 0 | `size.control.md`, `button.size.md` | `.card-install` | min-height 30, padding 0 9, gap 7 | Radix button size 2 |
| `Button` sm | 24 | 8 | 4 | 0 | `size.control.sm`, `button.size.sm` | `.card-install` | min-height 30, padding 0 9, gap 7 | Radix button size 1; a 14 px icon |
| `Button` lg | 40 | 16 | 12 | 0 | `size.control.lg`, `button.size.lg` | `.button` | min-height 36, padding 0 13, gap 7 | Radix button size 3 |
| `IconButton` | 24, 32, 40 | square | | 0 | `size.control`, `icon.size` | `.search-clear` | 30 × 30, padding 0 | the icon follows the size: 14 at `sm`, 16 at `md` and `lg` |
| `TextField` | 32 | 12 | 8 | 0 | `textField.height`, `textField.paddingX`, `textField.gap` | `.search-term` | height 30, padding 0 7 0 9, gap 7 | 16 px content icons |
| `Select` | 32 | 12; the chevron's room on the right | 8 | 0 | `textField.height`, `textField.paddingX`, `textField.gap` | `.sort-control select` | padding 0 34 0 12 | its list's entries start at the field's text x |
| `SegmentedControl` | 32 | 2 inset | 2 | 0 | `segmented.height`, `segmented.padding`, `segmented.gap` | `.catalog-view-mode` | gap 4 | inset 2, gap 2 |
| a segment | 28 | 12 | | 0 | `segmented.paddingX` | `.catalog-view-mode button` | min-height 29, padding 0 9 | 32 less the inset |
| `ListItem` | 36; 56 with a secondary line | 12 | 8; 4 between its lines | 0 | `listItem.height`, `listItem.twoLineHeight`, `listItem.paddingX`, `listItem.gap`, `row.lineGap` | `.field-row` | min-height 45, padding 0 12 | 36 and 56 on the grid |
| `MenuItem` | 32 | 12 | 8 | 0 | `menu.item.height`, `menu.item.paddingX`, `menu.item.gap` | `.aside-link` | min-height 32, padding 5 0 5 12 | a trailing shortcut column; the title elides |
| a `Select` list entry | 32 | the field's side padding | | 0 | `menu.item.height`, `textField.paddingX` | `.aside-link` | min-height 32, padding 5 0 5 12 | |
| `Field`, inline | 36 unless the control is taller; 28 compact | 12 | 12 after a 128 label; 4 between row and hint | | `row.height`, `row.compactHeight`, `field.labelWidth`, `field.labelGap`, `field.gap` | `.field-row` | min-height 45, padding 0 12, columns 130px 1fr 70px, gap 12 | no third column; a read-only row is compact |
| `SectionHeader` | its lines, 0 above, 4 below | 0 | 4 | | `sectionHeader.paddingBottom`, `sectionHeader.gap` | `.listing-checks h3` and `.detail-section` | heading after 28 px section gap, margin-bottom 12 | `Section` owns the 24 px section gap |
| `Section` | content | 0 header inset by default | 4 between rows; 12 between groups; 24 above sections | | `stack.row`, `stack.group`, `stack.section` | `.detail-section` | 28 px above and below, heading margin-bottom 12 | 24 px section gap on the 4 px grid |
| `Badge` sm | 20 | 6 | 4 | 0 | `badge.size.sm.height`, `badge.size.sm.paddingX`, `badge.gap` | Omarchy `.listing-check-status`; Radix Badge size 1 | min-height 20, padding 2 7 0; padding 2 × 6 | optical centring instead of top padding |
| `Badge` md | 24 | 8 | 4 | 0 | `badge.size.md.height`, `badge.size.md.paddingX`, `badge.gap` | Radix Badge size 2 | padding 4 × 8, 24 tall | the label role |
| `Kbd` | 20, at least square | 6 | | 0 | `kbd.height`, `kbd.paddingX` | `.sidebar-search kbd` | padding 3 7 | the height of `Badge` sm |
| `CodeLine` | 16 padding plus the larger of its line boxes and the Copy button | 8 | 8 between the text and the button | 0 | `codeLine.padding`, `codeLine.gap`, `size.control.sm` | Omarchy `.code-block pre` | padding 18 20, line-height 1.65 | wraps at word boundaries; line height 1.5 |
| `Tabs` | 32 | 12 | 8 between tabs | | `tabs.height`, `tabs.paddingX`, `tabs.gap` | `.market-nav a` | height 32, padding 0 10 | padding 12 |
| `Tooltip` | line + 8, wrapping at 280 | 8 | 4 from the anchor | 0 | `tooltip.paddingX`, `tooltip.paddingY`, `tooltip.gap`, `tooltip.maxWidth` | `.control-tooltip` | padding 5 7 | padding 4 8, Radix Tooltip |
| `Toast` | content + 16 | 8 | 8 between icon, text and close; 8 between toasts | 0 | `toast.padding`, `toast.contentGap`, `toast.gap` | `.toast` | padding 9 12 | padding 8 |
| `Checkbox`, `Radio`, `Switch` | indicator 16, 16, Switch sm 28 × 16 and md 36 × 20; input at least 24 | | 8 | 0; round for `Radio` and `Switch` | `checkbox.gap`, `radio.gap`, `toggle.size`, `toggle.gap`, `size.control.sm` | Radix Switch size 1 and 2 | 28 × 16 and 35 × 20 | md width is 36 |
| `IconButton` rest | as `IconButton` | | | 0 | `iconButton.restOpacity` | Geist and Linear icon-only buttons | muted at rest, opaque on interaction | rest opacity 0.6 |
| `Slider` | 14 handle, 4 track; input at least 24 | | | round | `slider.handle`, `slider.track`, `size.control.sm` | none | | |
| `Popover` | content + 24 | 12 | 4 from the anchor | 0 | `popover.padding`, `popover.gap` | none | | |
| `Dialog` | content + 32 | 16 | 12 between the title, the message, the content and the actions; 8 between actions | 0 | `dialog.width`, `dialog.padding`, `dialog.gap`, `dialog.actionGap` | none | | 360 wide |
| `Menu` | items + 16, 160 to 360 wide, scrolling past nine items | 8 | 4 from the anchor | 0 | `menu.padding`, `menu.gap`, `menu.minWidth`, `menu.maxWidth`, `menu.maxHeight` | none | | |
| the embedded scroll bar | the area's height; a thumb of at least 24 | 4 thick, 2 from the edge, in an 8 gutter | | round | `scrollArea.barWidth`, `scrollArea.barInset`, `scrollArea.gutter`, `scrollArea.minThumb` | none | | |
| `TitleButton` | the role's line + 3 | 0 | 4 to the caret; the underline 2 below the text | | `titleButton.gap`, `titleButton.underline`, `titleButton.underlineGap` | none | | |
| a window | half the monitor | 16 inset; 12 from a narrower monitor's sides | | | `size.window.width`, `size.window.heightShare`, `size.window.gutter`, `inset.window` | none | | 600 wide |
| `BarItem`, a workspace pill | 24 | 8; square when icon-only | 4 between items | 0 | `bar.item.height`, `bar.item.paddingX`, `bar.item.gap`, `bar.item.icon` | `.market-nav a` | height 32, padding 0 10 | sized to the bar |
| the bar | 28 | 12 | 8 | | `bar.height`, `bar.padding`, `bar.gap` | `.market-toolbar` | min-height 44 | 28 tall |
