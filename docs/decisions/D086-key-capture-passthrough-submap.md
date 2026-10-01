# D086: Key capture reaches the Settings window through a Hyprland pass-through submap

[← Decision Index](INDEX.md)

**Date**: 2026-10-01
**Status**: Active
**Research**: VGS-687
**Refines**: [D028](D028-one-generated-hyprland-layer.md), [D067](D067-overlay-keyboard-capture.md)
**API Contract**: `shell.shortcut.capture` offers `holder`, `passthrough`, `failed`, `ended`, `timeoutMs`, `begin(item)`, `end(item, reason)`, `keyFor(key, modifiers)` and `conflicts(key, id, shortcut)`; `qs.Ui` `ShortcutField` asks it and never dispatches.

## Context

The Settings window's Keys rows took a key as `MOD+KEY` text, so a user had to know the modifier spelling. [D077](D077-settings-schema-presets-and-row-rhythm.md) names key capture as its revisit condition. A field the user presses keys into needs every combo to reach the focused Settings window, but Hyprland runs a default-map bind before the focused client sees the key, so `SUPER+SPACE` opens the launcher instead ([runtime-hyprland-capture.md](../architecture/runtime-hyprland-capture.md)). A shell that changes how the compositor routes keys must never leave it changed: a stuck capture takes every bind away from the user.

## Decision

While a key field captures, Hyprland is in a second constant core submap of the generated layer, `vgs:passthrough`. Its one bind is Escape, which resets to the default map, so every other key reaches the focused window. The layer defines `enter`, which refuses unless a window of the shell's class has the focus and records that window, and `leave`, which resets only this submap, on the table `HyprlandLayer.KEY_PASSTHROUGH` names. `shell/Core/Dispatch.js` builds the two requests from that table, Lua-only and absent from `PLUGIN_DISPATCHERS`, and `Compositor.passthrough` sends them and hands back each answer.

One core owner, `shell/Core/KeyCapture.qml`, the `capture` member of the `shortcut` capability, holds the capture: which control captures, whether Hyprland reports the submap current, and whether the enter failed; for the conflict hint it keeps `HyprlandState.qml`'s binds read on and reads its answer. A begin while an earlier capture's leave is still queued waits to send its enter until that leave is answered, so the earlier capture's submap events never end the newer one. `PluginLogic.capturedKey` turns a Qt key event into the key `hyprlandKey` writes, so a captured combo is the string the text entry stores for the same keys; a key that types or edits text with no modifier but Shift is refused with a notice, since a bind on it would stop typing everywhere. `qs.Ui` `ShortcutField` draws the field, and the Settings Keys row uses it for every bind, keeping a text entry for a key the capture cannot name. The field says when the enter failed, so Hyprland's own binds still run, and when a capture ended at the timeout.

Each exit has an owner:

| Exit | Owner | Mechanism |
|---|---|---|
| Commit | Shell | The field ends with `commit`; the owner sends `leave` |
| Escape | Hyprland | The submap's Escape bind resets it; the owner reads the `submap` event and ends the capture |
| Focus loss | Shell | The field loses focus and ends with `focus`; the owner sends `leave` |
| Window close | Shell and Hyprland | The field's focus loss, its destruction or its instance's teardown sends `leave`, since a closing window ends the field's focus first; the layer's `window.close` hook, the killed-shell exit, resets the submap for the window `enter` recorded |
| Shell killed | Hyprland | The `window.close` hook |
| Timeout | Hyprland | One repeating `hl.timer`, armed while the submap is current, that disarms itself and calls `leave` after 10 s |
| Layer run | Hyprland | Each load of the layer, at start and at every `hyprctl reload`, resets the submap: a reload keeps the current submap and drops the timer |

The conflict hint names every other plugin shortcut whose bind asks for the same key, whether or not the layer's first-by-id rule gives it the key, and says when a bind outside the layer holds it, from the one binds read `HyprlandState.qml` owns ([D080](D080-hyprland-options-rendered-from-data.md)), or that the read failed. Nothing refuses the key.

