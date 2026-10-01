# Bar placement

Covers: scripts/smoke/rows/placement.sh

Whether a plugin's bar widget is in the bar. A placement edit never writes `disabledPlugins`; enablement follows from placement only for a plugin whose only kind is `bar-widget`. The Settings page's Show in bar switch ([settings-window.md](settings-window.md)) and the IPC set it; enablement is [manager.md](manager.md).

## Mechanism

- `PluginLogic.isPlaced` is the one placed reading: the manifest declares `bar-widget` and a bar section holds an entry with the plugin's id. A disabled plugin's entry still reads placed. `listPlugins` and the manager rows carry it as `placed`.
- `Plugins.setPlaced(id, placed)` is the one operation. The IPC `setPluginPlaced <id> <true|false>` and the `manager` capability's `setPlaced(id, placed)` call it.
- `setPlaced(id, true)` places the widget at the end of its default section, `center` when the manifest names none. Enabling an unplaced widget places it through the same `PluginLogic` rule.
- `setPlaced(id, false)` removes every layout entry with the id from every section.
- Neither reads or writes `disabledPlugins`. A plugin with a kind besides `bar` and `bar-widget` stays enabled, so its service and other kinds stay built.
- A call that finds the widget as asked changes nothing. `PluginLogic.withPlaced` decides the edit. It seeds the user `bar` from the effective bar first, as every bar edit does, since a user `bar` replaces the shipped one whole ([configuration.md](configuration.md)).
- A placed entry starts with the settings of the plugin's `plugins[]` row. The manager writes a plugin-wide setting to both entries, so a setting outlives Show in bar off and on.
- Unplacing a third-party plugin of a kind other than `bar` and `bar-widget` that has no `plugins[]` row lists it there, seeded with the first removed entry's settings. Its placement was what enabled it ([plugins.md](plugins.md)), so it stays enabled. A first-party plugin needs no row.
- A plugin whose only kind is `bar-widget` has nothing left once unplaced: it reads as disabled, and Enable places it again. The IPC and the capability allow it; the Settings page draws no Show in bar for such a plugin, whose Enabled switch is its placement.
- `PluginLogic.enablementRule` names what enables a plugin: `bar`, `widget`, `first-party` or `row`. `isEnabled` matches on it, and `withEnabled` and `withPlaced` ask it whether a plugin needs a `plugins[]` row.
- The answers are `ok`, `unknown: <id>`, `refused: placed=<id> reason=no-bar-widget` for a plugin without that kind, `refused: placed=<id> reason=disabled` for a disabled plugin, or the user file's write refusal. `PluginLogic.placedRefusal` decides the refusal; a disabled plugin is refused as its setting is. The capability answers `refused: placed=<value> want=boolean` for a non-boolean.

## Omarchy

Omarchy's `PluginRegistry.setEnabled` (basecamp/omarchy `8b4eae6`, `shell/services/PluginRegistry.qml`) drops a widget's layout entry and keeps a first-party plugin's other kinds loaded. Its disable of a first-party widget is an unplace, and the entry's settings go with the entry. VGS keeps enablement and placement as two operations, so a plugin's service and other kinds outlive its widget, and its settings outlive its entry.

## Invariants

1. A place, an unplace, a repeated call and each refusal give the user file the rule above states, and no call writes `disabledPlugins`. Enforced by `scripts/test-plugin-logic.js`, with a judge copy per rule as control, among them one whose `withPlaced` writes `disabledPlugins`.
2. After `setPluginPlaced` false, true and false, the bar's build records, the user `shell.json` and `listPlugins` follow each call, the plugin stays enabled, its service stays built and `disabledPlugins` is unchanged. Each refusal leaves the file as it was. Two clicks on the drawn Show in bar switch place and unplace the widget the same way, and a widget-only fixture's page draws no such switch. Enforced by `scripts/smoke/rows/placement.sh`.
