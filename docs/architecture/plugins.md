# Plugins

Covers: shell/plugins/**, shell/Core/Plugins.qml, shell/Core/PluginLogic.js, shell/Core/Config.qml, shell/Commons/**, shell/Ui/**, shell/Hosts/**, config/shell.json, bin/vgsh-scan, .agents/skills/vgs-plugin/**

The plugin contract: what a plugin is, what the core builds for it, what it may use, and how the core keeps a running plugin in step with the configuration.

## Manifest

A plugin is a directory with `manifest.json` at its root. `shell/Core/PluginLogic.js` is the one judge of a manifest; `scripts/check-manifests.js` and `vgsh plugin validate` run that judge offline, and `scripts/test-plugin-logic.js` pins each refusal by its text. A key not in this table refuses the manifest, so a misspelt key fails loudly instead of being carried and ignored.

| Field | Required | Meaning |
|---|---|---|
| `schemaVersion` | yes | `1`. Any other value refuses the plugin. |
| `id` | yes | Dotted and author-namespaced, lower case: `author.name`. `vgs.*` is first-party. |
| `name`, `version`, `author`, `description` | yes | Listing metadata, non-empty strings. |
| `license` | no | SPDX identifier, non-empty when present. |
| `kinds` | yes | One or more of `bar-widget`, `bar`, `panel`, `overlay`, `menu`, `service`, each once. |
| `entryPoints` | yes | One QML file per declared kind, keyed by the kind name, relative to the plugin root and inside it. A key naming an undeclared kind is refused. |
| `capabilities` | no | Core APIs the plugin uses beyond its kinds, from the table under § Capabilities. |
| `settings` | no | The plugin's default settings, an object without an `id` key. The configuration entry for the plugin overrides them key by key. |
| `defaultSection` | no | `left`, `center` or `right`: where `vgsh plugin enable` places a bar widget that has no placement yet. Needs kind `bar-widget`; `center` when absent. |

## Kinds

A kind names a surface the core can host. A plugin declares every kind it can fill and the core builds each one whose host exists and whose configuration enables it. A kind whose host is absent is not built; the plugin's other kinds are.

| Kind | Entry point is | Host | Built when |
|---|---|---|---|
| `bar-widget` | an `Item` extending `BarWidget` from `qs.Ui` | the active bar's sections | placed in a bar section, enabled, and a bar is active |
| `bar` | an `Item` declaring `leftSection`, `centerSection` and `rightSection` | `BarHost`, one per screen | it is the active bar; one at a time |
| `service` | a headless `Item` | `ServiceHost` | enabled |
| `panel`, `overlay`, `menu` | an `Item` with `open(payloadJson)` and `close()` | none yet | never, until each host lands with the first plugin of its kind |

Enabled means: the active bar; a bar widget placed in a section; a plugin listed in `plugins`; a first-party plugin declaring a kind other than `bar` and `bar-widget`. `disabledPlugins` wins over every other rule: a placed widget listed there leaves the bar and its layout entry stays in the file.

Disabling the active bar hides every enabled bar widget and the manager's reply names them. They stay enabled and return with the next bar. Enabling a bar makes it the active bar.

## What the core builds and hands over

- `bin/vgsh-scan` reads every manifest under `shell/plugins/` and `~/.config/vgs/plugins/` in one process and reports every directory it could not inspect as an error, never as absence. The user directory wins an id collision and the hidden plugin is logged when the collision set changes. The registry replaces its manifest map whole and bumps its generation only when the set changed.
- Nothing is built before the first scan finished and both configuration files settled: the shipped file loaded, and the user file loaded, found absent or refused as unparseable. A bar built from the user file alone would draw without the shipped layout.
- `PluginSlot` in `shell/Hosts/` owns one instance of one kind: it asks the core to build, rebuilds when `Plugins.slotKey` changes (the plugin id or the generation), and destroys before every rebuild and on its own destruction. A build that produces no instance is reported to the host, which takes the surface down. Every host is a surface plus slots.
- The core builds an entry point with `Qt.createComponent` on a `file://` URL and assigns its properties after creation, never as initial properties: initial properties cross a QVariant conversion that drops functions and turns nested lists into sequences `Array.isArray` rejects. A host hands the core the properties it owns (a bar's `screen`) through the slot's `context`; no host assigns a plugin property itself.
- Every instance receives `shell`: its manifest, its settings, and one provider per capability its manifest names. A bar widget also receives `bar`, `moduleName` and `settings`. A bar also receives `screen`.
- Settings are the manifest's `settings` under the configuration entry for the plugin: the layout entry for a bar widget, the `plugins` row for every other kind.
- The core mounts bar widgets into the active bar's section containers, in layout order, and records every widget under the bar's host key. A bar owns geometry only: it never builds, destroys or interprets a widget.
- Quickshell watches only files reached from `shell.qml` by static import, so an edit inside a plugin reloads nothing. `vgsh ipc call shell rescanPlugins` re-reads manifests; a changed set bumps the generation every slot keys on.

## Reconciliation

Every configuration change reaches every running instance through one reconcile in `Plugins.qml`, driven by `PluginLogic.effectiveLayout` and `PluginLogic.settingsFor`:

- A bar section whose widget id sequence changed is rebuilt whole, in order. A section whose ids are unchanged keeps its widgets.
- A widget whose layout entry changed, and any other instance whose `plugins` row changed, receives a fresh `shell` (and, for a widget, `settings`) in place. Nothing else is rebuilt.
- A write that changes no entry an instance reads builds nothing; `scripts/qml-smoke.sh` asserts it through the core's build counter, and asserts the delivered settings by reading the instance back.

## Capabilities

A capability is a core API named in the manifest's `capabilities` and delivered as `shell.<name>`. `PluginLogic.js` owns the name list and `Plugins.qml` maps each name to its provider; an unknown name refuses the manifest. An instance's `shell` holds exactly `manifest`, `settings` and the capabilities it named; the smoke reads the key list back from its fixture.

| Capability | Gives the plugin |
|---|---|
| `compositor` | `shell.compositor.focusWorkspace(id)`: one dispatch through the core's reply judge, in Lua or classic syntax as the session needs |

A capability lands with its name, its provider row and one consuming plugin in the same PR.

## Isolation

- Static: a plugin's imports start with `QtQuick`, `QtQml`, `Qt.labs.`, `Quickshell`, `qs.Commons` or `qs.Ui`, never `Quickshell.Wayland` or `QtQuick.Window`; a quoted import stays inside the plugin directory; no window type is instantiated; no object the core lends through a capability is instantiated and `Hyprland.dispatch` is never called. `scripts/check-plugin-boundary.py` enforces these four rules on every `.qml` and `.js` file with comments blanked, and `scripts/test-check-plugin-boundary.py` plants one violation per rule. A directory or file the check cannot read ends the run; an incomplete walk certifies nothing.
- The core names no plugin: the same check refuses a first-party id literal or a plugin directory import under `shell/` outside `shell/plugins/`. The default bar id lives in `config/shell.json`.
- Runtime: a plugin receives a scoped `shell` object, never a host singleton. A bar's `shell` is the bar's own; a widget reaching `bar.shell` gets the bar's capabilities, not its own, so a widget uses its own `shell`.
- Not a sandbox: a plugin runs in the shell process with the shell's file and process access, and a visual plugin shares the host's scene, [D010](../decisions/D010-facade-scope-not-sandbox.md).

## Plugin manager

The manager is core: the `Plugins` singleton plus `vgsh plugin`. Its user interface does not exist yet.

- `vgsh plugin list`, `enable <id>`, `disable <id>`, `validate <dir>`. Enable and disable go through the shell's IPC, which writes the user file; the shell watches the file and re-derives the enabled set.
- Disable lists the id in `disabledPlugins` and changes nothing else: placement, settings rows and the active bar id stay, so re-enabling restores the exact screen. Enable unlists the id and gives a plugin a presence only when it has none: a bar becomes the active bar, an unplaced widget is placed in its default section, an unlisted third-party plugin of another kind is listed. Enabling a plugin that already has its presence is idempotent. `scripts/test-plugin-logic.js` pins each rule.
- Configuration is `config/shell.json` merged with `~/.config/vgs/shell.json`, [D006](../decisions/D006-two-configuration-layers.md). `scripts/test-plugin-logic.js` pins each merge rule and the seeding of the user `bar` key.
- A user file that does not parse keeps the last good value and refuses every write until it parses again. A write the disk refuses restores the value in memory and refuses the next write with the error.
- Only the shell the runner started accepts a state-changing call; [runtime.md § Process](runtime.md#process).
- Not yet written: `add <git url>`, `update`, `remove`, [D007](../decisions/D007-install-runs-no-plugin-code.md).

## Budgets

- `scripts/qml-smoke.sh` runs the shell with every bundled plugin and one fixture plugin in the nested sandbox, asserts the widgets each bar built, the capabilities and settings each instance received, the surface and reserved space the bar host holds, and the resident-size ceiling its header states. That ceiling catches a startup allocation blow-up and nothing else.
- A service owns every watcher, poller and subprocess it starts, one owner per source, inside its own tree.
- A plugin holds no cache keyed by data other applications supply without a ceiling.
- No latency row exists yet. A per-plugin latency or memory budget is a target until a row measures it; the current smoke pass is not evidence for one.

## Decisions

[D003](../decisions/D003-everything-is-a-plugin.md), [D005](../decisions/D005-kinds-are-surfaces-no-dependencies.md), [D006](../decisions/D006-two-configuration-layers.md), [D007](../decisions/D007-install-runs-no-plugin-code.md), [D009](../decisions/D009-one-manifest-judge-under-node.md), [D010](../decisions/D010-facade-scope-not-sandbox.md) and [D011](../decisions/D011-native-manifest-no-cross-shell-compatibility.md).
