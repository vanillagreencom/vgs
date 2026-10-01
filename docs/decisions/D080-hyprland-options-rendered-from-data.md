# D080: Hyprland options and monitor rules are rendered from data and written only when set

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: VGS-694; plan [v2-system-plan.md](../plans/v2-system-plan.md) §2.6, §3.6, §3.7, §7 and its review [v2-system-plan-review.md](../plans/v2-system-plan-review.md) M3, M4, M14

**Refines**: [D028](D028-one-generated-hyprland-layer.md)

**Context**: The Mouse and Keyboard settings set Hyprland input options: pointer speed, scrolling, touchpad behaviour, layouts and key repeat. [D028](D028-one-generated-hyprland-layer.md) lets no plugin write Hyprland configuration, and its layer rendered binds, layer rules and theme appearance alone; its revisit condition, "a plugin needs a Hyprland setting other than a bind or a blur rule", is met. The settings also need to read Hyprland back: which of their options a user's own line overrides, which input devices exist, which keys something else binds, and a keyboard layout switch. `switchxkblayout` is a top-level `hyprctl` command, while the compositor provider sends `hyprctl dispatch <request>`, so it cannot be a dispatcher entry.

**Decision**: The core renders Hyprland settings a plugin asks for from data, and writes each only while the user's configuration sets it. [hyprland-options.md](../architecture/hyprland-options.md) is the contract.

- **Options as data.** A manifest's `hyprland.options` maps a schema setting to a path of a closed core table, `HyprlandLayer.OPTIONS`: the `input.*` and `input.touchpad.*` keys the Mouse and Keyboard settings need, plus a touchpad's `enabled`. `PluginLogic` type-checks the setting's schema entry against the path.
- **Written only when set.** An option is written while the plugin's `plugins` row sets its setting, never from the manifest's default. An option the user never set keeps Hyprland's value and the user's own line.
- **Rendered.** One `hl.config({ input = { ... } })` per plugin section, keyed by the Lua option name, values as judged literals, and one `hl.device` per touchpad Hyprland lists for the touchpad's `enabled`. A path two plugins set stays with the first by id.
- **Read back through a capability.** `hyprland` lends `overridden`, `devices`, `foreignBinds` and `switchKeyboardLayout(target)`. The switch runs `hyprctl switchxkblayout all <target>` as its own argument list in the compositor's queue, never through `hyprctl dispatch`.
- **Monitor rules follow the same rule.** The monitor rules the `monitors` capability adds (plan item S05) are rendered into the layer from data and written only while the user's monitor configuration sets them.

**Rationale**:

- The layer stays the one place VGS writes Hyprland configuration, and no plugin text becomes Lua: a path comes from the core's table, a value is a literal of the path's type, and a string holds only the characters XKB names use.
- Writing only what the user set leaves every other option to Hyprland and to the user's own lines, so enabling a settings plugin changes nothing until the user changes a setting. A layer that wrote every default would replace Hyprland's value for each option the user never touched, and `overridden` would name a user's existing `input` line as overriding a setting the user never made. The smoke reads that failure on a shell copy that writes defaults.
- A closed table keeps the type check exact and keeps a plugin from setting an option VGS has not judged.
- Reading `overridden` back after each reload tells a page that a user's line wins, instead of letting a setting look applied while Hyprland holds another value. `foreignBinds` gives the Keys page the "Use my binding" choice (plan review M14).
- `switchxkblayout` is not a dispatcher, and Hyprland's Lua session refuses `hyprctl dispatch switchxkblayout`, so the switch takes its own argument list through the same queue (plan review M4).

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Each plugin runs `hyprctl eval` for its options | Every reload drops the value, plugin code would write Hyprland state at runtime, and two plugins could fight over an option with no place to settle it. |
| The layer writes every declared option, its default included | It would override the user's own `input` lines, and an untouched setting would still change Hyprland. |
| Free-form option paths in the manifest | No type check, and a plugin could set any Hyprland option VGS has not judged. |
| The layout switch as a dispatcher entry | `hyprctl dispatch` runs its request as Lua in a Lua session, where `switchxkblayout all next` is a syntax error. |

## Omarchy comparison

Checked against basecamp/omarchy `quattro` at `8b4eae6`: `config/hypr/input.lua`, `default/hypr/input.lua`, `default/hypr/toggles.lua`, `default/hypr/disabled-input-device.lua`, `bin/omarchy-toggle-input-device`, `bin/omarchy-hw-touchpad` and `shell/plugins/bar/widgets/KeyboardLayout.qml`.

| Omarchy | VGS | Where VGS takes it, or why it differs |
|---|---|---|
| The user edits `~/.config/hypr/input.lua`, whose commented `hl.config({ input = { ... } })` block overrides Omarchy's defaults in `default/hypr/input.lua`. | The Settings page writes `shell.json`; the layer renders an `hl.config({ input = ... })` from it. | Taken: the same Lua table, loaded before the user's lines, so the user's own lines win. VGS writes no default: Omarchy owns the whole configuration, VGS one line of the user's (D028). |
| The touchpad toggle stores the device name as data and `disabled-input-device.lua` runs `hl.device({ name = name, enabled = false })` on every reload; the name comes from `hyprctl devices -j`, a mouse whose name matches `touchpad` or `trackpad`. | The layer writes `hl.device` per touchpad from the same `hyprctl devices` rule. | Taken: the name rule and per-device `enabled`. A name reaches the Lua only when it holds no quote, backslash or control character, the injection Omarchy's comment warns of. |
| The keyboard widget runs `hyprctl switchxkblayout <keyboard> <index>` per keyboard sharing the layout list, and reads `hyprctl -j devices` on `activelayout` and `configreloaded`. | `switchKeyboardLayout` runs `hyprctl switchxkblayout all <target>`; `devices` is read on the same two events. | Taken: the events, and the switch as a command, never a dispatch. VGS moves every keyboard with `all` as the plan states; a caller that wants Omarchy's convergence passes an absolute index, which `all` applies to every keyboard alike. |

**Revisit When**: a settings plugin needs a Hyprland option outside the table, Hyprland gains a Lua or event interface that lists input devices or reads an option's source, or Hyprland makes `switchxkblayout` a dispatcher.

**Verification**: `scripts/test-plugin-logic.js` pins each `hyprland.options` refusal, `scripts/test-hyprland-layer.js` the listing and the text, `scripts/test-hyprland-state.js` the readings and `scripts/test-dispatch.js` the switch's argument list, each rule with a control on a copy of its file. `scripts/smoke/rows/hyprland-options.sh` reads the nested Hyprland back: a set option through `getoption`, an unset one at Hyprland's default, `overridden`, `foreignBinds`, a layout switch in `devices -j`, an empty `configerrors` and the exact members; it failed on a shell copy that writes the defaults of unset options.

**References**: [D028](D028-one-generated-hyprland-layer.md), [D012](D012-core-owns-lent-objects.md), [D032](D032-settings-plugin-and-manifest-settings-convention.md), [hyprland-options.md](../architecture/hyprland-options.md), [runtime-hyprland-input.md](../architecture/runtime-hyprland-input.md)
