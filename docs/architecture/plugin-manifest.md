# Plugin manifest

Covers: shell/plugins/**/manifest.json, shell/Core/PluginLogic.js, shell/Core/PackageManagers.js, shell/Ui/icons/Lucide.js, bin/vgsh-scan, bin/lib/check-manifests.js, scripts/test-plugin-logic.js, scripts/test-hyprland-layer.js, scripts/test-check-manifests.js

The manifest contract for a plugin directory. The broader plugin lifecycle, kinds, capabilities and isolation rules are in [plugins.md](plugins.md).

## Manifest

A plugin is a directory with `manifest.json` at its root. `shell/Core/PluginLogic.js` is the one judge of a manifest; `bin/lib/check-manifests.js` and `vgsh plugin validate` run that judge offline, and `scripts/test-plugin-logic.js` pins each refusal by its text, the `hyprland` key's in `scripts/test-hyprland-layer.js`. A key not in this table refuses the manifest, so a misspelt key fails loudly instead of being carried and ignored.

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
| `schema` | no | The settings a user or the plugin itself may change, keyed by setting name: `type` (`string`, `number`, `boolean` or `enum`), `label`, optional `description`, `options` for an `enum`, and optional `group`, a non-empty section heading. A `number` may take `min` and `max`, finite with `min` below `max`, and a positive `step`; the three are refused on any other type. Every entry needs a default of its type, inside its bounds, in `settings`, and a written number outside them is refused; `step` refuses nothing. The Settings window draws one field per entry in key order, ungrouped entries first, then each group in the order its first entry appears, and a number with both bounds as a slider. Required with capability `configure`. |
| `defaultSection` | no | `left`, `center` or `right`: where `vgsh plugin enable` places a bar widget that has no placement. Needs kind `bar-widget`; `center` when absent. |
| `appearance` | no | A `.js` file inside the plugin holding the plugin's own look, which the theme reaches through its mode and accent alone: [appearance.md](appearance.md). |
| `status` | no | The runtime values the plugin publishes through capability `status`, which the manifest must name, each `{ type, label, group?, hint?, action?, command?, hidden? }`; its instances read them and the Settings page draws them, with an entry's `action` as a one-click setup step and its `command` behind Show command: [status.md](status.md), [D061](../decisions/D061-no-manual-commands.md). |
| `secrets` | no | `{ service, label }`: the libsecret items the core stores and clears for the plugin from a masked field on its Settings page. Needs capability `secrets` and a `presenceList` status entry whose items name each account: [status-actions.md § Actions and secrets](status-actions.md#actions-and-secrets). |
| `hyprland` | no | What the plugin asks of Hyprland, as data the core renders into the Hyprland layer: `binds`, a list of `{ shortcut, key, hold? }`, each a shortcut the plugin registers through capability `shortcut`, which the manifest must name, and its default key such as `SUPER+SPACE`; optional boolean `hold` adds the release bind defined in [hyprland-shortcuts.md § Hold shortcuts](hyprland-shortcuts.md#hold-shortcuts). `layerRules` is a list of `{ namespace, blur, ignoreAlpha }` for `^vgs:<name>$`, the core hosts' namespaces; `appearance` maps `borders`, `radius` or `motion` to a boolean schema key for a plugin with capability `theme`. At least one of `binds`, `layerRules` or `appearance` is non-empty, and no shortcut, key or namespace appears twice. An appearance-only section is valid: [hyprland.md](hyprland.md). |
| `requirements` | no | The external commands the plugin runs, each `{ command, packages, optional, purpose }`: a bare command name, its package per manager id, whether the plugin works without it, and one line on what it is for. A requirement never names a plugin, and `requires` is refused: [requirements.md](requirements.md). |
| `tui` | no | Floating TUI scripts: [tui-capability.md](tui-capability.md). |

A string `schema` entry may carry `optionsFrom`, the key of its own plugin's `choices` status. The judge verifies the reference. The editor and retained-value contract is [status.md § Setting choices](status.md#setting-choices).
