# Design system

Covers: shell/Commons/Tokens.js, shell/Commons/ThemeLogic.js, shell/Commons/Theme.qml, shell/Commons/ThemeSource.qml, shell/Commons/Inset.js, shell/Commons/ClearingInset.qml, shell/assets/**, shell/Ui/foundation/**, shell/Ui/controls/**, shell/Ui/feedback/**, shell/Ui/layout/**, shell/Ui/overlay/**, shell/Ui/icons/**, shell/Ui/qmldir, scripts/smoke/rows/gallery.sh, shell/plugins/vgs.gallery/**, shell/Ui/AGENTS.md, shell/Commons/AGENTS.md, scripts/check-design-tokens.py, scripts/test-check-design-tokens.py, scripts/test-theme-logic.js, scripts/test-inset.js, scripts/qml_source.py, scripts/qml-unit.sh, scripts/test-qml-unit.sh, scripts/qml-tests/**, scripts/smoke/rows/theme.sh, tools/byte-ceiling-excludes

Every value the shell draws with is a token: one table, one judge, one singleton, and one component library that reads it. A theme is a document that overrides tokens. First-party plugins and third-party plugins read the same singleton and compose the same components, so one theme restyles every surface, and nothing a user sees is a literal in code. A plugin that owns its look takes the theme's mode, accent and motion scale alone: [appearance.md](appearance.md).

## Layers

Each layer reads only the layer above it.

1. The table and the judge, `shell/Commons/Tokens.js` and `shell/Commons/ThemeLogic.js`: plain JavaScript with no Qt object and no I/O. Node runs the same files through `bin/lib/qml-library.js`, so a script judges with the shell's own judge.
2. `Theme` in `qs.Commons`: the accepted values as QML values, one read-only, deep-frozen object of primitives per top-level group, plus `name`, `revision` and `fileState`, the theme file's state as `ThemeSource` last read it (`pending`, `loaded`, `absent`, `refused`, `unreadable`), which a refused edit moves without a new revision. `ThemeSource.qml` owns the theme file and the accept call; `qmldir` marks it internal to the module, so no plugin can name it.
3. The components in `qs.Ui`: every control extends a `QtQuick.Templates` type or a plain `QtQuick` item and supplies its `background`, `contentItem`, `indicator`, `handle` or `delegate` from tokens. The overlays are Quickshell popup windows; everything else imports no Quickshell module, and the unit runner stands in for the popup window, so all of it runs under `qmltestrunner` with no compositor.
4. Every QML file that draws, a plugin's included: it composes components, reads `Theme.<group>.<token>` for what they do not cover, and holds no literal style value.

## Tiers

| Tier | Groups | Holds |
|---|---|---|
| Scheme | `scheme` | `mode`, `dark` or `light`, which no component reads: it picks a plugin-owned look's light values |
| Palette | `palette` | `background`, `foreground`, `accent`, `success`, `warning`, `danger`, `info` |
| Scale | `space`, `radius`, `border`, `opacity`, `motion`, `hyprland`, `size`, `icon`, `font` | the spacing unit and its steps, radius steps, border widths, the disabled opacity, `motion.scale` with the durations and easings, Hyprland border thickness, window radius, rounding power, motion preset and shadow colour, control, panel and window sizes, icon sizes and stroke, font families and the base size |
| Semantic | `color`, `text` | colour roles derived from the palette; one typography role per kind of text, each with `family`, `size`, `weight`, `letterSpacing` in em, `lineHeight` and `uppercase` |
| Rhythm | `control`, `row` | the horizontal padding and icon-and-text gap every one-line control shares; a row's horizontal padding, its inline label's width and gap, and the gap between a label and the line it names |
| Component | one group per component | every value a component draws with, derived from its own component first, so a theme that sets one fill keeps the text on it readable |

The token list is `Tokens.js`; no document copies it. A theme that sets the seven palette colours restyles every surface. `motion.scale` of 0 sets every duration to 0, a theme's own timing included; a wait that is not an animation is a `number` token in milliseconds. The `hyprland` group reaches only the generated Hyprland layer and only for the groups whose switches are on: [hyprland.md](hyprland.md).

## Types and expressions

| Type | Resolved value | Range |
|---|---|---|
| `color` | `#rrggbbaa`, alpha last; `Theme` publishes it as the string `#aarrggbb`, the order Qt reads, and a file that needs channels calls `Qt.color` on it | |
| `length` | whole pixels | 0 to 4096, unless the token declares its own `min` and `max` |
| `number` | unitless | the range the token declares |
| `duration` | whole milliseconds; every duration resolves unscaled, then the published value is multiplied by `motion.scale` once | 0 to 10000 before the scale |
| `weight` | whole font weight | 100 to 900 |
| `family` | a font family name | non-empty |
| `flag` | `true` or `false` | |
| `easing` | one of `ThemeLogic.EASINGS` | |
| `choice` | one of the options the token declares | |

A value is a literal, a reference `{group.token}` to a token of the same type, or one call: `mix(a, b, t)` moves each channel of colour `a` toward `b` by `t` in sRGB; `alpha(c, a)` sets the alpha; `contrast(c)` is black or white, whichever has the higher WCAG contrast against an opaque `c`; `mul(n, k)` scales a number, length or duration. Calls nest to a depth of 8 and an expression holds at most 256 characters. The judge evaluates no JavaScript from a document.

## Readability

`ThemeLogic.readabilityShortfalls` owns the contrast table for resting text, accent text and status text on resting surfaces. `scripts/check-theme-contrast.js` runs that table over the shipped `vgs` and `light` packages and every catalog entry, so a token default or converted theme that makes text unreadable fails offline validation. The table excludes hover surfaces and disabled text for the reasons in [theme-conversion.md § Readability](theme-conversion.md#readability).

## Components

What each component of `qs.Ui` guarantees is in [components.md](components.md).

## Text stack

Reading text draws in `font.family.sans`, the bundled Inter; chrome draws in `font.family.mono`, the bundled JetBrains Mono, at 11 to 13 px. The base `font.size` is the reference's body size, and every role's size is a factor of it. A single-line chrome role takes line height 1, so its line box is the font's own height. `text.item`, `text.itemHint` and `text.itemCode` are `body`, `hint` and `code` at line height 1, for one line of text in a control's row: a menu entry, a list item's two lines, a value beside its label. `scripts/qml-tests/tst_label.qml` restates every role's family and metrics and reads them back from a drawn `Label`; it fails when the table gains a role it does not restate. The reference rule each role is read from is [design-values.md § Text roles](../reference/design-values.md#text-roles).

## Component spacing

Every one-line control is `size.control.md` tall, with `control.paddingX` a side and `control.gap` between an icon and its text. Every row pads its content `row.paddingX` a side, and a row's inline label is `row.labelWidth` wide and `row.gap` from its control. A component token still names each value, derived from these, so a theme can move one component. Each component's measured height, padding, gap and radius beside the reference rule it follows is [design-values.md § Component spacing](../reference/design-values.md#component-spacing). `scripts/qml-tests/tst_spacing.qml` reads the rhythm back from drawn components under the defaults and under a theme that moves it. `scripts/smoke/rows/manager.sh` holds the Settings page's fields to one label edge and one control edge, [manager.md](manager.md).

Rectangular content inside a rounded container starts far enough in that each of its corners stays one spacing step inside the curve of the drawn corner, at the content's own distance from the top and bottom edges. Content lower in the container therefore needs less inset. Content within one step of the edge clears the whole corner. The drawn corner is `min(radius, width / 2, height / 2)`, and `shell/Commons/Inset.js` owns the calculation. A square corner keeps the component's normal padding. A round avatar, face stack or pill control may sit at the normal padding when its centre stays concentric with the rounded end. The notifications stack reads one text column for every card and for the inbox header: the inset of its tallest card, whose text starts `card.pad` from the top. The inset grows with the height, so the column also clears every shorter card, and the texts line up. `scripts/test-inset.js` checks the helper with controls. `scripts/qml-tests/tst_spacing.qml` checks `Toast`, and `scripts/smoke/rows/notifications.sh` checks the notifications cards and header in the sandbox.

## Gallery

`shell/plugins/vgs.gallery` is a first-party application window ([surfaces.md](surfaces.md)) that draws every component in every variant and state, and every role of `Theme.text` in its typography section, read from the group itself, so a theme author previews a whole theme at once. It is built only while summoned; `scripts/smoke/rows/gallery.sh` summons it, reads its section and component counts back, holds every example inside the window's right edge, shows a toast through its capability and hides it, then reads it as a Hyprland window. A new component is added to the gallery in the same change.

## The shell document

`~/.config/vgs/theme.json` holds `{ "schemaVersion": 1, "name": "<theme>", "tokens": { <nested overrides> } }`. `ThemeLogic.accept` parses, judges and resolves it in one call and answers the name and every resolved value, or one refusal `{ ok: false, reason, token, detail }`, logged as `theme: refused: token=<path> reason=<key> ...` or `theme: refused: document reason=<key> ...`. One bad token refuses the whole document; nothing of a refused document is published and the last accepted theme stands. An absent file publishes the defaults, and a file removed while the shell runs does the same. An edit that lands while the file is being read is read again, so the last save is the one drawn. The document holds shell tokens only; terminal colours and application overrides are package files under [themes.md](themes.md), not tokens.

## Boundaries

- The table and the judge import nothing and take the table as an argument, so `scripts/test-theme-logic.js` runs them under node with no copy. Enforced by the `.pragma library` header `bin/lib/qml-library.js` requires.
- `Theme` publishes frozen objects of primitives through read-only properties. A write to `Theme.color.accent` or to a group from any file changes nothing. Enforced by `Object.freeze` in `Theme.convert` and by publishing no QML colour value, whose channels a frozen object cannot protect; `scripts/smoke/rows/theme.sh` reads every group back frozen and writes a token and a group.
- Shipped QML (`shell/Ui`, `shell/Hosts`, `shell/plugins`) and the vgs-plugin skill templates hold no literal colour, font, metric, opacity or duration, every radius reads a token, and every `Theme.<path>` anywhere under `shell/`, the templates and the smoke fixtures names a token. Enforced by `scripts/check-design-tokens.py`, whose header names each rule; `scripts/test-check-design-tokens.py` plants one violation per rule. A plugin that owns its look reads it from its own table, under the rules [appearance.md § The style check](appearance.md#the-style-check) adds. `shell/Commons` and `shell/Core` draw nothing and a fixture's fixed geometry is what a placement row measures, so those trees are under the token rule alone.
- `vgs-plugin check` runs the same check on a third-party plugin: an unknown token fails it and a literal is a notice, since an author may choose one.
- The bundled fonts are `shell/assets/fonts/InterVariable.ttf`, which Qt names `Inter Variable`, and `shell/assets/fonts/JetBrainsMono-Variable.ttf`, each with its licence beside it. `tools/byte-ceiling-excludes` exempts `shell/assets/` from the commit-guards byte ceiling. A theme names families and ships no font file; a family Qt does not list is logged as `theme: font=<family> unavailable; drawing <bundled>` and the bundled family the token's default names draws in its place, so a sans role stays sans and a chrome role stays mono.

## Invariants

1. Every component the module lists instantiates with its defaults, and each guarantee a component states holds under pointer, keyboard and a theme change. Enforced by `scripts/qml-unit.sh` running `scripts/qml-tests/tst_*.qml` against the shipped module through a stand-in `ThemeSource` that calls the shipped `accept`; `scripts/test-qml-unit.sh` applies one mutation per guarantee to a copy of the module and requires its test to fail. The area is `unit`, which needs Qt and no Wayland session; `offline` leaves it out, while the default `all` area selects it when its inputs change.
2. Every default resolves, every refusal is reached by its key, and the derived colours equal values computed by hand. Enforced by `scripts/test-theme-logic.js`, with one control per judge rule in a copy of the judge.
3. `revision` rises by one after the last group holds a new theme, so a handler on `revisionChanged` reads one theme; a binding on a group reads the current one. A theme change rebuilds no component. Enforced by `scripts/smoke/rows/theme.sh`, which reads the revision, the bar's foreground and a derived component value back from a running instance.
4. Every top-level group of the table is a property of `Theme`. Enforced by the `group-unpublished` rule of `scripts/check-design-tokens.py` and read back frozen by `scripts/smoke/rows/theme.sh`.
5. A portable `#rrggbbaa` colour never reaches a QML property. Enforced by `Theme.toColor`, the one conversion, and by the `literal-color` rule for shipped QML.

## Decisions

- Tokens are a JavaScript table judged by pure functions and published as frozen objects, never generated QML properties: [D015](../decisions/D015-tokens-are-a-judged-table.md).
- Two bundled variable fonts, so the default theme draws the same on every machine: [D016](../decisions/D016-bundled-variable-font.md).
- Controls extend `QtQuick.Templates` and icons are path data drawn with `QtQuick.Shapes`: [D017](../decisions/D017-templates-and-path-icons.md).
- Overlays are Quickshell popup windows anchored to their item, not Qt window popups: [D018](../decisions/D018-overlays-are-quickshell-popups.md).
- A plugin may own its look, taking the theme's mode, accent and motion scale alone: [D023](../decisions/D023-plugin-owned-appearance.md).
