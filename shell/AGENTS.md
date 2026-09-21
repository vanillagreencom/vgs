# shell/

The Quickshell shell root. `shell.qml`, `Core/`, `Hosts/`, `Commons/` and `Ui/` are the core; `plugins/` holds first-party plugins and has its own `AGENTS.md`.

- The core names no plugin and imports no plugin directory. `scripts/check-plugin-boundary.py` refuses a `vgs.<name>` literal or a plugin import here.
- Every Wayland surface is created in `Hosts/`. A host destroys the plugin instance it built before it builds another.
- `Core/PluginLogic.js` is pure: no QML object, no I/O. `scripts/test-plugin-logic.js` runs it under node, and every decision about manifests, configuration merging and enablement lives there once.
- `Core/Compositor.qml` is the only file that dispatches to Hyprland. It judges every reply by text.
- A `qs.Commons` or `qs.Ui` name is Omarchy's name for that token or control, so an Omarchy plugin reads it unchanged.
- Hand a plugin its properties by assignment after `createObject`, never as initial properties, which lose functions and arrays.
- Every Quickshell type, property or signal comes from the 0.3.1 reference, cited, never from memory.
