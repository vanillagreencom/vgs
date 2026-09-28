# Design reference values

The rule of the reference stylesheet each typography role and each component's spacing is read from, and where the shell departs from it. The stylesheet is plugins.omarchy.org `assets/css/style.css?v=20260923-01`, fetched with curl on 2026-09-27. The rules these values follow are [design-system.md § Text stack](../architecture/design-system.md#text-stack) and [§ Component spacing](../architecture/design-system.md#component-spacing).

## Text roles

Each role is read from one rule of the stylesheet. A value the rule does not set is the inherited one: `body` sets 15 px and line height 1.55, and an unstyled heading is bold. The last column names where the role departs from its rule.

| Role | Reference rule | Reference value | Departs |
|---|---|---|---|
| `text.display` | `.page-header h1` | sans, 34 px, 700, -.02em, line height 1.15 | |
| `text.h1` | `.market-contribute h2` | mono, 24 px, bold, line height 1.55 | sans, -.01em, line height 1.2 |
| `text.h2` | `.detail-section h2` | sans, 20 px, bold, line height 1.55 | 600, line height 1.25 |
| `text.h3` | `.plugin-title-line h3` | sans, 16 px, bold, line height 1.55 | 600, line height 1.3 |
| `text.subheading` | `.intro` | sans, 16 px, 400, line height 1.75 | |
| `text.body` | `body` | sans, 15 px, 400, line height 1.55 | |
| `text.bodyStrong` | `.check-list strong` | sans, 15 px, 650, line height 1.55 | 600 |
| `text.hint` | `.check-list small` | sans, 13 px, 400, line height 1.55 | |
| `text.eyebrow` | `.page-eyebrow` | mono, 11 px, 700, .18em, uppercase, line height 1.55 | line height 1 |
| `text.label` | `.code-head` | mono, 11 px, 500, .08em, uppercase, line height 1.55 | line height 1 |
| `text.button` | `.button` | mono, 11 px, 400, .08em, uppercase, line height 1.55 | 500, line height 1; `Button` draws the variant's weight |
| `text.kbd` | `.sidebar-search kbd` | mono, 11 px, 600, .02em, line height 1 | |
| `text.code` | `.code-block pre` | mono, 13 px, 500, line height 1.65 | |
| `text.tooltip` | `.control-tooltip` | sans, 11 px, 600, 0em, line height 1.3 | mono, with the rest of the chrome |
| `text.bar` | `.sidebar-brand`, `.button` | mono, 12 px, 700, .04em, uppercase; `.button` .08em | 500, .08em, line height 1 |

## Component spacing

Each value is read from one rule of the stylesheet. A measured value is the resolved default in pixels, as `ThemeLogic.accept` answers it for an empty document; "line" is the text's own line box. The reference draws square corners, so every radius is 0 except a round indicator's. The last column names where a component departs from its rule.

