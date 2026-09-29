# Plugin API

What a plugin receives and may call. The core owns every table here; a value not listed does not exist for a plugin.

## Kinds

| Kind | Entry point key | Base | Host today | Built when |
|---|---|---|---|---|
| `bar-widget` | `bar-widget` | `BarWidget` from `qs.Ui` | the active bar's sections | placed in `bar.layout.<section>`, not in `disabledPlugins`, and a bar is active |
| `bar` | `bar` | `Item` declaring the three section containers below | the bar host, one per screen | it is `bar.id` in the configuration and is not in `disabledPlugins` |
| `service` | `service` | `Item` | the service host | enabled |
| `background` | `background` | `Item` declaring `property var screen: null`, and optionally `property bool shown`: the host maps no surface on a screen while every instance there declares it false | the background host, one per screen, under every window | enabled |
| `panel` | `panel` | `Item` with `open(payloadJson)` and `close()`, sized by `implicitWidth` and `implicitHeight` | the panel host: a popup under its anchor item with a focus grab, or a layer surface on the top layer without one, centred on the whole monitor by default | enabled and summoned, until hidden |
| `overlay` | `overlay` | `Item` with `open(payloadJson)` and `close()` | the overlay host: an anchored popup, or a layer surface covering its screen without an anchor | enabled and summoned, until hidden |
| `menu` | `menu` | `Item` with `open(payloadJson)` and `close()`, sized by `implicitWidth` and `implicitHeight` | the menu host: a popup under its anchor item with a focus grab, or a layer surface on the overlay layer without one | enabled and summoned, until hidden |

