# Plugins

Covers: shell/plugins/**, shell/Core/Registry.qml, shell/Core/Plugins.qml, shell/Core/PluginLogic.js, shell/Core/Capabilities.qml, shell/Core/ShortcutRegistry.qml, shell/Core/IpcRegistry.qml, shell/Core/NotificationHub.qml, shell/Core/SessionLock.qml, shell/Core/qmldir, shell/Commons/Style.qml, shell/Commons/Time.qml, shell/Commons/Workspaces.qml, shell/Commons/qmldir, shell/Ui/**, shell/Hosts/**, bin/vgsh-scan, .agents/skills/vgs-plugin/**

The plugin contract: what a plugin is, what the core builds for it, what it may use, and how the core keeps a running plugin in step with the configuration. Enabling, installing and the manager's user interface are in [manager.md](manager.md).

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

`summon <kind> <id> <payloadJson>`, `hide <kind> <id>` and `toggle` reach the summonable kinds, over IPC or through the plugin's own `surfaces` capability. A summon with an anchor item creates a popup relative to that item's window; a summon without an anchor creates a layer surface on the screen it came from (the focused monitor for IPC). The host builds the plugin in it and calls `open(payloadJson)`; summoning an open plugin calls `open` again with the new payload and builds nothing. `hide` destroys the surface after the slot calls `close()`, so a hidden plugin keeps no Wayland object; a plugin disabled while summoned is closed the same way. An `open()` that throws refuses the summon with `refused: open-failed=<id>`; a `close()` that throws is logged and the surface still goes. A summon of a plugin that cannot be built now answers `Registry.buildRefusal`: the scan pending, the configuration not ready (`refused: config=<state>`, where the state is `Config.notReady`: `pending`, or the failure of a shipped file that has never loaded), the plugin unknown or disabled, or an exclusive capability held by another plugin. An anchored popup opens below its item, centred on it. The compositor flips or slides it at screen edges. The host updates the anchor when the item or an ancestor moves, and the compositor moves the popup on its next frame. An anchored popup takes a focus grab, whichever kind it is: keyboard input reaches it under a bar whose layer takes none, and a click outside hides it and calls `close()`. Hiding or destroying the anchor closes its popup. With no anchor, a panel or menu uses the plugin's `placement` setting clear of reserved space; `PluginLogic.PLACEMENTS` lists the values. An unanchored overlay covers its screen. `PluginLogic.surfacePlacement` decides layer placement; `SummonPopup` delegates anchored placement to [PopupAnchor](https://quickshell.org/docs/v0.3.1/types/Quickshell/PopupAnchor/) and dismissal to [PopupWindow](https://quickshell.org/docs/v0.3.1/types/Quickshell/PopupWindow/).

Disabling the active bar hides every enabled bar widget and the manager's reply names them. They stay enabled and return with the next bar. Enabling a bar makes it the active bar.

## What the core builds and hands over

- `bin/vgsh-scan` reads every manifest and every source file under `shell/plugins/` and `~/.config/vgs/plugins/` in one process and reports every directory or file it could not read as an error, never as absence. The user directory wins an id collision and the hidden plugin is logged when the collision set changes. Each plugin carries a source revision, a hash of every file under its directory except `.git`, and the scan publishes the files of each revision once under `$XDG_RUNTIME_DIR/vgsh-sources-<shell pid>/<revision>/`; the shell loads entry points from there, [D014](../decisions/D014-source-revisions-are-published-snapshots.md). `shell/Core/Registry.qml` holds the manifest map, replaces it whole when the set or any revision changed, and logs `plugins: scan complete changed=<bool>` for every scan it applies; the smoke's no-op rescan row waits on that line.
- `PluginSlot` in `shell/Hosts/` owns one instance of one kind: it asks the core to build, rebuilds when `Registry.slotKey` changes, and destroys before every rebuild and on its own destruction. The key is the plugin id and its source revision, so a change to one plugin's files moves that plugin's keys alone. A build that produces no instance is reported to the host, which takes the surface down, and is remembered for that host, kind and id until its revision changes or its screen goes away. Settings changes do not retry broken code. Every host is a surface plus slots.
- The core builds an entry point with `Qt.createComponent` on a `file://` URL and assigns its properties after creation, never as initial properties ([runtime.md § QML](runtime.md#qml) says why). A host hands the core the properties it owns (a bar's `screen`) through the slot's `context`; no host assigns a plugin property itself.
- Every instance receives `shell`: its manifest, its settings, and one provider per capability its manifest names. A bar widget also receives `bar`, `moduleName` and `settings`. A bar also receives `screen`.
- Settings are the manifest's `settings` under the configuration entry for the plugin: the layout entry for a bar widget, the `plugins` row for every other kind.
- The core mounts bar widgets into the active bar's section containers, in layout order, and records every widget under the bar's host key. A bar never builds, destroys or interprets a plugin widget.
- A bar may draw built-in widgets of its own in the same containers, ahead of the plugin widgets, and registers each through its `builtins` capability: [overview.md § Vocabulary](overview.md#vocabulary) defines the built-in widget and [D013](../decisions/D013-built-in-widgets-are-the-bar-plugins.md) records the choice. The core built none of it, so the build counter does not move.
- Quickshell watches only files reached from `shell.qml` by static import, so an edit inside a plugin reloads nothing by itself. `vgsh ipc call shell rescanPlugins` re-reads every plugin; a plugin whose files changed gets a new revision and is rebuilt, from its new snapshot, and every other plugin keeps its instances. A rescan asked for while one runs is queued and starts when it ends. The registry accepts output only after a successful scanner exit. A failed start, exit or parse keeps the last registry and reports `scanError`. Recovery requires another rescan; failures do not start a retry timer.

## Reconciliation

Every configuration change reaches every running instance through one reconcile in `shell/Core/Plugins.qml`, which builds and destroys every instance from what the Registry lists, driven by `PluginLogic.effectiveLayout` and `PluginLogic.settingsFor`:

- A bar section whose widget id sequence changed is rebuilt whole, in order. A section whose ids are unchanged keeps its widgets. `reconcileBar` keeps one entry per wanted layout entry, a failed build included, so a change to one entry reaches that entry's widget alone.
- A widget whose plugin's source revision changed is rebuilt in its place, and the widgets around it stay. The smoke edits a sibling file the fixture widget imports and reads the new value back from the rebuilt widget, with the build counter and the widgets' positions.
- A widget whose layout entry changed, and any other instance whose `plugins` row changed, receives a fresh `shell` (and, for a widget, `settings`) in place. Nothing else is rebuilt.
- A write that changes no entry an instance reads builds nothing; the smoke asserts it through the build counter and reads delivered settings back.

## Capabilities

A capability is a core API named in the manifest's `capabilities` and delivered as `shell.<name>`. `PluginLogic.js` owns the name list and `Capabilities.qml` holds one provider per name; an unknown name refuses the manifest, and a name without a provider is logged at start. An instance's `shell` holds exactly `manifest`, `settings` and the capabilities it named; the smoke reads the key list back from a fixture naming every capability but `surfaces`, `builtins` and `manager`, and from one naming none.

- The core makes each provider for one instance when it builds the instance. A settings change hands over a new `shell` holding the same providers.
- Every registration a provider makes returns a disposer, and the instance's build record owns it through one lifetime, `shell/Core/Lifetime.js`. Calling a disposer early releases its registration at once and drops it from the record, so a plugin that registers and releases repeatedly (a bar changing its built-in widgets) holds nothing for what it released. Destroying the instance drains what is still pending, newest first, and goes on after one that throws, so disabling a plugin releases every shortcut, IPC target, subscriber and hold it made. `scripts/test-lifetime.js` pins the helper; the smoke asserts each release after disabling its fixture, from the core's lending record and from the compositor or bus the capability reaches, and reads the pending count of a bar back through its built-in cycles.
- `lock` and `polkit` are exclusive: while one plugin holds one, another plugin naming it is not built, and it builds once the holder lets go. `PluginLogic.lendRefusal` decides it. `Registry.buildRefusal`, which `slotKey` reads, follows a copy of the holders taken after each change settles; `reconcileBar` reads the live record. `scripts/test-plugin-logic.js` and the smoke pin it.
- A build that fails after its capabilities were made (an entry point without `shell`, a background without `screen`, a widget without the `BarWidget` properties) drains the same lifetime, leaves no build record and is reported to the host as a failed build.
- Every instance is destroyed under the host key it was built under, so a host whose key changes while its screen goes away still releases everything.
- The notification server and the polkit agent exist only while a plugin holds their capability, so a shell with no such plugin claims neither role. The smoke asserts both objects are gone once the holder is disabled. Whether the process keeps the notification D-Bus name after the server is destroyed is Quickshell's, and [D012](../decisions/D012-core-owns-lent-objects.md) names it as the revisit condition.

Each capability's members are listed in [`.agents/skills/vgs-plugin/references/api.md` § The shell object](../../.agents/skills/vgs-plugin/references/api.md#the-shell-object). Three carry rules of their own: `compositor` offers one function per dispatcher in `Dispatch.PLUGIN_DISPATCHERS`, and `shell/Core/Dispatch.js` refuses an argument that could break out of the session's syntax; `configure` writes only a key the manifest's `schema` declares, with a value of its type, to the configuration entry `PluginLogic.settingTargetOf` names for the calling instance's kind; `lock` keeps a locked session locked when its holder is unloaded.

A capability lands with its name, its provider and a fixture consumer with its smoke rows in the same change.

`Capabilities` maps providers and accounts for holds. Each resource owner keeps its state, registration and release together. New shared connectors follow this contract; stateless providers need no separate component.

## Isolation

- Static: a plugin imports only the prefixes [`api.md` § Allowed imports](../../.agents/skills/vgs-plugin/references/api.md#allowed-imports) lists and files in its own directory, instantiates no window type and no object the core lends, and never calls `Hyprland.dispatch`. `scripts/check-plugin-boundary.py` enforces these four rules on every `.qml` and `.js` file with comments blanked, and `scripts/test-check-plugin-boundary.py` plants one violation per rule. A directory or file the check cannot read ends the run; an incomplete walk certifies nothing.
- The core names no plugin: the same check refuses a first-party id literal or a plugin directory import under `shell/` outside `shell/plugins/`. The default bar id lives in `config/shell.json`.
- Runtime: a plugin receives a scoped `shell` object, never a host singleton. A bar's `shell` is the bar's own; a widget reaching `bar.shell` gets the bar's capabilities, not its own, so a widget uses its own `shell`.
- Not a sandbox: a plugin runs in the shell process with the shell's file and process access, and a visual plugin shares the host's scene, [D010](../decisions/D010-facade-scope-not-sandbox.md).

## Budgets

- `scripts/qml-smoke.sh` runs the shell with its fixture plugins in the nested sandbox and asserts what each host built and each instance received, plus the ceilings its header states: resident size, exec to first bar, and a `setPluginEnabled` reply to the build records. The resident-size ceiling catches a startup allocation blow-up and nothing else.
- A service owns every watcher, poller and subprocess it starts, one owner per source, inside its own tree.
- A plugin holds no cache keyed by data other applications supply without a ceiling.
- The latency ceilings measure the whole shell. No row measures one plugin's latency or memory.

## Decisions

The [decision index](../decisions/INDEX.md) records these contracts and their reasons.
