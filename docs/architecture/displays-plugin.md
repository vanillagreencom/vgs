# Displays plugin

Covers: shell/plugins/vgs.displays/*.qml, shell/plugins/vgs.displays/*.js, shell/plugins/vgs.displays/manifest.json, scripts/test-displays-logic.js, scripts/smoke/rows/displays.sh

`vgs.displays` sets the brightness of each display on its own: a bar widget per screen, a flyout, the brightness keys with an on-screen display, and System → Displays. It runs the brightness helper that [displays.md](displays.md) describes, and nothing else. The plan is [v2-system-plan.md § 3.5](../plans/v2-system-plan.md#35-displays--vgsdisplays-s15s17-s24). [D083](../decisions/D083-brightness-helper-and-uaccess-rule.md) records why a helper runs.

## Parts

| Part | File | Role |
|---|---|---|
| Service | `Service.qml` | Owns every helper run, the assignments file, the brightness keys, the on-screen display, Identify, the plugin's IPC and every status write. |
| Widget | `Widget.qml` | One per bar. It controls the display on its own screen (`screens.current`): a scroll moves it one `brightnessStep` a notch and shows the on-screen display there, and a click opens the flyout. It hides while no ready display lights its screen. |
| Flyout | `Panel.qml` | One row per display, the display on the flyout's own screen first; Link displays; Display Settings, which opens the plugin's pane. |
| Pane | `Pane.qml` | System → Displays: the rows, each display's Screen choice and Identify, Link displays, the stale choices, and the access entries with their actions. |
| Row | `DisplayRow.qml` | One display, in the flyout and the pane: a Slider while it is ready, else its state and Allow while its access entry offers it. |
| Layers | `Osd.qml`, `Identify.qml` | The passive layers the service shows through `layers`: a `LevelOsd`, and each screen's name. |
| Logic | `DisplaysLogic.js` | Every decision on this page. |

The surfaces read the status and ask the service through the plugin's IPC: `set` with `{ id, percent, osd? }`, `assign` with `{ device, output }`, where `output` "" forgets the choice, and `identify` with a display id. No surface runs a process.

## Runs

- The helper runs one at a time: `list --outputs -` with `shell.monitors.outputs` on its stdin, or `set ID PERCENT`. A change waits as the latest value per display, in the order each display was first asked. A drag of any length therefore makes the run in flight and one more per display. A list waits behind the changes (`queueSet`, `takeRun`). Omarchy's monitor panel keeps one set in flight and queues the next the same way.
- The service stops a run after 8 s, v1's bridge timeout (`brightnessbridge.go`). It logs a run that ends without an answer the judge accepts. After a failed `set` it lists again, since the level shown was the one asked for.
- The service lists again 1 s after the last change of `shell.monitors.outputs`, `shell.system.revision` or `shell.requirements.revision`. A hotplug, an Allow and an install therefore each read the displays again. The first list waits for the outputs and the assignments file.
- While a change waits or runs, the display's published level is the one asked for (`pendingPercent`). A key, a scroll and a linked slider move from that level.

## Changes

- A slider, a key and a scroll hold a display at 1 % or more, as Omarchy's `clampBrightness` does. A kernel backlight at 0 % turns its panel off.
- A brightness key moves `brightnessStep`, but 1 % at a time up from below 5 % and down from 5 % or below, as Omarchy's `omarchy-brightness-display` does. `keysTarget` `focused` moves the ready display on the output Hyprland focuses (`Hyprland.focusedMonitor`); `all` moves every ready display by its own step.
- The keys are the manifest's `XF86MonBrightnessUp` and `XF86MonBrightnessDown` binds. A user's own bind on the same key shows as a conflict on the Settings page's Keys row, and clearing VGS's key there leaves the user's bind. VGS never edits the user's file.
- While `linked` is on, a change to one display moves every other ready display by the same amount, each held to 1 to 100 (`linkedChanges`).
- A key and a scroll show the on-screen display on the outputs the changed display lights, for 1.5 s. A slider shows none.

## Keys

- System → Displays opens on the first display's slider. Tab follows reading order through the sliders, each Screen choice and Identify, Link displays and the access actions. Up and Down move a slider and a closed Screen choice.
- The flyout opens on its first slider and takes Tab the same way. The bar item takes no focus.

## Assignments

The helper places what it can ([displays.md § Output mapping](displays.md#output-mapping)). The user places the rest in the pane. The choices live in `${XDG_STATE_HOME}/vgs/plugins/vgs.displays/assignments.json` as `{ "assignments": [{ device, label, output }] }`. `parseAssignments` judges the file: at most 64 entries, each with exactly those three keys as printable text, and one entry per device.

- `device` is an Apple display's USB parent and serial, `usb:<parent>#<serial>`, else its helper id. A unit plugged into another port reads as a new device, so the pane asks again.
- `output` is the output's identifier as the `monitors` capability names it. A tiled Pro Display XDR's two outputs share one identifier, so one choice lights both.
- An entry applies only to a display the helper left unplaced, only while its device and its output are both present, and only while no other display lights that output (`resolve`). The service publishes each entry as `applied`, `stale` (its device or its output is gone) or `unused`. A stale entry stays in the file and never applies; the pane lists it with Forget.
- A new choice replaces the device's own entry and the entry of any other present device on the same output, and keeps stale entries. Past 64 entries the oldest entry of an absent device goes.
- The service logs a file the judge refuses or it cannot read, and reads it as no choices; the pane says so. The next choice replaces the file. The first write makes the plugin's state directory: a Quickshell `FileView` write makes the file's parent directories first ([`fileview.cpp`](https://git.outfoxxed.me/quickshell/quickshell/src/tag/v0.3.1/src/io/fileview.cpp) `FileViewWriter::write`, v0.3.1).
- Identify shows every screen's output name and description for 3 s. For that time it moves the chosen display to 10 %, or to 100 % when the display stood below 50 %, then back, so the user sees which screen it lights. The pane's Screen choice lists each output identifier once.

## Status

| Key | Type | Value |
|---|---|---|
| `displays` | `data` | `{ state, items }`: `state` is `pending`, `ready` or `failed`, the last list's outcome; each item is `{ id, device, label, backend, state, percent, outputs, assigned }` |
| `assignments` | `data` | `{ entries, error }`: each entry with its `state`, and the file's keyed refusal or null |
| `appleAccess` | `state` | The `apple-displays` step; Allow while it reads `needed` or `nixos` |
| `ddcAccess` | `state` | The `i2c-dev` step; Allow while it reads `needed` or `nixos`. `denied` reads "DDC access isn't supported on this system" |
| `ddcTool`, `backlightTool` | `state` | Install while `shell.requirements.missing` names `ddcutil`, or names `brightnessctl` while a backlight reads `missing` |

A display that reads `no-access` shows Allow while the access entry of its backend offers it. The flyout and the pane run the action with `shell.status.act`, the plugin's own status action ([status-actions.md](status-actions.md)).

## Invariants

1. The runs coalesce: a 20-event drag makes 2 runs, each display keeps its place, a list waits behind the changes, and no second run starts while one is in flight. A key moves the display on the focused output, a linked change moves the others by its delta, and the dark end takes 1 % steps. The judge refuses each malformed file, and stale and unused entries never apply. Enforced by `scripts/test-displays-logic.js`, whose controls drop the coalescing, put the list first, start a second run, ignore the focused output, drop the fine steps, link by level, apply an entry whose output is gone or whose display the helper placed, accept one device twice, drop stale entries on a new choice, allow 0 % and withhold Allow from a needed step.
2. In the nested sandbox, over the HID fake's Pro Display XDR and two Studio Displays with one serial, `scripts/smoke/rows/displays.sh` reads: no display placed and no widget shown; on the keyboard alone in System → Displays, Up raising the XDR and Down on its Screen choice placing it; each bar's widget controlling its own display; a burst of 20 scroll notches making at most 2 helper runs, leaving its last level in the fake and changing no other display, with the on-screen display on that screen alone; a key acting on the focused output; the flyout listing its screen's display first; Identify; a closed node reading `no-access`, with Allow handed to `core/system`; and the choices coming back from the file after the service is rebuilt while the second Studio Display still waits. Its control sends the 20 notches one run at a time and reads 20 runs.
