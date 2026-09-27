# Design system

Covers: shell/Commons/Tokens.js, shell/Commons/ThemeLogic.js, shell/Commons/Theme.qml, shell/Commons/ThemeSource.qml, shell/assets/**, scripts/check-design-tokens.py, scripts/test-check-design-tokens.py, scripts/test-theme-logic.js, scripts/qml_source.py, scripts/smoke/rows/theme.sh, tools/byte-ceiling-excludes

Every value the shell draws with is a token: one table, one judge, one singleton. A theme is a document that overrides tokens. First-party plugins and third-party plugins read the same singleton, so one theme restyles every surface, and nothing a user sees is a literal in code.

## Layers

Each layer reads only the layer above it.

1. The table and the judge, `shell/Commons/Tokens.js` and `shell/Commons/ThemeLogic.js`: plain JavaScript with no Qt object and no I/O. Node runs the same files through `scripts/qml-library.js`, so a script judges with the shell's own judge.
2. `Theme` in `qs.Commons`: the accepted values as QML values, one read-only, deep-frozen object of primitives per top-level group, plus `name` and `revision`. `ThemeSource.qml` owns the theme file and the accept call; `qmldir` marks it internal to the module, so no plugin can name it.
3. Every QML file that draws: it reads `Theme.<group>.<token>` and holds no literal style value.

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

## The shell document

`~/.config/vgs/theme.json` holds `{ "schemaVersion": 1, "name": "<theme>", "tokens": { <nested overrides> } }`. `ThemeLogic.accept` parses, judges and resolves it in one call and answers the name and every resolved value, or one refusal `{ ok: false, reason, token, detail }`, logged as `theme: refused: token=<path> reason=<key> ...` or `theme: refused: document reason=<key> ...`. One bad token refuses the whole document; nothing of a refused document is published and the last accepted theme stands. An absent file publishes the defaults, and a file removed while the shell runs does the same. The document holds shell tokens only; terminal colours and application overrides belong to a theme package, which lands with the themes plugin.

## Boundaries

- The table and the judge import nothing and take the table as an argument, so `scripts/test-theme-logic.js` runs them under node with no copy. Enforced by the `.pragma library` header `scripts/qml-library.js` requires.
- `Theme` publishes frozen objects of primitives through read-only properties. A write to `Theme.color.accent` or to a group from any file changes nothing. Enforced by `Object.freeze` in `Theme.convert` and by publishing no QML colour value, whose channels a frozen object cannot protect; `scripts/smoke/rows/theme.sh` reads every group back frozen and writes a token and a group.
- Shipped QML (`shell/Ui`, `shell/Hosts`, `shell/plugins`) and the vgs-plugin skill templates hold no literal colour, font, metric, opacity or duration, every radius reads a token, and every `Theme.<path>` anywhere under `shell/`, the templates and the smoke fixtures names a token. Enforced by `scripts/check-design-tokens.py`, whose header names each rule; `scripts/test-check-design-tokens.py` plants one violation per rule. `shell/Commons` and `shell/Core` draw nothing and a fixture's fixed geometry is what a placement row measures, so those trees are under the token rule alone.
- `vgs-plugin check` runs the same check on a third-party plugin: an unknown token fails it and a literal is a notice, since an author may choose one.
- The bundled font is `shell/assets/fonts/JetBrainsMono-Variable.ttf` with its licence beside it. `tools/byte-ceiling-excludes` exempts `shell/assets/` from the commit-guards byte ceiling. A theme names families and ships no font file; a family Qt does not list is logged as `theme: font=<family> unavailable` and the bundled family draws in its place.

## Invariants

1. Every default resolves, every refusal is reached by its key, and the derived colours equal values computed by hand. Enforced by `scripts/test-theme-logic.js`, with one control per judge rule in a copy of the judge.
2. `revision` rises by one after the last group holds a new theme, so a handler on `revisionChanged` reads one theme; a binding on a group reads the current one. A theme change rebuilds no component. Enforced by `scripts/smoke/rows/theme.sh`, which reads the revision, the bar's foreground and a derived component value back from a running instance.
3. Every top-level group of the table is a property of `Theme`. Enforced by the `group-unpublished` rule of `scripts/check-design-tokens.py` and read back frozen by `scripts/smoke/rows/theme.sh`.
4. A portable `#rrggbbaa` colour never reaches a QML property. Enforced by `Theme.toColor`, the one conversion, and by the `literal-color` rule for shipped QML.

## Decisions

- Tokens are a JavaScript table judged by pure functions and published as frozen objects, never generated QML properties: [D015](../decisions/D015-tokens-are-a-judged-table.md).
- One bundled variable font, so the default theme draws the same on every machine: [D016](../decisions/D016-bundled-variable-font.md).
