# Plugin API

What a plugin receives and may call. The core owns every table here; a value not listed does not exist for a plugin.

## Kinds

| Kind | Entry point key | Base | Host today | Built when |
|---|---|---|---|---|
| `bar-widget` | `barWidget` | `BarWidget` from `qs.Ui` | the active bar's sections | placed in `bar.layout.<section>` and a bar is active |
| `bar` | `bar` | `Item` | the bar host, one per screen | it is `bar.id` in the configuration |
| `service` | `service` | `Item` | the service host | enabled |
| `panel` | `panel` | `Item` with `open(payloadJson)` and `close()` | none | never, until the panel host lands |
| `overlay` | `overlay` | `Item` with `open(payloadJson)` and `close()` | none | never, until the overlay host lands |
| `menu` | `menu` | `Item` with `open(payloadJson)` and `close()` | none | never, until the menu host lands |

## Properties every instance receives

| Property | Type | Assigned by | Meaning |
|---|---|---|---|
| `shell` | object | the core, after creation | this plugin's scoped object, table below |

Declare it as `property var shell: null`; the templates do.

## Properties a bar widget also receives

| Property | Type | Meaning |
|---|---|---|
| `bar` | object | the bar API below |
| `moduleName` | string | the plugin id; the template sets it |
| `settings` | object | `barWidget.defaults` under the widget's layout entry, for example `{ "id": "vgs.clock", "format": "HH:mm" }` |

`BarWidget` adds `vertical`, `barSize` and `setting(name, fallback)`.

## Properties a bar also receives

| Property | Type | Meaning |
|---|---|---|
| `barConfig` | object | the effective `bar` configuration; reassigned when the layout changes |
| `screen` | ShellScreen | the screen this bar draws on |

## The shell object

| Member | Present | Value |
|---|---|---|
| `shell.manifest` | always | this plugin's validated manifest |
| `shell.settings` | always | `barWidget.defaults` under the plugin's configuration entry |
| `shell.widgets.manifestFor(id)` | always | a plugin's manifest, or undefined |
| `shell.widgets.create(id, parent, bar, entry)` | always | builds an enabled bar widget under `parent` with its own `shell`, or null after logging |
| `shell.widgets.destroy(instance)` | always | destroys a widget `create` built |
| `shell.compositor.focusWorkspace(id)` | capability `compositor` | one dispatch through the core's reply judge |

## The bar API

| Member | Type | Value |
|---|---|---|
| `foreground` | color | `Color.bar.text` |
| `background` | color | `Color.bar.background` |
| `urgent` | color | `Color.urgent` |
| `fontFamily` | string | `Style.font.family` |
| `position` | string | `"top"` |
| `vertical` | bool | `false` |
| `barSize` | int | `Style.bar.sizeHorizontal` |

A widget reads its capabilities from its own `shell`, never from the bar.

## Capabilities

| Name | Grants |
|---|---|
| `compositor` | `shell.compositor` |

## Allowed imports

| Prefix | Refused inside it |
|---|---|
| `QtQuick` | `QtQuick.Window` |
| `QtQml` | |
| `Qt.labs.` | |
| `Quickshell` | `Quickshell.Wayland` |
| `qs.Commons`, `qs.Ui` | |
| a quoted path | one that leaves the plugin directory |

Names refused anywhere in a plugin's QML: `PanelWindow`, `FloatingWindow`, `PopupWindow`, `WlSessionLock`, `WlSessionLockSurface`, `WlrLayershell`, `Window`, `ApplicationWindow`.

## Tokens in `qs.Commons`

| Token | Type |
|---|---|
| `Color.foreground`, `Color.background`, `Color.accent`, `Color.urgent`, `Color.muted` | color |
| `Color.bar.background`, `Color.bar.text`, `Color.bar.active` | color |
| `Style.cornerRadius` | int |
| `Style.space(units)` | int, four pixels per unit |
| `Style.spacing.xs`, `sm`, `md`, `lg`, `xl`, `controlGap`, `controlPaddingX` | int |
| `Style.font.family`, `Style.font.size`, `Style.font.small` | string, int, int |
| `Style.bar.sizeHorizontal`, `Style.bar.sizeVertical` | int |
| `Workspaces.ids`, `Workspaces.focusedId` | list of int, int |
| `Util.alpha(color, opacity)`, `Util.fileUrl(path)`, `Util.shellQuote(value)` | function |

## IPC

`bin/vgsh ipc call shell <function> [args]`, target `shell`:

| Function | Reply |
|---|---|
| `ping` | `ok` |
| `guarded` | `true` when started by the runner |
| `listPlugins` | JSON: `plugins[]` with `id`, `version`, `kinds`, `enabled`, `dir`; `errors[]`; `collisions[]`; `scanError`; `scanned` |
| `listShellConfig` | the effective configuration as JSON |
| `built` | JSON: host key to the instances the core built there, each `id`, `kind`, `capabilities` |
| `buildCount` | instances built since start |
| `setPluginEnabled <id> <true|false>` | `ok`, `ok hidden=<ids>`, `unknown: <id>` or `refused: user-config=...` |
| `reloadConfig` | `ok` |
| `rescanPlugins` | `ok`, or `busy` while a scan runs and one more is queued |
| `summon <kind> <id> <payloadJson>`, `hide <kind> <id>`, `toggle <kind> <id> <payloadJson>` | `refused: no-host=<kind>` until that kind has a host |

## Manifest `vgs` block

| Key | Value |
|---|---|
| `capabilities` | array of capability names from the table above |
| `budgets` | object, reserved for a validation row's ceilings |
| `requires` | refused |
