# Plugins

Covers: shell/plugins/**, shell/Core/**, shell/Commons/**, shell/Ui/**, shell/Hosts/**, shell/shell.qml, config/shell.json, bin/**

The plugin contract: what a plugin is, how the core loads and unloads it, what it may use, and how an Omarchy Quattro plugin fits without edits.

## Manifest

A plugin is a directory with `manifest.json` at its root. The schema is Omarchy Quattro's, schema version 1, taken whole, plus one reserved key. `shell/Core/PluginLogic.js` is the one judge of a manifest; `scripts/check-manifests.js` and `vgsh plugin validate` run that judge offline.

| Field | Meaning |
|---|---|
| `schemaVersion` | `1`. Any other value refuses the plugin. |
| `id` | Dotted and author-namespaced, lower case: `author.name`. `vgs.*` is first-party here and `omarchy.*` first-party there. |
| `name`, `version`, `author`, `description` | Listing metadata, all required. |
| `license` | Optional SPDX identifier. |
| `kinds` | One or more of `bar-widget`, `bar`, `panel`, `overlay`, `menu`, `service`. |
| `entryPoints` | One QML file per declared kind, keyed `barWidget`, `bar`, `panel`, `overlay`, `menu`, `service`, relative to the plugin root and inside it. |
| `keepLoaded` | Optional. A summoned kind stays loaded between summons. |
| `barWidget` | Per-kind block: `displayName`, `category`, `allowMultiple`, `defaultSection`, `defaults`, `schema`. `schema` is the declarative settings form the manager renders. |
| `vgs` | The one reserved key. `capabilities`: core APIs the plugin uses beyond its kinds. `budgets`: the ceilings its validation row asserts. A `requires` key is refused: plugins declare no dependencies. |

## Kinds are surfaces, not dependencies

A kind names a surface the core can host. A plugin declares every kind it can fill and the core shows each one whose host exists. A kind whose host is absent is not shown, and the plugin's other kinds keep working. Nothing depends on another plugin by name.

A notification center is the shape this serves: kind `service` owns the notification daemon, kind `bar-widget` draws a bell in the bar, and kind `panel` is the list that opens under the bell. With no bar enabled the bell is not shown, the service keeps collecting, and the panel opens from the shortcut the plugin registers and at the placement its settings choose. The panel's placement is a setting of that plugin, not of the bar.

| Kind | Entry point is | Draws in | Loaded |
|---|---|---|---|
| `bar-widget` | an `Item` extending `BarWidget` from `qs.Ui` | the active bar's sections | when placed in a bar section and a bar is active |
| `bar` | an `Item` that lays out widgets | the bar host, one per screen | when it is the active bar; one at a time |
| `panel` | an `Item` with `open(payloadJson)` and `close()` | the panel host | on summon |
| `overlay` | an `Item` with `open(payloadJson)` and `close()` | the overlay host | on summon |
| `menu` | an `Item` with `open(payloadJson)` and `close()` | the menu host | on summon |
| `service` | a headless `Item` | nothing | at startup when enabled |

The core creates every Wayland surface. An entry point never names `PanelWindow`, `FloatingWindow`, `PopupWindow`, `WlSessionLock` or `WlrLayershell`; `scripts/check-plugin-boundary.py` refuses the name. The bar host exists; the panel, overlay and menu hosts land with the first plugin of each kind.

Disabling the active bar hides every enabled bar widget and the manager says so in its reply. The widgets stay enabled and return with the next bar.

## Loading

- Plugins live under the shell root: first-party under `shell/plugins/<id>/`, user plugins under `~/.config/vgs/plugins/<id>/`. The user directory takes precedence over the bundled one when two plugins share an id, and the hidden one is reported once.
- `bin/vgsh-scan` reads every manifest in one process per scan; the shell validates them and replaces its manifest map whole, so bindings re-evaluate once.
- A host builds an entry point with `Qt.createComponent` on a `file://` URL and parents the instance to its slot. `import qs.Commons` and `import qs.Ui` resolve through the shell root from that URL.
- A host assigns `shell`, `barConfig` and `screen` after creation, never as initial properties: initial properties cross a QVariant conversion that drops the facade's functions and turns nested lists into sequences `Array.isArray` rejects.
- The bar builds each widget with `bar`, `moduleName` and `settings`, the three properties `BarWidget` declares, and destroys and rebuilds a section when the layout entry list changes.
- Unload is destruction: the host destroys the instance and everything parented to it. A plugin keeps no object outside its own tree.
- Quickshell watches only files reached from `shell.qml` by static import, so an edit inside a plugin reloads nothing. `vgsh ipc call shell rescanPlugins` re-reads manifests and bumps the generation every host keys its instances on.

## Capabilities

A capability is a core API named in the manifest's `vgs.capabilities`, delivered on the `shell` object at load. The core owns the list in `PluginLogic.js` and refuses an unknown name.

| Capability | Gives the plugin |
|---|---|
| `compositor` | `shell.compositor.focusWorkspace(id)`: a dispatch through the core's one reply judge, in Lua or classic syntax as the session needs |

Every plugin receives `shell.manifest` and `shell.widgets`, the bar-widget catalogue a bar uses to build its sections. A capability lands with its interface, its core provider and one consuming plugin in the same PR.

## Isolation

- Static: a plugin file imports Qt and Quickshell modules other than `Quickshell.Wayland`, `qs.Commons`, `qs.Ui`, and files under its own directory. No `qs.Core`, no `qs.Hosts`, no other plugin, no `..`. `scripts/check-plugin-boundary.py` enforces it and `scripts/test-check-plugin-boundary.py` plants one violation per rule.
- The core names no plugin: the same check refuses a first-party id literal or a plugin directory import under `shell/` outside `shell/plugins/`. The default bar id lives in `config/shell.json`.
- Runtime: a plugin receives a scoped `shell` object, not the host singletons.
- Not a sandbox: a plugin runs in the shell process with the shell's file and process access, and a visual plugin shares the host's scene. Omarchy documents the same limit. Sensitive state never relies on the scope alone.
- A process-per-plugin boundary is the alternative. It is not chosen until the runtime budgets are measured against it.

## Plugin manager

The manager is core: its mechanism is the `Plugins` singleton plus the `vgsh plugin` subcommand, and its user interface will be a first-party plugin of kind `menu`.

- `vgsh plugin list`, `enable <id>`, `disable <id>`, `validate <dir>`. Enable and disable go through the shell's IPC, which writes the user file; the shell watches the file and re-derives the enabled set. `disable` on the active bar answers `ok hidden=<ids>`.
- Configuration is `config/shell.json` merged with `~/.config/vgs/shell.json`. A user key replaces the shipped key whole, except `plugins`, whose entries merge by id with the user entry winning, and `disabledPlugins`, which is the user list. The manager seeds the user `bar` key from the effective bar before its first edit so one change never drops the other widgets. `scripts/test-plugin-logic.js` pins each rule.
- Enabled means: the active bar; a bar widget placed in a section; a plugin listed in `plugins`; a first-party plugin with a non-bar kind unless listed in `disabledPlugins`.
- Not yet written: `add <git url>`, `update`, `remove`. Their rules stand: clone into staging, validate, refuse a duplicate id, land disabled, run no plugin code, ask for no privilege, fast-forward only with the diff shown.

## Omarchy compatibility

An unmodified Omarchy Quattro plugin loads when it uses only what the core provides under the same names: the manifest schema; the kinds; `qs.Commons` with `Color`, `Style`, `Util`; `qs.Ui` with `BarWidget`; the widget properties `bar`, `moduleName`, `settings`; the bar properties `foreground`, `background`, `urgent`, `fontFamily`, `position`, `vertical`, `barSize`.

Not yet provided: `Border` in `qs.Commons`, the rest of `qs.Ui`, the injected `omarchyPath`, `pluginRegistry` and `barWidgetRegistry` properties, the four proxied `omarchy.*` services, `bar.run`, tooltips and popouts, and the `summon`, `hide`, `toggle` and `call` IPC methods. Out of scope: plugins that shell out to `omarchy-*` commands, the `shell.toml` theme pipeline, and the inline `type: "command"` and `type: "qml"` bar modules. The compatibility PR pins one marketplace plugin as a fixture at a recorded commit and runs it in the nested sandbox.

## Budgets

- `scripts/qml-smoke.sh` runs the shell with every bundled plugin in the nested sandbox and asserts the resident-size ceiling its header states, measured by the same script.
- A service owns every watcher, poller and subprocess it starts, one owner per source.
- A plugin holds no cache keyed by data other applications supply without a ceiling.
- A latency row does not exist yet; `scripts/bench-shell-events.py` is the tool it will use.

## Decisions

- The manifest is Omarchy's, whole, plus one reserved key. Two formats would need a translator that drifts.
- Kinds are the six Omarchy kinds and each is a surface. A seventh is a core change with its own host.
- No dependencies between plugins. A kind whose host is absent is not shown; everything else in the plugin still runs.
- The core is privileged and names no plugin. DeepSeek Harness makes even its main loop replaceable; a shell that scopes plugins needs a core they cannot swap out.
- No install hooks, no privilege, land disabled: Omarchy's installer rules.
- The inline command module is not core. A shell-out on an interval into a bar slot contradicts the per-plugin budget; it ships as a plugin if wanted.
- Two configuration layers, not Omarchy's one. A shipped default that never reaches a customised user file is a regression channel.

No decision record exists yet. The first structural PR records these with the decider skill.
