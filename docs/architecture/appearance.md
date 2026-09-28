# Plugin-owned appearance

Covers: scripts/qml-tests/tst_appearance.qml, scripts/smoke/rows/launcher.sh, scripts/smoke/rows/notifications.sh

Most plugins draw from the shell's tokens, so a theme restyles them. A plugin whose design must look the same under every theme owns its look instead, and takes from the theme exactly three values: whether it is light or dark, its accent, and the motion scale. [D023](../decisions/D023-plugin-owned-appearance.md) records the choice; `shell/plugins/vgs.launcher` and `shell/plugins/vgs.notifications` are such plugins.

## The contract

- The manifest names `appearance`: a `.js` file inside the plugin, with the `.pragma library` header, that exports `TOKENS` and `LIGHT`. `PluginLogic.validateManifest` refuses any other path shape.
- `TOKENS` is a table in the `Tokens.js` leaf format, judged by the shell table's own rules and expression grammar ([design-system.md § Types and expressions](design-system.md#types-and-expressions)). Its `palette` group holds `accent` alone, a colour, and it holds `motion.scale`, a number; both are inputs, replaced by the active theme's.
- `LIGHT` is an overrides tree in theme-document shape. It names paths of `TOKENS`, sets neither input, and applies only while the theme's `scheme.mode` is `light`.
- `scheme.mode` is a shell token, `dark` or `light`, that a theme states; the shipped `light` package sets it. No component and no plugin infers a mode from a colour.
- A file reads the look as `Theme.appearance(TOKENS, LIGHT)`, bound once, conventionally to a property named `look`, and every value it draws with as `look.<path>`. A binding on it re-evaluates on a theme change and answers the same values for every theme with the same mode, accent and scale.
- The motion scale reaches every duration of the table as it reaches the shell's, so a user who stills the shell stills the plugin. An animation that is not a duration token, such as a continuous orbit, stops while the scale is 0.

## The judge

`ThemeLogic.acceptAppearance(table, light, theme)` judges the table and `LIGHT` in either mode, reads the inputs from `theme`, the active theme's resolved values, and resolves; it answers the values or one refusal whose reason is `appearance-table`, `appearance-palette`, `appearance-light`, `appearance-input`, `appearance-theme` or the resolver's own. `Theme.appearance` converts an accepted answer as the shell's groups are converted, deep-frozen, colours as `#aarrggbb` and a family never substituted; a refusal is logged as `appearance: refused: <token or document> reason=<key> ...` and answers null, and a plugin fails loudly on null rather than draw a look the judge did not accept.

## The style check

`scripts/check-design-tokens.py` holds a plugin that declares `appearance` to the contract, in the shell's trees and under `vgs-plugin check`:

- `appearance-refused`: the declared file throws as it loads, or the judge refuses it in dark or in light mode against the shell's defaults.
- `look-unknown`: a `look.<path>` names no path of the table.
- `theme-read`: a file reads a `Theme` member other than `appearance`. A bar entry takes the bar's colour from the `bar` API.
- The declared file is exempt from the literal rules, since the judge types each of its values. Every other file of the plugin stays under every literal rule, and a radius naming `look.` reads a token.

No plugin id is exempt, and no rule is bypassed by moving a value into settings.

## Invariants

1. No shell token but `scheme.mode`, `palette.accent` and `motion.scale` changes a plugin-owned look. Enforced by `scripts/test-theme-logic.js` and `scripts/qml-tests/tst_appearance.qml`, which move every other token and read the values back unchanged, and by `scripts/smoke/rows/launcher.sh` and `scripts/smoke/rows/notifications.sh` against the running plugins.
2. Every rule of the judge refuses its defect. Enforced by the appearance rows and controls of `scripts/test-theme-logic.js`.
3. Every appearance rule of the style check fires on its planted defect. Enforced by `scripts/test-check-design-tokens.py`.