| Component | Height | Padding X | Gap | Radius | Token | Reference rule | Reference value | Departs |
|---|---|---|---|---|---|---|---|---|
| `Button` md, `ToggleButton` | 30 | 9 | 7 | 0 | `size.control.md`, `button.paddingX`, `button.gap` | `.card-install` | min-height 30, padding 0 9, gap 7 | |
| `Button` sm | 24 | 9 | 7 | 0 | `size.control.sm`, `button.paddingX`, `button.gap` | `.tag` | min-height 28, padding 0 9 | 24 tall |
| `Button` lg | 36 | 9 | 7 | 0 | `size.control.lg`, `button.paddingX`, `button.gap` | `.button` | min-height 36, padding 0 13, gap 7 | padding 9 |
| `IconButton` | 30 | 7 | | 0 | `size.control.md`, `icon.size.md` | `.search-clear` | 30 × 30, padding 0 | square, the 16 px icon centred |
| `TextField` | 30 | 9 | 7 | 0 | `textField.height`, `textField.paddingX`, `textField.gap` | `.search-term` | height 30, padding 0 7 0 9, gap 7 | 9 on the right |
| `Select` | 30 | 9; 30 on the right, past the chevron | 7 | 0 | `textField.height`, `textField.paddingX`, `textField.gap` | `.sort-control select` | padding 0 34 0 12 | 9 and 30 |
| `SegmentedControl` | 30 | 2 inset | 2 | 0 | `segmented.height`, `segmented.padding`, `segmented.gap` | `.catalog-view-mode` | gap 4 | inset 2, gap 2 |
| a segment | 26 | 9 | | 0 | `segmented.paddingX` | `.catalog-view-mode button` | min-height 29, padding 0 9 | 26 tall: 30 less the inset |
| `ListItem` | 36 | 12 | 7 | 0 | `listItem.height`, `listItem.paddingX`, `listItem.gap` | `.field-row` | min-height 45, padding 0 12 | 36 tall |
| `MenuItem` | 30 | 12 | 7 | 0 | `menu.item.height`, `menu.item.paddingX`, `menu.item.gap` | `.aside-link` | min-height 32, padding 5 0 5 12 | 30 tall |
| a `Select` list entry | 30 | 12 | | 0 | `menu.item.height`, `menu.item.paddingX` | `.aside-link` | min-height 32, padding 5 0 5 12 | 30 tall |
| `Field`, inline | the control's | 12 | 12 after a 130 label; 4 between lines | | `field.paddingX`, `field.labelWidth`, `field.labelGap`, `field.gap` | `.field-row` | padding 0 12, columns 130px 1fr 70px, gap 12 | no third column; the 4 px line gap has no rule |
| `SectionHeader` | its lines, 8 above, 4 below | 0; 12 where the surface insets its rows | 4 | | `sectionHeader.paddingTop`, `sectionHeader.paddingBottom`, `sectionHeader.gap` | `.listing-checks h3` | min-height 40, padding 0 13 | no height floor; the 4 px line gap has no rule |
| `Badge` | 20 | 4 | 7 | 0 | `badge.height`, `badge.paddingX`, `badge.gap` | `.listing-check-status` | min-height 20, padding 2 7 0 | padding 4 |
| `Kbd` | line + 4 | 2 | | 0 | `kbd.paddingX` | `.sidebar-search kbd` | padding 3 7 | padding 2 |
| `Tabs` | 30 | 4 | 8 between tabs | | `tabs.height`, `space.xs`, `tabs.gap` | `.market-nav a` | height 32, padding 0 10 | 30 tall, padding 4 |
| `Tooltip` | line + 4 | 6 | 4 from the anchor | 0 | `tooltip.paddingX`, `tooltip.paddingY`, `tooltip.gap` | `.control-tooltip` | padding 5 7 | padding 2 6 |
| `Toast` | content + 16 | 8 | 7 between icon, text and close; 6 between toasts | 0 | `toast.padding`, `toast.contentGap`, `toast.gap` | `.toast` | padding 9 12 | padding 8 |
| `Checkbox`, `Radio`, `Switch` | indicator 16, 16, 36 × 20 | | 7 | 0; round for `Radio` and `Switch` | `checkbox.gap`, `radio.gap`, `toggle.gap` | none | | |
| `Slider` | 14 handle, 4 track | | | round | `slider.handle`, `slider.track` | none | | |
| `Popover` | content + 16 | 8 | 4 from the anchor | 0 | `popover.padding`, `popover.gap` | none | | |
| `Menu` | items + 4, at least 160 wide | 2 | 4 from the anchor | 0 | `menu.padding`, `menu.gap`, `menu.minWidth` | none | | |
| bar item, a workspace pill | line + 4 | 6 | 4 between items | 0 | `bar.item.paddingX`, `bar.item.gap` | `.market-nav a` | height 32, padding 0 10 | sized to the bar |
| the bar's manager button | line + 4 | 6 | 7 | 0 | `bar.item.paddingX`, `bar.item.iconGap` | `.card-install` | gap 7 | sized to the bar |
| the bar | 26 | 12 | 8 | | `bar.height`, `bar.padding`, `bar.gap` | `.market-toolbar` | min-height 44 | 26 tall |
