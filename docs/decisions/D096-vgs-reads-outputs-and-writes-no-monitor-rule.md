# D096: VGS reads outputs and writes no monitor rule

[← Decision Index](INDEX.md)

**Date**: 2026-10-02

**Status**: Active

**Research**: VGS-744, VGS-707; owner ruling 2026-10-02 20:56Z

**Refines**: [D028](D028-one-generated-hyprland-layer.md)

**Context**: [D080](D080-hyprland-options-rendered-from-data.md) gave the core a monitor-rule writer: `~/.config/vgs/monitors.json`, a judge, an `hl.monitor` section in the Hyprland layer, an exclusive `monitors` capability with `write`, and a preview that a detached guard restored. The Displays pane that would have called them became a read-only pane (VGS-707). No pane writes a rule, and no release shipped the writer: 0.1.0 is unreleased.

**Decision**: Monitor settings belong to the user's own Hyprland config. VGS reads the outputs Hyprland lists and writes no monitor rule.

- **Read only.** Capability `monitors` lends one member, `outputs`: `hyprctl -j monitors all` as `MonitorLogic.parseOutputs` reads it, read again when an output comes or goes and after each reload. [hyprland-monitors.md](../architecture/hyprland-monitors.md) is the contract.
- **Shared.** `monitors` is no longer exclusive. Exclusivity served the one writer; a reading has no second writer to exclude, so every plugin that names it holds it.
- **No writer.** The core holds no `monitors.json`, no judge of monitor rules, no Monitors section in the layer, no preview and no guard. No file under `bin/`, `shell/` or `config/` holds an `hl.monitor` call or the text of one.
- **No reader for old rules.** No release wrote `monitors.json`, so the shell does not read, migrate or remove one. A file left by a development build is inert.
- **Supersedes the monitor half of D080.** D080's bullets "Monitor rules follow the same rule", "One document, judged", "One section, before the plugins", "An exclusive capability, one writer", "A preview is guarded outside the shell" and "The guard holds nothing of its caller's" no longer hold. Its options half stands.

**Rationale**:

- A user who sets a mode, a scale or a position already does so in `hyprland.lua`, where a line after the VGS loading line wins. A second place that also sets outputs gives two sources for one fact, and `overridden` existed only to report when they disagreed.
- A wrong mode can leave no usable screen. The writer needed a preview, a record, a detached guard and a transaction lock to make that recoverable. A shell that writes no rule needs none of them.
- The read-only pane (VGS-707) and VGS-711 read the output list and nothing else.
- The shell is one line of the user's Hyprland config ([D028](D028-one-generated-hyprland-layer.md)), not the owner of it.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Keep the writer for a later Displays page | No caller exists, and the owner ruled that monitor settings stay in the user's config. Unused code that can blank a screen is a cost with no user. |
| Keep the preview alone, as a way to try a mode | A preview with no save has no use, and it carries the whole guard. |
| Keep a reader that drops an old `monitors.json` | No release wrote one, so the reader would serve no user. |
| Keep `monitors` exclusive | Nothing the capability lends can conflict between two holders. |

## Omarchy comparison

Checked against basecamp/omarchy `quattro` at `c05d901`: `config/hypr/monitors.lua`, `shell/plugins/panels/monitor/Panel.qml`, `shell/plugins/panels/monitor/Model.js` and `bin/omarchy-hyprland-monitor-scaling`.

| Omarchy | VGS | Where VGS takes it, or why it differs |
|---|---|---|
| `config/hypr/monitors.lua` is the user's own file: a default `hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })`, commented per-output examples and `GDK_SCALE`. The user edits it. | The user's `hyprland.lua` sets every output. VGS ships no monitor file. | Taken: monitor settings are the user's own Hyprland lines. Omarchy ships the file because it owns the whole configuration; VGS owns one loading line (D028). |
| The monitor panel reads `omarchy-monitor-state` and shows each display, the brightness, the scale and the text size. It keeps no rule document of its own. | `monitors.outputs` gives a plugin the output list. | Taken: a panel that reads the outputs. |
| The panel's scale picker runs `omarchy-hyprland-monitor-scaling`, which applies one `hl.monitor` through `hyprctl eval` and rewrites the scale variable in the user's `monitors.lua`. Its display switch runs `hyprctl keyword monitor <name>,disable`, which no file keeps. | VGS changes no output. | Differs: Omarchy can edit `monitors.lua` because it shipped that file and knows its one variable. VGS does not know the shape of a user's `hyprland.lua`, so it cannot edit a monitor line there, and a rule it wrote elsewhere would be the second source this record removes. |

**Revisit When**: The owner asks for a Displays page that changes an output, or Hyprland gains an interface that sets an output's rule and reports which rule set each field.

**Verification**: `scripts/validate`'s `runtime_writes_no_monitor_rule` refuses an `hl.monitor` call in any file under `bin/`, `shell/` or `config/`; `scripts/test-validate.sh` plants one in a copy and reads the refusal. `scripts/test-hyprland-layer.js` holds that a rendered layer has no `hl.monitor` line, with a control on a copy of `HyprlandLayer.js`. `scripts/test-monitor-logic.js` pins the outputs reply and the identifier. `scripts/test-plugin-logic.js` holds that a second plugin naming `monitors` is lent it. `scripts/smoke/rows/monitor-outputs.sh` reads, in the nested sandbox, that the capability's members are `outputs` alone, that `outputs` follows a reload, and that the layer holds no `hl.monitor` call.

**References**: [D080](D080-hyprland-options-rendered-from-data.md), [D028](D028-one-generated-hyprland-layer.md), [D012](D012-core-owns-lent-objects.md), [hyprland-monitors.md](../architecture/hyprland-monitors.md), [runtime-hyprland-monitors.md](../architecture/runtime-hyprland-monitors.md)
