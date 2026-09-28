# D015: Tokens are a JavaScript table judged by pure functions and published as frozen objects

[← Decision Index](INDEX.md)

**Date**: 2026-09-26

**Status**: Active (a plugin-owned look → D023)

**Research**: —

**Context**: A later themes plugin must be able to change every value the shell draws with: colours, component values, geometry and fonts. The previous shell held five palette colours in one singleton and its structural values in another, with the status colours and every spacing literal beyond a theme's reach. A theme file needs a judge that scripts can run too, and plugin authors need one name for every value.

**Decision**: `shell/Commons/Tokens.js` declares one table of typed leaves with default expressions, the `vgs` theme. `shell/Commons/ThemeLogic.js` is the one judge: it takes the table as an argument, parses and resolves a document in one call and answers every value or one keyed refusal, and node runs the same file through `scripts/qml-library.js`. `Theme.qml` converts the accepted values once and publishes each top-level group as a deep-frozen object of primitives through a read-only property, colours as `#aarrggbb` strings, with a `revision` counter that rises after the last group holds a new theme. The judge multiplies every duration by `motion.scale` after the duration's own expression resolves. The shell document holds shell tokens only. The expression grammar is a literal, a reference and four functions; it evaluates no JavaScript from a document.

**Rationale**:

- One table fixes each value's type and name once. The judge fixes the type at run time and `scripts/check-design-tokens.py` fixes the name at check time, with no generator and no generated file.
- Typed QML properties generated from the table were rejected: both designs answer `undefined` for a bad name at run time, and a generator adds a build step and a generated file to review.
- Frozen objects published whole make a theme change one assignment per group, and a write from a plugin a no-op, without a second copy of the values. A colour value inside a frozen object keeps a channel write, so colours are strings.
- Scaling durations after resolution keeps reduced motion effective for a theme that states its own timing.
- A judge with no Qt dependency tests in milliseconds under node, as [D009](D009-one-manifest-judge-under-node.md) chose for manifests.

**Revisit When**: An editor resolves `qs` modules for plugin authors and typed properties would give completion, or a decision needs a QML type node cannot host. A plugin that owns its look draws from its own table, judged by the same functions, instead of from shell tokens: [D023](D023-plugin-owned-appearance.md).

**Verification**: `scripts/test-theme-logic.js` pins every default, every refusal key and the derived colours, with one control per rule; `scripts/check-design-tokens.py` refuses an unknown token path and a literal in shipped QML; `scripts/smoke/rows/theme.sh` reads the revision and the published values back from a running shell.

**References**: [D006](D006-two-configuration-layers.md), [D009](D009-one-manifest-judge-under-node.md), [D016](D016-bundled-variable-font.md)
