# Monitor rules and the monitors capability

Covers: shell/Core/MonitorLogic.js, shell/Core/MonitorState.qml, scripts/test-monitor-logic.js, scripts/smoke/rows/monitor-rules.sh, scripts/smoke/fixtures/plugins/acme.monitors

How the user's monitor rules reach Hyprland through the Hyprland layer, and what the `monitors` capability reads back and writes. The layer itself is [hyprland.md](hyprland.md); the Hyprland facts these rest on are [runtime-hyprland-monitors.md](runtime-hyprland-monitors.md). [D080](../decisions/D080-hyprland-options-rendered-from-data.md) records the choice.

## The document

`~/.config/vgs/monitors.json` (`Paths.configDir`) holds `{ "version": 1, "rules": [rule, ...] }`. The core reads it always, since the rules outlive any plugin, and reads it again when it changes. Only `write` writes it.

| Field | Value |
|---|---|
| `output` | The identifier, required. `MonitorLogic.identifier` makes it: `desc:<make> <model> <serial>` with every comma removed when Hyprland reads a serial, else the connector name, `DP-1`. Printable ASCII with no quote, backslash or comma, and no space at either end. |
| `disabled` | `true` turns the output off. A disabled rule holds `output` and `disabled` alone. `false` is dropped. |
| `mode` | `"WxH@R"`, R in Hz with up to three decimals. Required in an enabled rule. |
| `position` | `{ "x", "y" }`, whole numbers. Required in an enabled rule. |
| `scale` | A number from 0.25. Required in an enabled rule. |
| `transform` | 0 to 7. |
| `vrr` | 0, 1 or 2. |
| `mirror` | Another output's identifier or connector. |
| `bitdepth` | 8 or 10. |
| `cm` | `auto`, `srgb`, `dcip3`, `dp3`, `adobe`, `wide`, `edid`, `hdr` or `hdredid`. `hdr` and `hdredid` need `bitdepth` 10. |

- **Judge.** `MonitorLogic.judge` refuses an unknown key, a version other than 1, a field of the wrong type or range, two rules for one identifier, a scale that leaves fractional logical pixels (a mode side over the scale more than 0.001 from a whole number), and a mirror that names its own output. Each refusal is one line naming the first fault:
  - the document: `refused: monitors=<value> want=object`, `refused: monitors.key=<key> want=version,rules`, `refused: monitors.version=<value> want=1` or `refused: monitors.rules=<value> want=list`, and `refused: monitors=unparsed <error>` from `MonitorLogic.readDocument` for text that is no JSON;
  - one rule: `refused: rule=<i> <field>=<value> want=<what>`, as `refused: rule=0 scale=1.3 want=whole-logical-pixels mode=3840x2160`;
  - the rules together, against the outputs: `refused: rules=no-output-on want=one-output-on`.
- **Against the outputs.** `write` also judges the rules against the outputs Hyprland lists. A mirror must name another output that stays on. A listed output's mode must be one of its `availableModes`, refresh within 15 mHz, when it lists any; an output that lists none, as the nested Wayland output, takes any mode. At least one listed output must stay on: an output stays on when its rule is enabled, or when it has no rule and Hyprland lists it enabled. An output a user line holds off never stays on: Hyprland lists it disabled while the saved rules enable it, the case `overridden` reports, and a user line after the loading line wins over any rule the write adds. The same holds for a mirror's target. An output listed disabled that the saved rules disable, or do not name, is one the write may turn on. A rule for an output Hyprland does not list is kept for when it is plugged in.
- **Read from disk.** A document read from disk is judged on its own fields alone, so the layer never depends on whether a plugin reads the outputs. A document the judge refuses, or one the shell cannot read, is not applied: the layer writes one comment in the section's place and `listPlugins` and the Settings page report `hyprland: monitors: <reason>`.

## The layer section

