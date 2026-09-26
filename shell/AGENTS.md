# shell/

The Quickshell shell root. `shell.qml`, `Core/`, `Hosts/`, `Commons/` and `Ui/` are the core; `plugins/` holds first-party plugins and has its own `AGENTS.md`.

- The core names no plugin and imports no plugin directory. `scripts/check-plugin-boundary.py` enforces it.
- What the loader, a host and a capability provider may do, and what each hands a plugin: `docs/architecture/plugins.md` § What the core builds and hands over and § Capabilities.
- Every Hyprland dispatch and every Quickshell fact the code relies on: `docs/architecture/runtime.md` § Hyprland and § QML. Read them before editing `Core/Compositor.qml`, `Core/Dispatch.js` or a handler that reads a property a binding also reads.
