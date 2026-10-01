# D080: Hyprland options and monitor rules are rendered from data and written only when set

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: VGS-694, VGS-695; plan [v2-system-plan.md](../plans/v2-system-plan.md) §2.6, §3.6, §3.7, §7 and its review [v2-system-plan-review.md](../plans/v2-system-plan-review.md) M3, M4, M14

**Refines**: [D028](D028-one-generated-hyprland-layer.md)

**Context**: The Mouse and Keyboard settings set Hyprland input options: pointer speed, scrolling, touchpad behaviour, layouts and key repeat. [D028](D028-one-generated-hyprland-layer.md) lets no plugin write Hyprland configuration, and its layer rendered binds, layer rules and theme appearance alone; its revisit condition, "a plugin needs a Hyprland setting other than a bind or a blur rule", is met. The settings also need to read Hyprland back: which of their options a user's own line overrides, which input devices exist, which keys something else binds, and a keyboard layout switch. `switchxkblayout` is a top-level `hyprctl` command, while the compositor provider sends `hyprctl dispatch <request>`, so it cannot be a dispatcher entry.

**Decision**: The core renders Hyprland settings a plugin asks for from data, and writes each only while the user's configuration sets it. [hyprland-options.md](../architecture/hyprland-options.md) is the contract.

- **Options as data.** A manifest's `hyprland.options` maps a schema setting to a path of a closed core table, `HyprlandLayer.OPTIONS`: the `input.*` and `input.touchpad.*` keys the Mouse and Keyboard settings need, plus a touchpad's `enabled`. `PluginLogic` type-checks the setting's schema entry against the path.
- **Written only when set.** An option is written while the plugin's `plugins` row sets its setting, never from the manifest's default. An option the user never set keeps Hyprland's value and the user's own line.
- **Rendered.** One `hl.config({ input = { ... } })` per plugin section, keyed by the Lua option name, values as judged literals, and one `hl.device` per touchpad Hyprland lists for the touchpad's `enabled`. A path two plugins set stays with the first by id.
- **Read back through a capability.** `hyprland` lends `overridden`, `devices`, `foreignBinds` and `switchKeyboardLayout(target)`. The switch runs `hyprctl switchxkblayout all <target>` as its own argument list in the compositor's queue, never through `hyprctl dispatch`.
- **Monitor rules follow the same rule.** The monitor rules the `monitors` capability adds (plan item S05) are rendered into the layer from data and written only while the user's monitor configuration sets them. [hyprland-monitors.md](../architecture/hyprland-monitors.md) is their contract.
- **One document, judged.** `~/.config/vgs/monitors.json` holds the rules, keyed `desc:<make> <model> <serial>` when Hyprland reads a serial, else by connector, as v1 keyed them (`bin/vshell_helper.py:13332-13342`). `MonitorLogic.judge` refuses fractional logical pixels, a mirror of itself or of an output that is not on, and, against the outputs Hyprland lists at write time, a mode the output does not list and turning off the last output. A document read from disk is judged on its own fields, so the layer never depends on whether a plugin reads the outputs.
- **One section, before the plugins.** The layer writes one `hl.monitor` per rule after its core sections and before every plugin section; a user line after the loading line still wins, and `overridden` names each rule Hyprland reads back otherwise.
- **An exclusive capability, one writer.** `monitors` lends `outputs`, `saved`, `overridden`, `writeState` and `write(rules)` to one plugin at a time. `write` saves the document and asks the layer's writer for a cycle; nothing else writes the layer or reloads Hyprland for it. `writeState` exists because `write` answers before the save, the layer's write and reload, and the read-back end.

**Rationale**:

- The layer stays the one place VGS writes Hyprland configuration, and no plugin text becomes Lua: a path comes from the core's table, a value is a literal of the path's type, and a string holds only the characters XKB names use.
- Writing only what the user set leaves every other option to Hyprland and to the user's own lines, so enabling a settings plugin changes nothing until the user changes a setting. A layer that wrote every default would replace Hyprland's value for each option the user never touched, and `overridden` would name a user's existing `input` line as overriding a setting the user never made. The smoke reads that failure on a shell copy that writes defaults.
- A closed table keeps the type check exact and keeps a plugin from setting an option VGS has not judged.
- Reading `overridden` back after each reload tells a page that a user's line wins, instead of letting a setting look applied while Hyprland holds another value. `foreignBinds` gives the Keys page the "Use my binding" choice (plan review M14).
- `switchxkblayout` is not a dispatcher, and Hyprland's Lua session refuses `hyprctl dispatch switchxkblayout`, so the switch takes its own argument list through the same queue (plan review M4).
- A monitor rule in the layer survives every reload, which an `hyprctl eval` rule does not, and Hyprland applies it whether or not the Displays plugin runs. A scale that leaves fractional logical pixels is moved by Hyprland to another scale, so the judge refuses it rather than let a written scale read back otherwise (v1 `:13371`). `overridden` does not read `vrr`: `monitors -j` prints whether adaptive sync runs now, which a rule cannot make true on an output without it.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| A plugin writes its own `hl.monitor` file and runs `hyprctl reload`, as v1's `outputs.lua` did | A second writer of Hyprland configuration, and a second loading line in `hyprland.lua`. |
| Each plugin runs `hyprctl eval` for its options | Every reload drops the value, plugin code would write Hyprland state at runtime, and two plugins could fight over an option with no place to settle it. |
| The layer writes every declared option, its default included | It would override the user's own `input` lines, and an untouched setting would still change Hyprland. |
| Free-form option paths in the manifest | No type check, and a plugin could set any Hyprland option VGS has not judged. |
| The layout switch as a dispatcher entry | `hyprctl dispatch` runs its request as Lua in a Lua session, where `switchxkblayout all next` is a syntax error. |

