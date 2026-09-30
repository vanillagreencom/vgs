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

## Hold shortcuts

[D071](../decisions/D071-hold-shortcuts-use-a-release-companion.md) records the release-path choice.

A manifest bind may set `hold: true`; absent or `false` keeps an ordinary press bind. `PluginLogic.hyprlandError` refuses a non-boolean value. Key overrides preserve the hold declaration. An unbound or conflicting key produces neither bind.

The plugin supplies the optional fourth callback, `shell.shortcut.register(name, description, onPressed, onReleased)`. `ShortcutRegistry` owns both native objects under one instance disposer. The main object receives down. A `<name>.release` companion receives up through a second bind with `release`, `non_consuming`, `transparent` and `ignore_mods` set. A dot is outside the public registration-name grammar, so a plugin cannot claim the companion name. Both default and overlay-capture maps use the same renderer.

Only a down received by that registration with an available effective key starts a hold. The owner reads the current generated-layer key at the press, since Registry can change before Hyprland replaces its binds. A late press after unbind, conflict cancellation or section removal does nothing. Repeated down and unmatched up do nothing. Releasing another chord with the same terminal key cannot call an idle registration's callback. Changing the effective key, unbinding it or disposing the registration completes an active hold once. Disposal destroys both native objects even if the release callback throws. Ordinary callers keep their press-only behavior.

The release bind ignores the live modifier mask but does not consume client input. Plain Right Alt therefore reaches the focused client without starting a hold. This API does not authenticate physical input: a Wayland virtual keyboard can activate it.

`scripts/qml-tests/tst_shortcutregistry.qml` drives the shipped owner and its lifetime with controls in `scripts/test-qml-unit.sh`. `scripts/smoke/rows/hold-shortcuts.sh` sends physical keycodes on US, AltGr and swapped Right Alt layouts. It checks both modifier-release orders, plain-key client delivery, repeated input, early disposal and disable. Its controls drop modifier-independent release and virtual-keyboard delivery. [validation-smoke.md](validation-smoke.md) defines the shell-processed marker that orders negative reads and the healthy delayed controls.
