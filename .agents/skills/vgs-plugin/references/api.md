# Plugin API

What a plugin receives and may call. The core owns every table here; a value not listed does not exist for a plugin.

## Kinds

| Kind | Entry point key | Base | Host | Shown when |
|---|---|---|---|---|
| `bar-widget` | `barWidget` | `BarWidget` from `qs.Ui` | the active bar's sections | placed in `bar.layout.<section>` and a bar is active |
| `bar` | `bar` | `Item` | the bar host, one per screen | it is `bar.id` in the configuration |
| `panel` | `panel` | `Item` with `open(payloadJson)` and `close()` | the panel host | summoned |
| `overlay` | `overlay` | `Item` with `open(payloadJson)` and `close()` | the overlay host | summoned |
| `menu` | `menu` | `Item` with `open(payloadJson)` and `close()` | the menu host | summoned |
| `service` | `service` | `Item` | none | enabled |

Hosts present today: bar. Panel, overlay and menu hosts land with the first plugin of each kind; until then those kinds validate but are not shown.

## Properties a bar widget receives

| Property | Type | Meaning |
|---|---|---|
| `bar` | object | the bar API below |
| `moduleName` | string | the plugin id; the template sets it |
| `settings` | object | the widget's inline entry from `bar.layout`, for example `{ "id": "vgs.clock", "format": "HH:mm" }` |

`BarWidget` adds `vertical`, `barSize` and `setting(name, fallback)`.

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
| `shell` | object | the bar plugin's scoped shell object |

## Properties a bar receives

`shell`, `barConfig` (the effective `bar` configuration object) and `screen`. The bar builds each widget with `shell.widgets.entryUrl(id)` and hands it the three widget properties. `widgetIds()` returns the built ids for the smoke.

## The shell object

| Member | Present | Value |
|---|---|---|
| `shell.manifest` | always | this plugin's validated manifest |
| `shell.widgets.entryUrl(id)` | always | the `file://` entry point of an enabled bar widget, or `""` |
| `shell.widgets.manifestFor(id)` | always | a plugin's manifest, or undefined |
| `shell.compositor.focusWorkspace(id)` | with capability `compositor` | one dispatch through the core's reply judge |

## Capabilities

| Name | Grants |
|---|---|
| `compositor` | `shell.compositor` |

## Theme tokens in `qs.Commons`

| Token | Type |
|---|---|
| `Color.foreground`, `Color.background`, `Color.accent`, `Color.urgent`, `Color.muted` | color |
| `Color.bar.background`, `Color.bar.text`, `Color.bar.active` | color |
| `Style.cornerRadius` | int |
| `Style.space(units)` | int, four pixels per unit |
| `Style.spacing.xs`, `sm`, `md`, `lg`, `xl`, `controlGap`, `controlPaddingX` | int |
| `Style.font.family`, `Style.font.size`, `Style.font.small` | string, int, int |
| `Style.bar.sizeHorizontal`, `Style.bar.sizeVertical` | int |
| `Util.alpha(color, opacity)`, `Util.fileUrl(path)`, `Util.shellQuote(value)` | function |

## IPC

`bin/vgsh ipc call shell <function> [args]`, target `shell`:

| Function | Reply |
|---|---|
| `ping` | `ok` |
| `guarded` | `true` when started by the runner |
| `listPlugins` | JSON: `plugins[]` with `id`, `version`, `kinds`, `enabled`, `dir`; `errors[]`; `collisions[]` |
| `listShellConfig` | the effective configuration as JSON |
| `barWidgets` | JSON: screen name to the widget ids its bar built |
| `setPluginEnabled <id> <true|false>` | `ok`, `ok hidden=<ids>` or `unknown: <id>` |
| `reloadConfig` | `ok` |
| `rescanPlugins` | `ok`; re-reads manifests and rebuilds every host |

## Manifest `vgs` block

| Key | Value |
|---|---|
| `capabilities` | array of capability names from the table above |
| `budgets` | object; a ceiling a validation row asserts, with the measurement that produced it named in the PR |
| `requires` | refused |
