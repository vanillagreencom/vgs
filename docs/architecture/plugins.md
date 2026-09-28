# Plugins

Covers: shell/plugins/**, shell/Core/Registry.qml, shell/Core/Plugins.qml, shell/Core/PluginLogic.js, shell/Core/qmldir, shell/Commons/Time.qml, shell/Commons/Workspaces.qml, shell/Commons/qmldir, shell/Ui/**, shell/Hosts/**, bin/vgsh-scan, .agents/skills/vgs-plugin/**

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
| `appearance` | no | A `.js` file inside the plugin holding the plugin's own look, which the theme reaches through its mode and accent alone: [appearance.md](appearance.md). |

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

`summon <kind> <id> <payloadJson>`, `hide <kind> <id>` and `toggle` reach the summonable kinds, over IPC or through the plugin's own `surfaces` capability. A summon with an anchor item creates a popup relative to that item's window; a summon without an anchor creates a layer surface on the screen it came from (the focused monitor for IPC). The host builds the plugin in it and calls `open(payloadJson)`; summoning an open plugin calls `open` again with the new payload and builds nothing. `hide` destroys the surface after the slot calls `close()`, so a hidden plugin keeps no Wayland object; a plugin disabled while summoned is closed the same way. An `open()` that throws refuses the summon with `refused: open-failed=<id>`; a `close()` that throws is logged and the surface still goes. A summon of a plugin that cannot be built now answers `Registry.buildRefusal`, which names the cause: the scan pending, the configuration not ready (`refused: config=<state>`), the plugin unknown or disabled, or an exclusive capability held by another plugin. An anchored popup opens below its item, centred on it; the compositor flips or slides it at screen edges and moves it when the host updates the anchor after the item or an ancestor moved. An anchored popup takes a focus grab, whichever kind it is: keyboard input reaches it under a bar whose layer takes none, and a click outside hides it and calls `close()`. Hiding or destroying the anchor closes its popup. With no anchor, a panel or menu uses the plugin's `placement` setting clear of reserved space; `PluginLogic.PLACEMENTS` lists the values. An unanchored overlay covers its screen. `PluginLogic.surfacePlacement` decides layer placement; `SummonPopup` delegates anchored placement to [PopupAnchor](https://quickshell.org/docs/v0.3.1/types/Quickshell/PopupAnchor/) and dismissal to [PopupWindow](https://quickshell.org/docs/v0.3.1/types/Quickshell/PopupWindow/).

Disabling the active bar hides every shown bar widget, named in the manager's reply; they return with the next bar. Enabling a bar makes it the active bar.

A background instance may declare `shown`. `BackgroundHost` maps a screen's surface only while an instance there is shown, one without the property included, so a plugin with nothing to draw leaves the screen to whatever draws under it. A hidden layer-shell window deletes its Wayland window and keeps its items, which show it again ([`wlr_layershell.cpp`](https://git.outfoxxed.me/quickshell/quickshell/src/tag/v0.3.1/src/wayland/wlr_layershell/wlr_layershell.cpp) `deleteOnInvisible`, [`proxywindow.cpp`](https://git.outfoxxed.me/quickshell/quickshell/src/tag/v0.3.1/src/window/proxywindow.cpp) `setVisibleDirect`).

## What the core builds and hands over

- `bin/vgsh-scan` reads every manifest and every source file under `shell/plugins/` and `~/.config/vgs/plugins/` in one process and reports every directory or file it could not read as an error, never as absence. The user directory wins an id collision and the hidden plugin is logged when the collision set changes. Each plugin carries a source revision, a hash of every file under its directory except `.git`, and the scan publishes the files of each revision once under `$XDG_RUNTIME_DIR/vgsh-sources-<shell pid>/<revision>/`; the shell loads entry points from there, [D014](../decisions/D014-source-revisions-are-published-snapshots.md). `shell/Core/Registry.qml` holds the manifest map, replaces it whole when the set or any revision changed, and logs `plugins: scan complete changed=<bool>` for every scan it applies; the smoke's no-op rescan row waits on that line.
- `PluginSlot` in `shell/Hosts/` owns one instance of one kind: it asks the core to build, rebuilds when `Registry.slotKey` changes, and destroys before every rebuild and on its own destruction. The key is the plugin id and its source revision, so a change to one plugin's files moves that plugin's keys alone. A manifest or code failure is reported to the host, which takes the surface down, and is remembered for that host, kind and id until its revision changes or its screen goes away. Settings changes do not retry broken code. A slot retries a lending refusal when the holder leaves. Every host is a surface plus slots.
- The core builds an entry point with `Qt.createComponent` on a `file://` URL and assigns its properties after creation, never as initial properties ([runtime-qml.md](runtime-qml.md) says why). A host hands the core the properties it owns (a bar's `screen`) through the slot's `context`; no host assigns a plugin property itself.
- Every instance receives `shell`: its manifest, its settings, and one provider per capability its manifest names. A bar widget also receives `bar`, `moduleName` and `settings`. A bar also receives `screen`.
- Settings are the manifest's `settings` under the configuration entry for the plugin: the layout entry for a bar widget, the `plugins` row for every other kind.
- The core mounts bar widgets into the active bar's section containers, in layout order, and records every widget under the bar's host key. A bar never builds, destroys or interprets a plugin widget.
- A bar may draw built-in widgets of its own in the same containers, ahead of the plugin widgets, and registers each through its `builtins` capability: [overview.md § Vocabulary](overview.md#vocabulary) defines the built-in widget and [D013](../decisions/D013-built-in-widgets-are-the-bar-plugins.md) records the choice. The core built none of it, so the build counter does not move.
- Quickshell watches only files reached from `shell.qml` by static import, so an edit inside a plugin reloads nothing by itself. `vgsh ipc call shell rescanPlugins` re-reads every plugin; a plugin whose files changed gets a new revision and is rebuilt from its new snapshot, and every other plugin keeps its instances. A rescan asked for while one runs is queued. The registry accepts output only after a successful scanner exit; a failed start, exit or parse keeps the last registry, reports `scanError` and starts no retry.

## Reconciliation

Every configuration change reaches every running instance through one reconcile in `shell/Core/Plugins.qml`, which builds and destroys every instance from what the Registry lists, driven by `PluginLogic.effectiveLayout` and `PluginLogic.settingsFor`:

- A bar section whose widget id sequence changed is rebuilt whole, in order. A section whose ids are unchanged keeps its widgets. `reconcileBar` keeps one entry per wanted layout entry, a failed build included, so a change to one entry reaches that entry's widget alone.
- A widget whose plugin's source revision changed is rebuilt in its place, and the widgets around it stay. The smoke edits a sibling file the fixture widget imports and reads the new value back from the rebuilt widget, with the build counter and the widgets' positions.
- A widget whose layout entry changed, and any other instance whose `plugins` row changed, receives a fresh `shell` (and, for a widget, `settings`) in place. Nothing else is rebuilt.
- A write that changes no entry an instance reads builds nothing; the smoke asserts it through the build counter and reads delivered settings back.

## Capabilities

A capability is a core API named in the manifest's `capabilities` and delivered as `shell.<name>`, one provider per instance, every registration released with it: [capabilities.md](capabilities.md).

## Isolation

- Static: a plugin imports only the prefixes [`api.md` § Allowed imports](../../.agents/skills/vgs-plugin/references/api.md#allowed-imports) lists and files in its own directory, instantiates no window type and no object the core lends, and never calls `Hyprland.dispatch`. `scripts/check-plugin-boundary.py` enforces these four rules on every `.qml` and `.js` file with comments blanked, and `scripts/test-check-plugin-boundary.py` plants one violation per rule. A directory or file the check cannot read ends the run; an incomplete walk certifies nothing.
- The core names no plugin: the same check refuses a first-party id literal or a plugin directory import under `shell/` outside `shell/plugins/`. The default bar id lives in `config/shell.json`.
- Runtime: a plugin receives a scoped `shell` object, never a host singleton. A bar's `shell` is the bar's own; a widget reaching `bar.shell` gets the bar's capabilities, not its own, so a widget uses its own `shell`.
- An overlay component of `qs.Ui` opens a popup that is a child of the host surface and dies with the instance, [design-system.md § Components](design-system.md#components).
- Not a sandbox: a plugin runs in the shell process with the shell's file and process access, and a visual plugin shares the host's scene, [D010](../decisions/D010-facade-scope-not-sandbox.md).

## Budgets

- `scripts/qml-smoke.sh` runs the shell with its fixture plugins in the nested sandbox and asserts what each host built and each instance received, plus the ceilings its header states: resident size, exec to first bar, and a `setPluginEnabled` reply to the build records. The resident-size ceiling catches a startup allocation blow-up and nothing else.
- A service owns every watcher, poller and subprocess it starts, one owner per source, inside its own tree.
- A plugin holds no cache keyed by data other applications supply without a ceiling.
- The latency ceilings measure the whole shell. No row measures one plugin's latency or memory.

## Decisions

The [decision index](../decisions/INDEX.md) records these contracts and their reasons.
