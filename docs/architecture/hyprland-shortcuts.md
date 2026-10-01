# Hyprland shortcuts

Covers: shell/Core/ShortcutRegistry.qml, shell/Core/KeyCapture.qml, shell/Core/PluginLogic.js, shell/Core/HyprlandLayer.js, scripts/test-hyprland-layer.js, scripts/test-key-capture.js, scripts/qml-tests/tst_shortcutregistry.qml, scripts/qml-tests/tst_keycapture.qml

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

The setup-text inventory treats `hold` as boolean data, not user-facing prose. `scripts/test-check-user-commands.py` checks that every admitted manifest field has a classification and controls the hold flag's classification.

The plugin supplies the optional fourth callback, `shell.shortcut.register(name, description, onPressed, onReleased)`. `ShortcutRegistry` owns both native objects under one instance disposer. The main object receives down. A `<name>.release` companion receives up through a second bind with `release`, `non_consuming`, `transparent` and `ignore_mods` set. A dot is outside the public registration-name grammar, so a plugin cannot claim the companion name. Both default and overlay-capture maps use the same renderer.

Only a down received by that registration with an available effective key starts a hold. The owner reads the current generated-layer key at the press, since Registry can change before Hyprland replaces its binds. A late press after unbind, conflict cancellation or section removal does nothing. Repeated down and unmatched up do nothing. Releasing another chord with the same terminal key cannot call an idle registration's callback. Changing the effective key, unbinding it or disposing the registration completes an active hold once. Disposal destroys both native objects even if the release callback throws. Ordinary callers keep their press-only behavior.

The release bind ignores the live modifier mask but does not consume client input. Plain Right Alt therefore reaches the focused client without starting a hold. This API does not authenticate physical input: a Wayland virtual keyboard can activate it.

`scripts/qml-tests/tst_shortcutregistry.qml` drives the shipped owner and its lifetime with controls in `scripts/test-qml-unit.sh`. `scripts/smoke/rows/hold-shortcuts.sh` sends physical keycodes on US, AltGr and swapped Right Alt layouts. It checks both modifier-release orders, plain-key client delivery, repeated input, early disposal and disable. Its controls drop modifier-independent release and virtual-keyboard delivery. [validation-smoke.md](validation-smoke.md) defines the shell-processed marker that orders negative reads and the healthy delayed controls.

## Key capture

[D086](../decisions/D086-key-capture-passthrough-submap.md) records the choice; [hyprland.md](hyprland.md) holds the pass-through section the layer writes.

`shell.shortcut.capture` is the one key capture, owned by `KeyCapture.qml` for every instance. `begin(item)` makes ITEM the holder, ending an earlier holder's capture, and sends the pass-through `enter`; `end(item, reason)` ends the holder's capture and sends `leave`. The owner also ends it when the holder is destroyed and when the instance that began it is torn down. A begin while an earlier leave is unanswered waits to send its enter until that leave was answered, so the earlier capture's submap events never end the new one. The owner reads Hyprland's `submap` event: `passthrough` turns true once Hyprland reports the submap, and a change away from it ends the capture without a request, since Hyprland left it itself, as `timeout` once `timeoutMs` passed and as `compositor` before, with the submap name and the time held in the log. `failed` is true while the holder's enter was refused or answered with an error. `holder`, `passthrough`, `failed` and `ended`, the last capture's `{ item, reason }`, are bindable.

`keyFor(key, modifiers)` is `PluginLogic.capturedKey`: a Qt key event names a key as `hyprlandKey` writes it, a keypad key by its `KP_` keysym, a modifier pressed alone names the held modifiers, a key that types or edits text with no modifier but Shift is `text`, and a key outside both tables is unnamed, for the text entry. `conflicts(key, id, shortcut)` is `PluginLogic.keyConflicts` over the key each enabled plugin's bind asks for and the keys something other than the layer binds, HyprlandState's `foreignKeys` ([hyprland-options.md](hyprland-options.md)), with `binds`, that read's state, beside them: `unread`, `read` or `failed`. HyprlandState's reads stay on while a capture runs and while an instance that asked a question lives, and read again after each `configreloaded`; a question after a failed read asks once more. The key capture reads no `hyprctl` itself.

`scripts/test-key-capture.js` pins the key table, the bind reader and the conflict judge with controls. `scripts/qml-tests/tst_keycapture.qml` drives the owner against a recording `Compositor` stand-in, with mutations in `scripts/test-qml-unit.sh`.

## Key capture pass-through

The layer's section defines the `vgs:passthrough` submap, whose one bind is Escape, the `enter` and `leave` functions on `hl.__vgs_key_passthrough`, one timer, a `keybinds.submap` hook that arms the timer while the submap is current and forgets the entering window when it is not, and a `window.close` hook, and leaves the submap as it loads. [D086](../decisions/D086-key-capture-passthrough-submap.md) records the choice.

While the Settings key field captures, `KeyCapture.qml` asks for `enter` through `Compositor.passthrough`. The layer's `enter` refuses unless a window of the shell's class has the focus, and Hyprland then passes every key but Escape to that window. The owner sends `leave` on commit, focus loss and teardown. The layer leaves the submap on Escape, on the close of the window `enter` recorded, `HyprlandLayer.KEY_PASSTHROUGH.timeoutMs` after it entered, and each time it loads. `leave` resets only this submap, so an overlay that entered `vgs:capture` keeps it.

The layer's pass-through section is written byte for byte after the overlay keyboard capture section and before the session lock's restore; its submap's one bind is Escape, `enter` refuses a window of another class and `leave` resets only its own submap. Enforced by `scripts/test-hyprland-layer.js`, whose controls drop the section, move it, rebind Escape, make `leave` unconditional, drop the class check, the recorded window, the timer, the close hook and the reset on load. On the nested instance every exit [D086](../decisions/D086-key-capture-passthrough-submap.md) lists leaves the submap, a `hyprctl reload` included, each with a tree-copy control that keeps it: `scripts/smoke/rows/key-passthrough.sh`.
