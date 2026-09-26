# Plugins

Covers: shell/plugins/**, shell/Core/Plugins.qml, shell/Core/PluginLogic.js, shell/Core/Capabilities.qml, shell/Core/qmldir, shell/Commons/Style.qml, shell/Commons/Time.qml, shell/Commons/Workspaces.qml, shell/Commons/qmldir, shell/Ui/**, shell/Hosts/**, bin/vgsh-scan, bin/vgsh-plugin-judge, .agents/skills/vgs-plugin/**

The plugin contract: what a plugin is, what the core builds for it, what it may use, and how the core keeps a running plugin in step with the configuration.

## Manifest

A plugin is a directory with `manifest.json` at its root. `shell/Core/PluginLogic.js` is the one judge of a manifest; `scripts/check-manifests.js` and `vgsh plugin validate` run that judge offline, and `scripts/test-plugin-logic.js` pins each refusal by its text. A key not in this table refuses the manifest, so a misspelt key fails loudly instead of being carried and ignored.

| Field | Required | Meaning |
|---|---|---|
| `schemaVersion` | yes | `1`. Any other value refuses the plugin. |
| `id` | yes | Dotted and author-namespaced, lower case: `author.name`. `vgs.*` is first-party. |
| `name`, `version`, `author`, `description` | yes | Listing metadata, non-empty strings. |
| `license` | no | A non-empty string when present. The judge checks nothing more about it. |
| `kinds` | yes | One or more of the kinds `PluginLogic.KINDS` lists and [overview.md § Vocabulary](overview.md#vocabulary) defines, each once. |
| `entryPoints` | yes | One QML file per declared kind, keyed by the kind name, relative to the plugin root and inside it. A key naming an undeclared kind is refused. |
| `capabilities` | no | Core APIs the plugin uses beyond its kinds, from the table under § Capabilities. |
| `settings` | no | The plugin's default settings, an object without an `id` key. The configuration entry for the plugin overrides them key by key. `placement` is reserved: the core reads it for a summoned panel or menu, and a value outside `PluginLogic.PLACEMENTS` refuses the manifest. |
| `schema` | no | The settings a user or the plugin itself may change, keyed by setting name: `type` (`string`, `number`, `boolean` or `enum`), `label`, optional `description`, and `options` for an `enum`. Every entry needs a default of its type in `settings`. Required with capability `configure`. |
| `defaultSection` | no | `left`, `center` or `right`: where `vgsh plugin enable` places a bar widget that has no placement. Needs kind `bar-widget`; `center` when absent. |

## Kinds

A kind names a surface the core can host. A plugin declares every kind it can fill and the core builds each one whose host exists and whose configuration enables it. A kind whose host is absent is not built; the plugin's other kinds are.

| Kind | Entry point is | Host | Built when |
|---|---|---|---|
| `bar-widget` | an `Item` extending `BarWidget` from `qs.Ui` | the active bar's sections | placed in a bar section, enabled, and a bar is active |
| `bar` | an `Item` declaring `leftSection`, `centerSection` and `rightSection` | `BarHost`, one per screen | it is the active bar; one at a time |
| `service` | a headless `Item` | `ServiceHost` | enabled |
| `background` | an `Item` declaring `screen` | `BackgroundHost`, one per screen, on the layer under every window | enabled |
| `panel`, `overlay`, `menu` | an `Item` with `open(payloadJson)` and `close()` | `SummonHost`, one per kind | enabled and summoned, until hidden |

Enabled means: the active bar, with every other kind it declares; a bar widget placed in a section; any other plugin listed in `plugins` or first-party. A plugin declaring `bar` is enabled only as the active bar. `disabledPlugins` wins over every other rule: a placed widget listed there leaves the bar and its layout entry stays in the file.

`summon <kind> <id> <payloadJson>`, `hide <kind> <id>` and `toggle` reach the summonable kinds, over IPC or through the plugin's own `surfaces` capability. A summon creates a layer surface on the screen it came from (the focused monitor for IPC), builds the plugin in it and calls `open(payloadJson)`; summoning an open plugin calls `open` again with the new payload and builds nothing. `hide` destroys the surface after the slot calls `close()`, so a hidden plugin keeps no Wayland object; a plugin disabled while summoned is closed the same way. An `open()` that throws refuses the summon with `refused: open-failed=<id>`; a `close()` that throws is logged and the surface still goes. A summon of a plugin that cannot be built now answers `Plugins.buildRefusal`: the scan pending, the configuration not ready (`refused: config=<state>`, where the state is `Config.notReady`: `pending`, or the failure of a shipped file that has never loaded), the plugin unknown or disabled, or an exclusive capability held by another plugin. A panel is placed under the widget that summoned it, centred on it and clamped to the screen, or, with no anchor, at the plugin's `placement` setting clear of reserved space; `PluginLogic.PLACEMENTS` lists the values. A menu is placed the same way on the overlay layer; an overlay covers its screen. `PluginLogic.surfacePlacement` decides the geometry and the layer.

Disabling the active bar hides every enabled bar widget and the manager's reply names them. They stay enabled and return with the next bar. Enabling a bar makes it the active bar.

## What the core builds and hands over

- `bin/vgsh-scan` reads every manifest under `shell/plugins/` and `~/.config/vgs/plugins/` in one process and reports every directory it could not inspect as an error, never as absence. The user directory wins an id collision and the hidden plugin is logged when the collision set changes. The registry replaces its manifest map whole and bumps its generation only when the set changed, and logs `plugins: scan complete changed=<bool>` for every scan it applies; the smoke's no-op rescan row waits on that line.
- `PluginSlot` in `shell/Hosts/` owns one instance of one kind: it asks the core to build, rebuilds when `Plugins.slotKey` changes, and destroys before every rebuild and on its own destruction. A build that produces no instance is reported to the host, which takes the surface down. Every host is a surface plus slots.
- The core builds an entry point with `Qt.createComponent` on a `file://` URL and assigns its properties after creation, never as initial properties ([runtime.md § QML](runtime.md#qml) says why). A host hands the core the properties it owns (a bar's `screen`) through the slot's `context`; no host assigns a plugin property itself.
- Every instance receives `shell`: its manifest, its settings, and one provider per capability its manifest names. A bar widget also receives `bar`, `moduleName` and `settings`. A bar also receives `screen`.
- Settings are the manifest's `settings` under the configuration entry for the plugin: the layout entry for a bar widget, the `plugins` row for every other kind.
- The core mounts bar widgets into the active bar's section containers, in layout order, and records every widget under the bar's host key. A bar never builds, destroys or interprets a plugin widget.
- A bar may draw built-in widgets of its own in the same containers, ahead of the plugin widgets, and registers each through its `builtins` capability: [overview.md § Vocabulary](overview.md#vocabulary) defines the built-in widget and [D013](../decisions/D013-built-in-widgets-are-the-bar-plugins.md) records the choice. The core built none of it, so the build counter does not move.
- Quickshell watches only files reached from `shell.qml` by static import, so an edit inside a plugin reloads nothing. `vgsh ipc call shell rescanPlugins` re-reads manifests; a changed set bumps the generation every slot keys on.

## Reconciliation

Every configuration change reaches every running instance through one reconcile in `Plugins.qml`, driven by `PluginLogic.effectiveLayout` and `PluginLogic.settingsFor`:

- A bar section whose widget id sequence changed is rebuilt whole, in order. A section whose ids are unchanged keeps its widgets. `reconcileBar` keeps one entry per wanted layout entry, a failed build included, so a change to one entry reaches that entry's widget alone.
- A widget whose layout entry changed, and any other instance whose `plugins` row changed, receives a fresh `shell` (and, for a widget, `settings`) in place. Nothing else is rebuilt.
- A write that changes no entry an instance reads builds nothing; the smoke asserts it through the build counter and reads delivered settings back.

## Capabilities

A capability is a core API named in the manifest's `capabilities` and delivered as `shell.<name>`. `PluginLogic.js` owns the name list and `Capabilities.qml` holds one provider per name; an unknown name refuses the manifest, and a name without a provider is logged at start. An instance's `shell` holds exactly `manifest`, `settings` and the capabilities it named; the smoke reads the key list back from a fixture naming every capability but `surfaces`, `builtins` and `manager`, and from one naming none.

- The core makes each provider for one instance when it builds the instance. A settings change hands over a new `shell` holding the same providers.
- Every registration a provider makes returns a disposer, and the instance's build record keeps each one. Destroying the instance runs them all, newest first, so disabling a plugin releases every shortcut, IPC target, subscriber and hold it made. The smoke asserts each release after disabling its fixture, from the core's lending record and from the compositor or bus the capability reaches.
- `lock` and `polkit` are exclusive: while one plugin holds one, another plugin naming it is not built, and it builds once the holder lets go. `PluginLogic.lendRefusal` decides it. `Plugins.buildRefusal`, which `slotKey` reads, follows a copy of the holders taken after each change settles; `reconcileBar` reads the live record. `scripts/test-plugin-logic.js` and the smoke pin it.
- A build that fails after its capabilities were made (an entry point without `shell`, a background without `screen`, a widget without the `BarWidget` properties) runs every disposer, leaves no build record and is reported to the host as a failed build.
- Every instance is destroyed under the host key it was built under, so a host whose key changes while its screen goes away still releases everything.
- The notification server and the polkit agent exist only while a plugin holds their capability, so a shell with no such plugin claims neither role. The smoke asserts both objects are gone once the holder is disabled. Whether the process keeps the notification D-Bus name after the server is destroyed is Quickshell's, and [D012](../decisions/D012-core-owns-lent-objects.md) names it as the revisit condition.

Each capability's members are listed in [`.agents/skills/vgs-plugin/references/api.md` § The shell object](../../.agents/skills/vgs-plugin/references/api.md#the-shell-object). Three carry rules of their own: `compositor` offers one function per dispatcher in `Dispatch.PLUGIN_DISPATCHERS`, and `shell/Core/Dispatch.js` refuses an argument that could break out of the session's syntax; `configure` writes only a key the manifest's `schema` declares, with a value of its type, to the configuration entry `PluginLogic.settingTargetOf` names for the calling instance's kind; `lock` keeps a locked session locked when its holder is unloaded.

A capability lands with its name, its provider and a fixture consumer with its smoke rows in the same change.

## Isolation

- Static: a plugin imports only the prefixes [`api.md` § Allowed imports](../../.agents/skills/vgs-plugin/references/api.md#allowed-imports) lists and files in its own directory, instantiates no window type and no object the core lends, and never calls `Hyprland.dispatch`. `scripts/check-plugin-boundary.py` enforces these four rules on every `.qml` and `.js` file with comments blanked, and `scripts/test-check-plugin-boundary.py` plants one violation per rule. A directory or file the check cannot read ends the run; an incomplete walk certifies nothing.
- The core names no plugin: the same check refuses a first-party id literal or a plugin directory import under `shell/` outside `shell/plugins/`. The default bar id lives in `config/shell.json`.
- Runtime: a plugin receives a scoped `shell` object, never a host singleton. A bar's `shell` is the bar's own; a widget reaching `bar.shell` gets the bar's capabilities, not its own, so a widget uses its own `shell`.
- Not a sandbox: a plugin runs in the shell process with the shell's file and process access, and a visual plugin shares the host's scene, [D010](../decisions/D010-facade-scope-not-sandbox.md).

## Plugin manager

The manager is core: the `Plugins` singleton plus `vgsh plugin`. Its user interface is the shipped bar's `manager` built-in: a button that opens the bar's own panel, which lists every discovered plugin with its enabled state and draws a settings form from each manifest's `schema`. The panel reaches the manager through the `manager` capability, which calls the same `setEnabled` the IPC does and writes a setting to every entry the plugin's instances read; a disabled plugin's setting is refused, since listing a third-party row would enable it. The panel shows each refusal on its plugin's row until a later call for that plugin succeeds.

- Enable and disable go through the shell's IPC, which writes the user file; the shell watches the file and re-derives the enabled set.
- Disable lists the id in `disabledPlugins` and changes nothing else: placement, settings rows and the active bar id stay, so re-enabling restores the exact screen. Enable unlists the id and gives a plugin a presence only when it has none: a bar becomes the active bar, an unplaced widget is placed in its default section, an unlisted third-party plugin of another kind is listed. Enabling a plugin that already has its presence is idempotent. `scripts/test-plugin-logic.js` pins each rule.
- The configuration files, their shape, their states and the write rule: [configuration.md](configuration.md). Nothing is built before the first scan and before the configuration is ready.
- Only the shell the runner started accepts a state-changing call; [runtime.md § Process](runtime.md#process).
- `add` clones into a staging directory beside `~/.config/vgs/plugins/`, runs the manifest judge, refuses an id another plugin owns or an occupied target, lists the id in `disabledPlugins` when the configuration would already enable it, then moves it into place. `update` refuses a modified checkout, prints the incoming diff, fast-forwards only and rolls back a version the judge refuses. `remove` deletes only `~/.config/vgs/plugins/<id>` holding that id, never a bundled plugin or a symlink. None runs plugin code or a git hook; each starts a rescan of a running shell. `bin/vgsh-plugin-judge` makes their decisions through `PluginLogic.js`, and `scripts/test-vgsh.sh` pins each rule, [D007](../decisions/D007-install-runs-no-plugin-code.md).

## Budgets

- `scripts/qml-smoke.sh` runs the shell with its fixture plugins in the nested sandbox and asserts what each host built and each instance received, plus the ceilings its header states: resident size, exec to first bar, and a `setPluginEnabled` reply to the build records. The resident-size ceiling catches a startup allocation blow-up and nothing else.
- A service owns every watcher, poller and subprocess it starts, one owner per source, inside its own tree.
- A plugin holds no cache keyed by data other applications supply without a ceiling.
- The latency ceilings measure the whole shell. No row measures one plugin's latency or memory.

## Decisions

[D003](../decisions/D003-everything-is-a-plugin.md), [D005](../decisions/D005-kinds-are-surfaces-no-dependencies.md), [D006](../decisions/D006-two-configuration-layers.md), [D007](../decisions/D007-install-runs-no-plugin-code.md), [D009](../decisions/D009-one-manifest-judge-under-node.md), [D010](../decisions/D010-facade-scope-not-sandbox.md), [D011](../decisions/D011-native-manifest-no-cross-shell-compatibility.md), [D012](../decisions/D012-core-owns-lent-objects.md) and [D013](../decisions/D013-built-in-widgets-are-the-bar-plugins.md).
