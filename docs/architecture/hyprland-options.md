# Hyprland options and the hyprland capability

Covers: shell/Core/HyprlandLayer.js, shell/Core/HyprlandState.qml, shell/Core/HyprlandState.js, shell/Core/Compositor.qml, shell/Core/Dispatch.js, scripts/test-hyprland-layer.js, scripts/test-hyprland-state.js, scripts/test-dispatch.js, scripts/smoke/rows/hyprland-options.sh, scripts/smoke/fixtures/plugins/acme.hyprland

How a plugin's settings set Hyprland input options through the Hyprland layer, and what the `hyprland` capability reads back. The layer itself is [hyprland.md](hyprland.md); the Hyprland facts these rest on are [runtime-hyprland-input.md](runtime-hyprland-input.md). [D080](../decisions/D080-hyprland-options-rendered-from-data.md) records the choice.

## Options

A manifest's `hyprland.options` maps a setting of its `schema` to an option path of the core's closed table, `HyprlandLayer.OPTIONS`:

| Path | Hyprland type |
|---|---|
| `input.kb_layout`, `input.kb_variant`, `input.kb_options` | string |
| `input.repeat_rate` | int, 0 to 200 |
| `input.repeat_delay` | int, 0 to 2000 |
| `input.numlock_by_default`, `input.natural_scroll`, `input.left_handed` | bool |
| `input.sensitivity` | float, -1 to 1 |
| `input.accel_profile` | string, `adaptive` or `flat` |
| `input.scroll_factor`, `input.touchpad.scroll_factor` | float, 0 to 2 |
| `input.touchpad.tap_to_click`, `input.touchpad.natural_scroll`, `input.touchpad.disable_while_typing`, `input.touchpad.clickfinger_behavior` | bool |
| `device.touchpad.enabled` | bool, written per touchpad through `hl.device` |

- **Judge.** `PluginLogic.hyprlandOptionsError` refuses a path outside the table, a path two settings name, a setting key that is not a setting name, a setting with no schema entry, and a manifest that maps options without capability `hyprland`. The entry must hold the path's values: a boolean for a bool; a number with `min` and `max` inside the path's range for an int or a float, whole bounds and step for an int; an enum within the choices for `accel_profile`; a string or an enum for any other string.
- **Written only when set.** `PluginLogic.hyprlandSection` lists an option only when the plugin's `plugins` row in the configuration sets its setting, so a default in the manifest is never written and an option the user never set keeps Hyprland's value and the user's own line. A value that does not fit its schema entry is listed as unfit. Every plugin kind but a bar widget reads that row, and the Settings page writes it.
- **Text.** A plugin whose row sets an option gets an options section just before its bind section, headed `-- <id> <version>: input options its settings set`: one `hl.config({ input = { ... } })` line holding every option written, nested by path in the manifest's order, then one `hl.device({ name = "<touchpad>", enabled = <bool> })` line per touchpad, then one comment for each option not written. The key is the Lua name, `tap_to_click`: Hyprland refuses the hyphenated `["tap-to-click"]`. A value reaches the text as a Lua literal: a fractional int is refused as `want=whole-number`, and a string holding a character outside `HyprlandLayer.OPTION_STRING`, which XKB names never need, as `want=characters:...`. A touchpad name holding a quote, a backslash or a control character is skipped.
- **Touchpads.** The touchpad names are the pointers `hyprctl devices` lists whose name holds `touchpad` or `trackpad`, Omarchy's rule. The first render waits while a section sets `device.touchpad.enabled` and devices are unread. A failed devices read releases the wait, writes a comment and reports a problem. When a completed read lists no touchpad, the section writes a comment, reports a problem and does not count the option as written.
- **Conflicts.** A path two plugins set stays with the first by id. The later option is a `-- skipped` comment, and every skipped or refused option reaches `listPlugins` and the Settings page as a `hyprland: ` problem.

## The capability

`hyprland` lends a plugin four members, each read bindable and each read a frozen copy of its own. `HyprlandState.qml` runs the reads while any plugin holds the capability, a key capture runs or an instance that asked the key capture who else holds a key lives ([hyprland-shortcuts.md § Key capture](hyprland-shortcuts.md#key-capture)), and stops them otherwise; `HyprlandState.js` judges every reply.

| Member | What it holds |
|---|---|
| `overridden` | The paths of the calling plugin's options the layer wrote whose `getoption` value differs, plus paths this plugin lost to an earlier plugin conflict. It is null until read and after a failed read. The read runs in one batch after each `configreloaded` and on activation. A user line after the loading line puts its path here when the value differs. `device.touchpad.enabled` has no `getoption` reading and is never listed. |
| `devices` | `hyprctl -j devices` as `{ mice: [{ name, touchpad }], keyboards: [{ name, layout, variant, options, activeKeymap, activeLayoutIndex, main }] }`, null until read, read again after `configreloaded`, after `activelayout`, which Hyprland posts when a keyboard comes, goes or switches layout, and when the files under `/dev/input` change, since Hyprland posts nothing when a pointer comes or goes. |
| `foreignBinds` | The keys bound in the default submap by something other than the layer, normalised as `hyprland.binds` keys are, sorted. It is null until read and after a failed read. A bind whose description is one the layer wrote is the layer's. A keycode bind and a bind with a modifier outside SUPER, CTRL, ALT and SHIFT are left out, since no key names them; mouse keys that Hyprland prints as names, such as `MOUSE_DOWN`, are kept. |
| `switchKeyboardLayout(target)` | Switches every keyboard: `next`, `prev`, or a layout index as a whole number or its decimal text. It runs `hyprctl switchxkblayout all <target>` as its own argument list, never through `hyprctl dispatch`, in the compositor's one queue, and answers `ok` once queued, `refused: dispatch-queue=full limit=32 request=[...]` when the queue is full, or `refused: layout=<target> want=next|prev|index`. Hyprland's reply is judged when it lands, as a dispatch's is. |

A failed read is logged as `hyprland: <reason>` and returns that member to null; a failed binds read also leaves its reason in `bindsFailure`, which the key capture reads and the next successful read clears, and `scripts/qml-tests/tst_hyprlandstate_binds.qml` pins it with mutations in `scripts/test-qml-unit.sh`. One unread `getoption` part marks that path overridden and logs the part error, while the other parts still update. The lending record's `hyprland.active` says whether the reads run.

## Invariants

1. A manifest's `hyprland.options` and the options its plugins row sets are decided in `PluginLogic.js`; the option table, the text, its order and the conflicts in `HyprlandLayer.js`. Enforced by `scripts/test-plugin-logic.js` for the judge and by `scripts/test-hyprland-layer.js` for the listing and the text, each rule with a control on a copy of its file.
2. Every reading of the capability is decided in `HyprlandState.js`, and the switch's argument list in `Dispatch.js`. Enforced by `scripts/test-hyprland-state.js`, on the reply shapes Hyprland printed, and `scripts/test-dispatch.js`, whose controls include a copy that routes the switch through `hyprctl dispatch`.
3. On the nested instance an option the fixture's plugins row sets reads back through `getoption`, an unset option keeps Hyprland's default with `set: false`, a later user line is reported in `overridden`, a user bind on the fixture's key shows in `foreignBinds`, `switchKeyboardLayout('next')` moves `devices -j` from `English (US)` to `German`, `configerrors` stays empty, and the fixture reads back exactly the four members. Enforced by `scripts/smoke/rows/hyprland-options.sh`, which failed on a shell copy that writes the defaults of unset options.
