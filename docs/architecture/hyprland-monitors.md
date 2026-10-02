# The monitors capability

Covers: shell/Core/MonitorLogic.js, shell/Core/MonitorState.qml, scripts/test-monitor-logic.js, scripts/smoke/rows/monitor-outputs.sh, scripts/smoke/fixtures/plugins/acme.monitors

What the `monitors` capability reads from Hyprland and hands a plugin. VGS writes no monitor rule: the user's own Hyprland config sets every output. [D096](../decisions/D096-vgs-reads-outputs-and-writes-no-monitor-rule.md) records the choice. The Hyprland facts the reading rests on are [runtime-hyprland-monitors.md](runtime-hyprland-monitors.md).

## The capability

`MonitorState.qml` owns it in `Capabilities.qml`, beside `HyprlandState`. Any number of plugins hold it at once. It holds nothing per instance. The read is bindable, and each non-null read is a frozen copy of its own.

| Member | What it holds |
|---|---|
| `outputs` | `hyprctl -j monitors all` as `MonitorLogic.parseOutputs` reads it: `[{ identifier, id, name, description, make, model, serial, width, height, refreshRate, x, y, scale, transform, vrr, disabled, mirrorOf, availableModes: [{ width, height, refresh }], currentFormat }]`, in Hyprland's order, disabled outputs included. `mirrorOf` is the mirrored output's name or null. Null until read and after a failed read. |

- **When it reads.** The core reads the outputs while a plugin holds `monitors`: on activation, and on `monitoradded`, `monitoraddedv2`, `monitorremoved`, `monitorremovedv2` and `configreloaded`. A change that posts none of those events reaches `outputs` at the next one.
- **A failed read.** A reply `parseOutputs` refuses, or a `hyprctl` that fails, sets `outputs` to null and logs one line led by `monitors: `. The refusals are `refused: outputs=unparsed <error>`, `refused: outputs=shape want=list`, `refused: outputs=shape output=<i> field=<field>` and `refused: outputs=shape output=<i> mirrorOf=<value>`.
- **The identifier.** `MonitorLogic.identifier` names an output across ports: `desc:<make> <model> <serial>`, trimmed, with every comma removed, when Hyprland reads a serial, else the connector name, `DP-1`. It is the selector an `hl.monitor` line in the user's config takes for that output.
- **The lending record.** Its `monitors` holds `active`, whether the outputs are read.

## Invariants

1. Every decision about the outputs reply and the identifier is made in `MonitorLogic.js`. Enforced by `scripts/test-monitor-logic.js`, on the reply the nested Hyprland printed and on outputs in the shape `getMonitorData` prints, each rule with a control on a copy of the file.
2. No file an install ships from `bin/`, `shell/` or `config/` holds an `hl.monitor` call or the text of one. Enforced by `runtime_writes_no_monitor_rule` in `scripts/validate`, whose controls in `scripts/test-validate.sh` plant one call in a copy of the tree. A call assembled from parts, such as `"hl." + "monitor("`, is not matched.
3. The Hyprland layer holds no `hl.monitor` line. Enforced by `scripts/test-hyprland-layer.js`, whose control adds one to a copy of `HyprlandLayer.js`.
4. `monitors` is not exclusive. Enforced by `scripts/test-plugin-logic.js`, whose control adds it to `EXCLUSIVE_CAPABILITIES`.
5. On the nested instance the fixture reads back `outputs` as the capability's one member, `outputs` names every output Hyprland lists, a reload under a held scale-2 mode reaches `outputs`, and the layer holds no `hl.monitor` call. Enforced by `scripts/smoke/rows/monitor-outputs.sh`, which failed on a tree whose `MonitorState.qml` reads the outputs on no `configreloaded`.
