# shell/Commons/

The singletons every QML file may read, module `qs.Commons`: `Theme`, `Paths`, `Time` and `Workspaces`. `Tokens.js` and `ThemeLogic.js` are the design system's table and judge, `docs/architecture/design-system.md`.

- `Tokens.js` and `ThemeLogic.js` are `.pragma library` files with no import of each other and no Qt object, so node runs them through `scripts/qml-library.js`. A token change is pinned in `scripts/test-theme-logic.js`; a new top-level group is a property of `Theme.qml`, which `scripts/check-design-tokens.py` enforces.
- `ThemeSource.qml` is internal to the module and owns the theme file; `Theme.qml` publishes frozen objects of primitives and nothing else.
