# Plugins

Covers: shell/plugins/**, shell/Hosts/PaneHost.qml, shell/Core/Registry.qml, shell/Core/Plugins.qml, shell/Core/PluginLogic.js, shell/Core/qmldir, shell/Commons/Time.qml, shell/Commons/Workspaces.qml, shell/Commons/qmldir, shell/Ui/**, shell/Hosts/**, bin/vgsh-scan, .agents/skills/vgs-plugin/**

The plugin contract: what a plugin is, what the core builds for it, what it may use, and how the core keeps a running plugin in step with the configuration. Enabling, installing and the manager's user interface are in [manager.md](manager.md).

## Manifest

A plugin is a directory with `manifest.json` at its root. The field table and manifest judge rules are in [plugin-manifest.md](plugin-manifest.md).

## Kinds

A kind names an entry point the core can host on a surface or inside a holder. A plugin declares every kind it can fill. The core builds a surface kind whose host exists and whose configuration enables it; it builds a `pane` only when the panes holder mounts it. A kind whose host or holder is absent is not built; the plugin's other kinds are.

| Kind | Entry point is | Host | Built when |
|---|---|---|---|
| `bar-widget` | an `Item` extending `BarWidget` from `qs.Ui` | the active bar's sections | placed in a bar section, enabled, and a bar is active |
| `bar` | an `Item` declaring `leftSection`, `centerSection` and `rightSection` | `BarHost`, one per screen | it is the active bar; one at a time |
| `service` | a headless `Item` | `ServiceHost` | enabled; at start, once the first bars have drawn a frame ([D047](../decisions/D047-services-build-after-the-first-bar-frame.md)) |
| `background` | an `Item` declaring `screen` | `BackgroundHost`, one per screen, on the layer under every window | enabled |
| `panel`, `overlay`, `menu` | an `Item` with `open(payloadJson)` and `close()` | `SummonHost`, one per kind | enabled and summoned, until hidden |
| `window` | the same | `SummonHost`, as a Hyprland window | enabled and summoned, until hidden or closed |
| `pane` | the same | the enabled holder of capability `panes` | enabled and mounted by that holder |

Enabled means: the active bar, with every other kind it declares; a bar widget placed in a section; any other plugin listed in `plugins` or first-party. A plugin declaring `bar` is enabled only as the active bar. `disabledPlugins` wins over every other rule: a placed widget listed there leaves the bar and its layout entry stays in the file. A listed id no discovered plugin has enables and disables nothing and is reported: [configuration.md § Unknown ids](configuration.md#unknown-ids).

`summon`, `hide` and `toggle` reach the summonable kinds. Which surface each summon builds, a layer surface, a popup under an anchor or a Hyprland window, and how each one opens, closes and places itself, is in [surfaces.md](surfaces.md). An overlay entry may implement `navigate(direction)`, with `left`, `right`, `up` or `down`; the core calls it when the Hyprland capture layer receives a learned directional focus bind. An overlay without it ignores the key.

Disabling the active bar hides every shown bar widget, named in the manager's reply; they return with the next bar. Enabling a bar makes it the active bar.

A background instance may declare `shown`. `BackgroundHost` maps a screen's surface only while an instance there is shown, one without the property included, so a plugin with nothing to draw leaves the screen to whatever draws under it. A hidden layer-shell window deletes its Wayland window and keeps its items, which show it again ([`wlr_layershell.cpp`](https://git.outfoxxed.me/quickshell/quickshell/src/tag/v0.3.1/src/wayland/wlr_layershell/wlr_layershell.cpp) `deleteOnInvisible`, [`proxywindow.cpp`](https://git.outfoxxed.me/quickshell/quickshell/src/tag/v0.3.1/src/window/proxywindow.cpp) `setVisibleDirect`).

## What the core builds and hands over

- `bin/vgsh-scan` reads every manifest and every source file under `shell/plugins/` and `~/.config/vgs/plugins/` in one process and reports every directory or file it could not read as an error, never as absence. The user directory wins an id collision and the hidden plugin is logged when the collision set changes. Each plugin carries a source revision, a hash of every file under its directory except `.git`, and the scan publishes the files of each revision once under `$XDG_RUNTIME_DIR/vgsh-sources-<shell pid>/<revision>/`; the shell loads entry points from there, [D014](../decisions/D014-source-revisions-are-published-snapshots.md). The same process probes every command a manifest's `requirements` declares, once per scan, and reports the ones not on PATH: [requirements.md § Probe](requirements.md#probe). `shell/Core/Registry.qml` holds the manifest map, replaces it whole when the set or any revision changed, and logs `plugins: scan complete changed=<bool>` for every scan it applies; the smoke's no-op rescan row waits on that line. Every scan attempt, applied or failed, ends with its `scanFinished` signal, on which the guarded instance follows the applied theme package: [theme-capability.md § Capability](theme-capability.md#capability).
- `PluginSlot` in `shell/Hosts/` owns one instance of one kind: it asks the core to build, rebuilds when `Registry.slotKey` changes, and destroys before every rebuild and on its own destruction. The key is the plugin id and its source revision, so a change to one plugin's files moves that plugin's keys alone. A manifest or code failure is reported to the host, which takes the surface down, and is remembered for that host, kind and id until its revision changes or its screen goes away. Settings changes do not retry broken code. A slot retries a lending refusal when the holder leaves. Every surface host is a surface plus slots. The panes holder uses `PaneHost` to place a `PluginSlot` inside the holder's item tree, so the mounted pane follows the same `Registry.slotKey` lifecycle as a surface slot.
- The core builds an entry point with `Qt.createComponent` on a `file://` URL and assigns its properties after creation, never as initial properties ([runtime-qml.md](runtime-qml.md) says why). A host hands the core the properties it owns (a bar's `screen`) through the slot's `context`; no host assigns a plugin property itself.
- Every instance receives `shell`: its manifest, its settings, and one provider per capability its manifest names. A bar widget also receives `bar`, `moduleName` and `settings`. A bar also receives `screen`.
- Settings are the manifest's `settings` under the configuration entry for the plugin: the layout entry for a bar widget, the `plugins` row for every other kind. A pane that writes through `configure` writes every entry its plugin reads, the same multi-target contract the manager uses. A row's `keys` is no setting: [hyprland.md](hyprland.md).
- The core mounts bar widgets into the active bar's section containers, in layout order, and records every widget under the bar's host key. The `panes` holder mounts one pane at a time into its own item tree through `PaneHost` and a `PluginSlot`, records it under the holder's host key, and destroys or rebuilds it when `Registry.slotKey` changes. The mounted item fills the holder's container and takes the pane's implicit size as its own, so a holder can grow a scrolling container to a pane taller than its room. The holder draws the section's title and owns its inset and scrolling; a pane is a body drawn from x 0. `vgs.system`, the System window, is the shipped holder: [system-window.md](system-window.md). A bar never builds, destroys or interprets a plugin widget.
- A bar may draw built-in widgets of its own in the same containers, ahead of the plugin widgets, and registers each through its `builtins` capability: [overview.md § Vocabulary](overview.md#vocabulary) defines the built-in widget and [D013](../decisions/D013-built-in-widgets-are-the-bar-plugins.md) records the choice. The core built none of it, so the build counter does not move.
- `vgsh run` disables Quickshell's engine file watcher, so file edits do not reload the engine. `vgsh ipc call shell rescanPlugins` re-reads every plugin; a plugin whose files changed gets a new revision and is rebuilt from its new snapshot, and every other plugin keeps its instances. A rescan asked for while one runs is queued. The registry accepts output only after a successful scanner exit; a failed start, exit or parse keeps the last registry, reports `scanError` and starts no retry.

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
- An overlay component of `qs.Ui` opens a popup that is a child of the host surface and dies with the instance, [components.md](components.md).
- Not a sandbox: a plugin runs in the shell process with the shell's file and process access, and a visual plugin shares the host's scene, [D010](../decisions/D010-facade-scope-not-sandbox.md).

## Budgets

- `scripts/qml-smoke.sh` runs the shell with its fixture plugins in the nested sandbox and asserts what each host built and each instance received, plus the ceilings its header states: resident size, exec to first bar, and a `setPluginEnabled` reply to the build records. The resident-size ceiling catches an allocation blow-up and nothing else.
- A service owns every watcher, poller and subprocess it starts, one owner per source, inside its own tree.
- A plugin holds no cache keyed by data other applications supply without a ceiling.
- The latency ceilings measure the whole shell. No row measures one plugin's latency or memory.

## Decisions

The [decision index](../decisions/INDEX.md) records these contracts and their reasons.
