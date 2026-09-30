# D057: Keycodes and effective shortcut keys use the generated layer's judges

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: VGS-614, [Jarvis plan § Keys](../plans/v2-jarvis-plan.md#41-keys-manifest-hyprlandbinds-rebindable-in-settings-and-shelljson)

**Refines**: [D028](D028-one-generated-hyprland-layer.md)

**Context**: A physical key must remain bindable when its keysym changes with the keyboard layout. A plugin must show the user's rebound key, not its manifest default.

**Decision**: `PluginLogic.hyprlandKey` accepts decimal keycodes in Hyprland's unsigned 32-bit range and normalizes them to lower-case `code:<n>` without leading zeros. `shell.shortcut.keys` reads the calling plugin's effective keys through the same configuration and conflict judges as the generated layer. [hyprland.md § Shortcut key reads](../architecture/hyprland.md#shortcut-key-reads) defines the API.

**Rationale**:
- Hyprland's Lua parser requires the lower-case `code:` prefix. One normalizer keeps manifest defaults, Settings writes and hand-edited rebounds equal.
- A plugin receives its own read-only map, with a fresh object per read. Configuration changes update QML bindings without another configuration store.
- The map reports a lost conflict as null. A label therefore does not advertise a key the shell skipped.
- The map describes the generated layer. Scraping compositor binds cannot recover the shell's shortcut names, defaults or null unbindings.

**Omarchy comparison**: Read the local read-only `basecamp/omarchy` reference at `8b4eae6`. The [shortcut registry](https://github.com/basecamp/omarchy/blob/8b4eae6/shell/shell.qml) uses `parseShortcuts` to read the shared shortcut list and create `GlobalShortcut` registrations. Its [Hyprland helpers](https://github.com/basecamp/omarchy/blob/8b4eae6/default/hypr/helpers.lua) route binds to those global shortcuts. VGS keeps the same native registration path. It differs because plugin manifests own defaults and Settings owns rebounds, so the existing judges must supply the labels. No extra key configuration file is needed.

**Alternatives considered**: Keep keysym-only binds, which change with layouts; copy manifest defaults into plugins, which gives stale labels after a rebind; or read compositor JSON, which omits Lua's parsed `sMkKeys` keycodes and cannot represent shell defaults.

**Revisit When**: Hyprland changes keycode syntax or exposes shortcut identity and parsed keys through a readback API that can include later user overrides.

**Verification**: `scripts/test-hyprland-layer.js` pins grammar, normalization, conflicts and maps with planted controls. `scripts/qml-tests/tst_shortcutregistry.qml` pins reactive provider reads and local mutation. `scripts/test-qml-unit.sh` plants snapshot and foreign-plugin controls. `scripts/smoke/rows/hyprland.sh` reads the rebound key from the fixture and the registered bind from the nested compositor.
