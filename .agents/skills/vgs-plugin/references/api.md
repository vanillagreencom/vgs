# Plugin API

What a plugin receives and may call. The core owns every table here; a value not listed does not exist for a plugin.

## Kinds

| Kind | Entry point key | Base | Host today | Built when |
|---|---|---|---|---|
| `bar-widget` | `bar-widget` | `BarWidget` from `qs.Ui` | the active bar's sections | placed in `bar.layout.<section>`, not in `disabledPlugins`, and a bar is active |
| `bar` | `bar` | `Item` declaring the three section containers below | the bar host, one per screen | it is `bar.id` in the configuration |
| `service` | `service` | `Item` | the service host | enabled |
| `background` | `background` | `Item` declaring `property var screen: null` | the background host, one per screen, under every window | enabled |
| `panel` | `panel` | `Item` with `open(payloadJson)` and `close()`, sized by `implicitWidth` and `implicitHeight` | the panel host, on the top layer | enabled and summoned, until hidden |
| `overlay` | `overlay` | `Item` with `open(payloadJson)` and `close()` | the overlay host, covering its screen, on the overlay layer | enabled and summoned, until hidden |
| `menu` | `menu` | `Item` with `open(payloadJson)` and `close()`, sized by `implicitWidth` and `implicitHeight` | the menu host, on the overlay layer | enabled and summoned, until hidden |

