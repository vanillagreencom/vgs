# Design system

Covers: shell/Commons/Tokens.js, shell/Commons/ThemeLogic.js, shell/Commons/Theme.qml, shell/Commons/ThemeSource.qml, shell/assets/**, shell/Ui/foundation/**, shell/Ui/controls/**, shell/Ui/feedback/**, shell/Ui/layout/**, shell/Ui/overlay/**, shell/Ui/icons/**, shell/Ui/qmldir, shell/Core/Toasts.qml, shell/Hosts/ToastHost.qml, scripts/smoke/rows/overlays.sh, scripts/smoke/rows/toasts.sh, scripts/smoke/rows/gallery.sh, scripts/smoke/fixtures/plugins/acme.overlays/**, shell/plugins/vgs.gallery/**, shell/Ui/AGENTS.md, shell/Commons/AGENTS.md, scripts/check-design-tokens.py, scripts/test-check-design-tokens.py, scripts/test-theme-logic.js, scripts/qml_source.py, scripts/vendor-lucide, scripts/test-lucide-data.js, scripts/qml-unit.sh, scripts/test-qml-unit.sh, scripts/qml-tests/**, scripts/smoke/rows/theme.sh, tools/byte-ceiling-excludes

Every value the shell draws with is a token: one table, one judge, one singleton, and one component library that reads it. A theme is a document that overrides tokens. First-party plugins and third-party plugins read the same singleton and compose the same components, so one theme restyles every surface, and nothing a user sees is a literal in code.

## Layers

Each layer reads only the layer above it.

1. The table and the judge, `shell/Commons/Tokens.js` and `shell/Commons/ThemeLogic.js`: plain JavaScript with no Qt object and no I/O. Node runs the same files through `scripts/qml-library.js`, so a script judges with the shell's own judge.
2. `Theme` in `qs.Commons`: the accepted values as QML values, one read-only, deep-frozen object of primitives per top-level group, plus `name` and `revision`. `ThemeSource.qml` owns the theme file and the accept call; `qmldir` marks it internal to the module, so no plugin can name it.
3. The components in `qs.Ui`: every control extends a `QtQuick.Templates` type or a plain `QtQuick` item and supplies its `background`, `contentItem`, `indicator`, `handle` or `delegate` from tokens. The overlays are Quickshell popup windows; everything else imports no Quickshell module, and the unit runner stands in for the popup window, so all of it runs under `qmltestrunner` with no compositor. `shell/Ui/qmldir` is the component list; files sit under `foundation/`, `controls/`, `feedback/`, `layout/` and `overlay/`.
4. Every QML file that draws, a plugin's included: it composes components, reads `Theme.<group>.<token>` for what they do not cover, and holds no literal style value.

## Tiers

| Tier | Groups | Holds |
|---|---|---|
| Palette | `palette` | `background`, `foreground`, `accent`, `success`, `warning`, `danger`, `info` |
| Scale | `space`, `radius`, `border`, `opacity`, `motion`, `size`, `icon`, `font` | the spacing unit and its steps, radius steps, border widths, the disabled opacity, `motion.scale` with the durations and easings, control and panel sizes, icon sizes and stroke, font families and the base size |
| Semantic | `color`, `text` | colour roles derived from the palette; one typography role per kind of text, each with `family`, `size`, `weight`, `letterSpacing` in em, `lineHeight` and `uppercase` |
| Component | one group per component | every value a component draws with, derived from its own component first, so a theme that sets one fill keeps the text on it readable |

The token list is `Tokens.js`; no document copies it. A theme that sets the seven palette colours restyles every surface. `motion.scale` of 0 sets every duration to 0, a theme's own timing included; a wait that is not an animation is a `number` token in milliseconds.

## Types and expressions

| Type | Resolved value | Range |
|---|---|---|
| `color` | `#rrggbbaa`, alpha last; `Theme` publishes it as the string `#aarrggbb`, the order Qt reads, and a file that needs channels calls `Qt.color` on it | |
| `length` | whole pixels | 0 to 4096 |
| `number` | unitless | the range the token declares |
| `duration` | whole milliseconds; every duration resolves unscaled, then the published value is multiplied by `motion.scale` once | 0 to 10000 before the scale |
| `weight` | whole font weight | 100 to 900 |
| `family` | a font family name | non-empty |
| `flag` | `true` or `false` | |
| `easing` | one of `ThemeLogic.EASINGS` | |
| `choice` | one of the options the token declares | |

A value is a literal, a reference `{group.token}` to a token of the same type, or one call: `mix(a, b, t)` moves each channel of colour `a` toward `b` by `t` in sRGB; `alpha(c, a)` sets the alpha; `contrast(c)` is black or white, whichever has the higher WCAG contrast against an opaque `c`; `mul(n, k)` scales a number, length or duration. Calls nest to a depth of 8 and an expression holds at most 256 characters. The judge evaluates no JavaScript from a document.

## Components

- A control that takes a name (`variant`, `size`, `role`, `tone`, `level`) logs an error naming the component and the value for an unknown name and draws its default. A control draws `FocusRing` while `visualFocus` holds, so a keyboard user sees the ring and a pointer user does not. A control sets `Accessible.name` from its text; `IconButton` requires `label` and logs an error without one. A disabled control draws at `opacity.disabled`. Every animation reads a `motion` token, so `motion.scale` of 0 stills the shell.
- `Label` draws one typography role and sets both `font.weight` and `font.variableAxes`, since a variable font moves on the axis alone and a static family on the weight alone. Letter spacing is stated in em and set in pixels.
- The bar's built-ins draw their text in `text.bar`, a mono chrome role with line height 1, so a label's line box is the font's own height and centring the box centres the glyphs. `bar.item` holds each item's `paddingX`, the `gap` between the items of one widget and the `radius`: a workspace pill is its label plus `paddingX` a side, never narrower than `size.control.sm`, and its label's line height plus `space.xs` tall. Every built-in sits on the bar's vertical centre; `scripts/smoke/rows/bar.sh` reads the pills, their labels, the clock and the manager button back and holds each to it within one pixel.
- `Icon` draws Lucide path data from `shell/Ui/icons/Lucide.js`, written by `scripts/vendor-lucide` from the pinned `lucide-static` package with every primitive converted to path commands. The shape is drawn in the data's box and scaled as an item, so `icon.stroke` is the same number of pixels at every size.
- Radios under one parent are exclusive, as the template makes them. `TextField` draws its action buttons as children of the field, not of its background, because the control puts the background under itself and the input takes every press on it.
- An overlay (`Popover`, `Tooltip`, `Menu`, the list of `Select`) is a Quickshell `PopupWindow` anchored to the item that declares it, under its bottom-left edge with the theme's gap: its own surface, so it leaves a bar of any height. `Popover`, `Menu` and the list take a focus grab, so they hold the keys and close on a press outside and on Escape; `Tooltip` takes none, opens after `tooltip.delay` while the pointer rests, and stays closed while `OverlayState` counts an open overlay. `AnchorTracker` watches the anchor and its ancestors: a move updates the anchor and a hide closes the popup. `Menu` and `Select` hold their own keys, since the surface a control sits in may take no keyboard focus. [D018](../decisions/D018-overlays-are-quickshell-popups.md) records the choice.

## Text stack

Reading text draws in `font.family.sans`, the bundled Inter; chrome draws in `font.family.mono`, the bundled JetBrains Mono, at 11 to 13 px. The base `font.size` is the reference's body size, and every role's size is a factor of it. A single-line chrome role takes line height 1, so its line box is the font's own height. `scripts/qml-tests/tst_label.qml` restates every role's family and metrics and reads them back from a drawn `Label`; it fails when the table gains a role it does not restate.

### Reference values

Each role is read from one rule of the plugins.omarchy.org stylesheet, `assets/css/style.css?v=20260923-01`, fetched with curl. A value the rule does not set is the inherited one: `body` sets 15 px and line height 1.55, and an unstyled heading is bold. The last column names where the role departs from its rule.

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

## Gallery

`shell/plugins/vgs.gallery` is a first-party panel that draws every component in every variant and state, and every role of `Theme.text` in its typography section, read from the group itself, so a theme author previews a whole theme at once. It is built only while summoned; `scripts/smoke/rows/gallery.sh` summons it, reads its section and component counts back, shows a toast through its capability and hides it. A new component is added to the gallery in the same change.

## Toasts

`Toast` is the notice the core's toast stack, `shell/Core/Toasts.qml`, draws through `shell/Hosts/ToastHost.qml` on the focused screen; a plugin shows one through the `toasts` capability, [plugins.md § Capabilities](plugins.md#capabilities). `PluginLogic.toastOptions` judges the options and `PluginLogic.TOAST_VISIBLE_MAX` and `TOAST_QUEUE_MAX` are the ceilings; a theme sets the look, the corner and the default duration, never a ceiling. A toast's timer starts when it shows, so one that waited shows for its whole duration. Expiry, the user's close, the disposer and the instance's teardown all run the one release, which is idempotent. When the stack's screen goes, the shown toasts return to the front of the queue and show again on the next focused screen; with no screen, every toast waits. `scripts/smoke/rows/toasts.sh` reads each of these back from the lending record, the layer list and a click on the close button.

## The shell document

`~/.config/vgs/theme.json` holds `{ "schemaVersion": 1, "name": "<theme>", "tokens": { <nested overrides> } }`. `ThemeLogic.accept` parses, judges and resolves it in one call and answers the name and every resolved value, or one refusal `{ ok: false, reason, token, detail }`, logged as `theme: refused: token=<path> reason=<key> ...` or `theme: refused: document reason=<key> ...`. One bad token refuses the whole document; nothing of a refused document is published and the last accepted theme stands. An absent file publishes the defaults, and a file removed while the shell runs does the same. The document holds shell tokens only; terminal colours and application overrides are package files under [themes.md](themes.md), not tokens.

## Boundaries

- The table and the judge import nothing and take the table as an argument, so `scripts/test-theme-logic.js` runs them under node with no copy. Enforced by the `.pragma library` header `scripts/qml-library.js` requires.
- `Theme` publishes frozen objects of primitives through read-only properties. A write to `Theme.color.accent` or to a group from any file changes nothing. Enforced by `Object.freeze` in `Theme.convert` and by publishing no QML colour value, whose channels a frozen object cannot protect; `scripts/smoke/rows/theme.sh` reads every group back frozen and writes a token and a group.
- Shipped QML (`shell/Ui`, `shell/Hosts`, `shell/plugins`) and the vgs-plugin skill templates hold no literal colour, font, metric, opacity or duration, every radius reads a token, and every `Theme.<path>` anywhere under `shell/`, the templates and the smoke fixtures names a token. Enforced by `scripts/check-design-tokens.py`, whose header names each rule; `scripts/test-check-design-tokens.py` plants one violation per rule. `shell/Commons` and `shell/Core` draw nothing and a fixture's fixed geometry is what a placement row measures, so those trees are under the token rule alone.
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
