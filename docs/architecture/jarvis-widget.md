# Jarvis bar widget

Covers: shell/plugins/vgs.jarvis/Widget.qml, shell/plugins/vgs.jarvis/WidgetView.js, scripts/test-jarvis-widget.js, scripts/qml-tests/tst_jarvis_widget.qml, scripts/smoke/rows/jarvis-widget.sh

The widget shows Jarvis's state in the bar and toggles privacy mute. It draws only the status the [Jarvis service](jarvis.md) publishes. It runs no process and holds no state of its own. The core builds it only while Jarvis is enabled and its widget is placed, so it is never the required capture indicator.

## Placement

The manifest declares kind `bar-widget` with `defaultSection` `right`. Enabling Jarvis through the manager places an unplaced widget, as [placement.md](placement.md) states. The shipped configuration enables Jarvis without a placement, so the widget is absent until the user turns on Show in bar.

## States

`WidgetView.js::view` is the one judge from the status values `daemon`, `detail` and `audio` to the widget's state, icon, tone and tooltip. The first matching rule wins:

| State | Rule | Icon | Tone |
|---|---|---|---|
| live | Session's capture is not `closed` | `audio-lines` | accent |
| problem | `daemon` or `audio` has tone `danger`, or the phase is `error` | `circle-alert` | danger |
| off | no Session state yet | `power-off` | neutral |
| muted | mute is `on` or `muting` | `mic-off` | neutral |
| off | the gate is down | `power-off` | neutral |
| working | the phase is `thinking`, `speaking`, `confirming` or `acting` | `loader` | info |
| ready | the phase is `idle` | `mic` | the bar's foreground |

- Live comes first: an opening, open or closing microphone always shows. A mute that waits for capture to close therefore reads live until the close completes.
- The tooltip's first line names the state. A problem names its cause text. Off before the first state shows the daemon's own text, such as Starting or Restarting. The service clears `detail` when the child ends, so the retry wait and a problem never show the ended child's state. Off with the gate down names its reason. The second line follows the mute region a click toggles, whatever state the icon shows: "Click to unmute" while a Session state has mute `on` or `muting`, otherwise "Click to mute".
- The shell has no coding-task status yet. Working therefore means a Session phase in which Jarvis is busy with its microphone closed.
- A tone, region kind, gate reason or phase outside the shapes that `Service.qml` and `Session.js` produce throws a keyed `jarvis widget:` error. Listening and armed with capture closed are such shapes. No value falls back to a default.

## Mute path

The service owns mute. It registers the IPC handler `mute` once per instance, beside its shortcuts. The handler calls the same `intent("mute")` as the Mute key and answers `ok`. [jarvis-controls.md § Privacy mute](jarvis-controls.md#privacy-mute) defines that intent: a refusal toast during a permanent problem, one pending request before the daemon is ready, and the toggle when ready.

The widget calls `shell.ipc.call("mute", "")` and logs any reply other than `ok`. The same handler answers `vgsh ipc call vgs.jarvis invoke mute`. No second mute path exists.

## Keyboard

`BarItem` is a button that takes Tab focus. Space activates it as a click. `BarItem` handles neither Return nor keypad Enter, so the widget adds `Keys.onReturnPressed` and `Keys.onEnterPressed`. The bar layer takes no keyboard focus in the live shell, so the Mute shortcut is the keyboard path there. The QML unit test proves Space, Return and Enter on a focused widget.

## Evidence

- `scripts/test-jarvis-widget.js` runs the judge under node. Its Session records come from `Session.initial`, pass `Session.validate` and take their phase from `Session.phaseOf`. It covers every state, each precedence edge, every gate reason and working phase, and each refusal. Each control removes one rule from a copy of the view and must fail an assertion.
- `scripts/qml-tests/tst_jarvis_widget.qml` builds `Widget.qml` with a stand-in `shell`. It reads the drawn icon, colour and tooltip per state. A click, Space, Return and Enter each make exactly one `mute` call. Mutation rows in `scripts/test-qml-unit.sh` drop the click call and each key handler, change the handler name, fix the icon, swap one tone and accept an unknown tone.
- `scripts/smoke/rows/jarvis-widget.sh` runs the real service with the scripted daemon fixture. It reads the right section, then the drawn widget for off before the first state, ready, live, thinking, speaking, muted by a click, unmuted and muted again by the physical Mute key, unmuted by a click, live while mute waits for capture to close, off with the Restarting text after the daemon is killed, a permanent problem with its refusal toast, and off for the unconfigured stock daemon. The retry case plants a 3 s retry delay in a copy of `Service.qml`, so the row reads the widget before the next start. Four controls each plant one defect in a copy of a plugin file. A click that calls nothing and a handler that sends no intent each fail the click assertion once. A view that reads the microphone from the phase fails the closing assertion once. A service that keeps the ended state fails the Restarting assertion once. No latency budget is claimed.

## Omarchy comparison

The Omarchy shell's `plugins/bar/widgets/Microphone.qml` toggles the mute of PipeWire's default source on a click and shows the microphone as in use while a stream records. VGS does not change the default source. Privacy mute is Jarvis's persistent Session mute, which the service owns and the daemon stores, so other applications keep their microphone. The widget reads the service's status instead of PipeWire, because Session already decides when Jarvis holds capture.
