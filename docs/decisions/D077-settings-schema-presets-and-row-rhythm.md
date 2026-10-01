# D077: Settings schema presets and one row rhythm

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: VGS-686

**Refines**: [D032](D032-settings-plugin-and-manifest-settings-convention.md), [D057](D057-setting-options-from-status.md), [D063](D063-design-scale-on-the-4-px-grid.md)

**Context**: Settings exposed format-like strings as free text and mixed shorter metadata rows with taller editable rows. A user had to know Qt date-format letters to change the bar clock, and the Settings page changed rhythm between rows that belonged to the same key/value grid.

**Decision**: A string schema entry declares either `presets` or `optionsFrom`. A preset string can allow Custom…, and a `format: "datetime"` value is judged before it writes. A number can declare `unit`, so the Settings page labels slider values. A short enum draws as a segmented control. Every inline key/value row uses `row.height` unless its control is taller. [plugin-manifest.md § Settings schema](../architecture/plugin-manifest.md#settings-schema) defines the schema keys. [settings-window.md § The window](../architecture/settings-window.md#the-window) defines the drawn controls.

**Rationale**:
- A picker lets a user choose a safe value without knowing a library syntax.
- Custom keeps power-user formats available while the manifest still names safe starting points.
- The manifest judge refuses a format-like string by one rule, not by guessing from a key name.
- A unit belongs to the setting contract, so every display of the number can use the same words.
- One row height makes metadata, switches, selects, segmented controls and sliders read as one table.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Keep free-text strings and add better descriptions | A description still asks the user to know Qt format syntax. |
| Add a keybind-capture control now | Key capture is a separate input problem. The Keys section keeps its `MOD+KEY` text field. |
| Keep compact metadata rows | The page reads as two row systems inside one key/value table. |
| Infer format strings from setting names | A name heuristic would be a second schema judge and would miss real producers. |

## Omarchy comparison

The read-only Omarchy reference at `basecamp/omarchy` uses a clock format ring in `shell/plugins/panels/clock/Model.js`. It offers fixed date and time formats and adds the configured alternate. VGS takes the preset-ring approach. VGS differs by declaring the ring in the manifest schema because Settings draws every plugin page from the manifest.

**Revisit When**: A setting needs a structured editor the schema cannot describe, a string must accept arbitrary user text with no preset anchor, or key capture lands as its own control.

**Verification**: `scripts/test-plugin-logic.js` pins the manifest rules and setting refusals with controls. `scripts/test-setting-values.js` pins unit text, datetime format validation and preset labels with controls. `scripts/smoke/rows/settings.sh` reads preset choice and custom datetime writes. `scripts/smoke/rows/manager.sh` reads key/value row heights and plants a taller row.
