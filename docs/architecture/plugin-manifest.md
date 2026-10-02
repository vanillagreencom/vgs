# Plugin manifest

Covers: shell/plugins/**/manifest.json, shell/Core/PluginLogic.js, shell/Commons/SettingValues.js, shell/Core/PackageManagers.js, shell/Ui/icons/Lucide.js, bin/vgsh-scan, bin/lib/check-manifests.js, scripts/test-plugin-logic.js, scripts/test-setting-values.js, scripts/test-plugin-extras.js, scripts/test-hyprland-layer.js, scripts/test-check-manifests.js

The manifest contract for a plugin directory. The broader plugin lifecycle, kinds, capabilities and isolation rules are in [plugins.md](plugins.md).

## Manifest

A plugin is a directory with `manifest.json` at its root. `shell/Core/PluginLogic.js` is the one judge of a manifest; `bin/lib/check-manifests.js` and `vgsh plugin validate` run that judge offline, and `scripts/test-plugin-logic.js` pins each refusal by its text, the `hyprland` key's in `scripts/test-hyprland-layer.js` but for `hyprland.options`, whose stay in `scripts/test-plugin-logic.js`. A key not in this table refuses the manifest, so a misspelt key fails loudly instead of being carried and ignored.

| Field | Required | Meaning |
|---|---|---|
| `schemaVersion` | yes | `1`. Any other value refuses the plugin. |
| `id` | yes | Dotted and author-namespaced, lower case: `author.name`. `vgs.*` is first-party. |
| `name`, `version`, `author`, `description` | yes | Listing metadata, non-empty strings. |
| `license` | no | A non-empty string when present. The judge checks nothing more about it. |
| `icon` | no | A Lucide name from the shipped set, `shell/Ui/icons/Lucide.js`, which `PluginLogic.js` imports; the Settings window lists the plugin with it, and with `package` when absent. |
| `kinds` | yes | One or more of the kinds `PluginLogic.KINDS` lists and [overview.md § Vocabulary](overview.md#vocabulary) defines, each once. |
| `entryPoints` | yes | One QML file per declared kind, keyed by the kind name, relative to the plugin root and inside it. A key naming an undeclared kind is refused. |
| `capabilities` | no | Core APIs the plugin uses beyond its kinds, from the table under § Capabilities. |
| `settings` | no | The plugin's default settings, an object without an `id` or a `keys` key. The configuration entry for the plugin overrides them key by key. `placement` is reserved: the core reads it for a summoned panel or menu, and a value outside `PluginLogic.PLACEMENTS` refuses the manifest. |
| `schema` | no | The settings a user or the plugin itself may change, keyed by setting name. [Settings schema](#settings-schema) defines entry keys, presets, runtime choices, units and fields. Required with capability `configure`. |
| `defaultSection` | no | `left`, `center` or `right`: where `vgsh plugin enable` places a bar widget that has no placement. Needs kind `bar-widget`; `center` when absent. |
| `pane` | no | `{ group, order }` for kind `pane`. `group` is the section heading the panes holder lists the plugin under, and `order` sorts it inside that group. Needs kind `pane`; kind `pane` needs it. |
| `appearance` | no | A `.js` file inside the plugin holding the plugin's own look, which the theme reaches through its mode and accent alone: [appearance.md](appearance.md). |
| `status` | no | The runtime values the plugin publishes through capability `status`, which the manifest must name, each `{ type, label, group?, hint?, action?, command?, hidden? }`; its instances read them and the Settings page draws them, with an entry's `action` as a one-click setup step and its `command` behind Show command: [status.md](status.md), [D061](../decisions/D061-no-manual-commands.md). |
| `secrets` | no | `{ service, label }`: the libsecret items the core stores and clears for the plugin from a masked field on its Settings page. Needs capability `secrets` and a `presenceList` status entry whose items name each account: [status.md § Actions and secrets](status.md#actions-and-secrets). |
| `extras` | no | Owner-only extras, features that need developer setup such as a token from an app the user must create, which no consumer sees ([D075](../decisions/D075-consumer-features-need-no-developer-setup.md)). Each key names a setting whose default is `false` and which has no `schema` entry; its entry lists `status`, the drawn status entries only it uses, and `requirements`, the optional commands only it runs, each non-empty when present, and no entry serves two extras. While the setting is not `true`, `PluginLogic.activeManifest` leaves them out of the Settings page, the manager's steps, the requirement notice and the requirement reports. The plugin's README documents each under "Extras (not supported)". |
| `hyprland` | no | What the plugin asks of Hyprland, as data the core renders into the Hyprland layer: `binds`, a list of `{ shortcut, key, hold? }`, each a shortcut the plugin registers through capability `shortcut`, which the manifest must name, and its default key such as `SUPER+SPACE`, which the Settings page's Keys row lets the user replace by pressing a combo in a `ShortcutField` ([D086](../decisions/D086-key-capture-passthrough-submap.md)); optional boolean `hold` adds the release bind defined in [hyprland-shortcuts.md § Hold shortcuts](hyprland-shortcuts.md#hold-shortcuts). `layerRules` is a list of `{ namespace, blur, ignoreAlpha }` for `^vgs:<name>$`, the core hosts' namespaces; `appearance` maps `borders`, `radius` or `motion` to a boolean schema key for a plugin with capability `theme`; `options` maps a schema key to an input option path of the core's table for a plugin with capability `hyprland`, written only while the plugin's `plugins` row sets that key: [hyprland-options.md](hyprland-options.md). At least one of `binds`, `layerRules`, `appearance` or `options` is non-empty, and no shortcut, key or namespace appears twice. An appearance-only section is valid: [hyprland.md](hyprland.md). |
| `requirements` | no | The external commands the plugin runs, each `{ command, packages, optional, purpose }`: a bare command name, its package per manager id, whether the plugin works without it, and one line on what it is for. A requirement never names a plugin, and `requires` is refused: [requirements.md](requirements.md). |
| `tui` | no | Floating TUI scripts: [tui-capability.md](tui-capability.md). |
| `systemSteps` | no | The core's system steps the plugin offers, each once, from `PluginLogic.SYSTEM_STEPS`; needs capability `system`, which lends their probed states, and a status action `{ label, system }` applies one: [tui-system.md](tui-system.md). |

A string `schema` entry may carry `optionsFrom`, the key of its own plugin's `choices` status. The judge verifies the reference. The editor and retained-value contract is [status.md § Setting choices](status.md#setting-choices).

## Settings schema

Each entry has `type`, one of `string`, `number`, `boolean` or `enum`; `label`; optional `description`; and optional `group`, a non-empty section heading. An `enum` has `options`, a non-empty list of distinct non-empty strings. A `number` may take finite `min` and `max`, with `min` below `max`, and a positive `step`; these keys are refused on other types. Every entry needs a default of its type, inside its bounds, in `settings`. A written number outside its bounds is refused. `step` refuses nothing.

A `string` entry declares `presets` or `optionsFrom`. It never declares both. `optionsFrom` names a `choices` status entry of the same plugin. `presets` is a non-empty list of `{ value, label? }` entries on a `string` or `number`. Each value fits the entry's type, bounds and format, and values are distinct. `label`, when present, is one printable line. An empty string preset has a label.

`allowCustom` is a boolean that needs `presets`. Without it, a written value must equal one preset. With it, any value that fits the entry is accepted. `format` is for a `string` with `presets`. The only format is `datetime`, a Qt date and time format. `unit` is for `number`: `seconds`, `minutes`, `hours` or `days`.

The Settings window draws one field per entry in key order, ungrouped entries first, then each group in the order its first entry appears. A boolean uses a switch. An enum with at most three options uses a segmented control, and a larger enum uses a select. A string with `optionsFrom` uses a select. A string or number with presets uses a select, and adds Custom… when `allowCustom` is true. A bounded number uses a slider, and a `unit` labels the value.
