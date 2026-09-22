# shell/

The Quickshell shell root. `shell.qml`, `Core/`, `Hosts/`, `Commons/` and `Ui/` are the core; `plugins/` holds first-party plugins and has its own `AGENTS.md`.

- The core names no plugin and imports no plugin directory. `scripts/check-plugin-boundary.py` refuses a `vgs.<name>` literal or a plugin import here.
- Every Wayland surface is created in `Hosts/`. A host destroys the plugin instance it built before it builds another.
- `Core/PluginLogic.js` is pure: no QML object, no I/O. `scripts/test-plugin-logic.js` runs it under node, and every decision about manifests, configuration merging and enablement lives there once.
- `Core/Compositor.qml` is the only file that dispatches to Hyprland. It judges every reply by text.
- `Core/Plugins.qml` is the only place a plugin instance is created, given properties or updated. A host owns a surface and `PluginSlot`s, hands host-owned values through the slot's `context`, and destroys its surface when no instance can be built.
- A property change handler runs before a binding that depends on the same property re-evaluates; read the source property inside the handler, not the binding.
