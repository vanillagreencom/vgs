# Plugins

Covers: shell/plugins/**, shell/Core/Plugins.qml, shell/Core/PluginLogic.js, shell/Core/Config.qml, shell/Commons/**, shell/Ui/**, shell/Hosts/**, config/shell.json, bin/vgsh-scan, .agents/skills/vgs-plugin/**

The plugin contract: what a plugin is, what the core builds for it, what it may use, and where an Omarchy Quattro plugin fits.

## Manifest

A plugin is a directory with `manifest.json` at its root. The schema is Omarchy Quattro's, schema version 1, plus one reserved key. `shell/Core/PluginLogic.js` is the one judge of a manifest; `scripts/check-manifests.js` and `vgsh plugin validate` run that judge offline, and `scripts/test-plugin-logic.js` pins each refusal by its text.

| Field | Read by the core | Meaning |
|---|---|---|
| `schemaVersion` | yes | `1`. Any other value refuses the plugin. |
| `id` | yes | Dotted and author-namespaced, lower case: `author.name`. `vgs.*` is first-party here and `omarchy.*` first-party there. |
| `name`, `version`, `author`, `description` | listed | Listing metadata, all required. |
| `license` | no | Optional SPDX identifier. |
| `kinds` | yes | One or more of `bar-widget`, `bar`, `panel`, `overlay`, `menu`, `service`. |
| `entryPoints` | yes | One QML file per declared kind, keyed `barWidget`, `bar`, `panel`, `overlay`, `menu`, `service`, relative to the plugin root and inside it. |
| `keepLoaded` | no | Omarchy schema, carried and not consumed. |
| `barWidget.defaultSection` | yes | The section `vgsh plugin enable` places the widget in; `center` when absent or unknown. |
| `barWidget.defaults` | yes | The widget's default settings, under its layout entry. |
| `barWidget.displayName`, `category`, `allowMultiple`, `schema` | no | Omarchy schema, carried for the manager's user interface, which does not exist yet. |
| `vgs.capabilities` | yes | Core APIs the plugin uses beyond its kinds. |
| `vgs.budgets` | no | Reserved for the validation row's ceilings. |
| `vgs.requires` | refused | Plugins declare no dependencies, [D005](../decisions/D005-kinds-are-surfaces-no-dependencies.md). |

## Kinds

A kind names a surface the core can host. A plugin declares every kind it can fill and the core builds each one whose host exists and whose configuration enables it. A kind whose host is absent is not built; the plugin's other kinds are.

| Kind | Entry point is | Host | Built when |
|---|---|---|---|
| `bar-widget` | an `Item` extending `BarWidget` from `qs.Ui` | the active bar's sections | placed in a bar section and a bar is active |
| `bar` | an `Item` | `BarHost`, one per screen | it is the active bar; one at a time |
| `service` | a headless `Item` | `ServiceHost` | enabled |
| `panel`, `overlay`, `menu` | an `Item` with `open(payloadJson)` and `close()` | none yet | never, until each host lands with the first plugin of its kind |

Enabled means: the active bar; a bar widget placed in a section; a plugin listed in `plugins`; a first-party plugin declaring a kind other than `bar` and `bar-widget`, unless listed in `disabledPlugins`. `disabledPlugins` wins over every other rule.

Disabling the active bar hides every enabled bar widget and the manager's reply names them. They stay enabled and return with the next bar. Enabling a bar makes it the active bar.

## What the core builds and hands over

- `bin/vgsh-scan` reads every manifest under `shell/plugins/` and `~/.config/vgs/plugins/` in one process. The user directory wins an id collision and the hidden plugin is logged when the collision set changes. The registry replaces its manifest map whole and bumps its generation only when the set changed.
- `PluginSlot` in `shell/Hosts/` owns one instance of one kind: it asks the core to build, rebuilds when the plugin id or the generation changes, and destroys before every rebuild and on its own destruction. Every host is a surface plus slots.
- The core builds an entry point with `Qt.createComponent` on a `file://` URL and assigns its properties after creation, never as initial properties: initial properties cross a QVariant conversion that drops functions and turns nested lists into sequences `Array.isArray` rejects.
- Every instance receives `shell`: its manifest, its settings, the widget catalogue, and one provider per capability its manifest names. A bar widget also receives `bar`, `moduleName` and `settings`. A bar receives `barConfig` and `screen`.
- Settings are the manifest's `barWidget.defaults` under the configuration entry for the plugin: the layout entry for a bar widget, the `plugins` row for every other kind.
- A bar builds its widgets only through `shell.widgets.create` and `shell.widgets.destroy`, so every widget gets its own scope and the core records what it built. A bar never receives a widget's entry point.
- A bar rebuilds a section when that section's entry list changes. A configuration write that leaves the layout alone builds nothing; `scripts/qml-smoke.sh` asserts it through the core's build counter.
- Quickshell watches only files reached from `shell.qml` by static import, so an edit inside a plugin reloads nothing. `vgsh ipc call shell rescanPlugins` re-reads manifests; a changed set bumps the generation every slot keys on.

## Capabilities

A capability is a core API named in the manifest's `vgs.capabilities` and delivered as `shell.<name>`. `PluginLogic.js` owns the name list and `Plugins.qml` maps each name to its provider; an unknown name refuses the manifest.

| Capability | Gives the plugin |
|---|---|
| `compositor` | `shell.compositor.focusWorkspace(id)`: one dispatch through the core's reply judge, in Lua or classic syntax as the session needs |

A capability lands with its name, its provider row and one consuming plugin in the same PR.

## Isolation

- Static: a plugin's QML imports start with `QtQuick`, `QtQml`, `Qt.labs.`, `Quickshell`, `qs.Commons` or `qs.Ui`, never `Quickshell.Wayland` or `QtQuick.Window`; a quoted import stays inside the plugin directory; no window type is named. `scripts/check-plugin-boundary.py` enforces these three rules on `.qml` files and `scripts/test-check-plugin-boundary.py` plants one violation per rule. A plugin's `.js` files are not read.
- The core names no plugin: the same check refuses a first-party id literal or a plugin directory import under `shell/` outside `shell/plugins/`. The default bar id lives in `config/shell.json`.
- Runtime: a plugin receives a scoped `shell` object, never a host singleton. A bar's `shell` is the bar's own; a widget reaching `bar.shell` gets the bar's capabilities, not its own, so a widget uses its own `shell`.
- Not a sandbox: a plugin runs in the shell process with the shell's file and process access, and a visual plugin shares the host's scene, [D010](../decisions/D010-facade-scope-not-sandbox.md).

## Plugin manager

The manager is core: the `Plugins` singleton plus `vgsh plugin`. Its user interface does not exist yet.

- `vgsh plugin list`, `enable <id>`, `disable <id>`, `validate <dir>`. Enable and disable go through the shell's IPC, which writes the user file; the shell watches the file and re-derives the enabled set.
- Configuration is `config/shell.json` merged with `~/.config/vgs/shell.json`, [D006](../decisions/D006-two-configuration-layers.md). `scripts/test-plugin-logic.js` pins each merge rule and the seeding of the user `bar` key.
- A user file that does not parse keeps the last good value and refuses every write until it parses again. A write the disk refuses restores the value in memory and refuses the next write with the error.
- Not yet written: `add <git url>`, `update`, `remove`, [D007](../decisions/D007-install-runs-no-plugin-code.md).

## Omarchy compatibility

An unmodified Omarchy Quattro plugin loads when it uses only what the core provides under Omarchy's names: the manifest schema; the kinds; `qs.Commons` with `Color`, `Style`, `Util`; `qs.Ui` with `BarWidget`; the widget properties `bar`, `moduleName`, `settings`; the bar properties `foreground`, `background`, `urgent`, `fontFamily`, `position`, `vertical`, `barSize`. No plugin written for the other shell has been loaded yet; the compatibility fixture row will pin one marketplace plugin at a recorded commit.

Not yet provided: `Border` in `qs.Commons`, the rest of `qs.Ui`, the injected `omarchyPath`, `pluginRegistry` and `barWidgetRegistry` properties, the four proxied `omarchy.*` services, `bar.run`, tooltips and popouts, and the `call` IPC method. Out of scope: plugins that shell out to `omarchy-*` commands, the `shell.toml` theme pipeline, and the inline `type: "command"` and `type: "qml"` bar modules.

## Budgets

- `scripts/qml-smoke.sh` runs the shell with every bundled plugin and one fixture plugin in the nested sandbox, asserts the widgets each bar built and the capabilities each received, and asserts the resident-size ceiling its header states. That ceiling catches a startup allocation blow-up and nothing else.
- A service owns every watcher, poller and subprocess it starts, one owner per source, inside its own tree.
- A plugin holds no cache keyed by data other applications supply without a ceiling.
- No latency row exists yet; `scripts/bench-shell-events.py` is the tool it will use.

## Decisions

[D003](../decisions/D003-everything-is-a-plugin.md), [D004](../decisions/D004-omarchy-manifest-plus-one-key.md), [D005](../decisions/D005-kinds-are-surfaces-no-dependencies.md), [D006](../decisions/D006-two-configuration-layers.md), [D007](../decisions/D007-install-runs-no-plugin-code.md), [D009](../decisions/D009-one-manifest-judge-under-node.md) and [D010](../decisions/D010-facade-scope-not-sandbox.md).