Enabled is defined in [`docs/architecture/plugins.md` § Kinds](../../../../docs/architecture/plugins.md#kinds); `PluginLogic.isEnabled` is the judge.

A summoned kind is built on summon and destroyed on hide. `open(payloadJson)` that throws refuses the summon with `refused: open-failed=<id>`, so a payload that does not parse is left to throw. Summoning an open one calls `open` again with the new payload. Pass the item the surface belongs to as `anchor`. The compositor places an anchored surface beside that item in its own window and adjusts it at screen edges. Moving the item moves the popup. An anchored surface takes keyboard focus and closes on a click outside, receiving `close()`. The popup also closes when its anchor is hidden or destroyed. A panel or menu summoned without an anchor sits at its `placement` setting: `top-left`, `top`, `top-right`, `left`, `center` (the default), `right`, `bottom-left`, `bottom` or `bottom-right`. `center` ignores the space a bar reserves and centres on the whole monitor; every other placement keeps clear of it.

## Properties every instance receives

| Property | Type | Assigned by | Meaning |
|---|---|---|---|
| `shell` | object | the core, after creation and again when the plugin's settings change | this plugin's scoped object, table below |

Declare it as `property var shell: null`, or inherit it from `BarWidget`.

## Properties a bar widget also receives

| Property | Type | Meaning |
|---|---|---|
| `bar` | object | the bar API below |
| `moduleName` | string | the plugin id; the core assigns it after creation |
| `settings` | object | the manifest's `settings` under the widget's layout entry, for example `{ "units": "metric" }`; the entry id is excluded; reassigned when the entry changes |

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
| `shell.run.detached(argv)` | capability `run` | a detached process from a list of non-empty strings, with the shell's environment less `VGSH_RUNNER_PID`; returns `ok` once handed over, or `refused: argv=...`; a program that fails to start is not reported |
| `shell.screens.all`, `.current` | capability `screens` | every screen; the screen this instance draws on, null for a service |
| `shell.shortcut.register(name, description, onPressed)` | capability `shortcut` | a global shortcut, `<plugin id>:<name>`, which a bind in the manifest's `hyprland.binds` gives a key; returns a disposer |
| `shell.manager.plugins`, `.setEnabled(id, enabled)`, `.setSetting(id, key, value)`, `.setKey(id, shortcut, key)`, `.update(id)`, `.remove(id)`, `.installRequirements(id)`, `.add()` | capability `manager` | every discovered plugin as `{ id, name, version, description, author, license, icon, kinds, capabilities, source, enabled, schema, settings, status, binds, requirements, errors }`, `source` `bundled` or `installed`, `status` one `{ key, type, label, group, hint, command, report, value, tone }` per status entry the Settings page draws, `report` `reported` or `unreported`, `binds` one `{ shortcut, key, default, description }` per manifest bind with the key in effect (null when unbound), `requirements` one `{ command, packages, optional, purpose, state }` per manifest requirement, `state` `present` or `missing` from the last scan, `errors` its failed builds and Hyprland layer problems; enabling and disabling as `setPluginEnabled` does, with `refused: enabled=<value> want=boolean` for a non-boolean; a setting written to every entry the plugin reads; a key written to the plugin's `plugins[].keys`, a string to rebind, null to unbind, undefined to return to the manifest's key, `refused: key=<shortcut> ...` for an undeclared shortcut or a malformed key; a setting or key is refused for a disabled plugin; each returns the IPC reply; `update` and `remove` open `vgsh plugin update <id>` and `vgsh plugin remove <id>` in a core floating TUI, and `add` opens `core/plugin-add`, `vgsh plugin add` asking for the URL, answering `ok` when the launcher started or the busy key's live window was asked to take focus, `unknown: <id>`, `refused: bundled=<id>` for a bundled plugin, or `refused: tui=core/<name> reason=launcher-missing`; `installRequirements` shows the requirement notice for any plugin with every missing command, answering `ok`, `unknown: <id>`, `refused: requirements=<id> reason=satisfied` or `refused: notices=full limit=<n>` |
| `shell.builtins.register(name, item)` | capability `builtins` | records an item the plugin draws itself under its host key as `<plugin id>/<name>`, origin `plugin`, with this instance's kind; returns a disposer |
| `shell.surfaces.summon(kind, payloadJson, anchor)`, `.hide(kind)`, `.toggle(kind, payloadJson, anchor)` | capability `surfaces` | the plugin's own panel, overlay or menu, never another plugin's: another plugin's surface, such as a Settings page, opens through `vgsh ipc call shell summon <kind> <id> '<payload>'`; pass its source item as `anchor` for a compositor-placed popup, or omit it for layer placement on this instance's screen; returns the IPC reply |
| `shell.toasts.show({ title, message, tone, icon, duration })` | capability `toasts` | one toast in the core's stack: `title` required, `tone` one of the badge tones, `duration` in milliseconds with 0 for until dismissed and the theme's default when omitted; returns a disposer that ends it; throws `refused: toast=<reason>` for a malformed option and `refused: toasts=full` past the core's ceiling |
| `shell.layers.show(component)` | capability `layers` | one copy of `component`, a `Component` the plugin declares, on every screen, in a surface on the overlay layer that covers the screen clear of reserved space and never takes keyboard focus; the core assigns each copy `screen`, and pointer input reaches it everywhere while its `inputAll` is true, otherwise only in its `inputItem`; returns a disposer; throws `refused: layers=not-a-component` or `refused: layers=component-not-ready status=<n>`: [`docs/architecture/layers.md`](../../../../docs/architecture/layers.md) |
| `shell.status.set(key, value)`, `.values`, `.revision` | capability `status` | publishes one value the manifest's `status` declares, with a value of its type, for every instance of the plugin; returns `ok` or `refused: status=<key> reason=undeclared|type|size|retired`; `values` is every published value, bindable, each read a deep-frozen copy of its own, `{}` before the first write, and `revision` the serial of the last write, 0 before one; the record goes when the plugin is disabled or its source changes: [`docs/architecture/status.md`](../../../../docs/architecture/status.md) |
| `shell.tui.run(name, args, done)`, `.entries`, `.open(key)`, `.state` | capability `tui` | `run` opens one of this plugin's own scripts from the manifest's `tui` key, from its published snapshot, with `args` (absent, or at most 16 strings of 1 to 256 characters with no control character) as argv after the script, and calls `done`, when given, once with `{ code, reason }` when the run ends, dropped with the instance; `state` is this plugin's scripts by name as `{ running, code, endedAt }`, the same for every instance; `entries` is every listed TUI, the core's `core/<name>` and every enabled plugin's `<plugin id>/<name>`, each `{ key, plugin, name, title, label, icon, group }`; `open` opens a listed key with no arguments. Both return `ok` once the launcher starts, or `refused: tui=<name> reason=undeclared\|disabled\|args\|busy\|launcher-missing`, `busy` while a run of the key is live, whose window the core focuses, and `launcher-missing` while the core found no terminal launcher; a later call answers `ok` once one is installed: [`docs/architecture/tui-capability.md` § The capability](../../../../docs/architecture/tui-capability.md#the-capability) |
| `shell.requirements.offer(commands)`, `.missing` | capability `requirements` | `missing` is the plugin's own declared commands the last scan did not find on PATH, in declaration order, a copy per read, bindable; `offer` raises the core's requirement notice for this plugin's own missing commands: `commands` is a list of 1 to 16 commands its manifest's `requirements` declares, and the notice lists and installs each that the last scan did not find, optional or not; returns `ok` when a notice shows or waits, merged into one the plugin already holds, `satisfied` when none is missing, `refused: requirements=malformed`, `refused: requirement=<command> reason=undeclared`, `refused: requirements=<id> reason=resting retry-ms=<ms>` for 10 minutes after the user answered this plugin's notice Not now, or `refused: notices=full limit=8`; the notice outlives the instance: [`docs/architecture/requirement-notice.md`](../../../../docs/architecture/requirement-notice.md) |
| `shell.doctor.offer(owner, commands)`, `.missing` | capability `doctor` | a view of every owner's requirements: `offer` raises the core's requirement notice, on the user's press, for `owner`, `core` or an enabled plugin's id, and 1 to 16 commands that owner declares, with no rest: it answers `ok` and raises the notice after a scan it starts, for each command that scan finds missing, or at once `refused: owner=malformed`, `refused: owner=<owner> reason=unknown`, `refused: owner=<id> reason=disabled` or an offer's own refusal; `missing` is the last scan's missing commands of the core and of every enabled plugin by owner id, each read a copy, bindable: [`docs/architecture/requirement-notice.md`](../../../../docs/architecture/requirement-notice.md) |
| `shell.theme.list(done)`, `.apply(name, done)`, `.background(step, done)`, `.catalog(done)`, `.install(name, done)`, `.images(scope, done)`, `.set(path, screen, done)`, `.wallpapers(name, done, options)`, `.swatch(name)`, `.current`, `.revision`, `.fileState`, `.modified`, `.last` | capability `theme` | `list` hands `done` `{ file, packages, reason }` as `vgsh theme list --json` prints them, `reason` null, or `file` and `packages` null beside the reason the runner could not report them; `apply` starts `vgsh theme apply --json <name>` and returns `ok`, or `refused: theme=<name> reason=busy` while another apply runs and `reason=malformed-name` at once, and `done` receives the structured result `{ state, shell, targets, theme, reason }`, every other refusal included; `background` starts `vgsh theme background --json <step>` for `next` or `previous` and returns `ok`, or `refused: background=<step> reason=malformed-step` at once, and `done` receives `{ state, background, theme, path, reason }`, every refusal included; `catalog` hands `done` `{ entries, reason }` as `vgsh theme catalog --json` prints the entries, `reason` null, or `entries` null beside the reason; `install` starts `vgsh theme install --json <name>` and returns `ok`, or `refused: theme=<name> reason=malformed-name` at once, and `done` receives `{ state, theme, path, shadows, reason }`; `images` starts `vgsh theme background --json list`, with `--all` for scope `all`, for scope `applied` or `all` and returns `ok`, or `refused: images=<scope> reason=malformed-scope` at once, and `done` receives `{ state, images, reason }`; `set` starts `vgsh theme background --json set <path>`, with `--screen <screen>` for an output name and `--every-screen` for screen `*`, which clears each screen's own image, and returns `ok`, or `refused: set=<path> reason=malformed-path` for a path that is not absolute and `refused: set=<screen> reason=malformed-screen` for any other screen that is not null, at once, and `done` receives `{ state, background, theme, path, screen, reason }`; `wallpapers` starts `vgsh theme wallpapers --json <name>` on the download lane, which runs beside the other jobs, with `--update` for `options` `{ update: true }`, and returns `ok`, or `refused: wallpapers=<name> reason=malformed-name`, `refused: wallpapers=<options JSON> reason=malformed-options` for options other than absent or `{ update: <boolean> }`, or `reason=busy` while a download runs, at once, and `done` receives `{ state, theme, wallpapers, images, sha256, reason }`; each of these hands `done` every other refusal; `swatch` is one accepted package's palette from the last list as `#aarrggbb` strings, null for a refused or unknown package; `current`, `revision` and `fileState` are `Theme.name`, `Theme.revision` and `Theme.fileState`, and `done` can run before they move; `modified` is the last list's answer, null before one; `last` is `{ applying, result, downloading }`, the apply running, the last result and the running download's `{ name, state, bytes, total }` or null, kept by the core across instances; `result` is also the result, with its `follow` outcome, of a follow that applied the changed package again; a destroyed instance's `done` is dropped and its job still completes. Contract: [`docs/architecture/theme-capability.md`](../../../../docs/architecture/theme-capability.md). `done` that is not a function throws `refused: theme=<verb> done=not-a-function` |

A registration name is lower case, digits and dashes. Registering a taken shortcut or IPC name throws an `Error` whose message starts `refused:`. Register shortcuts and IPC handlers from one instance, a service, since every instance of the plugin shares the names. Disabling the plugin runs every disposer; call one to release earlier. `lock` and `polkit` serve one plugin at a time: a second plugin naming either is not built while another holds it.

Nothing else is on it. A capability the manifest did not name is absent, not null.

## The bar API

| Member | Type | Value |
|---|---|---|
| `foreground` | color | `Theme.bar.foreground` |
| `background` | color | `Theme.bar.background` |
| `fontFamily` | string | `Theme.text.bar.family` |
| `barSize` | int | `Theme.bar.height` |

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
| `toasts` | `shell.toasts` |
| `theme` | `shell.theme` |
| `layers` | `shell.layers` |
| `status` | `shell.status`; needs a manifest `status` |
| `tui` | `shell.tui`; a manifest `tui` key needs it |
| `requirements` | `shell.requirements` |
| `doctor` | `shell.doctor` |

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

## Components in `qs.Ui`

`shell/Ui/qmldir` is the list. Each component's header states what it takes; the names below are what a plugin composes.

| Component | Base | Takes |
|---|---|---|
| `Label` | `Text` | `role`: a group of `Theme.text` (`display`, `h1`, `h2`, `h3`, `eyebrow`, `subheading`, `body`, `bodyStrong`, `label`, `hint`, `tooltip`, `button`, `code`) |
| `Icon` | `Item` | `name`: a Lucide icon; `size`, `color`, `stroke` |
| `Surface`, `Divider`, `FocusRing` | `Rectangle` | `level`; `vertical`; `target` |
| `Button`, `IconButton`, `ToggleButton` | `T.Button` | `text`, `iconName`, `variant` (`primary`, `secondary`, `tertiary`, `ghost`, `danger`), `size` (`sm`, `md`, `lg`); `label` for an icon button |
| `SegmentedControl` | `Rectangle` | `model`, `currentIndex`, `activated(index)` |
| `Switch`, `Checkbox`, `Radio` | `T.Switch`, `T.CheckBox`, `T.RadioButton` | `text`, `checked` |
| `Slider` | `T.Slider` | `from`, `to`, `value`, `stepSize` |
| `TextField` | `T.TextField` | `placeholderText`, `leadingIcon`, `trailingIcon`, `actions`, `error`, `validator` |
| `Field` | `Column` | `label`, `hint`, `error`, `inline`; the control as its child |
| `Spinner`, `ProgressBar` | `Item`, `T.ProgressBar` | `running`; `value`, `indeterminate` |
| `Badge`, `Kbd` | `Rectangle` | `text`, `iconName`, `tone` (`neutral`, `accent`, `success`, `warning`, `danger`, `info`); `text` |
| `CodeLine` | `Rectangle` | `text`, a command or path, wrapped whole; `copyLabel`, the Copy button's label; `copy()`, `copied()`, `confirming` while the button shows its check mark |
| `ScrollArea` | `Flickable` | its children; `overflowing`, and `bar`, the embedded bar, which a gutter keeps clear of the content |
| `Tabs` | `T.TabBar` | `model`, `currentIndex` |
| `ListItem` | `T.ItemDelegate` | `text`, `secondary`, `iconName`, `trailing`, `highlighted` |
| `SectionHeader` | `Column` | `text`, `description`; `leftPadding` and `rightPadding` inset both lines |
| `Select` | `T.AbstractButton` | `model`, `currentIndex`, `textRole`; `openList()`; the list opens in its own surface and scrolls under the embedded bar |
| `Popover` | `Item` | its content as children, `width`; `open()`, `close()`, `opened`; a surface under the item it is declared in |
| `Tooltip` | `Item` | `text`; opens on hover of the item it is declared in |
| `Menu`, `MenuItem` | `Item`, `T.MenuItem` | `MenuItem` children with `text`, `iconName`, `shortcut`, `checked` (a check mark), `triggered`; `maxHeight`; `open()`, `close()`, `toggle()`; typed letters jump to an entry |
| `TitleButton` | `T.AbstractButton` | `text`, `role` (a group of `Theme.text`, `h3` by default), `menu`: a `Menu` declared inside it, which a click, Enter or Down opens |
| `Toast` | `Rectangle` | `title`, `message`, `tone`, `iconName`, `dismissed`; the core's toast host draws it, a plugin shows one through `shell.toasts` |
| `Dialog` | `FocusScope` | `title`, `message`, `actions` (each `{ label, role, variant, enabled }`, `role` `accept` or `cancel`), `busy`, `accepted`, `rejected`; content as children, under the message; a card its host places and hides |
| `AngledCard` | `Item` | content as children, clipped to a parallelogram; `skew` (negative leans left), `selected`, `dimmed` (by default while not selected); `corners`, the parallelogram in the card's coordinates; the caller sizes and places it |
| `CardCarousel` | `Item` | `model`, as a Repeater takes it; `delegate`, one card's content, whose root declares `required property var modelData` and `required property size decodeSize`, the size an image in it decodes at, or the card stays empty with one warning; `currentIndex`, `activated(index)` on a click of the current card, `step(delta)`, wrapping; `devicePixelRatio`, the screen's by default; takes the keys once it has the focus; the caller sizes and places it |
| `Scrim` | `Rectangle` | fills its parent with `color.scrim`, takes the presses, hover and wheel on it and emits `clicked`; declare the modal surface after it |

A name a component does not know is logged and drawn as the default. A control's `background`, `contentItem`, `indicator` or `handle` may be replaced on one instance to restyle it.

## Singletons in `qs.Commons`

| Member | Type |
|---|---|
| `Theme.<group>.<token>` | the design tokens: one read-only group per top-level group of `shell/Commons/Tokens.js`, each token a primitive: a colour as the string `#aarrggbb` a `color` property takes (call `Qt.color` on it for channels), an `int` of pixels or milliseconds, a `string`, a `bool`, an `Easing` enumerator; `docs/architecture/design-system.md` states the tiers |
| `Theme.appearance(TOKENS, LIGHT)` | function: a plugin-owned look, the plugin's own table resolved against the theme's `scheme.mode`, `palette.accent` and `motion.scale` alone, frozen and converted as the groups are; null after a logged refusal. Only for a plugin whose manifest names `appearance`: [`docs/architecture/appearance.md`](../../../../docs/architecture/appearance.md) |
| `Theme.name`, `Theme.revision`, `Theme.fileState` | string, int, string: the accepted theme's name, a counter that rises after every group holds a new theme, and the theme file's state (`pending`, `loaded`, `absent`, `refused`, `unreadable`), which a refused edit moves without a new revision |
| `Paths.configDir` | string: the directory `shell.json` and `theme.json` are read from |
| `Paths.stateDir` | string: `${XDG_STATE_HOME:-~/.local/state}/vgs`, where `vgsh theme` keeps what it applied |
| `Workspaces.ids`, `Workspaces.focusedId` | list of int, int |
| `Time.now` | date: the shared wall clock, ticking once a minute |
| `Time.holdSeconds(item, wanted)` | function: while any item holds it, `Time.now` ticks once a second; release on destruction |

`WatchedFile` in `qs.Commons` reads a file again whenever it changes, and an edit that lands during a read is read again: `path` (required, set once), `read()`, `write(content)`, `busy`, and the signals `loaded(content)`, `loadFailed(error)`, `saved()`, `saveFailed(error)` and `changed()`. The header of `shell/Commons/WatchedFile.qml` states the contract; [`runtime-qml.md`](../../../../docs/architecture/runtime-qml.md) states the Quickshell behaviour it works around.

## IPC

`bin/vgsh ipc call shell <function> [args]`, target `shell`. A call marked guarded answers `refused: guard=unowned pid=<pid>` from an instance the runner did not start.

| Function | Guarded | Reply |
|---|---|---|
| `ping` | no | `ok` |
| `guarded` | no | `true` when started by the runner |
| `listPlugins` | no | JSON: `plugins[]` with `id`, `version`, `kinds`, `enabled`, `dir`, `revision`, `requirements` (each declared command with its `state`, `present` or `missing`); `errors[]`; `collisions[]`; `scanError`; `scanned`; `config` with `ready`, `shipped` and `user` states |
| `listShellConfig` | no | the effective configuration as JSON |
| `built` | no | JSON: host key to the records on that surface, each `id`, `kind`, `origin` (`core` for an instance the core built, `plugin` for a registered built-in) and `capabilities` |
| `lent` | no | JSON: `holders` (capability to plugin ids), `shortcuts`, `ipcTargets`, `subscribers`, `notificationServer`, `polkitAgent`, `polkitRegistered`, `lock`, `toasts`, `layers` (plugin and screens per registration), `status` (plugin id to its record's `keys`, `revision` and `bytes`), `theme` with its `jobs` (`verb` `list`, `apply`, `background`, `catalog`, `install`, `images`, `set` or `follow`, `name`, `started`, `waiters`), its `download` (the running `wallpapers` job in the same shape, or null) and `last` |
| `setPluginEnabled <id> <true|false>` | yes | `ok`, `ok hidden=<ids>`, `unknown: <id>` or `refused: user-config=...` |
| `reloadConfig` | yes | `ok` |
| `rescanPlugins` | yes | `ok`, or `busy` while a scan runs and one more is queued |
| `summon <kind> <id> <payloadJson>`, `hide <kind> <id>`, `toggle <kind> <id> <payloadJson>` | yes | `ok`, `unknown: <id>`, or `refused: not-summonable=<kind>`, `refused: no-host=<kind>`, `refused: kind=<kind> id=<id>`, `refused: scan=pending`, `refused: config=<state>` (the state `Config.notReady` names, [`plugins.md` § Kinds](../../../../docs/architecture/plugins.md#kinds)), `refused: disabled=<id>`, `refused: capability=<name> held-by=<id>`, `refused: screen=none`, `refused: build-failed=<id>`, `refused: open-failed=<id>`; a summon opens on the focused monitor. qs reads a bracketed argument as a list, so a payload is a JSON object |

## Manifest

The field table is [`docs/architecture/plugins.md` § Manifest](../../../../docs/architecture/plugins.md#manifest). An unknown key refuses the manifest.