## Omarchy comparison

Checked against basecamp/omarchy `quattro` at `8b4eae6`, and at `c05d901` for the monitor rows: `config/hypr/monitors.lua`, `bin/omarchy-hyprland-monitor-internal`, `bin/omarchy-hyprland-monitor-internal-mirror`, `config/hypr/input.lua`, `default/hypr/input.lua`, `default/hypr/toggles.lua`, `default/hypr/disabled-input-device.lua`, `bin/omarchy-toggle-input-device`, `bin/omarchy-hw-touchpad` and `shell/plugins/bar/widgets/KeyboardLayout.qml`.

| Omarchy | VGS | Where VGS takes it, or why it differs |
|---|---|---|
| The user edits `~/.config/hypr/input.lua`, whose commented `hl.config({ input = { ... } })` block overrides Omarchy's defaults in `default/hypr/input.lua`. | The Settings page writes `shell.json`; the layer renders an `hl.config({ input = ... })` from it. | Taken: the same Lua table, loaded before the user's lines, so the user's own lines win. VGS writes no default: Omarchy owns the whole configuration, VGS one line of the user's (D028). |
| The touchpad toggle stores the device name as data and `disabled-input-device.lua` runs `hl.device({ name = name, enabled = false })` on every reload; the name comes from `hyprctl devices -j`, a mouse whose name matches `touchpad` or `trackpad`. | The layer writes `hl.device` per touchpad from the same `hyprctl devices` rule. | Taken: the name rule and per-device `enabled`. A name reaches the Lua only when it holds no quote, backslash or control character, the injection Omarchy's comment warns of. |
| The keyboard widget runs `hyprctl switchxkblayout <keyboard> <index>` per keyboard sharing the layout list, and reads `hyprctl -j devices` on `activelayout` and `configreloaded`. | `switchKeyboardLayout` runs `hyprctl switchxkblayout all <target>`; `devices` is read on the same two events. | Taken: the events, and the switch as a command, never a dispatch. VGS moves every keyboard with `all` as the plan states; a caller that wants Omarchy's convergence passes an absolute index, which `all` applies to every keyboard alike. |
| `config/hypr/monitors.lua` is the user's own file: a default `hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })` and commented per-output examples keyed by connector. Its toggles write one generated `hl.monitor` line to a state file (`bin/omarchy-hyprland-monitor-internal`, `-internal-mirror`), refuse a name outside `^[A-Za-z0-9._-]+$`, refuse turning off the only active display, and run `hyprctl reload`. | `monitors.json` holds the rules as data; the layer renders one `hl.monitor` per rule, and `write` judges and saves them. | Taken: rules as `hl.monitor` lines Hyprland reloads, a later user line still winning, the refusal to turn off the last display and a name check before Lua. VGS keys a rule by `desc:` when the output has a serial, since a connector changes with the port, and judges every field, since a Displays page writes every output's mode, scale and position where Omarchy writes two toggles. |

**Revisit When**: a settings plugin needs a Hyprland option outside the table, a monitor field outside the document's (the SDR and ICC fields v1 wrote), Hyprland reports a rule's `vrr` setting rather than live adaptive sync, Hyprland gains a Lua or event interface that lists input devices or reads an option's source, or Hyprland makes `switchxkblayout` a dispatcher.

**Verification**: `scripts/test-plugin-logic.js` pins each `hyprland.options` refusal, `scripts/test-hyprland-layer.js` the listing and the text, `scripts/test-hyprland-state.js` the readings and `scripts/test-dispatch.js` the switch's argument list, each rule with a control on a copy of its file. `scripts/smoke/rows/hyprland-options.sh` reads the nested Hyprland back: a set option through `getoption`, an unset one at Hyprland's default, `overridden`, `foreignBinds`, a layout switch in `devices -j`, an empty `configerrors` and the exact members; it failed on a shell copy that writes the defaults of unset options. `scripts/test-monitor-logic.js` pins each monitor rule refusal, the identifier, the outputs reply and `overridden`, and `scripts/test-hyprland-layer.js` the Monitors section and its place, each with a control. `scripts/smoke/rows/monitor-rules.sh` reads a scale-2 write back on the nested output, the refused fractional scale and last-output disable, a later user line in `overridden`, a refused hand edit and an empty `configerrors`; it failed on a tree whose judge accepts fractional logical pixels.

**References**: [D028](D028-one-generated-hyprland-layer.md), [D012](D012-core-owns-lent-objects.md), [D032](D032-settings-plugin-and-manifest-settings-convention.md), [hyprland-options.md](../architecture/hyprland-options.md), [runtime-hyprland-input.md](../architecture/runtime-hyprland-input.md), [hyprland-monitors.md](../architecture/hyprland-monitors.md), [runtime-hyprland-monitors.md](../architecture/runtime-hyprland-monitors.md)
