# Hyprland decisions

Covers: docs/decisions/D028-*, docs/decisions/D044-*, docs/decisions/D048-*, docs/decisions/D059-*, docs/decisions/D067-*, docs/decisions/D071-*, docs/decisions/D080-*, docs/decisions/D086-*, docs/decisions/D096-*

The decision records on the generated Hyprland layer, application windows, shortcuts and outputs. [Decisions](decisions.md) holds the other architecture records. [INDEX.md](../decisions/INDEX.md) holds the full log with dates, rationale and status.

- [D028](../decisions/D028-one-generated-hyprland-layer.md): the shell writes one Hyprland Lua layer from the theme and plugin manifest data, loaded by one line in `hyprland.lua`.
- [D044](../decisions/D044-application-windows-are-hyprland-toplevels.md): an application window is kind `window`, a Hyprland toplevel of class `org.vgs.shell` titled with its plugin's name, which an unaccepted Escape closes; Settings, Dev Tools and the Gallery are ones. Every other surface is a transient overlay, and a flyout closes on an outside click. Refines D032.
- [D048](../decisions/D048-theme-owned-hyprland-appearance.md): themes own bounded Hyprland border, radius and motion appearance groups through manifest-declared switches. Refines D015 and D028.
- [D059](../decisions/D059-keycodes-and-effective-shortcut-keys.md): keycodes and plugins' read-only effective shortcut keys share the generated layer's configuration and conflict judges.
- [D067](../decisions/D067-overlay-keyboard-capture.md): full-screen overlays capture keyboard input through a Hyprland submap. Refines D028.
- [D071](../decisions/D071-hold-shortcuts-use-a-release-companion.md): core hold shortcuts complete through a release companion under one registration lifetime. Refines D028 and D012.
- [D080](../decisions/D080-hyprland-options-rendered-from-data.md): a plugin's Hyprland input options are rendered into the layer from data, written only while the user's configuration sets them, and read back through capability `hyprland`, whose layout switch is its own `hyprctl` command. Refines D028. Its monitor half, the rule writer and the guarded preview, is superseded by D096.
- [D086](../decisions/D086-key-capture-passthrough-submap.md): the Settings key field captures a pressed combo while Hyprland is in the layer's `vgs:passthrough` submap, whose one bind is Escape; `KeyCapture.qml` owns the capture and leaves the submap on commit, focus loss and teardown, and the layer leaves it on Escape, its window's close, a 10 s timeout and each load. Refines D028 and D067.
- [D096](../decisions/D096-vgs-reads-outputs-and-writes-no-monitor-rule.md): VGS reads the outputs Hyprland lists through the shared capability `monitors` and writes no monitor rule; monitor settings belong to the user's own Hyprland config. Supersedes the monitor half of D080.
