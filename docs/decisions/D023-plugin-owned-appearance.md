# D023: A plugin may own its look, taking the theme's mode, accent and motion scale alone

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active

**Research**: VGS-475

**Refines**: [D015](D015-tokens-are-a-judged-table.md)

**Context**: [D015](D015-tokens-are-a-judged-table.md) and the design system make every value a surface draws a shell token, so one theme restyles every surface. The owner's Spotlight launcher, and the notifications port after it, are designs that must look the same under every theme: a glass card whose neutrals, type and geometry are its own, lit by the theme's accent and switched by whether the theme is light or dark. Drawing them from shell tokens lets an unrelated palette, font or spacing change restyle them; drawing them from literals breaks the style check and hides each value from any judge.

**Decision**: A plugin whose manifest names `appearance`, a `.pragma library` file inside it, owns its look. The file exports `TOKENS`, a table in the `Tokens.js` leaf format, and `LIGHT`, overrides in theme-document shape. `ThemeLogic.acceptAppearance(table, light, theme)` is the one judge: the table must pass the shell table's own rules, its `palette` group holds `accent` alone, `LIGHT` must name the table's paths and may set no input, and the result resolves with the active theme's `palette.accent` and `motion.scale` as overrides and `LIGHT` applied only when the theme's `scheme.mode` is `light`. `scheme.mode` is a shell token, a `choice` of `dark` and `light` that a theme states, so no plugin infers a mode from a colour and there is no second theme source. `Theme.appearance(TOKENS, LIGHT)` answers the resolved values converted as the shell's groups are, or null after logging `appearance: refused: ...`. `scripts/check-design-tokens.py` holds such a plugin to it: the table must be accepted in both modes (`appearance-refused`), every `look.<path>` must name the table (`look-unknown`), no file reads a `Theme` member other than `appearance` (`theme-read`), and every file other than the table stays under every literal rule.

**Rationale**:

- The accent and the mode are the two theme values the design wants; naming them as the only inputs, by the paths the shell table already holds, makes a leak of any other theme value unrepresentable rather than a review finding.
- The motion scale is the reduced-motion control, not styling: taking it keeps a plugin still when the user stills the shell, through the judge's existing duration rule.
- One judge, the shell's own resolver over a second table, keeps every plugin value typed, ranged and expression-checked, runs under node for the style check and needs no second grammar.
- A literal allowance, a plugin-id exemption or values moved into settings would each hide the look from the judge; the table keeps it visible and checked.
- A mode inferred from the background's luminance was rejected: a theme can mean light with a mid-grey background, and every plugin would infer it on its own.

**Revisit When**: A plugin needs a third theme input, a component of `qs.Ui` gains a parameterized form that plugins with their own look share, or a theme needs to restyle such a plugin after all.

**Verification**: `scripts/test-theme-logic.js` pins every acceptance and refusal of `acceptAppearance`, with one control per rule; `scripts/qml-tests/tst_appearance.qml` moves every other shell token and reads the plugin's values back unchanged, and moves the mode, the accent and the scale; `scripts/test-check-design-tokens.py` plants one violation per appearance rule; `scripts/smoke/rows/launcher.sh` reads the launcher's look back from a running shell under an unrelated theme, an accent, light mode and a zero motion scale.

**References**: [D015](D015-tokens-are-a-judged-table.md), [D009](D009-one-manifest-judge-under-node.md), [D011](D011-native-manifest-no-cross-shell-compatibility.md)