The layer writes the rules after the session lock's restore and before every plugin section, headed `-- Monitors: the output rules monitors.json sets.`: one `hl.monitor` line per rule, in the document's order, each field written only when the rule sets it. A document with no rule, or none at all, writes no section. The first render waits until the document is read; an absent document counts as read (`HyprlandLayer.monitorInput`). A user line after the loading line still wins: Hyprland applies the last rule that names an output, and an `hl.monitor` for an output already named changes only the fields it sets.

## The capability

`monitors` is exclusive: one plugin holds it at a time, since the rules are a session-wide role ([D012](../decisions/D012-core-owns-lent-objects.md)). `MonitorState.qml` owns it in `Capabilities.qml`, beside `HyprlandState`. Each member read is bindable and each non-null read a frozen copy of its own.

| Member | What it holds |
|---|---|
| `outputs` | `hyprctl -j monitors all` as `MonitorLogic.parseOutputs` reads it: `[{ identifier, id, name, description, make, model, serial, width, height, refreshRate, x, y, scale, transform, vrr, disabled, mirrorOf, availableModes: [{ width, height, refresh }], currentFormat }]`, `mirrorOf` the mirrored output's name or null. Null until read and after a failed read. Read while a plugin holds `monitors`: on activation, on `monitoradded`, `monitoraddedv2`, `monitorremoved`, `monitorremovedv2` and `configreloaded`. |
| `saved` | The judged rules of the document, `[]` when it is absent, null while unread and while it is refused or unreadable. |
| `overridden` | The identifiers of saved rules whose listed output reads back otherwise, sorted; null while `outputs` is unread. An enabled rule is read by its mode (refresh within 15 mHz), position, scale (within a millionth), its transform when it sets one, and no mirror; a mirror rule by its mirror alone; a disabled rule by the output being off. `vrr` is not read: `monitors -j` prints whether adaptive sync runs now. An output Hyprland does not list is never overridden. |
| `writeState` | `{ phase, failure }`: `idle`; `saving` the document; `applying` it until the layer wrote and reloaded it and the outputs were read back; `failed` with the keyed failure of the save, the layer's cycle or the read. |
| `preview(rules, seconds)`, `confirm(token)`, `revert(token)`, `previewState` | Apply rules for a while without saving them, guarded by a detached process that restores the outputs at the deadline: [hyprland-monitors-preview.md](hyprland-monitors-preview.md#the-capability). |
| `write(rules)` | Judges `rules` against the current `outputs` and answers at once: `ok` once the save is queued, the judge's `refused: ...`, `refused: outputs=unread`, `refused: write=busy phase=<phase>` while a write runs, or `refused: monitors=<state> path=<path>` while the document on disk is refused or unreadable, so a hand edit is never overwritten unread. The save goes through `HyprlandLayer.qml`, the one writer of the layer, which writes and reloads whatever the bytes. |

The lending record's `monitors` holds `active`, whether the outputs are read, and `phase`.

## Invariants

1. Every decision about the document, the outputs reply, the rendered lines and `overridden` is made in `MonitorLogic.js`. Enforced by `scripts/test-monitor-logic.js`, on the reply the nested Hyprland printed and on outputs in the shape `getMonitorData` prints, each rule with a control on a copy of the file.
2. The section's text, its place after the session lock's restore and before every plugin section, its absence without a rule, the comment for a refused document, the wait for the first read and which layer step ends a write's cycle, and with what failure (`cycleEnd`), are decided in `HyprlandLayer.js`. Enforced by `scripts/test-hyprland-layer.js`, each with a control.
3. `monitors` is exclusive. Enforced by `scripts/test-plugin-logic.js`, whose control drops it from `EXCLUSIVE_CAPABILITIES`.
4. On the nested instance a scale-2 write at double the output's mode reads back from `hyprctl -j monitors` and from `outputs`, a fractional scale and turning off the only output are refused and leave the output on, the section sits after the session lock and before every plugin section, a later user line is reported in `overridden` and its removal clears it, a refused hand edit is reported and not applied, `configerrors` stays empty, and the fixture reads back exactly the nine members. Enforced by `scripts/smoke/rows/monitor-rules.sh`, which failed on a tree whose judge accepts fractional logical pixels.