## Rationale

- Hyprland owns bind precedence, so the pass-through starts in Hyprland, as the overlay capture of D067 does.
- A key no bind of the current submap matches goes to the focused surface. Hyprland refuses to enter a submap with no bind, so the submap needs one; Escape is that bind, and it works while the shell is wedged.
- The layer already owns one core submap. A second constant section keeps every Hyprland text in the generated file and every request in one judge.
- The compositor-side exits cover a shell that cannot act: a killed shell's window closes, and a wedged one times out or takes Escape.
- Every exit but the window close has one owner, so removing it in a tree copy leaves the submap held and the row proves it. A close keeps the shell's leave, since the field loses the focus as its window closes, and the `window.close` hook it shares with a killed shell is proven alone by the SIGKILL reading.
- The key grammar stays `hyprlandKey`'s: the capture table only names keys, and its result passes through that judge.

## Alternatives considered

- **Capture in Qt alone.** A combo a bind holds never reaches the window.
- **Unbinding the user's binds during a capture.** It rewrites user-owned configuration, and a crash would leave it rewritten.
- **A catch-all bind in the submap.** A catch-all runs a dispatcher instead of passing the key to the window.
- **A shell-side timeout and close watch alone.** A killed or wedged shell could not leave the submap.
- **A compositor-side focus hook beside the field's focus loss.** Hyprland sees only a move to another window, while the field's focus loss also covers a click elsewhere in the Settings window, which no compositor event reports; a hook would give the window move two owners, and a wedged shell is already covered by Escape and the timeout.

## Omarchy comparison

Omarchy, default branch `quattro` read on 2026-10-01, has no key capture control. A user rebinds by editing `~/.config/hypr/bindings.lua` with its `o.bind` and `o.rebind` helpers (`config/hypr/bindings.lua`, `default/hypr/helpers.lua`), and `omarchy-menu-keybindings` lists binds from `hyprctl binds` plus a source-derived cache, because Hyprland reports a Lua bind as dispatcher `__lua`. Omarchy owns the user's default bind file, so text editing serves it. VGS loads into a user-owned Hyprland configuration and gives every setting a control with no manual command ([D061](D061-no-manual-commands.md)), so it captures the keys in its Settings window and keeps the text entry for a key the capture cannot name.

**Revisit When**: Hyprland lets a focused client receive bound keys without a submap, Hyprland enters a submap that holds no bind, or Quickshell offers a key grab for application windows.

**Verification**: `node scripts/test-hyprland-layer.js` pins the section byte for byte, with a control per rule. `node scripts/test-dispatch.js` pins the two requests and their refusals, with controls. `node scripts/test-key-capture.js` pins the key table and the conflict judge, with controls. `scripts/qml-tests/tst_keycapture.qml` and `scripts/qml-tests/tst_shortcutfield.qml` pin the owner and the field, with mutations in `scripts/test-qml-unit.sh`. `scripts/smoke/rows/key-capture.sh` captures `SUPER+SPACE`, `CTRL+ALT+T` and `F5` in the nested sandbox and compares each stored string with the typed one, with a control that sends no enter. `scripts/smoke/rows/key-passthrough.sh` reads the submap left after each exit above, the reload included, each with a control that removes that exit.

**References**: [D028](D028-one-generated-hyprland-layer.md), [D067](D067-overlay-keyboard-capture.md), [D077](D077-settings-schema-presets-and-row-rhythm.md), [D061](D061-no-manual-commands.md), [hyprland.md](../architecture/hyprland.md), [hyprland-shortcuts.md](../architecture/hyprland-shortcuts.md), [runtime-hyprland-capture.md](../architecture/runtime-hyprland-capture.md), [components-fields.md](../architecture/components-fields.md)
