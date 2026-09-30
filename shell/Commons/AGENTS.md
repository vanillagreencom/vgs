# shell/Commons/

The singletons every QML file may read, module `qs.Commons`: `Theme`, `Paths`, `Time` and `Workspaces`, beside `WatchedFile`, the one reader of a file read on change. `Tokens.js` and `ThemeLogic.js` are the design system's table and judge, `docs/architecture/design-system.md`.

- `Tokens.js` and `ThemeLogic.js` are `.pragma library` files with no import of each other and no Qt object, so node runs them through `bin/lib/qml-library.js`. A token change is pinned in `scripts/test-theme-logic.js`; a new top-level group is a property of `Theme.qml`, which `scripts/check-design-tokens.py` enforces.
- `SessionLockState.js` is the one reading of whether Hyprland holds a session lock, from `hyprctl -j monitors`: a `.pragma library` file with no Qt object, read by the core's session lock, `vgs.lock` and, under node, the runner in `bin/vgsh`. `scripts/test-session-lock-state.js` pins it; `docs/architecture/lock-polkit.md` states its use.
- `ThemeSource.qml` is internal to the module and owns the theme file; `Theme.qml` publishes frozen objects of primitives and nothing else.