Enabled is defined in [`docs/architecture/plugins.md` § Kinds](../../../../docs/architecture/plugins.md#kinds); `PluginLogic.isEnabled` is the judge.

A summoned kind is built on summon and destroyed on hide. `open(payloadJson)` that throws refuses the summon with `refused: open-failed=<id>`, so a payload that does not parse is left to throw. Summoning an open one calls `open` again with the new payload. A panel or menu summoned without an anchor sits at its `placement` setting: `top-left`, `top`, `top-right`, `left`, `center` (the default), `right`, `bottom-left`, `bottom` or `bottom-right`.

## Properties every instance receives

| Property | Type | Assigned by | Meaning |
|---|---|---|---|
| `shell` | object | the core, after creation and again when the plugin's settings change | this plugin's scoped object, table below |

Declare it as `property var shell: null`; the templates do.

## Properties a bar widget also receives

| Property | Type | Meaning |
|---|---|---|
| `bar` | object | the bar API below |
| `moduleName` | string | the plugin id; the core assigns it after creation |
| `settings` | object | the manifest's `settings` under the widget's layout entry, for example `{ "id": "acme.weather", "units": "metric" }`; reassigned when the entry changes |

`BarWidget` adds `barSize` and `setting(name, fallback)`.

## Properties a bar also receives and declares

| Property | Direction | Type | Meaning |
|---|---|---|---|
| `screen` | received | ShellScreen | the screen this bar draws on |
| `leftSection`, `centerSection`, `rightSection` | declared | Item | the containers the core parents widgets into, in layout order; a `RowLayout` in the template |

A bar never creates, destroys or reads a plugin widget. It may draw built-in widgets of its own ahead of them in each container and register each with `shell.builtins`; [`docs/architecture/overview.md` § Vocabulary](../../../../docs/architecture/overview.md#vocabulary) defines the built-in widget.

## The shell object

| Member | Present | Value |
|---|---|---|
| `shell.manifest` | always | this plugin's validated manifest |
| `shell.settings` | always | the manifest's `settings` under the plugin's configuration entry |
| `shell.compositor.focusWorkspace(workspace)`, `.focusWindow(address)`, `.moveWindowToWorkspace(address, workspace)`, `.toggleSpecialWorkspace(name)`, `.closeWindow(address)` | capability `compositor` | one function per dispatcher in `Dispatch.PLUGIN_DISPATCHERS`, each one dispatch through the core's argument check and reply judge; a moved window's workspace does not take focus; returns `ok` or `refused: ...` |
| `shell.configure.set(key, value)` | capability `configure` | writes one schema-declared setting to the entry `PluginLogic.settingTargetOf` names for this instance's kind (the layout entry for a bar widget, the `plugins` row otherwise); returns `ok`, `refused: setting=<key> ...` or `refused: user-config=...` when the user file cannot be written |
| `shell.ipc.handle(name, fn)` | capability `ipc` | `vgsh ipc call <plugin id> invoke <name> <arg>` calls `fn(arg)` and answers its result; returns a disposer |
| `shell.lock.lock(component)`, `.unlock()`, `.locked`, `.secure`, `.hasContent` | capability `lock` | the session lock; the component declares `property var screen` and is built on every screen. `locked` is what was asked for, `secure` what the compositor confirmed. A holder rebuilt while `locked` is true calls `lock(component)` again: the session stays locked but shows only the background colour until it does |
| `shell.notifications.subscribe(fn)`, `.tracked` | capability `notifications` | `fn(notification)` for every notification; set `notification.tracked = true` to keep one; returns a disposer |
| `shell.polkit.agent`, `.registered` | capability `polkit` | the polkit agent: `isActive`, `flow`; `registered` is false while polkitd has not accepted it |
| `shell.run.detached(argv)` | capability `run` | a detached process from a list of non-empty strings; returns `ok` once handed over, or `refused: argv=...`; a program that fails to start is not reported |
| `shell.screens.all`, `.current` | capability `screens` | every screen; the screen this instance draws on, null for a service |
| `shell.shortcut.register(name, description, onPressed)` | capability `shortcut` | a global shortcut bound in Hyprland as `global, <plugin id>:<name>`; returns a disposer |
| `shell.manager.plugins`, `.setEnabled(id, enabled)`, `.setSetting(id, key, value)` | capability `manager` | every discovered plugin as `{ id, name, version, description, kinds, enabled, schema, settings }`; enabling and disabling as `setPluginEnabled` does, with `refused: enabled=<value> want=boolean` for a non-boolean; a setting written to every entry the plugin reads, refused for a disabled plugin; each returns the IPC reply |
| `shell.builtins.register(name, item)` | capability `builtins` | records an item the plugin draws itself under its host key as `<plugin id>/<name>`, origin `plugin`, with this instance's kind; returns a disposer |
| `shell.surfaces.summon(kind, payloadJson, anchor)`, `.hide(kind)`, `.toggle(kind, payloadJson, anchor)` | capability `surfaces` | the plugin's own panel, overlay or menu on this instance's screen, under `anchor` (an item of the plugin's) when given; returns the IPC reply |

A registration name is lower case, digits and dashes. Registering a taken shortcut or IPC name throws an `Error` whose message starts `refused:`. Register shortcuts and IPC handlers from one instance, a service, since every instance of the plugin shares the names. Disabling the plugin runs every disposer; call one to release earlier. `lock` and `polkit` serve one plugin at a time: a second plugin naming either is not built while another holds it.

Nothing else is on it. A capability the manifest did not name is absent, not null.

## The bar API

| Member | Type | Value |
|---|---|---|
| `foreground` | color | `Color.bar.text` |
| `background` | color | `Color.bar.background` |
| `fontFamily` | string | `Style.font.family` |
| `barSize` | int | `Style.bar.sizeHorizontal` |

A widget reads its capabilities from its own `shell`, never from the bar.

## Capabilities

| Name | Grants |
|---|---|
| `compositor` | `shell.compositor` |
| `configure` | `shell.configure`; needs a manifest `schema` |
| `ipc` | `shell.ipc` |
| `lock` | `shell.lock`; exclusive |
| `notifications` | `shell.notifications` |
| `polkit` | `shell.polkit`; exclusive |
| `run` | `shell.run` |
| `screens` | `shell.screens` |
| `shortcut` | `shell.shortcut` |
| `surfaces` | `shell.surfaces` |
| `builtins` | `shell.builtins` |
| `manager` | `shell.manager` |

## Allowed imports

| Prefix | Refused inside it |
|---|---|
| `QtQuick` | `QtQuick.Window` |
| `QtQml` | |
| `Qt.labs.` | |
| `Quickshell` | `Quickshell.Wayland` |
| `qs.Commons`, `qs.Ui` | |
| a quoted path | one that leaves the plugin directory |

Types refused as an instantiation anywhere in a plugin's QML or JS: `PanelWindow`, `FloatingWindow`, `PopupWindow`, `WlSessionLock`, `WlSessionLockSurface`, `WlrLayershell`, `Window`, `ApplicationWindow`, and the types the core lends through a capability: `IpcHandler`, `GlobalShortcut`, `NotificationServer`, `PolkitAgent`. `Hyprland.dispatch` is refused; use `shell.compositor`.

## Tokens in `qs.Commons`

| Token | Type |
|---|---|
| `Color.foreground`, `Color.background`, `Color.accent`, `Color.urgent`, `Color.muted` | color |
| `Color.bar.background`, `Color.bar.text`, `Color.bar.active` | color |
| `Style.cornerRadius` | int |
| `Style.space(units)` | int, four pixels per unit |
| `Style.spacing.xs`, `sm`, `md`, `lg`, `xl` | int |
| `Style.font.family`, `Style.font.size`, `Style.font.small` | string, int, int |
| `Style.bar.sizeHorizontal` | int |
| `Paths.configDir` | string: the directory `shell.json` and `theme.json` are read from |
| `Workspaces.ids`, `Workspaces.focusedId` | list of int, int |
| `Time.now` | date: the shared wall clock, ticking once a minute |
| `Time.holdSeconds(item, wanted)` | function: while any item holds it, `Time.now` ticks once a second; release on destruction |

## IPC

`bin/vgsh ipc call shell <function> [args]`, target `shell`. A call marked guarded answers `refused: guard=unowned pid=<pid>` from an instance the runner did not start.

| Function | Guarded | Reply |
|---|---|---|
| `ping` | no | `ok` |
| `guarded` | no | `true` when started by the runner |
| `listPlugins` | no | JSON: `plugins[]` with `id`, `version`, `kinds`, `enabled`, `dir`; `errors[]`; `collisions[]`; `scanError`; `scanned`; `config` with `ready`, `shipped` and `user` states |
| `listShellConfig` | no | the effective configuration as JSON |
| `built` | no | JSON: host key to the records on that surface, each `id`, `kind`, `origin` (`core` for an instance the core built, `plugin` for a registered built-in) and `capabilities` |
| `buildCount` | no | instances of origin `core` built since start |
| `lent` | no | JSON: `holders` (capability to plugin ids), `shortcuts`, `ipcTargets`, `subscribers`, `notificationServer`, `polkitAgent`, `polkitRegistered`, `lock` |
| `readInstance <hostKey> <id> <property>` | no | that property of the built instance as JSON; `absent` with no such instance, `undefined` with no such property |
| `setPluginEnabled <id> <true|false>` | yes | `ok`, `ok hidden=<ids>`, `unknown: <id>` or `refused: user-config=...` |
| `reloadConfig` | yes | `ok` |
| `rescanPlugins` | yes | `ok`, or `busy` while a scan runs and one more is queued |
| `summon <kind> <id> <payloadJson>`, `hide <kind> <id>`, `toggle <kind> <id> <payloadJson>` | yes | `ok`, `unknown: <id>`, or `refused: not-summonable=<kind>`, `refused: no-host=<kind>`, `refused: kind=<kind> id=<id>`, `refused: scan=pending`, `refused: config=<state>` (the state `Config.notReady` names, [`plugins.md` § Kinds](../../../../docs/architecture/plugins.md#kinds)), `refused: disabled=<id>`, `refused: capability=<name> held-by=<id>`, `refused: screen=none`, `refused: build-failed=<id>`, `refused: open-failed=<id>`; a summon opens on the focused monitor. qs reads a bracketed argument as a list, so a payload is a JSON object |
| `invokeInstance <hostKey> <id> <function> <arg>` | yes | calls that function of the built instance with one text argument and answers its result; `absent` with no such instance, `no-function` with no such function |

## Manifest

The field table is [`docs/architecture/plugins.md` § Manifest](../../../../docs/architecture/plugins.md#manifest). An unknown key refuses the manifest.
