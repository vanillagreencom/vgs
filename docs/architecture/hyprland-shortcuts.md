# Hyprland shortcuts

Covers: shell/Core/ShortcutRegistry.qml, shell/Core/PluginLogic.js, shell/Core/HyprlandLayer.js, scripts/test-hyprland-layer.js, scripts/qml-tests/tst_shortcutregistry.qml

Key normalization and effective key reads share the generated [Hyprland layer](hyprland.md). [D059](../decisions/D059-keycodes-and-effective-shortcut-keys.md) records this boundary.

## Key syntax

A key is written `MOD+MOD+KEY`, with the modifiers `SUPER`, `CTRL`, `ALT` and `SHIFT`. `PluginLogic.hyprlandKey` orders modifiers, uppercases keysyms and normalizes a numeric keycode to lower-case `code:<n>` without leading zeros. It accepts decimal digits in Hyprland's unsigned 32-bit range.

A bind takes the key the plugin's `plugins[].keys` entry gives its shortcut, [configuration.md § shell.json keys](configuration.md#shelljson-keys), else the manifest's. A hand edit or the Settings window's Keys rows write that entry, [manager.md](manager.md). A `null` entry unbinds it and leaves `-- unbound <id>:<shortcut>: shell.json sets its key to null`.

## Shortcut key reads

`shell.shortcut.keys` is a read-only, bindable map for the calling plugin: shortcut name to normalized key. Declared shortcuts have `null` when unbound or skipped by a conflict. Undeclared names, including registered names without a manifest bind, are absent. Each read returns a new prototype-free map; changing that copy affects no configuration, bind or other instance.

`Registry.hyprlandSections` holds the enabled manifests' `PluginLogic.hyprlandSection` results. The renderer, overlay capture and `ShortcutRegistry` use `HyprlandLayer.resolveBinds` for the same conflict decision. Reads follow configuration, enablement and manifest updates. They describe the shell's generated layer, not user Lua overrides after its loading line or physical keyboard labels.

`scripts/test-hyprland-layer.js` pins the keycode grammar and effective maps with controls. `scripts/qml-tests/tst_shortcutregistry.qml` reads the actual provider through a QML binding. `scripts/smoke/rows/hyprland.sh` reads a fixture's default, rebound and unbound key from its running instance, plus the compositor's registered bind and configuration errors.
