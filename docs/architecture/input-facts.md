# Input facts

Covers: shell/Core/Compositor.qml, shell/Core/Dispatch.js, shell/Core/HyprlandState.qml, shell/Core/HyprlandState.js, shell/Core/HyprlandLayer.js, shell/Core/Capabilities.qml, shell/Hosts/PluginSlot.qml, shell/Hosts/OverlaySurface.qml, bin/lib/xkb-keys.py, scripts/test-input-facts.js, scripts/test-xkb-keys.py, scripts/smoke/rows/input-facts.sh, scripts/smoke/fixtures/plugins/acme.input-facts/**

[D090](../decisions/D090-core-input-facts.md) adds read-only input observations to the existing compositor and Hyprland device owners. [Jarvis input](jarvis-input.md) consumes them. An observation grants no authority to send input.

## Owners

- `HyprlandState.resolveKeys(keys, done)` refreshes the existing device reader. `HyprlandState.js::keyRequest` applies the core key syntax judge and selects the main keyboard. `xkb-keys.py` compiles its active layout, variant and options through the system XKB library. The same device reader obtains the global keyboard options. A second map resolves the global bind translation at group zero, which Hyprland uses independently of the active device group. Both maps must succeed. Custom global files, rules and models refuse; the supported rules are evdev and the model is pc105. A missing or ambiguous layout or symbol refuses. The helper opens no device and sends no input.
- `Compositor.observeInput(point, done)` reads clients, active window, monitors, layers and cursor in one Hyprland batch. `Dispatch.inputTarget` owns classification. A null point means keyboard input. A point names absolute layout coordinates for pointer input.
- Core hosts register their raw Qt windows with Compositor. The observation reads their current activation as well as Hyprland's active application. This identifies a VGS layer with keyboard focus when `activewindow` still names the application below it. Registration ends with its host.
- Desktop entries identify application classes and `TerminalEmulator` categories. An unrecognized application or ambiguous overlapping client refuses input. No terminal class inventory duplicates those entries.
- A read failure clears the result. Each on-demand owner accepts one request at a time and bounds its lifetime. No stale successful observation grants input after a failed read.

## Limits

The compositor exposes layer rectangles, but not their input regions. Protected VGS top and overlay rectangles include pass-through gaps. A background or bottom rectangle refuses only when no application covers the point. This can refuse a click that a physical pointer would pass to an application. No protected rectangle becomes a permitted application target through that gap.

XKB compilation uses the system rule files and the device owner's active layout metadata. A custom external keymap that metadata cannot describe is not supported. Global custom keymap files refuse. Devices do not expose a per-device custom file path, so native code meaning for such a file cannot be established. The emitted-code protection still uses the independent global map. Missing or unresolved keys refuse.

The observation is a snapshot. A user can change focus after it. The input consumer must observe immediately before sending and refuse a changed target. No public interface atomically binds a synthetic input event to an application.

## Evidence

`scripts/test-input-facts.js` controls the pure classification and key request rules. `scripts/test-xkb-keys.py` uses the real system library under a scratch environment and controls the resolver's independent rules. The nested `input-facts` row reads the capabilities back from their fixture. No real authentication or physical device enters these checks.
